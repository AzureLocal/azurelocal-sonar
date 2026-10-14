Set-StrictMode -Version Latest

# Record and replay (plan task S-11).
#
# A recording is JSON Lines (UTF-8, one event per line, append-only). Every event has t (UTC, when Sonar saw it) and
# k (kind):
#   session  { format, tool, version, server, cluster, config, guidance }   one per Sonar start (appending survives restarts)
#   state    { full: <state> } or { ops: [[op, path, value?], ...] }        the state the page gets, as a keyframe or a delta
#   tailer   { tailer: <status> }                                          the log tailer status
#   log      { lines: [<line>], lost? }                                     log lines (seq, time, received, timeSource, file, level, text)
#   end      { }                                                            Sonar stopped cleanly
# Delta ops: ["s", path, value] sets (object key or array index; index = length appends), ["d", path] deletes a key,
# ["t", path, length] truncates an array. A session starts with a keyframe; another keyframe follows once the deltas
# since the last one add up to its size (or after AzlSonarRecordingMaxDeltas deltas), so seeking applies at most about
# one keyframe's worth of deltas and the file stays within about twice the size of the deltas.
# Everything written is masked first (Protect-AzlSonarText on every string, plus the log credential and the Key Vault
# secret names as exact values). The public config carries no addresses, secret names or secrets.

$script:AzlSonarRecordingFormat = 1
$script:AzlSonarRecordingMaxDeltas = 200
$script:AzlSonarRecordingKinds = @('session', 'state', 'tailer', 'log', 'end')
$script:AzlSonarJsonRelaxed = $null

function Get-AzlSonarJsonWriteOption {
    <#
    .SYNOPSIS
        System.Text.Json options for recording lines: compact, relaxed escaping (log text stays readable).
    #>
    [CmdletBinding()]
    [OutputType([System.Text.Json.JsonSerializerOptions])]
    param()

    if ($null -eq $script:AzlSonarJsonRelaxed) {
        $options = [System.Text.Json.JsonSerializerOptions]::new()
        $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
        $options.WriteIndented = $false
        $script:AzlSonarJsonRelaxed = $options
    }
    return $script:AzlSonarJsonRelaxed
}

function New-AzlSonarNodeBox {
    <#
    .SYNOPSIS
        A one-element array holding a parsed JSON node. JsonObject and JsonArray are enumerable, so @($node) or plain
        output would unroll them; functions return nodes in this box and callers unwrap it with [0].
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory array only.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [object]$Node
    )

    $box = [object[]]::new(1)
    $box[0] = $Node
    return , $box
}

function ConvertTo-AzlSonarNodeJson {
    <#
    .SYNOPSIS
        A JsonNode (or $null) as compact JSON text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Node
    )

    if ($null -eq $Node) { return 'null' }
    return $Node.ToJsonString((Get-AzlSonarJsonWriteOption))
}

function Protect-AzlSonarJsonNode {
    <#
    .SYNOPSIS
        Masks secrets in every string value of a parsed JSON tree, in place (Protect-AzlSonarText per string).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Node,

        [string[]]$Secret = @()
    )

    if ($null -eq $Node) { return }
    if ($Node -is [System.Text.Json.Nodes.JsonObject]) {
        $keys = [string[]]@(foreach ($pair in $Node) { $pair.Key })
        foreach ($key in $keys) {
            $child = $Node[$key]
            if ($null -eq $child) { continue }
            if ($child -is [System.Text.Json.Nodes.JsonValue]) {
                if ($child.GetValueKind() -eq [System.Text.Json.JsonValueKind]::String) {
                    $text = $child.GetValue[string]()
                    $masked = Protect-AzlSonarText -Text $text -Secret $Secret
                    if ($masked -cne $text) { $Node[$key] = [System.Text.Json.Nodes.JsonValue]::Create($masked) }
                }
            }
            else {
                Protect-AzlSonarJsonNode -Node $child -Secret $Secret
            }
        }
        return
    }
    if ($Node -is [System.Text.Json.Nodes.JsonArray]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            $child = $Node[$i]
            if ($null -eq $child) { continue }
            if ($child -is [System.Text.Json.Nodes.JsonValue]) {
                if ($child.GetValueKind() -eq [System.Text.Json.JsonValueKind]::String) {
                    $text = $child.GetValue[string]()
                    $masked = Protect-AzlSonarText -Text $text -Secret $Secret
                    if ($masked -cne $text) { $Node[$i] = [System.Text.Json.Nodes.JsonValue]::Create($masked) }
                }
            }
            else {
                Protect-AzlSonarJsonNode -Node $child -Secret $Secret
            }
        }
    }
}

