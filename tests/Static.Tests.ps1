#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeDiscovery {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $srcRoot = Join-Path $repoRoot 'src'
    $script:PowerShellFiles = @(
        Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
        Get-Item -LiteralPath (Join-Path $repoRoot 'Start-AzlSonar.ps1')
    ) | ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repoRoot.Length + 1) } }
    $script:JsonFiles = @(
        Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter '*.json'
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'examples') -Recurse -File -Filter '*.json'
    ) | ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repoRoot.Length + 1) } }
    $script:WebFiles = @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'AzlSonar/web') -Recurse -File) |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
}

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'PowerShell sources parse' {
    It '<Name> parses with no errors' -ForEach $script:PowerShellFiles {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) | Should -BeNullOrEmpty
    }
}

Describe 'PSScriptAnalyzer' {
    BeforeAll {
        $script:HasAnalyzer = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
    }

    It 'reports no Error or Warning under src and in Start-AzlSonar.ps1' {
        if (-not $script:HasAnalyzer) { Set-ItResult -Skipped -Because 'PSScriptAnalyzer is not installed'; return }
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $findings = @(
            Invoke-ScriptAnalyzer -Path (Join-Path $script:SonarRepoRoot 'src') -Recurse -Severity Error, Warning
            Invoke-ScriptAnalyzer -Path (Join-Path $script:SonarRepoRoot 'Start-AzlSonar.ps1') -Severity Error, Warning
        )
        @($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message }) | Should -BeNullOrEmpty
    }
}

Describe 'JSON files parse' {
    It '<Name> is valid JSON' -ForEach $script:JsonFiles {
        { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 64 -ErrorAction Stop } | Should -Not -Throw
    }

    It 'the example config passes Read-AzlSonarConfig' {
        Import-SonarTestModule
        { Read-AzlSonarConfig -Path $script:SonarExampleConfig } | Should -Not -Throw
    }

    It 'the example config uses neutral values (zero GUID, RFC 5737 addresses)' {
        $example = Get-Content -LiteralPath $script:SonarExampleConfig -Raw | ConvertFrom-Json
        $example.subscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
        foreach ($node in $example.nodes) { $node.address | Should -Match '^(192\.0\.2|198\.51\.100|203\.0\.113)\.\d+$' }
    }
}

Describe 'Web files (no CDN, no external resources)' {
    It '<Name> contains no http(s) URL' -ForEach $script:WebFiles {
        $text = Get-Content -LiteralPath $Path -Raw
        # The SVG namespace (in azurelocal-sonar-icon.svg) is an XML namespace identifier, never fetched; it is the only
        # allowed match.
        $urls = @([regex]::Matches($text, 'https?://[^\s''"<>)]+') | ForEach-Object { $_.Value } |
                Where-Object { $_ -ne 'http://www.w3.org/2000/svg' })
        $urls | Should -BeNullOrEmpty
    }

    It '<Name> loads no protocol-relative resource' -ForEach $script:WebFiles {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Not -Match '(src|href)\s*=\s*["'']//'
        $text | Should -Not -Match 'url\(\s*["'']?//'
        $text | Should -Not -Match '@import\s+(url\()?["'']?(https?:)?//'
    }

    It 'index.html loads app.js and app.css from the same origin' {
        $html = Get-Content -LiteralPath (Join-Path $script:SonarModuleRoot 'web/index.html') -Raw
        $html | Should -Match '<script[^>]+src="/?app\.js"'
        $html | Should -Match '<link[^>]+href="/?app\.css"'
    }

    It 'index.html has the Help box with the license and copyright text exactly, and no link of its own' {
        $html = Get-Content -LiteralPath (Join-Path $script:SonarModuleRoot 'web/index.html') -Raw
        $html | Should -Match 'id="help-btn"'
        $html | Should -Match 'Released under the MIT License.<br>s*Copyright &copy; Hybrid Cloud Solutions &amp; AzureLocal'
        $html | Should -Match 'id="details-btn"'
        $html | Should -Match 'id="la-btn"'
    }

    It 'index.html uses the Azure Local family icon from the web folder for the favicon and the page logo' {
        $html = Get-Content -LiteralPath (Join-Path $script:SonarModuleRoot 'web/index.html') -Raw
        $html | Should -Match '<link rel="icon" type="image/svg\+xml" href="azurelocal-sonar-icon\.svg">'
        $html | Should -Match '<img class="brand-mark" src="azurelocal-sonar-icon\.svg"'
        $html | Should -Not -Match 'href="data:'
        $icon = Join-Path $script:SonarModuleRoot 'web/azurelocal-sonar-icon.svg'
        Test-Path -LiteralPath $icon -PathType Leaf | Should -BeTrue
        $svg = [xml](Get-Content -LiteralPath $icon -Raw)
        $svg.DocumentElement.LocalName | Should -Be 'svg'
        $svg.DocumentElement.GetAttribute('aria-label') | Should -Be 'Azure Local Sonar'
    }

    It 'the docs site uses the same icon file as the page' {
        $docsIcon = Join-Path $script:SonarRepoRoot 'docs/public/assets/images/azurelocal-sonar-icon.svg'
        $webIcon = Join-Path $script:SonarModuleRoot 'web/azurelocal-sonar-icon.svg'
        (Get-FileHash -LiteralPath $docsIcon).Hash | Should -Be (Get-FileHash -LiteralPath $webIcon).Hash
        $config = Get-Content -LiteralPath (Join-Path $script:SonarRepoRoot 'docs/.vitepress/config.mts') -Raw
        $config | Should -Match "logo: '/assets/images/azurelocal-sonar-icon\.svg'"
        $config | Should -Match "rel: 'icon'.+href: '/azurelocal-sonar/assets/images/azurelocal-sonar-icon\.svg'"
    }
}

Describe 'Module manifest' {
    It 'is valid and exports the public functions of the design, the recording tools and the config commands' {
        $manifest = Test-ModuleManifest -Path $script:SonarManifest -ErrorAction Stop
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'Add-AzlSonarNode', 'ConvertTo-AzlSonarConfig', 'ConvertTo-AzlSonarStepTree', 'Export-AzlSonarBundle', 'Export-AzlSonarPublishableRecording', 'Get-AzlSonarConfig', 'Get-AzlSonarDeploymentState', 'Get-AzlSonarPhaseGuidance', 'Invoke-AzlSonarApi', 'New-AzlSonarConfig', 'Read-AzlSonarConfig', 'Remove-AzlSonarNode', 'Set-AzlSonarConfig', 'Start-AzlSonarServer', 'Test-AzlSonarConfig', 'Test-AzlSonarPublishableRecording'
        )
    }

    It 'imports and exports the same functions as the manifest' {
        Import-SonarTestModule
        @((Get-Module AzlSonar).ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'Add-AzlSonarNode', 'ConvertTo-AzlSonarConfig', 'ConvertTo-AzlSonarStepTree', 'Export-AzlSonarBundle', 'Export-AzlSonarPublishableRecording', 'Get-AzlSonarConfig', 'Get-AzlSonarDeploymentState', 'Get-AzlSonarPhaseGuidance', 'Invoke-AzlSonarApi', 'New-AzlSonarConfig', 'Read-AzlSonarConfig', 'Remove-AzlSonarNode', 'Set-AzlSonarConfig', 'Start-AzlSonarServer', 'Test-AzlSonarConfig', 'Test-AzlSonarPublishableRecording'
        )
    }
}
