#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The read-only facts behind the Help box (/api/about) and the Details pop-down (/api/details): what Sonar collected and
# is using, where each value came from, and what is never shown (secrets, the full subscription id).

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule

    $script:Json = New-SonarConfigObject
    $script:Json | Add-Member -NotePropertyName location -NotePropertyValue 'eastus' -Force
    $script:Json.subscriptionId = '11111111-2222-3333-4444-555555555555'
    $script:Json.credential = [pscustomobject]@{ source = 'keyvault'; vault = 'kv-sonar-test'; usernameSecret = 'sonar-user-secret'; passwordSecret = 'sonar-pass-secret' }
    $script:ConfigPath = Join-Path $TestDrive 'sonar.config.json'
    ConvertTo-SonarConfigJson $script:Json | Set-Content -LiteralPath $script:ConfigPath
    $script:Config = Read-AzlSonarConfig -Path $script:ConfigPath
}

Describe 'Get-AzlSonarAbout' {
    It 'gives the version and the documentation links' {
        $a = InModuleScope AzlSonar { Get-AzlSonarAbout -Version '1.2.3' }
        $a.version | Should -Be '1.2.3'
        @($a.links).id | Should -Be @('docs', 'run', 'config', 'troubleshooting', 'github')
        @($a.links).url | ForEach-Object { $_ | Should -Match '^https://' }
        ($a.links | Where-Object id -eq 'docs').url | Should -Be 'https://azurelocal.cloud/azurelocal-sonar/'
    }

    It 'reads the version served by the page from the module manifest' {
        $manifest = Import-PowerShellDataFile -LiteralPath $script:SonarManifest
        $a = InModuleScope AzlSonar -Parameters @{ V = [string](Get-Module -Name AzlSonar).Version } { param($V) Get-AzlSonarAbout -Version $V }
        $a.version | Should -Be $manifest.ModuleVersion
    }
}

Describe 'Read-AzlSonarConfig: sourceKind and location' {
    It 'marks a config file and keeps the region' {
        $script:Config.sourceKind | Should -Be 'config'
        $script:Config.location | Should -Be 'eastus'
    }

    It 'marks the master infrastructure file and reads azure.location' {
        $file = Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.toolkit-lom-management-ztp.yml'
        $c = Read-AzlSonarConfig -InfrastructureFile $file 3>$null
        $c.sourceKind | Should -Be 'infrastructure'
        $c.location | Should -Be 'eastus'
    }

    It 'leaves the region empty when the file has none' {
        $file = Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml'
        (Read-AzlSonarConfig -InfrastructureFile $file 3>$null).location | Should -Be ''
    }
}

Describe 'New-AzlSonarDetailFact' {
    It 'shows only the first 8 characters of the subscription' {
        $f = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) New-AzlSonarDetailFact -Config $C }
        $f.subscriptionShort | Should -Be '11111111...'
        (ConvertTo-Json $f -Depth 8) | Should -Not -Match '2222-3333|555555555555'
    }

    It 'never carries a credential, a vault or a secret name' {
        $f = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) New-AzlSonarDetailFact -Config $C }
        (ConvertTo-Json $f -Depth 8) | Should -Not -Match 'kv-sonar-test|sonar-user-secret|sonar-pass-secret|passwordSecret'
    }

    It 'lists the nodes with their addresses and the seed' {
        $f = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) New-AzlSonarDetailFact -Config $C }
        @($f.nodes).name | Should -Be @('node01', 'node02')
        @($f.nodes | ForEach-Object { $_['address'] }) | Should -Be @('192.0.2.11', '192.0.2.12')
        @($f.nodes | Where-Object seed).name | Should -Be 'node01'
    }

    It 'flags what is not set, with the key of the file Sonar was started from' {
        $json = New-SonarConfigObject
        $json.provisioningRoute = 'simplified'
        $path = Join-Path $TestDrive 'bare.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
        $bare = Read-AzlSonarConfig -Path $path
        $f = InModuleScope AzlSonar -Parameters @{ C = $bare } { param($C) New-AzlSonarDetailFact -Config $C }
        @($f.notSet).setting | Should -Be @('location', 'ztpEvents', 'osConfigEvents', 'armEvents', 'verificationEvents', 'discovery')
        (@($f.notSet) | Where-Object setting -eq 'location').key | Should -Be 'location'
        (@($f.notSet) | Where-Object setting -eq 'ztpEvents').key | Should -Be 'ztpEvents.path'
        (@($f.notSet) | Where-Object setting -eq 'osConfigEvents').key | Should -Be 'osConfigEventsPath'
        (@($f.notSet) | Where-Object setting -eq 'armEvents').key | Should -Be 'armEventsPath'
        (@($f.notSet) | Where-Object setting -eq 'verificationEvents').key | Should -Be 'verificationEventsPath'

        $infra = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $g = InModuleScope AzlSonar -Parameters @{ C = $infra } { param($C) New-AzlSonarDetailFact -Config $C }
        (@($g.notSet) | Where-Object setting -eq 'location').key | Should -Be 'azure.location'
        $g.readFrom | Should -Be 'infrastructure.yml'
        $g.fileName | Should -Be 'infrastructure.3node.yml'
    }
}

