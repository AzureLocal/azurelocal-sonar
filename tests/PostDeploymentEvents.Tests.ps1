#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The toolkit's post-deployment feed (azurelocal-toolkit, phase 06 of the Implementation guide): post-deployment-events.jsonl in the shared
# events folder, written by Invoke-AzureLocalPostDeployment.ps1 (Invoke-AzlPostDeployment). The fixtures in tests/fixtures/toolkit-events are the
# orchestrator's REAL output, produced offline by New-ToolkitEventFixtures.ps1 (Azure blocked, the cluster's answers made up):
#   plan-example   the toolkit's own step scripts, Plan mode, against its example infrastructure file (it stops at quorum: exit code 2)
#   plan-passed    Plan, every step planned or skipped with its reason (exit 0)
#   plan-warning   Plan that stops after a step with a warning (exit 3)
#   apply-passed   Apply, every step passed
#   apply-failed   Apply, the storage volumes step failed (exit 1), the steps after it not run
# No Azure, no cluster, no node: every Azure call is mocked to fail the test.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Fx = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/toolkit-events'
    $script:StepIds = @('sdn', 'sdn-test', 'quorum', 'security-groups', 'ssh', 'storage-volumes', 'storage-paths', 'vm-images', 'nsgs', 'logical-networks', 'verification', 'external-storage', 'sbe-import-plan')
    function global:Get-PdLine([string]$Name) { @(Get-Content -LiteralPath (Join-Path $script:Fx "$Name.post-deployment-events.jsonl") | Where-Object { $_ }) }
    function global:Get-PdState {
        param([string[]]$Line, [string]$Events = 'C:\events')
        InModuleScope AzlSonar -Parameters @{ L = $Line; E = $Events } {
            param($L, $E)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarPostDeploymentEvent -Store $store -Line $x }
            Get-AzlSonarPostDeploymentState -Store $store -Config ([pscustomobject]@{ armEventsPath = (Join-Path $E 'arm-deployment-events.jsonl') })
        }
    }
    function global:Get-PdStep($State, [string]$Id) { @($State.steps | Where-Object { $_.id -eq $Id })[0] }
}

