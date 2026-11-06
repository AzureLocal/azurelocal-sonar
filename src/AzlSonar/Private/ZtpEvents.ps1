Set-StrictMode -Version Latest

# ZTP provisioning events (azurelocal-ztp): the machines are provisioned before the deployment exists, and the
# provisioning scripts write one JSON object per line to an event file: { timestamp, node, state, evidence, nextAction,
# level, stage }. Sonar follows that file (local, read-only) and shows each event in the log pane, so the ZTP stages
# (Mounted, Booting, MaintenanceEnvironmentRunning, VoucherWritten, ReadyForPortal, and the failure states) sit next to the
# edge machine progress it already reads from Azure.

function ConvertFrom-AzlSonarZtpEvent {
    <#
    .SYNOPSIS
        One event line of the ZTP event file as a log line { file, text }, or $null when the line is not an event.
    .DESCRIPTION
        The text starts with the event's own UTC timestamp, so the log pane orders it by event time, and ends with the
        level word (error, warning) the pane colours by. Lines that are not JSON objects with node and state are skipped
        (a half-written line is retried by the reader on the next poll).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try { $entry = ConvertFrom-Json -InputObject $Line -Depth 8 } catch { return $null }
    if ($entry -isnot [pscustomobject]) { return $null }
    $node = [string](Get-AzlSonarMember $entry 'node' '')
    $state = [string](Get-AzlSonarMember $entry 'state' '')
    if (-not $node -or -not $state) { return $null }
    $stamp = [string](Get-AzlSonarMember $entry 'timestamp' '')
    $parsed = [datetime]::MinValue
    $prefix = if ($stamp -and [datetime]::TryParse($stamp, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        $parsed.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) + ' '
    }
    else { '' }
    $level = ([string](Get-AzlSonarMember $entry 'level' 'Info')).ToLowerInvariant()
    $evidence = [string](Get-AzlSonarMember $entry 'evidence' '')
    $next = [string](Get-AzlSonarMember $entry 'nextAction' '')
    $text = "${prefix}[ztp] $node $state"
    if ($evidence) { $text += ": $evidence" }
    if ($next) { $text += " -> next: $next" }
    # Failure states carry the word the log pane colours by even when the evidence text has none.
    if ($level -eq 'error' -and $text -notmatch '(?i)\b(error|failed|fatal|exception)\b') { $text += ' (error)' }
    elseif ($level -eq 'warning' -and $text -notmatch '(?i)\bwarn(ing)?\b') { $text += ' (warning)' }
    return @{ file = 'ztp-events'; text = $text }
}

function Read-AzlSonarZtpEventChunk {
    <#
    .SYNOPSIS
        Reads the complete lines of the event file after -Offset (bytes). Returns { Lines, Offset }.
    .DESCRIPTION
        The file is opened with FileShare ReadWrite (the writer keeps appending). A partial last line is left for the next
        poll; a file that got smaller (replaced or truncated) is read again from the start. A missing file returns no lines.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [long]$Offset = 0
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Lines = @(); Offset = 0 } }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        if ($Offset -gt $stream.Length) { $Offset = 0 }
        $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new([int][math]::Min($stream.Length - $Offset, 4MB))
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally { $stream.Dispose() }
    $lastNewline = [array]::LastIndexOf($buffer, [byte]10, [math]::Max(0, $read - 1))
    if ($read -le 0 -or $lastNewline -lt 0) { return @{ Lines = @(); Offset = $Offset } }
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $lastNewline + 1)
    return @{ Lines = @($text -split "`r?`n" | Where-Object { $_ }); Offset = $Offset + $lastNewline + 1 }
}

