#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The Get-AzKeyVaultSecret stub mirrors the real parameters.')]
param()
Set-StrictMode -Version Latest

# The cluster's own update service, read on one node (NodeUpdate.ps1), merged into the Azure update verdict (LiveTracks.ps1).
# Everything is mocked: the node answers with the JSON text of fixtures/node-update (the shape the remote script returns, taken
# from a live 12.2610 cluster with invented names, times and versions), Azure answers from fixtures. No node, no Azure, no secret.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:StubbedKeyVault = $false
    if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        $script:StubbedKeyVault = $true
        Set-Item -Path 'function:global:Get-AzKeyVaultSecret' -Value { [CmdletBinding()] param([string]$VaultName, [string]$Name, [string]$Version, [switch]$AsPlainText) throw 'Get-AzKeyVaultSecret stub called without a mock.' }
    }
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-11-09T05:21:00', [System.DateTimeKind]::Utc)
    function script:Get-NodeFx { param([string]$Name) Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures/node-update/$Name") -Raw }
    function script:Get-ParsedNodeFx { param([string]$Name) (Get-NodeFx $Name) | ConvertFrom-Json -Depth 64 }
    $script:ArmRoutes = [System.Collections.Generic.List[hashtable]]::new()
    function script:Add-Route { param([string]$Match, [object]$Response) $script:ArmRoutes.Add(@{ Match = $Match; Response = $Response }) }
    $script:ThreeNodes = @'
{
  "subscriptionId": "00000000-0000-0000-0000-000000000001",
  "resourceGroup": "rg-example-azl",
  "clusterName": "clus01",
  "identityModel": "ActiveDirectory",
  "nodes": [
    { "name": "iic-azl-n01", "address": "192.0.2.11", "seed": true },
    { "name": "iic-azl-n02", "address": "192.0.2.12" },
    { "name": "iic-azl-n03", "address": "192.0.2.13" }
  ],
  "credential": { "source": "prompt" },
  "monitor": "Update",
  "updateAccount": __ACCOUNT__
}
'@
    function script:New-UpdateConfig {
        param([string]$AccountJson = '{ "source": "parameter" }')
        $json = $script:ThreeNodes.Replace('__ACCOUNT__', $AccountJson)
        if ($AccountJson -eq 'none') { $json = $script:ThreeNodes -replace ',\s*"updateAccount":\s*__ACCOUNT__', '' }
        Read-AzlSonarConfig -Json $json
    }
    function script:New-FakeCredential { [pscredential]::new('svc-update@example.test', (ConvertTo-SecureString 'N0t-A-Real-Pa55' -AsPlainText -Force)) }
}

AfterAll {
    if ($script:StubbedKeyVault) { Remove-Item -LiteralPath 'Function:\Get-AzKeyVaultSecret' -ErrorAction SilentlyContinue }
}

Describe 'updateAccount in the config (names only, never a password)' {
    It 'is optional: without it the config is valid and the setting says it is not configured' {
        $cfg = New-UpdateConfig 'none'
        $cfg.updateAccount.configured | Should -BeFalse
    }

    It 'accepts a Key Vault account and a parameter account' {
        $kv = New-UpdateConfig '{ "source": "keyvault", "vault": "kv-example-01", "usernameSecret": "update-user", "passwordSecret": "update-password", "domain": "example.test" }'
        $kv.updateAccount.configured | Should -BeTrue
        $kv.updateAccount.source | Should -Be 'keyvault'
        $kv.updateAccount.vault | Should -Be 'kv-example-01'
        $kv.updateAccount.domain | Should -Be 'example.test'
        (New-UpdateConfig '{ "source": "parameter" }').updateAccount.source | Should -Be 'parameter'
        (New-UpdateConfig '{ "vault": "kv-example-01", "username": "svc-update@example.test", "passwordSecret": "update-password" }').updateAccount.source | Should -Be 'keyvault' -Because 'a vault makes keyvault the default source'
    }

    It 'reports what is wrong, naming the key and never echoing a value' -TestCases @(
        @{ Json = '{ "source": "keyvault" }'; Message = 'updateAccount.vault is required' }
        @{ Json = '{ "source": "keyvault", "vault": "kv-example-01", "passwordSecret": "p" }'; Message = 'updateAccount needs username or usernameSecret' }
        @{ Json = '{ "source": "magic" }'; Message = 'updateAccount.source must be keyvault or parameter' }
        @{ Json = '{ "source": "parameter", "domain": "not a domain" }'; Message = 'updateAccount.domain must be a domain name' }
        @{ Json = '{ "source": "parameter", "password": "Sup3r-Secret-Value" }'; Message = 'updateAccount.password is not allowed' }
        @{ Json = '{ "source": "parameter", "secretValue": "Sup3r-Secret-Value" }'; Message = 'updateAccount.secretValue is not allowed' }
        @{ Json = '{ "source": "keyvault", "vault": "-bad-", "passwordSecret": "p", "username": "u" }'; Message = 'Azure would not accept' }
    ) {
        $problems = Test-AzlSonarConfig -Config ($script:ThreeNodes.Replace('__ACCOUNT__', $Json) | ConvertFrom-Json)
        ($problems -join "`n") | Should -Match ([regex]::Escape($Message))
        ($problems -join "`n") | Should -Not -Match 'Sup3r-Secret-Value'
    }

    It 'is not part of the public config (/api/config)' {
        $cfg = New-UpdateConfig '{ "source": "keyvault", "vault": "kv-example-01", "usernameSecret": "update-user", "passwordSecret": "update-password" }'
        $public = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) ConvertTo-AzlSonarPublicConfig -Config $C -StartedAt ([datetime]::UtcNow) -ServerId 'x' | ConvertTo-Json -Depth 10 }
        $public | Should -Not -Match 'kv-example-01|update-user|update-password|updateAccount'
    }
}

