Set-StrictMode -Version Latest

function ConvertTo-AzlSonarStepStatus {
    <#
    .SYNOPSIS
        Normalises an Azure Local step status to notstarted, running, success, error, skipped or unknown.
    .DESCRIPTION
        Case-insensitive; spaces, dashes and underscores are ignored ('Not Started' = 'NotStarted').
        Also maps the edge machine job statuses (DeploymentSuccess, DeploymentFailed, DeploymentInProgress and the
        Validation* equivalents), lifecycle stage statuses (Completed) and Arc extension provisioning states
        (Creating, Updating, Accepted, Canceled).
        Values that are not recognised map to 'unknown'; callers keep the raw value in rawStatus.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Status
    )

    if ($null -eq $Status) { return 'notstarted' }
    $key = ([string]$Status -replace '[\s_\-]', '').ToLowerInvariant()
    switch ($key) {
        '' { return 'notstarted' }
        'notstarted' { return 'notstarted' }
        'success' { return 'success' }
        'succeeded' { return 'success' }
        'completed' { return 'success' }
        'deploymentsuccess' { return 'success' }
        'validationsuccess' { return 'success' }
        'inprogress' { return 'running' }
        'running' { return 'running' }
        'provisioning' { return 'running' }
        'creating' { return 'running' }
        'updating' { return 'running' }
        'accepted' { return 'running' }
        'deploymentinprogress' { return 'running' }
        'validationinprogress' { return 'running' }
        'error' { return 'error' }
        'failed' { return 'error' }
        'failure' { return 'error' }
        'canceled' { return 'error' }
        'cancelled' { return 'error' }
        'deploymentfailed' { return 'error' }
        'validationfailed' { return 'error' }
        'skipped' { return 'skipped' }
    }
    return 'unknown'
}

function ConvertTo-AzlSonarStepNode {
    <#
    .SYNOPSIS
        Converts one raw step (and its nested steps) to a normalised tree node.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Step,

        [Parameter(Mandatory)]
        [datetime]$Now,

        [Parameter(Mandatory)]
        [string]$FallbackId
    )

    $rawStatus = Get-AzlSonarMember $Step 'status'
    $status = ConvertTo-AzlSonarStepStatus $rawStatus
    $start = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $Step 'startTimeUtc')
    $end = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $Step 'endTimeUtc')

    $id = [string](Get-AzlSonarMember $Step 'fullStepIndex' '')
    if ([string]::IsNullOrWhiteSpace($id)) { $id = $FallbackId }
    $name = [string](Get-AzlSonarMember $Step 'name' '')
    $description = [string](Get-AzlSonarMember $Step 'description' '')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = if ($description) { $description } else { "Step $id" } }

    $duration = $null
    if ($null -ne $start) {
        $nowUtc = $Now.ToUniversalTime()
        if ($status -eq 'running') {
            $duration = [long][Math]::Floor(($nowUtc - $start).TotalSeconds)
        }
        elseif ($null -ne $end) {
            $duration = [long][Math]::Floor(($end - $start).TotalSeconds)
        }
        if ($null -ne $duration -and $duration -lt 0) { $duration = [long]0 }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $Step 'exception'))) {
        $text = Protect-AzlSonarText -Text ([string]$item)
        if (-not [string]::IsNullOrWhiteSpace($text)) { $errors.Add($text) }
    }

    $children = @(ConvertTo-AzlSonarStepTree -StatusObject $Step -Now $Now -ParentId $id)

    return [ordered]@{
        id              = $id
        name            = $name
        description     = $description
        status          = $status
        rawStatus       = if ($null -eq $rawStatus) { $null } else { [string]$rawStatus }
        start           = Format-AzlSonarDate $start
        end             = Format-AzlSonarDate $end
        durationSeconds = $duration
        errors          = $errors.ToArray()
        children        = $children
    }
}

