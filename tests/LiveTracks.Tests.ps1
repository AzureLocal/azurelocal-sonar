#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Hardening 2610, gaps 4 and 5: Azure lag and the Environment Checker stage (S-14), and the update track (S-13).
# Everything is mocked: ARM answers come from fixtures, the node log is a list of invented lines. The update track is
# built from the Learn REST/template reference only ("unverified against a live run").

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-10-11T18:35:00', [System.DateTimeKind]::Utc)
    function script:Get-Fx { param([string]$Name) Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures/$Name") -Raw }

    $script:ArmRoutes = [System.Collections.Generic.List[hashtable]]::new()
    $script:ArmCalls = [System.Collections.Generic.List[string]]::new()
    function script:Add-Route { param([string]$Match, [object]$Response) $script:ArmRoutes.Add(@{ Match = $Match; Response = $Response }) }

    function script:New-LogLine {
        param([string]$File, [string]$Text, [string]$Time = '2026-10-11T18:34:30Z')
        [ordered]@{ seq = 1; time = $Time; received = $Time; timeSource = 'log'; file = "C:\CloudDeployment\Logs\$File"; level = 'info'; text = $Text }
    }
}

Describe 'Get-AzlSonarLogHintFromLine' {
    It 'reads the role:interface that runs now from the orchestrator log and the file it came from' {
        $lines = @(
            New-LogLine 'CloudDeployment.2026-10-11.14-31-29.0.log' '2026-10-11 18:34:10 Verbose  [BareMetal:SetPrerequisitesForDeployment] Starting'
            New-LogLine 'CloudDeployment.2026-10-11.14-31-29.0.log' '2026-10-11 18:34:28 Verbose  [BareMetal:EnableWindowsFeaturesForDeployment] Starting'
            New-LogLine 'Other.log' 'no fragment here [x]'
        )
        $hint = InModuleScope AzlSonar -Parameters @{ L = $lines } { param($L) Get-AzlSonarLogHintFromLine -Line $L }
        $hint.roleInterface | Should -Be 'BareMetal:EnableWindowsFeaturesForDeployment'
        $hint.role | Should -Be 'BareMetal'
        $hint.deployActive | Should -BeTrue
        $hint.file | Should -Match '^CloudDeployment'
    }

    It 'tells the limited from the full Environment Checker by the file name' {
        $limited = InModuleScope AzlSonar -Parameters @{ L = @(New-LogLine 'AzStackHciEnvironmentChecker.log' 'Running tests') } { param($L) Get-AzlSonarLogHintFromLine -Line $L }
        $limited.limitedSeen | Should -BeTrue
        $limited.fullSeen | Should -BeFalse
        $full = InModuleScope AzlSonar -Parameters @{ L = @(New-LogLine 'EnvironmentValidatorFull.2026-10-11.14-07-47.0.log' 'Running tests') } { param($L) Get-AzlSonarLogHintFromLine -Line $L }
        $full.fullSeen | Should -BeTrue
    }

    It 'an empty log gives an empty hint' {
        $hint = InModuleScope AzlSonar { Get-AzlSonarLogHintFromLine -Line @() }
        $hint.roleInterface | Should -BeNullOrEmpty
        $hint.deployActive | Should -BeFalse
    }
}

Describe 'Get-AzlSonarEnvironmentCheckerStage (limited, then full, then cloud deployment)' {
    It 'says what Deploy mode does first when Azure has no step and the log has not shown a checker yet' {
        $r = InModuleScope AzlSonar { Get-AzlSonarEnvironmentCheckerStage -Mode 'Deploy' -DeploymentTree @() -ProvisioningState 'Accepted' -LogHint $null }
        $r.stage | Should -Be 'starting'
        $r.label | Should -Match 'limited Environment Checker run, then a full one, then cloud deployment'
        $r.source | Should -Be 'Learn'
    }

    It 'follows the node log: limited, then full, then cloud deployment' -TestCases @(
        @{ Hint = @{ limitedSeen = $true; fullSeen = $false; deployActive = $false }; Stage = 'limited' }
        @{ Hint = @{ limitedSeen = $true; fullSeen = $true; deployActive = $false }; Stage = 'full' }
        @{ Hint = @{ limitedSeen = $true; fullSeen = $true; deployActive = $true }; Stage = 'cloud-deployment' }
    ) {
        $r = InModuleScope AzlSonar -Parameters @{ H = $Hint } { param($H) Get-AzlSonarEnvironmentCheckerStage -Mode 'Deploy' -DeploymentTree @() -ProvisioningState 'Accepted' -LogHint $H }
        $r.stage | Should -Be $Stage
        $r.source | Should -Be 'node log'
    }

    It 'is cloud deployment once Azure reports a deployment step, and nothing outside Deploy mode' {
        $tree = @([ordered]@{ id = '0'; name = 'Begin cloud deployment'; status = 'running'; children = @() })
        (InModuleScope AzlSonar -Parameters @{ T = $tree } { param($T) Get-AzlSonarEnvironmentCheckerStage -Mode 'Deploy' -DeploymentTree $T -DeploymentStatus 'running' -ProvisioningState 'Accepted' -LogHint $null }).stage | Should -Be 'cloud-deployment'
        (InModuleScope AzlSonar { Get-AzlSonarEnvironmentCheckerStage -Mode 'Validate' -DeploymentTree @() -ProvisioningState 'Accepted' -LogHint $null }).stage | Should -Be 'validate'
        (InModuleScope AzlSonar { Get-AzlSonarEnvironmentCheckerStage -Mode $null -DeploymentTree @() -ProvisioningState $null -LogHint $null }).stage | Should -Be 'none'
        (InModuleScope AzlSonar { Get-AzlSonarEnvironmentCheckerStage -Mode 'Deploy' -DeploymentTree @() -ProvisioningState 'Failed' -LogHint $null }).stage | Should -Be 'none'
    }
}

