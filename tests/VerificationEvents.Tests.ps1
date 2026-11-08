#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The Verification view: the reader of the pre-cluster verification gate's event file, its store (latest run only), the
# state builder, the config key and the monitor. The fixtures in tests/fixtures/verification are written to the contract
# (schema 1: RunStarted, Check, RunCompleted); names are examples. No Azure, no node, no real gate.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Fx = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/verification'
    function global:Get-VfFixture([string]$Name) { Join-Path -Path $script:Fx -ChildPath "precluster-verification-$Name.jsonl" }
    # The state built from the lines of a fixture; -Now is fixed (the fixtures expire at 2026-11-08T16:00:00Z).
    function global:Get-VfState {
        param([string]$Name, [string]$NowUtc = '2026-11-08T13:00:00Z')
        $lines = @(Get-Content -LiteralPath (Get-VfFixture $Name))
        InModuleScope AzlSonar -Parameters @{ L = $lines; N = [datetime]::Parse($NowUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } {
            param($L, $N)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarVerificationEvent -Store $store -Line $x }
            Get-AzlSonarVerificationState -Store $store -Config ([pscustomobject]@{ verificationEventsPath = 'x' }) -Now $N
        }
    }
    function global:Find-VfCheck($State, [string]$Id, [string]$Node = '') {
        @($State.categories | ForEach-Object { $_.checks }) | Where-Object { $_.id -eq $Id -and $_.node -eq $Node }
    }
}

AfterAll {
    foreach ($f in 'Get-VfFixture', 'Get-VfState', 'Find-VfCheck') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'ConvertFrom-AzlSonarVerificationLine' {
    It 'reads the contract fields of a Check and keeps the text as written' {
        $line = '{"schema":1,"runId":"r1","seq":7,"ts":"2026-11-08T12:00:02.5Z","type":"Check","checkId":"nodes.reachable","category":"Nodes","title":"Node is reachable","status":"failed","node":"iic-azl-n02","message":"No answer","remedy":"Check the cable","source":"https://learn.microsoft.com/x","blocking":true}'
        $e = InModuleScope AzlSonar -Parameters @{ L = $line } { param($L) ConvertFrom-AzlSonarVerificationLine -Line $L }
        $e.runId | Should -Be 'r1'
        $e.seq | Should -Be 7
        $e.type | Should -Be 'Check'
        $e.category | Should -Be 'nodes'
        $e.status | Should -Be 'Failed'
        $e.node | Should -Be 'iic-azl-n02'
        $e.blocking | Should -BeTrue
        $e.timestamp | Should -Be '2026-11-08T12:00:02.500Z'
    }
    It 'reads RunCompleted with the verdict, the counts, the hash and the expiry' {
        $line = '{"schema":1,"runId":"r1","seq":9,"ts":"2026-11-08T12:01:00Z","type":"RunCompleted","verdict":"pass","counts":{"passed":3,"Skipped":1},"fileHash":"sha256:ab","expiresUtc":"2026-11-08T16:00:00Z"}'
        $e = InModuleScope AzlSonar -Parameters @{ L = $line } { param($L) ConvertFrom-AzlSonarVerificationLine -Line $L }
        $e.verdict | Should -Be 'Pass'
        $e.counts['Passed'] | Should -Be 3
        $e.counts['Skipped'] | Should -Be 1
        $e.fileHash | Should -Be 'sha256:ab'
        $e.expires.ToUniversalTime().ToString('o') | Should -Be '2026-11-08T16:00:00.0000000Z'
    }
    It 'skips what is not an event: garbage, a half line, no runId, an unknown type, a Check without a checkId' {
        foreach ($bad in '', 'not json', '{"runId":"r1","type":"Check"', '{"type":"RunStarted"}', '{"runId":"r1"}', '{"runId":"r1","type":"Mystery"}', '{"runId":"r1","type":"Check"}', '[1,2]') {
            InModuleScope AzlSonar -Parameters @{ L = $bad } { param($L) ConvertFrom-AzlSonarVerificationLine -Line $L } | Should -BeNullOrEmpty
        }
    }
    It 'reads a timestamp as UTC whatever the culture is, and a missing blocking flag as blocking' {
        $old = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]'de-DE'
            $e = InModuleScope AzlSonar { ConvertFrom-AzlSonarVerificationLine -Line '{"runId":"r1","type":"Check","checkId":"a","ts":"2026-11-08T12:00:01.5000000Z","status":"Failed"}' }
            $e.timestamp | Should -Be '2026-11-08T12:00:01.500Z'
            $e.blocking | Should -BeTrue
        }
        finally { [cultureinfo]::CurrentCulture = $old }
    }
}

