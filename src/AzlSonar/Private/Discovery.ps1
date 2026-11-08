Set-StrictMode -Version Latest

# Hardware discovery (the first stage of the flow, before ZTP): the toolkit's Invoke-HardwareDiscovery.ps1 reads every node's
# Dell iDRAC (Redfish, read-only) and writes, in its -OutputPath folder:
#   <ServiceTag>.json          one file per node: NodeName, CollectedAt, Identity{ServiceTag,SerialNumber,Model,BiosVersion},
#                              Bmc{MacAddress}, NetworkPorts[{Name,Slot,MacAddress,LinkUp,LinkSpeedMbps,AdapterModel}],
#                              Boss{Present,DriveCount,HasVirtualDisk,NeedsVirtualDisk}, Warnings[]
#   discovery-summary.json     one object per node, written after the last node: NodeName, ServiceTag, Model, BmcMac,
#                              Ports[{Name,Mac,LinkUp}], ManagementPort, ManagementMac, ManagementPortConfirmed,
#                              ManagementPortReason, Boss{Present,DriveCount,HasVirtualDisk,NeedsVirtualDisk}, Warnings (count)
# Sonar reads those files (local, read-only) from discoveryPath: a folder, or one of the files. It never talks to an iDRAC.
# The files are parsed again only when they change (the cache holds the fields Sonar uses, by path, size and write time).
# Unknown fields are ignored and missing ones are empty, so a newer toolkit does not break the reader.

$script:AzlSonarDiscoverySummaryName = 'discovery-summary.json'

function Get-AzlSonarDiscoveryValue {
    # A value from nested hashtables by dotted path; $Default when any part is missing. Key case is ignored.
    [CmdletBinding()]
    param([object]$Object, [string]$Path, [object]$Default = $null)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($current -isnot [System.Collections.IDictionary]) { return $Default }
        $hit = $null
        foreach ($k in $current.Keys) { if ([string]$k -ieq $part) { $hit = $k; break } }
        if ($null -eq $hit) { return $Default }
        $current = $current[$hit]
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function ConvertTo-AzlSonarDiscoveryMac {
    # 00-00-5E-00-53-01 style as the toolkit wrote it, or '' when the text is not a MAC.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    $text = if ($null -ne $Value) { ([string]$Value).Trim() } else { '' }
    if ($text -match '^[0-9A-Fa-f]{2}([:\-.]?[0-9A-Fa-f]{2}){5}$' -or $text -match '^[0-9A-Fa-f]{12}$') { return $text.ToUpperInvariant() }
    return ''
}

function ConvertFrom-AzlSonarDiscoveryNodeFile {
    <#
    .SYNOPSIS
        The fields Sonar uses from one <ServiceTag>.json (as a parsed hashtable), as a record. Pure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Json)

    $ports = @(foreach ($p in @(Get-AzlSonarDiscoveryValue $Json 'NetworkPorts' @())) {
            if ($p -isnot [System.Collections.IDictionary]) { continue }
            $speed = Get-AzlSonarDiscoveryValue $p 'LinkSpeedMbps'
            @{
                name = [string](Get-AzlSonarDiscoveryValue $p 'Name' ''); slot = [string](Get-AzlSonarDiscoveryValue $p 'Slot' '')
                mac = ConvertTo-AzlSonarDiscoveryMac (Get-AzlSonarDiscoveryValue $p 'MacAddress')
                linkUp = [bool](Get-AzlSonarDiscoveryValue $p 'LinkUp' $false)
                speedMbps = $(if ($null -ne $speed -and "$speed" -match '^\d+$') { [long]$speed } else { $null })
                adapterModel = [string](Get-AzlSonarDiscoveryValue $p 'AdapterModel' '')
            }
        })
    $warnings = @(foreach ($w in @(Get-AzlSonarDiscoveryValue $Json 'Warnings' @())) { if ($null -ne $w -and "$w".Trim()) { [string]$w } })
    return @{
        name = [string](Get-AzlSonarDiscoveryValue $Json 'NodeName' '')
        serviceTag = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.ServiceTag' '')
        serial = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.SerialNumber' '')
        model = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.Model' '')
        biosVersion = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.BiosVersion' '')
        bmcMac = ConvertTo-AzlSonarDiscoveryMac (Get-AzlSonarDiscoveryValue $Json 'Bmc.MacAddress')
        collectedAt = [string](Get-AzlSonarDiscoveryValue $Json 'CollectedAt' '')
        ports = $ports
        management = $null
        managementReason = ''
        boss = @{
            present = [bool](Get-AzlSonarDiscoveryValue $Json 'Boss.Present' $false); driveCount = [int](Get-AzlSonarDiscoveryValue $Json 'Boss.DriveCount' 0)
            hasVirtualDisk = [bool](Get-AzlSonarDiscoveryValue $Json 'Boss.HasVirtualDisk' $false); needsVirtualDisk = [bool](Get-AzlSonarDiscoveryValue $Json 'Boss.NeedsVirtualDisk' $false)
        }
        warnings = $warnings
        warningCount = $warnings.Count
    }
}

