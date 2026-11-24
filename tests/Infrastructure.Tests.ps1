#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Fixture = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/infrastructure.3node.yml'
    $script:ToolkitCopy = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/infrastructure.toolkit-lom-management-ztp.yml'

    function Get-FixtureConfig {
        param([string]$Path = $script:Fixture)
        Get-AzlSonarConfig -InfrastructureFile $Path
    }
    function New-ModifiedInfrastructure {
        # The 3-node fixture with a text edit applied, written to TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that writes a file under TestDrive.')]
        param([Parameter(Mandatory)][scriptblock]$Edit)
        $text = Get-Content -LiteralPath $script:Fixture -Raw
        $text = & $Edit $text
        $path = Join-Path -Path $TestDrive -ChildPath ("infra-{0}.yml" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $path -Value $text -Encoding utf8
        return $path
    }
}

Describe 'Infrastructure file: mapping from a 3-node schema 5 fixture' {
    BeforeAll { $script:Config = Get-FixtureConfig }

    It 'maps subscription, resource group, cluster, route and identity' {
        $script:Config.subscriptionId | Should -Be '11111111-2222-3333-4444-555555555555'
        $script:Config.resourceGroup | Should -Be 'rg-example-azl-01'
        $script:Config.clusterName | Should -Be 'example-clus01'
        $script:Config.provisioningRoute | Should -Be 'simplified'
        $script:Config.identityModel | Should -Be 'ActiveDirectory'
    }

    It 'lists all three nodes (the node added last is not dropped)' {
        @($script:Config.nodes).Count | Should -Be 3
        ($script:Config.nodes | ForEach-Object name) | Should -Be @('example-n01', 'example-n02', 'example-n03')
    }

    It 'takes the management address from the onboard management port, whatever the port order' {
        $script:Config.nodes[0].address | Should -Be '192.0.2.11'   # management port listed after a storage NIC
        $script:Config.nodes[1].address | Should -Be '192.0.2.12'
    }

    It 'takes the address of a dhcp_reservation management port' {
        $script:Config.nodes[2].address | Should -Be '192.0.2.13'
    }

    It 'makes the first listed node the seed (schema 5.3 has no seed key)' {
        $script:Config.seedNode.name | Should -Be 'example-n01'
        @($script:Config.nodes | Where-Object seed).Count | Should -Be 1
    }

    It 'keeps arc_machine_name when the file sets it' {
        $script:Config.nodes[0].arcMachineName | Should -Be 'example-n01'
        $script:Config.nodes[0].arcMachineNameSet | Should -BeTrue
        $script:Config.nodes[1].arcMachineNameSet | Should -BeFalse
    }

    It 'points the ZTP event file at the evidence folder plus ztp-events.jsonl' {
        $script:Config.ztpEventsPath | Should -Be 'D:\Data\azl-ztp\example\evidence\ztp-events.jsonl'
    }

    It 'keeps the existing defaults for polling and credential source' {
        $script:Config.pollSeconds | Should -Be 20
        $script:Config.credential.source | Should -Be 'prompt'
    }

    It 'maps iso to oem-image and local_identity to LocalIdentity, with no ZTP event file' {
        $path = New-ModifiedInfrastructure { param($t) $t -replace 'os_install: simplified', 'os_install: iso' -replace 'identity: active_directory', 'identity: local_identity' }
        $config = Get-FixtureConfig -Path $path
        $config.provisioningRoute | Should -Be 'oem-image'
        $config.identityModel | Should -Be 'LocalIdentity'
        $config.ztpEventsPath | Should -Be ''
    }

    It 'tracks a fourth node added to the file' {
        $path = New-ModifiedInfrastructure {
            param($t)
            $added = "  - name: `"example-n04`"`n    network_adapters:`n      - { name: `"Embedded NIC 1`", roles: [management], ip_assignment: static, ip_address: `"192.0.2.14`" }`n`nhardware:"
            $t -replace '(?m)^hardware:', $added
        }
        $config = Get-FixtureConfig -Path $path
        @($config.nodes).Count | Should -Be 4
        $config.nodes[3].address | Should -Be '192.0.2.14'
    }
}

