Set-StrictMode -Version Latest

# Tailer limits (not environment values).
$script:AzlSonarTail = @{
    MaxFiles          = 300          # newest files considered per poll
    MaxBytesPerFile   = 1048576      # bytes read from one file per poll
    InitialTailBytes  = 16384        # files already present when Sonar starts begin this far from their end
    RetrySeconds      = 60           # wait before reconnecting after a failure
    SessionOpenMs     = 30000
    SessionOperationMs = 180000
}

#region Pure helpers. These four are also embedded in the remote script, so they must run on Windows PowerShell 5.1.

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

#endregion

function Get-AzlSonarLineLevel {
    <#
    .SYNOPSIS
        Classifies a log line: error, warning or info.
    .DESCRIPTION
        error: \b(error|exception|failed|fatal)\b; warning: \bwarn(ing)?\b; case-insensitive; else info.
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
    if ($Text -match '(?i)\b(error|exception|failed|fatal)\b') { return 'error' }
    if ($Text -match '(?i)\bwarn(ing)?\b') { return 'warning' }
    return 'info'
}

function Get-AzlSonarRemoteTailScript {
    <#
    .SYNOPSIS
        Builds the read-only script the tailer runs on the seed node (one call per poll).
    .DESCRIPTION
        Lists files under the log paths (recursing RecurseDepth levels; a path that does not exist yet is reported
        and checked again next poll), keeps only files written within ActiveWindowMinutes, newest first, and reads
        new bytes from each with FileShare ReadWrite (and Delete, so rotation is never blocked). Offsets travel with
        the call (FileState in, state out), so the node keeps nothing between polls. Runs on Windows PowerShell 5.1.
        It can also be invoked locally against a folder, which is how the offset and rotation logic is tested.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    $helperNames = 'Get-AzlSonarBomEncoding', 'Test-AzlSonarNameMatch', 'Resolve-AzlSonarTailOffset', 'Split-AzlSonarLogChunk'
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
    [long]$InitialTailBytes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
'@

    $body = @'
if ($null -eq $FileState) { $FileState = @{} }
$windowStart = [datetime]::UtcNow.AddMinutes(-1 * $ActiveWindowMinutes)
$candidates = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[string]
$errors = New-Object System.Collections.Generic.List[string]
$seen = @{}
foreach ($root in $Paths) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { $missing.Add($root); continue }
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Depth $RecurseDepth -File -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if (-not (Test-AzlSonarNameMatch -Name $item.Name -Include $Include -Exclude $Exclude)) { continue }
        $seen[$item.FullName] = $true
        if ($item.LastWriteTimeUtc -ge $windowStart) { $candidates.Add($item) }
    }
}
$active = @($candidates | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First $MaxFiles)
$activeSet = @{}
foreach ($item in $active) { $activeSet[$item.FullName] = $true }

$newState = @{}
# Files still on disk but outside the active window keep their offset so they continue, not restart, if written again.
foreach ($key in @($FileState.Keys)) {
    if ($seen.ContainsKey($key) -and -not $activeSet.ContainsKey($key)) { $newState[$key] = $FileState[$key] }
}

