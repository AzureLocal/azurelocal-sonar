Set-StrictMode -Version Latest

# Export bundle (plan task S-9): from a recording of a run, a timeline JSON (phases, steps, errors, durations) and a
# self-contained HTML report (no script, no external resource, opens anywhere). Works on any recording, so the same
# bundle comes out of a live run recorded with -Record and out of a replayed file.

function ConvertTo-AzlSonarHtmlText {
    <#
    .SYNOPSIS
        HTML-encodes a value for the report (text and attribute safe).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-AzlSonarBundleStep {
    <#
    .SYNOPSIS
        Flattens a step tree (JsonNode array) into rows: section, path, depth, name, status, start, end, duration, errors.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()][object]$Tree,
        [Parameter(Mandatory)][string]$Section,
        [string]$Path = '',
        [int]$Depth = 0
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    if ($Tree -isnot [System.Text.Json.Nodes.JsonArray]) { return , $rows.ToArray() }
    foreach ($node in $Tree) {
        if ($node -isnot [System.Text.Json.Nodes.JsonObject]) { continue }
        $name = ConvertTo-AzlSonarNodeText $node['name']
        $here = if ($Path) { "$Path > $name" } else { $name }
        $errors = [System.Collections.Generic.List[string]]::new()
        if ($node['errors'] -is [System.Text.Json.Nodes.JsonArray]) { foreach ($e in $node['errors']) { $errors.Add((ConvertTo-AzlSonarNodeText $e)) } }
        $duration = $null
        if ($node['durationSeconds'] -is [System.Text.Json.Nodes.JsonValue] -and $node['durationSeconds'].GetValueKind() -eq [System.Text.Json.JsonValueKind]::Number) { $duration = $node['durationSeconds'].GetValue[double]() }
        $rows.Add([ordered]@{
                section         = $Section
                path            = $here
                depth           = $Depth
                name            = $name
                status          = ConvertTo-AzlSonarNodeText $node['status']
                rawStatus       = ConvertTo-AzlSonarNodeText $node['rawStatus']
                start           = ConvertTo-AzlSonarNodeText $node['start']
                end             = ConvertTo-AzlSonarNodeText $node['end']
                durationSeconds = $duration
                errors          = $errors.ToArray()
            })
        foreach ($child in (Get-AzlSonarBundleStep -Tree $node['children'] -Section $Section -Path $here -Depth ($Depth + 1))) { $rows.Add($child) }
    }
    return , $rows.ToArray()
}

function Format-AzlSonarBundleDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Seconds)

    if ($null -eq $Seconds) { return '' }
    $ts = [timespan]::FromSeconds([double]$Seconds)
    return '{0}:{1:mm\:ss}' -f [int][Math]::Floor($ts.TotalHours), $ts
}

