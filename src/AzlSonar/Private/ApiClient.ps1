Set-StrictMode -Version Latest

# Invoke-AzlSonarApi: the supported way for a script, a pipeline step or an agent to call Sonar's read-only HTTP API
# (docs/api.md). It does the access-token handshake (GET /?t=<token> answers 302 and sets the sonar_t cookie, kept in a
# cookie container for the session), pages /api/logs, follows /api/events and saves /api/export. It only ever sends GET,
# only to this machine, and never prints, logs or puts the token in an error message.

$script:AzlSonarApiRoutes = @('/api/config', '/api/about', '/api/guidance', '/api/details', '/api/state', '/api/logs', '/api/events', '/api/export', '/api/replay')
# One session (HttpClient with a cookie container) per Sonar address: { Origin, Client, Jar, TokenHash }.
$script:AzlSonarApiSessions = @{}
$script:AzlSonarApiMaxRetryWaitSeconds = 120

function Get-AzlSonarApiHash {
    # A short fingerprint of a token, to tell whether the session was opened with the token now given. Not the token.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)

    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))).Substring(0, 16)
}

function Protect-AzlSonarApiText {
    <#
    .SYNOPSIS
        Removes the token (and any t=<hex> value) from a text before it goes into a message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text, [AllowNull()][AllowEmptyString()][string]$Token)

    $out = [string]$Text
    if ($Token) { $out = $out.Replace($Token, '***') }
    $out = [regex]::Replace($out, '(?i)([?&]t=|sonar_t=)[0-9a-f]{8,}', '${1}***')
    return $out
}

function ConvertTo-AzlSonarApiOrigin {
    <#
    .SYNOPSIS
        Checks -BaseUrl and returns 'http://host:port'. Only this machine is accepted: the token never goes to another host.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$BaseUrl)

    $uri = $null
    if (-not [uri]::TryCreate($BaseUrl.Trim(), [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http') {
        throw "BaseUrl must be the address Sonar listens on, for example http://localhost:8642 (plain http, no path)."
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.AbsolutePath -ne '/') { throw 'BaseUrl must be only the address and port, for example http://localhost:8642 (no path, query or user name).' }
    if ($uri.Host -notin 'localhost', '127.0.0.1', '[::1]', '::1') {
        throw "BaseUrl must be localhost or 127.0.0.1: Sonar only answers this machine, and the access token is never sent to another host (got '$($uri.Host)')."
    }
    return 'http://{0}:{1}' -f $uri.Host, $uri.Port
}

function Get-AzlSonarApiToken {
    <#
    .SYNOPSIS
        The access token from -Token or from the token file; '' when neither is given.
    .DESCRIPTION
        The token is checked for the form Sonar makes (32 hexadecimal characters), which also keeps anything else out of the
        handshake address. Error messages name the file, never its content. A token file that other accounts can read gets a warning.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Token, [string]$TokenFile)

    $value = ''
    if ($Token) { $value = $Token.Trim() }
    elseif ($TokenFile) {
        $path = Resolve-AzlSonarTokenFilePath -Path $TokenFile
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The token file does not exist: $path. Start Sonar with -TokenFile, and check that it is running." }
        $content = Get-AzlSonarTokenFileContent -Path $path
        if ($null -eq $content) { throw "The token file cannot be read or is too large to be a token file: $path." }
        if (-not $content) { throw "The token file is empty: $path. Sonar empties it when it stops; start Sonar again." }
        $value = $content
        $check = Test-AzlSonarTokenFileSecure -Path $path
        if (-not $check.Secure) { Write-Warning "The token file $path is not private ($($check.Problem)); other accounts on this machine may read the token." }
    }
    if ($value -and -not (Test-AzlSonarTokenText -Text $value)) {
        throw 'The access token does not have the form Sonar makes (32 lower-case hexadecimal characters). Pass the token only, not the URL.'
    }
    return $value
}

