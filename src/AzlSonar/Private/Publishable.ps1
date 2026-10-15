Set-StrictMode -Version Latest

# Publishable recordings (hardening 2610, gap 1).
#
# A normal recording masks secrets only. A publishable recording also replaces every identifier with a stable
# pseudonym: the same original value always gets the same token inside one recording, structure, timestamps, step
# names and durations stay as they were, so a replay behaves the same.
#
# The detectors and the pseudonym maps live in Pseudonymizer.cs (compiled once with Add-Type: a real recording is
# 100+ MB and the PowerShell version of the same logic needed hours). This file is the PowerShell surface: the
# state object, line and file conversion, verification and the export.
#
# Token formats (documented in docs/reference/publishable-recordings.md):
#   GUID          00000000-0000-0000-0000-000000000001       (32 hex without dashes: 31 zeros and a counter; 40 hex: same idea)
#   IPv4          192.0.2.x, then 198.51.100.x, then 203.0.113.x, then 198.18.x.x (documentation ranges)
#   IPv6          2001:db8::N
#   MAC           00-00-5e-00-53-NN (the RFC 7042 documentation range; separator and letter case are kept)
#   subscription  sub-0001   (a subscription name; a subscription id is a GUID)
#   resource grp  rg-01      cluster cluster-01   node node-01   Arc machine arc-01   host host-01
#   user / UPN    user-01  user-01@dom-01.example.test       account DOM\user -> DOM01\user-01
#   domain        dom-01.example.test                         other named resource res-01
#   Windows SID   S-1-5-21-1000000001-2000000001-3000000001-<RID kept>
#
# Verification: after writing, the whole output is read again and checked with the same detector set (plus every
# learned term and every -ExtraTerm); one surviving original identifier means the file is not written.

function Initialize-AzlSonarPseudonymizerType {
    <#
    .SYNOPSIS
        Compiles Pseudonymizer.cs once per session.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Compiles an in-memory type only.')]
    [CmdletBinding()]
    param()

    if ('AzlSonar.Pseudonymizer' -as [type]) { return }
    $source = Join-Path -Path $PSScriptRoot -ChildPath 'Pseudonymizer.cs'
    Add-Type -Path $source -ErrorAction Stop
}

function New-AzlSonarPseudonymizer {
    <#
    .SYNOPSIS
        A new pseudonymiser for one recording: token maps, learned terms and counters.
    .PARAMETER ExtraTerm
        Additional strings that must never survive (for example a company name); each is replaced and checked.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory state only.')]
    [CmdletBinding()]
    [OutputType([object])]
    param([string[]]$ExtraTerm = @())

    Initialize-AzlSonarPseudonymizerType
    return [AzlSonar.Pseudonymizer]::new([string[]]@($ExtraTerm))
}

function Get-AzlSonarPseudonym {
    <#
    .SYNOPSIS
        The stable token for an original value of a category (allocated on first use).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Value
    )

    return $State.Pseudo($Category, $Value)
}

function Register-AzlSonarPublishableTerm {
    <#
    .SYNOPSIS
        Registers a value (a node name, a domain, a user ...) so every later bare mention is replaced as well.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory state only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$Category,
        [AllowNull()][string]$Value
    )

    $State.RegisterTerm($Category, $Value)
}

function Protect-AzlSonarPublishableText {
    <#
    .SYNOPSIS
        Replaces every identifier in a string with its stable pseudonym (see the token formats at the top of this file).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][object]$State
    )

    return $State.Protect($Text)
}

function Find-AzlSonarPublishableIdentifier {
    <#
    .SYNOPSIS
        The categories of original identifiers still in a string (one entry per finding; never the values).
    .DESCRIPTION
        Uses the same detector set as the pseudonymiser, plus the learned terms. Read-only: learns nothing.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][object]$State
    )

    return , [string[]]$State.Find($Text)
}

function Register-AzlSonarPublishableConfig {
    <#
    .SYNOPSIS
        Learns the names in the parsed Sonar config (cluster, resource group, nodes, their addresses and Arc names) before a live recording starts.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory state only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [AllowNull()][object]$Config
    )

    if ($null -eq $Config) { return }
    foreach ($pair in @(@('clusterName', 'cluster'), @('cluster', 'cluster'), @('resourceGroup', 'rg'), @('seedNode', 'node'))) {
        $v = [string](Get-AzlSonarMember $Config $pair[0] '')
        if ($v) { $State.RegisterTerm($pair[1], $v) }
    }
    foreach ($n in @(Get-AzlSonarMember $Config 'nodes' @())) {
        foreach ($pair in @(@('name', 'node'), @('arcMachineName', 'arc'), @('address', 'host'))) {
            $v = [string](Get-AzlSonarMember $n $pair[0] '')
            if (-not $v -or $v -match '^[0-9.:]+$') { continue }
            if ($v.Contains('.')) { $null = $State.DomainToken($v) }
            else { $State.RegisterTerm($pair[1], $v) }
        }
    }
}

