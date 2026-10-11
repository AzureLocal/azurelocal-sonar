Set-StrictMode -Version Latest

$script:AzlSonarArcApiVersion = '2024-07-10'

function Invoke-AzlSonarArmGet {
    <#
    .SYNOPSIS
        One read-only ARM GET through the signed-in Az PowerShell context (Invoke-AzRestMethod).
    .OUTPUTS
        { StatusCode, Body (parsed JSON or $null), ErrorMessage }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $response = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
    $code = [int](Get-AzlSonarMember $response 'StatusCode' 0)
    $content = [string](Get-AzlSonarMember $response 'Content' '')
    $body = $null
    if (-not [string]::IsNullOrWhiteSpace($content)) {
        try { $body = ConvertFrom-Json -InputObject $content -Depth 64 } catch { $body = $null }
    }
    $message = $null
    if ($code -ge 400) {
        $message = [string](Get-AzlSonarMember $body 'error.message' '')
        if (-not $message) { $message = "HTTP $code" }
    }
    return [pscustomobject]@{ StatusCode = $code; Body = $body; ErrorMessage = $message }
}

function Get-AzlSonarResourceGroupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Config)

    return '/subscriptions/{0}/resourceGroups/{1}' -f [uri]::EscapeDataString($Config.subscriptionId), [uri]::EscapeDataString($Config.resourceGroup)
}

function Get-AzlSonarArcMachineStatus {
    <#
    .SYNOPSIS
        Reads the Arc machine of every configured node (Connected/Disconnected, last change, agent version).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [System.Collections.Generic.List[string]]$Warnings
    )

    $rgPath = Get-AzlSonarResourceGroupPath -Config $Config
    foreach ($node in $Config.nodes) {
        $result = [ordered]@{
            name             = $node.name
            arcMachineName   = $node.arcMachineName
            seed             = [bool]$node.seed
            arcStatus        = 'Unknown'
            lastStatusChange = $null
            agentVersion     = $null
        }
        try {
            $path = '{0}/providers/Microsoft.HybridCompute/machines/{1}?api-version={2}' -f $rgPath, [uri]::EscapeDataString($node.arcMachineName), $script:AzlSonarArcApiVersion
            $response = Invoke-AzlSonarArmGet -Path $path
            if ($response.StatusCode -eq 200) {
                $result.arcStatus = [string](Get-AzlSonarMember $response.Body 'properties.status' 'Unknown')
                $result.lastStatusChange = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $response.Body 'properties.lastStatusChange'))
                $result.agentVersion = Get-AzlSonarMember $response.Body 'properties.agentVersion'
            }
            elseif ($response.StatusCode -eq 404) {
                $result.arcStatus = 'NotFound'
            }
            elseif ($null -ne $Warnings) {
                $Warnings.Add("Arc machine $($node.arcMachineName): $($response.ErrorMessage)")
            }
        }
        catch {
            if ($null -ne $Warnings) { $Warnings.Add("Arc machine $($node.arcMachineName): $($_.Exception.Message)") }
        }
        $result
    }
}