Describe 'Get-AzlSonarLagStatus (Azure behind the node)' {
    It 'labels Azure as lagging when the seed node already runs a deployment role but Azure shows no step' {
        $hint = [ordered]@{ roleInterface = 'BareMetal:EnableWindowsFeaturesForDeployment'; at = '2026-10-11T18:34:28Z'; deployActive = $true }
        $r = InModuleScope AzlSonar -Parameters @{ H = $hint; N = $script:Now } { param($H, $N) Get-AzlSonarLagStatus -Mode 'Deploy' -DeploymentTree @() -ProvisioningState 'Accepted' -LogHint $H -Now $N }
        $r.detected | Should -BeTrue
        $r.kind | Should -Be 'deploy-not-reported'
        $r.source | Should -Be 'node log'
        $r.nodeStep | Should -Be 'BareMetal:EnableWindowsFeaturesForDeployment'
        $r.message | Should -Match 'Azure still shows Deploy not started, but the seed node is running BareMetal:EnableWindowsFeaturesForDeployment \(from the node log'
    }

    It 'does not call it a lag when the node line is old, Azure has steps, or the deployment ended' -TestCases @(
        @{ At = '2026-10-11T17:00:00Z'; Tree = @(); State = 'Accepted' }
        @{ At = '2026-10-11T18:34:28Z'; Tree = @([ordered]@{ id = '0'; name = 'x'; status = 'running'; children = @() }); State = 'Accepted' }
        @{ At = '2026-10-11T18:34:28Z'; Tree = @(); State = 'Failed' }
    ) {
        $hint = [ordered]@{ roleInterface = 'BareMetal:X'; at = $At; deployActive = $true }
        $r = InModuleScope AzlSonar -Parameters @{ H = $hint; N = $script:Now; T = $Tree; S = $State } { param($H, $N, $T, $S) Get-AzlSonarLagStatus -Mode 'Deploy' -DeploymentTree $T -ProvisioningState $S -LogHint $H -Now $N }
        $r.detected | Should -BeFalse
    }

    It 'labels the previous attempt when a newer ARM deployment is running (re-run)' {
        $arm = [ordered]@{ name = 'azlocal-validate-0002'; timestamp = '2026-10-11T18:55:00Z'; mode = 'Incremental' }
        $r = InModuleScope AzlSonar -Parameters @{ A = $arm; N = $script:Now } { param($A, $N) Get-AzlSonarLagStatus -Mode 'Validate' -DeploymentTree @() -ProvisioningState 'Failed' -SettingsModifiedAt '2026-10-11T18:10:00Z' -ArmDeployment $A -Now $N }
        $r.detected | Should -BeTrue
        $r.kind | Should -Be 'rerun-pending'
        $r.source | Should -Be 'ARM deployment'
        $r.message | Should -Match 'a new validation'
        $r.message | Should -Match 'previous attempt'
    }

    It 'ignores an ARM deployment that is older than the last deploymentSettings write' {
        $arm = [ordered]@{ name = 'azlocal-validate-0001'; timestamp = '2026-10-11T18:05:00Z'; mode = 'Incremental' }
        $r = InModuleScope AzlSonar -Parameters @{ A = $arm; N = $script:Now } { param($A, $N) Get-AzlSonarLagStatus -Mode 'Validate' -DeploymentTree @() -ProvisioningState 'Failed' -SettingsModifiedAt '2026-10-11T18:10:00Z' -ArmDeployment $A -Now $N }
        $r.detected | Should -BeFalse
    }
}

