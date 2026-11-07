#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Drift guard for Appendix A (docs/appendix/a-sonar-api.md): the page must list every HTTP route the server serves
# and every function the module exports, and must not list a route the server no longer has. Nothing is started and
# nothing is called: the route list is read from the source text of Server.ps1, the command list from the manifest.
#
# Adding a route to Server.ps1 or a command to FunctionsToExport fails this test until Appendix A has a section for it:
#   - a route needs a heading "### GET /api/<name>" (any heading level 2 to 4 works), and the heading text names the route
#   - a command needs a heading whose text is the command name
# Re-run this test after merging another branch that adds routes or commands.

BeforeDiscovery {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $serverText = Get-Content -LiteralPath (Join-Path $repoRoot 'src/AzlSonar/Private/Server.ps1') -Raw
    # Every quoted /api/<something> literal in the server: the route switch, the replay guard, anything added later.
    $script:RoutesFound = @([regex]::Matches($serverText, "'(/api/[A-Za-z0-9_\-/]+)'") | ForEach-Object { $_.Groups[1].Value.TrimEnd('/') } |
            Where-Object { $_ -ne '/api' } | Sort-Object -Unique)
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'src/AzlSonar/AzlSonar.psd1')
    $script:CommandsFound = @($manifest.FunctionsToExport | Sort-Object -Unique)
    $script:RouteCases = @($script:RoutesFound | ForEach-Object { @{ Route = $_ } })
    $script:CommandCases = @($script:CommandsFound | ForEach-Object { @{ Command = $_ } })
}

BeforeAll {
    Set-StrictMode -Version Latest
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    # Pester 5 keeps BeforeDiscovery variables out of the run phase: read the source again here.
    $serverText = Get-Content -LiteralPath (Join-Path $repoRoot 'src/AzlSonar/Private/Server.ps1') -Raw
    $script:RoutesFound = @([regex]::Matches($serverText, "'(/api/[A-Za-z0-9_\-/]+)'") | ForEach-Object { $_.Groups[1].Value.TrimEnd('/') } |
            Where-Object { $_ -ne '/api' } | Sort-Object -Unique)
    $script:CommandsFound = @((Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'src/AzlSonar/AzlSonar.psd1')).FunctionsToExport | Sort-Object -Unique)
    $script:PagePath = Join-Path $repoRoot 'docs/appendix/a-sonar-api.md'
    $script:PageLines = @(Get-Content -LiteralPath $script:PagePath)
    $script:Headings = @($script:PageLines | Where-Object { $_ -match '^#{2,4}\s+\S' } | ForEach-Object { ($_ -replace '^#+\s+', '').Trim() })
    $script:RouteHeadings = @($script:Headings | Where-Object { $_ -match '^GET\s+/api/' })
}

Describe 'Appendix A exists' {
    It 'is at docs/appendix/a-sonar-api.md' {
        Test-Path -LiteralPath $script:PagePath | Should -BeTrue
    }

    It 'found routes and commands to check (the extraction itself works)' {
        $script:RoutesFound.Count | Should -BeGreaterThan 5
        $script:CommandsFound.Count | Should -BeGreaterThan 10
    }
}

Describe 'Appendix A lists every HTTP route of Server.ps1' {
    It 'has a "GET <Route>" section for <Route>' -ForEach $script:RouteCases {
        $names = @($script:RouteHeadings | ForEach-Object { ($_ -replace '^GET\s+', '') -replace '[?\s].*$', '' })
        $names | Should -Contain $Route -Because "Server.ps1 serves $Route; add a '### GET $Route' section to docs/appendix/a-sonar-api.md (and a row in its route table)"
    }

    It 'mentions <Route> in the route table with its method' -ForEach $script:RouteCases {
        $row = @($script:PageLines | Where-Object { $_ -match '^\|' -and $_.Contains("``GET $Route") })
        $row.Count | Should -BeGreaterThan 0 -Because "the route table of Appendix A needs a row for GET $Route"
    }
}

Describe 'Appendix A lists no route the server does not have' {
    It 'every "GET /api/..." heading is a route in Server.ps1' {
        $documented = @($script:RouteHeadings | ForEach-Object { ($_ -replace '^GET\s+', '') -replace '[?\s].*$', '' } | Sort-Object -Unique)
        $stale = @($documented | Where-Object { $_ -notin $script:RoutesFound })
        $stale | Should -BeNullOrEmpty -Because 'these routes are documented but Server.ps1 no longer serves them'
    }
}

Describe 'Appendix A lists every exported command' {
    It 'has a section for <Command>' -ForEach $script:CommandCases {
        $script:Headings | Where-Object { $_ -eq $Command } |
            Should -Not -BeNullOrEmpty -Because "the manifest exports $Command; add a section headed '$Command' to docs/appendix/a-sonar-api.md"
    }

    It 'names <Command> in a command example or description' -ForEach $script:CommandCases {
        (($script:PageLines -join "`n") -match [regex]::Escape($Command)) | Should -BeTrue
    }
}

Describe 'Appendix A lists no command the module does not export' {
    It 'every heading that looks like an AzlSonar command is exported' {
        $exported = $script:CommandsFound
        $looksLikeCommand = @($script:Headings | Where-Object { $_ -match '^[A-Z][a-z]+-AzlSonar[A-Za-z]+$' })
        @($looksLikeCommand | Where-Object { $_ -notin $exported }) | Should -BeNullOrEmpty -Because 'these commands are documented but not exported'
    }
}

Describe 'Appendix A is linked' {
    It 'from docs/index.md' {
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../docs/index.md') -Raw) | Should -Match 'appendix/a-sonar-api'
    }

    It 'from the README' {
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw) | Should -Match 'docs/appendix/a-sonar-api\.md'
    }

    It 'from the documentation sidebar' {
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../docs/.vitepress/config.mts') -Raw) | Should -Match '/appendix/a-sonar-api'
    }
}
