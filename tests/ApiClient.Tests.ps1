#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Invoke-AzlSonarApi (src/AzlSonar/Private/ApiClient.ps1, scripts/Invoke-AzlSonarApi.ps1) against a fake Sonar on a localhost
# port (tests/FakeSonar.ps1) and, for the handshake, against the real request handler. Never the live instance, no Azure,
# no node. Every test also checks that the token never appears in what the helper writes.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'FakeSonar.ps1')
    Import-SonarTestModule
    $script:Token = 'aaaabbbbccccddddeeeeffff00001111'
    $script:OtherToken = '99998888777766665555444433332222'
    $script:Fake = Start-FakeSonar -Token $script:Token
    $script:Url = $script:Fake.BaseUrl

    $script:Sse = "retry: 5000`n`nevent: hello`ndata: {`"server`":`"srv-1`",`"since`":10}`n`nevent: state`ndata: {`"phase`":`"validation`"}`n`n: ping`n`nevent: tailer`ndata: {`"state`":`"connected`"}`n`nevent: log`ndata: {`"server`":`"srv-1`",`"lines`":[{`"seq`":11,`"text`":`"a`"},`ndata: {`"seq`":12,`"text`":`"b`"}]}`n`n"

    function Initialize-ApiTest {
        Wait-FakeSonarIdle $script:Fake
        Reset-FakeSonar $script:Fake
        $script:Fake.State.Token = $script:Token
        InModuleScope AzlSonar { Clear-AzlSonarApiSession }
    }
    function Get-LogPage {
        # A /api/logs answer. $Seq is the list of sequence numbers of its lines.
        param([string]$Server = 'srv-1', [long]$LastSeq, [bool]$Truncated = $false, [long[]]$Seq = @())
        $lines = @($Seq | ForEach-Object { [ordered]@{ seq = $_; time = '2026-11-08T23:55:40.786Z'; level = 'info'; text = "line $_" } })
        return ([ordered]@{ server = $Server; lastSeq = $LastSeq; truncated = $Truncated; tailer = $null; files = @(); lines = $lines } | ConvertTo-Json -Depth 8 -Compress)
    }
    function Get-SeenPath { return @($script:Fake.State.Requests | ForEach-Object { $_.Url }) }
}

AfterAll {
    Stop-FakeSonar $script:Fake
    InModuleScope AzlSonar { Clear-AzlSonarApiSession }
}

