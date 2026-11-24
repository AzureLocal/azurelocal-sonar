Set-StrictMode -Version Latest

# The pre-cluster verification gate's PLAN events (azurelocal-toolkit, gap K9). Invoke-AzureLocalPreClusterVerification.ps1 -Mode Plan reads
# nothing and checks nothing: it lists which checks apply to this environment. Besides plan.json and plan.md it appends the plan to
# precluster-plan-events.jsonl in the one shared events folder (deployment.events_directory, else -ReportDirectory when the run is given
# one, else <ProgramData>\AzureLocalToolkit\<cluster.name>\events), in the envelope every toolkit feed uses (one object per line):
#   { timestamp (UTC round trip), node '*', stage 'PreClusterVerification', step, state, evidence, level, nextAction, runId, mode 'Plan',
#     cluster, ...data }
#   RunStarted (step Run)                       the plan starts
#   CategoryPlanned (step = the category id)    one per category: data.applies, data.total, data.blocking (checks that apply, all checks,
#                                               checks that apply and block the gate)
#   RunCompleted (step Run)                     data.exitCode 0 and data.result 'Planned'; evidence is the one-line plan and nextAction the
#                                               command that runs the checks
# It is a separate file from precluster-verification-events.jsonl on purpose: a Plan has NO verdict. Sonar therefore shows it as planned
# (informational, nothing was read) and never as Pass or Fail, and it never replaces a verdict the gate wrote: the Verification state's
# `plan` object sits beside the verdict, and the page shows it alone only while the gate has written no run.
#
# Sonar follows the file the way it follows the gate's own: the LATEST run only (a RunStarted with another runId starts over, a line of an
# older run is counted and not shown), rebuilt from the whole file whenever it changes. The store is Shared.VerificationEvents, key 'plan'
# (the gate's run is the key '*'), so no state function needs a new parameter. No new configuration key: the file is looked for in the
# events folder (the folder that holds updateEventsPath, armEventsPath or osConfigEventsPath), then in the folder of the gate's own
# event file.

$script:AzlSonarVerifyPlanKey = 'plan'
$script:AzlSonarVerifyPlanEventFile = 'verification-plan-events'
$script:AzlSonarVerifyPlanFileName = 'precluster-plan-events.jsonl'
$script:AzlSonarVerifyPlanStages = 'PreClusterVerification'
$script:AzlSonarVerifyPlanMaxCategories = 64

function ConvertFrom-AzlSonarVerificationPlanLine {
    <#
    .SYNOPSIS
        Parses one line of the plan event file into { node, state, step, when, timestamp, evidence, level, nextAction, runId, mode,
        cluster, data }, or $null when it is not a plan event (no node or state, or another stage).
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
    $stage = [string](& $get 'stage' 'PreClusterVerification')
    if ($stage -and $stage -notin $script:AzlSonarVerifyPlanStages) { return $null }
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

function ConvertFrom-AzlSonarVerificationPlanEvent {
    <#
    .SYNOPSIS
        One event line of the plan file as a log line { file, text, level }, or $null when the line is not a plan event.
    .DESCRIPTION
        "<UTC time> [verify-plan] <node|*> <State> (<step>): <evidence> -> next: <nextAction>". The level is the event's own (a plan
        normally writes Info lines only).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Line)

    $e = ConvertFrom-AzlSonarVerificationPlanLine -Line $Line
    if ($null -eq $e) { return $null }
    $prefix = if ($e.when) { $e.timestamp + ' ' } else { '' }
    $text = "${prefix}[verify-plan] $($e.node) $($e.state)"
    if ($e.step) { $text += " ($($e.step))" }
    if ($e.evidence) { $text += ": $($e.evidence)" }
    if ($e.nextAction) { $text += " -> next: $($e.nextAction)" }
    return @{ file = $script:AzlSonarVerifyPlanEventFile; text = $text; level = ([string]$e.level).ToLowerInvariant() }
}

