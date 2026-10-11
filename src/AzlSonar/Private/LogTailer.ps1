Set-StrictMode -Version Latest

# Tailer limits (not environment values).
$script:AzlSonarTail = @{
    MaxFiles           = 300          # newest files considered per poll
    MaxBytesPerFile    = 1048576      # bytes read from one file per poll
    InitialTailBytes   = 16384        # files already present when Sonar starts begin this far from their end
    RetrySeconds       = 60           # wait before reconnecting after a failure
    SessionOpenMs      = 30000
    SessionOperationMs = 180000
    DiscoverEveryPolls = 3            # list the log folders (Get-ChildItem) on every 3rd poll ...
    DiscoverMaxSeconds = 60           # ... or when 60 s have passed since the last listing; known files are tailed in between
    MaxStateEntries    = 2000         # tracked files (offsets); the least recently written are evicted beyond this
    HeadBytes          = 64           # first bytes kept per file to recognise it after a rename or a re-creation
}

# Leading timestamps in node log lines (see Get-AzlSonarLogEventTime).
$script:AzlSonarLineTimeRegex = [regex]::new(
    '^[\s\uFEFF]*[\[(]?\s*(?:' +
    '(?<y>\d{4})-(?<mo>\d{2})-(?<d>\d{2})[T ](?<h>\d{2}):(?<mi>\d{2}):(?<s>\d{2})(?:[.,](?<f>\d{1,7}))?(?<z>Z|[+-]\d{2}:?\d{2})?' +
    '|(?<mo>\d{1,2})/(?<d>\d{1,2})/(?<y>\d{4})[ T]+(?<h>\d{1,2}):(?<mi>\d{2}):(?<s>\d{2})(?:[.,](?<f>\d{1,7}))?(?:\s?(?<ap>[AP]M))?' +
    '|Start time:\s*(?<y>\d{4})(?<mo>\d{2})(?<d>\d{2})(?<h>\d{2})(?<mi>\d{2})(?<s>\d{2})' +
    ')(?!\d)',
    [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
# Timestamps in Azure Local log file names: Name_20261010-161642.log, Name_20261010-234335Z.log, transcript.20261010161642.txt
$script:AzlSonarFileTimeRegex = [regex]::new(
    '(?<!\d)(?<y>20\d{2})(?<mo>\d{2})(?<d>\d{2})[-_.]?(?<h>\d{2})(?<mi>\d{2})(?<s>\d{2})(?<z>Z)?(?!\d)',
    [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
# Zero-count summaries that are not problems: 'error=0', 'Failed: 0', 'warning count=0', 'errors: 0', '0 failed'.
$script:AzlSonarZeroCountRegex = @(
    [regex]::new('\b(?:errors?|exceptions?|failed|failures?|fatal|warnings?|warn)(?:\s+count)?\s*[:=]\s*0+(?![\w]|[.,]\d)', 'IgnoreCase, CultureInvariant'),
    [regex]::new('(?<![\w.,])0+\s+(?:errors?|exceptions?|failed|failures?|fatal|warnings?)\b', 'IgnoreCase, CultureInvariant')
)

#region Pure helpers. These are also embedded in the remote script, so they must run on Windows PowerShell 5.1.

function Get-AzlSonarBomEncoding {
    <#
    .SYNOPSIS
        Detects a log file's encoding from its first bytes: utf8 (default), unicode (UTF-16LE) or bigendianunicode.
    .OUTPUTS
        Hashtable { Name; BomLength }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $n = $Bytes.Length
    if ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return @{ Name = 'utf8'; BomLength = 3 } }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return @{ Name = 'unicode'; BomLength = 2 } }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return @{ Name = 'bigendianunicode'; BomLength = 2 } }
    if ($n -ge 4 -and $Bytes[0] -ne 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -ne 0 -and $Bytes[3] -eq 0) { return @{ Name = 'unicode'; BomLength = 0 } }
    return @{ Name = 'utf8'; BomLength = 0 }
}

function Test-AzlSonarNameMatch {
    <#
    .SYNOPSIS
        True when a file name matches one of the include patterns and none of the exclude patterns.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Include,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Exclude
    )

    if ($null -ne $Exclude) {
        foreach ($pattern in $Exclude) {
            if ($pattern -and $Name -like $pattern) { return $false }
        }
    }
    if ($null -eq $Include -or $Include.Length -eq 0) { return $true }
    foreach ($pattern in $Include) {
        if ($pattern -and $Name -like $pattern) { return $true }
    }
    return $false
}

function Resolve-AzlSonarTailOffset {
    <#
    .SYNOPSIS
        Decides where to read a log file from: continue, start of a new file, or reset after rotation/truncation.
    .DESCRIPTION
        No previous entry: offset 0 (a file that appears while Sonar runs is read from the start); when -StartAtEnd
        (the file existed when Sonar started) the read starts InitialTailBytes before the end and the first partial
        line is skipped. Previous entry: when the file was re-created (creation time changed) or truncated
        (size < offset) the offset resets to 0; otherwise reading continues from the stored offset.
    .OUTPUTS
        Hashtable { Offset; SkipPartialLine; Reset; Reason (new|initial-tail|continue|recreated|truncated) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Previous,

        [long]$Size,

        [long]$CreatedTicks,

        [bool]$StartAtEnd,

        [long]$InitialTailBytes
    )

    if ($null -eq $Previous) {
        if ($StartAtEnd) {
            $tail = [Math]::Max([long]0, $InitialTailBytes)
            $offset = [Math]::Max([long]0, $Size - $tail)
            return @{ Offset = [long]$offset; SkipPartialLine = ($offset -gt 0); Reset = $false; Reason = 'initial-tail' }
        }
        return @{ Offset = [long]0; SkipPartialLine = $false; Reset = $false; Reason = 'new' }
    }

    $previousOffset = [long]0
    if ($Previous.Contains('offset') -and $null -ne $Previous['offset']) { $previousOffset = [long]$Previous['offset'] }
    $previousCreated = [long]0
    if ($Previous.Contains('created') -and $null -ne $Previous['created']) { $previousCreated = [long]$Previous['created'] }
    $previousSkip = $false
    if ($Previous.Contains('skip') -and $null -ne $Previous['skip']) { $previousSkip = [bool]$Previous['skip'] }

    if ($previousCreated -ne 0 -and $CreatedTicks -ne 0 -and $previousCreated -ne $CreatedTicks) {
        return @{ Offset = [long]0; SkipPartialLine = $false; Reset = $true; Reason = 'recreated' }
    }
    if ($Size -lt $previousOffset) {
        return @{ Offset = [long]0; SkipPartialLine = $false; Reset = $true; Reason = 'truncated' }
    }
    return @{ Offset = $previousOffset; SkipPartialLine = $previousSkip; Reset = $false; Reason = 'continue' }
}

