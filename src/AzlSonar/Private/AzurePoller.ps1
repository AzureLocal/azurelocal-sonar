Set-StrictMode -Version Latest

$script:AzlSonarArcApiVersion = '2024-07-10'
# The mandatory Arc extensions of an Azure Local machine (extension resource names on the Arc machine).
$script:AzlSonarMandatoryExtensions = @('AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics')
# An Arc machine resource id Sonar will GET (ids read from Azure are checked against it before use).
$script:AzlSonarArcIdPattern = '^/subscriptions/[^/?#\s]+/resourceGroups/[^/?#\s]+/providers/Microsoft\.HybridCompute/machines/[^/?#\s]+$'

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

function Get-AzlSonarArcResourcePath {
    <#
    .SYNOPSIS
        A Microsoft.HybridCompute/machines resource id that is safe to GET, or $null when it is not one.
    .DESCRIPTION
        Accepts only /subscriptions/{s}/resourceGroups/{rg}/providers/Microsoft.HybridCompute/machines/{name} (any
        case, trailing slash removed), so an id read from Azure can never turn into another request path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    $id = $ResourceId.Trim().TrimEnd('/')
    if ($id -notmatch $script:AzlSonarArcIdPattern) { return $null }
    return $id
}

function Get-AzlSonarResourceLeaf {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    return $ResourceId.TrimEnd('/').Split('/')[-1]
}

function Resolve-AzlSonarArcTarget {
    <#
    .SYNOPSIS
        Works out which Arc machine to read for every configured node.
    .DESCRIPTION
        An explicit nodes[].arcMachineName always wins (resource group of the config; the edge machine's resource id
        is used instead when its name matches). Otherwise, on the simplified route, the Arc machine comes from the
        node's edge machine: the target of its ProvisionOs job (provisioningRequest.onboardingConfiguration.resourceId,
        the <device-id>-1 machine), else properties.arcMachineResourceId (while the OS installs this is the maintenance
        environment's Arc machine). On the OEM image route, or when there is no edge machine, the Arc machine carries
        the node name (Invoke-AzStackHciArcInitialization names it after the host).
        Returns one ordered dictionary per node: name, arcMachineName, arcMachineResourceId, arcSource
        (config | edgeMachine.job | edgeMachine | nodeName).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [ValidateSet('simplified', 'oem-image')]
        [string]$Route,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$EdgeMachines
    )

    $rgPath = Get-AzlSonarResourceGroupPath -Config $Config
    foreach ($node in $Config.nodes) {
        $edge = $null
        foreach ($machine in (ConvertTo-AzlSonarArray $EdgeMachines)) {
            if ($machine.node -eq $node.name) { $edge = $machine; break }
        }
        $edgeId = if ($null -ne $edge) { $edge.targetArcMachineResourceId } else { $null }
        $explicit = [bool](Get-AzlSonarMember $node 'arcMachineNameSet' $true)
        $byName = '{0}/providers/Microsoft.HybridCompute/machines/{1}' -f $rgPath, [uri]::EscapeDataString($node.arcMachineName)

        if ($explicit) {
            $id = if ($edgeId -and (Get-AzlSonarResourceLeaf $edgeId) -eq $node.arcMachineName) { $edgeId } else { $byName }
            [ordered]@{ name = $node.name; arcMachineName = $node.arcMachineName; arcMachineResourceId = $id; arcSource = 'config' }
        }
        elseif ($Route -eq 'simplified' -and $edgeId) {
            [ordered]@{ name = $node.name; arcMachineName = (Get-AzlSonarResourceLeaf $edgeId); arcMachineResourceId = $edgeId; arcSource = $edge.arcSource }
        }
        else {
            [ordered]@{ name = $node.name; arcMachineName = $node.name; arcMachineResourceId = ('{0}/providers/Microsoft.HybridCompute/machines/{1}' -f $rgPath, [uri]::EscapeDataString($node.name)); arcSource = 'nodeName' }
        }
    }
}

