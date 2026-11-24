#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The toolkit's two feeds of the shared events folder (azurelocal-toolkit fd64eb43, gap K9), read with the toolkit's REAL output:
#   update-events.jsonl          Get-AvailableSolutionUpdate.ps1 (mode Check) and Start-AzureLocalSolutionUpdate.ps1 (mode WhatIf and Install)
#   precluster-plan-events.jsonl Invoke-AzureLocalPreClusterVerification.ps1 -Mode Plan (a Plan has no verdict)
# The fixtures in tests/fixtures/toolkit-events are what those scripts wrote when they were run offline against a stubbed cluster
# (Invoke-Command replaced by a function that returns a made-up update state; the Plan against the toolkit's own fc-san test
# infrastructure file): nothing was sent to a cluster or to Azure. Only the machine paths in the Plan's next action were replaced and the
# cluster is named clus01. The existing UpdateEvents.Tests.ps1 and VerificationEvents.Tests.ps1 cover the readers with hand-made lines.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Fx = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/toolkit-events'
    function global:Get-TkLine([string]$Name) { @(Get-Content -LiteralPath (Join-Path $script:Fx $Name) | Where-Object { $_ }) }
    function global:Get-TkUpdate([string]$Name) {
        $lines = Get-TkLine "$Name.update-events.jsonl"
        InModuleScope AzlSonar -Parameters @{ L = $lines } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $store -Line $x }
            Get-AzlSonarUpdateEventState -Store $store -Config ([pscustomobject]@{ updateEventsPath = 'x' })
        }
    }
    function global:Get-TkPlan([string[]]$Line) {
        InModuleScope AzlSonar -Parameters @{ L = $Line } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarVerificationPlanEvent -Store $store -Line $x }
            Get-AzlSonarVerificationPlanState -Store $store -Config ([pscustomobject]@{ armEventsPath = 'C:\events\arm-deployment-events.jsonl' })
        }
    }
}