function Get-AzlSonarApiSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Origin)

    if (-not $script:AzlSonarApiSessions.ContainsKey($Origin)) {
        $jar = [System.Net.CookieContainer]::new()
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $true
        $handler.CookieContainer = $jar
        $client = [System.Net.Http.HttpClient]::new($handler)
        # Timeouts are set per request (a stream has none).
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $script:AzlSonarApiSessions[$Origin] = @{ Origin = $Origin; Client = $client; Jar = $jar; TokenHash = '' }
    }
    return $script:AzlSonarApiSessions[$Origin]
}

function Clear-AzlSonarApiSession {
    <#
    .SYNOPSIS
        Forgets the sessions (cookie containers) of this PowerShell session.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Drops in-memory objects only.')]
    [CmdletBinding()]
    param([string]$Origin)

    foreach ($key in @($script:AzlSonarApiSessions.Keys)) {
        if ($Origin -and $key -ne $Origin) { continue }
        try { $script:AzlSonarApiSessions[$key].Client.Dispose() } catch { Write-Verbose 'The client was already disposed.' }
        $script:AzlSonarApiSessions.Remove($key)
    }
}

function New-AzlSonarApiError {
    <#
    .SYNOPSIS
        An error record whose exception is an HttpRequestException with the status code. The message holds no secret.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object only.')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Id = 'AzlSonarApi',
        [AllowNull()][Nullable[int]]$StatusCode,
        [string]$Target,
        [string]$Token
    )

    $safe = Protect-AzlSonarApiText -Text $Message -Token $Token
    $exception = if ($null -ne $StatusCode) { [System.Net.Http.HttpRequestException]::new($safe, $null, [System.Net.HttpStatusCode]$StatusCode) } else { [System.InvalidOperationException]::new($safe) }
    $category = if ($null -ne $StatusCode) { [System.Management.Automation.ErrorCategory]::InvalidResult } else { [System.Management.Automation.ErrorCategory]::ConnectionError }
    if ($StatusCode -in 401, 403) { $category = [System.Management.Automation.ErrorCategory]::AuthenticationError }
    if ($StatusCode -eq 404) { $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound }
    if ($StatusCode -eq 429) { $category = [System.Management.Automation.ErrorCategory]::LimitsExceeded }
    return [System.Management.Automation.ErrorRecord]::new($exception, $(if ($null -ne $StatusCode) { "$Id.$StatusCode" } else { $Id }), $category, $Target)
}

function Get-AzlSonarApiErrorText {
    # The "error" of Sonar's JSON error body, or the short text it sent; '' when there is none. Never more than 300 characters.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Body)

    if (-not $Body) { return '' }
    $text = $Body.Trim()
    if ($text.StartsWith('{')) {
        try {
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.PSObject.Properties['error']) { $text = [string]$parsed.error }
        }
        catch { Write-Verbose 'The error body is not JSON.' }
    }
    if ($text.StartsWith('<')) { return '' }
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
    return $text
}

function Get-AzlSonarApiStatusMessage {
    <#
    .SYNOPSIS
        The sentence for a status code Sonar answers, with what to do. 401, 403, 404, 405 and 429 have their own wording.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$StatusCode, [string]$Route, [string]$Detail, [AllowNull()][string]$RetryAfter)

    $suffix = if ($Detail) { " Sonar says: $Detail" } else { '' }
    switch ($StatusCode) {
        400 { return "Sonar refused the request for $Route (400, bad request).$suffix" }
        401 { return 'Sonar answered 401: the access token is missing, wrong, or Sonar was restarted (every start has a new token). Pass the current -Token, or -TokenFile of a Sonar started with -TokenFile.' }
        403 { return 'Sonar answered 403: it only answers this machine (loopback) and requests without a foreign Origin header. Call it from the machine Sonar runs on.' }
        404 {
            $why = switch ($Route) {
                '/api/replay' { ' /api/replay exists only when Sonar was started with -Replay.' }
                { $_ -in '/api/events', '/api/export' } { ' A replay does not serve this route (the recording is the export).' }
                default { '' }
            }
            return "Sonar answered 404 for ${Route}.$why$suffix"
        }
        405 { return "Sonar answered 405 for ${Route}: Sonar is read-only and only answers GET." }
        429 {
            $wait = if ($RetryAfter) { " Retry in $RetryAfter second(s)." } else { '' }
            return "Sonar answered 429 for ${Route}: too many event streams are open (maxEventStreams, default 4).$wait Close another stream (a browser tab holds one) or raise maxEventStreams."
        }
        default {
            if ($StatusCode -ge 500) { return "Sonar answered $StatusCode for ${Route}: it failed inside.$suffix" }
            return "Sonar answered $StatusCode for ${Route}.$suffix"
        }
    }
}