function Add-AzlSonarVerificationPlanEvent {
    <#
    .SYNOPSIS
        Records one plan event line in the store (key 'plan': the latest plan run with its categories). Each change stores a new object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Store,
        [AllowNull()][AllowEmptyString()][string]$Line
    )

    $e = ConvertFrom-AzlSonarVerificationPlanLine -Line $Line
    if ($null -eq $e) { return }
    $key = $script:AzlSonarVerifyPlanKey
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
        $run = @{ RunId = $e.runId; Cluster = $e.cluster; Started = $e.timestamp; Completed = $null; ExitCode = $null; Failed = $false
            Events = 0; Stale = 0; LastEventAt = $e.timestamp; Message = ''; NextAction = ''; Order = [string[]]@(); Categories = @{} }
    }
    else { foreach ($k in $old.Keys) { $run[$k] = $old[$k] } }
    $run['Events'] = [int]$run['Events'] + 1
    $run['LastEventAt'] = $e.timestamp
    if ($e.cluster -and -not $run['Cluster']) { $run['Cluster'] = $e.cluster }
    switch ($e.state) {
        'RunCompleted' {
            $run['Completed'] = $e.timestamp
            if ($e.data.ContainsKey('exitCode') -and "$($e.data['exitCode'])" -match '^-?\d+$') { $run['ExitCode'] = [int]$e.data['exitCode'] }
            if ($null -ne $run['ExitCode'] -and [int]$run['ExitCode'] -ne 0) { $run['Failed'] = $true }
            if ($e.evidence) { $run['Message'] = $e.evidence }
            if ($e.nextAction) { $run['NextAction'] = $e.nextAction }
        }
        'RunFailed' {
            # Not produced by the toolkit today. A plan that did not finish has no verdict to fail: it is shown as incomplete.
            $run['Completed'] = $e.timestamp; $run['Failed'] = $true
            if ($e.data.ContainsKey('exitCode') -and "$($e.data['exitCode'])" -match '^-?\d+$') { $run['ExitCode'] = [int]$e.data['exitCode'] }
            if ($e.evidence) { $run['Message'] = $e.evidence }
        }
        'RunStarted' { }
        default {
            if ($e.step -and $e.data.ContainsKey('total')) {
                $num = { param($k) $n = [long]0; if ($e.data.ContainsKey($k) -and [long]::TryParse(([string]$e.data[$k]).Trim(), [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$n)) { $n } else { [long]0 } }
                $categories = @{}; foreach ($k in $run['Categories'].Keys) { $categories[$k] = $run['Categories'][$k] }
                $order = [System.Collections.Generic.List[string]]::new([string[]]@($run['Order']))
                if (-not $categories.ContainsKey($e.step) -and $order.Count -ge $script:AzlSonarVerifyPlanMaxCategories) { $Store[$key] = $run; return }
                if (-not $categories.ContainsKey($e.step)) { $order.Add($e.step) }
                $categories[$e.step] = @{ Id = $e.step; Applies = [int](& $num 'applies'); Total = [int](& $num 'total'); Blocking = [int](& $num 'blocking'); Evidence = $e.evidence; At = $e.timestamp }
                $run['Categories'] = $categories
                $run['Order'] = $order.ToArray()
            }
        }
    }
    $Store[$key] = $run
}

function Resolve-AzlSonarVerificationPlanFile {
    <#
    .SYNOPSIS
        The plan event file to follow: precluster-plan-events.jsonl in the events folder (the folder that holds updateEventsPath,
        armEventsPath or osConfigEventsPath), else in the folder of the gate's own event file. '' when neither is configured.
    .DESCRIPTION
        The toolkit writes the plan feed to the events folder (deployment.events_directory), and to the report directory of the run when
        it is given -ReportDirectory without that setting; both are candidates, and the first one that holds the file wins. When none
        holds it yet, the events folder is the one to wait on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Config)

    if ($null -eq $Config) { return '' }
    $folders = [System.Collections.Generic.List[string]]::new()
    foreach ($k in 'updateEventsPath', 'armEventsPath', 'osConfigEventsPath') {
        $p = [string](Get-AzlSonarMember $Config $k '')
        if ($p.Trim()) { $dir = Split-Path -Parent $p; if ($dir -and -not $folders.Contains($dir)) { $folders.Add($dir) }; break }
    }
    $verify = Resolve-AzlSonarVerificationEventFile -Path ([string](Get-AzlSonarMember $Config 'verificationEventsPath' ''))
    if ($verify) { $dir = Split-Path -Parent $verify; if ($dir -and -not $folders.Contains($dir)) { $folders.Add($dir) } }
    if ($folders.Count -eq 0) { return '' }
    foreach ($dir in $folders) {
        $candidate = Join-Path -Path $dir -ChildPath $script:AzlSonarVerifyPlanFileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return (Join-Path -Path $folders[0] -ChildPath $script:AzlSonarVerifyPlanFileName)
}

function Invoke-AzlSonarVerificationPlanEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the plan event file, adds each new event to the log pane and rebuilds the plan entry of
        Shared.VerificationEvents from the whole file whenever it changes, until the stop flag is set.
    .DESCRIPTION
        The file is small, so the plan entry is rebuilt from all its lines on every change: a file the toolkit replaced or emptied is
        shown as it is now. A missing file or folder is not an error (nobody has planned yet).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [double]$PollSeconds = 2
    )

    if (-not (Resolve-AzlSonarVerificationPlanFile -Config $Config)) { return }
    $stamp = $null
    $head = $null
    $emitted = 0
    while (-not $Shared.Stop) {
        try {
            $path = Resolve-AzlSonarVerificationPlanFile -Config $Config
            $file = Read-AzlSonarVerificationEventFile -Path $path
            if ("$path|$($file.Found)|$($file.Stamp)" -ne $stamp) {
                $stamp = "$path|$($file.Found)|$($file.Stamp)"
                $lines = @($file.Lines)
                $first = if ($lines.Count -gt 0) { [string]$lines[0] } else { '' }
                if ($first -ne $head -or $lines.Count -lt $emitted) { $emitted = 0 }
                $head = $first
                $fresh = @($lines | Select-Object -Skip $emitted)
                $emitted = $lines.Count
                $logLines = foreach ($raw in $fresh) { ConvertFrom-AzlSonarVerificationPlanEvent -Line $raw }
                if (@($logLines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($logLines) }
                if ($Shared.Contains('VerificationEvents')) {
                    $built = @{}
                    foreach ($raw in $lines) { Add-AzlSonarVerificationPlanEvent -Store $built -Line $raw }
                    $target = $Shared['VerificationEvents']
                    if ($built.ContainsKey($script:AzlSonarVerifyPlanKey)) { $target[$script:AzlSonarVerifyPlanKey] = $built[$script:AzlSonarVerifyPlanKey] }
                    else { $target.Remove($script:AzlSonarVerifyPlanKey) }
                }
            }
        }
        catch { Write-Verbose "Verification plan event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

function Get-AzlSonarVerificationPlanState {
    <#
    .SYNOPSIS
        The plan object of the verification state, from the plan entry of the store. Pure.
    .DESCRIPTION
        { configured, hasData, planned (always $true: nothing was read), status (notplanned | planning | planned | incomplete), word,
        file, applies, total, blocking, categories[{id, name, applies, total, blocking, evidence}] (the gate's category order, then
        any other), message, nextAction, run{runId, cluster, started, completed, exitCode, lastEventAt, events, stale}, warnings[] }.
        There is no verdict and no failed state: a plan only says which checks would run. 'planning' is a plan with no closing line
        yet; 'incomplete' is one that reported a non-zero exit code or a RunFailed line (it is a note, never a gate Fail).
    .PARAMETER Store
        Shared.VerificationEvents; the plan entry is under the key 'plan'.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Store,
        [Parameter(Mandatory)][object]$Config
    )

    $file = Resolve-AzlSonarVerificationPlanFile -Config $Config
    $configured = [bool]$file
    $run = if ($null -ne $Store -and $Store.Contains($script:AzlSonarVerifyPlanKey)) { $Store[$script:AzlSonarVerifyPlanKey] } else { $null }
    if ($null -eq $run) {
        return [ordered]@{ configured = $configured; hasData = $false; planned = $true; status = 'notplanned'; word = 'not planned'; file = $(if ($file) { [System.IO.Path]::GetFileName($file) } else { '' })
            applies = 0; total = 0; blocking = 0; categories = @(); message = ''; nextAction = ''; run = $null; warnings = @() }
    }
    $warnings = [System.Collections.Generic.List[string]]::new()
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $script:AzlSonarVerifyCategory.Keys) { if ($run['Categories'].ContainsKey([string]$id)) { $ids.Add([string]$id) } }
    foreach ($id in @($run['Order'])) { if (-not $ids.Contains([string]$id)) { $ids.Add([string]$id) } }
    $categories = foreach ($id in $ids) {
        $c = $run['Categories'][$id]
        $name = if ($script:AzlSonarVerifyCategory.Contains($id)) { [string]$script:AzlSonarVerifyCategory[$id] } else { (Get-Culture).TextInfo.ToTitleCase($id) }
        [ordered]@{ id = $id; name = $name; applies = [int]$c['Applies']; total = [int]$c['Total']; blocking = [int]$c['Blocking']; evidence = (Protect-AzlSonarText -Text ([string]$c['Evidence'])) }
    }
    $categories = @($categories)
    $sumApplies = 0; $sumTotal = 0; $sumBlocking = 0
    foreach ($c in $categories) { $sumApplies += [int]$c['applies']; $sumTotal += [int]$c['total']; $sumBlocking += [int]$c['blocking'] }
    $done = $null -ne $run['Completed']
    $status = if (-not $done) { 'planning' } elseif ([bool]$run['Failed']) { 'incomplete' } else { 'planned' }
    if ($status -eq 'incomplete') { $warnings.Add("The plan did not finish cleanly$(if ($run['Message']) { ': ' + (Protect-AzlSonarText -Text ([string]$run['Message'])) }). It is a plan: no check ran, so this is not a gate result.") }
    if ([int]$run['Stale'] -gt 0) { $warnings.Add("Ignored $([int]$run['Stale']) line(s) of an older plan.") }
    $word = switch ($status) { 'planning' { 'planning' } 'planned' { 'planned' } default { 'plan incomplete' } }
    return [ordered]@{
        configured = $configured; hasData = $true; planned = $true; status = $status; word = $word; file = $(if ($file) { [System.IO.Path]::GetFileName($file) } else { '' })
        applies = $sumApplies; total = $sumTotal; blocking = $sumBlocking
        categories = $categories
        message = (Protect-AzlSonarText -Text ([string]$run['Message'])); nextAction = (Protect-AzlSonarText -Text ([string]$run['NextAction']))
        run = [ordered]@{ runId = [string]$run['RunId']; cluster = [string]$run['Cluster']; started = [string]$run['Started']; completed = $run['Completed']; exitCode = $run['ExitCode']
            lastEventAt = [string]$run['LastEventAt']; events = [int]$run['Events']; stale = [int]$run['Stale'] }
        warnings = $warnings.ToArray()
    }
}
