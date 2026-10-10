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
            Lines         = [System.Collections.Generic.Queue[object]]::new()
            LogSeq        = [long]0
            RingSize      = $RingSize
            Files         = @()
            Tailer        = $null
            TailerJson    = 'null'
            TailerVersion = [long]0
            Redact        = @()   # exact secret values to mask in node text (never serialized)
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
        $bytes = if ($Body -is [byte[]]) { $Body } elseif ($null -eq $Body) { [byte[]]@() } else { [System.Text.Encoding]::UTF8.GetBytes([string]$Body) }
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $Response.Headers['X-Content-Type-Options'] = 'nosniff'
        $Response.Headers['Referrer-Policy'] = 'no-referrer'
        if ($NoCache) { $Response.Headers['Cache-Control'] = 'no-store' }
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

function Resolve-AzlSonarStaticPath {
    <#
    .SYNOPSIS
        Maps a URL path to a file under the web root; returns $null for anything outside it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$WebRoot,

        [Parameter(Mandatory)]
        [string]$UrlPath
    )

    $relative = if ($UrlPath -eq '/' -or $UrlPath -eq '') { 'index.html' } else { $UrlPath.TrimStart('/') }
    if ($relative -match '(^|[\\/])\.\.([\\/]|$)' -or $relative.Contains(':')) { return $null }
    $root = [System.IO.Path]::GetFullPath($WebRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not [System.IO.File]::Exists($full)) { return $null }
    return $full
}

function Get-AzlSonarLogsJson {
    <#
    .SYNOPSIS
        The /api/logs body: { tailer, files[], lines[] } with lines after -Since.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [long]$Since = 0
    )

    $lines = Get-AzlSonarLogLine -Shared $Shared -Since $Since
    $files = ConvertTo-AzlSonarJson @($Shared.Files)
    return '{"tailer":' + $Shared.TailerJson + ',"files":' + $files + ',"lines":' + (ConvertTo-AzlSonarJson $lines) + '}'
}

function Get-AzlSonarExportJson {
    <#
    .SYNOPSIS
        The /api/export bundle: config (no secrets), the state timeline, the latest state and the log ring buffer.
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
    }
    finally {
        [System.Threading.Monitor]::Exit($shared.Lock)
    }
    $meta = ConvertTo-AzlSonarJson ([ordered]@{
            tool       = 'AzL Sonar'
            version    = $Server.Version
            exportedAt = Format-AzlSonarDate ([datetime]::UtcNow)
            snapshots  = $timeline.Count
        })
    return '{"export":' + $meta +
        ',"config":' + $Server.ConfigJson +
        ',"guidance":' + $Server.GuidanceJson +
        ',"state":' + $stateJson +
        ',"timeline":[' + ($timeline -join ',') + ']' +
        ',"logs":' + (Get-AzlSonarLogsJson -Shared $shared -Since 0) + '}'
}

function Open-AzlSonarSseClient {
    <#
    .SYNOPSIS
        Turns a request into a Server-Sent Events stream and registers it; the main loop pushes the events.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context,

        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    $response = $Context.Response
    $response.StatusCode = 200
    $response.ContentType = 'text/event-stream; charset=utf-8'
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.SendChunked = $true
    $response.KeepAlive = $true
    $client = @{
        Response      = $response
        Stream        = $response.OutputStream
        StateVersion  = [long]-1
        TailerVersion = [long]-1
        LogSeq        = [long]$Server.Shared.LogSeq
        LastPing      = [datetime]::UtcNow
    }
    try {
        Write-AzlSonarSseText -Client $client -Text "retry: 5000`n`n"
        $Server.Clients.Add($client)
    }
    catch {
        try { $response.Abort() } catch { Write-Verbose 'SSE client already gone.' }
    }
}

function Write-AzlSonarSseText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Client,

        [Parameter(Mandatory)]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Client.Stream.Write($bytes, 0, $bytes.Length)
    $Client.Stream.Flush()
}

