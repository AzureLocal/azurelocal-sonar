Set-StrictMode -Version Latest

$script:AzlSonarContentTypes = @{
    '.html'  = 'text/html; charset=utf-8'
    '.htm'   = 'text/html; charset=utf-8'
    '.js'    = 'text/javascript; charset=utf-8'
    '.mjs'   = 'text/javascript; charset=utf-8'
    '.css'   = 'text/css; charset=utf-8'
    '.json'  = 'application/json; charset=utf-8'
    '.svg'   = 'image/svg+xml'
    '.png'   = 'image/png'
    '.ico'   = 'image/x-icon'
    '.txt'   = 'text/plain; charset=utf-8'
    '.woff2' = 'font/woff2'
}
$script:AzlSonarSsePingSeconds = 15
$script:AzlSonarSseMaxLinesPerEvent = 1000
$script:AzlSonarSseMaxClients = 4               # live streams served at once (config maxEventStreams); more get 429
$script:AzlSonarLogsMaxLines = 2000             # lines in one /api/logs answer
$script:AzlSonarLogsMaxBytes = 2097152          # bytes of lines in one /api/logs answer (2 MB)
$script:AzlSonarContentSecurityPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
$script:AzlSonarSseMaxQueuedBytes = 4194304     # bytes queued for one client before it counts as fallen behind
$script:AzlSonarSseWriteTimeoutSeconds = 15     # one write still in flight after this long drops the client

function Initialize-AzlSonarSharedState {
    <#
    .SYNOPSIS
        Creates the synchronized table the poller, the tailer and the HTTP loop share.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$RingSize = 5000,

        [int]$TimelineMax = 5000
    )

    return [hashtable]::Synchronized(@{
            Stop          = $false
            Lock          = [object]::new()
            State         = $null
            StateJson     = 'null'
            StateVersion  = [long]0
            LastStateKey  = ''
            Timeline      = [System.Collections.Generic.List[string]]::new()
            TimelineMax   = $TimelineMax
            TimelineDropped = [long]0
            ServerId      = [guid]::NewGuid().ToString('N')   # changes on every start: the page detects a restart by it
            Lines         = [System.Collections.Generic.Queue[object]]::new()
            LogSeq        = [long]0
            RingSize      = $RingSize
            Files         = @()
            Tailer        = $null
            TailerJson    = 'null'
            TailerVersion = [long]0
            Redact        = @()   # exact secret values to mask in node text (never serialized)
            NodeProbe     = [hashtable]::Synchronized(@{})   # OEM image route: per-node bootstrap/update status (Invoke-AzlSonarNodeProbeLoop)
            ZtpStages     = [hashtable]::Synchronized(@{})   # simplified route: per-node azurelocal-ztp Device and Network events (Invoke-AzlSonarZtpEventLoop)
            ZtpInfo       = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null })   # the ZTP event file: events read and the newest event time (/api/details)
            OsConfigEvents = [hashtable]::Synchronized(@{})   # per-node OS configuration events of the latest attempt, and the run entry '*' (Invoke-AzlSonarOsConfigEventLoop)
            ArmEvents     = [hashtable]::Synchronized(@{})   # ARM Validate and Deploy events: the run entry '*', the validation and deployment entries and their checks (Invoke-AzlSonarArmEventLoop)
            VerificationEvents = [hashtable]::Synchronized(@{})   # pre-cluster verification gate events: the latest run entry '*' with its checks (Invoke-AzlSonarVerificationEventLoop)
            VerificationInfo   = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null })   # the verification event file: events read and the newest event time (/api/details)
            ArmInfo       = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null })   # the ARM event file: events read and the newest event time (/api/details)
            LogAccount    = [hashtable]::Synchronized(@{})   # per node: immutable records of the account log access uses (never a password); '*breaker' and '*unavailable' hold the account-wide ones
            CredentialLock = [object]::new()   # one lock for the domain credential (read, mask, publish) and for the breaker and the per-node records
            LocalUserName = ''   # the local log account's user name (-Credential or the prompt), for the account shown per node
            OsConfigInfo  = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null })   # the OS configuration event file: events read and the newest event time (/api/details)
            DiscoveryCache = [hashtable]::Synchronized(@{})   # hardware discovery files already read, by path (Get-AzlSonarDiscoveryState)
            ConfigInfo    = [hashtable]::Synchronized(@{ ReadAt = $null; CheckedAt = $null; ChangedAt = $null; Note = $null })   # when the config source was read, checked and last changed (/api/details)
        })
}

function Start-AzlSonarWorker {
    <#
    .SYNOPSIS
        Runs a private module function on its own runspace (the module is imported there) and returns its handle.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts an in-process runspace only; nothing outside the process changes.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [hashtable]$Arguments
    )

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    if ($IsWindows) { $sessionState.ExecutionPolicy = Get-ExecutionPolicy }
    $sessionState.ImportPSModule([string[]]@($script:AzlSonarModuleManifest))
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($sessionState)
    $runspace.Name = "AzlSonar-$Name"
    $runspace.Open()

    $entry = {
        param([string]$Command, [hashtable]$Arguments)
        Set-StrictMode -Version Latest
        $module = Get-Module -Name AzlSonar
        & $module { param($Name, $Splat) & $Name @Splat } $Command $Arguments
    }
    $powershell = [System.Management.Automation.PowerShell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript($entry.ToString()).AddArgument($Command).AddArgument($Arguments)
    $handle = $powershell.BeginInvoke()
    return @{ Name = $Name; PowerShell = $powershell; Runspace = $runspace; Handle = $handle; Reported = $false }
}

function Stop-AzlSonarWorker {
    <#
    .SYNOPSIS
        Waits briefly for a worker to see the stop flag, stops it if needed, and disposes its runspace.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops an in-process runspace only; nothing outside the process changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Worker,

        [int]$TimeoutMilliseconds = 3000
    )

    try {
        if (-not $Worker.Handle.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            $Worker.PowerShell.Stop()
        }
    }
    catch {
        Write-Verbose "Stopping worker $($Worker.Name): $($_.Exception.Message)"
    }
    finally {
        $Worker.PowerShell.Dispose()
        $Worker.Runspace.Dispose()
    }
}

function ConvertTo-AzlSonarSafeJsonText {
    <#
    .SYNOPSIS
        Writes the characters less-than, greater-than and ampersand of a JSON text as their \u escapes. They only occur
        inside strings, so the meaning is unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrEmpty($Json)) { return [string]$Json }
    $lt = '\u' + '003c'
    $gt = '\u' + '003e'
    $amp = '\u' + '0026'
    return $Json.Replace('<', $lt).Replace('>', $gt).Replace('&', $amp)
}

function Set-AzlSonarSecurityHeader {
    <#
    .SYNOPSIS
        Puts the security headers on a response: no caching, no sniffing, no referrer, no framing and a Content-Security-Policy
        that allows only this origin's own files.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets headers on an in-memory response only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response)

    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Content-Security-Policy'] = $script:AzlSonarContentSecurityPolicy
}