Describe 'Get-AzlSonarDetail' {
    BeforeAll {
        $script:Server = InModuleScope AzlSonar -Parameters @{ Config = $script:Config } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            $state = Get-AzlSonarInitialState -Config $Config
            $state.polledAt = '2026-10-10T18:10:00Z'
            Publish-AzlSonarState -Shared $shared -State $state
            Publish-AzlSonarTailerStatus -Shared $shared -Status ([ordered]@{ state = 'unavailable'; reason = 'WinRM refused'; node = 'node01'; credential = 'supplied' })
            $shared.ZtpInfo['Count'] = [long]212
            $shared.ZtpInfo['LastEventAt'] = '2026-10-10T18:09:56Z'
            @{ Shared = $shared; Facts = (New-AzlSonarDetailFact -Config $Config -ReadAt ([datetime]'2026-10-10T18:00:00Z')); Version = '0.4.0'; ClusterName = 'clus01'; Mode = 'live' }
        }
        $script:D = InModuleScope AzlSonar -Parameters @{ S = $script:Server } { param($S) Get-AzlSonarDetail -Server $S -Now ([datetime]'2026-10-10T18:10:10Z') }
    }

    It 'groups Target, Mode, Nodes, Sources and Config' {
        @($script:D.Keys) | Should -Be @('generatedAt', 'mode', 'target', 'route', 'identity', 'nodes', 'logAccount', 'sources', 'config')
        $script:D.target.cluster.value | Should -Be 'clus01'
        $script:D.target.region.value | Should -Be 'eastus'
        $script:D.target.subscription.value | Should -Be '11111111...'
        $script:D.target.subscription.note | Should -Be 'first 8 characters only'
    }

    It 'says where each value came from' {
        $script:D.target.resourceGroup.source | Should -Be 'from sonar.config.json resourceGroup'
        $script:D.identity.source | Should -Be 'from sonar.config.json identityModel'
        $script:D.identity.label | Should -Be 'Local identity'
        $script:D.identity.meaning | Should -Match 'workgroup'
    }

    It 'reports the Azure poll, the ZTP event file and the node log access' {
        $script:D.sources.azure.pollSeconds | Should -Be 20
        $script:D.sources.azure.lastAnswerAt | Should -Be '2026-10-10T18:10:00Z'
        $script:D.sources.ztpEvents.events | Should -Be 212
        $script:D.sources.ztpEvents.lastEventAt | Should -Be '2026-10-10T18:09:56Z'
        $script:D.sources.nodeLogs.state | Should -Be 'unavailable'
        $script:D.sources.nodeLogs.credential | Should -Be 'supplied'
        $script:D.sources.nodeLogs.node | Should -Be 'node01'
    }

    It 'reports the config source, its version and what is not set' {
        $script:D.config.readFrom | Should -Be 'the config file'
        $script:D.config.file | Should -Be 'sonar.config.json'
        $script:D.config.version | Should -Be '0.4.0'
        $script:D.config.readAt | Should -Be '2026-10-10T18:00:00Z'
        @($script:D.config.notSet).setting | Should -Contain 'ztpEvents'
    }

    It 'holds no secret and no full subscription id in the serialised body' {
        $body = ConvertTo-Json $script:D -Depth 16
        $body | Should -Not -Match 'kv-sonar-test|sonar-user-secret|sonar-pass-secret|2222-3333-4444|password'
    }

    It 'in a replay says the recording does not carry what it never recorded' {
        $replay = InModuleScope AzlSonar -Parameters @{ S = $script:Server } {
            param($S)
            $recorded = '{"clusterName":"clus01","resourceGroup":"rg-example-azl","identityModel":"ActiveDirectory","provisioningRoute":"simplified","nodes":[{"name":"node01","seed":true}]}'
            $r = @{ Shared = $S.Shared; Version = '0.4.0'; ClusterName = 'clus01'; Mode = 'replay'
                Facts = (New-AzlSonarReplayDetailFact -ConfigJson $recorded -Cluster 'clus01' -ReadAt ([datetime]'2026-10-10T17:00:00Z')) }
            Get-AzlSonarDetail -Server $r
        }
        $replay.mode | Should -Be 'replay'
        $replay.config.readFrom | Should -Be 'the recording'
        $replay.target.subscription.value | Should -Be ''
        $replay.target.resourceGroup.source | Should -Be 'from the recording'
        $replay.identity.label | Should -Be 'Active Directory'
        @($replay.nodes).name | Should -Be @('node01')
        @($replay.config.notSet).Count | Should -Be 0
    }
}

Describe 'Update-AzlSonarZtpInfo' {
    It 'counts event lines and keeps the newest event time' {
        $info = InModuleScope AzlSonar {
            $i = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null })
            Update-AzlSonarZtpInfo -Info $i -Line @(
                '{"timestamp":"2026-10-15T14:00:05Z","node":"n1","state":"Booting"}',
                'not json',
                '{"timestamp":"2026-10-15T14:00:01Z","node":"n1","state":"Mounted"}')
            $i
        }
        $info.Count | Should -Be 2
        $info.LastEventAt | Should -Be '2026-10-15T14:00:05Z'
    }
}