function Get-AzlSonarEdgeMachine {
    <#
    .SYNOPSIS
        Best effort: the resource group's edge machines (simplified machine provisioning) and their ProvisionOs job.
    .DESCRIPTION
        Ignores 404 and 400 (the resource type exists only from edgeApiVersion 2025-12-01-preview, and a resource
        group without edge machines is normal). The job's validationStatus and deploymentStatus are converted with
        ConvertTo-AzlSonarStepTree.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [datetime]$Now = [datetime]::UtcNow,

        [System.Collections.Generic.List[string]]$Warnings
    )

    $rgPath = Get-AzlSonarResourceGroupPath -Config $Config
    $apiVersion = $Config.edgeApiVersion
    try {
        $list = Invoke-AzlSonarArmGet -Path ('{0}/providers/Microsoft.AzureStackHCI/edgeMachines?api-version={1}' -f $rgPath, $apiVersion)
    }
    catch {
        if ($null -ne $Warnings) { $Warnings.Add("edgeMachines: $($_.Exception.Message)") }
        return
    }
    if ($list.StatusCode -in 400, 404) { return }
    if ($list.StatusCode -ne 200) {
        if ($null -ne $Warnings) { $Warnings.Add("edgeMachines: $($list.ErrorMessage)") }
        return
    }

    foreach ($machine in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $list.Body 'value'))) {
        $name = [string](Get-AzlSonarMember $machine 'name' '')
        $id = [string](Get-AzlSonarMember $machine 'id' '')
        $properties = Get-AzlSonarMember $machine 'properties'
        $arcId = [string](Get-AzlSonarMember $properties 'arcMachineResourceId' '')
        $arcName = if ($arcId) { $arcId.TrimEnd('/').Split('/')[-1] } else { $null }
        $nodeName = $null
        foreach ($node in $Config.nodes) {
            if ($node.name -eq $name -or ($arcName -and $node.arcMachineName -eq $arcName)) { $nodeName = $node.name }
        }

        $job = [ordered]@{
            status          = $null
            percentComplete = $null
            validation      = [ordered]@{ status = 'notstarted'; tree = @() }
            deployment      = [ordered]@{ status = 'notstarted'; tree = @() }
        }
        if ($id) {
            try {
                $jobPath = '{0}/jobs/ProvisionOs?api-version={1}' -f $id, $apiVersion
                $jobResponse = Invoke-AzlSonarArmGet -Path $jobPath
                if ($jobResponse.StatusCode -eq 200) {
                    $jobProperties = Get-AzlSonarMember $jobResponse.Body 'properties'
                    $reported = Get-AzlSonarMember $jobProperties 'reportedProperties'
                    $job.status = Get-AzlSonarMember $jobProperties 'status'
                    $job.percentComplete = Get-AzlSonarMember $reported 'percentComplete'
                    foreach ($kind in 'validation', 'deployment') {
                        $statusObject = Get-AzlSonarMember $reported "${kind}Status"
                        if ($null -eq $statusObject) { $statusObject = Get-AzlSonarMember $jobProperties "${kind}Status" }
                        $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $statusObject -Now $Now)
                        $job[$kind] = [ordered]@{
                            status = Get-AzlSonarRollupStatus -RawStatus (Get-AzlSonarMember $statusObject 'status') -Tree $tree
                            tree   = $tree
                        }
                    }
                }
                elseif ($jobResponse.StatusCode -notin 400, 404 -and $null -ne $Warnings) {
                    $Warnings.Add("edgeMachines/$name/jobs/ProvisionOs: $($jobResponse.ErrorMessage)")
                }
            }
            catch {
                if ($null -ne $Warnings) { $Warnings.Add("edgeMachines/$name/jobs/ProvisionOs: $($_.Exception.Message)") }
            }
        }

        [ordered]@{
            name                 = $name
            node                 = $nodeName
            provisioningState    = Get-AzlSonarMember $properties 'provisioningState'
            lifecycle            = Get-AzlSonarMember $properties 'lifecycleDetails.lifecycleStatus.status'
            machineState         = Get-AzlSonarMember $properties 'machineState'
            connectivityStatus   = Get-AzlSonarMember $properties 'connectivityStatus'
            arcMachineName       = $arcName
            provisionOsJob       = $job
        }
    }
}

function Get-AzlSonarInitialState {
    <#
    .SYNOPSIS
        The state served before the first successful poll (and the base when a poll fails with no earlier state).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $nodes = foreach ($node in $Config.nodes) {
        [ordered]@{ name = $node.name; arcMachineName = $node.arcMachineName; seed = [bool]$node.seed; arcStatus = 'Unknown'; lastStatusChange = $null; agentVersion = $null }
    }
    $emptyCounts = Measure-AzlSonarStepTree -Tree @()
    return [ordered]@{
        cluster           = $Config.clusterName
        resourceGroup     = $Config.resourceGroup
        mode              = $null
        provisioningState = $null
        phase             = 'provisioning'
        validation        = [ordered]@{ status = 'notstarted'; tree = @(); counts = $emptyCounts }
        deployment        = [ordered]@{ status = 'notstarted'; tree = @(); counts = (Measure-AzlSonarStepTree -Tree @()) }
        nodes             = @($nodes)
        edgeMachines      = @()
        current           = [ordered]@{ phase = 'provisioning'; stepPath = @(); stepNames = @(); stepName = $null; stepId = $null; status = $null }
        warnings          = @()
        pollError         = $null
        polledAt          = $null
    }
}

