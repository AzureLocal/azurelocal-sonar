Set-StrictMode -Version Latest

# Pre-cluster verification gate events (azurelocal-toolkit, the gate that runs after OS configuration and before the ARM
# Validate and Deploy run). The gate writes three files into its report directory: precluster-verification-events.jsonl,
# report.json and summary.md (default <environment data>/arm-report/verification/live). Sonar follows the events file
# (local, read-only). One object per line:
#   { schema 1, runId, seq, ts (UTC ISO), type RunStarted|Check|RunCompleted, checkId, category azure|identity|nodes|network|
#     storage|readiness, title, status Passed|Failed|Warning|Skipped|NotApplicable|Fixed|Running, node, message, remedy,
#     source, blocking (bool) }
# RunCompleted adds verdict Pass|Fail, counts { status: count }, fileHash and expiresUtc.
#
# The file can hold more than one run (and the gate may replace it for a new run), so the reader follows the LATEST run only:
#  - the first line of a run id Sonar has not seen starts that run and the checks of the old one go (RunStarted does this;
#    so does a first line whose RunStarted was never read);
#  - a line of a run id that was seen and is no longer current, or of an unseen run that is older than the current run's
#    start, is stale: it is ignored and counted, never shown as the current run;
#  - a check is one row per checkId and node; the highest seq wins, a line with a lower or equal seq is ignored;
#  - a run without a RunCompleted line is Running; a Pass whose expiresUtc has passed is Expired.
# The state never shows green by accident: a Pass verdict with a Failed or Skipped (blocking) check in the same run is shown
# as Fail with a warning, because the gate's own words and its checks disagree.
#
# The store (Shared.VerificationEvents) maps '*' to the run entry. Every change stores a new object (never edits one the
# poller may be reading). The loop rebuilds the entry from the whole file whenever the file changes (it is small), so a
# replaced, truncated or rewritten file is always shown as it is now.

$script:AzlSonarVerifyRunKey = '*'
$script:AzlSonarVerifyEventFile = 'verification-events'
$script:AzlSonarVerifyFileName = 'precluster-verification-events.jsonl'
$script:AzlSonarVerifyMaxChecks = 2000
$script:AzlSonarVerifyMaxRuns = 32
$script:AzlSonarVerifyMaxBytes = 8MB
$script:AzlSonarVerifyMaxAttention = 60
$script:AzlSonarVerifyGuide = 'https://azurelocal.cloud'

# Status words of the contract, by their lower-case form, and the order the page shows them in (failed first).
$script:AzlSonarVerifyStatus = [ordered]@{
    failed        = @{ Name = 'Failed'; Rank = 0 }
    skipped       = @{ Name = 'Skipped'; Rank = 1 }
    running       = @{ Name = 'Running'; Rank = 2 }
    warning       = @{ Name = 'Warning'; Rank = 3 }
    fixed         = @{ Name = 'Fixed'; Rank = 4 }
    passed        = @{ Name = 'Passed'; Rank = 5 }
    notapplicable = @{ Name = 'NotApplicable'; Rank = 6 }
}
$script:AzlSonarVerifyCategory = [ordered]@{
    azure     = 'Azure'
    identity  = 'Identity'
    nodes     = 'Nodes'
    network   = 'Network'
    storage   = 'Storage'
    readiness = 'Readiness'
}

# ---------------------------------------------------------------------------------------------------------------------
# Reading the file
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSonarVerifyStatusName {
    <#
    .SYNOPSIS
        The canonical status word (Passed, Failed, ...) for a status written in any case, or the text as written when it is
        not one the contract names (kept, shown as it is, never dropped).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $k = ([string]$Value).Trim().ToLowerInvariant() -replace '[\s_-]', ''
    if ($script:AzlSonarVerifyStatus.Contains($k)) { return [string]$script:AzlSonarVerifyStatus[$k].Name }
    return ([string]$Value).Trim()
}