Describe 'Resolve-AzlSonarUpdateCredential' {
    It 'is off, with the reason, when no account is set' {
        $r = InModuleScope AzlSonar -Parameters @{ C = (New-UpdateConfig 'none') } { param($C) Resolve-AzlSonarUpdateCredential -Config $C -Credential $null }
        $r.Status | Should -Be 'off'
        $r.Credential | Should -BeNullOrEmpty
        $r.Message | Should -Match 'Node-side update reading is off'
        $r.Message | Should -Match 'updateAccount'
        $r.Message | Should -Match '-UpdateCredential'
    }

    It 'is off when the source is parameter and -UpdateCredential was not given' {
        $r = InModuleScope AzlSonar -Parameters @{ C = (New-UpdateConfig) } { param($C) Resolve-AzlSonarUpdateCredential -Config $C -Credential $null }
        $r.Status | Should -Be 'off'
        $r.Message | Should -Match 'without -UpdateCredential'
    }

    It '-UpdateCredential is used as given' {
        $r = InModuleScope AzlSonar -Parameters @{ C = (New-UpdateConfig 'none'); K = (New-FakeCredential) } { param($C, $K) Resolve-AzlSonarUpdateCredential -Config $C -Credential $K }
        $r.Status | Should -Be 'ok'
        $r.UserName | Should -Be 'svc-update@example.test'
        $r.Source | Should -Be 'parameter'
    }

    It 'reads the user name and the password from Key Vault, qualifies a user name that has no domain, and keeps the password as a SecureString' {
        Mock -ModuleName AzlSonar -CommandName Get-AzKeyVaultSecret -MockWith {
            if ($Name -eq 'update-user') { return 'svc-update' }
            [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'N0t-A-Real-Pa55' -AsPlainText -Force); Version = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' }
        }
        $cfg = New-UpdateConfig '{ "source": "keyvault", "vault": "kv-example-01", "usernameSecret": "update-user", "passwordSecret": "update-password", "domain": "example.test" }'
        $r = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) Resolve-AzlSonarUpdateCredential -Config $C -Credential $null }
        $r.Status | Should -Be 'ok'
        $r.UserName | Should -Be 'svc-update@example.test'
        $r.Credential.Password | Should -BeOfType ([securestring])
        $r.Version | Should -Be 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 2 -Exactly
        ($r | Select-Object Status, UserName, Version, Message, Source | ConvertTo-Json) | Should -Not -Match 'N0t-A-Real'
    }

    It 'an account that cannot be read is "unavailable" with a message naming the vault and the secrets, never a value' {
        Mock -ModuleName AzlSonar -CommandName Get-AzKeyVaultSecret -MockWith { throw 'Forbidden: the caller does not have secrets get permission.' }
        $cfg = New-UpdateConfig '{ "source": "keyvault", "vault": "kv-example-01", "usernameSecret": "update-user", "passwordSecret": "update-password" }'
        $r = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) Resolve-AzlSonarUpdateCredential -Config $C -Credential $null }
        $r.Status | Should -Be 'unavailable'
        $r.Message | Should -Match "Key Vault 'kv-example-01'"
        $r.Message | Should -Match 'update-password'
        $r.Message | Should -Match 'tries again every 5 minutes'
    }
}

Describe 'The remote script only reads' {
    It 'calls only Get- cmdlets of the update service and the cluster, plus formatting' {
        $script = InModuleScope AzlSonar { (Get-AzlSonarNodeUpdateScript).ToString() }
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        $allowed = 'Get-SolutionUpdate', 'Get-SolutionUpdateRun', 'Get-SolutionUpdateEnvironment', 'Get-ClusterNode', 'Get-Command', 'Get-Word', 'Get-Time', 'Get-Limited', 'ConvertTo-Step', 'ConvertTo-Json', 'ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object'
        @($names | Where-Object { $_ -notin $allowed }) | Should -BeNullOrEmpty
        @($names | Where-Object { $_ -match '^(Start|Add|Remove|Set|New|Install|Invoke|Resume|Suspend|Stop|Restart|Update|Enable|Disable|Import|Register|Unregister)-' }) | Should -BeNullOrEmpty
    }

    It 'uses Invoke-Command, Negotiate and a short open timeout, with the update account, on one node at a time' {
        $text = Get-Content -LiteralPath (Join-Path $script:SonarModuleRoot 'Private/NodeUpdate.ps1') -Raw
        $text | Should -Match 'Invoke-Command -ComputerName \$Address -Credential \$Credential -Authentication Negotiate'
        $text | Should -Match 'New-PSSessionOption -OpenTimeout'
    }
}

