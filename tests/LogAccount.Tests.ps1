#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test credentials are made-up values held only in memory.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The Get-AzKeyVaultSecret stub mirrors the real parameters.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock runs in the module scope; a global is the only way to show it whether the credential lock was held.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The parallel blocks pass their values with $using: and into the module with param(); the analyzer cannot see through the nested script block.')]
param()
Set-StrictMode -Version Latest

# Which account reads a node's logs: local until the node has reported DomainJoined and DomainAdminsConfigured, then the
# domain account the operator supplies (never the LCM user), guarded by one account-wide circuit breaker. No Azure, no node:
# Key Vault is mocked, no secret is real.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    # Az.KeyVault may be missing on a build agent; Pester can only mock a command that exists.
    $script:StubbedKeyVault = $false
    if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        Set-Item -Path 'function:global:Get-AzKeyVaultSecret' -Value { [CmdletBinding()] param([string]$VaultName, [string]$Name, [string]$Version) throw 'Get-AzKeyVaultSecret stub called without a mock.' }
        $script:StubbedKeyVault = $true
    }
    Import-SonarTestModule
    $script:Password = 'D0main-Pa55-not-real'
    $script:LocalPassword = 'Local-Pa55-not-real'
    $script:T0 = [datetime]::SpecifyKind([datetime]'2026-11-07T20:00:00', 'Utc')
    $script:Accounts = [pscustomobject]@{
        local  = [pscustomobject]@{ username = 'azl-admin' }
        domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example-mgmt-01/svc-join-password'; maxRejections = 2 }
    }
    function global:New-AccountConfig([string]$Identity = 'ActiveDirectory', [object]$Accounts = $script:Accounts) {
        [pscustomobject]@{ identityModel = $Identity; logAccounts = $Accounts; nodes = @([pscustomobject]@{ name = 'node-01'; seed = $true }, [pscustomobject]@{ name = 'node-02' }, [pscustomobject]@{ name = 'node-03' }); seedNode = [pscustomobject]@{ name = 'node-01'; address = '192.0.2.11' } }
    }
    function global:New-AccountLine([string]$At, [string]$Node, [string]$State, [string]$Evidence = '', [hashtable]$Extra = @{}) {
        $o = [ordered]@{ timestamp = $At; node = $Node; stage = 'OsConfiguration'; step = 'DomainJoin'; state = $State; evidence = $Evidence; level = 'Info'; nextAction = ''; method = ''; transport = '' }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        $o | ConvertTo-Json -Compress -Depth 6
    }
    # A shared state with the nodes' domain events fed in: 'none', 'joined' (DomainJoined) or 'both' (and DomainAdminsConfigured).
    function global:New-AccountShared([string]$Domain = 'both', [string[]]$Nodes = @('node-01', 'node-02', 'node-03')) {
        InModuleScope AzlSonar -Parameters @{ D = $Domain; N = $Nodes } {
            param($D, $N)
            $shared = Initialize-AzlSonarSharedState
            foreach ($n in $N) {
                if ($D -in 'joined', 'both') { Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line ('{"timestamp":"2026-11-07T19:00:00Z","node":"' + $n + '","stage":"OsConfiguration","step":"DomainJoin","state":"DomainJoined"}') }
                if ($D -eq 'both') { Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line ('{"timestamp":"2026-11-07T19:01:00Z","node":"' + $n + '","stage":"OsConfiguration","step":"DomainJoin","state":"DomainAdminsConfigured"}') }
            }
            $shared
        }
    }
    # One Select-AzlSonarNodeAccount call: what the node is given, as plain values.
    function global:Invoke-AccountPick($Shared, [string]$Node = 'node-01', [double]$Minutes = 0, [object]$Config = (New-AccountConfig), [bool]$Connect = $true) {
        InModuleScope AzlSonar -Parameters @{ S = $Shared; C = $Config; N = $Node; Now = $script:T0.AddMinutes($Minutes); K = $Connect } {
            param($S, $C, $N, $Now, $K)
            $local = [pscredential]::new('azl-admin', (ConvertTo-SecureString 'Local-Pa55-not-real' -AsPlainText -Force))
            $pick = Select-AzlSonarNodeAccount -Shared $S -Config $C -Node $N -Local $local -Now $Now -Connect $K
            [pscustomobject]@{ UserName = $pick.Credential.UserName; Password = $pick.Credential.GetNetworkCredential().Password; Kind = $pick.Account.kind; Reason = $pick.Account.reason; Warning = $pick.Account.warning; Probe = $pick.Probe; Ticket = $pick.Ticket }
        }
    }
    function global:Register-AccountResult($Shared, [string]$Node, [string]$Class, [double]$Minutes = 0, [string]$Message = '', [object]$Config = (New-AccountConfig), [object]$Ticket = $null) {
        InModuleScope AzlSonar -Parameters @{ S = $Shared; C = $Config; N = $Node; K = $Class; M = $Message; Now = $script:T0.AddMinutes($Minutes); T = $Ticket } {
            param($S, $C, $N, $K, $M, $Now, $T)
            if ($null -ne $T) { Register-AzlSonarAccountResult -Shared $S -Config $C -Node $N -Class $K -Message $M -Now $Now -Ticket $T }
            else { Register-AzlSonarAccountResult -Shared $S -Config $C -Node $N -Class $K -Message $M -Now $Now }
        }
    }
    # The first use of the domain account is a single probe; a node that connects with it and reports ok verifies it for everybody.
    function global:Confirm-AccountDomain($Shared, [string]$Node = 'node-01', [double]$Minutes = 0, [object]$Config = (New-AccountConfig)) {
        $p = Invoke-AccountPick $Shared $Node $Minutes $Config
        Register-AccountResult $Shared $Node ok $Minutes '' $Config $p.Ticket
        $p
    }
    function global:Get-AccountBreaker($Shared) { InModuleScope AzlSonar -Parameters @{ S = $Shared } { param($S) Get-AzlSonarAccountBreaker -Table $S['LogAccount'] } }
}

AfterAll {
    foreach ($f in 'New-AccountConfig', 'New-AccountLine', 'New-AccountShared', 'Invoke-AccountPick', 'Register-AccountResult', 'Confirm-AccountDomain', 'Get-AccountBreaker') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
    if ($script:StubbedKeyVault) { Remove-Item -LiteralPath 'Function:\Get-AzKeyVaultSecret' -ErrorAction SilentlyContinue }
}

Describe 'Key Vault references: validated like Azure validates them' {
    It 'reads keyvault://vault/secret and an optional version' {
        InModuleScope AzlSonar {
            $r = ConvertFrom-AzlSonarKeyVaultReference -Reference 'keyvault://kv-example-mgmt-01/svc-join-password'
            $r.Vault | Should -Be 'kv-example-mgmt-01'
            $r.Secret | Should -Be 'svc-join-password'
            $r.Version | Should -Be ''
            $v = ConvertFrom-AzlSonarKeyVaultReference -Reference 'keyvault://kv-example/s/0123456789abcdef0123456789ABCDEF'
            $v.Version | Should -Be '0123456789abcdef0123456789ABCDEF'
            Get-AzlSonarKeyVaultReferenceProblem -Reference 'keyvault://kv-example/s/0123456789abcdef0123456789ABCDEF' | Should -Be ''
        }
    }
    It 'refuses what is not a reference, with a message that never echoes the value' {
        InModuleScope AzlSonar {
            foreach ($bad in 'P@ssw0rd!', 'https://kv.vault.azure.net/secrets/x', '', 'keyvault://', 'keyvault://kv-example', 'keyvault://kv-example/a/b/c') {
                (Get-AzlSonarKeyVaultReferenceProblem -Reference $bad) | Should -Match 'keyvault://<vault>/<secret>'
                ConvertFrom-AzlSonarKeyVaultReference -Reference $bad | Should -BeNullOrEmpty
            }
            Get-AzlSonarKeyVaultReferenceProblem -Reference 'Sup3r-Secret-Value' | Should -Not -Match 'Sup3r'
        }
    }
    It 'vault names: 3 to 24 characters, start with a letter, letters digits and single hyphens, no leading or trailing hyphen' {
        InModuleScope AzlSonar {
            foreach ($bad in 'ab', '1vault', '-vault', 'vault-', 'va--ult', 'vault_name', ('v' * 25)) {
                (Get-AzlSonarKeyVaultReferenceProblem -Reference "keyvault://$bad/secret") | Should -Match 'vault that Azure would not accept' -Because $bad
            }
            foreach ($good in 'abc', 'kv-1', ('v' * 24), 'Kv-Example-01') {
                (Get-AzlSonarKeyVaultReferenceProblem -Reference "keyvault://$good/secret") | Should -Be '' -Because $good
            }
        }
    }
    It 'secret names and versions' {
        InModuleScope AzlSonar {
            (Get-AzlSonarKeyVaultReferenceProblem -Reference 'keyvault://kv-example/bad_name') | Should -Match 'secret that Azure would not accept'
            (Get-AzlSonarKeyVaultReferenceProblem -Reference ('keyvault://kv-example/' + ('s' * 128))) | Should -Match 'secret that Azure would not accept'
            (Get-AzlSonarKeyVaultReferenceProblem -Reference 'keyvault://kv-example/s/abc') | Should -Match 'version that is not 32 hexadecimal'
            (Get-AzlSonarKeyVaultReferenceProblem -Reference 'keyvault://kv-example/s/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz') | Should -Match 'version that is not 32 hexadecimal'
        }
    }
}

