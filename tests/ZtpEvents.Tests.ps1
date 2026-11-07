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

Describe 'ZTP Device and Network stage events (Add-AzlSonarZtpStageEvent, ConvertTo-AzlSonarZtpStageStep)' {
    It 'keeps only Device and Network events per node; an event after a finished attempt starts a new one' {
        $out = InModuleScope AzlSonar {
            $store = [hashtable]::Synchronized(@{})
            foreach ($l in @(
                    '{"timestamp":"2026-11-06T01:00:00Z","node":"node-01","state":"DeviceConfigurationSubmitted","evidence":"NIC1 static","level":"Info","stage":"Device"}',
                    '{"timestamp":"2026-11-06T01:00:05Z","node":"node-01","state":"Booting","evidence":"x","level":"Info","stage":"Boot"}',
                    '{"timestamp":"2026-11-06T01:01:00Z","node":"node-01","state":"DeviceConfigurationFailed","evidence":"no answer","level":"Error","stage":"Device"}',
                    '{"timestamp":"2026-11-06T01:10:00Z","node":"node-01","state":"DeviceAddressAlreadySet","evidence":"rerun","level":"Info","stage":"Device"}',
                    '{"timestamp":"2026-11-06T02:00:00Z","node":"node-01","state":"PrepareStarted","evidence":"older ZTP","level":"Info","stage":"Prepare"}',
                    '{"timestamp":"2026-11-06T03:00:00Z","node":"node-01","state":"NetworkJobSubmitted","evidence":"NIC1 apply","level":"Info","stage":"Network"}',
                    '{"timestamp":"2026-11-06T03:00:30Z","node":"node-01","state":"NetworkJobStatus","evidence":"NIC1 ApplyConfiguration: Job is not yet triggered as other jobs are still running","level":"Info","stage":"Network"}',
                    '{"timestamp":"2026-11-06T03:01:00Z","node":"node-02","state":"DeviceConfigurationSkipped","evidence":"no maintenance_address","level":"Warning","stage":"Device"}',
                    '{"timestamp":"2026-11-06T03:02:00Z","node":"*","state":"StageCompleted","evidence":"stage Device","level":"Info","stage":"Device"}',
                    'not json')) { Add-AzlSonarZtpStageEvent -Store $store -Line $l }
            [pscustomobject]@{
                Nodes   = @($store.Keys | Sort-Object)
                Device1 = @($store['node-01']['Device'] | ForEach-Object { $_['state'] })
                Network = @($store['node-01']['Network'] | ForEach-Object { $_['state'] })
                Stages1 = @($store['node-01'].Keys | Sort-Object)
                Device2 = @($store['node-02']['Device'] | ForEach-Object { $_['state'] })
            }
        }
        $out.Nodes | Should -Be @('node-01', 'node-02')
        $out.Device1 | Should -Be @('DeviceAddressAlreadySet')
        $out.Network | Should -Be @('NetworkJobSubmitted', 'NetworkJobStatus')
        $out.Stages1 | Should -Be @('Device', 'Network')
        $out.Device2 | Should -Be @('DeviceConfigurationSkipped')
    }

    It 'clears a stage on every node when the orchestrator starts it again, and keeps the other stage' {
        $out = InModuleScope AzlSonar {
            $store = [hashtable]::Synchronized(@{})
            foreach ($l in @(
                    '{"timestamp":"2026-11-06T01:00:00Z","node":"node-01","state":"DeviceAddressSet","evidence":"NIC1","stage":"Device"}',
                    '{"timestamp":"2026-11-06T03:00:00Z","node":"node-01","state":"ManagementAddressFailed","evidence":"timed out","level":"Error","stage":"Network"}',
                    '{"timestamp":"2026-11-06T03:00:00Z","node":"node-02","state":"NetworkJobSubmitted","evidence":"NIC1","stage":"Network"}',
                    '{"timestamp":"2026-11-06T04:00:00Z","node":"*","state":"StageStarted","evidence":"stage Network","stage":"Network"}')) { Add-AzlSonarZtpStageEvent -Store $store -Line $l }
            [pscustomobject]@{ One = @($store['node-01'].Keys); Two = @($store['node-02'].Keys) }
        }
        $out.One | Should -Be @('Device')
        @($out.Two).Count | Should -Be 0
    }

    It 'Device: notstarted, running, success on each success state, error on DeviceConfigurationFailed' {
        $r = InModuleScope AzlSonar {
            $now = [datetime]'2026-11-06T02:00:00Z'
            $ev = { param($s, $t, $e) [ordered]@{ state = $s; timestamp = $t; evidence = $e; level = 'Info' } }
            $none = ConvertTo-AzlSonarZtpStageStep -Stage Device -Events @() -Now $now
            $running = ConvertTo-AzlSonarZtpStageStep -Stage Device -Events @((& $ev 'DeviceConfigurationSubmitted' '2026-11-06T01:00:00Z' 'NIC1 static'), (& $ev 'DeviceConfigurationStatus' '2026-11-06T01:00:30Z' 'status: InProgress')) -Now $now
            $ok = foreach ($s in 'DeviceAddressSet', 'DeviceAddressAlreadySet', 'DeviceAddressReported', 'DeviceConfigurationSkipped') { (ConvertTo-AzlSonarZtpStageStep -Stage Device -Events @((& $ev $s '2026-11-06T01:00:00Z' 'x')) -Now $now).status }
            $failed = ConvertTo-AzlSonarZtpStageStep -Stage Device -Events @((& $ev 'DeviceConfigurationSubmitted' '2026-11-06T01:00:00Z' ''), (& $ev 'DeviceConfigurationFailed' '2026-11-06T01:05:00Z' 'no answer on 20001')) -Now $now
            [pscustomobject]@{
                None = $none.status; NoneMessage = $none.message; Running = $running.status; RunningLast = $running.node['children'][-1]['status']
                Ok = @($ok); Failed = $failed.status; FailedMessage = $failed.message; FailedErrors = @($failed.node['errors'])
                Name = $running.node['name']; Id = $running.node['id']; Children = @($running.node['children']).Count
            }
        }
        $r.None | Should -Be 'notstarted'
        $r.NoneMessage | Should -Be 'Waiting for the Device stage'
        $r.Running | Should -Be 'running'
        $r.RunningLast | Should -Be 'running'
        $r.Ok | Should -Be @('success', 'success', 'success', 'success')
        $r.Failed | Should -Be 'error'
        $r.FailedMessage | Should -Be 'no answer on 20001'
        $r.FailedErrors | Should -Be @('no answer on 20001')
        $r.Name | Should -Be 'Management address (maintenance environment)'
        $r.Id | Should -Be 'ztp.device'
        $r.Children | Should -Be 2
    }

    It 'Network: a queued job is running, not an error; success on each success state; error on ManagementAddressFailed' {
        $r = InModuleScope AzlSonar {
            $now = [datetime]'2026-11-06T04:00:00Z'
            $ev = { param($s, $t, $e) [ordered]@{ state = $s; timestamp = $t; evidence = $e; level = 'Info' } }
            $queued = ConvertTo-AzlSonarZtpStageStep -Stage Network -Events @(
                (& $ev 'NetworkJobSubmitted' '2026-11-06T03:00:00Z' 'NIC1 (00-11-22-33-44-55) ApplyConfiguration apply: Static'),
                (& $ev 'NetworkJobStatus' '2026-11-06T03:00:30Z' 'NIC1 ApplyConfiguration: Job is not yet triggered as other jobs are still running')) -Now $now
            $ok = foreach ($s in 'ManagementAddressSet', 'ManagementAddressAlreadySet', 'ManagementAddressReported') { (ConvertTo-AzlSonarZtpStageStep -Stage Network -Events @((& $ev $s '2026-11-06T03:00:00Z' 'x')) -Now $now).status }
            $released = ConvertTo-AzlSonarZtpStageStep -Stage Network -Events @((& $ev 'ManagementAddressReleased' '2026-11-06T03:00:00Z' 'released from SLOT 3')) -Now $now
            $failed = ConvertTo-AzlSonarZtpStageStep -Stage Network -Events @((& $ev 'NetworkJobSubmitted' '2026-11-06T03:00:00Z' ''), (& $ev 'ManagementAddressFailed' '2026-11-06T03:30:00Z' 'ApplyConfiguration failed')) -Now $now
            [pscustomobject]@{
                Queued = $queued.status; QueuedLast = $queued.node['children'][-1]['status']; QueuedErrors = @($queued.node['errors']).Count
                QueuedChildErrors = @($queued.node['children'] | ForEach-Object { @($_['errors']) }).Count
                QueuedMessage = $queued.message; Ok = @($ok); Released = $released.status; Failed = $failed.status; FailedMessage = $failed.message
                Name = $queued.node['name']; Id = $queued.node['id']
            }
        }
        $r.Queued | Should -Be 'running'
        $r.QueuedLast | Should -Be 'running'
        $r.QueuedErrors | Should -Be 0
        $r.QueuedChildErrors | Should -Be 0
        $r.QueuedMessage | Should -Match 'Job is not yet triggered'
        $r.Ok | Should -Be @('success', 'success', 'success')
        $r.Released | Should -Be 'running'
        $r.Failed | Should -Be 'error'
        $r.FailedMessage | Should -Be 'ApplyConfiguration failed'
        $r.Name | Should -Be 'Management address on the management NIC'
        $r.Id | Should -Be 'ztp.network'
    }

    It 'Restore: running after BiosRestoreStarted, success on BiosRestored, error on BiosRestoreFailed, not applicable without events once the stage is over' {
        $r = InModuleScope AzlSonar {
            $now = [datetime]'2026-11-06T05:00:00Z'
            $ev = { param($s, $t, $e) [ordered]@{ state = $s; timestamp = $t; evidence = $e; level = 'Info' } }
            $started = ConvertTo-AzlSonarZtpStageStep -Stage Restore -Events @((& $ev 'BiosRestoreStarted' '2026-11-06T04:00:00Z' 'FC HBA on')) -Now $now
            $done = ConvertTo-AzlSonarZtpStageStep -Stage Restore -Events @((& $ev 'BiosRestoreStarted' '2026-11-06T04:00:00Z' ''), (& $ev 'BiosRestored' '2026-11-06T04:20:00Z' 'Arc Connected')) -Now $now
            $failed = ConvertTo-AzlSonarZtpStageStep -Stage Restore -Events @((& $ev 'BiosRestoreStarted' '2026-11-06T04:00:00Z' ''), (& $ev 'BiosRestoreFailed' '2026-11-06T04:30:00Z' 'Arc did not reconnect')) -Now $now
            $waiting = ConvertTo-AzlSonarZtpStageStep -Stage Restore -Events @() -Now $now
            $na = ConvertTo-AzlSonarZtpStageStep -Stage Restore -Events @() -Now $now -NotApplicable
            $naIgnored = ConvertTo-AzlSonarZtpStageStep -Stage Restore -Events @((& $ev 'BiosRestoreStarted' '2026-11-06T04:00:00Z' '')) -Now $now -NotApplicable
            [pscustomobject]@{ Started = $started.status; Done = $done.status; Failed = $failed.status; FailedMessage = $failed.message; Waiting = $waiting.status; Na = $na.status; NaMessage = $na.message; NaIgnored = $naIgnored.status; Name = $done.node['name'] }
        }
        $r.Started | Should -Be 'running'
        $r.Done | Should -Be 'success'
        $r.Failed | Should -Be 'error'
        $r.FailedMessage | Should -Be 'Arc did not reconnect'
        $r.Waiting | Should -Be 'notstarted'
        $r.Na | Should -Be 'skipped'
        $r.NaMessage | Should -Match 'Not applicable'
        $r.NaIgnored | Should -Be 'running' -Because 'events of the node win over the run-wide fact'
        $r.Name | Should -Be 'BIOS restored'
    }

    It 'Restore is over for the run on its StageCompleted or any Handoff event, and open again on its StageStarted' {
        $out = InModuleScope AzlSonar {
            $store = [hashtable]::Synchronized(@{})
            $over = { $store.Contains('*') -and $store['*'].Contains('Restore') -and [bool]$store['*']['Restore'] }
            $seen = [System.Collections.Generic.List[bool]]::new()
            $seen.Add((& $over))
            Add-AzlSonarZtpStageEvent -Store $store -Line '{"timestamp":"2026-11-06T04:00:00Z","node":"node-01","state":"BiosRestoreStarted","evidence":"","stage":"Restore"}'
            Add-AzlSonarZtpStageEvent -Store $store -Line '{"timestamp":"2026-11-06T04:20:00Z","node":"*","state":"StageCompleted","evidence":"stage Restore","stage":"Restore"}'
            $seen.Add((& $over))
            Add-AzlSonarZtpStageEvent -Store $store -Line '{"timestamp":"2026-11-06T05:00:00Z","node":"*","state":"StageStarted","evidence":"stage Restore","stage":"Restore"}'
            $seen.Add((& $over))
            $restoreKept = $store['node-01'].ContainsKey('Restore')
            Add-AzlSonarZtpStageEvent -Store $store -Line '{"timestamp":"2026-11-06T05:10:00Z","node":"*","state":"StageStarted","evidence":"stage Handoff","stage":"Handoff"}'
            $seen.Add((& $over))
            [pscustomobject]@{ Seen = @($seen); RestoreKept = $restoreKept; Nodes = @($store.Keys | Where-Object { $_ -ne '*' }) }
        }
        $out.Seen | Should -Be @($false, $true, $false, $true)
        $out.RestoreKept | Should -BeFalse
        $out.Nodes | Should -Be @('node-01')
    }

    It 'the event loop fills the shared stage store' {
        $file = Join-Path $TestDrive 'stages.jsonl'
        [System.IO.File]::WriteAllText($file, '{"timestamp":"2026-11-06T03:00:00Z","node":"node-01","state":"ManagementAddressSet","evidence":"NIC1 Static","level":"Info","stage":"Network"}' + "`n")
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar { $Shared['Stop'] = $true }
        $states = InModuleScope AzlSonar -Parameters @{ File = $file } {
            param($File)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarZtpEventLoop -Shared $shared -Config ([pscustomobject]@{ ztpEventsPath = $File })
            @($shared['ZtpStages']['node-01']['Network'] | ForEach-Object { $_['state'] })
        }
        $states | Should -Be @('ManagementAddressSet')
    }
}
