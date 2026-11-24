Set-StrictMode -Version Latest

# Hardware discovery (the first stage of the flow, before ZTP): the toolkit's Invoke-HardwareDiscovery.ps1 reads every node's
# Dell iDRAC (Redfish, read-only) and writes, in its -OutputPath folder:
#   <ServiceTag>.json          one file per node: NodeName, CollectedAt, Identity{ServiceTag,SerialNumber,Model,BiosVersion},
#                              Bmc{MacAddress}, NetworkPorts[{Name,Slot,MacAddress,LinkUp,LinkSpeedMbps,AdapterModel}],
#                              Boss{Present,DriveCount,HasVirtualDisk,NeedsVirtualDisk}, Warnings[]   (schemaVersion 1.0)
#                              schemaVersion 2.0 keeps identity and warnings, and moves the rest: bmc.mac,
#                              network.adapters[].ports[]{name,slot,mac,linkUp,speedMbps} with the card model on the adapter,
#                              storage.bootDevice{kind (boss or null),driveIds[],hasVirtualDisk,needsVirtualDisk}
#   discovery-summary.json     one object per node, written after the last node: NodeName, ServiceTag, Model, BmcMac,
#                              Ports[{Name,Mac,LinkUp}], ManagementPort, ManagementMac, ManagementPortConfirmed,
#                              ManagementPortReason, Boss{Present,DriveCount,HasVirtualDisk,NeedsVirtualDisk}, Warnings (count)
#   hardware-inventory-*.json  the toolkit's Get-HardwareInventory.ps1 (kind hardware-inventory, schemaVersion 1.x): nodes[]
#                              {name, status, collectedAt, identity{serialNumber, model}, bios{version}, bmc{mac},
#                              network.ports[]{adapter, portNumber, mac, linkStatus, speedMbps, model}, drives[]{controller}}.
#                              Read as a record of each node that no discovery file names yet (and to fill missing fields).
#   validation-*.json          AzL Beacon's results (schemaVersion 1.x, tool.name AzL Beacon): node{hostname, serialNumber},
#                              summary{total, pass, fail, warn, skip, verdict}, results[]. Shown on the machine whose serial
#                              number (or name) it names, also from the beacon subfolder of discoveryPath (owner decision O5:
#                              Beacon's results go to the Discovery view and to the evidence).
# Files of other tools that may sit in the same evidence folder (a Ranger manifest or as-built snapshot, the Environment
# Checker's own report) are listed as skipped, never as unreadable.
# Sonar reads those files (local, read-only) from discoveryPath: a folder, or one of the files. It never talks to an iDRAC.
# The files are parsed again only when they change (the cache holds the fields Sonar uses, by path, size and write time).
# Unknown fields are ignored and missing ones are empty, so a newer toolkit does not break the reader. A run older than
# AzlSonarDiscoveryStaleDays is flagged stale: what the machines report may have changed since.

$script:AzlSonarDiscoverySummaryName = 'discovery-summary.json'
$script:AzlSonarDiscoveryBeaconFolder = 'beacon'
$script:AzlSonarDiscoveryStaleDays = 7
$script:AzlSonarBeaconMaxFailures = 5

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

function ConvertTo-AzlSonarDiscoveryTime {
    # A time read from a discovery file as yyyy-MM-ddTHH:mm:ssZ (ConvertFrom-Json turns ISO strings into DateTime); other text as written.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        $utc = ConvertTo-AzlSonarUtcDate $Value
        return $(if ($null -ne $utc) { Format-AzlSonarDate $utc } else { '' })
    }
    return ([string]$Value).Trim()
}

