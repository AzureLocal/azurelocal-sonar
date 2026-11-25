Set-StrictMode -Version Latest

# The toolkit's post-deployment events (azurelocal-toolkit, phase 06 of the Implementation guide). Invoke-AzureLocalPostDeployment.ps1 runs the
# eleven post-deployment tasks in one run (Plan or Apply) and appends what it does to post-deployment-events.jsonl in the one shared events
# folder (deployment.events_directory, else <ProgramData>\AzureLocalToolkit\<cluster.name>\events), one object per line, in the envelope every
# toolkit feed uses (Write-AzlToolkitEvent):
#   { timestamp (UTC round trip), node '*', stage 'PostDeployment', step, state, evidence, level, nextAction, runId, mode (Plan|Apply),
#     cluster, ...data }
#   RunStarted (step '')                        the run starts; data.route (PowerShell|AzureCli), data.selected (the step ids of this run)
#   StepSkipped (step = the step id)            the file does not need the step, or skip_steps leaves it out; evidence is the reason
#   StepStarted                                 data.task (the page of the guide, for example task-05-storage-configuration)
#   StepPlanned | StepPassed | StepWarning | StepFailed   data.exitCode; a Plan passes -WhatIf to the step, so its steps end Planned
#   StepNotRun                                  an earlier step stopped the run
#   StepRefused                                 an irreversible step whose acknowledgement keys are missing (the run exits with 2)
#   ClusterReachable | ClusterUnreachable       the one connection check before the first step that needs the cluster
#   RunCompleted (step '')                      data.exitCode (0 every selected step passed, was planned or was skipped; 1 a step failed;
#                                               2 bad input, a refusal or a cluster that does not answer; 3 stopped after a step with
#                                               warnings) and data.result (the one-line verdict)
# The 13 step ids and their pages come from PostDeploymentSteps.psd1 of the toolkit. The reader does not depend on that list: it shows the
# steps the events name, in the order of the table when it knows the id and in the order first seen otherwise. A Skipped or NotRun step has
# no StepStarted line and so no data.task: the page of a known step id is the fallback below, and data.task wins when a line has it.
#
# Sonar follows the file the way it follows the gate's plan file: the LATEST run only (a RunStarted with another runId starts over, a line of
# an older run is counted and not shown), rebuilt from the whole file whenever it changes. The store is Shared.PostDeploymentEvents, key '*'.
# No new configuration key: the file is looked for in the events folder (the folder that holds updateEventsPath, armEventsPath,
# osConfigEventsPath or verificationEventsPath), the way the Update monitor finds update-events.jsonl.
#
# A Plan changes nothing. What a Plan reports is a finding, never a deployment failure: a Plan that stopped is shown as "Plan stopped" (amber)
# and its Error lines are shown as warnings; an Apply that failed is red.

$script:AzlSonarPostDeploymentKey = '*'
$script:AzlSonarPostDeploymentEventFile = 'post-deployment-events'
$script:AzlSonarPostDeploymentFileName = 'post-deployment-events.jsonl'
$script:AzlSonarPostDeploymentStages = 'PostDeployment'
$script:AzlSonarPostDeploymentMaxSteps = 64

# The steps of PostDeploymentSteps.psd1 (toolkit), in the order of the guide's pages, with the page of each (the fallback for a step whose
# line carries no data.task).
$script:AzlSonarPostDeploymentSteps = [ordered]@{
    'sdn'              = 'task-01-deploy-sdn'
    'sdn-test'         = 'task-01-deploy-sdn'
    'quorum'           = 'task-02-cluster-quorum-configuration'
    'security-groups'  = 'task-03-security-groups-applied-to-nodes'
    'ssh'              = 'task-04-ssh-connectivity-to-nodes'
    'storage-volumes'  = 'task-05-storage-configuration'
    'storage-paths'    = 'task-05-storage-configuration'
    'vm-images'        = 'task-06-image-downloads'
    'nsgs'             = 'task-07-configure-nsgs'
    'logical-networks' = 'task-08-logical-network-creation'
    'verification'     = 'task-09-post-deployment-verification'
    'external-storage' = 'task-10-enable-external-storage-hybrid'
    'sbe-import-plan'  = 'task-11-sbe-update-import'
}

