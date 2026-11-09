#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The page's HTTP surface: Host and Origin checks, the per-start access token and its cookie, security headers on every
# response, the fixed static-file table, limits on /api/logs and /api/events, and what /api/details never contains.
# Real HttpListener on localhost; the handler is called directly; no Azure, no node.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    Add-Type -AssemblyName System.Net.Http

    $script:HostileCluster = '"><img src=x onerror=alert(1)>'
    $script:HostileNode = '<script>x</script>'
    $json = New-SonarConfigObject
    $json.clusterName = $script:HostileCluster
    $json.nodes[0].name = $script:HostileNode
    $json.credential = [pscustomobject]@{ source = 'keyvault'; vault = 'kv-sonar-test'; usernameSecret = 'sonar-user-secret'; passwordSecret = 'sonar-pass-secret' }
    $json.subscriptionId = '11111111-2222-3333-4444-555555555555'
    $path = Join-Path $TestDrive 'sonar.config.json'
    ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
    $script:Config = Read-AzlSonarConfig -Path $path

    $script:Token = 'aaaabbbbccccddddeeeeffff00001111'
    $script:Port = Get-SonarFreeTcpPort
    $script:Base = "http://localhost:$($script:Port)"
    $script:Listener = [System.Net.HttpListener]::new()
    $script:Listener.Prefixes.Add("$($script:Base)/")
    $script:Listener.Prefixes.Add("http://127.0.0.1:$($script:Port)/")
    $script:Listener.Start()
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseProxy = $false
    $script:Client = [System.Net.Http.HttpClient]::new($handler)
    $script:Client.Timeout = [TimeSpan]::FromSeconds(30)

    function Get-SecServer {
        param([string]$Token = '', [int]$MaxStreams = 0)
        InModuleScope AzlSonar -Parameters @{ Config = $script:Config; Token = $Token; Max = $MaxStreams } {
            param($Config, $Token, $Max)
            $shared = Initialize-AzlSonarSharedState
            $state = Get-AzlSonarInitialState -Config $Config
            $state.polledAt = '2026-10-10T18:10:00Z'
            Publish-AzlSonarState -Shared $shared -State $state
            $shared.ConfigInfo['Note'] = 'cannot be read: C:\Users\someone\infra\infrastructure.yml is locked, token sonar_t=aaaabbbbccccddddeeeeffff00001111'
            Publish-AzlSonarTailerStatus -Shared $shared -Status ([ordered]@{ state = 'unavailable'; reason = 'WinRM: access denied reading C:\CloudDeployment\Logs\x.log'; node = 'node01'; credential = 'supplied' })
            $table = @{
                Shared = $shared; WebRoot = Join-Path $script:AzlSonarModuleRoot 'web'
                ConfigJson = ConvertTo-AzlSonarJson (ConvertTo-AzlSonarPublicConfig -Config $Config -StartedAt ([datetime]'2026-10-10T18:00:00Z'))
                GuidanceJson = ConvertTo-AzlSonarJson (Get-AzlSonarPhaseGuidance -IdentityModel $Config.identityModel)
                Facts = (New-AzlSonarDetailFact -Config $Config -ReadAt ([datetime]'2026-10-10T18:00:00Z'))
                ClusterName = $Config.clusterName; Version = '0.4.0'; Clients = [System.Collections.Generic.List[hashtable]]::new()
            }
            if ($Token) { $table.Token = $Token }
            if ($Max -gt 0) { $table.MaxEventStreams = $Max }
            $table
        }
    }

    $script:Pending = $null
    function Wait-SecContext {
        param([System.Threading.Tasks.Task]$Send)
        if ($null -eq $script:Pending) { $script:Pending = $script:Listener.GetContextAsync() }
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $deadline) {
            if ($script:Pending.IsCompleted) { $c = $script:Pending.Result; $script:Pending = $null; return $c }
            if ($null -ne $Send -and $Send.IsCompleted) { return $null }
            $null = $script:Pending.Wait(50)
        }
        throw 'No request arrived within 10 s.'
    }

    function Invoke-SecRequest {
        param($Server, [string]$PathAndQuery, [string]$Cookie, [hashtable]$Header = @{}, [string]$Method = 'GET', [string]$BaseUrl = $script:Base)
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $BaseUrl + $PathAndQuery)
        if ($Cookie) { $null = $req.Headers.TryAddWithoutValidation('Cookie', $Cookie) }
        foreach ($k in $Header.Keys) { $null = $req.Headers.TryAddWithoutValidation($k, [string]$Header[$k]) }
        $send = $script:Client.SendAsync($req)
        $ctx = Wait-SecContext -Send $send
        if ($null -ne $ctx) {
            InModuleScope AzlSonar -Parameters @{ C = $ctx; S = $Server } { param($C, $S) Invoke-AzlSonarHttpRequest -Context $C -Server $S }
        }
        $r = $send.GetAwaiter().GetResult()
        $h = @{}
        foreach ($x in $r.Headers) { $h[$x.Key] = ($x.Value -join ',') }
        foreach ($x in $r.Content.Headers) { $h[$x.Key] = ($x.Value -join ',') }
        [pscustomobject]@{ Status = [int]$r.StatusCode; Body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult(); Headers = $h }
    }
}