function Send-AzlSonarApiRequest {
    <#
    .SYNOPSIS
        Sends one GET and returns the response once its headers arrive. Network failures become clear errors.
    #>
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpResponseMessage])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$PathAndQuery,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$Token,
        [string]$Accept
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Session.Origin + $PathAndQuery)
    if ($Accept) { $null = $request.Headers.TryAddWithoutValidation('Accept', $Accept) }
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        return $Session.Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
    }
    catch [System.OperationCanceledException] {
        throw (New-AzlSonarApiError -Message "Sonar at $($Session.Origin) did not answer within $TimeoutSeconds second(s)." -Id 'AzlSonarApi.Timeout' -Token $Token)
    }
    catch [System.Net.Http.HttpRequestException] {
        throw (New-AzlSonarApiError -Message "Cannot reach Sonar at $($Session.Origin): is it running, and is the port right? ($(Protect-AzlSonarApiText -Text $_.Exception.GetBaseException().Message -Token $Token))" -Id 'AzlSonarApi.Unreachable' -Token $Token)
    }
    finally {
        $cts.Dispose()
        $request.Dispose()
    }
}

function Connect-AzlSonarApi {
    <#
    .SYNOPSIS
        The handshake: GET /?t=<token> answers 302 and sets the sonar_t cookie, which the session's cookie container keeps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    Write-Verbose "Opening a session with Sonar at $($Session.Origin)."
    $response = Send-AzlSonarApiRequest -Session $Session -PathAndQuery ('/?t=' + $Token) -TimeoutSeconds $TimeoutSeconds -Token $Token
    try {
        $code = [int]$response.StatusCode
        if ($code -eq 302) {
            $cookie = $Session.Jar.GetCookies([uri]$Session.Origin)['sonar_t']
            if ($null -eq $cookie) { throw (New-AzlSonarApiError -Message 'Sonar answered the handshake with 302 but sent no sonar_t cookie.' -Id 'AzlSonarApi.NoCookie' -StatusCode 302 -Token $Token) }
        }
        elseif ($code -eq 200) { Write-Verbose 'Sonar answered 200: its access token is off, no cookie is needed.' }
        elseif ($code -eq 401) {
            throw (New-AzlSonarApiError -Message (Get-AzlSonarApiStatusMessage -StatusCode 401 -Route '/') -Id 'AzlSonarApi' -StatusCode 401 -Token $Token)
        }
        else {
            throw (New-AzlSonarApiError -Message (Get-AzlSonarApiStatusMessage -StatusCode $code -Route 'the handshake') -Id 'AzlSonarApi' -StatusCode $code -Token $Token)
        }
        $Session.TokenHash = Get-AzlSonarApiHash -Text $Token
    }
    finally { $response.Dispose() }
}