Describe 'ConvertFrom-AzlSonarVerificationEvent (the log line)' {
    It 'leads with the event time, names the machine, the status and the check, and ends with a level word' {
        $line = '{"schema":1,"runId":"r1","seq":3,"ts":"2026-11-08T12:00:30Z","type":"Check","checkId":"nodes.reachable","category":"nodes","title":"Node is reachable","status":"Failed","node":"iic-azl-n02","message":"No answer","remedy":"Check the cable","blocking":true}'
        $r = InModuleScope AzlSonar -Parameters @{ L = $line } { param($L) ConvertFrom-AzlSonarVerificationEvent -Line $L }
        $r.file | Should -Be 'verification-events'
        $r.text | Should -Be '2026-11-08T12:00:30.000Z [verify] iic-azl-n02 Check Failed (nodes.reachable): No answer -> next: Check the cable'
    }
    It 'tags Skipped as a warning, uses * for a check of the whole environment, and shows the verdict' {
        $s = InModuleScope AzlSonar { ConvertFrom-AzlSonarVerificationEvent -Line '{"runId":"r1","type":"Check","checkId":"a","ts":"2026-11-08T12:00:30Z","status":"Skipped","message":"Not reached"}' }
        $s.text | Should -Be '2026-11-08T12:00:30.000Z [verify] * Check Skipped (a): Not reached (warning)'
        $c = InModuleScope AzlSonar { ConvertFrom-AzlSonarVerificationEvent -Line '{"runId":"r1","type":"RunCompleted","ts":"2026-11-08T12:01:00Z","verdict":"Fail"}' }
        $c.text | Should -Be '2026-11-08T12:01:00.000Z [verify] * RunCompleted Fail (error)'
    }
    It 'skips what is not an event' {
        InModuleScope AzlSonar { ConvertFrom-AzlSonarVerificationEvent -Line 'not json' } | Should -BeNullOrEmpty
    }
}

Describe 'happy path: a run that passed' {
    BeforeAll { $script:Pass = Get-VfState 'pass' }
    It 'is a Pass with every check counted by status' {
        $script:Pass.configured | Should -BeTrue
        $script:Pass.hasData | Should -BeTrue
        $script:Pass.status | Should -Be 'pass'
        $script:Pass.verdict | Should -Be 'Pass'
        $script:Pass.total | Should -Be 12
        $script:Pass.counts['Passed'] | Should -Be 9
        $script:Pass.counts['Fixed'] | Should -Be 1
        $script:Pass.counts['Warning'] | Should -Be 1
        $script:Pass.counts['NotApplicable'] | Should -Be 1
        $script:Pass.counts['Failed'] | Should -Be 0
        $script:Pass.counts['Skipped'] | Should -Be 0
        $script:Pass.blockers | Should -Be 0
        $script:Pass.countsMismatch | Should -BeFalse
        @($script:Pass.warnings).Count | Should -Be 0
    }
    It 'groups the checks by category in the contract order, each with its node, message, remedy and source' {
        @($script:Pass.categories).id | Should -Be @('azure', 'identity', 'nodes', 'network', 'storage', 'readiness')
        @($script:Pass.categories).name | Should -Be @('Azure', 'Identity', 'Nodes', 'Network', 'Storage', 'Readiness')
        $jumbo = Find-VfCheck $script:Pass 'network.jumbo' 'iic-azl-n02'
        $jumbo.status | Should -Be 'Warning'
        $jumbo.remedy | Should -Be 'Set the storage ports to 9014.'
        $jumbo.blocks | Should -BeFalse
        $ctx = Find-VfCheck $script:Pass 'azure.context'
        $ctx.sourceUrl | Should -Be 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites'
        $ctx.source | Should -Be 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites'
    }
    It 'carries the run, the expiry and the time left' {
        $script:Pass.run.runId | Should -Be 'vf-20261108-0001'
        $script:Pass.run.expiresUtc | Should -Be '2026-11-08T16:00:00.0000000Z'
        $script:Pass.run.expiresInSeconds | Should -Be 10800
        $script:Pass.run.fileHash | Should -Match '^sha256:'
        $script:Pass.run.stale | Should -Be 0
    }
    It 'masks the text it serves (a secret in a message never reaches the page)' {
        $line = '{"runId":"r1","seq":2,"ts":"2026-11-08T12:00:02Z","type":"Check","checkId":"a","category":"azure","status":"Failed","message":"password=Sup3rS3cret! was rejected","blocking":true}'
        $s = InModuleScope AzlSonar -Parameters @{ L = $line } {
            param($L)
            $store = @{}
            Add-AzlSonarVerificationEvent -Store $store -Line $L
            Get-AzlSonarVerificationState -Store $store -Config ([pscustomobject]@{ verificationEventsPath = 'x' })
        }
        $s.categories[0].checks[0].message | Should -Not -Match 'Sup3rS3cret'
    }
}