Describe 'Get-AzlSonarRunningArmDeployment and the poller (mocked ARM)' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        $script:Cfg = Read-AzlSonarConfig -Path $script:SonarExampleConfig
    }

    It 'picks the newest running deployment and sends one read-only GET' {
        Add-Route 'Microsoft.Resources/deployments' (New-SonarArmResponse 200 (Get-Fx 'arm-deployments-running.json'))
        $r = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg } { param($C) Get-AzlSonarRunningArmDeployment -Config $C }
        $r.name | Should -Be 'azlocal-validate-0002'
        $script:ArmCalls.Count | Should -Be 1
        $script:ArmCalls[0] | Should -Match 'Microsoft.Resources/deployments/\?api-version=2021-04-01'
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -ParameterFilter { $Method -ne 'GET' } -Times 0 -Exactly
    }

    It 'returns nothing when the call fails (best effort, never an error)' {
        Add-Route 'Microsoft.Resources/deployments' (New-SonarArmResponse 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'no' } })
        (InModuleScope AzlSonar -Parameters @{ C = $script:Cfg } { param($C) Get-AzlSonarRunningArmDeployment -Config $C }) | Should -BeNullOrEmpty
    }

    It 'the poller shows the lag, the node step as the current step, and the Environment Checker stage' {
        $settings = [pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Deploy'; provisioningState = 'Accepted'; reportedProperties = [pscustomobject]@{ validationStatus = (Get-SonarValidationSuccessFixture); deploymentStatus = [pscustomobject]@{} } }; systemData = [pscustomobject]@{ lastModifiedAt = '2026-10-11T18:20:00Z' } }
        Add-Route 'deploymentSettings/default' (New-SonarArmResponse 200 $settings)
        Add-Route 'Microsoft.Resources/deployments' (New-SonarArmResponse 200 @{ value = @() })
        Add-Route 'HybridCompute/machines/' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Connected'; lastStatusChange = '2026-10-11T17:00:00Z'; agentVersion = '1.50' } }))
        Add-Route 'edgeMachines\?' (New-SonarArmResponse 404 $null)
        Add-Route 'updateSummaries' (New-SonarArmResponse 404 $null)
        $hint = [ordered]@{ roleInterface = 'BareMetal:EnableWindowsFeaturesForDeployment'; at = '2026-10-11T18:34:28Z'; deployActive = $true; limitedSeen = $true; fullSeen = $true }
        $state = Get-AzlSonarDeploymentState -Config $script:Cfg -Now $script:Now -LogHint $hint
        $state.lag.detected | Should -BeTrue
        $state.lag.kind | Should -Be 'deploy-not-reported'
        $state.current.stepName | Should -Be 'BareMetal:EnableWindowsFeaturesForDeployment'
        $state.current.source | Should -Be 'node log'
        $state.environmentChecker.stage | Should -Be 'cloud-deployment'
        $state.mode | Should -Be 'Deploy'
    }

    It 'the poller adds no lag and no ARM call once deployment succeeded' {
        $dep = [pscustomobject]@{ status = 'Success'; steps = @([pscustomobject]@{ name = 'All'; fullStepIndex = '0'; status = 'Success'; startTimeUtc = '2026-10-10T18:00:00Z'; endTimeUtc = '2026-10-10T19:00:00Z' }) }
        $settings = [pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Deploy'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ validationStatus = (Get-SonarValidationSuccessFixture); deploymentStatus = $dep } } }
        Add-Route 'deploymentSettings/default' (New-SonarArmResponse 200 $settings)
        Add-Route 'HybridCompute/machines/' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Connected'; lastStatusChange = '2026-10-11T17:00:00Z'; agentVersion = '1.50' } }))
        Add-Route 'edgeMachines\?' (New-SonarArmResponse 404 $null)
        Add-Route 'updateSummaries' (New-SonarArmResponse 200 (Get-Fx 'update-summary-idle.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 @{ value = @() })
        $state = Get-AzlSonarDeploymentState -Config $script:Cfg -Now $script:Now
        $state.lag.detected | Should -BeFalse
        @($script:ArmCalls | Where-Object { $_ -match 'Microsoft.Resources/deployments' }).Count | Should -Be 0
        $state.phase | Should -Be 'done'
        $state.update.phase | Should -Be 'idle'
        $state.update.verified | Should -BeFalse
    }
}

Describe 'The update track (updateSummaries, updates, updateRuns)' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        $script:Cfg = Read-AzlSonarConfig -Path $script:SonarExampleConfig
    }

    It 'follows an installing update: summary, the update that installs, the newest run as a step tree' {
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-installing.json'))
        Add-Route 'updates/Solution12.2610.1002.4/updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-installing.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-installing.json'))
        $u = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now } { param($C, $N) Get-AzlSonarUpdateState -Config $C -Now $N }
        $u.verified | Should -BeFalse -Because 'built from the REST reference only'
        $u.phase | Should -Be 'installing'
        $u.status | Should -Be 'running'
        $u.summary.currentVersion | Should -Be '12.2609.1003.7'
        $u.summary.failedChecks.Count | Should -Be 1
        $u.active.name | Should -Be 'Solution12.2610.1002.4'
        $u.active.state | Should -Be 'Installing'
        $u.run.name | Should -Be '20261014-2100-run' -Because 'the newest run by timeStarted'
        @($u.tree).Count | Should -Be 3
        $u.tree[0].name | Should -Be 'Prepare'
        $u.tree[0].status | Should -Be 'success'
        $u.tree[0].durationSeconds | Should -Be 600
        $u.tree[1].status | Should -Be 'running'
        $u.tree[1].children[1].name | Should -Be 'Update node 2'
        $u.tree[1].children[1].children[0].name | Should -Be 'Reboot node'
        $u.tree[2].status | Should -Be 'notstarted' -Because "'Unknown status' is Learn's literal for no status yet"
        $u.counts.success | Should -BeGreaterThan 1
        @($script:ArmCalls) | ForEach-Object { $_ | Should -Match 'api-version=2026-10-01' }
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -ParameterFilter { $Method -ne 'GET' } -Times 0 -Exactly
    }

    It 'shows a failed update with the failing step and its error' {
        $summary = (Get-Fx 'update-summary-installing.json') -replace '"UpdateInProgress"', '"UpdateFailed"'
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 $summary)
        Add-Route 'updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-failed.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 ((Get-Fx 'updates-list-installing.json') -replace '"Installing"', '"InstallationFailed"'))
        $u = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now } { param($C, $N) Get-AzlSonarUpdateState -Config $C -Now $N }
        $u.phase | Should -Be 'failed'
        $u.status | Should -Be 'error'
        $u.tree[0].status | Should -Be 'error'
        $u.tree[0].errors | Should -Contain 'Cluster-Aware Updating failed: max retries exceeded'
    }

    It 'is idle (and makes one call) when there is no update activity or no update data yet' {
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-idle.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 @{ value = @() })
        $u = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now } { param($C, $N) Get-AzlSonarUpdateState -Config $C -Now $N }
        $u.phase | Should -Be 'idle'
        $u.status | Should -Be 'notstarted' -Because 'AppliedSuccessfully with a lastUpdated but no installed update and no run is not an update that ran'
        $u.level | Should -Be 'neutral'
        $u.label | Should -Be 'No update has run'
        @($u.tree).Count | Should -Be 0
        $script:ArmCalls.Count | Should -Be 2 -Because 'the summary and the update list; no run is read when no update installs'
        $script:ArmRoutes.Clear()
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 404 $null)
        $none = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now } { param($C, $N) Get-AzlSonarUpdateState -Config $C -Now $N }
        $none.phase | Should -Be 'idle'
        $none.summary | Should -BeNullOrEmpty
    }

    It 'never lets an ARM failure break the poll: it becomes a warning' {
        $w = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'network down' }
        $u = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now; W = $w } { param($C, $N, $W) Get-AzlSonarUpdateState -Config $C -Now $N -Warnings $W }
        $u.phase | Should -Be 'idle'
        $w[0] | Should -Match 'Update track: network down'
    }

    It 'the poller makes the update the phase while it installs, with the running step as the current step' {
        $dep = [pscustomobject]@{ status = 'Success'; steps = @([pscustomobject]@{ name = 'All'; fullStepIndex = '0'; status = 'Success'; startTimeUtc = '2026-10-10T18:00:00Z'; endTimeUtc = '2026-10-10T19:00:00Z' }) }
        $settings = [pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Deploy'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ validationStatus = (Get-SonarValidationSuccessFixture); deploymentStatus = $dep } } }
        Add-Route 'deploymentSettings/default' (New-SonarArmResponse 200 $settings)
        Add-Route 'HybridCompute/machines/' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Connected'; lastStatusChange = '2026-10-11T17:00:00Z'; agentVersion = '1.50' } }))
        Add-Route 'edgeMachines\?' (New-SonarArmResponse 404 $null)
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-installing.json'))
        Add-Route 'updates/Solution12.2610.1002.4/updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-installing.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-installing.json'))
        $state = Get-AzlSonarDeploymentState -Config $script:Cfg -Now $script:Now
        $state.phase | Should -Be 'update'
        $state.activePhase | Should -Be 'update'
        $state.current.phase | Should -Be 'update'
        $state.current.stepName | Should -Be 'Update node 2'
        $state.update.run.status | Should -Be 'running'
    }

    It 'updateTrack off never calls the update APIs' {
        $cfg = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson ((New-SonarConfigObject) | Add-Member -NotePropertyName updateTrack -NotePropertyValue 'off' -PassThru -Force))
        $dep = [pscustomobject]@{ status = 'Success'; steps = @([pscustomobject]@{ name = 'All'; fullStepIndex = '0'; status = 'Success'; startTimeUtc = '2026-10-10T18:00:00Z'; endTimeUtc = '2026-10-10T19:00:00Z' }) }
        Add-Route 'deploymentSettings/default' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Deploy'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ validationStatus = [pscustomobject]@{}; deploymentStatus = $dep } } }))
        Add-Route 'HybridCompute/machines/' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Connected'; lastStatusChange = '2026-10-11T17:00:00Z'; agentVersion = '1.50' } }))
        Add-Route 'edgeMachines\?' (New-SonarArmResponse 404 $null)
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now $script:Now
        @($script:ArmCalls | Where-Object { $_ -match 'update' }).Count | Should -Be 0
        $state.update | Should -BeNullOrEmpty
    }

    It 'validates the track settings in the config' {
        $c = New-SonarConfigObject
        $c | Add-Member -NotePropertyName track -NotePropertyValue 'upgrade' -Force
        $c | Add-Member -NotePropertyName updateTrack -NotePropertyValue 'maybe' -Force
        { Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $c) } | Should -Throw '*track must be auto, deployment, update, add-node or repair*'
        $ok = New-SonarConfigObject
        $ok | Add-Member -NotePropertyName track -NotePropertyValue 'add-node' -Force
        (Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $ok)).track | Should -Be 'add-node'
    }

    It 'the add-node and repair tracks set the phase once deployment is done (guidance only, unverified)' -TestCases @(@{ Track = 'add-node' }, @{ Track = 'repair' }) {
        $c = New-SonarConfigObject
        $c | Add-Member -NotePropertyName track -NotePropertyValue $Track -Force
        $cfg = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $c)
        $dep = [pscustomobject]@{ status = 'Success'; steps = @([pscustomobject]@{ name = 'All'; fullStepIndex = '0'; status = 'Success'; startTimeUtc = '2026-10-10T18:00:00Z'; endTimeUtc = '2026-10-10T19:00:00Z' }) }
        Add-Route 'deploymentSettings/default' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Deploy'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ validationStatus = [pscustomobject]@{}; deploymentStatus = $dep } } }))
        Add-Route 'HybridCompute/machines/' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Connected'; lastStatusChange = '2026-10-11T17:00:00Z'; agentVersion = '1.50' } }))
        Add-Route 'edgeMachines\?' (New-SonarArmResponse 404 $null)
        Add-Route 'updateSummaries' (New-SonarArmResponse 404 $null)
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now $script:Now
        $state.phase | Should -Be $Track
        $state.track | Should -Be $Track
        $g = Get-AzlSonarPhaseGuidance -IdentityModel LocalIdentity
        $g.phases.Contains($Track) | Should -BeTrue
        $g.phases[$Track].verified | Should -BeFalse
        $g.phases[$Track].observed | Should -Match 'unverified against a live run'
        $g.phases[$Track].timing | Should -Not -BeNullOrEmpty
    }
}

