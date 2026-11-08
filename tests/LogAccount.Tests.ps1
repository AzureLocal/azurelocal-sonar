#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test credentials are made-up values held only in memory.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The Get-AzKeyVaultSecret stub mirrors the real parameters.')]
param()
Set-StrictMode -Version Latest

# Which account reads a node's logs: local until the node reports DomainJoined, then the domain account, and back to the
# local one (with a warning) when the node rejects it. No Azure, no node: Key Vault is mocked, no secret is real.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    # Az.KeyVault may be missing on a build agent; Pester can only mock a command that exists.
    if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        Set-Item -Path 'function:global:Get-AzKeyVaultSecret' -Value { [CmdletBinding()] param([string]$VaultName, [string]$Name) throw 'Get-AzKeyVaultSecret stub called without a mock.' }
        $script:StubbedKeyVault = $true
    }
    Import-SonarTestModule
    $script:Password = 'D0main-Pa55-not-real'
    $script:Accounts = [pscustomobject]@{
        local  = [pscustomobject]@{ username = 'azl-admin' }
        domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example-mgmt-01/svc-join-password' }
    }
    function global:New-AccountConfig([string]$Identity = 'ActiveDirectory', [object]$Accounts = $script:Accounts) {
        [pscustomobject]@{ identityModel = $Identity; logAccounts = $Accounts; nodes = @([pscustomobject]@{ name = 'node-01'; seed = $true }, [pscustomobject]@{ name = 'node-02' }); seedNode = [pscustomobject]@{ name = 'node-01'; address = '192.0.2.11' } }
    }
    function global:New-AccountLine([string]$At, [string]$Node, [string]$State, [string]$Evidence = '', [hashtable]$Extra = @{}) {
        $o = [ordered]@{ timestamp = $At; node = $Node; stage = 'OsConfiguration'; step = 'DomainJoin'; state = $State; evidence = $Evidence; level = 'Info'; nextAction = ''; method = ''; transport = '' }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        $o | ConvertTo-Json -Compress -Depth 6
    }
}

AfterAll {
    foreach ($f in 'New-AccountConfig', 'New-AccountLine') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
    if ($script:StubbedKeyVault) { Remove-Item -LiteralPath 'Function:\Get-AzKeyVaultSecret' -ErrorAction SilentlyContinue }
}