Describe 'failed: blocking checks, failed first' {
    BeforeAll { $script:Failed = Get-VfState 'failed' }
    It 'is a Fail that counts what blocks' {
        $script:Failed.status | Should -Be 'fail'
        $script:Failed.verdict | Should -Be 'Fail'
        $script:Failed.counts['Failed'] | Should -Be 3
        $script:Failed.blockers | Should -Be 2
        @($script:Failed.attention).id | Should -Be @('azure.providers', 'nodes.reachable')
    }
    It 'a failed check the gate did not mark blocking is shown as failed but does not block' {
        $drives = Find-VfCheck $script:Failed 'storage.drives' 'iic-azl-n01'
        $drives.status | Should -Be 'Failed'
        $drives.blocking | Should -BeFalse
        $drives.blocks | Should -BeFalse
    }
    It 'puts the failed check before the passed one inside its category, and the categories that block first' {
        $nodes = @($script:Failed.categories | Where-Object id -eq 'nodes')[0]
        @($nodes.checks).status | Should -Be @('Failed', 'Passed')
        @($nodes.checks)[0].node | Should -Be 'iic-azl-n02'
        @($script:Failed.categories).id | Should -Be @('azure', 'nodes', 'identity', 'network', 'storage')
        ($script:Failed.categories | Where-Object id -eq 'azure').status | Should -Be 'Failed'
    }
    It 'keeps the remedy next to the failure' {
        (Find-VfCheck $script:Failed 'azure.providers').remedy | Should -Match 'Register-AzResourceProvider'
    }
}

Describe 'skipped blocks the gate' {
    It 'a skipped check blocks even when the gate did not mark it blocking, and is counted apart' {
        $s = Get-VfState 'skipped'
        $s.status | Should -Be 'fail'
        $s.counts['Skipped'] | Should -Be 2
        $s.counts['NotApplicable'] | Should -Be 0
        $s.skippedBlocking | Should -Be 2
        $s.blockers | Should -Be 2
        (Find-VfCheck $s 'network.jumbo' 'iic-azl-n01').blocking | Should -BeFalse
        (Find-VfCheck $s 'network.jumbo' 'iic-azl-n01').blocks | Should -BeTrue
        @($s.attention).status | Should -Be @('Skipped', 'Skipped')
    }
    It 'never shows green when the gate wrote Pass while a check was skipped' {
        $s = Get-VfState 'skipped-pass'
        $s.verdict | Should -Be 'Pass'
        $s.status | Should -Be 'fail'
        ($s.warnings -join ' ') | Should -Match 'verdict Pass, but 2 check\(s\) still block it'
    }
}

