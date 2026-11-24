#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The toolkit's solution update event file (gap K9 / N7): update-events.jsonl in the one shared events folder, followed by the
# Update monitor with no Azure. The reader, the store, the offline update view, the merge with Azure's track, the config key,
# the monitor plan and the poller after a failed Azure poll. The event lines are built here: no Azure, no node.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule

    # One event line in the envelope every toolkit feed uses.
    function global:New-UpdLine {
        param([string]$At, [string]$State, [string]$Node = '*', [string]$Step = '', [string]$Evidence = '', [string]$Level = 'Info', [string]$NextAction = '', [string]$Mode = 'Install', [string]$RunId = 'u1', [string]$Stage = 'SolutionUpdate', [hashtable]$Extra = @{})
        $o = [ordered]@{ timestamp = $At; node = $Node; stage = $Stage; step = $Step; state = $State; evidence = $Evidence; level = $Level; nextAction = $NextAction; schemaVersion = '5.6.31'; runId = $RunId; mode = $Mode; cluster = 'c1' }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        $o | ConvertTo-Json -Compress -Depth 6
    }
    $script:T0 = [datetime]::SpecifyKind([datetime]'2026-11-24T12:00:00', 'Utc')
    function global:Get-UpdTime([double]$Minutes) { $script:T0.AddMinutes($Minutes).ToString('o', [cultureinfo]::InvariantCulture) }
    function global:Get-UpdState {
        param([string[]]$Line)
        InModuleScope AzlSonar -Parameters @{ L = $Line } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $store -Line $x }
            Get-AzlSonarUpdateEventState -Store $store -Config ([pscustomobject]@{ updateEventsPath = 'x' })
        }
    }
    # A WhatIf (plan) run that checked the update and stopped before the install.
    $script:PlanRun = @(
        (New-UpdLine -At (Get-UpdTime 0) -State RunStarted -Mode WhatIf -Evidence 'Update run started (WhatIf).')
        (New-UpdLine -At (Get-UpdTime 1) -State UpdateDiscovered -Mode WhatIf -Step 'Discover' -Evidence 'Solution12.2611.1004.9 is Ready.' -Extra @{ updateName = 'Solution12.2611.1004.9'; version = '12.2611.1004.9' })
        (New-UpdLine -At (Get-UpdTime 2) -State PrerequisitesChecked -Mode WhatIf -Step 'Prerequisites' -Evidence 'Every prerequisite passed.' -Extra @{ result = 'Passed' })
        (New-UpdLine -At (Get-UpdTime 3) -State InstallSkipped -Mode WhatIf -Step 'Install' -Evidence 'WhatIf: the update was not started.')
        (New-UpdLine -At (Get-UpdTime 4) -State RunCompleted -Mode WhatIf -Evidence 'Update run complete.' -Extra @{ exitCode = 0 })
    )
}