AfterAll {
    if ($script:Client) { $script:Client.Dispose() }
    if ($script:Listener) { $script:Listener.Stop(); $script:Listener.Close() }
}

Describe 'Host and Origin checks (DNS rebinding)' {
    BeforeAll { $script:S = Get-SecServer }

    It 'accepts only this machine''s loopback names on the request''s own port' -TestCases @(
        @{ H = 'localhost:8642'; P = 8642; Ok = $true }
        @{ H = 'LOCALHOST:8642'; P = 8642; Ok = $true }
        @{ H = '127.0.0.1:8642'; P = 8642; Ok = $true }
        @{ H = '[::1]:8642'; P = 8642; Ok = $true }
        @{ H = 'localhost'; P = 8642; Ok = $false }
        @{ H = 'localhost:9999'; P = 8642; Ok = $false }
        @{ H = 'evil.example:8642'; P = 8642; Ok = $false }
        @{ H = 'localhost.evil.example:8642'; P = 8642; Ok = $false }
        @{ H = '127.0.0.1.evil.example:8642'; P = 8642; Ok = $false }
        @{ H = 'localhost:8642@evil.example'; P = 8642; Ok = $false }
        @{ H = ''; P = 8642; Ok = $false }
    ) {
        param($H, $P, $Ok)
        InModuleScope AzlSonar -Parameters @{ H = $H; P = $P } { param($H, $P) Test-AzlSonarHostHeader -HostHeader $H -Port $P } | Should -Be $Ok
    }

    It 'accepts an Origin only when it is this page''s own' -TestCases @(
        @{ O = 'http://localhost:8642'; Ok = $true }
        @{ O = 'http://127.0.0.1:8642'; Ok = $true }
        @{ O = 'http://evil.example'; Ok = $false }
        @{ O = 'http://localhost:9'; Ok = $false }
        @{ O = 'https://localhost:8642'; Ok = $false }
        @{ O = 'null'; Ok = $false }
        @{ O = 'http://localhost.evil.example:8642'; Ok = $false }
    ) {
        param($O, $Ok)
        InModuleScope AzlSonar -Parameters @{ O = $O } { param($O) Test-AzlSonarOriginHeader -Origin $O -Port 8642 } | Should -Be $Ok
    }

    It 'refuses a request whose Host is another name with 400 and no body' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -Header @{ Host = 'evil.example' }
        # http.sys already turns most of these away; the handler's own check is the second layer (tested above on the header).
        $r.Status | Should -Be 400
        $r.Body | Should -Not -Match 'Sonar|api/'
    }

    It 'refuses a foreign Origin with 403' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -Header @{ Origin = 'http://evil.example' }
        $r.Status | Should -Be 403
        $r.Body | Should -BeNullOrEmpty
    }

    It 'answers on localhost and on 127.0.0.1, with and without its own Origin' {
        (Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state').Status | Should -Be 200
        (Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -BaseUrl "http://127.0.0.1:$($script:Port)").Status | Should -Be 200
        (Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -Header @{ Origin = $script:Base }).Status | Should -Be 200
    }
}

