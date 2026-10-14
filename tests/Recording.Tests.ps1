#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Record and replay (S-11). No Azure, no node: the recorder reads an in-memory shared table; the end-to-end tests
# bind a free localhost port (never 8642) and mock every worker and Azure call.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    Add-Type -AssemblyName System.Net.Http
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/recording-sample.jsonl'

    function script:T([string]$Time) {
        [datetime]::Parse("2026-10-11T$($Time)Z", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    }

    # A small state like the poller's: phase, a step tree and polledAt.
    function script:New-SonarRecState {
        param([string]$Phase = 'validation', [string[]]$Status = @('running'), [string]$PolledAt = '2026-10-11T10:00:00Z', [string[]]$Errors = @())
        $tree = for ($i = 0; $i -lt $Status.Count; $i++) {
            [ordered]@{ id = [string]$i; name = "Step $i"; status = $Status[$i]; start = '2026-10-11T09:59:00Z'; end = $null; durationSeconds = 60 + $i; errors = @($Errors); children = @() }
        }
        return [ordered]@{ cluster = 'clus01'; phase = $Phase; activePhase = $Phase; validation = [ordered]@{ status = 'InProgress'; tree = @($tree) }; polledAt = $PolledAt }
    }

    function script:Open-SonarTestRecorder {
        param([string]$Path, [string[]]$Secret = @(), [int]$MaxDeltas = 200, [datetime]$Now = (T '10:00:00'))
        InModuleScope AzlSonar -Parameters @{ P = $Path; S = $Secret; M = $MaxDeltas; N = $Now } {
            param($P, $S, $M, $N)
            $session = New-AzlSonarSessionJson -ConfigJson '{"cluster":"clus01","clusterName":"clus01"}' -GuidanceJson '{"phases":{}}' -ServerId 'srv1' -Version '0.1.0' -Cluster 'clus01'
            Open-AzlSonarRecorder -Path $P -SessionJson $session -Secret $S -MaxDeltas $M -Now $N
        }
    }

    function script:Step-SonarRecorder {
        param([hashtable]$Recorder, [System.Collections.IDictionary]$Shared, [datetime]$Now)
        InModuleScope AzlSonar -Parameters @{ R = $Recorder; S = $Shared; N = $Now } { param($R, $S, $N) Invoke-AzlSonarRecorderStep -Recorder $R -Shared $S -Now $N }
    }

    function script:Get-SonarRecordLine {
        param([string]$Path)
        @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 64 })
    }
}