Describe 'Get-AzlSonarLogAccount (which account, and why)' {
    It 'workgroup before the node reports DomainJoined: the local account' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $false }
        $a.kind | Should -Be 'local'
        $a.userName | Should -Be 'azl-admin'
        $a.reason | Should -Be 'workgroup: using azl-admin'
        $a.warning | Should -Be ''
    }
    It 'joined, but the domain account is not yet a local administrator (no DomainAdminsConfigured): still the local account, and no warning' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $false }
        $a.kind | Should -Be 'local'
        $a.reason | Should -Be 'joined, waiting for domain administrators: using azl-admin'
        $a.waitingForAdmins | Should -BeTrue
        $a.warning | Should -Be ''
    }
    It 'DomainAdminsConfigured without DomainJoined is not enough either' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $false -AdminsConfigured $true }
        $a.kind | Should -Be 'local'
        $a.reason | Should -Be 'workgroup: using azl-admin'
    }
    It 'after DomainJoined and DomainAdminsConfigured: the domain account the operator supplied, NETBIOS\user' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $true }
        $a.kind | Should -Be 'domain'
        $a.userName | Should -Be 'IIC\svc-join'
        $a.reason | Should -Be 'domain-joined: using IIC\svc-join'
    }
    It 'a local identity design stays on the local account even if a join is reported' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig 'LocalIdentity') } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $true }
        $a.kind | Should -Be 'local'
        $a.reason | Should -Match 'identity design is local'
    }
    It 'every pause says why, names the account and never presents the domain account' {
        $cases = @(
            @{ Kind = 'rejected'; Reason = 'IIC\\svc-join was rejected: using azl-admin' },
            @{ Kind = 'open'; Reason = 'was rejected; the domain account is paused for every node \(next check 20:15 UTC\)' },
            @{ Kind = 'lockedOut'; Reason = 'is locked out; the domain account is paused' },
            @{ Kind = 'latched'; Reason = 'rejected repeatedly; the domain account stays paused until its password changes or Sonar restarts' },
            @{ Kind = 'unavailable'; Reason = 'the domain account is not available \(next check 20:15 UTC\)' },
            @{ Kind = 'authorization'; Reason = 'IIC\\svc-join is not an administrator of the node' })
        foreach ($c in $cases) {
            $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig); K = $c.Kind; U = $script:T0.AddMinutes(15) } { param($C, $K, $U) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $true -Pause ([pscustomobject]@{ Kind = $K; Until = $U; Message = 'Vault unreachable.' }) }
            $a.kind | Should -Be 'local' -Because $c.Kind
            $a.userName | Should -Be 'azl-admin'
            $a.reason | Should -Match $c.Reason
            $a.warning | Should -Not -BeNullOrEmpty
        }
    }
    It '-Rejected is the same as a rejected pause' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $true -Rejected $true }
        $a.kind | Should -Be 'local'
        $a.rejected | Should -BeTrue
        $a.reason | Should -Be 'domain-joined, but IIC\svc-join was rejected: using azl-admin'
    }
    It 'joined but the file names no domain account: the local account and a warning that names domain_join_account, never lcm_user as the thing to set' {
        $none = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = ''; username = ''; passwordRef = '' } }
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig 'ActiveDirectory' $none) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-02' -DomainJoined $true -AdminsConfigured $true }
        $a.kind | Should -Be 'local'
        $a.warning | Should -Match 'domain_join_account'
        ($a.warning + $a.reason) | Should -Not -Match 'lcm'
    }
    It 'the account given with -Credential is the local account when it is known better than the file' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'n' -DomainJoined $false -LocalUserName '.\operator' }
        $a.reason | Should -Be 'workgroup: using .\operator'
    }
    It 'a user name that already carries its domain is not given a second one' {
        $acc = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join@iic.example.test'; passwordRef = 'keyvault://kv-example/s' } }
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig 'ActiveDirectory' $acc) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'n' -DomainJoined $true -AdminsConfigured $true }
        $a.userName | Should -Be 'svc-join@iic.example.test'
    }
}

Describe 'The domain flags in the event store' {
    BeforeEach {
        $script:Store = [hashtable]::Synchronized(@{})
        $script:Feed = { param($Lines) InModuleScope AzlSonar -Parameters @{ S = $script:Store; L = @($Lines) } { param($S, $L) foreach ($x in $L) { Add-AzlSonarOsConfigEvent -Store $S -Line $x } } }
        $script:State = { param($Node) InModuleScope AzlSonar -Parameters @{ S = $script:Store; N = $Node } { param($S, $N) Get-AzlSonarOsDomainState -Store $S -Node $N } }
    }
    It 'joined and admins-configured are two separate facts, a plan that finds the node not joined clears both' {
        (& $script:State 'node-01').Joined | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoined' 'joined'))
        $s1 = & $script:State 'node-01'
        $s1.Joined | Should -BeTrue; $s1.AdminsConfigured | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T19:03:00Z' 'node-01' 'DomainAdminsConfigured' 'admins'))
        $s2 = & $script:State 'node-01'
        $s2.Joined | Should -BeTrue; $s2.AdminsConfigured | Should -BeTrue
        (& $script:State 'node-02').AdminsConfigured | Should -BeFalse
        (& $script:State 'NODE-01').Joined | Should -BeTrue
        & $script:Feed @((New-AccountLine '2026-11-07T20:00:00Z' 'node-01' 'DomainJoinPlanned' 'Change: not joined' @{ action = 'Change' }))
        $s3 = & $script:State 'node-01'
        $s3.Joined | Should -BeFalse; $s3.AdminsConfigured | Should -BeFalse
    }
    It 'a DomainJoinFailed does not mark the node as joined, a plan that finds it joined does, and the flags survive a new attempt and a clearing RunStarted' {
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoinFailed' 'The specified domain either does not exist.'))
        (& $script:State 'node-01').Joined | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T19:03:00Z' 'node-01' 'DomainJoinPlanned' 'Ok: already joined' @{ action = 'Ok' }), (New-AccountLine '2026-11-07T19:04:00Z' 'node-01' 'DomainAdminsConfigured' 'admins'))
        & $script:Feed @('{"timestamp":"2026-11-07T20:00:00Z","node":"node-01","stage":"OsConfiguration","state":"NodeStarted"}')
        & $script:Feed @('{"timestamp":"2026-11-07T21:00:00Z","node":"*","stage":"OsConfiguration","state":"RunStarted","nodes":["node-01"]}')
        $script:Store.Contains('node-01') | Should -BeFalse
        $f = & $script:State 'node-01'
        $f.Joined | Should -BeTrue; $f.AdminsConfigured | Should -BeTrue
    }
    It 'the flags are not a machine: the state lists only real nodes' {
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoined' 'joined'))
        $s = InModuleScope AzlSonar -Parameters @{ S = $script:Store; C = (New-AccountConfig) } { param($S, $C) Get-AzlSonarOsConfigurationState -Store $S -Config $C }
        @($s.nodes).name | Should -Be @('node-01', 'node-02', 'node-03')
    }
}

Describe 'Connection failures: what each one says about the account' {
    It 'WinRM: a wrong user name or password is a rejection (error codes and phrases)' {
        InModuleScope AzlSonar {
            foreach ($m in 'The user name or password is incorrect.', 'Logon failure: unknown user name or bad password.', 'Connecting to remote server n1 failed with the following error message : 0x8009030c', 'The WinRM client got 0x8007052e from the server.') {
                (Get-AzlSonarConnectionFailureClass -Transport winrm -Message $m).Class | Should -Be 'rejected' -Because $m
            }
        }
    }
    It 'WinRM: access denied once a session is open (a later step) is authorization: the account got in and may not do this' {
        InModuleScope AzlSonar {
            foreach ($m in 'Access is denied.', 'Connecting to remote server n1 failed with the following error message : Access is denied.', 'WinRM returned 0x80070005') {
                $c = Get-AzlSonarConnectionFailureClass -Transport winrm -Message $m -Stage use
                $c.Class | Should -Be 'authorization' -Because $m
                $c.Reason | Should -Be 'not an administrator of the node'
            }
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([System.UnauthorizedAccessException]::new('Attempted to perform an unauthorized operation.')) -Stage use).Class | Should -Be 'authorization'
        }
    }
    It 'WinRM: a locked-out account is its own class, even when the text also says logon failure' {
        InModuleScope AzlSonar {
            foreach ($m in 'Logon failure: referenced account is currently locked out and may not be logged on to.', 'The account locked out.', 'error 0x80070775') {
                (Get-AzlSonarConnectionFailureClass -Transport winrm -Message $m).Class | Should -Be 'lockedOut' -Because $m
            }
        }
    }
    It 'WinRM: broad words are not enough (the false positives): authentication mechanism, Kerberos, credential provider, timeouts, network errors' {
        InModuleScope AzlSonar {
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The WinRM client cannot process the request. The authentication mechanism requested by the client is not supported (Kerberos, NTLM).').Class | Should -Be 'other'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The credential provider failed to return a credential.').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'No credentials are available in the security package.').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The operation has timed out.').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'WinRM cannot complete the operation. Verify that the specified computer name is valid, that the computer is accessible over the network').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The network path was not found.').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'Something else went wrong.').Class | Should -Be 'other'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message '').Class | Should -Be 'other'
        }
    }
    It 'reads the exception chain and the transport message, not only the first message' {
        InModuleScope AzlSonar {
            $inner = [System.Exception]::new('Logon failure: unknown user name or bad password.')
            $outer = [System.InvalidOperationException]::new('Connecting to the remote server failed.', $inner)
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception $outer).Class | Should -Be 'rejected'
            $record = [System.Management.Automation.ErrorRecord]::new($outer, 'x', [System.Management.Automation.ErrorCategory]::AuthenticationError, $null)
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception $record).Class | Should -Be 'rejected'
        }
    }
    It 'SSH: Permission denied (publickey,password) is a rejection; timeouts and network errors are not' {
        InModuleScope AzlSonar {
            (Get-AzlSonarConnectionFailureClass -Transport ssh -Message 'Permission denied (publickey,password).').Class | Should -Be 'rejected'
            (Get-AzlSonarConnectionFailureClass -Transport ssh -Message 'Connection timed out.').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport ssh -Message 'A connection attempt failed because the connected party did not respond').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport ssh -Message 'Server response does not contain SSH protocol identification.').Class | Should -Be 'other'
            (Get-AzlSonarConnectionFailureClass -Transport ssh -Message 'User account is locked out (0x80070775)').Class | Should -Be 'lockedOut'
        }
    }
}

Describe 'Masking a secret without keeping it' {
    It 'a fingerprint holds no way back to the password and is not text' {
        $f = InModuleScope AzlSonar { New-AzlSonarSecretFingerprint -Secret (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force) }
        $f.Kind | Should -Be 'fingerprint'
        $f.Length | Should -Be 20
        $f.Salt.Length | Should -Be 16
        ($f | ConvertTo-Json -Depth 4) | Should -Not -Match 'D0main'
        ($f | Out-String) | Should -Not -Match 'D0main'
        $f.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }
    It 'Protect-AzlSonarText masks the password wherever it sits, as often as it occurs, and nothing near it' {
        $text = InModuleScope AzlSonar {
            $f = New-AzlSonarSecretFingerprint -Secret (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force)
            [pscustomobject]@{
                Start  = Protect-AzlSonarText -Text 'D0main-Pa55-not-real was rejected' -Secret @($f)
                End    = Protect-AzlSonarText -Text 'tried with D0main-Pa55-not-real' -Secret @($f)
                Middle = Protect-AzlSonarText -Text 'x=D0main-Pa55-not-real;y=D0main-Pa55-not-real!' -Secret @($f)
                Only   = Protect-AzlSonarText -Text 'D0main-Pa55-not-real' -Secret @($f)
                Near   = Protect-AzlSonarText -Text 'D0main-Pa55-not-rea1 and d0main-pa55-not-real and D0main-Pa55-not-real-x' -Secret @($f)
                Short  = Protect-AzlSonarText -Text 'D0main' -Secret @($f)
                Mixed  = Protect-AzlSonarText -Text 'token=abcd1234 D0main-Pa55-not-real' -Secret @('abcd1234', $f)
                Empty  = Protect-AzlSonarText -Text '' -Secret @($f)
            }
        }
        $text.Start | Should -Be '*** was rejected'
        $text.End | Should -Be 'tried with ***'
        $text.Middle | Should -Be 'x=***;y=***!'
        $text.Only | Should -Be '***'
        $text.Near | Should -Be 'D0main-Pa55-not-rea1 and d0main-pa55-not-real and ***-x'
        $text.Short | Should -Be 'D0main'
        $text.Mixed | Should -Be 'token=*** ***'
        $text.Empty | Should -Be ''
    }
    It 'masks a password with unusual characters and a very long text quickly' {
        $r = InModuleScope AzlSonar {
            $f = New-AzlSonarSecretFingerprint -Secret (ConvertTo-SecureString 'pa$$ w0rd"{}\é' -AsPlainText -Force)
            $long = ('x' * 200000) + 'pa$$ w0rd"{}\é' + ('y' * 200000)
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $masked = Protect-AzlSonarText -Text $long -Secret @($f)
            [pscustomobject]@{ Masked = $masked.Contains('***'); Leaked = $masked.Contains('w0rd'); Length = $masked.Length; Ms = $watch.ElapsedMilliseconds }
        }
        $r.Masked | Should -BeTrue
        $r.Leaked | Should -BeFalse
        $r.Length | Should -Be 400003
        $r.Ms | Should -BeLessThan 5000
    }
    It 'registering a password replaces Shared.Redact with a new snapshot of fingerprints and keeps no plaintext, even in memory dumps of the table' {
        $r = InModuleScope AzlSonar {
            $shared = Initialize-AzlSonarSharedState
            $before = $shared['Redact']
            Add-AzlSonarRedaction -Shared $shared -Secret (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force)
            Add-AzlSonarRedaction -Shared $shared -Secret (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force)
            [pscustomobject]@{
                Same = [object]::ReferenceEquals($before, $shared['Redact']); Count = @($shared['Redact']).Count; BeforeCount = @($before).Count
                Strings = @(@($shared['Redact']) | Where-Object { $_ -is [string] }).Count
                Text = (@($shared['Redact']) | ConvertTo-Json -Depth 5) + ((@($shared['Redact']) | Out-String))
            }
        }
        $r.Same | Should -BeFalse
        $r.BeforeCount | Should -Be 0
        $r.Count | Should -Be 1 -Because 'the same password is registered once'
        $r.Strings | Should -Be 0
        $r.Text | Should -Not -Match 'D0main'
    }
}

