[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers start and stop a localhost fake only.')]
param()
Set-StrictMode -Version Latest

# A fake AzL Sonar for the API helper tests: an HttpListener on localhost in its own runspace, with the real handshake
# (GET /?t=<token> answers 302 and sets sonar_t; anything else without the cookie answers 401), scripted answers per
# path, and a log of the requests it saw. No Azure, no node, no network except a localhost port.
#
#   $fake = Start-FakeSonar -Token 'aaaabbbbccccddddeeeeffff00001111'
#   Add-FakeSonarResponse $fake '/api/state' @{ Body = '{"phase":"x"}' }       # next answer for the path (queue)
#   Set-FakeSonarDefault $fake '/api/about' @{ Body = '{"name":"AzL Sonar"}' } # every answer for the path
#   $fake.State.Requests                                                         # what it saw
#   Stop-FakeSonar $fake
#
# A spec: Status (200), Body, ContentType (application/json; charset=utf-8), Headers (hashtable), HoldMs (wait before
# answering), Sse (the text of an event stream; kept open for HoldMs after it).

function Start-FakeSonar {
    param([AllowEmptyString()][string]$Token = 'aaaabbbbccccddddeeeeffff00001111')

    $port = Get-SonarFreeTcpPort
    $state = [hashtable]::Synchronized(@{
            Stop     = $false
            Ready    = $false
            Busy     = $false
            Token    = $Token
            Requests = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
            Queues   = [hashtable]::Synchronized(@{})
            Defaults = [hashtable]::Synchronized(@{})
        })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript({
            param($Port, $S)
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add("http://localhost:$Port/")
            $listener.Start()
            $S.Ready = $true
            function Send {
                param($Res, [int]$Status, [string]$Body, [string]$Type = 'application/json; charset=utf-8', $Headers)
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $Res.StatusCode = $Status
                $Res.ContentType = $Type
                if ($Headers) { foreach ($k in $Headers.Keys) { $Res.AppendHeader([string]$k, [string]$Headers[$k]) } }
                $Res.ContentLength64 = $bytes.Length
                $Res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            try {
                while (-not $S.Stop) {
                    $task = $listener.GetContextAsync()
                    while (-not $task.Wait(50)) { if ($S.Stop) { return } }
                    $context = $task.Result
                    $S.Busy = $true
                    $req = $context.Request
                    $res = $context.Response
                    try {
                        $path = $req.Url.AbsolutePath
                        $cookie = $req.Cookies['sonar_t']
                        $null = $S.Requests.Add([pscustomobject]@{ Method = $req.HttpMethod; Url = $req.Url.PathAndQuery; Path = $path; HasCookie = ($null -ne $cookie); Accept = [string]$req.Headers['Accept'] })
                        if ($req.HttpMethod -ne 'GET') { Send $res 405 'Only GET is supported.' 'text/plain' @{ Allow = 'GET' }; continue }
                        $token = [string]$S.Token
                        if ($token) {
                            $cookieOk = $null -ne $cookie -and $cookie.Value -ceq $token
                            if (-not $cookieOk) {
                                if ($req.QueryString['t'] -ceq $token) {
                                    Send $res 302 '' 'text/plain' @{ Location = '/'; 'Set-Cookie' = "sonar_t=$token; HttpOnly; SameSite=Strict; Path=/" }
                                }
                                else { Send $res 401 'Open the URL Sonar printed.' 'text/plain' }
                                continue
                            }
                        }
                        $spec = $null
                        $queue = $S.Queues[$path]
                        if ($null -ne $queue -and $queue.Count -gt 0) { $spec = $queue.Dequeue() }
                        elseif ($S.Defaults.ContainsKey($path)) { $spec = $S.Defaults[$path] }
                        if ($null -eq $spec) { Send $res 404 (('{"error":"Unknown API route: ' + $path + '"}')) 'application/json; charset=utf-8'; continue }
                        $hold = if ($spec.ContainsKey('HoldMs')) { [int]$spec.HoldMs } else { 0 }
                        if ($spec.ContainsKey('Sse')) {
                            $res.StatusCode = 200
                            $res.ContentType = 'text/event-stream; charset=utf-8'
                            $res.SendChunked = $true
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$spec.Sse)
                            $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            $res.OutputStream.Flush()
                        }
                        if ($hold -gt 0) {
                            $until = [datetime]::UtcNow.AddMilliseconds($hold)
                            while ([datetime]::UtcNow -lt $until -and -not $S.Stop) { Start-Sleep -Milliseconds 25 }
                        }
                        if (-not $spec.ContainsKey('Sse')) {
                            $status = if ($spec.ContainsKey('Status')) { [int]$spec.Status } else { 200 }
                            $type = if ($spec.ContainsKey('ContentType')) { [string]$spec.ContentType } else { 'application/json; charset=utf-8' }
                            $headers = if ($spec.ContainsKey('Headers')) { $spec.Headers } else { $null }
                            Send $res $status ([string]$spec.Body) $type $headers
                        }
                    }
                    catch { Write-Verbose "fake: $($_.Exception.Message)" }
                    finally { try { $res.Close() } catch { Write-Verbose 'fake: close' }; $S.Busy = $false }
                }
            }
            finally { $listener.Stop(); $listener.Close() }
        }).AddArgument($port).AddArgument($state)
    $handle = $ps.BeginInvoke()
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while (-not $state.Ready -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    if (-not $state.Ready) { throw 'The fake Sonar did not start.' }
    return [pscustomobject]@{ Port = $port; BaseUrl = "http://localhost:$port"; State = $state; PowerShell = $ps; Runspace = $runspace; Handle = $handle }
}

function Stop-FakeSonar {
    param($Fake)
    if ($null -eq $Fake) { return }
    $Fake.State.Stop = $true
    try { $null = $Fake.Handle.AsyncWaitHandle.WaitOne(3000) } catch { Write-Verbose 'fake: wait' }
    try { $Fake.PowerShell.Dispose() } catch { Write-Verbose 'fake: dispose' }
    try { $Fake.Runspace.Dispose() } catch { Write-Verbose 'fake: dispose runspace' }
}

function Add-FakeSonarResponse {
    param($Fake, [string]$Path, [hashtable]$Spec)
    if (-not $Fake.State.Queues.ContainsKey($Path)) { $Fake.State.Queues[$Path] = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new()) }
    $Fake.State.Queues[$Path].Enqueue($Spec)
}

function Set-FakeSonarDefault {
    param($Fake, [string]$Path, [hashtable]$Spec)
    $Fake.State.Defaults[$Path] = $Spec
}

function Wait-FakeSonarIdle {
    # A held answer (HoldMs) keeps the fake busy; wait until it is done so the next test starts clean.
    param($Fake)
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while ($Fake.State.Busy -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
}

function Reset-FakeSonar {
    # Forget the queued answers, the defaults and the request log (a test starts clean).
    param($Fake)
    $Fake.State.Queues.Clear()
    $Fake.State.Defaults.Clear()
    $Fake.State.Requests.Clear()
}