function ConvertTo-AzlSonarProtectedJson {
    <#
    .SYNOPSIS
        Parses JSON text, masks every string value and returns the parsed tree as a one-element array (unwrap with [0]).
    .DESCRIPTION
        The tree is returned inside an array because PowerShell would enumerate a JsonObject or JsonArray on output.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Json,

        [string[]]$Secret = @()
    )

    if ([string]::IsNullOrWhiteSpace($Json)) { return , [object[]]@($null) }
    $node = [System.Text.Json.Nodes.JsonNode]::Parse($Json)
    Protect-AzlSonarJsonNode -Node $node -Secret $Secret
    return , (New-AzlSonarNodeBox $node)
}

function ConvertTo-AzlSonarPathJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Path = @()
    )

    $parts = foreach ($segment in $Path) {
        if ($segment -is [int]) { [string]$segment }
        else { ConvertTo-AzlSonarNodeJson ([System.Text.Json.Nodes.JsonValue]::Create([string]$segment)) }
    }
    return '[' + (@($parts) -join ',') + ']'
}

function Compare-AzlSonarJsonNode {
    <#
    .SYNOPSIS
        Appends the delta ops that turn -Old into -New (both parsed JSON trees) to -Ops, as JSON text.
    .DESCRIPTION
        Objects are compared key by key, arrays index by index (extra items are set at index = length, missing items
        truncated); anything else that differs is set whole. Unchanged subtrees are skipped with JsonNode.DeepEquals.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Old,

        [AllowNull()]
        [object]$New,

        [AllowEmptyCollection()]
        [object[]]$Path = @(),

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Ops
    )

    if ([System.Text.Json.Nodes.JsonNode]::DeepEquals($Old, $New)) { return }
    if ($Old -is [System.Text.Json.Nodes.JsonObject] -and $New -is [System.Text.Json.Nodes.JsonObject]) {
        foreach ($pair in $New) {
            if ($Old.ContainsKey($pair.Key)) {
                Compare-AzlSonarJsonNode -Old $Old[$pair.Key] -New $pair.Value -Path ($Path + @($pair.Key)) -Ops $Ops
            }
            else {
                $Ops.Add('["s",' + (ConvertTo-AzlSonarPathJson ($Path + @($pair.Key))) + ',' + (ConvertTo-AzlSonarNodeJson $pair.Value) + ']')
            }
        }
        foreach ($pair in $Old) {
            if (-not $New.ContainsKey($pair.Key)) {
                $Ops.Add('["d",' + (ConvertTo-AzlSonarPathJson ($Path + @($pair.Key))) + ']')
            }
        }
        return
    }
    if ($Old -is [System.Text.Json.Nodes.JsonArray] -and $New -is [System.Text.Json.Nodes.JsonArray]) {
        $common = [Math]::Min($Old.Count, $New.Count)
        for ($i = 0; $i -lt $common; $i++) {
            Compare-AzlSonarJsonNode -Old $Old[$i] -New $New[$i] -Path ($Path + @([int]$i)) -Ops $Ops
        }
        for ($i = $common; $i -lt $New.Count; $i++) {
            $Ops.Add('["s",' + (ConvertTo-AzlSonarPathJson ($Path + @([int]$i))) + ',' + (ConvertTo-AzlSonarNodeJson $New[$i]) + ']')
        }
        if ($Old.Count -gt $New.Count) {
            $Ops.Add('["t",' + (ConvertTo-AzlSonarPathJson $Path) + ',' + $New.Count + ']')
        }
        return
    }
    $Ops.Add('["s",' + (ConvertTo-AzlSonarPathJson $Path) + ',' + (ConvertTo-AzlSonarNodeJson $New) + ']')
}

