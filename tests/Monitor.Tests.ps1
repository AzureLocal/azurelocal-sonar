#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Standalone monitors: Start-AzlSonar.ps1 -Monitor Discovery|Provisioning|OsConfiguration|Validate|Deployment|Update|AddNode|Repair
# (and Auto, today's behaviour). No Azure, no node: the poll is mocked.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Names = 'Auto', 'Discovery', 'Provisioning', 'OsConfiguration', 'Validate', 'Deployment', 'Update', 'AddNode', 'Repair'
}

Describe 'the monitor names' {
    It 'are exactly the eight monitors and Auto, and there is no Health' {
        InModuleScope AzlSonar { Get-AzlSonarMonitorNameList } | Should -Be $script:Names
        InModuleScope AzlSonar { Get-AzlSonarMonitorName -Value 'health' } | Should -Be ''
    }
    It 'are matched in any case, with or without dashes; an empty value is Auto' {
        InModuleScope AzlSonar {
            Get-AzlSonarMonitorName -Value 'osconfiguration' | Should -Be 'OsConfiguration'
            Get-AzlSonarMonitorName -Value 'os-configuration' | Should -Be 'OsConfiguration'
            Get-AzlSonarMonitorName -Value 'add-node' | Should -Be 'AddNode'
            Get-AzlSonarMonitorName -Value ' REPAIR ' | Should -Be 'Repair'
            Get-AzlSonarMonitorName -Value '' | Should -Be 'Auto'
            Get-AzlSonarMonitorName -Value 'nonsense' | Should -Be ''
        }
    }
}

Describe 'what each monitor reads' {
    It 'Auto is today: everything' {
        $p = InModuleScope AzlSonar { Get-AzlSonarMonitorPlan -Monitor 'Auto' }
        $p.standalone | Should -BeFalse
        ($p.azure -and $p.ztpEvents -and $p.osConfigEvents -and $p.armEvents -and $p.nodeProbe -and $p.tailer -and $p.discovery) | Should -BeTrue
        @($p.phases).Count | Should -Be 8
    }
    It '<Name> reads only what it needs' -ForEach @(
        @{ Name = 'Discovery'; Azure = $false; Ztp = $false; Os = $false; Tail = $false; Disc = $true; Phases = @() }
        @{ Name = 'Provisioning'; Azure = $true; Ztp = $true; Os = $false; Tail = $false; Disc = $false; Phases = @('provisioning', 'arc-registration') }
        @{ Name = 'OsConfiguration'; Azure = $true; Ztp = $false; Os = $true; Tail = $false; Disc = $false; Phases = @('provisioning') }
        @{ Name = 'Validate'; Azure = $true; Ztp = $false; Os = $false; Tail = $true; Disc = $false; Phases = @('validation') }
        @{ Name = 'Deployment'; Azure = $true; Ztp = $false; Os = $false; Tail = $true; Disc = $false; Phases = @('deployment', 'post-deployment') }
        @{ Name = 'Update'; Azure = $true; Ztp = $false; Os = $false; Tail = $true; Disc = $false; Phases = @('update') }
        @{ Name = 'AddNode'; Azure = $true; Ztp = $false; Os = $false; Tail = $true; Disc = $false; Phases = @('add-node') }
        @{ Name = 'Repair'; Azure = $true; Ztp = $false; Os = $false; Tail = $true; Disc = $false; Phases = @('repair') }
    ) {
        $p = InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Get-AzlSonarMonitorPlan -Monitor $N }
        $p.standalone | Should -BeTrue
        $p.azure | Should -Be $Azure
        $p.ztpEvents | Should -Be $Ztp
        $p.osConfigEvents | Should -Be $Os
        $p.tailer | Should -Be $Tail
        $p.discovery | Should -Be $Disc
        $p.armEvents | Should -Be ($Name -in 'Validate', 'Deployment')
        @($p.phases) | Should -Be $Phases
        $p.nodeProbe | Should -Be ($Name -eq 'Provisioning')
    }
}

