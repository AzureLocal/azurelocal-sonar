Set-StrictMode -Version Latest

# OS configuration events (azurelocal-toolkit Invoke-AzureLocalOsConfiguration.ps1): after provisioning, before validation,
# the toolkit configures the operating system of every node and appends what it does to a JSON Lines file, one object per
# line: { timestamp, node, stage 'OsConfiguration', step, state, evidence, level, nextAction, method, transport,
# payloadVersion, schemaVersion, ... } (the contract: pmo/azure-local/os-configuration-design.md section 6 of the platform
# repository). Run events use node '*' (RunStarted, PlanCompleted, WipeListPublished, RunCompleted). Node events:
# NodeStarted, MethodResolved, TransportResolved, NodeRetry, NodeConverged, NodeFailed, NodeBlocked, NodeReconnecting,
# NodeReconnected (an older NodeRestarting counts as NodeReconnecting). Step events: StepPlanned, StepSkipped,
# StepApplying, StepApplied, StepFailed, StepVerified. Guarded network change (step Network): NetworkChangeStaged,
# NetworkChangeVerifying, NetworkChangeAwaitingConfirm, NetworkChangeCommitted, NetworkChangeRepaired,
# NetworkChangeRolledBack, NetworkChangeRefused. Sonar follows that file (local, read-only), shows each
# event in the log pane (file 'os-config-events') and builds the OS configuration mode from it: one machine per node, one
# step per OS configuration step (Get-AzlSonarOsConfigurationState).
#
# The store maps a node name to { Events = events of the node's latest attempt; Attempt = n }, and '*' to the run entry.
# Every change stores a new object (never edits one the poller may be reading). An attempt of a node restarts on its next
# NodeStarted line; a run-wide RunStarted with a `nodes` array clears exactly those nodes. Both follow the order of the
# lines in the file, never a clock.

$script:AzlSonarOsRunKey = '*'
# Per node: has it reported that it is joined to the domain? Kept apart from the attempts, which a new run clears.
$script:AzlSonarOsDomainKey = '*domain'
$script:AzlSonarOsEventFile = 'os-config-events'
$script:AzlSonarOsMaxNodeEvents = 600
# A run command still 'Creating' after this many minutes gets a warning with its age.
$script:AzlSonarOsRunCommandStuckMinutes = 10
$script:AzlSonarRunCommandApiVersion = '2026-09-01'

# The steps in display order. Verify: true = on the ZTP path the step is checked, not changed (ZTP set the computer name
# and registered the machine with Azure Arc). Arc: the step runs as an Arc Run Command when the node is reached that way.
$script:AzlSonarOsStep = [ordered]@{
    RemoteManagement = @{ Name = 'Remote management'; Description = 'WinRM, remote desktop and ping are on, so the node can be managed.' }
    Network          = @{ Name = 'Network (management address)'; Description = 'The static management address on the port with the management MAC, DHCP off on the other ports.' }
    Dns              = @{ Name = 'DNS servers'; Description = 'The DNS servers of the management port.' }
    Time             = @{ Name = 'Time (NTP)'; Description = 'The NTP peers the node keeps its clock with.' }
    Hostname         = @{ Name = 'Computer name'; Description = 'The computer name from the master file (a restart). ZTP sets it, so there it is only checked.' }
    DomainJoin       = @{ Name = 'Domain join'; Description = 'The machine joins the Active Directory domain and OU from the master file, after its name, network, DNS and time. A local identity design does not join.' }
    UnusedAdapters   = @{ Name = 'Unused network adapters'; Description = 'Ports no role uses are disabled.' }
    LocalAdmin       = @{ Name = 'Local administrator'; Description = 'The deployment administrator exists, is enabled and has the password from the Key Vault.' }
    Mpio             = @{ Name = 'MPIO (SAN)'; Description = 'Multipath I/O for the SAN: the feature, the hardware ID, the load-balance policy and the settings.' }
    SanVerify        = @{ Name = 'SAN verification'; Description = 'The SAN disks and Fibre Channel ports the node sees match the master file.' }
    ClearStorage     = @{ Name = 'Clear storage'; Description = 'Leftover local storage is wiped (only when os_configuration.clear_storage is on).' }
    Sbe              = @{ Name = 'SBE package'; Description = 'The OEM Solution Builder Extension package is on the node.' }
    Drivers          = @{ Name = 'OEM drivers'; Description = 'The OEM network drivers from the SBE.' }
    ArcRegistration  = @{ Name = 'Azure Arc registration'; Description = 'The machine is registered with Azure Arc. ZTP does it, so there it is only checked.' }
}

function ConvertFrom-AzlSonarOsConfigEvent {
    <#
    .SYNOPSIS
        One event line of the OS configuration event file as a log line { file, text }, or $null when the line is not an event.
    .DESCRIPTION
        The text starts with the event's own UTC timestamp, so the log pane orders it by event time, then
        "[osconfig] <node> <State> (<step>): <evidence> -> next: <nextAction>", and ends with the level word (error, warning)
        the pane colours by. Lines that are not JSON objects with a node and a state are skipped (a half-written line is
        retried by the reader on the next poll).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    $entry = ConvertFrom-AzlSonarOsConfigLine -Line $Line
    if ($null -eq $entry) { return $null }
    $prefix = if ($entry.when) { $entry.when.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) + ' ' } else { '' }
    $level = ([string]$entry.level).ToLowerInvariant()
    $text = "${prefix}[osconfig] $($entry.node) $($entry.state)"
    if ($entry.step) { $text += " ($($entry.step))" }
    if ($entry.evidence) { $text += ": $($entry.evidence)" }
    if ($entry.nextAction) { $text += " -> next: $($entry.nextAction)" }
    if ($level -eq 'error' -and $text -notmatch '(?i)\b(error|failed|fatal|exception)\b') { $text += ' (error)' }
    elseif ($level -eq 'warning' -and $text -notmatch '(?i)\bwarn(ing)?\b') { $text += ' (warning)' }
    return @{ file = $script:AzlSonarOsEventFile; text = $text }
}