function Invoke-AzlSonarJsonPatch {
    <#
    .SYNOPSIS
        Applies delta ops (a parsed JSON array) to a parsed JSON tree; returns the result in a one-element array.
    .DESCRIPTION
        The tree is changed in place except when an op replaces the root. Op values are cloned, so the ops array can
        be applied again.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [object]$Root,

        [Parameter(Mandatory)]
        [System.Text.Json.Nodes.JsonArray]$Ops
    )

    # JsonObject and JsonArray are enumerable: never let one pass through the pipeline (an if-expression or a
    # function output would unroll it). Every node below is assigned directly.
    foreach ($op in $Ops) {
        if ($op -isnot [System.Text.Json.Nodes.JsonArray] -or $op.Count -lt 2) { throw 'A delta op is not [op, path, ...].' }
        $kind = $op[0].GetValue[string]()
        $path = $op[1]
        if ($path -isnot [System.Text.Json.Nodes.JsonArray]) { throw 'A delta op path is not an array.' }
        $value = $null
        if ($op.Count -gt 2 -and $null -ne $op[2]) { $value = $op[2].DeepClone() }
        if ($path.Count -eq 0) {
            if ($kind -ne 's') { throw "Delta op '$kind' needs a path." }
            $Root = $value
            continue
        }
        $parent = $Root
        for ($i = 0; $i -lt $path.Count - 1; $i++) {
            $parent = Get-AzlSonarJsonChild -Parent $parent -Segment $path[$i]
            if ($null -eq $parent) { throw "Delta op path not found at segment $i." }
        }
        $last = $path[$path.Count - 1]
        $isIndex = $last.GetValueKind() -eq [System.Text.Json.JsonValueKind]::Number
        switch ($kind) {
            's' {
                if ($isIndex) {
                    $index = $last.GetValue[int]()
                    while ($parent.Count -lt $index) { $parent.Add([System.Text.Json.Nodes.JsonNode]$null) }
                    if ($index -eq $parent.Count) { $parent.Add([System.Text.Json.Nodes.JsonNode]$value) } else { $parent[$index] = $value }
                }
                else {
                    $parent[$last.GetValue[string]()] = $value
                }
            }
            'd' {
                if ($isIndex) { $parent.RemoveAt($last.GetValue[int]()) } else { $null = $parent.Remove($last.GetValue[string]()) }
            }
            't' {
                $target = Get-AzlSonarJsonChild -Parent $parent -Segment $last
                if ($target -isnot [System.Text.Json.Nodes.JsonArray]) { throw 'Delta op t (truncate) does not point at an array.' }
                $length = $op[2].GetValue[int]()
                while ($target.Count -gt $length) { $target.RemoveAt($target.Count - 1) }
            }
            default { throw "Unknown delta op '$kind'." }
        }
    }
    return , (New-AzlSonarNodeBox $Root)
}

function Get-AzlSonarJsonChild {
    <#
    .SYNOPSIS
        The child of a parsed JSON object (by key) or array (by index); $null when missing. Returned in a variable-safe
        way: the caller assigns the result directly.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Parent,

        [Parameter(Mandatory)]
        [System.Text.Json.Nodes.JsonNode]$Segment
    )

    $child = $null
    if ($Segment.GetValueKind() -eq [System.Text.Json.JsonValueKind]::Number) {
        $index = $Segment.GetValue[int]()
        if ($Parent -is [System.Text.Json.Nodes.JsonArray] -and $index -ge 0 -and $index -lt $Parent.Count) { $child = $Parent[$index] }
    }
    elseif ($Parent -is [System.Text.Json.Nodes.JsonObject]) {
        $key = $Segment.GetValue[string]()
        if ($Parent.ContainsKey($key)) { $child = $Parent[$key] }
    }
    return , $child
}

function Get-AzlSonarRecorderSecret {
    <#
    .SYNOPSIS
        The exact values a recording masks: the log credential (Shared.Redact) and the Key Vault vault and secret names.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [AllowNull()]
        [object]$Config
    )

    $values = [System.Collections.Generic.List[string]]::new()
    if ($Shared.Contains('Redact')) { foreach ($s in @($Shared['Redact'])) { if ($s) { $values.Add([string]$s) } } }
    foreach ($name in 'vault', 'usernameSecret', 'passwordSecret') {
        $v = [string](Get-AzlSonarMember $Config "credential.$name" '')
        if ($v.Length -ge 4) { $values.Add($v) }
    }
    return [string[]]$values.ToArray()
}

