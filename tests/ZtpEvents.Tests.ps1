#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
}

Describe 'ConvertFrom-AzlSonarZtpEvent' {
    It 'turns an event into a log line led by its UTC time, with evidence and next action' {
        $line = '{"timestamp":"2026-10-15T14:00:00.0000000Z","node":"node-01","state":"VoucherWritten","evidence":"valid ownership voucher read back","nextAction":"collect it","level":"Info","stage":"Bootstrap"}'
        $result = InModuleScope AzlSonar -Parameters @{ Line = $line } { param($Line) ConvertFrom-AzlSonarZtpEvent -Line $Line }
        $result.file | Should -Be 'ztp-events'
        $result.text | Should -Be '2026-10-15T14:00:00.000Z [ztp] node-01 VoucherWritten: valid ownership voucher read back -> next: collect it'
    }

    It 'makes error and warning levels visible to the log pane level detection' {
        $err = InModuleScope AzlSonar { ConvertFrom-AzlSonarZtpEvent -Line '{"timestamp":"2026-10-15T14:00:00Z","node":"n1","state":"MediaRejected","evidence":"slot empty","level":"Error"}' }
        $warn = InModuleScope AzlSonar { ConvertFrom-AzlSonarZtpEvent -Line '{"timestamp":"2026-10-15T14:00:00Z","node":"n1","state":"Booting","evidence":"no change for 20 minutes","level":"Warning"}' }
        InModuleScope AzlSonar -Parameters @{ T = $err.text } { param($T) Get-AzlSonarLineLevel $T } | Should -Be 'error'
        InModuleScope AzlSonar -Parameters @{ T = $warn.text } { param($T) Get-AzlSonarLineLevel $T } | Should -Be 'warning'
    }

    It 'skips blank lines, non-JSON and objects without node and state' {
        foreach ($line in '', '   ', 'not json', '[1,2]', '{"node":"n1"}', '{"state":"Mounted"}', '{"timestamp":"x"') {
            InModuleScope AzlSonar -Parameters @{ Line = $line } { param($Line) ConvertFrom-AzlSonarZtpEvent -Line $Line } | Should -BeNullOrEmpty
        }
    }
}