Describe 'Recording: write (Open-AzlSonarRecorder, Invoke-AzlSonarRecorderStep)' {
    BeforeEach {
        $script:Path = Join-Path $TestDrive ("rec-" + [guid]::NewGuid().ToString('N') + '.jsonl')
        $script:Shared = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
    }

    It 'writes a session header, then a keyframe, then only deltas; an unchanged state writes nothing' {
        $rec = Open-SonarTestRecorder -Path $script:Path
        $state = New-SonarRecState
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared; X = $state } { param($S, $X) Publish-AzlSonarState -Shared $S -State $X }
        Step-SonarRecorder $rec $script:Shared (T '10:00:01')
        Step-SonarRecorder $rec $script:Shared (T '10:00:02')   # nothing new
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared; X = $state } { param($S, $X) Publish-AzlSonarState -Shared $S -State $X }
        Step-SonarRecorder $rec $script:Shared (T '10:00:21')   # published again, same JSON: nothing written
        $state.polledAt = '2026-10-11T10:00:40Z'
        $state.validation.tree[0].status = 'success'
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared; X = $state } { param($S, $X) Publish-AzlSonarState -Shared $S -State $X }
        Step-SonarRecorder $rec $script:Shared (T '10:00:41')
        InModuleScope AzlSonar -Parameters @{ R = $rec } { param($R) Close-AzlSonarRecorder -Recorder $R -Now ([datetime]'2026-10-11T10:01:00Z') }

        $lines = Get-SonarRecordLine $script:Path
        @($lines.k) | Should -Be @('session', 'state', 'state', 'end')
        $lines[0].format | Should -Be 1
        $lines[0].tool | Should -Be 'AzL Sonar'
        $lines[0].config.cluster | Should -Be 'clus01'
        (Get-Content -LiteralPath $script:Path)[1] | Should -Match '^\{"t":"2026-10-11T10:00:01\.000Z","k":"state","full":'
        $lines[1].full.phase | Should -Be 'validation'
        $lines[2].PSObject.Properties.Name | Should -Not -Contain 'full'
        $ops = @($lines[2].ops | ForEach-Object { , @($_) })
        $ops.Count | Should -Be 2
        (Get-Content -LiteralPath $script:Path)[2] | Should -BeExactly '{"t":"2026-10-11T10:00:41.000Z","k":"state","ops":[["s",["validation","tree",0,"status"],"success"],["s",["polledAt"],"2026-10-11T10:00:40Z"]]}'
    }

    It 'records log lines in order, in batches, with no gap across many polls' {
        $rec = Open-SonarTestRecorder -Path $script:Path
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared } {
            param($S)
            Publish-AzlSonarState -Shared $S -State ([ordered]@{ phase = 'deployment' })
            Add-AzlSonarLogLine -Shared $S -Time ([datetime]'2026-10-11T10:00:00Z') -Line @(1..1500 | ForEach-Object { [pscustomobject]@{ file = 'C:\a.log'; text = "line $_" } })
        }
        Step-SonarRecorder $rec $script:Shared (T '10:00:01')
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared } { param($S) Add-AzlSonarLogLine -Shared $S -Line @([pscustomobject]@{ file = 'C:\a.log'; text = 'ERROR last' }) }
        Step-SonarRecorder $rec $script:Shared (T '10:00:02')
        $rec.Writer.Dispose()
        $logs = @(Get-SonarRecordLine $script:Path | Where-Object { $_.k -eq 'log' })
        $logs.Count | Should -Be 3
        $seqs = @($logs | ForEach-Object { $_.lines } | ForEach-Object { [long]$_.seq })
        $seqs.Count | Should -Be 1501
        ($seqs -join ',') | Should -Be ((1..1501) -join ',')
        $last = $logs[-1].lines[-1]
        $last.level | Should -Be 'error'
        $last.text | Should -Be 'ERROR last'
        @($last.PSObject.Properties.Name) | Should -Be @('seq', 'time', 'received', 'timeSource', 'file', 'level', 'text')
    }

    It 'counts the lines it lost when the ring buffer dropped them before they were recorded' {
        $script:Shared.RingSize = 10
        $rec = Open-SonarTestRecorder -Path $script:Path
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared } {
            param($S)
            Add-AzlSonarLogLine -Shared $S -Line @(1..25 | ForEach-Object { [pscustomobject]@{ file = 'C:\a.log'; text = "line $_" } })
        }
        Step-SonarRecorder $rec $script:Shared (T '10:00:01')
        $rec.Writer.Dispose()
        $log = @(Get-SonarRecordLine $script:Path | Where-Object { $_.k -eq 'log' })[0]
        $log.lost | Should -Be 15
        @($log.lines).Count | Should -Be 10
        $log.lines[0].seq | Should -Be 16
    }

    It 'masks secrets everywhere it writes: state, log lines, tailer status and the session header' {
        $config = [pscustomobject]@{ credential = [pscustomobject]@{ source = 'keyvault'; vault = 'kv-rec-test-vault'; usernameSecret = 'rec-user-secret-name'; passwordSecret = 'rec-pass-secret-name' } }
        $script:Shared.Redact = @('P@ssw0rd-Exact!')
        $secret = InModuleScope AzlSonar -Parameters @{ S = $script:Shared; C = $config } { param($S, $C) Get-AzlSonarRecorderSecret -Shared $S -Config $C }
        @($secret) | Should -Be @('P@ssw0rd-Exact!', 'kv-rec-test-vault', 'rec-user-secret-name', 'rec-pass-secret-name')
        $rec = InModuleScope AzlSonar -Parameters @{ P = $script:Path; S = $secret } {
            param($P, $S)
            $session = New-AzlSonarSessionJson -ConfigJson '{"cluster":"clus01","note":"vault kv-rec-test-vault"}' -GuidanceJson '{"phases":{}}' -ServerId 'srv' -Version '0.1.0' -Cluster 'clus01'
            Open-AzlSonarRecorder -Path $P -SessionJson $session -Secret $S
        }
        $state = New-SonarRecState -Status @('error') -Errors @('Login failed: password=P@ssw0rd-Exact! (secret rec-pass-secret-name in kv-rec-test-vault)', 'Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOi.sig')
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared; X = $state } {
            param($S, $X)
            Publish-AzlSonarState -Shared $S -State $X
            # The tailer masks lines itself; the recorder masks again (here the shared Redact is cleared first to prove it).
            $S.Redact = @()
            Add-AzlSonarLogLine -Shared $S -Line @(
                [pscustomobject]@{ file = 'C:\a.log'; text = 'Connect-AzAccount -AccessToken abc client_secret=xyz123 P@ssw0rd-Exact!' }
                [pscustomobject]@{ file = 'C:\a.log'; text = 'Get-AzKeyVaultSecret -VaultName kv-rec-test-vault -Name rec-user-secret-name' }
            )
            Publish-AzlSonarTailerStatus -Shared $S -Status ([ordered]@{ state = 'error'; reason = 'Access denied for password=P@ssw0rd-Exact!'; node = 'node01' })
        }
        Step-SonarRecorder $rec $script:Shared (T '10:00:01')
        InModuleScope AzlSonar -Parameters @{ R = $rec } { param($R) Close-AzlSonarRecorder -Recorder $R }

        $text = Get-Content -LiteralPath $script:Path -Raw
        $text | Should -Not -Match 'P@ssw0rd-Exact!'
        $text | Should -Not -Match 'kv-rec-test-vault|rec-user-secret-name|rec-pass-secret-name'
        $text | Should -Not -Match 'eyJ0eXAiOiJKV1QiLCJhbGciOi|xyz123'
        $text | Should -Match 'password=\*\*\*'
        $text | Should -Match 'Bearer \*\*\*'
        $text | Should -Match 'client_secret=\*\*\*'
        @(Get-SonarRecordLine $script:Path | Where-Object { $_.k -eq 'tailer' })[0].tailer.reason | Should -Be 'Access denied for password=***'
    }

    It 'appends a new session to an existing recording and never truncates it' {
        $rec = Open-SonarTestRecorder -Path $script:Path -Now (T '10:00:00')
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared } { param($S) Publish-AzlSonarState -Shared $S -State ([ordered]@{ phase = 'validation'; n = 1 }) }
        Step-SonarRecorder $rec $script:Shared (T '10:00:01')
        InModuleScope AzlSonar -Parameters @{ R = $rec } { param($R) Close-AzlSonarRecorder -Recorder $R -Now ([datetime]'2026-10-11T10:00:02Z') }
        $before = Get-Content -LiteralPath $script:Path -Raw

        $shared2 = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $rec2 = Open-SonarTestRecorder -Path $script:Path -Now (T '10:05:00')
        InModuleScope AzlSonar -Parameters @{ S = $shared2 } { param($S) Publish-AzlSonarState -Shared $S -State ([ordered]@{ phase = 'validation'; n = 2 }) }
        Step-SonarRecorder $rec2 $shared2 (T '10:05:01')
        InModuleScope AzlSonar -Parameters @{ R = $rec2 } { param($R) Close-AzlSonarRecorder -Recorder $R -Now ([datetime]'2026-10-11T10:05:02Z') }

        $after = Get-Content -LiteralPath $script:Path -Raw
        $after.StartsWith($before) | Should -BeTrue
        @((Get-SonarRecordLine $script:Path).k) | Should -Be @('session', 'state', 'end', 'session', 'state', 'end')
        @(Get-SonarRecordLine $script:Path | Where-Object { $_.k -eq 'state' })[1].full.n | Should -Be 2 -Because 'each session starts with a keyframe'
    }

    It 'starts the new session on its own line when Sonar stopped mid-write; the reader skips the partial line' {
        [System.IO.File]::WriteAllText($script:Path, '{"t":"2026-10-11T09:00:00.000Z","k":"session","format":1,"tool":"AzL Sonar"}' + "`n" +
            '{"t":"2026-10-11T09:00:01.000Z","k":"state","full":{"phase":"validation"}}' + "`n" + '{"t":"2026-10-11T09:00:21.000Z","k":"state","op')
        $rec = Open-SonarTestRecorder -Path $script:Path -Now (T '10:00:00')
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared } { param($S) Publish-AzlSonarState -Shared $S -State ([ordered]@{ phase = 'deployment' }) }
        Step-SonarRecorder $rec $script:Shared (T '10:00:01')
        InModuleScope AzlSonar -Parameters @{ R = $rec } { param($R) Close-AzlSonarRecorder -Recorder $R }
        $raw = @(Get-Content -LiteralPath $script:Path)
        $raw[2] | Should -BeExactly '{"t":"2026-10-11T09:00:21.000Z","k":"state","op'
        $raw[3] | Should -Match '^\{"t":"2026-10-11T10:00:00.000Z","k":"session"'
        $recording = InModuleScope AzlSonar -Parameters @{ P = $script:Path } { param($P) Read-AzlSonarRecording -Path $P }
        $recording.Invalid | Should -Be 1
        @($recording.Sessions).Count | Should -Be 2
    }

    It 'writes a keyframe again after MaxDeltas deltas, and when the deltas add up to a keyframe' {
        $rec = Open-SonarTestRecorder -Path $script:Path -MaxDeltas 3
        for ($i = 0; $i -lt 8; $i++) {
            $state = New-SonarRecState -PolledAt ('2026-10-11T10:{0:00}:00Z' -f $i)
            InModuleScope AzlSonar -Parameters @{ S = $script:Shared; X = $state } { param($S, $X) Publish-AzlSonarState -Shared $S -State $X }
            Step-SonarRecorder $rec $script:Shared (T ('10:{0:00}:01' -f $i))
        }
        $rec.Writer.Dispose()
        $kinds = @(Get-SonarRecordLine $script:Path | Where-Object { $_.k -eq 'state' } | ForEach-Object { if ($_.PSObject.Properties.Name -contains 'full') { 'K' } else { 'd' } })
        ($kinds -join '') | Should -Be 'KdddKdddK'.Substring(0, 8)

        # A change bigger than the keyframe is written as a keyframe.
        $path2 = Join-Path $TestDrive 'big.jsonl'
        $shared2 = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $rec2 = Open-SonarTestRecorder -Path $path2
        InModuleScope AzlSonar -Parameters @{ S = $shared2 } { param($S) Publish-AzlSonarState -Shared $S -State ([ordered]@{ a = 1 }) }
        Step-SonarRecorder $rec2 $shared2 (T '10:00:01')
        InModuleScope AzlSonar -Parameters @{ S = $shared2 } { param($S) Publish-AzlSonarState -Shared $S -State ([ordered]@{ a = 1; b = ('x' * 500) }) }
        Step-SonarRecorder $rec2 $shared2 (T '10:00:21')
        $rec2.Writer.Dispose()
        @(Get-SonarRecordLine $path2 | Where-Object { $_.k -eq 'state' } | ForEach-Object { $_.PSObject.Properties.Name -contains 'full' }) | Should -Be @($true, $true)
    }

    It 'Resolve-AzlSonarRecordPath creates the folder and refuses a folder as the file' {
        $nested = Join-Path $TestDrive 'a/b/c/run.jsonl'
        $full = InModuleScope AzlSonar -Parameters @{ P = $nested } { param($P) Resolve-AzlSonarRecordPath -Path $P }
        $full | Should -Be ([System.IO.Path]::GetFullPath($nested))
        Test-Path -LiteralPath (Split-Path $nested) | Should -BeTrue
        { InModuleScope AzlSonar -Parameters @{ P = $TestDrive } { param($P) Resolve-AzlSonarRecordPath -Path $P } } | Should -Throw '*is a folder*'
    }

    It 'Invoke-AzlSonarRecorderLoop records once more and writes the end event when Sonar stops' {
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared } { param($S) Publish-AzlSonarState -Shared $S -State ([ordered]@{ phase = 'validation' }); $S.Stop = $true }
        InModuleScope AzlSonar -Parameters @{ S = $script:Shared; P = $script:Path } {
            param($S, $P)
            Invoke-AzlSonarRecorderLoop -Shared $S -Path $P -SessionJson (New-AzlSonarSessionJson -ConfigJson '{}' -GuidanceJson '{}') -Config $null
        }
        @((Get-SonarRecordLine $script:Path).k) | Should -Be @('session', 'state', 'end')
    }
}

