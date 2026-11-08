#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The OS configuration event contract as the toolkit writes it (azurelocal-toolkit scripts/common/node-configuration,
# AzlOsConfigurationEvents.psm1 and its hardening: runId and seq on every line, NodeWaiting heartbeat, one file per run).
# Every state the toolkit can emit has a visible status and message; a state Sonar does not know is shown, never dropped;
# an older run is ignored; events are ordered by seq; the reader ignores fields it does not know and treats a file
# without runId as one legacy run. The event files are temp files: no Azure, no node.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule

    # One event line. -Run and -Seq are the hardening fields; both are left out when not given (an older producer).
    function global:New-OccLine {
        param([string]$At, [string]$Node, [string]$State, [string]$Step = '', [string]$Evidence = '', [string]$Level = 'Info', [string]$Method = '', [string]$Transport = '', [string]$Run = '', $Seq = $null, [hashtable]$Extra = @{})
        $o = [ordered]@{ timestamp = $At; node = $Node; stage = 'OsConfiguration'; step = $Step; state = $State; evidence = $Evidence; level = $Level; nextAction = ''; method = $Method; transport = $Transport; payloadVersion = '1'; schemaVersion = '5.4.0' }
        if ($Run) { $o['runId'] = $Run }
        if ($null -ne $Seq) { $o['seq'] = $Seq }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        $o | ConvertTo-Json -Compress -Depth 6
    }
    $script:T0 = [datetime]::SpecifyKind([datetime]'2026-11-07T19:00:00', 'Utc')
    function global:Get-OccTime([double]$Minutes) { $script:T0.AddMinutes($Minutes).ToString('o', [cultureinfo]::InvariantCulture) }
    # Lines to a store, then the state of the page.
    function global:Get-OccState {
        param([string[]]$Lines, [string[]]$Names = @('n1', 'n2'))
        $cfg = [pscustomobject]@{ osConfigEventsPath = 'x'; nodes = @($Names | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
        InModuleScope AzlSonar -Parameters @{ L = @($Lines); C = $cfg } {
            param($L, $C)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarOsConfigEvent -Store $store -Line $x }
            Get-AzlSonarOsConfigurationState -Store $store -Config $C -ExpectedRoute 'simplified'
        }
    }
    function global:Get-OccStore {
        param([string[]]$Lines)
        InModuleScope AzlSonar -Parameters @{ L = @($Lines) } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarOsConfigEvent -Store $store -Line $x }
            $store
        }
    }
}

