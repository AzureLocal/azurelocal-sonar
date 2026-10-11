#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Config = Read-AzlSonarConfig -Path $script:SonarExampleConfig
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-10-10T18:10:00', [System.DateTimeKind]::Utc)

    # Route table: ordered list of @{ Match = <regex on the ARM path>; Response = <Invoke-AzRestMethod result> }.
    # The first matching route answers; anything unrouted fails the test loudly (no live call can slip through).
    $script:ArmRoutes = [System.Collections.Generic.List[hashtable]]::new()
    $script:ArmCalls = [System.Collections.Generic.List[string]]::new()
    function Add-ArmRoute {
        param([string]$Match, [object]$Response)
        $script:ArmRoutes.Add(@{ Match = $Match; Response = $Response })
    }

    function Get-SettingsBody {
        param([object]$Validation, [object]$Deployment, [string]$Mode = 'Validate', [string]$State = 'Succeeded')
        return [pscustomobject]@{
            id         = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/clus01/deploymentSettings/default'
            properties = [pscustomobject]@{
                deploymentMode     = $Mode
                provisioningState  = $State
                reportedProperties = [pscustomobject]@{ validationStatus = $Validation; deploymentStatus = $Deployment }
            }
        }
    }

    function Get-ArcBody {
        param([string]$Status = 'Connected')
        return [pscustomobject]@{ properties = [pscustomobject]@{ status = $Status; lastStatusChange = '2026-10-10T17:00:00Z'; agentVersion = '1.50' } }
    }
}