Describe 'Access token and cookie' {
    BeforeAll { $script:S = Get-SecServer -Token $script:Token }

    It 'refuses a request with no cookie (401, short text)' {
        foreach ($p in '/', '/api/state', '/api/logs', '/api/details', '/app.js') {
            $r = Invoke-SecRequest -Server $script:S -PathAndQuery $p
            $r.Status | Should -Be 401
            $r.Body | Should -Be 'Open the URL Sonar printed.'
        }
    }

    It 'refuses a wrong cookie' {
        (Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -Cookie 'sonar_t=00000000000000000000000000000000').Status | Should -Be 401
        (Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -Cookie 'sonar_t=').Status | Should -Be 401
        (Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -Cookie "other=$($script:Token)").Status | Should -Be 401
    }

    It 'answers 200 with the right cookie' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery '/api/state' -Cookie "sonar_t=$($script:Token)"
        $r.Status | Should -Be 200
        ($r.Body | ConvertFrom-Json).cluster | Should -Be $script:HostileCluster
        (Invoke-SecRequest -Server $script:S -PathAndQuery '/' -Cookie "sonar_t=$($script:Token)").Status | Should -Be 200
    }

    It '?t= with the right token sets the cookie and redirects to the same URL without it' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery "/?demo=1&route=simplified&t=$($script:Token)"
        $r.Status | Should -Be 302
        $r.Headers['Location'] | Should -Be '/?demo=1&route=simplified'
        $r.Headers['Set-Cookie'] | Should -Be "sonar_t=$($script:Token); HttpOnly; SameSite=Strict; Path=/"
        $r.Headers['Location'] | Should -Not -Match $script:Token
    }

    It 'never redirects to another host, whatever the path' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery "//evil.example/x?t=$($script:Token)"
        if ($r.Status -eq 302) { $r.Headers['Location'] | Should -Match '^/[^/]' }
    }

    It 'a wrong ?t= is 401 and sets no cookie' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery '/?t=00000000000000000000000000000000'
        $r.Status | Should -Be 401
        $r.Headers.ContainsKey('Set-Cookie') | Should -BeFalse
    }

    It 'the token is never in a response body (config, details, state, export, logs) or a header apart from the cookie' {
        $cookie = "sonar_t=$($script:Token)"
        foreach ($p in '/api/config', '/api/details', '/api/state', '/api/about', '/api/guidance', '/api/logs', '/api/export') {
            $r = Invoke-SecRequest -Server $script:S -PathAndQuery $p -Cookie $cookie
            $r.Status | Should -Be 200
            $r.Body | Should -Not -Match $script:Token
            ($r.Headers.Values -join ' ') | Should -Not -Match $script:Token
        }
    }

    It 'compares tokens in constant time and refuses an empty or a different-length one' {
        InModuleScope AzlSonar { Test-AzlSonarTokenEqual -Left 'abc' -Right 'abc' } | Should -BeTrue
        InModuleScope AzlSonar { Test-AzlSonarTokenEqual -Left 'abc' -Right 'abd' } | Should -BeFalse
        InModuleScope AzlSonar { Test-AzlSonarTokenEqual -Left 'abc' -Right 'abcd' } | Should -BeFalse
        InModuleScope AzlSonar { Test-AzlSonarTokenEqual -Left '' -Right '' } | Should -BeFalse
    }

    It 'a server without a token (-NoAccessToken) answers without a cookie' {
        $open = Get-SecServer
        (Invoke-SecRequest -Server $open -PathAndQuery '/api/state').Status | Should -Be 200
    }

    It 'makes a 32-character hex token from the cryptographic generator, different every time' {
        $a = InModuleScope AzlSonar { New-AzlSonarAccessToken }
        $b = InModuleScope AzlSonar { New-AzlSonarAccessToken }
        $a | Should -Match '^[0-9a-f]{32}$'
        $a | Should -Not -Be $b
    }

    It 'masks the token like a password in anything Sonar stores' {
        InModuleScope AzlSonar { Protect-AzlSonarText -Text 'open http://localhost:8642/?t=aaaabbbbccccddddeeeeffff00001111 now; Cookie: sonar_t=aaaabbbbccccddddeeeeffff00001111' } |
            Should -Not -Match 'aaaabbbbcccc'
    }
}