Describe 'ConvertTo-AzlSonarLocalUpdate: what the cluster says, state by state' {
    BeforeAll {
        function script:Convert-Local {
            param([string]$Fixture, [datetime]$At = $script:Now)
            InModuleScope AzlSonar -Parameters @{ R = (Get-ParsedNodeFx $Fixture); N = $At } { param($R, $N) ConvertTo-AzlSonarLocalUpdate -Raw $R -Node 'iic-azl-n01' -Now $N }
        }
    }

    It 'Ready: an update waits, nothing started' {
        $l = Convert-Local 'ready.json'
        $l.status | Should -Be 'notstarted'
        $l.phase | Should -Be 'available'
        $l.label | Should -Be 'Update available'
        $l.state | Should -Be 'Ready'
        $l.run | Should -BeNullOrEmpty
        @($l.nodes).Count | Should -Be 3
        @($l.nodes | ForEach-Object { $_.role }) | Should -Be @('up', 'up', 'up')
    }

    It 'Preparing: running, the first step runs' {
        $l = Convert-Local 'preparing.json'
        $l.status | Should -Be 'running'
        $l.phase | Should -Be 'preparing'
        $l.level | Should -Be 'run'
        $l.run.status | Should -Be 'running'
        $l.progress.current | Should -Be 'Stage hardware update files'
    }

    It 'HealthChecking: running, "Checking update health"' {
        $l = Convert-Local 'healthchecking.json'
        $l.status | Should -Be 'running'
        $l.phase | Should -Be 'preparing'
        $l.label | Should -Be 'Checking update health'
        $l.state | Should -Be 'HealthChecking'
        $l.stateWord | Should -Be 'Checking health'
    }

    It 'Installing with node 2 Paused: the node timeline says which machine is drained and patched' {
        $l = Convert-Local 'installing-paused.json'
        $l.status | Should -Be 'running'
        $l.phase | Should -Be 'installing'
        $l.label | Should -Be 'Installing 5.0.2609.1611'
        $n = @{}; foreach ($x in $l.nodes) { $n[$x.name] = $x }
        $n['iic-azl-n01'].role | Should -Be 'done'
        $n['iic-azl-n02'].state | Should -Be 'Paused'
        $n['iic-azl-n02'].role | Should -Be 'patching'
        $n['iic-azl-n02'].word | Should -Be 'Paused: drained and being patched'
        $n['iic-azl-n02'].step | Should -Be 'Install CAU Updates'
        $n['iic-azl-n02'].stepStatus | Should -Be 'running'
        $n['iic-azl-n03'].role | Should -Be 'waiting'
        @($n['iic-azl-n01'].timeline).Count | Should -BeGreaterThan 0
        $n['iic-azl-n01'].timeline[0].name | Should -Not -Match 'iic-azl-n01' -Because 'the node name is not repeated in each step of its own timeline'
        $l.run.status | Should -Be 'running'
        $l.progress.total | Should -BeGreaterThan $l.progress.done
    }

    It 'a node that is Down while the run is active is restarting; Joining is rejoining' {
        $raw = Get-ParsedNodeFx 'installing-paused.json'
        $raw.clusterNodes[1].state = 'Down'
        $raw.clusterNodes[2].state = 'Joining'
        $l = InModuleScope AzlSonar -Parameters @{ R = $raw; N = $script:Now } { param($R, $N) ConvertTo-AzlSonarLocalUpdate -Raw $R -Now $N }
        @($l.nodes | Where-Object { $_.name -eq 'iic-azl-n02' })[0].role | Should -Be 'restarting'
        @($l.nodes | Where-Object { $_.name -eq 'iic-azl-n03' })[0].role | Should -Be 'rejoining'
    }

    It 'a failed step is named, with the node and its error text' {
        $l = Convert-Local 'failed.json'
        $l.status | Should -Be 'error'
        $l.phase | Should -Be 'failed'
        $l.level | Should -Be 'error'
        $l.state | Should -Be 'InstallationFailed'
        $l.failed.name | Should -Be '[SBE Partner] Install CAU Updates iic-azl-n02'
        $l.failed.node | Should -Be 'iic-azl-n02'
        $l.failed.error | Should -Be 'Install failed on iic-azl-n02: the hardware update package returned exit code 1603.'
        (@($l.nodes | Where-Object { $_.name -eq 'iic-azl-n02' })[0]).role | Should -Be 'failed'
        ($l.events | Where-Object { $_.kind -eq 'failed' }).text | Should -Match "failed on the cluster at '\[SBE Partner\] Install CAU Updates iic-azl-n02' on iic-azl-n02"
        $l.run.status | Should -Be 'error'
    }

    It 'Installed: the run Succeeded, so "Update succeeded", with the duration, the events and the versions' {
        $l = Convert-Local 'installed.json' ([datetime]::SpecifyKind([datetime]'2026-11-09T08:25:00', [System.DateTimeKind]::Utc))
        $l.status | Should -Be 'success'
        $l.phase | Should -Be 'idle'
        $l.level | Should -Be 'ok'
        $l.label | Should -Be 'Update succeeded (12.2610.1004.50)'
        $l.run.status | Should -Be 'success'
        $l.run.durationSeconds | Should -Be 11779
        $l.run.duration | Should -Be '03:16:19'
        $l.run.started | Should -Be '2026-11-09T05:03:34Z'
        @($l.events | ForEach-Object { $_.kind }) | Should -Be @('started', 'finished')
        $l.events[1].text | Should -Match 'succeeded after 03:16:19'
        $l.versions.after.sbe | Should -Be '5.0.2609.1611'
        $l.versions.after.known | Should -BeTrue
        $l.versions.before.known | Should -BeFalse -Because 'Sonar did not watch before the run, so it does not claim to know the old version'
        @($l.history).Count | Should -Be 1
        @($l.nodes | ForEach-Object { $_.role }) | Should -Be @('done', 'done', 'done')
    }

    It 'the readiness checks come from the cluster and keep their severity (Informational does not colour the tab)' {
        $l = Convert-Local 'ready.json'
        $l.summary.checkCounts.informational | Should -Be 2
        $l.summary.checkCounts.critical | Should -Be 0
        $l.summary.checkCounts.total | Should -Be 3
        $l.level | Should -Be 'neutral'
    }

    It 'carries no account name and no secret' {
        $json = (Convert-Local 'installing-paused.json') | ConvertTo-Json -Depth 20
        $json | Should -Not -Match 'svc-update|N0t-A-Real|password'
    }
}