function ConvertFrom-AzlSonarDiscoverySummary {
    <#
    .SYNOPSIS
        The records of discovery-summary.json (an array of objects, or one object), keyed by node name. Pure.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()][object]$Json)

    $list = @(if ($Json -is [System.Collections.IDictionary]) { , $Json } elseif ($null -ne $Json) { $Json })
    return @(foreach ($s in $list) {
            if ($s -isnot [System.Collections.IDictionary]) { continue }
            $ports = @(foreach ($p in @(Get-AzlSonarDiscoveryValue $s 'Ports' @())) {
                    if ($p -is [System.Collections.IDictionary]) { @{ name = [string](Get-AzlSonarDiscoveryValue $p 'Name' ''); slot = ''; mac = ConvertTo-AzlSonarDiscoveryMac (Get-AzlSonarDiscoveryValue $p 'Mac'); linkUp = [bool](Get-AzlSonarDiscoveryValue $p 'LinkUp' $false); speedMbps = $null; adapterModel = '' } }
                })
            $mgmtName = Get-AzlSonarDiscoveryValue $s 'ManagementPort'
            @{
                name = [string](Get-AzlSonarDiscoveryValue $s 'NodeName' '')
                serial = ''; biosVersion = ''; collectedAt = ''; warnings = @()
                serviceTag = [string](Get-AzlSonarDiscoveryValue $s 'ServiceTag' ''); model = [string](Get-AzlSonarDiscoveryValue $s 'Model' '')
                bmcMac = ConvertTo-AzlSonarDiscoveryMac (Get-AzlSonarDiscoveryValue $s 'BmcMac')
                ports = $ports
                management = $(if ($null -ne $mgmtName -and "$mgmtName".Trim()) {
                        @{ name = [string]$mgmtName; mac = ConvertTo-AzlSonarDiscoveryMac (Get-AzlSonarDiscoveryValue $s 'ManagementMac'); confirmed = [bool](Get-AzlSonarDiscoveryValue $s 'ManagementPortConfirmed' $false); reason = [string](Get-AzlSonarDiscoveryValue $s 'ManagementPortReason' '') }
                    } else { $null })
                managementReason = [string](Get-AzlSonarDiscoveryValue $s 'ManagementPortReason' '')
                boss = @{
                    present = [bool](Get-AzlSonarDiscoveryValue $s 'Boss.Present' $false); driveCount = [int](Get-AzlSonarDiscoveryValue $s 'Boss.DriveCount' 0)
                    hasVirtualDisk = [bool](Get-AzlSonarDiscoveryValue $s 'Boss.HasVirtualDisk' $false); needsVirtualDisk = [bool](Get-AzlSonarDiscoveryValue $s 'Boss.NeedsVirtualDisk' $false)
                }
                warningCount = $(if ((Get-AzlSonarDiscoveryValue $s 'Warnings' 0) -is [System.Collections.IEnumerable] -and (Get-AzlSonarDiscoveryValue $s 'Warnings' 0) -isnot [string]) { @(Get-AzlSonarDiscoveryValue $s 'Warnings').Count } else { [int](Get-AzlSonarDiscoveryValue $s 'Warnings' 0) })
            }
        })
}

