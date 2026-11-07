Set-StrictMode -Version Latest

# ZTP provisioning events (azurelocal-ztp): the machines are provisioned before the deployment exists, and the
# provisioning scripts write one JSON object per line to an event file: { timestamp, node, state, evidence, nextAction,
# level, stage }. Sonar follows that file (local, read-only) and shows each event in the log pane, so the ZTP stages
# (Mounted, Booting, MaintenanceEnvironmentRunning, VoucherWritten, ReadyForPortal, and the failure states) sit next to the
# edge machine progress it already reads from Azure. The per-node Device and Network stages also become steps of each
# machine (Add-AzlSonarZtpStageEvent, ConvertTo-AzlSonarZtpStageStep).

function ConvertFrom-AzlSonarZtpEvent {
    <#
    .SYNOPSIS
        One event line of the ZTP event file as a log line { file, text }, or $null when the line is not an event.
    .DESCRIPTION
        The text starts with the event's own UTC timestamp, so the log pane orders it by event time, and ends with the
        level word (error, warning) the pane colours by. Lines that are not JSON objects with node and state are skipped
        (a half-written line is retried by the reader on the next poll).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try { $entry = ConvertFrom-Json -InputObject $Line -Depth 8 } catch { return $null }
    if ($entry -isnot [pscustomobject]) { return $null }
    $node = [string](Get-AzlSonarMember $entry 'node' '')
    $state = [string](Get-AzlSonarMember $entry 'state' '')
    if (-not $node -or -not $state) { return $null }
    $stamp = [string](Get-AzlSonarMember $entry 'timestamp' '')
    $parsed = [datetime]::MinValue
    $prefix = if ($stamp -and [datetime]::TryParse($stamp, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        $parsed.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) + ' '
    }
    else { '' }
    $level = ([string](Get-AzlSonarMember $entry 'level' 'Info')).ToLowerInvariant()
    $evidence = [string](Get-AzlSonarMember $entry 'evidence' '')
    $next = [string](Get-AzlSonarMember $entry 'nextAction' '')
    $text = "${prefix}[ztp] $node $state"
    if ($evidence) { $text += ": $evidence" }
    if ($next) { $text += " -> next: $next" }
    # Failure states carry the word the log pane colours by even when the evidence text has none.
    if ($level -eq 'error' -and $text -notmatch '(?i)\b(error|failed|fatal|exception)\b') { $text += ' (error)' }
    elseif ($level -eq 'warning' -and $text -notmatch '(?i)\bwarn(ing)?\b') { $text += ' (warning)' }
    return @{ file = 'ztp-events'; text = $text }
}

function Read-AzlSonarZtpEventChunk {
    <#
    .SYNOPSIS
        Reads the complete lines of the event file after -Offset (bytes). Returns { Lines, Offset }.
    .DESCRIPTION
        The file is opened with FileShare ReadWrite (the writer keeps appending). A partial last line is left for the next
        poll; a file that got smaller (replaced or truncated) is read again from the start. A missing file returns no lines.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [long]$Offset = 0
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Lines = @(); Offset = 0 } }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        if ($Offset -gt $stream.Length) { $Offset = 0 }
        $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new([int][math]::Min($stream.Length - $Offset, 4MB))
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally { $stream.Dispose() }
    $lastNewline = [array]::LastIndexOf($buffer, [byte]10, [math]::Max(0, $read - 1))
    if ($read -le 0 -or $lastNewline -lt 0) { return @{ Lines = @(); Offset = $Offset } }
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $lastNewline + 1)
    return @{ Lines = @($text -split "`r?`n" | Where-Object { $_ }); Offset = $Offset + $lastNewline + 1 }
}