Describe 'Get-AzlSonarUpdateState: the cluster against Azure' {
    BeforeAll {
        $script:NodeAnswers = @{}
        $script:NodeCalls = [System.Collections.Generic.List[string]]::new()
    }
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:NodeCalls.Clear()
        $script:NodeAnswers = @{ '192.0.2.11' = (Get-NodeFx 'healthchecking.json'); '192.0.2.12' = (Get-NodeFx 'healthchecking.json'); '192.0.2.13' = (Get-NodeFx 'healthchecking.json') }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzlSonarNodeUpdateCommand -MockWith {
            $script:NodeCalls.Add($Address)
            $answer = $script:NodeAnswers[$Address]
            if ($answer -is [string] -and $answer.StartsWith('throw:')) { throw $answer.Substring(6) }
            return $answer
        }
        # Azure still says the update is Ready (what it said for 17 minutes on 9 Nov 2026).
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-NodeFx 'azure-summary-available.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-NodeFx 'azure-updates-ready.json'))
        $script:Cfg = New-UpdateConfig
        function script:Get-Merged {
            param([datetime]$At = $script:Now, [hashtable]$Context)
            if (-not $Context) { $Context = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $Context['ParameterCredential'] = New-FakeCredential }
            InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $At; X = $Context } { param($C, $N, $X) Get-AzlSonarUpdateState -Config $C -Now $N -UpdateContext $X }
        }
    }

    It 'Azure says Ready, the cluster says Ready: they agree, nothing is flagged' {
        $script:NodeAnswers = @{ '192.0.2.11' = (Get-NodeFx 'ready.json') }
        $u = Get-Merged
        $u.status | Should -Be 'notstarted'
        $u.phase | Should -Be 'available'
        $u.label | Should -Be 'Update available'
        $u.sources.agree | Should -BeTrue
        $u.sources.winner | Should -Be 'cluster'
        $u.sources.lagMinutes | Should -BeNullOrEmpty
        $u.sources.message | Should -BeNullOrEmpty
        $u.local.read | Should -BeTrue
        $u.local.node | Should -Be 'iic-azl-n01'
    }

    It 'the failing case: HealthChecking on the cluster while Azure says Ready is running, and Azure is flagged as 17 minutes behind' {
        $u = Get-Merged
        $u.status | Should -Be 'running'
        $u.phase | Should -Be 'preparing'
        $u.level | Should -Be 'run'
        $u.label | Should -Be 'Checking update health'
        $u.sources.winner | Should -Be 'cluster'
        $u.sources.agree | Should -BeFalse
        $u.sources.azure.status | Should -Be 'notstarted'
        $u.sources.azure.state | Should -Be 'UpdateAvailable' -Because 'the Azure side is kept and shown, not hidden'
        $u.sources.azure.label | Should -Be 'Update available'
        $u.sources.cluster.label | Should -Be 'Checking update health'
        $u.sources.lagMinutes | Should -Be 17
        $u.sources.lagBasis | Should -Be 'run'
        $u.sources.message | Should -Match '^Azure is behind the cluster by 17 minutes\.'
        $u.sources.message | Should -Match 'The cluster says: Checking update health\. Azure still says: Update available\.'
        $u.run.source | Should -Be 'cluster'
        $u.run.status | Should -Be 'running'
        @($u.tree).Count | Should -BeGreaterThan 0
        $u.ran | Should -BeTrue
        @($u.runs).Count | Should -Be 1
        $u.runs[0].source | Should -Be 'cluster'
    }

    It 'the phase follows the cluster, so the page goes to the Update view at once' {
        $u = Get-Merged
        $move = InModuleScope AzlSonar -Parameters @{ U = $u } { param($U) Resolve-AzlSonarUpdatePhase -Update $U -Phase 'done' -ActivePhase 'done' }
        $move.phase | Should -Be 'update'
        $move.follow | Should -BeTrue
    }

    It 'Installing with node 2 Paused: running, the machines and their roles come from the cluster' {
        $script:NodeAnswers = @{ '192.0.2.11' = (Get-NodeFx 'installing-paused.json') }
        $u = Get-Merged ([datetime]::SpecifyKind([datetime]'2026-11-09T06:40:00', [System.DateTimeKind]::Utc))
        $u.status | Should -Be 'running'
        $u.phase | Should -Be 'installing'
        $u.label | Should -Be 'Installing 5.0.2609.1611'
        $u.active.state | Should -Be 'Installing'
        $u.updates[0].state | Should -Be 'Installing' -Because 'when the cluster wins, the offered updates are the cluster''s'
        (@($u.local.nodes | Where-Object { $_.name -eq 'iic-azl-n02' })[0]).state | Should -Be 'Paused'
        $u.sources.lagMinutes | Should -Be 96
    }

    It 'a failed step shows its error text and the update is an error' {
        $script:NodeAnswers = @{ '192.0.2.11' = (Get-NodeFx 'failed.json') }
        $u = Get-Merged ([datetime]::SpecifyKind([datetime]'2026-11-09T06:45:00', [System.DateTimeKind]::Utc))
        $u.status | Should -Be 'error'
        $u.phase | Should -Be 'failed'
        $u.level | Should -Be 'error'
        $u.label | Should -Be 'Update failed'
        $u.local.failed.error | Should -Match 'exit code 1603'
        $u.sources.winner | Should -Be 'cluster'
        $u.sources.message | Should -Match '^Azure is behind the cluster by 6 minutes\.'
    }

    It 'a run that Succeeded on the cluster is "Update succeeded" even when Azure still says Ready' {
        $script:NodeAnswers = @{ '192.0.2.11' = (Get-NodeFx 'installed.json') }
        $u = Get-Merged ([datetime]::SpecifyKind([datetime]'2026-11-09T08:25:00', [System.DateTimeKind]::Utc))
        $u.status | Should -Be 'success'
        $u.phase | Should -Be 'idle'
        $u.level | Should -Be 'ok'
        $u.label | Should -Be 'Update succeeded (12.2610.1004.50)'
        $u.sources.azure.label | Should -Be 'Update available'
        $u.sources.lagMinutes | Should -Be 5
        $u.sources.lagSince | Should -Be '2026-11-09T08:19:53Z'
        $u.sources.message | Should -Match 'Azure is behind the cluster by 5 minutes'
        $u.nextAction | Should -BeNullOrEmpty -Because 'the "start the update from Azure" hint is Azure''s stale answer'
        $u.updates[0].state | Should -Be 'Installed'
    }

    It 'the poll after a finished run keeps saying so (the same answer is not an event)' {
        $script:NodeAnswers = @{ '192.0.2.11' = (Get-NodeFx 'installed.json') }
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
        $first = Get-Merged ([datetime]::SpecifyKind([datetime]'2026-11-09T08:25:00', [System.DateTimeKind]::Utc)) $ctx
        $second = Get-Merged ([datetime]::SpecifyKind([datetime]'2026-11-09T08:25:20', [System.DateTimeKind]::Utc)) $ctx
        $first.status | Should -Be 'success'
        $second.status | Should -Be 'success'
        $script:NodeCalls.Count | Should -Be 1 -Because 'an idle cluster is read at most every 30 seconds; the last good read is shown in between'
    }

    It 'the state JSON carries no password and no account name' {
        $u = Get-Merged
        $json = InModuleScope AzlSonar -Parameters @{ U = $u } { param($U) ConvertTo-AzlSonarJson $U }
        $json | Should -Not -Match 'N0t-A-Real|svc-update'
    }

    Context 'a node that does not answer (it restarts during an update)' {
        It 'falls back to the next node and says so; that is not an error' {
            $script:NodeAnswers['192.0.2.11'] = 'throw:Connecting to remote server 192.0.2.11 failed with the following error message : WinRM cannot complete the operation. Verify that the specified computer name is valid.'
            $script:NodeAnswers['192.0.2.12'] = (Get-NodeFx 'installing-paused.json')
            $u = Get-Merged
            @($script:NodeCalls) | Should -Be @('192.0.2.11', '192.0.2.12')
            $u.local.read | Should -BeTrue
            $u.local.stale | Should -BeFalse
            $u.local.node | Should -Be 'iic-azl-n02'
            $u.local.nodeNote | Should -Match 'iic-azl-n01 did not answer, so iic-azl-n02 was read'
            $u.local.nodeNote | Should -Match 'normal'
            @($u.local.attempts | ForEach-Object { $_.class }) | Should -Be @('unreachable', 'ok')
            $u.sources.winner | Should -Be 'cluster'
        }

        It 'tries the node that answered last first' {
            $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
            $script:NodeAnswers['192.0.2.11'] = 'throw:WinRM cannot complete the operation.'
            $script:NodeAnswers['192.0.2.12'] = (Get-NodeFx 'installing-paused.json')
            $null = Get-Merged $script:Now $ctx
            $script:NodeCalls.Clear()
            $null = Get-Merged $script:Now.AddSeconds(30) $ctx
            @($script:NodeCalls)[0] | Should -Be '192.0.2.12'
        }

        It 'all nodes silent: shows the last good answer, marked stale, with the reason; once it is too old Azure alone speaks' {
            $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
            $good = Get-Merged $script:Now $ctx
            $good.local.read | Should -BeTrue
            foreach ($a in '192.0.2.11', '192.0.2.12', '192.0.2.13') { $script:NodeAnswers[$a] = 'throw:WinRM cannot complete the operation.' }
            $later = Get-Merged $script:Now.AddSeconds(40) $ctx
            $later.local.read | Should -BeTrue
            $later.local.stale | Should -BeTrue
            $later.local.reasonKind | Should -Be 'unreachable'
            $later.local.reason | Should -Match 'probably restarting'
            $later.local.reason | Should -Match 'last answer from 2026-11-09T05:21:00Z'
            $later.status | Should -Be 'running' -Because 'the cluster''s last answer still beats Azure''s stale one'
            $gone = Get-Merged $script:Now.AddMinutes(11) $ctx
            $gone.local.read | Should -BeFalse
            $gone.local.stale | Should -BeFalse
            $gone.status | Should -Be 'notstarted' -Because 'Azure alone speaks again'
            $gone.sources.winner | Should -Be 'azure'
            $gone.sources.message | Should -Match 'No node answered'
        }

        It 'a node without the update module is skipped like a silent one' {
            $script:NodeAnswers['192.0.2.11'] = (Get-NodeFx 'no-module.json')
            $script:NodeAnswers['192.0.2.12'] = (Get-NodeFx 'healthchecking.json')
            $u = Get-Merged
            $u.local.node | Should -Be 'iic-azl-n02'
            $u.local.nodeNote | Should -Match 'has no Azure Local update module'
        }
    }

    Context 'the update account' {
        It 'without an account Sonar stays Azure-only, says why, and touches no node' {
            $script:Cfg = New-UpdateConfig 'none'
            $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }
            $u = Get-Merged $script:Now $ctx
            $script:NodeCalls.Count | Should -Be 0
            $u.local.enabled | Should -BeFalse
            $u.local.read | Should -BeFalse
            $u.local.reasonKind | Should -Be 'off'
            $u.local.reason | Should -Match 'Node-side update reading is off'
            $u.sources.winner | Should -Be 'azure'
            $u.sources.message | Should -Match 'Node-side update reading is off'
            $u.status | Should -Be 'notstarted' -Because 'this is today''s Azure-only answer'
            $u.label | Should -Be 'Update available'
        }

        It 'a Key Vault account that cannot be read is Azure-only with the reason, and Sonar asks again after 5 minutes' {
            Mock -ModuleName AzlSonar -CommandName Get-AzKeyVaultSecret -MockWith { throw 'Forbidden' }
            $script:Cfg = New-UpdateConfig '{ "source": "keyvault", "vault": "kv-example-01", "username": "svc-update@example.test", "passwordSecret": "update-password" }'
            $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }
            $u = Get-Merged $script:Now $ctx
            $u.local.enabled | Should -BeFalse
            $u.local.reasonKind | Should -Be 'unavailable'
            $u.local.reason | Should -Match "Key Vault 'kv-example-01'"
            $null = Get-Merged $script:Now.AddMinutes(1) $ctx
            Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 1 -Exactly
            $null = Get-Merged $script:Now.AddMinutes(6) $ctx
            Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSonar -Times 2 -Exactly
            $script:NodeCalls.Count | Should -Be 0
        }

        It 'a rejected account is not tried on the other nodes, and is not tried again for a while' {
            foreach ($a in '192.0.2.11', '192.0.2.12', '192.0.2.13') { $script:NodeAnswers[$a] = 'throw:Connecting to remote server failed with the following error message : Access is denied.' }
            $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
            $u = Get-Merged $script:Now $ctx
            @($script:NodeCalls) | Should -Be @('192.0.2.11') -Because 'the same account fails on every node and every try counts at the domain'
            $u.local.read | Should -BeFalse
            $u.local.reasonKind | Should -Be 'credential'
            $u.local.reason | Should -Match 'refused the update account'
            $u.local.reason | Should -Match 'tries once more at 2026-11-09T05:36:00Z'
            $script:NodeCalls.Clear()
            $null = Get-Merged $script:Now.AddMinutes(5) $ctx
            $script:NodeCalls.Count | Should -Be 0 -Because 'inside the back-off'
            $second = Get-Merged $script:Now.AddMinutes(16) $ctx
            @($script:NodeCalls) | Should -Be @('192.0.2.11')
            $second.local.reason | Should -Match 'will not try the account again until Sonar restarts or the password secret changes'
            $script:NodeCalls.Clear()
            $null = Get-Merged $script:Now.AddHours(5) $ctx
            $script:NodeCalls.Count | Should -Be 0 -Because 'the second rejection latches the breaker'
        }

        It 'a locked-out account latches at once' {
            $script:NodeAnswers['192.0.2.11'] = 'throw:The referenced account is currently locked out and may not be logged on to.'
            $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
            $null = Get-Merged $script:Now $ctx
            $script:NodeCalls.Clear()
            $u = Get-Merged $script:Now.AddHours(1) $ctx
            $script:NodeCalls.Count | Should -Be 0
            $u.local.reason | Should -Match 'not usable'
        }
    }
}