Describe 'Guidance: 12.2609 timing and the update, add-node and repair cards' {
    It 'carries the Learn timing for Validate (about 10 minutes) and Deploy (2.5 to 3 hours, limited then full Environment Checker)' {
        $g = Get-AzlSonarPhaseGuidance -IdentityModel LocalIdentity
        $g.phases.validation.timing | Should -Match 'about 10 minutes'
        $g.phases.deployment.timing | Should -Match 'limited Environment Checker run and then a full Environment Checker run'
        $g.phases.deployment.timing | Should -Match '2.5 to 3 hours'
        $g.phases.deployment.timing | Should -Match 'Begin cloud deployment takes 45-60 minutes'
        $g.phases.deployment.timing | Should -Match 'Deploy Moc and ARB Stack: 40-45 minutes'
    }

    It 'has an update card for both identity models, marked unverified' -TestCases @(@{ Model = 'LocalIdentity' }, @{ Model = 'ActiveDirectory' }) {
        $g = Get-AzlSonarPhaseGuidance -IdentityModel $Model
        $g.phases.update.verified | Should -BeFalse
        $g.phases.update.commands | Should -Contain 'Get-CauReport (Cluster-Aware Updating run details)'
    }
}

Describe 'The update verdict: a summary that says AppliedSuccessfully is not an update that ran' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        $script:Cfg = Read-AzlSonarConfig -Path $script:SonarExampleConfig
        function script:Get-UpdateTrack {
            InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now } { param($C, $N) Get-AzlSonarUpdateState -Config $C -Now $N }
        }
    }

    Context 'the live payload of a cluster that just finished its deployment' {
        BeforeEach {
            Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-no-update-yet.json'))
            Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-sbe-content.json'))
        }

        It 'is not green: no run, no installing update, the SBE update waits for content' {
            $u = Get-UpdateTrack
            $u.status | Should -Be 'notstarted'
            $u.ran | Should -BeFalse
            $u.run | Should -BeNullOrEmpty
            $u.active | Should -BeNullOrEmpty
            @($u.tree).Count | Should -Be 0
            $u.phase | Should -Be 'waiting'
            $u.level | Should -Be 'warn' -Because 'an available update that cannot start yet is amber'
            $u.label | Should -Be 'Waiting for content'
            @($script:ArmCalls).Count | Should -Be 2 -Because 'the summary and the update list; no run exists to read'
        }

        It 'shows the offered update with its name, version, package type, description and next action' {
            $u = Get-UpdateTrack
            @($u.updates).Count | Should -Be 1
            $u.updates[0].name | Should -Be 'SBE5.0.2609.1611'
            $u.updates[0].version | Should -Be '5.0.2609.1611'
            $u.updates[0].packageType | Should -Be 'SBE'
            $u.updates[0].description | Should -Be 'Premier SBE for Example 16G AX Servers'
            $u.updates[0].state | Should -Be 'AdditionalContentRequired'
            $u.updates[0].stateWord | Should -Be 'Waiting for content'
            $u.nextAction.text | Should -Match 'SBE side-load'
            $u.nextAction.guide | Should -Match '^https://learn\.microsoft\.com/azure/azure-local/update/solution-builder-extension.*additionalcontentrequired'
        }

        It 'lists the Informational readiness checks and counts them without colouring the tab by themselves' {
            $u = Get-UpdateTrack
            $u.summary.state | Should -Be 'AppliedSuccessfully'
            $u.summary.lastUpdated | Should -BeNullOrEmpty
            $u.summary.currentVersion | Should -Be '12.2610.1004.50'
            $u.summary.checkCounts.informational | Should -Be 2
            $u.summary.checkCounts.critical | Should -Be 0
            $u.summary.checkCounts.total | Should -Be 3
            @($u.summary.failedChecks).Count | Should -Be 2 -Because 'the check that succeeded is not listed, even with severity Critical'
            $u.summary.failedChecks[0].title | Should -Match 'machine proxy on each failover cluster node'
            $u.summary.failedChecks[0].remediation | Should -Match '^https://learn\.microsoft\.com/'
            $u.summary.failedChecks[1].title | Should -Match 'CAU clustered role'
        }
    }

    It 'is neutral with the label "No update has run" when only Informational checks exist and nothing is offered' {
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-no-update-yet.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 @{ value = @() })
        $u = Get-UpdateTrack
        $u.status | Should -Be 'notstarted'
        $u.phase | Should -Be 'idle'
        $u.level | Should -Be 'neutral'
        $u.label | Should -Be 'No update has run'
        $u.summary.checkCounts.informational | Should -Be 2
    }

    It 'the tab colour is the worst non-informational severity: <Severity> -> <Level>' -TestCases @(
        @{ Severity = 'Informational'; Level = 'neutral' }
        @{ Severity = 'Warning'; Level = 'warn' }
        @{ Severity = 'Error'; Level = 'error' }
        @{ Severity = 'Critical'; Level = 'error' }
    ) {
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 ((Get-Fx 'update-summary-live-no-update-yet.json') -replace '"severity": "Informational"', ('"severity": "' + $Severity + '"')))
        Add-Route '/updates\?' (New-SonarArmResponse 200 @{ value = @() })
        $u = Get-UpdateTrack
        $u.level | Should -Be $Level
        $u.status | Should -Be 'notstarted' -Because 'a failed check is not an update run'
        $u.summary.checkCounts[$Severity.ToLowerInvariant()] | Should -Be 2
    }

    It 'a mix of severities counts each and lists the worst first' {
        $mixed = (Get-Fx 'update-summary-live-no-update-yet.json') -replace '"severity": "Informational",(\s*)"status": "Failed",(\s*)"description": "The Cluster', '"severity": "Critical",$1"status": "Failed",$2"description": "The Cluster'
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 $mixed)
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-sbe-content.json'))
        $u = Get-UpdateTrack
        $u.summary.checkCounts.critical | Should -Be 1
        $u.summary.checkCounts.informational | Should -Be 1
        $u.summary.failedChecks[0].severity | Should -Be 'Critical'
        $u.level | Should -Be 'error'
        $u.status | Should -Be 'notstarted'
    }

    It 'is green only after a real run succeeded and the summary is back to AppliedSuccessfully with lastUpdated set' {
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-succeeded.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-succeeded.json'))
        Add-Route 'updates/Solution12.2611.1002.10/updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-succeeded.json'))
        Add-Route 'updates/SBE5.0.2609.1611/updateRuns' (New-SonarArmResponse 200 @{ value = @() })
        $u = Get-UpdateTrack
        $u.status | Should -Be 'success'
        $u.level | Should -Be 'ok'
        $u.ran | Should -BeTrue
        $u.label | Should -Be 'Update succeeded (12.2611.1002.10)'
        $u.run.name | Should -Be '20261209-1840-run'
        $u.run.status | Should -Be 'success'
        $u.summary.lastUpdated | Should -Be '2026-12-09T19:20:00Z'
        @($u.tree).Count | Should -Be 2
        @($u.runs).Count | Should -Be 2 -Because 'the history keeps the earlier run'
        $u.runs[1].name | Should -Be '20261105-1000-old'
        ($u.updates | Where-Object { $_.state -eq 'Obsolete' }).stateWord | Should -Be 'Superseded by a newer version'
    }

    It 'is green from lastUpdated and an installed update when Azure keeps no run, and not otherwise' {
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-succeeded.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-succeeded.json'))
        Add-Route 'updateRuns' (New-SonarArmResponse 404 $null)
        (Get-UpdateTrack).status | Should -Be 'success'
        $script:ArmRoutes.Clear()
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 ((Get-Fx 'update-summary-live-succeeded.json') -replace '"lastUpdated": "[^"]+"', '"lastUpdated": null'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-succeeded.json'))
        Add-Route 'updateRuns' (New-SonarArmResponse 404 $null)
        (Get-UpdateTrack).status | Should -Be 'notstarted'
    }

    It 'a new update that is available again after a successful run is not green' {
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 ((Get-Fx 'update-summary-live-succeeded.json') -replace '"AppliedSuccessfully"', '"UpdateAvailable"'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-succeeded.json'))
        Add-Route 'updates/Solution12.2611.1002.10/updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-succeeded.json'))
        Add-Route 'updates/SBE5.0.2609.1611/updateRuns' (New-SonarArmResponse 200 @{ value = @() })
        $u = Get-UpdateTrack
        $u.status | Should -Be 'notstarted'
        $u.phase | Should -Be 'available'
        $u.level | Should -Be 'neutral'
        $u.run.status | Should -Be 'success' -Because 'the history still shows the last run'
    }

    It 'a failed newest run is an error even when the summary says AppliedSuccessfully' {
        $failedRuns = (Get-Fx 'updateruns-succeeded.json') -replace '"status": "Success"', '"status": "Error"'
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-succeeded.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-succeeded.json'))
        Add-Route 'updates/Solution12.2611.1002.10/updateRuns' (New-SonarArmResponse 200 $failedRuns)
        Add-Route 'updates/SBE5.0.2609.1611/updateRuns' (New-SonarArmResponse 200 @{ value = @() })
        $u = Get-UpdateTrack
        $u.status | Should -Be 'error'
        $u.level | Should -Be 'error'
        $u.phase | Should -Be 'failed'
    }

    Context 'every update state means something plain' {
        It '<State> -> kind <Kind>, phase <Phase>, level <Level>, word <Word>' -TestCases @(
            @{ State = 'AdditionalContentRequired'; Kind = 'waiting'; Phase = 'waiting'; Level = 'warn'; Word = 'Waiting for content' }
            @{ State = 'HasPrerequisite'; Kind = 'waiting'; Phase = 'waiting'; Level = 'warn'; Word = 'Needs another update first' }
            @{ State = 'Ready'; Kind = 'ready'; Phase = 'available'; Level = 'neutral'; Word = 'Ready to install' }
            @{ State = 'ReadyToInstall'; Kind = 'ready'; Phase = 'available'; Level = 'neutral'; Word = 'Ready to install' }
            @{ State = 'Downloading'; Kind = 'running'; Phase = 'preparing'; Level = 'run'; Word = 'Downloading' }
            @{ State = 'Preparing'; Kind = 'running'; Phase = 'preparing'; Level = 'run'; Word = 'Preparing' }
            @{ State = 'Installing'; Kind = 'running'; Phase = 'installing'; Level = 'run'; Word = 'Installing' }
            @{ State = 'InstallationFailed'; Kind = 'failed'; Phase = 'failed'; Level = 'error'; Word = 'Installation failed' }
            @{ State = 'PreparationFailed'; Kind = 'failed'; Phase = 'failed'; Level = 'error'; Word = 'Preparation failed' }
            @{ State = 'HealthCheckFailed'; Kind = 'failed'; Phase = 'failed'; Level = 'error'; Word = 'Health check failed' }
            @{ State = 'Obsolete'; Kind = 'ignored'; Phase = 'idle'; Level = 'neutral'; Word = 'Superseded by a newer version' }
            @{ State = 'Installed'; Kind = 'installed'; Phase = 'idle'; Level = 'ok'; Word = 'Installed' }
            @{ State = 'SomethingNew'; Kind = 'unknown'; Phase = 'idle'; Level = 'neutral'; Word = 'SomethingNew' }
        ) {
            $info = InModuleScope AzlSonar -Parameters @{ S = $State } { param($S) Get-AzlSonarUpdateStateInfo -State $S }
            $info.kind | Should -Be $Kind
            $info.phase | Should -Be $Phase
            $info.level | Should -Be $Level
            $info.word | Should -Be $Word
        }

        It 'an unknown update state is shown as the raw word, neutral, never green' {
            $weird = (Get-Fx 'updates-list-live-sbe-content.json') -replace 'AdditionalContentRequired', 'SomethingNew'
            Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-no-update-yet.json'))
            Add-Route '/updates\?' (New-SonarArmResponse 200 $weird)
            $u = Get-UpdateTrack
            $u.updates[0].stateWord | Should -Be 'SomethingNew'
            $u.updates[0].level | Should -Be 'neutral'
            $u.status | Should -Not -Be 'success'
            $u.level | Should -Be 'neutral'
        }

        It 'a failed update reads the failing run and keeps the failure guide as the next action' {
            Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 ((Get-Fx 'update-summary-installing.json') -replace '"UpdateInProgress"', '"UpdateFailed"'))
            Add-Route 'updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-failed.json'))
            Add-Route '/updates\?' (New-SonarArmResponse 200 ((Get-Fx 'updates-list-installing.json') -replace '"Installing"', '"InstallationFailed"'))
            $u = Get-UpdateTrack
            $u.level | Should -Be 'error'
            $u.nextAction.guide | Should -Match 'update-troubleshooting'
        }
    }

    It 'the roll-up of one state: AppliedSuccessfully is not success, Installed is' {
        InModuleScope AzlSonar { Get-AzlSonarUpdateStatusFromState 'AppliedSuccessfully' } | Should -Be 'notstarted'
        InModuleScope AzlSonar { Get-AzlSonarUpdateStatusFromState 'Installed' } | Should -Be 'success'
        InModuleScope AzlSonar { Get-AzlSonarUpdateStatusFromState 'InstallationFailed' } | Should -Be 'error'
        InModuleScope AzlSonar { Get-AzlSonarUpdateStatusFromState 'Installing' } | Should -Be 'running'
        InModuleScope AzlSonar { Get-AzlSonarUpdateStatusFromState 'AdditionalContentRequired' } | Should -Be 'notstarted'
    }
}