$budget = $MaxLines
$outLines = New-Object System.Collections.Generic.List[object]
$outFiles = New-Object System.Collections.Generic.List[object]
foreach ($item in $active) {
    $path = $item.FullName
    $size = [long]$item.Length
    $created = [long]$item.CreationTimeUtc.Ticks
    $previous = $null
    if ($FileState.ContainsKey($path)) { $previous = $FileState[$path] }
    $plan = Resolve-AzlSonarTailOffset -Previous $previous -Size $size -CreatedTicks $created -StartAtEnd $FirstRun -InitialTailBytes $InitialTailBytes
    $offset = [long]$plan.Offset
    $skip = [bool]$plan.SkipPartialLine
    $encoding = $null
    $bomLength = 0
    if ($null -ne $previous -and -not $plan.Reset -and $previous.Contains('encoding') -and $previous['encoding']) {
        $encoding = [string]$previous['encoding']
        if ($previous.Contains('bom') -and $null -ne $previous['bom']) { $bomLength = [int]$previous['bom'] }
    }
    if ($size -gt $offset -and $budget -gt 0) {
        $stream = $null
        try {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            if (-not $encoding) {
                $head = New-Object byte[] ([int][Math]::Min([long]4, $size))
                $null = $stream.Read($head, 0, $head.Length)
                $detected = Get-AzlSonarBomEncoding -Bytes $head
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
    $newState[$path] = @{ offset = [long]$offset; created = $created; size = $size; encoding = $encoding; bom = $bomLength; skip = $skip }
    $outFiles.Add([pscustomobject]@{ path = $path; size = $size; offset = [long]$offset; lastWriteUtc = $item.LastWriteTimeUtc.ToString('o') })
}

[pscustomobject]@{
    computer     = $env:COMPUTERNAME
    polledAtUtc  = [datetime]::UtcNow.ToString('o')
    files        = $outFiles.ToArray()
    lines        = $outLines.ToArray()
    state        = $newState
    missingPaths = $missing.ToArray()
    errors       = $errors.ToArray()
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

        [bool]$FirstRun
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
        [long]$script:AzlSonarTail.InitialTailBytes
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

        [bool]$FirstRun
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
    }
    $toB64 = { param([string]$s) [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s)) }
    $scriptB64 = & $toB64 (Get-AzlSonarRemoteTailScript).ToString()
    $argsB64 = & $toB64 ($arguments | ConvertTo-Json -Depth 6 -Compress)
    # One statement per line: 'powershell -Command -' runs stdin line by line (Windows PowerShell 5.1 on the node).
    $stdin = @(
        '$ErrorActionPreference = ''Stop''; $ProgressPreference = ''SilentlyContinue'''
        "`$u = [System.Text.Encoding]::UTF8; `$sb = [scriptblock]::Create(`$u.GetString([Convert]::FromBase64String('$scriptB64'))); `$a = `$u.GetString([Convert]::FromBase64String('$argsB64')) | ConvertFrom-Json"
        '$fs = @{}; if ($a.FileState) { foreach ($p in $a.FileState.PSObject.Properties) { $h = @{}; foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }; $fs[$p.Name] = $h } }'
        '$r = & $sb ([string[]]$a.Paths) ([string[]]$a.Include) ([string[]]$a.Exclude) ([int]$a.RecurseDepth) ([int]$a.ActiveWindowMinutes) $fs ([int]$a.MaxLines) ([bool]$a.FirstRun) ([int]$a.MaxFiles) ([int]$a.MaxBytesPerFile) ([long]$a.InitialTailBytes)'
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
        foreach ($field in 'offset', 'created', 'size', 'encoding', 'bom', 'skip') {
            $entry[$field] = Get-AzlSonarMember $value $field
        }
        $result[$pair.Key] = $entry
    }
    return $result
}

function Add-AzlSonarLogLine {
    <#
    .SYNOPSIS
        Adds lines to the shared ring buffer with a sequence number, receive time and level.
    .DESCRIPTION
        Keeps at most RingSize lines (5000 by default); the oldest drop out. Thread-safe (shared Lock).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Line,

        [datetime]$Time = [datetime]::UtcNow
    )

    $items = ConvertTo-AzlSonarArray $Line
    if ($items.Count -eq 0) { return }
    $timeText = $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        foreach ($item in $items) {
            $text = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $item 'text' '')) -Secret $Shared.Redact
            $Shared.LogSeq = [long]$Shared.LogSeq + 1
            $Shared.Lines.Enqueue([ordered]@{
                    seq   = [long]$Shared.LogSeq
                    time  = $timeText
                    file  = [string](Get-AzlSonarMember $item 'file' '')
                    level = Get-AzlSonarLineLevel $text
                    text  = $text
                })
            while ($Shared.Lines.Count -gt $Shared.RingSize) { $null = $Shared.Lines.Dequeue() }
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
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

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        $all = $Shared.Lines.ToArray()
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
    return , $result.ToArray()
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
                $result = if ($null -ne $session) {
                    Invoke-AzlSonarLogPoll -Session $session -Config $Config -FileState $fileState -FirstRun $firstRun
                }
                else {
                    Invoke-AzlSonarLogPollSsh -SshSession $ssh -Config $Config -FileState $fileState -FirstRun $firstRun
                }
                $firstRun = $false
                $fileState = ConvertTo-AzlSonarFileState (Get-AzlSonarMember $result 'state')
                Add-AzlSonarLogLine -Shared $Shared -Line (ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'lines'))
                $files = foreach ($file in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'files'))) {
                    [ordered]@{
                        path         = [string](Get-AzlSonarMember $file 'path' '')
                        size         = [long](Get-AzlSonarMember $file 'size' 0)
                        offset       = [long](Get-AzlSonarMember $file 'offset' 0)
                        lastWriteUtc = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $file 'lastWriteUtc'))
                    }
                }
                $Shared.Files = @($files)
                $missing = [string[]](ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'missingPaths'))
                $fileErrors = [string[]](ConvertTo-AzlSonarArray (Get-AzlSonarMember $result 'errors'))
                $reason = if ($missing.Count -gt 0) { "Not created yet (checked every poll): $($missing -join ', ')" } else { $null }
                & $status 'connected' $reason @{
                    transport    = if ($null -ne $session) { 'winrm' } else { 'ssh' }
                    missingPaths = $missing
                    fileErrors   = $fileErrors
                    filesTracked = @($files).Count
                    lastPollUtc  = Format-AzlSonarDate ([datetime]::UtcNow)
                }
            }
            catch {
                & $status 'unavailable' "Reading the logs on $($seed.name) failed: $($_.Exception.Message)" @{ retryInSeconds = $script:AzlSonarTail.RetrySeconds }
                if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
                if ($null -ne $ssh) { $null = Remove-SSHSession -SessionId $ssh.SessionId -ErrorAction SilentlyContinue }
                $session = $null; $ssh = $null
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