Describe 'Recording: read and seek (Read-AzlSonarRecording, Get-AzlSonarRecordingStateAt)' {
    BeforeAll {
        $script:Sample = InModuleScope AzlSonar -Parameters @{ P = $script:Fixture } { param($P) Read-AzlSonarRecording -Path $P }
        function script:Get-SonarStateAt([datetime]$At) {
            $json = InModuleScope AzlSonar -Parameters @{ R = $script:Sample; A = $At } { param($R, $A) Get-AzlSonarRecordingStateAt -Recording $R -Time $A }
            if ($json) { $json | ConvertFrom-Json -Depth 64 } else { $null }
        }
    }

    It 'reads the sample recording: two sessions, start, end, cluster, config and guidance' {
        $r = $script:Sample
        @($r.Sessions).Count | Should -Be 2
        @($r.Sessions.Server) | Should -Be @('a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2')
        $r.Start | Should -Be (T '08:00:00')
        $r.End | Should -Be (T '09:06:00')
        $r.Cluster | Should -Be 'clus01'
        $r.Invalid | Should -Be 0
        ($r.ConfigJson | ConvertFrom-Json).identityModel | Should -Be 'LocalIdentity'
        ($r.GuidanceJson | ConvertFrom-Json).phases.deployment.account | Should -Be 'The deployment local admin'
        @($r.Events | Where-Object Kind -EQ 'state').Count | Should -Be 12
    }

    It 'the sample recording holds no secret' {
        $text = Get-Content -LiteralPath $script:Fixture -Raw
        $text | Should -Not -Match 'Hunter2|sample-pass-secret|sample-user-secret|kv-sample-vault|eyJhbGci'
        $text | Should -Match 'password=\*\*\*'
    }

    It 'returns $null before the first state' {
        Get-SonarStateAt (T '08:00:00.5') | Should -BeNullOrEmpty
    }

    It 'rebuilds the state at <At>: phase <Phase>' -TestCases @(
        @{ At = '08:03:00'; Phase = 'arc-registration'; Check = { param($s) [datetime]$s.polledAt | Should -Be (T '08:00:21'); $s.provisioning.status | Should -Be 'running' } }
        @{ At = '08:07:00'; Phase = 'arc-registration'; Check = { param($s) $s.provisioning.readyForValidate | Should -BeTrue } }
        @{ At = '08:11:00'; Phase = 'validation'; Check = { param($s) $s.validation.tree[0].status | Should -Be 'running' } }
        @{ At = '08:13:00'; Phase = 'validation'; Check = { param($s) $s.validation.tree[1].status | Should -Be 'running'; $s.current.stepName | Should -Be 'Validate Hardware' } }
        @{ At = '08:35:00'; Phase = 'deployment'; Check = { param($s) @($s.deployment.tree.status) | Should -Be @('success', 'running', 'notstarted') } }
        @{ At = '08:52:00'; Phase = 'failed'; Check = { param($s) $s.deployment.tree[2].status | Should -Be 'error'; $s.deployment.tree[2].errors[0] | Should -Match 'password=\*\*\* was rejected \(\*\*\*\)' } }
        @{ At = '08:56:00'; Phase = 'deployment'; Check = { param($s) $s.deployment.tree[2].status | Should -Be 'running'; @($s.deployment.tree[2].errors).Count | Should -Be 0 } }
        @{ At = '09:30:00'; Phase = 'done'; Check = { param($s) $s.deployment.status | Should -Be 'Success' } }
    ) {

        $s = Get-SonarStateAt (T $At)
        $s.phase | Should -Be $Phase
        & $Check $s
    }

    It 'seek correctness: every state the recorder was given comes back exactly at its recorded time' {
        $path = Join-Path $TestDrive 'roundtrip.jsonl'
        $shared = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $rec = Open-SonarTestRecorder -Path $path -MaxDeltas 2
        $published = [System.Collections.Generic.List[object]]::new()
        $statuses = @(
            @('running', 'notstarted', 'notstarted'), @('success', 'running', 'notstarted'), @('success', 'running', 'notstarted'),
            @('success', 'success', 'running'), @('success', 'success'), @('success', 'success', 'error', 'running'),
            @('success'), @('success', 'success', 'success', 'success', 'success')
        )
        for ($i = 0; $i -lt $statuses.Count; $i++) {
            $state = New-SonarRecState -Status $statuses[$i] -PolledAt ('2026-10-11T10:{0:00}:00Z' -f $i) -Errors $(if ($i -eq 5) { @('boom') } else { @() })
            if ($i -eq 4) { $state.Remove('activePhase'); $state.extra = [ordered]@{ list = @(1, 2, 3); nested = [ordered]@{ deep = $true } } }
            if ($i -eq 6) { $state.extra = $null }
            $at = T ('10:{0:00}:01' -f $i)
            InModuleScope AzlSonar -Parameters @{ S = $shared; X = $state } { param($S, $X) Publish-AzlSonarState -Shared $S -State $X }
            Step-SonarRecorder $rec $shared $at
            $published.Add(@{ At = $at; Json = (InModuleScope AzlSonar -Parameters @{ X = $state } { param($X) ConvertTo-AzlSonarJson $X }) })
        }
        $rec.Writer.Dispose()
        $recording = InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) Read-AzlSonarRecording -Path $P }
        @($recording.Events | Where-Object { $_.Kind -eq 'state' -and $null -ne $_.Node['full'] }).Count | Should -BeGreaterThan 2
        foreach ($item in ($published.ToArray() + @($published[3], $published[0], $published[6]))) {
            $got = InModuleScope AzlSonar -Parameters @{ R = $recording; A = $item.At.AddSeconds(5) } { param($R, $A) Get-AzlSonarRecordingStateAt -Recording $R -Time $A }
            $equal = [System.Text.Json.Nodes.JsonNode]::DeepEquals([System.Text.Json.Nodes.JsonNode]::Parse($got), [System.Text.Json.Nodes.JsonNode]::Parse($item.Json))
            $equal | Should -BeTrue -Because "the state at $($item.At.ToString('o')) must be the one published then"
        }
    }

    It 'reads a gzip-compressed recording (.jsonl.gz)' {
        $gz = Join-Path $TestDrive 'sample.jsonl.gz'
        $out = [System.IO.File]::Create($gz)
        try {
            $zip = [System.IO.Compression.GZipStream]::new($out, [System.IO.Compression.CompressionMode]::Compress)
            $bytes = [System.IO.File]::ReadAllBytes($script:Fixture)
            $zip.Write($bytes, 0, $bytes.Length)
            $zip.Dispose()
        }
        finally { $out.Dispose() }
        $r = InModuleScope AzlSonar -Parameters @{ P = $gz } { param($P) Read-AzlSonarRecording -Path $P }
        $r.Events.Count | Should -Be $script:Sample.Events.Count
    }

    It 'refuses <Name>' -TestCases @(
        @{ Name = 'a missing file'; Content = $null; Expected = '*Recording not found*'; File = $null }
        @{ Name = 'an empty file'; Content = "`n  `n"; Expected = '*is empty*'; File = $null }
        @{ Name = 'a file that is not JSON Lines'; Content = "hello`nworld"; Expected = '*no line is a valid event*'; File = $null }
        @{ Name = 'a file that does not start with a session header'; Content = '{"t":"2026-10-11T08:00:00Z","k":"state","full":{}}'; Expected = '*does not start with a session header*'; File = $null }
        @{ Name = 'a newer format'; Content = '{"t":"2026-10-11T08:00:00Z","k":"session","format":2}'; Expected = '*format 2 by a newer AzL Sonar*'; File = $null }
        @{ Name = 'a session header without a format'; Content = '{"t":"2026-10-11T08:00:00Z","k":"session"}'; Expected = '*without a valid format*'; File = $null }
        @{ Name = 'a recording without any state'; Content = '{"t":"2026-10-11T08:00:00Z","k":"session","format":1}' + "`n" + '{"t":"2026-10-11T08:00:01Z","k":"end"}'; Expected = '*holds no state snapshots*'; File = $null }
        @{ Name = 'a .gz file that is not gzip'; Content = 'plain text'; Expected = '*not a valid gzip file*'; File = 'bad.jsonl.gz' }
    ) {

        $path = Join-Path $TestDrive $(if ($File) { $File } else { "bad-$([guid]::NewGuid().ToString('N')).jsonl" })
        if ($null -ne $Content) { [System.IO.File]::WriteAllText($path, $Content) }
        { InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) Read-AzlSonarRecording -Path $P } } | Should -Throw $Expected
    }

    It 'skips invalid lines, unknown kinds and a delta before any keyframe, and counts them' {
        $path = Join-Path $TestDrive 'mixed.jsonl'
        @(
            '{"t":"2026-10-11T08:00:00Z","k":"session","format":1}'
            '{"t":"2026-10-11T08:00:01Z","k":"state","ops":[["s",["a"],1]]}'
            'not json'
            '{"t":"not a time","k":"state","full":{}}'
            '{"t":"2026-10-11T08:00:02Z","k":"future-kind","x":1}'
            '{"t":"2026-10-11T08:00:03Z","k":"state","full":{"a":0}}'
            '{"t":"2026-10-11T08:00:04Z","k":"log","lines":"not a list"}'
            '{"t":"2026-10-11T08:00:05Z","k":"state","ops":[["s",["a"],2]]}'
        ) | Set-Content -LiteralPath $path
        $r = InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) Read-AzlSonarRecording -Path $P }
        $r.Invalid | Should -Be 4
        $r.Ignored | Should -Be 1
        @($r.Events.Kind) | Should -Be @('session', 'state', 'state')
        InModuleScope AzlSonar -Parameters @{ R = $r } { param($R) Get-AzlSonarRecordingStateAt -Recording $R -Time ([datetime]'2026-10-11T08:00:09Z') } | Should -Be '{"a":2}'
    }
}

