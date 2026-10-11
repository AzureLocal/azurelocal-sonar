#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
}

Describe 'Test-AzlSonarConfig' {
    It 'accepts the example config with no problems' {
        $config = New-SonarConfigObject
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        @($problems).Count | Should -Be 0
    }

    It 'reports an empty config' {
        $problems = InModuleScope AzlSonar { Test-AzlSonarConfig -Config $null }
        $problems | Should -Contain 'The config is empty.'
    }

    It 'reports every missing required field at once' {
        $config = [pscustomobject]@{}
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'subscriptionId must be a GUID.'
        ($problems -match '^resourceGroup must be') | Should -Not -BeNullOrEmpty
        ($problems -match '^clusterName is required') | Should -Not -BeNullOrEmpty
        $problems | Should -Contain 'identityModel must be LocalIdentity or ActiveDirectory.'
        $problems | Should -Contain 'nodes must list at least one node.'
    }

    It 'reports a node without name or address' {
        $config = New-SonarConfigObject
        $config.nodes = @([pscustomobject]@{ arcMachineName = 'x' })
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'nodes[0].name is required.'
        $problems | Should -Contain 'nodes[0].address is required (host name or IP address).'
    }

    It 'rejects two seed nodes' {
        $config = New-SonarConfigObject
        $config.nodes[1] | Add-Member -NotePropertyName seed -NotePropertyValue $true -Force
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'Only one node can be the seed node (seed: true).'
    }

    It 'rejects duplicate node names (case-insensitive)' {
        $config = New-SonarConfigObject
        $config.nodes[1].name = 'NODE01'
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        ($problems -match "nodes\[1\]\.name 'NODE01' is listed more than once") | Should -Not -BeNullOrEmpty
    }

    It 'rejects a non-boolean seed' {
        $config = New-SonarConfigObject
        $config.nodes[0].seed = 'yes'
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'nodes[0].seed must be true or false.'
    }

    It 'rejects credential.<Key> in the config (secrets never go in the file)' -TestCases @(
        @{ Key = 'password' }
        @{ Key = 'secret' }
        @{ Key = 'secretValue' }
    ) {
        param($Key)
        $config = New-SonarConfigObject
        $config.credential | Add-Member -NotePropertyName $Key -NotePropertyValue 'P@ssw0rd!' -Force
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        ($problems -match "^credential\.$Key is not allowed") | Should -Not -BeNullOrEmpty
    }

    It 'requires vault and secret names for keyvault' {
        $config = New-SonarConfigObject
        $config.credential = [pscustomobject]@{ source = 'keyvault' }
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'credential.vault is required when credential.source is keyvault.'
        $problems | Should -Contain 'credential.usernameSecret is required when credential.source is keyvault.'
        $problems | Should -Contain 'credential.passwordSecret is required when credential.source is keyvault.'
    }

    It 'rejects an unknown credential source' {
        $config = New-SonarConfigObject
        $config.credential.source = 'file'
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'credential.source must be prompt, parameter or keyvault.'
    }

    It 'rejects bad api versions, pollSeconds and log limits' {
        $config = New-SonarConfigObject
        $config.apiVersion = 'latest'
        $config.edgeApiVersion = '2025-12'
        $config.pollSeconds = 1
        $config.logs.maxLinesPerPoll = 0
        $config.logs.activeWindowMinutes = 'thirty'
        $config.logs.include = @()
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'apiVersion must look like 2025-09-15 or 2025-09-15-preview.'
        $problems | Should -Contain 'edgeApiVersion must look like 2025-09-15 or 2025-09-15-preview.'
        $problems | Should -Contain 'pollSeconds must be a whole number from 5 to 3600.'
        $problems | Should -Contain 'logs.maxLinesPerPoll must be a whole number from 1 to 10000.'
        $problems | Should -Contain 'logs.activeWindowMinutes must be a whole number from 1 to 10080.'
        $problems | Should -Contain 'logs.include must be a list of file name patterns such as *.log.'
    }

    It 'rejects an unknown logs.transport' {
        $config = New-SonarConfigObject
        $config.logs | Add-Member -NotePropertyName transport -NotePropertyValue 'rdp'
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        $problems | Should -Contain 'logs.transport must be auto, winrm or ssh.'
    }

    It 'accepts logs.transport <Transport>' -TestCases @(@{ Transport = 'auto' }, @{ Transport = 'winrm' }, @{ Transport = 'ssh' }) {
        param($Transport)
        $config = New-SonarConfigObject
        $config.logs | Add-Member -NotePropertyName transport -NotePropertyValue $Transport
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        @($problems).Count | Should -Be 0
    }

    It 'allows an empty exclude list' {
        $config = New-SonarConfigObject
        $config.logs.exclude = @()
        $problems = InModuleScope AzlSonar -Parameters @{ Config = $config } { param($Config) Test-AzlSonarConfig -Config $Config }
        @($problems).Count | Should -Be 0
    }
}