function Resolve-AzlSonarRecordPath {
    <#
    .SYNOPSIS
        Resolves the recording path to a full path, creates its folder and checks the file can be opened for appending.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([System.IO.Directory]::Exists($full)) { throw "The recording path is a folder: $full. Give a file name, for example $full\clus01.jsonl." }
    $folder = [System.IO.Path]::GetDirectoryName($full)
    try {
        if ($folder -and -not [System.IO.Directory]::Exists($folder)) { $null = [System.IO.Directory]::CreateDirectory($folder) }
        $stream = [System.IO.FileStream]::new($full, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $stream.Dispose()
    }
    catch {
        throw "Cannot write the recording $full ($($_.Exception.Message))."
    }
    return $full
}

function New-AzlSonarSessionJson {
    <#
    .SYNOPSIS
        The body of a recording's 'session' event: format, tool, version, server id, cluster, public config, guidance.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigJson,

        [Parameter(Mandatory)]
        [string]$GuidanceJson,

        [string]$ServerId = '',

        [string]$Version = '',

        [string]$Cluster = ''
    )

    return '"format":' + $script:AzlSonarRecordingFormat + ',"tool":"AzL Sonar","version":' + (ConvertTo-AzlSonarJson $Version) +
        ',"server":' + (ConvertTo-AzlSonarJson $ServerId) + ',"cluster":' + (ConvertTo-AzlSonarJson $Cluster) +
        ',"config":' + $ConfigJson + ',"guidance":' + $GuidanceJson
}

function Open-AzlSonarRecorder {
    <#
    .SYNOPSIS
        Opens (appends to) a recording and writes the 'session' event. Returns the recorder record.
    .DESCRIPTION
        An existing file is never truncated: a new session is appended. When the file does not end with a line break
        (Sonar was stopped mid-write) the new session starts on a new line; the reader skips the partial line.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Appends to the local recording file the user asked for.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SessionJson,

        [string[]]$Secret = @(),

        [int]$MaxDeltas = $script:AzlSonarRecordingMaxDeltas,

        [datetime]$Now = [datetime]::UtcNow
    )

    $full = Resolve-AzlSonarRecordPath -Path $Path
    $needsBreak = $false
    $info = [System.IO.FileInfo]::new($full)
    if ($info.Exists -and $info.Length -gt 0) {
        $probe = [System.IO.FileStream]::new($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $null = $probe.Seek(-1, [System.IO.SeekOrigin]::End)
            $needsBreak = $probe.ReadByte() -ne 10
        }
        finally { $probe.Dispose() }
    }
    $stream = [System.IO.FileStream]::new($full, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    if ($needsBreak) { $writer.Write("`n") }
    $recorder = @{
        Path          = $full
        Writer        = $writer
        Secret        = $Secret
        MaxDeltas     = $MaxDeltas
        LastT         = [datetime]::MinValue
        LastState     = $null
        StateVersion  = [long]-1
        TailerVersion = [long]-1
        LastTailer    = $null
        LogSeq        = [long]0
        FullBytes     = [long]0
        DeltaBytes    = [long]0
        DeltaCount    = 0
        Events        = [long]0
        Keyframes     = [long]0
    }
    $sessionNode = (ConvertTo-AzlSonarProtectedJson -Json ('{' + $SessionJson + '}') -Secret $Secret)[0]
    $body = (ConvertTo-AzlSonarNodeJson $sessionNode).Substring(1)
    Write-AzlSonarRecordLine -Recorder $recorder -Kind 'session' -Body $body.Substring(0, $body.Length - 1) -Now $Now
    $writer.Flush()
    return $recorder
}

function Write-AzlSonarRecordLine {
    <#
    .SYNOPSIS
        Writes one event line: {"t":..., "k":..., <Body>}. Times never go backwards within a file write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Recorder,

        [Parameter(Mandatory)]
        [string]$Kind,

        [AllowEmptyString()]
        [string]$Body = '',

        [datetime]$Now = [datetime]::UtcNow
    )

    $t = $Now.ToUniversalTime()
    if ($t -lt $Recorder.LastT) { $t = $Recorder.LastT }
    $Recorder.LastT = $t
    $stamp = $t.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $line = '{"t":"' + $stamp + '","k":"' + $Kind + '"' + $(if ($Body) { ',' + $Body } else { '' }) + '}'
    $Recorder.Writer.Write($line + "`n")
    $Recorder.Events = [long]$Recorder.Events + 1
}