function Split-AzlSonarLogChunk {
    <#
    .SYNOPSIS
        Splits a chunk of log bytes into complete lines and reports how many bytes were consumed.
    .DESCRIPTION
        Works on bytes, so offsets stay exact whatever the content: only complete lines (ending in LF) are consumed;
        an incomplete last line is left for the next poll. CR before LF is removed; blank lines are dropped but
        their bytes are consumed. With -SkipPartialLine the bytes up to the first LF are consumed without output
        (the read started mid-line). When a full chunk holds no LF at all, the whole chunk is consumed as one line
        so a huge line cannot stall the tailer.
    .OUTPUTS
        PSCustomObject { Lines (string[]); ConsumedBytes (long); SkippedPartial (bool) }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [int]$Count = -1,

        [ValidateSet('utf8', 'unicode', 'bigendianunicode')]
        [string]$Encoding = 'utf8',

        [int]$MaxLines = [int]::MaxValue,

        [bool]$SkipPartialLine = $false,

        [bool]$ChunkIsFull = $false
    )

    if ($Count -lt 0 -or $Count -gt $Bytes.Length) { $Count = $Bytes.Length }
    $textEncoding = [System.Text.Encoding]::UTF8
    if ($Encoding -eq 'unicode') { $textEncoding = [System.Text.Encoding]::Unicode }
    elseif ($Encoding -eq 'bigendianunicode') { $textEncoding = [System.Text.Encoding]::BigEndianUnicode }
    $newlineLength = 1
    if ($Encoding -ne 'utf8') { $newlineLength = 2 }

    # Returns the index where the newline sequence starts, or -1.
    $findNewline = {
        param([int]$From)
        $search = $From
        while ($search -lt $Count) {
            $index = [Array]::IndexOf($Bytes, [byte]10, $search, $Count - $search)
            if ($index -lt 0) { return -1 }
            if ($Encoding -eq 'utf8') { return $index }
            if ($Encoding -eq 'unicode') {
                if (($index % 2) -eq 0 -and ($index + 1) -lt $Count -and $Bytes[$index + 1] -eq 0) { return $index }
            }
            else {
                if (($index % 2) -eq 1 -and $Bytes[$index - 1] -eq 0) { return ($index - 1) }
            }
            $search = $index + 1
        }
        return -1
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $position = 0
    $skipped = $false

    if ($SkipPartialLine) {
        $first = & $findNewline 0
        if ($first -lt 0) {
            if ($ChunkIsFull) {
                return [pscustomobject]@{ Lines = [string[]]@(); ConsumedBytes = [long]$Count; SkippedPartial = $false }
            }
            return [pscustomobject]@{ Lines = [string[]]@(); ConsumedBytes = [long]0; SkippedPartial = $false }
        }
        $position = $first + $newlineLength
        $skipped = $true
    }

    while ($lines.Count -lt $MaxLines -and $position -lt $Count) {
        $newline = & $findNewline $position
        if ($newline -lt 0) {
            if ($ChunkIsFull -and $position -eq 0) {
                $lines.Add($textEncoding.GetString($Bytes, 0, $Count).TrimEnd("`r", "`n"))
                $position = $Count
            }
            break
        }
        $text = $textEncoding.GetString($Bytes, $position, $newline - $position).TrimEnd("`r")
        if (-not [string]::IsNullOrWhiteSpace($text)) { $lines.Add($text) }
        $position = $newline + $newlineLength
    }

    return [pscustomobject]@{ Lines = [string[]]$lines.ToArray(); ConsumedBytes = [long]$position; SkippedPartial = $skipped }
}

function Test-AzlSonarBytePrefix {
    <#
    .SYNOPSIS
        True when -Actual starts with all of -Expected (the remembered first bytes of a log file). Empty -Expected is
        never a match: an unknown head proves nothing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [byte[]]$Expected,

        [AllowNull()]
        [AllowEmptyCollection()]
        [byte[]]$Actual
    )

    if ($null -eq $Expected -or $Expected.Length -eq 0 -or $null -eq $Actual -or $Actual.Length -lt $Expected.Length) { return $false }
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Expected[$i] -ne $Actual[$i]) { return $false }
    }
    return $true
}

function Read-AzlSonarFileHead {
    <#
    .SYNOPSIS
        Reads up to -Count bytes from the start of a file with shared read (never blocks the writer); empty on error.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Count = 64
    )

    $stream = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $want = [int][Math]::Min([long]$Count, [long]$stream.Length)
        $buffer = New-Object byte[] $want
        $read = 0
        while ($read -lt $want) {
            $got = $stream.Read($buffer, $read, $want - $read)
            if ($got -le 0) { break }
            $read += $got
        }
        if ($read -lt $want) {
            $short = New-Object byte[] $read
            [Array]::Copy($buffer, $short, $read)
            return , $short
        }
        return , $buffer
    }
    catch {
        return , (New-Object byte[] 0)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

#endregion

function Get-AzlSonarNodeTime {
    <#
    .SYNOPSIS
        Builds a UTC time from date parts. -Zone 'Z' or '+hh:mm'/'-hhmm' is explicit; no zone means node-local time,
        converted with -UtcOffsetMinutes (no offset known: $null, because the time cannot be placed).
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [int]$Year, [int]$Month, [int]$Day, [int]$Hour, [int]$Minute, [int]$Second,

        [AllowEmptyString()]
        [string]$Fraction = '',

        [AllowEmptyString()]
        [string]$Zone = '',

        [AllowNull()]
        [Nullable[int]]$UtcOffsetMinutes
    )

    if ($Year -lt 2000 -or $Year -gt 2100) { return $null }
    try {
        $value = [datetime]::new($Year, $Month, $Day, $Hour, $Minute, $Second, [System.DateTimeKind]::Unspecified)
    }
    catch {
        return $null
    }
    if ($Fraction) { $value = $value.AddTicks([long]$Fraction.PadRight(7, '0').Substring(0, 7)) }
    if ($Zone -eq 'Z' -or $Zone -eq 'z') { return [datetime]::SpecifyKind($value, [System.DateTimeKind]::Utc) }
    if ($Zone) {
        $digits = $Zone.Substring(1).Replace(':', '')
        $offsetMinutes = [int]$digits.Substring(0, 2) * 60 + [int]$digits.Substring(2, 2)
        if ($offsetMinutes -gt 14 * 60) { return $null }
        if ($Zone[0] -eq '-') { $offsetMinutes = -$offsetMinutes }
        return [datetime]::SpecifyKind($value.AddMinutes(-$offsetMinutes), [System.DateTimeKind]::Utc)
    }
    if ($null -eq $UtcOffsetMinutes) { return $null }
    return [datetime]::SpecifyKind($value.AddMinutes(-[int]$UtcOffsetMinutes), [System.DateTimeKind]::Utc)
}