function ConvertFrom-AzlSonarVerificationLine {
    <#
    .SYNOPSIS
        Parses one line of the verification event file into a hashtable { schema, runId, seq ($null when absent), when (UTC
        datetime or $null), timestamp, type, checkId, category, title, status, node, message, remedy, source, blocking,
        verdict, counts, fileHash, expiresUtc, expires (UTC datetime or $null) }, or $null when it is not an event.
    .DESCRIPTION
        Only objects with a runId and a type of RunStarted, Check or RunCompleted are events, and a Check needs a checkId.
        A timestamp is read as UTC with the invariant culture whatever the culture of this machine is. A half-written line
        is not JSON and is skipped. Text is kept as the gate wrote it (it scrubbed its own secrets); Sonar masks it again
        before it reaches the page. A missing blocking means true for a failed check.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $raw = $null
    try { $raw = ConvertFrom-Json -InputObject $Line -AsHashtable -Depth 8 } catch { return $null }
    if ($raw -isnot [System.Collections.IDictionary]) { return $null }
    $get = { param($k, $d) if ($raw.Contains($k) -and $null -ne $raw[$k]) { $raw[$k] } else { $d } }
    $runId = ([string](& $get 'runId' '')).Trim()
    $type = ([string](& $get 'type' '')).Trim()
    $typeName = switch ($type.ToLowerInvariant()) { 'runstarted' { 'RunStarted' } 'check' { 'Check' } 'runcompleted' { 'RunCompleted' } default { '' } }
    if (-not $runId -or -not $typeName) { return $null }
    $checkId = ([string](& $get 'checkId' '')).Trim()
    if ($typeName -eq 'Check' -and -not $checkId) { return $null }

    $seq = $null
    $seqRaw = & $get 'seq' $null
    if ($null -ne $seqRaw) {
        $parsed = [long]0
        if ([long]::TryParse(([string]$seqRaw).Trim(), [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$parsed)) { $seq = $parsed }
    }
    $schema = 1
    $schemaRaw = & $get 'schema' 1
    $schemaParsed = [int]0
    if ([int]::TryParse(([string]$schemaRaw).Trim(), [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$schemaParsed)) { $schema = $schemaParsed }

    $when = ConvertTo-AzlSonarUtcDate (& $get 'ts' '')
    $blocking = $true
    $blockingRaw = & $get 'blocking' $true
    if ($blockingRaw -is [bool]) { $blocking = $blockingRaw }
    elseif ("$blockingRaw" -match '^(?i:false|0|no)$') { $blocking = $false }

    $counts = [ordered]@{}
    $countsRaw = & $get 'counts' $null
    if ($countsRaw -is [System.Collections.IDictionary]) {
        foreach ($k in $countsRaw.Keys) {
            $n = [long]0
            if ([long]::TryParse(([string]$countsRaw[$k]).Trim(), [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$n)) { $counts[(Get-AzlSonarVerifyStatusName -Value ([string]$k))] = $n }
        }
    }
    # PowerShell 7 turns an ISO string into a DateTime while it parses the line: keep the time, written the same way every time.
    $expiresRaw = & $get 'expiresUtc' ''
    $expires = ConvertTo-AzlSonarUtcDate $expiresRaw
    $expiresText = if ($null -ne $expires) { $expires.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [cultureinfo]::InvariantCulture) } else { ([string]$expiresRaw).Trim() }
    $verdictRaw = ([string](& $get 'verdict' '')).Trim()
    $verdict = switch ($verdictRaw.ToLowerInvariant()) { 'pass' { 'Pass' } 'fail' { 'Fail' } default { $verdictRaw } }

    return @{
        schema     = $schema
        runId      = $runId
        seq        = $seq
        when       = $when
        timestamp  = $(if ($when) { $when.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) } else { '' })
        type       = $typeName
        checkId    = $checkId
        category   = ([string](& $get 'category' '')).Trim().ToLowerInvariant()
        title      = [string](& $get 'title' '')
        status     = Get-AzlSonarVerifyStatusName -Value ([string](& $get 'status' ''))
        node       = ([string](& $get 'node' '')).Trim()
        message    = [string](& $get 'message' '')
        remedy     = [string](& $get 'remedy' '')
        source     = [string](& $get 'source' '')
        blocking   = $blocking
        verdict    = $verdict
        counts     = $counts
        fileHash   = [string](& $get 'fileHash' '')
        expiresUtc = $expiresText
        expires    = $expires
    }
}

function ConvertFrom-AzlSonarVerificationEvent {
    <#
    .SYNOPSIS
        One event line of the verification file as a log line { file, text }, or $null when the line is not an event.
    .DESCRIPTION
        The text starts with the event's own UTC timestamp, so the log pane orders it by event time, then
        "[verify] <node|*> <Type> <Status> (<checkId>): <message> -> next: <remedy>", and ends with a level word (error,
        warning) the pane colours by. Failed is an error; Skipped and Warning are warnings.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    $e = ConvertFrom-AzlSonarVerificationLine -Line $Line
    if ($null -eq $e) { return $null }
    $prefix = if ($e.when) { $e.timestamp + ' ' } else { '' }
    $node = if ($e.node) { $e.node } else { '*' }
    $text = "${prefix}[verify] $node $($e.type)"
    switch ($e.type) {
        'Check' {
            $text += " $($e.status) ($($e.checkId))"
            $detail = if ($e.message) { $e.message } else { $e.title }
            if ($detail) { $text += ": $detail" }
            if ($e.remedy -and $e.status -notin 'Passed', 'Fixed', 'NotApplicable') { $text += " -> next: $($e.remedy)" }
            if ($e.status -eq 'Failed' -and $text -notmatch '(?i)\b(error|failed|fatal|exception)\b') { $text += ' (error)' }
            elseif ($e.status -in 'Skipped', 'Warning' -and $text -notmatch '(?i)\bwarn(ing)?\b') { $text += ' (warning)' }
        }
        'RunCompleted' {
            if ($e.verdict) { $text += " $($e.verdict)" }
            if ($e.verdict -eq 'Fail' -and $text -notmatch '(?i)\b(error|failed|fatal|exception)\b') { $text += ' (error)' }
        }
    }
    return @{ file = $script:AzlSonarVerifyEventFile; text = $text }
}

function Resolve-AzlSonarVerificationEventFile {
    <#
    .SYNOPSIS
        The event file verificationEventsPath names: the file itself, or precluster-verification-events.jsonl inside it when
        it is a folder (or a path that does not exist yet and has no extension). '' when nothing is configured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (Test-Path -LiteralPath $Path -PathType Container) { return (Join-Path -Path $Path -ChildPath $script:AzlSonarVerifyFileName) }
    if (-not (Test-Path -LiteralPath $Path) -and -not [System.IO.Path]::HasExtension($Path)) { return (Join-Path -Path $Path -ChildPath $script:AzlSonarVerifyFileName) }
    return $Path
}

function Read-AzlSonarVerificationEventFile {
    <#
    .SYNOPSIS
        All the lines of the verification event file. Returns { Lines, Found, Length, Stamp }.
    .DESCRIPTION
        Opened with FileShare ReadWrite (the gate may still be writing). A missing file is Found = $false with no lines,
        never an error. A last line the gate has not finished is not JSON and is skipped by the parser. A file larger than
        8 MB is read from its last 8 MB. Stamp is the length and the last write time, to tell whether it changed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $empty = @{ Lines = @(); Found = $false; Length = [long]0; Stamp = '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        $length = $stream.Length
        $start = [long][math]::Max(0, $length - $script:AzlSonarVerifyMaxBytes)
        $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new([int]($length - $start))
        $read = 0
        while ($read -lt $buffer.Length) {
            $n = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $lines = @($text -split "`r?`n")
        if ($start -gt 0 -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
        $stamp = "$length|$((Get-Item -LiteralPath $Path).LastWriteTimeUtc.Ticks)"
        return @{ Lines = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }); Found = $true; Length = [long]$length; Stamp = $stamp }
    }
    catch { return $empty }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

# ---------------------------------------------------------------------------------------------------------------------
# The store
# ---------------------------------------------------------------------------------------------------------------------

function Copy-AzlSonarVerifyTable {
    # A shallow copy of a hashtable (null gives an empty one).
    param([AllowNull()][System.Collections.IDictionary]$Table)
    $c = @{}
    if ($null -ne $Table) { foreach ($k in $Table.Keys) { $c[$k] = $Table[$k] } }
    return $c
}

function New-AzlSonarVerifyRun {
    # A fresh run entry for the run $RunId that starts at $Evt.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Evt, [string[]]$Runs = @(), [int]$Stale = 0)
    return @{
        RunId = [string]$Evt.runId; Runs = [string[]]@($Runs); Stale = $Stale; Events = 0
        Started = [string]$Evt.timestamp; StartedAt = $Evt.when; LastEventAt = [string]$Evt.timestamp; Schema = [int]$Evt.schema
        Seq = $null; Checks = @{}; Order = [string[]]@()
        Completed = $null; Verdict = ''; Counts = $null; FileHash = ''; ExpiresUtc = ''; Expires = $null
    }
}

function Add-AzlSonarVerificationEvent {
    <#
    .SYNOPSIS
        Records one event line in the verification store (the run entry '*').
    .DESCRIPTION
        A line of the current run is applied; a line of a new run starts that run (the old checks go); a line of a run that was
        seen before and is no longer current, or of an unseen run older than the current run's start, is stale: ignored and
        counted. A Check replaces the row of its checkId and node when its seq is higher than the held one (file order when
        either has none); RunCompleted records the verdict, the counts the gate reported, the file hash and the expiry.
        Each change stores a new object: the poller never reads one being written. Lines that are not events are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Store,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    $e = ConvertFrom-AzlSonarVerificationLine -Line $Line
    if ($null -eq $e) { return }
    $key = $script:AzlSonarVerifyRunKey
    $run = if ($Store.Contains($key) -and $null -ne $Store[$key]) { $Store[$key] } else { $null }
    $current = if ($null -ne $run) { [string]$run['RunId'] } else { '' }
    $seen = if ($null -ne $run) { @($run['Runs']) } else { @() }
    $stale = if ($null -ne $run) { [int]$run['Stale'] } else { 0 }

    if ($e.runId -ne $current) {
        $startedAt = if ($null -ne $run) { $run['StartedAt'] } else { $null }
        $older = $seen -contains $e.runId -or ($current -and $null -ne $startedAt -and $null -ne $e.when -and $e.when -lt $startedAt)
        if ($older) {
            $entry = Copy-AzlSonarVerifyTable $run
            $entry['Stale'] = $stale + 1
            if ($seen -notcontains $e.runId) { $entry['Runs'] = [string[]]@(@($seen) + $e.runId | Select-Object -Last $script:AzlSonarVerifyMaxRuns) }
            $Store[$key] = $entry
            return
        }
        $run = New-AzlSonarVerifyRun -Evt $e -Runs @(@($seen) + $e.runId | Select-Object -Last $script:AzlSonarVerifyMaxRuns) -Stale $stale
    }

    $new = Copy-AzlSonarVerifyTable $run
    $new['Events'] = [int]$new['Events'] + 1
    if ($e.timestamp) { $new['LastEventAt'] = $e.timestamp }
    if ($null -ne $e.seq) { $top = if ($null -ne $new['Seq']) { [long]$new['Seq'] } else { [long]::MinValue }; $new['Seq'] = [long][math]::Max($top, [long]$e.seq) }

    switch ($e.type) {
        'RunStarted' {
            if ($e.timestamp) { $new['Started'] = $e.timestamp; $new['StartedAt'] = $e.when }
            $new['Schema'] = [int]$e.schema
        }
        'Check' {
            $checkKey = ($e.checkId + '|' + $e.node).ToLowerInvariant()
            $checks = Copy-AzlSonarVerifyTable $new['Checks']
            $held = if ($checks.ContainsKey($checkKey)) { $checks[$checkKey] } else { $null }
            if ($null -ne $held -and $null -ne $held['Seq'] -and $null -ne $e.seq -and [long]$e.seq -le [long]$held['Seq']) {
                # An older or repeated line of this check: the held one stays.
                $Store[$key] = $new
                return
            }
            if ($null -eq $held -and $checks.Count -ge $script:AzlSonarVerifyMaxChecks) { $Store[$key] = $new; return }
            $checks[$checkKey] = @{
                CheckId = $e.checkId; Category = $e.category; Title = $e.title; Status = $e.status; Node = $e.node; Message = $e.message
                Remedy = $e.remedy; Source = $e.source; Blocking = [bool]$e.blocking; Seq = $e.seq; At = $e.timestamp
            }
            $new['Checks'] = $checks
            if ($null -eq $held) { $new['Order'] = [string[]]@(@($new['Order']) + $checkKey) }
        }
        'RunCompleted' {
            $new['Completed'] = $e.timestamp
            $new['Verdict'] = [string]$e.verdict
            $new['Counts'] = $e.counts
            $new['FileHash'] = $e.fileHash
            $new['ExpiresUtc'] = $e.expiresUtc
            $new['Expires'] = $e.expires
        }
    }
    $Store[$key] = $new
}

function Update-AzlSonarVerificationInfo {
    <#
    .SYNOPSIS
        Counts the event lines read and keeps the newest event time, for the page's Details (/api/details).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory counter only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Info,

        [AllowEmptyCollection()]
        [string[]]$Line = @()
    )

    foreach ($raw in $Line) {
        $e = ConvertFrom-AzlSonarVerificationLine -Line $raw
        if ($null -eq $e) { continue }
        $Info['Count'] = [long]$Info['Count'] + 1
        $when = $e.when
        if ($null -eq $when) { $when = [datetime]::UtcNow }
        $current = ConvertTo-AzlSonarUtcDate $Info['LastEventAt']
        if ($null -eq $current -or $when -gt $current) { $Info['LastEventAt'] = Format-AzlSonarDate $when }
    }
}

function Invoke-AzlSonarVerificationEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the verification event file, adds each new event to the log pane and rebuilds the store from
        the whole file whenever it changes, until the stop flag is set.
    .DESCRIPTION
        The file is small, so the run entry is rebuilt from all its lines on every change: a file the gate replaced, emptied
        or rewrote for a new run is shown as it is now, and nothing of a run that is gone stays. The log pane gets only the
        lines it has not had (all of them again when the file is a different one). A missing file or folder is not an error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [object]$Config,

        [double]$PollSeconds = 2
    )

    $configured = [string](Get-AzlSonarMember $Config 'verificationEventsPath' '')
    if (-not $configured) { return }
    $stamp = $null
    $head = $null
    $emitted = 0
    while (-not $Shared.Stop) {
        try {
            $path = Resolve-AzlSonarVerificationEventFile -Path $configured
            $file = Read-AzlSonarVerificationEventFile -Path $path
            if ("$($file.Found)|$($file.Stamp)" -ne $stamp) {
                $stamp = "$($file.Found)|$($file.Stamp)"
                $lines = @($file.Lines)
                $first = if ($lines.Count -gt 0) { [string]$lines[0] } else { '' }
                if ($first -ne $head -or $lines.Count -lt $emitted) {
                    # A different file (or an emptied one): the log pane starts over for it.
                    $emitted = 0
                    if ($Shared.Contains('VerificationInfo')) { $Shared['VerificationInfo']['Count'] = [long]0; $Shared['VerificationInfo']['LastEventAt'] = $null }
                }
                $head = $first
                $fresh = @($lines | Select-Object -Skip $emitted)
                $emitted = $lines.Count
                $logLines = foreach ($raw in $fresh) { ConvertFrom-AzlSonarVerificationEvent -Line $raw }
                if (@($logLines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($logLines) }
                if ($Shared.Contains('VerificationInfo')) { Update-AzlSonarVerificationInfo -Info $Shared['VerificationInfo'] -Line $fresh }
                if ($Shared.Contains('VerificationEvents')) {
                    $built = @{}
                    foreach ($raw in $lines) { Add-AzlSonarVerificationEvent -Store $built -Line $raw }
                    $target = $Shared['VerificationEvents']
                    if ($built.ContainsKey($script:AzlSonarVerifyRunKey)) { $target[$script:AzlSonarVerifyRunKey] = $built[$script:AzlSonarVerifyRunKey] }
                    else { $target.Remove($script:AzlSonarVerifyRunKey) }
                }
            }
        }
        catch { Write-Verbose "Verification event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The state: the verification object of /api/state
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSonarVerificationRank {
    # The sort rank of a status word: failed first, then skipped, running, warning, fixed, passed, not applicable; a word the
    # contract does not name sits with the warnings.
    param([string]$Status)
    $k = $Status.ToLowerInvariant() -replace '[\s_-]', ''
    if ($script:AzlSonarVerifyStatus.Contains($k)) { return [int]$script:AzlSonarVerifyStatus[$k].Rank }
    return 3
}

function Get-AzlSonarVerificationCheck {
    <#
    .SYNOPSIS
        One check of the store as the page shows it, with whether it blocks the gate.
    .DESCRIPTION
        blocks: Skipped always (the gate could not check it, so it cannot pass), Failed when the gate marked it blocking
        (a missing flag counts as blocking), Running when the run is already complete (it never finished). sourceUrl is set
        only for an http or https source, so the page links nothing else.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Check, [bool]$RunComplete)

    $status = [string]$Check.Status
    $blocks = switch ($status) {
        'Skipped' { $true }
        'Failed' { [bool]$Check.Blocking }
        'Running' { [bool]($RunComplete -and $Check.Blocking) }
        default { $false }
    }
    $source = Protect-AzlSonarText -Text ([string]$Check.Source)
    $sourceUrl = ''
    if ($source -match '^\s*(https?://[^\s<>"'']+)\s*$') {
        $uri = $null
        if ([uri]::TryCreate($Matches[1], [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in 'http', 'https') { $sourceUrl = $uri.AbsoluteUri }
    }
    $title = Protect-AzlSonarText -Text ([string]$Check.Title)
    return [ordered]@{
        id        = [string]$Check.CheckId
        title     = $(if ($title) { $title } else { [string]$Check.CheckId })
        category  = [string]$Check.Category
        status    = $status
        node      = [string]$Check.Node
        message   = Protect-AzlSonarText -Text ([string]$Check.Message)
        remedy    = Protect-AzlSonarText -Text ([string]$Check.Remedy)
        source    = $source
        sourceUrl = $sourceUrl
        blocking  = [bool]$Check.Blocking
        blocks    = [bool]$blocks
        seq       = $Check.Seq
        at        = [string]$Check.At
    }
}

function Get-AzlSonarVerificationState {
    <#
    .SYNOPSIS
        The verification object of /api/state, from the verification event store: the verdict, the counts and the checks.
    .DESCRIPTION
        { configured, hasData, status (notstarted|running|pass|fail|expired), verdict ('' | Pass | Fail, the gate's own word),
        word, run{runId, started, completed, lastEventAt, events, stale, schema, fileHash, expiresUtc, expiresInSeconds},
        counts{Passed, Failed, Warning, Skipped, NotApplicable, Fixed, Running, ...}, total, reportedCounts, countsMismatch,
        blockers (checks that block), skippedBlocking, categories[{id, name, status, counts, checks[]}] (known order; failed
        checks first inside a category), attention[] (the blocking checks), warnings[], guide }.
        Running: the run has no RunCompleted line. Pass with expiresUtc in the past: expired. A Pass verdict while a check
        blocks is shown as fail (the verdict and the checks disagree: the gate is never shown green by accident).
    .PARAMETER Store
        Shared.VerificationEvents (Add-AzlSonarVerificationEvent).
    .PARAMETER Config
        A config object; verificationEventsPath says whether the event file is followed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Store,

        [Parameter(Mandatory)]
        [object]$Config,

        [datetime]$Now = [datetime]::UtcNow
    )

    $configured = [bool][string](Get-AzlSonarMember $Config 'verificationEventsPath' '')
    $run = $null
    if ($null -ne $Store -and $Store.Contains($script:AzlSonarVerifyRunKey)) { $run = $Store[$script:AzlSonarVerifyRunKey] }
    $hasData = $null -ne $run
    $complete = [bool]($hasData -and $null -ne $run['Completed'])
    $warnings = [System.Collections.Generic.List[string]]::new()

    $checks = [System.Collections.Generic.List[object]]::new()
    if ($hasData) {
        foreach ($k in @($run['Order'])) {
            if ($run['Checks'].ContainsKey($k)) { $checks.Add((Get-AzlSonarVerificationCheck -Check $run['Checks'][$k] -RunComplete $complete)) }
        }
    }

    $counts = [ordered]@{}
    foreach ($def in $script:AzlSonarVerifyStatus.Values) { $counts[[string]$def.Name] = 0 }
    foreach ($c in $checks) { if (-not $counts.Contains($c.status)) { $counts[$c.status] = 0 }; $counts[$c.status] = [int]$counts[$c.status] + 1 }
    $blockers = @($checks | Where-Object { $_.blocks })
    $skippedBlocking = @($blockers | Where-Object { $_.status -eq 'Skipped' }).Count

    # What the gate counted, when it said: shown beside what Sonar counted, and a difference is a warning.
    $reported = [ordered]@{}
    $mismatch = $false
    if ($hasData -and $complete -and $run['Counts'] -is [System.Collections.IDictionary]) {
        foreach ($k in $run['Counts'].Keys) { $reported[[string]$k] = [int]$run['Counts'][$k] }
        foreach ($k in $reported.Keys) {
            $mine = if ($counts.Contains($k)) { [int]$counts[$k] } else { 0 }
            if ($mine -ne [int]$reported[$k]) { $mismatch = $true }
        }
        foreach ($k in $counts.Keys) { if ([int]$counts[$k] -gt 0 -and -not $reported.Contains($k)) { $mismatch = $true } }
        if ($mismatch) { $warnings.Add('The gate reported different counts than the checks Sonar read (a line may be missing from the file).') }
    }

    $status = 'notstarted'
    $verdict = ''
    $expiresIn = $null
    if ($hasData) {
        $verdict = [string]$run['Verdict']
        if (-not $complete) { $status = 'running' }
        elseif ($verdict -eq 'Pass') {
            if ($blockers.Count -gt 0) {
                $status = 'fail'
                $warnings.Add("The gate wrote verdict Pass, but $($blockers.Count) check(s) still block it ($(@($blockers | Select-Object -First 3 | ForEach-Object { $_.id }) -join ', ')); Sonar shows the checks, not the verdict.")
            }
            else {
                $status = 'pass'
                if ($null -ne $run['Expires']) {
                    $expiresIn = [math]::Floor(($run['Expires'] - $Now).TotalSeconds)
                    if ($expiresIn -le 0) { $status = 'expired' }
                }
                elseif ($run['ExpiresUtc']) { $warnings.Add('The expiry time in the file could not be read; the verdict is shown as written.') }
            }
        }
        elseif ($verdict -eq 'Fail') { $status = 'fail' }
        else { $status = 'fail'; $warnings.Add("The gate wrote no usable verdict ('$verdict'); the run is shown as Fail.") }
        if ($status -eq 'fail' -and $null -ne $run['Expires'] -and $null -eq $expiresIn) { $expiresIn = [math]::Floor(($run['Expires'] - $Now).TotalSeconds) }
        if ($complete -and @($checks | Where-Object { $_.status -eq 'Running' }).Count -gt 0) { $warnings.Add('The run is complete but some checks never finished (still Running).') }
        if ([int]$run['Stale'] -gt 0) { $warnings.Add("Ignored $([int]$run['Stale']) line(s) of an older run.") }
        if ([int]$run['Schema'] -gt 1) { $warnings.Add("The file uses schema $([int]$run['Schema']); Sonar reads the fields it knows.") }
    }

    $word = switch ($status) { 'running' { 'running' } 'pass' { 'pass' } 'fail' { 'fail' } 'expired' { 'expired' } default { 'waiting' } }

    # Categories: the known ones in their order, then any other the file names; failed checks first inside each.
    $byCategory = [ordered]@{}
    foreach ($id in $script:AzlSonarVerifyCategory.Keys) { $byCategory[[string]$id] = [System.Collections.Generic.List[object]]::new() }
    foreach ($c in $checks) {
        $id = if ($c.category) { [string]$c.category } else { 'other' }
        if (-not $byCategory.Contains($id)) { $byCategory[$id] = [System.Collections.Generic.List[object]]::new() }
        $byCategory[$id].Add($c)
    }
    $categories = foreach ($id in $byCategory.Keys) {
        $list = @($byCategory[$id] | Sort-Object -Property @{ Expression = { Get-AzlSonarVerificationRank -Status $_.status } }, @{ Expression = { $_.title } }, @{ Expression = { $_.node } })
        if ($list.Count -eq 0) { continue }
        $cc = [ordered]@{}
        foreach ($c in $list) { if (-not $cc.Contains($c.status)) { $cc[$c.status] = 0 }; $cc[$c.status] = [int]$cc[$c.status] + 1 }
        $name = if ($script:AzlSonarVerifyCategory.Contains($id)) { [string]$script:AzlSonarVerifyCategory[$id] } elseif ($id -eq 'other') { 'Other' } else { (Get-Culture).TextInfo.ToTitleCase($id) }
        [ordered]@{ id = $id; name = $name; status = [string]$list[0].status; blocks = [bool](@($list | Where-Object { $_.blocks }).Count -gt 0); counts = $cc; checks = $list }
    }
    # Failed categories first, in the known order otherwise.
    $categories = @($categories | Sort-Object -Property @{ Expression = { if ($_.blocks) { 0 } else { 1 } } }, @{ Expression = { $i = @($byCategory.Keys).IndexOf($_.id); $i } })

    $attention = @($blockers | Sort-Object -Property @{ Expression = { Get-AzlSonarVerificationRank -Status $_.status } }, @{ Expression = { $_.category } }, @{ Expression = { $_.title } } | Select-Object -First $script:AzlSonarVerifyMaxAttention)

    return [ordered]@{
        configured      = $configured
        hasData         = [bool]$hasData
        status          = $status
        state           = $word
        verdict         = $verdict
        run             = [ordered]@{
            runId           = $(if ($hasData) { [string]$run['RunId'] } else { '' })
            started         = $(if ($hasData) { [string]$run['Started'] } else { $null })
            completed       = $(if ($complete) { [string]$run['Completed'] } else { $null })
            lastEventAt     = $(if ($hasData) { [string]$run['LastEventAt'] } else { $null })
            events          = $(if ($hasData) { [int]$run['Events'] } else { 0 })
            stale           = $(if ($hasData) { [int]$run['Stale'] } else { 0 })
            schema          = $(if ($hasData) { [int]$run['Schema'] } else { 1 })
            fileHash        = $(if ($hasData) { [string]$run['FileHash'] } else { '' })
            expiresUtc      = $(if ($hasData) { [string]$run['ExpiresUtc'] } else { '' })
            expiresInSeconds = $expiresIn
        }
        counts          = $counts
        total           = $checks.Count
        reportedCounts  = $(if ($reported.Count -gt 0) { $reported } else { $null })
        countsMismatch  = [bool]$mismatch
        blockers        = $blockers.Count
        skippedBlocking = $skippedBlocking
        categories      = @($categories)
        attention       = $attention
        warnings        = $warnings.ToArray()
        guide           = $script:AzlSonarVerifyGuide
    }
}