function Send-AzlSonarHttpResponse {
    <#
    .SYNOPSIS
        Writes a complete response (string or bytes) and closes it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerResponse]$Response,

        [int]$StatusCode = 200,

        [string]$ContentType = 'application/json; charset=utf-8',

        [AllowNull()]
        [object]$Body,

        [hashtable]$Header = @{},

        [switch]$NoCache
    )

    try {
        # JSON never carries a raw <, > or & (an HTML parser that ever saw the body finds no tag in it); JSON.parse reads it unchanged.
        if ($Body -is [string] -and $ContentType -like 'application/json*') { $Body = ConvertTo-AzlSonarSafeJsonText $Body }
        $bytes = if ($Body -is [byte[]]) { $Body } elseif ($null -eq $Body) { [byte[]]@() } else { [System.Text.Encoding]::UTF8.GetBytes([string]$Body) }
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $null = $NoCache   # every response is no-store now
        Set-AzlSonarSecurityHeader -Response $Response
        foreach ($key in $Header.Keys) { $Response.Headers[$key] = [string]$Header[$key] }
        $Response.ContentLength64 = $bytes.Length
        if ($bytes.Length -gt 0) { $Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    }
    catch {
        Write-Verbose "Response not completed: $($_.Exception.Message)"
    }
    finally {
        try { $Response.Close() } catch { Write-Verbose 'Response already closed.' }
    }
}

function Send-AzlSonarJsonError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerResponse]$Response,

        [Parameter(Mandatory)]
        [int]$StatusCode,

        [Parameter(Mandatory)]
        [string]$Message
    )

    Send-AzlSonarHttpResponse -Response $Response -StatusCode $StatusCode -Body (ConvertTo-AzlSonarJson ([ordered]@{ error = $Message })) -NoCache
}

# The only files the page is made of. The request path picks an entry; it is never combined into a file path.
$script:AzlSonarStaticFiles = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$script:AzlSonarStaticFiles['/'] = 'index.html'
$script:AzlSonarStaticFiles['/index.html'] = 'index.html'
$script:AzlSonarStaticFiles['/app.js'] = 'app.js'
$script:AzlSonarStaticFiles['/app.css'] = 'app.css'
$script:AzlSonarStaticFiles['/azurelocal-sonar-icon.svg'] = 'azurelocal-sonar-icon.svg'

function Resolve-AzlSonarStaticPath {
    <#
    .SYNOPSIS
        Maps a (once decoded) URL path to one of the shipped page files; returns $null for anything else.
    .DESCRIPTION
        An allow-list: /, /index.html, /app.js, /app.css and the icon. A path with a control character, a drive colon, a
        wildcard, a quote, an angle bracket, a pipe or a backslash is refused before the lookup, so are reserved device
        names, a trailing dot or space and an alternate data stream. The file is then resolved under the web root and must
        start with the root plus a directory separator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$WebRoot,

        [Parameter(Mandatory)]
        [string]$UrlPath
    )

    if ($UrlPath -match '[\x00-\x1f:*?"<>|\\]') { return $null }
    foreach ($segment in $UrlPath.Split('/')) {
        if ($segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return $null }
        if ($segment -match '[. ]$' -and $segment -notin '', '.', '..') { return $null }
        if ($segment -eq '..') { return $null }
    }
    $name = $null
    if (-not $script:AzlSonarStaticFiles.TryGetValue($UrlPath, [ref]$name)) { return $null }
    $root = [System.IO.Path]::GetFullPath($WebRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $name))
    if (-not $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not [System.IO.File]::Exists($full)) { return $null }
    return $full
}

function Get-AzlSonarLogsJson {
    <#
    .SYNOPSIS
        The /api/logs body: { server, lastSeq, tailer, files[], lines[] } with lines after -Since.
    .DESCRIPTION
        server is this back end's instance id (new on every start). lastSeq is the last sequence number given out when
        the lines were read: the page has every line up to lastSeq (or it fell out of the ring buffer) and uses it as
        its catch-up cursor.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [long]$Since = 0,

        # The export keeps the whole ring buffer; the page's answers are capped.
        [switch]$NoLimit
    )

    if ($NoLimit) {
        $window = Get-AzlSonarLogWindow -Shared $Shared -Since $Since
        $lines = @($window.Lines)
        $lastSeq = [long]$window.LastSeq
        $truncated = $false
    }
    else {
        $window = Get-AzlSonarLogWindow -Shared $Shared -Since $Since -Max $script:AzlSonarLogsMaxLines
        $lines = [System.Collections.Generic.List[object]]::new()
        $texts = [System.Collections.Generic.List[string]]::new()
        $bytes = 0
        foreach ($line in @($window.Lines)) {
            $json = ConvertTo-AzlSonarJson $line
            if ($lines.Count -gt 0 -and $bytes + $json.Length -gt $script:AzlSonarLogsMaxBytes) { break }
            $bytes += $json.Length + 1
            $lines.Add($line)
            $texts.Add($json)
        }
        $lastSeq = [long]$window.LastSeq
        $truncated = $false
        # Not every line fitted (or the ring holds more than one answer): the cursor stops at the last line sent, so the
        # page asks again for the rest.
        if ($lines.Count -gt 0 -and [long]$lines[$lines.Count - 1]['seq'] -lt $lastSeq) {
            $lastSeq = [long]$lines[$lines.Count - 1]['seq']
            $truncated = $true
        }
        $lines = $texts
    }
    $linesJson = if ($NoLimit) { ConvertTo-AzlSonarJson $lines } else { '[' + ($lines -join ',') + ']' }
    $files = ConvertTo-AzlSonarJson @($Shared.Files)
    return '{"server":' + (ConvertTo-AzlSonarJson ([string]$Shared.ServerId)) + ',"lastSeq":' + $lastSeq + ',"truncated":' + $truncated.ToString().ToLowerInvariant() +
        ',"tailer":' + $Shared.TailerJson + ',"files":' + $files + ',"lines":' + $linesJson + '}'
}