Describe 'running: no RunCompleted yet' {
    It 'is Running with the checks so far and no verdict' {
        $s = Get-VfState 'running'
        $s.status | Should -Be 'running'
        $s.verdict | Should -Be ''
        $s.total | Should -Be 3
        $s.counts['Running'] | Should -Be 1
        $s.run.completed | Should -BeNullOrEmpty
        $s.blockers | Should -Be 0
    }
    It 'a finished run that left a check Running is a fail with a warning (the check never finished)' {
        $lines = @(Get-Content -LiteralPath (Get-VfFixture 'running')) + '{"schema":1,"runId":"vf-20261108-0004","seq":20,"ts":"2026-11-08T12:05:00Z","type":"RunCompleted","verdict":"Pass","expiresUtc":"2026-11-08T16:00:00Z"}'
        $s = InModuleScope AzlSonar -Parameters @{ L = $lines } {
            param($L)
            $store = @{}
            foreach ($x in $L) { Add-AzlSonarVerificationEvent -Store $store -Line $x }
            Get-AzlSonarVerificationState -Store $store -Config ([pscustomobject]@{ verificationEventsPath = 'x' }) -Now ([datetime]::SpecifyKind([datetime]'2026-11-08T13:00:00', 'Utc'))
        }
        $s.status | Should -Be 'fail'
        ($s.warnings -join ' ') | Should -Match 'never finished'
    }
}

Describe 'expired: a Pass whose time is up' {
    It 'is a Pass before expiresUtc and Expired after it' {
        (Get-VfState 'pass' '2026-11-08T15:59:00Z').status | Should -Be 'pass'
        $late = Get-VfState 'pass' '2026-11-08T16:00:01Z'
        $late.status | Should -Be 'expired'
        $late.verdict | Should -Be 'Pass'
        $late.run.expiresInSeconds | Should -BeLessOrEqual 0
    }
    It 'a Fail stays a Fail after the time has passed' {
        (Get-VfState 'failed' '2026-11-09T00:00:00Z').status | Should -Be 'fail'
    }
}

Describe 'stale: only the latest run is the current one' {
    It 'ignores the late lines of an older run that arrive after the newer run started' {
        $s = Get-VfState 'stale'
        $s.run.runId | Should -Be 'vf-20261108-0006'
        $s.status | Should -Be 'pass'
        $s.total | Should -Be 12
        Find-VfCheck $s 'azure.late' | Should -BeNullOrEmpty
        $s.counts['Failed'] | Should -Be 0
        $s.run.stale | Should -Be 2
        ($s.warnings -join ' ') | Should -Match 'Ignored 2 line\(s\) of an older run'
    }
    It 'ignores a whole older run written after a newer one' {
        $s = Get-VfState 'older-after-newer'
        $s.run.runId | Should -Be 'vf-20261108-0009'
        $s.status | Should -Be 'pass'
        $s.total | Should -Be 12
        $s.run.stale | Should -BeGreaterThan 0
    }
    It 'a new run replaces the checks of the old one, even when its RunStarted is the only line yet' {
        $s = InModuleScope AzlSonar {
            $store = @{}
            foreach ($l in @(Get-Content -LiteralPath (Join-Path $args[0] 'precluster-verification-failed.jsonl'))) { Add-AzlSonarVerificationEvent -Store $store -Line $l }
            Add-AzlSonarVerificationEvent -Store $store -Line '{"schema":1,"runId":"vf-new","seq":1,"ts":"2026-11-08T13:30:00Z","type":"RunStarted"}'
            Get-AzlSonarVerificationState -Store $store -Config ([pscustomobject]@{ verificationEventsPath = 'x' }) -Now ([datetime]::SpecifyKind([datetime]'2026-11-08T13:31:00', 'Utc'))
        } -ArgumentList $script:Fx
        $s.run.runId | Should -Be 'vf-new'
        $s.status | Should -Be 'running'
        $s.total | Should -Be 0
        @($s.categories).Count | Should -Be 0
    }
    It 'a repeated or older line of a check (lower seq) does not replace the newer one; garbage and a half line are skipped' {
        $s = Get-VfState 'partial'
        $s.status | Should -Be 'running'
        $p = Find-VfCheck $s 'azure.providers'
        $p.status | Should -Be 'Passed'
        $p.message | Should -Be 'Now registered.'
        $s.total | Should -Be 7
    }
}