Describe 'Select-AzlSonarNodeAccount: the credential a connection opens with' {
    BeforeEach {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
    }
    It 'before the join: the local credential, and the Key Vault is not read' {
        $r = Invoke-AccountPick (New-AccountShared 'none')
        $r.UserName | Should -Be 'azl-admin'
        $r.Kind | Should -Be 'local'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 0 -Exactly
    }
    It 'joined but DomainAdminsConfigured has not arrived: still the local credential, the Key Vault is not read, and the reason says why' {
        $r = Invoke-AccountPick (New-AccountShared 'joined')
        $r.UserName | Should -Be 'azl-admin'
        $r.Password | Should -Be 'Local-Pa55-not-real'
        $r.Reason | Should -Be 'joined, waiting for domain administrators: using azl-admin'
        $r.Warning | Should -Be ''
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 0 -Exactly
    }
    It 'after both events: the domain credential from the Key Vault reference; the password is masked by a fingerprint, with no plaintext kept in Shared' {
        $shared = New-AccountShared 'both'
        $r = Invoke-AccountPick $shared
        $r.UserName | Should -Be 'IIC\svc-join'
        $r.Password | Should -Be $script:Password
        $r.Reason | Should -Be 'domain-joined: using IIC\svc-join'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly -ParameterFilter { $VaultName -eq 'kv-example-mgmt-01' -and $Name -eq 'svc-join-password' -and -not $Version }
        $check = InModuleScope AzlSonar -Parameters @{ S = $shared } {
            param($S)
            [pscustomobject]@{
                Strings = @(@($S['Redact']) | Where-Object { $_ -is [string] }).Count; Fingerprints = @(@($S['Redact']) | Where-Object { Test-AzlSonarFingerprint -Value $_ }).Count
                Credential = $S['DomainCredential'] -is [pscredential]; Masked = Protect-AzlSonarText -Text 'rejected: D0main-Pa55-not-real' -Secret $S['Redact']
                Dump = (@($S['Redact']) | ConvertTo-Json -Depth 5) + ($S['LogAccount'].Keys -join ',') + ($S['LogAccount'].Values | ConvertTo-Json -Depth 6)
            }
        }
        $check.Strings | Should -Be 0
        $check.Fingerprints | Should -Be 1
        $check.Credential | Should -BeTrue
        $check.Masked | Should -Be 'rejected: ***'
        $check.Dump | Should -Not -Match 'D0main'
    }
    It 'a pinned secret version is passed to Key Vault' {
        $acc = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example-mgmt-01/svc-join-password/0123456789abcdef0123456789abcdef' } }
        $r = Invoke-AccountPick (New-AccountShared 'both') 'node-01' 0 (New-AccountConfig 'ActiveDirectory' $acc)
        $r.Kind | Should -Be 'domain'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly -ParameterFilter { $Version -eq '0123456789abcdef0123456789abcdef' }
    }
    It 'the domain credential is read once and kept, for every node' {
        $shared = New-AccountShared 'both'
        1..3 | ForEach-Object { $null = Invoke-AccountPick $shared 'node-01' }
        $null = Invoke-AccountPick $shared 'node-02'
        $null = Invoke-AccountPick $shared 'node-03'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly
    }
    It 'a password written in the file instead of a reference is refused, never used, and not echoed' {
        $bad = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'Plain-Text-Pa55' } }
        $r = Invoke-AccountPick (New-AccountShared 'both') 'node-01' 0 (New-AccountConfig 'ActiveDirectory' $bad)
        $r.UserName | Should -Be 'azl-admin'
        $r.Warning | Should -Match 'keyvault://'
        ($r.Warning + $r.Reason) | Should -Not -Match 'Plain-Text'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 0 -Exactly
    }
}

Describe 'The account-wide circuit breaker' {
    BeforeEach {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
    }
    It 'the first rejection by any node stops the domain account for EVERY node, for 15 minutes' {
        $shared = New-AccountShared 'both'
        (Invoke-AccountPick $shared 'node-01').Kind | Should -Be 'domain'
        Register-AccountResult $shared 'node-01' rejected 0 'Logon failure: unknown user name or bad password.'
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'open'
        $b.Failures | Should -Be 1
        $b.BackoffMinutes | Should -Be 15
        $b.NextProbeAt | Should -Be $script:T0.AddMinutes(15)
        foreach ($n in 'node-01', 'node-02', 'node-03') {
            $r = Invoke-AccountPick $shared $n 5
            $r.Kind | Should -Be 'local' -Because $n
            $r.UserName | Should -Be 'azl-admin'
            $r.Reason | Should -Match 'paused for every node \(next check 20:15 UTC\)'
            $r.Warning | Should -Match 'not locked out'
        }
    }
    It 'a rejected account is never presented again per poll: a hundred polls inside the back-off give the domain account to nobody' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-02' rejected 0
        $kinds = foreach ($i in 1..100) { (Invoke-AccountPick $shared ('node-0' + (1 + $i % 3)) (0.1 + $i * 0.1)).Kind }
        @($kinds | Where-Object { $_ -eq 'domain' }).Count | Should -Be 0
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly -Because 'the secret is not even read again while the breaker is open'
    }
    It 'after the back-off exactly ONE probe is allowed at a time, whichever node asks first' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' rejected 0
        $first = Invoke-AccountPick $shared 'node-02' 16
        $first.Probe | Should -BeTrue
        $first.Kind | Should -Be 'domain'
        $second = Invoke-AccountPick $shared 'node-03' 16.1
        $second.Probe | Should -BeFalse
        $second.Kind | Should -Be 'local'
        $third = Invoke-AccountPick $shared 'node-01' 16.2
        $third.Kind | Should -Be 'local'
        (Get-AccountBreaker $shared).ProbeInFlight | Should -BeTrue
    }
    It 'a successful probe closes the breaker and resets the count' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' rejected 0
        $null = Invoke-AccountPick $shared 'node-02' 16
        Register-AccountResult $shared 'node-02' ok 16.1
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'closed'
        $b.Failures | Should -Be 0
        $b.BackoffMinutes | Should -Be 0
        (Invoke-AccountPick $shared 'node-03' 17).Kind | Should -Be 'domain'
    }
    It 'a rejected probe doubles the back-off, and after maxRejections (2 by default) the breaker latches: no more probes, however long' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' rejected 0
        $probe = Invoke-AccountPick $shared 'node-02' 16
        $probe.Probe | Should -BeTrue
        Register-AccountResult $shared 'node-02' rejected 16.1
        $b = Get-AccountBreaker $shared
        $b.Failures | Should -Be 2
        $b.BackoffMinutes | Should -Be 30
        $b.State | Should -Be 'latched'
        foreach ($m in 60, 600, 6000) {
            $r = Invoke-AccountPick $shared 'node-01' $m
            $r.Probe | Should -BeFalse
            $r.Kind | Should -Be 'local'
            $r.Reason | Should -Match 'stays paused until its password changes or Sonar restarts'
        }
    }
    It 'with a higher maxRejections the back-off doubles 15, 30, 60, 120 and stays at 120' {
        $acc = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example-mgmt-01/svc-join-password'; maxRejections = 5 } }
        $cfg = New-AccountConfig 'ActiveDirectory' $acc
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01' 0 $cfg
        $seen = @()
        $clock = 0
        foreach ($i in 1..5) {
            Register-AccountResult $shared 'node-01' rejected $clock '' $cfg
            $seen += (Get-AccountBreaker $shared).BackoffMinutes
            $clock += 130
            $p = Invoke-AccountPick $shared 'node-02' $clock $cfg
            if ($i -lt 5) { $p.Probe | Should -BeTrue }
        }
        $seen | Should -Be @(15, 30, 60, 120, 120)
        (Get-AccountBreaker $shared).State | Should -Be 'latched'
    }
    It 'a locked-out account latches the breaker at once (checked every 120 minutes for a new secret version), with a warning' {
        $shared = New-AccountShared 'both'
        $first = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' lockedOut 0 'referenced account is currently locked out' (New-AccountConfig) $first.Ticket
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'latched'
        $b.BackoffMinutes | Should -Be 120
        $b.LastClass | Should -Be 'lockedOut'
        $r = Invoke-AccountPick $shared 'node-02' 10
        $r.Kind | Should -Be 'local'
        $r.Reason | Should -Match 'is locked out; the domain account is paused'
        $r.Warning | Should -Match 'locked out in Active Directory'
        (Invoke-AccountPick $shared 'node-02' 119).Kind | Should -Be 'local'
        $later = Invoke-AccountPick $shared 'node-02' 121
        $later.Kind | Should -Be 'local' -Because 'the same secret version: still locked out as far as Sonar knows'
        $later.Probe | Should -BeFalse
    }
    It 'authorization (logged on, not an administrator) does not trip the breaker: that node uses the local account for 5 minutes, the others keep the domain account' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' authorization 0 'Access is denied.'
        (Get-AccountBreaker $shared).State | Should -Be 'closed'
        (Get-AccountBreaker $shared).Failures | Should -Be 0
        $a = Invoke-AccountPick $shared 'node-01' 2
        $a.Kind | Should -Be 'local'
        $a.Reason | Should -Match 'is not an administrator of the node'
        (Invoke-AccountPick $shared 'node-02' 2).Kind | Should -Be 'domain'
        (Invoke-AccountPick $shared 'node-01' 6).Kind | Should -Be 'domain' -Because 'tried again after 5 minutes'
    }
    It 'unreachable and other errors change nothing, and a probe that never reached its node gives the slot back' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' unreachable 0 'timed out'
        Register-AccountResult $shared 'node-01' other 0 'what?'
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'closed'; $b.Failures | Should -Be 0
        Register-AccountResult $shared 'node-01' rejected 1
        $probe = Invoke-AccountPick $shared 'node-02' 17
        $probe.Probe | Should -BeTrue
        Register-AccountResult $shared 'node-02' unreachable 17.1 'timed out'
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'open'
        $b.Failures | Should -Be 1 -Because 'an unreachable node says nothing about the account'
        $b.ProbeInFlight | Should -BeFalse
        (Invoke-AccountPick $shared 'node-03' 17.2).Probe | Should -BeFalse -Because 'the next probe is pushed 5 minutes out after an inconclusive one'
        (Invoke-AccountPick $shared 'node-03' 22.5).Probe | Should -BeTrue
    }
    It 'a changed secret version resets the breaker: the probe becomes an ordinary connection' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' rejected 0
        Register-AccountResult $shared 'node-01' rejected 1
        (Get-AccountBreaker $shared).State | Should -Be 'latched'
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'New-Pa55-not-real' -AsPlainText -Force); Version = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2' } }
        # a latched breaker is left only by a changed password; its version is looked at once per back-off (Key Vault read, account not tried)
        (Invoke-AccountPick $shared 'node-02' 20).Kind | Should -Be 'local' -Because 'not time to look yet'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly -Because 'only the original read'
        $r = Invoke-AccountPick $shared 'node-02' 32
        $r.Kind | Should -Be 'domain'
        $r.Probe | Should -BeTrue -Because 'after a version change there is ONE probe'
        $r.Password | Should -Be 'New-Pa55-not-real'
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'closed'
        $b.Failures | Should -Be 0
        $b.SecretVersion | Should -Be 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2'
        $masked = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) Protect-AzlSonarText -Text 'old D0main-Pa55-not-real new New-Pa55-not-real' -Secret $S['Redact'] }
        $masked | Should -Be 'old *** new ***' -Because 'the new password is masked too'
    }
    It 'a latched breaker whose secret has the same version stays latched, and is looked at again after the back-off, not on every poll' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' rejected 0
        Register-AccountResult $shared 'node-01' rejected 1
        (Invoke-AccountPick $shared 'node-02' 32).Kind | Should -Be 'local'
        (Invoke-AccountPick $shared 'node-03' 33).Kind | Should -Be 'local'
        (Invoke-AccountPick $shared 'node-01' 40).Kind | Should -Be 'local'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 2 -Exactly -Because 'the first read was the original one; one version check since'
        (Get-AccountBreaker $shared).State | Should -Be 'latched'
        (Get-AccountBreaker $shared).Failures | Should -Be 2
    }
    It 'the breaker keeps no mutable nested tables: its records are replaced, and a copy held by a reader does not change' {
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        $held = Get-AccountBreaker $shared
        Register-AccountResult $shared 'node-01' rejected 0
        $held.State | Should -Be 'closed'
        (Get-AccountBreaker $shared).State | Should -Be 'open'
        $held -is [hashtable] | Should -BeFalse
        $node = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) $S['LogAccount']['node-01'] }
        $node -is [hashtable] | Should -BeFalse
    }
}