function Get-AzlSonarArcMachineStatus {
    <#
    .SYNOPSIS
        Reads the Arc machine of every configured node (Connected/Disconnected, last change, agent version).
    .DESCRIPTION
        -Target comes from Resolve-AzlSonarArcTarget (one entry per node, with the Arc machine's resource id). Without
        it every node is read by its configured arcMachineName in the config's resource group.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Target,

        [System.Collections.Generic.List[string]]$Warnings
    )

    $rgPath = Get-AzlSonarResourceGroupPath -Config $Config
    foreach ($node in $Config.nodes) {
        $resolved = $null
        foreach ($t in (ConvertTo-AzlSonarArray $Target)) { if ($t.name -eq $node.name) { $resolved = $t; break } }
        if ($null -eq $resolved) {
            $resolved = [ordered]@{
                name                 = $node.name
                arcMachineName       = $node.arcMachineName
                arcMachineResourceId = '{0}/providers/Microsoft.HybridCompute/machines/{1}' -f $rgPath, [uri]::EscapeDataString($node.arcMachineName)
                arcSource            = 'config'
            }
        }
        $result = [ordered]@{
            name                 = $node.name
            arcMachineName       = $resolved.arcMachineName
            arcMachineResourceId = $resolved.arcMachineResourceId
            arcSource            = $resolved.arcSource
            seed                 = [bool]$node.seed
            arcStatus            = 'Unknown'
            lastStatusChange     = $null
            agentVersion         = $null
            registeredAt         = $null
        }
        try {
            $path = '{0}?api-version={1}' -f $resolved.arcMachineResourceId, $script:AzlSonarArcApiVersion
            $response = Invoke-AzlSonarArmGet -Path $path
            if ($response.StatusCode -eq 200) {
                $result.arcStatus = [string](Get-AzlSonarMember $response.Body 'properties.status' 'Unknown')
                $result.lastStatusChange = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $response.Body 'properties.lastStatusChange'))
                $result.agentVersion = Get-AzlSonarMember $response.Body 'properties.agentVersion'
                $result.registeredAt = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $response.Body 'systemData.createdAt'))
            }
            elseif ($response.StatusCode -eq 404) {
                $result.arcStatus = 'NotFound'
            }
            elseif ($null -ne $Warnings) {
                $Warnings.Add("Arc machine $($resolved.arcMachineName): $($response.ErrorMessage)")
            }
        }
        catch {
            if ($null -ne $Warnings) { $Warnings.Add("Arc machine $($resolved.arcMachineName): $($_.Exception.Message)") }
        }
        $result
    }
}

function Get-AzlSonarArcExtension {
    <#
    .SYNOPSIS
        The mandatory Azure Local extensions of one Arc machine (OEM image + Arc registration route).
    .DESCRIPTION
        GETs {arc machine}/extensions (api 2024-07-10) and returns one entry per mandatory extension
        (AzureEdgeDeviceManagement, AzureEdgeLifecycleManager, AzureEdgeRemoteSupport, AzureEdgeTelemetryAndDiagnostics):
        { name, present, rawStatus (properties.provisioningState), status (normalised), message
        (properties.instanceView.status.message), start (systemData.createdAt), end (systemData.lastModifiedAt or
        instanceView.status.time once finished) }. A 404 or 400 means no extensions yet. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$ArcMachineResourceId,

        [string]$ArcMachineName = '',

        [System.Collections.Generic.List[string]]$Warnings
    )

    $found = @{}
    try {
        $response = Invoke-AzlSonarArmGet -Path ('{0}/extensions?api-version={1}' -f $ArcMachineResourceId, $script:AzlSonarArcApiVersion)
        if ($response.StatusCode -eq 200) {
            foreach ($ext in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $response.Body 'value'))) {
                $extName = [string](Get-AzlSonarMember $ext 'name' '')
                if ($extName) { $found[$extName] = $ext }
            }
        }
        elseif ($response.StatusCode -notin 400, 404 -and $null -ne $Warnings) {
            $Warnings.Add("Arc machine $ArcMachineName extensions: $($response.ErrorMessage)")
        }
    }
    catch {
        if ($null -ne $Warnings) { $Warnings.Add("Arc machine $ArcMachineName extensions: $($_.Exception.Message)") }
    }

    foreach ($name in $script:AzlSonarMandatoryExtensions) {
        $ext = $null
        foreach ($key in $found.Keys) { if ($key -eq $name) { $ext = $found[$key] } }
        if ($null -eq $ext) {
            [ordered]@{ name = $name; present = $false; rawStatus = $null; status = 'notstarted'; message = $null; start = $null; end = $null }
            continue
        }
        $raw = Get-AzlSonarMember $ext 'properties.provisioningState'
        $status = ConvertTo-AzlSonarStepStatus $raw
        if ($status -eq 'notstarted') { $status = 'running' }
        $message = [string](Get-AzlSonarMember $ext 'properties.instanceView.status.message' '')
        $start = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $ext 'systemData.createdAt')
        $end = $null
        if ($status -in 'success', 'error') {
            $end = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $ext 'systemData.lastModifiedAt')
            if ($null -eq $end) { $end = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $ext 'properties.instanceView.status.time') }
        }
        [ordered]@{
            name      = $name
            present   = $true
            rawStatus = if ($null -eq $raw) { $null } else { [string]$raw }
            status    = $status
            message   = if ($message) { Protect-AzlSonarText -Text $message } else { $null }
            start     = Format-AzlSonarDate $start
            end       = Format-AzlSonarDate $end
        }
    }
}

function ConvertTo-AzlSonarIndexedStep {
    <#
    .SYNOPSIS
        Copies a raw step-like object (step, lifecycle stage) into the deploymentSettings step shape with a fixed id.
    .DESCRIPTION
        Lifecycle stages use subStages; job steps use steps. Ids are set here (fullStepIndex) so every provisioning
        tree node has a stable, unique id whatever the source reports.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Step,

        [Parameter(Mandatory)]
        [string]$Id,

        [string]$ChildKey = 'steps'
    )

    $children = ConvertTo-AzlSonarArray (Get-AzlSonarMember $Step $ChildKey)
    $mapped = for ($i = 0; $i -lt $children.Count; $i++) {
        ConvertTo-AzlSonarIndexedStep -Step $children[$i] -Id "$Id.$i" -ChildKey $ChildKey
    }
    return [pscustomobject]@{
        name          = Get-AzlSonarMember $Step 'name'
        description   = Get-AzlSonarMember $Step 'description'
        fullStepIndex = $Id
        startTimeUtc  = Get-AzlSonarMember $Step 'startTimeUtc'
        endTimeUtc    = Get-AzlSonarMember $Step 'endTimeUtc'
        status        = Get-AzlSonarMember $Step 'status'
        exception     = Get-AzlSonarMember $Step 'exception'
        steps         = @($mapped | Where-Object { $null -ne $_ })
    }
}