AfterAll {
    foreach ($f in 'Get-TkLine', 'Get-TkUpdate', 'Get-TkPlan') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'the toolkit fixtures are the real envelope' {
    It 'every line of every fixture has the shared envelope and the stage of its feed' {
        foreach ($file in Get-ChildItem -LiteralPath $script:Fx -Filter '*.jsonl') {
            $want = if ($file.Name -like '*precluster-plan*') { 'PreClusterVerification' } else { 'SolutionUpdate' }
            foreach ($line in Get-TkLine $file.Name) {
                $o = $line | ConvertFrom-Json
                foreach ($k in 'timestamp', 'node', 'stage', 'step', 'state', 'evidence', 'level', 'nextAction', 'runId', 'mode', 'cluster') { $o.PSObject.Properties.Name | Should -Contain $k -Because "$($file.Name): $k" }
                $o.stage | Should -Be $want
                $o.node | Should -Be '*'
            }
        }
    }
    It 'holds no machine path of the machine that produced it (a user profile, a work folder, a temp folder)' {
        foreach ($file in Get-ChildItem -LiteralPath $script:Fx -Filter '*.jsonl') {
            (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match '(?i)[\\/]+(Users|worktrees|Temp|git)[\\/]+|scratchpad'
        }
    }
}

Describe 'the Update view from update-events.jsonl (no Azure)' {
    It 'a Check that finds an update: the run is the Check, the stages are what it read, the update is named and nothing was installed' {
        $s = Get-TkUpdate 'check-available'
        $s.hasData | Should -BeTrue
        $s.status | Should -Be 'success'
        $s.plan | Should -BeTrue
        $s.phase | Should -Be 'available'
        $s.level | Should -Be 'neutral'
        $s.run.mode | Should -Be 'Check'
        $s.run.verdict | Should -Be 'UpdateAvailable'
        $s.run.exitCode | Should -Be 0
        $s.run.update | Should -Be '12.2611.1004.9'
        $s.label | Should -Be 'Update available: 12.2611.1004.9; nothing was installed (toolkit Check run)'
        @($s.tree | ForEach-Object id) | Should -Be @('upd.Environment', 'upd.Discovery', 'upd.Update 12.2611.1004.9') -Because 'the Run lines are the run, not a stage'
        @($s.tree | ForEach-Object status) | Should -Be @('success', 'success', 'success')
        $s.tree[2].description | Should -Match 'Start-AzureLocalSolutionUpdate'
    }
    It 'a Check that finds nothing: ok, no update named' {
        $s = Get-TkUpdate 'check-uptodate'
        $s.status | Should -Be 'success'
        $s.phase | Should -Be 'idle'
        $s.level | Should -Be 'ok'
        $s.run.verdict | Should -Be 'UpToDate'
        $s.run.update | Should -Be ''
        $s.label | Should -BeLike 'Up to date: no update is offered; nothing was installed*'
        @($s.tree | ForEach-Object id) | Should -Be @('upd.Environment', 'upd.Discovery')
    }
    It 'a Check that needs attention ends with RunFailed and exit code 1, naming what is wrong rather than restating the verdict' {
        $s = Get-TkUpdate 'check-attention'
        $s.status | Should -Be 'error'
        $s.phase | Should -Be 'failed'
        $s.level | Should -Be 'error'
        $s.run.exitCode | Should -Be 1
        $s.run.verdict | Should -Be 'AttentionNeeded'
        @($s.tree | ForEach-Object status) | Should -Be @('error', 'success', 'error')
        $s.run.message | Should -Be 'the update environment state is UpdateFailed'
        $s.run.message | Should -Not -BeLike 'Verdict:*'
        $s.tree[2].errors[0] | Should -Match 'InstallationFailed'
    }
    It 'a -WhatIf of the install: planned, the update would start, nothing was installed' {
        $s = Get-TkUpdate 'start-whatif'
        $s.plan | Should -BeTrue
        $s.run.mode | Should -Be 'WhatIf'
        $s.status | Should -Be 'success'
        $s.phase | Should -Be 'available'
        $s.label | Should -BeLike 'Plan complete for 12.2611.1004.9; nothing was installed (toolkit WhatIf run)'
        $s.tree[-1].rawStatus | Should -Be 'UpdateWouldStart'
    }
    It 'an install that was submitted: not a plan, the script does not wait and the tile is running' {
        $s = Get-TkUpdate 'start-install'
        $s.plan | Should -BeFalse
        $s.run.mode | Should -Be 'Install'
        $s.phase | Should -Be 'installing'
        $s.level | Should -Be 'run'
        $s.label | Should -BeLike '*was started; the toolkit script does not wait*'
    }
    It 'an update that is already running when the install script looks is running, not complete (UpdateAlreadyRunning)' {
        $lines = @(Get-TkLine 'start-install.update-events.jsonl' | ForEach-Object {
                $o = $_ | ConvertFrom-Json
                if ($o.state -eq 'UpdateStarted') { $o.state = 'UpdateAlreadyRunning'; $o.PSObject.Properties.Remove('updateName'); $o.PSObject.Properties.Remove('version') }
                if ($o.state -eq 'RunCompleted') { $o.PSObject.Properties.Remove('updateName'); $o.PSObject.Properties.Remove('version') }
                $o | ConvertTo-Json -Compress
            })
        $s = InModuleScope AzlSonar -Parameters @{ L = $lines } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $store -Line $x }
            Get-AzlSonarUpdateEventState -Store $store -Config ([pscustomobject]@{ updateEventsPath = 'x' })
        }
        $s.plan | Should -BeFalse
        $s.phase | Should -Be 'installing'
        $s.level | Should -Be 'run'
        $s.label | Should -BeLike 'An update is running on the cluster*the toolkit''s Install run started nothing'
    }
    It 'two updates are two stages, each with its own status (the Check writes one Update line per update)' {
        $lines = @(Get-TkLine 'check-available.update-events.jsonl')
        $extra = ($lines[3] | ConvertFrom-Json)
        $extra.updateName = '12.2612.1001.90'; $extra.version = '12.2612.1001.90'; $extra.state = 'UpdateAttention'; $extra.level = 'Error'; $extra.result = 'Failed'
        $all = @($lines[0..3]) + @(($extra | ConvertTo-Json -Compress)) + @($lines[4])
        $s = InModuleScope AzlSonar -Parameters @{ L = $all } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $store -Line $x }
            Get-AzlSonarUpdateEventState -Store $store -Config ([pscustomobject]@{ updateEventsPath = 'x' })
        }
        @($s.tree | ForEach-Object id) | Should -Be @('upd.Environment', 'upd.Discovery', 'upd.Update 12.2611.1004.9', 'upd.Update 12.2612.1001.90')
        @($s.tree | ForEach-Object status) | Should -Be @('success', 'success', 'success', 'error')
    }
    It 'the log pane gets a line for each event with the time, the state, the step and what the toolkit said' {
        $l = InModuleScope AzlSonar -Parameters @{ L = (Get-TkLine 'check-attention.update-events.jsonl')[3] } { param($L) ConvertFrom-AzlSonarUpdateEvent -Line $L }
        $l.file | Should -Be 'update-events'
        $l.level | Should -Be 'error'
        $l.text | Should -BeLike '2026-11-24T21:*Z `[update`] `* UpdateAttention (Update): Update 12.2611.1004.9 (Solution) is InstallationFailed*'
    }
    It 'the Update monitor with no Azure sign-in fills update and updateEvents from a Check (the tile populates)' {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'Run Connect-AzAccount to login.' }
        $cfg = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $cfg | Add-Member -NotePropertyName monitor -NotePropertyValue 'Update' -Force
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg; L = (Get-TkLine 'check-available.update-events.jsonl') } {
            param($C, $L)
            $shared = Initialize-AzlSonarSharedState
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $shared['UpdateEvents'] -Line $x }
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            $shared.State
        }
        $state.updateEvents.hasData | Should -BeTrue
        $state.update.source | Should -Be 'events'
        $state.update.verified | Should -BeFalse
        $state.update.level | Should -Be 'neutral'
        $state.update.label | Should -BeLike 'Update available: 12.2611.1004.9*'
        @($state.update.tree).Count | Should -Be 3
    }
    It 'the loop follows the file in the events folder: a WhatIf run and then a Check, the later run is the view' {
        $dir = Join-Path $TestDrive 'events-update'
        $null = New-Item -ItemType Directory -Path $dir
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        $r = InModuleScope AzlSonar -Parameters @{ Dir = $dir; A = (Get-TkLine 'start-whatif.update-events.jsonl'); B = (Get-TkLine 'check-uptodate.update-events.jsonl') } {
            param($Dir, $A, $B)
            $file = Join-Path $Dir 'update-events.jsonl'
            Set-Content -LiteralPath $file -Value @($A + $B)
            $shared = [hashtable]::Synchronized(@{ Stop = $false; UpdateEvents = [hashtable]::Synchronized(@{}) })
            $script:logged = @()
            Mock Add-AzlSonarLogLine { $script:logged += @($Line) }
            Invoke-AzlSonarUpdateEventLoop -Shared $shared -Config ([pscustomobject]@{ updateEventsPath = $file })
            @{ State = (Get-AzlSonarUpdateEventState -Store $shared['UpdateEvents'] -Config ([pscustomobject]@{ updateEventsPath = $file })); Logged = @($script:logged).Count }
        }
        $r.Logged | Should -Be 8
        $r.State.run.mode | Should -Be 'Check'
        $r.State.run.verdict | Should -Be 'UpToDate'
    }
}