Describe 'Monitoring a monthly update: standalone (-Monitor Update) and Auto against an old deployment' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        $script:Connected = New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Connected'; lastStatusChange = '2026-10-11T17:00:00Z'; agentVersion = '1.50' } })
        $script:MinimalJson = @'
{
  "subscriptionId": "00000000-0000-0000-0000-000000000001",
  "resourceGroup": "rg-example-azl",
  "clusterName": "clus01",
  "identityModel": "ActiveDirectory",
  "nodes": [ { "name": "node01", "address": "192.0.2.11", "seed": true } ],
  "credential": { "source": "prompt" },
  "monitor": "Update"
}
'@
    }

    It 'a minimal config (subscription, resource group, cluster, seed node, credential) is valid and needs no deployment keys' {
        (Test-AzlSonarConfig -Config ($script:MinimalJson | ConvertFrom-Json)) | Should -BeNullOrEmpty
        $cfg = Read-AzlSonarConfig -Json $script:MinimalJson
        $cfg.monitor | Should -Be 'Update'
        $cfg.ztpEventsPath | Should -BeNullOrEmpty
        $cfg.osConfigEventsPath | Should -BeNullOrEmpty
        $cfg.armEventsPath | Should -BeNullOrEmpty
        $cfg.seedNode.name | Should -Be 'node01'
        $plan = InModuleScope AzlSonar -Parameters @{ M = $cfg.monitor } { param($M) Get-AzlSonarMonitorPlan -Monitor $M }
        $plan.armEvents | Should -BeFalse
        $plan.ztpEvents | Should -BeFalse
        $plan.osConfigEvents | Should -BeFalse
        $plan.tailer | Should -BeTrue -Because 'the update logs on the seed node are tailed'
        $plan.phases | Should -Be @('update')
    }

    It 'reads no deployment settings, edge machines or ARM deployments and lands on the update, waiting for content' {
        $cfg = Read-AzlSonarConfig -Json $script:MinimalJson
        Add-Route 'clusters/clus01\?api-version' (New-SonarArmResponse 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'ConnectedRecently'; connectivityStatus = 'Connected'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ clusterVersion = '12.2610.1004.50'; nodes = @([pscustomobject]@{ name = 'node01' }) } } }))
        Add-Route 'HybridCompute/machines/' $script:Connected
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-no-update-yet.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-sbe-content.json'))
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now $script:Now
        @($script:ArmCalls | Where-Object { $_ -match 'deploymentSettings|edgeMachines|Microsoft.Resources/deployments' }).Count | Should -Be 0
        $state.phase | Should -Be 'update'
        $state.activePhase | Should -Be 'update'
        $state.monitor | Should -Be 'Update'
        @($state.deployment.tree).Count | Should -Be 0
        @($state.validation.tree).Count | Should -Be 0
        $state.update.phase | Should -Be 'waiting'
        $state.update.status | Should -Be 'notstarted'
        $state.update.level | Should -Be 'warn'
        $state.update.updates[0].name | Should -Be 'SBE5.0.2609.1611'
        $state.nodes[0].arcStatus | Should -Be 'Connected'
        $state.clusterResource.exists | Should -BeTrue
        $state.pollError | Should -BeNullOrEmpty
        @($state.warnings) | Should -BeNullOrEmpty
    }

    It 'follows an installing update: step tree, the running step as the current step, per-node steps' {
        $cfg = Read-AzlSonarConfig -Json $script:MinimalJson
        Add-Route 'clusters/clus01\?api-version' (New-SonarArmResponse 404 $null)
        Add-Route 'HybridCompute/machines/' $script:Connected
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-installing.json'))
        Add-Route 'updates/Solution12.2610.1002.4/updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-installing.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-installing.json'))
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now $script:Now
        $state.phase | Should -Be 'update'
        $state.update.status | Should -Be 'running'
        $state.update.level | Should -Be 'run'
        $state.current.stepName | Should -Be 'Update node 2'
        $state.update.tree[1].children[1].name | Should -Be 'Update node 2'
    }

    It 'a failed update in the standalone monitor is the failed phase on the update' {
        $cfg = Read-AzlSonarConfig -Json $script:MinimalJson
        Add-Route 'clusters/clus01\?api-version' (New-SonarArmResponse 404 $null)
        Add-Route 'HybridCompute/machines/' $script:Connected
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 ((Get-Fx 'update-summary-installing.json') -replace '"UpdateInProgress"', '"UpdateFailed"'))
        Add-Route 'updateRuns' (New-SonarArmResponse 200 (Get-Fx 'updateruns-failed.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 ((Get-Fx 'updates-list-installing.json') -replace '"Installing"', '"InstallationFailed"'))
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now $script:Now
        $state.phase | Should -Be 'failed'
        $state.activePhase | Should -Be 'update'
    }

    It 'the standalone state has the same keys as the initial state, so the page needs no special case' {
        $cfg = Read-AzlSonarConfig -Json $script:MinimalJson
        Add-Route 'clusters/clus01\?api-version' (New-SonarArmResponse 404 $null)
        Add-Route 'HybridCompute/machines/' $script:Connected
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 404 $null)
        $state = Get-AzlSonarDeploymentState -Config $cfg -Now $script:Now
        $full = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) Get-AzlSonarInitialState -Config $C }
        foreach ($key in $full.Keys) { $state.Contains($key) | Should -BeTrue -Because "state.$key" }
        $state.Contains('update') | Should -BeTrue
        $state.update.label | Should -Be 'No update data from Azure yet'
    }

    Context 'Auto with a deployment that finished a while ago' {
        BeforeEach {
            $script:Cfg = Read-AzlSonarConfig -Path $script:SonarExampleConfig
            function script:Set-AutoRoutes {
                param([string]$DeploymentEnd, [string]$Updates = 'updates-list-live-sbe-content.json')
                $dep = [pscustomobject]@{ status = 'Success'; steps = @([pscustomobject]@{ name = 'All'; fullStepIndex = '0'; status = 'Success'; startTimeUtc = '2026-09-01T10:00:00Z'; endTimeUtc = $DeploymentEnd }) }
                $settings = [pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Deploy'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ validationStatus = (Get-SonarValidationSuccessFixture); deploymentStatus = $dep } } }
                Add-Route 'deploymentSettings/default' (New-SonarArmResponse 200 $settings)
                Add-Route 'HybridCompute/machines/' $script:Connected
                Add-Route 'edgeMachines\?' (New-SonarArmResponse 404 $null)
                Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-no-update-yet.json'))
                if ($Updates) { Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx $Updates)) } else { Add-Route '/updates\?' (New-SonarArmResponse 200 @{ value = @() }) }
            }
        }

        It 'lands on the Update view when the finished deployment is old and an update waits' {
            Set-AutoRoutes -DeploymentEnd '2026-09-01T12:00:00Z'
            $state = Get-AzlSonarDeploymentState -Config $script:Cfg -Now $script:Now
            $state.phase | Should -Be 'update'
            $state.activePhase | Should -Be 'update'
            $state.update.phase | Should -Be 'waiting'
        }

        It 'stays on Deployment (done) right after the deployment finished' {
            Set-AutoRoutes -DeploymentEnd '2026-10-11T12:00:00Z'
            $state = Get-AzlSonarDeploymentState -Config $script:Cfg -Now $script:Now
            $state.phase | Should -Be 'done'
            $state.update.phase | Should -Be 'waiting' -Because 'the Update tile still shows the waiting update'
        }

        It 'stays on Deployment when the old deployment has nothing waiting' {
            Set-AutoRoutes -DeploymentEnd '2026-09-01T12:00:00Z' -Updates ''
            $state = Get-AzlSonarDeploymentState -Config $script:Cfg -Now $script:Now
            $state.phase | Should -Be 'done'
        }
    }
}