Describe 'Invoke-AzlSonarApi: the module exports it and a script wraps it' {
    It 'is exported with the nine routes as the Route set' {
        $command = Get-Command Invoke-AzlSonarApi
        $command.Source | Should -Be 'AzlSonar'
        $set = ($command.Parameters['Route'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
        @($set).Count | Should -Be 9
        $set | Should -Contain '/api/replay'
    }

    It 'offers -Token, -TokenFile, -BaseUrl, -OutFile, -All, -Follow and -Raw (alias AsJson)' {
        $command = Get-Command Invoke-AzlSonarApi
        foreach ($name in 'Token', 'TokenFile', 'BaseUrl', 'OutFile', 'All', 'Follow', 'Raw', 'Since', 'TimeoutSeconds', 'MaxRetry', 'ServerId', 'EventName', 'DurationSeconds') {
            $command.Parameters.Keys | Should -Contain $name
        }
        $command.Parameters['Raw'].Aliases | Should -Contain 'AsJson'
    }

    It 'the script wrapper has the same parameters as the function' {
        $script = Get-Command (Join-Path $script:SonarRepoRoot 'scripts/Invoke-AzlSonarApi.ps1')
        $function = Get-Command Invoke-AzlSonarApi
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters
        @($script.Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object) | Should -Be @($function.Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object)
    }

    It 'the script wrapper calls the function' {
        Initialize-ApiTest
        Set-FakeSonarDefault $script:Fake '/api/about' @{ Body = '{"name":"AzL Sonar","version":"9.9.9"}' }
        $result = & (Join-Path $script:SonarRepoRoot 'scripts/Invoke-AzlSonarApi.ps1') -Route /api/about -BaseUrl $script:Url -Token $script:Token
        $result.version | Should -Be '9.9.9'
    }

    It 'rejects a route that is not one of the nine' {
        { Invoke-AzlSonarApi '/api/nope' -BaseUrl $script:Url -Token $script:Token } | Should -Throw
    }
}

Describe 'Invoke-AzlSonarApi: the cookie handshake' {
    BeforeEach { Initialize-ApiTest }

    It 'exchanges the token once (302 and the cookie), then sends the cookie' {
        Set-FakeSonarDefault $script:Fake '/api/about' @{ Body = '{"name":"AzL Sonar","version":"0.4.0"}' }
        $first = Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -Token $script:Token
        $second = Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -Token $script:Token
        $first.name | Should -Be 'AzL Sonar'
        $second.version | Should -Be '0.4.0'
        $seen = @($script:Fake.State.Requests)
        $seen.Count | Should -Be 3
        $seen[0].Url | Should -Be "/?t=$($script:Token)"
        $seen[0].HasCookie | Should -BeFalse
        $seen[1].Path | Should -Be '/api/about'
        $seen[1].HasCookie | Should -BeTrue
        $seen[2].HasCookie | Should -BeTrue
        @($seen | Where-Object { $_.Method -ne 'GET' }) | Should -BeNullOrEmpty
        # The token goes into the handshake address only, never into a route call.
        @($seen | Where-Object { $_.Path -ne '/' -and $_.Url -match $script:Token }) | Should -BeNullOrEmpty
    }

    It 'needs no handshake when Sonar runs without an access token' {
        $script:Fake.State.Token = ''
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Body = '{"phase":"validation"}' }
        (Invoke-AzlSonarApi /api/state -BaseUrl $script:Url).phase | Should -Be 'validation'
        @($script:Fake.State.Requests).Count | Should -Be 1
    }

    It 'makes a new handshake when it is given another token' {
        Set-FakeSonarDefault $script:Fake '/api/about' @{ Body = '{"v":1}' }
        $null = Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -Token $script:Token
        $script:Fake.State.Token = $script:OtherToken
        $null = Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -Token $script:OtherToken
        @($script:Fake.State.Requests | Where-Object { $_.Path -eq '/' }).Count | Should -Be 2
    }

    It 'reads the token from -TokenFile, and again after a restart (401), without the caller doing anything' {
        $file = Join-Path $TestDrive 'sonar.token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $file; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        Set-FakeSonarDefault $script:Fake '/api/about' @{ Body = '{"v":1}' }
        $null = Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -TokenFile $file
        # Sonar restarts: new token, and a new start rewrites the file.
        $script:Fake.State.Token = $script:OtherToken
        Set-Content -LiteralPath $file -Value $script:OtherToken -NoNewline
        (Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -TokenFile $file).v | Should -Be 1
        @($script:Fake.State.Requests | Where-Object { $_.Path -eq '/' }).Count | Should -Be 2
    }

    It 'says what is wrong when the token file is missing or empty' {
        { Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -TokenFile (Join-Path $TestDrive 'no-such.token') } | Should -Throw '*token file does not exist*'
        $empty = Join-Path $TestDrive 'empty.token'
        Set-Content -LiteralPath $empty -Value '' -NoNewline
        { Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -TokenFile $empty } | Should -Throw '*token file is empty*'
    }

    It 'refuses a token that is not the form Sonar makes, without echoing it' {
        $bad = 'http://localhost:8642/?t=' + $script:Token
        $err = $null
        try { Invoke-AzlSonarApi /api/about -BaseUrl $script:Url -Token $bad } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'form Sonar makes'
        $err.Exception.Message | Should -Not -Match $script:Token
        @($script:Fake.State.Requests).Count | Should -Be 0
    }
}

Describe 'Invoke-AzlSonarApi: results' {
    BeforeEach { Initialize-ApiTest }

    It 'returns parsed JSON by default and the text with -Raw (alias -AsJson)' {
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Body = '{"phase":"validation","n":[1,2]}' }
        (Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token).n.Count | Should -Be 2
        Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token -Raw | Should -Be '{"phase":"validation","n":[1,2]}'
        Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token -AsJson | Should -Be '{"phase":"validation","n":[1,2]}'
    }

    It 'accepts the route in any case' {
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Body = '{"phase":"x"}' }
        (Invoke-AzlSonarApi '/API/State' -BaseUrl $script:Url -Token $script:Token).phase | Should -Be 'x'
    }

    It 'asks /api/logs for one page after -Since' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 12 -Seq 11, 12) }
        $page = Invoke-AzlSonarApi /api/logs -Since 10 -BaseUrl $script:Url -Token $script:Token
        $page.lastSeq | Should -Be 12
        @($page.lines).Count | Should -Be 2
        Get-SeenPath | Should -Contain '/api/logs?since=10'
    }

    It 'saves /api/export to the file with -OutFile and returns the file, leaving no .part' {
        Set-FakeSonarDefault $script:Fake '/api/export' @{ Body = '{"export":{"tool":"AzL Sonar"},"timeline":[]}'; Headers = @{ 'Content-Disposition' = 'attachment; filename="x.json"' } }
        $target = Join-Path $TestDrive 'export.json'
        $file = Invoke-AzlSonarApi /api/export -OutFile $target -BaseUrl $script:Url -Token $script:Token
        $file.FullName | Should -Be $target
        (Get-Content -LiteralPath $target -Raw) | Should -Be '{"export":{"tool":"AzL Sonar"},"timeline":[]}'
        Test-Path -LiteralPath "$target.part" | Should -BeFalse
    }

    It 'saves nothing when the answer is an error' {
        Add-FakeSonarResponse $script:Fake '/api/export' @{ Status = 404; Body = '{"error":"Replay mode: /api/export is not available; the page plays /api/replay."}' }
        $target = Join-Path $TestDrive 'export-fail.json'
        { Invoke-AzlSonarApi /api/export -OutFile $target -BaseUrl $script:Url -Token $script:Token } | Should -Throw '*404*replay*'
        Test-Path -LiteralPath $target | Should -BeFalse
        Test-Path -LiteralPath "$target.part" | Should -BeFalse
    }

    It 'refuses an -OutFile in a folder that does not exist, before any request' {
        { Invoke-AzlSonarApi /api/export -OutFile (Join-Path $TestDrive 'nope/x.json') -BaseUrl $script:Url -Token $script:Token } | Should -Throw '*folder of -OutFile*'
        @($script:Fake.State.Requests).Count | Should -Be 0
    }
}