function Get-AzlSonarDeploymentState {
    <#
    .SYNOPSIS
        Reads the deployment state of an Azure Local instance from Azure (read-only) and normalises it.
    .DESCRIPTION
        GETs deploymentSettings/default (validation and deployment step trees, mode, provisioning state), the Arc
        machine of every node and, best effort, the edge machines of the resource group with their ProvisionOs job.
        Uses Invoke-AzRestMethod with the signed-in Az PowerShell context. Never writes to Azure.
        A 404 on deploymentSettings is not an error: the instance is still being provisioned.
    .PARAMETER Config
        A config object from Read-AzlSonarConfig.
    .PARAMETER ConfigPath
        Path to a config file (read with Read-AzlSonarConfig).
    .PARAMETER Now
        The poll time (UTC); used for polledAt and running-step durations. Defaults to now.
    .EXAMPLE
        Get-AzlSonarDeploymentState -ConfigPath ./config/clus01.json | ConvertTo-Json -Depth 20
    .OUTPUTS
        Ordered dictionary: cluster, resourceGroup, mode, provisioningState, phase, validation{status,tree,counts},
        deployment{status,tree,counts}, nodes[], edgeMachines[], current{phase,stepPath(ids),stepNames,stepName,stepId,status},
        warnings[], pollError, polledAt.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Config')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Config', Position = 0)]
        [object]$Config,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string]$ConfigPath,

        [datetime]$Now = [datetime]::UtcNow
    )

    $ErrorActionPreference = 'Stop'
    if ($PSCmdlet.ParameterSetName -eq 'Path') { $Config = Read-AzlSonarConfig -Path $ConfigPath }
    $Now = $Now.ToUniversalTime()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $rgPath = Get-AzlSonarResourceGroupPath -Config $Config

    $settingsPath = '{0}/providers/Microsoft.AzureStackHCI/clusters/{1}/deploymentSettings/default?api-version={2}' -f $rgPath, [uri]::EscapeDataString($Config.clusterName), $Config.apiVersion
    $settings = Invoke-AzlSonarArmGet -Path $settingsPath
    $properties = $null
    if ($settings.StatusCode -eq 200) {
        $properties = Get-AzlSonarMember $settings.Body 'properties'
    }
    elseif ($settings.StatusCode -eq 404) {
        $warnings.Add("deploymentSettings for $($Config.clusterName) not found yet (instance not created or deployment not started).")
    }
    else {
        throw "GET deploymentSettings for $($Config.clusterName) failed: $($settings.ErrorMessage)"
    }

    $validationObject = Get-AzlSonarMember $properties 'reportedProperties.validationStatus'
    $deploymentObject = Get-AzlSonarMember $properties 'reportedProperties.deploymentStatus'
    $validationTree = @(ConvertTo-AzlSonarStepTree -StatusObject $validationObject -Now $Now)
    $deploymentTree = @(ConvertTo-AzlSonarStepTree -StatusObject $deploymentObject -Now $Now)
    $validationStatus = Get-AzlSonarRollupStatus -RawStatus (Get-AzlSonarMember $validationObject 'status') -Tree $validationTree
    $deploymentStatus = Get-AzlSonarRollupStatus -RawStatus (Get-AzlSonarMember $deploymentObject 'status') -Tree $deploymentTree

    $nodes = @(Get-AzlSonarArcMachineStatus -Config $Config -Warnings $warnings)
    $edgeMachines = @(Get-AzlSonarEdgeMachine -Config $Config -Now $Now -Warnings $warnings)

    $phaseInfo = Get-AzlSonarPhase -ValidationTree $validationTree -ValidationStatus $validationStatus -DeploymentTree $deploymentTree -DeploymentStatus $deploymentStatus
    $active = $phaseInfo.activePhase
    $current = switch ($active) {
        'deployment' { Get-AzlSonarCurrentStep -Tree $deploymentTree -Phase 'deployment' }
        'validation' { Get-AzlSonarCurrentStep -Tree $validationTree -Phase 'validation' }
        default {
            # Provisioning: one synthetic parent per edge machine so stepPath starts with the machine name.
            $machineTree = foreach ($machine in $edgeMachines) {
                $job = $machine.provisionOsJob
                $children = @($job.validation.tree) + @($job.deployment.tree)
                if ($children.Count -gt 0) {
                    [ordered]@{ id = $machine.name; name = $machine.name; status = 'notstarted'; start = $null; end = $null; children = $children }
                }
            }
            Get-AzlSonarCurrentStep -Tree @($machineTree) -Phase 'provisioning'
        }
    }

    return [ordered]@{
        cluster           = $Config.clusterName
        resourceGroup     = $Config.resourceGroup
        mode              = Get-AzlSonarMember $properties 'deploymentMode'
        provisioningState = Get-AzlSonarMember $properties 'provisioningState'
        phase             = $phaseInfo.phase
        validation        = [ordered]@{ status = $validationStatus; tree = $validationTree; counts = (Measure-AzlSonarStepTree -Tree $validationTree) }
        deployment        = [ordered]@{ status = $deploymentStatus; tree = $deploymentTree; counts = (Measure-AzlSonarStepTree -Tree $deploymentTree) }
        nodes             = $nodes
        edgeMachines      = $edgeMachines
        current           = $current
        warnings          = $warnings.ToArray()
        pollError         = $null
        polledAt          = Format-AzlSonarDate $Now
    }
}

