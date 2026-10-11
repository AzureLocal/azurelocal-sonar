#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:Models = @(@{ Model = 'LocalIdentity' }, @{ Model = 'ActiveDirectory' })
}

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:GuidancePath = Join-Path $script:SonarModuleRoot 'data/phase-guidance.json'
    $script:GuidanceDoc = Get-Content -LiteralPath $script:GuidancePath -Raw | ConvertFrom-Json -Depth 32
    $script:AllPhases = @('provisioning', 'arc-registration', 'validation', 'deployment', 'post-deployment')
}

Describe 'Get-AzlSonarPhaseGuidance for <Model>' -ForEach $script:Models {
    BeforeAll {
        $script:g = Get-AzlSonarPhaseGuidance -IdentityModel $Model
    }

    It 'is available and carries the identity model and version' {
        $script:g.available | Should -BeTrue
        $script:g.identityModel | Should -Be $Model
        $script:g.version | Should -Be $script:GuidanceDoc.version
    }

    It 'returns all five phases in order' {
        @($script:g.phases.Keys) | Should -Be $script:AllPhases
    }

    It 'returns the <Model> entry of the data file for every phase' {
        foreach ($phase in $script:AllPhases) {
            $entry = @($script:GuidanceDoc.phases | Where-Object { $_.phase -eq $phase -and $_.identityModel -eq $Model })
            $entry.Count | Should -Be 1 -Because "the data file has one $Model entry for $phase"
            $actual = $script:g.phases[$phase]
            $actual.account | Should -Be $entry[0].account
            $actual.logPaths | Should -Be @($entry[0].logPaths)
            $actual.when | Should -Be $entry[0].available
            $actual.how | Should -Be $entry[0].access
            $actual.source | Should -Be $entry[0].source
            $actual.verified | Should -Be ([bool]$entry[0].verified)
        }
    }

    It 'gives every phase an account, at least one log path and a Learn source' {
        foreach ($phase in $script:AllPhases) {
            $p = $script:g.phases[$phase]
            [string]$p.account | Should -Not -BeNullOrEmpty
            @($p.logPaths).Count | Should -BeGreaterThan 0
            [string]$p.source | Should -Match '^https://learn\.microsoft\.com/'
            $p.verified | Should -BeOfType [bool]
        }
    }

    It 'filters to one phase with -Phase' {
        $one = Get-AzlSonarPhaseGuidance -IdentityModel $Model -Phase 'deployment'
        @($one.phases.Keys) | Should -Be @('deployment')
    }
}

Describe 'Get-AzlSonarPhaseGuidance edge cases' {
    It 'returns available = false and no phases for a missing file' {
        $g = Get-AzlSonarPhaseGuidance -IdentityModel LocalIdentity -Path (Join-Path $TestDrive 'missing.json')
        $g.available | Should -BeFalse
        @($g.phases.Keys).Count | Should -Be 0
    }

    It 'applies generic entries to both models and lets an exact entry win' {
        $path = Join-Path $TestDrive 'guidance.json'
        @'
{ "version": 9, "phases": [
  { "phase": "validation", "identityModel": "ActiveDirectory", "account": "exact-ad", "logPaths": ["C:\\a"] },
  { "phase": "validation", "identityModel": "Any", "account": "generic", "logPaths": ["C:\\b"] },
  { "phase": "deployment", "account": "no-model", "logPaths": "C:\\single" },
  { "phase": "post-deployment", "identityModel": "LocalIdentity", "account": "local-only" },
  { "identityModel": "Any", "account": "no phase name: ignored" }
] }
'@ | Set-Content -LiteralPath $path
        $ad = Get-AzlSonarPhaseGuidance -IdentityModel ActiveDirectory -Path $path
        $ad.version | Should -Be 9
        $ad.phases.validation.account | Should -Be 'exact-ad'
        $ad.phases.deployment.account | Should -Be 'no-model'
        $ad.phases.deployment.logPaths | Should -Be @('C:\single')
        $ad.phases.deployment.verified | Should -BeFalse
        $ad.phases.Contains('post-deployment') | Should -BeFalse

        $local = Get-AzlSonarPhaseGuidance -IdentityModel LocalIdentity -Path $path
        $local.phases.validation.account | Should -Be 'generic'
        $local.phases['post-deployment'].account | Should -Be 'local-only'
        @($local.phases['post-deployment'].logPaths).Count | Should -Be 0
    }

    It 'rejects an unknown identity model' {
        { Get-AzlSonarPhaseGuidance -IdentityModel 'Workgroup' } | Should -Throw
    }
}
