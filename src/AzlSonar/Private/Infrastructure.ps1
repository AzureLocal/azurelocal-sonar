Set-StrictMode -Version Latest

# Reads the master infrastructure.yml (azurelocal-toolkit, schema 5) and builds Sonar's configuration from it.
# Self-contained on purpose: Sonar must stand alone, so it neither imports the toolkit's loader nor needs a YAML module.
# The YAML reader handles the subset the schema uses (block maps and lists, flow lists and maps, quoted and plain scalars,
# comments, | and > block scalars). Anchors, aliases, tags and multi-document files are refused with a clear message.
# Only the keys Sonar needs are read. A keyvault:// reference is never resolved and no secret key is ever read.

$script:AzlSonarSupportedSchemaMajor = 5
$script:AzlSonarYamlKeyPattern = '^(?<key>"[^"]*"|''[^'']*''|[^\s:"''\[\{#\-][^:]*|-[^\s:][^:]*)\s*:(?:\s+(?<value>.*))?$'

function Get-AzlSonarYamlLineContent {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)

    $quote = [char]0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($quote -ne [char]0) {
            if ($c -eq '\' -and $quote -eq '"') { $i++; continue }
            if ($c -eq $quote) { $quote = [char]0 }
            continue
        }
        if (($c -eq '"' -or $c -eq "'") -and ($i -eq 0 -or $Text[$i - 1] -match '[\s\[\{,:]')) { $quote = $c; continue }
        if ($c -eq '#' -and ($i -eq 0 -or $Text[$i - 1] -match '\s')) { return $Text.Substring(0, $i).TrimEnd() }
    }
    return $Text.TrimEnd()
}

function ConvertFrom-AzlSonarYamlScalar {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $t = $Text.Trim()
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
        return [regex]::Replace($t.Substring(1, $t.Length - 2), '\\(["\\/nt])', {
                param($m)
                switch ($m.Groups[1].Value) { 'n' { "`n" } 't' { "`t" } default { $m.Groups[1].Value } }
            })
    }
    if ($t.Length -ge 2 -and $t.StartsWith("'") -and $t.EndsWith("'")) { return $t.Substring(1, $t.Length - 2).Replace("''", "'") }
    if ($t -eq '' -or $t -eq '~' -or $t -eq 'null') { return $null }
    if ($t -match '^(?i:true)$') { return $true }
    if ($t -match '^(?i:false)$') { return $false }
    if ($t -match '^-?\d{1,9}$') { return [int]$t }
    if ($t -match '^-?\d+\.\d+$') { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($t -match '^[&*!]') { throw "YAML anchors, aliases and tags are not supported: $t" }
    return $t
}

function ConvertFrom-AzlSonarYamlFlowToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [string]$Stop)

    $text = $State.Text
    $start = $State.Pos
    $c = $text[$start]
    if ($c -eq '"' -or $c -eq "'") {
        $i = $start + 1
        while ($i -lt $text.Length) {
            if ($c -eq '"' -and $text[$i] -eq '\') { $i += 2; continue }
            if ($text[$i] -eq $c) {
                if ($c -eq "'" -and ($i + 1) -lt $text.Length -and $text[$i + 1] -eq "'") { $i += 2; continue }
                break
            }
            $i++
        }
        if ($i -ge $text.Length) { throw "Unterminated quoted string in YAML: $text" }
        $State.Pos = $i + 1
        return ConvertFrom-AzlSonarYamlScalar -Text $text.Substring($start, $i + 1 - $start)
    }
    $i = $start
    while ($i -lt $text.Length) {
        $ch = $text[$i]
        if ($Stop.Contains([string]$ch)) {
            # ':' only ends a key when followed by a space; ',' ']' '}' always end a plain value.
            if ($ch -ne ':' -or ($i + 1) -ge $text.Length -or $text[$i + 1] -match '\s') { break }
        }
        $i++
    }
    $State.Pos = $i
    return ConvertFrom-AzlSonarYamlScalar -Text $text.Substring($start, $i - $start)
}