Describe 'ConvertFrom-AzlSonarKeyVaultReference' {
    It 'reads keyvault://vault/secret (and a version), and nothing else' {
        InModuleScope AzlSonar {
            $r = ConvertFrom-AzlSonarKeyVaultReference -Reference 'keyvault://kv-example-mgmt-01/svc-join-password'
            $r.Vault | Should -Be 'kv-example-mgmt-01'
            $r.Secret | Should -Be 'svc-join-password'
            (ConvertFrom-AzlSonarKeyVaultReference -Reference 'keyvault://kv-example/s/0123abcd').Secret | Should -Be 's'
            ConvertFrom-AzlSonarKeyVaultReference -Reference 'P@ssw0rd!' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarKeyVaultReference -Reference 'https://kv.vault.azure.net/secrets/x' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarKeyVaultReference -Reference '' | Should -BeNullOrEmpty
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
        $a.userName | Should -Be 'azl-admin'
        $a.reason | Should -Be 'joined, waiting for domain administrators: using azl-admin'
        $a.waitingForAdmins | Should -BeTrue
        $a.warning | Should -Be ''
    }
    It 'DomainAdminsConfigured without DomainJoined is not enough either' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $false -AdminsConfigured $true }
        $a.kind | Should -Be 'local'
        $a.reason | Should -Be 'workgroup: using azl-admin'
    }
    It 'after DomainJoined and DomainAdminsConfigured: the domain account, NETBIOS\user from the file' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $true }
        $a.kind | Should -Be 'domain'
        $a.userName | Should -Be 'IIC\svc-join'
        $a.reason | Should -Be 'domain-joined: using IIC\svc-join'
        $a.waitingForAdmins | Should -BeFalse
    }
    It 'a local identity design stays on the local account even if a join is reported' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig 'LocalIdentity') } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $true }
        $a.kind | Should -Be 'local'
        $a.reason | Should -Match 'identity design is local'
    }
    It 'a domain account the node rejected: back to the local account, with a warning that names both' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-01' -DomainJoined $true -AdminsConfigured $true -Rejected $true }
        $a.kind | Should -Be 'local'
        $a.rejected | Should -BeTrue
        $a.reason | Should -Be 'domain-joined, but IIC\svc-join was rejected: using azl-admin'
        $a.warning | Should -Match 'IIC\\svc-join was rejected on node-01'
        $a.warning | Should -Match 'azl-admin'
    }
    It 'joined but the file names no domain account: the local account and a warning that says what to set' {
        $none = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = ''; username = ''; passwordRef = '' } }
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig 'ActiveDirectory' $none) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'node-02' -DomainJoined $true -AdminsConfigured $true }
        $a.kind | Should -Be 'local'
        $a.warning | Should -Match 'lcm_user'
    }
    It 'the account given with -Credential is the local account when it is known better than the file' {
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'n' -DomainJoined $false -LocalUserName '.\operator' }
        $a.reason | Should -Be 'workgroup: using .\operator'
    }
    It 'a user name that already carries its domain is not given a second one' {
        $acc = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join@iic.example.test'; passwordRef = 'keyvault://kv/s' } }
        $a = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig 'ActiveDirectory' $acc) } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'n' -DomainJoined $true -AdminsConfigured $true }
        $a.userName | Should -Be 'svc-join@iic.example.test'
    }
}