function Send-AzlSonarSseUpdate {
    <#
    .SYNOPSIS
        Pushes what changed to every SSE client: state, tailer, new log lines, and a ping every 15 seconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    $shared = $Server.Shared
    $now = [datetime]::UtcNow
    foreach ($client in @($Server.Clients.ToArray())) {
        try {
            $stateVersion = [long]$shared.StateVersion
            if ($stateVersion -ne $client.StateVersion) {
                Write-AzlSonarSseText -Client $client -Text ("event: state`ndata: " + $shared.StateJson + "`n`n")
                $client.StateVersion = $stateVersion
            }
            $tailerVersion = [long]$shared.TailerVersion
            if ($tailerVersion -ne $client.TailerVersion -and $tailerVersion -gt 0) {
                Write-AzlSonarSseText -Client $client -Text ("event: tailer`ndata: " + $shared.TailerJson + "`n`n")
                $client.TailerVersion = $tailerVersion
            }
            if ([long]$shared.LogSeq -gt $client.LogSeq) {
                $lines = Get-AzlSonarLogLine -Shared $shared -Since $client.LogSeq -Max $script:AzlSonarSseMaxLinesPerEvent
                if ($lines.Count -gt 0) {
                    Write-AzlSonarSseText -Client $client -Text ("event: log`ndata: " + (ConvertTo-AzlSonarJson $lines) + "`n`n")
                    $client.LogSeq = [long]$lines[-1]['seq']
                }
                else {
                    $client.LogSeq = [long]$shared.LogSeq
                }
            }
            if (($now - $client.LastPing).TotalSeconds -ge $script:AzlSonarSsePingSeconds) {
                Write-AzlSonarSseText -Client $client -Text ": ping`n`n"
                $client.LastPing = $now
            }
        }
        catch {
            $null = $Server.Clients.Remove($client)
            try { $client.Response.Abort() } catch { Write-Verbose 'SSE client already gone.' }
        }
    }
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
        $path = [uri]::UnescapeDataString($request.Url.AbsolutePath)
        $shared = $Server.Shared
        switch ($path) {
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
            '/api/logs' {
                $since = [long]0
                $sinceText = $request.QueryString['since']
                if ($sinceText -and -not [long]::TryParse($sinceText, [ref]$since)) {
                    Send-AzlSonarJsonError -Response $response -StatusCode 400 -Message 'since must be a whole number.'
                    return
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

function Start-AzlSonarServer {
    <#
    .SYNOPSIS
        Starts AzL Sonar: the Azure poller, the log tailer and the local web server, until Ctrl+C.
    .DESCRIPTION
        Reads the config, checks the Az PowerShell sign-in, resolves the log account (prompt, -Credential or Key
        Vault), binds http://localhost:{Port}/ only, starts the poller and the tailer on background runspaces and
        serves the page, the JSON API and Server-Sent Events. Read-only towards Azure and the nodes. Ctrl+C stops
        the listener, closes the remoting session and disposes the runspaces.
    .PARAMETER ConfigPath
        Path to the Sonar config file (JSON).
    .PARAMETER Port
        Local port. Default 8642.
    .PARAMETER Credential
        Account that reads the logs on the seed node. Overrides credential.source.
    .PARAMETER NoBrowser
        Do not open the browser.
    .EXAMPLE
        Start-AzlSonarServer -ConfigPath ./config/clus01.json
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a local, read-only monitor; changes nothing outside the process.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [ValidateRange(1, 65535)]
        [int]$Port = 8642,

        [AllowNull()]
        [pscredential]$Credential,

        [switch]$NoBrowser
    )

    $ErrorActionPreference = 'Stop'
    $config = Read-AzlSonarConfig -Path $ConfigPath
    Assert-AzlSonarAzContext
    $logCredential = Resolve-AzlSonarCredential -Config $config -Credential $Credential

    $shared = Initialize-AzlSonarSharedState
    if ($logCredential) { $shared.Redact = @($logCredential.GetNetworkCredential().Password) | Where-Object { $_ } }
    $initial = Get-AzlSonarInitialState -Config $config
    $shared.State = $initial
    $shared.StateJson = ConvertTo-AzlSonarJson $initial
    $guidance = Get-AzlSonarPhaseGuidance -IdentityModel $config.identityModel
    if (-not $guidance.available) {
        Write-Warning 'data/phase-guidance.json not found: /api/guidance returns no entries.'
    }

    $moduleVersion = [string]$MyInvocation.MyCommand.Module.Version
    $server = @{
        Shared       = $shared
        WebRoot      = Join-Path -Path $script:AzlSonarModuleRoot -ChildPath 'web'
        ConfigJson   = ConvertTo-AzlSonarJson (ConvertTo-AzlSonarPublicConfig -Config $config -StartedAt ([datetime]::UtcNow))
        GuidanceJson = ConvertTo-AzlSonarJson $guidance
        ClusterName  = $config.clusterName
        Version      = $moduleVersion
        Clients      = [System.Collections.Generic.List[hashtable]]::new()
    }
    if (-not (Test-Path -LiteralPath (Join-Path $server.WebRoot 'index.html'))) {
        Write-Warning "The page is missing ($($server.WebRoot)\index.html); the API still works."
    }

    $url = "http://localhost:$Port/"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($url)
    try {
        $listener.Start()
    }
    catch {
        $listener.Close()
        throw "Cannot listen on $url ($($_.Exception.Message)). Is the port in use? Choose another with -Port."
    }

    $workers = [System.Collections.Generic.List[hashtable]]::new()
    try {
        $workers.Add((Start-AzlSonarWorker -Name 'Poller' -Command 'Invoke-AzlSonarPollerLoop' -Arguments @{ Shared = $shared; Config = $config }))
        $workers.Add((Start-AzlSonarWorker -Name 'Tailer' -Command 'Invoke-AzlSonarTailerLoop' -Arguments @{ Shared = $shared; Config = $config; Credential = $logCredential }))

        Write-Information -MessageData "AzL Sonar is listening on $url for $($config.clusterName) (read-only). Press Ctrl+C to stop." -InformationAction Continue
        if (-not $NoBrowser) {
            try { Start-Process -FilePath $url } catch { Write-Warning "Could not open the browser: $($_.Exception.Message). Open $url yourself." }
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
        Write-Information -MessageData 'AzL Sonar stopped.' -InformationAction Continue
    }
}