AfterAll {
    foreach ($f in 'New-OccLine', 'Get-OccTime', 'Get-OccState', 'Get-OccStore') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'the reader is tolerant' {
    It 'reads runId and seq, and ignores every field it does not know' {
        $line = New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted -Run 'r-1' -Seq 7 -Extra @{ somethingNew = @{ a = 1 }; another = 'x' }
        $e = InModuleScope AzlSonar -Parameters @{ L = $line } { param($L) ConvertFrom-AzlSonarOsConfigLine -Line $L }
        $e.runId | Should -Be 'r-1'
        $e.seq | Should -Be 7
        $e.data.Keys | Should -Contain 'somethingNew'
        $e.data.Keys | Should -Not -Contain 'runId'
        $e.data.Keys | Should -Not -Contain 'seq'
    }
    It 'a line without runId or seq is a legacy line: empty run id, no sequence' {
        $e = InModuleScope AzlSonar -Parameters @{ L = (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted) } { param($L) ConvertFrom-AzlSonarOsConfigLine -Line $L }
        $e.runId | Should -Be ''
        $null -eq $e.seq | Should -BeTrue
    }
    It 'reads a seq written as text and drops one that is not a number' {
        $a = InModuleScope AzlSonar { ConvertFrom-AzlSonarOsConfigLine -Line '{"node":"n1","state":"NodeStarted","seq":"12"}' }
        $b = InModuleScope AzlSonar { ConvertFrom-AzlSonarOsConfigLine -Line '{"node":"n1","state":"NodeStarted","seq":"soon"}' }
        $a.seq | Should -Be 12
        $null -eq $b.seq | Should -BeTrue
    }
    It 'a file without any runId is one legacy run: the state names no run id and says legacy' {
        $s = Get-OccState @((New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted), (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeStarted))
        $s.run.id | Should -Be ''
        $s.run.legacy | Should -BeTrue
        $s.run.staleIgnored | Should -Be 0
        @($s.nodes | Where-Object name -eq 'n1')[0].attempt | Should -Be 1
    }
}

Describe 'every state the toolkit can emit has a visible status and message' {
    BeforeAll {
        # The states of AzlOsConfigurationEvents.psm1 (Get-AzlOsConfigurationEventState), the guard, domain join, remoting and wipe adapters.
        $script:Known = @(
            'RunStarted', 'PlanCompleted', 'WipeListPublished', 'WipeListApproved', 'WipeListRejected', 'RunCompleted',
            'NodeStarted', 'MethodResolved', 'TransportResolved', 'NodeRetry', 'NodeRestarting', 'NodeConverged', 'NodeFailed', 'NodeBlocked', 'NodeReconnecting', 'NodeReconnected', 'NodeWaiting',
            'StepPlanned', 'StepSkipped', 'StepApplying', 'StepApplied', 'StepFailed', 'StepVerified',
            'DomainJoinPlanned', 'DomainJoinApplying', 'DomainJoined', 'DomainAdminsConfigured', 'DomainJoinFailed',
            'NetworkChangeStaged', 'NetworkChangeVerifying', 'NetworkChangeAwaitingConfirm', 'NetworkChangeCommitted', 'NetworkChangeRepaired', 'NetworkChangeRolledBack', 'NetworkChangeRefused',
            'RemotingProfileResolved', 'RemotingFirewallChange', 'RemotingListenerChange', 'RemotingBootstrapStarted', 'RemotingBootstrapSucceeded', 'RemotingBootstrapFailed', 'TrustedHostsChanged', 'TrustedHostsRestored',
            'StaleRunCommandDeleted')
    }
    It 'maps all of them to a label, a group and a status' {
        $bad = InModuleScope AzlSonar -Parameters @{ K = $script:Known } {
            param($K)
            foreach ($s in $K) {
                $i = Get-AzlSonarOsEventInfo -State $s
                if (-not $i.known -or -not $i.label -or -not $i.group -or $i.status -notin 'ok', 'run', 'warn', 'err', 'idle') { $s }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'knows exactly the groups run, node, step, domain, guarded, remoting, transport and wipe' {
        $g = InModuleScope AzlSonar -Parameters @{ K = $script:Known } { param($K) @($K | ForEach-Object { (Get-AzlSonarOsEventInfo -State $_).group } | Sort-Object -Unique) }
        $g | Should -Be @('domain', 'guarded', 'node', 'remoting', 'run', 'step', 'transport', 'wipe')
    }
    It 'the message is the evidence when there is one, else the label; the level colours the status' {
        $r = InModuleScope AzlSonar {
            [pscustomobject]@{
                A = (Get-AzlSonarOsEventInfo -State NodeReconnecting -Evidence 'waiting for n1 on 192.0.2.10')
                B = (Get-AzlSonarOsEventInfo -State NodeReconnecting)
                C = (Get-AzlSonarOsEventInfo -State NodeReconnecting -Level Warning)
                D = (Get-AzlSonarOsEventInfo -State DomainJoined -Level Error)
                E = (Get-AzlSonarOsEventInfo -State NodeFailed)
                F = (Get-AzlSonarOsEventInfo -State NetworkChangeRolledBack -Level Warning)
            }
        }
        $r.A.message | Should -Be 'waiting for n1 on 192.0.2.10'
        $r.B.message | Should -Be $r.B.label
        $r.C.status | Should -Be 'warn'
        $r.D.status | Should -Be 'err'
        $r.E.status | Should -Be 'err'
        $r.F.status | Should -Be 'err' -Because 'a rollback is an error whatever level the producer gave it'
    }
    It 'an unknown state is not known, gets a readable label, a status from its level and a message that names it' {
        $r = InModuleScope AzlSonar {
            [pscustomobject]@{ A = (Get-AzlSonarOsEventInfo -State DiskEncryptionStarted); B = (Get-AzlSonarOsEventInfo -State X_y -Level Error -Evidence 'boom'); C = (Get-AzlSonarOsEventInfo -State Odd -Level Warning) }
        }
        $r.A.known | Should -BeFalse
        $r.A.group | Should -Be 'unknown'
        $r.A.label | Should -Be 'Disk Encryption Started'
        $r.A.status | Should -Be 'idle'
        $r.A.message | Should -Match 'DiskEncryptionStarted'
        $r.B.status | Should -Be 'err'
        $r.B.message | Should -Be 'boom'
        $r.C.status | Should -Be 'warn'
    }
}

Describe 'the node timeline shows every event, known or not' {
    It 'keeps an unknown state on the node: timeline, unknownStates and the run summary, never dropped' {
        $s = Get-OccState @(
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State DiskEncryptionStarted -Step Bitlocker -Evidence 'encrypting the OS volume'),
            (New-OccLine -At (Get-OccTime 2) -Node '*' -State PostRunHookFinished -Evidence 'hook done'))
        $n = @($s.nodes | Where-Object name -eq 'n1')[0]
        $t = @($n.timeline | Where-Object state -eq 'DiskEncryptionStarted')
        $t.Count | Should -Be 1
        $t[0].known | Should -BeFalse
        $t[0].message | Should -Be 'encrypting the OS volume'
        @($n.unknownStates) | Should -Be @('DiskEncryptionStarted')
        @($s.unknownStates.state) | Should -Contain 'DiskEncryptionStarted'
        @($s.unknownStates.state) | Should -Contain 'PostRunHookFinished'
        @($s.run.timeline | Where-Object state -eq 'PostRunHookFinished').Count | Should -Be 1
    }
    It 'an unknown state does not change the node state or hide a known one' {
        $s = Get-OccState @(
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeReconnecting),
            (New-OccLine -At (Get-OccTime 2) -Node n1 -State SomethingNew))
        @($s.nodes | Where-Object name -eq 'n1')[0].state | Should -Be 'reconnecting'
        @($s.nodes | Where-Object name -eq 'n1')[0].lastEvent.state | Should -Be 'SomethingNew'
    }
    It 'maps the domain join states to a message and a status each' {
        $s = Get-OccState @(
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State DomainJoinPlanned -Step DomainJoin -Evidence 'will join' -Extra @{ action = 'Change' }),
            (New-OccLine -At (Get-OccTime 2) -Node n1 -State DomainJoinApplying -Step DomainJoin -Evidence 'joining'),
            (New-OccLine -At (Get-OccTime 3) -Node n1 -State DomainJoined -Step DomainJoin -Evidence 'joined'),
            (New-OccLine -At (Get-OccTime 4) -Node n1 -State DomainAdminsConfigured -Step DomainJoin -Evidence 'admins added'),
            (New-OccLine -At (Get-OccTime 5) -Node n2 -State DomainJoinFailed -Step DomainJoin -Level Error -Evidence 'AD error 1326'))
        $t = @((@($s.nodes | Where-Object name -eq 'n1')[0]).timeline)
        ($t | Where-Object state -eq 'DomainJoined').status | Should -Be 'ok'
        ($t | Where-Object state -eq 'DomainJoinApplying').status | Should -Be 'run'
        ($t | Where-Object state -eq 'DomainAdminsConfigured').message | Should -Be 'admins added'
        $f = @((@($s.nodes | Where-Object name -eq 'n2')[0]).timeline)[0]
        $f.status | Should -Be 'err'
        $f.message | Should -Be 'AD error 1326'
    }
    It 'keeps the last 12 events of a node in the timeline and redacts secrets in their messages' {
        $lines = @(1..20 | ForEach-Object { New-OccLine -At (Get-OccTime $_) -Node n1 -State StepApplying -Step Dns -Evidence "e$_" })
        $lines += (New-OccLine -At (Get-OccTime 30) -Node n1 -State StepFailed -Step Dns -Level Error -Evidence 'failed: password = Sup3rSecret!x')
        $n = @((Get-OccState $lines).nodes | Where-Object name -eq 'n1')[0]
        @($n.timeline).Count | Should -Be 12
        $n.timeline[-1].state | Should -Be 'StepFailed'
        ($n.timeline[-1].message) | Should -Not -Match 'Sup3rSecret'
    }
}

Describe 'restart and reconnect states' {
    It 'NodeRestarting then NodeReconnecting then NodeReconnected is one restart, and the node is reconnecting until it is back' {
        $head = @((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted), (New-OccLine -At (Get-OccTime 1) -Node n1 -State StepApplying -Step Hostname))
        $mid = $head + @((New-OccLine -At (Get-OccTime 2) -Node n1 -State NodeRestarting -Level Warning), (New-OccLine -At (Get-OccTime 2.1) -Node n1 -State NodeReconnecting -Level Warning))
        $n = @((Get-OccState $mid).nodes | Where-Object name -eq 'n1')[0]
        $n.state | Should -Be 'reconnecting'
        $n.restarts | Should -Be 1
        $done = $mid + @((New-OccLine -At (Get-OccTime 5) -Node n1 -State NodeReconnected -Extra @{ address = '192.0.2.21' }))
        $d = @((Get-OccState $done).nodes | Where-Object name -eq 'n1')[0]
        $d.state | Should -Not -Be 'reconnecting'
        $d.restarts | Should -Be 1
        $d.address.value | Should -Be '192.0.2.21'
    }
    It 'a reconnect that is a pending reconciliation says so in the state text' {
        $s = Get-OccState @((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted), (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeReconnecting -Level Warning -Evidence 'PendingReconciliation: no answer' -Extra @{ pendingReconciliation = $true }))
        @($s.nodes | Where-Object name -eq 'n1')[0].stateText | Should -Match 'reconcil'
    }
    It 'the NodeWaiting heartbeat is shown as what the host waits for, and does not hide the reconnecting state' {
        $lines = @((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted), (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeReconnecting),
            (New-OccLine -At (Get-OccTime 2) -Node n1 -State NodeWaiting -Evidence 'Still waiting' -Extra @{ waiting = 'n1 to answer again'; phase = 'AwaitingConfirm'; elapsedSeconds = 120; heartbeat = 2 }))
        $n = @((Get-OccState $lines).nodes | Where-Object name -eq 'n1')[0]
        $n.state | Should -Be 'reconnecting'
        $n.waiting.what | Should -Be 'n1 to answer again'
        $n.waiting.phase | Should -Be 'AwaitingConfirm'
        $n.waiting.elapsedSeconds | Should -Be 120
        $n.waiting.heartbeat | Should -Be 2
        $after = $lines + @((New-OccLine -At (Get-OccTime 3) -Node n1 -State NodeReconnected))
        $null -eq @((Get-OccState $after).nodes | Where-Object name -eq 'n1')[0].waiting | Should -BeTrue -Because 'a later event ends the wait'
    }
    It 'the heartbeats are folded in the timeline: a long wait shows its newest beat once' {
        $lines = @(New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted)
        $lines += @(1..8 | ForEach-Object { New-OccLine -At (Get-OccTime $_) -Node n1 -State NodeWaiting -Extra @{ waiting = 'x'; elapsedSeconds = (60 * $_); heartbeat = $_ } })
        $n = @((Get-OccState $lines).nodes | Where-Object name -eq 'n1')[0]
        @($n.timeline | Where-Object state -eq 'NodeWaiting').Count | Should -Be 1
        @($n.timeline | Where-Object state -eq 'NodeWaiting')[0].message | Should -Match '480 s'
    }
}

Describe 'the node address and where it came from' {
    It 'reads the address and its source from TransportResolved: <Given> is <Id>' -ForEach @(
        @{ Given = 'override'; Id = 'override'; Label = 'override' }
        @{ Given = 'handoff'; Id = 'handoff'; Label = 'handoff' }
        @{ Given = 'ztp-handoff'; Id = 'handoff'; Label = 'handoff' }
        @{ Given = 'Arc'; Id = 'arc'; Label = 'Arc' }
        @{ Given = 'infrastructure file'; Id = 'file'; Label = 'file' }
        @{ Given = 'file'; Id = 'file'; Label = 'file' }
        @{ Given = 'mac-lookup'; Id = 'neighbor'; Label = 'neighbor' }
        @{ Given = 'Get-NetNeighbor'; Id = 'neighbor'; Label = 'neighbor' }
        @{ Given = 'arp -a'; Id = 'neighbor'; Label = 'neighbor' }
    ) {
        $s = Get-OccState @((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted), (New-OccLine -At (Get-OccTime 1) -Node n1 -State TransportResolved -Transport WinRM -Extra @{ address = '192.0.2.11'; forced = $false; addressSource = $Given }))
        $a = @($s.nodes | Where-Object name -eq 'n1')[0].address
        $a.value | Should -Be '192.0.2.11'
        $a.source | Should -Be $Id
        $a.sourceLabel | Should -Match $Label
        $a.forced | Should -BeFalse
    }
    It 'also reads the source from a field called source, and from the evidence text when no field has it' {
        $a = @((Get-OccState @((New-OccLine -At (Get-OccTime 1) -Node n1 -State TransportResolved -Extra @{ address = '192.0.2.11'; source = 'arc' }))).nodes | Where-Object name -eq 'n1')[0].address
        $a.source | Should -Be 'arc'
        $b = @((Get-OccState @((New-OccLine -At (Get-OccTime 1) -Node n1 -State TransportResolved -Evidence 'n1: current management address 192.0.2.12, found by mac-lookup (Get-NetNeighbor); answers on TCP 5985.' -Extra @{ address = '192.0.2.12' }))).nodes | Where-Object name -eq 'n1')[0].address
        $b.source | Should -Be 'neighbor'
    }
    It 'a source the toolkit adds later is shown as it was written; no source is "not reported"; the transport is forced when it says so' {
        $x = @((Get-OccState @((New-OccLine -At (Get-OccTime 1) -Node n1 -State TransportResolved -Extra @{ address = '192.0.2.13'; addressSource = 'dhcp-lease'; forced = $true }))).nodes | Where-Object name -eq 'n1')[0].address
        $x.source | Should -Be 'dhcp-lease'
        $x.sourceLabel | Should -Match 'dhcp-lease'
        $x.forced | Should -BeTrue
        $y = @((Get-OccState @((New-OccLine -At (Get-OccTime 1) -Node n1 -State TransportResolved -Extra @{ address = '192.0.2.14' }))).nodes | Where-Object name -eq 'n1')[0].address
        $y.source | Should -Be ''
        $y.sourceLabel | Should -Match 'not reported'
        $null -eq @((Get-OccState @()).nodes)[0].address.value -or @((Get-OccState @()).nodes)[0].address.value -eq '' | Should -BeTrue
    }
}

Describe 'the guarded change panel' {
    BeforeAll {
        $script:G = @(
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State NetworkChangeStaged -Step Network -Evidence 'Staged' -Extra @{ changeId = 'chg-1'; group = 'Management'; oldAddress = '192.0.2.10'; newAddress = '192.0.2.20'; items = 'nic-static' }),
            (New-OccLine -At (Get-OccTime 2) -Node n1 -State NetworkChangeVerifying -Step Network -Extra @{ changeId = 'chg-1'; group = 'Management'; oldAddress = '192.0.2.10'; newAddress = '192.0.2.20' }),
            (New-OccLine -At (Get-OccTime 3) -Node n1 -State NetworkChangeAwaitingConfirm -Step Network -Extra @{ changeId = 'chg-1'; group = 'Management'; oldAddress = '192.0.2.10'; newAddress = '192.0.2.20'; confirmBy = (Get-OccTime 13) }))
    }
    It 'shows the change id, old and new address, phase and the deadline while it waits for confirmation' {
        $s = Get-OccState $script:G
        $g = @($s.nodes | Where-Object name -eq 'n1')[0].guardedDetail
        $g.changeId | Should -Be 'chg-1'
        $g.oldAddress | Should -Be '192.0.2.10'
        $g.newAddress | Should -Be '192.0.2.20'
        $g.phase | Should -Be 'AwaitingConfirm'
        $g.active | Should -BeTrue
        $g.confirmBy | Should -Be '2026-11-07T19:13:00Z'
        $g.group | Should -Be 'Management'
        @($s.guarded).Count | Should -Be 1
        $s.guarded[0].node | Should -Be 'n1'
        $s.guarded[0].changeId | Should -Be 'chg-1'
    }
    It 'the phase follows Staged, Verifying and AwaitingConfirm and is not active once Committed' {
        (@((Get-OccState $script:G[0..1]).nodes | Where-Object name -eq 'n1')[0].guardedDetail).phase | Should -Be 'Staged'
        (@((Get-OccState $script:G[0..2]).nodes | Where-Object name -eq 'n1')[0].guardedDetail).phase | Should -Be 'Verifying'
        $c = @((Get-OccState ($script:G + @((New-OccLine -At (Get-OccTime 5) -Node n1 -State NetworkChangeCommitted -Step Network -Extra @{ changeId = 'chg-1'; oldAddress = '192.0.2.10'; newAddress = '192.0.2.20' })))).nodes | Where-Object name -eq 'n1')[0].guardedDetail
        $c.phase | Should -Be 'Committed'
        $c.active | Should -BeFalse
    }
    It 'a rollback shows its reason and the node verdict; the panel stays after the rollback' {
        $s = Get-OccState ($script:G + @((New-OccLine -At (Get-OccTime 6) -Node n1 -State NetworkChangeRolledBack -Step Network -Level Warning -Evidence 'rolled back' -Extra @{ changeId = 'chg-1'; oldAddress = '192.0.2.10'; newAddress = '192.0.2.20'; verdict = 'GatewayUnreachable'; reason = 'The gateway did not answer for 60 s.' })))
        $g = @($s.nodes | Where-Object name -eq 'n1')[0].guardedDetail
        $g.phase | Should -Be 'RolledBack'
        $g.reason | Should -Match 'gateway did not answer'
        $g.verdict | Should -Be 'GatewayUnreachable'
        $g.active | Should -BeFalse
        @($s.guarded).Count | Should -Be 1
    }
    It 'a repair names the rungs the node used, also when the producer sends a list' {
        $s = Get-OccState ($script:G + @((New-OccLine -At (Get-OccTime 4) -Node n1 -State NetworkChangeRepaired -Step Network -Level Warning -Extra @{ changeId = 'chg-1'; rung = @(1, 2) })))
        $g = @($s.nodes | Where-Object name -eq 'n1')[0].guardedDetail
        $g.rung | Should -Be '1, 2'
        $g.repairs | Should -Be 1
    }
    It 'a node without a guarded change has no panel entry' {
        $s = Get-OccState @((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted))
        @($s.guarded).Count | Should -Be 0
        $null -eq @($s.nodes | Where-Object name -eq 'n1')[0].guardedDetail | Should -BeTrue
    }
}