Describe 'The domain-joined flag in the event store' {
    BeforeEach {
        $script:Store = [hashtable]::Synchronized(@{})
        $script:Feed = { param($Lines) InModuleScope AzlSonar -Parameters @{ S = $script:Store; L = @($Lines) } { param($S, $L) foreach ($x in $L) { Add-AzlSonarOsConfigEvent -Store $S -Line $x } } }
        $script:Joined = { param($Node) InModuleScope AzlSonar -Parameters @{ S = $script:Store; N = $Node } { param($S, $N) Get-AzlSonarOsDomainJoined -Store $S -Node $N } }
    }
    It 'joined and admins-configured are two separate facts: DomainJoined, then DomainAdminsConfigured' {
        $state = { param($Node) InModuleScope AzlSonar -Parameters @{ S = $script:Store; N = $Node } { param($S, $N) Get-AzlSonarOsDomainState -Store $S -Node $N } }
        $s0 = & $state 'node-01'
        $s0.Joined | Should -BeFalse; $s0.AdminsConfigured | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoined' 'joined'))
        $s1 = & $state 'node-01'
        $s1.Joined | Should -BeTrue; $s1.AdminsConfigured | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T19:03:00Z' 'node-01' 'DomainAdminsConfigured' 'the LCM user was added to the local Administrators'))
        $s2 = & $state 'node-01'
        $s2.Joined | Should -BeTrue; $s2.AdminsConfigured | Should -BeTrue
        (& $state 'node-02').AdminsConfigured | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T20:00:00Z' 'node-01' 'DomainJoinPlanned' 'Change: not joined' @{ action = 'Change' }))
        $s3 = & $state 'node-01'
        $s3.Joined | Should -BeFalse; $s3.AdminsConfigured | Should -BeFalse
    }
    It 'is false until DomainJoined arrives, then true for that node only' {
        & $script:Joined 'node-01' | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T19:00:00Z' 'node-01' 'DomainJoinPlanned' 'Change: join iic.example.test' @{ action = 'Change' }), (New-AccountLine '2026-11-07T19:01:00Z' 'node-01' 'DomainJoinApplying'))
        & $script:Joined 'node-01' | Should -BeFalse
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoined' 'joined iic.example.test'))
        & $script:Joined 'node-01' | Should -BeTrue
        & $script:Joined 'node-02' | Should -BeFalse
        & $script:Joined 'NODE-01' | Should -BeTrue -Because 'node names are case-insensitive'
    }
    It 'a DomainJoinFailed does not mark the node as joined' {
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoinFailed' 'The specified domain either does not exist or could not be contacted.'))
        & $script:Joined 'node-01' | Should -BeFalse
    }
    It 'a plan that finds the machine already joined counts, and a plan that finds it not joined clears the flag' {
        & $script:Feed @((New-AccountLine '2026-11-07T19:00:00Z' 'node-01' 'DomainJoinPlanned' 'Ok: already joined' @{ action = 'Ok' }))
        & $script:Joined 'node-01' | Should -BeTrue
        & $script:Feed @((New-AccountLine '2026-11-07T20:00:00Z' 'node-01' 'DomainJoinPlanned' 'Change: not joined' @{ action = 'Change' }))
        & $script:Joined 'node-01' | Should -BeFalse
    }
    It 'survives a new attempt and a run-wide RunStarted that clears the node' {
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoined' 'joined'), (New-AccountLine '2026-11-07T19:03:00Z' 'node-01' 'DomainAdminsConfigured' 'admins'))
        & $script:Feed @('{"timestamp":"2026-11-07T20:00:00Z","node":"node-01","stage":"OsConfiguration","state":"NodeStarted"}')
        & $script:Joined 'node-01' | Should -BeTrue
        & $script:Feed @('{"timestamp":"2026-11-07T21:00:00Z","node":"*","stage":"OsConfiguration","state":"RunStarted","nodes":["node-01","node-02"]}')
        $script:Store.Contains('node-01') | Should -BeFalse
        & $script:Joined 'node-01' | Should -BeTrue
    }
    It 'the flag is not a machine: the state lists only real nodes' {
        & $script:Feed @((New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoined' 'joined'))
        $s = InModuleScope AzlSonar -Parameters @{ S = $script:Store; C = (New-AccountConfig) } { param($S, $C) Get-AzlSonarOsConfigurationState -Store $S -Config $C }
        @($s.nodes).name | Should -Be @('node-01', 'node-02')
    }
}

Describe 'Select-AzlSonarNodeAccount (the credential a connection opens with)' {
    BeforeEach {
        $script:Local = [pscredential]::new('azl-admin', (ConvertTo-SecureString 'Local-Pa55-not-real' -AsPlainText -Force))
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force) } }
        $script:Pick = {
            param($Domain, $Config = (New-AccountConfig), [bool]$Reject = $false)
            InModuleScope AzlSonar -Parameters @{ C = $Config; J = $Domain; L = $script:Local; Rej = $Reject } {
                param($C, $J, $L, $Rej)
                $shared = Initialize-AzlSonarSharedState
                # J: 'none' (a workgroup node), 'joined' (DomainJoined only) or 'both' (DomainJoined and DomainAdminsConfigured)
                if ($J -in 'joined', 'both') { Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line '{"timestamp":"2026-11-07T19:00:00Z","node":"node-01","stage":"OsConfiguration","step":"DomainJoin","state":"DomainJoined"}' }
                if ($J -eq 'both') { Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line '{"timestamp":"2026-11-07T19:01:00Z","node":"node-01","stage":"OsConfiguration","step":"DomainJoin","state":"DomainAdminsConfigured"}' }
                if ($Rej) { Set-AzlSonarLogAccountRejected -Shared $shared -Node 'node-01' -Message 'Access is denied.' }
                $pick = Select-AzlSonarNodeAccount -Shared $shared -Config $C -Node 'node-01' -Local $L
                [pscustomobject]@{ UserName = $pick.Credential.UserName; Password = $pick.Credential.GetNetworkCredential().Password; Account = $pick.Account; Redact = @($shared.Redact); Info = $shared['LogAccount']['node-01'] }
            }
        }
    }
    It 'before the join: the local credential, and the Key Vault is not read' {
        $r = & $script:Pick 'none'
        $r.UserName | Should -Be 'azl-admin'
        $r.Account.kind | Should -Be 'local'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 0 -Exactly
    }
    It 'joined but DomainAdminsConfigured has not arrived: still the local credential, the Key Vault is not read, and the reason says why' {
        $r = & $script:Pick 'joined'
        $r.UserName | Should -Be 'azl-admin'
        $r.Password | Should -Be 'Local-Pa55-not-real'
        $r.Account.kind | Should -Be 'local'
        $r.Account.reason | Should -Be 'joined, waiting for domain administrators: using azl-admin'
        $r.Account.warning | Should -Be ''
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 0 -Exactly
    }
    It 'after DomainJoined and DomainAdminsConfigured: NETBIOS\user with the password from the Key Vault reference, and the password is masked from then on' {
        $r = & $script:Pick 'both'
        $r.UserName | Should -Be 'IIC\svc-join'
        $r.Password | Should -Be $script:Password
        $r.Account.reason | Should -Be 'domain-joined: using IIC\svc-join'
        $r.Redact | Should -Contain $script:Password
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly -ParameterFilter { $VaultName -eq 'kv-example-mgmt-01' -and $Name -eq 'svc-join-password' }
        ($r.Info.Account | ConvertTo-Json -Depth 4) | Should -Not -Match 'D0main'
    }
    It 'the domain credential is read once and kept' {
        $null = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig); L = $script:Local } {
            param($C, $L)
            $shared = Initialize-AzlSonarSharedState
            Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line '{"timestamp":"2026-11-07T19:00:00Z","node":"node-01","state":"DomainJoined"}'
            Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line '{"timestamp":"2026-11-07T19:01:00Z","node":"node-01","state":"DomainAdminsConfigured"}'
            1..3 | ForEach-Object { $null = Select-AzlSonarNodeAccount -Shared $shared -Config $C -Node 'node-01' -Local $L }
        }
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly
    }
    It 'a domain account the node rejected: the local credential again, a warning, and it stays that way' {
        $r = & $script:Pick 'both' (New-AccountConfig) $true
        $r.UserName | Should -Be 'azl-admin'
        $r.Account.kind | Should -Be 'local'
        $r.Account.rejected | Should -BeTrue
        $r.Account.warning | Should -Match 'IIC\\svc-join was rejected'
        $r.Info.Rejected | Should -BeTrue
        $r.Info.Message | Should -Be 'Access is denied.'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 0 -Exactly
    }
    It 'a Key Vault that cannot be read: the local credential and a reason that names the vault, never a secret' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { throw 'Forbidden: the caller is not authorized to get secrets.' }
        $r = & $script:Pick 'both'
        $r.UserName | Should -Be 'azl-admin'
        $r.Account.kind | Should -Be 'local'
        $r.Account.warning | Should -Match 'kv-example-mgmt-01'
        $r.Account.warning | Should -Match 'svc-join-password'
        $r.Account.warning | Should -Not -Match 'D0main'
        $r.Info.Rejected | Should -BeTrue
    }
    It 'a password written in the file instead of a reference is refused, never used' {
        $bad = [pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'Plain-Text-Pa55' } }
        $r = & $script:Pick 'both' (New-AccountConfig 'ActiveDirectory' $bad)
        $r.UserName | Should -Be 'azl-admin'
        $r.Account.warning | Should -Match 'keyvault://'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 0 -Exactly
    }
}