function ConvertFrom-AzlSonarOsConfigLine {
    <#
    .SYNOPSIS
        Parses one line of the event file into a hashtable { node, state, step, when (UTC datetime or $null), timestamp,
        evidence, level, nextAction, method, transport, data (the other fields) }, or $null when it is not an event.
    .DESCRIPTION
        Only objects with a node and a state are events. A timestamp is read as UTC with the invariant culture whatever
        the culture of this machine is. Unknown fields are kept in data.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $raw = $null
    try { $raw = ConvertFrom-Json -InputObject $Line -AsHashtable -Depth 8 } catch { return $null }
    if ($raw -isnot [System.Collections.IDictionary]) { return $null }
    $get = { param($k, $d) if ($raw.Contains($k) -and $null -ne $raw[$k]) { $raw[$k] } else { $d } }
    $node = [string](& $get 'node' '')
    $state = [string](& $get 'state' '')
    if (-not $node -or -not $state) { return $null }
    $stage = [string](& $get 'stage' 'OsConfiguration')
    if ($stage -and $stage -ne 'OsConfiguration') { return $null }
    $stamp = & $get 'timestamp' ''
    $when = ConvertTo-AzlSonarUtcDate $stamp
    $level = [string](& $get 'level' 'Info')
    if ($level -notin 'Info', 'Warning', 'Error') { $level = 'Info' }
    $standard = 'node', 'state', 'stage', 'step', 'timestamp', 'evidence', 'level', 'nextAction', 'method', 'transport'
    $data = @{}
    foreach ($k in $raw.Keys) { if ([string]$k -notin $standard) { $data[[string]$k] = $raw[$k] } }
    return @{
        node       = $node
        state      = $state
        step       = [string](& $get 'step' '')
        when       = $when
        timestamp  = $(if ($when) { $when.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) } else { '' })
        evidence   = [string](& $get 'evidence' '')
        level      = $level
        nextAction = [string](& $get 'nextAction' '')
        method     = [string](& $get 'method' '')
        transport  = [string](& $get 'transport' '')
        data       = $data
    }
}

function Read-AzlSonarOsConfigEventChunk {
    <#
    .SYNOPSIS
        Reads the complete lines of the OS configuration event file after -Offset (bytes). Returns { Lines, Offset, Truncated }.
    .DESCRIPTION
        Same rules as the ZTP event file (Read-AzlSonarZtpEventChunk): opened with FileShare ReadWrite, a partial last
        line waits for the next poll, a missing file returns no lines. Truncated is true when the file got smaller than
        -Offset (replaced or emptied): the lines returned are then the file from its start and the caller starts over.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [long]$Offset = 0
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Lines = @(); Offset = 0; Truncated = ($Offset -gt 0) } }
    $length = (Get-Item -LiteralPath $Path).Length
    $truncated = $Offset -gt $length
    if ($truncated) { $Offset = 0 }
    $chunk = Read-AzlSonarZtpEventChunk -Path $Path -Offset $Offset
    return @{ Lines = @($chunk.Lines); Offset = [long]$chunk.Offset; Truncated = $truncated }
}