Describe 'Read-AzlSonarConfig' {
    It 'reads the example config file' {
        $config = Read-AzlSonarConfig -Path $script:SonarExampleConfig
        $config.subscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
        $config.resourceGroup | Should -Be 'rg-example-azl'
        $config.clusterName | Should -Be 'clus01'
        $config.identityModel | Should -Be 'LocalIdentity'
        $config.pollSeconds | Should -Be 20
        @($config.nodes).Count | Should -Be 2
        $config.seedNode.name | Should -Be 'node01'
        $config.seedNode.address | Should -Be '192.0.2.11'
        $config.nodes[1].seed | Should -BeFalse
        $config.logs.include | Should -Be @('*.log', '*.txt', '*.xml')
        $config.logs.exclude | Should -Be @('*.etl')
        $config.logs.recurseDepth | Should -Be 3
        $config.credential.source | Should -Be 'prompt'
    }

    It 'throws for a missing file' {
        { Read-AzlSonarConfig -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*config file not found*'
    }

    It 'throws for invalid JSON' {
        { Read-AzlSonarConfig -Json '{ not json' } | Should -Throw '*is not valid JSON*'
    }

    It 'throws one error listing every problem' {
        $config = New-SonarConfigObject
        $config.subscriptionId = 'abc'
        $config.identityModel = 'Workgroup'
        $json = ConvertTo-SonarConfigJson $config
        $message = $null
        try { Read-AzlSonarConfig -Json $json } catch { $message = $_.Exception.Message }
        $message | Should -BeLike '*is not valid:*'
        $message | Should -BeLike '*subscriptionId must be a GUID.*'
        $message | Should -BeLike '*identityModel must be LocalIdentity or ActiveDirectory.*'
    }

    It 'throws when two nodes are seeds' {
        $config = New-SonarConfigObject
        $config.nodes[1] | Add-Member -NotePropertyName seed -NotePropertyValue $true -Force
        { Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config) } | Should -Throw '*Only one node can be the seed node*'
    }

    It 'uses the first node as seed with a warning when no node is marked' {
        $config = New-SonarConfigObject
        $config.nodes[0].PSObject.Properties.Remove('seed')
        $warnings = $null
        $result = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config) -WarningVariable warnings -WarningAction SilentlyContinue
        $result.seedNode.name | Should -Be 'node01'
        $result.nodes[0].seed | Should -BeTrue
        $result.nodes[1].seed | Should -BeFalse
        @($warnings).Count | Should -Be 1
        [string]$warnings[0] | Should -BeLike '*No node is marked seed*node01*'
    }

    It 'honours a seed on a node other than the first' {
        $config = New-SonarConfigObject
        $config.nodes[0].seed = $false
        $config.nodes[1] | Add-Member -NotePropertyName seed -NotePropertyValue $true -Force
        $result = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config) -WarningAction Stop
        $result.seedNode.name | Should -Be 'node02'
    }

    It 'throws when the credential holds a password' {
        $config = New-SonarConfigObject
        $config.credential | Add-Member -NotePropertyName password -NotePropertyValue 'P@ssw0rd!'
        { Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config) } | Should -Throw '*credential.password is not allowed*'
    }

    Context 'defaults' {
        BeforeAll {
            $minimal = @'
{
  "subscriptionId": "AAAAAAAA-0000-0000-0000-000000000000",
  "resourceGroup": "rg-example-azl",
  "clusterName": "clus01",
  "identityModel": "ActiveDirectory",
  "nodes": [ { "name": "node01", "address": "192.0.2.11" } ]
}
'@
            $script:minimalConfig = Read-AzlSonarConfig -Json $minimal -WarningAction SilentlyContinue
        }

        It 'applies apiVersion and edgeApiVersion defaults' {
            $script:minimalConfig.apiVersion | Should -Be '2025-09-15-preview'
            $script:minimalConfig.edgeApiVersion | Should -Be '2025-12-01-preview'
        }

        It 'applies pollSeconds and lowercases the subscription id' {
            $script:minimalConfig.pollSeconds | Should -Be 20
            $script:minimalConfig.subscriptionId | Should -Be 'aaaaaaaa-0000-0000-0000-000000000000'
        }

        It 'applies the log path, include and exclude defaults' {
            $script:minimalConfig.logs.paths | Should -Be @(
                'C:\CloudContent\MASLogs',
                'C:\MASLogs',
                'C:\CloudDeployment\Logs',
                'C:\Observability',
                'C:\Windows\System32\Bootstrap\Logs'
            )
            $script:minimalConfig.logs.include | Should -Be @('*.log', '*.txt', '*.xml')
            $script:minimalConfig.logs.exclude | Should -Be @('*.etl')
        }

        It 'applies the log limit defaults' {
            $script:minimalConfig.logs.activeWindowMinutes | Should -Be 30
            $script:minimalConfig.logs.maxLinesPerPoll | Should -Be 500
            $script:minimalConfig.logs.recurseDepth | Should -Be 3
            $script:minimalConfig.logs.pollSeconds | Should -Be 20
            $script:minimalConfig.logs.transport | Should -Be 'auto'
        }

        It 'defaults arcMachineName to the node name and credential source to prompt' {
            $script:minimalConfig.nodes[0].arcMachineName | Should -Be 'node01'
            $script:minimalConfig.nodes[0].arcMachineNameSet | Should -BeFalse -Because 'the poller may resolve it (simplified provisioning names it <device-id>-1)'
            $script:minimalConfig.credential.source | Should -Be 'prompt'
            $script:minimalConfig.identityModel | Should -Be 'ActiveDirectory'
        }

        It 'defaults provisioningRoute to auto' {
            $script:minimalConfig.provisioningRoute | Should -Be 'auto'
        }
    }

    It 'keeps an explicit arcMachineName and marks it as set' {
        $config = New-SonarConfigObject
        $config.nodes[0] | Add-Member -NotePropertyName arcMachineName -NotePropertyValue '11111111-1111-1111-1111-111111111111-1' -Force
        $read = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config)
        $read.nodes[0].arcMachineName | Should -Be '11111111-1111-1111-1111-111111111111-1'
        $read.nodes[0].arcMachineNameSet | Should -BeTrue
        $read.nodes[1].arcMachineNameSet | Should -BeFalse
    }

    It 'accepts provisioningRoute <Route> (normalised to lower case)' -TestCases @(
        @{ Route = 'auto'; Expected = 'auto' }
        @{ Route = 'simplified'; Expected = 'simplified' }
        @{ Route = 'oem-image'; Expected = 'oem-image' }
        @{ Route = 'OEM-Image'; Expected = 'oem-image' }
    ) {
        param($Route, $Expected)
        $config = New-SonarConfigObject
        $config.provisioningRoute = $Route
        (Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config)).provisioningRoute | Should -Be $Expected
    }

    It 'rejects an unknown provisioningRoute' {
        $config = New-SonarConfigObject
        $config.provisioningRoute = 'ztp'
        { Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config) } | Should -Throw '*provisioningRoute must be auto, simplified or oem-image.*'
    }

    It 'keeps logs.transport (the tailer reads it; it was dropped before)' {
        $config = New-SonarConfigObject
        $config.logs | Add-Member -NotePropertyName transport -NotePropertyValue 'SSH'
        (Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config)).logs.transport | Should -Be 'ssh'
    }

    It 'keeps Key Vault secret names as names only' {
        $config = New-SonarConfigObject
        $config.credential = [pscustomobject]@{ source = 'keyvault'; vault = 'kv-example'; usernameSecret = 'log-user'; passwordSecret = 'log-pass' }
        $result = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config)
        $result.credential.source | Should -Be 'keyvault'
        $result.credential.vault | Should -Be 'kv-example'
        $result.credential.passwordSecret | Should -Be 'log-pass'
    }
}