Describe 'Merge-AzlSonarUpdateSource' {
    It 'with the cluster not read, the Azure verdict is untouched and the sources say why' {
        $azure = [ordered]@{ status = 'notstarted'; phase = 'available'; label = 'Update available'; level = 'neutral'; summary = $null; updates = @(); runs = @(); run = $null; tree = @(); active = $null }
        $local = InModuleScope AzlSonar { Get-AzlSonarEmptyLocalUpdate -Enabled $false -Reason 'Node-side update reading is off. x' -ReasonKind 'off' }
        $m = InModuleScope AzlSonar -Parameters @{ A = $azure; L = $local; N = $script:Now } { param($A, $L, $N) Merge-AzlSonarUpdateSource -Azure $A -Local $L -Now $N }
        $m.label | Should -Be 'Update available'
        $m.sources.winner | Should -Be 'azure'
        $m.sources.message | Should -Be 'Node-side update reading is off. x'
        $m.local.enabled | Should -BeFalse
    }

    It 'both running, but Azure''s newest step is 8 minutes older than the cluster''s: flagged, the cluster''s steps are shown' {
        $local = InModuleScope AzlSonar -Parameters @{ R = (Get-ParsedNodeFx 'installing-paused.json'); N = $script:Now.AddHours(1) } { param($R, $N) ConvertTo-AzlSonarLocalUpdate -Raw $R -Now $N }
        $azure = [ordered]@{
            status = 'running'; phase = 'installing'; label = 'Installing 5.0.2609.1611'; level = 'run'; summary = $null; updates = @(); runs = @(); tree = @(); active = $null
            run = [ordered]@{ name = 'azure-run'; update = 'SBE5.0.2609.1611'; status = 'running'; timeStarted = '2026-11-09T05:03:34Z'; duration = ''; lastUpdated = '2026-11-09T06:20:00Z' }
        }
        $local.run.lastUpdated = '2026-11-09T06:28:30Z'
        $m = InModuleScope AzlSonar -Parameters @{ A = $azure; L = $local; N = $script:Now.AddHours(1) } { param($A, $L, $N) Merge-AzlSonarUpdateSource -Azure $A -Local $L -Now $N }
        $m.sources.agree | Should -BeTrue
        $m.sources.lagMinutes | Should -Be 8
        $m.sources.message | Should -Match 'Both say the update is running'
        $m.run.source | Should -Be 'cluster'
    }
}