function Add-AzlSonarOsConfigEvent {
    <#
    .SYNOPSIS
        Records one event line in the OS configuration store (run entry '*' and one entry per node).
    .DESCRIPTION
        NodeStarted begins a new attempt of the node: its events are replaced by this one. RunStarted with a `nodes` array
        clears exactly those nodes (their next NodeStarted begins again anyway) and starts a new run entry; RunStarted
        without one only starts a new run entry. The other node events and the step events are added to the node's
        attempt (at most 600 kept: the oldest after the first two go). Run events update the run entry. An event of a node
        with no attempt yet starts one. Each change stores new objects: the poller never reads one being written. Lines
        that are not events are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Store,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    $evt = ConvertFrom-AzlSonarOsConfigLine -Line $Line
    if ($null -eq $evt) { return }
    $runKey = $script:AzlSonarOsRunKey
    $run = $null
    if ($Store.Contains($runKey) -and $null -ne $Store[$runKey]) { $run = $Store[$runKey] }
    $copyRun = {
        $c = @{}
        if ($null -ne $run) { foreach ($k in $run.Keys) { $c[$k] = $run[$k] } }
        $c
    }

    if ($evt.node -eq $runKey) {
        $new = & $copyRun
        $new['Events'] = [int]$(if ($new.ContainsKey('Events')) { $new['Events'] } else { 0 }) + 1
        $new['LastEventAt'] = $evt.timestamp
        switch ($evt.state) {
            'RunStarted' {
                $names = @()
                if ($evt.data.ContainsKey('nodes') -and $null -ne $evt.data['nodes']) { $names = @(@($evt.data['nodes']) | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
                foreach ($n in $names) { if ($Store.Contains($n)) { $Store.Remove($n) } }
                $new = @{
                    Events = 1; LastEventAt = $evt.timestamp; Started = $evt.timestamp; Nodes = [string[]]$names
                    Mode = [string]$(if ($evt.data.ContainsKey('mode')) { $evt.data['mode'] } else { '' })
                    Cluster = [string]$(if ($evt.data.ContainsKey('cluster')) { $evt.data['cluster'] } else { '' })
                    SchemaVersion = [string]$(if ($evt.data.ContainsKey('schemaVersion')) { $evt.data['schemaVersion'] } else { '' })
                    WrapperVersion = [string]$(if ($evt.data.ContainsKey('wrapperVersion')) { $evt.data['wrapperVersion'] } else { '' })
                    PlanCompleted = $null; Completed = $null; ExitCode = $null; Wipe = $null; Level = $evt.level
                }
            }
            'PlanCompleted' {
                $new['PlanCompleted'] = $evt.timestamp
                $new['PlanChanges'] = [int]$(if ($evt.data.ContainsKey('changes')) { $evt.data['changes'] } else { 0 })
                $new['PlanBlocked'] = [int]$(if ($evt.data.ContainsKey('blocked')) { $evt.data['blocked'] } else { 0 })
            }
            'WipeListPublished' {
                $wipe = @(if ($evt.data.ContainsKey('wipe') -and $null -ne $evt.data['wipe']) {
                        foreach ($w in @($evt.data['wipe'])) {
                            if ($w -is [System.Collections.IDictionary]) { @{ node = [string]$w['node']; disks = [string]$w['disks'] } }
                        }
                    })
                $new['Wipe'] = @{
                    At = $evt.timestamp; Enabled = [bool]$(if ($evt.data.ContainsKey('clearStorage')) { $evt.data['clearStorage'] } else { $wipe.Count -gt 0 })
                    Count = [int]$(if ($evt.data.ContainsKey('wipeCount')) { $evt.data['wipeCount'] } else { $wipe.Count }); Nodes = $wipe
                }
            }
            'RunCompleted' {
                $new['Completed'] = $evt.timestamp
                $new['ExitCode'] = [int]$(if ($evt.data.ContainsKey('exitCode')) { $evt.data['exitCode'] } else { -1 })
                $new['Level'] = $evt.level
                if ($evt.data.ContainsKey('mode') -and $evt.data['mode']) { $new['Mode'] = [string]$evt.data['mode'] }
            }
        }
        if (-not $new.ContainsKey('Started')) { $new['Started'] = $evt.timestamp }
        $Store[$runKey] = $new
        return
    }

    # A node event. The first event of a run that this store never saw start also marks the run as started.
    if ($null -eq $run) {
        $implicit = & $copyRun
        $implicit['Started'] = $evt.timestamp; $implicit['Events'] = 0; $implicit['LastEventAt'] = $evt.timestamp
        $Store[$runKey] = $implicit
    }
    else {
        $touch = & $copyRun
        $touch['LastEventAt'] = $evt.timestamp
        $Store[$runKey] = $touch
    }
    # For log access: DomainJoined (or a DomainJoin plan that found the machine already joined) marks the node as joined;
    # DomainAdminsConfigured marks the domain account as an administrator of it. A DomainJoin plan that finds the machine not
    # joined clears both.
    $domainChange = $null
    if ($evt.state -eq 'DomainJoined') { $domainChange = @{ Joined = $true } }
    elseif ($evt.state -eq 'DomainAdminsConfigured') { $domainChange = @{ AdminsConfigured = $true } }
    elseif ($evt.state -eq 'DomainJoinPlanned') {
        $action = [string]$(if ($evt.data.ContainsKey('action')) { $evt.data['action'] } else { 'Change' })
        if ($action -eq 'Ok') { $domainChange = @{ Joined = $true } } else { $domainChange = @{ Joined = $false; AdminsConfigured = $false } }
    }
    if ($null -ne $domainChange) {
        $flags = @{}
        if ($Store.Contains($script:AzlSonarOsDomainKey) -and $null -ne $Store[$script:AzlSonarOsDomainKey]) { foreach ($k in $Store[$script:AzlSonarOsDomainKey].Keys) { $flags[$k] = $Store[$script:AzlSonarOsDomainKey][$k] } }
        $entry = @{ Joined = $false; AdminsConfigured = $false }
        if ($flags.ContainsKey($evt.node)) { foreach ($k in $flags[$evt.node].Keys) { $entry[$k] = $flags[$evt.node][$k] } }
        foreach ($k in $domainChange.Keys) { $entry[$k] = $domainChange[$k] }
        $flags[$evt.node] = $entry
        $Store[$script:AzlSonarOsDomainKey] = $flags
    }
    $previous = $null
    if ($Store.Contains($evt.node) -and $null -ne $Store[$evt.node]) { $previous = $Store[$evt.node] }
    $attempt = if ($null -ne $previous) { [int]$previous['Attempt'] } else { 0 }
    $list = [System.Collections.ArrayList]::new()
    if ($evt.state -eq 'NodeStarted' -or $null -eq $previous) {
        $attempt++
    }
    else {
        foreach ($e in $previous['Events']) { $null = $list.Add($e) }
    }
    $null = $list.Add($evt)
    while ($list.Count -gt $script:AzlSonarOsMaxNodeEvents) { $list.RemoveAt(2) }
    $Store[$evt.node] = @{ Attempt = $attempt; Events = $list.ToArray() }
}

function Update-AzlSonarOsConfigInfo {
    <#
    .SYNOPSIS
        Counts the event lines read and keeps the newest event time, for the page's Details (/api/details).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory counter only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Info,

        [AllowEmptyCollection()]
        [string[]]$Line = @()
    )

    foreach ($raw in $Line) {
        $evt = ConvertFrom-AzlSonarOsConfigLine -Line $raw
        if ($null -eq $evt) { continue }
        $Info['Count'] = [long]$Info['Count'] + 1
        $when = $evt.when
        if ($null -eq $when) { $when = [datetime]::UtcNow }
        $current = ConvertTo-AzlSonarUtcDate $Info['LastEventAt']
        if ($null -eq $current -or $when -gt $current) { $Info['LastEventAt'] = Format-AzlSonarDate $when }
    }
}

function Invoke-AzlSonarOsConfigEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the OS configuration event file and adds each event to the log pane and to the store until the stop flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [object]$Config,

        [double]$PollSeconds = 2
    )

    $path = [string](Get-AzlSonarMember $Config 'osConfigEventsPath' '')
    if (-not $path) { return }
    $offset = [long]0
    while (-not $Shared.Stop) {
        try {
            $chunk = Read-AzlSonarOsConfigEventChunk -Path $path -Offset $offset
            if ($chunk.Truncated -and $Shared.Contains('OsConfigEvents')) {
                # The file was replaced or emptied: what the store holds came from a file that is gone.
                foreach ($key in @($Shared['OsConfigEvents'].Keys)) { $Shared['OsConfigEvents'].Remove($key) }
            }
            $offset = [long]$chunk.Offset
            $lines = foreach ($raw in $chunk.Lines) { ConvertFrom-AzlSonarOsConfigEvent -Line $raw }
            if (@($lines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($lines) }
            if ($Shared.Contains('OsConfigInfo')) { Update-AzlSonarOsConfigInfo -Info $Shared['OsConfigInfo'] -Line @($chunk.Lines) }
            if ($Shared.Contains('OsConfigEvents')) { foreach ($raw in $chunk.Lines) { Add-AzlSonarOsConfigEvent -Store $Shared['OsConfigEvents'] -Line $raw } }
        }
        catch { Write-Verbose "OS configuration event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

function Get-AzlSonarOsConfigRunCommand {
    <#
    .SYNOPSIS
        The OS configuration run commands of one Arc machine (read-only GET of machines/{name}/runCommands): name, state, since, age.
    .DESCRIPTION
        The toolkit names its run commands azl-osconfig-<id>. A command whose provisioning state is still Creating after
        10 minutes is marked stuck. Returns { Items, Error }: a failed read is an Error text, never an exception.
        Unverified against a live run (Microsoft.HybridCompute/machines/runCommands, read from the REST reference).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ArcMachineResourceId,

        [datetime]$Now = [datetime]::UtcNow
    )

    $id = Get-AzlSonarArcResourcePath -ResourceId $ArcMachineResourceId
    if (-not $id) { return @{ Items = @(); Error = '' } }
    try {
        $response = Invoke-AzlSonarArmGet -Path ('{0}/runCommands?api-version={1}' -f $id, $script:AzlSonarRunCommandApiVersion)
    }
    catch { return @{ Items = @(); Error = $_.Exception.Message } }
    if ($response.StatusCode -eq 404) { return @{ Items = @(); Error = '' } }
    if ($response.StatusCode -ne 200) { return @{ Items = @(); Error = [string]$response.ErrorMessage } }
    $listed = Get-AzlSonarMember $response.Body 'value' @()
    $items = foreach ($rc in $listed) {
        $name = [string](Get-AzlSonarMember $rc 'name' '')
        if ($name -notlike 'azl-osconfig-*') { continue }
        $provisioning = [string](Get-AzlSonarMember $rc 'properties.provisioningState' '')
        $execution = [string](Get-AzlSonarMember $rc 'properties.instanceView.executionState' '')
        $since = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $rc 'properties.instanceView.startTime')
        if ($null -eq $since) { $since = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $rc 'systemData.createdAt') }
        $age = if ($null -ne $since) { [int][math]::Max(0, ($Now.ToUniversalTime() - $since).TotalMinutes) } else { $null }
        [ordered]@{
            name         = $name
            state        = $(if ($execution) { $execution } else { $provisioning })
            provisioning = $provisioning
            since        = Format-AzlSonarDate $since
            ageMinutes   = $age
            stuck        = [bool]($provisioning -eq 'Creating' -and $null -ne $age -and $age -ge $script:AzlSonarOsRunCommandStuckMinutes)
        }
    }
    return @{ Items = @($items); Error = '' }
}