function Get-AzlSonarExportJson {
    <#
    .SYNOPSIS
        The /api/export bundle: config (no secrets), the state timeline, the latest state and the log ring buffer.
    .DESCRIPTION
        The timeline is change-only and capped: a snapshot is kept only when the state changed (polledAt and running
        durations ignored), at most TimelineMax (5000); older snapshots are dropped first. The latest state is always
        in 'state'. The export metadata describes both caps: timelineMode, timelineMax, timelineDropped,
        latestStateIncluded, logRingSize, logLinesKept, logFirstSeq, logLastSeq and logLinesDropped.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    $shared = $Server.Shared
    [System.Threading.Monitor]::Enter($shared.Lock)
    try {
        $timeline = $shared.Timeline.ToArray()
        $stateJson = $shared.StateJson
        $timelineDropped = [long]$shared.TimelineDropped
    }
    finally {
        [System.Threading.Monitor]::Exit($shared.Lock)
    }
    $window = Get-AzlSonarLogWindow -Shared $shared -Since 0
    $kept = @($window.Lines).Count
    $firstSeq = if ($kept -gt 0) { [long]$window.Lines[0]['seq'] } else { $null }
    $meta = ConvertTo-AzlSonarJson ([ordered]@{
            tool                = 'AzL Sonar'
            version             = $Server.Version
            server              = [string]$shared.ServerId
            exportedAt          = Format-AzlSonarDate ([datetime]::UtcNow)
            snapshots           = $timeline.Count
            timelineMode        = 'change-only'
            timelineMax         = [int]$shared.TimelineMax
            timelineDropped     = $timelineDropped
            latestStateIncluded = $true
            logRingSize         = [int]$shared.RingSize
            logLinesKept        = $kept
            logFirstSeq         = $firstSeq
            logLastSeq          = [long]$window.LastSeq
            logLinesDropped     = [long]([Math]::Max([long]0, [long]$window.LastSeq - $kept))
        })
    return '{"export":' + $meta +
        ',"config":' + $Server.ConfigJson +
        ',"guidance":' + $Server.GuidanceJson +
        ',"state":' + $stateJson +
        ',"timeline":[' + ($timeline -join ',') + ']' +
        ',"logs":' + (Get-AzlSonarLogsJson -Shared $shared -Since 0 -NoLimit) + '}'
}

function Open-AzlSonarSseClient {
    <#
    .SYNOPSIS
        Turns a request into a Server-Sent Events stream and registers it; the main loop pushes the events.
    .DESCRIPTION
        At most AzlSonarSseMaxClients (10) streams are served at once; one more gets 503 with Retry-After (the page
        falls back to polling /api/state and /api/logs). The stream starts with 'retry: 5000' and an 'event: hello'
        whose data is { server, since }: the back end's instance id and the log sequence the stream continues from.
        Nothing is written synchronously: the text is queued and written with WriteAsync by Invoke-AzlSonarSseWrite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context,

        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    $response = $Context.Response
    $cap = if ($Server.ContainsKey('MaxEventStreams') -and [int]$Server['MaxEventStreams'] -gt 0) { [int]$Server['MaxEventStreams'] } else { $script:AzlSonarSseMaxClients }
    if ($Server.Clients.Count -ge $cap) {
        Send-AzlSonarHttpResponse -Response $response -StatusCode 429 -ContentType 'text/plain; charset=utf-8' -NoCache -Header @{ 'Retry-After' = '30' } `
            -Body "AzL Sonar serves at most $cap live streams at once. Close another Sonar tab; this page polls meanwhile."
        return
    }
    $response.StatusCode = 200
    $response.ContentType = 'text/event-stream; charset=utf-8'
    Set-AzlSonarSecurityHeader -Response $response
    $response.SendChunked = $true
    $response.KeepAlive = $true
    $client = New-AzlSonarSseClient -Response $response -Stream $response.OutputStream -LogSeq ([long]$Server.Shared.LogSeq)
    try {
        Add-AzlSonarSseText -Client $client -Text "retry: 5000`n`n"
        $hello = ConvertTo-AzlSonarJson ([ordered]@{ server = [string]$Server.Shared.ServerId; since = [long]$client.LogSeq })
        Add-AzlSonarSseText -Client $client -Text ("event: hello`ndata: " + $hello + "`n`n")
        $null = Invoke-AzlSonarSseWrite -Client $client -Now ([datetime]::UtcNow)
        $Server.Clients.Add($client)
    }
    catch {
        try { $response.Abort() } catch { Write-Verbose 'SSE client already gone.' }
    }
}

function New-AzlSonarSseClient {
    <#
    .SYNOPSIS
        The per-client record of an SSE stream: its response, stream, cursors and bounded write queue.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Response,

        [Parameter(Mandatory)]
        [object]$Stream,

        [long]$LogSeq = 0
    )

    return @{
        Response      = $Response
        Stream        = $Stream
        StateVersion  = [long]-1
        TailerVersion = [long]-1
        LogSeq        = $LogSeq
        LastPing      = [datetime]::UtcNow
        Queue         = [System.Collections.Generic.Queue[byte[]]]::new()
        QueuedBytes   = [long]0
        Pending       = $null
        PendingSince  = [datetime]::UtcNow
    }
}

function Add-AzlSonarSseText {
    <#
    .SYNOPSIS
        Queues text for one SSE client. Throws when the client's queue would pass AzlSonarSseMaxQueuedBytes (it fell behind).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Client,

        [Parameter(Mandatory)]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-AzlSonarSafeJsonText $Text))
    if ([long]$Client.QueuedBytes + $bytes.Length -gt $script:AzlSonarSseMaxQueuedBytes) {
        throw "The client fell behind: more than $($script:AzlSonarSseMaxQueuedBytes) bytes queued."
    }
    $Client.Queue.Enqueue($bytes)
    $Client.QueuedBytes = [long]$Client.QueuedBytes + $bytes.Length
}

function Invoke-AzlSonarSseWrite {
    <#
    .SYNOPSIS
        Moves one SSE client's queue to the network without waiting. Returns $true when no write is in flight afterwards.
    .DESCRIPTION
        At most one WriteAsync is in flight per client. When the previous write is still running the call returns at
        once ($false); when it has run longer than AzlSonarSseWriteTimeoutSeconds, or it failed, the call throws so the
        caller drops the client. Otherwise everything queued is written as one buffer with WriteAsync. The dispatch
        loop never blocks on a client.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Client,

        [datetime]$Now = [datetime]::UtcNow
    )

    if ($null -ne $Client.Pending) {
        $task = $Client.Pending
        if (-not $task.IsCompleted) {
            if (($Now - $Client.PendingSince).TotalSeconds -ge $script:AzlSonarSseWriteTimeoutSeconds) {
                throw "A write to the client has not finished in $($script:AzlSonarSseWriteTimeoutSeconds) s."
            }
            return $false
        }
        $Client.Pending = $null
        if ($task.IsFaulted -or $task.IsCanceled) { throw 'A write to the client failed.' }
    }
    if ($Client.Queue.Count -eq 0) { return $true }
    $buffer = [System.IO.MemoryStream]::new()
    try {
        while ($Client.Queue.Count -gt 0) {
            $chunk = $Client.Queue.Dequeue()
            $buffer.Write($chunk, 0, $chunk.Length)
        }
        $bytes = $buffer.ToArray()
    }
    finally {
        $buffer.Dispose()
    }
    $Client.QueuedBytes = [long]0
    $Client.PendingSince = $Now
    $Client.Pending = $Client.Stream.WriteAsync($bytes, 0, $bytes.Length)
    if ($Client.Pending.IsCompleted) {
        $task = $Client.Pending
        $Client.Pending = $null
        if ($task.IsFaulted -or $task.IsCanceled) { throw 'A write to the client failed.' }
        return $true
    }
    return $false
}

