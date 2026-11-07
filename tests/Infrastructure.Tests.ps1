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

Describe 'Infrastructure file: contract with the toolkit' {
    It 'reads a copy of the toolkit example (lom-management-ztp.yml)' {
        $config = Get-FixtureConfig -Path $script:ToolkitCopy
        $config.clusterName | Should -Be 'iic-lab-azl'
        ($config.nodes | ForEach-Object name) | Should -Be @('iic-lab-n01', 'iic-lab-n02')
        $config.nodes[0].address | Should -Be '192.0.2.11'
        $config.ztpEventsPath | Should -Match 'ztp-events\.jsonl$'
    }

    It 'agrees with the toolkit loader when it is importable (skipped otherwise)' -Skip:(-not ((Test-Path "$PSScriptRoot/../../azurelocal-toolkit/scripts/common/infrastructure/AzlInfrastructure.psm1") -and (Get-Module -ListAvailable powershell-yaml))) {
        Import-Module "$PSScriptRoot/../../azurelocal-toolkit/scripts/common/infrastructure/AzlInfrastructure.psm1" -Force
        $infra = Import-AzlInfrastructure -Path $script:ToolkitCopy
        $config = Get-FixtureConfig -Path $script:ToolkitCopy
        $expected = @($infra.nodes | ForEach-Object { (Get-AzlManagementAdapter -Infrastructure $infra -Node $_).IpAddress })
        @($config.nodes | ForEach-Object address) | Should -Be $expected
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