function Export-AzlSonarBundle {
    <#
    .SYNOPSIS
        Writes the export bundle of a recording: <name>-timeline.json and <name>-report.html in -OutDirectory.
    .DESCRIPTION
        The timeline holds the recording (file, sessions, from, to), the phases with start, end and duration, every step of
        validation, deployment and the update track with status, times, duration and errors, the errors on their own, the
        last state's summary and the warning and error log lines (at most -MaxLogLines, the first ones of the run). The
        report shows the same as plain HTML with inline CSS only. A recording made without -Publishable still holds the
        identifiers of the cluster, and so do the bundle files: share them only after Protect-Recording.ps1.
    .PARAMETER Recording
        A recording (.jsonl or .jsonl.gz).
    .PARAMETER OutDirectory
        Where to write the two files (created when missing).
    .PARAMETER Name
        File name prefix. Default: the recording's name without extension.
    .PARAMETER MaxLogLines
        Warning and error log lines kept in the bundle. Default 300.
    .OUTPUTS
        PSCustomObject: Timeline, Report, Phases, Steps, Errors, LogLines.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the two files the caller asked for.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Recording,
        [Parameter(Mandatory)][string]$OutDirectory,
        [string]$Name,
        [ValidateRange(0, 100000)][int]$MaxLogLines = 300
    )

    $rec = Read-AzlSonarRecording -Path $Recording -KeepLogNodes
    $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDirectory)
    if (-not [System.IO.Directory]::Exists($out)) { $null = [System.IO.Directory]::CreateDirectory($out) }
    if (-not $Name) { $Name = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($rec.Name)) }
    $Name = $Name -replace '[^\w\.-]', '_'
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $iso = "yyyy-MM-dd'T'HH:mm:ss'Z'"

    # Walk the states once: phase changes (first time each phase is seen, in order) and the last state.
    $state = $null
    $phases = [System.Collections.Generic.List[hashtable]]::new()
    $lastKey = $null
    $logLines = [System.Collections.Generic.List[object]]::new()
    $logCounts = @{ info = 0; warning = 0; error = 0 }
    foreach ($e in $rec.Events) {
        switch ($e.Kind) {
            'state' {
                if ($e.Node['full'] -is [System.Text.Json.Nodes.JsonObject]) { $state = $e.Node['full'].DeepClone() }
                elseif ($null -ne $state -and $e.Node['ops'] -is [System.Text.Json.Nodes.JsonArray]) { $state = (Invoke-AzlSonarJsonPatch -Root $state -Ops $e.Node['ops'])[0] }
                if ($state -is [System.Text.Json.Nodes.JsonObject]) {
                    $phase = ConvertTo-AzlSonarNodeText $state['phase']
                    $active = ConvertTo-AzlSonarNodeText $state['activePhase']
                    $key = "$phase|$active"
                    if ($key -ne $lastKey) {
                        if ($phases.Count -gt 0) { $phases[$phases.Count - 1].end = $e.T }
                        $phases.Add(@{ phase = $phase; activePhase = $active; start = $e.T; end = $null })
                        $lastKey = $key
                    }
                }
            }
            'log' {
                foreach ($l in $e.Node['lines']) {
                    if ($l -isnot [System.Text.Json.Nodes.JsonObject]) { continue }
                    $level = ConvertTo-AzlSonarNodeText $l['level']
                    if ($logCounts.ContainsKey($level)) { $logCounts[$level]++ }
                    if ($level -in 'warning', 'error' -and $logLines.Count -lt $MaxLogLines) {
                        $logLines.Add([ordered]@{ time = ConvertTo-AzlSonarNodeText $l['time']; level = $level; file = ConvertTo-AzlSonarNodeText $l['file']; text = ConvertTo-AzlSonarNodeText $l['text'] })
                    }
                }
            }
        }
    }
    if ($phases.Count -gt 0) { $phases[$phases.Count - 1].end = $rec.End }
    $phaseRows = @(foreach ($p in $phases) {
            [ordered]@{
                phase           = $p.phase
                activePhase     = $p.activePhase
                start           = $p.start.ToString($iso, $culture)
                end             = $p.end.ToString($iso, $culture)
                durationSeconds = [long][Math]::Max(0, ($p.end - $p.start).TotalSeconds)
            }
        })

    $steps = [System.Collections.Generic.List[object]]::new()
    $summary = [ordered]@{}
    if ($state -is [System.Text.Json.Nodes.JsonObject]) {
        foreach ($section in 'validation', 'deployment', 'update') {
            $sec = $state[$section]
            if ($sec -is [System.Text.Json.Nodes.JsonObject]) {
                foreach ($row in (Get-AzlSonarBundleStep -Tree $sec['tree'] -Section $section)) { $steps.Add($row) }
                $summary[$section] = ConvertTo-AzlSonarNodeText $sec['status']
            }
        }
        foreach ($k in 'cluster', 'mode', 'provisioningState', 'phase', 'activePhase', 'polledAt') { $summary[$k] = ConvertTo-AzlSonarNodeText $state[$k] }
    }
    $errorRows = @($steps | Where-Object { $_.errors.Count -gt 0 -or $_.status -eq 'error' })

    $timeline = [ordered]@{
        tool          = 'AzL Sonar'
        version       = [string]$MyInvocation.MyCommand.Module.Version
        kind          = 'timeline'
        generatedAt   = [datetime]::UtcNow.ToString($iso, $culture)
        source        = [ordered]@{ file = $rec.Name; sessions = @($rec.Sessions).Count; recordedFrom = $rec.Start.ToString($iso, $culture); recordedTo = $rec.End.ToString($iso, $culture); invalidLines = $rec.Invalid }
        cluster       = $rec.Cluster
        summary       = $summary
        phases        = $phaseRows
        steps         = $steps.ToArray()
        errors        = $errorRows
        logCounts     = $logCounts
        logLines      = $logLines.ToArray()
        notes         = @('Built from a recording; identifiers are as recorded unless it was made with -Publishable.', 'Tracks built from the Learn REST reference only (update, add-node, repair) are unverified against a live run.')
    }
    $timelinePath = Join-Path -Path $out -ChildPath "$Name-timeline.json"
    [System.IO.File]::WriteAllText($timelinePath, (ConvertTo-AzlSonarJson $timeline), [System.Text.UTF8Encoding]::new($false))

    # The report: plain HTML, inline CSS, no script and nothing fetched.
    $h = [System.Text.StringBuilder]::new()
    $enc = { param($v) ConvertTo-AzlSonarHtmlText $v }
    $null = $h.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer">')
    $null = $h.Append('<title>AzL Sonar report - ').Append((& $enc $rec.Cluster)).Append('</title><style>')
    $null = $h.Append(':root{color-scheme:light dark;--bg:#fff;--fg:#1b1f24;--muted:#59636f;--line:#dde2e9;--ok:#1a7f37;--err:#cf222e;--run:#0a5cc7;--bar:#cfe0fa}@media (prefers-color-scheme:dark){:root{--bg:#0f141a;--fg:#e6e9ee;--muted:#9aa5b1;--line:#2b333d;--ok:#3fb950;--err:#ff7b72;--run:#58a6ff;--bar:#1f3a5f}}')
    $null = $h.Append('body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,Segoe UI,sans-serif}main{max-width:1100px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 8px}p.m{color:var(--muted);margin:2px 0}')
    $null = $h.Append('table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid var(--line);padding:5px 8px;text-align:left;vertical-align:top}th{color:var(--muted);font-weight:600;font-size:12px}td.n{font-variant-numeric:tabular-nums;white-space:nowrap}')
    $null = $h.Append('.s-success{color:var(--ok)}.s-error{color:var(--err);font-weight:600}.s-running{color:var(--run)}.bar{display:inline-block;height:8px;background:var(--bar);border-radius:3px;vertical-align:middle}pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:0;font:12px/1.4 ui-monospace,Consolas,monospace}.note{border-left:3px solid var(--line);padding:4px 10px;color:var(--muted);margin:8px 0}')
    $null = $h.Append('</style></head><body><main>')
    $null = $h.Append('<h1>AzL Sonar report: ').Append((& $enc $rec.Cluster)).Append('</h1>')
    $null = $h.Append('<p class="m">Recording ').Append((& $enc $rec.Name)).Append(' &middot; ').Append((& $enc $rec.Start.ToString($iso, $culture))).Append(' to ').Append((& $enc $rec.End.ToString($iso, $culture))).Append(' &middot; ').Append(@($rec.Sessions).Count).Append(' session(s)</p>')
    if ($summary.Contains('phase')) {
        $null = $h.Append('<p class="m">Phase ').Append((& $enc $summary['phase'])).Append(' &middot; mode ').Append((& $enc $summary['mode'])).Append(' &middot; ARM ').Append((& $enc $summary['provisioningState'])).Append('</p>')
    }
    $null = $h.Append('<div class="note">Made from a recording. Identifiers are as recorded unless the recording was made with -Publishable. Update, add node and repair tracks are built from the Microsoft Learn REST reference and are unverified against a live run.</div>')

    $null = $h.Append('<h2>Phases</h2><table><thead><tr><th>Phase</th><th>Start (UTC)</th><th>End (UTC)</th><th>Duration</th></tr></thead><tbody>')
    foreach ($p in $phaseRows) {
        $null = $h.Append('<tr><td>').Append((& $enc $(if ($p.activePhase -and $p.activePhase -ne $p.phase) { "$($p.phase) ($($p.activePhase))" } else { $p.phase }))).Append('</td><td class="n">').Append((& $enc $p.start)).Append('</td><td class="n">').Append((& $enc $p.end)).Append('</td><td class="n">').Append((& $enc (Format-AzlSonarBundleDuration $p.durationSeconds))).Append('</td></tr>')
    }
    $null = $h.Append('</tbody></table>')

    $maxDuration = 1.0
    foreach ($row in $steps) { if ($null -ne $row.durationSeconds -and $row.durationSeconds -gt $maxDuration) { $maxDuration = [double]$row.durationSeconds } }
    foreach ($section in 'validation', 'deployment', 'update') {
        $rows = @($steps | Where-Object { $_.section -eq $section })
        if ($rows.Count -eq 0) { continue }
        $title = switch ($section) { 'validation' { 'Validation steps' } 'deployment' { 'Deployment steps' } default { 'Update steps (unverified against a live run)' } }
        $null = $h.Append('<h2>').Append($title).Append('</h2><table><thead><tr><th>Step</th><th>Status</th><th>Start (UTC)</th><th>Duration</th><th></th></tr></thead><tbody>')
        foreach ($row in $rows) {
            $width = if ($null -ne $row.durationSeconds) { [int][Math]::Round(180 * [double]$row.durationSeconds / $maxDuration) } else { 0 }
            $null = $h.Append('<tr><td style="padding-left:').Append(8 + 18 * [int]$row.depth).Append('px">').Append((& $enc $row.name)).Append('</td><td class="s-').Append((& $enc $row.status)).Append('">').Append((& $enc $row.status)).Append('</td><td class="n">').Append((& $enc $row.start)).Append('</td><td class="n">').Append((& $enc (Format-AzlSonarBundleDuration $row.durationSeconds))).Append('</td><td><span class="bar" style="width:').Append($width).Append('px"></span></td></tr>')
        }
        $null = $h.Append('</tbody></table>')
    }

    $null = $h.Append('<h2>Errors</h2>')
    if ($errorRows.Count -eq 0) { $null = $h.Append('<p class="m">No step reported an error.</p>') }
    else {
        $null = $h.Append('<table><thead><tr><th>Step</th><th>Error</th></tr></thead><tbody>')
        foreach ($row in $errorRows) {
            $null = $h.Append('<tr><td>').Append((& $enc $row.path)).Append('</td><td><pre>').Append((& $enc (@($row.errors) -join "`n"))).Append('</pre></td></tr>')
        }
        $null = $h.Append('</tbody></table>')
    }

    $null = $h.Append('<h2>Warning and error log lines</h2><p class="m">').Append($logCounts['info']).Append(' info, ').Append($logCounts['warning']).Append(' warning and ').Append($logCounts['error']).Append(' error line(s) in the run; the first ').Append($logLines.Count).Append(' warning or error line(s) are listed.</p>')
    if ($logLines.Count -gt 0) {
        $null = $h.Append('<table><thead><tr><th>Time</th><th>Level</th><th>File</th><th>Text</th></tr></thead><tbody>')
        foreach ($l in $logLines) {
            $null = $h.Append('<tr><td class="n">').Append((& $enc $l.time)).Append('</td><td class="s-').Append($(if ($l.level -eq 'error') { 'error' } else { 'running' })).Append('">').Append((& $enc $l.level)).Append('</td><td>').Append((& $enc ([System.IO.Path]::GetFileName($l.file.Replace('\', '/'))))).Append('</td><td><pre>').Append((& $enc $l.text)).Append('</pre></td></tr>')
        }
        $null = $h.Append('</tbody></table>')
    }
    $null = $h.Append('</main></body></html>')
    $reportPath = Join-Path -Path $out -ChildPath "$Name-report.html"
    [System.IO.File]::WriteAllText($reportPath, $h.ToString(), [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Timeline = $timelinePath
        Report   = $reportPath
        Phases   = $phaseRows.Count
        Steps    = $steps.Count
        Errors   = $errorRows.Count
        LogLines = $logLines.Count
    }
}