Describe 'Access token settings' {
    It 'accessToken must be true or false; maxEventStreams a whole number from 1 to 50' {
        $c = New-SonarConfigObject
        $c | Add-Member -NotePropertyName accessToken -NotePropertyValue 'no' -Force
        $c | Add-Member -NotePropertyName maxEventStreams -NotePropertyValue 99 -Force
        $problems = @(Test-AzlSonarConfig -Config $c)
        ($problems -match 'accessToken') | Should -Not -BeNullOrEmpty
        ($problems -match 'maxEventStreams') | Should -Not -BeNullOrEmpty
    }

    It 'is on by default and off with accessToken false' {
        $c = New-SonarConfigObject
        (Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $c)).accessToken | Should -BeTrue
        (Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $c)).maxEventStreams | Should -Be 4
        $c | Add-Member -NotePropertyName accessToken -NotePropertyValue $false -Force
        $c | Add-Member -NotePropertyName maxEventStreams -NotePropertyValue 8 -Force
        $read = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $c)
        $read.accessToken | Should -BeFalse
        $read.maxEventStreams | Should -Be 8
    }
}

Describe 'Security headers on every response' {
    BeforeAll {
        $script:S = Get-SecServer -Token $script:Token
        $script:Cookie = "sonar_t=$($script:Token)"
        $script:Csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    It '<Name> carries all five headers and the exact content type' -TestCases @(
        @{ Name = 'the page'; P = '/'; Status = 200; Type = 'text/html; charset=utf-8' }
        @{ Name = 'app.js'; P = '/app.js'; Status = 200; Type = 'text/javascript; charset=utf-8' }
        @{ Name = 'app.css'; P = '/app.css'; Status = 200; Type = 'text/css; charset=utf-8' }
        @{ Name = 'the icon'; P = '/azurelocal-sonar-icon.svg'; Status = 200; Type = 'image/svg+xml' }
        @{ Name = '/api/state'; P = '/api/state'; Status = 200; Type = 'application/json; charset=utf-8' }
        @{ Name = '/api/details'; P = '/api/details'; Status = 200; Type = 'application/json; charset=utf-8' }
        @{ Name = '/api/logs'; P = '/api/logs'; Status = 200; Type = 'application/json; charset=utf-8' }
        @{ Name = 'a 404'; P = '/nope.txt'; Status = 404; Type = 'text/plain; charset=utf-8' }
        @{ Name = 'an unknown API route'; P = '/api/nope'; Status = 404; Type = 'application/json; charset=utf-8' }
    ) {
        param($Name, $P, $Status, $Type)
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery $P -Cookie $script:Cookie
        $r.Status | Should -Be $Status -Because $Name
        $r.Headers['Content-Type'] | Should -Be $Type
        $r.Headers['Cache-Control'] | Should -Be 'no-store'
        $r.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
        $r.Headers['Referrer-Policy'] | Should -Be 'no-referrer'
        $r.Headers['X-Frame-Options'] | Should -Be 'DENY'
        $r.Headers['Content-Security-Policy'] | Should -Be $script:Csp
    }

    It 'also on the 401, the 405 and the 302' {
        foreach ($case in @(@{ P = '/api/state'; M = 'GET'; C = ''; S = 401 }, @{ P = '/api/state'; M = 'POST'; C = $script:Cookie; S = 405 }, @{ P = "/?t=$($script:Token)"; M = 'GET'; C = ''; S = 302 })) {
            $r = Invoke-SecRequest -Server $script:S -PathAndQuery $case.P -Method $case.M -Cookie $case.C
            $r.Status | Should -Be $case.S
            $r.Headers['Content-Security-Policy'] | Should -Be $script:Csp
            $r.Headers['X-Frame-Options'] | Should -Be 'DENY'
            $r.Headers['Cache-Control'] | Should -Be 'no-store'
        }
    }
}

Describe 'The page needs no inline script, style or handler (Content-Security-Policy without unsafe-inline)' {
    It 'index.html has no inline script, no style attribute and no on* attribute' {
        $html = Get-Content -LiteralPath (Join-Path $script:SonarModuleRoot 'web/index.html') -Raw
        $html | Should -Not -Match '<script(?![^>]*\ssrc=)[^>]*>'
        $html | Should -Not -Match '\sstyle\s*='
        $html | Should -Not -Match '\son[a-z]+\s*='
        $html | Should -Not -Match '<style'
        $html | Should -Not -Match 'javascript:'
    }
}

Describe 'Static files: a fixed table, never a path from the request' {
    BeforeAll { $script:Root = Join-Path $script:SonarModuleRoot 'web' }

    It 'maps only the shipped files' -TestCases @(
        @{ U = '/'; E = 'index.html' }, @{ U = '/index.html'; E = 'index.html' }, @{ U = '/app.js'; E = 'app.js' },
        @{ U = '/app.css'; E = 'app.css' }, @{ U = '/azurelocal-sonar-icon.svg'; E = 'azurelocal-sonar-icon.svg' }
    ) {
        param($U, $E)
        InModuleScope AzlSonar -Parameters @{ R = $script:Root; U = $U } { param($R, $U) Resolve-AzlSonarStaticPath -WebRoot $R -UrlPath $U } | Should -Be (Join-Path $script:Root $E)
    }

    It 'refuses <U>' -TestCases @(
        @{ U = '/../AzlSonar.psd1' }, @{ U = '/..\..\Windows\win.ini' }, @{ U = '/../../Windows/win.ini' }, @{ U = '//server/share/x' }, @{ U = '/index.html::$DATA' },
        @{ U = '/CON' }, @{ U = '/NUL' }, @{ U = '/con.txt' }, @{ U = '/COM1' }, @{ U = '/LPT9.js' }, @{ U = '/index.html.' }, @{ U = '/index.html ' }, @{ U = '/app.js.' },
        @{ U = '/api/details/..%2f..%2fx' }, @{ U = '/%252e%252e/Windows/win.ini' }, @{ U = '/%2e%2e/Windows/win.ini' }, @{ U = '/index.html?x' }, @{ U = '/app*.js' },
        @{ U = '/app"js' }, @{ U = '/app<js' }, @{ U = '/app>js' }, @{ U = '/app|js' }, @{ U = '/APP.JS' }, @{ U = '/data/phase-guidance.json' },
        @{ U = '/Start-AzlSonar.ps1' }, @{ U = '/sub/../index.html' }, @{ U = 'C:\Windows\win.ini' }, @{ U = '/C:/Windows/win.ini' }, @{ U = '/missing.html' }
    ) {
        param($U)
        InModuleScope AzlSonar -Parameters @{ R = $script:Root; U = $U } { param($R, $U) Resolve-AzlSonarStaticPath -WebRoot $R -UrlPath $U } | Should -BeNullOrEmpty
    }

    # The NUL is built at run time and is not in the test name: Pester writes the name into the NUnit XML, and XML cannot hold char 0.
    It 'refuses a NUL byte inside the path' {
        $u = '/app.js' + [string][char]0 + '.png'
        InModuleScope AzlSonar -Parameters @{ R = $script:Root; U = $u } { param($R, $U) Resolve-AzlSonarStaticPath -WebRoot $R -UrlPath $U } | Should -BeNullOrEmpty
    }

    It 'never serves a file outside the root, even one that exists, through the handler' {
        $outside = Join-Path (Split-Path $script:Root -Parent) 'AzlSonar.psd1'
        Test-Path -LiteralPath $outside | Should -BeTrue
        $s = Get-SecServer
        foreach ($p in '/..%5C..%5CWindows%5Cwin.ini', '/%2e%2e/Windows/win.ini', '//server/share/x', '/index.html::$DATA', '/CON', '/NUL', '/index.html.',
            '/api/details/..%2f..%2fx', '/%252e%252e/Windows/win.ini', '/../AzlSonar.psd1', '/..%2fAzlSonar.psd1') {
            $r = Invoke-SecRequest -Server $s -PathAndQuery $p
            $r.Status | Should -BeIn 400, 403, 404 -Because $p
            $r.Body | Should -Not -Match 'ModuleVersion|\[fonts\]|for 16-bit app support' -Because $p
        }
    }
}

Describe '/api/logs limits and a strict since' {
    BeforeAll {
        $script:S = Get-SecServer
        InModuleScope AzlSonar -Parameters @{ S = $script:S } {
            param($S)
            $lines = foreach ($i in 1..2500) { [pscustomobject]@{ file = 'C:\MASLogs\a.log'; text = "line $i" } }
            Add-AzlSonarLogLine -Shared $S.Shared -Line @($lines)
        }
    }

    It 'caps one answer at 2000 lines, says it is cut and stops the cursor at the last line sent' {
        $a = (Invoke-SecRequest -Server $script:S -PathAndQuery '/api/logs?since=0').Body | ConvertFrom-Json
        @($a.lines).Count | Should -Be 2000
        $a.truncated | Should -BeTrue
        $a.lastSeq | Should -Be 2000
        $b = (Invoke-SecRequest -Server $script:S -PathAndQuery "/api/logs?since=$($a.lastSeq)").Body | ConvertFrom-Json
        @($b.lines).Count | Should -Be 500
        $b.truncated | Should -BeFalse
        $b.lastSeq | Should -Be 2500
    }

    It 'caps one answer at about 2 MB of lines' {
        $big = Get-SecServer
        InModuleScope AzlSonar -Parameters @{ S = $big } {
            param($S)
            $text = 'x' * 200000
            Add-AzlSonarLogLine -Shared $S.Shared -Line @(1..30 | ForEach-Object { [pscustomobject]@{ file = 'C:\MASLogs\big.log'; text = $text } })
        }
        $r = Invoke-SecRequest -Server $big -PathAndQuery '/api/logs?since=0'
        $r.Body.Length | Should -BeLessThan 2400000
        $o = $r.Body | ConvertFrom-Json
        $o.truncated | Should -BeTrue
        @($o.lines).Count | Should -BeLessThan 30
        $o.lastSeq | Should -Be @($o.lines)[-1].seq
    }

    It 'the export keeps the whole ring buffer' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery '/api/export'
        (($r.Body | ConvertFrom-Json).logs.lines | Measure-Object).Count | Should -Be 2500
    }

    It 'refuses since=<S> with 400 and a short message' -TestCases @(
        @{ S = '-1' }, @{ S = 'abc' }, @{ S = '99999999999999999999' }, @{ S = '1.5' }, @{ S = '1e3' }, @{ S = '0x10' }
    ) {
        param($S)
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery "/api/logs?since=$S"
        $r.Status | Should -Be 400
        ($r.Body | ConvertFrom-Json).error | Should -Be 'since must be a whole number from 0.'
    }

    It 'clamps a since beyond the current sequence to it' {
        $r = Invoke-SecRequest -Server $script:S -PathAndQuery '/api/logs?since=900000000'
        $r.Status | Should -Be 200
        $o = $r.Body | ConvertFrom-Json
        @($o.lines).Count | Should -Be 0
        $o.lastSeq | Should -Be 2500
    }
}

