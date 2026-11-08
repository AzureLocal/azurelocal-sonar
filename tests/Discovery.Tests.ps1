#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The Discovery stage: Sonar reads the files the toolkit's Invoke-HardwareDiscovery.ps1 writes (a folder with one
# <ServiceTag>.json per node and discovery-summary.json). Documentation values only (MACs 00-00-5E-00-53-xx, tags EXAMPLEnn).
# The files are temp files: no iDRAC, no Azure, no node.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule

    # A per-node file as the toolkit writes it (-Detail Full adds more sections, which Sonar ignores).
    function global:New-DiscNodeJson {
        param([string]$Name, [string]$Tag, [int]$Index, [bool]$Boss = $true, [bool]$BossDisk = $true, [string[]]$Warnings = @(), [bool]$Full = $true)
        $mac = { param($n) '00-00-5E-00-53-{0:X2}' -f $n }
        $d = [ordered]@{
            SchemaVersion = '1.0'; CollectedAt = '2026-11-07T18:00:00Z'; BmcAddress = '192.0.2.50'; NodeName = $Name
            Identity = [ordered]@{ ServiceTag = $Tag; SerialNumber = "CH$Tag"; Model = 'Example R660'; Manufacturer = 'Example'; BiosVersion = '2.1.0' }
            Bmc = [ordered]@{ Address = '192.0.2.50'; MacAddress = (& $mac (100 + $Index)); Interfaces = @() }
            NetworkPorts = @(
                [ordered]@{ Name = 'Embedded Port 1'; Slot = 'Embedded'; MacAddress = (& $mac ($Index * 4 + 1)); LinkUp = $true; LinkSpeedMbps = 10000; AdapterModel = 'Example 10G'; Unknown = 'x' },
                [ordered]@{ Name = 'Slot 3 Port 1'; Slot = 'Slot 3'; MacAddress = (& $mac ($Index * 4 + 2)); LinkUp = $false; LinkSpeedMbps = $null; AdapterModel = 'Example 25G' })
            Boss = [ordered]@{ Present = $Boss; DriveCount = $(if ($Boss) { 2 } else { 0 }); HasVirtualDisk = ($Boss -and $BossDisk); NeedsVirtualDisk = ($Boss -and -not $BossDisk) }
            Warnings = @($Warnings)
        }
        if ($Full) { $d['BiosAttributes'] = [ordered]@{ ProcVirtualization = 'Enabled' }; $d['Firmware'] = @(@{ Id = 'x' }) }
        $d | ConvertTo-Json -Depth 8
    }
    function global:New-DiscSummaryJson {
        param([object[]]$Nodes)   # @{ Name; Tag; Index; Port; Confirmed; Boss; BossDisk }
        $rows = foreach ($n in $Nodes) {
            $mac = { param($x) '00-00-5E-00-53-{0:X2}' -f $x }
            [ordered]@{
                NodeName = $n.Name; ServiceTag = $n.Tag; Model = 'Example R660'; BmcMac = (& $mac (100 + $n.Index))
                Ports = @([ordered]@{ Name = 'Embedded Port 1'; Mac = (& $mac ($n.Index * 4 + 1)); LinkUp = $true }, [ordered]@{ Name = 'Slot 3 Port 1'; Mac = (& $mac ($n.Index * 4 + 2)); LinkUp = $false })
                ManagementPort = $(if ($n.ContainsKey('Port')) { $n.Port } else { 'Embedded Port 1' }); ManagementMac = $(if ($n.ContainsKey('Port') -and -not $n.Port) { $null } else { & $mac ($n.Index * 4 + 1) })
                ManagementPortConfirmed = $(if ($n.ContainsKey('Confirmed')) { $n.Confirmed } else { $true }); ManagementPortReason = 'its MAC is already the management MAC in infrastructure.yml'
                Boss = [ordered]@{ Present = $true; DriveCount = 2; HasVirtualDisk = $(if ($n.ContainsKey('BossDisk')) { $n.BossDisk } else { $true }); NeedsVirtualDisk = $(if ($n.ContainsKey('BossDisk')) { -not $n.BossDisk } else { $false }) }
                Warnings = 0
            }
        }
        ConvertTo-Json -InputObject @($rows) -Depth 8
    }
    # A folder with the files of the given nodes; the summary is written only when -Summary.
    function global:New-DiscFolder {
        param([string]$Name, [hashtable[]]$Nodes, [switch]$Summary)
        $dir = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($n in $Nodes) {
            $args2 = @{ Name = $n.Name; Tag = $n.Tag; Index = $n.Index }
            foreach ($k in 'Boss', 'BossDisk', 'Warnings') { if ($n.ContainsKey($k)) { $args2[$k] = $n[$k] } }
            [IO.File]::WriteAllText((Join-Path $dir "$($n.Tag).json"), (New-DiscNodeJson @args2))
        }
        if ($Summary) { [IO.File]::WriteAllText((Join-Path $dir 'discovery-summary.json'), (New-DiscSummaryJson -Nodes $Nodes)) }
        $dir
    }
    function global:Get-DiscState {
        param([string]$Path, [string[]]$Names = @('n1', 'n2'), $Cache = $null)
        $cfg = [pscustomobject]@{ discoveryPath = $Path; nodes = @($Names | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
        InModuleScope AzlSonar -Parameters @{ C = $cfg; K = $Cache } { param($C, $K) Get-AzlSonarDiscoveryState -Config $C -Cache $K }
    }
    $script:Two = @(@{ Name = 'n1'; Tag = 'EXAMPLE1'; Index = 1 }, @{ Name = 'n2'; Tag = 'EXAMPLE2'; Index = 2 })
}

AfterAll {
    foreach ($f in 'New-DiscNodeJson', 'New-DiscSummaryJson', 'New-DiscFolder', 'Get-DiscState') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'the Discovery state: waiting, empty, running, failed, discovered' {
    It 'is not configured without discoveryPath: grey, one waiting machine per configured node' {
        $s = Get-DiscState ''
        $s.configured | Should -BeFalse
        $s.state | Should -Be 'notconfigured'
        $s.status | Should -Be 'notstarted'
        @($s.nodes).Count | Should -Be 2
        @($s.nodes).state | Should -Be @('missing', 'missing')
    }
    It 'waits while the path is not there yet' {
        $s = Get-DiscState (Join-Path $TestDrive 'not-yet')
        $s.configured | Should -BeTrue
        $s.state | Should -Be 'waiting'
        $s.status | Should -Be 'notstarted'
        $s.stateText | Should -Match 'Waiting'
        $s.location | Should -Be 'not-yet'
    }
    It 'is empty when the folder is there and holds no discovery file' {
        $dir = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $dir
        [IO.File]::WriteAllText((Join-Path $dir 'notes.txt'), 'x')
        $s = Get-DiscState $dir
        $s.state | Should -Be 'empty'
        $s.status | Should -Be 'notstarted'
    }
    It 'is running (partial) while some machines are read and the summary, written after the last one, is not there' {
        $dir = New-DiscFolder 'partial' @($script:Two[0])
        $s = Get-DiscState $dir
        $s.state | Should -Be 'partial'
        $s.status | Should -Be 'running'
        $s.nodesDiscovered | Should -Be 1
        $s.summaryFound | Should -BeFalse
        (@($s.nodes) | Where-Object name -eq 'n2').state | Should -Be 'missing'
        (@($s.nodes) | Where-Object name -eq 'n2').status | Should -Be 'notstarted'
    }
    It 'has discovered every machine when each has its file and the summary is there' {
        $dir = New-DiscFolder 'all' $script:Two -Summary
        $s = Get-DiscState $dir
        $s.state | Should -Be 'discovered'
        $s.status | Should -Be 'success'
        $s.ready | Should -BeTrue
        $s.summaryFound | Should -BeTrue
        $s.nodesDiscovered | Should -Be 2
        $s.nodesFailed | Should -Be 0
        $s.collectedAt | Should -Be '2026-11-07T18:00:00Z'
        $s.stateText | Should -Match 'All 2 machines discovered'
    }
    It 'fails when the summary is there and a machine has no record (the run reported it as failed)' {
        $dir = New-DiscFolder 'one-failed' @($script:Two[0]) -Summary
        $s = Get-DiscState $dir
        $s.state | Should -Be 'failed'
        $s.status | Should -Be 'error'
        $s.nodesFailed | Should -Be 1
        (@($s.nodes) | Where-Object name -eq 'n2').status | Should -Be 'error'
        @((@($s.nodes) | Where-Object name -eq 'n2').errors)[0] | Should -Match 'No discovery record'
    }
    It 'fails when a file cannot be read, names the file, and still shows the machines that were read' {
        $dir = New-DiscFolder 'broken' @($script:Two[0])
        [IO.File]::WriteAllText((Join-Path $dir 'EXAMPLE2.json'), '{ "Identity": { "ServiceTag": ')
        [IO.File]::WriteAllText((Join-Path $dir 'EMPTY.json'), '')
        $s = Get-DiscState $dir
        $s.state | Should -Be 'failed'
        $s.status | Should -Be 'error'
        @($s.problems).file | Should -Contain 'EXAMPLE2.json'
        @($s.problems).file | Should -Contain 'EMPTY.json'
        $s.nodesDiscovered | Should -Be 1
    }
    It 'a JSON file that is not a discovery file is a problem, not a machine' {
        $dir = Join-Path $TestDrive 'foreign'
        $null = New-Item -ItemType Directory -Path $dir
        [IO.File]::WriteAllText((Join-Path $dir 'other.json'), '{"hello":"world"}')
        $s = Get-DiscState $dir @()
        $s.state | Should -Be 'failed'
        @($s.problems)[0].message | Should -Match 'not a discovery file'
    }
    It 'reads a single file path: the summary alone, or one node file' {
        $dir = New-DiscFolder 'single' $script:Two -Summary
        $a = Get-DiscState (Join-Path $dir 'discovery-summary.json')
        $a.nodesDiscovered | Should -Be 2
        $a.state | Should -Be 'discovered'
        (@($a.nodes) | Where-Object name -eq 'n1').serviceTag | Should -Be 'EXAMPLE1'
        $b = Get-DiscState (Join-Path $dir 'EXAMPLE1.json') @('n1')
        $b.nodesDiscovered | Should -Be 1
    }
    It 'with no nodes in the config it lists every record it finds' {
        $dir = New-DiscFolder 'nocfg' $script:Two -Summary
        $s = Get-DiscState $dir @()
        @($s.nodes).name | Should -Be @('n1', 'n2')
        $s.state | Should -Be 'discovered'
    }
}

Describe 'what a machine shows: serial, MACs, management port, BOSS card' {
    BeforeAll {
        $script:Dir = New-DiscFolder 'detail' @(
            @{ Name = 'n1'; Tag = 'EXAMPLE1'; Index = 1 },
            @{ Name = 'n2'; Tag = 'EXAMPLE2'; Index = 2; BossDisk = $false; Confirmed = $false },
            @{ Name = 'n3'; Tag = 'EXAMPLE3'; Index = 3; Port = $null; Warnings = @('Storage: Volumes failed') }) -Summary
        $script:S = Get-DiscState $script:Dir @('n1', 'n2', 'n3')
    }
    It 'shows the service tag, model, BIOS version, iDRAC MAC and every port with its MAC and link' {
        $n = @($script:S.nodes | Where-Object name -eq 'n1')[0]
        $n.state | Should -Be 'discovered'
        $n.serviceTag | Should -Be 'EXAMPLE1'
        $n.serial | Should -Be 'CHEXAMPLE1'
        $n.model | Should -Be 'Example R660'
        $n.biosVersion | Should -Be '2.1.0'
        $n.bmcMac | Should -Be '00-00-5E-00-53-65'
        @($n.ports).Count | Should -Be 2
        $n.ports[0].mac | Should -Be '00-00-5E-00-53-05'
        $n.ports[0].linkUp | Should -BeTrue
        $n.ports[0].speedMbps | Should -Be 10000
        $n.ports[1].linkUp | Should -BeFalse
        $n.notes.Count | Should -Be 0
    }
    It 'shows the suggested management port, and says when it is only a guess' {
        $a = @($script:S.nodes | Where-Object name -eq 'n1')[0]
        $a.management.name | Should -Be 'Embedded Port 1'
        $a.management.mac | Should -Be '00-00-5E-00-53-05'
        $a.management.confirmed | Should -BeTrue
        $b = @($script:S.nodes | Where-Object name -eq 'n2')[0]
        $b.management.confirmed | Should -BeFalse
        ($b.notes -join ' ') | Should -Match 'guess'
        $b.state | Should -Be 'attention'
    }
    It 'says when no management port was suggested, and counts the iDRAC warnings' {
        $c = @($script:S.nodes | Where-Object name -eq 'n3')[0]
        $null -eq $c.management | Should -BeTrue
        ($c.notes -join ' ') | Should -Match 'No management port'
        $c.warnings | Should -Be 1
        @($c.warningTexts)[0] | Should -Match 'Volumes failed'
        $c.state | Should -Be 'attention'
    }
    It 'reports the BOSS card: virtual disk present, or the card that has none (Phase 02 Task 01 creates it)' {
        $ok = @($script:S.nodes | Where-Object name -eq 'n1')[0]
        $ok.boss.present | Should -BeTrue
        $ok.boss.hasVirtualDisk | Should -BeTrue
        $no = @($script:S.nodes | Where-Object name -eq 'n2')[0]
        $no.boss.needsVirtualDisk | Should -BeTrue
        ($no.notes -join ' ') | Should -Match 'no virtual disk'
    }
    It 'builds the step tree the page shows: identity, ports (one child each), management port, BOSS card' {
        $t = @(@($script:S.nodes | Where-Object name -eq 'n1')[0].tree)
        $t.name | Should -Be @('Identity', 'Network ports (2)', 'Management port', 'BOSS card')
        @($t[1].children).Count | Should -Be 2
        $t[1].children[0].description | Should -Match '00-00-5E-00-53-05'
        $t[0].status | Should -Be 'success'
    }
    It 'a machine with attention is still a discovered one, and the overall state counts the machines to check' {
        $script:S.state | Should -Be 'discovered'
        $script:S.stateText | Should -Match '2 to check before ZTP'
    }
    It 'reads a node file without the summary: ports and identity, no management suggestion' {
        $dir = New-DiscFolder 'nosummary' @($script:Two[0])
        $n = @((Get-DiscState $dir @('n1')).nodes)[0]
        $n.serviceTag | Should -Be 'EXAMPLE1'
        @($n.ports).Count | Should -Be 2
        $null -eq $n.management | Should -BeTrue
    }
    It 'serialises to JSON the page can read (arrays stay arrays)' {
        $o = $script:S | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        @($o.nodes).Count | Should -Be 3
        @($o.nodes[0].ports).Count | Should -Be 2
        @($o.nodes[0].tree[1].children).Count | Should -Be 2
        @($o.problems).Count | Should -Be 0
    }
}

Describe 'the cache: a file is parsed again only when it changes' {
    It 'keeps parsed files by path, parses nothing the second time, and re-reads a changed file' {
        $dir = New-DiscFolder 'cache' $script:Two -Summary
        $cache = [hashtable]::Synchronized(@{})
        $a = Get-DiscState $dir @('n1', 'n2') $cache
        $cache.Count | Should -Be 3
        $stamp = $cache[(Join-Path $dir 'EXAMPLE1.json')].Stamp
        $result = $cache[(Join-Path $dir 'EXAMPLE1.json')].Result
        $null = Get-DiscState $dir @('n1', 'n2') $cache
        [object]::ReferenceEquals($cache[(Join-Path $dir 'EXAMPLE1.json')].Result, $result) | Should -BeTrue
        [IO.File]::WriteAllText((Join-Path $dir 'EXAMPLE1.json'), (New-DiscNodeJson -Name 'n1' -Tag 'EXAMPLE1' -Index 1 -Warnings @('changed')))
        $b = Get-DiscState $dir @('n1', 'n2') $cache
        $cache[(Join-Path $dir 'EXAMPLE1.json')].Stamp | Should -Not -Be $stamp
        (@($b.nodes) | Where-Object name -eq 'n1').warnings | Should -Be 1
        $a.nodesDiscovered | Should -Be 2
    }
    It 'forgets a file that is gone' {
        $dir = New-DiscFolder 'cache-gone' $script:Two -Summary
        $cache = [hashtable]::Synchronized(@{})
        $null = Get-DiscState $dir @('n1', 'n2') $cache
        Remove-Item -LiteralPath (Join-Path $dir 'EXAMPLE2.json')
        $null = Get-DiscState $dir @('n1', 'n2') $cache
        $cache.ContainsKey((Join-Path $dir 'EXAMPLE2.json')) | Should -BeFalse
    }
}

Describe 'discoveryPath in the config, the state and Details' {
    It 'is empty by default and resolved against the config folder when relative' {
        $cfg = New-SonarConfigObject
        $cfg | Add-Member -NotePropertyName discoveryPath -NotePropertyValue './discovery' -Force
        $path = Join-Path $TestDrive 'sonar.json'
        [IO.File]::WriteAllText($path, (ConvertTo-SonarConfigJson $cfg))
        $c = InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) Read-AzlSonarConfig -Path $P }
        $c.discoveryPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'discovery')))
        (InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson (New-SonarConfigObject)) } { param($Json) (Read-AzlSonarConfig -Json $Json).discoveryPath }) | Should -Be ''
    }
    It 'rejects an empty or non-text path' {
        $cfg = New-SonarConfigObject
        $cfg | Add-Member -NotePropertyName discoveryPath -NotePropertyValue '   ' -Force
        { InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $cfg) } { param($Json) Read-AzlSonarConfig -Json $Json } } | Should -Throw '*discoveryPath*'
    }
    It 'Set-AzlSonarConfig can set it' {
        $path = Join-Path $TestDrive 'set.json'
        [IO.File]::WriteAllText($path, (ConvertTo-SonarConfigJson (New-SonarConfigObject)))
        Set-AzlSonarConfig -Path $path -Key discoveryPath -Value 'D:\x\discovery' 6>$null
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).discoveryPath | Should -Be 'D:\x\discovery'
    }
    It 'is imported from the master file: the discovery folder inside the evidence folder' {
        $config = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.toolkit-lom-management-ztp.yml') 3>$null
        $config.discoveryPath | Should -Match 'discovery$'
        Split-Path $config.discoveryPath -Parent | Should -Be (Split-Path $config.ztpEventsPath -Parent)
    }
    It 'is documented in docs/config.md and explained in the commented example (one row per key)' {
        $doc = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/config.md') -Raw
        $example = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'examples/sonar.config.commented.jsonc') -Raw
        ([regex]::Matches($doc, '(?m)^\| `discoveryPath` \|')).Count | Should -Be 1
        $example | Should -Match 'discoveryPath'
    }
    It 'the initial state carries a discovery object, the poll state adds it from the cache, and the shared state holds the cache' {
        $dir = New-DiscFolder 'poll' $script:Two -Summary
        $cfgObj = New-SonarConfigObject
        $cfgObj | Add-Member -NotePropertyName discoveryPath -NotePropertyValue $dir -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $cfgObj) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $init = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) Get-AzlSonarInitialState -Config $C }
        $init.discovery.configured | Should -BeTrue
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { [pscustomobject]@{ StatusCode = 404; Body = $null; ErrorMessage = 'HTTP 404'; ErrorCode = 'ResourceNotFound' } }
        $cache = [hashtable]::Synchronized(@{})
        $state = InModuleScope AzlSonar -Parameters @{ C = $cfg; K = $cache } { param($C, $K) Get-AzlSonarDeploymentState -Config $C -DiscoveryCache $K }
        $state.discovery.configured | Should -BeTrue
        $state.discovery.nodesDiscovered | Should -Be 2 -Because 'the two machines of the fixture are named n1 and n2 and the config names others, so the fixture machines are extra rows'
        $cache.Count | Should -Be 3
        (InModuleScope AzlSonar { (Initialize-AzlSonarSharedState).Contains('DiscoveryCache') }) | Should -BeTrue
    }
    It 'Details names the folder, says whether it is there, and lists it as Not set when it is not configured' {
        $config = New-SonarConfigObject
        $config | Add-Member -NotePropertyName discoveryPath -NotePropertyValue 'D:\x\discovery' -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $config) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $facts = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) New-AzlSonarDetailFact -Config $C }
        $facts.discoveryFile | Should -Be 'discovery'
        @($facts.notSet).setting | Should -Not -Contain 'discovery'
        $bare = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson (New-SonarConfigObject)) } { param($Json) New-AzlSonarDetailFact -Config (Read-AzlSonarConfig -Json $Json) }
        (@($bare.notSet) | Where-Object setting -eq 'discovery').key | Should -Be 'discoveryPath'
    }
}

