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
#  - OEM image + Arc registration: no edge machines; the Arc machine carries the host name. Arc registration is read
#    on the node (OS image update and bootstrap, tests/fixtures/arc-*.json) and in Azure (the Arc machine); the four
#    mandatory extensions (Microsoft.HybridCompute/machines/extensions, api 2024-07-10) install during Validate and
#    are read only once a validation exists.
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
    # What Arc registration does on each node, read on the node (Get-ArcZeroDaySolutionUpdateStatus,
    # Get-ArcBootstrapStatus; tests/fixtures/arc-*.json) plus the Arc machine in Azure. The fixtures follow the shape read
    # live on 11 Oct 2026 (AzureEdgeBootstrap 1.0.0: { Version, Response: { Name, Status, Message, Errors[],
    # DetailedResponse[], StartTime, EndTime } } and the step names); only NotStarted was seen live. InProgress, Succeeded
    # and Failed use the Learn status values, and the Errors[] entries (a string in the update fixture, an object with
    # Message in the bootstrap fixture) are guesses: no failure has been recorded yet.
    BeforeAll {
        $script:ArcNow = [datetime]::SpecifyKind([datetime]'2026-10-11T06:30:00', [System.DateTimeKind]::Utc)

        function New-Probe {
            # A node probe record as the probe loop stores it, built from fixtures (empty name: command not on the node).
            param([string]$Update, [string]$Bootstrap, [datetime]$At = $script:ArcNow)
            $part = {
                param([string]$Fixture)
                [pscustomobject]@{ available = [bool]$Fixture; json = $(if ($Fixture) { Get-Fixture $Fixture } else { $null }); error = $null }
            }
            $result = [pscustomobject]@{ computer = 'NODE'; update = (& $part $Update); bootstrap = (& $part $Bootstrap) }
            return (InModuleScope AzlSonar -Parameters @{ R = $result; T = $At } { param($R, $T) Update-AzlSonarNodeProbeEntry -Result $R -Transport 'winrm' -Now $T })
        }
    }

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

    It 'provisioningRoute oem-image never reads edge machines or extensions; nothing started is NotStarted with three groups' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } })

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:ArcNow
        ($script:ArmCalls -match 'edgeMachines') | Should -BeNullOrEmpty
        ($script:ArmCalls -match '/extensions\?') | Should -BeNullOrEmpty -Because 'the extensions install during Validate, not during Arc registration'
        $state.provisioning.route | Should -Be 'oem-image'
        $state.provisioning.routeSource | Should -Be 'config'
        $state.phase | Should -Be 'arc-registration'
        $state.provisioning.status | Should -Be 'notstarted'
        $state.provisioning.readyForValidate | Should -BeFalse
        $state.extensions.shown | Should -BeFalse
        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'NotStarted'
        $n1.status | Should -Be 'notstarted'
        $n1.percent | Should -Be 0
        $n1.arcMachineName | Should -Be 'node-01'
        $n1.arcSource | Should -Be 'nodeName'
        @($n1.extensions).Count | Should -Be 0
        @($n1.tree | ForEach-Object { $_['name'] }) | Should -Be @('OS image update', 'Bootstrap', 'Azure registration')
        @($n1.tree[2]['children'] | ForEach-Object { $_['name'] }) | Should -Be @('Arc machine registered', 'Arc agent Connected')
        $n1.tree[0]['rawStatus'] | Should -Be 'NotRead'
        $n1.tree[0]['description'] | Should -Match 'Get-ArcZeroDaySolutionUpdateStatus not read from the node yet'
        $n1.probe.state | Should -Be 'pending'
        (Find-TreeNode -Tree @($n1.tree) -Name 'Extensions') | Should -BeNullOrEmpty
    }

    It 'node01 updating its OS image (Download) and node02 bootstrapping (ArcConfiguration > ArcRegistration), read on the nodes' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } })
        $probe = @{
            'node-01' = New-Probe -Update 'arc-zeroday-update-inprogress.json' -Bootstrap 'arc-bootstrap-notstarted.json'
            'node-02' = New-Probe -Update 'arc-zeroday-update-notstarted.json' -Bootstrap 'arc-bootstrap-inprogress.json'
        }

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:ArcNow -NodeProbe $probe
        ($script:ArmCalls -match '/extensions\?') | Should -BeNullOrEmpty
        $state.provisioning.status | Should -Be 'running'
        $state.phase | Should -Be 'arc-registration'

        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'UpdatingOsImage'
        $n1.status | Should -Be 'running'
        $n1.lifecycleMessage | Should -Match 'Download'
        $n1.lifecycleMessage | Should -Match '40-45 minutes, then a reboot'
        $n1.update.done | Should -Be 1
        $n1.update.total | Should -Be 3
        $n1.update.current | Should -Be 'Download'
        $n1.probe.state | Should -Be 'ok'
        $n1.probe.transport | Should -Be 'winrm'
        $update = $n1.tree[0]
        $update['name'] | Should -Be 'OS image update'
        $update['rawStatus'] | Should -Be 'InProgress'
        @($update['children'] | ForEach-Object { $_['name'] }) | Should -Be @('Scan', 'Download', 'Install')
        $download = Find-TreeNode -Tree @($update) -Name 'Download'
        $download['status'] | Should -Be 'running'
        $download['durationSeconds'] | Should -Be 4650
        $install = Find-TreeNode -Tree @($update) -Name 'Install'
        $install['status'] | Should -Be 'notstarted'
        $install['start'] | Should -BeNullOrEmpty -Because 'a NotStarted entry reports the time of the call as StartTime'
        $install['durationSeconds'] | Should -BeNullOrEmpty
        $n1.tree[1]['status'] | Should -Be 'notstarted'
        $n1.tree[1]['start'] | Should -BeNullOrEmpty
        $n1.percent | Should -Be 7 -Because '1 of 3 update steps, 0 of 9 bootstrap steps, 0 of 2 Azure steps'

        $n2 = $state.provisioning.nodes[1]
        $n2.lifecycle | Should -Be 'Bootstrapping'
        $n2.lifecycleMessage | Should -Be 'Bootstrapping: ArcConfiguration > ArcRegistration.'
        $n2.bootstrap.done | Should -Be 7
        $n2.bootstrap.total | Should -Be 9
        $n2.update.status | Should -Be 'notstarted'
        $boot = $n2.tree[1]
        @($boot['children'] | ForEach-Object { $_['name'] }) | Should -Be @('NetworkConfig', 'RemoteConfig', 'WebProxy', 'TimeServer', 'HostName', 'ArcConfiguration')
        @((Find-TreeNode -Tree @($boot) -Name 'ArcConfiguration')['children'] | ForEach-Object { $_['name'] }) | Should -Be @('ArtifactsUpload', 'ConnectivityValidation', 'ArcRegistration', 'ArcExtensionInstall')
        (Find-TreeNode -Tree @($boot) -Name 'ArcRegistration')['durationSeconds'] | Should -Be 1080
        $n2.percent | Should -Be 64 -Because 'the update has not started (current image): 7 of 9 bootstrap + 0 of 2 Azure steps'

        $state.current.phase | Should -Be 'arc-registration'
        $state.current.stepPath | Should -Be @('node-02', 'bootstrap', 'bootstrap.5', 'bootstrap.5.2')
        $state.current.stepName | Should -Be 'ArcRegistration'
    }

    It 'a failed update and a failed bootstrap show the Errors text inline, masked; the phase is failed' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 404 $null)
        $probe = @{
            'node-01' = New-Probe -Update 'arc-zeroday-update-failed.json' -Bootstrap 'arc-bootstrap-notstarted.json'
            'node-02' = New-Probe -Update 'arc-zeroday-update-notstarted.json' -Bootstrap 'arc-bootstrap-failed.json'
        }

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:ArcNow -NodeProbe $probe -Secret @('device code')
        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'Failed'
        $n1.status | Should -Be 'error'
        $n1.errors | Should -Contain 'OS image update: Zero-day update failed.' -Because 'a failed entry with no Errors[] shows its Message'
        $n1.errors | Should -Contain 'OS image update > Download: Download of the solution update failed: the connection was closed. password=***'
        $n1.lifecycleMessage | Should -BeLike 'Failed: *'
        (Find-TreeNode -Tree @($n1.tree) -Name 'Download')['errors'] | Should -Be @('Download of the solution update failed: the connection was closed. password=***')

        $n2 = $state.provisioning.nodes[1]
        $n2.lifecycle | Should -Be 'Failed'
        $n2.errors | Should -Contain 'Bootstrap > ArcConfiguration > ArcRegistration: Arc registration failed: the *** expired. Rerun with a new ARM token.'
        (Find-TreeNode -Tree @($n2.tree) -Name 'ArcRegistration')['rawStatus'] | Should -Be 'Failed'
        (ConvertTo-Json -InputObject $state -Depth 64 -Compress) | Should -Not -Match 'hunter2|device code'

        $state.provisioning.status | Should -Be 'error'
        $state.phase | Should -Be 'failed'
        $state.activePhase | Should -Be 'arc-registration'
    }

    It 'Arc Connected while the bootstrap is still in ArcExtensionInstall stays Bootstrapping' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        $json = Get-Fixture 'arc-bootstrap-inprogress.json' | ConvertFrom-Json -Depth 64
        $arcCfg = $json.Response.DetailedResponse[5]
        $arcCfg.DetailedResponse[2].Status = 'Succeeded'
        $arcCfg.DetailedResponse[2].EndTime = '2026-10-11T06:20:00Z'
        $arcCfg.DetailedResponse[3].Status = 'InProgress'
        $arcCfg.DetailedResponse[3].StartTime = '2026-10-11T06:20:00Z'
        $entry = New-Probe -Update 'arc-zeroday-update-notstarted.json' -Bootstrap 'arc-bootstrap-notstarted.json'
        $entry.bootstrapJson = ConvertTo-Json -InputObject $json -Depth 64
        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:ArcNow -NodeProbe @{ 'node-01' = $entry }
        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'Bootstrapping'
        $n1.lifecycleMessage | Should -Be 'Bootstrapping: ArcConfiguration > ArcExtensionInstall.'
        $n1.tree[2]['status'] | Should -Be 'success' -Because 'the Arc machine is Connected'
        $state.provisioning.readyForValidate | Should -BeFalse
    }

    It 'Registered on every node (Arc Connected, bootstrap Succeeded): Ready for Validate, and the probe stops' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        $probe = @{
            'node-01' = New-Probe -Update 'arc-zeroday-update-succeeded.json' -Bootstrap 'arc-bootstrap-succeeded.json'
            'node-02' = New-Probe -Update 'arc-zeroday-update-notstarted.json' -Bootstrap 'arc-bootstrap-succeeded.json'
        }
        $config = New-RouteConfig -Route 'oem-image'
        $state = Get-AzlSonarDeploymentState -Config $config -Now $script:ArcNow -NodeProbe $probe
        foreach ($n in $state.provisioning.nodes) {
            $n.lifecycle | Should -Be 'Registered'
            $n.status | Should -Be 'success'
            $n.percent | Should -Be 100
            $n.lifecycleMessage | Should -Match 'Connected and bootstrap Succeeded'
        }
        $state.provisioning.nodes[0].update.status | Should -Be 'success'
        $state.provisioning.nodes[0].update.start | Should -Be '2026-10-11T05:10:00Z'
        $state.provisioning.status | Should -Be 'success'
        $state.provisioning.readyForValidate | Should -BeTrue
        $state.phase | Should -Be 'arc-registration' -Because 'registered machines wait for Validate; only deployment success is done'
        ($script:ArmCalls -match '/extensions\?') | Should -BeNullOrEmpty

        $plan = InModuleScope AzlSonar -Parameters @{ S = $state; C = $config; P = $probe } { param($S, $C, $P) Get-AzlSonarNodeProbePlan -State $S -Config $C -Probe $P }
        @($plan).Count | Should -Be 0 -Because 'every node is Connected with bootstrap Succeeded'
    }

    It 'nodes without the bootstrap cmdlets (other images): Registered from Azure alone, the groups say why they are empty' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:ArcNow -NodeProbe @{ 'node-01' = (New-Probe) }
        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'Registered'
        $n1.lifecycleMessage | Should -Match 'Get-ArcBootstrapStatus is not on this node'
        $n1.update.available | Should -BeFalse
        $n1.tree[0]['rawStatus'] | Should -Be 'NotAvailable'
        $n1.tree[1]['description'] | Should -Match 'Get-ArcBootstrapStatus is not on this node'
        $state.provisioning.nodes[1].lifecycleMessage | Should -Match 'bootstrap status was not read from the node' -Because 'node-02 was never read'
    }

    It 'a node that stops answering (reboot after the OS image update) keeps its data: Rebooting / unreachable since, not Failed' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 404 $null)
        $ok = New-Probe -Update 'arc-zeroday-update-inprogress.json' -Bootstrap 'arc-bootstrap-notstarted.json'
        $down = InModuleScope AzlSonar -Parameters @{ P = $ok; T = $script:ArcNow.AddMinutes(2) } { param($P, $T) Update-AzlSonarNodeProbeEntry -Previous $P -Failure 'WinRM: The WinRM client cannot complete the operation.' -Now $T }
        $still = InModuleScope AzlSonar -Parameters @{ P = $down; T = $script:ArcNow.AddMinutes(4) } { param($P, $T) Update-AzlSonarNodeProbeEntry -Previous $P -Failure 'WinRM: timeout' -Now $T }
        $still.state | Should -Be 'unreachable'
        $still.unreachableSince | Should -Be '2026-10-11T06:32:00Z' -Because 'the first failed attempt is kept'
        $still.updateJson | Should -Be $ok.updateJson
        $still.transport | Should -Be 'winrm'

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:ArcNow -NodeProbe @{ 'node-01' = $still }
        $n1 = $state.provisioning.nodes[0]
        $n1.lifecycle | Should -Be 'UpdatingOsImage'
        $n1.status | Should -Be 'running'
        $n1.lifecycleMessage | Should -Match 'Rebooting / unreachable since 2026-10-11T06:32:00Z\.$'
        $n1.probe.state | Should -Be 'unreachable'
        $n1.probe.reason | Should -Be 'WinRM: timeout'
        $n1.probe.unreachableSince | Should -Be '2026-10-11T06:32:00Z'

        $back = InModuleScope AzlSonar -Parameters @{ P = $still } { param($P) Update-AzlSonarNodeProbeEntry -Previous $P -Result ([pscustomobject]@{ update = @{ available = $true; json = '{}' }; bootstrap = @{ available = $false } }) -Transport 'ssh' }
        $back.state | Should -Be 'ok'
        $back.unreachableSince | Should -BeNullOrEmpty
        $back.bootstrapAvailable | Should -BeFalse
        $back.transport | Should -Be 'ssh'
    }

    It 'the mandatory extensions appear only once a validation exists, in their own group (Creating runs, Failed shows its message)' {
        $settings = [pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Validate'; provisioningState = 'Succeeded'; reportedProperties = [pscustomobject]@{ validationStatus = (Get-SonarValidationFixture); deploymentStatus = [pscustomobject]@{} } } }
        $script:ArmRoutes.Clear()
        Add-ArmRoute 'deploymentSettings/default' (New-SonarArmResponse 200 $settings)
        $extensions = @(
            New-Extension -Name 'AzureEdgeDeviceManagement' -State 'Succeeded' -Message 'Enable succeeded' -Modified '2026-10-10T17:50:00Z'
            New-Extension -Name 'AzureEdgeLifecycleManager' -State 'Creating' -Created '2026-10-10T17:55:00Z'
            New-Extension -Name 'AzureEdgeTelemetryAndDiagnostics' -State 'Failed' -Message 'Extension install failed: password=hunter2 rejected' -Modified '2026-10-10T17:58:00Z'
            New-Extension -Name 'SomeOtherExtension' -State 'Failed' -Message 'not mandatory'
        )
        Add-ArmRoute 'machines/node-01/extensions\?' (New-SonarArmResponse 200 @{ value = $extensions })
        Add-ArmRoute 'machines/node-02/extensions\?' (New-SonarArmResponse 200 @{ value = @() })
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 200 (Get-ArcBody))
        Add-ArmRoute 'edgeMachines\?' (New-SonarArmResponse 200 @{ value = @() })

        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig) -Now $script:Now
        $state.provisioning.route | Should -Be 'oem-image'
        $state.provisioning.routeSource | Should -Be 'auto'
        $state.phase | Should -Be 'validation'
        $state.provisioning.readyForValidate | Should -BeFalse -Because 'validation has started'
        $script:ArmCalls | Should -Contain '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/node-01/extensions?api-version=2024-07-10'
        @($state.provisioning.nodes[0].tree | ForEach-Object { $_['name'] }) | Should -Be @('OS image update', 'Bootstrap', 'Azure registration') -Because 'the extensions are not part of Arc registration'

        $state.extensions.shown | Should -BeTrue
        $state.extensions.status | Should -Be 'error'
        $e1 = $state.extensions.nodes[0]
        $e1.name | Should -Be 'node-01'
        $e1.status | Should -Be 'error'
        $e1.ready | Should -Be 1
        $e1.total | Should -Be 4
        $e1.errors | Should -Be @('AzureEdgeTelemetryAndDiagnostics: Extension install failed: password=*** rejected')
        @($e1.tree | ForEach-Object { $_['name'] }) | Should -Be @('AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics')
        $tele = Find-TreeNode -Tree @($e1.tree) -Name 'AzureEdgeTelemetryAndDiagnostics'
        $tele['status'] | Should -Be 'error'
        $tele['errors'] | Should -Be @('Extension install failed: password=*** rejected')
        $tele['end'] | Should -Be '2026-10-10T17:58:00Z'
        $lcm = Find-TreeNode -Tree @($e1.tree) -Name 'AzureEdgeLifecycleManager'
        $lcm['status'] | Should -Be 'running'
        $lcm['durationSeconds'] | Should -Be 300
        (Find-TreeNode -Tree @($e1.tree) -Name 'AzureEdgeRemoteSupport')['status'] | Should -Be 'notstarted'
        (Find-TreeNode -Tree @($e1.tree) -Name 'SomeOtherExtension') | Should -BeNullOrEmpty
        $state.extensions.nodes[1].status | Should -Be 'notstarted'
    }

    It 'an unreadable Arc machine is Unknown with a warning, not NotStarted' {
        Add-ArmRoute 'HybridCompute/machines/' (New-SonarArmResponse 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'no read access' } })
        $state = Get-AzlSonarDeploymentState -Config (New-RouteConfig -Route 'oem-image') -Now $script:Now
        $state.provisioning.nodes[0].lifecycle | Should -Be 'Unknown'
        $state.provisioning.nodes[0].status | Should -Be 'unknown'
        $state.warnings | Should -Contain 'Arc machine node-01: no read access'
    }
}