# ---------------------------------------------------------------------------------------------------------------------
# The state: the osConfiguration object of /api/state
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSonarOsStepStage {
    # One step's events (latest first applies) folded into { stage, action, ... }. Events are in file order.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Events = @())

    $s = @{ stage = 'waiting'; action = ''; verifyOnly = $false; evidence = ''; current = ''; desired = ''; item = ''; start = $null; end = $null; errors = @(); level = 'Info'; nextAction = ''; guarded = ''; transport = ''; changeId = ''; rung = ''; repairs = 0; reason = ''; confirmBy = $null; confirmMinutes = 0 }
    foreach ($e in $Events) {
        $data = $e.data
        switch ($e.state) {
            'StepPlanned' {
                $action = [string]$(if ($data.ContainsKey('action')) { $data['action'] } else { 'Info' })
                $s.action = $action
                $s.stage = switch ($action) { 'Ok' { 'ok' } 'Change' { 'planned' } 'Blocked' { 'blocked' } default { 'info' } }
                $s.verifyOnly = [bool]$(if ($data.ContainsKey('verifyOnly')) { $data['verifyOnly'] } else { $false })
                $s.evidence = $e.evidence; $s.level = $e.level; $s.nextAction = $e.nextAction
                foreach ($k in 'current', 'desired', 'item') { $s[$k] = [string]$(if ($data.ContainsKey($k)) { $data[$k] } else { '' }) }
                $s.errors = @(); $s.end = $null
            }
            'StepApplying' {
                $s.stage = 'changing'; $s.start = $e.when; $s.end = $null; $s.evidence = $e.evidence; $s.level = $e.level; $s.errors = @()
                foreach ($k in 'current', 'desired', 'item') { if ($data.ContainsKey($k)) { $s[$k] = [string]$data[$k] } }
            }
            'StepApplied' { $s.stage = 'applied'; $s.end = $e.when; $s.evidence = $e.evidence; $s.level = $e.level }
            'StepVerified' { $s.stage = 'verified'; $s.end = $e.when; $s.evidence = $e.evidence; $s.level = $e.level; $s.errors = @() }
            'StepFailed' {
                $s.stage = 'failed'; $s.end = $e.when; $s.evidence = $e.evidence; $s.level = 'Error'; $s.nextAction = $e.nextAction
                $s.errors = @($e.evidence)
                foreach ($k in 'current', 'desired', 'item') { if ($data.ContainsKey($k)) { $s[$k] = [string]$data[$k] } }
            }
            'StepSkipped' { $s.stage = 'skipped'; $s.evidence = $e.evidence; $s.level = $e.level; $s.end = $e.when }
            'DomainJoinPlanned' {
                $action = [string]$(if ($data.ContainsKey('action')) { $data['action'] } else { 'Change' })
                $s.action = $action
                $s.stage = switch ($action) { 'Ok' { 'ok' } 'Blocked' { 'blocked' } default { 'planned' } }
                $s.evidence = $e.evidence; $s.level = $e.level; $s.nextAction = $e.nextAction; $s.errors = @(); $s.end = $null
                foreach ($k in 'current', 'desired', 'item') { $s[$k] = [string]$(if ($data.ContainsKey($k)) { $data[$k] } else { '' }) }
            }
            'DomainJoinApplying' { $s.stage = 'changing'; $s.start = $e.when; $s.end = $null; $s.evidence = $e.evidence; $s.level = $e.level; $s.errors = @() }
            'DomainJoined' { $s.stage = 'applied'; $s.end = $e.when; $s.evidence = $e.evidence; $s.level = $e.level; $s.errors = @() }
            'DomainAdminsConfigured' { $s.stage = 'applied'; $s.end = $e.when; $s.evidence = $e.evidence; $s.level = $e.level; $s.errors = @() }
            'DomainJoinFailed' { $s.stage = 'failed'; $s.end = $e.when; $s.evidence = $e.evidence; $s.level = 'Error'; $s.nextAction = $e.nextAction; $s.errors = @($e.evidence) }
            { $_ -like 'NetworkChange*' } {
                # The guarded change of the management network: commit confirmed (design section 4). Written for the Network step.
                $g = $_.Substring('NetworkChange'.Length)
                $s.guarded = $g; $s.evidence = $e.evidence; $s.level = $e.level; $s.nextAction = $e.nextAction
                if ($data.ContainsKey('changeId')) { $s.changeId = [string]$data['changeId'] }
                switch ($g) {
                    'Staged' { $s.stage = 'changing'; if ($null -eq $s.start) { $s.start = $e.when }; $s.end = $null; $s.errors = @(); $s.repairs = 0 }
                    'Verifying' { $s.stage = 'changing'; $s.end = $null }
                    'AwaitingConfirm' {
                        $s.stage = 'changing'; $s.end = $null; $s.confirmAt = $e.when
                        $minutes = if ($data.ContainsKey('confirmMinutes')) { [int]$data['confirmMinutes'] } else { 10 }
                        $s.confirmMinutes = $minutes
                        $by = if ($data.ContainsKey('confirmBy')) { ConvertTo-AzlSonarUtcDate $data['confirmBy'] } else { $null }
                        $s.confirmBy = if ($null -ne $by) { $by } elseif ($null -ne $e.when) { $e.when.AddMinutes($minutes) } else { $null }
                    }
                    'Repaired' { $s.stage = 'changing'; $s.repairs = [int]$(if ($s.ContainsKey('repairs')) { $s['repairs'] } else { 0 }) + 1; $s.rung = [string]$(if ($data.ContainsKey('rung')) { $data['rung'] } else { '' }) }
                    'Committed' { $s.stage = 'applied'; $s.end = $e.when; $s.errors = @() }
                    'RolledBack' {
                        $s.stage = 'rolledback'; $s.end = $e.when; $s.level = 'Error'
                        $reason = if ($data.ContainsKey('reason') -and $data['reason']) { [string]$data['reason'] } else { $e.evidence }
                        $s.reason = $reason; $s.errors = @($reason)
                    }
                    'Refused' {
                        $s.stage = 'refused'; $s.end = $e.when; $s.level = 'Error'
                        $reason = if ($data.ContainsKey('reason') -and $data['reason']) { [string]$data['reason'] } else { $e.evidence }
                        $s.reason = $reason; $s.errors = @($reason)
                    }
                }
            }
        }
        if ($e.transport) { $s.transport = $e.transport }
        if ($null -eq $s.start -and $e.state -in 'StepPlanned', 'StepSkipped') { $s.firstSeen = $e.when }
    }
    return $s
}