function Invoke-AzlSonarZtpEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the ZTP event file and adds each event to the log pane until the stop flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [object]$Config,

        [double]$PollSeconds = 2
    )

    $path = [string](Get-AzlSonarMember $Config 'ztpEventsPath' '')
    if (-not $path) { return }
    $offset = [long]0
    while (-not $Shared.Stop) {
        try {
            $chunk = Read-AzlSonarZtpEventChunk -Path $path -Offset $offset
            $offset = [long]$chunk.Offset
            $lines = foreach ($raw in $chunk.Lines) { ConvertFrom-AzlSonarZtpEvent -Line $raw }
            if (@($lines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($lines) }
            if ($Shared.Contains('ZtpPrepare')) { foreach ($raw in $chunk.Lines) { Add-AzlSonarZtpPrepareEvent -Store $Shared['ZtpPrepare'] -Line $raw } }
        }
        catch { Write-Verbose "ZTP event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

function Add-AzlSonarZtpPrepareEvent {
    <#
    .SYNOPSIS
        Records one ZTP event line in the per-node Prepare store when it belongs to the Prepare stage.
    .DESCRIPTION
        azurelocal-ztp's Prepare stage (Initialize-ZtpNode.ps1) writes one event per gate with stage 'Prepare':
        PrepareStarted, PrepareDriversInstalled, PrepareRestarting, PrepareRestarted, then ReadyForValidate or
        PrepareFailed. The store maps node name to the events of its latest attempt: PrepareStarted begins a new list,
        so a rerun replaces the earlier attempt. Other stages and malformed lines are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Store,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $entry = ConvertFrom-Json -InputObject $Line -Depth 8 } catch { return }
    if ($entry -isnot [pscustomobject]) { return }
    if ([string](Get-AzlSonarMember $entry 'stage' '') -ne 'Prepare') { return }
    $node = [string](Get-AzlSonarMember $entry 'node' '')
    $state = [string](Get-AzlSonarMember $entry 'state' '')
    if (-not $node -or $node -eq '*' -or -not $state) { return }
    $record = [ordered]@{
        state     = $state
        timestamp = [string](Get-AzlSonarMember $entry 'timestamp' '')
        evidence  = [string](Get-AzlSonarMember $entry 'evidence' '')
        level     = [string](Get-AzlSonarMember $entry 'level' 'Info')
    }
    # Direct assignment: an if-expression would unroll the stored list.
    $list = $null
    if ($Store.Contains($node)) { $list = $Store[$node] }
    if ($null -eq $list -or $state -eq 'PrepareStarted') { $list = [System.Collections.ArrayList]::new() }
    $null = $list.Add($record)
    $Store[$node] = $list
}

function ConvertTo-AzlSonarPrepareStage {
    <#
    .SYNOPSIS
        The 'Prepare for Validate' step for one node, from its Prepare events: { node (step tree node), status, state, message }.
    .DESCRIPTION
        status is success after ReadyForValidate, error after PrepareFailed, running while events arrive, notstarted with
        none. Each event becomes a child step; the last one runs until the next event or the end.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Events = @(),

        [datetime]$Now = [datetime]::UtcNow
    )

    $labels = @{
        PrepareStarted          = 'Azure reports Ready to cluster; signed in to the node'
        PrepareDriversInstalled = 'OEM network drivers and network settings applied'
        PrepareRestarting       = 'Restarting for the drivers'
        PrepareRestarted        = 'Back with a new boot time'
        ReadyForValidate        = 'All checks passed: ready for Validate'
        PrepareFailed           = 'Prepare failed'
    }
    $list = @($Events | Where-Object { $null -ne $_ })
    $last = if ($list.Count) { $list[-1] } else { $null }
    $lastState = if ($null -ne $last) { [string]$last['state'] } else { '' }
    $status = if ($null -eq $last) { 'NotStarted' } elseif ($lastState -eq 'ReadyForValidate') { 'Success' } elseif ($lastState -eq 'PrepareFailed') { 'Failed' } else { 'InProgress' }
    $steps = for ($i = 0; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        $state = [string]$e['state']
        $stepStatus = if ($state -eq 'PrepareFailed') { 'Failed' } elseif ($i -eq $list.Count - 1 -and $status -eq 'InProgress') { 'InProgress' } else { 'Success' }
        $end = if ($i + 1 -lt $list.Count) { $list[$i + 1]['timestamp'] } elseif ($stepStatus -ne 'InProgress') { $e['timestamp'] } else { $null }
        $label = if ($labels.ContainsKey($state)) { $labels[$state] } else { $state }
        [pscustomobject]@{
            name          = $state
            description   = $(if ($e['evidence'] -and $state -ne 'PrepareFailed') { "${label}: $($e['evidence'])" } else { $label })
            fullStepIndex = "prepare.$i"
            startTimeUtc  = $e['timestamp']
            endTimeUtc    = $end
            status        = $stepStatus
            exception     = @($(if ($state -eq 'PrepareFailed') { [string]$e['evidence'] }) | Where-Object { $_ })
        }
    }
    $raw = [pscustomobject]@{
        name          = 'Prepare for Validate'
        description   = 'azurelocal-ztp Prepare: OEM network drivers, static management address, one default gateway, DNS, time, C:\SBE'
        fullStepIndex = 'prepare'
        startTimeUtc  = $(if ($list.Count) { $list[0]['timestamp'] } else { $null })
        endTimeUtc    = $(if ($status -in 'Success', 'Failed') { $last['timestamp'] } else { $null })
        status        = $status
        exception     = @($(if ($status -eq 'Failed') { [string]$last['evidence'] }) | Where-Object { $_ })
        steps         = @($steps)
    }
    $node = @(ConvertTo-AzlSonarStepTree -StatusObject @($raw) -Now $Now)[0]
    return [ordered]@{
        node    = $node
        status  = [string]$node['status']
        state   = $lastState
        message = $(if ($null -ne $last -and $last['evidence']) { [string]$last['evidence'] } elseif ($null -ne $last) { $lastState } else { 'Waiting for the Prepare stage' })
    }
}