Describe 'a manual install (scenario.os_install not simplified)' {
    It 'is a manual install only when the master file says ISO: the Provisioning tile reads Not used' {
        InModuleScope AzlSonar {
            Test-AzlSonarManualInstall -Config ([pscustomobject]@{ sourceKind = 'infrastructure' }) -Route 'oem-image' | Should -BeTrue
            Test-AzlSonarManualInstall -Config ([pscustomobject]@{ sourceKind = 'infrastructure' }) -Route 'simplified' | Should -BeFalse
            Test-AzlSonarManualInstall -Config ([pscustomobject]@{ sourceKind = 'config' }) -Route 'oem-image' | Should -BeFalse -Because 'a Sonar config file keeps the OEM image route (Arc registration is watched)'
            Test-AzlSonarManualInstall -Config ([pscustomobject]@{ sourceKind = 'infrastructure' }) -Route '' | Should -BeFalse
        }
    }
    It 'the state says so: provisioning.manualInstall follows scenario.os_install of the master file' {
        $iso = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.toolkit-lom-management-iso.yml') 3>$null
        $ztp = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.toolkit-lom-management-ztp.yml') 3>$null
        (InModuleScope AzlSonar -Parameters @{ C = $iso } { param($C) (Get-AzlSonarInitialState -Config $C).provisioning.manualInstall }) | Should -BeTrue
        (InModuleScope AzlSonar -Parameters @{ C = $ztp } { param($C) (Get-AzlSonarInitialState -Config $C).provisioning.manualInstall }) | Should -BeFalse
    }
}
