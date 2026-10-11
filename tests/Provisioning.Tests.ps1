#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures only.')]
param()
Set-StrictMode -Version Latest

# The two ways Azure Local machines get ready before the cluster deployment (plan task S-8):
#  - simplified machine provisioning: edge machines (api 2025-12-01-preview) with their jobs/ProvisionOs. The fixtures in
#    tests/fixtures are the recorded live responses of the 10 Oct 2026 run (copied from azurelocal-ztp, neutral ids);
#    job-provisionos-failed.json is derived from them with the InstallExtensions failure seen on the 12.2609 run
#    ('Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server'; the middle of the message and the
#    error code were not recorded, so both are placeholders).
#  - OEM image + Arc registration: no edge machines; the Arc machine carries the host name and the four mandatory
#    extensions install (Microsoft.HybridCompute/machines/extensions, api 2024-07-10).
# Every ARM call is mocked; nothing reaches Azure.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', [System.DateTimeKind]::Utc)
    $script:ArmRoutes = [System.Collections.Generic.List[hashtable]]::new()
    $script:ArmCalls = [System.Collections.Generic.List[string]]::new()

    function Add-ArmRoute {
        param([string]$Match, [object]$Response)
        $script:ArmRoutes.Add(@{ Match = $Match; Response = $Response })
    }

    function Get-Fixture {
        param([string]$Name)
        return (Get-Content -LiteralPath (Join-Path $script:Fixtures $Name) -Raw)
    }

    function New-RouteConfig {
        # Two nodes named like the recorded edge machines (node-01, node-02), no arcMachineName.
        param([string]$Route, [hashtable]$ArcNames = @{})
        $config = New-SonarConfigObject
        $config.nodes[0].name = 'node-01'
        $config.nodes[1].name = 'node-02'
        foreach ($node in $config.nodes) {
            if ($ArcNames.ContainsKey($node.name)) { $node | Add-Member -NotePropertyName arcMachineName -NotePropertyValue $ArcNames[$node.name] -Force }
        }
        if ($Route) { $config | Add-Member -NotePropertyName provisioningRoute -NotePropertyValue $Route -Force }
        return (Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config))
    }

    function New-EdgeList {
        param([string[]]$Fixture)
        $items = foreach ($f in $Fixture) { Get-Fixture $f | ConvertFrom-Json -Depth 64 }
        return (New-SonarArmResponse 200 ([pscustomobject]@{ value = @($items) }))
    }

    function Get-ArcBody {
        param([string]$Status = 'Connected')
        return [pscustomobject]@{
            properties = [pscustomobject]@{ status = $Status; lastStatusChange = '2026-10-10T17:40:00Z'; agentVersion = '1.50' }
            systemData = [pscustomobject]@{ createdAt = '2026-10-10T17:30:00Z' }
        }
    }

    function New-Extension {
        param([string]$Name, [string]$State, [string]$Message, [string]$Created = '2026-10-10T17:45:00Z', [string]$Modified)
        $ext = [ordered]@{
            name       = $Name
            properties = [ordered]@{ provisioningState = $State; instanceView = [ordered]@{ name = $Name; status = [ordered]@{ code = '0'; level = 'Information'; message = $Message } } }
            systemData = [ordered]@{ createdAt = $Created }
        }
        if ($Modified) { $ext.systemData.lastModifiedAt = $Modified }
        if ($State -eq 'Failed') { $ext.properties.instanceView.status.level = 'Error' }
        return $ext
    }

    function Find-TreeNode {
        param([object[]]$Tree, [string]$Name)
        foreach ($n in $Tree) {
            if ($n['name'] -eq $Name) { return $n }
            $hit = Find-TreeNode -Tree @($n['children']) -Name $Name
            if ($null -ne $hit) { return $hit }
        }
        return $null
    }
}