AfterAll {
    foreach ($f in 'Get-PdLine', 'Get-PdState', 'Get-PdStep') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'the fixtures are the orchestrator''s real envelope' {
    It 'every line has the shared envelope, the stage PostDeployment and the node *' {
        foreach ($name in 'plan-example', 'plan-passed', 'plan-warning', 'apply-passed', 'apply-failed') {
            foreach ($line in Get-PdLine $name) {
                $o = $line | ConvertFrom-Json
                foreach ($k in 'timestamp', 'node', 'stage', 'step', 'state', 'evidence', 'level', 'nextAction', 'runId', 'mode', 'cluster') { $o.PSObject.Properties.Name | Should -Contain $k -Because "$name`: $k" }
                $o.stage | Should -Be 'PostDeployment'
                $o.node | Should -Be '*'
                $o.cluster | Should -Be 'clus01'
            }
        }
    }
    It 'every run starts with RunStarted and ends with RunCompleted, and the mode is Plan or Apply' {
        foreach ($name in 'plan-example', 'plan-passed', 'plan-warning', 'apply-passed', 'apply-failed') {
            $objects = @(Get-PdLine $name | ForEach-Object { $_ | ConvertFrom-Json })
            $objects[0].state | Should -Be 'RunStarted'
            $objects[-1].state | Should -Be 'RunCompleted'
            @($objects | ForEach-Object mode | Select-Object -Unique) | Should -Be @($(if ($name -like 'apply*') { 'Apply' } else { 'Plan' }))
            @($objects[0].selected) | Should -Be $script:StepIds
        }
    }
    It 'holds no machine path, user profile or lab name of the machine that produced it' {
        foreach ($file in Get-ChildItem -LiteralPath $script:Fx -Filter '*.post-deployment-events.jsonl') {
            (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match '(?i)[\\/]+(Users|worktrees|Temp|git)[\\/]+|scratchpad|iic-|kristopher'
        }
    }
}

Describe 'the Post-deployment view from the real events (no Azure)' {
    It 'a Plan that passed: planned, informational, every step with its task, the skipped ones with their reason' {
        $s = Get-PdState (Get-PdLine 'plan-passed')
        $s.hasData | Should -BeTrue
        $s.mode | Should -Be 'Plan'
        $s.status | Should -Be 'planned'
        $s.kind | Should -Be 'idle' -Because 'a Plan is never green or red'
        $s.exitCode | Should -Be 0
        $s.verdict | Should -Be 'every selected step passed or was planned'
        $s.cluster.state | Should -Be 'reachable'
        @($s.steps | ForEach-Object id) | Should -Be $script:StepIds -Because 'the 13 steps in the order of the guide'
        $s.counts.total | Should -Be 13
        $s.counts.planned | Should -Be 9
        $s.counts.skipped | Should -Be 4
        $sdn = Get-PdStep $s 'sdn'
        $sdn.status | Should -Be 'skipped'
        $sdn.word | Should -Be 'Skipped'
        $sdn.reason | Should -Be 'sdn.enabled is not true (the file has it false)'
        $sdn.task | Should -Be 'task-01-deploy-sdn' -Because 'a skipped step has no StepStarted line: the page comes from the known step table'
        $q = Get-PdStep $s 'quorum'
        $q.status | Should -Be 'planned'
        $q.exitCode | Should -Be 0
        $q.task | Should -Be 'task-02-cluster-quorum-configuration' -Because 'data.task of the StepStarted line'
        @($s.warnings).Count | Should -Be 0
    }
    It 'a Plan that stopped on the toolkit''s example file: Plan stopped (amber), the failed step is a finding, never an error' {
        $s = Get-PdState (Get-PdLine 'plan-example')
        $s.mode | Should -Be 'Plan'
        $s.status | Should -Be 'incomplete'
        $s.kind | Should -Be 'warn'
        $s.word | Should -Be 'plan stopped'
        $s.exitCode | Should -Be 2
        $q = Get-PdStep $s 'quorum'
        $q.status | Should -Be 'failed'
        $q.kind | Should -Be 'warn' -Because 'a failed step of a Plan is a finding'
        $q.exitCode | Should -Be 2
        $q.reason | Should -Match 'azure.subscription_id'
        $q.nextAction | Should -Match '-From quorum'
        (Get-PdStep $s 'security-groups').status | Should -Be 'notrun'
        (Get-PdStep $s 'sbe-import-plan').word | Should -Be 'Not run'
        $s.counts.skipped | Should -Be 6
        $s.counts.failed | Should -Be 1
        $s.counts.notrun | Should -Be 6
        @($s.warnings)[0] | Should -Match 'A plan changes nothing'
    }
    It 'a Plan that stopped after a step with a warning: exit code 3, amber' {
        $s = Get-PdState (Get-PdLine 'plan-warning')
        $s.status | Should -Be 'warning'
        $s.kind | Should -Be 'warn'
        $s.exitCode | Should -Be 3
        $s.verdict | Should -Match "stopped after step 'ssh'"
        (Get-PdStep $s 'ssh').status | Should -Be 'warning'
        (Get-PdStep $s 'ssh').reason | Should -Match 'ended with 1 warning'
        (Get-PdStep $s 'storage-volumes').status | Should -Be 'notrun'
    }
    It 'an Apply that passed is ok (green), 13 of 13' {
        $s = Get-PdState (Get-PdLine 'apply-passed')
        $s.mode | Should -Be 'Apply'
        $s.status | Should -Be 'passed'
        $s.kind | Should -Be 'ok'
        $s.counts.passed | Should -Be 13
        $s.exitCode | Should -Be 0
        (Get-PdStep $s 'sbe-import-plan').status | Should -Be 'passed'
    }
    It 'an Apply that failed is red at the failing step, the steps after it not run' {
        $s = Get-PdState (Get-PdLine 'apply-failed')
        $s.status | Should -Be 'failed'
        $s.kind | Should -Be 'err'
        $s.exitCode | Should -Be 1
        $f = Get-PdStep $s 'storage-volumes'
        $f.status | Should -Be 'failed'
        $f.kind | Should -Be 'err'
        $f.exitCode | Should -Be 1
        @($s.steps | Where-Object status -EQ 'notrun').Count | Should -Be 7
        @($s.steps | Where-Object status -EQ 'passed').Count | Should -Be 5
    }
    It 'serialises to JSON the page can read' {
        $json = (Get-PdState (Get-PdLine 'plan-passed') | ConvertTo-Json -Depth 12) | ConvertFrom-Json
        @($json.steps).Count | Should -Be 13
        $json.counts.total | Should -Be 13
        $json.run.runId | Should -Not -BeNullOrEmpty
    }
}

Describe 'the reader on partial, odd and repeated input' {
    It 'before any line it waits, quietly' {
        $s = Get-PdState @()
        $s.hasData | Should -BeFalse
        $s.status | Should -Be 'notstarted'
        $s.kind | Should -Be 'idle'
        @($s.steps).Count | Should -Be 0
    }
    It 'a run in progress: the started step is running, the others it selected wait, nothing is failed' {
        $lines = @(Get-PdLine 'plan-passed')
        $cut = @($lines | Where-Object { $_ -notmatch '"state":"RunCompleted"' } | Select-Object -First 9)
        $s = Get-PdState $cut
        $s.status | Should -Be 'running'
        $s.word | Should -Be 'planning'
        $s.kind | Should -Be 'run'
        @($s.steps | Where-Object status -EQ 'running').Count | Should -BeLessOrEqual 1
        @($s.steps).Count | Should -Be 13 -Because 'the selected steps without a line yet are waiting'
        @($s.steps | Where-Object status -EQ 'pending').Count | Should -BeGreaterThan 0
        $s.exitCode | Should -BeNullOrEmpty
    }
    It 'a run that ended: a step still waiting is not run' {
        $lines = @(Get-PdLine 'apply-failed' | Where-Object { $_ -notmatch '"state":"StepNotRun"' })
        $s = Get-PdState $lines
        @($s.steps | Where-Object status -EQ 'pending').Count | Should -Be 0
        (Get-PdStep $s 'ssh').status | Should -Be 'passed'
        (Get-PdStep $s 'vm-images').status | Should -Be 'notrun'
    }
    It 'only the latest run is shown: a new RunStarted starts over, a line of an older run is counted and not shown' {
        $first = @(Get-PdLine 'apply-failed')
        $second = @(Get-PdLine 'plan-passed')
        $s = Get-PdState ($first + $second)
        $s.mode | Should -Be 'Plan'
        $s.status | Should -Be 'planned'
        $s.run.stale | Should -Be 0
        # an older run's tail with no RunStarted in view
        $tail = @($first[-1])
        $t = Get-PdState ($second + $tail)
        $t.mode | Should -Be 'Plan'
        $t.status | Should -Be 'planned'
        $t.run.stale | Should -Be 1
        @($t.warnings)[0] | Should -Match 'older run'
    }
    It 'tolerates a state it does not know, a step id it does not know and lines that are not JSON' {
        $extra = @(
            '{"timestamp":"2026-11-25T02:21:34.0000000Z","node":"*","stage":"PostDeployment","step":"","state":"RunStarted","evidence":"x","level":"Info","nextAction":"","runId":"r1","mode":"Apply","cluster":"clus01","route":"PowerShell","selected":["quorum","new-step"]}',
            'this is not json',
            '{"timestamp":"2026-11-25T02:21:35.0000000Z","node":"*","stage":"PostDeployment","step":"new-step","state":"StepRetried","evidence":"again","level":"Info","nextAction":"","runId":"r1","mode":"Apply","cluster":"clus01"}',
            '{"timestamp":"2026-11-25T02:21:36.0000000Z","node":"*","stage":"PostDeployment","step":"new-step","state":"StepPassed","evidence":"ok","level":"Info","nextAction":"","runId":"r1","mode":"Apply","cluster":"clus01","task":"task-99-future","exitCode":0}',
            '{"timestamp":"2026-11-25T02:21:37.0000000Z","node":"*","stage":"SolutionUpdate","step":"quorum","state":"StepFailed","evidence":"another feed","level":"Error","nextAction":"","runId":"r1","mode":"Apply","cluster":"clus01"}'
        )
        $s = Get-PdState $extra
        @($s.steps | ForEach-Object id) | Should -Be @('quorum', 'new-step') -Because 'a known id first, then any other'
        (Get-PdStep $s 'new-step').status | Should -Be 'passed'
        (Get-PdStep $s 'new-step').task | Should -Be 'task-99-future'
        (Get-PdStep $s 'quorum').status | Should -Be 'pending' -Because 'a line of another stage is not read'
        $s.status | Should -Be 'running'
    }
    It 'masks a secret in a step''s reason' {
        $line = '{"timestamp":"2026-11-25T02:21:35.0000000Z","node":"*","stage":"PostDeployment","step":"quorum","state":"StepFailed","evidence":"ERROR: connected with password = hunter2","level":"Error","nextAction":"","runId":"r1","mode":"Apply","cluster":"clus01","exitCode":1}'
        $start = '{"timestamp":"2026-11-25T02:21:34.0000000Z","node":"*","stage":"PostDeployment","step":"","state":"RunStarted","evidence":"x","level":"Info","nextAction":"","runId":"r1","mode":"Apply","cluster":"clus01"}'
        $s = Get-PdState @($start, $line)
        (Get-PdStep $s 'quorum').reason | Should -Not -Match 'hunter2'
    }
}

Describe 'the log lines' {
    It 'show each event as [post-deployment] with its state, step, evidence and next action' {
        $l = InModuleScope AzlSonar -Parameters @{ L = (Get-PdLine 'apply-failed') } { param($L) @($L | ForEach-Object { ConvertFrom-AzlSonarPostDeploymentEvent -Line $_ }) }
        @($l).Count | Should -Be (Get-PdLine 'apply-failed').Count
        $l[0].file | Should -Be 'post-deployment-events'
        $l[0].text | Should -Match '\[post-deployment\] \* RunStarted'
        ($l | Where-Object { $_.text -match 'StepFailed \(storage-volumes\)' }).text | Should -Match '-> next: Read the log'
    }
    It 'an Error line of a Plan is shown as a warning (a Plan changes nothing), one of an Apply stays an error' {
        $plan = InModuleScope AzlSonar -Parameters @{ L = (Get-PdLine 'plan-example') } { param($L) @($L | ForEach-Object { ConvertFrom-AzlSonarPostDeploymentEvent -Line $_ }) }
        @($plan | Where-Object level -EQ 'error').Count | Should -Be 0
        @($plan | Where-Object level -EQ 'warning').Count | Should -Be 2 -Because 'StepFailed and RunCompleted'
        $apply = InModuleScope AzlSonar -Parameters @{ L = (Get-PdLine 'apply-failed') } { param($L) @($L | ForEach-Object { ConvertFrom-AzlSonarPostDeploymentEvent -Line $_ }) }
        @($apply | Where-Object level -EQ 'error').Count | Should -Be 2
    }
    It 'a line of another feed or not JSON is no event' {
        InModuleScope AzlSonar {
            ConvertFrom-AzlSonarPostDeploymentEvent -Line 'nope' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarPostDeploymentEvent -Line '{"node":"*","state":"RunStarted","stage":"SolutionUpdate"}' | Should -BeNullOrEmpty
        }
    }
}

Describe 'which file is followed: the events folder, no new configuration key' {
    BeforeAll {
        $script:Events = Join-Path $TestDrive 'events'
        $null = New-Item -ItemType Directory -Path $script:Events -Force
    }
    It 'is post-deployment-events.jsonl next to the feed the config names (<Key>), whether or not it exists yet' -ForEach @(
        @{ Key = 'updateEventsPath'; Name = 'update-events.jsonl' }, @{ Key = 'armEventsPath'; Name = 'arm-deployment-events.jsonl' },
        @{ Key = 'osConfigEventsPath'; Name = 'os-configuration-events.jsonl' }, @{ Key = 'verificationEventsPath'; Name = 'precluster-verification-events.jsonl' }
    ) {
        $r = InModuleScope AzlSonar -Parameters @{ E = $script:Events; K = $Key; N = $Name } {
            param($E, $K, $N)
            $c = [pscustomobject]@{ $K = (Join-Path $E $N) }
            [pscustomobject]@{ Any = (Resolve-AzlSonarPostDeploymentEventsFile -Config $c); Must = (Resolve-AzlSonarPostDeploymentEventsFile -Config $c -MustExist) }
        }
        $r.Any | Should -Be (Join-Path $script:Events 'post-deployment-events.jsonl')
        $r.Must | Should -Be '' -Because 'a folder that merely might get the file is not a source'
    }
    It 'finds nothing when no feed is configured' {
        InModuleScope AzlSonar { Resolve-AzlSonarPostDeploymentEventsFile -Config ([pscustomobject]@{}) | Should -Be '' }
    }
    It 'finds the file when the folder holds it' {
        Copy-Item -LiteralPath (Join-Path $script:Fx 'plan-passed.post-deployment-events.jsonl') -Destination (Join-Path $script:Events 'post-deployment-events.jsonl')
        InModuleScope AzlSonar -Parameters @{ E = $script:Events } {
            param($E)
            Resolve-AzlSonarPostDeploymentEventsFile -Config ([pscustomobject]@{ updateEventsPath = (Join-Path $E 'update-events.jsonl') }) -MustExist | Should -Be (Join-Path $E 'post-deployment-events.jsonl')
        }
    }
    It 'the loop follows the file, logs each event, and puts the run under the key * of Shared.PostDeploymentEvents' {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        $r = InModuleScope AzlSonar -Parameters @{ E = $script:Events } {
            param($E)
            $shared = [hashtable]::Synchronized(@{ Stop = $false; PostDeploymentEvents = [hashtable]::Synchronized(@{}) })
            $script:logged = @()
            Mock Add-AzlSonarLogLine { $script:logged += @($Line) }
            Invoke-AzlSonarPostDeploymentEventLoop -Shared $shared -Config ([pscustomobject]@{ armEventsPath = (Join-Path $E 'arm-deployment-events.jsonl') })
            @{ Keys = @($shared['PostDeploymentEvents'].Keys); Events = $shared['PostDeploymentEvents']['*'].Events; Logged = @($script:logged).Count }
        }
        $r.Keys | Should -Be @('*')
        $r.Events | Should -Be (Get-PdLine 'plan-passed').Count
        $r.Logged | Should -Be (Get-PdLine 'plan-passed').Count
    }
}

Describe 'the monitor plan and the start with no Azure sign-in' {
    It 'the Deployment and Auto monitors read the post-deployment events; the others do not' -ForEach @(
        @{ Name = 'Auto'; Reads = $true }, @{ Name = 'Deployment'; Reads = $true }, @{ Name = 'Validate'; Reads = $false }, @{ Name = 'Update'; Reads = $false },
        @{ Name = 'Verification'; Reads = $false }, @{ Name = 'Provisioning'; Reads = $false }, @{ Name = 'Discovery'; Reads = $false }
    ) {
        $p = InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Get-AzlSonarMonitorPlan -Monitor $N }
        $p.postDeploymentEvents | Should -Be $Reads
    }
    It 'the Deployment monitor with no Azure reads the events only: no Azure, no node, no log tailer, no log access' {
        $p = InModuleScope AzlSonar { Get-AzlSonarMonitorPlan -Monitor 'Deployment' -AzureOffline }
        $p.azure | Should -BeFalse
        $p.tailer | Should -BeFalse
        $p.nodeProbe | Should -BeFalse
        $p.cluster | Should -BeFalse
        $p.postDeploymentEvents | Should -BeTrue
        @($p.phases).Count | Should -Be 0
    }
    It 'is today''s plan with a sign-in' {
        $p = InModuleScope AzlSonar { Get-AzlSonarMonitorPlan -Monitor 'Deployment' }
        $p.azure | Should -BeTrue
        $p.tailer | Should -BeTrue
        @($p.phases) | Should -Be @('deployment', 'post-deployment')
    }
    It 'only the Deployment monitor can start without Azure, and only when the file is there' {
        $events = Join-Path $TestDrive 'offline-events'
        $null = New-Item -ItemType Directory -Path $events -Force
        $r = InModuleScope AzlSonar -Parameters @{ E = $events } {
            param($E)
            $cfg = { param($m) [pscustomobject]@{ monitor = $m; armEventsPath = (Join-Path $E 'arm-deployment-events.jsonl') } }
            $before = Test-AzlSonarOfflinePostDeployment -Config (& $cfg 'Deployment')
            Set-Content -LiteralPath (Join-Path $E 'post-deployment-events.jsonl') -Value '{}'
            [pscustomobject]@{ Before = $before; Deployment = (Test-AzlSonarOfflinePostDeployment -Config (& $cfg 'Deployment')); Auto = (Test-AzlSonarOfflinePostDeployment -Config (& $cfg 'Auto')); Update = (Test-AzlSonarOfflinePostDeployment -Config (& $cfg 'Update')) }
        }
        $r.Before | Should -BeFalse
        $r.Deployment | Should -BeTrue
        $r.Auto | Should -BeFalse
        $r.Update | Should -BeFalse
    }
}

Describe 'the offline Deployment state (no Azure call, never an error)' {
    BeforeAll {
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No Azure call may be made.' }
        function global:Get-PdOffline([string[]]$Line) {
            InModuleScope AzlSonar -Parameters @{ L = $Line } {
                param($L)
                $store = [hashtable]::Synchronized(@{})
                foreach ($x in $L) { Add-AzlSonarPostDeploymentEvent -Store $store -Line $x }
                $cfg = [pscustomobject]@{ clusterName = 'clus01'; resourceGroup = 'rg'; nodes = @(); monitor = 'Deployment'; armEventsPath = 'C:\events\arm-deployment-events.jsonl'; azureConnected = $false }
                Get-AzlSonarPostDeploymentOfflineState -Config $cfg -PostDeploymentEvents $store
            }
        }
    }
    AfterAll { Remove-Item -LiteralPath 'Function:\Get-PdOffline' -ErrorAction SilentlyContinue }
    It 'a Plan: the tile data is there, the phase is post-deployment, Azure is a fact, pollError stays empty' {
        $s = Get-PdOffline (Get-PdLine 'plan-passed')
        $s.postDeployment.status | Should -Be 'planned'
        $s.postDeployment.azure.connected | Should -BeFalse
        $s.postDeployment.azure.status | Should -Be 'notconnected'
        $s.postDeployment.azure.message | Should -Match 'not connected'
        $s.phase | Should -Be 'post-deployment'
        $s.activePhase | Should -Be 'post-deployment'
        $s.monitor | Should -Be 'Deployment'
        $s.pollError | Should -BeNullOrEmpty
        @($s.warnings).Count | Should -Be 0
    }
    It 'a Plan that stopped is not a failed phase' {
        $s = Get-PdOffline (Get-PdLine 'plan-example')
        $s.phase | Should -Be 'post-deployment'
        $s.postDeployment.kind | Should -Be 'warn'
    }
    It 'an Apply that failed moves the phase to failed (activePhase post-deployment)' {
        $s = Get-PdOffline (Get-PdLine 'apply-failed')
        $s.phase | Should -Be 'failed'
        $s.activePhase | Should -Be 'post-deployment'
        $s.pollError | Should -BeNullOrEmpty
    }
    It 'before the toolkit has written anything it waits' {
        $s = Get-PdOffline @()
        $s.postDeployment.hasData | Should -BeFalse
        $s.postDeployment.azure.connected | Should -BeFalse
    }
    It 'serialises to JSON the page can read' {
        $json = (Get-PdOffline (Get-PdLine 'plan-passed') | ConvertTo-Json -Depth 20) | ConvertFrom-Json
        $json.postDeployment.azure.connected | Should -BeFalse
        @($json.postDeployment.steps).Count | Should -Be 13
    }
}

Describe 'the poller with no Azure sign-in' {
    It 'publishes the post-deployment view and makes no Azure call when azureConnected is false' {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No Azure call may be made.' }
        $cfg = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $cfg | Add-Member -NotePropertyName monitor -NotePropertyValue 'Deployment' -Force
        $cfg | Add-Member -NotePropertyName azureConnected -NotePropertyValue $false -Force
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg; L = (Get-PdLine 'plan-passed') } {
            param($C, $L)
            $shared = Initialize-AzlSonarSharedState
            foreach ($x in $L) { Add-AzlSonarPostDeploymentEvent -Store $shared['PostDeploymentEvents'] -Line $x }
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            $shared.State
        }
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -Times 0 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -ParameterFilter { $Seconds -eq 2 } -Times 1 -Exactly
        $state.postDeployment.status | Should -Be 'planned'
        $state.postDeployment.azure.connected | Should -BeFalse
        $state.pollError | Should -BeNullOrEmpty
    }
}