Describe 'the Verification view from precluster-plan-events.jsonl (a plan has no verdict)' {
    It 'reads the gate Plan: one row per category, in the gate order, with how many checks apply' {
        $p = Get-TkPlan (Get-TkLine 'gate-plan.precluster-plan-events.jsonl')
        $p.hasData | Should -BeTrue
        $p.planned | Should -BeTrue
        $p.status | Should -Be 'planned'
        $p.word | Should -Be 'planned'
        $p.applies | Should -Be 91
        $p.total | Should -Be 100
        $p.blocking | Should -Be 81
        @($p.categories | ForEach-Object id) | Should -Be @('azure', 'identity', 'nodes', 'network', 'storage', 'readiness')
        $p.categories[0].name | Should -Be 'Azure'
        $p.categories[0].applies | Should -Be 23
        $p.categories[0].total | Should -Be 24
        $p.categories[0].blocking | Should -Be 22
        $p.run.exitCode | Should -Be 0
        $p.run.events | Should -Be 8
        $p.message | Should -BeLike 'Plan: 91 of 100 checks apply to clus01*'
        $p.nextAction | Should -BeLike 'Run the checks: *-Mode Verify*'
        $p.file | Should -Be 'precluster-plan-events.jsonl'
        $p.configured | Should -BeTrue
    }
    It 'has no verdict and no failed state of any kind' {
        $p = Get-TkPlan (Get-TkLine 'gate-plan.precluster-plan-events.jsonl')
        $p.Keys | Should -Not -Contain 'verdict'
        $p.status | Should -Not -Be 'fail'
        (ConvertTo-Json -InputObject $p -Depth 6) | Should -Not -Match '(?i)"(verdict|Fail|Failed)"'
    }
    It 'a plan with no closing line is planning; a later run replaces an earlier one; an older run''s tail is counted, not shown' {
        $lines = Get-TkLine 'gate-plan.precluster-plan-events.jsonl'
        $open = Get-TkPlan @($lines[0..2])
        $open.status | Should -Be 'planning'
        $open.categories.Count | Should -Be 2
        $second = @($lines | ForEach-Object { ($_ | ConvertFrom-Json) | ForEach-Object { $_.runId = 'second000001'; $_ } } | Select-Object -First 3 | ForEach-Object { $_ | ConvertTo-Json -Compress })
        $both = Get-TkPlan @($lines + $second)
        $both.run.runId | Should -Be 'second000001'
        $both.status | Should -Be 'planning'
        $both.categories.Count | Should -Be 2 -Because 'the second run has its RunStarted and two categories'
        $older = (($lines[1] | ConvertFrom-Json) | ForEach-Object { $_.runId = 'older0000001'; $_ }) | ConvertTo-Json -Compress
        $tail = Get-TkPlan @($lines + @($older))
        $tail.run.stale | Should -Be 1
        $tail.status | Should -Be 'planned'
        $tail.warnings -join ' ' | Should -Match 'older plan'
    }
    It 'a plan that reported a non-zero exit code is incomplete and a note, never a gate Fail' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Fx 'gate-plan.precluster-plan-events.jsonl'))
        $last = $lines[-1] | ConvertFrom-Json
        $last.exitCode = 1
        $p = Get-TkPlan @($lines[0..6] + @(($last | ConvertTo-Json -Compress)))
        $p.status | Should -Be 'incomplete'
        $p.warnings -join ' ' | Should -Match 'not a gate result'
    }
    It 'ignores lines that are not plan events (another stage, no state, not JSON)' {
        $p = Get-TkPlan @('', 'not json', '{"node":"*"}', '{"node":"*","state":"RunStarted","stage":"SolutionUpdate","runId":"x"}')
        $p.hasData | Should -BeFalse
        $p.status | Should -Be 'notplanned'
    }
    It 'the log pane gets a [verify-plan] line per event, informational' {
        $l = InModuleScope AzlSonar -Parameters @{ L = (Get-TkLine 'gate-plan.precluster-plan-events.jsonl')[1] } { param($L) ConvertFrom-AzlSonarVerificationPlanEvent -Line $L }
        $l.file | Should -Be 'verification-plan-events'
        $l.level | Should -Be 'info'
        $l.text | Should -BeLike '2026-11-24T21:*Z `[verify-plan`] `* CategoryPlanned (azure): 23 of 24 checks apply (22 blocking).'
    }
}