function Remove-AzlSonarSseClient {
    <#
    .SYNOPSIS
        Drops one SSE client: removes it from the list and aborts its connection (the page reconnects and catches up).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Closes a local HTTP connection only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server,

        [Parameter(Mandatory)]
        [hashtable]$Client,

        [string]$Reason
    )

    $null = $Server.Clients.Remove($Client)
    Write-Verbose "SSE client dropped: $Reason"
    try { $Client.Response.Abort() } catch { Write-Verbose 'SSE client already gone.' }
}

function Send-AzlSonarSseUpdate {
    <#
    .SYNOPSIS
        Pushes what changed to every SSE client: state, tailer, new log lines, and a ping every 15 seconds.
    .DESCRIPTION
        Never blocks on a client. A client whose previous write is still in flight gets nothing new this turn (state
        and tailer events coalesce to the latest; log lines wait at its cursor). A client is dropped when a write
        fails or stays in flight longer than AzlSonarSseWriteTimeoutSeconds, when its queue passes
        AzlSonarSseMaxQueuedBytes, or when the lines it still needs have left the ring buffer (it fell behind). Log
        events carry { server, lines[] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    $shared = $Server.Shared
    $now = [datetime]::UtcNow
    $clients = @($Server.Clients.ToArray())
    if ($clients.Count -eq 0) { return }
    $serverJson = ConvertTo-AzlSonarJson ([string]$shared.ServerId)
    foreach ($client in $clients) {
        try {
            if (-not (Invoke-AzlSonarSseWrite -Client $client -Now $now)) { continue }
            $stateVersion = [long]$shared.StateVersion
            if ($stateVersion -ne $client.StateVersion) {
                Add-AzlSonarSseText -Client $client -Text ("event: state`ndata: " + $shared.StateJson + "`n`n")
                $client.StateVersion = $stateVersion
            }
            $tailerVersion = [long]$shared.TailerVersion
            if ($tailerVersion -ne $client.TailerVersion -and $tailerVersion -gt 0) {
                Add-AzlSonarSseText -Client $client -Text ("event: tailer`ndata: " + $shared.TailerJson + "`n`n")
                $client.TailerVersion = $tailerVersion
            }
            if ([long]$shared.LogSeq -gt $client.LogSeq) {
                $window = Get-AzlSonarLogWindow -Shared $shared -Since $client.LogSeq -Max $script:AzlSonarSseMaxLinesPerEvent
                if ($window.OldestSeq -gt ($client.LogSeq + 1)) {
                    throw "The client fell behind the log ring buffer (needs seq $($client.LogSeq + 1), oldest kept $($window.OldestSeq))."
                }
                $lines = $window.Lines
                if ($lines.Count -gt 0) {
                    Add-AzlSonarSseText -Client $client -Text ("event: log`ndata: {""server"":" + $serverJson + ',"lines":' + (ConvertTo-AzlSonarJson $lines) + "}`n`n")
                    $client.LogSeq = [long]$lines[-1]['seq']
                }
                else {
                    $client.LogSeq = [long]$window.LastSeq
                }
            }
            if (($now - $client.LastPing).TotalSeconds -ge $script:AzlSonarSsePingSeconds) {
                Add-AzlSonarSseText -Client $client -Text ": ping`n`n"
                $client.LastPing = $now
            }
            $null = Invoke-AzlSonarSseWrite -Client $client -Now $now
        }
        catch {
            Remove-AzlSonarSseClient -Server $Server -Client $client -Reason $_.Exception.Message
        }
    }
}

function Test-AzlSonarHostHeader {
    <#
    .SYNOPSIS
        True when the Host header names this machine's loopback address on the port the request came in on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$HostHeader, [Parameter(Mandatory)][int]$Port)

    if ([string]::IsNullOrEmpty($HostHeader)) { return $false }
    return $HostHeader -imatch ('^(localhost|127\.0\.0\.1|\[::1\]):' + $Port + '$')
}

function Test-AzlSonarOriginHeader {
    <#
    .SYNOPSIS
        True when an Origin header is this page's own origin (http://localhost:<port> or http://127.0.0.1:<port>).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Origin, [Parameter(Mandatory)][int]$Port)

    return $Origin -imatch ('^http://(localhost|127\.0\.0\.1):' + $Port + '$')
}

function Test-AzlSonarTokenEqual {
    <#
    .SYNOPSIS
        Compares two access tokens in constant time.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Left, [AllowNull()][AllowEmptyString()][string]$Right)

    $a = [System.Text.Encoding]::UTF8.GetBytes([string]$Left)
    $b = [System.Text.Encoding]::UTF8.GetBytes([string]$Right)
    if ($a.Length -ne $b.Length -or $a.Length -eq 0) { return $false }
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, $b)
}

function New-AzlSonarAccessToken {
    <#
    .SYNOPSIS
        A fresh access token: 32 hex characters from the system's cryptographic random generator.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a random string only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [System.Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
}