function Invoke-AzlSonarZtpEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the ZTP event file and adds each event to the log pane until the stop flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [object]$Config,

        [double]$PollSeconds = 2
    )

    $path = [string](Get-AzlSonarMember $Config 'ztpEventsPath' '')
    if (-not $path) { return }
    $offset = [long]0
    while (-not $Shared.Stop) {
        try {
            $chunk = Read-AzlSonarZtpEventChunk -Path $path -Offset $offset
            $offset = [long]$chunk.Offset
            $lines = foreach ($raw in $chunk.Lines) { ConvertFrom-AzlSonarZtpEvent -Line $raw }
            if (@($lines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($lines) }
            if ($Shared.Contains('ZtpStages')) { foreach ($raw in $chunk.Lines) { Add-AzlSonarZtpStageEvent -Store $Shared['ZtpStages'] -Line $raw } }
        }
        catch { Write-Verbose "ZTP event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

# The per-node azurelocal-ztp stages Sonar draws as steps. Device runs in the maintenance environment before the Azure
# claim (Set-ZtpDeviceConfiguration.ps1, the Configurator service on port 20001); Network runs after the OS install,
# through the edge machine's per-NIC API (Set-ZtpManagementAddress.ps1); Restore, after Network, puts back the final BIOS
# values where the install needed temporary ones (Redfish PATCH, restart, Arc connected again). ZTP ends there (Handoff
# writes files only): the OEM drivers, C:\SBE, DHCP off, DNS, time and the deployment admin are OS configuration, the
# step after ZTP.
# Success and Failed states end an attempt; any other state means the stage is still running.
$script:AzlSonarZtpStage = [ordered]@{
    Device  = @{
        Name        = 'Management address (maintenance environment)'
        Description = 'azurelocal-ztp Device: the static management address and host name on the port with the management MAC, set in the maintenance environment before the Azure claim'
        Id          = 'ztp.device'
        Success     = @('DeviceAddressSet', 'DeviceAddressAlreadySet', 'DeviceAddressReported', 'DeviceConfigurationSkipped')
        Failed      = @('DeviceConfigurationFailed')
        Waiting     = 'Waiting for the Device stage'
        NotApplicable = 'Not applicable'
        Labels      = @{
            DeviceConfigurationSkipped   = 'Skipped (no maintenance address; the Network stage sets the address after the OS install)'
            DeviceAddressReported        = 'Address reported, not changed'
            DeviceAddressAlreadySet      = 'Address already set'
            DeviceConfigurationSubmitted = 'Configuration sent to the maintenance environment'
            DeviceConfigurationStatus    = 'Configuration status'
            DeviceAddressSet             = 'Address set'
            DeviceConfigurationFailed    = 'Device configuration failed'
        }
    }
    Network = @{
        Name        = 'Management address on the management NIC'
        Description = 'azurelocal-ztp Network: the management address moved to the adapter with the management MAC through the edge machine''s networkAdapters API, after the OS install'
        Id          = 'ztp.network'
        Success     = @('ManagementAddressSet', 'ManagementAddressAlreadySet', 'ManagementAddressReported')
        Failed      = @('ManagementAddressFailed')
        Waiting     = 'Waiting for the Network stage'
        NotApplicable = 'Not applicable'
        Labels      = @{
            ManagementAddressReported   = 'Address reported, not changed'
            ManagementAddressAlreadySet = 'Address already set'
            NetworkJobSubmitted         = 'ApplyConfiguration job sent'
            NetworkJobStatus            = 'Job status'
            ManagementAddressReleased   = 'Address released from another adapter'
            ManagementAddressSet        = 'Address set on the management NIC'
            ManagementAddressFailed     = 'Management address failed'
        }
    }
    Restore = @{
        Name        = 'BIOS restored'
        Description = 'azurelocal-ztp Restore: the final BIOS values put back over Redfish after the temporary install values (for example the FC HBA off), a restart, then Arc connected again'
        Id          = 'ztp.restore'
        Success     = @('BiosRestored')
        Failed      = @('BiosRestoreFailed')
        Waiting     = 'Waiting for the Restore stage'
        NotApplicable = 'Not applicable: the run set no temporary BIOS values'
        Labels      = @{
            BiosRestoreStarted = 'Restoring the final BIOS values'
            BiosRestored       = 'BIOS restored and Arc connected again'
            BiosRestoreFailed  = 'BIOS restore failed'
        }
    }
}

# Store key of the run-wide ZTP facts (no node is named '*': ZTP uses it for events about every node).
$script:AzlSonarZtpRunKey = '*'

function Add-AzlSonarZtpStageEvent {
    <#
    .SYNOPSIS
        Records one ZTP event line in the per-node stage store when it belongs to the Device, Network or Restore stage.
    .DESCRIPTION
        The store maps node name to { Device = events[], Network = events[], Restore = events[] }: the events of the
        latest attempt of each stage. An event after a finished attempt (a Success or Failed state) begins a new attempt,
        and the orchestrator's StageStarted (node '*') for the stage clears it on every node, so a rerun replaces the
        earlier attempt. Each change stores new lists rather than changing the stored ones, so the poller never reads a
        list being written.
        A run with no temporary BIOS values writes no Restore event for a node. So the run entry (key '*') records
        Restore = $true once the Restore stage is over: the orchestrator's StageCompleted for Restore, or any Handoff
        event. A node without Restore events is then 'not applicable' rather than waiting. StageStarted for Restore
        clears that again.
        Other stages (Prepare from older ZTP runs included), other orchestrator events and malformed lines are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Store,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $entry = ConvertFrom-Json -InputObject $Line -Depth 8 } catch { return }
    if ($entry -isnot [pscustomobject]) { return }
    $stage = [string](Get-AzlSonarMember $entry 'stage' '')
    $node = [string](Get-AzlSonarMember $entry 'node' '')
    $state = [string](Get-AzlSonarMember $entry 'state' '')
    if (-not $node -or -not $state) { return }
    $runKey = $script:AzlSonarZtpRunKey
    $closeRestore = {
        $run = @{}
        if ($Store.Contains($runKey) -and $null -ne $Store[$runKey]) { foreach ($k in $Store[$runKey].Keys) { $run[$k] = $Store[$runKey][$k] } }
        $run['Restore'] = $true
        $Store[$runKey] = $run
    }
    if ($stage -eq 'Handoff') { & $closeRestore; return }
    if (-not $script:AzlSonarZtpStage.Contains($stage)) { return }
    $stage = @($script:AzlSonarZtpStage.Keys | Where-Object { $_ -eq $stage })[0]
    $spec = $script:AzlSonarZtpStage[$stage]
    if ($node -eq '*') {
        if ($state -eq 'StageStarted') {
            # Clears the stage on every node, and for Restore the run's 'Restore is over' too.
            foreach ($key in @($Store.Keys)) {
                $copy = @{}
                foreach ($s in $Store[$key].Keys) { if ($s -ne $stage) { $copy[$s] = $Store[$key][$s] } }
                $Store[$key] = $copy
            }
        }
        elseif ($state -eq 'StageCompleted' -and $stage -eq 'Restore') { & $closeRestore }
        return
    }
    $record = [ordered]@{
        state     = $state
        timestamp = [string](Get-AzlSonarMember $entry 'timestamp' '')
        evidence  = [string](Get-AzlSonarMember $entry 'evidence' '')
        level     = [string](Get-AzlSonarMember $entry 'level' 'Info')
    }
    $stages = @{}
    if ($Store.Contains($node) -and $null -ne $Store[$node]) { foreach ($s in $Store[$node].Keys) { $stages[$s] = $Store[$node][$s] } }
    $list = [System.Collections.ArrayList]::new()
    $previous = @($(if ($stages.ContainsKey($stage)) { $stages[$stage] }) | Where-Object { $null -ne $_ })
    $finished = $previous.Count -gt 0 -and [string]$previous[-1]['state'] -in (@($spec.Success) + @($spec.Failed))
    if (-not $finished) { foreach ($p in $previous) { $null = $list.Add($p) } }
    $null = $list.Add($record)
    $stages[$stage] = $list
    $Store[$node] = $stages
}

function ConvertTo-AzlSonarZtpStageStep {
    <#
    .SYNOPSIS
        The step of one per-node ZTP stage (Device, Network or Restore), from its events: { node (step tree node), status, state, message }.
    .DESCRIPTION
        status is success after a Success state of the stage (Device: DeviceAddressSet, DeviceAddressAlreadySet,
        DeviceAddressReported, DeviceConfigurationSkipped; Network: ManagementAddressSet, ManagementAddressAlreadySet,
        ManagementAddressReported; Restore: BiosRestored), error after its Failed state (DeviceConfigurationFailed,
        ManagementAddressFailed, BiosRestoreFailed), running while other events arrive (a queued ApplyConfiguration job,
        BiosRestoreStarted) and notstarted with none; skipped (not applicable) with none and -NotApplicable. Each event
        becomes a child step; the last one runs until the next event or the end. Only a Failed state is an error: the
        evidence of a status event is never read for one.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Device', 'Network', 'Restore')]
        [string]$Stage,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Events = @(),

        [datetime]$Now = [datetime]::UtcNow,

        # No events and the stage is over (Restore on a run without temporary BIOS values): skipped, not waiting.
        [switch]$NotApplicable
    )

    $spec = $script:AzlSonarZtpStage[$Stage]
    $list = @($Events | Where-Object { $null -ne $_ })
    $last = if ($list.Count) { $list[-1] } else { $null }
    $lastState = if ($null -ne $last) { [string]$last['state'] } else { '' }
    $status = if ($null -eq $last -and $NotApplicable) { 'Skipped' } elseif ($null -eq $last) { 'NotStarted' } elseif ($lastState -in $spec.Success) { 'Success' } elseif ($lastState -in $spec.Failed) { 'Failed' } else { 'InProgress' }
    $steps = for ($i = 0; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        $state = [string]$e['state']
        $isFailure = $state -in $spec.Failed
        $stepStatus = if ($isFailure) { 'Failed' } elseif ($i -eq $list.Count - 1 -and $status -eq 'InProgress') { 'InProgress' } else { 'Success' }
        $end = if ($i + 1 -lt $list.Count) { $list[$i + 1]['timestamp'] } elseif ($stepStatus -ne 'InProgress') { $e['timestamp'] } else { $null }
        $label = if ($spec.Labels.ContainsKey($state)) { $spec.Labels[$state] } else { $state }
        [pscustomobject]@{
            name          = $state
            description   = $(if ($e['evidence'] -and -not $isFailure) { "${label}: $($e['evidence'])" } else { $label })
            fullStepIndex = "$($spec.Id).$i"
            startTimeUtc  = $e['timestamp']
            endTimeUtc    = $end
            status        = $stepStatus
            exception     = @($(if ($isFailure) { [string]$e['evidence'] }) | Where-Object { $_ })
        }
    }
    $raw = [pscustomobject]@{
        name          = $spec.Name
        description   = $(if ($status -eq 'Skipped') { $spec.NotApplicable } else { $spec.Description })
        fullStepIndex = $spec.Id
        startTimeUtc  = $(if ($list.Count) { $list[0]['timestamp'] } else { $null })
        endTimeUtc    = $(if ($status -in 'Success', 'Failed') { $last['timestamp'] } else { $null })
        status        = $status
        exception     = @($(if ($status -eq 'Failed') { [string]$last['evidence'] }) | Where-Object { $_ })
        steps         = @($steps)
    }
    $node = @(ConvertTo-AzlSonarStepTree -StatusObject @($raw) -Now $Now)[0]
    return [ordered]@{
        node    = $node
        status  = [string]$node['status']
        state   = $lastState
        message = $(if ($null -ne $last -and $last['evidence']) { [string]$last['evidence'] } elseif ($null -ne $last) { $lastState } elseif ($status -eq 'Skipped') { $spec.NotApplicable } else { $spec.Waiting })
    }
}