function Publish-AzlSonarState {
    <#
    .SYNOPSIS
        Stores a state in the shared table (as JSON), bumps the version and adds it to the timeline when it changed.
    .DESCRIPTION
        The timeline keeps a snapshot only when something other than polledAt and running-step durations changed,
        so a long deployment does not fill memory with identical snapshots. At most TimelineMax (5000) snapshots are
        kept; older ones are dropped and counted in TimelineDropped (reported in the export metadata). The latest
        state is always kept separately (StateJson), so it is never lost to the cap.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$State
    )

    $json = ConvertTo-AzlSonarJson $State
    $key = $json -replace '"polledAt":(null|"[^"]*")', '' -replace '"durationSeconds":\d+', ''
    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        if ($key -ne $Shared.LastStateKey) {
            $Shared.Timeline.Add($json)
            while ($Shared.Timeline.Count -gt $Shared.TimelineMax) {
                $Shared.Timeline.RemoveAt(0)
                if ($Shared.Contains('TimelineDropped')) { $Shared.TimelineDropped = [long]$Shared.TimelineDropped + 1 }
            }
            $Shared.LastStateKey = $key
        }
        $Shared.State = $State
        $Shared.StateJson = $json
        $Shared.StateVersion = [long]$Shared.StateVersion + 1
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Invoke-AzlSonarPollerLoop {
    <#
    .SYNOPSIS
        Background loop: polls Azure every pollSeconds and publishes the state until the shared stop flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [object]$Config
    )

    while (-not $Shared.Stop) {
        try {
            $state = Get-AzlSonarDeploymentState -Config $Config
            Publish-AzlSonarState -Shared $Shared -State $state
        }
        catch {
            $previous = $Shared.State
            $state = [ordered]@{}
            if ($null -eq $previous) { $previous = Get-AzlSonarInitialState -Config $Config }
            foreach ($key in $previous.Keys) { $state[$key] = $previous[$key] }
            $state.pollError = [ordered]@{ message = $_.Exception.Message; at = Format-AzlSonarDate ([datetime]::UtcNow) }
            Publish-AzlSonarState -Shared $Shared -State $state
        }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $Config.pollSeconds
    }
}
