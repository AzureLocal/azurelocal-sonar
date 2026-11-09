#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Keeps docs/api.md and the code together. It reads src/AzlSonar/Private/Server.ps1 (and the functions that build the
# state and the log line) with the PowerShell parser and compares what the code registers with what the page documents:
#   - every route in Server.ps1 is in the routes table of docs/api.md, and every route in the table is registered;
#   - every top-level key of the state (the last return of Get-AzlSonarDeploymentState) is in the state key table, and back;
#   - every SSE event name and every log line field is documented, and back;
#   - every status code the server sends, every security header and the cookie name are mentioned;
#   - the limits the page states are the numbers in the code;
#   - the page has no real identifier in it (GUIDs, addresses, tokens) and no dead relative link;
#   - the page is in the VitePress sidebar and linked from README.md, docs/how-it-works.md and docs/config.md.
# No Azure, no node, no network.

BeforeDiscovery {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $serverPath = Join-Path $repoRoot 'src/AzlSonar/Private/Server.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$errors)
    $switches = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$path' }, $true)
    $script:CodeRoutes = @(foreach ($s in $switches) { foreach ($clause in $s.Clauses) { $clause.Item1.Extent.Text.Trim("'", '"') } }) | Where-Object { $_ -like '/api/*' } |
        ForEach-Object { @{ Route = $_ } }
    $script:Documents = @{}
}