function Get-AzlSonarLogEventTime {
    <#
    .SYNOPSIS
        Works out when a log line was written: from its leading timestamp, else from the file name, else the receive time.
    .DESCRIPTION
        Leading timestamps recognised (optional leading '[' or '('): ISO 8601 with or without fraction and Z/offset
        ('2026-10-10T16:16:42.123Z', '2026-10-10T16:16:42+02:00', '2026-10-10T16:16:42'), 'yyyy-MM-dd HH:mm:ss(.fff)'
        (also with a comma before the fraction), '[yyyy-MM-dd HH:mm:ss]', 'MM/dd/yyyy HH:mm:ss' (optionally h:mm:ss AM/PM)
        and the Windows PowerShell transcript header 'Start time: yyyyMMddHHmmss'. Fallback for lines without one: the
        timestamp in Azure Local log file names ('Name_20261010-161642.log', 'Name_20261010-234335Z.log',
        'PowerShell_transcript.NODE.x.20261010161642.txt'). Times without Z or an offset are node-local and are converted
        with the node's UTC offset; when it is unknown they are not used. A time more than a day after the receive time
        is ignored as garbage.
    .OUTPUTS
        Hashtable { Time (UTC DateTime); Source ('line' | 'file' | 'received') }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$File,

        [AllowNull()]
        [Nullable[int]]$UtcOffsetMinutes,

        [datetime]$Received = [datetime]::UtcNow
    )

    $receivedUtc = $Received.ToUniversalTime()
    $latest = $receivedUtc.AddDays(1)
    $fromMatch = {
        param([System.Text.RegularExpressions.Match]$Match, [Nullable[int]]$Offset)
        $g = $Match.Groups
        $hour = [int]$g['h'].Value
        if ($g['ap'].Success) {
            if ($hour -lt 1 -or $hour -gt 12) { return $null }
            if ($g['ap'].Value -match '^[Pp]') { if ($hour -ne 12) { $hour += 12 } } elseif ($hour -eq 12) { $hour = 0 }
        }
        $zone = if ($g['z'].Success) { $g['z'].Value } else { '' }
        $fraction = if ($g['f'].Success) { $g['f'].Value } else { '' }
        Get-AzlSonarNodeTime -Year ([int]$g['y'].Value) -Month ([int]$g['mo'].Value) -Day ([int]$g['d'].Value) -Hour $hour `
            -Minute ([int]$g['mi'].Value) -Second ([int]$g['s'].Value) -Fraction $fraction -Zone $zone -UtcOffsetMinutes $Offset
    }

    if (-not [string]::IsNullOrEmpty($Text)) {
        $match = $script:AzlSonarLineTimeRegex.Match($Text)
        if ($match.Success) {
            $time = & $fromMatch $match $UtcOffsetMinutes
            if ($null -ne $time -and $time -le $latest) { return @{ Time = $time; Source = 'line' } }
        }
    }
    if (-not [string]::IsNullOrEmpty($File)) {
        $name = ($File -split '[\\/]')[-1]
        $match = $script:AzlSonarFileTimeRegex.Match($name)
        if ($match.Success) {
            $time = & $fromMatch $match $UtcOffsetMinutes
            if ($null -ne $time -and $time -le $latest) { return @{ Time = $time; Source = 'file' } }
        }
    }
    return @{ Time = $receivedUtc; Source = 'received' }
}

function Get-AzlSonarLineLevel {
    <#
    .SYNOPSIS
        Classifies a log line: error, warning or info.
    .DESCRIPTION
        error: \b(error|exception|failed|fatal)\b; warning: \bwarn(ing)?\b; case-insensitive; else info.
        Zero-count summaries are removed first, so 'error=0', 'Failed: 0', '0 failed', 'warning count=0' and
        'errors: 0' do not make a line an error or a warning (another problem word in the same line still does).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return 'info' }
    $rest = $Text
    foreach ($zeroCount in $script:AzlSonarZeroCountRegex) { $rest = $zeroCount.Replace($rest, ' ') }
    if ($rest -match '(?i)\b(error|exception|failed|fatal)\b') { return 'error' }
    if ($rest -match '(?i)\bwarn(ing)?\b') { return 'warning' }
    return 'info'
}

function Get-AzlSonarRemoteTailScript {
    <#
    .SYNOPSIS
        Builds the read-only script the tailer runs on the seed node (one call per poll).
    .DESCRIPTION
        With -Discover (the caller asks for it on every DiscoverEveryPolls-th poll, or after DiscoverMaxSeconds) it
        lists the files under the log paths (recursing RecurseDepth levels; a path that does not exist yet is reported
        and checked again at the next listing) and keeps those written within ActiveWindowMinutes, newest first.
        Between listings it only re-checks the files that were active at the last listing (no Get-ChildItem), so a
        deep log tree is not enumerated every poll; a new file is picked up at the next listing.
        New bytes are read with FileShare ReadWrite (and Delete, so rotation is never blocked). Offsets travel with the
        call (FileState in, state out), so the node keeps nothing between polls; at most MaxStateEntries files are
        tracked (the least recently written are evicted first, active files never).
        Each tracked file remembers its first bytes (head). A known path whose head changed was re-created under the
        same name (NTFS tunnelling keeps the creation time for 15 s) and is read again from the start. A new path whose
        creation time and head match a file that just disappeared (or was just re-created) is the same file renamed by
        log rotation: its offset is carried over, so its lines are not sent twice (best effort, reported in 'renamed').
        Also reports the node's current UTC offset (utcOffsetMinutes) so node-local log timestamps can be converted.
        Runs on Windows PowerShell 5.1. It can also be invoked locally against a folder, which is how the offset and
        rotation logic is tested.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    $helperNames = 'Get-AzlSonarBomEncoding', 'Test-AzlSonarNameMatch', 'Resolve-AzlSonarTailOffset', 'Split-AzlSonarLogChunk',
    'Test-AzlSonarBytePrefix', 'Read-AzlSonarFileHead'
    $helpers = foreach ($name in $helperNames) {
        "function $name {`n$((Get-Command -Name $name -CommandType Function).ScriptBlock.ToString())`n}"
    }

    $head = @'
param(
    [string[]]$Paths,
    [string[]]$Include,
    [string[]]$Exclude,
    [int]$RecurseDepth,
    [int]$ActiveWindowMinutes,
    [hashtable]$FileState,
    [int]$MaxLines,
    [bool]$FirstRun,
    [int]$MaxFiles,
    [int]$MaxBytesPerFile,
    [long]$InitialTailBytes,
    [bool]$Discover = $true,
    [int]$MaxStateEntries = 2000,
    [int]$HeadBytes = 64
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
'@

    $body = @'
if ($null -eq $FileState) { $FileState = @{} }
if ($MaxStateEntries -le 0) { $MaxStateEntries = 2000 }
if ($HeadBytes -le 0) { $HeadBytes = 64 }
$windowStart = [datetime]::UtcNow.AddMinutes(-1 * $ActiveWindowMinutes)
$missing = New-Object System.Collections.Generic.List[string]
$errors = New-Object System.Collections.Generic.List[string]
$renamed = New-Object System.Collections.Generic.List[object]
$seen = @{}       # path -> FileInfo, for files present now
$vanished = @{}   # path -> previous state, for tracked files no longer on disk
$found = New-Object System.Collections.Generic.List[object]
$isActive = {
    param($Entry)
    ($null -ne $Entry -and $Entry -is [System.Collections.IDictionary] -and $Entry.Contains('active') -and [bool]$Entry['active'])
}

if ($Discover) {
    foreach ($root in $Paths) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { $missing.Add($root); continue }
        $items = @(Get-ChildItem -LiteralPath $root -Recurse -Depth $RecurseDepth -File -Force -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            if (-not (Test-AzlSonarNameMatch -Name $item.Name -Include $Include -Exclude $Exclude)) { continue }
            # NTFS does not update a directory entry's size and write time while a writer holds the file open: re-read them.
            try { $item.Refresh() } catch { }
            $seen[$item.FullName] = $item
            if ($item.LastWriteTimeUtc -ge $windowStart) { $found.Add($item) }
        }
    }
    foreach ($key in @($FileState.Keys)) {
        if (-not $seen.ContainsKey($key)) { $vanished[$key] = $FileState[$key] }
    }
}
else {
    # No listing this poll: re-check only the files that were active at the last one.
    foreach ($key in @($FileState.Keys)) {
        if (-not (& $isActive $FileState[$key])) { continue }
        $info = New-Object System.IO.FileInfo -ArgumentList $key
        try { $info.Refresh() } catch { }
        if ($info.Exists) { $seen[$key] = $info; $found.Add($info) }
        else { $vanished[$key] = $FileState[$key] }
    }
}
$active = @($found | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First $MaxFiles)
$activeSet = @{}
foreach ($item in $active) { $activeSet[$item.FullName] = $true }

$newState = @{}
# Files still tracked but outside the active window keep their offset so they continue, not restart, if written again.
foreach ($key in @($FileState.Keys)) {
    if ($activeSet.ContainsKey($key) -or $vanished.ContainsKey($key)) { continue }
    if ($Discover -and -not $seen.ContainsKey($key)) { continue }
    $entry = $FileState[$key]
    if ($null -eq $entry -or -not ($entry -is [System.Collections.IDictionary])) { continue }
    $copy = @{}
    foreach ($field in @($entry.Keys)) { $copy[$field] = $entry[$field] }
    $copy['active'] = $false
    if ($seen.ContainsKey($key)) { $copy['lastWrite'] = [long]$seen[$key].LastWriteTimeUtc.Ticks }
    $newState[$key] = $copy
}

# Identities that just left a path (gone, or replaced by a new file): a new path may be one of them, renamed.
$pool = @{}
if ($Discover) { foreach ($key in @($vanished.Keys)) { $pool[$key] = $vanished[$key] } }

# Known paths first, so an identity replaced under its old name is in the pool before the new names are matched.
$ordered = @(@($active | Where-Object { $FileState.ContainsKey($_.FullName) }) + @($active | Where-Object { -not $FileState.ContainsKey($_.FullName) }))

$budget = $MaxLines
$outLines = New-Object System.Collections.Generic.List[object]
$outFiles = New-Object System.Collections.Generic.List[object]
foreach ($item in $ordered) {
    $path = $item.FullName
    $size = [long]$item.Length
    $created = [long]$item.CreationTimeUtc.Ticks
    $previous = $null
    if ($FileState.ContainsKey($path)) {
        $previous = $FileState[$path]
    }
    elseif ($pool.Count -gt 0 -and $created -ne 0) {
        foreach ($key in @($pool.Keys)) {
            $candidate = $pool[$key]
            if ($null -eq $candidate -or -not ($candidate -is [System.Collections.IDictionary])) { continue }
            if (-not $candidate.Contains('created') -or [long]$candidate['created'] -ne $created) { continue }
            if (-not $candidate.Contains('head') -or -not $candidate['head']) { continue }
            $expected = [Convert]::FromBase64String([string]$candidate['head'])
            if ($size -lt $expected.Length) { continue }
            $actual = Read-AzlSonarFileHead -Path $path -Count $expected.Length
            if (Test-AzlSonarBytePrefix -Expected $expected -Actual $actual) {
                $previous = $candidate
                $renamed.Add([pscustomobject]@{ from = ($key -replace '\|previous$', ''); to = $path; offset = [long]$candidate['offset'] })
                $pool.Remove($key)
                break
            }
        }
    }
    $plan = Resolve-AzlSonarTailOffset -Previous $previous -Size $size -CreatedTicks $created -StartAtEnd $FirstRun -InitialTailBytes $InitialTailBytes
    $offset = [long]$plan.Offset
    $skip = [bool]$plan.SkipPartialLine
    $encoding = $null
    $bomLength = 0
    $headText = ''
    if ($null -ne $previous -and $plan.Reset -and $FileState.ContainsKey($path)) { $pool[$path + '|previous'] = $previous }
    if ($null -ne $previous -and -not $plan.Reset) {
        if ($previous.Contains('encoding') -and $previous['encoding']) {
            $encoding = [string]$previous['encoding']
            if ($previous.Contains('bom') -and $null -ne $previous['bom']) { $bomLength = [int]$previous['bom'] }
        }
        if ($previous.Contains('head') -and $previous['head']) { $headText = [string]$previous['head'] }
    }
    if ($size -gt $offset -and $budget -gt 0) {
        $stream = $null
        try {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            if ([long]$stream.Length -gt $size) { $size = [long]$stream.Length }
            $headNow = New-Object byte[] ([int][Math]::Min([long]$HeadBytes, $size))
            $headRead = 0
            while ($headRead -lt $headNow.Length) {
                $got = $stream.Read($headNow, $headRead, $headNow.Length - $headRead)
                if ($got -le 0) { break }
                $headRead += $got
            }
            if ($headText) {
                $known = [Convert]::FromBase64String($headText)
                if (-not (Test-AzlSonarBytePrefix -Expected $known -Actual $headNow)) {
                    # Same name and creation time but other first bytes: re-created (NTFS tunnelling) or rewritten.
                    if ($null -ne $previous -and $FileState.ContainsKey($path)) { $pool[$path + '|previous'] = $previous }
                    $offset = [long]0; $skip = $false; $encoding = $null; $bomLength = 0; $headText = ''
                }
            }
            if (-not $headText -or [Convert]::FromBase64String($headText).Length -lt $headNow.Length) {
                $headText = [Convert]::ToBase64String($headNow)
            }
            if (-not $encoding) {
                $detected = Get-AzlSonarBomEncoding -Bytes $headNow
                $encoding = $detected.Name
                $bomLength = [int]$detected.BomLength
            }
            if ($offset -lt $bomLength) { $offset = [long]$bomLength }
            if ($encoding -ne 'utf8' -and ($offset % 2) -ne 0) { $offset = $offset + 1 }
            $want = [int][Math]::Min([long]$MaxBytesPerFile, $size - $offset)
            if ($want -gt 0) {
                $buffer = New-Object byte[] $want
                $stream.Position = $offset
                $read = 0
                while ($read -lt $want) {
                    $got = $stream.Read($buffer, $read, $want - $read)
                    if ($got -le 0) { break }
                    $read += $got
                }
                $full = ($read -ge $MaxBytesPerFile)
                $split = Split-AzlSonarLogChunk -Bytes $buffer -Count $read -Encoding $encoding -MaxLines $budget -SkipPartialLine $skip -ChunkIsFull $full
                if ($split.SkippedPartial -or ($skip -and $split.ConsumedBytes -gt 0)) { $skip = $false }
                foreach ($line in $split.Lines) { $outLines.Add([pscustomobject]@{ file = $path; text = $line }) }
                $budget -= @($split.Lines).Count
                $offset += [long]$split.ConsumedBytes
            }
        }
        catch {
            $errors.Add(('{0}: {1}' -f $path, $_.Exception.Message))
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    $newState[$path] = @{
        offset = [long]$offset; created = $created; size = $size; encoding = $encoding; bom = $bomLength; skip = $skip
        head = $headText; lastWrite = [long]$item.LastWriteTimeUtc.Ticks; active = $true
    }
    $outFiles.Add([pscustomobject]@{ path = $path; size = $size; offset = [long]$offset; lastWriteUtc = $item.LastWriteTimeUtc.ToString('o') })
}

# A tracked file that vanished between listings stays (inactive) until the next listing, where a renamed copy can claim it.
if (-not $Discover) {
    foreach ($key in @($vanished.Keys)) {
        $entry = $vanished[$key]
        if ($null -eq $entry -or -not ($entry -is [System.Collections.IDictionary])) { continue }
        $copy = @{}
        foreach ($field in @($entry.Keys)) { $copy[$field] = $entry[$field] }
        $copy['active'] = $false
        $copy['gone'] = $true
        $newState[$key] = $copy
    }
}

$evicted = 0
if ($newState.Count -gt $MaxStateEntries) {
    $rank = foreach ($key in @($newState.Keys)) {
        $entry = $newState[$key]
        $write = [long]0
        if ($entry.Contains('lastWrite') -and $null -ne $entry['lastWrite']) { $write = [long]$entry['lastWrite'] }
        [pscustomobject]@{ Key = $key; Active = [bool](& $isActive $entry); Write = $write }
    }
    $drop = @($rank | Sort-Object -Property @{ Expression = 'Active'; Descending = $true }, @{ Expression = 'Write'; Descending = $true } | Select-Object -Skip $MaxStateEntries)
    foreach ($entry in $drop) { $newState.Remove($entry.Key); $evicted++ }
}

$utcOffset = [int][Math]::Round([TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now).TotalMinutes)

[pscustomobject]@{
    computer         = $env:COMPUTERNAME
    polledAtUtc      = [datetime]::UtcNow.ToString('o')
    utcOffsetMinutes = $utcOffset
    discovered       = [bool]$Discover
    files            = $outFiles.ToArray()
    lines            = $outLines.ToArray()
    state            = $newState
    missingPaths     = $missing.ToArray()
    errors           = $errors.ToArray()
    renamed          = $renamed.ToArray()
    vanished         = @($vanished.Keys).Count
    stateEvicted     = $evicted
}
'@

    return [scriptblock]::Create($head + "`n" + ($helpers -join "`n") + "`n" + $body)
}