Describe 'A credential that cannot be had is not a rejection' {
    It 'a Key Vault outage: the local account, nobody marked rejected, asked again after 1, 2 and then 5 minutes' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { throw 'Forbidden: the caller is not authorized to get secrets.' }
        $shared = New-AccountShared 'both'
        $r = Invoke-AccountPick $shared 'node-01' 0
        $r.Kind | Should -Be 'local'
        $r.UserName | Should -Be 'azl-admin'
        $r.Reason | Should -Match 'the domain account is not available \(next check 20:01 UTC\)'
        $r.Warning | Should -Match 'kv-example-mgmt-01'
        $r.Warning | Should -Match 'svc-join-password'
        (Get-AccountBreaker $shared).State | Should -Be 'closed'
        (Get-AccountBreaker $shared).Failures | Should -Be 0
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly
        $null = Invoke-AccountPick $shared 'node-02' 0.5
        $null = Invoke-AccountPick $shared 'node-03' 0.9
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly -Because 'not asked again inside the minute'
        $null = Invoke-AccountPick $shared 'node-01' 1.1
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 2 -Exactly
        # attempts at 0 (wait 1), 1.1 (wait 2), 3.2 (wait 5), 8.3 (wait 5), 14 (wait 5)
        foreach ($t in 3.2, 8.3, 14) { $null = Invoke-AccountPick $shared 'node-01' $t }
        $u = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) $S['LogAccount']['*unavailable'] }
        $u.Attempt | Should -Be 5
        ($u.Until - $script:T0.AddMinutes(14)).TotalMinutes | Should -Be 5 -Because '1, 2, 5 and then 5 again'
    }
    It 'the first three waits are 1, 2 and 5 minutes' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { throw 'Forbidden' }
        $shared = New-AccountShared 'both'
        $waits = foreach ($t in 0, 1.5, 4) {
            $null = Invoke-AccountPick $shared 'node-01' $t
            $u = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) $S['LogAccount']['*unavailable'].Until }
            ($u - $script:T0.AddMinutes($t)).TotalMinutes
        }
        $waits | Should -Be @(1, 2, 5)
    }
    It 'a missing Az.KeyVault module and an expired Azure sign-in are the same class: unavailable, with the reason, and the node is not rejected' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { throw 'Run Connect-AzAccount to login.' }
        $shared = New-AccountShared 'both'
        $r = Invoke-AccountPick $shared 'node-01'
        $r.Warning | Should -Match 'Connect-AzAccount'
        (Get-AccountBreaker $shared).State | Should -Be 'closed'
        Mock Get-Command -ModuleName AzlSonar { $null } -ParameterFilter { $Name -eq 'Get-AzKeyVaultSecret' }
        $shared2 = New-AccountShared 'both'
        $r2 = Invoke-AccountPick $shared2 'node-01'
        $r2.Warning | Should -Match 'Az.KeyVault is not installed'
        $r2.Kind | Should -Be 'local'
        (Get-AccountBreaker $shared2).Failures | Should -Be 0
    }
    It 'when the Key Vault comes back the domain account is used and the unavailable record is cleared' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { throw 'Forbidden' }
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01' 0
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
        (Invoke-AccountPick $shared 'node-01' 2).Kind | Should -Be 'domain'
        InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) $S['LogAccount']['*unavailable'] } | Should -BeNullOrEmpty
    }
}

Describe 'Several nodes at once: one credential, one probe' {
    It 'eight threads asking together after the back-off give exactly one the probe' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' rejected 0
        $manifest = (Get-Module AzlSonar).Path
        $config = New-AccountConfig
        $now = $script:T0.AddMinutes(20)
        $probes = 1..8 | ForEach-Object -Parallel {
            Import-Module $using:manifest -Force
            function global:Get-AzKeyVaultSecret { param([string]$VaultName, [string]$Name, [string]$Version) [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
            $module = Get-Module AzlSonar
            & $module { param($S, $C, $N, $T) $local = [pscredential]::new('azl-admin', (ConvertTo-SecureString 'Local-Pa55-not-real' -AsPlainText -Force)); (Select-AzlSonarNodeAccount -Shared $S -Config $C -Node $N -Local $local -Now $T).Probe } $using:shared $using:config ('node-0' + (1 + ($_ % 3))) $using:now
        } -ThrottleLimit 8
        @($probes | Where-Object { $_ -eq $true }).Count | Should -Be 1
    }
}

Describe 'The password is never in the state, Details, the log pane, the page or an error message' {
    It 'with a registered password, every served or stored text is clean' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-02' rejected 0 'Logon failure for IIC\svc-join with D0main-Pa55-not-real: the user name or password is incorrect.'
        $out = InModuleScope AzlSonar -Parameters @{ S = $shared; C = (New-AccountConfig) } {
            param($S, $C)
            $state = Get-AzlSonarOsConfigurationState -Store $S['OsConfigEvents'] -Config $C -LogAccount $S['LogAccount'] -LocalUserName 'azl-admin'
            $line = ConvertFrom-AzlSonarOsConfigEvent -Line '{"timestamp":"2026-11-07T19:06:00Z","node":"node-01","state":"DomainJoinFailed","step":"DomainJoin","level":"Error","evidence":"join failed for IIC\\svc-join with D0main-Pa55-not-real"}'
            Add-AzlSonarLogLine -Shared $S -Line @($line)
            $detail = Get-AzlSonarLogAccountDetail -Shared $S -AccountName 'IIC\svc-join' -MaxRejections 2
            $classified = Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'Logon failure with D0main-Pa55-not-real'
            $private:err = try { Resolve-AzlSonarDomainCredential -Config (New-AccountConfigLocal) } catch { $_.Exception.Message }
            [pscustomobject]@{
                State = ConvertTo-AzlSonarJson ([ordered]@{ osConfiguration = $state }); Detail = ConvertTo-AzlSonarJson $detail
                Lines = ConvertTo-AzlSonarJson @((Get-AzlSonarLogWindow -Shared $S).lines); Table = ($S['LogAccount'].Values | ConvertTo-Json -Depth 8)
                Classified = ($classified | ConvertTo-Json -Depth 3)
            }
        }
        foreach ($name in 'State', 'Detail', 'Lines', 'Table', 'Classified') {
            $out.$name | Should -Not -Match 'D0main-Pa55-not-real' -Because $name
            $out.$name | Should -Not -Match 'keyvault://|kv-example-mgmt-01|svc-join-password' -Because $name
        }
        $out.Lines | Should -Match '\*\*\*'
        $out.State | Should -Match 'IIC\\\\svc-join'
        $out.Detail | Should -Match '"state":"open"'
    }
    It 'the rejection message kept for a node is masked before it is stored' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
        $shared = New-AccountShared 'both'
        $null = Invoke-AccountPick $shared 'node-01'
        Register-AccountResult $shared 'node-01' authorization 0 'Access is denied for D0main-Pa55-not-real.'
        $msg = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) $S['LogAccount']['node-01'].Message }
        $msg | Should -Be 'Access is denied for ***.'
    }
    It 'an error from Resolve-AzlSonarDomainCredential names the vault and the secret, never a value' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { throw 'The vault says no.' }
        $msg = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) try { Resolve-AzlSonarDomainCredential -Config $C } catch { $_.Exception.Message } }
        $msg | Should -Match "Key Vault 'kv-example-mgmt-01' \(secret 'svc-join-password'\)"
        $msg | Should -Not -Match 'Pa55'
    }
}

