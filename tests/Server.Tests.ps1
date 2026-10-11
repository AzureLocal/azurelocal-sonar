#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# HTTP tests use localhost only, on a free high port. No Azure, no node: the poller and tailer workers are never
# started (Start-AzlSonarWorker is mocked in the end-to-end test; the handler tests build the server table directly).

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    Add-Type -AssemblyName System.Net.Http

    # A config with Key Vault secret names, so the tests can prove none of them reaches the page.
    $script:SecretConfig = New-SonarConfigObject
    $script:SecretConfig.credential = [pscustomobject]@{ source = 'keyvault'; vault = 'kv-sonar-test'; usernameSecret = 'sonar-user-secret'; passwordSecret = 'sonar-pass-secret' }
    $script:SecretConfigPath = Join-Path $TestDrive 'sonar.config.json'
    ConvertTo-SonarConfigJson $script:SecretConfig | Set-Content -LiteralPath $script:SecretConfigPath
    $script:Config = Read-AzlSonarConfig -Path $script:SecretConfigPath
    $script:SecretPattern = 'kv-sonar-test|sonar-user-secret|sonar-pass-secret|192\.0\.2\.|subscriptionId|00000000-0000-0000-0000-000000000000|password'
    # The export also carries the guidance text, which mentions the word password; check the values only.
    $script:SecretValuePattern = 'kv-sonar-test|sonar-user-secret|sonar-pass-secret|192\.0\.2\.|subscriptionId|00000000-0000-0000-0000-000000000000'
}