Describe 'where the plan file is looked for' {
    It 'is in the events folder, beside the other toolkit feeds' {
        $r = InModuleScope AzlSonar { Resolve-AzlSonarVerificationPlanFile -Config ([pscustomobject]@{ updateEventsPath = 'D:\ev\update-events.jsonl'; verificationEventsPath = 'D:\gate\live\x.jsonl' }) }
        $r | Should -Be 'D:\ev\precluster-plan-events.jsonl'
        InModuleScope AzlSonar { Resolve-AzlSonarVerificationPlanFile -Config ([pscustomobject]@{ osConfigEventsPath = 'D:\ev2\os-configuration-events.jsonl' }) } | Should -Be 'D:\ev2\precluster-plan-events.jsonl'
    }
    It 'falls to the gate''s own folder when the run was given -ReportDirectory and the file is there' {
        $gate = Join-Path $TestDrive 'gate-live'
        $null = New-Item -ItemType Directory -Path $gate
        Copy-Item -LiteralPath (Join-Path $script:Fx 'gate-plan.precluster-plan-events.jsonl') -Destination (Join-Path $gate 'precluster-plan-events.jsonl')
        $r = InModuleScope AzlSonar -Parameters @{ G = $gate } { param($G) Resolve-AzlSonarVerificationPlanFile -Config ([pscustomobject]@{ updateEventsPath = 'D:\no-such-events\update-events.jsonl'; verificationEventsPath = (Join-Path $G 'precluster-verification-events.jsonl') }) }
        $r | Should -Be (Join-Path $gate 'precluster-plan-events.jsonl')
    }
    It 'is nothing when no events folder and no gate file is configured, and the infrastructure file gives the events folder' {
        InModuleScope AzlSonar { Resolve-AzlSonarVerificationPlanFile -Config ([pscustomobject]@{}) } | Should -Be ''
        $cfg = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $r = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) Resolve-AzlSonarVerificationPlanFile -Config $C }
        (Split-Path $r -Parent) | Should -Be (Split-Path $cfg.updateEventsPath -Parent)
        (Split-Path $r -Leaf) | Should -Be 'precluster-plan-events.jsonl'
    }
}