Describe 'Details: the breaker of the domain account' {
    It 'shows the account name, the state and the next check, and nothing secret' {
        $shared = New-AccountShared 'both'
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
        $null = Confirm-AccountDomain $shared 'node-01'
        $closed = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) Get-AzlSonarLogAccountDetail -Shared $S -AccountName 'IIC\svc-join' -MaxRejections 2 -Now ([datetime]'2026-11-07T20:00:00Z') }
        $closed.account | Should -Be 'IIC\svc-join'
        $closed.state | Should -Be 'closed'
        $closed.credential | Should -Be 'ready'
        $closed.nextProbeAt | Should -BeNullOrEmpty
        Register-AccountResult $shared 'node-01' rejected 0
        $open = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) Get-AzlSonarLogAccountDetail -Shared $S -AccountName 'IIC\svc-join' -MaxRejections 2 }
        $open.state | Should -Be 'open'
        $open.failures | Should -Be 1
        $open.maxRejections | Should -Be 2
        $open.backoffMinutes | Should -Be 15
        $open.nextProbeAt | Should -Be '2026-11-07T20:15:00Z'
        $open.lastClass | Should -Be 'rejected'
    }
    It 'Get-AzlSonarDetail carries it, from the facts of the config' {
        $cfgObj = New-SonarConfigObject
        $cfgObj | Add-Member -NotePropertyName identityModel -NotePropertyValue 'ActiveDirectory' -Force
        $cfgObj | Add-Member -NotePropertyName logAccounts -NotePropertyValue ([pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example/svc-join-password'; maxRejections = 3 } }) -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $cfgObj) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $detail = InModuleScope AzlSonar -Parameters @{ C = $cfg } {
            param($C)
            $shared = Initialize-AzlSonarSharedState
            Register-AzlSonarAccountResult -Shared $shared -Config $C -Node 'node01' -Class rejected
            Get-AzlSonarDetail -Server @{ Mode = 'live'; Shared = $shared; Facts = (New-AzlSonarDetailFact -Config $C); Version = '1.0.0'; ClusterName = 'clus01' }
        }
        $detail.logAccount.account | Should -Be 'IIC\svc-join'
        $detail.logAccount.state | Should -Be 'open'
        $detail.logAccount.maxRejections | Should -Be 3
        ($detail | ConvertTo-Json -Depth 10) | Should -Not -Match 'keyvault://|svc-join-password'
    }
}

Describe 'DomainJoin in the OS configuration steps' {
    BeforeAll {
        $script:BuildJoin = {
            param($Lines, $Identity = 'ActiveDirectory')
            InModuleScope AzlSonar -Parameters @{ L = @($Lines); C = (New-AccountConfig $Identity); } {
                param($L, $C)
                $store = [hashtable]::Synchronized(@{})
                foreach ($x in $L) { Add-AzlSonarOsConfigEvent -Store $store -Line $x }
                Get-AzlSonarOsConfigurationState -Store $store -Config $C -LocalUserName 'azl-admin'
            }
        }
        $script:JoinStep = { param($State) @($State.nodes[0].tree | Where-Object { $_.osc.step -eq 'DomainJoin' })[0] }
        $script:Start = (New-AccountLine '2026-11-07T19:00:00Z' 'node-01' 'NodeStarted' 'x' @{ step = '' })
    }
    It 'sits after the computer name and before the unused adapters, as the design orders it' {
        $s = & $script:BuildJoin @($script:Start)
        @($s.nodes[0].tree).Count | Should -Be 14
        $steps = @($s.nodes[0].tree).osc.step
        $steps.IndexOf('DomainJoin') | Should -Be ($steps.IndexOf('Hostname') + 1)
    }
    It 'planned, applying, joined (waiting for the administrators), configured, and failed with the AD error text' {
        $plan = New-AccountLine '2026-11-07T19:01:00Z' 'node-01' 'DomainJoinPlanned' 'Change: join iic.example.test (OU=Servers)' @{ action = 'Change'; current = 'workgroup WORKGROUP'; desired = 'iic.example.test' }
        $s = & $script:BuildJoin @($script:Start, $plan)
        (& $script:JoinStep $s).osc.stage | Should -Be 'planned'
        (& $script:JoinStep $s).osc.current | Should -Be 'workgroup WORKGROUP'
        $applying = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoinApplying' 'Add-Computer started'))
        (& $script:JoinStep $applying).osc.stage | Should -Be 'changing'
        (& $script:JoinStep $applying).status | Should -Be 'running'
        $joined = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:04:00Z' 'node-01' 'DomainJoined' 'joined iic.example.test'))
        (& $script:JoinStep $joined).osc.stage | Should -Be 'applied'
        $joined.nodes[0].domainJoined | Should -BeTrue
        $joined.nodes[0].domainAdminsConfigured | Should -BeFalse
        $joined.nodes[0].logAccount.reason | Should -Be 'joined, waiting for domain administrators: using azl-admin'
        $admins = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:04:00Z' 'node-01' 'DomainJoined' 'joined'), (New-AccountLine '2026-11-07T19:05:00Z' 'node-01' 'DomainAdminsConfigured' 'IIC\svc-join was added to the local Administrators'))
        $admins.nodes[0].domainAdminsConfigured | Should -BeTrue
        $admins.nodes[0].logAccount.kind | Should -Be 'domain'
        (& $script:JoinStep $admins).description | Should -Match 'was added to the local Administrators'
        $failed = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:03:00Z' 'node-01' 'DomainJoinFailed' 'Add-Computer: The specified domain either does not exist or could not be contacted.'))
        (& $script:JoinStep $failed).osc.stage | Should -Be 'failed'
        @((& $script:JoinStep $failed).errors)[0] | Should -Match 'specified domain either does not exist'
        $failed.nodes[0].domainJoined | Should -BeFalse
    }
    It 'a local identity design: not applicable, with the reason' {
        $s = & $script:BuildJoin @($script:Start) 'LocalIdentity'
        (& $script:JoinStep $s).osc.stage | Should -Be 'skipped'
        (& $script:JoinStep $s).description | Should -Match 'identity design is local'
    }
}

Describe 'The account per node in the state' {
    It 'every machine says which account reads its logs and why; the breaker shows on every node, a node-only authorization on that node only' {
        $s = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } {
            param($C)
            $store = [hashtable]::Synchronized(@{})
            foreach ($n in 'node-01', 'node-02', 'node-03') {
                Add-AzlSonarOsConfigEvent -Store $store -Line ('{"timestamp":"2026-11-07T19:05:00Z","node":"' + $n + '","step":"DomainJoin","state":"DomainJoined"}')
            }
            foreach ($n in 'node-02', 'node-03') { Add-AzlSonarOsConfigEvent -Store $store -Line ('{"timestamp":"2026-11-07T19:06:00Z","node":"' + $n + '","step":"DomainJoin","state":"DomainAdminsConfigured"}') }
            $table = [hashtable]::Synchronized(@{})
            $table['node-03'] = [pscustomobject]@{ Node = 'node-03'; Kind = 'authorization'; Until = [datetime]::UtcNow.AddMinutes(5); Message = ''; Rejected = $false }
            Get-AzlSonarOsConfigurationState -Store $store -Config $C -LogAccount $table -LocalUserName 'azl-admin'
        }
        $s.nodes[0].logAccount.reason | Should -Be 'joined, waiting for domain administrators: using azl-admin'
        $s.nodes[1].logAccount.reason | Should -Be 'domain-joined: using IIC\svc-join'
        $s.nodes[2].logAccount.reason | Should -Match 'is not an administrator of the node'
        ($s.warnings -join ' ') | Should -Match 'logged on to node-03'
    }
    It 'an open breaker is a warning on every domain-ready machine' {
        $s = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } {
            param($C)
            $store = [hashtable]::Synchronized(@{})
            foreach ($n in 'node-01', 'node-02') {
                Add-AzlSonarOsConfigEvent -Store $store -Line ('{"timestamp":"2026-11-07T19:05:00Z","node":"' + $n + '","step":"DomainJoin","state":"DomainJoined"}')
                Add-AzlSonarOsConfigEvent -Store $store -Line ('{"timestamp":"2026-11-07T19:06:00Z","node":"' + $n + '","step":"DomainJoin","state":"DomainAdminsConfigured"}')
            }
            $shared = Initialize-AzlSonarSharedState
            Register-AzlSonarAccountResult -Shared $shared -Config $C -Node 'node-01' -Class rejected
            Get-AzlSonarOsConfigurationState -Store $store -Config $C -LogAccount $shared['LogAccount'] -LocalUserName 'azl-admin'
        }
        $s.nodes[0].logAccount.kind | Should -Be 'local'
        $s.nodes[1].logAccount.kind | Should -Be 'local'
        $s.nodes[1].logAccount.reason | Should -Match 'paused for every node'
        ($s.warnings -join ' ') | Should -Match 'IIC\\svc-join'
    }
}