Describe 'Invoke-AzlSonarApi: errors say what to do and carry the status code' {
    BeforeEach { Initialize-ApiTest }

    It 'gives <Code> a clear message' -ForEach @(
        @{ Code = 400; Body = '{"error":"since must be a whole number from 0."}'; Match = '*400*since must be a whole number*'; Route = '/api/logs' }
        @{ Code = 403; Body = 'AzL Sonar only answers requests from this machine.'; Match = '*403*this machine*'; Route = '/api/state' }
        @{ Code = 404; Body = '{"error":"Not replaying. Start Sonar with -Replay <recording> to play a recording."}'; Match = '*404*-Replay*'; Route = '/api/replay' }
        @{ Code = 404; Body = '{"error":"Replay mode: /api/events is not available."}'; Match = '*404*replay does not serve*'; Route = '/api/export' }
        @{ Code = 405; Body = 'Only GET is supported.'; Match = '*405*read-only*GET*'; Route = '/api/state' }
        @{ Code = 500; Body = '{"error":"Internal error."}'; Match = '*500*failed inside*Internal error*'; Route = '/api/state' }
    ) {
        Add-FakeSonarResponse $script:Fake $Route @{ Status = $Code; Body = $Body }
        $err = $null
        try { Invoke-AzlSonarApi $Route -BaseUrl $script:Url -Token $script:Token -MaxRetry 0 } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike $Match
        $err.Exception.StatusCode | Should -Be $Code
        $err.FullyQualifiedErrorId | Should -Be "AzlSonarApi.$Code"
        $err.Exception.Message | Should -Not -Match $script:Token
    }

    It 'explains 401 without a token, with a wrong token, and after a restart' {
        $err = $null
        try { Invoke-AzlSonarApi /api/state -BaseUrl $script:Url } catch { $err = $_ }
        $err.Exception.Message | Should -BeLike '*401*token*restarted*-TokenFile*'
        $err.Exception.StatusCode | Should -Be 401
        Initialize-ApiTest
        try { Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:OtherToken } catch { $err = $_ }
        $err.Exception.Message | Should -BeLike '*401*'
        $err.Exception.Message | Should -Not -Match $script:OtherToken
        $err.Exception.Message | Should -Not -Match $script:Token
        # A restart while the caller holds an explicit -Token (nothing to re-read): the cached session gets 401 and the error says so.
        Initialize-ApiTest
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Body = '{"phase":"x"}' }
        $null = Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token
        $script:Fake.State.Token = $script:OtherToken
        $err = $null
        try { Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token } catch { $err = $_ }
        $err.Exception.Message | Should -BeLike '*401*restarted*'
        $err.Exception.StatusCode | Should -Be 401
    }

    It 'honours Retry-After on 429 and then succeeds' {
        Mock -ModuleName AzlSonar -CommandName Start-Sleep -MockWith { }
        Add-FakeSonarResponse $script:Fake '/api/state' @{ Status = 429; Body = 'Too many streams.'; ContentType = 'text/plain'; Headers = @{ 'Retry-After' = '7' } }
        Add-FakeSonarResponse $script:Fake '/api/state' @{ Body = '{"phase":"done"}' }
        (Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token).phase | Should -Be 'done'
        Should -Invoke -ModuleName AzlSonar -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
    }

    It 'caps the wait at 120 seconds' {
        Mock -ModuleName AzlSonar -CommandName Start-Sleep -MockWith { }
        Add-FakeSonarResponse $script:Fake '/api/state' @{ Status = 429; Body = 'x'; ContentType = 'text/plain'; Headers = @{ 'Retry-After' = '9999' } }
        Add-FakeSonarResponse $script:Fake '/api/state' @{ Body = '{"phase":"done"}' }
        $null = Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token
        Should -Invoke -ModuleName AzlSonar -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 120 }
    }

    It 'stops after -MaxRetry tries and says so (429, Retry-After in the message)' {
        Mock -ModuleName AzlSonar -CommandName Start-Sleep -MockWith { }
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Status = 429; Body = 'x'; ContentType = 'text/plain'; Headers = @{ 'Retry-After' = '30' } }
        $err = $null
        try { Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token -MaxRetry 2 } catch { $err = $_ }
        $err.Exception.Message | Should -BeLike '*429*too many event streams*Retry in 30 second*'
        $err.Exception.StatusCode | Should -Be 429
        Should -Invoke -ModuleName AzlSonar -CommandName Start-Sleep -Times 2 -Exactly
        @($script:Fake.State.Requests | Where-Object { $_.Path -eq '/api/state' }).Count | Should -Be 3
    }

    It 'does not retry a 429 when -MaxRetry is 0' {
        Mock -ModuleName AzlSonar -CommandName Start-Sleep -MockWith { }
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Status = 429; Body = 'x'; ContentType = 'text/plain'; Headers = @{ 'Retry-After' = '1' } }
        { Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token -MaxRetry 0 } | Should -Throw '*429*'
        Should -Invoke -ModuleName AzlSonar -CommandName Start-Sleep -Times 0 -Exactly
    }

    It 'says Sonar is not reachable when nothing listens' {
        $port = Get-SonarFreeTcpPort
        $err = $null
        try { Invoke-AzlSonarApi /api/state -BaseUrl "http://localhost:$port" -Token $script:Token } catch { $err = $_ }
        $err.Exception.Message | Should -BeLike "*Cannot reach Sonar at http://localhost:$port*"
        $err.Exception.Message | Should -Not -Match $script:Token
    }

    It 'times out when Sonar does not answer' {
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Body = '{}'; HoldMs = 2500 }
        $err = $null
        try { Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token -TimeoutSeconds 1 } catch { $err = $_ }
        $err.Exception.Message | Should -BeLike '*did not answer within 1 second*'
    }

    It 'only calls this machine, and never sends the token to another host' {
        foreach ($bad in 'http://example.test:8642', 'http://192.0.2.10:8642', 'https://localhost:8642', 'http://localhost:8642/api', 'http://user@localhost:8642', 'localhost') {
            { Invoke-AzlSonarApi /api/state -BaseUrl $bad -Token $script:Token } | Should -Throw
        }
        { Invoke-AzlSonarApi /api/state -BaseUrl 'http://127.0.0.1:1' -Token $script:Token } | Should -Throw '*Cannot reach Sonar at http://127.0.0.1:1*'
    }

    It 'refuses a combination that does not make sense' {
        { Invoke-AzlSonarApi /api/state -All -BaseUrl $script:Url -Token $script:Token } | Should -Throw '*belong to /api/logs*'
        { Invoke-AzlSonarApi /api/state -Follow -BaseUrl $script:Url -Token $script:Token } | Should -Throw '*belong to /api/events*'
        { Invoke-AzlSonarApi /api/events -BaseUrl $script:Url -Token $script:Token } | Should -Throw '*-Follow*'
        { Invoke-AzlSonarApi /api/logs -All -OutFile (Join-Path $TestDrive 'x') -BaseUrl $script:Url -Token $script:Token } | Should -Throw '*-OutFile*'
        @($script:Fake.State.Requests).Count | Should -Be 0
    }
}