Describe 'Simplified machine provisioning (edge machines, recorded live shapes)' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } })
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
    }

    It 'auto picks the simplified route, resolves the device-id-1 Arc machine from the job target and builds lifecycle + ProvisionOs trees' {
        Add-ArmRoute 'edgeMachines/node-01/jobs/ProvisionOs\?' (New-SonarArmResponse 200 (Get-Fixture 'job-provisionos-succeeded.json'))
        Add-ArmRoute 'edgeMachines/node-02/jobs/ProvisionOs\?' (New-SonarArmResponse 200 (Get-Fixture 'job-provisionos-in-progress.json'))
        Add-ArmRoute 'edgeMachines\?' (New-EdgeList 'edge-machine-provisioned.json', 'edge-machine-installing-os.json')

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig) -Now $script:Now
        $state.provisioning.route | Should -Be 'simplified'
        $state.provisioning.routeSource | Should -Be 'auto'
        $state.provisioning.phase | Should -Be 'provisioning'
        $state.phase | Should -Be 'provisioning'
        $state.activePhase | Should -Be 'provisioning'
        $state.provisioning.status | Should -Be 'running'

        $n1 = $state.provisioning.nodes[0]
        $n1.name | Should -Be 'node-01'
        $n1.lifecycle | Should -Be 'Provisioned'
        $n1.status | Should -Be 'success'
        $n1.percent | Should -Be 100
        $n1.reportedPercent | Should -Be 50 -Because 'the job reported 50 even after DeploymentSuccess; Sonar keeps it but does not draw it'
        $n1.machineState | Should -Be 'Purposed'
        $n1.job.status | Should -Be 'DeploymentSuccess'
        $n1.arcMachineName | Should -Be '00000000-0000-0000-0000-000000000000-1'
        $n1.arcSource | Should -Be 'edgeMachine.job'
        @($n1.extensions | Where-Object { $_.status -eq 'success' }).Count | Should -Be 4
        $jobNode = @($n1.tree)[-1]
        $jobNode['id'] | Should -Be 'job'
        $jobNode['status'] | Should -Be 'success'
        @($jobNode['children'] | ForEach-Object { $_['name'] }) | Should -Be @(
            'CreatedTargetArcMachine', 'CopiedSiteSettings', 'SetupPermissions', 'ArcNotificationSent', 'Initialize',
            'ResolveConfiguration', 'DownloadOSArtifacts', 'SBEDiscoveryDownload', 'SetupHybridComputeRP',
            'PrepareTargetOSProvisioning', 'InitiateTargetOSProvisioning', 'PrepareK3sShutdown', 'BootIntoTargetOS',
            'ValidateStagedArtifacts', 'InvokeTPAUpdate', 'ReportUpdateStatus', 'ProvisionOs', 'InstallExtensions',
            'DeleteUnusedRoleAssignments', 'DeleteUnusedArcMachine')
        (Find-TreeNode -Tree @($n1.tree) -Name 'ProvisionOs')['start'] | Should -Be '2026-10-10T17:43:42Z' -Because 'the MM/dd/yyyy step time is read as UTC'
        @($n1.tree)[0]['name'] | Should -Be 'ProvisionMachine'
        @(@($n1.tree)[0]['children']).Count | Should -Be 3

        $n2 = $state.provisioning.nodes[1]
        $n2.lifecycle | Should -Be 'InstallingOs'
        $n2.lifecycleMessage | Should -Be 'Installing OS in progress. Wait for the operation to complete.'
        $n2.status | Should -Be 'running'
        $n2.percent | Should -BeGreaterThan 25
        $n2.percent | Should -BeLessThan 96
        $n2.arcMachineName | Should -Be '00000000-0000-0000-0000-000000000000-1' -Because 'the target Arc machine, not the maintenance environment ROE1-... machine'
        $n2.arcMachineResourceId | Should -Match '/resourceGroups/rg-example/providers/Microsoft\.HybridCompute/machines/00000000-0000-0000-0000-000000000000-1$'
        $boot = Find-TreeNode -Tree @($n2.tree) -Name 'BootIntoTargetOS'
        $boot['status'] | Should -Be 'running'
        $boot['durationSeconds'] | Should -Be 140 -Because 'running steps get a live duration from their start'
        $boot['end'] | Should -BeNullOrEmpty -Because '0001-01-01 placeholders are not times'
        (Find-TreeNode -Tree @($n2.tree) -Name 'ResolveConfiguration')['start'] | Should -BeNullOrEmpty
        (Find-TreeNode -Tree @($n2.tree) -Name 'RebootOs')['status'] | Should -Be 'running'

        $state.edgeMachines[1].targetArcMachineResourceId | Should -Match '00000000-0000-0000-0000-000000000000-1$'
        $state.edgeMachines[1].arcMachineResourceId | Should -Match '/machines/ROE1-00000000-0000-0000-0000-000000000000$'
        $state.current.phase | Should -Be 'provisioning'
        $state.current.stepPath[0] | Should -Be 'node-02'
        $state.current.status | Should -Be 'running'
        $state.nodes[0].arcSource | Should -Be 'edgeMachine.job'
        $script:ArmCalls | Should -Contain '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.HybridCompute/machines/00000000-0000-0000-0000-000000000000-1?api-version=2024-07-10'
        ($script:ArmCalls -match 'machines/node-0[12]\?') | Should -BeNullOrEmpty -Because 'simplified provisioning does not name the Arc machine after the host'
        ($script:ArmCalls -match '/extensions\?') | Should -BeNullOrEmpty -Because 'the simplified route reads the extensions from the edge machine'
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -ParameterFilter { $Method -ne 'GET' } -Times 0 -Exactly
    }

    It 'the real InstallExtensions failure: step and job error inline, node error, phase failed' {
        Add-ArmRoute 'edgeMachines/node-01/jobs/ProvisionOs\?' (New-SonarArmResponse 200 (Get-Fixture 'job-provisionos-succeeded.json'))
        Add-ArmRoute 'edgeMachines/node-02/jobs/ProvisionOs\?' (New-SonarArmResponse 200 (Get-Fixture 'job-provisionos-failed.json'))
        Add-ArmRoute 'edgeMachines\?' (New-EdgeList 'edge-machine-provisioned.json', 'edge-machine-installing-os.json')

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'simplified') -Now $script:Now
        $state.provisioning.routeSource | Should -Be 'config'
        $n2 = $state.provisioning.nodes[1]
        $n2.status | Should -Be 'error'
        $n2.job.status | Should -Be 'DeploymentFailed'
        $n2.job.error | Should -Be 'InstallExtensionsFailed: Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server'
        $n2.errors | Should -Contain 'ProvisionOs: InstallExtensionsFailed: Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server'
        # The lifecycle sub-stage InstallExtensions comes first in the tree; find the job step under the job node.
        $step = Find-TreeNode -Tree @(@($n2.tree)[-1]) -Name 'InstallExtensions'
        $step['status'] | Should -Be 'error'
        $step['rawStatus'] | Should -Be 'Failed'
        $step['errors'] | Should -Be @('Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server')
        @($n2.tree)[-1]['status'] | Should -Be 'error'
        @($n2.tree)[-1]['errors'] | Should -Be @('InstallExtensionsFailed: Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server')
        $state.provisioning.status | Should -Be 'error'
        $state.phase | Should -Be 'failed'
        $state.activePhase | Should -Be 'provisioning'
    }

    It 'before the job is readable: operationDetails gives the job state; no edge machine gives NotCreated' {
        Add-ArmRoute 'jobs/ProvisionOs\?' (New-SonarArmResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'no job' } })
        Add-ArmRoute 'edgeMachines\?' (New-EdgeList 'edge-machine-installing-os.json')

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig) -Now $script:Now
        $state.provisioning.route | Should -Be 'simplified'
        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'NotCreated'
        $n1.status | Should -Be 'notstarted'
        $n1.arcMachineName | Should -Be 'node-01' -Because 'without an edge machine the node name is the only guess'
        $n1.arcSource | Should -Be 'nodeName'
        $n2 = $state.provisioning.nodes[1]
        $n2.job.operationStatus | Should -Be 'InProgress'
        @($n2.tree)[-1]['status'] | Should -Be 'running'
        @(@($n2.tree)[-1]['children']).Count | Should -Be 0
        $n2.arcMachineName | Should -Be 'ROE1-00000000-0000-0000-0000-000000000000' -Because 'without the job only properties.arcMachineResourceId is known'
        $n2.arcSource | Should -Be 'edgeMachine'
        $n2.percent | Should -Be 25
        @($state.warnings | Where-Object { $_ -match 'ProvisionOs' }).Count | Should -Be 0
    }

    It 'keeps an explicit arcMachineName (config resource group) when it differs from the edge machine' {
        Add-ArmRoute 'jobs/ProvisionOs\?' (New-SonarArmResponse 200 (Get-Fixture 'job-provisionos-succeeded.json'))
        Add-ArmRoute 'edgeMachines\?' (New-EdgeList 'edge-machine-provisioned.json', 'edge-machine-installing-os.json')

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -ArcNames @{ 'node-01' = 'my-arc-01' }) -Now $script:Now
        $state.nodes[0].arcMachineName | Should -Be 'my-arc-01'
        $state.nodes[0].arcSource | Should -Be 'config'
        $script:ArmCalls | Should -Contain '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/my-arc-01?api-version=2024-07-10'
        $state.nodes[1].arcSource | Should -Be 'edgeMachine.job'
    }

    It 'an explicit arcMachineName equal to the edge machine target uses the edge machine resource group' {
        Add-ArmRoute 'jobs/ProvisionOs\?' (New-SonarArmResponse 200 (Get-Fixture 'job-provisionos-succeeded.json'))
        Add-ArmRoute 'edgeMachines\?' (New-EdgeList 'edge-machine-provisioned.json')

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -ArcNames @{ 'node-01' = '00000000-0000-0000-0000-000000000000-1' }) -Now $script:Now
        $state.nodes[0].arcSource | Should -Be 'config'
        $state.nodes[0].arcMachineResourceId | Should -Match '/resourceGroups/rg-example/providers/'
    }

    It 'ignores an arcMachineResourceId that is not a HybridCompute machine id' {
        $machine = Get-Fixture 'edge-machine-installing-os.json' | ConvertFrom-Json -Depth 64
        $machine.properties.arcMachineResourceId = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/x?evil=1'
        Add-ArmRoute 'jobs/ProvisionOs\?' (New-SonarArmResponse 404 $null)
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 200 ([pscustomobject]@{ value = @($machine) }))

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig) -Now $script:Now
        $state.nodes[1].arcSource | Should -Be 'nodeName'
        ($script:ArmCalls -match 'Microsoft\.Storage') | Should -BeNullOrEmpty
    }

    It 'validation steps win over provisioning; the provisioning data stays in the state' {
        $settings = [pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Validate'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ validationStatus = (Get-SonarValidationFixture); deploymentStatus = [pscustomobject]@{} } } }
        $script:ArmRoutes.Clear()
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 $settings)
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'jobs/ProvisionOs\?' (New-SonarArmResponse 200 (Get-Fixture 'job-provisionos-failed.json'))
        Add-ArmRoute 'edgeMachines\?' (New-EdgeList 'edge-machine-provisioned.json')

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig) -Now $script:Now
        $state.phase | Should -Be 'validation'
        $state.activePhase | Should -Be 'validation'
        $state.provisioning.route | Should -Be 'simplified'
        @($state.provisioning.nodes).Count | Should -Be 2
        $state.current.phase | Should -Be 'validation'
    }

    It 'auto with edge machines that match no node follows the OEM route and says why' {
        $machine = Get-Fixture 'edge-machine-provisioned.json' | ConvertFrom-Json -Depth 64
        $machine.name = 'other-cluster-node'
        $machine.properties.siteDetails.deviceConfiguration.hostName = 'other-cluster-node'
        Add-ArmRoute 'jobs/ProvisionOs\?' (New-SonarArmResponse 404 $null)
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 200 ([pscustomobject]@{ value = @($machine) }))
        $script:ArmRoutes.Insert(0, @{ Match = '/extensions\?'; Response = (New-SonarArmResponse 200 @{ value = @() }) })

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig) -Now $script:Now
        $state.provisioning.route | Should -Be 'oem-image'
        $state.phase | Should -Be 'arc-registration'
        ($state.warnings -match 'match no configured node') | Should -Not -BeNullOrEmpty
    }
}