function Invoke-AzlSonarRecorderStep {
    <#
    .SYNOPSIS
        Records what changed in the shared table since the last call: the state (keyframe or delta), the tailer
        status and new log lines. Unchanged states are not written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Recorder,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [datetime]$Now = [datetime]::UtcNow
    )

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        $stateVersion = [long]$Shared.StateVersion
        $stateJson = [string]$Shared.StateJson
        $tailerVersion = [long]$Shared.TailerVersion
        $tailerJson = [string]$Shared.TailerJson
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }

    if ($stateVersion -ne $Recorder.StateVersion) {
        $Recorder.StateVersion = $stateVersion
        $state = (ConvertTo-AzlSonarProtectedJson -Json $stateJson -Secret $Recorder.Secret)[0]
        if ($null -ne $state) {
            $fullJson = $null
            if ($null -eq $Recorder.LastState) {
                $fullJson = ConvertTo-AzlSonarNodeJson $state
            }
            else {
                $ops = [System.Collections.Generic.List[string]]::new()
                Compare-AzlSonarJsonNode -Old $Recorder.LastState -New $state -Ops $ops
                if ($ops.Count -gt 0) {
                    $opsJson = '"ops":[' + ($ops -join ',') + ']'
                    if (($Recorder.DeltaBytes + $opsJson.Length) -gt $Recorder.FullBytes -or $Recorder.DeltaCount -ge $Recorder.MaxDeltas) {
                        $fullJson = ConvertTo-AzlSonarNodeJson $state
                    }
                    else {
                        Write-AzlSonarRecordLine -Recorder $Recorder -Kind 'state' -Body $opsJson -Now $Now
                        $Recorder.DeltaBytes = [long]$Recorder.DeltaBytes + $opsJson.Length
                        $Recorder.DeltaCount = [int]$Recorder.DeltaCount + 1
                    }
                }
            }
            if ($null -ne $fullJson) {
                Write-AzlSonarRecordLine -Recorder $Recorder -Kind 'state' -Body ('"full":' + $fullJson) -Now $Now
                $Recorder.FullBytes = [long]$fullJson.Length
                $Recorder.DeltaBytes = [long]0
                $Recorder.DeltaCount = 0
                $Recorder.Keyframes = [long]$Recorder.Keyframes + 1
            }
            $Recorder.LastState = $state
        }
    }

    if ($tailerVersion -ne $Recorder.TailerVersion -and $tailerVersion -gt 0) {
        $Recorder.TailerVersion = $tailerVersion
        $tailer = ConvertTo-AzlSonarNodeJson ((ConvertTo-AzlSonarProtectedJson -Json $tailerJson -Secret $Recorder.Secret)[0])
        if ($tailer -ne $Recorder.LastTailer) {
            Write-AzlSonarRecordLine -Recorder $Recorder -Kind 'tailer' -Body ('"tailer":' + $tailer) -Now $Now
            $Recorder.LastTailer = $tailer
        }
    }

    while ([long]$Shared.LogSeq -gt $Recorder.LogSeq) {
        $window = Get-AzlSonarLogWindow -Shared $Shared -Since $Recorder.LogSeq -Max 1000
        $lost = [long]0
        if ($window.OldestSeq -gt ($Recorder.LogSeq + 1)) { $lost = [long]$window.OldestSeq - $Recorder.LogSeq - 1 }
        $lines = foreach ($line in $window.Lines) {
            [ordered]@{
                seq        = [long]$line['seq']
                time       = [string]$line['time']
                received   = [string]$line['received']
                timeSource = [string]$line['timeSource']
                file       = Protect-AzlSonarText -Text ([string]$line['file']) -Secret $Recorder.Secret
                level      = [string]$line['level']
                text       = Protect-AzlSonarText -Text ([string]$line['text']) -Secret $Recorder.Secret
            }
        }
        $lines = @($lines)
        if ($lines.Count -eq 0) {
            $Recorder.LogSeq = [long]$window.LastSeq
            break
        }
        $body = '"lines":' + (ConvertTo-AzlSonarJson $lines)
        if ($lost -gt 0) { $body += ',"lost":' + $lost }
        Write-AzlSonarRecordLine -Recorder $Recorder -Kind 'log' -Body $body -Now $Now
        $Recorder.LogSeq = [long]$lines[-1]['seq']
    }
    $Recorder.Writer.Flush()
}