function ConvertFrom-AzlSonarDiscoveryNodeFile {
    <#
    .SYNOPSIS
        The fields Sonar uses from one <ServiceTag>.json (as a parsed hashtable), as a record. Pure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Json)

    $toPort = {
        param($p, [string]$adapterModel)
        $speed = Get-AzlSonarDiscoveryValue $p 'LinkSpeedMbps'
        if ($null -eq $speed) { $speed = Get-AzlSonarDiscoveryValue $p 'speedMbps' }
        $mac = Get-AzlSonarDiscoveryValue $p 'MacAddress'
        if ($null -eq $mac) { $mac = Get-AzlSonarDiscoveryValue $p 'mac' }
        $model = [string](Get-AzlSonarDiscoveryValue $p 'AdapterModel' '')
        if (-not $model) { $model = $adapterModel }
        @{
            name = [string](Get-AzlSonarDiscoveryValue $p 'Name' ''); slot = [string](Get-AzlSonarDiscoveryValue $p 'Slot' '')
            mac = ConvertTo-AzlSonarDiscoveryMac $mac
            linkUp = [bool](Get-AzlSonarDiscoveryValue $p 'LinkUp' $false)
            speedMbps = $(if ($null -ne $speed -and "$speed" -match '^\d+$') { [long]$speed } else { $null })
            adapterModel = $model
        }
    }
    # Schema 1.0: NetworkPorts[] at the top. Schema 2.0: network.adapters[].ports[] (the card model on the adapter).
    $ports = @(foreach ($p in @(Get-AzlSonarDiscoveryValue $Json 'NetworkPorts' @())) {
            if ($p -is [System.Collections.IDictionary]) { & $toPort $p '' }
        })
    if ($ports.Count -eq 0) {
        $ports = @(foreach ($a in @(Get-AzlSonarDiscoveryValue $Json 'network.adapters' @())) {
                if ($a -isnot [System.Collections.IDictionary]) { continue }
                $adapterModel = [string](Get-AzlSonarDiscoveryValue $a 'model' '')
                foreach ($p in @(Get-AzlSonarDiscoveryValue $a 'ports' @())) { if ($p -is [System.Collections.IDictionary]) { & $toPort $p $adapterModel } }
            })
    }
    # Schema 1.0: Boss{Present,DriveCount,HasVirtualDisk,NeedsVirtualDisk}. Schema 2.0: storage.bootDevice{kind,driveIds,...}.
    $bossBlock = Get-AzlSonarDiscoveryValue $Json 'Boss'
    $bootDevice = Get-AzlSonarDiscoveryValue $Json 'storage.bootDevice'
    $boss = if ($bossBlock -is [System.Collections.IDictionary] -or $bootDevice -isnot [System.Collections.IDictionary]) {
        @{
            present = [bool](Get-AzlSonarDiscoveryValue $Json 'Boss.Present' $false); driveCount = [int](Get-AzlSonarDiscoveryValue $Json 'Boss.DriveCount' 0)
            hasVirtualDisk = [bool](Get-AzlSonarDiscoveryValue $Json 'Boss.HasVirtualDisk' $false); needsVirtualDisk = [bool](Get-AzlSonarDiscoveryValue $Json 'Boss.NeedsVirtualDisk' $false)
        }
    }
    else {
        $isBoss = ([string](Get-AzlSonarDiscoveryValue $bootDevice 'kind' '')) -ieq 'boss'
        @{
            present = $isBoss; driveCount = $(if ($isBoss) { @(Get-AzlSonarDiscoveryValue $bootDevice 'driveIds' @()).Count } else { 0 })
            hasVirtualDisk = ($isBoss -and [bool](Get-AzlSonarDiscoveryValue $bootDevice 'hasVirtualDisk' $false))
            needsVirtualDisk = ($isBoss -and [bool](Get-AzlSonarDiscoveryValue $bootDevice 'needsVirtualDisk' $false))
        }
    }
    $bmcMac = Get-AzlSonarDiscoveryValue $Json 'Bmc.MacAddress'
    if ($null -eq $bmcMac) { $bmcMac = Get-AzlSonarDiscoveryValue $Json 'bmc.mac' }
    $warnings = @(foreach ($w in @(Get-AzlSonarDiscoveryValue $Json 'Warnings' @())) { if ($null -ne $w -and "$w".Trim()) { [string]$w } })
    return @{
        name = [string](Get-AzlSonarDiscoveryValue $Json 'NodeName' '')
        serviceTag = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.ServiceTag' '')
        serial = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.SerialNumber' '')
        model = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.Model' '')
        biosVersion = [string](Get-AzlSonarDiscoveryValue $Json 'Identity.BiosVersion' '')
        bmcMac = ConvertTo-AzlSonarDiscoveryMac $bmcMac
        collectedAt = ConvertTo-AzlSonarDiscoveryTime (Get-AzlSonarDiscoveryValue $Json 'CollectedAt' '')
        ports = $ports
        management = $null
        managementReason = ''
        boss = $boss
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

function ConvertFrom-AzlSonarHardwareInventory {
    <#
    .SYNOPSIS
        The node records of a toolkit hardware inventory file (Get-HardwareInventory.ps1, kind hardware-inventory). Pure.
    .DESCRIPTION
        One record per node the inventory read (status read): the serial number (the service tag on a Dell node), the
        model, the BIOS version, the BMC MAC, the network ports in the BMC's order (adapter and port number, MAC, link,
        speed, card model) and the BOSS card (the drives on a BOSS controller). The inventory names no management port
        and does not say whether the BOSS card has a virtual disk, so those stay unknown.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Json)

    $fileTime = ConvertTo-AzlSonarDiscoveryTime (Get-AzlSonarDiscoveryValue $Json 'collectedAt')
    return @(foreach ($n in @(Get-AzlSonarDiscoveryValue $Json 'nodes' @())) {
            if ($n -isnot [System.Collections.IDictionary]) { continue }
            if (([string](Get-AzlSonarDiscoveryValue $n 'status' 'read')) -ine 'read') { continue }
            $ports = @(foreach ($p in @(Get-AzlSonarDiscoveryValue $n 'network.ports' @())) {
                    if ($p -isnot [System.Collections.IDictionary]) { continue }
                    $adapter = [string](Get-AzlSonarDiscoveryValue $p 'adapter' '')
                    $number = [string](Get-AzlSonarDiscoveryValue $p 'portNumber' '')
                    $speed = Get-AzlSonarDiscoveryValue $p 'speedMbps'
                    @{
                        name = $(if ($adapter -and $number) { "$adapter-$number" } elseif ($adapter) { $adapter } else { "Port $([string](Get-AzlSonarDiscoveryValue $p 'order' ''))" })
                        slot = $adapter
                        mac = ConvertTo-AzlSonarDiscoveryMac (Get-AzlSonarDiscoveryValue $p 'mac')
                        linkUp = (([string](Get-AzlSonarDiscoveryValue $p 'linkStatus' '')) -ieq 'LinkUp')
                        speedMbps = $(if ($null -ne $speed -and "$speed" -match '^\d+$') { [long]$speed } else { $null })
                        adapterModel = [string](Get-AzlSonarDiscoveryValue $p 'model' '')
                    }
                })
            $bossDrives = @(@(Get-AzlSonarDiscoveryValue $n 'drives' @()) | Where-Object { $_ -is [System.Collections.IDictionary] -and ([string](Get-AzlSonarDiscoveryValue $_ 'controller' '')) -match '(?i)^BOSS' })
            $warnings = @(foreach ($w in @(Get-AzlSonarDiscoveryValue $n 'warnings' @())) { if ($null -ne $w -and "$w".Trim()) { [string]$w } })
            $serial = [string](Get-AzlSonarDiscoveryValue $n 'identity.serialNumber' '')
            $collected = ConvertTo-AzlSonarDiscoveryTime (Get-AzlSonarDiscoveryValue $n 'collectedAt')
            @{
                name = [string](Get-AzlSonarDiscoveryValue $n 'name' '')
                serviceTag = $serial; serial = $serial
                model = [string](Get-AzlSonarDiscoveryValue $n 'identity.model' '')
                biosVersion = [string](Get-AzlSonarDiscoveryValue $n 'bios.version' '')
                bmcMac = ConvertTo-AzlSonarDiscoveryMac (Get-AzlSonarDiscoveryValue $n 'bmc.mac')
                collectedAt = $(if ($collected) { $collected } else { $fileTime })
                ports = $ports
                management = $null
                managementReason = ''
                # The inventory lists the BOSS drives but not the virtual disk: hasVirtualDisk and needsVirtualDisk stay false.
                boss = @{ present = ($bossDrives.Count -gt 0); driveCount = $bossDrives.Count; hasVirtualDisk = $false; needsVirtualDisk = $false; unknownVirtualDisk = ($bossDrives.Count -gt 0) }
                warnings = $warnings
                warningCount = $warnings.Count
                source = 'hardware-inventory'
            }
        })
}