function ConvertTo-AzlSonarStepTree {
    <#
    .SYNOPSIS
        Converts an Azure Local status object ({ status, steps[] }) into a normalised step tree.
    .DESCRIPTION
        Works for deploymentSettings reportedProperties.validationStatus and .deploymentStatus and for edge machine
        ProvisionOs job status objects. Each node is
        { id, name, description, status, rawStatus, start, end, durationSeconds, errors[], children[] }.
        id is fullStepIndex (or the position path when missing); status is notstarted|running|success|error|skipped|unknown;
        start/end are UTC ISO strings; durationSeconds is end - start, or now - start for a running step;
        errors are the step's exception[] strings; children are the nested steps[].
        An empty status object ({}) or $null returns an empty tree. An array of steps is also accepted.
    .PARAMETER StatusObject
        The status object (or array of raw steps).
    .PARAMETER Now
        The time used for running-step durations (UTC). Defaults to now; pass a fixed value in tests.
    .PARAMETER ParentId
        Prefix for generated ids when a step has no fullStepIndex.
    .EXAMPLE
        ConvertTo-AzlSonarStepTree -StatusObject $settings.properties.reportedProperties.validationStatus
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary (one per top-level step).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$StatusObject,

        [datetime]$Now = [datetime]::UtcNow,

        [string]$ParentId = ''
    )

    if ($null -eq $StatusObject) { return }
    $isStepArray = $StatusObject -is [System.Collections.IEnumerable] -and
        $StatusObject -isnot [string] -and
        $StatusObject -isnot [System.Collections.IDictionary]
    $steps = if ($isStepArray) { ConvertTo-AzlSonarArray $StatusObject } else { ConvertTo-AzlSonarArray (Get-AzlSonarMember $StatusObject 'steps') }

    for ($i = 0; $i -lt $steps.Count; $i++) {
        $fallback = if ($ParentId) { "$ParentId.$i" } else { [string]$i }
        ConvertTo-AzlSonarStepNode -Step $steps[$i] -Now $Now -FallbackId $fallback
    }
}

function Measure-AzlSonarStepTree {
    <#
    .SYNOPSIS
        Counts the steps of a normalised tree by status, at every level.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Tree
    )

    $counts = [ordered]@{ total = 0; notstarted = 0; running = 0; success = 0; error = 0; skipped = 0; unknown = 0 }
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($node in (ConvertTo-AzlSonarArray $Tree)) { $stack.Push($node) }
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $counts.total++
        $status = [string]$node['status']
        if ($counts.Contains($status)) { $counts[$status]++ } else { $counts.unknown++ }
        foreach ($child in (ConvertTo-AzlSonarArray $node['children'])) { $stack.Push($child) }
    }
    return $counts
}

function Get-AzlSonarRollupStatus {
    <#
    .SYNOPSIS
        Overall status of a status object: its own status when reported, otherwise derived from the top-level steps.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$RawStatus,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Tree
    )

    if ($null -ne $RawStatus -and -not [string]::IsNullOrWhiteSpace([string]$RawStatus)) {
        return (ConvertTo-AzlSonarStepStatus $RawStatus)
    }
    $nodes = ConvertTo-AzlSonarArray $Tree
    if ($nodes.Count -eq 0) { return 'notstarted' }
    $statuses = @($nodes | ForEach-Object { [string]$_['status'] })
    if ($statuses -contains 'error') { return 'error' }
    if ($statuses -contains 'running') { return 'running' }
    $finished = @($statuses | Where-Object { $_ -in 'success', 'skipped' })
    if ($finished.Count -eq $statuses.Count) { return 'success' }
    if ($finished.Count -gt 0) { return 'running' }
    if ($statuses -contains 'unknown') { return 'unknown' }
    return 'notstarted'
}

