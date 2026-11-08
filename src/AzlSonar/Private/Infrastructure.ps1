Set-StrictMode -Version Latest

# Reads the master infrastructure.yml (azurelocal-toolkit, schema 5) and builds Sonar's configuration from it.
# Self-contained on purpose: Sonar must stand alone, so it neither imports the toolkit's loader nor needs a YAML module.
# The YAML reader handles the subset the schema uses (block maps and lists, flow lists and maps on one line, quoted and plain
# scalars on one line, comments, | and > block scalars). Anchors, aliases, tags, multi-document files, quoted values and flow
# collections that continue on the next line, and duplicate keys are refused with a message that names the line (never its text).
# Only the keys Sonar needs are read. A keyvault:// reference is never resolved and no secret key is ever read.

$script:AzlSonarSupportedSchemaMajor = 5
$script:AzlSonarYamlKeyPattern = '^(?<key>"[^"]*"|''[^'']*''|[^\s:"''\[\{#\-][^:]*|-[^\s:][^:]*)\s*:(?:\s+(?<value>.*))?$'
$script:AzlSonarYamlMaxBytes = 2MB
$script:AzlSonarYamlMaxDepth = 40
$script:AzlSonarYamlLine = 0   # the line being parsed; the block reader sets it so every error can name the line

function Get-AzlSonarYamlWhere {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:AzlSonarYamlLine -gt 0) { return "YAML line $($script:AzlSonarYamlLine):" }
    return 'YAML:'
}

function Get-AzlSonarYamlLineContent {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)

    $quote = [char]0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($quote -ne [char]0) {
            if ($c -eq '\' -and $quote -eq '"') { $i++; continue }
            if ($c -eq $quote) {
                # '' inside a single-quoted scalar is an escaped quote, not a close followed by an open.
                if ($quote -eq "'" -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
                $quote = [char]0
            }
            continue
        }
        if (($c -eq '"' -or $c -eq "'") -and ($i -eq 0 -or $Text[$i - 1] -match '[\s\[\{,:]')) { $quote = $c; continue }
        if ($c -eq '#' -and ($i -eq 0 -or $Text[$i - 1] -match '\s')) { return $Text.Substring(0, $i).TrimEnd() }
    }
    return $Text.TrimEnd()
}

function Find-AzlSonarYamlQuoteEnd {
    # Index of the quote that closes the quoted scalar opening at $Start; -1 when the line ends first.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][int]$Start)

    $q = $Text[$Start]
    $i = $Start + 1
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($q -eq '"' -and $c -eq '\') { $i += 2; continue }
        if ($c -eq $q) {
            if ($q -eq "'" -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i += 2; continue }
            return $i
        }
        $i++
    }
    return -1
}

function ConvertFrom-AzlSonarYamlQuoted {
    # Decodes one complete quoted scalar (quotes included). Throws a line-numbered error when it does not close on this line
    # or has text after the closing quote.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)

    $end = Find-AzlSonarYamlQuoteEnd -Text $Text -Start 0
    $kind = if ($Text[0] -eq '"') { 'double-quoted' } else { 'single-quoted' }
    if ($end -lt 0) { throw "$(Get-AzlSonarYamlWhere) a $kind value that continues on the next line is not supported (put it on one line)." }
    if ($end -ne $Text.Length - 1) { throw "$(Get-AzlSonarYamlWhere) text after the closing quote of a $kind value is not allowed." }
    $inner = $Text.Substring(1, $Text.Length - 2)
    if ($Text[0] -eq "'") { return $inner.Replace("''", "'") }
    return [regex]::Replace($inner, '\\(["\\/nt])', {
            param($m)
            switch ($m.Groups[1].Value) { 'n' { "`n" } 't' { "`t" } default { $m.Groups[1].Value } }
        })
}