function Invoke-AzlSonarLogPoll {
    <#
    .SYNOPSIS
        Runs one tail poll on the seed node through an open PSSession (Invoke-Command) and returns its result.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [hashtable]$FileState,

        [bool]$FirstRun,

        [bool]$Discover = $true
    )

    if ($null -eq $FileState) { $FileState = @{} }
    $logs = $Config.logs
    $arguments = @(
        [string[]]$logs.paths,
        [string[]]$logs.include,
        [string[]]$logs.exclude,
        [int]$logs.recurseDepth,
        [int]$logs.activeWindowMinutes,
        $FileState,
        [int]$logs.maxLinesPerPoll,
        $FirstRun,
        [int]$script:AzlSonarTail.MaxFiles,
        [int]$script:AzlSonarTail.MaxBytesPerFile,
        [long]$script:AzlSonarTail.InitialTailBytes,
        $Discover,
        [int]$script:AzlSonarTail.MaxStateEntries,
        [int]$script:AzlSonarTail.HeadBytes
    )
    return Invoke-Command -Session $Session -ScriptBlock (Get-AzlSonarRemoteTailScript) -ArgumentList $arguments -ErrorAction Stop
}

function Invoke-AzlSonarLogPollSsh {
    <#
    .SYNOPSIS
        Runs one tail poll on the seed node over SSH (Posh-SSH session) and returns its result.
    .DESCRIPTION
        For nodes that answer SSH but not WinRM from the workstation. The same read-only tail script is streamed to
        'powershell -NoProfile -NonInteractive -Command -' on the node through stdin (no command-line length limit, no
        file written on the node); the arguments travel with it as base64 JSON and the result comes back as JSON.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$SshSession,

        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [hashtable]$FileState,

        [bool]$FirstRun,

        [bool]$Discover = $true
    )

    if ($null -eq $FileState) { $FileState = @{} }
    $logs = $Config.logs
    $arguments = [ordered]@{
        Paths               = [string[]]$logs.paths
        Include             = [string[]]$logs.include
        Exclude             = [string[]]$logs.exclude
        RecurseDepth        = [int]$logs.recurseDepth
        ActiveWindowMinutes = [int]$logs.activeWindowMinutes
        FileState           = $FileState
        MaxLines            = [int]$logs.maxLinesPerPoll
        FirstRun            = $FirstRun
        MaxFiles            = [int]$script:AzlSonarTail.MaxFiles
        MaxBytesPerFile     = [int]$script:AzlSonarTail.MaxBytesPerFile
        InitialTailBytes    = [long]$script:AzlSonarTail.InitialTailBytes
        Discover            = $Discover
        MaxStateEntries     = [int]$script:AzlSonarTail.MaxStateEntries
        HeadBytes           = [int]$script:AzlSonarTail.HeadBytes
    }
    $toB64 = { param([string]$s) [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s)) }
    $scriptB64 = & $toB64 (Get-AzlSonarRemoteTailScript).ToString()
    $argsB64 = & $toB64 ($arguments | ConvertTo-Json -Depth 6 -Compress)
    # One statement per line: 'powershell -Command -' runs stdin line by line (Windows PowerShell 5.1 on the node).
    $stdin = @(
        '$ErrorActionPreference = ''Stop''; $ProgressPreference = ''SilentlyContinue'''
        "`$u = [System.Text.Encoding]::UTF8; `$sb = [scriptblock]::Create(`$u.GetString([Convert]::FromBase64String('$scriptB64'))); `$a = `$u.GetString([Convert]::FromBase64String('$argsB64')) | ConvertFrom-Json"
        '$fs = @{}; if ($a.FileState) { foreach ($p in $a.FileState.PSObject.Properties) { $h = @{}; foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }; $fs[$p.Name] = $h } }'
        '$r = & $sb ([string[]]$a.Paths) ([string[]]$a.Include) ([string[]]$a.Exclude) ([int]$a.RecurseDepth) ([int]$a.ActiveWindowMinutes) $fs ([int]$a.MaxLines) ([bool]$a.FirstRun) ([int]$a.MaxFiles) ([int]$a.MaxBytesPerFile) ([long]$a.InitialTailBytes) ([bool]$a.Discover) ([int]$a.MaxStateEntries) ([int]$a.HeadBytes)'
        '[Console]::Out.Write(''<<AZLSONAR>>'' + ($r | ConvertTo-Json -Depth 6 -Compress) + ''<<END>>'')'
        'exit'
    ) -join "`n"

    $client = $SshSession.Session
    $command = $client.CreateCommand('powershell -NoProfile -NonInteractive -Command -')
    $command.CommandTimeout = [TimeSpan]::FromMilliseconds($script:AzlSonarTail.SessionOperationMs)
    $async = $command.BeginExecute()
    $stdinStream = $command.CreateInputStream()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($stdin + "`n")
        $stdinStream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stdinStream.Dispose() }
    $null = $command.EndExecute($async)
    $text = [string]$command.Result
    $start = $text.IndexOf('<<AZLSONAR>>')
    $end = $text.LastIndexOf('<<END>>')
    if ($start -lt 0 -or $end -le $start) {
        $err = ([string]$command.Error).Trim()
        throw "The SSH tail poll returned no result (exit $($command.ExitStatus)). $($err.Substring(0, [Math]::Min(400, $err.Length)))"
    }
    $json = $text.Substring($start + 12, $end - $start - 12)
    return ($json | ConvertFrom-Json -AsHashtable)
}