function Open-AzlSonarApiResponse {
    <#
    .SYNOPSIS
        GETs a route and returns the open response (status 200, body not read yet). Handles the handshake, a 401 after a Sonar
        restart (re-reads the token file), 429 (waits for Retry-After) and turns every other status into a clear error.
    #>
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpResponseMessage])]
    param(
        [Parameter(Mandatory)][string]$Origin,
        [Parameter(Mandatory)][string]$Route,
        [Parameter(Mandatory)][string]$PathAndQuery,
        [string]$Token,
        [string]$TokenFile,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$MaxRetry,
        [string]$Accept
    )

    $session = Get-AzlSonarApiSession -Origin $Origin
    $currentToken = Get-AzlSonarApiToken -Token $Token -TokenFile $TokenFile
    $retriesLeft = $MaxRetry
    $reconnected = $false
    while ($true) {
        # A new token (a restarted Sonar rewrote the file, or the caller gave another one) needs a new handshake.
        if ($currentToken -and $session.TokenHash -ne (Get-AzlSonarApiHash -Text $currentToken)) {
            Clear-AzlSonarApiSession -Origin $Origin
            $session = Get-AzlSonarApiSession -Origin $Origin
            Connect-AzlSonarApi -Session $session -Token $currentToken -TimeoutSeconds $TimeoutSeconds
        }
        $response = Send-AzlSonarApiRequest -Session $session -PathAndQuery $PathAndQuery -TimeoutSeconds $TimeoutSeconds -Token $currentToken -Accept $Accept
        $code = [int]$response.StatusCode
        if ($code -eq 200) { return $response }
        try {
            if ($code -eq 401) {
                # Sonar restarted (new token) or the token was wrong: drop the session; one more try when the token file now holds another token.
                Clear-AzlSonarApiSession -Origin $Origin
                if (-not $reconnected -and $TokenFile -and -not $Token) {
                    $reconnected = $true
                    $fresh = Get-AzlSonarApiToken -TokenFile $TokenFile
                    if ($fresh -and $fresh -ne $currentToken) {
                        Write-Verbose 'Sonar answered 401; the token file holds another token. Starting a new session.'
                        $currentToken = $fresh
                        $session = Get-AzlSonarApiSession -Origin $Origin
                        continue
                    }
                }
                throw (New-AzlSonarApiError -Message (Get-AzlSonarApiStatusMessage -StatusCode 401 -Route $Route) -Id 'AzlSonarApi' -StatusCode 401 -Target $Route -Token $currentToken)
            }
            $retryAfter = $null
            if ($code -eq 429) {
                $header = $response.Headers.RetryAfter
                if ($null -ne $header) {
                    $retryAfter = if ($null -ne $header.Delta) { [int][Math]::Ceiling($header.Delta.TotalSeconds) } elseif ($null -ne $header.Date) { [int][Math]::Max(0, [Math]::Ceiling(($header.Date - [DateTimeOffset]::UtcNow).TotalSeconds)) } else { $null }
                }
                if ($retriesLeft -gt 0) {
                    $wait = if ($null -ne $retryAfter) { [Math]::Min($retryAfter, $script:AzlSonarApiMaxRetryWaitSeconds) } else { 5 }
                    Write-Verbose "Sonar answered 429; waiting $wait second(s) (Retry-After) before trying again ($retriesLeft retries left)."
                    $retriesLeft--
                    Start-Sleep -Seconds $wait
                    continue
                }
            }
            $detail = ''
            try {
                $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
                try { $detail = Get-AzlSonarApiErrorText -Body ($response.Content.ReadAsStringAsync($cts.Token).GetAwaiter().GetResult()) }
                finally { $cts.Dispose() }
            }
            catch { Write-Verbose 'The error body could not be read.' }
            throw (New-AzlSonarApiError -Message (Get-AzlSonarApiStatusMessage -StatusCode $code -Route $Route -Detail $detail -RetryAfter $retryAfter) -Id 'AzlSonarApi' -StatusCode $code -Target $Route -Token $currentToken)
        }
        finally { $response.Dispose() }
    }
}

function Read-AzlSonarApiText {
    # The body of an open response as text, within the timeout.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response, [Parameter(Mandatory)][int]$TimeoutSeconds, [string]$Route)

    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try { return $Response.Content.ReadAsStringAsync($cts.Token).GetAwaiter().GetResult() }
    catch [System.OperationCanceledException] { throw (New-AzlSonarApiError -Message "Sonar did not finish sending $Route within $TimeoutSeconds second(s)." -Id 'AzlSonarApi.Timeout') }
    finally { $cts.Dispose() }
}

