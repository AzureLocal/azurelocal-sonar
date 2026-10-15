#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Publishable recordings (hardening 2610, gap 1). Every identifier below is invented (documentation ranges, random
# GUIDs, made-up names). No Azure, no node, no network except a localhost port for the replay check.

BeforeDiscovery {
    # Identifiers that are planted in the sample recording (kept in one place so the tests can look for each).
    $script:Planted = [ordered]@{
        guid1      = '3f2a9c1e-7b44-4d0a-9e6f-1a2b3c4d5e6f'
        guid2      = 'AB12CD34-EF56-7890-ABCD-EF1234567890'
        sub        = 'c0ffee00-1111-4222-8333-444455556666'
        ip1        = '10.20.30.41'
        ip2        = '172.16.5.9'
        ip3        = '8.8.4.4'
        ipv6       = 'fd12:3456:789a:1::25'
        mac1       = 'A4:BF:01:2C:3D:4E'
        mac2       = 'a4-bf-01-2c-3d-4f'
        fqdn       = 'srv-blue07.corp.iic-example.com'
        shortfqdn  = 'iic-example.com'
        upn        = 'jane.doe@iic-example.com'
        sid        = 'S-1-5-21-1111111111-2222222222-3333333333-1105'
        rg         = 'rg-zebra-prod'
        cluster    = 'zebraclus'
        node1      = 'zebranode7'
        user       = 'jdoeadmin'
        thumb      = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
        storage    = 'zebrastorage42'
        extra      = 'IIC Widgets'
    }

}

BeforeAll {
    # Identifiers that are planted in the sample recording (kept in one place so the tests can look for each).
    $script:Planted = [ordered]@{
        guid1      = '3f2a9c1e-7b44-4d0a-9e6f-1a2b3c4d5e6f'
        guid2      = 'AB12CD34-EF56-7890-ABCD-EF1234567890'
        sub        = 'c0ffee00-1111-4222-8333-444455556666'
        ip1        = '10.20.30.41'
        ip2        = '172.16.5.9'
        ip3        = '8.8.4.4'
        ipv6       = 'fd12:3456:789a:1::25'
        mac1       = 'A4:BF:01:2C:3D:4E'
        mac2       = 'a4-bf-01-2c-3d-4f'
        fqdn       = 'srv-blue07.corp.iic-example.com'
        shortfqdn  = 'iic-example.com'
        upn        = 'jane.doe@iic-example.com'
        sid        = 'S-1-5-21-1111111111-2222222222-3333333333-1105'
        rg         = 'rg-zebra-prod'
        cluster    = 'zebraclus'
        node1      = 'zebranode7'
        user       = 'jdoeadmin'
        thumb      = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
        storage    = 'zebrastorage42'
        extra      = 'IIC Widgets'
    }

    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    Add-Type -AssemblyName System.Net.Http
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/recording-sample.jsonl'

    function script:New-DirtyRecording {
        # The sample recording with the planted identifiers added to the config, a state and several log lines.
        param([string]$Path)
        $p = $script:Planted
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-Content -LiteralPath $script:Fixture)) {
            if (-not $line) { continue }
            $line = $line.Replace('clus01', $p.cluster).Replace('node01', $p.node1).Replace('rg-example-azl', $p.rg)
            $out.Add($line)
            $node = $line | ConvertFrom-Json -Depth 64
            if ($node.k -eq 'log') {
                $dirty = @(
                    "Connecting to $($p.fqdn) ($($p.ip1)) as CORP\$($p.user) mac $($p.mac1) / $($p.mac2)",
                    "Resource /subscriptions/$($p.sub)/resourceGroups/$($p.rg)/providers/Microsoft.AzureStackHCI/clusters/$($p.cluster)/deploymentSettings/default and /providers/Microsoft.Storage/storageAccounts/$($p.storage)",
                    "user $($p.upn) sid $($p.sid) ipv6 $($p.ipv6) other $($p.ip2) and $($p.ip3); guid $($p.guid1) / $($p.guid2); thumb $($p.thumb)",
                    "C:\Users\$($p.user)\AppData\Local\Temp\x.log opened on \\$($p.node1)\c`$ $($p.shortfqdn) $($p.extra)"
                )
                $i = 0
                foreach ($d in $dirty) {
                    $i++
                    $o = [ordered]@{ t = $node.t; k = 'log'; lines = @([ordered]@{ seq = 900 + $i; time = $node.t; received = $node.t; timeSource = 'received'; file = "C:\Users\$($p.user)\logs\a.log"; level = 'info'; text = $d }) }
                    $out.Add(($o | ConvertTo-Json -Depth 6 -Compress))
                }
            }
        }
        [System.IO.File]::WriteAllLines($Path, $out.ToArray())
    }
}