function ConvertFrom-AzlSonarYamlScalar {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $t = $Text.Trim()
    if ($t.StartsWith('"') -or $t.StartsWith("'")) { return ConvertFrom-AzlSonarYamlQuoted -Text $t }
    if ($t -eq '' -or $t -eq '~' -or $t -eq 'null') { return $null }
    if ($t -match '^(?i:true)$') { return $true }
    if ($t -match '^(?i:false)$') { return $false }
    # Integers up to 9 digits without a leading zero (007 stays text: it may be a name). Longer numbers stay text.
    if ($t -match '^-?(0|[1-9]\d{0,8})$') { return [int]$t }
    if ($t -match '^-?\d+\.\d+$') { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($t -match '^[&*!]') { throw "$(Get-AzlSonarYamlWhere) YAML anchors, aliases and tags are not supported." }
    return $t
}

function ConvertFrom-AzlSonarYamlKey {
    # A mapping key is always a string: quoted keys are unquoted, plain keys are trimmed ("scenario : x" is key scenario).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)

    $t = $Text.Trim()
    if ($t.StartsWith('"') -or $t.StartsWith("'")) { return ConvertFrom-AzlSonarYamlQuoted -Text $t }
    return $t
}

function ConvertFrom-AzlSonarYamlFlowToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [string]$Stop)

    $text = $State.Text
    $start = $State.Pos
    $c = $text[$start]
    if ($c -eq '"' -or $c -eq "'") {
        $end = Find-AzlSonarYamlQuoteEnd -Text $text -Start $start
        if ($end -lt 0) { throw "$(Get-AzlSonarYamlWhere) a quoted value that continues on the next line is not supported (put it on one line)." }
        $j = $end + 1
        while ($j -lt $text.Length -and $text[$j] -eq ' ') { $j++ }
        if ($j -lt $text.Length -and ',]}:'.IndexOf($text[$j]) -lt 0) { throw "$(Get-AzlSonarYamlWhere) text after the closing quote of a quoted value is not allowed." }
        $State.Pos = $end + 1
        return ConvertFrom-AzlSonarYamlScalar -Text $text.Substring($start, $end + 1 - $start)
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
    if ($c -eq '[' -or $c -eq '{') {
        $State.Depth++
        if ($State.Depth + $State.BaseDepth -gt $script:AzlSonarYamlMaxDepth) {
            throw "$(Get-AzlSonarYamlWhere) nesting deeper than $($script:AzlSonarYamlMaxDepth) levels is not supported"
        }
    }
    if ($c -eq '[') {
        $State.Pos++
        $list = [System.Collections.Generic.List[object]]::new()
        while ($true) {
            while ($State.Pos -lt $text.Length -and $text[$State.Pos] -match '[\s,]') { $State.Pos++ }
            if ($State.Pos -ge $text.Length) { throw "$(Get-AzlSonarYamlWhere) a [ ... ] flow collection that continues on the next line is not supported (put it on one line, or use a block list)." }
            if ($text[$State.Pos] -eq ']') { $State.Pos++; break }
            $list.Add((ConvertFrom-AzlSonarYamlFlow -State $State))
        }
        $State.Depth--
        return , $list.ToArray()
    }
    if ($c -eq '{') {
        $State.Pos++
        $map = [ordered]@{}
        while ($true) {
            while ($State.Pos -lt $text.Length -and $text[$State.Pos] -match '[\s,]') { $State.Pos++ }
            if ($State.Pos -ge $text.Length) { throw "$(Get-AzlSonarYamlWhere) a { ... } flow collection that continues on the next line is not supported (put it on one line, or use a block map)." }
            if ($text[$State.Pos] -eq '}') { $State.Pos++; break }
            $key = [string](ConvertFrom-AzlSonarYamlFlowToken -State $State -Stop ':,}')
            while ($State.Pos -lt $text.Length -and $text[$State.Pos] -match '\s') { $State.Pos++ }
            if ($State.Pos -ge $text.Length -or $text[$State.Pos] -ne ':') { throw "$(Get-AzlSonarYamlWhere) expected ':' after a key in a flow map." }
            if ($map.Contains($key)) { throw "$(Get-AzlSonarYamlWhere) duplicate key '$key' in a flow map." }
            $State.Pos++
            $map[$key] = ConvertFrom-AzlSonarYamlFlow -State $State
        }
        $State.Depth--
        return $map
    }
    return ConvertFrom-AzlSonarYamlFlowToken -State $State -Stop ',]}'
}