function Convert-AzlSonarPublishableLine {
    <#
    .SYNOPSIS
        Rewrites one recording line (JSON text) into its publishable form; returns the new line ($null for a line that is not a JSON object).
    .PARAMETER MaxLogTextLength
        Log lines longer than this many characters are cut (0 keeps them whole) before scrubbing; a marker says how much was cut.
    .PARAMETER MaxInfoLinesPerEvent
        At most this many info lines are kept per log event, spread evenly through it (0 keeps all); warning and error lines are always kept.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][object]$State,
        [int]$MaxLogTextLength = 0,
        [int]$MaxInfoLinesPerEvent = 0,
        [switch]$LearnOnly
    )

    return $State.ConvertLine($Line, $MaxLogTextLength, $MaxInfoLinesPerEvent, [bool]$LearnOnly)
}

function Open-AzlSonarRecordingReader {
    [CmdletBinding()]
    [OutputType([System.IO.StreamReader])]
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 1048576)
    $source = $stream
    if ($Path.EndsWith('.gz', [System.StringComparison]::OrdinalIgnoreCase)) {
        $source = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Decompress)
    }
    return [System.IO.StreamReader]::new($source, [System.Text.UTF8Encoding]::new($false), $false, 1048576)
}

function Test-AzlSonarPublishableRecording {
    <#
    .SYNOPSIS
        Scans a recording (.jsonl or .jsonl.gz) with the identifier detectors and returns the number of surviving
        original identifiers per category. All zero means nothing a detector knows about is left.
    .PARAMETER ExtraTerm
        Strings that must not appear anywhere (case-insensitive).
    .OUTPUTS
        PSCustomObject: Path, Lines, Total, ByCategory (ordered; every detector category, zero included), Clean.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExtraTerm = @(),
        [object]$State
    )

    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not [System.IO.File]::Exists($full)) { throw "Recording not found: $full" }
    if (-not $State) { $State = New-AzlSonarPseudonymizer -ExtraTerm $ExtraTerm }
    $found = [System.Collections.Generic.Dictionary[string, int]]::new()
    $reader = Open-AzlSonarRecordingReader -Path $full
    $lines = 0
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $lines++
            $State.FindLine($line, $found)
        }
    }
    finally { $reader.Dispose() }
    $counts = [ordered]@{}
    foreach ($name in $State.DetectorNames()) { $counts[$name] = 0 }
    $total = 0
    foreach ($pair in $found.GetEnumerator()) { $counts[$pair.Key] = $pair.Value; $total += $pair.Value }
    return [pscustomobject]@{ Path = $full; Lines = $lines; Total = $total; ByCategory = $counts; Clean = ($total -eq 0) }
}