function ConvertFrom-AzlSonarBeaconResult {
    <#
    .SYNOPSIS
        The fields Sonar shows from one AzL Beacon results file (validation-<stamp>.json, schemaVersion 1.x). Pure.
    .DESCRIPTION
        { hostname, serial, verdict (PASS|FAIL|WARN or as written), total, pass, fail, warn, skip, startedAt, finishedAt,
        version, failures[{name, category, detail, remediation}] (the failed checks, at most AzlSonarBeaconMaxFailures),
        redacted }. Text is masked.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Json)

    $failed = @(@(Get-AzlSonarDiscoveryValue $Json 'results' @()) | Where-Object { $_ -is [System.Collections.IDictionary] -and ([string](Get-AzlSonarDiscoveryValue $_ 'status' '')) -ieq 'Fail' })
    $count = { param($k) $v = Get-AzlSonarDiscoveryValue $Json "summary.$k" 0; if ("$v" -match '^\d+$') { [int]$v } else { 0 } }
    return @{
        hostname = [string](Get-AzlSonarDiscoveryValue $Json 'node.hostname' '')
        serial = [string](Get-AzlSonarDiscoveryValue $Json 'node.serialNumber' '')
        verdict = ([string](Get-AzlSonarDiscoveryValue $Json 'summary.verdict' '')).ToUpperInvariant()
        total = & $count 'total'; pass = & $count 'pass'; fail = & $count 'fail'; warn = & $count 'warn'; skip = & $count 'skip'
        startedAt = ConvertTo-AzlSonarDiscoveryTime (Get-AzlSonarDiscoveryValue $Json 'startedUtc')
        finishedAt = ConvertTo-AzlSonarDiscoveryTime (Get-AzlSonarDiscoveryValue $Json 'finishedUtc')
        version = [string](Get-AzlSonarDiscoveryValue $Json 'tool.version' '')
        redacted = [bool](Get-AzlSonarDiscoveryValue $Json 'redacted' $false)
        failures = @($failed | Select-Object -First $script:AzlSonarBeaconMaxFailures | ForEach-Object {
                [ordered]@{
                    name = (Protect-AzlSonarText -Text ([string](Get-AzlSonarDiscoveryValue $_ 'name' '')))
                    category = [string](Get-AzlSonarDiscoveryValue $_ 'category' '')
                    detail = (Protect-AzlSonarText -Text ([string](Get-AzlSonarDiscoveryValue $_ 'detail' '')))
                    remediation = (Protect-AzlSonarText -Text ([string](Get-AzlSonarDiscoveryValue $_ 'remediation' '')))
                }
            })
    }
}