function Get-AzlSonarOsMethodGuess {
    # The method a node is expected to use before any event says: ZTP events or a simplified declaration mean Ztp, an ISO declaration Iso.
    [CmdletBinding()]
    param([string]$Node, [string]$Route, [string[]]$ZtpNode = @())
    if ($Node -and @($ZtpNode | Where-Object { $_ -ieq $Node }).Count) { return @{ Method = 'Ztp'; Note = 'ZTP events exist for this machine' } }
    if ($Route -eq 'simplified') { return @{ Method = 'Ztp'; Note = 'scenario.os_install is simplified' } }
    if ($Route -eq 'oem-image') { return @{ Method = 'Iso'; Note = 'scenario.os_install is iso' } }
    return @{ Method = ''; Note = '' }
}

function ConvertTo-AzlSonarOsConfigNode {
    <#
    .SYNOPSIS
        One machine of the OS configuration mode from its store entry: method, versions, state, retries and the step tree.
    .DESCRIPTION
        status is the tree status (notstarted, running, success, error); state is the plain word (waiting, planning,
        planned, applying, retrying, restarting, verifying, converged, failed, blocked). The tree has one item per step in
        display order; its osc object carries the stage (waiting, planned, ok, info, changing, applied, verified, failed,
        blocked, skipped), the action, verifyOnly, current and desired, and whether the step runs as an Arc Run Command.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [System.Collections.IDictionary]$Entry,

        [AllowNull()]
        [System.Collections.IDictionary]$Run,

        [string]$ExpectedRoute = '',

        [string[]]$ZtpNode = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$RunCommand = @(),

        [string]$IdentityModel = '',

        [bool]$DomainJoined = $false,

        [bool]$AdminsConfigured = $false,

        [AllowNull()]
        [System.Collections.IDictionary]$LogAccount
    )

    $events = @(if ($null -ne $Entry) { $Entry['Events'] })
    $guess = Get-AzlSonarOsMethodGuess -Node $Name -Route $ExpectedRoute -ZtpNode $ZtpNode

    # Method, transport and versions: the last MethodResolved events win field by field.
    $method = ''; $transport = ''; $methodResolved = $false
    $facts = @{}
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $events) {
        if ($e.state -eq 'MethodResolved') {
            $methodResolved = $true
            if ($e.method) { $method = $e.method }
            if ($e.transport) { $transport = $e.transport }
            foreach ($k in $e.data.Keys) { if ($null -ne $e.data[$k] -and "$($e.data[$k])" -ne '') { $facts[$k] = $e.data[$k] } }
            if ($e.level -eq 'Warning' -and $e.evidence) { $null = $warnings.Add($e.evidence) }
        }
        elseif ($e.state -eq 'TransportResolved') {
            if ($e.transport) { $transport = $e.transport }
            foreach ($k in 'address', 'forced') { if ($e.data.ContainsKey($k) -and $null -ne $e.data[$k]) { $facts[$k] = $e.data[$k] } }
        }
        else {
            if ($e.method -and -not $method) { $method = $e.method }
            if ($e.transport -and -not $transport) { $transport = $e.transport }
        }
    }
    $methodSource = if ($methodResolved) { 'resolved' } else { 'expected' }
    if (-not $method) { $method = $guess.Method }
    $declared = [string]$(if ($facts.ContainsKey('declared')) { $facts['declared'] } else { '' })
    $declaredMethod = [string]$(if ($facts.ContainsKey('declaredMethod')) { $facts['declaredMethod'] } else { '' })
    $mismatch = [bool]$(if ($facts.ContainsKey('mismatch')) { $facts['mismatch'] } else { $false })
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($w in $warnings) { if (-not $unique.Contains($w)) { $unique.Add($w) } }

    # Steps.
    $byStep = @{}
    foreach ($step in $script:AzlSonarOsStep.Keys) { $byStep[$step] = [System.Collections.Generic.List[object]]::new() }
    $retries = 0; $restarts = 0
    $outcome = ''; $outcomeEvent = $null; $last = $null; $started = $null; $lastWhen = $null
    foreach ($e in $events) {
        $stepName = if ($e.state -like 'NetworkChange*' -and -not $e.step) { 'Network' } elseif ($e.state -like 'DomainJoin*' -or $e.state -eq 'DomainAdminsConfigured') { 'DomainJoin' } else { $e.step }
        if ($stepName -and $byStep.ContainsKey($stepName)) { $byStep[$stepName].Add($e) }
        switch ($e.state) {
            'NodeRetry' { $retries++ }
            { $_ -in 'NodeRestarting', 'NodeReconnecting' } { $restarts++ }
            'NodeStarted' { $started = $e.when }
            { $_ -in 'NodeConverged', 'NodeFailed', 'NodeBlocked' } { $outcome = $e.state; $outcomeEvent = $e }
        }
        if ($null -ne $e.when) { $lastWhen = $e.when }
        $last = $e
    }
    $stages = @{}
    foreach ($step in $script:AzlSonarOsStep.Keys) { $stages[$step] = Get-AzlSonarOsStepStage -Events @($byStep[$step]) }
    if ($IdentityModel -eq 'LocalIdentity' -and $stages['DomainJoin'].stage -eq 'waiting' -and $events.Count -gt 0) {
        $stages['DomainJoin'].stage = 'skipped'
        $stages['DomainJoin'].evidence = 'Not applicable: the identity design is local, so the machine stays in a workgroup.'
    }

    $runActive = $null -ne $Run -and $Run.ContainsKey('Started') -and $null -eq $Run['Completed']
    $runDone = $null -ne $Run -and $null -ne $Run['Completed']
    $planned = $null -ne $Run -and $null -ne $Run['PlanCompleted']
    $runMode = if ($null -ne $Run) { [string]$Run['Mode'] } else { '' }
    $anyChanging = @($stages.Values | Where-Object { $_.stage -eq 'changing' }).Count -gt 0
    $anyApplied = @($stages.Values | Where-Object { $_.stage -in 'applied', 'verified' }).Count -gt 0
    $changesPending = @($stages.Values | Where-Object { $_.stage -eq 'planned' }).Count
    $blockedCount = @($stages.Values | Where-Object { $_.stage -eq 'blocked' }).Count
    $planSeen = @($stages.Values | Where-Object { $_.stage -ne 'waiting' }).Count -gt 0

    $state = 'waiting'; $status = 'notstarted'
    if ($outcome -eq 'NodeConverged') { $state = 'converged'; $status = 'success' }
    elseif ($outcome -eq 'NodeFailed') { $state = 'failed'; $status = 'error' }
    elseif ($outcome -eq 'NodeBlocked') { $state = 'blocked'; $status = 'error' }
    elseif ($events.Count -gt 0) {
        if ($null -ne $last -and $last.state -eq 'NodeRetry') { $state = 'retrying'; $status = 'running' }
        elseif ($null -ne $last -and $last.state -in 'NodeRestarting', 'NodeReconnecting') { $state = 'reconnecting'; $status = 'running' }
        elseif ($stages['Network'].guarded -eq 'AwaitingConfirm' -and $stages['Network'].stage -eq 'changing') { $state = 'awaitingconfirm'; $status = 'running' }
        elseif ($stages['Network'].stage -in 'rolledback', 'refused') { $state = $stages['Network'].stage; $status = 'error' }
        elseif ($anyChanging) { $state = 'applying'; $status = 'running' }
        elseif ($anyApplied -and $runActive) { $state = 'verifying'; $status = 'running' }
        elseif ($runDone -or ($planned -and $runMode -eq 'Plan' -and -not $runActive)) { $state = 'planned'; $status = 'notstarted' }
        elseif ($planned -and $planSeen) { $state = if ($runMode -eq 'Apply') { 'applying' } else { 'planned' }; $status = if ($state -eq 'applying') { 'running' } else { 'notstarted' } }
        elseif ($runActive -or -not $runDone) { $state = 'planning'; $status = 'running' }
    }
    $stateText = switch ($state) {
        'waiting' { 'Waiting to start' }
        'planning' { 'Reading the machine (plan)' }
        'planned' { if ($blockedCount) { "Planned: $blockedCount blocked" } elseif ($changesPending) { "Planned: $changesPending change$(if ($changesPending -ne 1) { 's' }) pending" } else { 'Planned: nothing to change' } }
        'applying' { 'Applying changes' }
        'retrying' { "Retrying (run command lost, try $retries)" }
        'reconnecting' { 'Reconnecting after a restart or an address change' }
        'awaitingconfirm' { "Network change applied; waiting for the orchestrator's confirmation" }
        'rolledback' { 'Network change rolled back' + $(if ($stages['Network'].reason) { ': ' + (Protect-AzlSonarText -Text $stages['Network'].reason) }) }
        'refused' { 'Network change refused' + $(if ($stages['Network'].reason) { ': ' + (Protect-AzlSonarText -Text $stages['Network'].reason) }) }
        'verifying' { 'Verifying' }
        'converged' { 'Converged' }
        'failed' { 'Failed' }
        'blocked' { 'Blocked' }
    }

    # Current step: the one being changed, else the last one an event touched while the node is working.
    $currentStep = ''
    foreach ($step in $script:AzlSonarOsStep.Keys) { if ($stages[$step].stage -eq 'changing') { $currentStep = $step; break } }
    if (-not $currentStep -and $status -eq 'running') {
        $touched = @($events | Where-Object { $_.step } | Select-Object -Last 1)
        if ($touched.Count) { $currentStep = $touched[0].step }
    }
    if (-not $currentStep -and $state -in 'failed', 'blocked', 'rolledback', 'refused') {
        foreach ($step in $script:AzlSonarOsStep.Keys) { if ($stages[$step].stage -in 'failed', 'blocked', 'rolledback', 'refused') { $currentStep = $step; break } }
    }

    $arc = $transport -eq 'ArcRunCommand'
    $verifyDefault = $method -eq 'Ztp'
    $tree = foreach ($step in $script:AzlSonarOsStep.Keys) {
        $st = $stages[$step]
        $spec = $script:AzlSonarOsStep[$step]
        $verify = if ($st.stage -ne 'waiting') { $st.verifyOnly } else { $verifyDefault -and $step -in 'Hostname', 'ArcRegistration' }
        $treeStatus = switch ($st.stage) {
            'waiting' { 'notstarted' } 'planned' { 'notstarted' } 'ok' { 'success' } 'info' { 'success' } 'changing' { 'running' }
            'applied' { 'success' } 'verified' { 'success' } 'failed' { 'error' } 'blocked' { 'error' } 'rolledback' { 'error' } 'refused' { 'error' } 'skipped' { 'skipped' } default { 'notstarted' }
        }
        if ($st.stage -in 'rolledback', 'refused') { $treeStatus = 'error' }
        $description = if ($st.evidence) { Protect-AzlSonarText -Text $st.evidence } else { $spec.Description }
        $node = [ordered]@{
            id              = "osc.$step"
            name            = $spec.Name
            description     = $description
            status          = $treeStatus
            rawStatus       = $st.stage
            start           = Format-AzlSonarDate $st.start
            end             = Format-AzlSonarDate $st.end
            durationSeconds = $(if ($null -ne $st.start -and $null -ne $st.end) { [long][math]::Max(0, ($st.end - $st.start).TotalSeconds) } else { $null })
            errors          = @($st.errors | ForEach-Object { Protect-AzlSonarText -Text ([string]$_) } | Where-Object { $_ })
            children        = @()
            osc             = [ordered]@{
                step       = $step
                stage      = $st.stage
                action     = $st.action
                verifyOnly = [bool]$verify
                notApplicable = [bool]($st.stage -eq 'skipped')
                current    = Protect-AzlSonarText -Text $st.current
                desired    = Protect-AzlSonarText -Text $st.desired
                nextAction = Protect-AzlSonarText -Text $st.nextAction
                level      = $st.level
                transport  = $(if ($st.transport) { $st.transport } else { $transport })
                arc        = [bool](($st.transport -eq 'ArcRunCommand' -or (-not $st.transport -and $arc)) -and $st.stage -notin 'waiting', 'skipped' -and -not $verify)
                guarded    = $(if ($st.guarded) {
                        [ordered]@{
                            state = $st.guarded; changeId = $st.changeId; rung = $st.rung; repairs = [int]$st.repairs
                            confirmBy = (Format-AzlSonarDate $st.confirmBy); confirmMinutes = [int]$st.confirmMinutes
                            reason = (Protect-AzlSonarText -Text $st.reason)
                        }
                    } else { $null })
            }
        }
        $node
    }

    $versionKeys = 'hostname', 'osVersion', 'build', 'osCaption', 'sbePublisher', 'sbeFamily', 'sbeVersion', 'sbePackage', 'sbeDelivery', 'schemaVersion', 'wrapperVersion'
    $versions = [ordered]@{}
    foreach ($k in $versionKeys) { $versions[$k] = if ($facts.ContainsKey($k)) { Protect-AzlSonarText -Text ([string]$facts[$k]) } else { '' } }
    if (-not $versions.schemaVersion -and $null -ne $Run -and $Run.ContainsKey('SchemaVersion')) { $versions.schemaVersion = [string]$Run['SchemaVersion'] }
    if (-not $versions.wrapperVersion -and $null -ne $Run -and $Run.ContainsKey('WrapperVersion')) { $versions.wrapperVersion = [string]$Run['WrapperVersion'] }
    $versions.build = if ($versions.build) { [string]$versions.build } else { '' }

    $errors = [System.Collections.Generic.List[string]]::new()
    if ($state -in 'rolledback', 'refused') { $errors.Add((Protect-AzlSonarText -Text $stages['Network'].reason)) }
    if ($state -in 'failed', 'blocked' -and $null -ne $outcomeEvent -and $outcomeEvent.evidence) { $errors.Add((Protect-AzlSonarText -Text $outcomeEvent.evidence)) }
    $rcOut = @(foreach ($rc in @($RunCommand)) { if ($null -ne $rc) { $rc } })
    foreach ($rc in $rcOut) {
        if ($rc.stuck) { $unique.Add("Run command $($rc.name) has been Creating for $($rc.ageMinutes) min; Azure may be waiting for the node's agent.") }
    }

    $logAccountOut = $null
    if ($null -ne $LogAccount) {
        $a = $LogAccount
        $logAccountOut = [ordered]@{ kind = [string]$a.kind; waitingForAdmins = [bool]$a.waitingForAdmins; userName = Protect-AzlSonarText -Text ([string]$a.userName); reason = Protect-AzlSonarText -Text ([string]$a.reason); warning = Protect-AzlSonarText -Text ([string]$a.warning) }
        if ($a.warning) { $unique.Add([string]$a.warning) }
    }
    return [ordered]@{
        name           = $Name
        method         = $method
        methodSource   = $methodSource
        methodNote     = $(if ($methodResolved) { '' } else { $guess.Note })
        declared       = $declared
        declaredMethod = $declaredMethod
        mismatch       = $mismatch
        transport      = $transport
        evidence       = [ordered]@{
            handoff = [string]$(if ($facts.ContainsKey('handoff')) { $facts['handoff'] } else { '' })
            arc     = [string]$(if ($facts.ContainsKey('arc')) { $facts['arc'] } else { '' })
            winrm   = [string]$(if ($facts.ContainsKey('winrm')) { $facts['winrm'] } else { '' })
        }
        warnings       = @($unique | ForEach-Object { Protect-AzlSonarText -Text $_ })
        versions       = $versions
        status         = $status
        state          = $state
        stateText      = $stateText
        currentStep    = $currentStep
        domainJoined   = $DomainJoined
        domainAdminsConfigured = $AdminsConfigured
        logAccount     = $logAccountOut
        converged      = [bool]($state -eq 'converged')
        retries        = $retries
        restarts       = $restarts
        guarded        = $stages['Network'].guarded
        guardedDetail  = $(@($tree | Where-Object { $_.osc.step -eq 'Network' })[0].osc.guarded)
        changes        = $changesPending
        blocked        = $blockedCount
        errors         = $errors.ToArray()
        attempt        = $(if ($null -ne $Entry) { [int]$Entry['Attempt'] } else { 0 })
        start          = Format-AzlSonarDate $started
        end            = $(if ($state -in 'converged', 'failed', 'blocked', 'rolledback', 'refused') { Format-AzlSonarDate $lastWhen } else { $null })
        lastEventAt    = Format-AzlSonarDate $lastWhen
        runCommands    = $rcOut
        tree           = @($tree)
    }
}

