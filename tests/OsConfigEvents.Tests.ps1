#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The OS configuration mode: the event reader and store, the state builder, the config key, the server state shape.
# No Azure, no node: the event file is a temp file, ARM calls are mocked.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule

    # One event line of the contract (pmo/azure-local/os-configuration-design.md section 6).
    function global:New-OscLine {
        param([string]$At, [string]$Node, [string]$State, [string]$Step = '', [string]$Evidence = '', [string]$Level = 'Info', [string]$Method = '', [string]$Transport = '', [hashtable]$Extra = @{})
        $o = [ordered]@{ timestamp = $At; node = $Node; stage = 'OsConfiguration'; step = $Step; state = $State; evidence = $Evidence; level = $Level; nextAction = ''; method = $Method; transport = $Transport; payloadVersion = '1'; schemaVersion = '5.3.0' }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        $o | ConvertTo-Json -Compress -Depth 6
    }
    $script:T0 = [datetime]::SpecifyKind([datetime]'2026-11-07T19:00:00', 'Utc')
    function global:Get-OscTime([double]$Minutes) { $script:T0.AddMinutes($Minutes).ToString('o', [cultureinfo]::InvariantCulture) }
}

AfterAll {
    foreach ($f in 'New-OscLine', 'Get-OscTime') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'ConvertFrom-AzlSonarOsConfigEvent (the log line)' {
    It 'leads with the event UTC time, names the node, state and step, and keeps evidence and next action' {
        $line = New-OscLine -At '2026-11-07T19:01:59.5360000Z' -Node 'n1' -State StepApplying -Step Dns -Evidence 'Changing: Dns: a -> b' -Method Ztp -Transport WinRM -Extra @{ nextAction = 'wait' }
        $r = InModuleScope AzlSonar -Parameters @{ L = $line } { param($L) ConvertFrom-AzlSonarOsConfigEvent -Line $L }
        $r.file | Should -Be 'os-config-events'
        $r.text | Should -Be '2026-11-07T19:01:59.536Z [osconfig] n1 StepApplying (Dns): Changing: Dns: a -> b -> next: wait'
    }
    It 'makes the level visible to the log pane' {
        $e = InModuleScope AzlSonar -Parameters @{ L = (New-OscLine -At '2026-11-07T19:00:00Z' -Node n1 -State NodeFailed -Evidence 'no route' -Level Error) } { param($L) ConvertFrom-AzlSonarOsConfigEvent -Line $L }
        $w = InModuleScope AzlSonar -Parameters @{ L = (New-OscLine -At '2026-11-07T19:00:00Z' -Node n1 -State MethodResolved -Evidence 'differs' -Level Warning) } { param($L) ConvertFrom-AzlSonarOsConfigEvent -Line $L }
        $e.text | Should -Match '\(error\)$'
        $w.text | Should -Match '\(warning\)$'
    }
    It 'skips what is not an event: garbage, a half line, no node or state, another stage' {
        InModuleScope AzlSonar {
            ConvertFrom-AzlSonarOsConfigEvent -Line 'garbage' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarOsConfigEvent -Line '{"node":"n1","state":' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarOsConfigEvent -Line '{"node":"n1"}' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarOsConfigEvent -Line '{"state":"X"}' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarOsConfigEvent -Line '[1,2]' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarOsConfigEvent -Line '{"node":"n1","state":"Mounted","stage":"Bootstrap"}' | Should -BeNullOrEmpty
            ConvertFrom-AzlSonarOsConfigEvent -Line '' | Should -BeNullOrEmpty
        }
    }
    It 'reads the timestamp as UTC whatever the culture of the machine is' {
        $line = New-OscLine -At '2026-11-07T19:01:59.5360000Z' -Node n1 -State NodeStarted
        $text = InModuleScope AzlSonar -Parameters @{ L = $line } {
            param($L)
            $old = [cultureinfo]::CurrentCulture
            try { [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE'); (ConvertFrom-AzlSonarOsConfigEvent -Line $L).text }
            finally { [cultureinfo]::CurrentCulture = $old }
        }
        $text | Should -Match '^2026-11-07T19:01:59\.536Z '
    }
    It 'accepts a timestamp without a zone as UTC' {
        $r = InModuleScope AzlSonar { ConvertFrom-AzlSonarOsConfigEvent -Line '{"timestamp":"2026-11-07T19:00:00","node":"n1","state":"NodeStarted"}' }
        $r.text | Should -Match '^2026-11-07T19:00:00\.000Z '
    }
}

Describe 'Read-AzlSonarOsConfigEventChunk' {
    It 'reads complete lines, leaves a partial last line for the next poll and returns nothing for a missing file' {
        $file = Join-Path $TestDrive 'chunk.jsonl'
        [IO.File]::WriteAllText($file, "{`"a`":1}`n{`"b`":2}`n{`"c`"")
        $r = InModuleScope AzlSonar -Parameters @{ F = $file } { param($F) Read-AzlSonarOsConfigEventChunk -Path $F -Offset 0 }
        @($r.Lines).Count | Should -Be 2
        $r.Truncated | Should -BeFalse
        [IO.File]::AppendAllText($file, ":3}`n")
        $r2 = InModuleScope AzlSonar -Parameters @{ F = $file; O = $r.Offset } { param($F, $O) Read-AzlSonarOsConfigEventChunk -Path $F -Offset $O }
        @($r2.Lines) | Should -Be @('{"c":3}')
        $m = InModuleScope AzlSonar -Parameters @{ F = (Join-Path $TestDrive 'none.jsonl') } { param($F) Read-AzlSonarOsConfigEventChunk -Path $F -Offset 0 }
        @($m.Lines).Count | Should -Be 0
    }
    It 'says so when the file got smaller (replaced), and reads it from the start' {
        $file = Join-Path $TestDrive 'small.jsonl'
        [IO.File]::WriteAllText($file, "{`"a`":1}`n")
        $r = InModuleScope AzlSonar -Parameters @{ F = $file } { param($F) Read-AzlSonarOsConfigEventChunk -Path $F -Offset 9999 }
        $r.Truncated | Should -BeTrue
        @($r.Lines).Count | Should -Be 1
    }
    It 'reads a file the writer still has open for appending' {
        $file = Join-Path $TestDrive 'open.jsonl'
        $writer = [IO.File]::Open($file, 'Append', 'Write', 'ReadWrite')
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes("{`"a`":1}`n"); $writer.Write($bytes, 0, $bytes.Length); $writer.Flush()
            $r = InModuleScope AzlSonar -Parameters @{ F = $file } { param($F) Read-AzlSonarOsConfigEventChunk -Path $F -Offset 0 }
            @($r.Lines).Count | Should -Be 1
        }
        finally { $writer.Dispose() }
    }
}

Describe 'Add-AzlSonarOsConfigEvent (the store: attempts and runs)' {
    BeforeEach {
        $script:Store = [hashtable]::Synchronized(@{})
        $script:Feed = {
            param($Lines)
            InModuleScope AzlSonar -Parameters @{ S = $script:Store; L = @($Lines) } { param($S, $L) foreach ($x in $L) { Add-AzlSonarOsConfigEvent -Store $S -Line $x } }
        }
    }
    It 'keeps the events of a node in file order, with the method and transport as the events say' {
        & $script:Feed @(
            (New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1', 'n2'); mode = 'Apply' }),
            (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State NodeStarted),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State MethodResolved -Method Ztp -Transport ArcRunCommand -Extra @{ declared = 'simplified'; declaredMethod = 'Ztp'; mismatch = $false }),
            (New-OscLine -At (Get-OscTime 0.3) -Node n1 -State StepPlanned -Step Dns -Extra @{ action = 'Change'; current = 'a'; desired = 'b' }))
        @($script:Store['n1'].Events).state | Should -Be @('NodeStarted', 'MethodResolved', 'StepPlanned')
        $script:Store['n1'].Attempt | Should -Be 1
        $script:Store['*'].Mode | Should -Be 'Apply'
        @($script:Store['*'].Nodes) | Should -Be @('n1', 'n2')
    }
    It 'a node attempt restarts on its next NodeStarted, by line order, not by the clock' {
        & $script:Feed @(
            (New-OscLine -At (Get-OscTime 5) -Node n1 -State NodeStarted),
            (New-OscLine -At (Get-OscTime 6) -Node n1 -State StepFailed -Step Dns -Level Error -Evidence 'boom'),
            (New-OscLine -At (Get-OscTime 1) -Node n1 -State NodeStarted),   # an earlier clock time, but a later line: the new attempt
            (New-OscLine -At (Get-OscTime 2) -Node n1 -State StepPlanned -Step Dns -Extra @{ action = 'Ok' }))
        @($script:Store['n1'].Events).state | Should -Be @('NodeStarted', 'StepPlanned')
        $script:Store['n1'].Attempt | Should -Be 2
    }
    It 'a run-wide RunStarted with a nodes array clears exactly those nodes' {
        & $script:Feed @(
            (New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 0) -Node n2 -State NodeStarted), (New-OscLine -At (Get-OscTime 0) -Node n3 -State NodeStarted),
            (New-OscLine -At (Get-OscTime 1) -Node '*' -State RunStarted -Extra @{ nodes = @('n1', 'n2') }))
        $script:Store.Contains('n1') | Should -BeFalse
        $script:Store.Contains('n2') | Should -BeFalse
        $script:Store.Contains('n3') | Should -BeTrue
        @($script:Store['*'].Nodes) | Should -Be @('n1', 'n2')
    }
    It 'a RunStarted with one node name (a one-item array) and one without a nodes array' {
        & $script:Feed @((New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 1) -Node '*' -State RunStarted -Extra @{ nodes = @('n1') }))
        $script:Store.Contains('n1') | Should -BeFalse
        & $script:Feed @((New-OscLine -At (Get-OscTime 2) -Node n2 -State NodeStarted), (New-OscLine -At (Get-OscTime 3) -Node '*' -State RunStarted))
        $script:Store.Contains('n2') | Should -BeTrue -Because 'no nodes array: nothing is cleared'
        @($script:Store['*'].Nodes).Count | Should -Be 0
    }
    It 'ignores malformed lines and counts nothing for them' {
        & $script:Feed @('nonsense', '{"node":"n1"}', '{"node":"n1","state":"NodeStarted","timestamp":"2026-11-07T19:00:00Z"}', '{broken')
        @($script:Store.Keys | Where-Object { $_ -ne '*' }) | Should -Be @('n1')
        @($script:Store['n1'].Events).Count | Should -Be 1
    }
    It 'records the plan, the wipe list and the completion on the run entry' {
        & $script:Feed @(
            (New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1'); mode = 'Apply'; cluster = 'c1'; wrapperVersion = '1.0.0' }),
            (New-OscLine -At (Get-OscTime 1) -Node '*' -State PlanCompleted -Extra @{ changes = 4; blocked = 1 }),
            (New-OscLine -At (Get-OscTime 1) -Node '*' -State WipeListPublished -Extra @{ wipeCount = 1; clearStorage = $true; wipe = @(@{ node = 'n1'; disks = '3 disks' }) }),
            (New-OscLine -At (Get-OscTime 9) -Node '*' -State RunCompleted -Extra @{ exitCode = 0; converged = 1; total = 1; mode = 'Apply' }))
        $run = $script:Store['*']
        $run.PlanChanges | Should -Be 4
        $run.PlanBlocked | Should -Be 1
        $run.Wipe.Count | Should -Be 1
        @($run.Wipe.Nodes)[0].node | Should -Be 'n1'
        $run.ExitCode | Should -Be 0
        $run.Completed | Should -Not -BeNullOrEmpty
        $run.WrapperVersion | Should -Be '1.0.0'
        $run.SchemaVersion | Should -Be '5.3.0'
    }
    It 'each change stores a new object: a reader holding the old one never sees it change' {
        & $script:Feed @((New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted))
        $held = $script:Store['n1']
        & $script:Feed @((New-OscLine -At (Get-OscTime 1) -Node n1 -State StepPlanned -Step Dns))
        @($held.Events).Count | Should -Be 1
        @($script:Store['n1'].Events).Count | Should -Be 2
        [object]::ReferenceEquals($held, $script:Store['n1']) | Should -BeFalse
    }
    It 'keeps at most 600 events per node, the first two always' {
        $lines = @((New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 0) -Node n1 -State MethodResolved)) + @(1..650 | ForEach-Object { New-OscLine -At (Get-OscTime 1) -Node n1 -State StepPlanned -Step Dns -Evidence "e$_" })
        & $script:Feed $lines
        @($script:Store['n1'].Events).Count | Should -Be 600
        @($script:Store['n1'].Events)[0].state | Should -Be 'NodeStarted'
        @($script:Store['n1'].Events)[1].state | Should -Be 'MethodResolved'
        @($script:Store['n1'].Events)[-1].evidence | Should -Be 'e650'
    }
}

Describe 'Get-AzlSonarOsConfigurationState (the state builder)' {
    BeforeAll {
        $script:Cfg = [pscustomobject]@{ osConfigEventsPath = 'x'; nodes = @([pscustomobject]@{ name = 'n1' }, [pscustomobject]@{ name = 'n2' }) }
        $script:Build = {
            param($Lines, $Route = 'simplified', $Ztp = @(), $Config = $script:Cfg)
            InModuleScope AzlSonar -Parameters @{ L = @($Lines); C = $Config; R = $Route; Z = @($Ztp) } {
                param($L, $C, $R, $Z)
                $store = [hashtable]::Synchronized(@{})
                foreach ($x in $L) { Add-AzlSonarOsConfigEvent -Store $store -Line $x }
                Get-AzlSonarOsConfigurationState -Store $store -Config $C -ExpectedRoute $R -ZtpNode $Z
            }
        }
        $script:Step = { param($Node, $Name) @($Node.tree | Where-Object { $_.osc.step -eq $Name })[0] }
    }
    It 'with no event: waiting machines show the method they are expected to use, and nothing is converged' {
        $s = & $script:Build @() 'simplified'
        $s.configured | Should -BeTrue
        $s.status | Should -Be 'notstarted'
        $s.state | Should -Be 'waiting'
        $s.ready | Should -BeFalse
        @($s.nodes).Count | Should -Be 2
        $s.nodes[0].method | Should -Be 'Ztp'
        $s.nodes[0].methodSource | Should -Be 'expected'
        (& $script:Build @() 'oem-image').nodes[0].method | Should -Be 'Iso'
        (& $script:Build @() '' @('n2')).nodes[1].method | Should -Be 'Ztp'
        (& $script:Build @() '').nodes[0].method | Should -Be ''
        @($s.nodes[0].tree).Count | Should -Be 14
        @($s.nodes[0].tree | Where-Object { $_.osc.verifyOnly }).osc.step | Should -Be @('Hostname', 'ArcRegistration')
    }
    It 'is not configured without osConfigEventsPath' {
        $s = & $script:Build @() 'simplified' @() ([pscustomobject]@{ nodes = @([pscustomobject]@{ name = 'n1' }) })
        $s.configured | Should -BeFalse
    }
    It 'resolves method, transport, declaration and versions from the events; a disagreement is a warning' {
        $s = & $script:Build @(
            (New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1', 'n2'); mode = 'Apply'; cluster = 'c1'; wrapperVersion = '1.0.0' }),
            (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State NodeStarted),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State MethodResolved -Method Iso -Transport WinRM -Level Warning -Evidence 'declared simplified but no handoff' -Extra @{ declared = 'simplified'; declaredMethod = 'Ztp'; mismatch = $true; sbePublisher = 'Dell'; sbeVersion = '5.0.2606.1616'; sbeDelivery = 'copy over WinRM' }),
            (New-OscLine -At (Get-OscTime 0.3) -Node n1 -State TransportResolved -Transport WinRM -Extra @{ address = '192.0.2.11'; forced = $false }),
            (New-OscLine -At (Get-OscTime 0.5) -Node n1 -State MethodResolved -Method Iso -Transport WinRM -Extra @{ hostname = 'n1'; osVersion = '10.0.26100.1'; build = 26100; osCaption = 'Azure Stack HCI' }))
        $n = $s.nodes[0]
        $n.method | Should -Be 'Iso'
        $n.methodSource | Should -Be 'resolved'
        $n.transport | Should -Be 'WinRM'
        $n.declared | Should -Be 'simplified'
        $n.declaredMethod | Should -Be 'Ztp'
        $n.mismatch | Should -BeTrue
        @($n.warnings).Count | Should -Be 1
        $n.versions.osVersion | Should -Be '10.0.26100.1'
        $n.versions.build | Should -Be '26100'
        $n.versions.osCaption | Should -Be 'Azure Stack HCI'
        $n.versions.sbePublisher | Should -Be 'Dell'
        $n.versions.sbeDelivery | Should -Be 'copy over WinRM'
        $n.versions.schemaVersion | Should -Be '5.3.0'
        $n.versions.wrapperVersion | Should -Be '1.0.0'
        $s.run.wrapperVersion | Should -Be '1.0.0'
        $s.nodes[1].methodSource | Should -Be 'expected'
        @($s.warnings).Count | Should -Be 1
    }
    It 'step stages from the events: planned, ok, changing, applied, verified, failed, not applicable, verify only' {
        $s = & $script:Build @(
            (New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted),
            (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State MethodResolved -Method Ztp -Transport ArcRunCommand),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepPlanned -Step Dns -Evidence 'Change: DNS: a -> b' -Extra @{ action = 'Change'; current = 'a'; desired = 'b'; item = 'DNS' }),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepPlanned -Step Time -Extra @{ action = 'Change'; current = 'x'; desired = 'y' }),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepPlanned -Step Mpio -Extra @{ action = 'Change'; current = 'Disabled'; desired = 'Enabled' }),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepPlanned -Step Network -Extra @{ action = 'Ok'; current = 'static' }),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepPlanned -Step Hostname -Evidence 'Ok: Verify only: n1' -Extra @{ action = 'Ok'; verifyOnly = $true }),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepPlanned -Step LocalAdmin -Extra @{ action = 'Blocked' }),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepSkipped -Step ClearStorage -Evidence 'Not applicable: clear_storage is off'),
            (New-OscLine -At (Get-OscTime 1) -Node n1 -State StepApplying -Step Dns -Extra @{ current = 'a'; desired = 'b' }),
            (New-OscLine -At (Get-OscTime 1.5) -Node n1 -State StepApplied -Step Dns),
            (New-OscLine -At (Get-OscTime 2) -Node n1 -State StepApplying -Step Time),
            (New-OscLine -At (Get-OscTime 2.5) -Node n1 -State StepFailed -Step Time -Level Error -Evidence 'w32tm failed'),
            (New-OscLine -At (Get-OscTime 3) -Node n1 -State StepApplying -Step Mpio),
            (New-OscLine -At (Get-OscTime 3.5) -Node n1 -State StepApplied -Step Mpio),
            (New-OscLine -At (Get-OscTime 4) -Node n1 -State StepVerified -Step Mpio -Extra @{ action = 'Ok' }))
        $n = $s.nodes[0]
        (& $script:Step $n 'Dns').osc.stage | Should -Be 'applied'
        (& $script:Step $n 'Dns').status | Should -Be 'success'
        (& $script:Step $n 'Dns').osc.current | Should -Be 'a'
        (& $script:Step $n 'Dns').osc.desired | Should -Be 'b'
        (& $script:Step $n 'Dns').durationSeconds | Should -Be 30
        (& $script:Step $n 'Time').osc.stage | Should -Be 'failed'
        (& $script:Step $n 'Time').status | Should -Be 'error'
        @((& $script:Step $n 'Time').errors) | Should -Be @('w32tm failed')
        (& $script:Step $n 'Mpio').osc.stage | Should -Be 'verified'
        (& $script:Step $n 'Network').osc.stage | Should -Be 'ok'
        (& $script:Step $n 'Hostname').osc.verifyOnly | Should -BeTrue
        (& $script:Step $n 'LocalAdmin').osc.stage | Should -Be 'blocked'
        (& $script:Step $n 'ClearStorage').osc.stage | Should -Be 'skipped'
        (& $script:Step $n 'ClearStorage').osc.notApplicable | Should -BeTrue
        (& $script:Step $n 'RemoteManagement').osc.stage | Should -Be 'waiting'
        $n.changes | Should -Be 0
        $n.blocked | Should -Be 1
    }
    It 'node states: planning, planned, applying, retrying, reconnecting, converged, failed, blocked; retries and restarts are counted' {
        $base = @(
            (New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1', 'n2'); mode = 'Apply' }),
            (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State MethodResolved -Method Ztp -Transport ArcRunCommand))
        (& $script:Build $base).nodes[0].state | Should -Be 'planning'
        $planned = $base + @((New-OscLine -At (Get-OscTime 1) -Node n1 -State StepPlanned -Step Dns -Extra @{ action = 'Change' }), (New-OscLine -At (Get-OscTime 1) -Node '*' -State PlanCompleted -Extra @{ changes = 1; blocked = 0 }))
        (& $script:Build $planned).nodes[0].state | Should -Be 'applying' -Because 'the plan is done and the run applies'
        $applying = $planned + @((New-OscLine -At (Get-OscTime 2) -Node n1 -State StepApplying -Step Dns))
        $s = & $script:Build $applying
        $s.nodes[0].state | Should -Be 'applying'
        $s.nodes[0].currentStep | Should -Be 'Dns'
        $s.status | Should -Be 'running'
        $retry = $applying + @((New-OscLine -At (Get-OscTime 2.1) -Node n1 -State NodeRetry -Level Warning -Extra @{ try = 1; tries = 3 }))
        $r = & $script:Build $retry
        $r.nodes[0].state | Should -Be 'retrying'
        $r.nodes[0].retries | Should -Be 1
        $r.nodesRetrying | Should -Be 1
        $reconn = $applying + @((New-OscLine -At (Get-OscTime 2.1) -Node n1 -State NodeReconnecting), (New-OscLine -At (Get-OscTime 2.3) -Node n1 -State NodeReconnected), (New-OscLine -At (Get-OscTime 2.4) -Node n1 -State NodeRestarting))
        $x = & $script:Build $reconn
        $x.nodes[0].restarts | Should -Be 2
        $x.nodes[0].state | Should -Be 'reconnecting' -Because 'a legacy NodeRestarting counts as reconnecting'
        $conv = $applying + @((New-OscLine -At (Get-OscTime 3) -Node n1 -State NodeConverged))
        (& $script:Build $conv).nodes[0].state | Should -Be 'converged'
        (& $script:Build $conv).nodes[0].status | Should -Be 'success'
        (& $script:Build $conv).ready | Should -BeFalse -Because 'n2 has not converged'
        $fail = $applying + @((New-OscLine -At (Get-OscTime 3) -Node n1 -State NodeFailed -Level Error -Evidence 'it broke'))
        $f = & $script:Build $fail
        $f.nodes[0].state | Should -Be 'failed'
        $f.nodes[0].status | Should -Be 'error'
        @($f.nodes[0].errors) | Should -Be @('it broke')
        $f.status | Should -Be 'error'
        $f.nodesFailed | Should -Be 1
        (& $script:Build ($applying + @((New-OscLine -At (Get-OscTime 3) -Node n1 -State NodeBlocked -Level Warning -Evidence 'wait')))).nodes[0].state | Should -Be 'blocked'
    }
    It 'ready only when every node has NodeConverged; Plan mode completion with changes pending is planned, not converged' {
        $both = @(
            (New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1', 'n2'); mode = 'Apply' }),
            (New-OscLine -At (Get-OscTime 1) -Node n1 -State NodeConverged), (New-OscLine -At (Get-OscTime 1) -Node n2 -State NodeConverged),
            (New-OscLine -At (Get-OscTime 2) -Node '*' -State RunCompleted -Extra @{ exitCode = 0; converged = 2; total = 2; mode = 'Apply' }))
        $s = & $script:Build $both
        $s.ready | Should -BeTrue
        $s.status | Should -Be 'success'
        $s.state | Should -Be 'converged'
        $s.nodesConverged | Should -Be 2
        $plan = @(
            (New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1', 'n2'); mode = 'Plan' }),
            (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State StepPlanned -Step Dns -Extra @{ action = 'Change' }), (New-OscLine -At (Get-OscTime 0.1) -Node n2 -State NodeStarted),
            (New-OscLine -At (Get-OscTime 1) -Node '*' -State PlanCompleted -Extra @{ changes = 2; blocked = 0 }),
            (New-OscLine -At (Get-OscTime 1) -Node '*' -State RunCompleted -Extra @{ exitCode = 0; converged = 0; total = 2; mode = 'Plan' }))
        $p = & $script:Build $plan
        $p.ready | Should -BeFalse
        $p.state | Should -Be 'planned'
        $p.status | Should -Be 'notstarted'
        $p.nodes[0].state | Should -Be 'planned'
        $p.nodes[0].stateText | Should -Be 'Planned: 1 change pending'
    }
    It 'the guarded network change: AwaitingConfirm with its window, Committed, RolledBack with the node reason, Refused, Repaired' {
        $head = @((New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State MethodResolved -Method Iso -Transport WinRM),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepPlanned -Step Network -Extra @{ action = 'Change'; current = 'dhcp'; desired = 'static' }),
            (New-OscLine -At (Get-OscTime 1) -Node n1 -State StepApplying -Step Network),
            (New-OscLine -At (Get-OscTime 1) -Node n1 -State NetworkChangeStaged -Step Network -Extra @{ changeId = 'c1' }),
            (New-OscLine -At (Get-OscTime 1.5) -Node n1 -State NetworkChangeVerifying -Step Network))
        $await = $head + @((New-OscLine -At (Get-OscTime 2) -Node n1 -State NetworkChangeAwaitingConfirm -Step Network -Extra @{ confirmMinutes = 10 }))
        $n = (& $script:Build $await).nodes[0]
        $n.state | Should -Be 'awaitingconfirm'
        $n.guarded | Should -Be 'AwaitingConfirm'
        $net = & $script:Step $n 'Network'
        $net.osc.stage | Should -Be 'changing'
        $net.osc.guarded.state | Should -Be 'AwaitingConfirm'
        $net.osc.guarded.confirmMinutes | Should -Be 10
        $net.osc.guarded.confirmBy | Should -Be '2026-11-07T19:12:00Z' -Because 'the window starts at the AwaitingConfirm event'
        $withBy = $head + @((New-OscLine -At (Get-OscTime 2) -Node n1 -State NetworkChangeAwaitingConfirm -Step Network -Extra @{ confirmBy = '2026-11-07T19:09:30.0000000Z' }))
        (& $script:Step (& $script:Build $withBy).nodes[0] 'Network').osc.guarded.confirmBy | Should -Be '2026-11-07T19:09:30Z'
        $committed = $await + @((New-OscLine -At (Get-OscTime 3) -Node n1 -State NetworkChangeCommitted -Step Network))
        $c = & $script:Step (& $script:Build $committed).nodes[0] 'Network'
        $c.osc.stage | Should -Be 'applied'
        $c.osc.guarded.state | Should -Be 'Committed'
        $repaired = $head + @((New-OscLine -At (Get-OscTime 2) -Node n1 -State NetworkChangeRepaired -Step Network -Extra @{ rung = 2 }))
        $rp = & $script:Step (& $script:Build $repaired).nodes[0] 'Network'
        $rp.osc.guarded.rung | Should -Be '2'
        $rp.osc.guarded.repairs | Should -Be 1
        $rolled = $await + @((New-OscLine -At (Get-OscTime 4) -Node n1 -State NetworkChangeRolledBack -Step Network -Level Error -Evidence 'rolled back' -Extra @{ reason = 'The gateway did not answer for 60 s; the snapshot was restored.' }))
        $rb = (& $script:Build $rolled).nodes[0]
        $rb.state | Should -Be 'rolledback'
        $rb.status | Should -Be 'error'
        $rb.stateText | Should -Match 'The gateway did not answer'
        (& $script:Step $rb 'Network').osc.stage | Should -Be 'rolledback'
        (& $script:Step $rb 'Network').osc.guarded.reason | Should -Match 'snapshot was restored'
        @((& $script:Step $rb 'Network').errors)[0] | Should -Match 'gateway'
        (& $script:Build $rolled).nodesFailed | Should -Be 1
        $refused = @((New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 1) -Node n1 -State NetworkChangeRefused -Step Network -Level Error -Evidence 'management MAC not found on the node'))
        $rf = (& $script:Build $refused).nodes[0]
        $rf.state | Should -Be 'refused'
        (& $script:Step $rf 'Network').osc.stage | Should -Be 'refused'
        $failedAfter = $rolled + @((New-OscLine -At (Get-OscTime 5) -Node n1 -State NodeFailed -Level Error -Evidence 'the node rolled back'))
        (& $script:Build $failedAfter).nodes[0].state | Should -Be 'failed'
    }
    It 'transport is per step: a step event carries its own transport and the Arc badge follows it' {
        $s = & $script:Build @(
            (New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State MethodResolved -Method Ztp -Transport WinRM),
            (New-OscLine -At (Get-OscTime 0.2) -Node n1 -State StepApplying -Step Dns -Transport WinRM),
            (New-OscLine -At (Get-OscTime 0.3) -Node n1 -State StepApplying -Step RemoteManagement -Transport ArcRunCommand))
        $n = $s.nodes[0]
        (& $script:Step $n 'Dns').osc.transport | Should -Be 'WinRM'
        (& $script:Step $n 'Dns').osc.arc | Should -BeFalse
        (& $script:Step $n 'RemoteManagement').osc.transport | Should -Be 'ArcRunCommand'
        (& $script:Step $n 'RemoteManagement').osc.arc | Should -BeTrue
    }
    It 'wipe list: pending until the listed node has cleared its storage' {
        $head = @((New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1', 'n2'); mode = 'Apply' }),
            (New-OscLine -At (Get-OscTime 1) -Node '*' -State WipeListPublished -Level Warning -Extra @{ wipeCount = 1; clearStorage = $true; wipe = @(@{ node = 'n2'; disks = '3 disks (1000 GB)' }) }),
            (New-OscLine -At (Get-OscTime 1) -Node n2 -State NodeStarted), (New-OscLine -At (Get-OscTime 1) -Node n2 -State StepPlanned -Step ClearStorage -Extra @{ action = 'Change' }))
        $s = & $script:Build $head
        $s.wipe.published | Should -BeTrue
        $s.wipe.enabled | Should -BeTrue
        $s.wipe.pending | Should -BeTrue
        $s.wipe.nodes[0].node | Should -Be 'n2'
        $s.wipe.nodes[0].disks | Should -Be '3 disks (1000 GB)'
        $done = $head + @((New-OscLine -At (Get-OscTime 2) -Node n2 -State StepApplying -Step ClearStorage), (New-OscLine -At (Get-OscTime 3) -Node n2 -State StepApplied -Step ClearStorage))
        (& $script:Build $done).wipe.pending | Should -BeFalse
    }
    It 'masks secrets in evidence' {
        $s = & $script:Build @((New-OscLine -At (Get-OscTime 0) -Node n1 -State NodeStarted), (New-OscLine -At (Get-OscTime 1) -Node n1 -State StepFailed -Step LocalAdmin -Level Error -Evidence 'failed: password = Sup3rSecret!x'))
        ($s | ConvertTo-Json -Depth 12) | Should -Not -Match 'Sup3rSecret'
    }
    It 'serialises to JSON the page can read (arrays stay arrays, no dates as objects)' {
        $s = & $script:Build @((New-OscLine -At (Get-OscTime 0) -Node '*' -State RunStarted -Extra @{ nodes = @('n1') }), (New-OscLine -At (Get-OscTime 0.1) -Node n1 -State NodeStarted))
        $json = InModuleScope AzlSonar -Parameters @{ S = $s } { param($S) ConvertTo-AzlSonarJson ([ordered]@{ osConfiguration = $S }) }
        $o = $json | ConvertFrom-Json -Depth 20
        $o.osConfiguration.nodes[0].tree.Count | Should -Be 14
        $o.osConfiguration.nodes[0].warnings -is [array] | Should -BeTrue
        $o.osConfiguration.nodes[0].tree[0].children -is [array] | Should -BeTrue
    }
}

Describe 'Get-AzlSonarOsConfigRunCommand (read-only GET of the run commands)' {
    It 'lists the toolkit run commands with state and age, and marks one stuck in Creating' {
        $now = [datetime]::SpecifyKind([datetime]'2026-11-07T20:00:00', 'Utc')
        $body = [pscustomobject]@{ value = @(
                [pscustomobject]@{ name = 'azl-osconfig-aaaa'; properties = [pscustomobject]@{ provisioningState = 'Creating'; instanceView = $null }; systemData = [pscustomobject]@{ createdAt = '2026-11-07T19:40:00Z' } },
                [pscustomobject]@{ name = 'azl-osconfig-bbbb'; properties = [pscustomobject]@{ provisioningState = 'Succeeded'; instanceView = [pscustomobject]@{ executionState = 'Running'; startTime = '2026-11-07T19:58:00Z' } } },
                [pscustomobject]@{ name = 'someone-elses'; properties = [pscustomobject]@{ provisioningState = 'Creating' } }) }
        $arc = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/node-01'
        $script:Asked = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { $script:Asked.Add($Path); [pscustomobject]@{ StatusCode = 200; Body = $Body; ErrorMessage = $null; ErrorCode = '' } } -ParameterFilter { $true }
        $r = InModuleScope AzlSonar -Parameters @{ Arc = $arc; Now = $now; Body = $body } {
            param($Arc, $Now, $Body)
            $script:BodyForMock = $Body
            Get-AzlSonarOsConfigRunCommand -ArcMachineResourceId $Arc -Now $Now
        }
        $r.Error | Should -Be ''
        @($r.Items).name | Should -Be @('azl-osconfig-aaaa', 'azl-osconfig-bbbb')
        $r.Items[0].stuck | Should -BeTrue
        $r.Items[0].ageMinutes | Should -Be 20
        $r.Items[1].stuck | Should -BeFalse
        $r.Items[1].state | Should -Be 'Running'
        $r.Items[1].ageMinutes | Should -Be 2
    }
    It 'an id that is not an Arc machine is never requested, and a failed read is an error text' {
        $r = InModuleScope AzlSonar { Get-AzlSonarOsConfigRunCommand -ArcMachineResourceId '/subscriptions/x/other/thing' }
        @($r.Items).Count | Should -Be 0
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { throw 'network down' }
        $arc = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/node-01'
        $e = InModuleScope AzlSonar -Parameters @{ Arc = $arc } { param($Arc) Get-AzlSonarOsConfigRunCommand -ArcMachineResourceId $Arc }
        $e.Error | Should -Match 'network down'
    }
    It 'reads only the machines being configured over Arc Run Command, and only while they are not finished' {
        $arc = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/'
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { [pscustomobject]@{ StatusCode = 200; Body = [pscustomobject]@{ value = @([pscustomobject]@{ name = 'azl-osconfig-1'; properties = [pscustomobject]@{ provisioningState = 'Succeeded' } }) }; ErrorMessage = $null; ErrorCode = '' } }
        $map = InModuleScope AzlSonar -Parameters @{ Arc = $arc } {
            param($Arc)
            $store = [hashtable]::Synchronized(@{})
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:00:00Z","node":"viaarc","state":"MethodResolved","method":"Ztp","transport":"ArcRunCommand"}'
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:00:00Z","node":"viawinrm","state":"MethodResolved","method":"Ztp","transport":"WinRM"}'
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:00:00Z","node":"finished","state":"MethodResolved","method":"Ztp","transport":"ArcRunCommand"}'
            Add-AzlSonarOsConfigEvent -Store $store -Line '{"timestamp":"2026-11-07T19:01:00Z","node":"finished","state":"NodeConverged"}'
            $nodes = @('viaarc', 'viawinrm', 'finished', 'noevents') | ForEach-Object { [ordered]@{ name = $_; arcMachineResourceId = $Arc + $_ } }
            Get-AzlSonarOsConfigRunCommandMap -Store $store -ArcNode $nodes
        }
        @($map.Keys) | Should -Be @('viaarc')
    }
}

Describe 'Invoke-AzlSonarOsConfigEventLoop' {
    It 'adds the events to the log pane (file os-config-events) and to the store, then stops when the stop flag is raised' {
        $file = Join-Path $TestDrive 'loop.jsonl'
        [IO.File]::WriteAllText($file, ((New-OscLine -At '2026-11-07T19:00:00Z' -Node n1 -State NodeStarted -Evidence 'looking') + "`n" + (New-OscLine -At '2026-11-07T19:00:05Z' -Node n1 -State StepApplying -Step Dns -Evidence 'changing') + "`n"))
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar { $Shared['Stop'] = $true }
        $r = InModuleScope AzlSonar -Parameters @{ File = $file } {
            param($File)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarOsConfigEventLoop -Shared $shared -Config ([pscustomobject]@{ osConfigEventsPath = $File })
            [pscustomobject]@{ Lines = @((Get-AzlSonarLogWindow -Shared $shared).lines); Events = @($shared['OsConfigEvents']['n1'].Events).Count; Count = $shared['OsConfigInfo']['Count']; Last = $shared['OsConfigInfo']['LastEventAt'] }
        }
        @($r.Lines).Count | Should -Be 2
        $r.Lines[0].file | Should -Be 'os-config-events'
        $r.Lines[1].text | Should -Match '\[osconfig\] n1 StepApplying \(Dns\): changing'
        $r.Events | Should -Be 2
        $r.Count | Should -Be 2
        $r.Last | Should -Be '2026-11-07T19:00:05Z'
    }
    It 'does nothing without a configured event file' {
        $count = InModuleScope AzlSonar { $shared = Initialize-AzlSonarSharedState; Invoke-AzlSonarOsConfigEventLoop -Shared $shared -Config ([pscustomobject]@{ osConfigEventsPath = '' }); @((Get-AzlSonarLogWindow -Shared $shared).lines).Count }
        $count | Should -Be 0
    }
    It 'starts over when the file is replaced by a shorter one' {
        $file = Join-Path $TestDrive 'replaced.jsonl'
        [IO.File]::WriteAllText($file, ((New-OscLine -At '2026-11-07T19:00:00Z' -Node old -State NodeStarted) + "`n"))
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar {
            if (-not $Shared.Contains('Round')) {
                $Shared['Round'] = 1
                $line = '{"timestamp":"2026-11-07T20:00:00Z","node":"new","state":"NodeStarted"}' + "`n"
                [IO.File]::WriteAllText([string]$Shared['ReplacedFile'], $line)
            }
            else { $Shared['Stop'] = $true }
        }
        $keys = InModuleScope AzlSonar -Parameters @{ File = $file } {
            param($File)
            $shared = Initialize-AzlSonarSharedState
            $shared['ReplacedFile'] = $File
            Invoke-AzlSonarOsConfigEventLoop -Shared $shared -Config ([pscustomobject]@{ osConfigEventsPath = $File })
            @($shared['OsConfigEvents'].Keys | Where-Object { $_ -ne '*' })
        }
        $keys | Should -Be @('new')
    }
}

Describe 'osConfigEventsPath in the config' {
    It 'is empty by default and resolved against the config folder when given' {
        $config = New-SonarConfigObject
        $plain = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $config) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $plain.osConfigEventsPath | Should -Be ''
        $config | Add-Member -NotePropertyName osConfigEventsPath -NotePropertyValue './os-configuration-events.jsonl' -Force
        $file = Join-Path $TestDrive 'cfg-os.json'
        Set-Content -LiteralPath $file -Value (ConvertTo-SonarConfigJson $config)
        $read = InModuleScope AzlSonar -Parameters @{ File = $file } { param($File) Read-AzlSonarConfig -Path $File }
        $read.osConfigEventsPath | Should -Be (Join-Path $TestDrive 'os-configuration-events.jsonl')
    }
    It 'rejects an empty or non-text path, like the other path keys' {
        foreach ($bad in ' ', '', 5) {
            $config = New-SonarConfigObject
            $config | Add-Member -NotePropertyName osConfigEventsPath -NotePropertyValue $bad -Force
            $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
            ($problems -match 'osConfigEventsPath') | Should -Not -BeNullOrEmpty -Because "'$bad' is not a path"
        }
    }
    It 'Set-AzlSonarConfig can set it and offers it as a key' {
        $path = Join-Path $TestDrive 'set-os.json'
        Set-Content -LiteralPath $path -Value (ConvertTo-SonarConfigJson (New-SonarConfigObject))
        Set-AzlSonarConfig -Path $path -Key osConfigEventsPath -Value 'D:\osconfig\os-configuration-events.jsonl' 6>$null
        (Get-AzlSonarConfig -Path $path).osConfigEventsPath | Should -Be 'D:\osconfig\os-configuration-events.jsonl'
        @(Set-AzlSonarConfig).Key | Should -Contain 'osConfigEventsPath'
        { Set-AzlSonarConfig -Path $path -Key osConfigEventsPath -Value '   ' 6>$null } | Should -Throw
    }
    It 'is documented in docs/config.md and explained in the commented example (one row per key)' {
        $doc = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/config.md') -Raw
        $example = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'examples/sonar.config.commented.jsonc') -Raw
        ([regex]::Matches($doc, '(?m)^\| `osConfigEventsPath` \|')).Count | Should -Be 1
        $example | Should -Match 'osConfigEventsPath'
    }
    It 'is imported from the master file: the evidence folder next to the ZTP event file' {
        $config = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.toolkit-lom-management-ztp.yml') 3>$null
        $config.ztpEventsPath | Should -Match 'ztp-events\.jsonl$'
        $config.osConfigEventsPath | Should -Match 'os-configuration-events\.jsonl$'
        Split-Path $config.osConfigEventsPath -Parent | Should -Be (Split-Path $config.ztpEventsPath -Parent)
    }
    It 'the Details pop-down names the file and counts its events' {
        $config = New-SonarConfigObject
        $config | Add-Member -NotePropertyName osConfigEventsPath -NotePropertyValue 'D:\x\os-configuration-events.jsonl' -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $config) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $facts = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) New-AzlSonarDetailFact -Config $C }
        $facts.osConfigEventsFile | Should -Be 'os-configuration-events.jsonl'
        @($facts.notSet).setting | Should -Not -Contain 'osConfigEvents'
        $bare = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson (New-SonarConfigObject)) } { param($Json) New-AzlSonarDetailFact -Config (Read-AzlSonarConfig -Json $Json) }
        @($bare.notSet).setting | Should -Contain 'osConfigEvents'
        (@($bare.notSet) | Where-Object setting -eq 'osConfigEvents').key | Should -Be 'osConfigEventsPath'
    }
}