function Get-AzlSonarJobErrorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$JobProperties)

    $code = [string](Get-AzlSonarMember $JobProperties 'error.code' '')
    $message = [string](Get-AzlSonarMember $JobProperties 'error.message' '')
    if (-not $code -and -not $message) { return $null }
    $text = if ($code -and $message) { "${code}: $message" } elseif ($message) { $message } else { $code }
    return (Protect-AzlSonarText -Text $text)
}

function Get-AzlSonarEdgeMachine {
    <#
    .SYNOPSIS
        Best effort: the resource group's edge machines (simplified machine provisioning) and their ProvisionOs job.
    .DESCRIPTION
        Ignores 404 and 400 (the resource type exists only from edgeApiVersion 2025-12-01-preview, and a resource
        group without edge machines is normal). Each edge machine is matched to a configured node by its name, its
        host name (siteDetails.deviceConfiguration.hostName or the job's provisioningRequest), or its Arc machine name
        against an explicit nodes[].arcMachineName. The job's validationStatus and deploymentStatus are converted with
        ConvertTo-AzlSonarStepTree; the lifecycle stages and the job become the node's provisioning tree.
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
        $reportedArcId = Get-AzlSonarArcResourcePath ([string](Get-AzlSonarMember $properties 'arcMachineResourceId' ''))

        $jobProperties = $null
        $jobExists = $false
        if ($id) {
            try {
                $jobResponse = Invoke-AzlSonarArmGet -Path ('{0}/jobs/ProvisionOs?api-version={1}' -f $id, $apiVersion)
                if ($jobResponse.StatusCode -eq 200) {
                    $jobProperties = Get-AzlSonarMember $jobResponse.Body 'properties'
                    $jobExists = $true
                }
                elseif ($jobResponse.StatusCode -notin 400, 404 -and $null -ne $Warnings) {
                    $Warnings.Add("edgeMachines/$name/jobs/ProvisionOs: $($jobResponse.ErrorMessage)")
                }
            }
            catch {
                if ($null -ne $Warnings) { $Warnings.Add("edgeMachines/$name/jobs/ProvisionOs: $($_.Exception.Message)") }
            }
        }

        $targetArcId = Get-AzlSonarArcResourcePath ([string](Get-AzlSonarMember $jobProperties 'provisioningRequest.onboardingConfiguration.resourceId' ''))
        $arcSource = 'edgeMachine.job'
        if (-not $targetArcId) { $targetArcId = $reportedArcId; $arcSource = 'edgeMachine' }
        $arcName = Get-AzlSonarResourceLeaf $targetArcId
        $reportedArcName = Get-AzlSonarResourceLeaf $reportedArcId
        $hostName = [string](Get-AzlSonarMember $properties 'siteDetails.deviceConfiguration.hostName' '')
        if (-not $hostName) { $hostName = [string](Get-AzlSonarMember $jobProperties 'provisioningRequest.deviceConfiguration.hostName' '') }

        $nodeName = $null
        foreach ($node in $Config.nodes) {
            $explicit = [bool](Get-AzlSonarMember $node 'arcMachineNameSet' $true)
            if ($node.name -eq $name -or ($hostName -and $node.name -eq $hostName) -or
                ($explicit -and (($arcName -and $node.arcMachineName -eq $arcName) -or ($reportedArcName -and $node.arcMachineName -eq $reportedArcName)))) {
                $nodeName = $node.name
                break
            }
        }

        $job = [ordered]@{
            exists            = $jobExists
            status            = $null
            provisioningState = $null
            operationStatus   = $null
            percentComplete   = $null
            start             = $null
            end               = $null
            error             = $null
            validation        = [ordered]@{ status = 'notstarted'; tree = @() }
            deployment        = [ordered]@{ status = 'notstarted'; tree = @() }
        }
        if ($jobExists) {
            $reported = Get-AzlSonarMember $jobProperties 'reportedProperties'
            $job.status = Get-AzlSonarMember $jobProperties 'status'
            $job.provisioningState = Get-AzlSonarMember $jobProperties 'provisioningState'
            $job.percentComplete = Get-AzlSonarMember $reported 'percentComplete'
            $job.start = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $jobProperties 'startTimeUtc'))
            $job.end = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $jobProperties 'endTimeUtc'))
            $job.error = Get-AzlSonarJobErrorText -JobProperties $jobProperties
            foreach ($kind in 'validation', 'deployment') {
                $statusObject = Get-AzlSonarMember $reported "${kind}Status"
                if ($null -eq $statusObject) { $statusObject = Get-AzlSonarMember $jobProperties "${kind}Status" }
                $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $statusObject -Now $Now)
                $job[$kind] = [ordered]@{
                    status = Get-AzlSonarRollupStatus -RawStatus (Get-AzlSonarMember $statusObject 'status') -Tree $tree
                    tree   = $tree
                    raw    = $statusObject
                }
            }
        }
        else {
            # Before the job is readable, operationDetails still carries its state.
            foreach ($op in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $properties 'operationDetails'))) {
                if ([string](Get-AzlSonarMember $op 'name' '') -eq 'ProvisionOs') { $job.operationStatus = Get-AzlSonarMember $op 'status' }
            }
        }

        $extensions = @{}
        foreach ($ext in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $properties 'reportedProperties.extensionProfile.extensions'))) {
            $leaf = Get-AzlSonarResourceLeaf ([string](Get-AzlSonarMember $ext 'extensionResourceId' ''))
            if ($leaf) { $extensions[$leaf] = Get-AzlSonarMember $ext 'state' }
        }

        [ordered]@{
            name                       = $name
            node                       = $nodeName
            hostName                   = if ($hostName) { $hostName } else { $null }
            provisioningState          = Get-AzlSonarMember $properties 'provisioningState'
            lifecycle                  = Get-AzlSonarMember $properties 'lifecycleDetails.lifecycleStatus.status'
            lifecycleMessage           = Get-AzlSonarMember $properties 'lifecycleDetails.lifecycleStatus.message'
            lifecycleStages            = Get-AzlSonarMember $properties 'lifecycleDetails.lifecycleStages'
            machineState               = Get-AzlSonarMember $properties 'machineState'
            connectivityStatus         = Get-AzlSonarMember $properties 'connectivityStatus'
            arcMachineName             = $arcName
            arcMachineResourceId       = $reportedArcId
            targetArcMachineResourceId = $targetArcId
            arcSource                  = if ($targetArcId) { $arcSource } else { $null }
            extensions                 = $extensions
            provisionOsJob             = $job
        }
    }
}