Describe 'ConvertTo-AzlSonarPublicConfig' {
    It 'serves no secrets, secret names or addresses' {
        $config = New-SonarConfigObject
        $config.credential = [pscustomobject]@{ source = 'keyvault'; vault = 'kv-example'; usernameSecret = 'log-user-secret'; passwordSecret = 'log-pass-secret' }
        $read = Read-AzlSonarConfig -Json (ConvertTo-SonarConfigJson $config)
        $json = InModuleScope AzlSonar -Parameters @{ Config = $read } {
            param($Config)
            ConvertTo-AzlSonarJson (ConvertTo-AzlSonarPublicConfig -Config $Config -StartedAt ([datetime]'2026-10-10T18:00:00Z'))
        }
        $json | Should -Not -Match 'kv-example|log-user-secret|log-pass-secret|192\.0\.2\.|credential|subscriptionId|00000000-0000'
        $public = $json | ConvertFrom-Json
        $public.cluster | Should -Be 'clus01'
        @($public.nodes).Count | Should -Be 2
        $public.nodes[0].PSObject.Properties.Name | Should -Be @('name', 'seed')
    }

    It 'carries the start time and the back-end instance id (the page detects a restart by them)' {
        $read = Read-AzlSonarConfig -Path $script:SonarExampleConfig
        $public = InModuleScope AzlSonar -Parameters @{ Config = $read } {
            param($Config)
            ConvertTo-AzlSonarPublicConfig -Config $Config -StartedAt ([datetime]'2026-10-10T18:00:00Z') -ServerId 'abc123'
        }
        $public.startedAt | Should -Be '2026-10-10T18:00:00Z'
        $public.serverId | Should -Be 'abc123'
        $public.provisioningRoute | Should -Be 'auto'
    }
}