Describe 'Resolve-AzlSonarStaticPath (path traversal guard)' {
    BeforeAll {
        $script:WebRoot = Join-Path $script:SonarModuleRoot 'web'
    }

    It 'maps <UrlPath> to <Expected>' -TestCases @(
        @{ UrlPath = '/'; Expected = 'index.html' }
        @{ UrlPath = '/index.html'; Expected = 'index.html' }
        @{ UrlPath = '/app.js'; Expected = 'app.js' }
        @{ UrlPath = '/app.css'; Expected = 'app.css' }
    ) {
        param($UrlPath, $Expected)
        $full = InModuleScope AzlSonar -Parameters @{ R = $script:WebRoot; U = $UrlPath } { param($R, $U) Resolve-AzlSonarStaticPath -WebRoot $R -UrlPath $U }
        $full | Should -Be (Join-Path $script:WebRoot $Expected)
    }

    It 'refuses <UrlPath>' -TestCases @(
        @{ UrlPath = '/../AzlSonar.psd1' }
        @{ UrlPath = '/..\AzlSonar.psd1' }
        @{ UrlPath = '/../../Start-AzlSonar.ps1' }
        @{ UrlPath = '/sub/../index.html' }
        @{ UrlPath = '/..' }
        @{ UrlPath = '/C:/Windows/win.ini' }
        @{ UrlPath = 'C:\Windows\win.ini' }
        @{ UrlPath = '/\\server\share\x' }
        @{ UrlPath = '/missing.html' }
        @{ UrlPath = '/data/phase-guidance.json' }
    ) {
        param($UrlPath)
        InModuleScope AzlSonar -Parameters @{ R = $script:WebRoot; U = $UrlPath } { param($R, $U) Resolve-AzlSonarStaticPath -WebRoot $R -UrlPath $U } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-AzlSonarHttpRequest (real HttpListener on localhost, handler called directly)' {
    BeforeAll {
        $script:Port = Get-SonarFreeTcpPort
        $script:BaseUrl = "http://localhost:$($script:Port)/"
        $script:Listener = [System.Net.HttpListener]::new()
        $script:Listener.Prefixes.Add($script:BaseUrl)
        $script:Listener.Start()
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseProxy = $false
        $script:Client = [System.Net.Http.HttpClient]::new($handler)
        $script:Client.Timeout = [TimeSpan]::FromSeconds(20)

        $state = InModuleScope AzlSonar -Parameters @{ Config = $script:Config } {
            param($Config)
            $s = Get-AzlSonarInitialState -Config $Config
            $s.phase = 'validation'
            $s.polledAt = '2026-10-10T18:10:00Z'
            $s
        }
        $script:Server = InModuleScope AzlSonar -Parameters @{ Config = $script:Config; State = $state } {
            param($Config, $State)
            $shared = Initialize-AzlSonarSharedState
            Publish-AzlSonarState -Shared $shared -State $State
            Add-AzlSonarLogLine -Shared $shared -Line @(
                [pscustomobject]@{ file = 'C:\CloudDeployment\Logs\a.log'; text = 'first' }
                [pscustomobject]@{ file = 'C:\CloudDeployment\Logs\a.log'; text = 'ERROR second' }
                [pscustomobject]@{ file = 'C:\CloudDeployment\Logs\a.log'; text = 'WARNING third' }
            )
            $shared.Files = @([ordered]@{ path = 'C:\CloudDeployment\Logs\a.log'; size = 30; offset = 30; lastWriteUtc = '2026-10-10T18:09:00Z' })
            Publish-AzlSonarTailerStatus -Shared $shared -Status ([ordered]@{ state = 'connected'; reason = $null; node = 'node01' })
            @{
                Shared       = $shared
                WebRoot      = Join-Path $script:AzlSonarModuleRoot 'web'
                ConfigJson   = ConvertTo-AzlSonarJson (ConvertTo-AzlSonarPublicConfig -Config $Config -StartedAt ([datetime]'2026-10-10T18:00:00Z'))
                GuidanceJson = ConvertTo-AzlSonarJson (Get-AzlSonarPhaseGuidance -IdentityModel $Config.identityModel)
                ClusterName  = $Config.clusterName
                Version      = '0.1.0'
                Clients      = [System.Collections.Generic.List[hashtable]]::new()
            }
        }

        $script:PendingContext = $null
        function Wait-SonarContext {
            # Returns the listener context for the request, or $null when http.sys answered it itself (for example a
            # 400 for a malformed path) so the request never reached the handler. One GetContextAsync stays pending
            # across calls so a context is never lost.
            param([System.Threading.Tasks.Task]$Send)
            if ($null -eq $script:PendingContext) { $script:PendingContext = $script:Listener.GetContextAsync() }
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while ([datetime]::UtcNow -lt $deadline) {
                if ($script:PendingContext.IsCompleted) {
                    $context = $script:PendingContext.Result
                    $script:PendingContext = $null
                    return $context
                }
                if ($null -ne $Send -and $Send.IsCompleted) { return $null }
                $null = $script:PendingContext.Wait(50)
            }
            throw 'Neither the listener nor the client finished within 10 s.'
        }
        function Invoke-SonarRequest {
            # Sends one request, serves it with the module's handler and returns the response.
            param([string]$PathAndQuery, [string]$Method = 'GET')
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $script:BaseUrl.TrimEnd('/') + $PathAndQuery)
            $send = $script:Client.SendAsync($request)
            $context = Wait-SonarContext -Send $send
            if ($null -ne $context) {
                InModuleScope AzlSonar -Parameters @{ Context = $context; Server = $script:Server } { param($Context, $Server) Invoke-AzlSonarHttpRequest -Context $Context -Server $Server }
            }
            $response = $send.GetAwaiter().GetResult()
            $headers = @{}
            foreach ($h in $response.Headers) { $headers[$h.Key] = ($h.Value -join ',') }
            foreach ($h in $response.Content.Headers) { $headers[$h.Key] = ($h.Value -join ',') }
            [pscustomobject]@{
                Status  = [int]$response.StatusCode
                Body    = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                Headers = $headers
            }
        }
    }

    AfterAll {
        if ($script:Client) { $script:Client.Dispose() }
        if ($script:Listener) { $script:Listener.Stop(); $script:Listener.Close() }
    }

    It 'GET /api/config returns the public config and no secrets' {
        $r = Invoke-SonarRequest '/api/config'
        $r.Status | Should -Be 200
        $r.Headers['Content-Type'] | Should -BeLike 'application/json*'
        $r.Headers['Cache-Control'] | Should -Be 'no-store'
        $r.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
        $r.Body | Should -Not -Match $script:SecretPattern
        $c = $r.Body | ConvertFrom-Json
        $c.cluster | Should -Be 'clus01'
        $c.resourceGroup | Should -Be 'rg-example-azl'
        $c.identityModel | Should -Be 'LocalIdentity'
        $c.pollSeconds | Should -Be 20
        @($c.nodes).Count | Should -Be 2
        @($c.nodes | Where-Object seed).name | Should -Be 'node01'
        @($c.logs.paths).Count | Should -Be 5
    }

    It 'GET /api/state returns the latest state' {
        $r = Invoke-SonarRequest '/api/state'
        $r.Status | Should -Be 200
        $s = $r.Body | ConvertFrom-Json
        $s.cluster | Should -Be 'clus01'
        $s.phase | Should -Be 'validation'
        $s.validation.status | Should -Be 'notstarted'
        @($s.nodes).Count | Should -Be 2
    }

    It 'GET /api/guidance returns the four phases for the identity model' {
        $r = Invoke-SonarRequest '/api/guidance'
        $r.Status | Should -Be 200
        $g = $r.Body | ConvertFrom-Json
        $g.identityModel | Should -Be 'LocalIdentity'
        $g.available | Should -BeTrue
        @($g.phases.PSObject.Properties.Name) | Should -Be @('provisioning', 'validation', 'deployment', 'post-deployment')
    }

    It 'GET /api/logs returns tailer, files and every line' {
        $r = Invoke-SonarRequest '/api/logs'
        $r.Status | Should -Be 200
        $l = $r.Body | ConvertFrom-Json
        $l.tailer.state | Should -Be 'connected'
        @($l.files).Count | Should -Be 1
        $l.files[0].offset | Should -Be 30
        @($l.lines).ForEach({ $_.seq }) | Should -Be @(1, 2, 3)
        @($l.lines).ForEach({ $_.level }) | Should -Be @('info', 'error', 'warning')
        $l.server | Should -Be $script:Server.Shared.ServerId
        $l.server | Should -Match '^[0-9a-f]{32}$'
        $l.lastSeq | Should -Be 3
        @($l.lines)[0].timeSource | Should -Be 'received'
        $r.Body | Should -Match '"received":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"'
    }

    It 'GET /api/logs?since=2 returns only newer lines' {
        $l = (Invoke-SonarRequest '/api/logs?since=2').Body | ConvertFrom-Json
        @($l.lines).ForEach({ $_.seq }) | Should -Be @(3)
    }

    It 'GET /api/logs?since=3 returns an empty lines array (not null) and the cursor' {
        $r = Invoke-SonarRequest '/api/logs?since=3'
        $r.Body | Should -BeLike '*"lines":`[`]*'
        ($r.Body | ConvertFrom-Json).lastSeq | Should -Be 3
    }

    It 'GET /api/logs?since=abc is a 400 with a JSON error' {
        $r = Invoke-SonarRequest '/api/logs?since=abc'
        $r.Status | Should -Be 400
        ($r.Body | ConvertFrom-Json).error | Should -Be 'since must be a whole number.'
    }

    It 'GET /api/export returns one bundle as an attachment, without secrets' {
        $r = Invoke-SonarRequest '/api/export'
        $r.Status | Should -Be 200
        $r.Headers['Content-Disposition'] | Should -Match '^attachment; filename="azlsonar-clus01-\d{8}-\d{6}\.json"$'
        $r.Body | Should -Not -Match $script:SecretValuePattern
        $e = $r.Body | ConvertFrom-Json -Depth 64
        $e.export.tool | Should -Be 'AzL Sonar'
        $e.export.snapshots | Should -Be 1
        $e.export.timelineMode | Should -Be 'change-only'
        $e.export.timelineMax | Should -Be 5000
        $e.export.timelineDropped | Should -Be 0
        $e.export.latestStateIncluded | Should -BeTrue
        $e.export.logRingSize | Should -Be 5000
        $e.export.logLinesKept | Should -Be 3
        $e.export.logFirstSeq | Should -Be 1
        $e.export.logLastSeq | Should -Be 3
        $e.export.logLinesDropped | Should -Be 0
        $e.export.server | Should -Be $script:Server.Shared.ServerId
        $e.config.cluster | Should -Be 'clus01'
        $e.state.phase | Should -Be 'validation'
        @($e.timeline).Count | Should -Be 1
        @($e.logs.lines).Count | Should -Be 3
    }

    It 'GET /api/unknown is a JSON 404' {
        $r = Invoke-SonarRequest '/api/unknown'
        $r.Status | Should -Be 404
        ($r.Body | ConvertFrom-Json).error | Should -Be 'Unknown API route: /api/unknown'
    }

    It 'GET /missing.html is a 404' {
        $r = Invoke-SonarRequest '/missing.html'
        $r.Status | Should -Be 404
        $r.Body | Should -Be 'Not found.'
    }

    It '<Method> /api/state is a 405 with Allow: GET' -TestCases @(
        @{ Method = 'POST' }, @{ Method = 'PUT' }, @{ Method = 'DELETE' }, @{ Method = 'PATCH' }
    ) {
        param($Method)
        $r = Invoke-SonarRequest '/api/state' -Method $Method
        $r.Status | Should -Be 405
        $r.Headers['Allow'] | Should -Be 'GET'
    }

    It 'GET / serves the page as HTML' {
        $r = Invoke-SonarRequest '/'
        $r.Status | Should -Be 200
        $r.Headers['Content-Type'] | Should -Be 'text/html; charset=utf-8'
        $r.Body | Should -BeLike '*<script src="app.js"*'
    }

    It 'GET /<File> is served as <Type>' -TestCases @(
        @{ File = 'app.js'; Type = 'text/javascript; charset=utf-8' }
        @{ File = 'app.css'; Type = 'text/css; charset=utf-8' }
    ) {
        param($File, $Type)
        $r = Invoke-SonarRequest "/$File"
        $r.Status | Should -Be 200
        $r.Headers['Content-Type'] | Should -Be $Type
        $r.Body.Length | Should -BeGreaterThan 100
    }

    It 'never serves a file outside the web folder for <Path>' -TestCases @(
        @{ Path = '/%2e%2e/AzlSonar.psd1' }
        @{ Path = '/..%2fAzlSonar.psd1' }
        @{ Path = '/..%5cAzlSonar.psd1' }
        @{ Path = '/%2e%2e%2f%2e%2e%2fStart-AzlSonar.ps1' }
        @{ Path = '/web/..%2f..%2fAzlSonar.psm1' }
    ) {
        param($Path)
        $r = Invoke-SonarRequest $Path
        $r.Status | Should -BeIn @(400, 403, 404)
        $r.Body | Should -Not -Match 'RootModule|Set-StrictMode|Export-ModuleMember'
    }

    It 'GET /api/events opens a Server-Sent Events stream with state, tailer and log events' {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $script:BaseUrl + 'api/events')
        $send = $script:Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        $context = Wait-SonarContext -Send $null
        $context | Should -Not -BeNullOrEmpty
        InModuleScope AzlSonar -Parameters @{ Context = $context; Server = $script:Server } {
            param($Context, $Server)
            Invoke-AzlSonarHttpRequest -Context $Context -Server $Server
            # The client starts at the current log sequence; add one line so a log event is due.
            Add-AzlSonarLogLine -Shared $Server.Shared -Line @([pscustomobject]@{ file = 'f'; text = 'fourth' })
            # Writes are asynchronous: drive the dispatch a few turns, as the main loop does every 250 ms.
            $deadline = [datetime]::UtcNow.AddSeconds(5)
            do {
                Send-AzlSonarSseUpdate -Server $Server
                $c = $Server.Clients[0]
                $done = $c.LogSeq -ge $Server.Shared.LogSeq -and $null -eq $c.Pending -and $c.Queue.Count -eq 0
                if (-not $done) { Start-Sleep -Milliseconds 50 }
            } until ($done -or [datetime]::UtcNow -gt $deadline)
        }
        try {
            $response = $send.GetAwaiter().GetResult()
            [int]$response.StatusCode | Should -Be 200
            $response.Content.Headers.ContentType.MediaType | Should -Be 'text/event-stream'
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader = [System.IO.StreamReader]::new($stream)
            $text = [System.Text.StringBuilder]::new()
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while ([datetime]::UtcNow -lt $deadline -and $text.ToString() -notmatch 'event: log') {
                $read = $reader.ReadLineAsync()
                if (-not $read.Wait(5000)) { break }
                $null = $text.AppendLine($read.Result)
            }
            # Read the data line of the log event.
            $read = $reader.ReadLineAsync()
            if ($read.Wait(5000)) { $null = $text.AppendLine($read.Result) }
            $all = $text.ToString()
            $all | Should -BeLike 'retry: 5000*'
            $all | Should -BeLike ('*event: hello*data: {"server":"' + $script:Server.Shared.ServerId + '","since":3}*')
            $all | Should -BeLike ('*event: log*data: {"server":"' + $script:Server.Shared.ServerId + '","lines":`[*')
            $all | Should -BeLike '*event: state*data: {"cluster":"clus01"*'
            $all | Should -BeLike '*event: tailer*"state":"connected"*'
            $all | Should -BeLike '*event: log*"text":"fourth"*'
            $all | Should -Not -BeLike '*"text":"first"*'
        }
        finally {
            InModuleScope AzlSonar -Parameters @{ Server = $script:Server } {
                param($Server)
                foreach ($c in @($Server.Clients.ToArray())) { try { $c.Response.Abort() } catch { $null = $_ } }
                $Server.Clients.Clear()
            }
        }
    }
}