Describe 'logAccounts in the config and the master file' {
    It 'is read from a config file, checked, never takes a password, and validates the reference like Azure does' {
        $good = New-SonarConfigObject
        $good | Add-Member -NotePropertyName logAccounts -NotePropertyValue ([pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example/svc-join-password/0123456789abcdef0123456789abcdef'; maxRejections = 3 } }) -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $good) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $cfg.logAccounts.domain.username | Should -Be 'svc-join'
        $cfg.logAccounts.domain.passwordRef | Should -Be 'keyvault://kv-example/svc-join-password/0123456789abcdef0123456789abcdef'
        $cfg.logAccounts.domain.maxRejections | Should -Be 3
        $plain = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson (New-SonarConfigObject)) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $plain.logAccounts.domain.username | Should -Be ''
        $plain.logAccounts.domain.maxRejections | Should -Be 2
        $cases = @(
            @{ Domain = @{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'Plain-Pa55' }; Match = 'is not a keyvault://' },
            @{ Domain = @{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://ab/secret' }; Match = 'vault that Azure would not accept' },
            @{ Domain = @{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example/secret/xyz' }; Match = '32 hexadecimal' },
            @{ Domain = @{ netbios = 'IIC'; username = 'svc-join'; password = 'x' }; Match = 'refused' },
            @{ Domain = @{ netbios = ' '; username = 'svc-join' }; Match = 'must be text' },
            @{ Domain = @{ netbios = 'IIC'; username = 'svc-join'; maxRejections = 9 }; Match = 'maxRejections' })
        foreach ($case in $cases) {
            $bad = New-SonarConfigObject
            $bad | Add-Member -NotePropertyName logAccounts -NotePropertyValue ([pscustomobject]@{ domain = [pscustomobject]$case.Domain }) -Force
            $problems = InModuleScope AzlSonar -Parameters @{ C = $bad } { param($C) Test-AzlSonarConfig -Config $C }
            ($problems -match 'logAccounts') | Should -Not -BeNullOrEmpty
            ($problems -join ' ') | Should -Match $case.Match
            ($problems -join ' ') | Should -Not -Match 'Plain-Pa55'
        }
    }
    It 'the master file import uses identity.active_directory.domain_join_account: names and a keyvault reference (pinned versions kept)' {
        $yaml = (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') -Raw)
        $yaml = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    domain_join_account:`n      username: `"svc-join`"`n      password: `"keyvault://kv-example-mgmt-01/svc-join-password/0123456789abcdef0123456789abcdef`"`n")
        $file = Join-Path $TestDrive 'ad.yml'
        Set-Content -LiteralPath $file -Value $yaml
        $config = Read-AzlSonarConfig -InfrastructureFile $file 3>$null
        $config.logAccounts.local.username | Should -Be 'azl-admin'
        $config.logAccounts.domain.netbios | Should -Be 'IIC'
        $config.logAccounts.domain.username | Should -Be 'svc-join'
        $config.logAccounts.domain.passwordRef | Should -Be 'keyvault://kv-example-mgmt-01/svc-join-password/0123456789abcdef0123456789abcdef'
    }
    It 'never uses the LCM user: not as the domain account, not as a fallback, even when the file names it' {
        $yaml = (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') -Raw)
        $withLcm = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    lcm_user:`n      username: `"svc-lcm`"`n      password: `"keyvault://kv-example-mgmt-01/lcm-password`"`n")
        $file = Join-Path $TestDrive 'ad-lcm-only.yml'
        Set-Content -LiteralPath $file -Value $withLcm
        $config = Read-AzlSonarConfig -InfrastructureFile $file 3>$null
        $config.logAccounts.domain.username | Should -Be '' -Because 'no domain_join_account: no domain account, the local account stays'
        $config.logAccounts.domain.passwordRef | Should -Be ''
        ($config | ConvertTo-Json -Depth 8) | Should -Not -Match 'svc-lcm|lcm-password'
        $both = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    lcm_user:`n      username: `"svc-lcm`"`n      password: `"keyvault://kv-example-mgmt-01/lcm-password`"`n    domain_join_account:`n      username: `"svc-join`"`n      password: `"keyvault://kv-example-mgmt-01/svc-join-password`"`n")
        $file2 = Join-Path $TestDrive 'ad-both.yml'
        Set-Content -LiteralPath $file2 -Value $both
        $c2 = Read-AzlSonarConfig -InfrastructureFile $file2 3>$null
        $c2.logAccounts.domain.username | Should -Be 'svc-join'
        ($c2 | ConvertTo-Json -Depth 8) | Should -Not -Match 'svc-lcm|lcm-password'
        $src = (Get-ChildItem (Join-Path $script:SonarRepoRoot 'src/AzlSonar/Private') -Filter '*.ps1' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        ([regex]::Matches($src, "Get-AzlSonarInfrastructureValue[^\r\n]*lcm_user")).Count | Should -Be 0 -Because 'no code reads the LCM user'
    }
    It 'a master file with no domain_join_account still imports (read defensively): the local account only' {
        $config = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $config.logAccounts.local.username | Should -Be 'azl-admin'
        $config.logAccounts.domain.username | Should -Be ''
    }
    It 'a password that is not a valid keyvault reference stops the import with a clear message that does not echo it' {
        $yaml = (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') -Raw)
        foreach ($case in @(@{ Value = 'Plain-Text-Pa55'; Match = 'keyvault://<vault>/<secret>' }, @{ Value = 'keyvault://ab/secret'; Match = 'vault that Azure would not accept' }, @{ Value = 'keyvault://kv-example/secret/nothex'; Match = '32 hexadecimal' })) {
            $text = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    domain_join_account:`n      username: `"svc-join`"`n      password: `"$($case.Value)`"`n")
            $file = Join-Path $TestDrive ('ad-bad-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.yml')
            Set-Content -LiteralPath $file -Value $text
            $err = try { Read-AzlSonarConfig -InfrastructureFile $file 3>$null; '' } catch { $_.Exception.Message }
            $err | Should -Match 'identity\.active_directory\.domain_join_account\.password'
            $err | Should -Match $case.Match
            $err | Should -Not -Match 'Plain-Text-Pa55'
        }
    }
    It 'is documented in docs/config.md and docs/log-access.md, with the breaker and the error classes, and says the LCM user is not used' {
        $config = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/config.md') -Raw
        $log = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/log-access.md') -Raw
        $config | Should -Match 'identity\.active_directory\.domain_join_account'
        $config | Should -Match 'logAccounts'
        $config | Should -Match 'maxRejections'
        $config | Should -Match 'lcm_user'
        $log | Should -Match 'DomainJoined'
        $log | Should -Match 'DomainAdminsConfigured'
        $log | Should -Match 'domain_join_account'
        $log | Should -Match 'circuit breaker'
        $log | Should -Match 'credentialUnavailable|not available'
        $log | Should -Match 'lcm_user'
    }
}


# ---------------------------------------------------------------------------------------------------------------------
# Second review (F1 to F11): each case below reproduces one finding.
# ---------------------------------------------------------------------------------------------------------------------

Describe 'F1/F9: classification by code, stage and phrase' {
    It 'F1: access denied while the session is OPENED is a rejection (a wrong password over Negotiate looks exactly like this)' {
        InModuleScope AzlSonar {
            foreach ($m in 'Connecting to remote server n1 failed with the following error message : Access is denied.', 'WinRM returned 0x80070005', 'AccessDenied,PSSessionOpenFailed') {
                (Get-AzlSonarConnectionFailureClass -Transport winrm -Message $m).Class | Should -Be 'rejected' -Because $m
            }
            $inner = [System.Exception]::new('Zugriff verweigert')
            $record = [System.Management.Automation.ErrorRecord]::new($inner, 'AccessDenied,PSSessionOpenFailed', [System.Management.Automation.ErrorCategory]::OpenError, $null)
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception $record).Class | Should -Be 'rejected'
        }
    }
    It 'F1: access denied AFTER a session opened (a later step) is authorization' {
        InModuleScope AzlSonar {
            $c = Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'Access is denied.' -Stage use
            $c.Class | Should -Be 'authorization'
            $c.Reason | Should -Be 'not an administrator of the node'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([System.UnauthorizedAccessException]::new('x')) -Stage use).Class | Should -Be 'authorization'
        }
    }
    It 'F1: numeric codes decide, whatever language the text is in (5, 1326, 1909, 1385)' {
        InModuleScope AzlSonar {
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'Zugriff verweigert'; ErrorCode = 5; InnerException = $null })).Class | Should -Be 'rejected'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'Anmeldefehler'; ErrorCode = 1326; InnerException = $null })).Class | Should -Be 'rejected'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'Konto gesperrt'; ErrorCode = 1909; InnerException = $null })).Class | Should -Be 'lockedOut'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'Anmeldetyp'; ErrorCode = 1385; InnerException = $null })).Class | Should -Be 'authorization'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'Zugriff verweigert'; HResult = [int]0x80070005; InnerException = $null }) -Stage use).Class | Should -Be 'authorization'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'gesperrt'; HResult = [int]0x80070775; InnerException = $null })).Class | Should -Be 'lockedOut'
        }
    }
    It 'F9: "logon failure" alone is not a rejection: logon type not granted (1385, 0x80070569) is authorization, the right password was typed' {
        InModuleScope AzlSonar {
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'Logon failure: the user has not been granted the requested logon type at this machine.').Class | Should -Be 'authorization'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The WinRM client got 0x80070569.').Class | Should -Be 'authorization'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'Logon failure: the target account name is incorrect.').Class | Should -Be 'other'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'Logon failure: unknown user name or bad password.').Class | Should -Be 'rejected'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The user name or password is incorrect.').Class | Should -Be 'rejected'
        }
    }
}

Describe 'F2: each transport leg is classified on its own, the domain password is not tried on a second transport' {
    It 'the worst leg wins: an SSH "Permission denied (" behind a WinRM timeout is a rejection' {
        InModuleScope AzlSonar {
            (Get-AzlSonarWorstFailureClass -Reason 'WinRM: The operation has timed out. | SSH: Permission denied (publickey,password).').Class | Should -Be 'rejected'
            (Get-AzlSonarWorstFailureClass -Reason 'WinRM: Access is denied. | SSH: Connection timed out.').Class | Should -Be 'rejected'
            (Get-AzlSonarWorstFailureClass -Reason 'WinRM: timed out | SSH: timed out').Class | Should -Be 'unreachable'
            (Get-AzlSonarWorstFailureClass -Reason 'WinRM: bad password | SSH: referenced account is currently locked out').Class | Should -Be 'lockedOut'
            (Get-AzlSonarWorstFailureClass -Reason 'SSH: Permission denied (publickey).').Class | Should -Be 'rejected'
            (Get-AzlSonarWorstFailureClass -Reason '').Class | Should -Be 'other'
        }
    }
    It 'with the domain account and transport auto, a failed WinRM leg does not send the domain password over SSH' {
        Mock New-PSSession -ModuleName AzlSonar { throw 'The WinRM client timed out.' }
        $r = InModuleScope AzlSonar {
            $cred = [pscredential]::new('IIC\svc-join', (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force))
            Open-AzlSonarNodeConnection -Address '192.0.2.11' -Credential $cred -Transport auto -DomainAccount
        }
        $r.Session | Should -BeNullOrEmpty
        $r.Ssh | Should -BeNullOrEmpty
        $r.Reason | Should -Match 'WinRM: The WinRM client timed out'
        $r.Reason | Should -Match 'SSH: not tried with the domain account'
        $r.Reason | Should -Not -Match 'Posh-SSH'
        Should -Invoke New-PSSession -ModuleName AzlSonar -Times 1 -Exactly
    }
}

Describe 'F10: strict anchors, no trailing newline or control characters' {
    It 'a reference with a trailing line break, or a control character, is not a reference' {
        InModuleScope AzlSonar {
            foreach ($bad in "keyvault://kv-example/secret`n", "keyvault://kv-example`n/secret", "keyvault://kv-example/secret/0123456789abcdef0123456789abcdef`n", "keyvault://kv-example/sec`tret", "keyvault://kv-example/secret`r", "keyvault://kv-example/secret`0") {
                (Get-AzlSonarKeyVaultReferenceProblem -Reference $bad) | Should -Not -BeNullOrEmpty -Because ($bad -replace "[`r`n`t`0]", '?')
                ConvertFrom-AzlSonarKeyVaultReference -Reference $bad | Should -BeNullOrEmpty
            }
            (Get-AzlSonarKeyVaultReferenceProblem -Reference 'keyvault://kv-example/secret') | Should -Be ''
        }
    }
    It 'maxRejections with a trailing line break is refused by the config check' {
        $bad = New-SonarConfigObject
        $bad | Add-Member -NotePropertyName logAccounts -NotePropertyValue ([pscustomobject]@{ domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; maxRejections = "3`n" } }) -Force
        $problems = InModuleScope AzlSonar -Parameters @{ C = $bad } { param($C) Test-AzlSonarConfig -Config $C }
        ($problems -join ' ') | Should -Match 'maxRejections'
    }
}

Describe 'F4: the recording masks a password that is registered after the recording started' {
    It 'a fingerprint added to Shared.Redact later is applied on the next step' {
        $path = Join-Path $TestDrive 'late-secret.jsonl'
        $shared = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $rec = InModuleScope AzlSonar -Parameters @{ P = $path } {
            param($P)
            $session = New-AzlSonarSessionJson -ConfigJson '{"cluster":"clus01"}' -GuidanceJson '{"phases":{}}' -ServerId 'srv1' -Version '0.1.0' -Cluster 'clus01'
            Open-AzlSonarRecorder -Path $P -SessionJson $session -Secret @()
        }
        InModuleScope AzlSonar -Parameters @{ S = $shared; R = $rec } {
            param($S, $R)
            Add-AzlSonarRedaction -Shared $S -Secret (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force)
            Publish-AzlSonarState -Shared $S -State ([ordered]@{ cluster = 'clus01'; phase = 'validation'; activePhase = 'validation'; polledAt = '2026-10-11T10:00:00Z'; note = 'rejected D0main-Pa55-not-real on node-01' })
            Invoke-AzlSonarRecorderStep -Recorder $R -Shared $S -Now ([datetime]'2026-10-11T10:00:01Z')
            Close-AzlSonarRecorder -Recorder $R -Now ([datetime]'2026-10-11T10:00:02Z')
        }
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Not -Match 'D0main-Pa55-not-real'
        $text | Should -Match 'rejected \*\*\* on node-01'
    }
}

Describe 'F3/F5/F6/F7/F8/F11: tickets, probe lease, version change and lockout latch' {
    BeforeEach {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
    }
    It 'F3: the first use of the domain account is ONE probe; nobody else gets it until that probe reports ok' {
        $shared = New-AccountShared 'both'
        $first = Invoke-AccountPick $shared 'node-01'
        $first.Kind | Should -Be 'domain'
        $first.Probe | Should -BeTrue
        $second = Invoke-AccountPick $shared 'node-02' 0.1
        $second.Kind | Should -Be 'local'
        $second.Reason | Should -Match 'another node is checking IIC.svc-join first'
        $second.Warning | Should -Be ''
        Register-AccountResult $shared 'node-01' ok 0.2 '' (New-AccountConfig) $first.Ticket
        (Get-AccountBreaker $shared).Verified | Should -BeTrue
        $third = Invoke-AccountPick $shared 'node-02' 0.3
        $third.Kind | Should -Be 'domain'
        $third.Probe | Should -BeFalse
    }
    It 'F3: eight nodes asking at once on the first use: exactly one gets the domain credential and Key Vault is read once' {
        $shared = New-AccountShared 'both'
        $manifest = (Get-Module AzlSonar).Path
        $counter = [hashtable]::Synchronized(@{ Reads = 0 })
        $config = New-AccountConfig
        $results = 1..8 | ForEach-Object -Parallel {
            Import-Module $using:manifest -Force
            function global:Get-AzKeyVaultSecret { param([string]$VaultName, [string]$Name, [string]$Version) $c = $using:counter; [System.Threading.Monitor]::Enter($c); try { $c['Reads'] = [int]$c['Reads'] + 1 } finally { [System.Threading.Monitor]::Exit($c) }; Start-Sleep -Milliseconds 200; [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
            $module = Get-Module AzlSonar
            & $module { param($S, $C, $N) $local = [pscredential]::new('azl-admin', (ConvertTo-SecureString 'Local-Pa55-not-real' -AsPlainText -Force)); $p = Select-AzlSonarNodeAccount -Shared $S -Config $C -Node $N -Local $local; [pscustomobject]@{ Kind = $p.Account.kind; Probe = [bool]$p.Probe } } $using:shared $using:config ('node-0' + (1 + ($_ % 3)))
        } -ThrottleLimit 8
        @($results | Where-Object { $_.Kind -eq 'domain' }).Count | Should -Be 1
        @($results | Where-Object { $_.Probe }).Count | Should -Be 1
        $counter['Reads'] | Should -Be 1
    }
    It 'F3: a cached credential is never handed out once the breaker is not closed' {
        $shared = New-AccountShared 'both'
        $v = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-02' 1
        $a.Kind | Should -Be 'domain'
        Register-AccountResult $shared 'node-02' rejected 2 '' (New-AccountConfig) $a.Ticket
        (InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) $S['DomainCredential'] -is [pscredential] }) | Should -BeTrue
        foreach ($n in 'node-01', 'node-02', 'node-03') { (Invoke-AccountPick $shared $n 3).Kind | Should -Be 'local' -Because $n }
    }
    It 'F7: Key Vault is read while CredentialLock is NOT held' {
        $shared = New-AccountShared 'both'
        $global:AzlTestLock = $shared['CredentialLock']
        $global:AzlTestHeld = 'unset'
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { $global:AzlTestHeld = [System.Threading.Monitor]::IsEntered($global:AzlTestLock); [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
        $null = Invoke-AccountPick $shared 'node-01'
        $held = $global:AzlTestHeld
        Remove-Variable -Name AzlTestLock, AzlTestHeld -Scope Global -ErrorAction SilentlyContinue
        $held | Should -BeFalse
    }
    It 'F5: a stale rejection (same epoch, second concurrent failure) does not double the back-off or latch' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-01' 1
        $b = Invoke-AccountPick $shared 'node-02' 1
        $a.Kind | Should -Be 'domain'; $b.Kind | Should -Be 'domain'
        Register-AccountResult $shared 'node-01' rejected 2 '' (New-AccountConfig) $a.Ticket
        Register-AccountResult $shared 'node-02' rejected 2 '' (New-AccountConfig) $b.Ticket
        $br = Get-AccountBreaker $shared
        $br.State | Should -Be 'open'
        $br.Failures | Should -Be 1
        $br.BackoffMinutes | Should -Be 15
    }
    It 'F5: a stale ok from an ordinary connection does not wipe an open or a latched breaker' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $old = Invoke-AccountPick $shared 'node-02' 1
        $bad = Invoke-AccountPick $shared 'node-03' 1
        Register-AccountResult $shared 'node-03' rejected 2 '' (New-AccountConfig) $bad.Ticket
        Register-AccountResult $shared 'node-02' ok 3 '' (New-AccountConfig) $old.Ticket
        (Get-AccountBreaker $shared).State | Should -Be 'open'
        (Get-AccountBreaker $shared).Failures | Should -Be 1
        $probe = Invoke-AccountPick $shared 'node-01' 20
        $probe.Probe | Should -BeTrue
        Register-AccountResult $shared 'node-01' rejected 20.1 '' (New-AccountConfig) $probe.Ticket
        (Get-AccountBreaker $shared).State | Should -Be 'latched'
        Register-AccountResult $shared 'node-02' ok 21 '' (New-AccountConfig) $old.Ticket
        (Get-AccountBreaker $shared).State | Should -Be 'latched'
        Register-AccountResult $shared 'node-02' ok 21 '' (New-AccountConfig)
        (Get-AccountBreaker $shared).State | Should -Be 'latched' -Because 'a result without a ticket from a node that holds no probe is ignored too'
    }
    It 'F5: only the holder of the probe releases it; other results do not clear ProbeInFlight' {
        $shared = New-AccountShared 'both'
        $v = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-01' 1
        Register-AccountResult $shared 'node-01' rejected 2 '' (New-AccountConfig) $a.Ticket
        $probe = Invoke-AccountPick $shared 'node-02' 20
        $probe.Probe | Should -BeTrue
        Register-AccountResult $shared 'node-03' unreachable 20.1
        Register-AccountResult $shared 'node-03' other 20.1
        Register-AccountResult $shared 'node-03' ok 20.1
        Register-AccountResult $shared 'node-01' authorization 20.1
        (Get-AccountBreaker $shared).ProbeInFlight | Should -BeTrue
        (Get-AccountBreaker $shared).State | Should -Be 'open'
        (Invoke-AccountPick $shared 'node-03' 20.2).Probe | Should -BeFalse
        Register-AccountResult $shared 'node-02' ok 20.3 '' (New-AccountConfig) $probe.Ticket
        (Get-AccountBreaker $shared).State | Should -Be 'closed'
        (Get-AccountBreaker $shared).ProbeInFlight | Should -BeFalse
    }
    It 'F6: a probe that makes no attempt is reclaimed after the lease, and the old holder is then ignored' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-01' 1
        Register-AccountResult $shared 'node-01' rejected 2 '' (New-AccountConfig) $a.Ticket
        $lost = Invoke-AccountPick $shared 'node-02' 20
        $lost.Probe | Should -BeTrue
        (Invoke-AccountPick $shared 'node-03' 22.9).Probe | Should -BeFalse -Because 'inside the 180 second lease (170 seconds)'
        $again = Invoke-AccountPick $shared 'node-03' 23.2
        $again.Probe | Should -BeTrue -Because 'the lease ran out (192 seconds)'
        $again.Kind | Should -Be 'domain'
        Register-AccountResult $shared 'node-02' ok 23.5 '' (New-AccountConfig) $lost.Ticket
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'open' -Because 'the late ok of the old holder is stale'
        $b.ProbeInFlight | Should -BeTrue
        Register-AccountResult $shared 'node-03' ok 23.6 '' (New-AccountConfig) $again.Ticket
        (Get-AccountBreaker $shared).State | Should -Be 'closed'
    }
    It 'F8: after the secret version changes there is ONE probe, and the breaker closes on that probe ok, not before' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-01' 1
        Register-AccountResult $shared 'node-01' rejected 2 '' (New-AccountConfig) $a.Ticket
        $p = Invoke-AccountPick $shared 'node-02' 20
        Register-AccountResult $shared 'node-02' rejected 20.1 '' (New-AccountConfig) $p.Ticket
        (Get-AccountBreaker $shared).State | Should -Be 'latched'
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'New-Pa55-not-real' -AsPlainText -Force); Version = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2' } }
        $first = Invoke-AccountPick $shared 'node-01' 60
        $first.Kind | Should -Be 'domain'
        $first.Probe | Should -BeTrue
        $first.Password | Should -Be 'New-Pa55-not-real'
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'closed'
        $b.Verified | Should -BeFalse
        $b.SecretVersion | Should -Be 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2'
        foreach ($n in 'node-02', 'node-03') { (Invoke-AccountPick $shared $n 60.1).Kind | Should -Be 'local' -Because $n }
        Register-AccountResult $shared 'node-01' ok 60.2 '' (New-AccountConfig) $first.Ticket
        (Get-AccountBreaker $shared).Verified | Should -BeTrue
        (Invoke-AccountPick $shared 'node-02' 61).Kind | Should -Be 'domain'
    }
    It 'F11: a locked-out account latches; only a new secret version, or the operator confirming the unlock, lets it back' {
        $shared = New-AccountShared 'both'
        $v = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-02' 1
        Register-AccountResult $shared 'node-02' lockedOut 2 'referenced account is currently locked out' (New-AccountConfig) $a.Ticket
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'latched'
        $b.LastClass | Should -Be 'lockedOut'
        foreach ($m in 130, 400, 5000) { (Invoke-AccountPick $shared 'node-01' $m).Kind | Should -Be 'local' -Because "minute $m" }
        $detail = InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) Get-AzlSonarLogAccountDetail -Shared $S -AccountName 'IIC\svc-join' -MaxRejections 2 }
        $detail.state | Should -Be 'latched'
        $detail.lastClass | Should -Be 'lockedOut'
        InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) Confirm-AzlSonarAccountUnlock -Shared $S }
        $after = Get-AccountBreaker $shared
        $after.State | Should -Be 'closed'
        $after.Verified | Should -BeFalse
        $probe = Invoke-AccountPick $shared 'node-03' 6000
        $probe.Kind | Should -Be 'domain'
        $probe.Probe | Should -BeTrue
    }
    It 'F11: a locked-out account is left by a new secret version' {
        $shared = New-AccountShared 'both'
        $v = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-02' 1
        Register-AccountResult $shared 'node-02' lockedOut 2 '' (New-AccountConfig) $a.Ticket
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'New-Pa55-not-real' -AsPlainText -Force); Version = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2' } }
        $r = Invoke-AccountPick $shared 'node-03' 130
        $r.Kind | Should -Be 'domain'
        $r.Probe | Should -BeTrue
    }
}