Describe 'remoting, TrustedHosts and the wipe list' {
    It 'keeps the remoting profile and the TrustedHosts change of the run, whichever comes first' {
        $lines = @(
            (New-OccLine -At (Get-OccTime 0) -Node '*' -State RemotingProfileResolved -Step RemoteManagement -Level Warning -Evidence 'class lab, posture relaxed' -Run r1 -Seq 1 -Extra @{ class = 'lab'; posture = 'relaxed'; relaxed = $true; scheme = 'http'; trustedHosts = 'Merge'; remoteAddress = @('192.0.2.0/24') }),
            (New-OccLine -At (Get-OccTime 1) -Node '*' -State RunStarted -Run r1 -Seq 2 -Extra @{ nodes = @('n1'); mode = 'Apply' }),
            (New-OccLine -At (Get-OccTime 2) -Node '*' -State TrustedHostsChanged -Step RemoteManagement -Run r1 -Seq 3 -Extra @{ class = 'lab'; mode = 'Merge'; previous = ''; applied = '192.0.2.10' }))
        $s = Get-OccState $lines
        $s.remoting.profile.class | Should -Be 'lab'
        $s.remoting.profile.posture | Should -Be 'relaxed'
        $s.remoting.profile.relaxed | Should -BeTrue
        $s.remoting.trustedHosts.changed | Should -BeTrue
        $s.remoting.trustedHosts.restored | Should -BeFalse
        $s.run.id | Should -Be 'r1'
        $restored = $lines + @((New-OccLine -At (Get-OccTime 9) -Node '*' -State TrustedHostsRestored -Step RemoteManagement -Run r1 -Seq 4 -Extra @{ restored = '' }))
        (Get-OccState $restored).remoting.trustedHosts.restored | Should -BeTrue
    }
    It 'per-node remoting events (bootstrap, firewall, listener) are on the node, with a status each' {
        $s = Get-OccState @(
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State RemotingBootstrapStarted -Step RemoteManagement -Extra @{ route = 'arc' }),
            (New-OccLine -At (Get-OccTime 2) -Node n1 -State RemotingBootstrapFailed -Step RemoteManagement -Level Warning -Evidence 'route arc failed' -Extra @{ route = 'arc'; reason = 'timeout' }),
            (New-OccLine -At (Get-OccTime 3) -Node n1 -State RemotingFirewallChange -Step RemoteManagement -Level Warning -Evidence 'Firewall scope NOT applied (reverted)' -Extra @{ class = 'lab'; status = 'Reverted' }),
            (New-OccLine -At (Get-OccTime 4) -Node n1 -State RemotingListenerChange -Step RemoteManagement -Evidence 'Listeners applied' -Extra @{ https = $true; http = $false }))
        $n = @($s.nodes | Where-Object name -eq 'n1')[0]
        $n.remoting.bootstrap.state | Should -Be 'RemotingBootstrapFailed'
        $n.remoting.bootstrap.route | Should -Be 'arc'
        $n.remoting.firewall.status | Should -Be 'warn'
        $n.remoting.listener.status | Should -Be 'ok'
        ($n.timeline | Where-Object state -eq 'RemotingBootstrapFailed').status | Should -Be 'warn'
    }
    It 'records the wipe list approval and a rejection on the wipe object' {
        $pub = New-OccLine -At (Get-OccTime 0) -Node '*' -State WipeListPublished -Extra @{ wipeCount = 1; clearStorage = $true; wipe = @(@{ node = 'n1'; disks = '3 disks' }) }
        $ok = Get-OccState @($pub, (New-OccLine -At (Get-OccTime 1) -Node '*' -State WipeListApproved -Level Warning -Evidence 'matches the approved list' -Extra @{ hash = 'abc'; approvedHash = 'abc' }))
        $ok.wipe.approval.state | Should -Be 'Approved'
        $ok.wipe.approval.hash | Should -Be 'abc'
        $no = Get-OccState @($pub, (New-OccLine -At (Get-OccTime 1) -Node '*' -State WipeListRejected -Level Error -Evidence 'no approved wipe list was given' -Extra @{ hash = 'abc' }))
        $no.wipe.approval.state | Should -Be 'Rejected'
        $no.wipe.approval.message | Should -Match 'no approved wipe list'
        @($no.run.timeline | Where-Object state -eq 'WipeListRejected')[0].status | Should -Be 'err'
    }
    It 'a stale run command that was deleted is a warning on the node' {
        $s = Get-OccState @((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted), (New-OccLine -At (Get-OccTime 1) -Node n1 -State StaleRunCommandDeleted -Step Transport -Level Warning -Evidence 'Deleted run command azl-osconfig-1' -Extra @{ runCommand = 'azl-osconfig-1' }))
        $e = @(@($s.nodes | Where-Object name -eq 'n1')[0].timeline | Where-Object state -eq 'StaleRunCommandDeleted')[0]
        $e.known | Should -BeTrue
        $e.status | Should -Be 'warn'
    }
}

