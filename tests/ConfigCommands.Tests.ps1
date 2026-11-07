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

Describe 'Set-AzlSonarConfig (change one key of a config file)' {
    BeforeEach {
        $script:SetPath = Join-Path $TestDrive "set-$([guid]::NewGuid().ToString('N')).json"
        $null = New-AzlSonarConfig -Path $script:SetPath -SubscriptionId $script:Sub -ResourceGroup rg-x -ClusterName c1 6>$null
        Add-AzlSonarNode -Path $script:SetPath -Name a -Address 192.0.2.1 -Seed
    }

    It 'sets a number, a word, a flag, a nested key and a list, and Sonar reads them back' {
        Set-AzlSonarConfig -Path $script:SetPath -Key pollSeconds -Value 45 6>$null
        Set-AzlSonarConfig -Path $script:SetPath -Key identityModel -Value activedirectory 6>$null
        Set-AzlSonarConfig -Path $script:SetPath -Key accessToken -Value false 6>$null
        Set-AzlSonarConfig -Path $script:SetPath -Key logs.transport -Value SSH 6>$null
        Set-AzlSonarConfig -Path $script:SetPath -Key logs.paths -Value 'C:\MASLogs', 'C:\Other' 6>$null
        Set-AzlSonarConfig -Path $script:SetPath -Key ztpEvents.path -Value 'D:\ztp\ztp-events.jsonl' 6>$null
        $raw = Get-Content -LiteralPath $script:SetPath -Raw | ConvertFrom-Json
        $raw.pollSeconds | Should -BeOfType [long]   # a JSON number, not the text "45"
        $raw.pollSeconds | Should -Be 45
        $raw.identityModel | Should -Be 'ActiveDirectory'   # the canonical spelling, not the one typed
        $raw.accessToken | Should -BeFalse
        $raw.logs.transport | Should -Be 'ssh'
        @($raw.logs.paths) | Should -Be @('C:\MASLogs', 'C:\Other')
        @(Test-AzlSonarConfig -Path $script:SetPath).Count | Should -Be 0
        (Get-AzlSonarConfig -Path $script:SetPath).ztpEventsPath | Should -Be 'D:\ztp\ztp-events.jsonl'
    }

    It 'keeps a single list value a list' {
        Set-AzlSonarConfig -Path $script:SetPath -Key logs.include -Value '*.log' 6>$null
        (Get-Content -LiteralPath $script:SetPath -Raw) | Should -Match '"include":\s*\[\s*"\*\.log"\s*\]'
    }

    It 'removes a key, and the empty section with it' {
        Set-AzlSonarConfig -Path $script:SetPath -Key logs.transport -Value ssh 6>$null
        Set-AzlSonarConfig -Path $script:SetPath -Key logs.transport -Remove 6>$null
        (Get-Content -LiteralPath $script:SetPath -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'logs'
        # removing a key that is not there is fine
        { Set-AzlSonarConfig -Path $script:SetPath -Key track -Remove 6>$null } | Should -Not -Throw
    }

    It 'writes nothing when the change would make the file invalid, and names the problem' {
        $before = Get-Content -LiteralPath $script:SetPath -Raw
        { Set-AzlSonarConfig -Path $script:SetPath -Key pollSeconds -Value 2 } | Should -Throw '*Not changed*pollSeconds must be a whole number from 5 to 3600*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key subscriptionId -Value 'my-subscription' } | Should -Throw '*subscriptionId must be a GUID*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key logs.transport -Value telnet } | Should -Throw '*must be one of: auto, winrm, ssh*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key pollSeconds -Value abc } | Should -Throw '*whole number*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key accessToken -Value maybe } | Should -Throw '*true or false*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key pollSeconds -Value 1, 2 } | Should -Throw '*takes one value*'
        Get-Content -LiteralPath $script:SetPath -Raw | Should -Be $before
    }

    It 'refuses a secret, a node, an unknown key, both -Value and -Remove, and neither' {
        { Set-AzlSonarConfig -Path $script:SetPath -Key credential.password -Value x } | Should -Throw '*never put secrets*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key nodes -Value x } | Should -Throw '*Add-AzlSonarNode*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key nodes[0].address -Value x } | Should -Throw '*Add-AzlSonarNode*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key colour -Value x } | Should -Throw "*'colour' is not a setting*"
        { Set-AzlSonarConfig -Path $script:SetPath -Key pollSeconds -Value 30 -Remove } | Should -Throw '*not both*'
        { Set-AzlSonarConfig -Path $script:SetPath -Key pollSeconds } | Should -Throw '*not both*'
        { Set-AzlSonarConfig -Key pollSeconds -Value 30 } | Should -Throw '*Give -Path*'
    }

    It 'does not write with -WhatIf, and lists the keys it can set when called without -Key' {
        $before = Get-Content -LiteralPath $script:SetPath -Raw
        Set-AzlSonarConfig -Path $script:SetPath -Key pollSeconds -Value 60 -WhatIf
        Get-Content -LiteralPath $script:SetPath -Raw | Should -Be $before
        $keys = @(Set-AzlSonarConfig)
        $keys.Key | Should -Contain 'logs.transport'
        ($keys | Where-Object Key -eq 'identityModel').Allowed | Should -Be 'LocalIdentity, ActiveDirectory'
        $keys.Key | Should -Not -Contain 'credential.password'
    }

    It 'offers only keys that docs/config.md and the commented example both explain' {
        $doc = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../docs/config.md') -Raw
        $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../examples/sonar.config.commented.jsonc') -Raw
        foreach ($key in @(Set-AzlSonarConfig).Key) {
            $doc | Should -Match ([regex]::Escape("``$key``")) -Because "docs/config.md must have a row for $key"
            $example | Should -Match ([regex]::Escape(($key -split '\.')[-1])) -Because "examples/sonar.config.commented.jsonc must explain $key"
        }
    }
}