function Close-AzlSonarRecorder {
    <#
    .SYNOPSIS
        Writes the 'end' event and closes the recording.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Recorder,

        [datetime]$Now = [datetime]::UtcNow
    )

    try {
        Write-AzlSonarRecordLine -Recorder $Recorder -Kind 'end' -Now $Now
        $Recorder.Writer.Flush()
    }
    finally {
        $Recorder.Writer.Dispose()
    }
}

function Invoke-AzlSonarRecorderLoop {
    <#
    .SYNOPSIS
        Background loop: records the shared state, tailer status and log lines to -Path every half second until the
        shared stop flag is set, then writes the 'end' event.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SessionJson,

        [AllowNull()]
        [object]$Config
    )

    $secret = Get-AzlSonarRecorderSecret -Shared $Shared -Config $Config
    $recorder = Open-AzlSonarRecorder -Path $Path -SessionJson $SessionJson -Secret $secret
    try {
        while (-not $Shared.Stop) {
            Invoke-AzlSonarRecorderStep -Recorder $recorder -Shared $Shared
            Start-Sleep -Milliseconds 500
        }
        Invoke-AzlSonarRecorderStep -Recorder $recorder -Shared $Shared
    }
    finally {
        Close-AzlSonarRecorder -Recorder $recorder
    }
}