Describe '/api/events: at most four streams, the rest get 429, the server stays responsive' {
    It 'serves 100 parallel connections with the cap, 429 for the rest, and then still answers' {
        $s = Get-SecServer
        $tasks = foreach ($i in 1..100) {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$($script:Base)/api/events")
            $script:Client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        }
        $served = 0
        while ($served -lt 100) {
            $ctx = Wait-SecContext
            InModuleScope AzlSonar -Parameters @{ C = $ctx; S = $s } { param($C, $S) Invoke-AzlSonarHttpRequest -Context $C -Server $S }
            $served++
        }
        $null = [System.Threading.Tasks.Task]::WaitAll(@($tasks), 20000)
        $codes = @($tasks | ForEach-Object { [int]$_.Result.StatusCode })
        @($codes | Where-Object { $_ -eq 200 }).Count | Should -Be 4
        @($codes | Where-Object { $_ -eq 429 }).Count | Should -Be 96
        $s.Clients.Count | Should -Be 4
        (Invoke-SecRequest -Server $s -PathAndQuery '/api/state').Status | Should -Be 200
        foreach ($c in @($s.Clients.ToArray())) { try { $c.Response.Abort() } catch { Write-Verbose 'gone' } }
        foreach ($t in $tasks) { if ($t.IsCompleted -and -not $t.IsFaulted) { $t.Result.Dispose() } }
    }

    It 'honours maxEventStreams from the config' {
        $s = Get-SecServer -MaxStreams 1
        $s.Clients.Add(@{ Dummy = 1 })
        $r = Invoke-SecRequest -Server $s -PathAndQuery '/api/events'
        $r.Status | Should -Be 429
        $r.Headers['Retry-After'] | Should -Be '30'
    }
}