Describe 'Start-AzlSonarServer: the Deployment monitor with no Azure sign-in' {
    BeforeAll {
        Add-Type -AssemblyName System.Net.Http
        $script:WithFile = Join-Path $TestDrive 'with-file'
        $null = New-Item -ItemType Directory -Path $script:WithFile -Force
        Copy-Item -LiteralPath (Join-Path $script:Fx 'plan-passed.post-deployment-events.jsonl') -Destination (Join-Path $script:WithFile 'post-deployment-events.jsonl')
        $a = New-SonarConfigObject
        $a | Add-Member -NotePropertyName armEventsPath -NotePropertyValue (Join-Path $script:WithFile 'arm-deployment-events.jsonl') -Force
        $script:FileConfig = Join-Path $TestDrive 'with-file.json'
        ConvertTo-SonarConfigJson $a | Set-Content -LiteralPath $script:FileConfig
        $script:Without = Join-Path $TestDrive 'without-file'
        $null = New-Item -ItemType Directory -Path $script:Without -Force
        $b = New-SonarConfigObject
        $b | Add-Member -NotePropertyName armEventsPath -NotePropertyValue (Join-Path $script:Without 'arm-deployment-events.jsonl') -Force
        $script:NoFileConfig = Join-Path $TestDrive 'without-file.json'
        ConvertTo-SonarConfigJson $b | Set-Content -LiteralPath $script:NoFileConfig
    }
    It 'starts without a sign-in and without asking for the log account when the events folder holds post-deployment-events.jsonl' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'No Azure sign-in found in this PowerShell session.' }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'The log account must not be asked for.' }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'Workers must not start.' }
        $port = Get-SonarFreeTcpPort
        $blocker = [System.Net.HttpListener]::new()
        $blocker.Prefixes.Add("http://localhost:$port/")
        $blocker.Start()
        try {
            { Start-AzlSonarServer -ConfigPath $script:FileConfig -Monitor Deployment -Port $port -NoBrowser } | Should -Throw "*Cannot listen on http://localhost:$port/*"
        }
        finally {
            $blocker.Stop(); $blocker.Close()
        }
        Should -Invoke -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -Times 1 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -Times 0 -Exactly
    }
    It 'still refuses to start without a sign-in when the file is not there, and for Auto' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'No Azure sign-in found in this PowerShell session.' }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'must not be reached' }
        { Start-AzlSonarServer -ConfigPath $script:NoFileConfig -Monitor Deployment -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*No Azure sign-in*'
        { Start-AzlSonarServer -ConfigPath $script:FileConfig -Monitor Auto -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*No Azure sign-in*'
    }
    It 'with a sign-in it is the Azure poll as before: the log account is asked for' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'asked for the log account' }
        { Start-AzlSonarServer -ConfigPath $script:FileConfig -Monitor Deployment -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*asked for the log account*'
    }
}