BeforeAll {
    Set-StrictMode -Version Latest
    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:ServerPath = Join-Path $script:RepoRoot 'src/AzlSonar/Private/Server.ps1'
    $script:PrivatePath = Join-Path $script:RepoRoot 'src/AzlSonar/Private'
    $script:ApiPath = Join-Path $script:RepoRoot 'docs/api.md'
    $script:ApiText = Get-Content -LiteralPath $script:ApiPath -Raw
    $script:ServerText = Get-Content -LiteralPath $script:ServerPath -Raw

    function Get-Ast {
        param([string]$Path)
        $tokens = $null; $errors = $null
        return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    }

    function Get-DocSection {
        # The text between a heading line (given as its exact text) and the next heading of the same or a higher level.
        param([string]$Heading)
        $level = ($Heading -split ' ')[0].Length
        $lines = $script:ApiText -split "`r?`n"
        $start = [array]::IndexOf($lines, $Heading)
        if ($start -lt 0) { throw "docs/api.md has no heading '$Heading'." }
        $out = [System.Collections.Generic.List[string]]::new()
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^(#{1,6})\s') { if ($Matches[1].Length -le $level) { break } }
            $out.Add($lines[$i])
        }
        return ($out -join "`n")
    }

    function Get-FirstCellName {
        # The `name` in the first column of every table row of a text. Rows whose first cell is not a single backticked name are skipped.
        param([string]$Text, [string]$Pattern = '[A-Za-z][A-Za-z0-9]*')
        return @([regex]::Matches($Text, "(?m)^\|\s*``($Pattern)``\s*\|") | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-HashtableKey {
        param($HashtableAst)
        return @($HashtableAst.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
    }
}

Describe 'docs/api.md exists' {
    It 'is there and has the sections the page promises' {
        Test-Path -LiteralPath $script:ApiPath | Should -BeTrue
        foreach ($heading in '## The read-only guarantee', '## Reaching the API', '## Routes', '## Route reference', '## The state object', '## The live stream (/api/events)', '## Modes and monitors', '## Recipes', '## Using the API from automation') {
            $script:ApiText | Should -Match ('(?m)^' + [regex]::Escape($heading) + '\s*$')
        }
    }
}

Describe 'Routes: Server.ps1 and docs/api.md agree' {
    It 'finds the routes in Server.ps1 (guards the parser used here)' {
        $ast = Get-Ast $script:ServerPath
        $found = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$path' }, $true))
        $found.Count | Should -BeGreaterOrEqual 1
        $routes = @(foreach ($clause in $found[0].Clauses) { $clause.Item1.Extent.Text.Trim("'", '"') })
        $routes.Count | Should -BeGreaterOrEqual 9
    }

    It 'documents the registered route <Route> in the routes table, with method GET' -ForEach $script:CodeRoutes {
        $table = Get-DocSection '## Routes'
        $table | Should -Match ('(?m)^\|\s*`GET`\s*\|\s*\[?`' + [regex]::Escape($Route) + '`')
    }

    It 'registers every route the routes table lists' {
        $ast = Get-Ast $script:ServerPath
        $switchAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$path' }, $true))[0]
        $registered = @(foreach ($clause in $switchAst.Clauses) { $clause.Item1.Extent.Text.Trim("'", '"') })
        $documented = @([regex]::Matches((Get-DocSection '## Routes'), '(?m)^\|\s*`([A-Z]+)`\s*\|\s*\[?`(/api/[a-z]+)`') | ForEach-Object { $_.Groups[2].Value })
        $documented.Count | Should -BeGreaterThan 0
        @($documented | Where-Object { $_ -notin $registered }) | Should -BeNullOrEmpty
        @($registered | Where-Object { $_ -notin $documented }) | Should -BeNullOrEmpty
    }

    It 'lists only GET in the routes table, as the server accepts only GET' {
        $methods = @([regex]::Matches((Get-DocSection '## Routes'), '(?m)^\|\s*`([A-Z]+)`\s*\|\s*\[?`/api/') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $methods | Should -Be @('GET')
        $script:ServerText | Should -Match "HttpMethod -ne 'GET'"
    }

    It 'has a route reference section for every route' -ForEach $script:CodeRoutes {
        $anchorHeading = '(?m)^###\s+' + [regex]::Escape($Route) + '\s*$'
        $script:ApiText | Should -Match $anchorHeading
    }

    It 'documents the query parameters the code reads' {
        $params = @([regex]::Matches($script:ServerText, "QueryString\['([A-Za-z]+)'\]") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $params | Should -Contain 'since'
        $params | Should -Contain 't'
        $script:ApiText | Should -Match '`since`'
        $script:ApiText | Should -Match '\?t=<token>'
    }
}

Describe 'The state object: the code and docs/api.md agree' {
    BeforeAll {
        $ast = Get-Ast (Join-Path $script:PrivatePath 'AzurePoller.ps1')
        $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AzlSonarDeploymentState' }, $true)
        # The returns of the function itself (not of nested script blocks): the last one builds the state.
        $returns = @($function.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true))
        $script:CodeStateKey = @()
        foreach ($r in $returns) {
            $h = $r.Pipeline.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
            if ($null -eq $h) { continue }
            $keys = @(Get-HashtableKey $h)
            if ($keys.Count -gt $script:CodeStateKey.Count) { $script:CodeStateKey = $keys }
        }
        $initial = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AzlSonarInitialState' }, $true)
        $initialReturn = @($initial.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true))[-1]
        $script:InitialStateKey = Get-HashtableKey ($initialReturn.Pipeline.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))
        $script:DocStateKey = Get-FirstCellName (Get-DocSection '### Top-level keys of the state')
    }

    It 'reads the state keys from the code (guards the parser used here)' {
        $script:CodeStateKey | Should -Contain 'phase'
        $script:CodeStateKey | Should -Contain 'polledAt'
        @($script:CodeStateKey).Count | Should -BeGreaterOrEqual 25
    }

    It 'documents every top-level key of the state' {
        @($script:CodeStateKey | Where-Object { $_ -notin $script:DocStateKey }) | Should -BeNullOrEmpty
    }

    It 'documents no top-level key the code does not produce' {
        @($script:DocStateKey | Where-Object { $_ -notin $script:CodeStateKey }) | Should -BeNullOrEmpty
    }

    It 'has no key in the initial state that the full state lacks' {
        @($script:InitialStateKey | Where-Object { $_ -notin $script:CodeStateKey }) | Should -BeNullOrEmpty
    }

    It 'names the keys that only appear after the first poll' {
        $late = @($script:CodeStateKey | Where-Object { $_ -notin $script:InitialStateKey })
        $late | Should -Not -BeNullOrEmpty
        foreach ($key in $late) {
            $row = [regex]::Match((Get-DocSection '### Top-level keys of the state'), ('(?m)^\|\s*`' + $key + '`\s*\|.*$')).Value
            $row | Should -Not -Match '\*\*Always\.\*\*' -Because "$key is missing from the initial state"
        }
    }

    It 'marks every key of the initial state as always present' {
        foreach ($key in $script:InitialStateKey) {
            $row = [regex]::Match((Get-DocSection '### Top-level keys of the state'), ('(?m)^\|\s*`' + $key + '`\s*\|.*$')).Value
            $row | Should -Match '\*\*Always\.\*\*' -Because "$key is in the initial state"
        }
    }
}

Describe 'The log line, the stream and the limits' {
    It 'documents every field of the log line, and no other' {
        $ast = Get-Ast (Join-Path $script:PrivatePath 'LogTailer.ps1')
        $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-AzlSonarLogLine' }, $true)
        $table = $function.Body.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and (Get-HashtableKey $n) -contains 'timeSource' }, $true)
        $code = Get-HashtableKey $table
        $code | Should -Contain 'seq'
        $doc = Get-FirstCellName (Get-DocSection '### The log line')
        @($code | Where-Object { $_ -notin $doc }) | Should -BeNullOrEmpty
        @($doc | Where-Object { $_ -notin $code }) | Should -BeNullOrEmpty
    }

    It 'documents every field of the logs answer' {
        $ast = Get-Ast $script:ServerPath
        $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AzlSonarLogsJson' }, $true)
        $code = @([regex]::Matches($function.Body.Extent.Text, '"([a-zA-Z]+)":') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $code | Should -Contain 'lastSeq'
        $section = Get-DocSection '### /api/logs'
        foreach ($field in $code) {
            $section | Should -Match ('(?m)^\|\s*`' + $field + '(\[\])?`\s*\|') -Because "the logs answer has a field $field"
        }
    }

    It 'documents every Server-Sent Events event the code sends, and no other' {
        $code = @([regex]::Matches($script:ServerText, 'event: (\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $code | Should -Contain 'hello'
        $doc = Get-FirstCellName (Get-DocSection '## The live stream (/api/events)') -Pattern '[a-z]+'
        @($code | Where-Object { $_ -notin $doc }) | Should -BeNullOrEmpty
        @($doc | Where-Object { $_ -notin $code }) | Should -BeNullOrEmpty
    }

    It 'states the retry interval, the ping and the Retry-After the code uses' {
        $script:ServerText | Should -Match 'retry: 5000'
        $script:ApiText | Should -Match 'retry: 5000'
        $script:ServerText | Should -Match "'Retry-After' = '30'"
        $script:ApiText | Should -Match 'Retry-After: 30'
        $script:ServerText | Should -Match ': ping'
        $script:ApiText | Should -Match ': ping'
    }

    It 'states the limit <Name> as the number in the code' -ForEach @(
        @{ Name = 'AzlSonarLogsMaxLines'; Format = '{0} lines'; Divide = 1 }
        @{ Name = 'AzlSonarLogsMaxBytes'; Format = '{0} MB'; Divide = 1MB }
        @{ Name = 'AzlSonarSsePingSeconds'; Format = 'every {0} seconds'; Divide = 1 }
        @{ Name = 'AzlSonarSseMaxLinesPerEvent'; Format = 'at most {0}'; Divide = 1 }
        @{ Name = 'AzlSonarSseMaxClients'; Format = 'default {0}'; Divide = 1 }
        @{ Name = 'AzlSonarSseMaxQueuedBytes'; Format = '{0} MiB'; Divide = 1MB }
        @{ Name = 'AzlSonarSseWriteTimeoutSeconds'; Format = 'in {0} seconds'; Divide = 1 }
    ) {
        $m = [regex]::Match($script:ServerText, '(?m)^\$script:' + $Name + '\s*=\s*(\d+)')
        $m.Success | Should -BeTrue -Because "the constant $Name must exist in Server.ps1"
        $value = [long]$m.Groups[1].Value
        $value = $value / $Divide
        $expected = $Format -f $value
        $script:ApiText | Should -Match ([regex]::Escape($expected)) -Because "docs/api.md must say '$expected' for $Name"
    }

    It 'states the ring buffer, timeline and cap sizes the code uses' {
        $shared = $script:ServerText
        $shared | Should -Match '\[int\]\$RingSize = 5000'
        $shared | Should -Match '\[int\]\$TimelineMax = 5000'
        $script:ApiText | Should -Match 'ring buffer of the last 5000'
        $script:ApiText | Should -Match '`timelineMax` \(5000\)'
        $script:ApiText | Should -Match '`logRingSize` \(5000\)'
    }

    It 'documents the access token as 32 hex characters and the cookie the code sets' {
        $script:ServerText | Should -Match 'GetBytes\(16\)'
        $script:ApiText | Should -Match '32 hex characters'
        $script:ServerText | Should -Match 'sonar_t=\$token; HttpOnly; SameSite=Strict; Path=/'
        $script:ApiText | Should -Match ([regex]::Escape('sonar_t=<token>; HttpOnly; SameSite=Strict; Path=/'))
    }
}

Describe 'Status codes and headers' {
    It 'lists every status code the server sends in the status code table' {
        $codes = @([regex]::Matches($script:ServerText, '-StatusCode (\d{3})') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $codes | Should -Contain '401'
        $table = Get-DocSection '### Status codes'
        foreach ($code in @('200') + $codes) {
            $table | Should -Match ('(?m)^\|\s*`' + $code + '`\s*\|') -Because "status $code must be in the table"
        }
    }

    It 'mentions every security header the server sets' {
        $headers = @([regex]::Matches($script:ServerText, "\`$Response\.Headers\['([A-Za-z-]+)'\] = ") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $headers.Count | Should -BeGreaterOrEqual 4
        foreach ($header in $headers) { $script:ApiText | Should -Match ([regex]::Escape($header)) }
    }

    It 'mentions the Allow header and the Host and Origin checks' {
        $script:ApiText | Should -Match 'Allow: GET'
        $script:ApiText | Should -Match '`Host` header'
        $script:ApiText | Should -Match '`Origin` header'
    }
}

Describe 'No real identifier on the page' {
    It 'has no GUID other than the documentation placeholders' {
        $guids = @([regex]::Matches($script:ApiText, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
        @($guids | Where-Object { $_ -notmatch '^00000000-0000-0000-0000-\d{12}$' }) | Should -BeNullOrEmpty
    }

    It 'has no IPv4 address other than documentation ranges and loopback' {
        $ips = @([regex]::Matches($script:ApiText, '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
        @($ips | Where-Object { $_ -notmatch '^(192\.0\.2\.\d+|127\.0\.0\.1|10\.0\.\d+\.\d+)$' -and $_ -ne '1.67.0.0' }) | Should -BeNullOrEmpty
    }

    It 'has no 32-hex token other than the documentation placeholder' {
        $tokens = @([regex]::Matches($script:ApiText, '\b[0-9a-f]{32}\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
        @($tokens | Where-Object { $_ -ne '0123456789abcdef0123456789abcdef' }) | Should -BeNullOrEmpty
    }

    It 'names no real cluster, resource group or node of a lab' {
        $script:ApiText | Should -Not -Match '(?i)tplabs|tierpoint|kturner|hybridsolutions'
    }
}

Describe 'Links and navigation' {
    It 'has no dead relative link or heading anchor (scripts/Test-MarkdownLinks.ps1)' {
        $script = Join-Path $script:RepoRoot 'scripts/Test-MarkdownLinks.ps1'
        $output = & pwsh -NoProfile -File $script -Root $script:RepoRoot 2>&1 | Out-String
        $mine = @($output -split "`r?`n" | Where-Object { $_ -match 'api\.md' })
        $mine | Should -BeNullOrEmpty -Because ('Test-MarkdownLinks reported: ' + ($mine -join '; '))
    }

    It 'is in the VitePress sidebar' {
        $config = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs/.vitepress/config.mts') -Raw
        $config | Should -Match "link: '/api'"
    }

    It 'is linked from <File>' -ForEach @(
        @{ File = 'README.md'; Pattern = '\(docs/api\.md[#)]' }
        @{ File = 'docs/how-it-works.md'; Pattern = '\(\./api\.md[#)]' }
        @{ File = 'docs/config.md'; Pattern = '\(\./api\.md[#)]' }
    ) {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot $File) -Raw
        $text | Should -Match $Pattern
    }

    It 'is mentioned in the README prerequisites (ports)' {
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw
        $readme | Should -Match '(?s)\*\*Network and ports\.\*\*.*?/api'
    }
}