Describe 'Publishable: pseudonyms (Protect-AzlSonarPublishableText)' {
    BeforeAll {
        function script:Protect([string]$Text, [object]$State) {
            InModuleScope AzlSonar -Parameters @{ T = $Text; S = $State } { param($T, $S) Protect-AzlSonarPublishableText -Text $T -State $S }
        }
        function script:New-State([string[]]$Extra = @()) { InModuleScope AzlSonar -Parameters @{ E = $Extra } { param($E) New-AzlSonarPseudonymizer -ExtraTerm $E } }
    }

    It 'keeps GUID tokens apart: two GUIDs never collapse into one token (the half-masked GUID rule leaves tokens alone)' {
        $s = New-State
        $out = Protect '3f2a9c1e-7b44-4d0a-9e6f-1a2b3c4d5e6f and AB12CD34-EF56-7890-ABCD-EF1234567890 and 3F2A9C1E-7B44-4D0A-9E6F-1A2B3C4D5E6F' $s
        $out | Should -Be '00000000-0000-0000-0000-000000000001 and 00000000-0000-0000-0000-000000000002 and 00000000-0000-0000-0000-000000000001'
    }

    It 'gives the same value the same token and different values different tokens' {
        $s = New-State
        $a = Protect '10.1.2.3 and 10.1.2.4 and 10.1.2.3 again' $s
        $a | Should -Be '192.0.2.1 and 192.0.2.2 and 192.0.2.1 again'
    }

    It 'uses the documented token formats' -TestCases @(
        @{ Text = 'id 3f2a9c1e-7b44-4d0a-9e6f-1a2b3c4d5e6f'; Expected = 'id 00000000-0000-0000-0000-000000000001' }
        @{ Text = 'ip 10.20.30.41'; Expected = 'ip 192.0.2.1' }
        @{ Text = '10.20.30.41'; Expected = '192.0.2.1' }
        @{ Text = '1:2:3:4:5:6:7:8'; Expected = '2001:db8::1' }
        @{ Text = 'ip6 fd12:3456:789a:1::25'; Expected = 'ip6 2001:db8::1' }
        @{ Text = 'mac A4:BF:01:2C:3D:4E'; Expected = 'mac 00:00:5E:00:53:00' }
        @{ Text = 'mac a4-bf-01-2c-3d-4e'; Expected = 'mac 00-00-5e-00-53-00' }
        @{ Text = 'sid S-1-5-21-1111111111-2222222222-3333333333-1105'; Expected = 'sid S-1-5-21-1000000001-2000000001-3000000001-1105' }
        @{ Text = 'mail jane.doe@iic-example.com'; Expected = 'mail user-01@dom-01.example.test' }
        @{ Text = 'host srv-blue07.corp.iic-example.com'; Expected = 'host host-01.dom-01.example.test' }
        @{ Text = '/subscriptions/c0ffee00-1111-4222-8333-444455556666/resourceGroups/rg-zebra-prod'; Expected = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-01' }
        @{ Text = 'C:\Users\jdoeadmin\AppData'; Expected = 'C:\Users\user-01\AppData' }
        @{ Text = 'cert AABBCCDDEEFF00112233445566778899AABBCCDD'; Expected = 'cert 0000000000000000000000000000000000000001' }
        @{ Text = 'sub d7f0cf39-xxxx-xxxx-xxxx-xxxxxxxxxxxx tail xxxxxxxx-xxxx-xxxx-xxxx-0123456789ab'; Expected = 'sub 00000000-xxxx-xxxx-xxxx-xxxxxxxxxxxx tail xxxxxxxx-xxxx-xxxx-xxxx-000000000000' }
        @{ Text = "--subscription-id 'd7f0cf39-xxxx-xxxx-xxx"; Expected = "--subscription-id '00000000-xxxx-xxxx-xxx" }
        @{ Text = 'NIC3f2a9c1e-7b44-4d0a-9e6f-1a2b3c4d5e6f and TestNICcea7454f-xxxx-xxxx-xxxx-0123456789ab'; Expected = 'NIC00000000-0000-0000-0000-000000000001 and TestNIC00000000-xxxx-xxxx-xxxx-000000000000' }
        @{ Text = 'sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'; Expected = ('sha256 ' + ('0' * 63) + '1') }
    ) {
        $s = New-State
        Protect $Text $s | Should -Be $Expected
    }

    It 'keeps what is not an identifier: versions, masks, loopback, public Microsoft hosts, documentation values, GUID-free text' -TestCases @(
        @{ Text = 'Version=4.0.0.0 build 10.0.26100.1 mask 255.255.255.0 loopback 127.0.0.1 any 0.0.0.0' }
        @{ Text = 'https://management.azure.com/subscriptions?api-version=2025-09-15 and login.microsoftonline.com' }
        @{ Text = 'docs 192.0.2.77 node-01.dom-01.example.test 00000000-0000-0000-0000-000000000009 user-07@dom-02.example.test' }
        @{ Text = 'System.Net.Http and Microsoft.AzureStack.Cloud and Get-ChildItem setup.log CloudDeployment.2026-10-11.14-31-29.0.log' }
        @{ Text = 'Validate Hardware: one disk has an older firmware (step 3 of 12, took 00:04:12)' }
    ) {
        $s = New-State
        Protect $Text $s | Should -Be $Text
    }

    It 'keeps the service suffix of a customer endpoint and public resource names' {
        $s = New-State
        Protect 'https://zebrastorage42.blob.core.windows.net/c and /providers/Microsoft.AzureStackHCI/clusters/zc9/arcSettings/default/extensions/AzureMonitorWindowsAgent' $s |
            Should -Be 'https://res-01.blob.core.windows.net/c and /providers/Microsoft.AzureStackHCI/clusters/cluster-01/arcSettings/default/extensions/AzureMonitorWindowsAgent'
    }

    It 'replaces a learned name wherever it appears, in any case, even without a pattern' {
        $s = New-State
        InModuleScope AzlSonar -Parameters @{ S = $s } { param($S) Register-AzlSonarPublishableTerm -State $S -Category 'node' -Value 'zebranode7' }
        Protect 'the node ZebraNode7 and zebranode7$ and [ZEBRANODE7]' $s | Should -Be 'the node node-01 and node-01$ and [node-01]'
    }

    It 'replaces -ExtraTerm everywhere' {
        $s = New-State @('IIC Widgets')
        Protect 'made by iic widgets, iic WIDGETS inc' $s | Should -Not -Match '(?i)iic'
    }

    It 'handles Windows event XML values, service principal names and -EncodedCommand payloads' {
        $s = New-State
        $text = '<Computer>zebra-hv07.corp.iic-example.com</Computer><Data Name="TargetUserName">jdoeadmin</Data><Data Name="SubjectUserName">SYSTEM</Data> SPN HOST/zebrahv07 pwsh -NoProfile -EncodedCommand JABhAGIAYwAgAD0AIAAnAHMAZQBjAHIAZQB0ACcA done'
        $out = Protect $text $s
        $out | Should -Not -Match 'zebra|jdoeadmin|iic|JABhAGIA'
        $out | Should -Match '<Data Name="SubjectUserName">SYSTEM</Data>' -Because 'a system account is not an identifier'
        $out | Should -Match 'EncodedCommand \[encoded command removed\] done'
        $found = InModuleScope AzlSonar -Parameters @{ S = $s } { param($S) Find-AzlSonarPublishableIdentifier -Text '<Data Name="TargetUserName">jdoeadmin</Data>' -State $S }
        @($found) | Should -Contain 'event-xml'
    }

    It 'sees through XML entities, CLIXML and percent-encoding of punctuation' {
        $s = New-State
        (Protect 'jane&#64;iic-example&#46;com and jane%40iic-example.com and 10_x002E_1.2.3' $s) | Should -Not -Match 'iic|jane'
    }

    It 'is idempotent: a scrubbed text is left as it is' {
        $s = New-State
        $once = Protect 'srv-blue07.corp.iic-example.com 10.20.30.41 jane.doe@iic-example.com A4:BF:01:2C:3D:4E 3f2a9c1e-7b44-4d0a-9e6f-1a2b3c4d5e6f' $s
        $s2 = New-State
        Protect $once $s2 | Should -Be $once
    }

    It 'finds what is left with the same detectors (Find-AzlSonarPublishableIdentifier) and reports categories only' {
        $s = New-State
        $found = InModuleScope AzlSonar -Parameters @{ S = $s } { param($S) Find-AzlSonarPublishableIdentifier -Text 'ip 10.20.30.41 guid 3f2a9c1e-7b44-4d0a-9e6f-1a2b3c4d5e6f' -State $S }
        @($found) | Should -Contain 'ipv4'
        @($found) | Should -Contain 'guid'
        $clean = InModuleScope AzlSonar -Parameters @{ S = $s } { param($S) Find-AzlSonarPublishableIdentifier -Text 'ip 192.0.2.1 guid 00000000-0000-0000-0000-000000000001' -State $S }
        @($clean).Count | Should -Be 0
    }
}

Describe 'Publishable: Export-AzlSonarPublishableRecording' {
    BeforeAll {
        $script:Dirty = Join-Path $TestDrive 'dirty.jsonl'
        New-DirtyRecording -Path $script:Dirty
        $script:Out = Join-Path $TestDrive 'clean.jsonl'
        $script:Result = Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $script:Out -ExtraTerm @('IIC Widgets')
        $script:OutText = Get-Content -LiteralPath $script:Out -Raw
    }

    It 'leaves none of the planted identifiers, in any case, and verifies clean' -TestCases @(
        $script:Planted.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } }
    ) {
        $script:OutText.IndexOf($Value, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "$Name must not survive"
        $script:Result.Verification.Clean | Should -BeTrue
        $script:Result.Verification.Total | Should -Be 0
    }

    It 'keeps structure, kinds, times, step names and durations' {
        $a = @(Get-Content -LiteralPath $script:Dirty | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 64 })
        $b = @(Get-Content -LiteralPath $script:Out | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 64 })
        $b.Count | Should -Be $a.Count
        for ($i = 0; $i -lt $a.Count; $i++) {
            $b[$i].k | Should -Be $a[$i].k
            $b[$i].t | Should -Be $a[$i].t
        }
        $names = { param($path) ([regex]::Matches((Get-Content -LiteralPath $path -Raw), '"name":"(?:Validate|Deploy)[A-Za-z ]+"').Value | Sort-Object -Unique) -join '|' }
        (& $names $script:Out) | Should -Be (& $names $script:Dirty)
        (& $names $script:Out) | Should -Match 'Validate Hardware'
        $script:OutText | Should -Match '"durationSeconds"'
    }

    It 'uses one token for one value across the whole recording' {
        $tokens = [regex]::Matches($script:OutText, 'node-01').Count
        $tokens | Should -BeGreaterThan 3
        $script:OutText | Should -Match '"name":"node-01"'
    }

    It 'is repeatable: the same input gives the same output byte for byte' {
        $again = Join-Path $TestDrive 'clean2.jsonl'
        $null = Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $again -ExtraTerm @('IIC Widgets')
        (Get-FileHash -LiteralPath $again).Hash | Should -Be (Get-FileHash -LiteralPath $script:Out).Hash
    }

    It 'never changes the source and refuses to overwrite without -Force' {
        { Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $script:Out } | Should -Throw '*exists*'
        { Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $script:Dirty -Force } | Should -Throw '*different file*'
    }

    It 'writes gzip when the destination ends in .gz and the reader replays it' {
        $gz = Join-Path $TestDrive 'clean.jsonl.gz'
        $r = Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $gz -ExtraTerm @('IIC Widgets')
        $r.BytesOut | Should -BeLessThan $r.BytesIn
        $rec = InModuleScope AzlSonar -Parameters @{ P = $gz } { param($P) Read-AzlSonarRecording -Path $P }
        $rec.Invalid | Should -Be 0
        $rec.Cluster | Should -Be 'cluster-01'
        $rec.Events.Count | Should -Be $script:Result.Lines
    }

    It 'cuts long log lines after scrubbing and says so' {
        $long = Join-Path $TestDrive 'long.jsonl'
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($l in (Get-Content -LiteralPath $script:Fixture | Where-Object { $_ })) { $lines.Add($l) }
        $text = ('x' * 3000) + ' 10.9.8.7'
        $lines.Insert(3, ([ordered]@{ t = '2026-10-11T08:00:02.000Z'; k = 'log'; lines = @([ordered]@{ seq = 99; time = '2026-10-11T08:00:02.000Z'; received = '2026-10-11T08:00:02.000Z'; timeSource = 'received'; file = 'a.log'; level = 'info'; text = $text }) } | ConvertTo-Json -Depth 6 -Compress))
        [System.IO.File]::WriteAllLines($long, $lines.ToArray())
        $dest = Join-Path $TestDrive 'long.out.jsonl'
        $null = Export-AzlSonarPublishableRecording -Path $long -Destination $dest -MaxLogTextLength 500
        $o = Get-Content -LiteralPath $dest -Raw
        $o | Should -Match 'more characters left out of this recording'
        $o | Should -Not -Match 'x{600}'
    }

    It 'closes idle gaps with -MaxIdleSeconds and keeps the order of events' {
        $idle = Join-Path $TestDrive 'idle.jsonl'
        $null = Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $idle -MaxIdleSeconds 60
        $times = @(Get-Content -LiteralPath $idle | Where-Object { $_ } | ForEach-Object { [datetime]::Parse([regex]::Match($_, '"t":"([^"]+)"').Groups[1].Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) })
        $span = ($times[-1] - $times[0]).TotalMinutes
        $span | Should -BeLessThan 30
        for ($i = 1; $i -lt $times.Count; $i++) { $times[$i] | Should -BeGreaterOrEqual $times[$i - 1] }
    }

    It 'refuses to write when the result is over -MaxBytes' {
        $big = Join-Path $TestDrive 'big.jsonl'
        { Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $big -MaxBytes 100 } | Should -Throw '*over the limit*'
        Test-Path -LiteralPath $big | Should -BeFalse
        Test-Path -LiteralPath ($big + '.partial') | Should -BeFalse
    }

    It 'refuses to write when the verification still finds an identifier (fail closed), with counts and no values' {
        $bad = Join-Path $TestDrive 'bad.jsonl'
        Mock -ModuleName AzlSonar -CommandName Convert-AzlSonarPublishableLine -MockWith { $Line }
        $caught = $null
        try { $null = Export-AzlSonarPublishableRecording -Path $script:Dirty -Destination $bad } catch { $caught = $_.Exception.Message }
        $caught | Should -BeLike 'Verification failed*'
        $caught | Should -Not -Match '10\.20\.30\.41|zebra'
        Test-Path -LiteralPath $bad | Should -BeFalse
        Test-Path -LiteralPath ($bad + '.partial') | Should -BeFalse
    }

    It 'a scrubbed recording scanned on its own is clean (Test-AzlSonarPublishableRecording) and the original is not' {
        (Test-AzlSonarPublishableRecording -Path $script:Out -ExtraTerm @('IIC Widgets')).Clean | Should -BeTrue
        $dirty = Test-AzlSonarPublishableRecording -Path $script:Dirty
        $dirty.Clean | Should -BeFalse
        $dirty.ByCategory['ipv4'] | Should -BeGreaterThan 0
        $dirty.ByCategory['guid'] | Should -BeGreaterThan 0
        $dirty.ByCategory['mac'] | Should -BeGreaterThan 0
        $dirty.ByCategory['email'] | Should -BeGreaterThan 0
    }

    It 'property: random identifiers planted in log lines never survive (50 seeded rounds)' {
        $rng = [System.Random]::new(2610)
        $rows = [System.Collections.Generic.List[string]]::new()
        $planted = [System.Collections.Generic.List[string]]::new()
        $hex = '0123456789abcdef'
        for ($i = 0; $i -lt 50; $i++) {
            $g = [guid]::new($rng.Next(), [int16]$rng.Next(0, 32767), [int16]$rng.Next(0, 32767), [byte[]]@(1..8 | ForEach-Object { [byte]$rng.Next(0, 256) })).ToString()
            $ip = '{0}.{1}.{2}.{3}' -f $rng.Next(1, 223), $rng.Next(0, 256), $rng.Next(0, 256), $rng.Next(1, 255)
            $mac = (1..6 | ForEach-Object { '{0:X2}' -f $rng.Next(0, 256) }) -join ':'
            $name = 'hostz' + (-join (1..6 | ForEach-Object { $hex[$rng.Next(0, 16)] }))
            $upn = "user$($rng.Next(1000, 9999))@corp$($rng.Next(10, 99)).example-corp.com"
            $planted.AddRange([string[]]@($g, $ip, $mac, $upn))
            $text = "round $i $g reached $ip mac $mac as $upn via $name.lan$($rng.Next(10, 99)).example-corp.com"
            $planted.Add("$name.lan")
            $rows.Add(([ordered]@{ t = '2026-10-11T08:00:01.000Z'; k = 'log'; lines = @([ordered]@{ seq = $i + 1; time = '2026-10-11T08:00:01.000Z'; received = '2026-10-11T08:00:01.000Z'; timeSource = 'received'; file = 'a.log'; level = 'info'; text = $text }) } | ConvertTo-Json -Depth 6 -Compress))
        }
        $src = Join-Path $TestDrive 'prop.jsonl'
        $head = @(Get-Content -LiteralPath $script:Fixture | Where-Object { $_ })[0..2]
        [System.IO.File]::WriteAllLines($src, @($head) + $rows.ToArray())
        $dst = Join-Path $TestDrive 'prop.out.jsonl'
        $null = Export-AzlSonarPublishableRecording -Path $src -Destination $dst
        $o = Get-Content -LiteralPath $dst -Raw
        foreach ($p in $planted) { $o.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "$($p.Length)-char planted value survived" }
    }
}