function Read-AzlSonarDiscoveryFile {
    <#
    .SYNOPSIS
        Reads one discovery file through the cache. Returns { Kind (summary|node|error), Records, Error }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [AllowNull()]
        [System.Collections.IDictionary]$Cache
    )

    $stamp = "$($File.Length):$($File.LastWriteTimeUtc.Ticks)"
    if ($null -ne $Cache -and $Cache.Contains($File.FullName) -and $Cache[$File.FullName].Stamp -eq $stamp) { return $Cache[$File.FullName].Result }
    $result = $null
    try {
        $text = [System.IO.File]::ReadAllText($File.FullName)
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'the file is empty' }
        $json = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 64
        if ($File.Name -ieq $script:AzlSonarDiscoverySummaryName) {
            $result = @{ Kind = 'summary'; Records = @(ConvertFrom-AzlSonarDiscoverySummary -Json $json); Error = '' }
        }
        elseif ($json -is [System.Collections.IDictionary] -and (Get-AzlSonarDiscoveryValue $json 'Identity') -is [System.Collections.IDictionary]) {
            $result = @{ Kind = 'node'; Records = @(ConvertFrom-AzlSonarDiscoveryNodeFile -Json $json); Error = '' }
        }
        else { throw 'it is not a discovery file (no Identity section)' }
    }
    catch {
        $result = @{ Kind = 'error'; Records = @(); Error = $_.Exception.Message }
    }
    if ($null -ne $Cache) { $Cache[$File.FullName] = @{ Stamp = $stamp; Result = $result } }
    return $result
}

function Merge-AzlSonarDiscoveryRecord {
    # A node file record with the summary record of the same node: the file has the ports and the warnings, the summary the management port.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Node, [hashtable]$Summary)
    if ($null -eq $Node) { return $Summary }
    if ($null -eq $Summary) { return $Node }
    $m = @{}
    foreach ($k in $Node.Keys) { $m[$k] = $Node[$k] }
    foreach ($k in 'serviceTag', 'model', 'bmcMac') { if (-not $m[$k] -and $Summary[$k]) { $m[$k] = $Summary[$k] } }
    if (@($m.ports).Count -eq 0) { $m.ports = $Summary.ports }
    $m.management = $Summary.management
    $m.managementReason = $Summary.managementReason
    if ($m.warningCount -eq 0 -and $Summary.warningCount -gt 0) { $m.warningCount = $Summary.warningCount }
    return $m
}

