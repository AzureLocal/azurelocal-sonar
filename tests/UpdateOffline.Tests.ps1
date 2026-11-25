#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The Update monitor with no Azure sign-in: it starts when the toolkit's update events are there to follow, shows them alone, marks the
# Azure live poll as not connected (a plain fact, never an error) and behaves as before when a sign-in is present. The events are the
# toolkit's real output (tests/fixtures/toolkit-events). No Azure, no cluster, no node: every Azure call is mocked to fail the test.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Fx = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/toolkit-events'
    function global:Get-OffLine([string]$Name) { @(Get-Content -LiteralPath (Join-Path $script:Fx "$Name.update-events.jsonl") | Where-Object { $_ }) }
    function global:Get-OffState {
        param([string[]]$Line, [string]$Path = 'x')
        InModuleScope AzlSonar -Parameters @{ L = $Line; P = $Path } {
            param($L, $P)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $store -Line $x }
            $cfg = [pscustomobject]@{ clusterName = 'clus01'; resourceGroup = 'rg'; nodes = @(); monitor = 'Update'; updateEventsPath = $P; azureConnected = $false }
            Get-AzlSonarUpdateOfflineState -Config $cfg -UpdateEvents $store
        }
    }
}

AfterAll {
    foreach ($f in 'Get-OffLine', 'Get-OffState') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'the monitor plan with no Azure' {
    It 'the Update monitor reads the update events only: no Azure, no node, no log tailer, no log access' {
        $p = InModuleScope AzlSonar { Get-AzlSonarMonitorPlan -Monitor 'Update' -AzureOffline }
        $p.azure | Should -BeFalse
        $p.tailer | Should -BeFalse
        $p.nodeProbe | Should -BeFalse
        $p.cluster | Should -BeFalse
        $p.updateEvents | Should -BeTrue
        @($p.phases).Count | Should -Be 0
    }
    It 'is today''s plan with a sign-in' {
        $p = InModuleScope AzlSonar { Get-AzlSonarMonitorPlan -Monitor 'Update' }
        $p.azure | Should -BeTrue
        $p.tailer | Should -BeTrue
        @($p.phases) | Should -Be @('update')
    }
    It 'changes nothing for the <Name> monitor: only the Update and the Deployment monitor (PostDeploymentEvents.Tests.ps1) run without Azure' -ForEach @(
        @{ Name = 'Auto' }, @{ Name = 'Validate' }, @{ Name = 'Provisioning' }
    ) {
        $plain = InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Get-AzlSonarMonitorPlan -Monitor $N }
        $off = InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Get-AzlSonarMonitorPlan -Monitor $N -AzureOffline }
        ($off | ConvertTo-Json -Depth 4) | Should -Be ($plain | ConvertTo-Json -Depth 4)
    }
}

Describe 'which config can start the Update monitor with no Azure' {
    It 'names updateEventsPath, whether or not the file is there yet' {
        $r = InModuleScope AzlSonar -Parameters @{ D = $TestDrive } {
            param($D)
            $c = [pscustomobject]@{ monitor = 'Update'; updateEventsPath = (Join-Path $D 'none/update-events.jsonl') }
            [pscustomobject]@{ File = (Resolve-AzlSonarUpdateEventsFile -Config $c); Offline = (Test-AzlSonarOfflineUpdate -Config $c) }
        }
        $r.File | Should -Be (Join-Path $TestDrive 'none/update-events.jsonl')
        $r.Offline | Should -BeTrue
    }
    It 'finds the update-events.jsonl the events folder of the other toolkit feeds holds' {
        $events = Join-Path $TestDrive 'events'
        $null = New-Item -ItemType Directory -Path $events -Force
        Set-Content -LiteralPath (Join-Path $events 'update-events.jsonl') -Value (Get-OffLine 'check-available')
        $r = InModuleScope AzlSonar -Parameters @{ E = $events } {
            param($E)
            $c = [pscustomobject]@{ monitor = 'Update'; armEventsPath = (Join-Path $E 'arm-deployment-events.jsonl') }
            [pscustomobject]@{ File = (Resolve-AzlSonarUpdateEventsFile -Config $c); Offline = (Test-AzlSonarOfflineUpdate -Config $c) }
        }
        $r.File | Should -Be (Join-Path $events 'update-events.jsonl')
        $r.Offline | Should -BeTrue
    }
    It 'finds nothing when no folder holds the file, so the sign-in is still required' {
        $empty = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $empty -Force
        $r = InModuleScope AzlSonar -Parameters @{ E = $empty } {
            param($E)
            $c = [pscustomobject]@{ monitor = 'Update'; osConfigEventsPath = $E }
            [pscustomobject]@{ File = (Resolve-AzlSonarUpdateEventsFile -Config $c); Offline = (Test-AzlSonarOfflineUpdate -Config $c) }
        }
        $r.File | Should -Be ''
        $r.Offline | Should -BeFalse
    }
    It 'is only for the Update monitor: Auto and the others still need the sign-in' -ForEach @(
        @{ Name = 'Auto' }, @{ Name = 'Deployment' }, @{ Name = 'Validate' }
    ) {
        $r = InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Test-AzlSonarOfflineUpdate -Config ([pscustomobject]@{ monitor = $N; updateEventsPath = 'C:\e\update-events.jsonl' }) }
        $r | Should -BeFalse
    }
}