# ---------------------------------------------------------------------------------------------------------------------
# Third review (N1 to N5)
# ---------------------------------------------------------------------------------------------------------------------

Describe 'N1/N2/N5: error numbers, SSPI codes and account states' {
    It 'N1: the legs of a failed connection carry the exception, and the worst leg is classified from its error numbers' {
        InModuleScope AzlSonar {
            $legs = @(
                @{ Transport = 'winrm'; Exception = [pscustomobject]@{ Message = 'Zeitueberschreitung'; ErrorCode = 53; InnerException = $null }; Message = 'Zeitueberschreitung' },
                @{ Transport = 'ssh'; Exception = $null; Message = 'SSH: not tried with the domain account after a WinRM failure'; Skipped = $true })
            (Get-AzlSonarWorstFailureClass -Leg $legs).Class | Should -Be 'other'
            $legs[0].Exception = [pscustomobject]@{ Message = 'Anmeldefehler'; ErrorCode = 1326; InnerException = $null }
            (Get-AzlSonarWorstFailureClass -Leg $legs).Class | Should -Be 'rejected'
            (Get-AzlSonarWorstFailureClass -Leg @(@{ Transport = 'ssh'; Exception = $null; Message = 'SSH: needs a credential.'; Skipped = $true })).Class | Should -Be 'unreachable'
        }
    }
    It 'N1: Open-AzlSonarNodeConnection returns a leg for every transport it tried or skipped' {
        Mock New-PSSession -ModuleName AzlSonar { throw 'The WinRM client timed out.' }
        $r = InModuleScope AzlSonar {
            $pw = [securestring]::new()
            foreach ($ch in 'D0main-Pa55-not-real'.ToCharArray()) { $pw.AppendChar($ch) }
            Open-AzlSonarNodeConnection -Address '192.0.2.11' -Credential ([pscredential]::new('IIC\svc-join', $pw)) -Transport auto -DomainAccount
        }
        @($r.Legs).Count | Should -Be 2
        $r.Legs[0].Transport | Should -Be 'winrm'
        $r.Legs[0].Exception | Should -Not -BeNullOrEmpty
        $r.Legs[1].Transport | Should -Be 'ssh'
        $r.Legs[1].Skipped | Should -BeTrue
    }
    It 'N2: SSPI codes are matched whole, signed or unsigned, in HResult, ErrorCode and text (0x8009030c rejected; 0x8009030e and 0x80090311 unreachable)' {
        InModuleScope AzlSonar {
            $signed = { param($u) [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$u), 0) }
            $logonDenied = 2148074252L   # 0x8009030c
            $noCredentials = 2148074254L # 0x8009030e
            $noAuthority = 2148074257L   # 0x80090311
            foreach ($form in @($logonDenied, (& $signed $logonDenied))) {
                (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'x'; HResult = $form; InnerException = $null })).Class | Should -Be 'rejected' -Because "HResult $form"
                (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'x'; ErrorCode = $form; InnerException = $null })).Class | Should -Be 'rejected' -Because "ErrorCode $form"
            }
            foreach ($code in $noCredentials, $noAuthority) {
                foreach ($form in @($code, (& $signed $code))) {
                    (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'x'; HResult = $form; InnerException = $null })).Class | Should -Be 'unreachable' -Because "HResult $form"
                    (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'x'; ErrorCode = $form; InnerException = $null })).Class | Should -Be 'unreachable' -Because "ErrorCode $form"
                }
            }
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The SSPI call failed with 0x80090311').Class | Should -Be 'unreachable'
            (Get-AzlSonarConnectionFailureClass -Transport winrm -Message 'The SSPI call failed with 0x8009030C').Class | Should -Be 'rejected'
        }
    }
    It 'N5: a disabled, expired or must-change account (1331, 1330, 1907) is its own class' {
        InModuleScope AzlSonar {
            foreach ($code in 1330, 1331, 1907) {
                (Get-AzlSonarConnectionFailureClass -Transport winrm -Exception ([pscustomobject]@{ Message = 'Kontofehler'; ErrorCode = $code; InnerException = $null })).Class | Should -Be 'accountUnusable' -Because "$code"
            }
            (Get-AzlSonarWorstFailureClass -Reason 'WinRM: bad password | SSH: timed out').Class | Should -Be 'rejected'
        }
    }
    It 'N5: an unusable account latches without counting a failure (it does not raise the bad-password count)' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-02' 1
        Register-AccountResult $shared 'node-02' accountUnusable 2 'account disabled' (New-AccountConfig) $a.Ticket
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'latched'
        $b.Failures | Should -Be 0
        $b.LastClass | Should -Be 'accountUnusable'
        $r = Invoke-AccountPick $shared 'node-03' 3
        $r.Kind | Should -Be 'local'
        $r.Reason | Should -Match 'disabled, expired or must change its password'
        $r.Warning | Should -Match 'cannot be used'
    }
}