Describe 'Invoke-AzlSonarApi -All: paging, gaps and restarts of /api/logs' {
    BeforeEach { Initialize-ApiTest }

    It 'follows lastSeq while truncated is true and stops when caught up' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 2 -Truncated $true -Seq 1, 2) }
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 4 -Truncated $true -Seq 3, 4) }
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 5 -Seq 5) }
        $result = Invoke-AzlSonarApi /api/logs -All -BaseUrl $script:Url -Token $script:Token
        $result.Pages | Should -Be 3
        $result.LastSeq | Should -Be 5
        $result.Server | Should -Be 'srv-1'
        @($result.Lines).seq | Should -Be 1, 2, 3, 4, 5
        $result.Gap | Should -BeFalse
        $result.Restarted | Should -BeFalse
        @(Get-SeenPath | Where-Object { $_ -like '/api/logs*' }) | Should -Be '/api/logs?since=0', '/api/logs?since=2', '/api/logs?since=4'
    }

    It 'returns an empty result with the cursor when there is nothing new' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 40) }
        $result = Invoke-AzlSonarApi /api/logs -All -Since 40 -BaseUrl $script:Url -Token $script:Token
        @($result.Lines).Count | Should -Be 0
        $result.LastSeq | Should -Be 40
        $result.Gap | Should -BeFalse
    }

    It 'reports a gap when the first returned seq is above Since + 1 (and warns)' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 30 -Seq 26, 27, 28, 29, 30) }
        $result = Invoke-AzlSonarApi /api/logs -All -Since 10 -BaseUrl $script:Url -Token $script:Token -WarningVariable warned -WarningAction SilentlyContinue
        $result.Gap | Should -BeTrue
        $result.MissedFrom | Should -Be 11
        $result.MissedTo | Should -Be 25
        $result.MissedCount | Should -Be 15
        @($result.Lines).Count | Should -Be 5
        "$warned" | Should -BeLike '*11 to 25*15 line*ring buffer*'
    }

    It 'reports a gap in the middle of the paging' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 2 -Truncated $true -Seq 1, 2) }
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 9 -Seq 8, 9) }
        $result = Invoke-AzlSonarApi /api/logs -All -BaseUrl $script:Url -Token $script:Token -WarningAction SilentlyContinue
        $result.Gap | Should -BeTrue
        $result.MissedFrom | Should -Be 3
        $result.MissedTo | Should -Be 7
        $result.MissedCount | Should -Be 5
    }

    It 'reports a gap when every line left the buffer (lastSeq above Since, no lines)' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 900) }
        $result = Invoke-AzlSonarApi /api/logs -All -Since 100 -BaseUrl $script:Url -Token $script:Token -WarningAction SilentlyContinue
        $result.Gap | Should -BeTrue
        $result.MissedFrom | Should -Be 101
        $result.MissedTo | Should -Be 900
    }

    It 'detects a restart against -ServerId and reads again from 0' {
        # The old cursor 500 is above the new newest seq: Sonar lowers it, so the first answer is empty and looks normal.
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -Server 'srv-2' -LastSeq 3) }
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -Server 'srv-2' -LastSeq 3 -Seq 1, 2, 3) }
        $result = Invoke-AzlSonarApi /api/logs -All -Since 500 -ServerId 'srv-1' -BaseUrl $script:Url -Token $script:Token -WarningVariable warned -WarningAction SilentlyContinue
        $result.Restarted | Should -BeTrue
        $result.Server | Should -Be 'srv-2'
        @($result.Lines).seq | Should -Be 1, 2, 3
        $result.Gap | Should -BeFalse
        "$warned" | Should -BeLike '*restarted*server id*'
        @(Get-SeenPath | Where-Object { $_ -like '/api/logs*' }) | Should -Be '/api/logs?since=500', '/api/logs?since=0'
    }

    It 'detects a restart between two pages and drops the lines of the old instance' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -Server 'srv-1' -LastSeq 2 -Truncated $true -Seq 1, 2) }
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -Server 'srv-2' -LastSeq 1) }
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -Server 'srv-2' -LastSeq 1 -Seq 1) }
        $result = Invoke-AzlSonarApi /api/logs -All -BaseUrl $script:Url -Token $script:Token -WarningAction SilentlyContinue
        $result.Restarted | Should -BeTrue
        $result.Server | Should -Be 'srv-2'
        @($result.Lines).Count | Should -Be 1
        $result.Lines[0].text | Should -Be 'line 1'
    }

    It 'does not call it a restart when -ServerId is the same' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -Server 'srv-1' -LastSeq 6 -Seq 6) }
        $result = Invoke-AzlSonarApi /api/logs -All -Since 5 -ServerId 'srv-1' -BaseUrl $script:Url -Token $script:Token
        $result.Restarted | Should -BeFalse
    }

    It 'stops when Sonar says truncated but gives no newer seq' {
        Set-FakeSonarDefault $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 0 -Truncated $true) }
        { Invoke-AzlSonarApi /api/logs -All -BaseUrl $script:Url -Token $script:Token } | Should -Throw '*no newer sequence number*'
    }

    It 'gives the result as one JSON text with -Raw' {
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 2 -Seq 1, 2) }
        $json = Invoke-AzlSonarApi /api/logs -All -Raw -BaseUrl $script:Url -Token $script:Token
        $parsed = $json | ConvertFrom-Json
        $parsed.LastSeq | Should -Be 2
        @($parsed.Lines).Count | Should -Be 2
    }
}