$script:AzlSonarPostDeploymentWord = @{
    planned = 'Planned'; passed = 'Passed'; skipped = 'Skipped'; warning = 'Warning'; failed = 'Failed'; notrun = 'Not run'
    refused = 'Refused'; running = 'Running'; pending = 'Waiting'
}

function ConvertFrom-AzlSonarPostDeploymentLine {
    <#
    .SYNOPSIS
        Parses one line of the post-deployment event file into { node, state, step, when, timestamp, evidence, level, nextAction, runId,
        mode, cluster, data }, or $null when it is not a post-deployment event (no node or state, or another stage).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $raw = $null
    try { $raw = ConvertFrom-Json -InputObject $Line -AsHashtable -Depth 8 } catch { return $null }
    if ($raw -isnot [System.Collections.IDictionary]) { return $null }
    $get = { param($k, $d) if ($raw.Contains($k) -and $null -ne $raw[$k]) { $raw[$k] } else { $d } }
    $node = [string](& $get 'node' '')
    $state = [string](& $get 'state' '')
    if (-not $node -or -not $state) { return $null }
    $stage = [string](& $get 'stage' 'PostDeployment')
    if ($stage -and $stage -notin $script:AzlSonarPostDeploymentStages) { return $null }
    $when = ConvertTo-AzlSonarUtcDate (& $get 'timestamp' '')
    $level = [string](& $get 'level' 'Info')
    if ($level -notin 'Info', 'Warning', 'Error') { $level = 'Info' }
    $standard = 'node', 'state', 'stage', 'step', 'timestamp', 'evidence', 'level', 'nextAction', 'runId', 'mode', 'cluster'
    $data = @{}
    foreach ($k in $raw.Keys) { if ([string]$k -notin $standard) { $data[[string]$k] = $raw[$k] } }
    return @{
        node = $node; state = $state; step = [string](& $get 'step' ''); when = $when
        timestamp = $(if ($when) { $when.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) } else { '' })
        evidence = [string](& $get 'evidence' ''); level = $level; nextAction = [string](& $get 'nextAction' '')
        runId = [string](& $get 'runId' ''); mode = [string](& $get 'mode' ''); cluster = [string](& $get 'cluster' ''); data = $data
    }
}

function Get-AzlSonarPostDeploymentStepStatus {
    <#
    .SYNOPSIS
        The status a step event stands for (planned, passed, skipped, warning, failed, notrun, refused, running), or '' when the state
        is not a step state. Pure.
    .DESCRIPTION
        The known states are mapped by name. An unknown future state is read by its last word, like the update events: ...Failed is
        failed, ...Refused refused, ...Skipped skipped, ...Planned planned, ...Passed passed, ...Warning warning, ...NotRun notrun and
        ...Started or ...Running running. A line with no step id is never a step.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$State, [string]$Step)

    if (-not $Step) { return '' }
    switch -Regex ($State) {
        '(Failed|TimedOut)$' { return 'failed' }
        'Refused$' { return 'refused' }
        'Skipped$' { return 'skipped' }
        'NotRun$' { return 'notrun' }
        'Planned$' { return 'planned' }
        'Passed$' { return 'passed' }
        'Warning$' { return 'warning' }
        '(Started|Running)$' { return 'running' }
    }
    return ''
}