function ConvertFrom-AzlSonarYamlFlow {
    # Parses a flow collection or scalar from $State.Text at $State.Pos: [a, b], { k: v }, "x", plain.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $text = $State.Text
    while ($State.Pos -lt $text.Length -and $text[$State.Pos] -match '\s') { $State.Pos++ }
    if ($State.Pos -ge $text.Length) { return $null }
    $c = $text[$State.Pos]
    if ($c -eq '[') {
        $State.Pos++
        $list = [System.Collections.Generic.List[object]]::new()
        while ($true) {
            while ($State.Pos -lt $text.Length -and $text[$State.Pos] -match '[\s,]') { $State.Pos++ }
            if ($State.Pos -ge $text.Length) { throw "Unterminated [ in YAML: $text" }
            if ($text[$State.Pos] -eq ']') { $State.Pos++; break }
            $list.Add((ConvertFrom-AzlSonarYamlFlow -State $State))
        }
        return , $list.ToArray()
    }
    if ($c -eq '{') {
        $State.Pos++
        $map = [ordered]@{}
        while ($true) {
            while ($State.Pos -lt $text.Length -and $text[$State.Pos] -match '[\s,]') { $State.Pos++ }
            if ($State.Pos -ge $text.Length) { throw "Unterminated { in YAML: $text" }
            if ($text[$State.Pos] -eq '}') { $State.Pos++; break }
            $key = ConvertFrom-AzlSonarYamlFlowToken -State $State -Stop ':,}'
            while ($State.Pos -lt $text.Length -and $text[$State.Pos] -match '\s') { $State.Pos++ }
            if ($State.Pos -ge $text.Length -or $text[$State.Pos] -ne ':') { throw "Expected ':' after '$key' in YAML flow map: $text" }
            $State.Pos++
            $map[[string]$key] = ConvertFrom-AzlSonarYamlFlow -State $State
        }
        return $map
    }
    return ConvertFrom-AzlSonarYamlFlowToken -State $State -Stop ',]}'
}

function ConvertFrom-AzlSonarYamlValueText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $t = $Text.Trim()
    if ($t.StartsWith('[') -or $t.StartsWith('{')) {
        $state = @{ Text = $t; Pos = 0 }
        $value = ConvertFrom-AzlSonarYamlFlow -State $state
        return , $value
    }
    return ConvertFrom-AzlSonarYamlScalar -Text $t
}

function Read-AzlSonarYamlBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Indent)

    $lines = $State.Lines
    $first = $lines[$State.Pos]
    if ($first.Text -match '^-(\s|$)') {
        $list = [System.Collections.Generic.List[object]]::new()
        while ($State.Pos -lt $lines.Count -and $lines[$State.Pos].Indent -eq $Indent -and $lines[$State.Pos].Text -match '^-(\s|$)') {
            $line = $lines[$State.Pos]
            $rest = $line.Text.Substring(1).TrimStart()
            if (-not $rest) {
                $State.Pos++
                if ($State.Pos -lt $lines.Count -and $lines[$State.Pos].Indent -gt $Indent) { $list.Add((Read-AzlSonarYamlBlock -State $State -Indent $lines[$State.Pos].Indent)) }
                else { $list.Add($null) }
            }
            elseif ($rest -match $script:AzlSonarYamlKeyPattern) {
                # "- key: value": the map's keys line up with the text after the dash.
                $line.Indent = $Indent + ($line.Text.Length - $rest.Length)
                $line.Text = $rest
                $list.Add((Read-AzlSonarYamlBlock -State $State -Indent $line.Indent))
            }
            else {
                $State.Pos++
                $list.Add((ConvertFrom-AzlSonarYamlValueText -Text $rest))
            }
        }
        return , $list.ToArray()
    }

    $map = [ordered]@{}
    while ($State.Pos -lt $lines.Count -and $lines[$State.Pos].Indent -ge $Indent) {
        $line = $lines[$State.Pos]
        if ($line.Indent -gt $Indent) { throw "YAML line $($line.No): unexpected indentation." }
        if ($line.Text -match '^-(\s|$)') { break }
        if ($line.Text -notmatch $script:AzlSonarYamlKeyPattern) { throw "YAML line $($line.No): expected 'key: value', found '$($line.Text)'." }
        $key = [string](ConvertFrom-AzlSonarYamlScalar -Text $Matches['key'])
        $valueText = if ($Matches.ContainsKey('value')) { $Matches['value'].Trim() } else { '' }
        $State.Pos++
        if ($valueText -match '^[|>][+-]?$') {
            $folded = $valueText.StartsWith('>')
            $parts = [System.Collections.Generic.List[string]]::new()
            while ($State.Pos -lt $lines.Count -and $lines[$State.Pos].Indent -gt $Indent) { $parts.Add($lines[$State.Pos].Text); $State.Pos++ }
            $map[$key] = $parts -join $(if ($folded) { ' ' } else { "`n" })
        }
        elseif ($valueText) {
            $map[$key] = ConvertFrom-AzlSonarYamlValueText -Text $valueText
        }
        elseif ($State.Pos -lt $lines.Count -and ($lines[$State.Pos].Indent -gt $Indent -or ($lines[$State.Pos].Indent -eq $Indent -and $lines[$State.Pos].Text -match '^-(\s|$)'))) {
            $map[$key] = Read-AzlSonarYamlBlock -State $State -Indent $lines[$State.Pos].Indent
        }
        else {
            $map[$key] = $null
        }
    }
    return $map
}