Describe 'Invoke-AzlSonarApi -Follow: /api/events (Server-Sent Events)' {
    BeforeEach { Initialize-ApiTest }

    It 'writes one object per event with the parsed data, skipping pings' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = $script:Sse }
        $events = @(Invoke-AzlSonarApi /api/events -Follow -BaseUrl $script:Url -Token $script:Token -WarningAction SilentlyContinue)
        $events.Event | Should -Be 'hello', 'state', 'tailer', 'log'
        $events[0].Data.server | Should -Be 'srv-1'
        $events[0].Data.since | Should -Be 10
        $events[1].Data.phase | Should -Be 'validation'
        @($events[3].Data.lines).Count | Should -Be 2
        $events[3].Data.lines[1].text | Should -Be 'b'
        (@($script:Fake.State.Requests | Where-Object { $_.Path -eq '/api/events' })[0]).Accept | Should -Be 'text/event-stream'
    }

    It 'filters with -EventName' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = $script:Sse }
        $events = @(Invoke-AzlSonarApi /api/events -Follow -EventName log, hello -BaseUrl $script:Url -Token $script:Token -WarningAction SilentlyContinue)
        $events.Event | Should -Be 'hello', 'log'
    }

    It 'writes one JSON line per event with -Raw' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = $script:Sse }
        $lines = @(Invoke-AzlSonarApi /api/events -Follow -Raw -EventName state -BaseUrl $script:Url -Token $script:Token -WarningAction SilentlyContinue)
        $lines.Count | Should -Be 1
        $parsed = $lines[0] | ConvertFrom-Json
        $parsed.event | Should -Be 'state'
        $parsed.data.phase | Should -Be 'validation'
    }

    It 'warns when the stream ends' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = "event: hello`ndata: {`"server`":`"s`",`"since`":0}`n`n" }
        $null = Invoke-AzlSonarApi /api/events -Follow -BaseUrl $script:Url -Token $script:Token -WarningVariable warned -WarningAction SilentlyContinue
        "$warned" | Should -BeLike '*stream ended*'
    }

    It 'stops after -DurationSeconds on a stream that stays open' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = "event: hello`ndata: {`"server`":`"s`",`"since`":0}`n`n"; HoldMs = 3000 }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $events = @(Invoke-AzlSonarApi /api/events -Follow -DurationSeconds 1 -BaseUrl $script:Url -Token $script:Token)
        $watch.Stop()
        $events.Count | Should -Be 1
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 4
    }

    It 'yields events as they arrive (does not wait for the stream to end)' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = "event: hello`ndata: {`"server`":`"s`",`"since`":0}`n`n"; HoldMs = 2500 }
        $first = Invoke-AzlSonarApi /api/events -Follow -BaseUrl $script:Url -Token $script:Token | Select-Object -First 1
        $first.Event | Should -Be 'hello'
    }

    It 'fails with a clear message when the stream goes silent' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = "event: hello`ndata: {`"server`":`"s`",`"since`":0}`n`n"; HoldMs = 4000 }
        $err = $null
        try { $null = @(Invoke-AzlSonarApi /api/events -Follow -TimeoutSeconds 1 -BaseUrl $script:Url -Token $script:Token) } catch { $err = $_ }
        $err.Exception.Message | Should -BeLike '*went silent for 1 second*'
    }

    It 'waits for Retry-After when too many streams are open, then follows' {
        Mock -ModuleName AzlSonar -CommandName Start-Sleep -MockWith { }
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Status = 429; Body = 'Too many streams.'; ContentType = 'text/plain'; Headers = @{ 'Retry-After' = '30' } }
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = "event: hello`ndata: {`"server`":`"s`",`"since`":0}`n`n" }
        $events = @(Invoke-AzlSonarApi /api/events -Follow -BaseUrl $script:Url -Token $script:Token -WarningAction SilentlyContinue)
        $events.Count | Should -Be 1
        Should -Invoke -ModuleName AzlSonar -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }

    It 'says what a 404 means for a replay' {
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Status = 404; Body = '{"error":"Replay mode: /api/events is not available; the page plays /api/replay."}' }
        { @(Invoke-AzlSonarApi /api/events -Follow -BaseUrl $script:Url -Token $script:Token) } | Should -Throw '*404*A replay does not serve*'
    }
}