Describe 'the Update tile from the toolkit''s real update events, with Azure not connected' {
    BeforeAll {
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No Azure call may be made.' }
    }
    It 'an update is offered (Check): the tile is populated from the events and Azure is not connected' {
        $s = Get-OffState -Line (Get-OffLine 'check-available')
        $s.update.source | Should -Be 'events'
        $s.update.verified | Should -BeFalse
        $s.update.phase | Should -Be 'available'
        $s.update.label | Should -BeLike 'Update available*nothing was installed*'
        @($s.update.tree).Count | Should -BeGreaterThan 0
        $s.updateEvents.hasData | Should -BeTrue
        $s.phase | Should -Be 'update'
        $s.track | Should -Be 'update'
        $s.monitor | Should -Be 'Update'
    }
    It 'marks the Azure live poll as not connected and never as an error' {
        $s = Get-OffState -Line (Get-OffLine 'check-available')
        $s.update.azure.connected | Should -BeFalse
        $s.update.azure.status | Should -Be 'notconnected'
        $s.update.azure.message | Should -Match 'not connected'
        $s.pollError | Should -BeNullOrEmpty
        @($s.warnings).Count | Should -Be 0
        $s.update.level | Should -Not -Be 'error'
    }
    It 'an up to date Check is ok and a failed one is an error from the events, not from Azure' {
        (Get-OffState -Line (Get-OffLine 'check-uptodate')).update.level | Should -Be 'ok'
        $bad = Get-OffState -Line (Get-OffLine 'check-attention')
        $bad.update.level | Should -Be 'error'
        $bad.phase | Should -Be 'failed'
        $bad.activePhase | Should -Be 'update'
        $bad.update.azure.connected | Should -BeFalse
        $bad.pollError | Should -BeNullOrEmpty
    }
    It 'a WhatIf run says nothing was installed and an install shows as installing' {
        (Get-OffState -Line (Get-OffLine 'start-whatif')).update.label | Should -BeLike '*nothing was installed*'
        (Get-OffState -Line (Get-OffLine 'start-install')).update.phase | Should -Be 'installing'
    }
    It 'before the toolkit has written anything it waits, neutral, with Azure not connected' {
        $s = Get-OffState -Line @()
        $s.update.level | Should -Be 'neutral'
        $s.update.label | Should -BeLike 'Waiting for the toolkit''s update events*'
        $s.update.azure.connected | Should -BeFalse
        $s.updateEvents.hasData | Should -BeFalse
        $s.pollError | Should -BeNullOrEmpty
    }
    It 'serialises to JSON the page can read (the update object carries azure.connected false)' {
        $json = (Get-OffState -Line (Get-OffLine 'check-available') | ConvertTo-Json -Depth 20) | ConvertFrom-Json
        $json.update.azure.connected | Should -BeFalse
        $json.update.tree | Should -Not -BeNullOrEmpty
    }
}