function ConvertTo-AzlSonarDiscoveryNode {
    <#
    .SYNOPSIS
        One machine of the Discovery mode: state, the notes to check, the ports and the step tree. Pure.
    .DESCRIPTION
        state: discovered (everything read, nothing to check), attention (read, with something to check: BOSS card without a
        virtual disk, no management port suggested, a guessed one, iDRAC warnings), missing (no record), unreadable (the
        file could not be read). The tree has the identity, the network ports (one child per port), the management port and
        the BOSS card, each with a status the page shows like any other step.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [hashtable]$Record,

        [string]$Problem = '',

        [bool]$MissingIsFailure = $false
    )

    $leaf = {
        param($id, $title, $status, $text, $children = @())
        [ordered]@{ id = "disc.$id"; name = $title; description = (Protect-AzlSonarText -Text $text); status = $status; rawStatus = $status; start = $null; end = $null; durationSeconds = $null; errors = @(); children = @($children) }
    }
    if ($Problem) {
        return [ordered]@{
            name = $Name; found = $false; state = 'unreadable'; status = 'error'; stateText = 'The discovery file could not be read'; serviceTag = ''; serial = ''; model = ''; biosVersion = ''; bmcMac = ''; collectedAt = ''
            management = $null; ports = @(); boss = [ordered]@{ present = $false; driveCount = 0; hasVirtualDisk = $false; needsVirtualDisk = $false }; warnings = 0; warningTexts = @(); notes = @(); errors = @(Protect-AzlSonarText -Text $Problem)
            tree = @()
        }
    }
    if ($null -eq $Record) {
        $text = if ($MissingIsFailure) { 'No discovery record: the discovery run reported this machine as failed or did not reach it' } else { 'Not discovered yet' }
        return [ordered]@{
            name = $Name; found = $false; state = 'missing'; status = $(if ($MissingIsFailure) { 'error' } else { 'notstarted' }); stateText = $text; serviceTag = ''; serial = ''; model = ''; biosVersion = ''; bmcMac = ''; collectedAt = ''
            management = $null; ports = @(); boss = [ordered]@{ present = $false; driveCount = 0; hasVirtualDisk = $false; needsVirtualDisk = $false }; warnings = 0; warningTexts = @(); notes = @(); errors = $(if ($MissingIsFailure) { @($text) } else { @() })
            tree = @()
        }
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    $mgmt = $Record.management
    if ($null -eq $mgmt) { $notes.Add('No management port was suggested: choose it from the switch cabling and pass -ManagementPort to the discovery.') }
    elseif (-not $mgmt.confirmed) { $notes.Add("The management port '$($mgmt.name)' is a guess ($($mgmt.reason)): confirm it before ZTP.") }
    $boss = $Record.boss
    if ($boss.present -and $boss.needsVirtualDisk) { $notes.Add('The BOSS card has no virtual disk yet: the toolkit''s Phase 02 Task 01 creates it before the OS install.') }
    elseif (-not $boss.present) { $notes.Add('No BOSS card was found.') }
    if ($Record.warningCount -gt 0) { $notes.Add("The iDRAC read reported $($Record.warningCount) warning$(if ($Record.warningCount -ne 1) { 's' }).") }
    if (-not $Record.serviceTag) { $notes.Add('The service tag (the serial number ZTP maps vouchers by) is empty.') }

    $ports = @($Record.ports)
    $portItems = foreach ($p in $ports) {
        $isMgmt = $null -ne $mgmt -and $mgmt.mac -and $p.mac -eq $mgmt.mac
        $desc = "$(if ($p.mac) { $p.mac } else { 'no MAC' }), $(if ($p.linkUp) { 'link up' } else { 'no link' })$(if ($null -ne $p.speedMbps) { ", $($p.speedMbps) Mbps" })$(if ($p.adapterModel) { ", $($p.adapterModel)" })$(if ($isMgmt) { '; suggested management port' })"
        & $leaf "port.$($p.name)" $p.name $(if ($p.mac) { 'success' } else { 'error' }) $desc
    }
    $mgmtItem = if ($null -ne $mgmt) { & $leaf 'management' 'Management port' $(if ($mgmt.confirmed) { 'success' } else { 'notstarted' }) "$($mgmt.name), $($mgmt.mac): $($mgmt.reason)" } else { & $leaf 'management' 'Management port' 'notstarted' 'No port suggested' }
    $bossText = if (-not $boss.present) { 'No BOSS card found' } elseif ($boss.hasVirtualDisk) { "$($boss.driveCount) drive$(if ($boss.driveCount -ne 1) { 's' }), a virtual disk exists" } else { "$($boss.driveCount) drive$(if ($boss.driveCount -ne 1) { 's' }), no virtual disk yet" }
    $bossItem = & $leaf 'boss' 'BOSS card' $(if ($boss.present -and $boss.hasVirtualDisk) { 'success' } else { 'notstarted' }) $bossText
    $identityText = "Service tag $(if ($Record.serviceTag) { $Record.serviceTag } else { '(none)' }), $(if ($Record.model) { $Record.model } else { 'model unknown' })$(if ($Record.biosVersion) { ", BIOS $($Record.biosVersion)" })$(if ($Record.bmcMac) { ", iDRAC MAC $($Record.bmcMac)" })"
    $tree = @(
        (& $leaf 'identity' 'Identity' $(if ($Record.serviceTag) { 'success' } else { 'error' }) $identityText)
        (& $leaf 'ports' "Network ports ($($ports.Count))" $(if ($ports.Count) { 'success' } else { 'error' }) "$(@($ports | Where-Object { $_.linkUp }).Count) of $($ports.Count) with link up" @($portItems))
        $mgmtItem
        $bossItem
    )
    $state = if ($notes.Count) { 'attention' } else { 'discovered' }
    return [ordered]@{
        name = $Name; found = $true; state = $state; status = 'success'
        stateText = $(if ($notes.Count) { "Discovered; $($notes.Count) thing$(if ($notes.Count -ne 1) { 's' }) to check" } else { 'Discovered' })
        serviceTag = $Record.serviceTag; serial = $Record.serial; model = $Record.model; biosVersion = $Record.biosVersion; bmcMac = $Record.bmcMac; collectedAt = $Record.collectedAt
        management = $(if ($null -ne $mgmt) { [ordered]@{ name = $mgmt.name; mac = $mgmt.mac; confirmed = [bool]$mgmt.confirmed; reason = (Protect-AzlSonarText -Text $mgmt.reason) } } else { $null })
        ports = @($ports | ForEach-Object { [ordered]@{ name = $_.name; slot = $_.slot; mac = $_.mac; linkUp = [bool]$_.linkUp; speedMbps = $_.speedMbps; adapterModel = $_.adapterModel } })
        boss = [ordered]@{ present = [bool]$boss.present; driveCount = [int]$boss.driveCount; hasVirtualDisk = [bool]$boss.hasVirtualDisk; needsVirtualDisk = [bool]$boss.needsVirtualDisk }
        warnings = [int]$Record.warningCount
        warningTexts = @($Record.warnings | ForEach-Object { Protect-AzlSonarText -Text ([string]$_) } | Select-Object -First 5)
        notes = $notes.ToArray()
        errors = @()
        tree = $tree
    }
}