function Invoke-AzlSonarHttpRequest {
    <#
    .SYNOPSIS
        Serves one request: the page, the read-only /api routes, or the SSE stream. Never changes Azure or a node.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context,

        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    $request = $Context.Request
    $response = $Context.Response
    try {
        # A 'localhost' prefix matches the Host header, not the socket: refuse anything that is not from this machine.
        $remote = $request.RemoteEndPoint
        if ($null -eq $remote -or -not [System.Net.IPAddress]::IsLoopback($remote.Address)) {
            Send-AzlSonarHttpResponse -Response $response -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body 'AzL Sonar only answers requests from this machine.'
            return
        }
        if ($request.HttpMethod -ne 'GET') {
            Send-AzlSonarHttpResponse -Response $response -StatusCode 405 -ContentType 'text/plain; charset=utf-8' -Body 'Only GET is supported.' -Header @{ Allow = 'GET' }
            return
        }
        # DNS rebinding: the peer is loopback but the Host header is the attacker's name. Only this machine's own names pass.
        $port = [int]$request.LocalEndPoint.Port
        if (-not (Test-AzlSonarHostHeader -HostHeader ([string]$request.Headers['Host']) -Port $port)) {
            Send-AzlSonarHttpResponse -Response $response -StatusCode 400 -ContentType 'text/plain; charset=utf-8' -Body ''
            return
        }
        $origin = $request.Headers['Origin']
        if ($null -ne $origin -and -not (Test-AzlSonarOriginHeader -Origin ([string]$origin) -Port $port)) {
            Send-AzlSonarHttpResponse -Response $response -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body ''
            return
        }
        $token = if ($Server.ContainsKey('Token')) { [string]$Server['Token'] } else { '' }
        if ($token) {
            $cookie = $request.Cookies['sonar_t']
            $cookieOk = $null -ne $cookie -and (Test-AzlSonarTokenEqual -Left ([string]$cookie.Value) -Right $token)
            if (-not $cookieOk) {
                $offered = $request.QueryString['t']
                if ($offered -and (Test-AzlSonarTokenEqual -Left ([string]$offered) -Right $token)) {
                    # First visit with the token: keep it in a cookie and redirect to the same address without it.
                    $query = foreach ($key in @($request.QueryString.AllKeys)) {
                        if ($key -and $key -ne 't') { [uri]::EscapeDataString($key) + '=' + [uri]::EscapeDataString([string]$request.QueryString[$key]) }
                    }
                    $target = '/' + $request.Url.AbsolutePath.TrimStart('/')
                    if (@($query).Count -gt 0) { $target += '?' + (@($query) -join '&') }
                    Send-AzlSonarHttpResponse -Response $response -StatusCode 302 -ContentType 'text/plain; charset=utf-8' -Body '' -Header @{
                        Location     = $target
                        'Set-Cookie' = "sonar_t=$token; HttpOnly; SameSite=Strict; Path=/"
                    }
                    return
                }
                Send-AzlSonarHttpResponse -Response $response -StatusCode 401 -ContentType 'text/plain; charset=utf-8' -Body 'Open the URL Sonar printed.'
                return
            }
        }
        $path = [uri]::UnescapeDataString($request.Url.AbsolutePath)
        $shared = $Server.Shared
        $replaying = $Server['Mode'] -eq 'replay'
        if ($replaying -and $path -in '/api/events', '/api/export') {
            Send-AzlSonarJsonError -Response $response -StatusCode 404 -Message "Replay mode: $path is not available; the page plays /api/replay."
            return
        }
        switch ($path) {
            '/api/replay' {
                if (-not $replaying) {
                    Send-AzlSonarJsonError -Response $response -StatusCode 404 -Message 'Not replaying. Start Sonar with -Replay <recording> to play a recording.'
                    return
                }
                Send-AzlSonarHttpResponse -Response $response -Body $Server.ReplayJson -NoCache
                return
            }
            '/api/config' {
                Send-AzlSonarHttpResponse -Response $response -Body $Server.ConfigJson -NoCache
                return
            }
            '/api/state' {
                Send-AzlSonarHttpResponse -Response $response -Body $shared.StateJson -NoCache
                return
            }
            '/api/guidance' {
                Send-AzlSonarHttpResponse -Response $response -Body $Server.GuidanceJson -NoCache
                return
            }
            '/api/about' {
                Send-AzlSonarHttpResponse -Response $response -Body (ConvertTo-AzlSonarJson (Get-AzlSonarAbout -Version ([string]$Server.Version))) -NoCache
                return
            }
            '/api/details' {
                Send-AzlSonarHttpResponse -Response $response -Body (ConvertTo-AzlSonarJson (Get-AzlSonarDetail -Server $Server)) -NoCache
                return
            }
            '/api/logs' {
                $since = [long]0
                $sinceText = $request.QueryString['since']
                if ($sinceText) {
                    if ($sinceText -notmatch '^[0-9]{1,15}$') {
                        Send-AzlSonarJsonError -Response $response -StatusCode 400 -Message 'since must be a whole number from 0.'
                        return
                    }
                    $since = [Math]::Min([long]$sinceText, [long]$shared.LogSeq)
                }
                Send-AzlSonarHttpResponse -Response $response -Body (Get-AzlSonarLogsJson -Shared $shared -Since $since) -NoCache
                return
            }
            '/api/events' {
                Open-AzlSonarSseClient -Context $Context -Server $Server
                return
            }
            '/api/export' {
                $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
                $safeName = $Server.ClusterName -replace '[^\w\.-]', '_'
                $disposition = "attachment; filename=`"azlsonar-$safeName-$stamp.json`""
                Send-AzlSonarHttpResponse -Response $response -Body (Get-AzlSonarExportJson -Server $Server) -Header @{ 'Content-Disposition' = $disposition } -NoCache
                return
            }
        }
        if ($path.StartsWith('/api/', [System.StringComparison]::OrdinalIgnoreCase)) {
            Send-AzlSonarJsonError -Response $response -StatusCode 404 -Message "Unknown API route: $path"
            return
        }
        $file = Resolve-AzlSonarStaticPath -WebRoot $Server.WebRoot -UrlPath $path
        if ($null -eq $file) {
            Send-AzlSonarHttpResponse -Response $response -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'Not found.'
            return
        }
        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        $type = if ($script:AzlSonarContentTypes.ContainsKey($extension)) { $script:AzlSonarContentTypes[$extension] } else { 'application/octet-stream' }
        Send-AzlSonarHttpResponse -Response $response -ContentType $type -Body ([System.IO.File]::ReadAllBytes($file)) -NoCache
    }
    catch {
        Write-Verbose "Request $($request.Url.AbsolutePath) failed: $($_.Exception.Message)"
        try { Send-AzlSonarJsonError -Response $response -StatusCode 500 -Message 'Internal error.' } catch { Write-Verbose 'Response already closed.' }
    }
}

function New-AzlSonarReplayServer {
    <#
    .SYNOPSIS
        The server table for a replay: the recording, the state at the start position, the recorded config (with the
        replay details) and guidance. No Azure, no node, no worker.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [double]$Speed = 60,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$StartAt,

        [switch]$Autoplay,

        [string]$Version = ''
    )

    $recording = Read-AzlSonarRecording -Path $Path
    $start = ConvertTo-AzlSonarReplayStart -Value $StartAt -Start $recording.Start -End $recording.End
    $shared = Initialize-AzlSonarSharedState
    $at = if ($null -ne $start.Time) { $start.Time } else { $recording.Start }
    $stateJson = Get-AzlSonarRecordingStateAt -Recording $recording -Time $at
    if (-not $stateJson) {
        $first = @($recording.Events | Where-Object { $_.Kind -eq 'state' })[0]
        $stateJson = ConvertTo-AzlSonarNodeJson $first.Node['full']
    }
    $shared.StateJson = $stateJson
    $shared.StateVersion = [long]1

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $format = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
    $meta = [ordered]@{
        cluster      = $recording.Cluster
        file         = $recording.Name
        recordedFrom = $recording.Start.ToString($format, $culture)
        recordedTo   = $recording.End.ToString($format, $culture)
        sessions     = @($recording.Sessions).Count
        invalid      = [int]$recording.Invalid
        speed        = $Speed
        startAt      = $(if ($null -ne $start.Time) { $start.Time.ToString($format, $culture) } else { $null })
        startAtPhase = $start.Phase
        autoplay     = [bool]$Autoplay
    }

    $config = $null
    if ($recording.ConfigJson -ne 'null') { $config = [System.Text.Json.Nodes.JsonNode]::Parse($recording.ConfigJson) }
    if ($config -isnot [System.Text.Json.Nodes.JsonObject]) {
        $config = [System.Text.Json.Nodes.JsonNode]::Parse((ConvertTo-AzlSonarJson ([ordered]@{ clusterName = $recording.Cluster; cluster = $recording.Cluster })))
    }
    $config['serverId'] = [System.Text.Json.Nodes.JsonValue]::Create([string]$shared.ServerId)
    $config['replay'] = [System.Text.Json.Nodes.JsonNode]::Parse((ConvertTo-AzlSonarJson $meta))
    $null = $config.Remove('recording')
    $identityModel = 'LocalIdentity'
    if ($config.ContainsKey('identityModel') -and $null -ne $config['identityModel']) { $identityModel = [string]$config['identityModel'] }
    $guidanceJson = $recording.GuidanceJson
    if ($guidanceJson -eq 'null') { $guidanceJson = ConvertTo-AzlSonarJson (Get-AzlSonarPhaseGuidance -IdentityModel $identityModel) }

    return @{
        Mode         = 'replay'
        Shared       = $shared
        WebRoot      = Join-Path -Path $script:AzlSonarModuleRoot -ChildPath 'web'
        ConfigJson   = ConvertTo-AzlSonarNodeJson $config
        Facts        = New-AzlSonarReplayDetailFact -ConfigJson $recording.ConfigJson -Cluster $recording.Cluster -ReadAt $recording.Start
        GuidanceJson = $guidanceJson
        ReplayJson   = Get-AzlSonarReplayJson -Recording $recording -Meta $meta
        ClusterName  = $recording.Cluster
        Version      = $Version
        Clients      = [System.Collections.Generic.List[hashtable]]::new()
        Recording    = $recording
    }
}

function Start-AzlSonarServer {
    <#
    .SYNOPSIS
        Starts AzL Sonar: the Azure poller, the log tailer and the local web server, until Ctrl+C. Or replays a
        recording through the same page (-Replay).
    .DESCRIPTION
        Live: reads the config, checks the Az PowerShell sign-in, resolves the log account (prompt, -Credential or Key
        Vault), binds http://localhost:{Port}/ only, starts the poller, the tailer and (unless provisioningRoute is
        simplified) the node probe that reads the Arc registration status on each node, on background runspaces, and
        serves the page, the JSON API and Server-Sent Events. With -Record (or recordPath in the config) a recorder
        appends every published state, tailer status and log line (masked) to a JSON Lines recording. Read-only towards
        Azure and the nodes. Ctrl+C stops the listener, closes the remoting session and disposes the runspaces.
        Replay: reads the recording and serves it through the same page with a transport bar (play, pause, speed,
        scrubber, phase markers). No Azure sign-in, no node access, no worker.
    .PARAMETER ConfigPath
        Path to the Sonar config file (JSON). Give this or -InfrastructureFile.
    .PARAMETER InfrastructureFile
        Path to the master infrastructure.yml (schema 5). Sonar builds the same configuration from it in memory and checks
        it every 60 seconds: when the node set changes it logs a notice to restart Sonar (the pollers are built at start).
    .PARAMETER PollSeconds
        Overrides pollSeconds (config file or default 20): seconds between Azure polls, 5 to 3600.
    .PARAMETER Replay
        Path to a recording (.jsonl, or .jsonl.gz) to play instead of watching a live deployment.
    .PARAMETER Port
        Local port. Default 8642.
    .PARAMETER Credential
        Account that reads the logs on the seed node. Overrides credential.source.
    .PARAMETER Record
        Append everything the page is sent to this recording file (JSON Lines). Overrides recordPath in the config.
    .PARAMETER Speed
        Replay: starting speed (recorded seconds per real second). Default 60.
    .PARAMETER StartAt
        Replay: where to start; an offset (1:42:10, 90m, 1h30m), a UTC time inside the recording, or a phase
        (arc-registration, validation, deployment).
    .PARAMETER Autoplay
        Replay: start playing at once instead of paused.
    .PARAMETER NoBrowser
        Do not open the browser.
    .PARAMETER TokenFile
        Write the per-start access token (just the token) to this file, readable by the current user only, and remove it when
        Sonar stops. The launch output then shows the path and no token. Overrides tokenFile in the config. Needs the access token on.
    .PARAMETER Force
        With -TokenFile or tokenFile: replace an existing file that is not a Sonar token file (without it such a file is refused).
    .EXAMPLE
        Start-AzlSonarServer -ConfigPath ./config/clus01.json -Record ./recordings/clus01.jsonl
    .EXAMPLE
        Start-AzlSonarServer -Replay ./recordings/clus01.jsonl -Speed 240 -StartAt deployment
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a local, read-only monitor; changes nothing outside the process (a recording is a local file the user asked for).')]
    [CmdletBinding(DefaultParameterSetName = 'Live')]
    param(
        [Parameter(ParameterSetName = 'Live')]
        [string]$ConfigPath,

        [Parameter(ParameterSetName = 'Live')]
        [string]$InfrastructureFile,

        [Parameter(ParameterSetName = 'Live')]
        [ValidateRange(5, 3600)]
        [int]$PollSeconds,

        [Parameter(Mandatory, ParameterSetName = 'Replay')]
        [string]$Replay,

        [ValidateRange(1, 65535)]
        [int]$Port = 8642,

        # Which stage to watch: Auto (the whole flow, as always) or one monitor. A single monitor shows only its tile and
        # reads only the sources it needs.
        [Parameter(ParameterSetName = 'Live')]
        [ValidateSet('Auto', 'Discovery', 'Provisioning', 'OsConfiguration', 'Verification', 'Validate', 'Deployment', 'Update', 'AddNode', 'Repair')]
        [string]$Monitor,

        [Parameter(ParameterSetName = 'Live')]
        [AllowNull()]
        [pscredential]$Credential,

        [Parameter(ParameterSetName = 'Live')]
        [string]$Record,

        [Parameter(ParameterSetName = 'Live')]
        [switch]$Publishable,

        [Parameter(ParameterSetName = 'Live')]
        [string[]]$ExtraTerm = @(),

        [Parameter(ParameterSetName = 'Replay')]
        [ValidateRange(0.1, 3600)]
        [double]$Speed = 60,

        [Parameter(ParameterSetName = 'Replay')]
        [string]$StartAt,

        [Parameter(ParameterSetName = 'Replay')]
        [switch]$Autoplay,

        [switch]$NoBrowser,

        # For a single-user machine only: without the access token any local account (and any local program) can read the page.
        [switch]$NoAccessToken,

        # A file the access token is written to (user-only) so automation need not read the launch output; removed at stop.
        [string]$TokenFile,

        # Replace an existing file at -TokenFile that is not a Sonar token file.
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'
    $moduleVersion = [string]$MyInvocation.MyCommand.Module.Version
    $workerSpecs = [System.Collections.Generic.List[hashtable]]::new()
    $tokenFilePath = ''

    if ($PSCmdlet.ParameterSetName -eq 'Replay') {
        # Fail before anything starts: the token file path is checked first.
        if ($PSBoundParameters.ContainsKey('TokenFile') -and $TokenFile) {
            if ($NoAccessToken) { throw '-TokenFile needs the access token: remove -NoAccessToken.' }
            $tokenFilePath = Assert-AzlSonarTokenFilePath -Path $TokenFile -Force:$Force
        }
        $server = New-AzlSonarReplayServer -Path $Replay -Speed $Speed -StartAt $StartAt -Autoplay:$Autoplay -Version $moduleVersion
        $recording = $server.Recording
        $from = $recording.Start.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        $length = $recording.End - $recording.Start
        $startMessage = "AzL Sonar is replaying $($recording.Name) ($($recording.Cluster), recorded $from, $([int][Math]::Floor($length.TotalHours)):$($length.ToString('mm\:ss')) long) on {0}. No Azure or node access. Press Ctrl+C to stop."
        if ($recording.Invalid -gt 0) { Write-Warning "$($recording.Invalid) line(s) of the recording are not valid events and were skipped (for example a line cut off when Sonar stopped)." }
    }
    else {
        if ($ConfigPath -and $InfrastructureFile) { throw 'Give -ConfigPath or -InfrastructureFile, not both.' }
        if (-not $ConfigPath -and -not $InfrastructureFile) { throw (Get-AzlSonarNoConfigMessage) }
        $readArguments = @{}
        if ($PSBoundParameters.ContainsKey('PollSeconds')) { $readArguments.PollSeconds = $PollSeconds }
        $config = if ($InfrastructureFile) { Read-AzlSonarConfig -InfrastructureFile $InfrastructureFile @readArguments } else { Read-AzlSonarConfig -Path $ConfigPath @readArguments }
        if ($PSBoundParameters.ContainsKey('Monitor')) { $config | Add-Member -NotePropertyName monitor -NotePropertyValue $Monitor -Force }
        # The token file (-TokenFile wins over tokenFile) is checked before Azure is touched.
        $tokenFileSetting = if ($PSBoundParameters.ContainsKey('TokenFile') -and $TokenFile) { $TokenFile } else { [string](Get-AzlSonarMember $config 'tokenFile' '') }
        if ($tokenFileSetting) {
            if ($NoAccessToken -or -not [bool](Get-AzlSonarMember $config 'accessToken' $true)) { throw 'A token file needs the access token: remove -NoAccessToken or set accessToken to true (or drop -TokenFile / tokenFile).' }
            $tokenFilePath = Assert-AzlSonarTokenFilePath -Path $tokenFileSetting -Force:$Force
        }
        $plan = Get-AzlSonarMonitorPlan -Monitor ([string](Get-AzlSonarMember $config 'monitor' 'Auto'))
        if ($plan.azure) { Assert-AzlSonarAzContext }
        $recordPath = if ($PSBoundParameters.ContainsKey('Record') -and $Record) { $Record } else { [string](Get-AzlSonarMember $config 'recordPath' '') }
        if ($Publishable -and -not $recordPath) { throw '-Publishable needs a recording: give -Record <file> or set recordPath in the config.' }
        if ($recordPath) { $recordPath = Resolve-AzlSonarRecordPath -Path $recordPath }
        if ($Publishable -and (Test-Path -LiteralPath $recordPath) -and (Get-Item -LiteralPath $recordPath).Length -gt 0) {
            throw "A publishable recording needs a new file (its pseudonyms are only stable inside one recording): $recordPath already holds data."
        }
        $logCredential = Resolve-AzlSonarCredential -Config $config -Credential $Credential

        $shared = Initialize-AzlSonarSharedState
        # The log account's password is masked by a fingerprint: no plaintext copy of it is kept in Shared.
        if ($logCredential) { Add-AzlSonarRedaction -Shared $shared -Secret $logCredential.Password }
        if ($logCredential) { $shared.LocalUserName = $logCredential.UserName }
        $initial = Get-AzlSonarInitialState -Config $config
        $shared.State = $initial
        $shared.StateJson = ConvertTo-AzlSonarJson $initial
        $shared.ConfigInfo['ReadAt'] = Format-AzlSonarDate ([datetime]::UtcNow)
        $guidance = Get-AzlSonarPhaseGuidance -IdentityModel $config.identityModel
        if (-not $guidance.available) {
            Write-Warning 'data/phase-guidance.json not found: /api/guidance returns no entries.'
        }

        $publicConfig = ConvertTo-AzlSonarPublicConfig -Config $config -StartedAt ([datetime]::UtcNow) -ServerId $shared.ServerId
        if ($recordPath) { $publicConfig.recording = [ordered]@{ file = [System.IO.Path]::GetFileName($recordPath) } }
        # A fingerprint of the page files: an open page reloads itself when Sonar comes back with different ones.
        $publicConfig.webVersion = Get-AzlSonarWebVersion -WebRoot (Join-Path -Path $script:AzlSonarModuleRoot -ChildPath 'web')
        $server = @{
            Mode         = 'live'
            Shared       = $shared
            WebRoot      = Join-Path -Path $script:AzlSonarModuleRoot -ChildPath 'web'
            ConfigJson   = ConvertTo-AzlSonarJson $publicConfig
            Facts        = New-AzlSonarDetailFact -Config $config
            GuidanceJson = ConvertTo-AzlSonarJson $guidance
            ClusterName  = $config.clusterName
            Version      = $moduleVersion
            Clients      = [System.Collections.Generic.List[hashtable]]::new()
        }
        if ($recordPath) {
            # First, so the recording starts with the initial state.
            $sessionJson = New-AzlSonarSessionJson -ConfigJson $server.ConfigJson -GuidanceJson $server.GuidanceJson -ServerId $shared.ServerId -Version $moduleVersion -Cluster $config.clusterName
            $workerSpecs.Add(@{ Name = 'Recorder'; Command = 'Invoke-AzlSonarRecorderLoop'; Arguments = @{ Shared = $shared; Path = $recordPath; SessionJson = $sessionJson; Config = $config; Publishable = [bool]$Publishable; ExtraTerm = @($ExtraTerm) } })
        }
        $workerSpecs.Add(@{ Name = 'Poller'; Command = 'Invoke-AzlSonarPollerLoop'; Arguments = @{ Shared = $shared; Config = $config } })
        if ($plan.tailer) { $workerSpecs.Add(@{ Name = 'Tailer'; Command = 'Invoke-AzlSonarTailerLoop'; Arguments = @{ Shared = $shared; Config = $config; Credential = $logCredential } }) }
        if ($config.ztpEventsPath -and $plan.ztpEvents) {
            # azurelocal-ztp event file (JSON Lines): provisioning states of the machines, shown in the log pane.
            $workerSpecs.Add(@{ Name = 'ZtpEvents'; Command = 'Invoke-AzlSonarZtpEventLoop'; Arguments = @{ Shared = $shared; Config = $config } })
        }
        if ($config.osConfigEventsPath -and $plan.osConfigEvents) {
            # The toolkit's OS configuration event file (JSON Lines): the OS configuration mode and its log lines.
            $workerSpecs.Add(@{ Name = 'OsConfigEvents'; Command = 'Invoke-AzlSonarOsConfigEventLoop'; Arguments = @{ Shared = $shared; Config = $config } })
        }
        if ($config.armEventsPath -and $plan.armEvents) {
            # The toolkit's ARM Validate and Deploy event file (JSON Lines): the ARM view of Validate and Deployment and its log lines.
            $workerSpecs.Add(@{ Name = 'ArmEvents'; Command = 'Invoke-AzlSonarArmEventLoop'; Arguments = @{ Shared = $shared; Config = $config } })
        }
        if ($config.verificationEventsPath -and $plan.verificationEvents) {
            # The toolkit's pre-cluster verification gate event file (JSON Lines): the Verification view and its log lines.
            $workerSpecs.Add(@{ Name = 'VerificationEvents'; Command = 'Invoke-AzlSonarVerificationEventLoop'; Arguments = @{ Shared = $shared; Config = $config } })
        }
        if ($InfrastructureFile) {
            # Logs a notice when the master file's node set changes (restart Sonar to track it).
            $workerSpecs.Add(@{ Name = 'InfrastructureWatch'; Command = 'Invoke-AzlSonarInfrastructureWatchLoop'; Arguments = @{ Shared = $shared; Config = $config; Path = $config.sourcePath } })
        }
        if ($config.provisioningRoute -ne 'simplified' -and $plan.nodeProbe) {
            # Reads Get-ArcBootstrapStatus / Get-ArcZeroDaySolutionUpdateStatus on each node, only while Arc registration (OEM image route) runs.
            $workerSpecs.Add(@{ Name = 'NodeProbe'; Command = 'Invoke-AzlSonarNodeProbeLoop'; Arguments = @{ Shared = $shared; Config = $config; Credential = $logCredential } })
        }
        $startMessage = "AzL Sonar is listening on {0} for $($config.clusterName) (read-only). Press Ctrl+C to stop."
        if ($recordPath) { $startMessage += " Recording to $recordPath$(if ($Publishable) { ' (publishable: identifiers replaced by pseudonyms)' } else { ' (secrets masked; identifiers are kept: use -Publishable to share it)' })." }
    }
    $shared = $server.Shared
    $tokenOn = -not $NoAccessToken
    $maxStreams = $script:AzlSonarSseMaxClients
    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        if (-not [bool](Get-AzlSonarMember $config 'accessToken' $true)) { $tokenOn = $false }
        $maxStreams = [int](Get-AzlSonarMember $config 'maxEventStreams' $script:AzlSonarSseMaxClients)
    }
    $server.MaxEventStreams = $maxStreams
    $accessToken = ''
    if ($tokenOn) {
        $accessToken = New-AzlSonarAccessToken
        $server.Token = $accessToken
        # Masked like a password in everything Sonar stores, serves or records.
        $shared.Redact = @($shared.Redact) + $accessToken
    }
    if (-not (Test-Path -LiteralPath (Join-Path $server.WebRoot 'index.html'))) {
        Write-Warning "The page is missing ($($server.WebRoot)\index.html); the API still works."
    }

    $url = "http://localhost:$Port/"
    $openUrl = if ($accessToken) { $url + '?t=' + $accessToken } else { $url }
    # With a token file the launch output carries the path and not the token; the browser still gets the token in its address.
    $shownUrl = if ($tokenFilePath) { $url } else { $openUrl }
    $tokenFileWritten = $false
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($url)
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    try {
        $listener.Start()
    }
    catch {
        $listener.Close()
        throw "Cannot listen on $url ($($_.Exception.Message)). Is the port in use? Choose another with -Port."
    }

    $workers = [System.Collections.Generic.List[hashtable]]::new()
    try {
        if ($tokenFilePath) {
            $null = New-AzlSonarTokenFile -Path $tokenFilePath -Token $accessToken -Force:$Force
            $tokenFileWritten = $true
        }
        foreach ($spec in $workerSpecs) {
            $workers.Add((Start-AzlSonarWorker -Name $spec.Name -Command $spec.Command -Arguments $spec.Arguments))
        }

        Write-Information -MessageData ($startMessage -f $shownUrl) -InformationAction Continue
        if ($tokenFileWritten) { Write-Information -MessageData ('Access token file: {0} (readable by the current user only; removed when Sonar stops).' -f $tokenFilePath) -InformationAction Continue }
        if (-not $accessToken) { Write-Warning 'The access token is off: any account on this machine can read this page. Use that on a single-user machine only.' }
        if (-not $NoBrowser) {
            try { Start-Process -FilePath $openUrl } catch { Write-Warning "Could not open the browser: $($_.Exception.Message). Open $shownUrl yourself$(if ($tokenFileWritten) { " (the token is in the token file)" })." }
        }

        $pending = $listener.GetContextAsync()
        $lastHealthCheck = [datetime]::UtcNow
        while ($listener.IsListening) {
            $ready = $false
            try { $ready = $pending.Wait(250) } catch { $pending = $listener.GetContextAsync() }
            if ($ready) {
                $context = $pending.Result
                $pending = $listener.GetContextAsync()
                Invoke-AzlSonarHttpRequest -Context $context -Server $server
            }
            Send-AzlSonarSseUpdate -Server $server

            if (([datetime]::UtcNow - $lastHealthCheck).TotalSeconds -ge 5) {
                $lastHealthCheck = [datetime]::UtcNow
                foreach ($worker in $workers) {
                    if ($worker.Handle.IsCompleted -and -not $worker.Reported) {
                        $worker.Reported = $true
                        $reason = @($worker.PowerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '; '
                        Write-Warning "The $($worker.Name) stopped unexpectedly. $reason"
                    }
                }
            }
        }
    }
    finally {
        $shared.Stop = $true
        foreach ($client in @($server.Clients.ToArray())) {
            try { $client.Response.Abort() } catch { Write-Verbose 'SSE client already gone.' }
        }
        $server.Clients.Clear()
        try { $listener.Stop() } catch { Write-Verbose 'Listener already stopped.' }
        $listener.Close()
        foreach ($worker in $workers) { Stop-AzlSonarWorker -Worker $worker }
        if ($tokenFileWritten) { $null = Remove-AzlSonarTokenFile -Path $tokenFilePath -Token $accessToken }
        Write-Information -MessageData 'AzL Sonar stopped.' -InformationAction Continue
    }
}

function Get-AzlSonarWebVersion {
    <#
    .SYNOPSIS
        A short fingerprint (first 12 hex digits of a SHA-256) of the files the page is made of, in name order.
    .DESCRIPTION
        Sent in /api/config as webVersion. After a restart the open page compares it with the one it loaded with and
        reloads itself when it differs, so an update reaches a page that was left open. A missing folder gives ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$WebRoot)

    if (-not (Test-Path -LiteralPath $WebRoot -PathType Container)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $WebRoot -File -Recurse | Sort-Object FullName)) {
            $name = [System.Text.Encoding]::UTF8.GetBytes($file.FullName.Substring($WebRoot.Length).Replace('\', '/'))
            $null = $sha.TransformBlock($name, 0, $name.Length, $null, 0)
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $null = $sha.TransformBlock($bytes, 0, $bytes.Length, $null, 0)
        }
        $null = $sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return ([System.BitConverter]::ToString($sha.Hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}