function Get-AzlSonarProvisioningPercent {
    <#
    .SYNOPSIS
        Sonar's progress estimate for one simplified-provisioning node (0-100), from the lifecycle and the job steps.
    .DESCRIPTION
        Creating 0, AwaitingConnection 5, Provisioning 15, ReadyForOs 25, InstallingOs 25 + 70 x (finished ProvisionOs
        steps / reported steps), Provisioned 100. The job's own percentComplete is kept separately (reportedPercent):
        recorded live responses showed 50 both mid-run and after DeploymentSuccess, so it is not used for the bar.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()][string]$Lifecycle,
        [AllowNull()][AllowEmptyCollection()][object[]]$JobSteps,
        [AllowNull()][string]$JobStatus
    )

    $steps = ConvertTo-AzlSonarArray $JobSteps
    $ratio = $null
    if ($steps.Count -gt 0) {
        $done = @($steps | Where-Object { [string]$_['status'] -in 'success', 'skipped' }).Count
        $ratio = $done / $steps.Count
    }
    if ($JobStatus -eq 'success') { $ratio = 1.0 }
    $key = ([string]$Lifecycle -replace '[\s_\-]', '').ToLowerInvariant()
    switch ($key) {
        'provisioned' { return 100 }
        'creating' { return 0 }
        'awaitingconnection' { return 5 }
        'provisioning' { return 15 }
        'readyforos' { return 25 }
        'installingos' {
            if ($null -eq $ratio) { return 25 }
            return [int][Math]::Min(95, [Math]::Round(25 + 70 * $ratio))
        }
    }
    if ($null -ne $ratio) { return [int][Math]::Round(100 * $ratio) }
    return $null
}

function Get-AzlSonarTreeHasStatus {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Tree, [Parameter(Mandatory)][string]$Status)

    foreach ($n in (ConvertTo-AzlSonarArray $Tree)) {
        if ([string]$n['status'] -eq $Status) { return $true }
        if (Get-AzlSonarTreeHasStatus -Tree $n['children'] -Status $Status) { return $true }
    }
    return $false
}