function Get-AzlSonarDiscoveryState {
    <#
    .SYNOPSIS
        The discovery object of /api/state: what the toolkit's hardware discovery found on each machine.
    .DESCRIPTION
        { configured, status (notstarted|running|success|error), state (notconfigured, waiting, empty, partial, discovered,
        failed), stateText, location, summaryFound, collectedAt, ready, nodesTotal, nodesDiscovered, nodesFailed, problems[],
        nodes[] }.
        notconfigured: no discoveryPath. waiting: the path is not there yet. empty: it is there with no discovery file.
        partial: some machines are read and the summary (written after the last machine) is not there yet, so the run is
        still going. failed: a file could not be read, or the summary is there and a machine has no record (the run
        reported it as failed). discovered: every machine of the config (or, with no config nodes, every record) has one.
        Reads only; a file is parsed again only when its size or write time changes.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [System.Collections.IDictionary]$Cache
    )

    $path = [string](Get-AzlSonarMember $Config 'discoveryPath' '')
    $configNodes = Get-AzlSonarMember $Config 'nodes' @()
    $expected = @(foreach ($n in $configNodes) { $nm = [string](Get-AzlSonarMember $n 'name' ''); if ($nm) { $nm } })
    $empty = [ordered]@{
        configured = [bool]$path; status = 'notstarted'; state = $(if ($path) { 'waiting' } else { 'notconfigured' })
        stateText = $(if ($path) { 'Waiting for the discovery output' } else { 'Discovery is not configured' })
        location = $(if ($path) { [System.IO.Path]::GetFileName($path.TrimEnd('\', '/')) } else { '' }); summaryFound = $false; collectedAt = $null; ready = $false
        nodesTotal = $expected.Count; nodesDiscovered = 0; nodesFailed = 0; problems = @()
        nodes = @($expected | ForEach-Object { ConvertTo-AzlSonarDiscoveryNode -Name $_ -Record $null })
    }
    if (-not $path) { return $empty }

    $files = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) { $files = @(Get-Item -LiteralPath $path) }
    elseif (Test-Path -LiteralPath $path -PathType Container) { $files = @(Get-ChildItem -LiteralPath $path -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object -Property Name) }
    else { return $empty }

    $summaryFile = @($files | Where-Object { $_.Name -ieq $script:AzlSonarDiscoverySummaryName } | Select-Object -First 1)
    $summaries = @{}
    $nodeRecords = @{}
    $problems = [System.Collections.Generic.List[object]]::new()
    $problemByNode = @{}
    foreach ($f in $files) {
        $r = Read-AzlSonarDiscoveryFile -File $f -Cache $Cache
        if ($r.Kind -eq 'error') {
            $problems.Add([ordered]@{ file = $f.Name; message = (Protect-AzlSonarText -Text $r.Error) })
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $problemByNode[$base] = $r.Error
            continue
        }
        foreach ($rec in @($r.Records)) {
            $key = if ($rec.name) { $rec.name } else { $rec.serviceTag }
            if (-not $key) { continue }
            if ($r.Kind -eq 'summary') { $summaries[$key.ToLowerInvariant()] = $rec } else { $nodeRecords[$key.ToLowerInvariant()] = $rec }
        }
    }
    # Cache entries of files that are gone.
    if ($null -ne $Cache) {
        $present = @($files | ForEach-Object { $_.FullName })
        foreach ($k in @($Cache.Keys)) { if ($k -notin $present -and ([string]$k).StartsWith($path.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { $Cache.Remove($k) } }
    }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $expected) { $names.Add($n) }
    foreach ($k in @(@($summaries.Keys) + @($nodeRecords.Keys) | Sort-Object)) {
        $rec = if ($summaries.ContainsKey($k)) { $summaries[$k] } else { $nodeRecords[$k] }
        $display = if ($rec.name) { $rec.name } else { $rec.serviceTag }
        if (-not @($names | Where-Object { $_ -ieq $display }).Count) { $names.Add($display) }
    }
    $summaryFound = $summaryFile.Count -gt 0 -and -not @($problems | Where-Object { $_.file -ieq $script:AzlSonarDiscoverySummaryName }).Count
    $nodes = @(foreach ($nm in $names) {
            $k = $nm.ToLowerInvariant()
            $rec = Merge-AzlSonarDiscoveryRecord -Node $(if ($nodeRecords.ContainsKey($k)) { $nodeRecords[$k] } else { $null }) -Summary $(if ($summaries.ContainsKey($k)) { $summaries[$k] } else { $null })
            ConvertTo-AzlSonarDiscoveryNode -Name $nm -Record $rec -MissingIsFailure $summaryFound
        })
    $found = @($nodes | Where-Object { $_.found })
    $failed = @($nodes | Where-Object { $_.status -eq 'error' })
    $latest = @($found | Where-Object { $_.collectedAt } | ForEach-Object { ConvertTo-AzlSonarUtcDate $_.collectedAt } | Where-Object { $null -ne $_ } | Sort-Object -Descending | Select-Object -First 1)

    $state = 'discovered'; $status = 'success'; $text = ''
    if ($found.Count -eq 0 -and $problems.Count -eq 0) { $state = 'empty'; $status = 'notstarted'; $text = 'The discovery output is there but has no machine in it yet' }
    elseif ($problems.Count -gt 0) { $state = 'failed'; $status = 'error'; $text = "$($problems.Count) discovery file$(if ($problems.Count -ne 1) { 's' }) could not be read" }
    elseif ($failed.Count -gt 0) { $state = 'failed'; $status = 'error'; $text = "$($failed.Count) machine$(if ($failed.Count -ne 1) { 's' }) not discovered" }
    elseif ($found.Count -lt $names.Count) { $state = 'partial'; $status = 'running'; $text = "$($found.Count) of $($names.Count) machines read; the discovery is still running" }
    else {
        $check = @($found | Where-Object { $_.state -eq 'attention' }).Count
        $text = "All $($found.Count) machine$(if ($found.Count -ne 1) { 's' }) discovered$(if ($check) { "; $check to check before ZTP" })"
    }
    # Unreadable node files show on their node, when the file is named after a machine of the list.
    foreach ($b in $problemByNode.Keys) {
        $idx = -1
        for ($i = 0; $i -lt $nodes.Count; $i++) { if ($nodes[$i].name -ieq $b) { $idx = $i } }
        if ($idx -ge 0 -and -not $nodes[$idx].found) { $nodes[$idx] = ConvertTo-AzlSonarDiscoveryNode -Name $nodes[$idx].name -Record $null -Problem $problemByNode[$b] }
    }
    return [ordered]@{
        configured = $true; status = $status; state = $state; stateText = $text
        location = [System.IO.Path]::GetFileName($path.TrimEnd('\', '/')); summaryFound = [bool]$summaryFound
        collectedAt = $(if ($latest.Count) { Format-AzlSonarDate $latest[0] } else { $null })
        ready = [bool]($state -eq 'discovered')
        nodesTotal = $nodes.Count; nodesDiscovered = $found.Count; nodesFailed = $failed.Count
        problems = $problems.ToArray(); nodes = $nodes
    }
}

function Test-AzlSonarManualInstall {
    <#
    .SYNOPSIS
        Is this run a manual install? True when Sonar read the master file (infrastructure.yml) and its scenario.os_install is not
        simplified (the ISO / manual install). Sonar does not monitor an install done by hand: the Provisioning (ZTP) tile
        reads "Not used: manual install" and the run starts at OS configuration. A Sonar config file keeps its own route.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Route
    )

    return [bool]([string](Get-AzlSonarMember $Config 'sourceKind' '') -eq 'infrastructure' -and $Route -eq 'oem-image')
}