function Read-AzlSonarRecording {
    <#
    .SYNOPSIS
        Reads and checks a recording (JSON Lines, or the same gzip-compressed as .gz). Returns its events and summary.
    .DESCRIPTION
        Lines that are not valid JSON objects with a time and a kind are skipped and counted (Invalid), for example a
        line cut off when Sonar was stopped mid-write; unknown kinds are skipped (Ignored). A delta before any keyframe
        of its session is skipped as invalid. Throws when the file is missing, is not a Sonar recording (no session
        header first), was written by a newer format, or holds no state.
    .OUTPUTS
        PSCustomObject: Path, Name, Format, Events (List of { T, Kind, Line, Node }), Sessions, Start, End, Cluster,
        ConfigJson, GuidanceJson, Invalid, Ignored.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not [System.IO.File]::Exists($full)) { throw "Recording not found: $full" }

    $stream = [System.IO.FileStream]::new($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $source = $stream
    if ($full.EndsWith('.gz', [System.StringComparison]::OrdinalIgnoreCase)) {
        $source = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Decompress)
    }
    $reader = [System.IO.StreamReader]::new($source, [System.Text.UTF8Encoding]::new($false))
    $events = [System.Collections.Generic.List[object]]::new()
    $sessions = [System.Collections.Generic.List[object]]::new()
    $invalid = 0
    $ignored = 0
    $nonBlank = 0
    $format = 0
    $haveFull = $false
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $nonBlank++
            $node = $null
            try { $node = [System.Text.Json.Nodes.JsonNode]::Parse($line) } catch { $node = $null }
            if ($node -isnot [System.Text.Json.Nodes.JsonObject]) { $invalid++; continue }
            $tNode = $node['t']
            $kNode = $node['k']
            $t = [datetime]::MinValue
            if ($null -eq $tNode -or $null -eq $kNode -or $tNode.GetValueKind() -ne [System.Text.Json.JsonValueKind]::String -or
                $kNode.GetValueKind() -ne [System.Text.Json.JsonValueKind]::String -or
                -not [datetime]::TryParse($tNode.GetValue[string](), $culture, $styles, [ref]$t)) {
                $invalid++
                continue
            }
            $kind = $kNode.GetValue[string]()
            if ($kind -notin $script:AzlSonarRecordingKinds) { $ignored++; continue }
            if ($events.Count -eq 0 -and $kind -ne 'session') {
                throw "$full is not an AzL Sonar recording: it does not start with a session header."
            }
            $valid = $true
            switch ($kind) {
                'session' {
                    $fmt = $node['format']
                    $format = if ($null -ne $fmt -and $fmt.GetValueKind() -eq [System.Text.Json.JsonValueKind]::Number) { $fmt.GetValue[int]() } else { 0 }
                    if ($format -lt 1) { throw "$full has a session header without a valid format number." }
                    if ($format -gt $script:AzlSonarRecordingFormat) {
                        throw "$full was recorded in format $format by a newer AzL Sonar; this version reads format $($script:AzlSonarRecordingFormat)."
                    }
                    $haveFull = $false
                    $sessions.Add([pscustomobject]@{
                            T       = $t
                            Server  = [string](ConvertTo-AzlSonarNodeText $node['server'])
                            Version = [string](ConvertTo-AzlSonarNodeText $node['version'])
                            Cluster = [string](ConvertTo-AzlSonarNodeText $node['cluster'])
                            Node    = $node
                        })
                }
                'state' {
                    $fullNode = $node['full']
                    $opsNode = $node['ops']
                    $isKeyframe = $fullNode -is [System.Text.Json.Nodes.JsonObject]
                    $isDelta = $opsNode -is [System.Text.Json.Nodes.JsonArray] -and $haveFull
                    if (-not $isKeyframe -and -not $isDelta) { $valid = $false }
                    if ($isKeyframe) { $haveFull = $true }
                }
                'log' {
                    if ($node['lines'] -isnot [System.Text.Json.Nodes.JsonArray]) { $valid = $false }
                }
                'tailer' {
                    if ($node['tailer'] -isnot [System.Text.Json.Nodes.JsonObject]) { $valid = $false }
                }
            }
            # continue inside a switch would only leave the switch: the flag decides here.
            if (-not $valid) { $invalid++; continue }
            $events.Add([pscustomobject]@{ T = $t; Kind = $kind; Line = $line; Node = $node })
        }
    }
    catch [System.IO.InvalidDataException] {
        throw "$full is not a valid gzip file ($($_.Exception.Message))."
    }
    finally {
        $reader.Dispose()
        $source.Dispose()
        $stream.Dispose()
    }

    if ($nonBlank -eq 0) { throw "$full is empty: it holds no recorded events." }
    if ($events.Count -eq 0) { throw "$full is not an AzL Sonar recording: no line is a valid event (JSON Lines with t and k)." }
    if (@($events | Where-Object { $_.Kind -eq 'state' }).Count -eq 0) { throw "$full holds no state snapshots; there is nothing to replay." }

    $last = $sessions[$sessions.Count - 1].Node
    $configNode = $last['config']
    $guidanceNode = $last['guidance']
    $cluster = $sessions[$sessions.Count - 1].Cluster
    if (-not $cluster -and $configNode -is [System.Text.Json.Nodes.JsonObject]) { $cluster = [string](ConvertTo-AzlSonarNodeText $configNode['clusterName']) }
    $start = $events[0].T
    $end = $start
    foreach ($e in $events) { if ($e.T -gt $end) { $end = $e.T } }
    return [pscustomobject]@{
        Path         = $full
        Name         = [System.IO.Path]::GetFileName($full)
        Format       = $format
        Events       = $events
        Sessions     = $sessions.ToArray()
        Start        = $start
        End          = $end
        Cluster      = $cluster
        ConfigJson   = $(if ($configNode -is [System.Text.Json.Nodes.JsonObject]) { ConvertTo-AzlSonarNodeJson $configNode } else { 'null' })
        GuidanceJson = $(if ($guidanceNode -is [System.Text.Json.Nodes.JsonObject]) { ConvertTo-AzlSonarNodeJson $guidanceNode } else { 'null' })
        Invalid      = $invalid
        Ignored      = $ignored
    }
}

function ConvertTo-AzlSonarNodeText {
    <#
    .SYNOPSIS
        The text of a JSON string value, or '' for anything else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Node
    )

    if ($Node -is [System.Text.Json.Nodes.JsonValue] -and $Node.GetValueKind() -eq [System.Text.Json.JsonValueKind]::String) { return $Node.GetValue[string]() }
    return ''
}