Describe 'Infrastructure file: reader-side key checks name the schema 5 path' {
    It 'names azure.resource_group when it is missing' {
        $path = New-ModifiedInfrastructure { param($t) $t -replace '(?m)^  resource_group:.*\r?\n', '' }
        { Get-FixtureConfig -Path $path } | Should -Throw '*azure.resource_group : is missing*schema 5*'
    }

    It 'names cluster.name when it is missing (for example a ZTP-only file)' {
        $path = New-ModifiedInfrastructure { param($t) $t -replace '(?m)^cluster:\r?\n  name:.*\r?\n', '' }
        { Get-FixtureConfig -Path $path } | Should -Throw '*cluster.name : is missing*'
    }

    It 'reports every problem at once' {
        $path = New-ModifiedInfrastructure { param($t) $t -replace '(?m)^  resource_group:.*\r?\n', '' -replace 'os_install: simplified', 'os_install: pxe' -replace 'identity: active_directory', 'identity: magic' }
        $message = ''
        try { Get-FixtureConfig -Path $path } catch { $message = $_.Exception.Message }
        $message | Should -Match 'azure.resource_group'
        $message | Should -Match "scenario.os_install : is 'pxe'; use simplified or iso"
        $message | Should -Match "scenario.identity : is 'magic'; use active_directory or local_identity"
    }

    It 'names nodes[1].network_adapters when a node has no management address' {
        $path = New-ModifiedInfrastructure { param($t) $t -replace 'ip_assignment: static, ip_address: "192.0.2.12"', 'ip_assignment: none' }
        { Get-FixtureConfig -Path $path } | Should -Throw '*nodes[[]1].network_adapters*example-n02*'
    }

    It 'refuses a file that is not schema 5' {
        $path = New-ModifiedInfrastructure { param($t) $t -replace '5\.3\.0', '4.2.0' }
        { Get-FixtureConfig -Path $path } | Should -Throw "*_metadata.schema_version : is '4.2.0'*"
    }

    It 'says so when the file is missing or not YAML' {
        { Get-FixtureConfig -Path (Join-Path $TestDrive 'nope.yml') } | Should -Throw '*not found*'
        $bad = Join-Path $TestDrive 'bad.yml'
        Set-Content -LiteralPath $bad -Value "a: b`n   c: [d"
        { Get-FixtureConfig -Path $bad } | Should -Throw '*not valid YAML*'
    }

    It 'Test-AzlSonarConfig -InfrastructureFile returns the problems instead of throwing' {
        $path = New-ModifiedInfrastructure { param($t) $t -replace '(?m)^  resource_group:.*\r?\n', '' }
        $problems = @(Test-AzlSonarConfig -InfrastructureFile $path)
        $problems.Count | Should -BeGreaterThan 0
        ($problems -join ' ') | Should -Match 'azure.resource_group'
        @(Test-AzlSonarConfig -InfrastructureFile $script:Fixture).Count | Should -Be 0
    }
}

Describe 'Infrastructure file: no secret is read' {
    It 'leaves every keyvault:// reference and secret name out of the configuration' {
        $config = Get-FixtureConfig
        $json = ConvertTo-Json -InputObject $config -Depth 32
        $json | Should -Not -Match 'keyvault'
        $json | Should -Not -Match 'local-admin|provisioning-admin'
        $json | Should -Not -Match 'bmc-'
        $config.credential.vault | Should -Be ''
        $config.credential.passwordSecret | Should -Be ''
    }

    It 'writes a generated config file with no secret values either' {
        $out = Join-Path $TestDrive 'generated.json'
        $null = ConvertTo-AzlSonarConfig -InfrastructureFile $script:Fixture -OutFile $out
        (Get-Content -LiteralPath $out -Raw) | Should -Not -Match 'keyvault|password|secret'
    }
}