Describe 'The timeline keeps a snapshot only when something real changed' {
    It 'two states that differ only in readAt, ageSeconds and lagMinutes are one snapshot' {
        $shared = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $a = [ordered]@{ update = [ordered]@{ label = 'x'; local = [ordered]@{ readAt = '2026-11-09T05:21:00Z'; ageSeconds = 0 }; sources = [ordered]@{ lagMinutes = 3 } }; polledAt = '2026-11-09T05:21:00Z' }
        $b = [ordered]@{ update = [ordered]@{ label = 'x'; local = [ordered]@{ readAt = '2026-11-09T05:21:20Z'; ageSeconds = 20 }; sources = [ordered]@{ lagMinutes = 4 } }; polledAt = '2026-11-09T05:21:20Z' }
        $c = [ordered]@{ update = [ordered]@{ label = 'y'; local = [ordered]@{ readAt = '2026-11-09T05:21:40Z'; ageSeconds = 0 }; sources = [ordered]@{ lagMinutes = 4 } }; polledAt = '2026-11-09T05:21:40Z' }
        InModuleScope AzlSonar -Parameters @{ S = $shared; A = $a; B = $b; C = $c } { param($S, $A, $B, $C) Publish-AzlSonarState -Shared $S -State $A; Publish-AzlSonarState -Shared $S -State $B; Publish-AzlSonarState -Shared $S -State $C }
        $shared.Timeline.Count | Should -Be 2
    }
}