Describe 'Get-AzlSonarDeploymentState (mocked ARM)' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) {
                if ($Path -match $route.Match) { return $route.Response }
            }
            throw "Unrouted ARM call in test: $Path"
        }
    }

    It 'validation succeeded and deployment {}: phase validation, validation done' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation (Get-SonarValidationSuccessFixture) -Deployment ([pscustomobject]@{})))
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 400 @{ error = @{ code = 'InvalidApiVersion'; message = 'no such api' } })

        $state = Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now
        $state.phase | Should -Be 'validation'
        $state.validation.status | Should -Be 'success'
        $state.validation.counts.success | Should -Be 3
        @($state.validation.tree).Count | Should -Be 3
        $state.deployment.status | Should -Be 'notstarted'
        @($state.deployment.tree).Count | Should -Be 0
        $state.deployment.counts.total | Should -Be 0
        $state.mode | Should -Be 'Validate'
        $state.provisioningState | Should -Be 'Succeeded'
        $state.current.phase | Should -Be 'validation'
        $state.current.stepName | Should -Be 'Validate Active Directory'
        $state.pollError | Should -BeNullOrEmpty
        $state.polledAt | Should -Be '2026-10-10T18:10:00Z'
        $state.cluster | Should -Be 'clus01'
    }

    It 'uses the configured api-version and escapes nothing unexpected in the path' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation ([pscustomobject]@{}) -Deployment ([pscustomobject]@{})))
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 404 $null)
        $null = Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now
        $script:ArmCalls[0] | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.AzureStackHCI/clusters/clus01/deploymentSettings/default?api-version=2025-09-15-preview'
        $script:ArmCalls | Should -Contain '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/node02?api-version=2024-07-10'
        ($script:ArmCalls -match 'edgeMachines\?api-version=2025-12-01-preview$') | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -ParameterFilter { $Method -ne 'GET' } -Times 0 -Exactly
    }

    It 'deployment running: phase deployment, current is the deepest running step' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation (Get-SonarValidationSuccessFixture) -Deployment (Get-SonarDeploymentFixture) -Mode 'Deploy' -State 'Provisioning'))
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 400 $null)
        $deployNow = [datetime]::SpecifyKind([datetime]'2026-10-10T20:00:00', [System.DateTimeKind]::Utc)

        $state = Get-AzlSonarDeploymentState -Config $script:Config -Now $deployNow
        $state.phase | Should -Be 'deployment'
        $state.mode | Should -Be 'Deploy'
        $state.deployment.status | Should -Be 'running'
        $state.deployment.counts.running | Should -Be 3
        $state.current.phase | Should -Be 'deployment'
        $state.current.stepPath | Should -Be @('1', '1.1', '1.1.0')
        $state.current.stepName | Should -Be 'Install MOC'
        $state.deployment.tree[1].durationSeconds | Should -Be 2400
    }

    It 'deployment succeeded: phase done' {
        $deployment = [pscustomobject]@{ status = 'Success'; steps = @([pscustomobject]@{ name = 'All'; fullStepIndex = '0'; status = 'Success'; startTimeUtc = '2026-10-10T19:00:00Z'; endTimeUtc = '2026-10-10T21:00:00Z' }) }
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation (Get-SonarValidationSuccessFixture) -Deployment $deployment -Mode 'Deploy'))
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 400 $null)
        (Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now).phase | Should -Be 'done'
    }

    It 'deployment step failed: phase failed' {
        $deployment = [pscustomobject]@{ status = 'Error'; steps = @([pscustomobject]@{ name = 'All'; fullStepIndex = '0'; status = 'Error'; exception = @('boom') }) }
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation (Get-SonarValidationSuccessFixture) -Deployment $deployment -Mode 'Deploy'))
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 400 $null)
        $state = Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now
        $state.phase | Should -Be 'failed'
        $state.deployment.tree[0].errors | Should -Be @('boom')
    }

    It 'Arc machine 404 is NotFound, not a warning' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation (Get-SonarValidationFixture) -Deployment ([pscustomobject]@{})))
        Add-ArmRoute 'machines/node01/extensions\?' (New-SonarArmResponse 200 @{ value = @() })
        Add-ArmRoute 'machines/node01\?' (New-SonarArmResponse 200 (Get-ArcBody -Status 'Connected'))
        Add-ArmRoute 'machines/node02\?' (New-SonarArmResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } })
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 400 $null)

        $state = Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now
        @($state.nodes).Count | Should -Be 2
        $state.nodes[0].arcStatus | Should -Be 'Connected'
        $state.nodes[0].lastStatusChange | Should -Be '2026-10-10T17:00:00Z'
        $state.nodes[0].agentVersion | Should -Be '1.50'
        $state.nodes[0].seed | Should -BeTrue
        $state.nodes[1].arcStatus | Should -Be 'NotFound'
        @($state.warnings).Count | Should -Be 0
        $state.phase | Should -Be 'validation'
        $state.current.stepName | Should -Be 'Validate Hardware'
    }

    It 'Arc machine 403 becomes a warning and the node stays Unknown' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation ([pscustomobject]@{}) -Deployment ([pscustomobject]@{})))
        Add-ArmRoute 'machines/node01\?' (New-SonarArmResponse 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'no read access' } })
        Add-ArmRoute 'machines/node02/extensions\?' (New-SonarArmResponse 200 @{ value = @() })
        Add-ArmRoute 'machines/node02\?' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 404 $null)
        $state = Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now
        $state.nodes[0].arcStatus | Should -Be 'Unknown'
        $state.warnings | Should -Contain 'Arc machine node01: no read access'
    }

    It 'edgeMachines 400 and 404 are ignored silently (auto route falls back to the OEM image route)' -TestCases @(@{ Code = 400 }, @{ Code = 404 }) {
        param($Code)
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation ([pscustomobject]@{}) -Deployment ([pscustomobject]@{})))
        Add-ArmRoute '/extensions\?' (New-SonarArmResponse 200 @{ value = @() })
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse $Code @{ error = @{ code = 'NoRegisteredProviderFound'; message = 'api version not supported' } })
        $state = Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now
        @($state.edgeMachines).Count | Should -Be 0
        @($state.warnings).Count | Should -Be 0
        $state.provisioning.route | Should -Be 'oem-image'
        $state.provisioning.routeSource | Should -Be 'auto'
        $state.phase | Should -Be 'arc-registration'
        $state.current.phase | Should -Be 'arc-registration'
        $state.current.stepPath[0] | Should -BeIn @('node01', 'node02') -Because 'the Arc registration tree starts with the node name'
    }

    It 'edgeMachines 500 becomes a warning' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 (Get-SettingsBody -Validation ([pscustomobject]@{}) -Deployment ([pscustomobject]@{})))
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 500 @{ error = @{ message = 'internal' } })
        $state = Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now
        $state.warnings | Should -Contain 'edgeMachines: internal'
    }

    It 'provisioning: an explicit arcMachineName still maps the edge machine; the current step starts with the node name' {
        $configObject = New-SonarConfigObject
        $configObject.nodes[0] | Add-Member -NotePropertyName arcMachineName -NotePropertyValue 'node01' -Force
        $explicitConfig = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $configObject)
        $edgeList = @{ value = @(@{
                    name       = 'dev-0001-1'
                    id         = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.AzureStackHCI/edgeMachines/dev-0001-1'
                    properties = @{ provisioningState = 'Provisioning'; machineState = 'Preparing'; connectivityStatus = 'Connected'; arcMachineResourceId = '/subscriptions/x/resourceGroups/y/providers/Microsoft.HybridCompute/machines/node01' }
                }) }
        $job = @{ properties = @{ status = 'InProgress'; reportedProperties = @{
                    percentComplete  = 40
                    deploymentStatus = @{ status = 'InProgress'; steps = @(
                            @{ name = 'DownloadOs'; fullStepIndex = '0'; status = 'Success'; startTimeUtc = '2026-10-10T17:00:00Z'; endTimeUtc = '2026-10-10T17:10:00Z' },
                            @{ name = 'InstallingOs'; fullStepIndex = '1'; status = 'InProgress'; startTimeUtc = '2026-10-10T17:10:00Z' }
                        ) }
                } } }
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'nope' } })
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'jobs/ProvisionOs\?' (New-SonarArmResponse 200 $job)
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 200 $edgeList)

        $state = Get-AzlSonarDeploymentState -Config $explicitConfig -Now $script:Now
        $state.phase | Should -Be 'provisioning'
        $state.provisioning.route | Should -Be 'simplified'
        ($state.warnings -match 'deploymentSettings for clus01 not found yet') | Should -Not -BeNullOrEmpty
        @($state.edgeMachines).Count | Should -Be 1
        $state.edgeMachines[0].node | Should -Be 'node01'
        $state.edgeMachines[0].arcMachineName | Should -Be 'node01'
        $state.edgeMachines[0].provisionOsJob.percentComplete | Should -Be 40
        $state.edgeMachines[0].provisionOsJob.deployment.status | Should -Be 'running'
        $state.nodes[0].arcSource | Should -Be 'config'
        $state.provisioning.nodes[0].reportedPercent | Should -Be 40
        $state.provisioning.nodes[1].lifecycle | Should -Be 'NotCreated'
        $state.current.phase | Should -Be 'provisioning'
        $state.current.stepPath | Should -Be @('node01', 'job', 'job.1')
        $state.current.stepName | Should -Be 'InstallingOs'
    }

    It 'throws on an ARM error from deploymentSettings' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'The client does not have authorization.' } })
        { Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now } | Should -Throw '*GET deploymentSettings for clus01 failed: The client does not have authorization.*'
    }

    It 'reports HTTP 502 when the error body is not JSON' {
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 502 '<html>bad gateway</html>')
        { Get-AzlSonarDeploymentState -Config $script:Config -Now $script:Now } | Should -Throw '*failed: HTTP 502*'
    }
}