function ConvertTo-AzlSonarFileState {
    <#
    .SYNOPSIS
        Turns the (deserialised) state returned by the remote script into a hashtable of hashtables.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$State
    )

    $result = @{}
    if ($null -eq $State) { return $result }
    $pairs = if ($State -is [System.Collections.IDictionary]) {
        foreach ($key in $State.Keys) { @{ Key = [string]$key; Value = $State[$key] } }
    }
    else {
        foreach ($property in $State.PSObject.Properties) { @{ Key = $property.Name; Value = $property.Value } }
    }
    foreach ($pair in $pairs) {
        $entry = @{}
        $value = $pair.Value
        foreach ($field in 'offset', 'created', 'size', 'encoding', 'bom', 'skip', 'head', 'lastWrite', 'active', 'gone') {
            $fieldValue = Get-AzlSonarMember $value $field
            if ($null -ne $fieldValue -or $field -in 'offset', 'created', 'size', 'encoding', 'bom', 'skip') { $entry[$field] = $fieldValue }
        }
        $result[$pair.Key] = $entry
    }
    return $result
}

function Add-AzlSonarLogLine {
    <#
    .SYNOPSIS
        Adds lines to the shared ring buffer with a sequence number, event time, receive time and level.
    .DESCRIPTION
        Each line gets: seq; received (when Sonar got it, UTC); time (the event time from the line's own leading
        timestamp or the file name, see Get-AzlSonarLogEventTime, else the receive time); timeSource (line | file |
        received); file; level; text (secrets masked). Node-local timestamps are converted with -UtcOffsetMinutes
        (the node's offset, reported by the remote tail script). Keeps at most RingSize lines (5000 by default); the
        oldest drop out. Thread-safe (shared Lock).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Line,

        [datetime]$Time = [datetime]::UtcNow,

        [AllowNull()]
        [Nullable[int]]$UtcOffsetMinutes
    )

    $items = ConvertTo-AzlSonarArray $Line
    if ($items.Count -eq 0) { return }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $format = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
    $received = $Time.ToUniversalTime()
    $receivedText = $received.ToString($format, $culture)
    $prepared = foreach ($item in $items) {
        $text = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $item 'text' '')) -Secret $Shared.Redact
        $file = [string](Get-AzlSonarMember $item 'file' '')
        $eventTime = Get-AzlSonarLogEventTime -Text $text -File $file -UtcOffsetMinutes $UtcOffsetMinutes -Received $received
        [ordered]@{
            seq        = [long]0
            time       = $eventTime.Time.ToString($format, $culture)
            received   = $receivedText
            timeSource = $eventTime.Source
            file       = $file
            level      = Get-AzlSonarLineLevel $text
            text       = $text
        }
    }
    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        foreach ($record in $prepared) {
            $Shared.LogSeq = [long]$Shared.LogSeq + 1
            $record.seq = [long]$Shared.LogSeq
            $Shared.Lines.Enqueue($record)
            while ($Shared.Lines.Count -gt $Shared.RingSize) { $null = $Shared.Lines.Dequeue() }
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Get-AzlSonarLogWindow {
    <#
    .SYNOPSIS
        Reads the ring buffer in one locked step: the lines with seq greater than -Since (at most -Max, oldest first),
        the last sequence number given out (LastSeq) and the oldest seq still held (OldestSeq, 0 when empty).
    .DESCRIPTION
        LastSeq is read together with the lines, so a client that asked for lines after -Since has seen (or lost to
        the ring) everything up to LastSeq. The page uses it as its catch-up cursor.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [long]$Since = 0,

        [int]$Max = [int]::MaxValue
    )

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        $all = $Shared.Lines.ToArray()
        $lastSeq = [long]$Shared.LogSeq
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $all) {
        if ([long]$line['seq'] -gt $Since) {
            $result.Add($line)
            if ($result.Count -ge $Max) { break }
        }
    }
    $oldest = if ($all.Length -gt 0) { [long]$all[0]['seq'] } else { [long]0 }
    return [pscustomobject]@{ Lines = $result.ToArray(); LastSeq = $lastSeq; OldestSeq = $oldest }
}