Describe 'Standalone: -Monitor Update with no deployment data at all' {
    It 'reads the cluster itself and lands on the update, with no deployment settings, edge machines or event files' {
        $script:ArmRoutes.Clear()
        $calls = [System.Collections.Generic.List[string]]::new()
        $script:ArmCalls2 = $calls
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls2.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzlSonarNodeUpdateCommand -MockWith { return (Get-NodeFx 'healthchecking.json') }
        Add-Route 'clusters/clus01\?api-version' (New-SonarArmResponse 404 $null)
        Add-Route 'HybridCompute/machines/' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Connected'; lastStatusChange = '2026-11-09T04:00:00Z'; agentVersion = '1.50' } }))
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-NodeFx 'azure-summary-available.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-NodeFx 'azure-updates-ready.json'))
        $cfg = New-UpdateConfig
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now $script:Now -UpdateContext $ctx
        @($calls | Where-Object { $_ -match 'deploymentSettings|edgeMachines|Microsoft.Resources/deployments' }).Count | Should -Be 0
        $state.phase | Should -Be 'update'
        $state.update.status | Should -Be 'running'
        $state.update.label | Should -Be 'Checking update health'
        $state.update.sources.lagMinutes | Should -Be 17
        $state.current.stepName | Should -Be 'Finalize SBE preparation'
        $state.pollError | Should -BeNullOrEmpty
    }

    It 'with the cluster resource and Azure update data both missing, the cluster alone still speaks' {
        $script:ArmRoutes.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzlSonarNodeUpdateCommand -MockWith { return (Get-NodeFx 'installing-paused.json') }
        Add-Route 'clusters/clus01\?api-version' (New-SonarArmResponse 404 $null)
        Add-Route 'HybridCompute/machines/' (New-SonarArmResponse 404 $null)
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 404 $null)
        $cfg = New-UpdateConfig
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now ([datetime]::SpecifyKind([datetime]'2026-11-09T06:40:00', [System.DateTimeKind]::Utc)) -UpdateContext $ctx
        $state.update.status | Should -Be 'running'
        $state.update.label | Should -Be 'Installing 5.0.2609.1611'
        $state.update.summary.currentVersion | Should -Be '12.2610.1004.50' -Because 'with no Azure summary the cluster''s summary fills in'
    }
}