Describe 'the monitor key of the config' {
    It 'is Auto by default, is read in any case, and rejects anything else' {
        (InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson (New-SonarConfigObject)) } { param($Json) (Read-AzlSonarConfig -Json $Json).monitor }) | Should -Be 'Auto'
        $c = New-SonarConfigObject
        $c | Add-Member -NotePropertyName monitor -NotePropertyValue 'osconfiguration' -Force
        (InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $c) } { param($Json) (Read-AzlSonarConfig -Json $Json).monitor }) | Should -Be 'OsConfiguration'
        $c.monitor = 'health'
        { InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $c) } { param($Json) Read-AzlSonarConfig -Json $Json } } | Should -Throw '*monitor must be one of*'
    }
    It 'a track of health is accepted and means auto, with a warning that says why' {
        $c = New-SonarConfigObject
        $c | Add-Member -NotePropertyName track -NotePropertyValue 'health' -Force
        $out = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $c) } { param($Json) Read-AzlSonarConfig -Json $Json 3>&1 }
        @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should -Match 'no longer a monitor'
        @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0].track | Should -Be 'auto'
    }
    It 'Set-AzlSonarConfig can set it (and offers the monitors as words)' {
        $path = Join-Path $TestDrive 'monitor.json'
        [IO.File]::WriteAllText($path, (ConvertTo-SonarConfigJson (New-SonarConfigObject)))
        Set-AzlSonarConfig -Path $path -Key monitor -Value 'Update' 6>$null
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).monitor | Should -Be 'Update'
        { Set-AzlSonarConfig -Path $path -Key monitor -Value 'Health' 6>$null } | Should -Throw
    }
    It 'the public config and the state carry the monitor, so the page and a replay agree' {
        $c = New-SonarConfigObject
        $c | Add-Member -NotePropertyName monitor -NotePropertyValue 'Validate' -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $c) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $pub = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) ConvertTo-AzlSonarPublicConfig -Config $C -StartedAt ([datetime]::UtcNow) -ServerId 'x' }
        $pub.monitor | Should -Be 'Validate'
        @($pub.monitorPhases) | Should -Be @('validation')
        (InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) (Get-AzlSonarInitialState -Config $C).monitor }) | Should -Be 'Validate'
    }
}

Describe 'Start-AzlSonar.ps1 -Monitor' {
    It 'is a Live parameter with the nine values and no Health' {
        $cmd = Get-Command -Name (Join-Path $script:SonarRepoRoot 'Start-AzlSonar.ps1')
        $p = $cmd.Parameters['Monitor']
        $p | Should -Not -BeNullOrEmpty
        @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues | Should -Be $script:Names
        $p.ParameterSets.Keys | Should -Be @('Live')
    }
    It 'Start-AzlSonarServer has it too, and the help names every monitor' {
        (Get-Command Start-AzlSonarServer).Parameters.Keys | Should -Contain 'Monitor'
        $help = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'Start-AzlSonar.ps1') -Raw
        foreach ($n in $script:Names) { $help | Should -Match $n }
    }
}

Describe 'the Discovery monitor polls no Azure' {
    It 'publishes a state from the discovery files without calling the deployment poll, and Auto still does' {
        $dir = Join-Path $TestDrive 'disc'
        $null = New-Item -ItemType Directory -Path $dir
        $c = New-SonarConfigObject
        $c | Add-Member -NotePropertyName discoveryPath -NotePropertyValue $dir -Force
        $c | Add-Member -NotePropertyName monitor -NotePropertyValue 'Discovery' -Force
        $cfg = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $c) } { param($Json) Read-AzlSonarConfig -Json $Json }
        Mock Wait-AzlSonarInterval -ModuleName AzlSonar { $Shared['Stop'] = $true }
        Mock Get-AzlSonarDeploymentState -ModuleName AzlSonar { [ordered]@{ called = $true } }
        $r = InModuleScope AzlSonar -Parameters @{ C = $cfg } {
            param($C)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarPollerLoop -Shared $shared -Config $C
            $shared.State
        }
        $r.monitor | Should -Be 'Discovery'
        $r.discovery.configured | Should -BeTrue
        Should -Invoke Get-AzlSonarDeploymentState -ModuleName AzlSonar -Times 0 -Exactly
        $c.monitor = 'Auto'
        $cfg2 = InModuleScope AzlSonar -Parameters @{ Json = (ConvertTo-SonarConfigJson $c) } { param($Json) Read-AzlSonarConfig -Json $Json }
        $null = InModuleScope AzlSonar -Parameters @{ C = $cfg2 } { param($C) $shared = Initialize-AzlSonarSharedState; Invoke-AzlSonarPollerLoop -Shared $shared -Config $C }
        Should -Invoke Get-AzlSonarDeploymentState -ModuleName AzlSonar -Times 1 -Exactly
    }
}