function Export-AzlSonarPublishableRecording {
    <#
    .SYNOPSIS
        Rewrites a recording into a publishable one: every identifier replaced by a stable pseudonym, then verified.
    .DESCRIPTION
        Reads -Path (.jsonl or .jsonl.gz), learns the names in it (pass 1), writes the pseudonymised copy to
        -Destination (gzip when it ends in .gz) and reads the copy back with the detector set plus -ExtraTerm (pass 3).
        When anything still matches, or the file is larger than -MaxBytes, nothing is left at -Destination and the
        function throws (counts per category, never the values). The source file is never changed.
    .PARAMETER MaxLogTextLength
        Cut log lines longer than this many characters (0 = keep whole), at a word boundary and before scrubbing.
        Large recordings are dominated by a few very long lines.
    .PARAMETER MaxInfoLinesPerEvent
        Keep at most this many info lines per log event (0 = all); warning and error lines are always kept. A replay of a
        recording with 200,000 log lines needs hundreds of MB; a few dozen info lines per event keep the run readable and light.
    .PARAMETER MaxIdleSeconds
        Close gaps between events longer than this (0 = keep): the page replays faster; step times inside the state are untouched.
    .PARAMETER MaxBytes
        Refuse to keep a destination larger than this (0 = no limit).
    .OUTPUTS
        PSCustomObject: Source, Destination, Lines, BytesIn, BytesOut, Replaced (by category), Distinct (by category), Verification.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the destination file the caller named; the source is only read.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExtraTerm = @(),
        [ValidateRange(0, 10000000)][int]$MaxLogTextLength = 0,
        [ValidateRange(0, 100000)][int]$MaxInfoLinesPerEvent = 0,
        [ValidateRange(0, 86400)][double]$MaxIdleSeconds = 0,
        [long]$MaxBytes = 0,
        [switch]$Force
    )

    $src = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dst = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    if (-not [System.IO.File]::Exists($src)) { throw "Recording not found: $src" }
    if ([string]::Equals($src, $dst, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'The destination must be a different file than the source.' }
    if ([System.IO.File]::Exists($dst) -and -not $Force) { throw "The destination exists: $dst. Use -Force to replace it." }
    $folder = [System.IO.Path]::GetDirectoryName($dst)
    if ($folder -and -not [System.IO.Directory]::Exists($folder)) { $null = [System.IO.Directory]::CreateDirectory($folder) }
    $tmp = $dst + '.partial'

    $state = New-AzlSonarPseudonymizer -ExtraTerm $ExtraTerm

    # Pass 1: learn every name (output discarded), so a name learned late is also replaced where it showed up first.
    $reader = Open-AzlSonarRecordingReader -Path $src
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $null = Convert-AzlSonarPublishableLine -Line $line -State $state -MaxLogTextLength $MaxLogTextLength -MaxInfoLinesPerEvent $MaxInfoLinesPerEvent -LearnOnly
        }
    }
    finally { $reader.Dispose() }
    $state.Replaced.Clear()

    # Pass 2: write.
    $lines = 0
    $reader = Open-AzlSonarRecordingReader -Path $src
    $fileStream = [System.IO.FileStream]::new($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576)
    $sink = $fileStream
    if ($dst.EndsWith('.gz', [System.StringComparison]::OrdinalIgnoreCase)) {
        $sink = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionLevel]::SmallestSize)
    }
    $writer = [System.IO.StreamWriter]::new($sink, [System.Text.UTF8Encoding]::new($false), 1048576)
    $writer.NewLine = "`n"
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $shift = [timespan]::Zero
    $previous = $null
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $new = Convert-AzlSonarPublishableLine -Line $line -State $state -MaxLogTextLength $MaxLogTextLength -MaxInfoLinesPerEvent $MaxInfoLinesPerEvent
            if (-not $new) { continue }
            # Every line starts {"t":"<time>": shift the time without parsing the line again.
            if ($MaxIdleSeconds -gt 0) {
                $head = [regex]::Match($new, '^\{"t":"(?<t>[^"]+)"')
                $t = [datetime]::MinValue
                if ($head.Success -and [datetime]::TryParse($head.Groups['t'].Value, $culture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$t)) {
                    if ($null -ne $previous -and ($t - $previous).TotalSeconds -gt $MaxIdleSeconds) { $shift += ($t - $previous) - [timespan]::FromSeconds($MaxIdleSeconds) }
                    $previous = $t
                    $new = '{"t":"' + ($t - $shift).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $culture) + $new.Substring($head.Length - 1)
                }
            }
            $writer.Write($new)
            $writer.Write("`n")
            $lines++
        }
        $writer.Flush()
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
    }

    # Pass 3: verify the file as written. Fail closed.
    $verify = $null
    try {
        $verify = Test-AzlSonarPublishableRecording -Path $tmp -ExtraTerm $ExtraTerm -State $state
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    $bytesOut = ([System.IO.FileInfo]::new($tmp)).Length
    if (-not $verify.Clean) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $detail = (@($verify.ByCategory.GetEnumerator() | Where-Object { $_.Value -gt 0 } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
        throw "Verification failed: $($verify.Total) original identifier(s) survive ($detail). Nothing was written to $dst. Add the missing names with -ExtraTerm and run again."
    }
    if ($MaxBytes -gt 0 -and $bytesOut -gt $MaxBytes) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "The publishable recording is $bytesOut bytes, over the limit of $MaxBytes. Nothing was written to $dst. Use -MaxLogTextLength (cut long log lines) or -MaxIdleSeconds."
    }
    if ([System.IO.File]::Exists($dst)) { Remove-Item -LiteralPath $dst -Force }
    [System.IO.File]::Move($tmp, $dst)
    $replaced = [ordered]@{}
    foreach ($k in ($state.Replaced.Keys | Sort-Object)) { $replaced[$k] = $state.Replaced[$k] }
    $distinct = [ordered]@{}
    foreach ($k in ($state.Distinct.Keys | Sort-Object)) { $distinct[$k] = $state.Distinct[$k] }
    return [pscustomobject]@{
        Source       = $src
        Destination  = $dst
        Lines        = $lines
        BytesIn      = ([System.IO.FileInfo]::new($src)).Length
        BytesOut     = $bytesOut
        Replaced     = $replaced
        Distinct     = $distinct
        Verification = $verify
    }
}