function ConvertFrom-AzlSonarPostDeploymentEvent {
    <#
    .SYNOPSIS
        One event line of the post-deployment file as a log line { file, text, level }, or $null when the line is not an event.
    .DESCRIPTION
        "<UTC time> [post-deployment] <node|*> <State> (<step>): <evidence> -> next: <nextAction>". The level is the event's own, except
        that an Error line of a Plan run is shown as a warning: a Plan changes nothing, so what it finds is not a failed deployment.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Line)

    $e = ConvertFrom-AzlSonarPostDeploymentLine -Line $Line
    if ($null -eq $e) { return $null }
    $prefix = if ($e.when) { $e.timestamp + ' ' } else { '' }
    $text = "${prefix}[post-deployment] $($e.node) $($e.state)"
    if ($e.step) { $text += " ($($e.step))" }
    if ($e.evidence) { $text += ": $($e.evidence)" }
    if ($e.nextAction) { $text += " -> next: $($e.nextAction)" }
    $level = ([string]$e.level).ToLowerInvariant()
    if ($level -eq 'error' -and $e.mode -eq 'Plan') { $level = 'warning' }
    return @{ file = $script:AzlSonarPostDeploymentEventFile; text = $text; level = $level }
}

function Add-AzlSonarPostDeploymentEvent {
    <#
    .SYNOPSIS
        Records one event line in the store (key '*': the latest run with its steps). Each change stores a new object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Store,
        [AllowNull()][AllowEmptyString()][string]$Line
    )

    $e = ConvertFrom-AzlSonarPostDeploymentLine -Line $Line
    if ($null -eq $e) { return }
    $key = $script:AzlSonarPostDeploymentKey
    $old = if ($Store.Contains($key)) { $Store[$key] } else { $null }
    $newRun = ($null -eq $old) -or ($e.state -eq 'RunStarted' -and (-not $e.runId -or $e.runId -ne [string]$old['RunId'] -or $null -ne $old['Completed']))
    if ($null -ne $old -and -not $newRun -and $e.runId -and $old['RunId'] -and $e.runId -ne [string]$old['RunId']) {
        # A line of another run with no RunStarted in view: an older run's tail; counted, not shown.
        $copy = @{}; foreach ($k in $old.Keys) { $copy[$k] = $old[$k] }
        $copy['Stale'] = [int]$copy['Stale'] + 1
        $Store[$key] = $copy
        return
    }
    $run = @{}
    if ($newRun) {
        $run = @{ RunId = $e.runId; Cluster = $e.cluster; Mode = $e.mode; Route = ''; Started = $e.timestamp; Completed = $null; ExitCode = $null; Failed = $false
            Events = 0; Stale = 0; LastEventAt = $e.timestamp; Message = ''; NextAction = ''; Selected = [string[]]@(); ClusterState = ''; ClusterMessage = ''
            Order = [string[]]@(); Steps = @{} }
    }
    else { foreach ($k in $old.Keys) { $run[$k] = $old[$k] } }
    $run['Events'] = [int]$run['Events'] + 1
    $run['LastEventAt'] = $e.timestamp
    if ($e.cluster -and -not $run['Cluster']) { $run['Cluster'] = $e.cluster }
    if ($e.mode -and -not $run['Mode']) { $run['Mode'] = $e.mode }
    switch ($e.state) {
        'RunStarted' {
            if ($e.data.ContainsKey('route')) { $run['Route'] = [string]$e.data['route'] }
            if ($e.data.ContainsKey('selected')) { $run['Selected'] = [string[]]@($e.data['selected'] | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -First $script:AzlSonarPostDeploymentMaxSteps) }
            if ($e.evidence) { $run['Message'] = $e.evidence }
        }
        { $_ -in 'RunCompleted', 'RunFailed' } {
            $run['Completed'] = $e.timestamp
            if ($e.data.ContainsKey('exitCode') -and "$($e.data['exitCode'])" -match '^-?\d+$') { $run['ExitCode'] = [int]$e.data['exitCode'] }
            if ($e.state -eq 'RunFailed' -or ($null -ne $run['ExitCode'] -and [int]$run['ExitCode'] -ne 0)) { $run['Failed'] = $true }
            $result = if ($e.data.ContainsKey('result')) { [string]$e.data['result'] } else { $e.evidence }
            if ($result) { $run['Message'] = $result }
            if ($e.nextAction) { $run['NextAction'] = $e.nextAction }
        }
        'ClusterReachable' { $run['ClusterState'] = 'reachable'; $run['ClusterMessage'] = $e.evidence }
        'ClusterUnreachable' { $run['ClusterState'] = 'unreachable'; $run['ClusterMessage'] = $e.evidence; if ($e.nextAction) { $run['NextAction'] = $e.nextAction } }
        default {
            $status = Get-AzlSonarPostDeploymentStepStatus -State $e.state -Step $e.step
            if ($status) {
                $steps = @{}; foreach ($k in $run['Steps'].Keys) { $steps[$k] = $run['Steps'][$k] }
                $order = [System.Collections.Generic.List[string]]::new([string[]]@($run['Order']))
                if (-not $steps.ContainsKey($e.step) -and $order.Count -ge $script:AzlSonarPostDeploymentMaxSteps) { $Store[$key] = $run; return }
                $previous = if ($steps.ContainsKey($e.step)) { $steps[$e.step] } else { $null }
                if ($null -eq $previous) { $order.Add($e.step) }
                $task = if ($e.data.ContainsKey('task') -and [string]$e.data['task']) { [string]$e.data['task'] } elseif ($null -ne $previous -and $previous['Task']) { [string]$previous['Task'] } else { '' }
                $exit = if ($e.data.ContainsKey('exitCode') -and "$($e.data['exitCode'])" -match '^-?\d+$') { [int]$e.data['exitCode'] } elseif ($null -ne $previous) { $previous['ExitCode'] } else { $null }
                $started = if ($status -eq 'running') { $e.timestamp } elseif ($null -ne $previous) { $previous['Started'] } else { $null }
                $steps[$e.step] = @{ Id = $e.step; Task = $task; Status = $status; State = $e.state; Evidence = $e.evidence; ExitCode = $exit; NextAction = $e.nextAction
                    Level = $e.level; At = $e.timestamp; Started = $started }
                $run['Steps'] = $steps
                $run['Order'] = $order.ToArray()
            }
        }
    }
    $Store[$key] = $run
}