function ConvertTo-AzlSonarSimplifiedNode {
    <#
    .SYNOPSIS
        The provisioning entry of one node on the simplified route: lifecycle, percent, ProvisionOs job and tree.
    .DESCRIPTION
        tree = the edge machine's lifecycle stages (ProvisionMachine, InstallOs, ... with their sub-stages) followed by
        one 'ProvisionOs job' node whose children are the job's steps (CreatedTargetArcMachine ... DeleteUnusedArcMachine)
        with their exception[] text; the job's properties.error is the job node's error. Every tree node has the
        ConvertTo-AzlSonarStepTree shape.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Node,
        [AllowNull()][object]$Edge,
        [AllowNull()][object]$Arc,
        [datetime]$Now = [datetime]::UtcNow
    )

    $entry = [ordered]@{
        name                 = $Node.name
        route                = 'simplified'
        exists               = $null -ne $Edge
        edgeMachineName      = $null
        lifecycle            = 'NotCreated'
        lifecycleMessage     = 'No edge machine for this node in the resource group yet.'
        status               = 'notstarted'
        percent              = $null
        reportedPercent      = $null
        provisioningState    = $null
        machineState         = $null
        connectivityStatus   = $null
        arcMachineName       = Get-AzlSonarMember $Arc 'arcMachineName'
        arcMachineResourceId = Get-AzlSonarMember $Arc 'arcMachineResourceId'
        arcSource            = Get-AzlSonarMember $Arc 'arcSource'
        arcStatus            = Get-AzlSonarMember $Arc 'arcStatus'
        job                  = $null
        extensions           = @()
        start                = $null
        end                  = $null
        errors               = @()
        tree                 = @()
    }
    if ($null -eq $Edge) { return $entry }

    $job = $Edge.provisionOsJob
    $tree = [System.Collections.Generic.List[object]]::new()
    $stages = ConvertTo-AzlSonarArray $Edge.lifecycleStages
    for ($i = 0; $i -lt $stages.Count; $i++) {
        $raw = ConvertTo-AzlSonarIndexedStep -Step $stages[$i] -Id "lifecycle.$i" -ChildKey 'subStages'
        foreach ($n in @(ConvertTo-AzlSonarStepTree -StatusObject @($raw) -Now $Now)) { $tree.Add($n) }
    }

    $jobNode = $null
    if ($job.exists -or $job.operationStatus) {
        $jobSteps = [System.Collections.Generic.List[object]]::new()
        $k = 0
        foreach ($kind in 'validation', 'deployment') {
            $raw = Get-AzlSonarMember $job[$kind] 'raw'
            foreach ($step in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $raw 'steps'))) {
                $prefix = if ($kind -eq 'validation') { 'job.v' } else { 'job.' }
                $jobSteps.Add((ConvertTo-AzlSonarIndexedStep -Step $step -Id "$prefix$k"))
                $k++
            }
        }
        $jobRawStatus = if ($job.status) { $job.status } elseif ($job.operationStatus) { $job.operationStatus } else { Get-AzlSonarMember $job.deployment 'raw.status' }
        $jobRaw = [pscustomobject]@{
            name          = 'ProvisionOs job'
            description   = 'edgeMachines/jobs/ProvisionOs'
            fullStepIndex = 'job'
            startTimeUtc  = $job.start
            endTimeUtc    = $job.end
            status        = $jobRawStatus
            exception     = @($job.error | Where-Object { $_ })
            steps         = $jobSteps.ToArray()
        }
        $jobNode = @(ConvertTo-AzlSonarStepTree -StatusObject @($jobRaw) -Now $Now)[0]
        $tree.Add($jobNode)
    }

    $lifecycle = [string]$Edge.lifecycle
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($lifecycle -match 'Fail') {
        $failures.Add(('Lifecycle {0}: {1}' -f $lifecycle, [string]$Edge.lifecycleMessage).TrimEnd(' ', ':'))
    }
    if ([string]$Edge.provisioningState -eq 'Failed') { $failures.Add('Edge machine provisioningState Failed.') }
    if ([string]$Edge.machineState -eq 'Failed') { $failures.Add('Edge machine machineState Failed: provision the machine again to recover.') }
    if ($job.error) { $failures.Add("ProvisionOs: $($job.error)") }
    if ([string]$job.provisioningState -eq 'Failed' -and -not $job.error) { $failures.Add('ProvisionOs job provisioningState Failed.') }

    $jobStatus = if ($null -ne $jobNode) { [string]$jobNode['status'] } else { $null }
    $status = 'running'
    if ($failures.Count -gt 0 -or $jobStatus -eq 'error' -or (Get-AzlSonarTreeHasStatus -Tree $tree.ToArray() -Status 'error')) { $status = 'error' }
    elseif ($lifecycle -eq 'Provisioned' -and ($null -eq $jobNode -or $jobStatus -eq 'success')) { $status = 'success' }

    $starts = @($tree | ForEach-Object { ConvertTo-AzlSonarUtcDate $_['start'] } | Where-Object { $null -ne $_ } | Sort-Object)
    $ends = @($tree | ForEach-Object { ConvertTo-AzlSonarUtcDate $_['end'] } | Where-Object { $null -ne $_ } | Sort-Object)

    $extensions = foreach ($name in $script:AzlSonarMandatoryExtensions) {
        $raw = $null
        foreach ($key in $Edge.extensions.Keys) { if ($key -eq $name) { $raw = $Edge.extensions[$key] } }
        $extStatus = if ($null -eq $raw) { 'notstarted' } else { ConvertTo-AzlSonarStepStatus $raw }
        [ordered]@{ name = $name; present = $null -ne $raw; rawStatus = $raw; status = $extStatus; message = $null; start = $null; end = $null }
    }

    $entry.edgeMachineName = $Edge.name
    $entry.lifecycle = if ($lifecycle) { $lifecycle } else { 'Unknown' }
    $entry.lifecycleMessage = $Edge.lifecycleMessage
    $entry.status = $status
    $entry.percent = Get-AzlSonarProvisioningPercent -Lifecycle $lifecycle -JobSteps $(if ($null -ne $jobNode) { $jobNode['children'] } else { @() }) -JobStatus $jobStatus
    $entry.reportedPercent = $job.percentComplete
    $entry.provisioningState = $Edge.provisioningState
    $entry.machineState = $Edge.machineState
    $entry.connectivityStatus = $Edge.connectivityStatus
    $entry.job = [ordered]@{ status = $job.status; operationStatus = $job.operationStatus; provisioningState = $job.provisioningState; start = $job.start; end = $job.end; error = $job.error }
    $entry.extensions = @($extensions)
    $entry.start = if ($starts.Count) { Format-AzlSonarDate $starts[0] } else { $null }
    $entry.end = if ($status -in 'success', 'error' -and $ends.Count) { Format-AzlSonarDate $ends[-1] } else { $null }
    $entry.errors = $failures.ToArray()
    $entry.tree = $tree.ToArray()
    return $entry
}