function Get-AzlSonarCurrentStep {
    <#
    .SYNOPSIS
        Finds the current step of a normalised tree: the deepest running step, else the last finished step.
    .DESCRIPTION
        Running: the deepest node with status running (ties: the latest start, then the last in tree order).
        Otherwise: the finished node (success, error, skipped) with the latest end time (ties: the deeper one, then
        the last in tree order). Returns { phase, stepPath[], stepNames[], stepName, stepId, status }; stepPath lists
        the step ids (fullStepIndex) from the top level down to the current step and stepNames the matching names.
        Empty tree: stepPath is empty and stepName is $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Tree,

        [string]$Phase = ''
    )

    $bestRunning = $null
    $bestFinished = $null
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $topLevel = ConvertTo-AzlSonarArray $Tree
    for ($i = $topLevel.Count - 1; $i -ge 0; $i--) {
        $stack.Push(@{ Node = $topLevel[$i]; Path = @([string]$topLevel[$i]['id']); Names = @([string]$topLevel[$i]['name']) })
    }
    $order = 0
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $node = $item.Node
        $order++
        $depth = $item.Path.Count
        $status = [string]$node['status']
        if ($status -eq 'running') {
            $start = ConvertTo-AzlSonarUtcDate $node['start']
            $startTicks = if ($null -ne $start) { $start.Ticks } else { 0 }
            if ($null -eq $bestRunning -or $depth -gt $bestRunning.Depth -or
                ($depth -eq $bestRunning.Depth -and $startTicks -ge $bestRunning.Key)) {
                $bestRunning = @{ Node = $node; Path = $item.Path; Names = $item.Names; Depth = $depth; Key = $startTicks }
            }
        }
        elseif ($status -in 'success', 'error', 'skipped') {
            $end = ConvertTo-AzlSonarUtcDate $node['end']
            $endTicks = if ($null -ne $end) { $end.Ticks } else { 0 }
            if ($null -eq $bestFinished -or $endTicks -gt $bestFinished.Key -or
                ($endTicks -eq $bestFinished.Key -and $depth -ge $bestFinished.Depth)) {
                $bestFinished = @{ Node = $node; Path = $item.Path; Names = $item.Names; Depth = $depth; Key = $endTicks }
            }
        }
        $children = ConvertTo-AzlSonarArray $node['children']
        for ($c = $children.Count - 1; $c -ge 0; $c--) {
            $stack.Push(@{
                    Node  = $children[$c]
                    Path  = @($item.Path + [string]$children[$c]['id'])
                    Names = @($item.Names + [string]$children[$c]['name'])
                })
        }
    }

    $best = if ($null -ne $bestRunning) { $bestRunning } else { $bestFinished }
    if ($null -eq $best) {
        return [ordered]@{ phase = $Phase; stepPath = @(); stepNames = @(); stepName = $null; stepId = $null; status = $null }
    }
    return [ordered]@{
        phase     = $Phase
        stepPath  = [string[]]$best.Path
        stepNames = [string[]]$best.Names
        stepName  = [string]$best.Node['name']
        stepId    = [string]$best.Node['id']
        status    = [string]$best.Node['status']
    }
}

function Get-AzlSonarPhase {
    <#
    .SYNOPSIS
        Works out the deployment phase: provisioning or arc-registration, validation, deployment, done or failed.
    .DESCRIPTION
        deployment when the deployment status has steps, else validation when the validation status has steps,
        else the machine-readiness phase of the route: provisioning (simplified machine provisioning) or
        arc-registration (OEM image + Arc registration), passed in -ProvisioningPhase. A deployment that succeeded is
        done; an error in the active phase (including -ProvisioningStatus error) is failed.
        Returns { phase, activePhase } where activePhase is the phase without done/failed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$ValidationTree,

        [AllowNull()]
        [string]$ValidationStatus,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$DeploymentTree,

        [AllowNull()]
        [string]$DeploymentStatus,

        [ValidateSet('provisioning', 'arc-registration')]
        [string]$ProvisioningPhase = 'provisioning',

        [AllowNull()]
        [string]$ProvisioningStatus
    )

    $active = $ProvisioningPhase
    $status = if ($ProvisioningStatus) { $ProvisioningStatus } else { 'notstarted' }
    if ((ConvertTo-AzlSonarArray $DeploymentTree).Count -gt 0) {
        $active = 'deployment'
        $status = $DeploymentStatus
    }
    elseif ((ConvertTo-AzlSonarArray $ValidationTree).Count -gt 0) {
        $active = 'validation'
        $status = $ValidationStatus
    }

    $phase = $active
    if ($active -eq 'deployment' -and $status -eq 'success') { $phase = 'done' }
    elseif ($status -eq 'error') { $phase = 'failed' }
    return [ordered]@{ phase = $phase; activePhase = $active }
}