function Get-AzlSonarOsConfigurationState {
    <#
    .SYNOPSIS
        The osConfiguration object of /api/state, from the event store: the run, the machines with their steps, the counts.
    .DESCRIPTION
        { configured, status (notstarted|running|success|error), state (waiting, planning, planned, applying, converged,
        failed, incomplete), ready, run{started, completed, mode, exitCode, planCompleted, cluster, schemaVersion,
        wrapperVersion, lastEventAt, events}, nodesTotal, nodesConverged, nodesFailed, nodesRetrying, wipe{published,
        enabled, count, pending, nodes[]}, nodes[], warnings[] }.
        ready is true when every machine has NodeConverged. The machines are the config's nodes, then any other node the
        events name. A machine with no event yet shows the method it is expected to use (ZTP events or the declared
        scenario.os_install). Nothing here changes the provisioning status: OS configuration never keeps Provisioning running.
    .PARAMETER Store
        Shared.OsConfigEvents (Add-AzlSonarOsConfigEvent).
    .PARAMETER Config
        A config object; osConfigEventsPath says whether the event file is followed.
    .PARAMETER ExpectedRoute
        simplified or oem-image: the method nodes are expected to use before an event says.
    .PARAMETER ZtpNode
        Names of the nodes that have ZTP events (Shared.ZtpStages).
    .PARAMETER RunCommand
        Node name -> the run commands read from Azure (Get-AzlSonarOsConfigRunCommand Items).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Store,

        [Parameter(Mandatory)]
        [object]$Config,

        [string]$ExpectedRoute = '',

        [string[]]$ZtpNode = @(),

        [AllowNull()]
        [System.Collections.IDictionary]$RunCommand,

        # Shared.LogAccount: the nodes that rejected the domain account, for the account shown per node.
        [AllowNull()]
        [System.Collections.IDictionary]$LogAccount,

        [string]$LocalUserName = ''
    )

    $configured = [bool][string](Get-AzlSonarMember $Config 'osConfigEventsPath' '')
    $identityModel = [string](Get-AzlSonarMember $Config 'identityModel' '')
    $run = $null
    if ($null -ne $Store -and $Store.Contains($script:AzlSonarOsRunKey)) { $run = $Store[$script:AzlSonarOsRunKey] }
    $names = [System.Collections.Generic.List[string]]::new()
    $configNodes = Get-AzlSonarMember $Config 'nodes' @()
    foreach ($n in $configNodes) { $nm = [string](Get-AzlSonarMember $n 'name' ''); if ($nm -and -not $names.Contains($nm)) { $names.Add($nm) } }
    if ($null -ne $run -and $run.ContainsKey('Nodes')) { foreach ($nm in @($run['Nodes'])) { if ($nm -and -not @($names | Where-Object { $_ -ieq $nm }).Count) { $names.Add([string]$nm) } } }
    if ($null -ne $Store) { foreach ($k in @($Store.Keys)) { if ($k -ne $script:AzlSonarOsRunKey -and $k -ne $script:AzlSonarOsDomainKey -and -not @($names | Where-Object { $_ -ieq $k }).Count) { $names.Add([string]$k) } } }

    $nodes = foreach ($nm in $names) {
        $entry = $null
        if ($null -ne $Store -and $Store.Contains($nm)) { $entry = $Store[$nm] }
        $rc = @()
        if ($null -ne $RunCommand -and $RunCommand.Contains($nm)) { $rc = @($RunCommand[$nm]) }
        $domainState = Get-AzlSonarOsDomainState -Store $Store -Node $nm
        $joined = $domainState.Joined
        $rejected = $false
        if ($null -ne $LogAccount -and $LogAccount.Contains($nm) -and $null -ne $LogAccount[$nm]) { $rejected = [bool]$LogAccount[$nm]['Rejected'] }
        $account = Get-AzlSonarLogAccount -Config $Config -Node $nm -DomainJoined $joined -AdminsConfigured $domainState.AdminsConfigured -Rejected $rejected -LocalUserName $LocalUserName
        ConvertTo-AzlSonarOsConfigNode -Name $nm -Entry $entry -Run $run -ExpectedRoute $ExpectedRoute -ZtpNode $ZtpNode -RunCommand $rc -IdentityModel $identityModel -DomainJoined $joined -AdminsConfigured $domainState.AdminsConfigured -LogAccount $account
    }
    $nodes = @($nodes)
    $total = $nodes.Count
    $converged = @($nodes | Where-Object { $_.state -eq 'converged' }).Count
    $failed = @($nodes | Where-Object { $_.state -in 'failed', 'blocked', 'rolledback', 'refused' }).Count
    $retrying = @($nodes | Where-Object { $_.state -eq 'retrying' }).Count
    $active = @($nodes | Where-Object { $_.status -eq 'running' }).Count
    $hasEvents = $null -ne $run -or @($nodes | Where-Object { $_.attempt -gt 0 }).Count -gt 0
    $runActive = $null -ne $run -and $run.ContainsKey('Started') -and $null -eq $run['Completed']
    $runDone = $null -ne $run -and $null -ne $run['Completed']
    $mode = if ($null -ne $run -and $run.ContainsKey('Mode')) { [string]$run['Mode'] } else { '' }

    $ready = $total -gt 0 -and $converged -eq $total
    $status = 'notstarted'
    if ($failed) { $status = 'error' }
    elseif ($ready) { $status = 'success' }
    elseif ($runActive -or $active) { $status = 'running' }
    $word = 'waiting'
    if ($hasEvents) {
        if ($failed) { $word = 'failed' }
        elseif ($ready) { $word = 'converged' }
        elseif ($runDone -and $mode -eq 'Plan') { $word = 'planned' }
        elseif ($runDone) { $word = 'incomplete' }
        elseif ($null -ne $run -and $null -ne $run['PlanCompleted'] -and $mode -eq 'Apply') { $word = 'applying' }
        elseif ($null -ne $run -and $null -ne $run['PlanCompleted']) { $word = 'planned' }
        else { $word = 'planning' }
    }

    # The wipe list: pending while a listed node has not finished its ClearStorage step.
    $wipe = [ordered]@{ published = $false; enabled = $false; count = 0; pending = $false; nodes = @() }
    if ($null -ne $run -and $null -ne $run['Wipe']) {
        $w = $run['Wipe']
        $listed = foreach ($item in @($w['Nodes'])) {
            $node = @($nodes | Where-Object { $_.name -ieq $item.node } | Select-Object -First 1)
            $stage = if ($node.Count) { @($node[0].tree | Where-Object { $_.osc.step -eq 'ClearStorage' })[0].osc.stage } else { 'waiting' }
            [ordered]@{ node = [string]$item.node; disks = Protect-AzlSonarText -Text ([string]$item.disks); done = [bool]($stage -in 'applied', 'verified', 'ok') }
        }
        $listed = @($listed)
        $wipe = [ordered]@{
            published = $true; enabled = [bool]$w['Enabled']; count = [int]$w['Count']
            pending = [bool](@($listed | Where-Object { -not $_.done }).Count -gt 0); nodes = $listed
        }
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $nodes) { foreach ($w in $n.warnings) { $warnings.Add("$($n.name): $w") } }

    return [ordered]@{
        configured     = $configured
        status         = $status
        state          = $word
        ready          = [bool]$ready
        run            = [ordered]@{
            started       = $(if ($null -ne $run) { [string]$run['Started'] } else { $null })
            completed     = $(if ($null -ne $run -and $null -ne $run['Completed']) { [string]$run['Completed'] } else { $null })
            mode          = $mode
            exitCode      = $(if ($null -ne $run -and $null -ne $run['ExitCode']) { [int]$run['ExitCode'] } else { $null })
            planCompleted = [bool]($null -ne $run -and $null -ne $run['PlanCompleted'])
            planChanges   = $(if ($null -ne $run -and $run.ContainsKey('PlanChanges')) { [int]$run['PlanChanges'] } else { $null })
            cluster       = $(if ($null -ne $run) { [string]$run['Cluster'] } else { '' })
            schemaVersion = $(if ($null -ne $run) { [string]$run['SchemaVersion'] } else { '' })
            wrapperVersion = $(if ($null -ne $run) { [string]$run['WrapperVersion'] } else { '' })
            lastEventAt   = $(if ($null -ne $run) { [string]$run['LastEventAt'] } else { $null })
            events        = $(if ($null -ne $run -and $run.ContainsKey('Events')) { [int]$run['Events'] } else { 0 })
        }
        nodesTotal     = $total
        nodesConverged = $converged
        nodesFailed    = $failed
        nodesRetrying  = $retrying
        wipe           = $wipe
        nodes          = $nodes
        warnings       = $warnings.ToArray()
    }
}