Describe 'a missing or empty file never breaks anything' {
    It 'the state with no store, an empty store or no config key is waiting' {
        foreach ($case in @{ Store = $null; Key = 'x' }, @{ Store = @{}; Key = 'x' }, @{ Store = @{}; Key = '' }) {
            $s = InModuleScope AzlSonar -Parameters @{ S = $case.Store; K = $case.Key } { param($S, $K) Get-AzlSonarVerificationState -Store $S -Config ([pscustomobject]@{ verificationEventsPath = $K }) }
            $s.hasData | Should -BeFalse
            $s.status | Should -Be 'notstarted'
            $s.configured | Should -Be ([bool]$case.Key)
            $s.total | Should -Be 0
            @($s.categories).Count | Should -Be 0
            @($s.attention).Count | Should -Be 0
        }
    }
    It 'reading a file that is not there is an empty answer, not an error' {
        $r = InModuleScope AzlSonar -Parameters @{ P = (Join-Path $TestDrive 'nope/precluster-verification-events.jsonl') } { param($P) Read-AzlSonarVerificationEventFile -Path $P }
        $r.Found | Should -BeFalse
        @($r.Lines).Count | Should -Be 0
    }
    It 'a path can name the file or the folder (a folder, or a path that is not there yet and has no extension, gets the file name)' {
        $dir = Join-Path $TestDrive 'live'
        $null = New-Item -ItemType Directory -Path $dir
        $file = Join-Path $dir 'x.jsonl'
        Set-Content -LiteralPath $file -Value ''
        $names = InModuleScope AzlSonar -Parameters @{ D = $dir; F = $file; M = (Join-Path $TestDrive 'later/live') } {
            param($D, $F, $M)
            @((Resolve-AzlSonarVerificationEventFile -Path $D), (Resolve-AzlSonarVerificationEventFile -Path $F), (Resolve-AzlSonarVerificationEventFile -Path $M), (Resolve-AzlSonarVerificationEventFile -Path ''))
        }
        $names[0] | Should -Be (Join-Path $dir 'precluster-verification-events.jsonl')
        $names[1] | Should -Be $file
        $names[2] | Should -Be (Join-Path $TestDrive 'later/live/precluster-verification-events.jsonl')
        $names[3] | Should -Be ''
    }
    It 'the loop follows a file that appears late, grows, is replaced by a new run, and goes away' {
        $dir = Join-Path $TestDrive 'loop-live'
        $file = Join-Path $dir 'precluster-verification-events.jsonl'
        $running = Get-VfFixture 'running'; $pass = Get-VfFixture 'pass'; $failed = Get-VfFixture 'failed'
        $r = InModuleScope AzlSonar -Parameters @{ Dir = $dir; File = $file; Running = $running; Pass = $pass; Failed = $failed } {
            param($Dir, $File, $Running, $Pass, $Failed)
            $shared = [hashtable]::Synchronized(@{ Stop = $false; VerificationEvents = [hashtable]::Synchronized(@{}); VerificationInfo = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null }) })
            $script:vfDir = $Dir; $script:vfFile = $File; $script:vfRunning = $Running; $script:vfPass = $Pass; $script:vfFailed = $Failed
            $script:vfLogged = @()
            $script:vfSeen = @()
            $script:vfStep = 0
            Mock Add-AzlSonarLogLine { $script:vfLogged += @($Line) }
            Mock Wait-AzlSonarInterval {
                $state = Get-AzlSonarVerificationState -Store $Shared['VerificationEvents'] -Config ([pscustomobject]@{ verificationEventsPath = 'x' }) -Now ([datetime]::SpecifyKind([datetime]'2026-11-08T13:00:00', 'Utc'))
                $script:vfSeen += "$($state.hasData)|$($state.status)|$($state.run.runId)|$($state.total)"
                switch ($script:vfStep) {
                    0 { $null = New-Item -ItemType Directory -Path $script:vfDir -Force; Get-Content -LiteralPath $script:vfRunning | Set-Content -LiteralPath $script:vfFile }
                    1 { Get-Content -LiteralPath $script:vfPass | Set-Content -LiteralPath $script:vfFile }
                    2 { Get-Content -LiteralPath $script:vfFailed | Set-Content -LiteralPath $script:vfFile }
                    3 { Remove-Item -LiteralPath $script:vfFile }
                    default { $Shared.Stop = $true }
                }
                $script:vfStep++
            }
            Invoke-AzlSonarVerificationEventLoop -Shared $shared -Config ([pscustomobject]@{ verificationEventsPath = $Dir })
            @{ Seen = $script:vfSeen; Logged = @($script:vfLogged).Count; Info = $shared.VerificationInfo.Count }
        }
        $r.Seen[0] | Should -Be 'False|notstarted||0'
        $r.Seen[1] | Should -Be 'True|running|vf-20261108-0004|3'
        $r.Seen[2] | Should -Be 'True|pass|vf-20261108-0001|12'
        $r.Seen[3] | Should -Be 'True|fail|vf-20261108-0002|7'
        $r.Seen[4] | Should -Be 'False|notstarted||0'
        # the log pane got each file's lines once: 4 (running) + 14 (pass) + 9 (failed)
        $r.Logged | Should -Be 27
    }
    It 'the loop adds only the lines the pane has not had when the file grows' {
        $file = Join-Path $TestDrive 'grow.jsonl'
        $all = @(Get-Content -LiteralPath (Get-VfFixture 'pass'))
        $r = InModuleScope AzlSonar -Parameters @{ File = $file; All = $all } {
            param($File, $All)
            $shared = [hashtable]::Synchronized(@{ Stop = $false; VerificationEvents = [hashtable]::Synchronized(@{}); VerificationInfo = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null }) })
            $script:grown = @()
            $script:gStep = 0
            $script:gFile = $File; $script:gAll = $All
            Mock Add-AzlSonarLogLine { $script:grown += @($Line) }
            $All[0..4] | Set-Content -LiteralPath $File
            Mock Wait-AzlSonarInterval {
                if ($script:gStep -eq 0) { Add-Content -LiteralPath $script:gFile -Value $script:gAll[5..($script:gAll.Count - 1)] } else { $Shared.Stop = $true }
                $script:gStep++
            }
            Invoke-AzlSonarVerificationEventLoop -Shared $shared -Config ([pscustomobject]@{ verificationEventsPath = $File })
            @{ Logged = @($script:grown).Count; Info = $shared.VerificationInfo.Count; Run = $shared.VerificationEvents['*'].Events }
        }
        $r.Logged | Should -Be $all.Count
        $r.Info | Should -Be $all.Count
        $r.Run | Should -Be $all.Count
    }
}