Describe 'Test-AzlSonarAuthenticationFailure' {
    It 'tells a refused account from an unreachable node' {
        InModuleScope AzlSonar {
            Test-AzlSonarAuthenticationFailure -Message 'WinRM: Access is denied.' | Should -BeTrue
            Test-AzlSonarAuthenticationFailure -Message 'The user name or password is incorrect.' | Should -BeTrue
            Test-AzlSonarAuthenticationFailure -Message 'Logon failure: unknown user name or bad password.' | Should -BeTrue
            Test-AzlSonarAuthenticationFailure -Message 'The WinRM client cannot process the request. (Kerberos)' | Should -BeTrue
            Test-AzlSonarAuthenticationFailure -Message 'WinRM cannot complete the operation: the computer is turned off or not reachable (timeout).' | Should -BeFalse
            Test-AzlSonarAuthenticationFailure -Message '' | Should -BeFalse
        }
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
    It 'planned, applying, joined, and failed with the AD error text' {
        $plan = New-AccountLine '2026-11-07T19:01:00Z' 'node-01' 'DomainJoinPlanned' 'Change: join iic.example.test (OU=Servers)' @{ action = 'Change'; current = 'workgroup WORKGROUP'; desired = 'iic.example.test' }
        $s = & $script:BuildJoin @($script:Start, $plan)
        (& $script:JoinStep $s).osc.stage | Should -Be 'planned'
        (& $script:JoinStep $s).osc.current | Should -Be 'workgroup WORKGROUP'
        $applying = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoinApplying' 'Add-Computer started'))
        (& $script:JoinStep $applying).osc.stage | Should -Be 'changing'
        (& $script:JoinStep $applying).status | Should -Be 'running'
        $joined = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoinApplying' 'x'), (New-AccountLine '2026-11-07T19:04:00Z' 'node-01' 'DomainJoined' 'joined iic.example.test'))
        (& $script:JoinStep $joined).osc.stage | Should -Be 'applied'
        (& $script:JoinStep $joined).status | Should -Be 'success'
        $joined.nodes[0].domainJoined | Should -BeTrue
        $joined.nodes[0].domainAdminsConfigured | Should -BeFalse
        $joined.nodes[0].logAccount.reason | Should -Be 'joined, waiting for domain administrators: using azl-admin'
        $joined.nodes[0].logAccount.waitingForAdmins | Should -BeTrue
        $admins = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:04:00Z' 'node-01' 'DomainJoined' 'joined iic.example.test'), (New-AccountLine '2026-11-07T19:05:00Z' 'node-01' 'DomainAdminsConfigured' 'the LCM user IIC\svc-lcm was added to the local Administrators'))
        $admins.nodes[0].domainAdminsConfigured | Should -BeTrue
        $admins.nodes[0].logAccount.kind | Should -Be 'domain'
        (& $script:JoinStep $admins).osc.stage | Should -Be 'applied'
        (& $script:JoinStep $admins).description | Should -Match 'was added to the local Administrators'
        $failed = & $script:BuildJoin @($script:Start, $plan, (New-AccountLine '2026-11-07T19:02:00Z' 'node-01' 'DomainJoinApplying' 'x'), (New-AccountLine '2026-11-07T19:03:00Z' 'node-01' 'DomainJoinFailed' 'Add-Computer: The specified domain either does not exist or could not be contacted.'))
        (& $script:JoinStep $failed).osc.stage | Should -Be 'failed'
        (& $script:JoinStep $failed).status | Should -Be 'error'
        @((& $script:JoinStep $failed).errors)[0] | Should -Match 'specified domain either does not exist'
        $failed.nodes[0].domainJoined | Should -BeFalse
    }
    It 'a local identity design: not applicable, with the reason' {
        $s = & $script:BuildJoin @($script:Start) 'LocalIdentity'
        (& $script:JoinStep $s).osc.stage | Should -Be 'skipped'
        (& $script:JoinStep $s).description | Should -Match 'identity design is local'
    }
}

Describe 'the account per node in the state, the Details and the page model' {
    It 'every machine says which account reads its logs and why; a join switches it' {
        $s = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } {
            param($C)
            $store = [hashtable]::Synchronized(@{})
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:00:00Z","node":"node-01","state":"NodeStarted"}'
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:05:00Z","node":"node-02","step":"DomainJoin","state":"DomainJoined"}'
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:06:00Z","node":"node-02","step":"DomainJoin","state":"DomainAdminsConfigured"}'
            Get-AzlSonarOsConfigurationState -Store $store -Config $C -LocalUserName 'azl-admin'
        }
        $s.nodes[0].logAccount.reason | Should -Be 'workgroup: using azl-admin'
        $s.nodes[0].logAccount.kind | Should -Be 'local'
        $s.nodes[1].logAccount.reason | Should -Be 'domain-joined: using IIC\svc-join'
        $s.nodes[1].logAccount.userName | Should -Be 'IIC\svc-join'
        $s.nodes[1].domainJoined | Should -BeTrue
    }
    It 'a rejected domain account is a warning on the machine and in the state warnings' {
        $s = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } {
            param($C)
            $store = [hashtable]::Synchronized(@{})
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:05:00Z","node":"node-01","step":"DomainJoin","state":"DomainJoined"}'
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:06:00Z","node":"node-01","step":"DomainJoin","state":"DomainAdminsConfigured"}'
            $info = [hashtable]::Synchronized(@{}); $info['node-01'] = @{ Rejected = $true; Message = 'Access is denied.' }
            Get-AzlSonarOsConfigurationState -Store $store -Config $C -LogAccount $info -LocalUserName 'azl-admin'
        }
        $s.nodes[0].logAccount.kind | Should -Be 'local'
        $s.nodes[0].logAccount.warning | Should -Match 'rejected'
        ($s.warnings -join ' ') | Should -Match 'IIC\\svc-join was rejected'
    }
    It 'the Details pop-down facts carry no password, no Key Vault name and no secret name' {
        $json = '{"subscriptionId":"00000000-0000-0000-0000-000000000000","resourceGroup":"rg-example-azl","clusterName":"clus01","identityModel":"ActiveDirectory","nodes":[{"name":"node-01","address":"192.0.2.11","seed":true}],"logAccounts":{"local":{"username":"azl-admin"},"domain":{"netbios":"IIC","username":"svc-join","passwordRef":"keyvault://kv-secret-vault-name/svc-join-password"}}}'
        $facts = InModuleScope AzlSonar -Parameters @{ J = $json } { param($J) New-AzlSonarDetailFact -Config (Read-AzlSonarConfig -Json $J) }
        ($facts | ConvertTo-Json -Depth 8) | Should -Not -Match 'kv-secret-vault-name|svc-join-password|keyvault://'
    }
    It 'the state, the public config and the log lines never carry the password, the vault or the reference' {
        Mock Get-AzKeyVaultSecret -ModuleName AzlSonar { [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'D0main-Pa55-not-real' -AsPlainText -Force) } }
        $r = InModuleScope AzlSonar -Parameters @{ C = (New-AccountConfig) } {
            param($C)
            $shared = Initialize-AzlSonarSharedState
            $local = [pscredential]::new('azl-admin', (ConvertTo-SecureString 'Local-Pa55-not-real' -AsPlainText -Force))
            $shared['LocalUserName'] = 'azl-admin'
            Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line '{"timestamp":"2026-11-07T19:05:00Z","node":"node-01","step":"DomainJoin","state":"DomainJoined"}'
            Add-AzlSonarOsConfigEvent -Store $shared['OsConfigEvents'] -Line '{"timestamp":"2026-11-07T19:06:00Z","node":"node-01","step":"DomainJoin","state":"DomainAdminsConfigured"}'
            $null = Select-AzlSonarNodeAccount -Shared $shared -Config $C -Node 'node-01' -Local $local
            # an event whose text carries the password is masked on its way into the log pane
            $line = ConvertFrom-AzlSonarOsConfigEvent -Line '{"timestamp":"2026-11-07T19:06:00Z","node":"node-01","state":"DomainJoinFailed","step":"DomainJoin","level":"Error","evidence":"join failed for IIC\\svc-join with D0main-Pa55-not-real"}'
            Add-AzlSonarLogLine -Shared $shared -Line @($line)
            $state = Get-AzlSonarOsConfigurationState -Store $shared['OsConfigEvents'] -Config $C -LogAccount $shared['LogAccount'] -LocalUserName 'azl-admin'
            [pscustomobject]@{
                State = ConvertTo-AzlSonarJson ([ordered]@{ osConfiguration = $state })
                Lines = ConvertTo-AzlSonarJson @((Get-AzlSonarLogWindow -Shared $shared).lines)
                Public = ConvertTo-AzlSonarJson (ConvertTo-AzlSonarPublicConfig -Config (Read-AzlSonarConfig -Json '{"subscriptionId":"00000000-0000-0000-0000-000000000000","resourceGroup":"rg","clusterName":"c","identityModel":"ActiveDirectory","nodes":[{"name":"node-01","address":"192.0.2.11","seed":true}],"logAccounts":{"local":{"username":"azl-admin"},"domain":{"netbios":"IIC","username":"svc-join","passwordRef":"keyvault://kv-example-mgmt-01/svc-join-password"}}}') -StartedAt ([datetime]::UtcNow) -ServerId 'x')
            }
        }
        foreach ($text in $r.State, $r.Lines, $r.Public) {
            $text | Should -Not -Match 'D0main-Pa55-not-real|Local-Pa55-not-real'
            $text | Should -Not -Match 'keyvault://|kv-example-mgmt-01|svc-join-password'
        }
        $r.State | Should -Match 'IIC\\\\svc-join'
        $r.Lines | Should -Match '\*\*\*'
    }
}