Describe 'runs: the current run id, stale runs and the order by seq' {
    It 'shows the current run id and counts the runs it has seen' {
        $s = Get-OccState @((New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted -Run 'r-1' -Seq 1 -Extra @{ nodes = @('n1') }), (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeStarted -Run 'r-1' -Seq 2))
        $s.run.id | Should -Be 'r-1'
        $s.run.legacy | Should -BeFalse
        $s.run.runsSeen | Should -Be 1
        $s.run.seq | Should -Be 2
    }
    It 'a new run id with RunStarted starts over: the nodes of the old run are gone, the old run is stale' {
        $lines = @(
            (New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted -Run 'r-1' -Seq 1 -Extra @{ nodes = @('n1', 'n2') }),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeConverged -Run 'r-1' -Seq 2),
            (New-OccLine -At (Get-OccTime 1) -Node n2 -State NodeConverged -Run 'r-1' -Seq 3),
            (New-OccLine -At (Get-OccTime 30) -Node '*' -State RunStarted -Run 'r-2' -Seq 1 -Extra @{ nodes = @('n1') }),
            (New-OccLine -At (Get-OccTime 31) -Node n1 -State NodeStarted -Run 'r-2' -Seq 2))
        $s = Get-OccState $lines
        $s.run.id | Should -Be 'r-2'
        $s.run.runsSeen | Should -Be 2
        @($s.nodes | Where-Object name -eq 'n2')[0].attempt | Should -Be 0 -Because 'n2 belongs to the old run only'
        @($s.nodes | Where-Object name -eq 'n1')[0].state | Should -Not -Be 'converged'
        $s.nodesConverged | Should -Be 0
    }
    It 'ignores a late event of an older run (it must not undo the new run) and counts it' {
        $lines = @(
            (New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted -Run 'r-1' -Seq 1 -Extra @{ nodes = @('n1') }),
            (New-OccLine -At (Get-OccTime 30) -Node '*' -State RunStarted -Run 'r-2' -Seq 1 -Extra @{ nodes = @('n1') }),
            (New-OccLine -At (Get-OccTime 31) -Node n1 -State NodeStarted -Run 'r-2' -Seq 2),
            (New-OccLine -At (Get-OccTime 5) -Node n1 -State NodeFailed -Level Error -Evidence 'old failure' -Run 'r-1' -Seq 9),
            (New-OccLine -At (Get-OccTime 6) -Node '*' -State RunCompleted -Run 'r-1' -Seq 10 -Extra @{ exitCode = 1 }))
        $s = Get-OccState $lines
        $s.run.id | Should -Be 'r-2'
        $s.run.staleIgnored | Should -Be 2
        @($s.nodes | Where-Object name -eq 'n1')[0].state | Should -Not -Be 'failed'
        $null -eq $s.run.completed | Should -BeTrue
    }
    It 'an event of a run that was never started and is older than the current run is stale' {
        $lines = @((New-OccLine -At (Get-OccTime 30) -Node '*' -State RunStarted -Run 'r-2' -Seq 1 -Extra @{ nodes = @('n1') }), (New-OccLine -At (Get-OccTime 2) -Node n1 -State NodeFailed -Level Error -Run 'r-0' -Seq 5))
        $s = Get-OccState $lines
        $s.run.id | Should -Be 'r-2'
        $s.run.staleIgnored | Should -Be 1
    }
    It 'an event of a new run whose RunStarted was never seen (the file was cut) starts that run' {
        $lines = @((New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted -Run 'r-1' -Seq 1 -Extra @{ nodes = @('n1') }), (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeConverged -Run 'r-1' -Seq 2),
            (New-OccLine -At (Get-OccTime 40) -Node n1 -State StepApplying -Step Dns -Run 'r-3' -Seq 7))
        $s = Get-OccState $lines
        $s.run.id | Should -Be 'r-3'
        @($s.nodes | Where-Object name -eq 'n1')[0].state | Should -Not -Be 'converged'
        $s.run.staleIgnored | Should -Be 0
    }
    It 'a line without runId inside a run with ids belongs to the current run' {
        $lines = @((New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted -Run 'r-1' -Seq 1 -Extra @{ nodes = @('n1') }), (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeConverged))
        $s = Get-OccState $lines
        $s.run.id | Should -Be 'r-1'
        @($s.nodes | Where-Object name -eq 'n1')[0].state | Should -Be 'converged'
    }
    It 'orders the events of a node by seq when they arrive out of order, and drops a repeated seq' {
        $lines = @(
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted -Run r -Seq 1),
            (New-OccLine -At (Get-OccTime 3) -Node n1 -State StepApplied -Step Dns -Run r -Seq 4),
            (New-OccLine -At (Get-OccTime 2) -Node n1 -State StepApplying -Step Dns -Run r -Seq 3),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State StepPlanned -Step Dns -Run r -Seq 2 -Extra @{ action = 'Change' }),
            (New-OccLine -At (Get-OccTime 3) -Node n1 -State StepApplied -Step Dns -Run r -Seq 4))
        $store = Get-OccStore $lines
        @($store['n1'].Events).state | Should -Be @('NodeStarted', 'StepPlanned', 'StepApplying', 'StepApplied')
        @($store['n1'].Events).seq | Should -Be @(1, 2, 3, 4)
        $s = Get-OccState $lines
        @((@($s.nodes | Where-Object name -eq 'n1')[0]).tree | Where-Object { $_.osc.step -eq 'Dns' })[0].osc.stage | Should -Be 'applied'
    }
    It 'a NodeStarted that arrives late (lower seq) does not throw away the events already in the attempt' {
        $lines = @(
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State StepApplying -Step Dns -Run r -Seq 3),
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted -Run r -Seq 1))
        $store = Get-OccStore $lines
        @($store['n1'].Events).state | Should -Be @('NodeStarted', 'StepApplying')
    }
    It 'a NodeStarted with a higher seq still begins a new attempt, as in a legacy file' {
        $lines = @(
            (New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted -Run r -Seq 1),
            (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeFailed -Level Error -Run r -Seq 2),
            (New-OccLine -At (Get-OccTime 2) -Node n1 -State NodeStarted -Run r -Seq 3))
        $store = Get-OccStore $lines
        @($store['n1'].Events).Count | Should -Be 1
        $store['n1'].Attempt | Should -Be 2
    }
    It 'serialises to JSON the page can read, with the new fields' {
        $s = Get-OccState @((New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted -Run r -Seq 1 -Extra @{ nodes = @('n1') }), (New-OccLine -At (Get-OccTime 1) -Node n1 -State TransportResolved -Run r -Seq 2 -Extra @{ address = '192.0.2.5'; addressSource = 'arc' }), (New-OccLine -At (Get-OccTime 2) -Node n1 -State Mystery -Run r -Seq 3))
        $o = ($s | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
        $o.run.id | Should -Be 'r'
        $o.nodes[0].address.source | Should -Be 'arc'
        @($o.nodes[0].timeline).Count | Should -BeGreaterThan 0
        @($o.unknownStates)[0].state | Should -Be 'Mystery'
    }
}