AfterAll {
    foreach ($f in 'New-UpdLine', 'Get-UpdTime', 'Get-UpdState') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'ConvertFrom-AzlSonarUpdateEvent (the log line)' {
    It 'leads with the event time, names node, state, step, evidence and next action, and carries the event level' {
        $l = InModuleScope AzlSonar -Parameters @{ L = (New-UpdLine -At (Get-UpdTime 0) -State InstallFailed -Step Install -Evidence 'The update failed at step 3.' -Level Error -NextAction 'Read the update run.') } { param($L) ConvertFrom-AzlSonarUpdateEvent -Line $L }
        $l.file | Should -Be 'update-events'
        $l.level | Should -Be 'error'
        $l.text | Should -BeLike '2026-11-24T12:00:00.000Z `[update`] `* InstallFailed (Install): The update failed at step 3. -> next: Read the update run.'
    }
    It 'ignores a line that is not an event: blank, not JSON, no state, another stage' -TestCases @(
        @{ Line = '' }, @{ Line = 'not json' }, @{ Line = '{"node":"*"}' }, @{ Line = '{"node":"*","state":"RunStarted","stage":"ArmDeployment"}' }
    ) {
        InModuleScope AzlSonar -Parameters @{ L = $Line } { param($L) ConvertFrom-AzlSonarUpdateEvent -Line $L } | Should -BeNullOrEmpty
    }
}

Describe 'the offline update view' {
    It 'a WhatIf run: stages in order, success, nothing installed, the update named' {
        $s = Get-UpdState -Line $script:PlanRun
        $s.hasData | Should -BeTrue
        $s.status | Should -Be 'success'
        $s.plan | Should -BeTrue
        $s.phase | Should -Be 'available'
        @($s.tree | ForEach-Object id) | Should -Be @('upd.Discover', 'upd.Prerequisites', 'upd.Install')
        @($s.tree | ForEach-Object status) | Should -Be @('success', 'success', 'skipped')
        $s.run.update | Should -Be 'Solution12.2611.1004.9'
        $s.run.version | Should -Be '12.2611.1004.9'
        $s.run.exitCode | Should -Be 0
        $s.label | Should -BeLike 'Plan complete for Solution12.2611.1004.9 (12.2611.1004.9); nothing was installed*'
    }
    It 'an install that is running shows the running stage and its progress' {
        $s = Get-UpdState -Line @(
            (New-UpdLine -At (Get-UpdTime 0) -State RunStarted)
            (New-UpdLine -At (Get-UpdTime 1) -State InstallStarted -Step Install -Evidence 'Started.' -Extra @{ updateName = 'Solution12.2611.1004.9' })
            (New-UpdLine -At (Get-UpdTime 9) -State InstallProgress -Step Install -Evidence '40 percent.' -Extra @{ progressPercentage = 40 })
        )
        $s.status | Should -Be 'running'
        $s.phase | Should -Be 'installing'
        $s.tree[0].status | Should -Be 'running'
        $s.tree[0].progressPercentage | Should -Be 40
        $s.tree[0].start | Should -Be '2026-11-24T12:01:00.000Z' -Because 'the stage keeps the time it started'
    }
    It 'a failed run is an error with its message and next action' {
        $s = Get-UpdState -Line @(
            (New-UpdLine -At (Get-UpdTime 0) -State RunStarted)
            (New-UpdLine -At (Get-UpdTime 1) -State InstallFailed -Step Install -Level Error -Evidence 'The update run failed.' -NextAction 'Run Get-SolutionUpdateRun.')
            (New-UpdLine -At (Get-UpdTime 2) -State RunCompleted -Level Error -Extra @{ exitCode = 1 })
        )
        $s.status | Should -Be 'error'
        $s.phase | Should -Be 'failed'
        $s.tree[0].errors | Should -Be @('The update run failed.')
        $s.run.nextAction | Should -Be 'Run Get-SolutionUpdateRun.'
    }
    It 'a new RunStarted starts over; a line of an older run is counted, not shown' {
        $s = Get-UpdState -Line @($script:PlanRun + @(
                (New-UpdLine -At (Get-UpdTime 10) -State RunStarted -RunId 'u2')
                (New-UpdLine -At (Get-UpdTime 11) -State UpdateDiscovered -RunId 'u1' -Step Discover)
                (New-UpdLine -At (Get-UpdTime 12) -State InstallStarted -RunId 'u2' -Step Install)))
        $s.run.runId | Should -Be 'u2'
        $s.run.stale | Should -Be 1
        @($s.tree | ForEach-Object id) | Should -Be @('upd.Install')
    }
    It 'no events: not started, no data' {
        $s = InModuleScope AzlSonar { Get-AzlSonarUpdateEventState -Store @{} -Config ([pscustomobject]@{ updateEventsPath = '' }) }
        $s.hasData | Should -BeFalse
        $s.configured | Should -BeFalse
        @($s.tree).Count | Should -Be 0
    }
}

Describe 'Merge-AzlSonarUpdateEvent: Azure first, the events when Azure has no run' {
    It 'keeps Azure''s update when it has a step tree' {
        $events = Get-UpdState -Line $script:PlanRun
        $azure = [ordered]@{ status = 'running'; tree = @([ordered]@{ id = '1'; name = 'Azure step'; status = 'running' }); source = 'azure' }
        $m = InModuleScope AzlSonar -Parameters @{ U = $azure; E = $events } { param($U, $E) Merge-AzlSonarUpdateEvent -Update $U -Events $E }
        $m.tree[0].name | Should -Be 'Azure step'
    }
    It 'fills the update from the events when Azure has none, and marks it unverified' {
        $events = Get-UpdState -Line $script:PlanRun
        $m = InModuleScope AzlSonar -Parameters @{ E = $events } { param($E) Merge-AzlSonarUpdateEvent -Update $null -Events $E }
        $m.source | Should -Be 'events'
        $m.verified | Should -BeFalse
        $m.ran | Should -BeFalse -Because 'a WhatIf run installs nothing'
        @($m.tree).Count | Should -Be 3
    }
    It 'builds an events-sourced update again from newer events (a failed poll keeps the previous state)' {
        $old = InModuleScope AzlSonar -Parameters @{ E = (Get-UpdState -Line @($script:PlanRun[0], $script:PlanRun[1])) } { param($E) Merge-AzlSonarUpdateEvent -Update $null -Events $E }
        $newer = Get-UpdState -Line $script:PlanRun
        $m = InModuleScope AzlSonar -Parameters @{ U = $old; E = $newer } { param($U, $E) Merge-AzlSonarUpdateEvent -Update $U -Events $E }
        @($m.tree).Count | Should -Be 3
        $m.status | Should -Be 'success'
    }
}

Describe 'the config key, the master file default and the monitor plan' {
    It 'derives updateEventsPath in the events folder from the master file' {
        $c = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $c.updateEventsPath | Should -Match 'update-events\.jsonl$'
        (Split-Path $c.updateEventsPath -Parent) | Should -Be (Split-Path $c.armEventsPath -Parent)
    }
    It 'reads updateEventsPath from a config file, relative to its folder, and refuses an empty value' {
        $cfg = New-SonarConfigObject
        $cfg | Add-Member -NotePropertyName updateEventsPath -NotePropertyValue './events/update-events.jsonl' -Force
        $path = Join-Path $TestDrive 'upd.json'
        Set-Content -LiteralPath $path -Value (ConvertTo-SonarConfigJson $cfg) -Encoding utf8
        (Read-AzlSonarConfig -Path $path).updateEventsPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'events/update-events.jsonl')))
        $cfg.updateEventsPath = ' '
        @(Test-AzlSonarConfig -Config $cfg) -join ' ' | Should -Match 'updateEventsPath'
    }
    It 'is read by the Auto and Update monitors only' -TestCases @(
        @{ Name = 'Auto'; On = $true }, @{ Name = 'Update'; On = $true }, @{ Name = 'Validate'; On = $false }, @{ Name = 'Discovery'; On = $false }, @{ Name = 'OsConfiguration'; On = $false }
    ) {
        (InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Get-AzlSonarMonitorPlan -Monitor $N }).updateEvents | Should -Be $On
    }
}

Describe 'the Update monitor with no Azure: a failed poll still shows the update events' {
    It 'fills update and updateEvents from the store when no Azure call works (no Az context)' {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'Run Connect-AzAccount to login.' }
        $cfg = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $cfg | Add-Member -NotePropertyName monitor -NotePropertyValue 'Update' -Force
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg; L = $script:PlanRun } {
            param($C, $L)
            $shared = Initialize-AzlSonarSharedState
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $shared['UpdateEvents'] -Line $x }
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            $shared.State
        }
        $state.updateEvents.hasData | Should -BeTrue
        $state.update.source | Should -Be 'events'
        @($state.update.tree).Count | Should -Be 3
    }
}