Describe '/api/export carries the reading of the cluster and the comparison with Azure' {
    It 'Get-AzlSonarExportUpdateJson: sources, local (without the step tree), history and events of the latest state' {
        $script:ArmRoutes.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzlSonarNodeUpdateCommand -MockWith { return (Get-NodeFx 'installed.json') }
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-NodeFx 'azure-summary-available.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-NodeFx 'azure-updates-ready.json'))
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
        $cfg = New-UpdateConfig
        $at = [datetime]::SpecifyKind([datetime]'2026-11-09T08:25:00', [System.DateTimeKind]::Utc)
        $json = InModuleScope AzlSonar -Parameters @{ C = $cfg; N = $at; X = $ctx } {
            param($C, $N, $X)
            $update = Get-AzlSonarUpdateState -Config $C -Now $N -UpdateContext $X
            $stateJson = ConvertTo-AzlSonarJson ([ordered]@{ phase = 'update'; update = $update })
            Get-AzlSonarExportUpdateJson -StateJson $stateJson
        }
        $e = $json | ConvertFrom-Json -Depth 64
        $e.sources.winner | Should -Be 'cluster'
        $e.sources.lagMinutes | Should -Be 5
        $e.local.status | Should -Be 'success'
        $e.local.PSObject.Properties.Name | Should -Not -Contain 'tree'
        $e.local.PSObject.Properties.Name | Should -Not -Contain 'history'
        @($e.history).Count | Should -Be 1
        $e.history[0].duration | Should -Be '03:16:19'
        @($e.events | ForEach-Object { $_.kind }) | Should -Be @('started', 'finished')
        $json | Should -Not -Match 'N0t-A-Real|svc-update'
    }

    It 'is null when the state has no update object or no cluster reading' {
        InModuleScope AzlSonar { Get-AzlSonarExportUpdateJson -StateJson '{"phase":"validation","update":null}' } | Should -Be 'null'
        InModuleScope AzlSonar { Get-AzlSonarExportUpdateJson -StateJson '{"phase":"update","update":{"label":"x"}}' } | Should -Be 'null'
        InModuleScope AzlSonar { Get-AzlSonarExportUpdateJson -StateJson 'null' } | Should -Be 'null'
    }
}

Describe 'The background reader keeps node reads off the Azure poll' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:BgCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzlSonarNodeUpdateCommand -MockWith { $script:BgCalls.Add($Address); return (Get-NodeFx 'healthchecking.json') }
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-NodeFx 'azure-summary-available.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-NodeFx 'azure-updates-ready.json'))
    }

    It 'the poll takes the reader''s latest record without reading a node, and asks for the update track' {
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential; $ctx['Background'] = $true
        $cfg = New-UpdateConfig
        $first = InModuleScope AzlSonar -Parameters @{ C = $cfg; N = $script:Now; X = $ctx } { param($C, $N, $X) Get-AzlSonarUpdateState -Config $C -Now $N -UpdateContext $X }
        $script:BgCalls.Count | Should -Be 0
        $first.local.read | Should -BeFalse
        $first.local.reasonKind | Should -Be 'pending'
        $ctx['WantedAt'] | Should -Be $script:Now
        $local = InModuleScope AzlSonar -Parameters @{ C = $cfg; N = $script:Now; X = $ctx } { param($C, $N, $X) Get-AzlSonarLocalUpdateState -Config $C -Context $X -Now $N }
        $ctx['Latest'] = $local
        $second = InModuleScope AzlSonar -Parameters @{ C = $cfg; N = $script:Now; X = $ctx } { param($C, $N, $X) Get-AzlSonarUpdateState -Config $C -Now $N -UpdateContext $X }
        $second.label | Should -Be 'Checking update health'
        $script:BgCalls.Count | Should -Be 1 -Because 'only the explicit read above touched a node'
    }

    It 'the reader reads nothing until the poller asks for the update track (a deployment in progress is never read)' {
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
        $shared = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $shared['UpdateLocal'] = $ctx
        InModuleScope AzlSonar -Parameters @{ S = $shared; C = (New-UpdateConfig) } { param($S, $C) Invoke-AzlSonarUpdateReaderLoop -Shared $S -Config $C }
        $script:BgCalls.Count | Should -Be 0
        $ctx['Latest'] | Should -BeNullOrEmpty
    }

    It 'once asked, the reader reads and keeps the record for the poll' {
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
        $ctx['WantedAt'] = [datetime]::UtcNow
        $shared = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $shared['UpdateLocal'] = $ctx
        InModuleScope AzlSonar -Parameters @{ S = $shared; C = (New-UpdateConfig) } { param($S, $C) Invoke-AzlSonarUpdateReaderLoop -Shared $S -Config $C }
        $script:BgCalls.Count | Should -Be 1
        $ctx['Latest'].read | Should -BeTrue
        $ctx['Latest'].status | Should -Be 'running'
    }

    It 'a node named by IP address that WinRM refuses without TrustedHosts is explained, not hidden' {
        $ctx = InModuleScope AzlSonar { New-AzlSonarUpdateContext }; $ctx['ParameterCredential'] = New-FakeCredential
        Mock -ModuleName AzlSonar -CommandName Invoke-AzlSonarNodeUpdateCommand -MockWith { throw 'The WinRM client cannot process the request. If the authentication scheme is different from Kerberos, the destination machine must be added to the TrustedHosts configuration setting.' }
        $l = InModuleScope AzlSonar -Parameters @{ C = (New-UpdateConfig); N = $script:Now; X = $ctx } { param($C, $N, $X) Get-AzlSonarLocalUpdateState -Config $C -Context $X -Now $N }
        $l.read | Should -BeFalse
        $l.reason | Should -Match 'use its host name or add it to TrustedHosts'
    }
}