function Resolve-AzlSonarPostDeploymentEventsFile {
    <#
    .SYNOPSIS
        The post-deployment event file to follow: post-deployment-events.jsonl in the events folder (the folder that holds
        updateEventsPath, armEventsPath, osConfigEventsPath or verificationEventsPath). '' when no folder is configured.
    .DESCRIPTION
        The toolkit writes the feed to the events folder (deployment.events_directory). The first folder that holds the file wins; when
        none holds it yet, the first configured folder is the one to wait on. With -MustExist only a folder that holds the file counts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Config, [switch]$MustExist)

    if ($null -eq $Config) { return '' }
    $folders = [System.Collections.Generic.List[string]]::new()
    foreach ($k in 'updateEventsPath', 'armEventsPath', 'osConfigEventsPath', 'verificationEventsPath') {
        $p = [string](Get-AzlSonarMember $Config $k '')
        if (-not $p.Trim()) { continue }
        $dir = if (Test-Path -LiteralPath $p -PathType Container) { $p } else { Split-Path -Parent $p }
        if ($dir -and -not $folders.Contains($dir)) { $folders.Add($dir) }
    }
    foreach ($dir in $folders) {
        $candidate = Join-Path -Path $dir -ChildPath $script:AzlSonarPostDeploymentFileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if ($MustExist -or $folders.Count -eq 0) { return '' }
    return (Join-Path -Path $folders[0] -ChildPath $script:AzlSonarPostDeploymentFileName)
}

function Invoke-AzlSonarPostDeploymentEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the post-deployment event file, adds each new event to the log pane and rebuilds the run entry of
        Shared.PostDeploymentEvents from the whole file whenever it changes, until the stop flag is set.
    .DESCRIPTION
        The file is small, so the run entry is rebuilt from all its lines on every change: a file the toolkit replaced or emptied is
        shown as it is now. A missing file or folder is not an error (nobody has run the post-deployment yet).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [double]$PollSeconds = 2
    )

    if (-not (Resolve-AzlSonarPostDeploymentEventsFile -Config $Config)) { return }
    $stamp = $null
    $head = $null
    $emitted = 0
    while (-not $Shared.Stop) {
        try {
            $path = Resolve-AzlSonarPostDeploymentEventsFile -Config $Config
            $file = Read-AzlSonarVerificationEventFile -Path $path
            if ("$path|$($file.Found)|$($file.Stamp)" -ne $stamp) {
                $stamp = "$path|$($file.Found)|$($file.Stamp)"
                $lines = @($file.Lines)
                $first = if ($lines.Count -gt 0) { [string]$lines[0] } else { '' }
                if ($first -ne $head -or $lines.Count -lt $emitted) { $emitted = 0 }
                $head = $first
                $fresh = @($lines | Select-Object -Skip $emitted)
                $emitted = $lines.Count
                $logLines = foreach ($raw in $fresh) { ConvertFrom-AzlSonarPostDeploymentEvent -Line $raw }
                if (@($logLines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($logLines) }
                if ($Shared.Contains('PostDeploymentEvents')) {
                    $built = @{}
                    foreach ($raw in $lines) { Add-AzlSonarPostDeploymentEvent -Store $built -Line $raw }
                    $target = $Shared['PostDeploymentEvents']
                    if ($built.ContainsKey($script:AzlSonarPostDeploymentKey)) { $target[$script:AzlSonarPostDeploymentKey] = $built[$script:AzlSonarPostDeploymentKey] }
                    else { $target.Remove($script:AzlSonarPostDeploymentKey) }
                }
            }
        }
        catch { Write-Verbose "Post-deployment event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

function Get-AzlSonarPostDeploymentState {
    <#
    .SYNOPSIS
        The postDeployment object of /api/state, from the post-deployment event store. Pure; no Azure call.
    .DESCRIPTION
        { configured, hasData, file, status (notstarted | running | planned | passed | warning | failed | incomplete), kind (idle | run |
        ok | warn | err: what the tile shows), mode (Plan | Apply | ''), word, verdict (the toolkit's one-line result), exitCode,
        nextAction, cluster{state (reachable | unreachable | ''), message}, counts{total, planned, passed, skipped, warning, failed,
        notrun, running, pending, refused}, steps[{id, order, task, status, word, kind, reason, exitCode, nextAction, at}],
        run{runId, cluster, route, started, completed, lastEventAt, events, stale}, warnings[] }.
        A Plan has no failed state: a Plan that completed with exit code 0 is planned (informational); one that stopped is
        'incomplete' (kind warn), its failed step stays a Failed step in the list but never turns the tile red. An Apply that failed
        is 'failed' (kind err); exit code 3 (stopped after a step with warnings) is 'warning'. 'running' is a run with no closing line.
    .PARAMETER Store
        Shared.PostDeploymentEvents; the run is under the key '*'.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Store,
        [Parameter(Mandatory)][object]$Config
    )

    $file = Resolve-AzlSonarPostDeploymentEventsFile -Config $Config
    $configured = [bool]$file
    $run = if ($null -ne $Store -and $Store.Contains($script:AzlSonarPostDeploymentKey)) { $Store[$script:AzlSonarPostDeploymentKey] } else { $null }
    $zero = [ordered]@{ total = 0; planned = 0; passed = 0; skipped = 0; warning = 0; failed = 0; refused = 0; notrun = 0; running = 0; pending = 0 }
    if ($null -eq $run) {
        return [ordered]@{ configured = $configured; hasData = $false; file = $(if ($file) { [System.IO.Path]::GetFileName($file) } else { '' }); status = 'notstarted'; kind = 'idle'
            mode = ''; word = 'waiting'; verdict = ''; exitCode = $null; nextAction = ''; cluster = [ordered]@{ state = ''; message = '' }; counts = $zero; steps = @()
            run = $null; warnings = @() }
    }
    $mode = [string]$run['Mode']
    $isPlan = $mode -eq 'Plan'
    $done = $null -ne $run['Completed']
    # The steps: the ids of the table first (in its order), then any other id in the order first seen. A step the run selected and has
    # not reported yet is waiting.
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $script:AzlSonarPostDeploymentSteps.Keys) { if ($run['Steps'].ContainsKey([string]$id) -or @($run['Selected']) -contains [string]$id) { $ids.Add([string]$id) } }
    foreach ($id in @($run['Order'])) { if (-not $ids.Contains([string]$id)) { $ids.Add([string]$id) } }
    foreach ($id in @($run['Selected'])) { if (-not $ids.Contains([string]$id)) { $ids.Add([string]$id) } }
    $counts = [ordered]@{}; foreach ($k in $zero.Keys) { $counts[$k] = 0 }
    $position = 0
    $steps = foreach ($id in $ids) {
        $position++
        $s = if ($run['Steps'].ContainsKey($id)) { $run['Steps'][$id] } else { $null }
        $status = if ($null -ne $s) { [string]$s['Status'] } else { 'pending' }
        # A step still 'running' or waiting in a run that ended is not running any more: the run stopped before it reported.
        if ($done -and $status -in 'running', 'pending') { $status = 'notrun' }
        $task = if ($null -ne $s -and $s['Task']) { [string]$s['Task'] } elseif ($script:AzlSonarPostDeploymentSteps.Contains($id)) { [string]$script:AzlSonarPostDeploymentSteps[$id] } else { '' }
        $kind = switch ($status) {
            'passed' { 'ok' } 'running' { 'run' } 'warning' { 'warn' } 'refused' { $(if ($isPlan) { 'warn' } else { 'err' }) } 'failed' { $(if ($isPlan) { 'warn' } else { 'err' }) } default { 'idle' }
        }
        $counts[$status] = [int]$counts[$status] + 1
        $counts['total'] = [int]$counts['total'] + 1
        [ordered]@{
            id = $id; order = $position; task = $task; status = $status; word = [string]$script:AzlSonarPostDeploymentWord[$status]; kind = $kind
            reason = $(if ($null -ne $s) { Protect-AzlSonarText -Text ([string]$s['Evidence']) } else { '' })
            exitCode = $(if ($null -ne $s) { $s['ExitCode'] } else { $null })
            nextAction = $(if ($null -ne $s) { Protect-AzlSonarText -Text ([string]$s['NextAction']) } else { '' })
            at = $(if ($null -ne $s) { [string]$s['At'] } else { '' })
        }
    }
    $steps = @($steps)
    $exit = $run['ExitCode']
    $status = if (-not $done) { 'running' }
    elseif ($null -ne $exit -and [int]$exit -eq 0 -and -not $run['Failed']) { $(if ($isPlan) { 'planned' } else { 'passed' }) }
    elseif ($null -ne $exit -and [int]$exit -eq 3) { 'warning' }
    elseif ($isPlan) { 'incomplete' }
    else { 'failed' }
    $kind = switch ($status) { 'running' { 'run' } 'passed' { 'ok' } 'planned' { 'idle' } 'warning' { 'warn' } 'incomplete' { 'warn' } 'failed' { 'err' } default { 'idle' } }
    $word = switch ($status) {
        'running' { $(if ($isPlan) { 'planning' } else { 'running' }) } 'planned' { 'planned' } 'passed' { 'passed' } 'warning' { 'stopped after warnings' }
        'incomplete' { 'plan stopped' } 'failed' { 'failed' } default { 'waiting' }
    }
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($status -eq 'incomplete') { $warnings.Add("The plan stopped$(if ($run['Message']) { ': ' + (Protect-AzlSonarText -Text ([string]$run['Message'])) }). A plan changes nothing: this is what it found, not a failed deployment.") }
    if ($run['ClusterState'] -eq 'unreachable') { $warnings.Add("The cluster did not answer$(if ($run['ClusterMessage']) { ': ' + (Protect-AzlSonarText -Text ([string]$run['ClusterMessage'])) }).") }
    if ([int]$run['Stale'] -gt 0) { $warnings.Add("Ignored $([int]$run['Stale']) line(s) of an older run.") }
    return [ordered]@{
        configured = $configured; hasData = $true; file = $(if ($file) { [System.IO.Path]::GetFileName($file) } else { '' }); status = $status; kind = $kind
        mode = $mode; word = $word; verdict = (Protect-AzlSonarText -Text ([string]$run['Message'])); exitCode = $exit
        nextAction = (Protect-AzlSonarText -Text ([string]$run['NextAction']))
        cluster = [ordered]@{ state = [string]$run['ClusterState']; message = (Protect-AzlSonarText -Text ([string]$run['ClusterMessage'])) }
        counts = $counts; steps = $steps
        run = [ordered]@{ runId = [string]$run['RunId']; cluster = [string]$run['Cluster']; route = [string]$run['Route']; started = [string]$run['Started']
            completed = $run['Completed']; lastEventAt = [string]$run['LastEventAt']; events = [int]$run['Events']; stale = [int]$run['Stale'] }
        warnings = $warnings.ToArray()
    }
}

function Get-AzlSonarPostDeploymentSection {
    <#
    .SYNOPSIS
        The postDeployment object of the state for the Auto and Deployment monitors, or $null for any other monitor. No Azure call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][System.Collections.IDictionary]$Store
    )

    if (-not (Get-AzlSonarMonitorPlan -Monitor ([string](Get-AzlSonarMember $Config 'monitor' 'Auto'))).postDeploymentEvents) { return $null }
    return (Get-AzlSonarPostDeploymentState -Store $Store -Config $Config)
}