Describe 'Publishable: the scrubbed recording replays like the original' {
    BeforeAll {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $script:Http = [System.Net.Http.HttpClient]::new($handler)
        $script:Http.Timeout = [TimeSpan]::FromSeconds(20)
        $dirty = Join-Path $TestDrive 'r-dirty.jsonl'
        New-DirtyRecording -Path $dirty
        $script:Scrubbed = Join-Path $TestDrive 'r-clean.jsonl.gz'
        $null = Export-AzlSonarPublishableRecording -Path $dirty -Destination $script:Scrubbed -ExtraTerm @('IIC Widgets')

        function script:Invoke-ReplayRun {
            param([scriptblock]$Start, [string[]]$Paths, [int]$Port)
            $script:Run = @{ Tasks = $null; Started = $null; Results = @{}; Paths = $Paths; Base = "http://localhost:$Port" }
            Mock -ModuleName AzlSonar -CommandName Send-AzlSonarSseUpdate -MockWith {
                $d = $script:Run
                if ($null -eq $d.Tasks) {
                    $d.Started = [datetime]::UtcNow
                    $d.Tasks = [ordered]@{}
                    foreach ($p in $d.Paths) { $d.Tasks[$p] = $script:Http.GetAsync($d.Base + $p) }
                }
                if (@($d.Tasks.Values | Where-Object { -not $_.IsCompleted }).Count -eq 0) {
                    foreach ($key in $d.Tasks.Keys) {
                        $t = $d.Tasks[$key]
                        $d.Results[$key] = if ($t.IsFaulted) { @{ Status = -1; Body = $t.Exception.InnerException.Message } } else { @{ Status = [int]$t.Result.StatusCode; Body = $t.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult() } }
                    }
                    throw 'AZLSONAR-TEST-STOP'
                }
                if (([datetime]::UtcNow - $d.Started).TotalSeconds -gt 30) { throw 'AZLSONAR-TEST-TIMEOUT' }
            }
            $stopped = $null
            try { & $Start } catch { $stopped = $_.Exception.Message }
            $stopped | Should -BeLike '*AZLSONAR-TEST-STOP*'
            return $script:Run.Results
        }
    }

    AfterAll { if ($script:Http) { $script:Http.Dispose() } }

    It 'serves the same states (phase at a time) and event count through the replay API' {
        Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { throw 'A replay must not need an Azure sign-in.' }
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'A replay starts no worker.' }
        Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No ARM call is expected.' }
        Mock -ModuleName AzlSonar -CommandName Start-Process -MockWith { throw 'The browser must not open in tests.' }
        $port = Get-SonarFreeTcpPort
        $results = Invoke-ReplayRun -Port $port -Paths @('/api/config', '/api/replay', '/api/state', '/api/logs', '/') -Start {
            Start-AzlSonarServer -Replay $script:Scrubbed -Port $port -Speed 240 -StartAt '0:35' -NoBrowser -InformationAction SilentlyContinue
        }
        $results['/api/config'].Status | Should -Be 200
        ($results['/api/config'].Body | ConvertFrom-Json).cluster | Should -Be 'cluster-01'
        $replay = $results['/api/replay'].Body | ConvertFrom-Json -Depth 64
        $replay.events[0].k | Should -Be 'session'
        ($results['/api/state'].Body | ConvertFrom-Json).phase | Should -Be 'deployment'
        $results['/'].Status | Should -Be 200
        ($results['/api/replay'].Body + $results['/api/state'].Body + $results['/api/config'].Body) | Should -Not -Match '(?i)zebra|iic|10\.20\.30\.41'
    }
}