function Get-AzlSonarOsConfigRunCommandMap {
    <#
    .SYNOPSIS
        Reads the OS configuration run commands (read-only) of the nodes that are being configured over Arc Run Command.
    .DESCRIPTION
        Only nodes with a running attempt that uses ArcRunCommand and a known Arc machine are read, so a finished or
        idle run costs no Azure call. Returns node name -> run command items, and adds a warning for a failed read.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Store,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$ArcNode = @(),

        [System.Collections.Generic.List[string]]$Warnings,

        [datetime]$Now = [datetime]::UtcNow
    )

    $map = @{}
    if ($null -eq $Store) { return $map }
    foreach ($arc in @($ArcNode)) {
        $name = [string](Get-AzlSonarMember $arc 'name' '')
        if (-not $name -or -not $Store.Contains($name)) { continue }
        $entry = $Store[$name]
        $events = @($entry['Events'])
        $finished = @($events | Where-Object { $_.state -in 'NodeConverged', 'NodeFailed', 'NodeBlocked' }).Count -gt 0
        $viaArc = @($events | Where-Object { $_.transport -eq 'ArcRunCommand' }).Count -gt 0
        if ($finished -or -not $viaArc) { continue }
        $result = Get-AzlSonarOsConfigRunCommand -ArcMachineResourceId ([string](Get-AzlSonarMember $arc 'arcMachineResourceId' '')) -Now $Now
        if ($result.Error -and $null -ne $Warnings) { $Warnings.Add("OS configuration run commands of ${name}: $($result.Error)") }
        if (@($result.Items).Count) { $map[$name] = @($result.Items) }
    }
    return $map
}