Describe 'the poller with no Azure sign-in' {
    It 'publishes the update events view and makes no Azure call when azureConnected is false' {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No Azure call may be made.' }
        $cfg = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $cfg | Add-Member -NotePropertyName monitor -NotePropertyValue 'Update' -Force
        $cfg | Add-Member -NotePropertyName azureConnected -NotePropertyValue $false -Force
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg; L = (Get-OffLine 'check-available') } {
            param($C, $L)
            $shared = Initialize-AzlSonarSharedState
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $shared['UpdateEvents'] -Line $x }
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            $shared.State
        }
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -Times 0 -Exactly
        # Nothing to pace (no Azure call): the view follows its file every 2 seconds, not every pollSeconds.
        Should -Invoke -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -ParameterFilter { $Seconds -eq 2 } -Times 1 -Exactly
        $state.update.source | Should -Be 'events'
        $state.update.azure.connected | Should -BeFalse
        $state.pollError | Should -BeNullOrEmpty
    }
    It 'with a sign-in the Azure poll is read and the update says it is connected' {
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarArcTarget -MockWith { @() }
        Mock -ModuleName AzlSonar -CommandName Get-AzlSonarArcMachineStatus -MockWith { @() }
        Mock -ModuleName AzlSonar -CommandName Get-AzlSonarClusterResource -MockWith { $null }
        Mock -ModuleName AzlSonar -CommandName Get-AzlSonarUpdateState -MockWith {
            [ordered]@{ verified = $false; status = 'notstarted'; phase = 'idle'; level = 'neutral'; label = 'No update has run'; ran = $false; nextAction = $null; summary = $null; active = $null; updates = @(); runs = @(); run = $null; tree = @(); counts = $null; local = $null; sources = $null }
        }
        $cfg = Get-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $cfg | Add-Member -NotePropertyName monitor -NotePropertyValue 'Update' -Force
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) Get-AzlSonarUpdateMonitorState -Config $C }
        $state.update.azure.connected | Should -BeTrue
        $state.update.azure.status | Should -Be 'connected'
    }
}

Describe 'Start-AzlSonarServer: the Update monitor with no Azure sign-in' {
    BeforeAll {
        Add-Type -AssemblyName System.Net.Http
        $script:Events = Join-Path $TestDrive 'events'
        $null = New-Item -ItemType Directory -Path $script:Events -Force
        Set-Content -LiteralPath (Join-Path $script:Events 'update-events.jsonl') -Value (Get-OffLine 'check-available')
        $withPath = New-SonarConfigObject
        $withPath | Add-Member -NotePropertyName updateEventsPath -NotePropertyValue (Join-Path $script:Events 'update-events.jsonl') -Force
        $script:PathConfig = Join-Path $TestDrive 'with-path.json'
        ConvertTo-SonarConfigJson $withPath | Set-Content -LiteralPath $script:PathConfig
        $withFolder = New-SonarConfigObject
        $withFolder | Add-Member -NotePropertyName armEventsPath -NotePropertyValue (Join-Path $script:Events 'arm-deployment-events.jsonl') -Force
        $script:FolderConfig = Join-Path $TestDrive 'with-folder.json'
        ConvertTo-SonarConfigJson $withFolder | Set-Content -LiteralPath $script:FolderConfig
        $script:NoFeedConfig = Join-Path $TestDrive 'no-feed.json'
        ConvertTo-SonarConfigJson (New-SonarConfigObject) | Set-Content -LiteralPath $script:NoFeedConfig
    }

    It 'starts without a sign-in and without asking for the log account when <Name>' -ForEach @(
        @{ Name = 'updateEventsPath is set'; Config = 'PathConfig' }
        @{ Name = 'the events folder holds update-events.jsonl'; Config = 'FolderConfig' }
    ) {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'No Azure sign-in found in this PowerShell session.' }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'The log account must not be asked for.' }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'Workers must not start.' }
        $port = Get-SonarFreeTcpPort
        $blocker = [System.Net.HttpListener]::new()
        $blocker.Prefixes.Add("http://localhost:$port/")
        $blocker.Start()
        try {
            # The taken port stops the start after the sign-in and credential steps: reaching it proves neither stopped the start.
            { Start-AzlSonarServer -ConfigPath (Get-Variable -Scope Script -Name $Config -ValueOnly) -Monitor Update -Port $port -NoBrowser } | Should -Throw "*Cannot listen on http://localhost:$port/*"
        }
        finally {
            $blocker.Stop(); $blocker.Close()
        }
        Should -Invoke -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -Times 1 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -Times 0 -Exactly
    }

    It 'still refuses to start without a sign-in when no update events are named' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'No Azure sign-in found in this PowerShell session.' }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'must not be reached' }
        { Start-AzlSonarServer -ConfigPath $script:NoFeedConfig -Monitor Update -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*No Azure sign-in*'
    }

    It 'still refuses to start without a sign-in for the <Monitor> monitor, which needs Azure' -ForEach @(
        @{ Monitor = 'Auto' }, @{ Monitor = 'Deployment' }
    ) {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'No Azure sign-in found in this PowerShell session.' }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'must not be reached' }
        { Start-AzlSonarServer -ConfigPath $script:PathConfig -Monitor $Monitor -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*No Azure sign-in*'
    }

    It 'with a sign-in it is the Azure poll as before: the log account is asked for' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
        Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { throw 'asked for the log account' }
        { Start-AzlSonarServer -ConfigPath $script:PathConfig -Monitor Update -Port (Get-SonarFreeTcpPort) -NoBrowser } | Should -Throw '*asked for the log account*'
    }
}