function Get-AzlSonarRecordingStateAt {
    <#
    .SYNOPSIS
        The state as the page showed it at -Time: the last keyframe at or before the last state event at or before
        -Time, plus the deltas after it. Returns JSON text, or $null before the first state.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Recording,

        [Parameter(Mandatory)]
        [datetime]$Time
    )

    $events = $Recording.Events
    $target = -1
    for ($i = 0; $i -lt $events.Count; $i++) {
        if ($events[$i].T -gt $Time) { break }
        if ($events[$i].Kind -eq 'state') { $target = $i }
    }
    if ($target -lt 0) { return $null }
    $key = $target
    while ($key -ge 0 -and -not ($events[$key].Kind -eq 'state' -and $events[$key].Node['full'] -is [System.Text.Json.Nodes.JsonObject])) { $key-- }
    if ($key -lt 0) { return $null }
    $state = $events[$key].Node['full'].DeepClone()
    for ($i = $key + 1; $i -le $target; $i++) {
        if ($events[$i].Kind -ne 'state') { continue }
        $state = (Invoke-AzlSonarJsonPatch -Root $state -Ops $events[$i].Node['ops'])[0]
    }
    return (ConvertTo-AzlSonarNodeJson $state)
}

function ConvertTo-AzlSonarReplayStart {
    <#
    .SYNOPSIS
        Reads -StartAt for a replay: an offset from the start of the recording (1:42:10, 42:10 is 42 h 10 min as in
        TimeSpan, 90m, 1h30m, 45s), a UTC time inside the recording, or a phase (arc-registration, provisioning,
        validation, deployment; the page jumps to its marker). Returns { Time, Phase }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory)]
        [datetime]$Start,

        [Parameter(Mandatory)]
        [datetime]$End
    )

    $length = $End - $Start
    $lengthText = '{0}:{1:mm\:ss}' -f [int][Math]::Floor($length.TotalHours), $length
    if ([string]::IsNullOrWhiteSpace($Value)) { return [pscustomobject]@{ Time = $Start; Phase = $null } }
    $text = $Value.Trim()
    $phases = @{ 'arc' = 'arc-registration'; 'arc-registration' = 'arc-registration'; 'provisioning' = 'provisioning'; 'validate' = 'validation'; 'validation' = 'validation'; 'deploy' = 'deployment'; 'deployment' = 'deployment' }
    if ($phases.ContainsKey($text.ToLowerInvariant())) { return [pscustomobject]@{ Time = $null; Phase = $phases[$text.ToLowerInvariant()] } }

    $offset = $null
    if ($text -match '^\+?(?<h>\d+):(?<m>[0-5]?\d)(?::(?<s>[0-5]?\d))?$') {
        $offset = [timespan]::new([int]$Matches['h'], [int]$Matches['m'], $(if ($Matches['s']) { [int]$Matches['s'] } else { 0 }))
    }
    elseif ($text -match '^\+?(?=\d)(?:(?<h>\d+)h)?(?:(?<m>\d+)m)?(?:(?<s>\d+)s)?$') {
        $offset = [timespan]::new($(if ($Matches['h']) { [int]$Matches['h'] } else { 0 }), $(if ($Matches['m']) { [int]$Matches['m'] } else { 0 }), $(if ($Matches['s']) { [int]$Matches['s'] } else { 0 }))
    }
    if ($null -ne $offset) {
        if ($offset -gt $length) { throw "-StartAt $Value is past the end of the recording (length $lengthText)." }
        return [pscustomobject]@{ Time = $Start + $offset; Phase = $null }
    }

    $parsed = [System.DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([System.DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        $time = $parsed.UtcDateTime
        if ($time -lt $Start -or $time -gt $End) {
            throw "-StartAt $Value is outside the recording ($(Format-AzlSonarDate $Start) to $(Format-AzlSonarDate $End))."
        }
        return [pscustomobject]@{ Time = $time; Phase = $null }
    }
    throw "-StartAt $Value is not an offset (1:42:10, 90m, 1h30m), a UTC time inside the recording, or a phase (arc-registration, validation, deployment)."
}

function Get-AzlSonarReplayJson {
    <#
    .SYNOPSIS
        The /api/replay body: { replay: { cluster, file, recordedFrom, recordedTo, sessions, invalid, speed, startAt,
        startAtPhase, autoplay }, events: [ every valid event line as recorded ] }.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Recording,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Meta
    )

    $builder = [System.Text.StringBuilder]::new()
    $null = $builder.Append('{"replay":').Append((ConvertTo-AzlSonarJson $Meta)).Append(',"events":[')
    $first = $true
    foreach ($e in $Recording.Events) {
        if (-not $first) { $null = $builder.Append(',') }
        $null = $builder.Append($e.Line)
        $first = $false
    }
    $null = $builder.Append(']}')
    return $builder.ToString()
}
