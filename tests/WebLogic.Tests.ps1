#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The page's pure log logic (log store, step filter, file filter, level fallback) runs under Node: app.js exports those
# functions when it is loaded with require() and there is no DOM. Each case in web-logic.cases.js becomes one test.
# Skipped when Node is not installed; no network, no browser.

BeforeDiscovery {
    $script:WebCases = @()
    $script:NodeMissing = $null -eq (Get-Command -Name node -CommandType Application -ErrorAction SilentlyContinue)
    if (-not $script:NodeMissing) {
        $appJs = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../src/AzlSonar/web/app.js')).ProviderPath
        $runner = Join-Path $PSScriptRoot 'web-logic.cases.js'
        $output = & node $runner $appJs 2>&1
        $text = ($output | Out-String).Trim()
        try {
            $script:WebCases = @($text | ConvertFrom-Json | ForEach-Object { @{ Name = $_.name; Ok = [bool]$_.ok; Message = [string]$_.message } })
        }
        catch {
            $script:WebCases = @(@{ Name = 'web-logic.cases.js ran'; Ok = $false; Message = $text })
        }
    }
}

Describe 'app.js log logic (Node)' {
    It 'Node ran the page logic cases' -Skip:$script:NodeMissing -ForEach @(@{ Count = $script:WebCases.Count }) {
        $Count | Should -BeGreaterThan 0
    }

    It '<Name>' -ForEach $script:WebCases {
        $Message | Should -BeNullOrEmpty
        $Ok | Should -BeTrue
    }
}