function Save-AzlSonarApiBody {
    <#
    .SYNOPSIS
        Copies the body of an open response to a file (through a .part file, moved when complete). The time limit applies to each chunk.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param([Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$TimeoutSeconds)

    $part = $Path + '.part'
    $source = $Response.Content.ReadAsStream()
    $target = [System.IO.FileStream]::new($part, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $buffer = [byte[]]::new(1MB)
        while ($true) {
            $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
            try { $read = $source.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult() }
            catch [System.OperationCanceledException] { throw (New-AzlSonarApiError -Message "Sonar stopped sending the export (nothing for $TimeoutSeconds second(s))." -Id 'AzlSonarApi.Timeout') }
            finally { $cts.Dispose() }
            if ($read -le 0) { break }
            $target.Write($buffer, 0, $read)
        }
        $target.Dispose(); $target = $null
        Move-Item -LiteralPath $part -Destination $Path -Force
    }
    catch {
        if ($null -ne $target) { $target.Dispose(); $target = $null }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw
    }
    finally { if ($null -ne $target) { $target.Dispose() } }
    return [System.IO.FileInfo]::new($Path)
}

function Read-AzlSonarApiEvent {
    <#
    .SYNOPSIS
        Reads a Server-Sent Events stream and writes { Event, Data (text) } for each event. Ends with the stream, the deadline, or the caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory)][int]$IdleSeconds,
        [AllowNull()][Nullable[datetime]]$Deadline
    )

    $reader = [System.IO.StreamReader]::new($Response.Content.ReadAsStream(), [System.Text.UTF8Encoding]::new($false))
    try {
        $name = 'message'
        $data = [System.Collections.Generic.List[string]]::new()
        while ($true) {
            $limit = $IdleSeconds
            if ($null -ne $Deadline) {
                $left = ($Deadline - [datetime]::UtcNow).TotalSeconds
                if ($left -le 0) { return }
                $limit = [Math]::Min($IdleSeconds, [Math]::Max(0.05, $left))
            }
            $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($limit))
            try { $line = $reader.ReadLineAsync($cts.Token).AsTask().GetAwaiter().GetResult() }
            catch [System.OperationCanceledException] {
                if ($null -ne $Deadline -and [datetime]::UtcNow -ge $Deadline.AddSeconds(-0.2)) { return }
                throw (New-AzlSonarApiError -Message "The event stream from Sonar went silent for $IdleSeconds second(s) (Sonar sends a ping every 15 seconds); it is probably gone." -Id 'AzlSonarApi.Timeout')
            }
            finally { $cts.Dispose() }
            if ($null -eq $line) {
                # The caller warns (a warning written here would not reach its -WarningVariable).
                [pscustomobject]@{ Event = '#ended'; Text = '' }
                return
            }
            if ($line -eq '') {
                if ($data.Count -gt 0) { [pscustomobject]@{ Event = $(if ($name) { $name } else { 'message' }); Text = ($data -join "`n") } }
                $name = 'message'
                $data.Clear()
                continue
            }
            if ($line.StartsWith(':')) { continue }
            $colon = $line.IndexOf(':')
            $field = if ($colon -ge 0) { $line.Substring(0, $colon) } else { $line }
            $value = if ($colon -ge 0) { $line.Substring($colon + 1) } else { '' }
            if ($value.StartsWith(' ')) { $value = $value.Substring(1) }
            switch ($field) {
                'event' { $name = $value }
                'data' { $data.Add($value) }
                default { Write-Verbose "Ignoring the stream field '$field'." }
            }
        }
    }
    finally { $reader.Dispose() }
}

