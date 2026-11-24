Set-StrictMode -Version Latest

# Solution update events (azurelocal-toolkit Get-AvailableSolutionUpdate.ps1 and Start-AzureLocalSolutionUpdate.ps1, gap K9):
# the update scripts append what they do to update-events.jsonl in the one shared events folder (deployment.events_directory,
# else <ProgramData>\AzureLocalToolkit\<cluster.name>\events), one object per line, in the envelope every toolkit feed uses:
# { timestamp (UTC round trip), node ('*' for the run, else a node name), stage 'SolutionUpdate', step, state, evidence,
#   level (Info|Warning|Error), nextAction, schemaVersion, runId, mode (Check|Plan|WhatIf|Install), cluster, ...data }.
# Sonar follows that file (local, read-only, no Azure), shows each event in the log pane (file 'update-events') and builds an
# offline update view from it (Get-AzlSonarUpdateEventState): one stage per step the run names, in the order first seen.
# The reader does not depend on a fixed list of states, so the update scripts can add one without a Sonar release:
#   RunStarted starts a run (a new runId, or no runId, starts over); RunCompleted (exitCode) and RunFailed end it.
#   A stage's status is data.status when the line gives one (notstarted, running, success, error, skipped), else data.result
#   (Passed, Failed, Warning, Skipped), else the level (Error), else the state's last word: ...Failed, ...Refused, ...TimedOut
#   are error; ...Skipped is skipped; ...Started, ...Running, ...Progress, ...Waiting, ...Submitted, ...Installing and
#   ...Preparing are running; anything else is success. data.update / data.updateName and data.version name the update.
# The Azure update track stays the source when Azure reports a run (it has the real step tree); the events fill the Update
# view when Azure has no data or cannot be reached (an offline run, -WhatIf, a run before the cluster reports).

$script:AzlSonarUpdateEventRunKey = '*'
$script:AzlSonarUpdateEventFile = 'update-events'
$script:AzlSonarUpdateEventFileName = 'update-events.jsonl'
$script:AzlSonarUpdateEventStages = 'SolutionUpdate', 'Update'
$script:AzlSonarUpdateEventMaxSteps = 400

function ConvertFrom-AzlSonarUpdateEventLine {
    <#
    .SYNOPSIS
        Parses one line of the update event file into { node, state, step, when, timestamp, evidence, level, nextAction, runId,
        mode, cluster, data }, or $null when it is not an event (no node or state, or another stage).
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
    $stage = [string](& $get 'stage' 'SolutionUpdate')
    if ($stage -and $stage -notin $script:AzlSonarUpdateEventStages) { return $null }
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

function ConvertFrom-AzlSonarUpdateEvent {
    <#
    .SYNOPSIS
        One event line of the update event file as a log line { file, text, level }, or $null when the line is not an event.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Line)

    $e = ConvertFrom-AzlSonarUpdateEventLine -Line $Line
    if ($null -eq $e) { return $null }
    $prefix = if ($e.when) { $e.when.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) + ' ' } else { '' }
    $text = "${prefix}[update] $($e.node) $($e.state)"
    if ($e.step) { $text += " ($($e.step))" }
    if ($e.evidence) { $text += ": $($e.evidence)" }
    if ($e.nextAction) { $text += " -> next: $($e.nextAction)" }
    return @{ file = $script:AzlSonarUpdateEventFile; text = $text; level = ([string]$e.level).ToLowerInvariant() }
}

function Get-AzlSonarUpdateEventStatus {
    <#
    .SYNOPSIS
        The step status (notstarted, running, success, error, skipped) one update event gives its stage. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$State, [string]$Level = 'Info', [AllowNull()][hashtable]$Data)

    if ($null -ne $Data) {
        $given = ([string]$(if ($Data.ContainsKey('status')) { $Data['status'] } else { '' })).ToLowerInvariant()
        if ($given -in 'notstarted', 'running', 'success', 'error', 'skipped') { return $given }
        $result = ([string]$(if ($Data.ContainsKey('result')) { $Data['result'] } else { '' })).ToLowerInvariant()
        switch ($result) { 'passed' { return 'success' } 'warning' { return 'success' } 'failed' { return 'error' } 'skipped' { return 'skipped' } }
    }
    if ($Level -eq 'Error') { return 'error' }
    if ($State -match '(Failed|Refused|TimedOut)$') { return 'error' }
    if ($State -match 'Skipped$') { return 'skipped' }
    if ($State -match '(Started|Running|Progress|Waiting|Submitted|Installing|Preparing)$') { return 'running' }
    return 'success'
}