Describe 'the state shape served to the page (/api/state)' {
    It 'the initial state carries an osConfiguration object: not started, every configured node waiting, no events' {
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson (New-SonarConfigObject)) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) Get-AzlSonarInitialState -Config $C }
        $state.Contains('osConfiguration') | Should -BeTrue
        $state.osConfiguration.status | Should -Be 'notstarted'
        $state.osConfiguration.nodesTotal | Should -Be @($cfg.nodes).Count
        @($state.osConfiguration.nodes)[0].tree.Count | Should -Be 14
        $state.osConfiguration.Contains('ready') | Should -BeTrue
    }
    It 'the shared state holds the store and the info counters of the event file' {
        $shared = InModuleScope AzlSonar { Initialize-AzlSonarSharedState }
        $shared.Contains('OsConfigEvents') | Should -BeTrue
        $shared.Contains('OsConfigInfo') | Should -BeTrue
    }
    It 'Get-AzlSonarDeploymentState adds osConfiguration from the store, Provisioning is untouched, and no route to Azure is added without events' {
        $cfgObj = New-SonarConfigObject
        $cfgObj | Add-Member -NotePropertyName osConfigEventsPath -NotePropertyValue 'D:\x\os-configuration-events.jsonl' -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $cfgObj) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $names = @($cfg.nodes | ForEach-Object { $_.name })
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { [pscustomobject]@{ StatusCode = 404; Body = $null; ErrorMessage = 'HTTP 404'; ErrorCode = 'ResourceNotFound' } }
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg; N = $names } {
            param($C, $N)
            $store = [hashtable]::Synchronized(@{})
            Add-AzlSonarOsConfigEvent -Store $store -Line ('{"timestamp":"2026-11-07T19:00:00Z","node":"' + $N[0] + '","state":"NodeConverged"}')
            Get-AzlSonarDeploymentState -Config $C -OsConfigEvents $store
        }
        $state.osConfiguration.configured | Should -BeTrue
        $state.osConfiguration.nodesConverged | Should -Be 1
        $state.osConfiguration.ready | Should -BeFalse
        $state.provisioning.status | Should -Not -Be 'running' -Because 'OS configuration never keeps Provisioning running'
        @($state.osConfiguration.nodes | Where-Object { $_.runCommands.Count -gt 0 }).Count | Should -Be 0
    }
}