Describe 'SSE live streams: client cap (real HttpListener on localhost)' {
    BeforeAll {
        $script:CapPort = Get-SonarFreeTcpPort
        $script:CapListener = [System.Net.HttpListener]::new()
        $script:CapListener.Prefixes.Add("http://localhost:$($script:CapPort)/")
        $script:CapListener.Start()
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $script:CapClient = [System.Net.Http.HttpClient]::new($handler)
        $script:CapClient.Timeout = [TimeSpan]::FromSeconds(20)
    }

    AfterAll {
        if ($script:CapClient) { $script:CapClient.Dispose() }
        if ($script:CapListener) { $script:CapListener.Stop(); $script:CapListener.Close() }
    }

    It 'answers 503 with Retry-After when 10 streams are already open' {
        $server = InModuleScope AzlSonar {
            $clients = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($i in 1..10) { $clients.Add(@{ Dummy = $i }) }
            @{ Shared = Initialize-AzlSonarSharedState; Clients = $clients }
        }
        $send = $script:CapClient.GetAsync("http://localhost:$($script:CapPort)/api/events")
        $pending = $script:CapListener.GetContextAsync()
        $null = $pending.Wait(10000)
        InModuleScope AzlSonar -Parameters @{ Context = $pending.Result; Server = $server } { param($Context, $Server) Invoke-AzlSonarHttpRequest -Context $Context -Server $Server }
        $response = $send.GetAwaiter().GetResult()
        [int]$response.StatusCode | Should -Be 503
        @($response.Headers.GetValues('Retry-After')) | Should -Be @('30')
        $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | Should -BeLike '*at most 10 live streams*'
        $server.Clients.Count | Should -Be 10
    }
}