Describe 'Invoke-AzlSonarApi: the token never appears in anything it writes' {
    BeforeEach { Initialize-ApiTest }

    It 'is in no output, verbose, warning or error stream, on success or failure' {
        $file = Join-Path $TestDrive 'secret.token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $file; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        Set-FakeSonarDefault $script:Fake '/api/state' @{ Body = '{"phase":"x"}' }
        Set-FakeSonarDefault $script:Fake '/api/gone' @{ Body = '{}' }
        Add-FakeSonarResponse $script:Fake '/api/logs' @{ Body = (Get-LogPage -LastSeq 30 -Seq 26, 30) }
        Add-FakeSonarResponse $script:Fake '/api/events' @{ Sse = $script:Sse }
        $all = & {
            $VerbosePreference = 'Continue'
            Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -TokenFile $file
            Invoke-AzlSonarApi /api/logs -All -Since 5 -BaseUrl $script:Url -TokenFile $file
            Invoke-AzlSonarApi /api/events -Follow -DurationSeconds 1 -BaseUrl $script:Url -Token $script:Token
            try { Invoke-AzlSonarApi /api/replay -BaseUrl $script:Url -Token $script:Token } catch { $_.Exception.Message; $_.ToString(); ($_ | Out-String) }
            try { Invoke-AzlSonarApi /api/state -BaseUrl 'http://localhost:1' -Token $script:Token } catch { $_.Exception.Message; ($_ | Out-String) }
            $script:Fake.State.Token = $script:OtherToken
            InModuleScope AzlSonar { Clear-AzlSonarApiSession }
            try { Invoke-AzlSonarApi /api/state -BaseUrl $script:Url -Token $script:Token } catch { $_.Exception.Message; ($_ | Out-String) }
        } *>&1
        $text = ($all | ForEach-Object { if ($_ -is [string]) { $_ } else { ($_ | Out-String) } }) -join "`n"
        $text.Length | Should -BeGreaterThan 50
        $text | Should -Not -Match $script:Token
        $text | Should -Not -Match $script:OtherToken
    }

    It 'Protect-AzlSonarApiText removes the token and any t= value' {
        $out = InModuleScope AzlSonar -Parameters @{ T = $script:Token } {
            param($T)
            Protect-AzlSonarApiText -Text "GET http://localhost:8642/?t=$T failed; cookie sonar_t=$T; again $T" -Token $T
        }
        $out | Should -Not -Match $script:Token
        $out | Should -BeLike '*t=***'
    }
}