function Get-AzlSonarLogLine {
    <#
    .SYNOPSIS
        Returns the ring-buffer lines with seq greater than -Since (at most -Max, oldest first).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [long]$Since = 0,

        [int]$Max = [int]::MaxValue
    )

    return , (Get-AzlSonarLogWindow -Shared $Shared -Since $Since -Max $Max).Lines
}

function Test-AzlSonarDiscoveryDue {
    <#
    .SYNOPSIS
        True when the next tail poll should list the log folders (Get-ChildItem) instead of only re-checking known files.
    .DESCRIPTION
        Due on the first poll, when -Force is set (a tracked file vanished, or the session was re-opened), on every
        EveryPolls-th poll (PollsSinceDiscovery counts the polls since the last listing) and when MaxSeconds have
        passed since the last listing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [int]$PollsSinceDiscovery,

        [AllowNull()]
        [Nullable[datetime]]$LastDiscoveryUtc,

        [datetime]$Now = [datetime]::UtcNow,

        [switch]$Force,

        [int]$EveryPolls = $script:AzlSonarTail.DiscoverEveryPolls,

        [int]$MaxSeconds = $script:AzlSonarTail.DiscoverMaxSeconds
    )

    if ($Force -or $null -eq $LastDiscoveryUtc) { return $true }
    if ($EveryPolls -le 1 -or ($PollsSinceDiscovery + 1) -ge $EveryPolls) { return $true }
    return (($Now.ToUniversalTime() - ([datetime]$LastDiscoveryUtc).ToUniversalTime()).TotalSeconds -ge $MaxSeconds)
}