Describe 'SSE flow control (fake clients, no network)' {
    BeforeAll {
        function Get-FakeSseClient {
            # ok: WriteAsync completes at once into a MemoryStream; stall: never completes; fail: completes faulted.
            param([string]$Mode = 'ok', [long]$LogSeq = 0)
            $stream = [pscustomobject]@{ Sink = [System.IO.MemoryStream]::new(); Mode = $Mode; Tcs = [System.Threading.Tasks.TaskCompletionSource[bool]]::new(); Writes = 0 }
            $stream | Add-Member -MemberType ScriptMethod -Name WriteAsync -Value {
                param([byte[]]$Buffer, [int]$Offset, [int]$Count)
                $this.Writes++
                if ($this.Mode -eq 'stall') { return $this.Tcs.Task }
                if ($this.Mode -eq 'fail') { return [System.Threading.Tasks.Task]::FromException([System.IO.IOException]::new('connection reset')) }
                $this.Sink.Write($Buffer, $Offset, $Count)
                return [System.Threading.Tasks.Task]::CompletedTask
            }
            $response = [pscustomobject]@{ Aborted = $false }
            $response | Add-Member -MemberType ScriptMethod -Name Abort -Value { $this.Aborted = $true }
            InModuleScope AzlSonar -Parameters @{ R = $response; S = $stream; L = $LogSeq } { param($R, $S, $L) New-AzlSonarSseClient -Response $R -Stream $S -LogSeq $L }
        }
        function Get-FakeServer {
            param([int]$RingSize = 5000)
            InModuleScope AzlSonar -Parameters @{ RingSize = $RingSize } {
                param($RingSize)
                @{ Shared = Initialize-AzlSonarSharedState -RingSize $RingSize; Clients = [System.Collections.Generic.List[hashtable]]::new() }
            }
        }
        function Add-FakeLine([hashtable]$Server, [int]$Count = 1) {
            InModuleScope AzlSonar -Parameters @{ Server = $Server; Count = $Count } {
                param($Server, $Count)
                Add-AzlSonarLogLine -Shared $Server.Shared -Line @(foreach ($i in 1..$Count) { [pscustomobject]@{ file = 'f.log'; text = "line $i" } })
            }
        }
        function Send-Update([hashtable]$Server) {
            InModuleScope AzlSonar -Parameters @{ Server = $Server } { param($Server) Send-AzlSonarSseUpdate -Server $Server }
        }
        function Get-SinkText([hashtable]$Client) { [System.Text.Encoding]::UTF8.GetString($Client.Stream.Sink.ToArray()) }
    }

    It 'never waits for a stalled client, and the other clients still get their events' {
        $server = Get-FakeServer
        $slow = Get-FakeSseClient -Mode stall
        $fast = Get-FakeSseClient -Mode ok
        $server.Clients.Add($slow); $server.Clients.Add($fast)
        Add-FakeLine $server 2
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Send-Update $server
        Add-FakeLine $server 3
        Send-Update $server
        $watch.Stop()
        $watch.ElapsedMilliseconds | Should -BeLessThan 3000
        Get-SinkText $fast | Should -BeLike '*event: log*"text":"line 2"*event: log*"text":"line 3"*'
        $fast.LogSeq | Should -Be 5
        $slow.Stream.Writes | Should -Be 1 -Because 'nothing more is written while its first write is in flight'
        $slow.LogSeq | Should -Be 2 -Because 'its cursor waits until the write completes'
        $server.Clients.Count | Should -Be 2
    }

    It 'continues a stalled client once its write completes' {
        $server = Get-FakeServer
        $slow = Get-FakeSseClient -Mode stall
        $server.Clients.Add($slow)
        Add-FakeLine $server 1
        Send-Update $server
        Add-FakeLine $server 1
        Send-Update $server
        $slow.Stream.Writes | Should -Be 1
        $slow.Stream.Mode = 'ok'
        $null = $slow.Stream.Tcs.TrySetResult($true)
        Send-Update $server
        $slow.Stream.Writes | Should -Be 2
        $slow.LogSeq | Should -Be 2
        $server.Clients.Count | Should -Be 1
    }

    It 'drops a client whose write has been in flight longer than the write timeout' {
        $server = Get-FakeServer
        $slow = Get-FakeSseClient -Mode stall
        $server.Clients.Add($slow)
        Add-FakeLine $server 1
        Send-Update $server
        $slow.PendingSince = [datetime]::UtcNow.AddSeconds(-60)
        Send-Update $server
        $server.Clients.Count | Should -Be 0
        $slow.Response.Aborted | Should -BeTrue
    }

    It 'drops a client whose write failed' {
        $server = Get-FakeServer
        $broken = Get-FakeSseClient -Mode fail
        $server.Clients.Add($broken)
        Add-FakeLine $server 1
        Send-Update $server
        $server.Clients.Count | Should -Be 0
        $broken.Response.Aborted | Should -BeTrue
    }

    It 'drops a client that fell behind the log ring buffer' {
        $server = Get-FakeServer -RingSize 5
        $behind = Get-FakeSseClient -Mode ok -LogSeq 0
        $server.Clients.Add($behind)
        Add-FakeLine $server 10
        Send-Update $server
        $server.Clients.Count | Should -Be 0
        $behind.Response.Aborted | Should -BeTrue
    }

    It 'bounds the per-client queue (a client past the byte limit counts as fallen behind)' {
        $client = Get-FakeSseClient -Mode ok
        {
            InModuleScope AzlSonar -Parameters @{ Client = $client } {
                param($Client)
                Add-AzlSonarSseText -Client $Client -Text ('x' * ($script:AzlSonarSseMaxQueuedBytes + 1))
            }
        } | Should -Throw '*fell behind*'
        $client.Queue.Count | Should -Be 0
    }

    It 'writes everything queued as one buffer and sends a ping every 15 s' {
        $server = Get-FakeServer
        $client = Get-FakeSseClient -Mode ok
        $server.Clients.Add($client)
        $client.LastPing = [datetime]::UtcNow.AddSeconds(-20)
        Send-Update $server
        $client.Stream.Writes | Should -Be 1
        Get-SinkText $client | Should -BeLike '*: ping*'
    }
}