function Get-AzlSonarDiscoveryFileKind {
    <#
    .SYNOPSIS
        What a parsed JSON file in the discovery folder is: summary, node, inventory, beacon, or skip (a known file of another
        tool, with the reason), or '' (not a known kind: an error). Pure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][object]$Json, [Parameter(Mandatory)][string]$Name)

    if ($Name -ieq $script:AzlSonarDiscoverySummaryName) { return @{ Kind = 'summary'; Reason = '' } }
    if ($Name -ieq 'AzStackHciEnvironmentReport.json') { return @{ Kind = 'skip'; Reason = 'the Environment Checker report Beacon keeps next to its results' } }
    if ($Json -isnot [System.Collections.IDictionary]) { return @{ Kind = ''; Reason = '' } }
    if ((Get-AzlSonarDiscoveryValue $Json 'Identity') -is [System.Collections.IDictionary]) { return @{ Kind = 'node'; Reason = '' } }
    $kind = [string](Get-AzlSonarDiscoveryValue $Json 'kind' '')
    if ($kind -ieq 'hardware-inventory') { return @{ Kind = 'inventory'; Reason = '' } }
    if (([string](Get-AzlSonarDiscoveryValue $Json 'tool.name' '')) -match '(?i)beacon' -and (Get-AzlSonarDiscoveryValue $Json 'summary') -is [System.Collections.IDictionary]) {
        # The redacted copy Beacon writes for sharing names no machine (<host>, <serial>): the full copy next to it is read.
        if ([bool](Get-AzlSonarDiscoveryValue $Json 'redacted' $false)) { return @{ Kind = 'skip'; Reason = 'the redacted copy of Beacon results (for sharing; it names no machine)' } }
        return @{ Kind = 'beacon'; Reason = '' }
    }
    $schema = [string](Get-AzlSonarDiscoveryValue $Json 'schema' '')
    if ($schema -like 'as-built-snapshot*') { return @{ Kind = 'skip'; Reason = 'a Ranger as-built snapshot (day 2, compare only)' } }
    if ((Get-AzlSonarDiscoveryValue $Json 'run.toolVersion') -and (Get-AzlSonarDiscoveryValue $Json 'collectors') -is [System.Collections.IDictionary]) { return @{ Kind = 'skip'; Reason = 'a Ranger manifest (day 2, compare only)' } }
    return @{ Kind = ''; Reason = '' }
}

function Read-AzlSonarDiscoveryFile {
    <#
    .SYNOPSIS
        Reads one discovery file through the cache. Returns { Kind (summary|node|inventory|beacon|skip|error), Records, Beacon, Reason, Error }.
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
        $what = Get-AzlSonarDiscoveryFileKind -Json $json -Name $File.Name
        $result = switch ($what.Kind) {
            'summary' { @{ Kind = 'summary'; Records = @(ConvertFrom-AzlSonarDiscoverySummary -Json $json); Beacon = $null; Reason = ''; Error = '' } }
            'node' { @{ Kind = 'node'; Records = @(ConvertFrom-AzlSonarDiscoveryNodeFile -Json $json); Beacon = $null; Reason = ''; Error = '' } }
            'inventory' { @{ Kind = 'inventory'; Records = @(ConvertFrom-AzlSonarHardwareInventory -Json $json); Beacon = $null; Reason = ''; Error = '' } }
            'beacon' { @{ Kind = 'beacon'; Records = @(); Beacon = (ConvertFrom-AzlSonarBeaconResult -Json $json); Reason = ''; Error = '' } }
            'skip' { @{ Kind = 'skip'; Records = @(); Beacon = $null; Reason = $what.Reason; Error = '' } }
            default { throw 'it is not a discovery file (no Identity section, and not a hardware inventory or Beacon results file)' }
        }
    }
    catch {
        $result = @{ Kind = 'error'; Records = @(); Beacon = $null; Reason = ''; Error = $_.Exception.Message }
    }
    if ($null -ne $Cache) { $Cache[$File.FullName] = @{ Stamp = $stamp; Result = $result } }
    return $result
}