Describe 'OEM image + Arc registration (no edge machines)' {
    BeforeEach {
        $script:ArmRoutes.Clear()
        $script:ArmCalls.Clear()
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith {
            $script:ArmCalls.Add($Path)
            foreach ($route in $script:ArmRoutes) { if ($Path -match $route.Match) { return $route.Response } }
            throw "Unrouted ARM call in test: $Path"
        }
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 404 $null)
    }

    It 'provisioningRoute oem-image never reads edge machines; a missing Arc machine is NotRegistered' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } })

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:Now
        ($script:ArmCalls -match 'edgeMachines') | Should -BeNullOrEmpty
        ($script:ArmCalls -match '/extensions\?') | Should -BeNullOrEmpty -Because 'there is no Arc machine to read extensions from'
        $state.provisioning.route | Should -Be 'oem-image'
        $state.provisioning.routeSource | Should -Be 'config'
        $state.phase | Should -Be 'arc-registration'
        $state.provisioning.status | Should -Be 'notstarted'
        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'NotRegistered'
        $n1.status | Should -Be 'notstarted'
        $n1.percent | Should -Be 0
        $n1.arcMachineName | Should -Be 'node-01'
        $n1.arcSource | Should -Be 'nodeName'
        @($n1.tree | ForEach-Object { $_['name'] }) | Should -Be @('Arc machine registered', 'Arc agent Connected', 'AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics')
        @($n1.tree | Where-Object { $_['status'] -ne 'notstarted' }).Count | Should -Be 0
    }

    It 'reads the Arc machine by host name and each mandatory extension as a step (Creating runs, Failed shows its message)' {
        $extensions = @(
            New-Extension -Name 'AzureEdgeDeviceManagement' -State 'Succeeded' -Message 'Enable succeeded' -Modified '2026-10-10T17:50:00Z'
            New-Extension -Name 'AzureEdgeLifecycleManager' -State 'Creating' -Created '2026-10-10T17:55:00Z'
            New-Extension -Name 'AzureEdgeTelemetryAndDiagnostics' -State 'Failed' -Message 'Extension install failed: password=hunter2 rejected' -Modified '2026-10-10T17:58:00Z'
            New-Extension -Name 'SomeOtherExtension' -State 'Failed' -Message 'not mandatory'
        )
        Add-ArmRoute 'machines/node-01/extensions\?' (New-SonarArmResponse 200 @{ value = $extensions })
        Add-ArmRoute 'machines/node-02/extensions\?' (New-SonarArmResponse 200 @{ value = @() })
        Add-ArmRoute 'machines/node-01\?' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'machines/node-02\?' (New-SonarArmResponse 200 (Get-ArcBody -Status 'Disconnected'))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 200 @{ value = @() })

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig) -Now $script:Now
        $state.provisioning.route | Should -Be 'oem-image'
        $state.provisioning.routeSource | Should -Be 'auto'
        $script:ArmCalls | Should -Contain '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/node-01/extensions?api-version=2024-07-10'

        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'Failed'
        $n1.status | Should -Be 'error'
        $n1.percent | Should -Be 50
        $n1.start | Should -Be '2026-10-10T17:30:00Z'
        $n1.errors | Should -Be @('AzureEdgeTelemetryAndDiagnostics: Extension install failed: password=*** rejected')
        $tele = Find-TreeNode -Tree @($n1.tree) -Name 'AzureEdgeTelemetryAndDiagnostics'
        $tele['status'] | Should -Be 'error'
        $tele['rawStatus'] | Should -Be 'Failed'
        $tele['errors'] | Should -Be @('Extension install failed: password=*** rejected')
        $tele['end'] | Should -Be '2026-10-10T17:58:00Z'
        $lcm = Find-TreeNode -Tree @($n1.tree) -Name 'AzureEdgeLifecycleManager'
        $lcm['status'] | Should -Be 'running'
        $lcm['durationSeconds'] | Should -Be 300
        (Find-TreeNode -Tree @($n1.tree) -Name 'AzureEdgeRemoteSupport')['status'] | Should -Be 'notstarted'
        (Find-TreeNode -Tree @($n1.tree) -Name 'Arc agent Connected')['end'] | Should -Be '2026-10-10T17:40:00Z'
        (Find-TreeNode -Tree @($n1.tree) -Name 'SomeOtherExtension') | Should -BeNullOrEmpty

        $n2 = $state.provisioning.nodes[1]
        $n2.lifecycle | Should -Be 'Registered'
        $n2.status | Should -Be 'running'
        (Find-TreeNode -Tree @($n2.tree) -Name 'Arc agent Connected')['rawStatus'] | Should -Be 'Disconnected'

        $state.provisioning.status | Should -Be 'error'
        $state.phase | Should -Be 'failed'
        $state.activePhase | Should -Be 'arc-registration'
        $state.current.phase | Should -Be 'arc-registration'
        $state.current.stepPath | Should -Be @('node-01', 'ext.AzureEdgeLifecycleManager')
    }

    It 'all four mandatory extensions Succeeded: Ready, 100 percent, status success' {
        $extensions = foreach ($name in 'AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics') {
            New-Extension -Name $name -State 'Succeeded' -Modified '2026-10-10T17:59:00Z'
        }
        Add-ArmRoute '/extensions\?' (New-SonarArmResponse 200 @{ value = @($extensions) })
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:Now
        foreach ($n in $state.provisioning.nodes) {
            $n.lifecycle | Should -Be 'Ready'
            $n.status | Should -Be 'success'
            $n.percent | Should -Be 100
            $n.end | Should -Be '2026-10-10T17:59:00Z'
        }
        $state.provisioning.status | Should -Be 'success'
        $state.phase | Should -Be 'arc-registration' -Because 'Ready machines wait for validation; only deployment success is done'
    }

    It 'an unreadable Arc machine is Unknown with a warning, not NotRegistered' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'no read access' } })
        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:Now
        $state.provisioning.nodes[0].lifecycle | Should -Be 'Unknown'
        $state.provisioning.nodes[0].status | Should -Be 'unknown'
        $state.warnings | Should -Contain 'Arc machine node-01: no read access'
    }
}