function ConvertTo-AzlSonarOemNode {
    <#
    .SYNOPSIS
        The arc-registration entry of one node on the OEM image route: Arc machine present, Connected, and each
        mandatory extension as a step.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Node,
        [AllowNull()][object]$Arc,
        [AllowNull()][AllowEmptyCollection()][object[]]$Extensions,
        [datetime]$Now = [datetime]::UtcNow
    )

    $arcStatus = [string](Get-AzlSonarMember $Arc 'arcStatus' 'Unknown')
    $present = $arcStatus -notin 'NotFound', 'Unknown'
    $arcName = [string](Get-AzlSonarMember $Arc 'arcMachineName' $Node.name)
    $connected = $arcStatus -eq 'Connected'

    $connectStatus = if (-not $present) { 'notstarted' } elseif ($connected) { 'Success' } elseif ($arcStatus -eq 'Expired') { 'Error' } else { $arcStatus }
    $connectErrors = if ($arcStatus -eq 'Expired') { @("Arc agent status Expired on $arcName.") } else { @() }
    $raw = [System.Collections.Generic.List[object]]::new()
    $raw.Add([pscustomobject]@{
            name = 'Arc machine registered'; description = "Microsoft.HybridCompute/machines/$arcName (Invoke-AzStackHciArcInitialization)"
            fullStepIndex = 'arc'; status = $(if ($present) { 'Success' } elseif ($arcStatus -eq 'Unknown') { $null } else { 'NotStarted' })
            startTimeUtc = $null; endTimeUtc = Get-AzlSonarMember $Arc 'registeredAt'
        })
    $raw.Add([pscustomobject]@{
            name = 'Arc agent Connected'; description = 'Microsoft.HybridCompute/machines properties.status'
            fullStepIndex = 'arc.connected'; status = $connectStatus
            startTimeUtc = $null; endTimeUtc = $(if ($connected) { Get-AzlSonarMember $Arc 'lastStatusChange' } else { $null })
            exception = $connectErrors
        })
    foreach ($ext in (ConvertTo-AzlSonarArray $Extensions)) {
        $extRawStatus = if ($ext['present']) { if ($ext['rawStatus']) { $ext['rawStatus'] } else { 'InProgress' } } else { 'NotStarted' }
        $raw.Add([pscustomobject]@{
                name = $ext['name']; description = 'Mandatory Azure Local extension'
                fullStepIndex = "ext.$($ext['name'])"; status = $extRawStatus
                startTimeUtc = $ext['start']; endTimeUtc = $ext['end']
                exception = @($ext['message'] | Where-Object { $_ -and $ext['status'] -eq 'error' })
            })
    }
    $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $raw.ToArray() -Now $Now)

    $extList = ConvertTo-AzlSonarArray $Extensions
    $failed = @($extList | Where-Object { $_['status'] -eq 'error' })
    $succeeded = @($extList | Where-Object { $_['status'] -eq 'success' })
    $started = @($extList | Where-Object { $_['present'] })
    $lifecycle = if ($arcStatus -eq 'Unknown') { 'Unknown' }
    elseif (-not $present) { 'NotRegistered' }
    elseif ($failed.Count -gt 0) { 'Failed' }
    elseif (-not $connected -and $arcStatus -eq 'Expired') { 'Failed' }
    elseif (-not $connected) { 'Registered' }
    elseif ($extList.Count -gt 0 -and $succeeded.Count -eq $extList.Count) { 'Ready' }
    elseif ($started.Count -gt 0) { 'InstallingExtensions' }
    else { 'Connected' }
    $message = switch ($lifecycle) {
        'Unknown' { "The Arc machine $arcName could not be read (see the warnings)." }
        'NotRegistered' { "No Arc machine named $arcName yet: run Invoke-AzStackHciArcInitialization on the node." }
        'Registered' { "Arc machine $arcName exists; agent status $arcStatus." }
        'Connected' { 'Arc agent Connected; waiting for the mandatory extensions.' }
        'InstallingExtensions' { "Installing the mandatory extensions ($($succeeded.Count) of $($extList.Count) succeeded)." }
        'Ready' { 'Arc machine Connected and every mandatory extension Succeeded.' }
        'Failed' { if ($failed.Count) { "Extension failed: $(@($failed | ForEach-Object { $_['name'] }) -join ', ')." } else { "Arc agent status $arcStatus." } }
    }
    $status = switch ($lifecycle) { 'Unknown' { 'unknown' } 'NotRegistered' { 'notstarted' } 'Ready' { 'success' } 'Failed' { 'error' } default { 'running' } }
    $doneSteps = @($tree | Where-Object { $_['status'] -eq 'success' }).Count
    $errors = @($failed | ForEach-Object { if ($_['message']) { "$($_['name']): $($_['message'])" } else { "$($_['name']): Failed" } }) + $connectErrors

    $starts = @($tree | ForEach-Object { ConvertTo-AzlSonarUtcDate $_['start'] } | Where-Object { $null -ne $_ } | Sort-Object)
    $ends = @($tree | ForEach-Object { ConvertTo-AzlSonarUtcDate $_['end'] } | Where-Object { $null -ne $_ } | Sort-Object)
    $registeredAt = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $Arc 'registeredAt')
    $start = if ($null -ne $registeredAt) { $registeredAt } elseif ($starts.Count) { $starts[0] } else { $null }

    return [ordered]@{
        name                 = $Node.name
        route                = 'oem-image'
        exists               = $present
        edgeMachineName      = $null
        lifecycle            = $lifecycle
        lifecycleMessage     = $message
        status               = $status
        percent              = [int][Math]::Round(100 * $doneSteps / [Math]::Max(1, $tree.Count))
        reportedPercent      = $null
        provisioningState    = $null
        machineState         = $null
        connectivityStatus   = $arcStatus
        arcMachineName       = $arcName
        arcMachineResourceId = Get-AzlSonarMember $Arc 'arcMachineResourceId'
        arcSource            = Get-AzlSonarMember $Arc 'arcSource'
        arcStatus            = $arcStatus
        job                  = $null
        extensions           = @($extList)
        start                = Format-AzlSonarDate $start
        end                  = if ($status -in 'success', 'error' -and $ends.Count) { Format-AzlSonarDate $ends[-1] } else { $null }
        errors               = @($errors)
        tree                 = $tree
    }
}