Describe 'ConvertTo-AzlSonarReplayStart (-StartAt)' {
    It 'reads <Value> as <Expected>' -TestCases @(
        @{ Value = ''; Expected = '08:00:00' }
        @{ Value = '0:42:10'; Expected = '08:42:10' }
        @{ Value = '+0:05'; Expected = '08:05:00' }
        @{ Value = '1:00:00'; Expected = '09:00:00' }
        @{ Value = '90m'; Expected = '09:30:00' }
        @{ Value = '1h30m'; Expected = '09:30:00' }
        @{ Value = '45s'; Expected = '08:00:45' }
        @{ Value = '2026-10-11T09:15:00Z'; Expected = '09:15:00' }
    ) {

        $r = InModuleScope AzlSonar -Parameters @{ V = $Value; S = (T '08:00:00'); E = (T '10:00:00') } { param($V, $S, $E) ConvertTo-AzlSonarReplayStart -Value $V -Start $S -End $E }
        $r.Time | Should -Be (T $Expected)
        $r.Phase | Should -BeNullOrEmpty
    }

    It 'reads the phase <Value> as <Phase> (the page jumps to its marker)' -TestCases @(
        @{ Value = 'deployment'; Phase = 'deployment' }
        @{ Value = 'Deploy'; Phase = 'deployment' }
        @{ Value = 'validate'; Phase = 'validation' }
        @{ Value = 'arc'; Phase = 'arc-registration' }
    ) {

        $r = InModuleScope AzlSonar -Parameters @{ V = $Value; S = (T '08:00:00'); E = (T '10:00:00') } { param($V, $S, $E) ConvertTo-AzlSonarReplayStart -Value $V -Start $S -End $E }
        $r.Phase | Should -Be $Phase
        $r.Time | Should -BeNullOrEmpty
    }

    It 'refuses <Value>' -TestCases @(
        @{ Value = '3:00:00'; Expected = '*past the end of the recording (length 2:00:00)*' }
        @{ Value = '2026-10-11T07:00:00Z'; Expected = '*outside the recording*' }
        @{ Value = 'soon'; Expected = '*is not an offset*' }
    ) {

        { InModuleScope AzlSonar -Parameters @{ V = $Value; S = (T '08:00:00'); E = (T '10:00:00') } { param($V, $S, $E) ConvertTo-AzlSonarReplayStart -Value $V -Start $S -End $E } } | Should -Throw $Expected
    }
}