Describe 'Node probe (Arc registration status read on the node)' {
    BeforeAll {
        $script:ProbeConfig = New-RouteConfig -Route 'oem-image'
        function New-PlanState {
            param([string]$Route = 'oem-image', [string]$Phase = 'arc-registration', [string[]]$Connected = @())
            return [ordered]@{
                activePhase  = $Phase
                provisioning = [ordered]@{ route = $Route }
                nodes        = @(foreach ($n in 'node-01', 'node-02') { [ordered]@{ name = $n; arcStatus = $(if ($Connected -contains $n) { 'Connected' } else { 'NotFound' }) } })
            }
        }
        function Get-Plan {
            param($State, $Probe)
            $plan = InModuleScope AzlSonar -Parameters @{ S = $State; C = $script:ProbeConfig; P = $Probe } { param($S, $C, $P) Get-AzlSonarNodeProbePlan -State $S -Config $C -Probe $P }
            return [string[]]$plan
        }
    }

    It 'probes only on the OEM image route while Arc registration is the active phase' {
        Get-Plan (New-PlanState) @{} | Should -Be @('node-01', 'node-02')
        @(Get-Plan (New-PlanState -Route 'simplified') @{}).Count | Should -Be 0
        @(Get-Plan (New-PlanState -Phase 'validation') @{}).Count | Should -Be 0
        @(Get-Plan $null @{}).Count | Should -Be 0 -Because 'no state yet (provisioningRoute auto before the first poll)'
    }

    It 'stops probing a node once it is Connected and its bootstrap Succeeded (or the cmdlet is not on it)' {
        $done = @{ state = 'ok'; lastSuccessUtc = '2026-10-11T06:30:00Z'; bootstrapAvailable = $true; bootstrapJson = (Get-Fixture 'arc-bootstrap-succeeded.json') }
        $running = @{ state = 'ok'; lastSuccessUtc = '2026-10-11T06:30:00Z'; bootstrapAvailable = $true; bootstrapJson = (Get-Fixture 'arc-bootstrap-inprogress.json') }
        $none = @{ state = 'ok'; lastSuccessUtc = '2026-10-11T06:30:00Z'; bootstrapAvailable = $false; bootstrapJson = $null }
        Get-Plan (New-PlanState -Connected 'node-01', 'node-02') @{ 'node-01' = $done; 'node-02' = $running } | Should -Be @('node-02')
        Get-Plan (New-PlanState -Connected 'node-02') @{ 'node-01' = $done; 'node-02' = $none } | Should -Be @('node-01') -Because 'node-01 bootstrap Succeeded but its Arc machine is not Connected yet'
        @(Get-Plan (New-PlanState -Connected 'node-01', 'node-02') @{ 'node-01' = $done; 'node-02' = $none }).Count | Should -Be 0
        Get-Plan (New-PlanState -Connected 'node-01') @{} | Should -Be @('node-01', 'node-02') -Because 'Connected but never read'
    }

    It 'the remote script is read-only: it calls only Get-* status commands and read-only helpers' {
        $probeScript = InModuleScope AzlSonar { Get-AzlSonarNodeProbeScript }
        $names = @($probeScript.Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        $names | Should -Be @('ConvertTo-Json', 'ForEach-Object', 'Get-Command', 'Select-Object', 'Where-Object')
        $probeScript.ToString() | Should -Match "'Get-ArcZeroDaySolutionUpdateStatus'"
        $probeScript.ToString() | Should -Match "'Get-ArcBootstrapStatus'"
        $probeScript.ToString() | Should -Match "ErrorAction = 'SilentlyContinue'"
    }

    It 'the remote script reports a missing cmdlet as not available, uses -JsonResult when offered and turns objects into JSON' {
        $probeScript = InModuleScope AzlSonar { Get-AzlSonarNodeProbeScript }
        try {
            Remove-Item -Path 'function:global:Get-ArcBootstrapStatus', 'function:global:Get-ArcZeroDaySolutionUpdateStatus' -ErrorAction SilentlyContinue
            $missing = InModuleScope AzlSonar -Parameters @{ O = (& $probeScript) } { param($O) ConvertFrom-AzlSonarProbeOutput -Output $O }
            $missing.update.available | Should -BeFalse
            $missing.bootstrap.available | Should -BeFalse
            $missing.update.error | Should -BeNullOrEmpty

            Set-Item -Path 'function:global:Get-ArcZeroDaySolutionUpdateStatus' -Value { [CmdletBinding()] param([switch]$JsonResult) if ($JsonResult) { '{"Version":"V1","Response":{"Name":"Update","Status":"NotStarted"}}' } else { throw 'expected -JsonResult' } }
            Set-Item -Path 'function:global:Get-ArcBootstrapStatus' -Value {
                [CmdletBinding()] param()
                [pscustomobject]@{ Version = 'V1'; Response = [pscustomobject]@{ Name = 'Bootstrap'; Status = [System.DayOfWeek]::Monday; StartTime = [datetime]::new(2026, 10, 11, 6, 0, 0, [System.DateTimeKind]::Utc); Errors = @(); DetailedResponse = @([pscustomobject]@{ Name = 'NetworkConfig'; Status = 'Succeeded' }) } }
            }
            $read = InModuleScope AzlSonar -Parameters @{ O = (& $probeScript) } { param($O) ConvertFrom-AzlSonarProbeOutput -Output $O }
            $read.update.available | Should -BeTrue
            ($read.update.json | ConvertFrom-Json).Response.Status | Should -Be 'NotStarted'
            $read.bootstrap.json | Should -Match '"StartTime":"2026-10-11T06:00:00(\.0+)?Z"' -Because 'dates travel as ISO 8601 UTC'
            $boot = ($read.bootstrap.json | ConvertFrom-Json).Response
            $boot.Status | Should -Be 'Monday' -Because 'enums travel as names'
            @($boot.DetailedResponse).Count | Should -Be 1
            $boot.DetailedResponse[0].Name | Should -Be 'NetworkConfig'
        }
        finally {
            Remove-Item -Path 'function:global:Get-ArcBootstrapStatus', 'function:global:Get-ArcZeroDaySolutionUpdateStatus' -ErrorAction SilentlyContinue
        }
    }

    It 'reads the result between the markers and fails clearly without them' {
        InModuleScope AzlSonar {
            $r = ConvertFrom-AzlSonarProbeOutput -Output @('noise', '<<AZLSONAR>>{"update":{"available":true,"json":"{}"},"bootstrap":{"available":false}}<<END>>')
            $r.update.available | Should -BeTrue
            { ConvertFrom-AzlSonarProbeOutput -Output 'Access is denied.' } | Should -Throw '*no result*Access is denied.*'
        }
    }

    It 'the loop reads every unfinished node, records an unreachable node and stops on the stop flag' {
        InModuleScope AzlSonar -Parameters @{ C = $script:ProbeConfig } {
            param($C)
            $shared = [hashtable]::Synchronized(@{ Stop = $false; NodeProbe = [hashtable]::Synchronized(@{}); State = [ordered]@{
                        activePhase = 'arc-registration'; provisioning = [ordered]@{ route = 'oem-image' }
                        nodes = @([ordered]@{ name = 'node-01'; arcStatus = 'NotFound' }, [ordered]@{ name = 'node-02'; arcStatus = 'NotFound' }) } })
            Mock Open-AzlSonarNodeConnection {
                if ($Address -eq '192.0.2.12') { return @{ Session = $null; Ssh = $null; Reason = 'WinRM: cannot connect' } }
                @{ Session = [pscustomobject]@{ State = 'Opened' }; Ssh = $null; Reason = $null }
            }
            Mock Invoke-AzlSonarNodeProbe { [pscustomobject]@{ update = @{ available = $true; json = $null; error = 'The command returned nothing.' }; bootstrap = @{ available = $true; json = '{"Version":"V1","Response":{"Name":"Bootstrap","Status":"InProgress"}}' } } }
            Mock Close-AzlSonarNodeConnection { }
            Mock Wait-AzlSonarInterval { $Shared.Stop = $true }

            Invoke-AzlSonarNodeProbeLoop -Shared $shared -Config $C -Credential $null

            $shared.NodeProbe['node-01'].state | Should -Be 'ok'
            $shared.NodeProbe['node-01'].transport | Should -Be 'winrm'
            $shared.NodeProbe['node-01'].bootstrapJson | Should -Be '{"Version":"V1","Response":{"Name":"Bootstrap","Status":"InProgress"}}'
            $shared.NodeProbe['node-01'].updateError | Should -Be 'The command returned nothing.'
            $shared.NodeProbe['node-02'].state | Should -Be 'unreachable'
            $shared.NodeProbe['node-02'].reason | Should -Be 'WinRM: cannot connect'
            Should -Invoke Invoke-AzlSonarNodeProbe -Times 1 -Exactly
            Should -Invoke Close-AzlSonarNodeConnection -Times 1 -Exactly -Because 'the open session is closed when the loop ends'
        }
    }

    It 'the poller passes the probe records and the secrets to the state' {
        InModuleScope AzlSonar -Parameters @{ C = $script:ProbeConfig } {
            param($C)
            $shared = Initialize-AzlSonarSharedState
            $shared.Redact = @('s3cret-value')
            $shared.NodeProbe['node-01'] = @{ state = 'ok' }
            Mock Get-AzlSonarDeploymentState { Get-AzlSonarInitialState -Config $Config }
            Mock Wait-AzlSonarInterval { $Shared.Stop = $true }
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            Should -Invoke Get-AzlSonarDeploymentState -Times 1 -Exactly -ParameterFilter { $NodeProbe.Contains('node-01') -and $Secret -contains 's3cret-value' }
            $shared.StateJson | Should -Match '"readyForValidate":false'
            $shared.StateJson | Should -Match '"extensions":\{"shown":false'
        }
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