function Merge-AzlSonarDiscoveryRecord {
    # A node file record with the summary record of the same node: the file has the ports and the warnings, the summary the management port.
    [CmdletBinding()]
    [OutputType([hashtable])]
    # A hardware inventory record (Get-HardwareInventory.ps1) is the last source: it stands in for a node no discovery file
    # names, and otherwise only fills fields the discovery files left empty.
    param([hashtable]$Node, [hashtable]$Summary, [hashtable]$Inventory)
    $m = $null
    if ($null -eq $Node) { $m = $Summary }
    elseif ($null -eq $Summary) { $m = $Node }
    else {
        $m = @{}
        foreach ($k in $Node.Keys) { $m[$k] = $Node[$k] }
        foreach ($k in 'serviceTag', 'model', 'bmcMac') { if (-not $m[$k] -and $Summary[$k]) { $m[$k] = $Summary[$k] } }
        if (@($m.ports).Count -eq 0) { $m.ports = $Summary.ports }
        $m.management = $Summary.management
        $m.managementReason = $Summary.managementReason
        if ($m.warningCount -eq 0 -and $Summary.warningCount -gt 0) { $m.warningCount = $Summary.warningCount }
    }
    if ($null -eq $Inventory) { return $m }
    if ($null -eq $m) { return $Inventory }
    $filled = @{}
    foreach ($k in $m.Keys) { $filled[$k] = $m[$k] }
    foreach ($k in 'serviceTag', 'serial', 'model', 'biosVersion', 'bmcMac', 'collectedAt') { if ($filled.ContainsKey($k) -and -not $filled[$k] -and $Inventory[$k]) { $filled[$k] = $Inventory[$k] } }
    if (@($filled.ports).Count -eq 0) { $filled.ports = $Inventory.ports }
    return $filled
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

        [bool]$MissingIsFailure = $false,

        # The newest AzL Beacon result of this machine (ConvertFrom-AzlSonarBeaconResult), or $null.
        [AllowNull()]
        [System.Collections.IDictionary]$Beacon
    )

    $beaconOut = $null
    if ($null -ne $Beacon) {
        $beaconOut = [ordered]@{
            verdict = [string]$Beacon['verdict']; total = [int]$Beacon['total']; pass = [int]$Beacon['pass']; fail = [int]$Beacon['fail']; warn = [int]$Beacon['warn']; skip = [int]$Beacon['skip']
            finishedAt = [string]$Beacon['finishedAt']; version = [string]$Beacon['version']; file = [string]$(if ($Beacon.Contains('file')) { $Beacon['file'] } else { '' }); failures = @($Beacon['failures'])
        }
    }
    $leaf = {
        param($id, $title, $status, $text, $children = @())
        [ordered]@{ id = "disc.$id"; name = $title; description = (Protect-AzlSonarText -Text $text); status = $status; rawStatus = $status; start = $null; end = $null; durationSeconds = $null; errors = @(); children = @($children) }
    }
    if ($Problem) {
        return [ordered]@{
            name = $Name; found = $false; state = 'unreadable'; status = 'error'; stateText = 'The discovery file could not be read'; serviceTag = ''; serial = ''; model = ''; biosVersion = ''; bmcMac = ''; collectedAt = ''
            management = $null; ports = @(); boss = [ordered]@{ present = $false; driveCount = 0; hasVirtualDisk = $false; needsVirtualDisk = $false }; warnings = 0; warningTexts = @(); notes = @(); errors = @(Protect-AzlSonarText -Text $Problem); beacon = $beaconOut
            tree = @()
        }
    }
    if ($null -eq $Record) {
        $text = if ($MissingIsFailure) { 'No discovery record: the discovery run reported this machine as failed or did not reach it' } else { 'Not discovered yet' }
        return [ordered]@{
            name = $Name; found = $false; state = 'missing'; status = $(if ($MissingIsFailure) { 'error' } else { 'notstarted' }); stateText = $text; serviceTag = ''; serial = ''; model = ''; biosVersion = ''; bmcMac = ''; collectedAt = ''
            management = $null; ports = @(); boss = [ordered]@{ present = $false; driveCount = 0; hasVirtualDisk = $false; needsVirtualDisk = $false }; warnings = 0; warningTexts = @(); notes = @(); errors = $(if ($MissingIsFailure) { @($text) } else { @() }); beacon = $beaconOut
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
    if ($null -ne $beaconOut -and $beaconOut.verdict -eq 'FAIL') { $notes.Add("Beacon found $($beaconOut.fail) failed check$(if ($beaconOut.fail -ne 1) { 's' }) on this machine: fix them before ZTP.") }

    $ports = @($Record.ports)
    $portItems = foreach ($p in $ports) {
        $isMgmt = $null -ne $mgmt -and $mgmt.mac -and $p.mac -eq $mgmt.mac
        $desc = "$(if ($p.mac) { $p.mac } else { 'no MAC' }), $(if ($p.linkUp) { 'link up' } else { 'no link' })$(if ($null -ne $p.speedMbps) { ", $($p.speedMbps) Mbps" })$(if ($p.adapterModel) { ", $($p.adapterModel)" })$(if ($isMgmt) { '; suggested management port' })"
        & $leaf "port.$($p.name)" $p.name $(if ($p.mac) { 'success' } else { 'error' }) $desc
    }
    $mgmtItem = if ($null -ne $mgmt) { & $leaf 'management' 'Management port' $(if ($mgmt.confirmed) { 'success' } else { 'notstarted' }) "$($mgmt.name), $($mgmt.mac): $($mgmt.reason)" } else { & $leaf 'management' 'Management port' 'notstarted' 'No port suggested' }
    $bossUnknown = $boss.ContainsKey('unknownVirtualDisk') -and [bool]$boss['unknownVirtualDisk']
    $bossText = if (-not $boss.present) { 'No BOSS card found' } elseif ($bossUnknown) { "$($boss.driveCount) drive$(if ($boss.driveCount -ne 1) { 's' }) (the hardware inventory does not say whether a virtual disk exists)" } elseif ($boss.hasVirtualDisk) { "$($boss.driveCount) drive$(if ($boss.driveCount -ne 1) { 's' }), a virtual disk exists" } else { "$($boss.driveCount) drive$(if ($boss.driveCount -ne 1) { 's' }), no virtual disk yet" }
    $bossItem = & $leaf 'boss' 'BOSS card' $(if ($boss.present -and $boss.hasVirtualDisk) { 'success' } else { 'notstarted' }) $bossText
    $identityText = "Service tag $(if ($Record.serviceTag) { $Record.serviceTag } else { '(none)' }), $(if ($Record.model) { $Record.model } else { 'model unknown' })$(if ($Record.biosVersion) { ", BIOS $($Record.biosVersion)" })$(if ($Record.bmcMac) { ", iDRAC MAC $($Record.bmcMac)" })"
    $tree = @(
        (& $leaf 'identity' 'Identity' $(if ($Record.serviceTag) { 'success' } else { 'error' }) $identityText)
        (& $leaf 'ports' "Network ports ($($ports.Count))" $(if ($ports.Count) { 'success' } else { 'error' }) "$(@($ports | Where-Object { $_.linkUp }).Count) of $($ports.Count) with link up" @($portItems))
        $mgmtItem
        $bossItem
    )
    if ($null -ne $beaconOut) {
        $beaconStatus = switch ($beaconOut.verdict) { 'PASS' { 'success' } 'FAIL' { 'error' } default { 'notstarted' } }
        $beaconText = "Verdict $($beaconOut.verdict): $($beaconOut.pass) passed, $($beaconOut.fail) failed, $($beaconOut.warn) warnings, $($beaconOut.skip) skipped$(if ($beaconOut.finishedAt) { ", finished $($beaconOut.finishedAt)" })"
        $beaconChildren = @(foreach ($f in @($beaconOut.failures)) { & $leaf "beacon.$($f.name)" $f.name 'error' $(if ($f.remediation) { "$($f.detail). Fix: $($f.remediation)" } else { $f.detail }) })
        $tree += & $leaf 'beacon' 'Beacon (pre-deployment checks)' $beaconStatus $beaconText $beaconChildren
    }
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
        beacon = $beaconOut
        tree = $tree
    }
}