function Test-AzlSonarOfflinePostDeployment {
    <#
    .SYNOPSIS
        True when the Deployment monitor can run without an Azure sign-in: the toolkit's post-deployment-events.jsonl is there to follow.
    .DESCRIPTION
        Only the Deployment monitor does this (Auto also needs Azure for the deployment itself). The file is found in the events
        folder of the toolkit's other feeds; no new configuration key. The file must exist: a folder that merely might get one later
        is not a source.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object]$Config)

    if ((Get-AzlSonarMonitorName -Value ([string](Get-AzlSonarMember $Config 'monitor' 'Auto'))) -ne 'Deployment') { return $false }
    return [bool](Resolve-AzlSonarPostDeploymentEventsFile -Config $Config -MustExist)
}

function Get-AzlSonarPostDeploymentOfflineState {
    <#
    .SYNOPSIS
        The state of the Deployment monitor when nobody is signed in to Azure: the toolkit's post-deployment events (and the ARM
        events of the deployment, when its file is there) only. Azure is a plain fact, never an error: pollError stays $null.
    .DESCRIPTION
        Built from the initial state (no Azure call, no node). The phase is post-deployment, or failed when an Apply run failed; the
        machine cards stay Unknown (they come from Azure).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][System.Collections.IDictionary]$PostDeploymentEvents,
        [AllowNull()][System.Collections.IDictionary]$ArmEvents,
        [datetime]$Now = [datetime]::UtcNow
    )

    $state = Get-AzlSonarInitialState -Config $Config
    $pd = Get-AzlSonarPostDeploymentState -Store $PostDeploymentEvents -Config $Config
    $state['arm'] = Get-AzlSonarArmState -Store $ArmEvents -Config $Config -Now $Now
    $pd['azure'] = [ordered]@{ connected = $false; status = 'notconnected'
        message = 'The Azure live poll is not connected: nobody is signed in to Azure in this PowerShell session. Sonar shows the toolkit''s post-deployment events only. To add what Azure and the cluster say about the deployment, run Connect-AzAccount and start Sonar again.' }
    $state['postDeployment'] = $pd
    $failed = $pd.hasData -and $pd.status -eq 'failed'
    $state.phase = if ($failed) { 'failed' } else { 'post-deployment' }
    $state.activePhase = 'post-deployment'
    $state.track = 'post-deployment'
    $state.polledAt = Format-AzlSonarDate $Now.ToUniversalTime()
    return $state
}