function Invoke-AzlSonarApi {
    <#
    .SYNOPSIS
        Calls a route of Sonar's read-only HTTP API and returns the parsed JSON (or the text, or a saved file).
    .DESCRIPTION
        The supported way for a script, a pipeline step or an agent to read what Sonar shows. It does the access-token handshake
        once per Sonar address (GET /?t=<token> answers 302 and sets the sonar_t cookie, kept in a session cookie container) and
        sends only GET, only to this machine. The token comes from -Token or from the file Sonar wrote with
        Start-AzlSonar.ps1 -TokenFile; it is never printed, logged or put in an error message. A Sonar whose access token is off
        needs no token. After a Sonar restart (401) the token file is read again.

        /api/logs: one page by default (the answer object: server, lastSeq, truncated, tailer, files, lines). With -All it pages
        until caught up and returns one object: Server, Since, LastSeq, Pages, Lines, plus Gap (lines missed because they left
        the 5000-line ring buffer: the first returned seq is above Since + 1), Restarted (the server id changed: Sonar restarted
        and its sequence numbers start again; the helper then reads from 0), and a warning for each. Give -ServerId (the Server
        you stored last time) to notice a restart between two calls.

        /api/events needs -Follow: it writes one object { Event, Data } per event (hello, state, tailer, log) until the stream
        ends, -DurationSeconds passes, or the caller stops. /api/export is best saved with -OutFile (it can be hundreds of MB).

        Errors name the status and what to do: 401 (token wrong or Sonar restarted), 403 (not this machine), 404 (no such route, or
        replay/live mismatch), 405 (read-only), 429 (too many event streams; Retry-After is honoured up to -MaxRetry times).
    .PARAMETER Route
        One of /api/config, /api/about, /api/guidance, /api/details, /api/state, /api/logs, /api/events, /api/export, /api/replay.
    .PARAMETER Since
        /api/logs: the lines after this sequence number (seq > Since). Default 0.
    .PARAMETER All
        /api/logs: page until caught up (follows lastSeq while truncated is true) and report gaps and restarts.
    .PARAMETER Follow
        /api/events: read the Server-Sent Events stream and write one object per event.
    .PARAMETER EventName
        -Follow: write only these events (hello, state, tailer, log).
    .PARAMETER DurationSeconds
        -Follow: stop after this many seconds. Default 0: until the stream ends or the caller stops.
    .PARAMETER ServerId
        -All: the server id of your last call. A different one means Sonar restarted.
    .PARAMETER BaseUrl
        Where Sonar listens: http://localhost:<port> or http://127.0.0.1:<port>. Default http://localhost:8642.
    .PARAMETER Token
        The access token (32 hexadecimal characters). Prefer -TokenFile.
    .PARAMETER TokenFile
        The file Start-AzlSonar.ps1 -TokenFile wrote. Read again when Sonar answers 401.
    .PARAMETER Raw
        Return the body as text (alias AsJson). With -All or -Follow: one JSON line per result or event.
    .PARAMETER OutFile
        Save the answer to this file and return the file (use it for /api/export). A failed answer saves nothing.
    .PARAMETER TimeoutSeconds
        Seconds one request may take; for -Follow, the longest quiet time on the stream. Default 30.
    .PARAMETER MaxRetry
        Retries after 429, each after Retry-After seconds (at most 120). Default 2.
    .EXAMPLE
        Invoke-AzlSonarApi /api/state -TokenFile ./sonar.token | Select-Object phase, activePhase
    .EXAMPLE
        $page = Invoke-AzlSonarApi /api/logs -Since $cursor -ServerId $server -All -TokenFile ./sonar.token
        $cursor = $page.LastSeq; $server = $page.Server; $page.Lines | Where-Object level -eq 'error'
    .EXAMPLE
        Invoke-AzlSonarApi /api/events -Follow -EventName state -DurationSeconds 120 -TokenFile ./sonar.token
    .EXAMPLE
        Invoke-AzlSonarApi /api/export -OutFile ./sonar-export.json -TokenFile ./sonar.token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('/api/config', '/api/about', '/api/guidance', '/api/details', '/api/state', '/api/logs', '/api/events', '/api/export', '/api/replay')]
        [string]$Route,

        [ValidateRange(0, 999999999999999)]
        [long]$Since = 0,

        [switch]$All,

        [switch]$Follow,

        [ValidateSet('hello', 'state', 'tailer', 'log')]
        [string[]]$EventName,

        [ValidateRange(0, 86400)]
        [int]$DurationSeconds = 0,

        [string]$ServerId,

        [string]$BaseUrl = 'http://localhost:8642',

        [string]$Token,

        [string]$TokenFile,

        [Alias('AsJson')]
        [switch]$Raw,

        [string]$OutFile,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 30,

        [ValidateRange(0, 10)]
        [int]$MaxRetry = 2
    )

    $routeName = $script:AzlSonarApiRoutes | Where-Object { $_ -eq $Route.ToLowerInvariant() } | Select-Object -First 1
    $isLogs = $routeName -eq '/api/logs'
    $isEvents = $routeName -eq '/api/events'
    if (($All -or $PSBoundParameters.ContainsKey('Since') -or $PSBoundParameters.ContainsKey('ServerId')) -and -not $isLogs) { throw '-Since, -All and -ServerId belong to /api/logs.' }
    if (($Follow -or $PSBoundParameters.ContainsKey('EventName') -or $PSBoundParameters.ContainsKey('DurationSeconds')) -and -not $isEvents) { throw '-Follow, -EventName and -DurationSeconds belong to /api/events.' }
    if ($isEvents -and -not $Follow) { throw '/api/events is a stream that never ends: add -Follow (and -DurationSeconds to stop it).' }
    if ($OutFile -and ($All -or $Follow)) { throw '-OutFile saves one answer: it cannot be combined with -All or -Follow.' }
    if ($ServerId -and -not $All) { throw '-ServerId belongs to -All (a single page carries its own server id).' }
    $origin = ConvertTo-AzlSonarApiOrigin -BaseUrl $BaseUrl
    $outPath = ''
    if ($OutFile) {
        $outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
        if (Test-Path -LiteralPath $outPath -PathType Container) { throw "-OutFile is a folder: $outPath" }
        $outParent = [System.IO.Path]::GetDirectoryName($outPath)
        if (-not (Test-Path -LiteralPath $outParent -PathType Container)) { throw "The folder of -OutFile does not exist: $outParent" }
    }
    $common = @{ Origin = $origin; Token = $Token; TokenFile = $TokenFile; TimeoutSeconds = $TimeoutSeconds; MaxRetry = $MaxRetry }

    if ($Follow) {
        $response = Open-AzlSonarApiResponse @common -Route $routeName -PathAndQuery $routeName -Accept 'text/event-stream'
        $deadline = if ($DurationSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($DurationSeconds) } else { $null }
        try {
            # A pipeline, not a collected list: each event is written as it arrives.
            Read-AzlSonarApiEvent -Response $response -IdleSeconds $TimeoutSeconds -Deadline $deadline | ForEach-Object {
                $item = $_
                if ($item.Event -eq '#ended') { Write-Warning 'The event stream ended (Sonar stopped, or dropped this client). Reconnect and catch up with /api/logs as docs/api.md describes.'; return }
                if ($EventName -and $item.Event -notin $EventName) { return }
                if ($Raw) { '{{"event":{0},"data":{1}}}' -f (ConvertTo-Json -InputObject $item.Event -Compress), $item.Text; return }
                $parsed = $item.Text
                try { $parsed = $item.Text | ConvertFrom-Json -Depth 100 -ErrorAction Stop }
                catch { Write-Verbose "The $($item.Event) event is not JSON; its text is returned." }
                [pscustomobject]@{ PSTypeName = 'AzlSonar.ApiEvent'; Event = $item.Event; Data = $parsed }
            }
        }
        finally { $response.Dispose() }
        return
    }

    if ($All) {
        $cursor = $Since
        $serverSeen = $ServerId
        $lines = [System.Collections.Generic.List[object]]::new()
        $pages = 0
        $restarted = $false
        $gap = $false
        $missedFrom = $null
        $missedTo = $null
        $missed = [long]0
        $restarts = 0
        $lastSeq = $Since
        while ($true) {
            $response = Open-AzlSonarApiResponse @common -Route $routeName -PathAndQuery "/api/logs?since=$cursor"
            try { $text = Read-AzlSonarApiText -Response $response -TimeoutSeconds $TimeoutSeconds -Route $routeName } finally { $response.Dispose() }
            $page = $text | ConvertFrom-Json -Depth 100
            $pages++
            if ($serverSeen -and [string]$page.server -ne $serverSeen) {
                # Another instance id: Sonar restarted. Its sequence numbers start again, so the old cursor means nothing.
                $restarts++
                if ($restarts -gt 5) { throw (New-AzlSonarApiError -Message 'Sonar restarted more than five times while its logs were read; stopping.' -Id 'AzlSonarApi.Restarts') }
                $restarted = $true
                Write-Warning 'Sonar was restarted (its server id changed): sequence numbers start again from 1. Reading the logs from the start; lines read before the restart are dropped.'
                $serverSeen = [string]$page.server
                $lines.Clear()
                $gap = $false; $missedFrom = $null; $missedTo = $null; $missed = 0
                # The page just read was asked for with the old cursor (and may be clamped): read again from 0.
                $cursor = 0
                continue
            }
            $serverSeen = [string]$page.server
            $pageLines = @($page.lines)
            $expectedFrom = $cursor + 1
            $firstSeq = if ($pageLines.Count -gt 0) { [long]$pageLines[0].seq } else { $null }
            if ($null -ne $firstSeq -and $firstSeq -gt $expectedFrom) {
                if (-not $gap) { $missedFrom = $expectedFrom }
                $gap = $true; $missedTo = $firstSeq - 1; $missed += ($firstSeq - $expectedFrom)
            }
            elseif ($null -eq $firstSeq -and [long]$page.lastSeq -gt $cursor -and -not [bool]$page.truncated) {
                # The newest seq is above the cursor but no line is left: they all left the ring buffer.
                if (-not $gap) { $missedFrom = $expectedFrom }
                $gap = $true; $missedTo = [long]$page.lastSeq; $missed += ([long]$page.lastSeq - $cursor)
            }
            foreach ($line in $pageLines) { $lines.Add($line) }
            $lastSeq = [long]$page.lastSeq
            if (-not [bool]$page.truncated) { break }
            if ($lastSeq -le $cursor) { throw (New-AzlSonarApiError -Message 'Sonar says more lines remain but gave no newer sequence number; stopping.' -Id 'AzlSonarApi.NoProgress') }
            $cursor = $lastSeq
            if ($pages -ge 100000) { throw (New-AzlSonarApiError -Message 'More than 100000 pages of logs were read; stopping.' -Id 'AzlSonarApi.TooManyPages') }
        }
        if ($gap) { Write-Warning "Log lines $missedFrom to $missedTo ($missed line(s)) left Sonar's 5000-line ring buffer before they were read and are missing." }
        $result = [pscustomobject]@{
            PSTypeName   = 'AzlSonar.ApiLogs'
            Server       = $serverSeen
            Since        = $Since
            LastSeq      = $lastSeq
            Pages        = $pages
            Lines        = $lines.ToArray()
            Gap          = $gap
            MissedFrom   = $missedFrom
            MissedTo     = $missedTo
            MissedCount  = $missed
            Restarted    = $restarted
        }
        if ($Raw) { return ($result | ConvertTo-Json -Depth 100 -Compress) }
        return $result
    }

    $pathAndQuery = if ($isLogs) { "/api/logs?since=$Since" } else { $routeName }
    $response = Open-AzlSonarApiResponse @common -Route $routeName -PathAndQuery $pathAndQuery
    try {
        if ($outPath) { return (Save-AzlSonarApiBody -Response $response -Path $outPath -TimeoutSeconds $TimeoutSeconds) }
        $text = Read-AzlSonarApiText -Response $response -TimeoutSeconds $TimeoutSeconds -Route $routeName
    }
    finally { $response.Dispose() }
    if ($Raw) { return $text }
    return ($text | ConvertFrom-Json -Depth 100)
}