Describe 'Start-AzlSonarServer -Replay and -Record (random port, no Azure, no node)' {
    BeforeAll {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $script:Http = [System.Net.Http.HttpClient]::new($handler)
        $script:Http.Timeout = [TimeSpan]::FromSeconds(20)
        $script:SecretConfig = New-SonarConfigObject
        $script:SecretConfig.credential = [pscustomobject]@{ source = 'keyvault'; vault = 'kv-sonar-test'; usernameSecret = 'sonar-user-secret'; passwordSecret = 'sonar-pass-secret' }
        $script:ConfigPath = Join-Path $TestDrive 'sonar.config.json'
        ConvertTo-SonarConfigJson $script:SecretConfig | Set-Content -LiteralPath $script:ConfigPath

        # Drives the server's main loop: sends the requests once, collects the answers, then stops the server.
        function script:Invoke-SonarServerRun {
            param([scriptblock]$Start, [string[]]$Paths, [int]$Port)
            $script:Run = @{ Tasks = $null; Started = $null; Results = @{}; Paths = $Paths; Base = "http://localhost:$Port" }
            Mock -ModuleName AzlSonar -CommandName Send-AzlSonarSseUpdate -MockWith {
                $d = $script:Run
                if ($null -eq $d.Tasks) {
                    $d.Started = [datetime]::UtcNow
                    $d.Tasks = [ordered]@{}
                    foreach ($p in $d.Paths) { $d.Tasks[$p] = $script:Http.GetAsync($d.Base + $p) }
                }
                if (@($d.Tasks.Values | Where-Object { -not $_.IsCompleted }).Count -eq 0) {
                    foreach ($key in $d.Tasks.Keys) {
                        $t = $d.Tasks[$key]
                        $d.Results[$key] = if ($t.IsFaulted) { @{ Status = -1; Body = $t.Exception.InnerException.Message } } else { @{ Status = [int]$t.Result.StatusCode; Body = $t.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult() } }
                    }
                    throw 'AZLSONAR-TEST-STOP'
                }
                if (([datetime]::UtcNow - $d.Started).TotalSeconds -gt 30) { throw 'AZLSONAR-TEST-TIMEOUT' }
            }
            $stopped = $null
            try { & $Start } catch { $stopped = $_.Exception.Message }
            $stopped | Should -BeLike '*AZLSONAR-TEST-STOP*'
            return $script:Run.Results
        }
    }

    AfterAll {
        if ($script:Http) { $script:Http.Dispose() }
    }

    It 'replays a recording through the page API without Azure, a node or a worker' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'A replay must not need an Azure sign-in.' }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'A replay must not need a credential.' }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'A replay starts no worker.' }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No ARM call is expected.' }
        Mock -ModuleName AzlSonar -CommandName New-PSSession -MockWith { throw 'No remoting is expected.' }
        Mock -ModuleName AzlSonar -CommandName Start-Process -MockWith { throw 'The browser must not open in tests.' }
        $port = Get-SonarFreeTcpPort
        $results = Invoke-SonarServerRun -Port $port -Paths @('/api/config', '/api/replay', '/api/state', '/api/guidance', '/api/logs', '/api/events', '/api/export', '/') -Start {
            Start-AzlSonarServer -Replay $script:Fixture -Port $port -Speed 240 -StartAt '0:35' -NoBrowser -InformationAction SilentlyContinue
        }
        $config = $results['/api/config'].Body | ConvertFrom-Json
        $results['/api/config'].Status | Should -Be 200
        $config.cluster | Should -Be 'clus01'
        $config.replay.file | Should -Be 'recording-sample.jsonl'
        $results['/api/config'].Body | Should -Match '"recordedFrom":"2026-10-11T08:00:00.000Z","recordedTo":"2026-10-11T09:06:00.000Z"'
        $config.replay.speed | Should -Be 240
        $results['/api/config'].Body | Should -Match '"startAt":"2026-10-11T08:35:00.000Z"'
        $config.replay.sessions | Should -Be 2
        $config.PSObject.Properties.Name | Should -Not -Contain 'recording'
        $replay = $results['/api/replay'].Body | ConvertFrom-Json -Depth 64
        @($replay.events).Count | Should -Be @(Get-Content -LiteralPath $script:Fixture | Where-Object { $_ }).Count
        $replay.events[0].k | Should -Be 'session'
        ($results['/api/state'].Body | ConvertFrom-Json).phase | Should -Be 'deployment' -Because '-StartAt 0:35 is 08:35, during Deploy'
        ($results['/api/guidance'].Body | ConvertFrom-Json).phases.deployment.account | Should -Be 'The deployment local admin'
        $results['/api/logs'].Status | Should -Be 200
        $results['/api/events'].Status | Should -Be 404
        $results['/api/export'].Status | Should -Be 404
        $results['/'].Status | Should -Be 200
        Should -Invoke -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -Times 0 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -Times 0 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'passes a phase -StartAt and -Autoplay to the page' {
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'A replay starts no worker.' }
        $port = Get-SonarFreeTcpPort
        $results = Invoke-SonarServerRun -Port $port -Paths @('/api/config') -Start {
            Start-AzlSonarServer -Replay $script:Fixture -Port $port -StartAt deployment -Autoplay -NoBrowser -InformationAction SilentlyContinue
        }
        $config = $results['/api/config'].Body | ConvertFrom-Json
        $config.replay.startAtPhase | Should -Be 'deployment'
        $config.replay.startAt | Should -BeNullOrEmpty
        $config.replay.autoplay | Should -BeTrue
        $config.replay.speed | Should -Be 60
    }

    It 'stops before binding when the recording cannot be read' {
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'must not be reached' }
        { Start-AzlSonarServer -Replay (Join-Path $TestDrive 'nope.jsonl') -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*Recording not found*'
        { Start-AzlSonarServer -Replay $script:Fixture -Port (Get-SonarFreeTcpPort) -StartAt '9:00:00' -NoBrowser } | Should -Throw '*past the end*'
    }

    It 'live with -Record: starts the recorder first, says so in /api/config, and stops it with the others' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { $null }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith {
            @{ Name = $Name; Handle = [pscustomobject]@{ IsCompleted = $false }; Reported = $false; PowerShell = $null; Runspace = $null }
        }
        Mock -ModuleName AzlSonar -CommandName Stop-AzlSonarWorker -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No ARM call is expected.' }
        $recordPath = Join-Path $TestDrive 'live/clus01.jsonl'
        $port = Get-SonarFreeTcpPort
        $results = Invoke-SonarServerRun -Port $port -Paths @('/api/config', '/api/replay') -Start {
            Start-AzlSonarServer -ConfigPath $script:ConfigPath -Record $recordPath -Port $port -NoBrowser -InformationAction SilentlyContinue
        }
        $config = $results['/api/config'].Body | ConvertFrom-Json
        $config.recording.file | Should -Be 'clus01.jsonl'
        $results['/api/config'].Body | Should -Not -Match 'kv-sonar-test|sonar-user-secret|sonar-pass-secret'
        $results['/api/replay'].Status | Should -Be 404
        Should -Invoke -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -Times 1 -Exactly -ParameterFilter {
            $Command -eq 'Invoke-AzlSonarRecorderLoop' -and $Arguments.Path -eq [System.IO.Path]::GetFullPath($recordPath) -and
            $Arguments.SessionJson -match '"format":1' -and $Arguments.SessionJson -notmatch 'sonar-pass-secret'
        }
        Should -Invoke -ModuleName AzlSonar -CommandName Stop-AzlSonarWorker -Times 4 -Exactly
        Test-Path -LiteralPath (Split-Path $recordPath) | Should -BeTrue -Because 'the folder is created (and the file checked) before binding'
    }

    It 'live: recordPath in the config records too, relative to the config file' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { $null }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith {
            @{ Name = $Name; Handle = [pscustomobject]@{ IsCompleted = $false }; Reported = $false; PowerShell = $null; Runspace = $null }
        }
        Mock -ModuleName AzlSonar -CommandName Stop-AzlSonarWorker -MockWith { }
        $cfg = New-SonarConfigObject
        $cfg | Add-Member -NotePropertyName recordPath -NotePropertyValue 'recordings/from-config.jsonl'
        $dir = Join-Path $TestDrive 'cfgdir'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $path = Join-Path $dir 'c.json'
        ConvertTo-SonarConfigJson $cfg | Set-Content -LiteralPath $path
        $port = Get-SonarFreeTcpPort
        $null = Invoke-SonarServerRun -Port $port -Paths @('/api/config') -Start {
            Start-AzlSonarServer -ConfigPath $path -Port $port -NoBrowser -InformationAction SilentlyContinue
        }
        Should -Invoke -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -Times 1 -Exactly -ParameterFilter {
            $Command -eq 'Invoke-AzlSonarRecorderLoop' -and $Arguments.Path -eq [System.IO.Path]::GetFullPath((Join-Path $dir 'recordings/from-config.jsonl'))
        }
    }

    It 'live: a recording path that cannot be written stops Sonar before it binds' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'must not be reached' }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'must not be reached' }
        { Start-AzlSonarServer -ConfigPath $script:ConfigPath -Record $TestDrive -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*is a folder*'
    }
}

Describe 'Config: recordPath' {
    It 'is optional and must be a non-empty string when given' {
        $cfg = New-SonarConfigObject
        (Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $cfg)).recordPath | Should -Be ''
        $cfg | Add-Member -NotePropertyName recordPath -NotePropertyValue ''
        { Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $cfg) } | Should -Throw '*recordPath must be a file path*'
        $cfg.recordPath = 5
        { Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $cfg) } | Should -Throw '*recordPath must be a file path*'
    }

    It 'never reaches the public config' {
        $cfg = New-SonarConfigObject
        $cfg | Add-Member -NotePropertyName recordPath -NotePropertyValue 'C:\private\run.jsonl'
        $config = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $cfg)
        $public = InModuleScope AzlSonar -Parameters @{ C = $config } { param($C) ConvertTo-AzlSonarPublicConfig -Config $C }
        $public.Keys | Should -Not -Contain 'recordPath'
    }
}