Describe 'Get-AzlSonarPhase with the machine-readiness phase' {
    It 'passes through <Phase> when nothing else has steps' -TestCases @(@{ Phase = 'provisioning' }, @{ Phase = 'arc-registration' }) {
        param($Phase)
        $r = InModuleScope AzlSonar -Parameters @{ P = $Phase } { param($P) Get-AzlSonarPhase -ValidationTree @() -ValidationStatus 'notstarted' -DeploymentTree @() -DeploymentStatus 'notstarted' -ProvisioningPhase $P -ProvisioningStatus 'running' }
        $r.phase | Should -Be $Phase
        $r.activePhase | Should -Be $Phase
    }

    It 'a provisioning error is failed with activePhase kept' {
        $r = InModuleScope AzlSonar { Get-AzlSonarPhase -ValidationTree @() -ValidationStatus 'notstarted' -DeploymentTree @() -DeploymentStatus 'notstarted' -ProvisioningPhase 'arc-registration' -ProvisioningStatus 'error' }
        $r.phase | Should -Be 'failed'
        $r.activePhase | Should -Be 'arc-registration'
    }

    It 'rejects an unknown machine-readiness phase' {
        { InModuleScope AzlSonar { Get-AzlSonarPhase -ProvisioningPhase 'bogus' } } | Should -Throw
    }
}