function Test-AzlSonarTrustedHost {
    <#
    .SYNOPSIS
        True when a WinRM TrustedHosts value (comma-separated, wildcards allowed) covers the address.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TrustedHosts,

        [Parameter(Mandatory)]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($TrustedHosts)) { return $false }
    foreach ($entry in $TrustedHosts.Split(',')) {
        $pattern = $entry.Trim()
        if (-not $pattern) { continue }
        if ($pattern -eq '*' -or $Address -like $pattern) { return $true }
    }
    return $false
}

function Get-AzlSonarTrustedHostsValue {
    <#
    .SYNOPSIS
        Reads (never sets) the workstation's WinRM client TrustedHosts list. Returns $null when it cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        return [string](Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value
    }
    catch {
        Write-Verbose "TrustedHosts not readable through WSMan: ($($_.Exception.Message)); trying the registry."
    }
    $locations = @(
        @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Client'; Value = 'TrustedHostsList' },
        @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client'; Value = 'trusted_hosts' }
    )
    foreach ($location in $locations) {
        try {
            $item = Get-ItemProperty -LiteralPath $location.Key -Name $location.Value -ErrorAction Stop
            return [string]$item.($location.Value)
        }
        catch {
            Write-Verbose "TrustedHosts not found at $($location.Key)."
        }
    }
    return $null
}

function Get-AzlSonarTrustedHostStatus {
    <#
    .SYNOPSIS
        Reports whether the seed address needs to be in TrustedHosts and whether it is. Only reports; never changes it.
    .DESCRIPTION
        Required for Local Identity (workgroup) nodes and whenever the address is an IP address (no Kerberos).
        -TrustedHostsValue lets tests pass the value instead of reading the workstation.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [Parameter(Mandatory)]
        [string]$IdentityModel,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TrustedHostsValue,

        [switch]$UseValue
    )

    $parsed = $null
    $isIp = [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)
    $required = ($IdentityModel -eq 'LocalIdentity') -or $isIp
    $status = [ordered]@{ required = $required; trusted = $null; message = $null }
    if (-not $required) {
        $status.message = 'Kerberos (Active Directory, host name): TrustedHosts is not needed.'
        return $status
    }
    if (-not $IsWindows) {
        $status.message = 'Not running on Windows: TrustedHosts not checked.'
        return $status
    }
    $value = if ($UseValue) { $TrustedHostsValue } else { Get-AzlSonarTrustedHostsValue }
    if ($null -eq $value -and -not $UseValue) {
        $status.message = 'Could not read the WinRM client TrustedHosts list on this workstation (WinRM service stopped or no access).'
        return $status
    }
    $status.trusted = Test-AzlSonarTrustedHost -TrustedHosts $value -Address $Address
    $status.message = if ($status.trusted) {
        "$Address is in the WinRM client TrustedHosts list."
    }
    else {
        "$Address is not in the WinRM client TrustedHosts list of this workstation. Workgroup (Local Identity) nodes and IP addresses need it: " +
        "an administrator adds the address to WSMan:\localhost\Client\TrustedHosts (append, do not replace). Sonar never changes it."
    }
    return $status
}

