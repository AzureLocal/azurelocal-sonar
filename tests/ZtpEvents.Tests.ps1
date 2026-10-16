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