Describe 'Read-AzlSonarZtpEventChunk' {
    It 'returns only complete lines and resumes after the offset' {
        $file = Join-Path $TestDrive 'ev.jsonl'
        [System.IO.File]::WriteAllText($file, "{`"a`":1}`n{`"b`":2}`n{`"c`":3")
        $first = InModuleScope AzlSonar -Parameters @{ File = $file } { param($File) Read-AzlSonarZtpEventChunk -Path $File -Offset 0 }
        @($first.Lines).Count | Should -Be 2
        [System.IO.File]::AppendAllText($file, "}`n")
        $second = InModuleScope AzlSonar -Parameters @{ File = $file; Offset = $first.Offset } { param($File, $Offset) Read-AzlSonarZtpEventChunk -Path $File -Offset $Offset }
        @($second.Lines) | Should -Be @('{"c":3}')
    }

    It 'rereads from the start when the file got smaller and returns nothing for a missing file' {
        $file = Join-Path $TestDrive 'ev2.jsonl'
        [System.IO.File]::WriteAllText($file, "{`"a`":1}`n")
        $r = InModuleScope AzlSonar -Parameters @{ File = $file } { param($File) Read-AzlSonarZtpEventChunk -Path $File -Offset 9999 }
        @($r.Lines).Count | Should -Be 1
        $m = InModuleScope AzlSonar -Parameters @{ File = (Join-Path $TestDrive 'nope.jsonl') } { param($File) Read-AzlSonarZtpEventChunk -Path $File -Offset 0 }
        @($m.Lines).Count | Should -Be 0
    }
}

Describe 'ztpEvents in the config' {
    It 'is empty by default and resolved against the config folder when given' {
        $config = New-SonarConfigObject
        $plain = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $config) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $plain.ztpEventsPath | Should -Be ''
        $config | Add-Member -NotePropertyName ztpEvents -NotePropertyValue ([pscustomobject]@{ path = './ztp-events.jsonl' }) -Force
        $file = Join-Path $TestDrive 'cfg.json'
        Set-Content -LiteralPath $file -Value (ConvertTo-SonarConfigJson $config)
        $read = InModuleScope AzlSonar -Parameters @{ File = $file } { param($File) Read-AzlSonarConfig -Path $File }
        $read.ztpEventsPath | Should -Be (Join-Path $TestDrive 'ztp-events.jsonl')
    }

    It 'rejects an empty ztpEvents.path' {
        $config = New-SonarConfigObject
        $config | Add-Member -NotePropertyName ztpEvents -NotePropertyValue ([pscustomobject]@{ path = ' ' }) -Force
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        ($problems -match 'ztpEvents.path') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-AzlSonarZtpEventLoop' {
    It 'adds the events of the file to the log ring, then stops when the stop flag is raised' {
        $file = Join-Path $TestDrive 'loop.jsonl'
        [System.IO.File]::WriteAllText($file, '{"timestamp":"2026-10-15T14:00:00Z","node":"node-01","state":"Mounted","evidence":"virtual media inserted","nextAction":"boot","level":"Info"}' + "`n")
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar { $Shared['Stop'] = $true }
        $lines = InModuleScope AzlSonar -Parameters @{ File = $file } {
            param($File)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarZtpEventLoop -Shared $shared -Config ([pscustomobject]@{ ztpEventsPath = $File })
            (Get-AzlSonarLogWindow -Shared $shared).lines
        }
        @($lines).Count | Should -Be 1
        @($lines)[0].text | Should -Match '\[ztp\] node-01 Mounted: virtual media inserted'
        @($lines)[0].file | Should -Be 'ztp-events'
    }

    It 'does nothing without a configured event file' {
        $count = InModuleScope AzlSonar { $shared = Initialize-AzlSonarSharedState; Invoke-AzlSonarZtpEventLoop -Shared $shared -Config ([pscustomobject]@{ ztpEventsPath = '' }); @((Get-AzlSonarLogWindow -Shared $shared).lines).Count }
        $count | Should -Be 0
    }
}

Describe 'Prepare stage events (Add-AzlSonarZtpPrepareEvent, ConvertTo-AzlSonarPrepareStage)' {
    It 'keeps only Prepare events per node, and a new PrepareStarted replaces the earlier attempt' {
        $out = InModuleScope AzlSonar {
            $store = [hashtable]::Synchronized(@{})
            foreach ($l in @(
                    '{"timestamp":"2026-11-06T02:29:34Z","node":"node-01","state":"PrepareStarted","evidence":"signed in","level":"Info","stage":"Prepare"}',
                    '{"timestamp":"2026-11-06T02:29:35Z","node":"node-01","state":"Booting","evidence":"x","level":"Info","stage":"Boot"}',
                    '{"timestamp":"2026-11-06T02:34:13Z","node":"node-01","state":"PrepareDriversInstalled","evidence":"b57nd60a.inf 221.0.8.0","level":"Info","stage":"Prepare"}',
                    '{"timestamp":"2026-11-06T02:34:17Z","node":"node-01","state":"PrepareFailed","evidence":"session dropped","level":"Error","stage":"Prepare"}',
                    '{"timestamp":"2026-11-06T02:37:57Z","node":"node-01","state":"PrepareStarted","evidence":"rerun","level":"Info","stage":"Prepare"}',
                    '{"timestamp":"2026-11-06T02:38:48Z","node":"node-01","state":"ReadyForValidate","evidence":"all checks passed","level":"Info","stage":"Prepare"}',
                    '{"timestamp":"2026-11-06T02:38:49Z","node":"*","state":"StageCompleted","evidence":"stage Prepare","level":"Info","stage":"Prepare"}',
                    'not json')) { Add-AzlSonarZtpPrepareEvent -Store $store -Line $l }
            @($store.Keys), @($store['node-01'] | ForEach-Object { $_['state'] })
        }
        $out[0] | Should -Be @('node-01')
        $out[1] | Should -Be @('PrepareStarted', 'ReadyForValidate')
    }

    It 'reports notstarted, running, success and error, with the gates as child steps' {
        $r = InModuleScope AzlSonar {
            $now = [datetime]'2026-11-06T02:40:00Z'
            $ev = { param($s, $t, $e) [ordered]@{ state = $s; timestamp = $t; evidence = $e; level = 'Info' } }
            $none = ConvertTo-AzlSonarPrepareStage -Events @() -Now $now
            $running = ConvertTo-AzlSonarPrepareStage -Events @((& $ev 'PrepareStarted' '2026-11-06T02:29:34Z' 'signed in'), (& $ev 'PrepareRestarting' '2026-11-06T02:34:17Z' 'a driver asked for a restart')) -Now $now
            $done = ConvertTo-AzlSonarPrepareStage -Events @((& $ev 'PrepareStarted' '2026-11-06T02:29:34Z' ''), (& $ev 'ReadyForValidate' '2026-11-06T02:36:50Z' 'all checks passed')) -Now $now
            $failed = ConvertTo-AzlSonarPrepareStage -Events @((& $ev 'PrepareStarted' '2026-11-06T02:29:34Z' ''), (& $ev 'PrepareFailed' '2026-11-06T02:35:00Z' 'no sign-in')) -Now $now
            [pscustomobject]@{ None = $none.status; Running = $running.status; RunningLast = $running.node['children'][-1]['status']; Done = $done.status; Failed = $failed.status; FailedMessage = $failed.message; Name = $done.node['name']; Children = @($done.node['children']).Count }
        }
        $r.None | Should -Be 'notstarted'
        $r.Running | Should -Be 'running'
        $r.RunningLast | Should -Be 'running'
        $r.Done | Should -Be 'success'
        $r.Failed | Should -Be 'error'
        $r.FailedMessage | Should -Be 'no sign-in'
        $r.Name | Should -Be 'Prepare for Validate'
        $r.Children | Should -Be 2
    }
}