function ConvertFrom-AzlSonarYaml {
    <#
    .SYNOPSIS
        Parses the YAML subset infrastructure.yml uses into ordered dictionaries, arrays and scalars.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = [System.Collections.Generic.List[object]]::new()
    $number = 0
    foreach ($raw in ($Text -split "\r?\n")) {
        $number++
        if ($raw -match '^\s*(#|$)') { continue }
        if ($raw -match '^(---|\.\.\.)\s*$') {
            if ($lines.Count -gt 0 -and $raw -like '---*') { throw "YAML line ${number}: more than one document is not supported." }
            continue
        }
        if ($raw -match '^ *\t') { throw "YAML line ${number}: tabs cannot indent YAML." }
        $clean = Get-AzlSonarYamlLineContent -Text $raw
        if (-not $clean.Trim()) { continue }
        $indent = $clean.Length - $clean.TrimStart().Length
        $lines.Add([pscustomobject]@{ Indent = $indent; Text = $clean.Trim(); No = $number })
    }
    if ($lines.Count -eq 0) { return [ordered]@{} }
    $state = @{ Lines = $lines; Pos = 0 }
    $result = Read-AzlSonarYamlBlock -State $state -Indent $lines[0].Indent
    if ($state.Pos -lt $lines.Count) { throw "YAML line $($lines[$state.Pos].No): unexpected content." }
    return $result
}