Describe 'Start-AzlSonarServer end to end (random port, mocked poller and tailer)' {
    BeforeAll {
        $script:E2EPort = Get-SonarFreeTcpPort
        $script:E2EBase = "http://localhost:$($script:E2EPort)"
        $script:Driver = @{ Tasks = $null; Started = $null; Calls = 0; Results = @{} }
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $script:E2EClient = [System.Net.Http.HttpClient]::new($handler)
        $script:E2EClient.Timeout = [TimeSpan]::FromSeconds(20)
    }

    AfterAll {
        if ($script:E2EClient) { $script:E2EClient.Dispose() }
    }

    It 'serves the API on localhost, starts both workers and stops cleanly' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { $null }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith {
            @{ Name = $Name; Handle = [pscustomobject]@{ IsCompleted = $false }; Reported = $false; PowerShell = $null; Runspace = $null }
        }
        Mock -ModuleName AzlSonar -CommandName Stop-AzlSonarWorker -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Start-Process -MockWith { throw 'The browser must not open in tests.' }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No ARM call is expected.' }
        Mock -ModuleName AzlSonar -CommandName New-PSSession -MockWith { throw 'No remoting is expected.' }
        # The main loop calls Send-AzlSonarSseUpdate on every turn: use it to drive requests and to stop the server.
        Mock -ModuleName AzlSonar -CommandName Send-AzlSonarSseUpdate -MockWith {
            $d = $script:Driver
            $d.Calls++
            if ($null -eq $d.Tasks) {
                $d.Started = [datetime]::UtcNow
                $d.Tasks = [ordered]@{}
                foreach ($p in '/api/config', '/api/state', '/api/guidance', '/api/logs', '/api/nope', '/') {
                    $d.Tasks[$p] = $script:E2EClient.GetAsync($script:E2EBase + $p)
                }
                $d.Tasks['POST /api/config'] = $script:E2EClient.PostAsync($script:E2EBase + '/api/config', [System.Net.Http.StringContent]::new('{}'))
            }
            $pendingTasks = @($d.Tasks.Values | Where-Object { -not $_.IsCompleted })
            if ($pendingTasks.Count -eq 0) {
                foreach ($key in $d.Tasks.Keys) {
                    $t = $d.Tasks[$key]
                    if ($t.IsFaulted) { $d.Results[$key] = @{ Status = -1; Body = $t.Exception.InnerException.Message } }
                    else { $d.Results[$key] = @{ Status = [int]$t.Result.StatusCode; Body = $t.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult() } }
                }
                throw 'AZLSONAR-TEST-STOP'
            }
            if (([datetime]::UtcNow - $d.Started).TotalSeconds -gt 30) { throw 'AZLSONAR-TEST-TIMEOUT' }
        }

        { Start-AzlSonarServer -ConfigPath $script:SecretConfigPath -Port $script:E2EPort -NoBrowser -InformationAction SilentlyContinue } |
            Should -Throw '*AZLSONAR-TEST-STOP*'

        $results = $script:Driver.Results
        $results['/api/config'].Status | Should -Be 200
        $results['/api/config'].Body | Should -Not -Match $script:SecretPattern
        ($results['/api/config'].Body | ConvertFrom-Json).cluster | Should -Be 'clus01'
        $results['/api/config'].Body | Should -Match '"startedAt":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        $results['/api/state'].Status | Should -Be 200
        ($results['/api/state'].Body | ConvertFrom-Json).phase | Should -Be 'provisioning'
        $results['/api/guidance'].Status | Should -Be 200
        @(($results['/api/guidance'].Body | ConvertFrom-Json).phases.PSObject.Properties.Name).Count | Should -Be 4
        $results['/api/logs'].Status | Should -Be 200
        ($results['/api/logs'].Body | ConvertFrom-Json).PSObject.Properties.Name | Should -Be @('server', 'lastSeq', 'tailer', 'files', 'lines')
        ($results['/api/logs'].Body | ConvertFrom-Json).server | Should -Be ($results['/api/config'].Body | ConvertFrom-Json).serverId
        $results['/api/nope'].Status | Should -Be 404
        $results['/'].Status | Should -Be 200
        $results['POST /api/config'].Status | Should -Be 405

        Should -Invoke -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -Times 1 -Exactly -ParameterFilter { $Command -eq 'Invoke-AzlSonarPollerLoop' }
        Should -Invoke -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -Times 1 -Exactly -ParameterFilter { $Command -eq 'Invoke-AzlSonarTailerLoop' }
        Should -Invoke -ModuleName AzlSonar -CommandName Stop-AzlSonarWorker -Times 2 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -Times 0 -Exactly

        # The listener is closed: the port accepts no more requests.
        $probe = [System.Net.Sockets.TcpClient]::new()
        try {
            $connect = $probe.ConnectAsync('127.0.0.1', $script:E2EPort)
            $connected = $false
            try { $connected = $connect.Wait(2000) -and $probe.Connected } catch { $connected = $false }
            if ($connected) {
                # http.sys may still accept the TCP connection for other registrations; the URL must not answer 200.
                $late = $null
                try { $late = $script:E2EClient.GetAsync($script:E2EBase + '/api/config').GetAwaiter().GetResult() } catch { $late = $null }
                if ($null -ne $late) { [int]$late.StatusCode | Should -Not -Be 200 }
            }
        }
        finally { $probe.Dispose() }
    }

    It 'fails with a clear message when the port is taken' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { $null }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'Workers must not start.' }
        $port = Get-SonarFreeTcpPort
        $blocker = [System.Net.HttpListener]::new()
        $blocker.Prefixes.Add("http://localhost:$port/")
        $blocker.Start()
        try {
            { Start-AzlSonarServer -ConfigPath $script:SecretConfigPath -Port $port -NoBrowser } | Should -Throw "*Cannot listen on http://localhost:$port/*"
        }
        finally {
            $blocker.Stop(); $blocker.Close()
        }
        Should -Invoke -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -Times 0 -Exactly
    }

    It 'stops before binding when nobody is signed in to Azure' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'No Azure sign-in found in this PowerShell session.' }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'must not be reached' }
        { Start-AzlSonarServer -ConfigPath $script:SecretConfigPath -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*No Azure sign-in*'
        Should -Invoke -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -Times 0 -Exactly
    }
}