Describe '/api/details never carries a path, a full subscription id, a secret name or a credential' {
    BeforeAll {
        $s = Get-SecServer
        $script:Body = (Invoke-SecRequest -Server $s -PathAndQuery '/api/details').Body
        $script:Details = $script:Body | ConvertFrom-Json
    }

    It 'has no drive-letter or UNC path anywhere' {
        $script:Body | Should -Not -Match '[A-Za-z]:\\\\'
        $script:Body | Should -Not -Match '[A-Za-z]:/'
        $script:Body | Should -Not -Match '\\\\\\\\[A-Za-z0-9]'
    }

    It 'has no 36-character GUID (the subscription is its first 8 characters)' {
        $script:Body | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $script:Details.target.subscription.value | Should -Be '11111111...'
    }

    It 'has no Key Vault, secret or password name' {
        $script:Body | Should -Not -Match 'kv-sonar-test|sonar-user-secret|sonar-pass-secret|passwordSecret|usernameSecret|vault|ztpEventsPath'
        $script:Body | Should -Not -Match '"keys"'
    }

    It 'names the credential only as a word, and cuts paths out of free text' {
        $script:Details.sources.nodeLogs.credential | Should -BeIn 'supplied', 'current Windows identity', ''
        $script:Details.sources.nodeLogs.reason | Should -Be 'WinRM: access denied reading x.log'
        $script:Details.config.lastChangeNote | Should -Not -Match 'Users|someone'
    }

    It 'passes markup in the cluster and node names as data (JSON-escaped, unchanged when parsed)' {
        $script:Body | Should -Not -Match '<img|<script'
        $script:Details.target.cluster.value | Should -Be $script:HostileCluster
        @($script:Details.nodes)[0].name | Should -Be $script:HostileNode
        $state = (Invoke-SecRequest -Server (Get-SecServer) -PathAndQuery '/api/state').Body
        $state | Should -Not -Match '<img|<script'
        ($state | ConvertFrom-Json).cluster | Should -Be $script:HostileCluster
    }
}