Describe 'Infrastructure file: contract with the toolkit (N8)' {
    # The toolkit checkout ($env:AZL_TOOLKIT_ROOT, else a sibling azurelocal-toolkit folder) is the source: its current
    # example, its generated monitoring template and the monitoring schema. CI checks it out, so nothing here is skipped
    # there; on a workstation without it the toolkit tests are skipped.
    BeforeAll {
        $script:ToolkitRoot = Get-SonarToolkitRoot
        $script:NoToolkit = -not $script:ToolkitRoot -and -not (Test-SonarOnCi)
        $script:ToolkitExample = if ($script:ToolkitRoot) { Join-Path $script:ToolkitRoot 'config/variables/examples/scenarios/lom-management-ztp.yml' } else { '' }
        $script:MonitoringTemplate = if ($script:ToolkitRoot) { Join-Path $script:ToolkitRoot 'config/variables/templates/tools/monitoring.yml' } else { '' }
        $script:MonitoringSchema = if ($script:ToolkitRoot) { Join-Path $script:ToolkitRoot 'config/variables/schema/tools/monitoring.schema.json' } else { '' }
        # Every key of a YAML tree as a dotted path; a list of mappings adds '[]'.
        function script:Get-YamlKeyPath {
            param($Node, [string]$Prefix = '')
            if ($Node -is [System.Collections.IDictionary]) {
                foreach ($k in $Node.Keys) {
                    $p = if ($Prefix) { "$Prefix.$k" } else { [string]$k }
                    $p
                    Get-YamlKeyPath -Node $Node[$k] -Prefix $p
                }
            }
            elseif ($Node -is [System.Collections.IList]) { foreach ($item in $Node) { Get-YamlKeyPath -Node $item -Prefix "$Prefix[]" } }
        }
        function script:Read-SonarYamlFile {
            param([string]$Path)
            InModuleScope AzlSonar -Parameters @{ T = (Get-Content -LiteralPath $Path -Raw) } { param($T) ConvertFrom-AzlSonarYaml -Text $T }
        }
        # Is a dotted path (a list item is walked through 'items') a key of a JSON schema? $ref, allOf, anyOf and oneOf are followed.
        function script:Test-SchemaPath {
            param($Schema, $Node, [string[]]$Parts)
            if ($Parts.Count -eq 0) { return $true }
            if ($Node.Contains('$ref')) {
                $target = $Schema
                foreach ($seg in (([string]$Node['$ref']) -replace '^#/', '') -split '/') { $target = $target[$seg] }
                return (Test-SchemaPath -Schema $Schema -Node $target -Parts $Parts)
            }
            foreach ($k in 'allOf', 'anyOf', 'oneOf') { if ($Node.Contains($k)) { foreach ($b in $Node[$k]) { if (Test-SchemaPath -Schema $Schema -Node $b -Parts $Parts) { return $true } } } }
            if ($Node.Contains('items') -and $Node['items'] -is [System.Collections.IDictionary] -and (Test-SchemaPath -Schema $Schema -Node $Node['items'] -Parts $Parts)) { return $true }
            if ($Node.Contains('properties') -and $Node['properties'].Contains($Parts[0])) { return (Test-SchemaPath -Schema $Schema -Node $Node['properties'][$Parts[0]] -Parts @($Parts | Select-Object -Skip 1)) }
            return $false
        }
    }

    It 'reads the copy of the toolkit example (lom-management-ztp.yml)' {
        $config = Get-FixtureConfig -Path $script:ToolkitCopy
        $config.clusterName | Should -Be 'iic-lab-azl'
        ($config.nodes | ForEach-Object name) | Should -Be @('iic-lab-n01', 'iic-lab-n02')
        $config.nodes[0].address | Should -Be '192.0.2.11'
        $config.ztpEventsPath | Should -Match 'ztp-events\.jsonl$'
    }

    It 'has the toolkit checkout (required on CI)' {
        if ($script:NoToolkit) { Set-ItResult -Skipped -Because 'no azurelocal-toolkit checkout (set AZL_TOOLKIT_ROOT)'; return }
        $script:ToolkitRoot | Should -Not -BeNullOrEmpty -Because 'CI checks out azurelocal-toolkit and sets AZL_TOOLKIT_ROOT'
        foreach ($f in $script:ToolkitExample, $script:MonitoringTemplate, $script:MonitoringSchema) { Test-Path -LiteralPath $f -PathType Leaf | Should -BeTrue -Because $f }
    }

    It 'the fixture is the toolkit''s current example: the same schema version and the same keys' {
        if ($script:NoToolkit) { Set-ItResult -Skipped -Because 'no azurelocal-toolkit checkout (set AZL_TOOLKIT_ROOT)'; return }
        $copy = Read-SonarYamlFile -Path $script:ToolkitCopy
        $current = Read-SonarYamlFile -Path $script:ToolkitExample
        [string]$copy._metadata.schema_version | Should -Be ([string]$current._metadata.schema_version) -Because 'tests/fixtures/infrastructure.toolkit-lom-management-ztp.yml is a copy of the toolkit''s examples/scenarios/lom-management-ztp.yml: copy it again'
        $copyKeys = @(Get-YamlKeyPath -Node $copy | Sort-Object -Unique)
        $currentKeys = @(Get-YamlKeyPath -Node $current | Sort-Object -Unique)
        $diff = @(Compare-Object -ReferenceObject $currentKeys -DifferenceObject $copyKeys | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
        $diff | Should -BeNullOrEmpty -Because 'the fixture must have the keys of the toolkit''s current example (=> only in the fixture, <= only in the toolkit)'
    }

    It 'every key Sonar reads is a key of the toolkit''s monitoring schema' {
        if ($script:NoToolkit) { Set-ItResult -Skipped -Because 'no azurelocal-toolkit checkout (set AZL_TOOLKIT_ROOT)'; return }
        $schema = Get-Content -LiteralPath $script:MonitoringSchema -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        # The keys ConvertFrom-AzlSonarInfrastructureTree reads (Private/Infrastructure.ps1). Two more are read when present but
        # are not registered for monitoring yet: hardware.discovery.output_directory (registry item R10) and
        # provisioning.simplified.media_path (the gate folder fallback); a file without them still works.
        $reads = @(
            '_metadata.schema_version', 'azure.subscription_id', 'azure.resource_group', 'azure.location', 'cluster.name'
            'scenario.os_install', 'scenario.identity', 'deployment.events_directory', 'deployment.pre_cluster_verification_report_directory'
            'provisioning.simplified.evidence_path', 'provisioning.simplified.site_name', 'identity.local_admin.username'
            'identity.active_directory.netbios_name', 'identity.active_directory.domain_join_account.username', 'identity.active_directory.domain_join_account.password'
            'nodes.name', 'nodes.network_adapters.roles', 'nodes.network_adapters.ip_assignment', 'nodes.network_adapters.ip_address', 'nodes.management.ip_address'
        )
        $missing = @($reads | Where-Object { -not (Test-SchemaPath -Schema $schema -Node $schema -Parts ($_ -split '\.')) })
        $missing | Should -BeNullOrEmpty -Because 'a monitoring cut of the master file must keep every key Sonar reads'
    }

    It 'reads the toolkit''s generated monitoring template (templates/tools/monitoring.yml)' {
        if ($script:NoToolkit) { Set-ItResult -Skipped -Because 'no azurelocal-toolkit checkout (set AZL_TOOLKIT_ROOT)'; return }
        $config = Read-AzlSonarConfig -InfrastructureFile $script:MonitoringTemplate 3>$null
        $config.clusterName | Should -Not -BeNullOrEmpty
        @($config.nodes).Count | Should -BeGreaterThan 0
        $config.armEventsPath | Should -Match 'arm-deployment-events\.jsonl$'
        $config.updateEventsPath | Should -Match 'update-events\.jsonl$'
    }

    It 'agrees with the toolkit loader on the management addresses' {
        if ($script:NoToolkit) { Set-ItResult -Skipped -Because 'no azurelocal-toolkit checkout (set AZL_TOOLKIT_ROOT)'; return }
        if (-not (Get-Module -ListAvailable powershell-yaml) -and -not (Test-SonarOnCi)) { Set-ItResult -Skipped -Because 'the toolkit loader needs powershell-yaml'; return }
        Import-Module (Join-Path $script:ToolkitRoot 'scripts/common/infrastructure/AzlInfrastructure.psm1') -Force
        $infra = Import-AzlInfrastructure -Path $script:ToolkitExample
        $config = Get-FixtureConfig -Path $script:ToolkitExample
        $expected = @($infra.nodes | ForEach-Object { (Get-AzlManagementAdapter -Infrastructure $infra -Node $_).IpAddress })
        @($config.nodes | ForEach-Object address) | Should -Be $expected
        $config.clusterName | Should -Be ([string]$infra.cluster.name)
    }
}

Describe 'YAML reader subset' {
    It 'reads flow lists and maps, quoted values with #, comments and block lists' {
        $yaml = "a:`n  b: [x, `"y, z`", 3]   # comment`n  c: { k: `"v # not a comment`", n: 5 }`n  d:`n  - one`n  - two: 2`n    three: true`ne: 'it''s'`n"
        $tree = InModuleScope AzlSonar -Parameters @{ Yaml = $yaml } { param($Yaml) ConvertFrom-AzlSonarYaml -Text $Yaml }
        $tree.a.b | Should -Be @('x', 'y, z', 3)
        $tree.a.c.k | Should -Be 'v # not a comment'
        $tree.a.c.n | Should -Be 5
        $tree.a.d[0] | Should -Be 'one'
        $tree.a.d[1].two | Should -Be 2
        $tree.a.d[1].three | Should -BeTrue
        $tree.e | Should -Be "it's"
    }

    It 'refuses a second document and anchors' {
        { InModuleScope AzlSonar { ConvertFrom-AzlSonarYaml -Text "a: 1`n---`nb: 2" } } | Should -Throw '*more than one document*'
        { InModuleScope AzlSonar { ConvertFrom-AzlSonarYaml -Text "a: &x 1" } } | Should -Throw '*anchors*'
    }
}

Describe 'YAML reader: hardening' {
    BeforeAll {
        function ConvertFrom-TestYaml {
            param([string]$Yaml)
            InModuleScope AzlSonar -Parameters @{ Yaml = $Yaml } { param($Yaml) ConvertFrom-AzlSonarYaml -Text $Yaml }
        }
        function Get-TestYamlError {
            param([string]$Yaml)
            try { ConvertFrom-TestYaml -Yaml $Yaml | Out-Null; return '' } catch { return $_.Exception.Message }
        }
    }

    Context 'keys' {
        It 'reads a key that looks like a number or a boolean together with its inline value' {
            (ConvertFrom-TestYaml '712: storage')['712'] | Should -Be 'storage'
            (ConvertFrom-TestYaml 'true: x')['true'] | Should -Be 'x'
            (ConvertFrom-TestYaml '1.5: x')['1.5'] | Should -Be 'x'
            @((ConvertFrom-TestYaml "712: storage`n713: 5").Keys) | Should -Be @('712', '713')
        }

        It 'trims trailing spaces of an unquoted key' {
            $t = ConvertFrom-TestYaml "scenario : x`n`"quoted k`" : y"
            $t.Contains('scenario') | Should -BeTrue
            $t['scenario'] | Should -Be 'x'
            $t['quoted k'] | Should -Be 'y'
        }

        It 'refuses a duplicate key and names both lines' {
            { ConvertFrom-TestYaml "a: 1`nb: 2`na: 3" } | Should -Throw "*YAML line 3: duplicate key 'a' (first on line 1).*"
            { ConvertFrom-TestYaml "a:`n  x: 1`n  y: 2`n  `"x`": 3" } | Should -Throw "*YAML line 4: duplicate key 'x' (first on line 2).*"
            { ConvertFrom-TestYaml "n:`n- k: 1`n  k: 2" } | Should -Throw "*YAML line 3: duplicate key 'k' (first on line 2).*"
        }

        It 'allows the same key in different maps' {
            $t = ConvertFrom-TestYaml "a:`n  k: 1`nb:`n  k: 2"
            $t.a.k | Should -Be 1
            $t.b.k | Should -Be 2
        }
    }

    Context 'comments and quotes' {
        It 'keeps a doubled apostrophe inside a single-quoted scalar and still strips a real comment' {
            (ConvertFrom-TestYaml "notes: 'it''s # not a comment'").notes | Should -Be "it's # not a comment"
            (ConvertFrom-TestYaml "notes: 'a' # real comment").notes | Should -Be 'a'
            (ConvertFrom-TestYaml "notes: ''  # empty").notes | Should -Be ''
        }

        It 'treats a # not preceded by a space as part of the value' {
            (ConvertFrom-TestYaml 'url: https://example.com#frag').url | Should -Be 'https://example.com#frag'
        }

        It 'keeps a # inside quotes and strips the comment after a plain value that has apostrophes' {
            (ConvertFrom-TestYaml 'notes: "GAP: # not a comment"').notes | Should -Be 'GAP: # not a comment'
            (ConvertFrom-TestYaml "notes: node's BMC        # node's `"port`"").notes | Should -Be "node's BMC"
        }

        It 'reads colons in plain values' {
            (ConvertFrom-TestYaml 'mac: 00:00:5E:00:53:11').mac | Should -Be '00:00:5E:00:53:11'
            (ConvertFrom-TestYaml 'ref: keyvault://vault/name').ref | Should -Be 'keyvault://vault/name'
        }
    }

    Context 'scalars' {
        It 'keeps yes as text, big numbers as text and small integers as integers' {
            $t = ConvertFrom-TestYaml "enabled: yes`nn: 4294967295`nm: -1`nz: 0`nname: 007`nd: 1.5"
            $t.enabled | Should -BeOfType ([string])
            $t.enabled | Should -Be 'yes'
            $t.n | Should -BeOfType ([string])
            $t.n | Should -Be '4294967295'
            $t.m | Should -BeOfType ([int])
            $t.m | Should -Be -1
            $t.z | Should -Be 0
            $t.name | Should -BeOfType ([string])
            $t.name | Should -Be '007'
            $t.d | Should -BeOfType ([double])
        }

        It 'reads schema_version quoted, unquoted and as a decimal: the major is 5 in every case' {
            foreach ($v in '"5.3.0"', '5.3.0', '5.3', '"5.3"', '5') {
                $path = New-ModifiedInfrastructure -Edit { param($t) $t -replace 'schema_version: "5.3.0"', "schema_version: $v" }
                (Get-FixtureConfig -Path $path).clusterName | Should -Be 'example-clus01'
            }
            $path = New-ModifiedInfrastructure -Edit { param($t) $t -replace 'schema_version: "5.3.0"', 'schema_version: 4.2' }
            { Get-FixtureConfig -Path $path } | Should -Throw "*_metadata.schema_version : is '4.2'*"
        }
    }

    Context 'lists' {
        It 'reads a list at the same indent as its key' {
            $t = ConvertFrom-TestYaml "roles:`n- management`n- compute`nafter: 1"
            @($t.roles) | Should -Be @('management', 'compute')
            $t.after | Should -Be 1
        }
    }

    Context 'files' {
        It 'reads a CRLF file' {
            $t = ConvertFrom-TestYaml "a:`r`n  b: 1`r`n  c: |`r`n    text`r`n    more`r`nd: [x, y]`r`n"
            $t.a.b | Should -Be 1
            $t.a.c | Should -Be "text`nmore`n"
            @($t.d) | Should -Be @('x', 'y')
        }

        It 'reads a file whose first line is a comment, and an empty file' {
            (ConvertFrom-TestYaml "# header comment`n`na: 1").a | Should -Be 1
            (ConvertFrom-TestYaml '').Count | Should -Be 0
            (ConvertFrom-TestYaml "# only a comment`n").Count | Should -Be 0
        }

        It 'ignores a byte order mark at the start of the text' {
            $t = ConvertFrom-TestYaml ([string][char]0xFEFF + 'abc: 1')
            $t['abc'] | Should -Be 1
        }

        It 'accepts a document start with a comment and rejects content after a document end' {
            (ConvertFrom-TestYaml "--- # the file`na: 1").a | Should -Be 1
            (ConvertFrom-TestYaml "a: 1`n...").a | Should -Be 1
            { ConvertFrom-TestYaml "a: 1`n...`nb: 2" } | Should -Throw '*YAML line 3: more than one document*'
            { ConvertFrom-TestYaml "a: 1`n...`n---`nb: 2" } | Should -Throw '*more than one document*'
            { ConvertFrom-TestYaml "a: 1`n--- # next`nb: 2" } | Should -Throw '*YAML line 2: more than one document*'
        }
    }

    Context 'block scalars' {
        It 'keeps blank lines, relative indentation and # lines inside a literal block' {
            $yaml = "a:`n  note: |`n    first line`n`n    # looks like a comment`n      indented`n    last`n  after: 1`nb: 2`n"
            $t = ConvertFrom-TestYaml $yaml
            $t.a.note | Should -Be "first line`n`n# looks like a comment`n  indented`nlast`n"
            $t.a.after | Should -Be 1
            $t.b | Should -Be 2
        }

        It 'applies the chomping indicators' {
            (ConvertFrom-TestYaml "k: |-`n  a`n  b`nz: 1").k | Should -Be "a`nb"
            (ConvertFrom-TestYaml "k: |`n  a`n`n`nz: 1").k | Should -Be "a`n"
            (ConvertFrom-TestYaml "k: |+`n  a`n`nz: 1").k | Should -Be "a`n`n"
            (ConvertFrom-TestYaml "k: |`n  a`n").k | Should -Be "a`n"
            (ConvertFrom-TestYaml "k: |`nz: 1").k | Should -Be ''
        }

        It 'folds single newlines of a > block and keeps paragraph breaks' {
            (ConvertFrom-TestYaml "k: >`n  one`n  two`n`n  three`nz: 1").k | Should -Be "one two`nthree`n"
            (ConvertFrom-TestYaml "k: >-`n  one`n  two`nz: 1").k | Should -Be 'one two'
        }

        It 'reads a block scalar in a list item and returns to the list' {
            $t = ConvertFrom-TestYaml "items:`n  - name: a`n    note: |`n      x`n`n      y`n  - name: b"
            $t.items[0].note | Should -Be "x`n`ny`n"
            $t.items[1].name | Should -Be 'b'
        }

        It 'refuses a header it does not support' {
            { ConvertFrom-TestYaml "k: |2`n   a" } | Should -Throw '*YAML line 1: this block scalar header is not supported*'
        }
    }

    Context 'errors name the line and never echo it' {
        It 'puts the line number on anchor, alias and tag errors' {
            { ConvertFrom-TestYaml "a: 1`nb: &x 2" } | Should -Throw '*YAML line 2:*anchors, aliases and tags*'
            { ConvertFrom-TestYaml "a: 1`nl:`n  - *x" } | Should -Throw '*YAML line 3:*anchors, aliases and tags*'
            { ConvertFrom-TestYaml 'a: !!str 1' } | Should -Throw '*YAML line 1:*'
        }

        It 'names the line of a flow error' {
            { ConvertFrom-TestYaml "a: 1`nb: [x, y" } | Should -Throw '*YAML line 2:*'
            { ConvertFrom-TestYaml "a: 1`nb: { k }" } | Should -Throw "*YAML line 2: expected ':' after a key in a flow map*"
        }

        It 'does not print the content of the failing line' {
            foreach ($y in 'a: "topsecretvalue', 'a: [topsecretvalue, y', 'a: { topsecretvalue', "a: 'x' topsecretvalue", 'topsecretvalue', 'a: &topsecretvalue 1', "l:`n- - topsecretvalue") {
                $m = Get-TestYamlError -Yaml $y
                $m | Should -Match 'YAML line \d+:'
                $m | Should -Not -Match 'topsecretvalue'
            }
        }

        It 'says what is not supported when a quoted value continues on the next line' {
            { ConvertFrom-TestYaml "a: 1`nb: `"long`n  more`"" } | Should -Throw '*YAML line 2: a double-quoted value that continues on the next line is not supported (put it on one line).*'
            { ConvertFrom-TestYaml "b: 'long`n  more'" } | Should -Throw '*YAML line 1: a single-quoted value that continues on the next line is not supported*'
            { ConvertFrom-TestYaml "l:`n  - `"long`n    more`"" } | Should -Throw '*YAML line 2: a double-quoted value that continues*'
        }

        It 'says what is not supported for a multi-line flow collection' {
            { ConvertFrom-TestYaml "a: [x,`n  y]" } | Should -Throw '*YAML line 1: a [[] ... ] flow collection that continues on the next line is not supported (put it on one line*'
            { ConvertFrom-TestYaml "a: 1`nb: {`n  k: v }" } | Should -Throw '*YAML line 2: a { ... } flow collection that continues on the next line is not supported*'
        }

        It 'says what is not supported for a nested list on one line' {
            { ConvertFrom-TestYaml "l:`n  - - a`n    - b" } | Should -Throw "*YAML line 2: a nested list on one line ('- - item') is not supported (use a block list).*"
        }

        It 'rejects text after a closing quote or bracket' {
            { ConvertFrom-TestYaml 'notes: "a"junk' } | Should -Throw '*YAML line 1: text after the closing quote*'
            { ConvertFrom-TestYaml "a: 1`nnotes: 'a'junk" } | Should -Throw '*YAML line 2: text after the closing quote*'
            { ConvertFrom-TestYaml 'notes: ["a"junk]' } | Should -Throw '*YAML line 1: text after the closing quote*'
            { ConvertFrom-TestYaml 'notes: [a] junk' } | Should -Throw '*YAML line 1: text after the closing bracket*'
        }

        It 'rejects a duplicate key in a flow map' {
            { ConvertFrom-TestYaml 'a: { k: 1, k: 2 }' } | Should -Throw "*YAML line 1: duplicate key 'k'*"
        }
    }

    Context 'limits' {
        It 'refuses input over the size limit' {
            InModuleScope AzlSonar {
                $old = $script:AzlSonarYamlMaxBytes
                $script:AzlSonarYamlMaxBytes = 50
                try {
                    { ConvertFrom-AzlSonarYaml -Text ('a: ' + ('x' * 100)) } | Should -Throw '*YAML input is larger than the 2 MB limit*'
                    ConvertFrom-AzlSonarYaml -Text 'a: x' | Should -Not -BeNullOrEmpty
                }
                finally { $script:AzlSonarYamlMaxBytes = $old }
            }
        }

        It 'refuses nesting deeper than 40 levels with a clean error, for block and flow collections' {
            $deep = (0..44 | ForEach-Object { (' ' * $_) + "k${_}:" }) -join "`n"
            { ConvertFrom-TestYaml ($deep + ' 1') } | Should -Throw '*YAML line 41: nesting deeper than 40 levels is not supported*'
            { ConvertFrom-TestYaml ('a: ' + ('[' * 60) + (']' * 60)) } | Should -Throw '*YAML line 1: nesting deeper than 40 levels is not supported*'
            { ConvertFrom-TestYaml ('a: ' + ('{ k: ' * 60) + '1' + (' }' * 60)) } | Should -Throw '*nesting deeper than 40 levels*'
            { ConvertFrom-TestYaml ("l:`n" + ((0..44 | ForEach-Object { (' ' * ($_ * 2)) + '- ' }) -join "`n") + 'x') } | Should -Throw '*nesting deeper than 40 levels*'
        }

        It 'reads 30 levels of nesting' {
            $ok = (0..29 | ForEach-Object { (' ' * $_) + "k${_}:" }) -join "`n"
            (ConvertFrom-TestYaml ($ok + ' 1')).k0 | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Overrides and backward compatibility' {
    It '-ConfigPath still reads the example config exactly as before' {
        $config = Read-AzlSonarConfig -Path $script:SonarExampleConfig
        $config.clusterName | Should -Be 'clus01'
        $config.seedNode.name | Should -Be 'node01'
        $config.pollSeconds | Should -Be 20
        $config.sourcePath | Should -Be (Resolve-Path -LiteralPath $script:SonarExampleConfig).ProviderPath
    }

    It '-PollSeconds overrides the file, for the infrastructure file and for a config file' {
        (Read-AzlSonarConfig -InfrastructureFile $script:Fixture -PollSeconds 45).pollSeconds | Should -Be 45
        $config = Read-AzlSonarConfig -Path $script:SonarExampleConfig -PollSeconds 30
        $config.pollSeconds | Should -Be 30
        $config.logs.pollSeconds | Should -Be 30
    }

    It 'rejects a -PollSeconds outside 5 to 3600' {
        { Read-AzlSonarConfig -InfrastructureFile $script:Fixture -PollSeconds 2 } | Should -Throw '*pollSeconds*'
    }

    It 'the commented example config is valid (comments are allowed)' {
        $path = Join-Path $script:SonarRepoRoot 'examples/sonar.config.commented.jsonc'
        @(Test-AzlSonarConfig -Path $path).Count | Should -Be 0
        @((Read-AzlSonarConfig -Path $path).nodes).Count | Should -Be 2
    }

    It 'Start-AzlSonarServer without a config, or with both, says what to do' {
        { Start-AzlSonarServer } | Should -Throw '*-InfrastructureFile*'
        { Start-AzlSonarServer -ConfigPath a.json -InfrastructureFile b.yml } | Should -Throw '*not both*'
    }
}

Describe 'Live change detection of the master file' {
    It 'stays quiet while the node set is unchanged, and asks for a restart when a node is added' {
        $work = Join-Path $TestDrive 'live.yml'
        Copy-Item -LiteralPath $script:Fixture -Destination $work
        $result = InModuleScope AzlSonar -Parameters @{ Path = $work } {
            param($Path)
            $config = Read-AzlSonarConfig -InfrastructureFile $Path
            $state = @{ LastWrite = (Get-Item -LiteralPath $Path).LastWriteTimeUtc; Nodes = @($config.nodes); LastError = '' }
            $none = Invoke-AzlSonarInfrastructureCheck -Path $Path -State $state
            $added = "  - name: `"example-n04`"`n    network_adapters:`n      - { name: `"E1`", roles: [management], ip_assignment: static, ip_address: `"192.0.2.14`" }`n`nhardware:"
            $text = (Get-Content -LiteralPath $Path -Raw) -replace '(?m)^hardware:', $added
            Set-Content -LiteralPath $Path -Value $text -Encoding utf8
            (Get-Item -LiteralPath $Path).LastWriteTimeUtc = $state.LastWrite.AddMinutes(1)
            $notice = Invoke-AzlSonarInfrastructureCheck -Path $Path -State $state
            $again = Invoke-AzlSonarInfrastructureCheck -Path $Path -State $state
            @{ None = $none; Notice = $notice; Again = $again }
        }
        $result.None | Should -BeNullOrEmpty
        $result.Notice | Should -Match 'added: example-n04'
        $result.Notice | Should -Match 'Restart Sonar'
        $result.Again | Should -BeNullOrEmpty
    }
}

Describe 'Infrastructure file: one events folder shared with the toolkit (D45)' {
    BeforeAll {
        $script:DefaultRoot = if ($IsWindows -and $env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }
    }

    It 'reads the OS configuration and ARM feeds from the default folder (ProgramData, AzureLocalToolkit, cluster name, events) when the file sets no folder' {
        $config = Get-FixtureConfig
        $folder = [System.IO.Path]::Combine($script:DefaultRoot, 'AzureLocalToolkit', 'example-clus01', 'events')
        $config.osConfigEventsPath | Should -Be (Join-Path $folder 'os-configuration-events.jsonl')
        $config.armEventsPath | Should -Be (Join-Path $folder 'arm-deployment-events.jsonl')
    }

    It 'reads them from deployment.events_directory when the file sets it, a relative path from the folder of the file' {
        $absolute = New-ModifiedInfrastructure { param($t) $t + "`ndeployment:`n  events_directory: 'D:\Data\azl-events\example-clus01'`n" }
        $config = Get-FixtureConfig -Path $absolute
        if ($IsWindows) { $config.osConfigEventsPath | Should -Be 'D:\Data\azl-events\example-clus01\os-configuration-events.jsonl' }
        $relative = New-ModifiedInfrastructure { param($t) $t + "`ndeployment:`n  events_directory: 'events'`n" }
        $config = Get-FixtureConfig -Path $relative
        $config.armEventsPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Join-Path $TestDrive 'events') 'arm-deployment-events.jsonl')))
    }

    It 'follows the verification gate report directory by the toolkit rule: next to the evidence folder, not inside it' {
        $config = Get-FixtureConfig
        $config.verificationEventsPath | Should -Be ([System.IO.Path]::Combine('D:\Data\azl-ztp\example', 'arm-report', 'verification', 'live', 'precluster-verification-events.jsonl'))
        $set = New-ModifiedInfrastructure { param($t) $t + "`ndeployment:`n  pre_cluster_verification_report_directory: 'gate'`n" }
        (Get-FixtureConfig -Path $set).verificationEventsPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Join-Path $TestDrive 'gate') 'precluster-verification-events.jsonl')))
    }

    It 'resolves the same folder as the toolkit (the toolkit checkout is required on CI)' {
        $root = Get-SonarToolkitRoot
        if ((-not $root -or -not (Get-Module -ListAvailable powershell-yaml)) -and -not (Test-SonarOnCi)) { Set-ItResult -Skipped -Because 'no azurelocal-toolkit checkout (set AZL_TOOLKIT_ROOT) or no powershell-yaml'; return }
        Import-Module (Join-Path $root 'scripts/common/infrastructure/AzlInfrastructure.psm1') -Force
        Get-Command Resolve-AzlEventsDirectory -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'the toolkit resolves the events folder (D45)'
        $infra = Import-AzlInfrastructure -Path $script:ToolkitCopy -SkipValidation
        $config = Get-FixtureConfig -Path $script:ToolkitCopy
        $config.osConfigEventsPath | Should -Be (Join-Path (Resolve-AzlEventsDirectory -Infrastructure $infra -InfrastructureFile $script:ToolkitCopy) 'os-configuration-events.jsonl')
    }
}
