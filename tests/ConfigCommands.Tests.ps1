#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Sub = '11111111-2222-3333-4444-555555555555'
}

Describe 'Config commands: create, add node, test, get' {
    It 'round-trips New, Add-AzlSonarNode, Test and Get' {
        $path = Join-Path $TestDrive 'cfg/clus01.json'
        $null = New-AzlSonarConfig -Path $path -SubscriptionId $script:Sub -ResourceGroup 'rg-example-azl' -ClusterName 'clus01' -Route simplified -IdentityModel ActiveDirectory -ZtpEventsPath 'D:\ztp\ztp-events.jsonl' -PollSeconds 30 6>$null
        # No node yet: Test names the key.
        @(Test-AzlSonarConfig -Path $path) | Should -Contain 'nodes must list at least one node.'
        Add-AzlSonarNode -Path $path -Name node01 -Address 192.0.2.11 -Seed
        Add-AzlSonarNode -Path $path -Name node02 -Address 192.0.2.12
        @(Test-AzlSonarConfig -Path $path).Count | Should -Be 0
        $config = Get-AzlSonarConfig -Path $path
        $config.clusterName | Should -Be 'clus01'
        $config.provisioningRoute | Should -Be 'simplified'
        $config.identityModel | Should -Be 'ActiveDirectory'
        $config.pollSeconds | Should -Be 30
        $config.ztpEventsPath | Should -Be 'D:\ztp\ztp-events.jsonl'
        ($config.nodes | ForEach-Object name) | Should -Be @('node01', 'node02')
        $config.seedNode.name | Should -Be 'node01'
        $config.credential.source | Should -Be 'prompt'
    }

    It 'moves the seed with -Seed, refuses a duplicate, and removes a node (the seed passes on)' {
        $path = Join-Path $TestDrive 'seed.json'
        $null = New-AzlSonarConfig -Path $path -SubscriptionId $script:Sub -ResourceGroup rg-x -ClusterName c1 6>$null
        Add-AzlSonarNode -Path $path -Name a -Address 192.0.2.1 -Seed
        Add-AzlSonarNode -Path $path -Name b -Address 192.0.2.2 -Seed
        (Get-AzlSonarConfig -Path $path).seedNode.name | Should -Be 'b'
        { Add-AzlSonarNode -Path $path -Name b -Address 192.0.2.9 } | Should -Throw '*already in*'
        Remove-AzlSonarNode -Path $path -Name b
        (Get-AzlSonarConfig -Path $path 3>$null).seedNode.name | Should -Be 'a'
        { Remove-AzlSonarNode -Path $path -Name zzz } | Should -Throw '*not in*'
    }

    It 'Test-AzlSonarConfig -Path names every missing key' {
        $path = Join-Path $TestDrive 'empty.json'
        Set-Content -LiteralPath $path -Value '{}'
        $problems = @(Test-AzlSonarConfig -Path $path)
        $problems | Should -Contain 'subscriptionId must be a GUID.'
        $problems | Should -Contain 'identityModel must be LocalIdentity or ActiveDirectory.'
        @(Test-AzlSonarConfig -Path (Join-Path $TestDrive 'nope.json')) | Should -Match 'not found'
    }

    It 'New-AzlSonarConfig names what is missing and will not overwrite' {
        { New-AzlSonarConfig -Path (Join-Path $TestDrive 'x.json') -ClusterName c } | Should -Throw '*-SubscriptionId*-ResourceGroup*-Interactive*'
        $path = Join-Path $TestDrive 'exists.json'
        Set-Content -LiteralPath $path -Value '{}'
        { New-AzlSonarConfig -Path $path -SubscriptionId $script:Sub -ResourceGroup r -ClusterName c } | Should -Throw '*already exists*'
    }

    It 'ConvertTo-AzlSonarConfig writes a file that reads back like -InfrastructureFile' {
        $fixture = Join-Path $PSScriptRoot 'fixtures/infrastructure.3node.yml'
        $out = Join-Path $TestDrive 'from-master.json'
        $null = ConvertTo-AzlSonarConfig -InfrastructureFile $fixture -OutFile $out
        $fromFile = Get-AzlSonarConfig -Path $out
        $direct = Get-AzlSonarConfig -InfrastructureFile $fixture
        ($fromFile.nodes | ForEach-Object { "$($_.name)=$($_.address)" }) | Should -Be ($direct.nodes | ForEach-Object { "$($_.name)=$($_.address)" })
        $fromFile.ztpEventsPath | Should -Be $direct.ztpEventsPath
        { ConvertTo-AzlSonarConfig -InfrastructureFile $fixture -OutFile $out } | Should -Throw '*already exists*'
        $null = ConvertTo-AzlSonarConfig -InfrastructureFile $fixture -OutFile $out -Force
    }
}