Describe 'counts the gate reported' {
    It 'a difference from the checks Sonar read is a warning, not a different verdict' {
        $lines = @(Get-Content -LiteralPath (Get-VfFixture 'pass'))
        $lines[-1] = $lines[-1] -replace '"Passed":9', '"Passed":10'
        $s = InModuleScope AzlSonar -Parameters @{ L = $lines } {
            param($L)
            $store = @{}
            foreach ($x in $L) { Add-AzlSonarVerificationEvent -Store $store -Line $x }
            Get-AzlSonarVerificationState -Store $store -Config ([pscustomobject]@{ verificationEventsPath = 'x' }) -Now ([datetime]::SpecifyKind([datetime]'2026-11-08T13:00:00', 'Utc'))
        }
        $s.countsMismatch | Should -BeTrue
        $s.status | Should -Be 'pass'
        ($s.warnings -join ' ') | Should -Match 'different counts'
        $s.reportedCounts['Passed'] | Should -Be 10
    }
}

Describe 'the config key, the master file default, the monitor and the state of the server' {
    It 'verificationEventsPath is validated, made absolute against the config file and settable' {
        $json = New-SonarConfigObject
        $json | Add-Member -NotePropertyName verificationEventsPath -NotePropertyValue './gate/live/precluster-verification-events.jsonl' -Force
        $path = Join-Path $TestDrive 'vf-config.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
        $cfg = Read-AzlSonarConfig -Path $path
        $cfg.verificationEventsPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'gate/live/precluster-verification-events.jsonl')))
        $json.verificationEventsPath = ''
        $bad = Join-Path $TestDrive 'vf-bad.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $bad
        { Read-AzlSonarConfig -Path $bad } | Should -Throw '*verificationEventsPath*'
        $set = Join-Path $TestDrive 'vf-set.json'
        [IO.File]::WriteAllText($set, (ConvertTo-SonarConfigJson (New-SonarConfigObject)))
        Set-AzlSonarConfig -Path $set -Key verificationEventsPath -Value './x.jsonl' 6>$null
        (Get-Content -LiteralPath $set -Raw | ConvertFrom-Json).verificationEventsPath | Should -Be './x.jsonl'
    }
    It 'a config file without the key follows nothing' {
        $path = Join-Path $TestDrive 'vf-none.json'
        ConvertTo-SonarConfigJson (New-SonarConfigObject) | Set-Content -LiteralPath $path
        (Read-AzlSonarConfig -Path $path).verificationEventsPath | Should -Be ''
    }
    It 'a master file follows the arm-report/verification/live folder of the environment data' {
        $infra = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $infra.verificationEventsPath | Should -Not -BeNullOrEmpty
        $tail = (($infra.verificationEventsPath -split '[\\/]') | Select-Object -Last 4) -join '/'
        $tail | Should -Be 'arm-report/verification/live/precluster-verification-events.jsonl'
    }
    It 'the Verification monitor reads only the gate file: no Azure, no node log, no other event file' {
        $p = InModuleScope AzlSonar { Get-AzlSonarMonitorPlan -Monitor 'verification' }
        $p.monitor | Should -Be 'Verification'
        $p.verificationEvents | Should -BeTrue
        foreach ($k in 'azure', 'ztpEvents', 'osConfigEvents', 'armEvents', 'nodeProbe', 'tailer', 'discovery', 'cluster') { $p[$k] | Should -BeFalse -Because $k }
        @($p.phases).Count | Should -Be 0
        (InModuleScope AzlSonar { Get-AzlSonarMonitorName -Value 'Verification' }) | Should -Be 'Verification'
        (InModuleScope AzlSonar { Get-AzlSonarMonitorPlan -Monitor 'Auto' }).verificationEvents | Should -BeTrue
    }
    It 'the state before the first poll, and the poll of the Verification monitor, carry the verification object' {
        $path = Join-Path $TestDrive 'vf-poll.json'
        $json = New-SonarConfigObject
        $json | Add-Member -NotePropertyName verificationEventsPath -NotePropertyValue (Get-VfFixture 'failed') -Force
        $json | Add-Member -NotePropertyName monitor -NotePropertyValue 'Verification' -Force
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
        $cfg = Read-AzlSonarConfig -Path $path
        $init = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) (Get-AzlSonarInitialState -Config $C).verification }
        $init.configured | Should -BeTrue
        $init.hasData | Should -BeFalse
        $r = InModuleScope AzlSonar -Parameters @{ C = $cfg; F = (Get-VfFixture 'failed') } {
            param($C, $F)
            Mock Wait-AzlSonarInterval { $Shared['Stop'] = $true }
            Mock Get-AzlSonarDeploymentState { throw 'the Verification monitor must not poll Azure' }
            $shared = Initialize-AzlSonarSharedState
            foreach ($l in @(Get-Content -LiteralPath $F)) { Add-AzlSonarVerificationEvent -Store $shared['VerificationEvents'] -Line $l }
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            $shared.State
        }
        $r.pollError | Should -BeNullOrEmpty
        $r.verification.hasData | Should -BeTrue
        $r.verification.status | Should -Be 'fail'
        $r.monitor | Should -Be 'Verification'
    }
    It 'the Details window lists the gate file as a source, and says when it is not set' {
        $path = Join-Path $TestDrive 'vf-details.json'
        $json = New-SonarConfigObject
        $json | Add-Member -NotePropertyName verificationEventsPath -NotePropertyValue (Get-VfFixture 'pass') -Force
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
        $cfg = Read-AzlSonarConfig -Path $path
        $f = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) New-AzlSonarDetailFact -Config $C }
        $f.verificationEventsFile | Should -Be 'precluster-verification-pass.jsonl'
        @($f.notSet).setting | Should -Not -Contain 'verificationEvents'
    }
}

Describe 'the page source and the docs agree with the back end' {
    It 'the page has the Verification mode and shows only text from the feed' {
        $js = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'src/AzlSonar/web/app.js') -Raw
        $js | Should -Match "MODE_IDS = \['discovery', 'prov', 'osconfig', 'verify', 'validate'"
        $js | Should -Match 'Skipped: blocks the gate'
        $js | Should -Match 'verification-events'
    }
    It 'the docs name the key, the monitor and the prerequisites' {
        $config = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/config.md') -Raw
        $config | Should -Match 'verificationEventsPath'
        $readme = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'README.md') -Raw
        $readme | Should -Match 'verificationEventsPath'
        $readme | Should -Match '-Monitor Verification'
        (Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/verification.md') -Raw) | Should -Match 'precluster-verification-events.jsonl'
    }
}