function Get-AzlSonarProvisioningRollup {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Nodes)

    $list = ConvertTo-AzlSonarArray $Nodes
    $statuses = @($list | ForEach-Object { [string]$_['status'] })
    if ($statuses.Count -eq 0) { return 'notstarted' }
    if ($statuses -contains 'error') { return 'error' }
    if (@($statuses | Where-Object { $_ -eq 'success' }).Count -eq $statuses.Count) { return 'success' }
    if (@($statuses | Where-Object { $_ -in 'running', 'success' }).Count -gt 0) { return 'running' }
    return 'notstarted'
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
        [ordered]@{ name = $node.name; arcMachineName = $node.arcMachineName; arcMachineResourceId = $null; arcSource = $null; seed = [bool]$node.seed; arcStatus = 'Unknown'; lastStatusChange = $null; agentVersion = $null; registeredAt = $null }
    }
    $configured = [string](Get-AzlSonarMember $Config 'provisioningRoute' 'auto')
    $route = if ($configured -in 'simplified', 'oem-image') { $configured } else { $null }
    $phase = if ($route -eq 'oem-image') { 'arc-registration' } else { 'provisioning' }
    $emptyCounts = Measure-AzlSonarStepTree -Tree @()
    return [ordered]@{
        cluster           = $Config.clusterName
        resourceGroup     = $Config.resourceGroup
        mode              = $null
        provisioningState = $null
        phase             = $phase
        activePhase       = $phase
        provisioning      = [ordered]@{ route = $route; routeSource = $(if ($route) { 'config' } else { 'auto' }); phase = $phase; status = 'notstarted'; nodes = @() }
        validation        = [ordered]@{ status = 'notstarted'; tree = @(); counts = $emptyCounts }
        deployment        = [ordered]@{ status = 'notstarted'; tree = @(); counts = (Measure-AzlSonarStepTree -Tree @()) }
        nodes             = @($nodes)
        edgeMachines      = @()
        current           = [ordered]@{ phase = $phase; stepPath = @(); stepNames = @(); stepName = $null; stepId = $null; status = $null }
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
        GETs deploymentSettings/default (validation and deployment step trees, mode, provisioning state), the edge
        machines of the resource group with their ProvisionOs job (simplified machine provisioning; skipped when
        provisioningRoute is oem-image), the Arc machine of every node and, on the OEM image route, each Arc machine's
        mandatory extensions. Uses Invoke-AzRestMethod with the signed-in Az PowerShell context. Never writes to Azure.
        A 404 on deploymentSettings is not an error: the machines are still being prepared.
        The route: provisioningRoute simplified or oem-image as configured; auto picks simplified when edge machines
        for the configured nodes exist, else oem-image. The phase: deployment > validation > provisioning (simplified)
        or arc-registration (OEM image).
    .PARAMETER Config
        A config object from Read-AzlSonarConfig.
    .PARAMETER ConfigPath
        Path to a config file (read with Read-AzlSonarConfig).
    .PARAMETER Now
        The poll time (UTC); used for polledAt and running-step durations. Defaults to now.
    .EXAMPLE
        Get-AzlSonarDeploymentState -ConfigPath ./config/clus01.json | ConvertTo-Json -Depth 20
    .OUTPUTS
        Ordered dictionary: cluster, resourceGroup, mode, provisioningState, phase, activePhase,
        provisioning{route,routeSource,phase,status,nodes[]}, validation{status,tree,counts},
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

    # Route: simplified machine provisioning (edge machines) or OEM image + Arc registration.
    $configuredRoute = [string](Get-AzlSonarMember $Config 'provisioningRoute' 'auto')
    $edgeMachines = @()
    if ($configuredRoute -ne 'oem-image') {
        $edgeMachines = @(Get-AzlSonarEdgeMachine -Config $Config -Now $Now -Warnings $warnings)
    }
    $route = $configuredRoute
    $routeSource = 'config'
    if ($configuredRoute -notin 'simplified', 'oem-image') {
        $routeSource = 'auto'
        $route = if (@($edgeMachines | Where-Object { $_.node }).Count -gt 0) { 'simplified' } else { 'oem-image' }
        if ($route -eq 'oem-image' -and $edgeMachines.Count -gt 0) {
            $warnings.Add("$($edgeMachines.Count) edge machine(s) in the resource group match no configured node; following the OEM image route. Set provisioningRoute to simplified, or name the nodes after the edge machines.")
        }
    }
    $provisioningPhase = if ($route -eq 'simplified') { 'provisioning' } else { 'arc-registration' }

    $targets = @(Resolve-AzlSonarArcTarget -Config $Config -Route $route -EdgeMachines $edgeMachines)
    $nodes = @(Get-AzlSonarArcMachineStatus -Config $Config -Target $targets -Warnings $warnings)

    $provisioningNodes = foreach ($node in $Config.nodes) {
        $arc = $null
        foreach ($n in $nodes) { if ($n.name -eq $node.name) { $arc = $n; break } }
        if ($route -eq 'simplified') {
            $edge = $null
            foreach ($machine in $edgeMachines) { if ($machine.node -eq $node.name) { $edge = $machine; break } }
            ConvertTo-AzlSonarSimplifiedNode -Node $node -Edge $edge -Arc $arc -Now $Now
        }
        else {
            $extensions = @()
            if ($null -ne $arc -and $arc.arcStatus -notin 'NotFound', 'Unknown') {
                $extensions = @(Get-AzlSonarArcExtension -ArcMachineResourceId $arc.arcMachineResourceId -ArcMachineName $arc.arcMachineName -Warnings $warnings)
            }
            else {
                $extensions = @(foreach ($name in $script:AzlSonarMandatoryExtensions) { [ordered]@{ name = $name; present = $false; rawStatus = $null; status = 'notstarted'; message = $null; start = $null; end = $null } })
            }
            ConvertTo-AzlSonarOemNode -Node $node -Arc $arc -Extensions $extensions -Now $Now
        }
    }
    $provisioningNodes = @($provisioningNodes)
    $provisioningStatus = Get-AzlSonarProvisioningRollup -Nodes $provisioningNodes

    # Keep the job's raw status objects out of the state (they are already converted into trees).
    $edgeOut = foreach ($machine in $edgeMachines) {
        $copy = [ordered]@{}
        foreach ($key in $machine.Keys) { if ($key -notin 'lifecycleStages', 'extensions') { $copy[$key] = $machine[$key] } }
        $job = [ordered]@{}
        foreach ($key in $machine.provisionOsJob.Keys) { $job[$key] = $machine.provisionOsJob[$key] }
        foreach ($kind in 'validation', 'deployment') { $job[$kind] = [ordered]@{ status = $job[$kind].status; tree = $job[$kind].tree } }
        $copy.provisionOsJob = $job
        $copy
    }

    $phaseInfo = Get-AzlSonarPhase -ValidationTree $validationTree -ValidationStatus $validationStatus -DeploymentTree $deploymentTree -DeploymentStatus $deploymentStatus -ProvisioningPhase $provisioningPhase -ProvisioningStatus $provisioningStatus
    $active = $phaseInfo.activePhase
    $current = switch ($active) {
        'deployment' { Get-AzlSonarCurrentStep -Tree $deploymentTree -Phase 'deployment' }
        'validation' { Get-AzlSonarCurrentStep -Tree $validationTree -Phase 'validation' }
        default {
            # Provisioning or Arc registration: one synthetic parent per node so stepPath starts with the node name.
            $machineTree = foreach ($p in $provisioningNodes) {
                if (@($p.tree).Count -gt 0) {
                    [ordered]@{ id = $p.name; name = $p.name; status = 'notstarted'; start = $null; end = $null; children = @($p.tree) }
                }
            }
            Get-AzlSonarCurrentStep -Tree @($machineTree) -Phase $active
        }
    }

    return [ordered]@{
        cluster           = $Config.clusterName
        resourceGroup     = $Config.resourceGroup
        mode              = Get-AzlSonarMember $properties 'deploymentMode'
        provisioningState = Get-AzlSonarMember $properties 'provisioningState'
        phase             = $phaseInfo.phase
        activePhase       = $active
        provisioning      = [ordered]@{ route = $route; routeSource = $routeSource; phase = $provisioningPhase; status = $provisioningStatus; nodes = $provisioningNodes }
        validation        = [ordered]@{ status = $validationStatus; tree = $validationTree; counts = (Measure-AzlSonarStepTree -Tree $validationTree) }
        deployment        = [ordered]@{ status = $deploymentStatus; tree = $deploymentTree; counts = (Measure-AzlSonarStepTree -Tree $deploymentTree) }
        nodes             = $nodes
        edgeMachines      = @($edgeOut)
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