function Publish-AzlSonarTailerStatus {
    <#
    .SYNOPSIS
        Stores the tailer status in the shared table and bumps its version (SSE 'tailer' event).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Status
    )

    $json = ConvertTo-AzlSonarJson $Status
    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        $Shared.Tailer = $Status
        $Shared.TailerJson = $json
        $Shared.TailerVersion = [long]$Shared.TailerVersion + 1
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Invoke-AzlSonarTailerLoop {
    <#
    .SYNOPSIS
        Background loop: keeps a PSSession to the seed node and tails the deployment logs until the stop flag is set.
    .DESCRIPTION
        When the session cannot be opened or a poll fails, reports { state: unavailable, reason } and retries after
        60 seconds. Removes the session on exit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [pscredential]$Credential
    )

    $seed = $Config.seedNode
    $trust = Get-AzlSonarTrustedHostStatus -Address $seed.address -IdentityModel $Config.identityModel
    $status = {
        param([string]$State, [string]$Reason, [object]$Extra)
        $value = [ordered]@{
            state        = $State
            reason       = $Reason
            node         = $seed.name
            address      = $seed.address
            credential   = if ($null -ne $Credential) { 'supplied' } else { 'current Windows identity' }
            trustedHosts = $trust
            missingPaths = @()
            fileErrors   = @()
            filesTracked = 0
            lastPollUtc  = $null
        }
        if ($null -ne $Extra) { foreach ($key in $Extra.Keys) { $value[$key] = $Extra[$key] } }
        Publish-AzlSonarTailerStatus -Shared $Shared -Status $value
    }

    $session = $null
    $ssh = $null
    $transport = [string](Get-AzlSonarMember $Config.logs 'transport' 'auto')
    $fileState = @{}
    $firstRun = $true
    $forceDiscovery = $true
    $pollsSinceDiscovery = 0
    $lastDiscoveryUtc = $null
    $missing = [string[]]@()
    $renamedCount = 0
    try {
        while (-not $Shared.Stop) {
            if (($null -eq $session -or $session.State -ne 'Opened') -and ($null -eq $ssh -or -not $ssh.Connected)) {
                $session = $null; $ssh = $null
                $reasons = [System.Collections.Generic.List[string]]::new()
                if ($transport -in 'auto', 'winrm') {
                    & $status 'connecting' "Opening a PowerShell remoting session to $($seed.name) ($($seed.address))." $null
                    try {
                        $options = New-PSSessionOption -OpenTimeout $script:AzlSonarTail.SessionOpenMs -OperationTimeout $script:AzlSonarTail.SessionOperationMs -NoMachineProfile
                        $sessionParameters = @{ ComputerName = $seed.address; SessionOption = $options; Name = 'AzlSonar'; ErrorAction = 'Stop' }
                        if ($null -ne $Credential) { $sessionParameters.Credential = $Credential }
                        $session = New-PSSession @sessionParameters
                    }
                    catch {
                        $r = "WinRM: $($_.Exception.Message)"
                        if ($trust.required -and $trust.trusted -eq $false) { $r += ' ' + $trust.message }
                        $reasons.Add($r)
                        $session = $null
                    }
                }
                if ($null -eq $session -and $transport -in 'auto', 'ssh') {
                    if ($null -eq $Credential) { $reasons.Add('SSH: needs a credential (prompt, -Credential or keyvault).') }
                    elseif (-not (Get-Module -ListAvailable -Name Posh-SSH)) { $reasons.Add('SSH: the Posh-SSH module is not installed on this workstation (Install-Module Posh-SSH -Scope CurrentUser).') }
                    else {
                        & $status 'connecting' "Opening an SSH session to $($seed.name) ($($seed.address))." $null
                        try {
                            Import-Module Posh-SSH -ErrorAction Stop
                            $ssh = New-SSHSession -ComputerName $seed.address -Credential $Credential -AcceptKey -ConnectionTimeout ([int]($script:AzlSonarTail.SessionOpenMs / 1000)) -ErrorAction Stop -WarningAction SilentlyContinue
                        }
                        catch { $reasons.Add("SSH: $($_.Exception.Message)"); $ssh = $null }
                    }
                }
                if ($null -eq $session -and $null -eq $ssh) {
                    & $status 'unavailable' ("Cannot reach the logs on $($seed.name) ($($seed.address)). " + ($reasons -join ' | ')) @{ retryInSeconds = $script:AzlSonarTail.RetrySeconds }
                    Wait-AzlSonarInterval -Shared $Shared -Seconds $script:AzlSonarTail.RetrySeconds
                    continue
                }
            }

            try {
                $discover = Test-AzlSonarDiscoveryDue -PollsSinceDiscovery $pollsSinceDiscovery -LastDiscoveryUtc $lastDiscoveryUtc -Force:($forceDiscovery -or $firstRun)
                $result = if ($null -ne $session) {
                    Invoke-AzlSonarLogPoll -Session $session -Config $Config -FileState $fileState -FirstRun $firstRun -Discover $discover
                }
                else {
                    Invoke-AzlSonarLogPollSsh -SshSession $ssh -Config $Config -FileState $fileState -FirstRun $firstRun -Discover $discover
                }
                $firstRun = $false
                $forceDiscovery = $false
                if ([bool](Get-AzlSonarMember $result 'discovered' $true)) {
                    $pollsSinceDiscovery = 0
                    $lastDiscoveryUtc = [datetime]::UtcNow
                    $missing = [string[]](ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'missingPaths'))
                }
                else {
                    $pollsSinceDiscovery++
                }
                # A tracked file vanished (rotation): list the folders on the next poll so its new name is found.
                if ([int](Get-AzlSonarMember $result 'vanished' 0) -gt 0) { $forceDiscovery = $true }
                $fileState = ConvertTo-AzlSonarFileState (Get-AzlSonarMember $result 'state')
                $offsetValue = Get-AzlSonarMember $result 'utcOffsetMinutes'
                $nodeOffset = if ($null -ne $offsetValue) { [Nullable[int]][int]$offsetValue } else { $null }
                Add-AzlSonarLogLine -Shared $Shared -Line (ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'lines')) -UtcOffsetMinutes $nodeOffset
                $files = foreach ($file in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'files'))) {
                    [ordered]@{
                        path         = [string](Get-AzlSonarMember $file 'path' '')
                        size         = [long](Get-AzlSonarMember $file 'size' 0)
                        offset       = [long](Get-AzlSonarMember $file 'offset' 0)
                        lastWriteUtc = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $file 'lastWriteUtc'))
                    }
                }
                $Shared.Files = @($files)
                $fileErrors = [string[]](ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'errors'))
                $renamedCount += @(ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'renamed')).Count
                $reason = if ($missing.Count -gt 0) { "Not created yet (checked at every folder listing): $($missing -join ', ')" } else { $null }
                & $status 'connected' $reason @{
                    transport            = if ($null -ne $session) { 'winrm' } else { 'ssh' }
                    missingPaths         = $missing
                    fileErrors           = $fileErrors
                    filesTracked         = @($files).Count
                    activeFiles          = [string[]]@($files | ForEach-Object { $_.path })
                    stateEntries         = $fileState.Count
                    renamedFiles         = $renamedCount
                    nodeUtcOffsetMinutes = $nodeOffset
                    lastDiscoveryUtc     = Format-AzlSonarDate $lastDiscoveryUtc
                    lastPollUtc          = Format-AzlSonarDate ([datetime]::UtcNow)
                }
            }
            catch {
                & $status 'unavailable' "Reading the logs on $($seed.name) failed: $($_.Exception.Message)" @{ retryInSeconds = $script:AzlSonarTail.RetrySeconds }
                if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
                if ($null -ne $ssh) { $null = Remove-SSHSession -SessionId $ssh.SessionId -ErrorAction SilentlyContinue }
                $session = $null; $ssh = $null
                $forceDiscovery = $true
                Wait-AzlSonarInterval -Shared $Shared -Seconds $script:AzlSonarTail.RetrySeconds
                continue
            }
            Wait-AzlSonarInterval -Shared $Shared -Seconds $Config.logs.pollSeconds
        }
    }
    finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        if ($null -ne $ssh) { $null = Remove-SSHSession -SessionId $ssh.SessionId -ErrorAction SilentlyContinue }
    }
}