Describe 'The update verdict: edge cases found in review' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        $script:Cfg = Read-AzlSonarConfig -Path $script:SonarExampleConfig
    }

    It 'an orphaned run left InProgress does not outvote an installed update and AppliedSuccessfully' {
        $orphan = (Get-Fx 'updateruns-succeeded.json') -replace '"status": "Success"', '"status": "InProgress"'
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-succeeded.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-succeeded.json'))
        Add-Route 'updates/Solution12.2611.1002.10/updateRuns' (New-SonarArmResponse 200 $orphan)
        Add-Route 'updates/SBE5.0.2609.1611/updateRuns' (New-SonarArmResponse 200 @{ value = @() })
        $u = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now } { param($C, $N) Get-AzlSonarUpdateState -Config $C -Now $N }
        $u.status | Should -Not -Be 'running'
        $u.status | Should -Be 'success' -Because 'lastUpdated is set with an installed update and the run status cannot be trusted'
    }

    It 'a newest run with a status Sonar cannot read falls back to lastUpdated with an installed update' {
        $odd = (Get-Fx 'updateruns-succeeded.json') -replace '"status": "Success"', '"status": "Unknown status"'
        Add-Route 'updateSummaries/default' (New-SonarArmResponse 200 (Get-Fx 'update-summary-live-succeeded.json'))
        Add-Route '/updates\?' (New-SonarArmResponse 200 (Get-Fx 'updates-list-live-succeeded.json'))
        Add-Route 'updates/Solution12.2611.1002.10/updateRuns' (New-SonarArmResponse 200 $odd)
        Add-Route 'updates/SBE5.0.2609.1611/updateRuns' (New-SonarArmResponse 200 @{ value = @() })
        $u = InModuleScope AzlSonar -Parameters @{ C = $script:Cfg; N = $script:Now } { param($C, $N) Get-AzlSonarUpdateState -Config $C -Now $N }
        $u.status | Should -Be 'success'
    }
}