function ConvertFrom-AzlSonarYamlValueText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [int]$Depth = 0)

    $t = $Text.Trim()
    if ($t.StartsWith('[') -or $t.StartsWith('{')) {
        $state = @{ Text = $t; Pos = 0; Depth = 0; BaseDepth = $Depth }
        $value = ConvertFrom-AzlSonarYamlFlow -State $state
        while ($state.Pos -lt $t.Length -and $t[$state.Pos] -match '\s') { $state.Pos++ }
        if ($state.Pos -lt $t.Length) { throw "$(Get-AzlSonarYamlWhere) text after the closing bracket of a flow collection is not allowed." }
        return , $value
    }
    return ConvertFrom-AzlSonarYamlScalar -Text $t
}

function Read-AzlSonarYamlBlockScalar {
    # Reads the lines of a | or > block scalar that follow line $HeaderNo, from the raw lines (blank lines, relative
    # indentation and # lines inside the block are text). Moves $State.Pos past every parsed line the block used.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$HeaderNo, [Parameter(Mandatory)][int]$Indent, [Parameter(Mandatory)][string]$Header)

    $raw = $State.Raw
    $folded = $Header.StartsWith('>')
    $chomp = if ($Header.EndsWith('-')) { 'strip' } elseif ($Header.EndsWith('+')) { 'keep' } else { 'clip' }
    $blockIndent = -1
    $content = [System.Collections.Generic.List[string]]::new()
    $last = $HeaderNo   # last raw line number holding block text
    $n = $HeaderNo + 1
    while ($n -le $raw.Count) {
        $r = $raw[$n - 1]
        if ($r.Trim() -eq '') { $content.Add(''); $n++; continue }
        $ind = $r.Length - $r.TrimStart(' ').Length
        if ($ind -le $Indent) { break }
        if ($blockIndent -lt 0) { $blockIndent = $ind }
        elseif ($ind -lt $blockIndent) { throw "YAML line ${n}: a block scalar line is indented less than the first line of the block." }
        $content.Add($r.Substring($blockIndent))
        $last = $n
        $n++
    }
    # Blank lines after the last text line are trailing blanks (kept only by +).
    $count = $content.Count
    while ($count -gt 0 -and $content[$count - 1] -eq '') { $count-- }
    $trailingBlank = $content.Count - $count
    $textLines = [System.Collections.Generic.List[string]]::new()
    if ($count -gt 0) { $textLines.AddRange($content.GetRange(0, $count)) }

    $sb = [System.Text.StringBuilder]::new()
    if ($folded) {
        $prev = $null
        $blanks = 0
        foreach ($l in $textLines) {
            if ($l -eq '') { $blanks++; continue }
            if ($null -eq $prev) { [void]$sb.Append("`n" * $blanks).Append($l) }
            else {
                $more = $l.StartsWith(' ') -or $prev.StartsWith(' ')
                if ($blanks -gt 0) { [void]$sb.Append("`n" * $(if ($more) { $blanks + 1 } else { $blanks })) }
                elseif ($more) { [void]$sb.Append("`n") }
                else { [void]$sb.Append(' ') }
                [void]$sb.Append($l)
            }
            $prev = $l
            $blanks = 0
        }
    }
    else {
        [void]$sb.Append(($textLines -join "`n"))
    }
    if ($textLines.Count -gt 0) {
        if ($chomp -eq 'clip') { [void]$sb.Append("`n") }
        elseif ($chomp -eq 'keep') { [void]$sb.Append("`n" * ($trailingBlank + 1)) }
    }
    elseif ($chomp -eq 'keep') { [void]$sb.Append("`n" * $trailingBlank) }

    $lines = $State.Lines
    while ($State.Pos -lt $lines.Count -and $lines[$State.Pos].No -le $last) { $State.Pos++ }
    return $sb.ToString()
}