Describe 'the event file loop reads a file, a folder with one file per run, or a pattern' {
    BeforeAll {
        $script:Loop = {
            param($Path)
            InModuleScope AzlSonar -Parameters @{ P = $Path } {
                param($P)
                $shared = Initialize-AzlSonarSharedState
                Invoke-AzlSonarOsConfigEventLoop -Shared $shared -Config ([pscustomobject]@{ osConfigEventsPath = $P })
                $cfg = [pscustomobject]@{ osConfigEventsPath = $P; nodes = @([pscustomobject]@{ name = 'n1' }) }
                [pscustomobject]@{ State = (Get-AzlSonarOsConfigurationState -Store $shared['OsConfigEvents'] -Config $cfg -ExpectedRoute 'simplified'); Lines = @((Get-AzlSonarLogWindow -Shared $shared).lines).Count; Count = $shared['OsConfigInfo']['Count'] }
            }
        }
    }
    It 'follows every file of a folder, oldest first, so the newest run is the current one and the older run is stale' {
        $dir = Join-Path $TestDrive 'perrun'
        $null = New-Item -ItemType Directory -Path $dir
        $f1 = Join-Path $dir 'os-configuration-events-r1.jsonl'
        $f2 = Join-Path $dir 'os-configuration-events-r2.jsonl'
        [IO.File]::WriteAllText($f1, ((New-OccLine -At (Get-OccTime 0) -Node '*' -State RunStarted -Run r1 -Seq 1 -Extra @{ nodes = @('n1') }) + "`n" + (New-OccLine -At (Get-OccTime 1) -Node n1 -State NodeConverged -Run r1 -Seq 2) + "`n"))
        [IO.File]::WriteAllText($f2, ((New-OccLine -At (Get-OccTime 30) -Node '*' -State RunStarted -Run r2 -Seq 1 -Extra @{ nodes = @('n1') }) + "`n" + (New-OccLine -At (Get-OccTime 31) -Node n1 -State NodeStarted -Run r2 -Seq 2) + "`n"))
        (Get-Item $f1).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
        (Get-Item $f2).LastWriteTimeUtc = [datetime]::UtcNow
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar { $Shared['Stop'] = $true }
        $r = & $script:Loop $dir
        $r.State.run.id | Should -Be 'r2'
        $r.State.run.runsSeen | Should -Be 2
        $r.State.nodesConverged | Should -Be 0
        $r.Lines | Should -Be 4
        $r.Count | Should -Be 4
    }
    It 'a wildcard path follows the files it matches; a folder or pattern with no file yet is just empty' {
        $dir = Join-Path $TestDrive 'glob'
        $null = New-Item -ItemType Directory -Path $dir
        [IO.File]::WriteAllText((Join-Path $dir 'os-configuration-events-a.jsonl'), ((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted -Run a -Seq 1) + "`n"))
        [IO.File]::WriteAllText((Join-Path $dir 'other.txt'), "not an event file`n")
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar { $Shared['Stop'] = $true }
        (& $script:Loop (Join-Path $dir 'os-configuration-events-*.jsonl')).Lines | Should -Be 1
        (& $script:Loop $dir).Lines | Should -Be 1 -Because 'other.txt is not a .jsonl file'
        (& $script:Loop (Join-Path $dir 'nothing-*.jsonl')).Lines | Should -Be 0
        (& $script:Loop (Join-Path $TestDrive 'does-not-exist')).Lines | Should -Be 0
    }
    It 'a file of a folder that grows is read from where it was left, a new file is picked up on the next poll' {
        $dir = Join-Path $TestDrive 'grow'
        $null = New-Item -ItemType Directory -Path $dir
        $f1 = Join-Path $dir 'e1.jsonl'
        [IO.File]::WriteAllText($f1, ((New-OccLine -At (Get-OccTime 0) -Node n1 -State NodeStarted -Run g -Seq 1) + "`n"))
        $script:GrowDir = $dir
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar {
            if (-not $Shared.Contains('Round')) {
                $Shared['Round'] = 1
                $d = [string]$Shared['GrowDir']
                [IO.File]::AppendAllText((Join-Path $d 'e1.jsonl'), ('{"timestamp":"2026-11-07T19:01:00Z","node":"n1","state":"StepApplying","step":"Dns","runId":"g","seq":2}' + "`n"))
                [IO.File]::WriteAllText((Join-Path $d 'e2.jsonl'), ('{"timestamp":"2026-11-07T19:02:00Z","node":"n1","state":"StepApplied","step":"Dns","runId":"g","seq":3}' + "`n"))
            }
            else { $Shared['Stop'] = $true }
        }
        $r = InModuleScope AzlSonar -Parameters @{ P = $dir } {
            param($P)
            $shared = Initialize-AzlSonarSharedState
            $shared['GrowDir'] = $P
            Invoke-AzlSonarOsConfigEventLoop -Shared $shared -Config ([pscustomobject]@{ osConfigEventsPath = $P })
            @($shared['OsConfigEvents']['n1'].Events).state
        }
        $r | Should -Be @('NodeStarted', 'StepApplying', 'StepApplied')
    }
}