function Add-AzlSonarUpdateEvent {
    <#
    .SYNOPSIS
        Records one event line in the update store ('*': the run with its stages). Each change stores a new run object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Store,
        [AllowNull()][AllowEmptyString()][string]$Line
    )

    $e = ConvertFrom-AzlSonarUpdateEventLine -Line $Line
    if ($null -eq $e) { return }
    $key = $script:AzlSonarUpdateEventRunKey
    $old = if ($Store.Contains($key)) { $Store[$key] } else { $null }
    $newRun = ($null -eq $old) -or ($e.state -eq 'RunStarted' -and (-not $e.runId -or $e.runId -ne [string]$old['RunId'] -or $null -ne $old['Completed']))
    if ($null -ne $old -and -not $newRun -and $e.runId -and $old['RunId'] -and $e.runId -ne [string]$old['RunId']) {
        # A line of another run that has no RunStarted in view: an older run's tail; counted, not shown.
        $copy = @{}; foreach ($k in $old.Keys) { $copy[$k] = $old[$k] }
        $copy['Stale'] = [int]$copy['Stale'] + 1
        $Store[$key] = $copy
        return
    }
    $run = @{}
    if ($newRun) {
        $run = @{ RunId = $e.runId; Mode = $e.mode; Cluster = $e.cluster; Started = $e.timestamp; Completed = $null; ExitCode = $null; Failed = $false
            Events = 0; Stale = 0; LastEventAt = $e.timestamp; Update = ''; Version = ''; Message = ''; NextAction = ''; Order = [string[]]@(); Steps = @{} }
    }
    else { foreach ($k in $old.Keys) { $run[$k] = $old[$k] } }
    $run['Events'] = [int]$run['Events'] + 1
    $run['LastEventAt'] = $e.timestamp
    if ($e.mode -and -not $run['Mode']) { $run['Mode'] = $e.mode }
    if ($e.cluster -and -not $run['Cluster']) { $run['Cluster'] = $e.cluster }
    foreach ($k in 'update', 'updateName') { if ($e.data.ContainsKey($k) -and $e.data[$k]) { $run['Update'] = [string]$e.data[$k] } }
    if ($e.data.ContainsKey('version') -and $e.data['version']) { $run['Version'] = [string]$e.data['version'] }
    # The run's message and next action: the newest error or next action that says something (a closing RunCompleted with no
    # text keeps the failure that came before it).
    if (($e.level -eq 'Error' -or $e.nextAction) -and $e.evidence) { $run['Message'] = $e.evidence }
    if ($e.nextAction) { $run['NextAction'] = $e.nextAction }
    switch ($e.state) {
        'RunCompleted' {
            $run['Completed'] = $e.timestamp
            if ($e.data.ContainsKey('exitCode') -and "$($e.data['exitCode'])" -match '^-?\d+$') { $run['ExitCode'] = [int]$e.data['exitCode'] }
            if ($e.level -eq 'Error' -or ($null -ne $run['ExitCode'] -and [int]$run['ExitCode'] -ne 0)) { $run['Failed'] = $true }
        }
        'RunFailed' { $run['Completed'] = $e.timestamp; $run['Failed'] = $true }
    }
    if ($e.state -notin 'RunStarted', 'RunCompleted', 'RunFailed' -or $e.step) {
        $id = if ($e.step) { $e.step } else { $e.state }
        $steps = @{}; foreach ($k in $run['Steps'].Keys) { $steps[$k] = $run['Steps'][$k] }
        $order = [System.Collections.Generic.List[string]]::new([string[]]@($run['Order']))
        $prev = if ($steps.ContainsKey($id)) { $steps[$id] } else { $null }
        if ($null -eq $prev -and $order.Count -ge $script:AzlSonarUpdateEventMaxSteps) { $Store[$key] = $run; return }
        $status = Get-AzlSonarUpdateEventStatus -State $e.state -Level $e.level -Data $e.data
        $name = [string]$(if ($e.data.ContainsKey('stepName') -and $e.data['stepName']) { $e.data['stepName'] } elseif ($null -ne $prev) { $prev['Name'] } else { ([regex]::Replace($id, '(?<=[a-z0-9])(?=[A-Z])', ' ')).Trim() })
        $step = @{
            Id = $id; Name = $name; Status = $status; State = $e.state; Node = $e.node; Message = $e.evidence; NextAction = $e.nextAction
            Start = $(if ($null -ne $prev -and $prev['Start']) { $prev['Start'] } else { $e.timestamp })
            End = $(if ($status -in 'success', 'error', 'skipped') { $e.timestamp } else { $null })
            Progress = $(if ($e.data.ContainsKey('progressPercentage') -and "$($e.data['progressPercentage'])" -match '^\d+(\.\d+)?$') { [double]$e.data['progressPercentage'] } elseif ($null -ne $prev) { $prev['Progress'] } else { $null })
        }
        if ($null -eq $prev) { $order.Add($id) }
        $steps[$id] = $step
        $run['Steps'] = $steps
        $run['Order'] = $order.ToArray()
    }
    $Store[$key] = $run
}