Describe 'the Verification monitor: the Plan beside the gate''s own file' {
    BeforeAll {
        $script:Events = Join-Path $TestDrive 'events-verify'
        $null = New-Item -ItemType Directory -Path $script:Events
        Copy-Item -LiteralPath (Join-Path $script:Fx 'gate-plan.precluster-plan-events.jsonl') -Destination (Join-Path $script:Events 'precluster-plan-events.jsonl')
        $script:GateDir = Join-Path $TestDrive 'gate-verify'
        $script:Pass = Join-Path $PSScriptRoot 'fixtures/verification/precluster-verification-pass.jsonl'
    }
    It 'the loop puts the plan under the key plan and leaves the gate''s run key alone' {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        $r = InModuleScope AzlSonar -Parameters @{ Dir = $script:Events } {
            param($Dir)
            $shared = [hashtable]::Synchronized(@{ Stop = $false; VerificationEvents = [hashtable]::Synchronized(@{ '*' = @{ marker = 'gate' } }) })
            $script:logged = @()
            Mock Add-AzlSonarLogLine { $script:logged += @($Line) }
            Invoke-AzlSonarVerificationPlanEventLoop -Shared $shared -Config ([pscustomobject]@{ armEventsPath = (Join-Path $Dir 'arm-deployment-events.jsonl') })
            @{ Keys = @($shared['VerificationEvents'].Keys | Sort-Object); Gate = $shared['VerificationEvents']['*'].marker; Plan = $shared['VerificationEvents']['plan'].Events; Logged = @($script:logged).Count }
        }
        $r.Keys | Should -Be @('*', 'plan')
        $r.Gate | Should -Be 'gate'
        $r.Plan | Should -Be 8
        $r.Logged | Should -Be 8
    }
    It 'with only a plan the state is waiting for the gate: no verdict, nothing blocks, the plan is there' {
        $lines = Get-TkLine 'gate-plan.precluster-plan-events.jsonl'
        $s = InModuleScope AzlSonar -Parameters @{ L = $lines; Dir = $script:Events } {
            param($L, $Dir)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarVerificationPlanEvent -Store $store -Line $x }
            Get-AzlSonarVerificationState -Store $store -Config ([pscustomobject]@{ verificationEventsPath = (Join-Path $Dir 'gate\precluster-verification-events.jsonl'); armEventsPath = (Join-Path $Dir 'arm.jsonl') })
        }
        $s.hasData | Should -BeFalse
        $s.status | Should -Be 'notstarted'
        $s.verdict | Should -Be ''
        $s.blockers | Should -Be 0
        @($s.categories).Count | Should -Be 0
        $s.plan.hasData | Should -BeTrue
        $s.plan.status | Should -Be 'planned'
        $s.plan.applies | Should -Be 91
    }
    It 'the gate''s verdict is untouched by a plan: a Pass stays a Pass' {
        $gateLines = @(Get-Content -LiteralPath $script:Pass)
        $planLines = Get-TkLine 'gate-plan.precluster-plan-events.jsonl'
        $s = InModuleScope AzlSonar -Parameters @{ G = $gateLines; P = $planLines; Dir = $script:Events } {
            param($G, $P, $Dir)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $G) { Add-AzlSonarVerificationEvent -Store $store -Line $x }
            foreach ($x in $P) { Add-AzlSonarVerificationPlanEvent -Store $store -Line $x }
            Get-AzlSonarVerificationState -Store $store -Config ([pscustomobject]@{ verificationEventsPath = 'x'; armEventsPath = (Join-Path $Dir 'arm.jsonl') }) -Now ([datetime]::SpecifyKind([datetime]'2026-11-08T13:00:00', 'Utc'))
        }
        $s.hasData | Should -BeTrue
        $s.status | Should -Be 'pass'
        $s.verdict | Should -Be 'Pass'
        $s.plan.hasData | Should -BeTrue
        $s.plan.applies | Should -Be 91
    }
    It 'the monitor plan reads the plan feed with the gate''s event file only (Auto and Verification)' -TestCases @(
        @{ Name = 'Auto'; On = $true }, @{ Name = 'Verification'; On = $true }, @{ Name = 'Update'; On = $false }, @{ Name = 'OsConfiguration'; On = $false }
    ) {
        (InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Get-AzlSonarMonitorPlan -Monitor $N }).verificationEvents | Should -Be $On
    }
    It 'the Verification monitor with no Azure sign-in serves the plan in /api/state' {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        $cfg = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $cfg | Add-Member -NotePropertyName monitor -NotePropertyValue 'Verification' -Force
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg; L = (Get-TkLine 'gate-plan.precluster-plan-events.jsonl') } {
            param($C, $L)
            $shared = Initialize-AzlSonarSharedState
            foreach ($x in $L) { Add-AzlSonarVerificationPlanEvent -Store $shared['VerificationEvents'] -Line $x }
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            $shared.State
        }
        $state.verification.hasData | Should -BeFalse
        $state.verification.plan.hasData | Should -BeTrue
        $state.verification.plan.status | Should -Be 'planned'
        @($state.verification.plan.categories).Count | Should -Be 6
    }
}