Describe 'Guided setup (New-AzlSonarConfig -Interactive)' {
    It 'asks for each value, pre-fills from the Az context, and never asks for a password' {
        # The mock runs in the module's scope: a closure carries the queue and the list in without a global variable.
        $answers = [System.Collections.Queue]::new(@('2', '', 'clus01', 'simplified', '', 'D:\ztp\ztp-events.jsonl', '30', 'node01', '192.0.2.11', 'node02', '192.0.2.12', ''))
        $prompts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlSonar Read-Host ({ $prompts.Add([string]$Prompt); [string]$answers.Dequeue() }.GetNewClosure())
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
        ($prompts -join '|') | Should -Not -Match '(?i)password|secret'
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match '(?i)"password"|secretValue'
    }

    It 'asks again after an invalid answer' {
        $answers = [System.Collections.Queue]::new(@('not-a-guid', '11111111-2222-3333-4444-555555555555', 'rg-x', 'c1', 'oem-image', '', '30', 'n1', '192.0.2.1', ''))
        Mock -ModuleName AzlSonar Read-Host ({ [string]$answers.Dequeue() }.GetNewClosure())
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

    It 'treats pwsh -NonInteractive as non-interactive even on a real console (Read-Host would throw there): <Arguments>' -TestCases @(
        @{ Arguments = @('pwsh', '-NoProfile', '-NonInteractive', '-File', 'x.ps1'); Expected = $true }
        @{ Arguments = @('pwsh', '-noni', '-File', 'x.ps1'); Expected = $true }
        @{ Arguments = @('pwsh', '-NoProfile', '-File', 'x.ps1'); Expected = $false }
        @{ Arguments = @('pwsh', '-File', 'x.ps1', '-NoBrowser'); Expected = $false }
    ) {
        InModuleScope AzlSonar -Parameters @{ A = $Arguments } { param($A) Test-AzlSonarNonInteractiveSwitch -Arguments $A } | Should -Be $Expected
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