function Invoke-AzlSonarUpdateEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the update event file, adds each event to the log pane and to the store until the stop flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [double]$PollSeconds = 2
    )

    $path = [string](Get-AzlSonarMember $Config 'updateEventsPath' '')
    if (-not $path) { return }
    $offset = [long]0
    while (-not $Shared.Stop) {
        try {
            $chunk = Read-AzlSonarArmEventChunk -Path $path -Offset $offset
            if ($chunk.Truncated -and $Shared.Contains('UpdateEvents')) { foreach ($k in @($Shared['UpdateEvents'].Keys)) { $Shared['UpdateEvents'].Remove($k) } }
            $offset = [long]$chunk.Offset
            $lines = foreach ($raw in $chunk.Lines) { ConvertFrom-AzlSonarUpdateEvent -Line $raw }
            if (@($lines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($lines) }
            if ($Shared.Contains('UpdateEvents')) { foreach ($raw in $chunk.Lines) { Add-AzlSonarUpdateEvent -Store $Shared['UpdateEvents'] -Line $raw } }
        }
        catch { Write-Verbose "Update event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

function Get-AzlSonarUpdateEventState {
    <#
    .SYNOPSIS
        The updateEvents object of /api/state, from the update event store. Pure.
    .DESCRIPTION
        { configured, hasData, status (notstarted|running|success|error), phase (preparing, installing, failed, available,
        idle), level (run|error|ok|neutral), label, plan (true for a Check, Plan or WhatIf run: nothing was installed),
        run{runId, mode, cluster, started, completed, exitCode, lastEventAt, events, stale, update, version, message,
        nextAction}, tree (one step per stage), counts }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Store,
        [Parameter(Mandatory)][object]$Config
    )

    $configured = [bool][string](Get-AzlSonarMember $Config 'updateEventsPath' '')
    $run = if ($null -ne $Store -and $Store.Contains($script:AzlSonarUpdateEventRunKey)) { $Store[$script:AzlSonarUpdateEventRunKey] } else { $null }
    if ($null -eq $run) {
        return [ordered]@{ configured = $configured; hasData = $false; status = 'notstarted'; phase = 'idle'; level = 'neutral'; label = ''; plan = $false; run = $null; tree = @(); counts = (Measure-AzlSonarStepTree -Tree @()) }
    }
    $tree = @(foreach ($id in @($run['Order'])) {
            $s = $run['Steps'][$id]
            [ordered]@{
                id = "upd.$id"; name = [string]$s['Name']; description = (Protect-AzlSonarText -Text ([string]$s['Message'])); status = [string]$s['Status']; rawStatus = [string]$s['State']
                start = $s['Start']; end = $s['End']; durationSeconds = $null; progressPercentage = $s['Progress']
                errors = @($(if ($s['Status'] -eq 'error' -and $s['Message']) { Protect-AzlSonarText -Text ([string]$s['Message']) })); children = @()
            }
        })
    $mode = [string]$run['Mode']
    $plan = $mode -in 'Check', 'Plan', 'WhatIf'
    $anyError = @($tree | Where-Object { $_.status -eq 'error' }).Count -gt 0
    $done = $null -ne $run['Completed']
    $status = if ($done) { if ([bool]$run['Failed'] -or $anyError) { 'error' } else { 'success' } } elseif ($anyError) { 'error' } else { 'running' }
    $phase = switch ($status) { 'error' { 'failed' } 'running' { $(if ($plan) { 'preparing' } else { 'installing' }) } default { $(if ($plan) { $(if ($run['Update']) { 'available' } else { 'idle' }) } else { 'idle' }) } }
    $level = switch ($status) { 'error' { 'error' } 'running' { 'run' } 'success' { 'ok' } default { 'neutral' } }
    $what = if ($run['Update']) { "$($run['Update'])$(if ($run['Version'] -and $run['Version'] -ne $run['Update']) { " ($($run['Version']))" })" } else { 'the solution update' }
    $label = switch ($status) {
        'running' { $(if ($plan) { "Checking $what (toolkit $mode run, read from the update events)" } else { "Installing $what (read from the update events)" }) }
        'error' { "The toolkit's update run failed$(if ($run['Message']) { ": $($run['Message'])" })" }
        default { $(if ($plan) { "Plan complete for $what; nothing was installed (toolkit $mode run)" } else { "Update run complete for $what" }) }
    }
    return [ordered]@{
        configured = $configured; hasData = $true; status = $status; phase = $phase; level = $level; label = (Protect-AzlSonarText -Text $label); plan = $plan
        run = [ordered]@{
            runId = [string]$run['RunId']; mode = $mode; cluster = [string]$run['Cluster']; started = [string]$run['Started']; completed = $run['Completed']; exitCode = $run['ExitCode']
            lastEventAt = [string]$run['LastEventAt']; events = [int]$run['Events']; stale = [int]$run['Stale']; update = [string]$run['Update']; version = [string]$run['Version']
            message = (Protect-AzlSonarText -Text ([string]$run['Message'])); nextAction = (Protect-AzlSonarText -Text ([string]$run['NextAction']))
        }
        tree = $tree
        counts = (Measure-AzlSonarStepTree -Tree $tree)
    }
}

function Merge-AzlSonarUpdateEvent {
    <#
    .SYNOPSIS
        The update object of /api/state with the toolkit's update events: Azure's track when it has a step tree, else the events.
    .DESCRIPTION
        When Azure reports a run (a step tree), it stays as it is. Otherwise, with update events, the update object shows the
        events' stages, status, phase and label (verified false, source 'events'); what the cluster said (local, sources)
        is kept.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Update,
        [AllowNull()][System.Collections.IDictionary]$Events
    )

    if ($null -eq $Events -or -not [bool]$Events['hasData']) { return $Update }
    # An update object this function built before (source 'events', kept from the previous state after a failed poll) is
    # not Azure's track: it is built again from the events.
    $fromEvents = $null -ne $Update -and [string](Get-AzlSonarMember $Update 'source' '') -eq 'events'
    $azureTree = if ($null -ne $Update -and -not $fromEvents) { Get-AzlSonarMember $Update 'tree' $null } else { $null }
    if (@($azureTree | Where-Object { $null -ne $_ }).Count -gt 0) { return $Update }
    $out = [ordered]@{}
    if ($Update -is [System.Collections.IDictionary]) { foreach ($k in $Update.Keys) { $out[$k] = $Update[$k] } }
    foreach ($k in 'ran', 'nextAction', 'summary', 'active', 'run', 'local', 'sources') { if (-not $out.Contains($k)) { $out[$k] = $null } }
    foreach ($k in 'updates', 'runs') { if (-not $out.Contains($k)) { $out[$k] = @() } }
    $out['verified'] = $false
    $out['source'] = 'events'
    $out['status'] = $Events['status']
    $out['phase'] = $Events['phase']
    $out['level'] = $Events['level']
    $out['label'] = $Events['label']
    $out['ran'] = -not [bool]$Events['plan']
    $out['tree'] = @($Events['tree'])
    $out['counts'] = $Events['counts']
    if ($Events['run'] -and $Events['run'].nextAction) { $out['nextAction'] = [ordered]@{ text = [string]$Events['run'].nextAction; guide = $null } }
    return $out
}