Describe 'Publishable: live recording (-Record -Publishable)' {
    It 'writes a recording that is already scrubbed, verifies it at close and refuses to append to an existing file' {
        $path = Join-Path $TestDrive 'live.jsonl'
        $session = InModuleScope AzlSonar { New-AzlSonarSessionJson -ConfigJson '{"cluster":"zebraclus","clusterName":"zebraclus","nodes":[{"name":"zebranode7"}]}' -GuidanceJson '{"phases":{}}' -ServerId 'srv1' -Version '0.2.0' -Cluster 'zebraclus' }
        InModuleScope AzlSonar -Parameters @{ P = $path; S = $session } {
            param($P, $S)
            $rec = Open-AzlSonarRecorder -Path $P -SessionJson $S -Publishable
            $shared = Initialize-AzlSonarSharedState
            $state = [ordered]@{ cluster = 'zebraclus'; phase = 'validation'; polledAt = '2026-10-11T10:00:00Z'; nodes = @([ordered]@{ name = 'zebranode7'; address = '10.20.30.41' }) }
            $shared.State = $state
            $shared.StateJson = ConvertTo-AzlSonarJson $state
            $shared.StateVersion = 1
            Invoke-AzlSonarRecorderStep -Recorder $rec -Shared $shared
            Close-AzlSonarRecorder -Recorder $rec
        }
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Not -Match '(?i)zebra|10\.20\.30\.41'
        $text | Should -Match 'cluster-01'
        $text | Should -Match '192\.0\.2\.1'
        { InModuleScope AzlSonar -Parameters @{ P = $path; S = $session } { param($P, $S) Open-AzlSonarRecorder -Path $P -SessionJson $S -Publishable } } | Should -Throw '*new file*'
    }
}