function Read-AzlSonarYamlBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Indent, [int]$Depth = 1)

    $lines = $State.Lines
    $first = $lines[$State.Pos]
    $script:AzlSonarYamlLine = $first.No
    if ($Depth -gt $script:AzlSonarYamlMaxDepth) { throw "$(Get-AzlSonarYamlWhere) nesting deeper than $($script:AzlSonarYamlMaxDepth) levels is not supported" }
    if ($first.Text -match '^-(\s|$)') {
        $list = [System.Collections.Generic.List[object]]::new()
        while ($State.Pos -lt $lines.Count -and $lines[$State.Pos].Indent -eq $Indent -and $lines[$State.Pos].Text -match '^-(\s|$)') {
            $line = $lines[$State.Pos]
            $script:AzlSonarYamlLine = $line.No
            $rest = $line.Text.Substring(1).TrimStart()
            if (-not $rest) {
                $State.Pos++
                if ($State.Pos -lt $lines.Count -and $lines[$State.Pos].Indent -gt $Indent) { $list.Add((Read-AzlSonarYamlBlock -State $State -Indent $lines[$State.Pos].Indent -Depth ($Depth + 1))) }
                else { $list.Add($null) }
                continue
            }
            if ($rest -match '^-(\s|$)') { throw "$(Get-AzlSonarYamlWhere) a nested list on one line ('- - item') is not supported (use a block list)." }
            $keyMatch = [regex]::Match($rest, $script:AzlSonarYamlKeyPattern)
            if ($keyMatch.Success) {
                # "- key: value": the map's keys line up with the text after the dash.
                $line.Indent = $Indent + ($line.Text.Length - $rest.Length)
                $line.Text = $rest
                $list.Add((Read-AzlSonarYamlBlock -State $State -Indent $line.Indent -Depth ($Depth + 1)))
            }
            else {
                $State.Pos++
                $list.Add((ConvertFrom-AzlSonarYamlValueText -Text $rest -Depth $Depth))
            }
        }
        return , $list.ToArray()
    }

    $map = [ordered]@{}
    $keyLine = @{}
    while ($State.Pos -lt $lines.Count -and $lines[$State.Pos].Indent -ge $Indent) {
        $line = $lines[$State.Pos]
        $script:AzlSonarYamlLine = $line.No
        if ($line.Indent -gt $Indent) { throw "YAML line $($line.No): unexpected indentation." }
        if ($line.Text -match '^-(\s|$)') { break }
        # Read the key and the value into locals first: a later regex (the scalar converter runs several) must not be able to lose them.
        $keyMatch = [regex]::Match($line.Text, $script:AzlSonarYamlKeyPattern)
        if (-not $keyMatch.Success) { throw "YAML line $($line.No): expected 'key: value'." }
        $rawKey = $keyMatch.Groups['key'].Value
        $valueText = if ($keyMatch.Groups['value'].Success) { $keyMatch.Groups['value'].Value.Trim() } else { '' }
        $key = ConvertFrom-AzlSonarYamlKey -Text $rawKey
        if ($keyLine.ContainsKey($key)) { throw "YAML line $($line.No): duplicate key '$key' (first on line $($keyLine[$key]))." }
        $keyLine[$key] = $line.No
        $State.Pos++
        if ($valueText.StartsWith('|') -or $valueText.StartsWith('>')) {
            if ($valueText -notmatch '^[|>][+-]?$') { throw "YAML line $($line.No): this block scalar header is not supported (use | or >, optionally with - or +)." }
            $map[$key] = Read-AzlSonarYamlBlockScalar -State $State -HeaderNo $line.No -Indent $Indent -Header $valueText
        }
        elseif ($valueText) {
            $map[$key] = ConvertFrom-AzlSonarYamlValueText -Text $valueText -Depth $Depth
        }
        elseif ($State.Pos -lt $lines.Count -and ($lines[$State.Pos].Indent -gt $Indent -or ($lines[$State.Pos].Indent -eq $Indent -and $lines[$State.Pos].Text -match '^-(\s|$)'))) {
            $map[$key] = Read-AzlSonarYamlBlock -State $State -Indent $lines[$State.Pos].Indent -Depth ($Depth + 1)
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

    $script:AzlSonarYamlLine = 0
    if ([System.Text.Encoding]::UTF8.GetByteCount($Text) -gt $script:AzlSonarYamlMaxBytes) { throw 'YAML input is larger than the 2 MB limit.' }
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    $rawLines = [System.Collections.Generic.List[string]]::new([string[]]($Text -split "\r?\n"))
    # The empty piece after the final newline is not a line.
    if ($rawLines.Count -gt 1 -and $rawLines[$rawLines.Count - 1] -eq '') { $rawLines.RemoveAt($rawLines.Count - 1) }
    $lines = [System.Collections.Generic.List[object]]::new()
    $number = 0
    $started = $false
    $ended = $false
    foreach ($raw in $rawLines) {
        $number++
        if ($raw -match '^\s*(#|$)') { continue }
        if ($raw -match '^(---|\.\.\.)(\s|$)') {
            $marker = (Get-AzlSonarYamlLineContent -Text $raw).Trim()   # '--- # comment' is a document start
            if ($marker -eq '---' -or $marker -eq '...') {
                if ($ended -or ($marker -eq '---' -and $started)) { throw "YAML line ${number}: more than one document is not supported." }
                if ($marker -eq '...') { $ended = $true }
                continue
            }
        }
        if ($ended) { throw "YAML line ${number}: more than one document is not supported (content after '...')." }
        if ($raw -match '^ *\t') { throw "YAML line ${number}: tabs cannot indent YAML." }
        $clean = Get-AzlSonarYamlLineContent -Text $raw
        if (-not $clean.Trim()) { continue }
        $started = $true
        $indent = $clean.Length - $clean.TrimStart().Length
        $lines.Add([pscustomobject]@{ Indent = $indent; Text = $clean.Trim(); No = $number })
    }
    if ($lines.Count -eq 0) { return [ordered]@{} }
    # Raw keeps every line, with its indentation and the blank and # lines the parsed list drops: block scalars read from it.
    $state = @{ Lines = $lines; Pos = 0; Raw = $rawLines }
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
        provisioning.simplified.evidence_path\ztp-events.jsonl -> ztpEvents.path (simplified route only),
        provisioning.simplified.evidence_path\os-configuration-events.jsonl -> osConfigEventsPath (the OS configuration event
        file, next to the ZTP one; on the ISO route only when evidence_path is set),
        <temp>/azl-arm-<cluster.name>/arm-deployment-events.jsonl -> armEventsPath (the toolkit's default report directory for
        the ARM Validate and Deploy run).
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
    $osConfigPath = $null
    $eventFile = {
        param($folder, $name)
        $folder = [Environment]::ExpandEnvironmentVariables([string]$folder)
        $separator = if ($folder.Contains('\')) { '\' } else { '/' }
        $path = $folder.TrimEnd('\', '/') + $separator + $name
        $rooted = $path -match '^([A-Za-z]:[\\/]|\\\\|/)'
        if (-not $rooted -and $BaseDirectory) { $path = [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $path)) }
        $path
    }
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
            $osConfigPath = & $eventFile $evidence 'os-configuration-events.jsonl'
        }
    }
    else {
        # ISO route: OS configuration still writes its event file; follow it when the file names the evidence folder.
        $isoEvidence = Get-AzlSonarInfrastructureValue $Tree 'provisioning.simplified.evidence_path'
        if ($isoEvidence) { $osConfigPath = & $eventFile $isoEvidence 'os-configuration-events.jsonl' }
    }

    # Which account reads a node's logs: the local administrator (identity.local_admin) until the node has reported DomainJoined
    # and DomainAdminsConfigured, then the domain account the operator supplies (identity.active_directory.domain_join_account:
    # username and a keyvault:// password reference, with the domain's netbios_name). Sonar never uses the LCM user
    # (identity.active_directory.lcm_user): it belongs to the deployment. Read defensively (the keys may be absent). Only
    # names and a keyvault:// reference are kept; a password that is not a valid reference is refused, and is never echoed.
    $localAdmin = Get-AzlSonarInfrastructureValue $Tree 'identity.local_admin.username'
    $accounts = [ordered]@{}
    if ($localAdmin -and ([string]$localAdmin).Trim()) { $accounts['local'] = [ordered]@{ username = ([string]$localAdmin).Trim() } }
    if ($identityModel -eq 'ActiveDirectory') {
        $netbios = Get-AzlSonarInfrastructureValue $Tree 'identity.active_directory.netbios_name'
        $joinUser = Get-AzlSonarInfrastructureValue $Tree 'identity.active_directory.domain_join_account.username'
        $joinRef = Get-AzlSonarInfrastructureValue $Tree 'identity.active_directory.domain_join_account.password'
        if ($joinUser -and ([string]$joinUser).Trim()) {
            $domain = [ordered]@{ username = ([string]$joinUser).Trim() }
            if ($netbios -and ([string]$netbios).Trim()) { $domain['netbios'] = ([string]$netbios).Trim() }
            if ($null -ne $joinRef -and "$joinRef" -ne '') {
                $refProblem = Get-AzlSonarKeyVaultReferenceProblem -Reference ([string]$joinRef)
                if ($refProblem) { & $fail 'identity.active_directory.domain_join_account.password' $refProblem }
                else { $domain['passwordRef'] = [string]$joinRef }
            }
            $accounts['domain'] = $domain
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
    $location = Get-AzlSonarInfrastructureValue $Tree 'azure.location'
    if ($location -and ([string]$location).Trim()) { $config['location'] = ([string]$location).Trim() }
    if ($null -ne $PollSeconds) { $config['pollSeconds'] = [int]$PollSeconds }
    $config['nodes'] = $nodes.ToArray()
    if ($ztpPath) { $config['ztpEvents'] = [ordered]@{ path = $ztpPath } }
    if ($osConfigPath) { $config['osConfigEventsPath'] = $osConfigPath }
    # The toolkit's ARM Validate and Deploy run writes arm-deployment-events.jsonl into its -ReportDirectory, which defaults to
    # <temp>/azl-arm-<cluster.name> (Invoke-AzlArmDeploymentRun). Sonar follows that default; armEventsPath moves it.
    $config['armEventsPath'] = Join-Path -Path (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('azl-arm-' + [string]$values['cluster.name'])) -ChildPath 'arm-deployment-events.jsonl'
    if ($accounts.Count -gt 0) { $config['logAccounts'] = $accounts }
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
    if ((Get-Item -LiteralPath $full).Length -gt $script:AzlSonarYamlMaxBytes) { throw "Infrastructure file ($full) is not valid YAML: YAML input is larger than the 2 MB limit." }
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
            $before = $state.LastWrite
            $notice = Invoke-AzlSonarInfrastructureCheck -Path $Path -State $state
            if ($Shared.Contains('ConfigInfo')) {
                # For the page's Details: when the file was last checked and re-read, and what the last change was.
                $now = Format-AzlSonarDate ([datetime]::UtcNow)
                $Shared['ConfigInfo']['CheckedAt'] = $now
                if ($state.LastWrite -ne $before) {
                    $Shared['ConfigInfo']['ReadAt'] = $now
                    $Shared['ConfigInfo']['ChangedAt'] = $now
                    $Shared['ConfigInfo']['Note'] = $(if ($notice) { ($notice -replace '^\[sonar\]\s*', '') } else { 'the file changed; the node set is the same' })
                }
            }
            if ($notice) { Add-AzlSonarLogLine -Shared $Shared -Line @(@{ file = 'sonar'; text = $notice }) }
        }
        catch { Write-Verbose "Infrastructure file check failed: $($_.Exception.Message)" }
    }
}