function Get-AzlSonarInfrastructureValue {
    # Value at a dotted path of an infrastructure tree; $null when any part is missing.
    [CmdletBinding()]
    param([AllowNull()][object]$Tree, [Parameter(Mandatory)][string]$Path)

    $node = $Tree
    foreach ($part in $Path.Split('.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] } else { return $null }
    }
    return $node
}

function ConvertFrom-AzlSonarInfrastructureTree {
    <#
    .SYNOPSIS
        Maps a parsed schema 5 infrastructure tree to Sonar's raw configuration. Pure: no file access.
    .DESCRIPTION
        azure.subscription_id -> subscriptionId, azure.resource_group -> resourceGroup, cluster.name -> clusterName,
        scenario.os_install (simplified | iso) -> provisioningRoute (simplified | oem-image),
        scenario.identity (active_directory | local_identity) -> identityModel (ActiveDirectory | LocalIdentity),
        nodes[].name -> nodes[].name, the management address of a node = the ip_address of its network_adapters[] port with
        role management and ip_assignment static or dhcp_reservation (schema 5.0 and 5.1 files: nodes[].management.ip_address),
        the first listed node is the seed (schema 5.3 has no seed key),
        provisioning.simplified.evidence_path\ztp-events.jsonl -> ztpEvents.path (simplified route only).
        Returns { Config; Problems }. Config is $null when there are problems.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Tree,
        [string]$BaseDirectory = '',
        [Nullable[int]]$PollSeconds
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $fail = { param($p, $m) $problems.Add("$p : $m (infrastructure.yml, schema 5)") }

    if ($Tree -isnot [System.Collections.IDictionary]) {
        & $fail '(file)' 'the file is empty or is not a YAML map'
        return [pscustomobject]@{ Config = $null; Problems = $problems.ToArray() }
    }

    $version = Get-AzlSonarInfrastructureValue $Tree '_metadata.schema_version'
    if (-not $version) { & $fail '_metadata.schema_version' 'is missing; Sonar reads schema 5 files (for example "5.3.0")' }
    elseif (([string]$version) -notmatch "^$($script:AzlSonarSupportedSchemaMajor)(\.|$)") { & $fail '_metadata.schema_version' "is '$version'; Sonar reads schema $($script:AzlSonarSupportedSchemaMajor).x files" }

    $required = [ordered]@{
        'azure.subscription_id' = 'the subscription of the cluster'
        'azure.resource_group'  = 'the resource group of the cluster'
        'cluster.name'          = 'the cluster name'
    }
    $values = @{}
    foreach ($path in $required.Keys) {
        $v = Get-AzlSonarInfrastructureValue $Tree $path
        if ($null -eq $v -or -not ([string]$v).Trim()) { & $fail $path "is missing; Sonar needs $($required[$path])" } else { $values[$path] = ([string]$v).Trim() }
    }

    $osInstall = Get-AzlSonarInfrastructureValue $Tree 'scenario.os_install'
    $route = $null
    if ($null -eq $osInstall) { & $fail 'scenario.os_install' 'is missing; use simplified or iso' }
    else {
        switch (([string]$osInstall).ToLowerInvariant()) {
            'simplified' { $route = 'simplified' }
            'iso' { $route = 'oem-image' }
            default { & $fail 'scenario.os_install' "is '$osInstall'; use simplified or iso" }
        }
    }

    $identity = Get-AzlSonarInfrastructureValue $Tree 'scenario.identity'
    $identityModel = $null
    if ($null -eq $identity) { & $fail 'scenario.identity' 'is missing; use active_directory or local_identity' }
    else {
        switch (([string]$identity).ToLowerInvariant()) {
            'active_directory' { $identityModel = 'ActiveDirectory' }
            'local_identity' { $identityModel = 'LocalIdentity' }
            default { & $fail 'scenario.identity' "is '$identity'; use active_directory or local_identity" }
        }
    }

    $nodeList = @($(if ($Tree.Contains('nodes') -and $null -ne $Tree['nodes']) { $Tree['nodes'] }))
    $nodes = [System.Collections.Generic.List[object]]::new()
    if ($nodeList.Count -eq 0) { & $fail 'nodes' 'is missing or empty; list at least one machine' }
    for ($i = 0; $i -lt $nodeList.Count; $i++) {
        $node = $nodeList[$i]
        if ($node -isnot [System.Collections.IDictionary]) { & $fail "nodes[$i]" 'is not a map'; continue }
        $name = if ($node.Contains('name') -and $null -ne $node['name']) { ([string]$node['name']).Trim() } else { '' }
        if (-not $name) { & $fail "nodes[$i].name" 'is missing'; continue }
        $address = $null
        if ($node.Contains('network_adapters') -and $null -ne $node['network_adapters']) {
            foreach ($port in @($node['network_adapters'])) {
                if ($port -isnot [System.Collections.IDictionary]) { continue }
                $roles = @(@($(if ($port.Contains('roles')) { $port['roles'] })) | ForEach-Object { ([string]$_).ToLowerInvariant() })
                $assignment = if ($port.Contains('ip_assignment') -and $null -ne $port['ip_assignment']) { ([string]$port['ip_assignment']).ToLowerInvariant() } else { '' }
                if ('management' -in $roles -and $assignment -in 'static', 'dhcp_reservation' -and $port.Contains('ip_address') -and $port['ip_address']) {
                    $address = [string]$port['ip_address']
                    break
                }
            }
            if (-not $address) {
                & $fail "nodes[$i].network_adapters" "node '$name' has no port with roles management, ip_assignment static or dhcp_reservation and an ip_address"
            }
        }
        elseif ($node.Contains('management') -and $node['management'] -is [System.Collections.IDictionary] -and $node['management'].Contains('ip_address') -and $node['management']['ip_address']) {
            $address = [string]$node['management']['ip_address']
        }
        else {
            & $fail "nodes[$i].network_adapters" "node '$name' has no network_adapters (schema 5.2) and no management.ip_address (schema 5.0 and 5.1): Sonar cannot find its management address"
        }
        if ($address) {
            $entry = [ordered]@{ name = $name; address = $address }
            if ($node.Contains('arc_machine_name') -and $node['arc_machine_name']) { $entry['arcMachineName'] = [string]$node['arc_machine_name'] }
            $nodes.Add($entry)
        }
    }

    $ztpPath = $null
    if ($route -eq 'simplified') {
        $evidence = Get-AzlSonarInfrastructureValue $Tree 'provisioning.simplified.evidence_path'
        if ($evidence) { $evidence = [string]$evidence }
        else {
            # ZTP's documented default: %ProgramData%\AzureLocalZtp\<site_name>\evidence
            $site = Get-AzlSonarInfrastructureValue $Tree 'provisioning.simplified.site_name'
            if ($site) { $evidence = "%ProgramData%\AzureLocalZtp\$site\evidence" }
            else { & $fail 'provisioning.simplified.evidence_path' 'is missing (and provisioning.simplified.site_name, for the default folder); Sonar needs the folder of ztp-events.jsonl on the simplified route' }
        }
        if ($evidence) {
            $evidence = [Environment]::ExpandEnvironmentVariables($evidence)
            $separator = if ($evidence.Contains('\')) { '\' } else { '/' }
            $ztpPath = $evidence.TrimEnd('\', '/') + $separator + 'ztp-events.jsonl'
            $rooted = $ztpPath -match '^([A-Za-z]:[\\/]|\\\\|/)'
            if (-not $rooted -and $BaseDirectory) { $ztpPath = [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $ztpPath)) }
        }
    }

    if ($problems.Count -gt 0) { return [pscustomobject]@{ Config = $null; Problems = $problems.ToArray() } }

    # Schema 5.3 has no seed key: the first listed node is the seed node (the one whose logs are read).
    $nodes[0]['seed'] = $true
    $config = [ordered]@{
        subscriptionId    = $values['azure.subscription_id']
        resourceGroup     = $values['azure.resource_group']
        clusterName       = $values['cluster.name']
        provisioningRoute = $route
        identityModel     = $identityModel
    }
    if ($null -ne $PollSeconds) { $config['pollSeconds'] = [int]$PollSeconds }
    $config['nodes'] = $nodes.ToArray()
    if ($ztpPath) { $config['ztpEvents'] = [ordered]@{ path = $ztpPath } }
    # The credential never comes from the infrastructure file (it holds keyvault:// references only).
    $config['credential'] = [ordered]@{ source = 'prompt' }
    return [pscustomobject]@{ Config = $config; Problems = @() }
}

function Read-AzlSonarInfrastructureFile {
    <#
    .SYNOPSIS
        Reads a schema 5 infrastructure.yml and returns Sonar's raw configuration (ordered dictionary). Throws one error
        listing every problem, each naming the schema 5 key.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Nullable[int]]$PollSeconds)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Infrastructure file not found: $Path" }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    try { $tree = ConvertFrom-AzlSonarYaml -Text (Get-Content -LiteralPath $full -Raw) }
    catch { throw "Infrastructure file ($full) is not valid YAML: $($_.Exception.Message)" }
    $mapped = ConvertFrom-AzlSonarInfrastructureTree -Tree $tree -BaseDirectory ([System.IO.Path]::GetDirectoryName($full)) -PollSeconds $PollSeconds
    if ($mapped.Problems.Count -gt 0) {
        throw ("Infrastructure file ($full) does not give Sonar what it needs:`n - " + ($mapped.Problems -join "`n - "))
    }
    return $mapped.Config
}

function Compare-AzlSonarNodeSet {
    <#
    .SYNOPSIS
        Compares two lists of nodes (name, address) and returns what was added, removed or changed address.
    #>
    [CmdletBinding()]
    param([object[]]$Old = @(), [object[]]$New = @())

    $oldMap = @{}; foreach ($n in $Old) { $oldMap[([string]$n.name).ToLowerInvariant()] = $n }
    $newMap = @{}; foreach ($n in $New) { $newMap[([string]$n.name).ToLowerInvariant()] = $n }
    $added = @($New | Where-Object { -not $oldMap.ContainsKey(([string]$_.name).ToLowerInvariant()) } | ForEach-Object { [string]$_.name })
    $removed = @($Old | Where-Object { -not $newMap.ContainsKey(([string]$_.name).ToLowerInvariant()) } | ForEach-Object { [string]$_.name })
    $changed = @($New | Where-Object {
            $k = ([string]$_.name).ToLowerInvariant()
            $oldMap.ContainsKey($k) -and [string]$oldMap[$k].address -ne [string]$_.address
        } | ForEach-Object { [string]$_.name })
    return [pscustomobject]@{ Added = $added; Removed = $removed; Changed = $changed; Different = (($added.Count + $removed.Count + $changed.Count) -gt 0) }
}

function Invoke-AzlSonarInfrastructureCheck {
    <#
    .SYNOPSIS
        One check of the master file: when its modification time changed, re-reads it and returns a notice if the node set
        changed. The pollers are built at start, so the notice asks for a restart rather than changing them live.
    .OUTPUTS
        The notice text, or $null. $State is updated (LastWrite, Nodes, LastError).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if ($item.LastWriteTimeUtc -eq $State.LastWrite) { return $null }
    $State.LastWrite = $item.LastWriteTimeUtc
    try {
        $fresh = Read-AzlSonarConfig -InfrastructureFile $Path 3>$null
    }
    catch {
        $message = $_.Exception.Message
        if ($message -eq $State.LastError) { return $null }
        $State.LastError = $message
        return "[sonar] The master infrastructure file changed but cannot be read, so Sonar keeps the nodes it has: $($message -replace '\s+', ' ')"
    }
    $State.LastError = ''
    $diff = Compare-AzlSonarNodeSet -Old $State.Nodes -New $fresh.nodes
    if (-not $diff.Different) { return $null }
    $State.Nodes = @($fresh.nodes)
    $parts = @()
    if ($diff.Added.Count) { $parts += "added: $($diff.Added -join ', ')" }
    if ($diff.Removed.Count) { $parts += "removed: $($diff.Removed -join ', ')" }
    if ($diff.Changed.Count) { $parts += "new address: $($diff.Changed -join ', ')" }
    return "[sonar] The master infrastructure file changed its node set ($($parts -join '; ')). Nodes now: $((@($fresh.nodes) | ForEach-Object { $_.name }) -join ', '). Restart Sonar to track the change."
}

function Invoke-AzlSonarInfrastructureWatchLoop {
    <#
    .SYNOPSIS
        Worker: every CheckSeconds, checks whether the infrastructure file changed and logs a notice when the node set did.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Path,
        [double]$CheckSeconds = 60
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    $state = @{ LastWrite = $(if ($item) { $item.LastWriteTimeUtc } else { [datetime]::MinValue }); Nodes = @($Config.nodes); LastError = '' }
    while (-not $Shared.Stop) {
        Wait-AzlSonarInterval -Shared $Shared -Seconds $CheckSeconds
        if ($Shared.Stop) { break }
        try {
            $notice = Invoke-AzlSonarInfrastructureCheck -Path $Path -State $state
            if ($notice) { Add-AzlSonarLogLine -Shared $Shared -Line @(@{ file = 'sonar'; text = $notice }) }
        }
        catch { Write-Verbose "Infrastructure file check failed: $($_.Exception.Message)" }
    }
}