Describe 'Get-AzlSonarProvisioningPercent' {
    It '<Lifecycle> with <Done> of <Total> job steps finished is <Expected>' -TestCases @(
        @{ Lifecycle = 'Creating'; Done = 0; Total = 0; Expected = 0 }
        @{ Lifecycle = 'AwaitingConnection'; Done = 0; Total = 0; Expected = 5 }
        @{ Lifecycle = 'Provisioning'; Done = 0; Total = 0; Expected = 15 }
        @{ Lifecycle = 'ReadyForOs'; Done = 0; Total = 0; Expected = 25 }
        @{ Lifecycle = 'InstallingOs'; Done = 10; Total = 20; Expected = 60 }
        @{ Lifecycle = 'InstallingOs'; Done = 20; Total = 20; Expected = 95 }
        @{ Lifecycle = 'Provisioned'; Done = 0; Total = 0; Expected = 100 }
    ) {
        param($Lifecycle, $Done, $Total, $Expected)
        $value = InModuleScope AzlSonar -Parameters @{ L = $Lifecycle; D = $Done; T = $Total } {
            param($L, $D, $T)
            $steps = @(for ($i = 0; $i -lt $T; $i++) { [ordered]@{ status = $(if ($i -lt $D) { 'success' } else { 'notstarted' }) } })
            Get-AzlSonarProvisioningPercent -Lifecycle $L -JobSteps $steps -JobStatus 'running'
        }
        $value | Should -Be $Expected
    }
}