Describe 'Invoke-AzlSonarPollerLoop keeps pollError on ARM failure' {
    BeforeEach {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
    }

    It 'publishes the previous state with pollError when ARM returns an error' {
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed","message":"denied"}}' }
        }
        $result = InModuleScope AzlSonar -Parameters @{ Config = $script:Config } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            $previous = Get-AzlSonarInitialState -Config $Config
            $previous.phase = 'validation'
            $previous.polledAt = '2026-10-10T18:00:00Z'
            $shared.State = $previous
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $Config
            $shared
        }
        $result.StateVersion | Should -Be 1
        $result.State.phase | Should -Be 'validation' -Because 'the last good state is kept'
        $result.State.polledAt | Should -Be '2026-10-10T18:00:00Z'
        $result.State.pollError.message | Should -BeLike '*denied*'
        $result.State.pollError.at | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        ($result.StateJson | ConvertFrom-Json).pollError.message | Should -BeLike '*denied*'
        $result.Timeline.Count | Should -Be 1
    }

    It 'starts from the initial state when the first poll throws (no Az context)' {
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'Run Connect-AzAccount to login.' }
        $result = InModuleScope AzlSonar -Parameters @{ Config = $script:Config } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $Config
            $shared
        }
        $result.State.phase | Should -Be 'provisioning'
        $result.State.cluster | Should -Be 'clus01'
        $result.State.pollError.message | Should -BeLike '*Connect-AzAccount*'
    }

    It 'clears pollError on the next good poll' {
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            if ($Path -match 'deploymentSettings') { return [pscustomobject]@{ StatusCode = 404; Content = '' } }
            if ($Path -match 'HybridCompute') { return [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"status":"Connected"}}' } }
            return [pscustomobject]@{ StatusCode = 400; Content = '' }
        }
        $result = InModuleScope AzlSonar -Parameters @{ Config = $script:Config } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            $previous = Get-AzlSonarInitialState -Config $Config
            $previous.pollError = [ordered]@{ message = 'old'; at = '2026-10-10T18:00:00Z' }
            $shared.State = $previous
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $Config
            $shared
        }
        $result.State.pollError | Should -BeNullOrEmpty
        $result.State.nodes[0].arcStatus | Should -Be 'Connected'
    }
}

Describe 'Publish-AzlSonarState timeline' {
    It 'adds a snapshot only when more than polledAt or durations changed' {
        $result = InModuleScope AzlSonar -Parameters @{ Config = $script:Config } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState -TimelineMax 2
            $a = Get-AzlSonarInitialState -Config $Config
            $a.polledAt = '2026-10-10T18:00:00Z'
            Publish-AzlSonarState -Shared $shared -State $a
            $b = Get-AzlSonarInitialState -Config $Config
            $b.polledAt = '2026-10-10T18:00:20Z'
            Publish-AzlSonarState -Shared $shared -State $b
            $counts = @($shared.Timeline.Count)
            foreach ($phase in 'validation', 'deployment', 'done') {
                $c = Get-AzlSonarInitialState -Config $Config
                $c.phase = $phase
                Publish-AzlSonarState -Shared $shared -State $c
            }
            $counts += $shared.Timeline.Count
            [pscustomobject]@{ Counts = $counts; Version = $shared.StateVersion; Last = $shared.Timeline[-1]; Dropped = $shared.TimelineDropped; StateJson = $shared.StateJson }
        }
        $result.Counts[0] | Should -Be 1
        $result.Counts[1] | Should -Be 2 -Because 'TimelineMax caps the snapshots'
        $result.Dropped | Should -Be 2 -Because 'four distinct snapshots were taken and two fit'
        ($result.StateJson | ConvertFrom-Json).phase | Should -Be 'done' -Because 'the latest state is kept apart from the capped timeline'
        $result.Version | Should -Be 5
        ($result.Last | ConvertFrom-Json).phase | Should -Be 'done'
    }
}