Describe 'Invoke-AzlSonarApi against the real request handler (Server.ps1)' {
    BeforeAll {
        Add-Type -AssemblyName System.Net.Http
        $script:RealPort = Get-SonarFreeTcpPort
        $script:RealUrl = "http://localhost:$($script:RealPort)"
        $script:RealListener = [System.Net.HttpListener]::new()
        $script:RealListener.Prefixes.Add("$($script:RealUrl)/")
        $script:RealListener.Start()
        $json = New-SonarConfigObject
        $path = Join-Path $TestDrive 'real.config.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
        $config = Read-AzlSonarConfig -Path $path
        $script:RealServerFor = {
            param($Token)
            InModuleScope AzlSonar -Parameters @{ Config = $config; Token = $Token } {
                param($Config, $Token)
                $shared = Initialize-AzlSonarSharedState
                $state = Get-AzlSonarInitialState -Config $Config
                Publish-AzlSonarState -Shared $shared -State $state
                Add-AzlSonarLogLine -Shared $shared -Line @(
                    [pscustomobject]@{ file = 'C:\CloudDeployment\Logs\a.log'; text = 'first' }
                    [pscustomobject]@{ file = 'C:\CloudDeployment\Logs\a.log'; text = 'ERROR second' }
                )
                $table = @{
                    Shared       = $shared
                    WebRoot      = Join-Path $script:AzlSonarModuleRoot 'web'
                    ConfigJson   = ConvertTo-AzlSonarJson (ConvertTo-AzlSonarPublicConfig -Config $Config -StartedAt ([datetime]'2026-10-10T18:00:00Z'))
                    Facts        = New-AzlSonarDetailFact -Config $Config -ReadAt ([datetime]'2026-10-10T18:00:00Z')
                    GuidanceJson = ConvertTo-AzlSonarJson (Get-AzlSonarPhaseGuidance -IdentityModel $Config.identityModel)
                    ClusterName  = $Config.clusterName
                    Version      = '0.4.0'
                    Clients      = [System.Collections.Generic.List[hashtable]]::new()
                }
                if ($Token) { $table.Token = $Token }
                $table
            }
        }
        $script:PendingReal = $null
        function Invoke-HelperThroughRealHandler {
            # Runs the helper in a thread job (it blocks) while this thread answers with the real handler.
            param([string]$Command, [hashtable]$Server)
            $commandText = $Command
            $manifest = $script:SonarManifest
            $job = Start-ThreadJob -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                Import-Module -Name $using:manifest -Force
                try { & ([scriptblock]::Create($using:commandText)) 2>&1 } catch { [pscustomobject]@{ Error = $_.Exception.Message; Status = $(if ($_.Exception.PSObject.Properties['StatusCode']) { [int]$_.Exception.StatusCode } else { 0 }) } }
            }
            $deadline = [datetime]::UtcNow.AddSeconds(60)
            while ($job.State -in 'NotStarted', 'Running' -and [datetime]::UtcNow -lt $deadline) {
                if ($null -eq $script:PendingReal) { $script:PendingReal = $script:RealListener.GetContextAsync() }
                if ($script:PendingReal.Wait(50)) {
                    $context = $script:PendingReal.Result
                    $script:PendingReal = $null
                    InModuleScope AzlSonar -Parameters @{ Context = $context; Server = $Server } { param($Context, $Server) Invoke-AzlSonarHttpRequest -Context $Context -Server $Server }
                }
            }
            return (Receive-Job -Job $job -Wait -AutoRemoveJob)
        }
    }

    AfterAll {
        $script:RealListener.Stop(); $script:RealListener.Close()
    }

    It 'does the handshake against the real handler and reads /api/state and /api/logs' {
        $token = '0123456789abcdef0123456789abcdef'
        $server = & $script:RealServerFor $token
        $command = "`$s = Invoke-AzlSonarApi /api/state -BaseUrl '$($script:RealUrl)' -Token '$token'; `$l = Invoke-AzlSonarApi /api/logs -All -BaseUrl '$($script:RealUrl)' -Token '$token'; [pscustomobject]@{ Phase = `$s.phase; Lines = @(`$l.Lines).Count; Last = `$l.LastSeq; Server = `$l.Server }"
        $result = Invoke-HelperThroughRealHandler -Command $command -Server $server
        $result.Phase | Should -Be 'provisioning'
        $result.Lines | Should -Be 2
        $result.Last | Should -Be 2
        $result.Server | Should -Be $server.Shared.ServerId
    }

    It 'gets 401 with a wrong token, 404 for /api/replay when live, and works without a token when the token is off' {
        $token = '0123456789abcdef0123456789abcdef'
        $server = & $script:RealServerFor $token
        $wrong = Invoke-HelperThroughRealHandler -Server $server -Command "Invoke-AzlSonarApi /api/state -BaseUrl '$($script:RealUrl)' -Token 'ffffffffffffffffffffffffffffffff'"
        $wrong.Status | Should -Be 401
        $wrong.Error | Should -BeLike '*401*'
        $replay = Invoke-HelperThroughRealHandler -Server $server -Command "Invoke-AzlSonarApi /api/replay -BaseUrl '$($script:RealUrl)' -Token '$token'"
        $replay.Status | Should -Be 404
        $replay.Error | Should -BeLike '*-Replay*'
        $open = & $script:RealServerFor ''
        $about = Invoke-HelperThroughRealHandler -Server $open -Command "Invoke-AzlSonarApi /api/about -BaseUrl '$($script:RealUrl)'"
        $about.name | Should -Be 'AzL Sonar'
    }
}
