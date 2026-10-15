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
        }
        catch { Write-Verbose "ZTP event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}