Describe 'logAccounts in the config and the master file' {
    It 'is read from a config file, checked, and never takes a password' {
        $good = New-SonarConfigObject
        $good | Add-Member -NotePropertyName logAccounts -NotePropertyValue ([pscustomobject]@{ local = [pscustomobject]@{ username = 'azl-admin' }; domain = [pscustomobject]@{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'keyvault://kv-example/svc-join-password' } }) -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $good) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $cfg.logAccounts.domain.username | Should -Be 'svc-join'
        $cfg.logAccounts.domain.passwordRef | Should -Be 'keyvault://kv-example/svc-join-password'
        $plain = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson (New-SonarConfigObject)) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $plain.logAccounts.domain.username | Should -Be ''
        foreach ($case in @{ Domain = @{ netbios = 'IIC'; username = 'svc-join'; passwordRef = 'Plain-Pa55' } }, @{ Domain = @{ netbios = 'IIC'; username = 'svc-join'; password = 'x' } }, @{ Domain = @{ netbios = ' '; username = 'svc-join' } }) {
            $bad = New-SonarConfigObject
            $bad | Add-Member -NotePropertyName logAccounts -NotePropertyValue ([pscustomobject]@{ domain = [pscustomobject]$case.Domain }) -Force
            $problems = InModuleScope AzlSonar -Parameters @{ C = $bad } { param($C) Test-AzlSonarConfig -Config $C }
            ($problems -match 'logAccounts') | Should -Not -BeNullOrEmpty
        }
    }
    It 'the master file import uses the LCM user (identity.active_directory.lcm_user) as the domain account when there is no override' {
        $yaml = (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') -Raw)
        $yaml = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    lcm_user:`n      username: `"svc-lcm`"`n      password: `"keyvault://kv-example-mgmt-01/lcm-password`"`n")
        $file = Join-Path $TestDrive 'ad-lcm.yml'
        Set-Content -LiteralPath $file -Value $yaml
        $config = Read-AzlSonarConfig -InfrastructureFile $file 3>$null
        $config.logAccounts.local.username | Should -Be 'azl-admin'
        $config.logAccounts.domain.netbios | Should -Be 'IIC'
        $config.logAccounts.domain.username | Should -Be 'svc-lcm'
        $config.logAccounts.domain.source | Should -Be 'lcm_user'
        $config.logAccounts.domain.passwordRef | Should -Be 'keyvault://kv-example-mgmt-01/lcm-password'
    }
    It 'the optional domain_join_account overrides the LCM user' {
        $yaml = (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') -Raw)
        $yaml = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    lcm_user:`n      username: `"svc-lcm`"`n      password: `"keyvault://kv-example-mgmt-01/lcm-password`"`n    domain_join_account:`n      username: `"svc-join`"`n      password: `"keyvault://kv-example-mgmt-01/svc-join-password`"`n")
        $file = Join-Path $TestDrive 'ad-override.yml'
        Set-Content -LiteralPath $file -Value $yaml
        $config = Read-AzlSonarConfig -InfrastructureFile $file 3>$null
        $config.logAccounts.domain.username | Should -Be 'svc-join'
        $config.logAccounts.domain.source | Should -Be 'domain_join_account'
        $config.logAccounts.domain.passwordRef | Should -Be 'keyvault://kv-example-mgmt-01/svc-join-password'
        $a = InModuleScope AzlSonar -Parameters @{ C = $config } { param($C) Get-AzlSonarLogAccount -Config $C -Node 'n' -DomainJoined $true -AdminsConfigured $true }
        $a.userName | Should -Be 'IIC\svc-join'
    }
    It 'the master file import reads identity.local_admin and identity.active_directory.domain_join_account, keeping only names and a keyvault reference' {
        $yaml = (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') -Raw)
        $yaml = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    domain_join_account:`n      username: `"svc-join`"`n      password: `"keyvault://kv-example-mgmt-01/svc-join-password`"`n")
        $file = Join-Path $TestDrive 'ad.yml'
        Set-Content -LiteralPath $file -Value $yaml
        $config = Read-AzlSonarConfig -InfrastructureFile $file 3>$null
        $config.logAccounts.local.username | Should -Be 'azl-admin'
        $config.logAccounts.domain.netbios | Should -Be 'IIC'
        $config.logAccounts.domain.username | Should -Be 'svc-join'
        $config.logAccounts.domain.passwordRef | Should -Be 'keyvault://kv-example-mgmt-01/svc-join-password'
    }
    It 'a master file with neither lcm_user nor domain_join_account still imports (read defensively): no domain account' {
        $config = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $config.logAccounts.local.username | Should -Be 'azl-admin'
        $config.logAccounts.domain.username | Should -Be ''
    }
    It 'a plain password written where the reference belongs is dropped on import' {
        $yaml = (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') -Raw)
        $yaml = $yaml -replace '(?m)^(    password: "keyvault://kv-example-mgmt-01/local-admin-password"\r?\n)', ('$1' + "  active_directory:`n    netbios_name: `"IIC`"`n    domain_join_account:`n      username: `"svc-join`"`n      password: `"Plain-Text-Pa55`"`n")
        $file = Join-Path $TestDrive 'ad-plain.yml'
        Set-Content -LiteralPath $file -Value $yaml
        $config = Read-AzlSonarConfig -InfrastructureFile $file 3>$null
        $config.logAccounts.domain.passwordRef | Should -Be ''
        ($config | ConvertTo-Json -Depth 8) | Should -Not -Match 'Plain-Text-Pa55'
    }
    It 'is documented in docs/config.md and docs/log-access.md' {
        $config = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/config.md') -Raw
        $log = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/log-access.md') -Raw
        $config | Should -Match 'identity\.active_directory\.domain_join_account'
        $config | Should -Match 'identity\.active_directory\.lcm_user'
        $config | Should -Match 'logAccounts'
        $log | Should -Match 'DomainJoined'
        $log | Should -Match 'DomainAdminsConfigured'
        $log | Should -Match 'lcm_user'
        $log | Should -Match 'domain_join_account'
    }
}