function Get-AzlSonarDiscoveryState {
    <#
    .SYNOPSIS
        The discovery object of /api/state: what the toolkit's hardware discovery found on each machine.
    .DESCRIPTION
        { configured, status (notstarted|running|success|error), state (notconfigured, waiting, empty, partial, discovered,
        failed), stateText, location, summaryFound, collectedAt, ageSeconds, stale, staleDays, ready, nodesTotal,
        nodesDiscovered, nodesFailed, problems[], skipped[{file, reason}], beacon[{file, node, hostname, serial, verdict,
        total, pass, fail, warn, skip, finishedAt}], warnings[], nodes[] }.
        notconfigured: no discoveryPath. waiting: the path is not there yet. empty: it is there with no discovery file.
        partial: some machines are read and the summary (written after the last machine) is not there yet, so the run is
        still going. failed: a file could not be read, or the summary is there and a machine has no record (the run
        reported it as failed). discovered: every machine of the config (or, with no config nodes, every record) has one.
        A hardware inventory file stands in for a machine no discovery file names. Beacon results (in the folder or its
        beacon subfolder) are shown on the machine with the same serial number or name; the newest per machine wins.
        Files of other tools (a Ranger manifest or snapshot, the Environment Checker report) are skipped, not failed.
        stale: the newest collectedAt is older than AzlSonarDiscoveryStaleDays days (a warning; the state stays as read).
        Reads only; a file is parsed again only when its size or write time changes.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [System.Collections.IDictionary]$Cache,

        [datetime]$Now = [datetime]::UtcNow
    )

    $path = [string](Get-AzlSonarMember $Config 'discoveryPath' '')
    $configNodes = Get-AzlSonarMember $Config 'nodes' @()
    $expected = @(foreach ($n in $configNodes) { $nm = [string](Get-AzlSonarMember $n 'name' ''); if ($nm) { $nm } })
    $empty = [ordered]@{
        configured = [bool]$path; status = 'notstarted'; state = $(if ($path) { 'waiting' } else { 'notconfigured' })
        stateText = $(if ($path) { 'Waiting for the discovery output' } else { 'Discovery is not configured' })
        location = $(if ($path) { [System.IO.Path]::GetFileName($path.TrimEnd('\', '/')) } else { '' }); summaryFound = $false; collectedAt = $null
        ageSeconds = $null; stale = $false; staleDays = $script:AzlSonarDiscoveryStaleDays; ready = $false
        nodesTotal = $expected.Count; nodesDiscovered = 0; nodesFailed = 0; problems = @(); skipped = @(); beacon = @(); warnings = @()
        nodes = @($expected | ForEach-Object { ConvertTo-AzlSonarDiscoveryNode -Name $_ -Record $null })
    }
    if (-not $path) { return $empty }

    $files = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) { $files = @(Get-Item -LiteralPath $path) }
    elseif (Test-Path -LiteralPath $path -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $path -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object -Property Name)
        # Beacon's results may be kept in a beacon subfolder of the discovery folder (O5: Discovery view and evidence).
        $beaconFolder = Join-Path -Path $path -ChildPath $script:AzlSonarDiscoveryBeaconFolder
        if (Test-Path -LiteralPath $beaconFolder -PathType Container) {
            $files += @(Get-ChildItem -LiteralPath $beaconFolder -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object -Property Name)
        }
    }
    else { return $empty }

    $root = (Get-Item -LiteralPath $path).FullName
    $relative = { param($f) $full = $f.FullName; if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and $full.Length -gt $root.Length) { $full.Substring($root.Length).TrimStart('\', '/') } else { $f.Name } }
    $summaryFile = @($files | Where-Object { $_.Name -ieq $script:AzlSonarDiscoverySummaryName } | Select-Object -First 1)
    $summaries = @{}
    $nodeRecords = @{}
    $inventory = @{}
    $beacons = [System.Collections.Generic.List[hashtable]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[object]]::new()
    $problemByNode = @{}
    foreach ($f in $files) {
        $r = Read-AzlSonarDiscoveryFile -File $f -Cache $Cache
        $shown = & $relative $f
        if ($r.Kind -eq 'error') {
            $problems.Add([ordered]@{ file = $shown; message = (Protect-AzlSonarText -Text $r.Error) })
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $problemByNode[$base] = $r.Error
            continue
        }
        if ($r.Kind -eq 'skip') { $skipped.Add([ordered]@{ file = $shown; reason = $r.Reason }); continue }
        if ($r.Kind -eq 'beacon') {
            $b = @{}
            foreach ($k in $r.Beacon.Keys) { $b[$k] = $r.Beacon[$k] }
            $b['file'] = $shown
            $beacons.Add($b)
            continue
        }
        foreach ($rec in @($r.Records)) {
            $key = if ($rec.name) { $rec.name } else { $rec.serviceTag }
            if (-not $key) { continue }
            switch ($r.Kind) {
                'summary' { $summaries[$key.ToLowerInvariant()] = $rec }
                'inventory' {
                    # The newest inventory of a machine wins (files are read in name order; the name carries the time).
                    $inventory[$key.ToLowerInvariant()] = $rec
                }
                default { $nodeRecords[$key.ToLowerInvariant()] = $rec }
            }
        }
    }
    # Cache entries of files that are gone.
    if ($null -ne $Cache) {
        $present = @($files | ForEach-Object { $_.FullName })
        foreach ($k in @($Cache.Keys)) { if ($k -notin $present -and ([string]$k).StartsWith($path.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { $Cache.Remove($k) } }
    }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $expected) { $names.Add($n) }
    foreach ($k in @(@($summaries.Keys) + @($nodeRecords.Keys) + @($inventory.Keys) | Sort-Object -Unique)) {
        $rec = if ($summaries.ContainsKey($k)) { $summaries[$k] } elseif ($nodeRecords.ContainsKey($k)) { $nodeRecords[$k] } else { $inventory[$k] }
        $display = if ($rec.name) { $rec.name } else { $rec.serviceTag }
        if (-not @($names | Where-Object { $_ -ieq $display }).Count) { $names.Add($display) }
    }
    $summaryFound = $summaryFile.Count -gt 0 -and -not @($problems | Where-Object { $_.file -ieq $script:AzlSonarDiscoverySummaryName }).Count

    # The newest Beacon result per machine: by serial number (the service tag), else by the host name.
    $beaconFor = {
        param([string]$Name, [hashtable]$Record)
        $ids = @(@($(if ($null -ne $Record) { $Record['serviceTag']; $Record['serial'] })) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $hit = @($beacons | Where-Object { ($_['serial'] -and $ids -contains ([string]$_['serial']).ToLowerInvariant()) -or ($_['hostname'] -and ([string]$_['hostname']) -ieq $Name) })
        if ($hit.Count -eq 0) { return $null }
        return ($hit | Sort-Object -Property @{ Expression = { $t = ConvertTo-AzlSonarUtcDate $_['finishedAt']; if ($null -ne $t) { $t } else { [datetime]::MinValue } } } -Descending | Select-Object -First 1)
    }
    $beaconNode = @{}
    $nodes = @(foreach ($nm in $names) {
            $k = $nm.ToLowerInvariant()
            $rec = Merge-AzlSonarDiscoveryRecord -Node $(if ($nodeRecords.ContainsKey($k)) { $nodeRecords[$k] } else { $null }) -Summary $(if ($summaries.ContainsKey($k)) { $summaries[$k] } else { $null }) -Inventory $(if ($inventory.ContainsKey($k)) { $inventory[$k] } else { $null })
            $b = & $beaconFor $nm $rec
            if ($null -ne $b) { $beaconNode[[string]$b['file']] = $nm }
            ConvertTo-AzlSonarDiscoveryNode -Name $nm -Record $rec -MissingIsFailure $summaryFound -Beacon $b
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

    # How old the newest read is: a run older than the limit may no longer match the machines.
    $warnings = [System.Collections.Generic.List[string]]::new()
    $age = $null; $stale = $false
    if ($latest.Count) {
        $age = [long][math]::Max(0, [math]::Floor(($Now.ToUniversalTime() - $latest[0]).TotalSeconds))
        if ($age -gt $script:AzlSonarDiscoveryStaleDays * 86400) {
            $stale = $true
            $warnings.Add("The discovery was collected $([math]::Floor($age / 86400)) days ago ($(Format-AzlSonarDate $latest[0])), more than $($script:AzlSonarDiscoveryStaleDays) days: run the hardware discovery again before ZTP, or check that discoveryPath (hardware.discovery.output_directory) names the latest run.")
        }
    }
    foreach ($b in $beacons) { if (-not $beaconNode.ContainsKey([string]$b['file'])) { $warnings.Add("Beacon results $($b['file']) name no machine of this cluster (host name '$($b['hostname'])', serial '$($b['serial'])').") } }
    $beaconOut = @(foreach ($b in $beacons) {
            [ordered]@{
                file = [string]$b['file']; node = $(if ($beaconNode.ContainsKey([string]$b['file'])) { $beaconNode[[string]$b['file']] } else { '' })
                hostname = [string]$b['hostname']; serial = [string]$b['serial']; verdict = [string]$b['verdict']
                total = [int]$b['total']; pass = [int]$b['pass']; fail = [int]$b['fail']; warn = [int]$b['warn']; skip = [int]$b['skip']; finishedAt = [string]$b['finishedAt']
            }
        })
    return [ordered]@{
        configured = $true; status = $status; state = $state; stateText = $text
        location = [System.IO.Path]::GetFileName($path.TrimEnd('\', '/')); summaryFound = [bool]$summaryFound
        collectedAt = $(if ($latest.Count) { Format-AzlSonarDate $latest[0] } else { $null })
        ageSeconds = $age; stale = $stale; staleDays = $script:AzlSonarDiscoveryStaleDays
        ready = [bool]($state -eq 'discovered')
        nodesTotal = $nodes.Count; nodesDiscovered = $found.Count; nodesFailed = $failed.Count
        problems = $problems.ToArray(); skipped = $skipped.ToArray(); beacon = $beaconOut; warnings = $warnings.ToArray(); nodes = $nodes
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