Describe 'N2: inconclusive results never make the account retry on every poll' {
    BeforeEach {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
    }
    It 'a probe that ends in other or unreachable pushes the next probe of an open breaker 5 minutes out' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-01' 1
        Register-AccountResult $shared 'node-01' rejected 2 '' (New-AccountConfig) $a.Ticket
        $probe = Invoke-AccountPick $shared 'node-02' 20
        $probe.Probe | Should -BeTrue
        Register-AccountResult $shared 'node-02' other 20.1 'what?' (New-AccountConfig) $probe.Ticket
        $b = Get-AccountBreaker $shared
        $b.ProbeInFlight | Should -BeFalse
        ($b.NextProbeAt - $script:T0.AddMinutes(20.1)).TotalMinutes | Should -Be 5
        (Invoke-AccountPick $shared 'node-03' 21).Probe | Should -BeFalse -Because 'not on the next poll'
        $again = Invoke-AccountPick $shared 'node-03' 26
        $again.Probe | Should -BeTrue
        Register-AccountResult $shared 'node-03' unreachable 26.1 'timed out' (New-AccountConfig) $again.Ticket
        (($b = Get-AccountBreaker $shared).NextProbeAt - $script:T0.AddMinutes(26.1)).TotalMinutes | Should -Be 5
        $b.State | Should -Be 'open'
    }
    It 'three results in a row that cannot be classified pause the account (and an ok in between starts the count again)' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        foreach ($m in 1, 2) {
            $p = Invoke-AccountPick $shared 'node-02' $m
            Register-AccountResult $shared 'node-02' other ($m + 0.1) 'odd' (New-AccountConfig) $p.Ticket
        }
        (Get-AccountBreaker $shared).OtherCount | Should -Be 2
        $good = Invoke-AccountPick $shared 'node-03' 3
        Register-AccountResult $shared 'node-03' ok 3.1 '' (New-AccountConfig) $good.Ticket
        (Get-AccountBreaker $shared).OtherCount | Should -Be 0
        foreach ($m in 4, 5, 6) {
            $p = Invoke-AccountPick $shared 'node-02' $m
            Register-AccountResult $shared 'node-02' other ($m + 0.1) 'odd' (New-AccountConfig) $p.Ticket
        }
        $b = Get-AccountBreaker $shared
        $b.State | Should -Be 'latched'
        $b.LastClass | Should -Be 'other'
        $r = Invoke-AccountPick $shared 'node-03' 7
        $r.Kind | Should -Be 'local'
        $r.Reason | Should -Match 'cannot tell from a wrong password'
    }
}

Describe 'N3: concurrent attempts are capped and a rotated password is noticed before it is reused' {
    BeforeEach {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
    }
    It 'at most maxRejections (2) connection attempts are in flight at once; asking without connecting is not an attempt' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $a = Invoke-AccountPick $shared 'node-02' 0.1
        $b = Invoke-AccountPick $shared 'node-03' 0.1
        $a.Kind | Should -Be 'domain'; $b.Kind | Should -Be 'domain'
        $c = Invoke-AccountPick $shared 'node-01' 0.1
        $c.Kind | Should -Be 'local'
        $c.Reason | Should -Match 'another node is checking'
        (Invoke-AccountPick $shared 'node-01' 0.1 (New-AccountConfig) $false).Kind | Should -Be 'domain' -Because 'a node that already has its connection only asks which account applies'
        Register-AccountResult $shared 'node-02' ok 0.2 '' (New-AccountConfig) $a.Ticket
        (Invoke-AccountPick $shared 'node-01' 0.3).Kind | Should -Be 'domain'
    }
    It 'attempts that never report stop counting when their lease runs out' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $null = Invoke-AccountPick $shared 'node-02' 0.1
        $null = Invoke-AccountPick $shared 'node-03' 0.1
        (Invoke-AccountPick $shared 'node-01' 1).Kind | Should -Be 'local'
        (Invoke-AccountPick $shared 'node-01' 3.5).Kind | Should -Be 'domain'
    }
    It 'a rotated password is noticed by a version recheck (a Key Vault read, not an attempt): one probe with the new password, the others wait' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        (Invoke-AccountPick $shared 'node-02' 0.5).Probe | Should -BeFalse
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly -Because 'no recheck inside a minute'
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'New-Pa55-not-real' -AsPlainText -Force); Version = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2' } }
        $r = Invoke-AccountPick $shared 'node-02' 1.5
        $r.Kind | Should -Be 'domain'
        $r.Probe | Should -BeTrue
        $r.Password | Should -Be 'New-Pa55-not-real'
        $b = Get-AccountBreaker $shared
        $b.Verified | Should -BeFalse
        $b.SecretVersion | Should -Be 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2'
        (Invoke-AccountPick $shared 'node-03' 1.6).Kind | Should -Be 'local'
        Register-AccountResult $shared 'node-02' ok 1.7 '' (New-AccountConfig) $r.Ticket
        (Invoke-AccountPick $shared 'node-03' 1.8).Kind | Should -Be 'domain'
    }
    It 'the same version at the recheck changes nothing; a failed recheck keeps the cached credential in use' {
        $shared = New-AccountShared 'both'
        $null = Confirm-AccountDomain $shared 'node-01'
        $same = Invoke-AccountPick $shared 'node-02' 1.5
        $same.Kind | Should -Be 'domain'
        $same.Probe | Should -BeFalse
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 2 -Exactly
        (Get-AccountBreaker $shared).Verified | Should -BeTrue
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { throw 'Forbidden' }
        $down = Invoke-AccountPick $shared 'node-03' 3
        $down.Kind | Should -Be 'domain'
        $down.Probe | Should -BeFalse
        (Get-AccountBreaker $shared).Verified | Should -BeTrue
        InModuleScope AzlSonar -Parameters @{ S = $shared } { param($S) $S['LogAccount']['*unavailable'] } | Should -BeNullOrEmpty
    }
}

Describe 'N4: the probe lease starts when the Key Vault read is over' {
    It 'ProbeStartedAt is the real time after the read, and the lease is 180 seconds' {
        $shared = New-AccountShared 'both'
        $global:AzlTestReadAt = $null
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { $global:AzlTestReadAt = [datetime]::UtcNow; Start-Sleep -Milliseconds 400; [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' } }
        $pick = InModuleScope AzlSonar -Parameters @{ S = $shared; C = (New-AccountConfig) } {
            param($S, $C)
            $local = [pscredential]::new('azl-admin', (ConvertTo-SecureString 'Local-Pa55-not-real' -AsPlainText -Force))
            Select-AzlSonarNodeAccount -Shared $S -Config $C -Node 'node-01' -Local $local
        }
        $readAt = $global:AzlTestReadAt
        Remove-Variable -Name AzlTestReadAt -Scope Global -ErrorAction SilentlyContinue
        $pick.Probe | Should -BeTrue
        $b = Get-AccountBreaker $shared
        ($b.ProbeStartedAt - $readAt).TotalMilliseconds | Should -BeGreaterThan 300
        $pick.Ticket.StartedAt | Should -Be $b.ProbeStartedAt
        InModuleScope AzlSonar { $script:AzlSonarProbeLeaseSeconds } | Should -BeGreaterOrEqual 180
    }
}