Describe 'Guided setup (New-AzlSonarConfig -Interactive)' {
    AfterEach {
        Remove-Variable -Name SonarTestAnswers -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name SonarTestPrompts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'asks for each value, pre-fills from the Az context, and never asks for a password' {
        $global:SonarTestAnswers = [System.Collections.Queue]::new(@('2', '', 'clus01', 'simplified', '', 'D:\ztp\ztp-events.jsonl', '30', 'node01', '192.0.2.11', 'node02', '192.0.2.12', ''))
        $global:SonarTestPrompts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlSonar Read-Host { $global:SonarTestPrompts.Add([string]$Prompt); [string]$global:SonarTestAnswers.Dequeue() }
        Mock -ModuleName AzlSonar Get-AzlSonarAzChoice { @{ SubscriptionId = '11111111-2222-3333-4444-555555555555'; ResourceGroup = 'rg-from-context'; Subscriptions = @(@{ Id = '11111111-2222-3333-4444-555555555555'; Name = 'sub-one' }, @{ Id = '66666666-7777-8888-9999-000000000000'; Name = 'sub-two' }) } }
        $path = Join-Path $TestDrive 'wizard.json'
        $null = New-AzlSonarConfig -Path $path -Interactive 6>$null
        $config = Get-AzlSonarConfig -Path $path
        $config.subscriptionId | Should -Be '66666666-7777-8888-9999-000000000000'   # picked "2" from the list
        $config.resourceGroup | Should -Be 'rg-from-context'                          # Enter took the default
        $config.clusterName | Should -Be 'clus01'
        $config.provisioningRoute | Should -Be 'simplified'
        $config.identityModel | Should -Be 'LocalIdentity'
        $config.pollSeconds | Should -Be 30
        $config.ztpEventsPath | Should -Be 'D:\ztp\ztp-events.jsonl'
        ($config.nodes | ForEach-Object name) | Should -Be @('node01', 'node02')
        $config.seedNode.name | Should -Be 'node01'
        ($global:SonarTestPrompts -join '|') | Should -Not -Match '(?i)password|secret'
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match '(?i)"password"|secretValue'
    }

    It 'asks again after an invalid answer' {
        $global:SonarTestAnswers = [System.Collections.Queue]::new(@('not-a-guid', '11111111-2222-3333-4444-555555555555', 'rg-x', 'c1', 'oem-image', '', '30', 'n1', '192.0.2.1', ''))
        Mock -ModuleName AzlSonar Read-Host { [string]$global:SonarTestAnswers.Dequeue() }
        Mock -ModuleName AzlSonar Get-AzlSonarAzChoice { @{ SubscriptionId = ''; ResourceGroup = ''; Subscriptions = @() } }
        $path = Join-Path $TestDrive 'wizard2.json'
        $null = New-AzlSonarConfig -Path $path -Interactive 6>$null
        (Get-AzlSonarConfig -Path $path).provisioningRoute | Should -Be 'oem-image'
    }
}

Describe 'Starting with no arguments' {
    It 'prints the three ways with the exact commands' {
        $text = InModuleScope AzlSonar { Get-AzlSonarNoConfigMessage }
        $text | Should -Match '\./Start-AzlSonar\.ps1 -InfrastructureFile \./infrastructure\.yml'
        $text | Should -Match 'New-AzlSonarConfig -Path \./config/sonar\.config\.json -Interactive'
        $text | Should -Match '\./Start-AzlSonar\.ps1 -ConfigPath \./config/sonar\.config\.json'
        $text | Should -Match 'sonar\.config\.commented\.jsonc'
    }

    It 'prints it and returns nothing in a non-interactive session (no prompt, no failure)' {
        Mock -ModuleName AzlSonar Test-AzlSonarInteractiveSession { $false }
        $out = InModuleScope AzlSonar { Invoke-AzlSonarNoConfigGuide 6>&1 }
        ($out | Out-String) | Should -Match '-InfrastructureFile'
    }

    It 'offers the guided setup in an interactive session and returns the new file' {
        Mock -ModuleName AzlSonar Test-AzlSonarInteractiveSession { $true }
        Mock -ModuleName AzlSonar New-AzlSonarConfig { }
        Mock -ModuleName AzlSonar Read-Host { 'y' }
        $result = InModuleScope AzlSonar { Invoke-AzlSonarNoConfigGuide -SetupPath './config/test-setup.json' 6>$null }
        $result | Should -Be './config/test-setup.json'
        Should -Invoke -ModuleName AzlSonar New-AzlSonarConfig -Times 1 -ParameterFilter { $Interactive }
    }

    It 'does not run the guided setup when the answer is no' {
        Mock -ModuleName AzlSonar Test-AzlSonarInteractiveSession { $true }
        Mock -ModuleName AzlSonar New-AzlSonarConfig { }
        Mock -ModuleName AzlSonar Read-Host { 'n' }
        $result = InModuleScope AzlSonar { Invoke-AzlSonarNoConfigGuide 6>$null }
        $result | Should -BeNullOrEmpty
        Should -Invoke -ModuleName AzlSonar New-AzlSonarConfig -Times 0
    }

    It 'Start-AzlSonar.ps1 with no arguments in an empty folder prints the message and exits cleanly' {
        $script = Join-Path $script:SonarRepoRoot 'Start-AzlSonar.ps1'
        $empty = Join-Path $TestDrive 'emptydir'
        $null = New-Item -ItemType Directory -Path $empty
        Push-Location $empty
        try { $out = (& pwsh -NoProfile -NonInteractive -File $script 6>&1 2>&1 | Out-String) }
        finally { Pop-Location }
        $out | Should -Match '-InfrastructureFile \./infrastructure\.yml'
        $out | Should -Match 'Interactive'
        $LASTEXITCODE | Should -Be 0
    }
}
