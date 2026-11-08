Set-StrictMode -Version Latest

# ARM Validate and Deploy events (azurelocal-toolkit Invoke-AzureLocalArmDeployment.ps1, module AzlArmDeploymentRun.psm1; the
# contract is docs/design/arm-validate-deploy.md section 11 of the toolkit). The run appends what it does to a JSON Lines file,
# arm-deployment-events.jsonl in its report directory, one object per line:
# { timestamp (UTC round trip), node ('*' for the run, else a node name), stage 'ArmDeployment', step, state, evidence, level,
#   nextAction, schemaVersion, runId, mode, cluster, ...data }. Sonar follows that file (local, read-only), shows each event in the
# log pane (file 'arm-events') and builds the Validate and Deployment views from it (Get-AzlSonarArmState).
#
# States the run writes: RunStarted (nodes, template, runMode), PreconditionChecked (step = check name; name, result Passed|Failed|
# Warning|Skipped), ParametersGenerated (template, parameterCount, parameterHash, deploymentSettingsApiVersion), PlanCompleted
# (failedPreconditions, offline), RunStateChanged (from, to), ValidationSubmitted / DeploymentSubmitted (deploymentName),
# ValidationSkipped (deploymentName), ValidationStep / DeploymentStep (step = the portal's step number such as 0.41; status
# notstarted|running|success|error|skipped|unknown, rawStatus, stepName, depth), ValidationPassed / ValidationFailed /
# ValidationTimedOut and DeploymentSucceeded / DeploymentFailed / DeploymentTimedOut (step = the failing step; knownIssue,
# stepName, status), ApprovalRequested / ApprovalGranted (approvalMode), DeploymentResumed (deploymentName, previous Failed|
# InProgress|Succeeded), PollError (consecutive), PhaseRefused (phase Validate|Deploy, knownIssue), RunFailed, RunCompleted
# (exitCode, state). Every event also carries runId, mode (Plan|Validate|Deploy|ValidateAndDeploy) and cluster.
#
# The store (Shared.ArmEvents) maps '*' to the run entry, '*validation' and '*deployment' to the phase entries and '*checks' to the
# preconditions of each phase. Every change stores a new object (never edits one the poller may be reading). A new run starts on
# its RunStarted line; a phase starts on the run state change into it (Validating, Deploying or Resumed) or on ValidationSkipped.
# Everything follows the order of the lines in the file, never a clock. The file holds many runs (a Validate run, then a Deploy
# run): the validation of an earlier run stays on show while a later Deploy run works.

$script:AzlSonarArmRunKey = '*'
$script:AzlSonarArmValidationKey = '*validation'
$script:AzlSonarArmDeploymentKey = '*deployment'
$script:AzlSonarArmChecksKey = '*checks'
$script:AzlSonarArmEventFile = 'arm-events'
$script:AzlSonarArmStage = 'ArmDeployment'
$script:AzlSonarArmMaxSteps = 2000
$script:AzlSonarArmMaxChecks = 400
$script:AzlSonarArmGuide = 'https://azurelocal.cloud'

# The known failures of config/known-issues/arm-deployment.json in the toolkit, by id: a title and one sentence of cause for the
# viewer. The run's own event carries the full remediation in nextAction; this is only the hint under the failing step. An id
# that is not here still shows (its id and a pointer to the list).
$script:AzlSonarArmHint = [ordered]@{
    'arc-device-id-name'                = @{ Phase = 'Deploy'; Title = 'The Arc machines are named after the device ID'; Text = 'Simplified provisioning names each Arc machine <device-id>-1, and on build 2690 the Arc infrastructure step looks it up by the host name (ParentResourceNotFound). Validate passes, Deploy fails at step 0.41. Resubmitting does not fix it.' }
    'arc-device-id-name-step-0-41'      = @{ Phase = 'Deploy'; Title = 'Deploy stopped at step 0.41'; Text = 'Step 0.41 is where the device-ID Arc name problem stops a deployment on build 2690. Look at the Arc machine names in the resource group: if they are not the host names, this is that problem. Resubmitting does not fix it.' }
    'unsupported-os-version'            = @{ Phase = 'Validate'; Title = 'Unsupported OS version'; Text = 'The OS build is not accepted for a new deployment in this subscription, or the nodes run different builds. Read the build on every node and install the one the deployment accepts.' }
    'registration-5901'                 = @{ Phase = 'Validate'; Title = 'Error 5901 (403 on the target Arc machine)'; Text = 'Seen soon after a role assignment; the same request passed after a resubmit. Wait 5 to 10 minutes and submit once more.' }
    'role-assignment-already-exists'    = @{ Phase = 'Validate'; Title = 'Role assignment already exists'; Text = 'An earlier portal attempt in the same resource group holds the role. Delete that assignment in Access control (IAM) and submit again.' }
    'role-assignment-zombie'            = @{ Phase = 'Validate'; Title = 'Role assignments of deleted resources remain'; Text = 'Filter the role assignments by Type Unknown, delete the ones shown as Identity not found, and submit again.' }
    'license-sync-after-failed-validate' = @{ Phase = 'Validate'; Title = 'A second Validate reset the system properties'; Text = 'Running Validate while the instance is in the Deployment failed state can break license sync. Do not validate again; fix the cause and resume the Deploy.' }
    'ad-prerequisites'                  = @{ Phase = 'Validate'; Title = 'Active Directory preparation is missing or incomplete'; Text = 'Check the OU path, the LCM user name and its rights against what the preparation tool created, then submit again.' }
    'dns-resolution'                    = @{ Phase = 'Validate'; Title = 'A name cannot be resolved'; Text = 'The DNS servers do not resolve the domain or the Azure endpoints. Check the DNS servers each node reports, fix them, and submit again.' }
    'vmswitch-not-bound'                = @{ Phase = 'Validate'; Title = 'The adapter is not bound to the management virtual switch'; Text = 'A failed validation left stale switch data. Follow the Microsoft steps (remove the validation switch, restart DeviceManagementService) before another attempt.' }
}

# ---------------------------------------------------------------------------------------------------------------------
# Reading the file
# ---------------------------------------------------------------------------------------------------------------------

function ConvertFrom-AzlSonarArmLine {
    <#
    .SYNOPSIS
        Parses one line of the ARM event file into a hashtable { node, state, step, when (UTC datetime or $null), timestamp,
        evidence, level, nextAction, runId, mode, cluster, data (the other fields) }, or $null when it is not an event.
    .DESCRIPTION
        Only objects with a node and a state are events, and only the stage ArmDeployment (a line with no stage is accepted).
        A timestamp is read as UTC with the invariant culture whatever the culture of this machine is. Unknown fields are kept
        in data. The text fields are kept as the run wrote them (it already scrubbed its own secrets); Sonar masks them again
        before they reach the page.
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
    $stage = [string](& $get 'stage' $script:AzlSonarArmStage)
    if ($stage -and $stage -ne $script:AzlSonarArmStage) { return $null }
    $when = ConvertTo-AzlSonarUtcDate (& $get 'timestamp' '')
    $level = [string](& $get 'level' 'Info')
    if ($level -notin 'Info', 'Warning', 'Error') { $level = 'Info' }
    $standard = 'node', 'state', 'stage', 'step', 'timestamp', 'evidence', 'level', 'nextAction', 'runId', 'mode', 'cluster'
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
        runId      = [string](& $get 'runId' '')
        mode       = [string](& $get 'mode' '')
        cluster    = [string](& $get 'cluster' '')
        data       = $data
    }
}

function ConvertFrom-AzlSonarArmEvent {
    <#
    .SYNOPSIS
        One event line of the ARM event file as a log line { file, text }, or $null when the line is not an event.
    .DESCRIPTION
        The text starts with the event's own UTC timestamp, so the log pane orders it by event time, then
        "[arm] <node> <State> (<step>): <evidence> -> next: <nextAction>", and ends with the level word (error, warning)
        the pane colours by.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    $entry = ConvertFrom-AzlSonarArmLine -Line $Line
    if ($null -eq $entry) { return $null }
    $prefix = if ($entry.when) { $entry.when.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) + ' ' } else { '' }
    $level = ([string]$entry.level).ToLowerInvariant()
    $text = "${prefix}[arm] $($entry.node) $($entry.state)"
    if ($entry.step) { $text += " ($($entry.step))" }
    if ($entry.evidence) { $text += ": $($entry.evidence)" }
    if ($entry.nextAction) { $text += " -> next: $($entry.nextAction)" }
    if ($level -eq 'error' -and $text -notmatch '(?i)\b(error|failed|fatal|exception)\b') { $text += ' (error)' }
    elseif ($level -eq 'warning' -and $text -notmatch '(?i)\bwarn(ing)?\b') { $text += ' (warning)' }
    return @{ file = $script:AzlSonarArmEventFile; text = $text }
}

function Read-AzlSonarArmEventChunk {
    <#
    .SYNOPSIS
        Reads the complete lines of the ARM event file after -Offset (bytes). Returns { Lines, Offset, Truncated }.
    .DESCRIPTION
        Same rules as the OS configuration file: opened with FileShare ReadWrite (the run keeps appending), a partial last
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

# ---------------------------------------------------------------------------------------------------------------------
# The store
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlSonarArmPhase {
    # A fresh phase entry for the run with sequence number $Seq.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$Seq, [string]$RunId, [AllowNull()][object]$Started)

    return @{
        Seq = $Seq; RunId = $RunId; Status = 'running'; Started = $Started; Completed = $null; DeploymentName = ''; Submitted = $null
        Skipped = $false; Resumed = $null; Steps = @(); Failing = $null; KnownIssue = ''; Message = ''; NextAction = ''; Refused = $null
        PollErrors = 0; PollError = ''; Level = 'Info'; CarriedOver = $false
    }
}

function Get-AzlSonarArmEntry {
    param([System.Collections.IDictionary]$Store, [string]$Key)
    if ($Store.Contains($Key) -and $null -ne $Store[$Key]) { return $Store[$Key] }
    return $null
}

function Copy-AzlSonarArmTable {
    # A shallow copy of a hashtable (null gives an empty one).
    param([AllowNull()][System.Collections.IDictionary]$Table)
    $c = @{}
    if ($null -ne $Table) { foreach ($k in $Table.Keys) { $c[$k] = $Table[$k] } }
    return $c
}

function Add-AzlSonarArmEvent {
    <#
    .SYNOPSIS
        Records one event line in the ARM store (run entry, validation and deployment entries, the checks of each phase).
    .DESCRIPTION
        RunStarted starts a new run entry (the next sequence number). RunStateChanged into Validating, Deploying or Resumed
        starts that phase (a fresh entry, unless this run already started it); ValidationSkipped does the same for an
        already validated instance. PreconditionChecked is added to the validate checks, or to the deploy checks once the run is
        past its validation (mode Deploy, or after ValidationPassed / ApprovalGranted). ValidationStep and DeploymentStep add
        or update one step by its number, in the order first seen. PhaseRefused makes a refused phase that keeps the steps of
        the phase's earlier failure. Each change stores new objects: the poller never reads one being written. Lines that
        are not events are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Store,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    $evt = ConvertFrom-AzlSonarArmLine -Line $Line
    if ($null -eq $evt) { return }
    $data = $evt.data
    $runKey = $script:AzlSonarArmRunKey
    $run = Get-AzlSonarArmEntry -Store $Store -Key $runKey
    $seq = if ($null -ne $run -and $run.ContainsKey('Seq')) { [int]$run['Seq'] } else { 0 }

    # The run entry: replaced on every event.
    $new = Copy-AzlSonarArmTable $run
    if ($evt.state -eq 'RunStarted') {
        $seq++
        $names = @()
        if ($data.ContainsKey('nodes') -and $null -ne $data['nodes']) { $names = @(@($data['nodes']) | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        $new = @{
            Seq = $seq; RunId = $evt.runId; Mode = $evt.mode; Cluster = $evt.cluster; Started = $evt.timestamp; Completed = $null; ExitCode = $null
            FinalState = ''; State = ''; StateAt = $evt.timestamp; Template = [string]$(if ($data.ContainsKey('template')) { $data['template'] } else { '' }); ParameterHash = ''
            SchemaVersion = ''; Nodes = [string[]]$names; Events = 0; LastEventAt = $evt.timestamp; Level = $evt.level; Message = ''; NextAction = ''
            Failed = $false; PlanCompleted = $false; PlanFailed = 0; Offline = $false; PastValidate = $false; Approval = $null
        }
        if ($data.ContainsKey('runMode') -and $data['runMode'] -and -not $new.Mode) { $new.Mode = [string]$data['runMode'] }
    }
    elseif ($null -eq $run) {
        $new = @{
            Seq = 0; RunId = $evt.runId; Mode = $evt.mode; Cluster = $evt.cluster; Started = $evt.timestamp; Completed = $null; ExitCode = $null
            FinalState = ''; State = ''; StateAt = $evt.timestamp; Template = ''; ParameterHash = ''; SchemaVersion = ''; Nodes = [string[]]@(); Events = 0
            LastEventAt = $evt.timestamp; Level = 'Info'; Message = ''; NextAction = ''; Failed = $false; PlanCompleted = $false; PlanFailed = 0; Offline = $false
            PastValidate = $false; Approval = $null
        }
    }
    $new['Events'] = [int]$(if ($new.ContainsKey('Events')) { $new['Events'] } else { 0 }) + 1
    $new['LastEventAt'] = $evt.timestamp
    if ($evt.cluster -and -not $new['Cluster']) { $new['Cluster'] = $evt.cluster }
    if ($evt.mode -and -not $new['Mode']) { $new['Mode'] = $evt.mode }
    if ($evt.runId -and -not $new['RunId']) { $new['RunId'] = $evt.runId }
    if ($data.ContainsKey('schemaVersion') -and $data['schemaVersion'] -and -not $new['SchemaVersion']) { $new['SchemaVersion'] = [string]$data['schemaVersion'] }
    $runSeq = [int]$new['Seq']
    $runId = [string]$new['RunId']
    $phaseEntry = {
        param($key)
        Get-AzlSonarArmEntry -Store $Store -Key $key
    }
    # The phase of this run: the stored one when this run started it, else a fresh one.
    $phaseOfRun = {
        param($key)
        $p = & $phaseEntry $key
        if ($null -ne $p -and [int]$p['Seq'] -eq $runSeq) { return (Copy-AzlSonarArmTable $p) }
        return (New-AzlSonarArmPhase -Seq $runSeq -RunId $runId -Started $evt.timestamp)
    }
    $phaseKeyOf = { param($name) if ($name -like 'Valid*') { $script:AzlSonarArmValidationKey } else { $script:AzlSonarArmDeploymentKey } }

    switch ($evt.state) {
        'ParametersGenerated' {
            if ($data.ContainsKey('template')) { $new['Template'] = [string]$data['template'] }
            if ($data.ContainsKey('parameterHash')) { $new['ParameterHash'] = [string]$data['parameterHash'] }
        }
        'PlanCompleted' {
            $new['PlanCompleted'] = $true
            $new['PlanFailed'] = [int]$(if ($data.ContainsKey('failedPreconditions')) { $data['failedPreconditions'] } else { 0 })
            $new['Offline'] = [bool]$(if ($data.ContainsKey('offline')) { $data['offline'] } else { $false })
            if ($evt.level -eq 'Error') { $new['Level'] = 'Error'; $new['Message'] = $evt.evidence; $new['NextAction'] = $evt.nextAction }
        }
        'PreconditionChecked' {
            $name = [string]$(if ($data.ContainsKey('name') -and $data['name']) { $data['name'] } else { $evt.step })
            $result = [string]$(if ($data.ContainsKey('result')) { $data['result'] } else { 'Passed' })
            if ($result -notin 'Passed', 'Failed', 'Warning', 'Skipped') { $result = 'Passed' }
            $which = if ($new['Mode'] -eq 'Deploy' -or [bool]$new['PastValidate']) { 'deploy' } else { 'validate' }
            $checks = Copy-AzlSonarArmTable (Get-AzlSonarArmEntry -Store $Store -Key $script:AzlSonarArmChecksKey)
            $slot = Copy-AzlSonarArmTable $(if ($checks.ContainsKey($which)) { $checks[$which] } else { $null })
            if (-not $slot.ContainsKey('Seq') -or [int]$slot['Seq'] -ne $runSeq) { $slot = @{ Seq = $runSeq; RunId = $runId; Plan = ($new['Mode'] -eq 'Plan'); Items = @() } }
            $item = @{ Name = $name; Node = $evt.node; Result = $result; Evidence = $evt.evidence; NextAction = $evt.nextAction; At = $evt.timestamp }
            $list = [System.Collections.Generic.List[object]]::new()
            $replaced = $false
            foreach ($existing in @($slot['Items'])) {
                if ($existing.Name -eq $name -and $existing.Node -eq $evt.node) { $list.Add($item); $replaced = $true } else { $list.Add($existing) }
            }
            if (-not $replaced) { $list.Add($item) }
            while ($list.Count -gt $script:AzlSonarArmMaxChecks) { $list.RemoveAt(0) }
            $slot['Items'] = $list.ToArray()
            $checks[$which] = $slot
            $Store[$script:AzlSonarArmChecksKey] = $checks
        }
        'RunStateChanged' {
            $to = [string]$(if ($data.ContainsKey('to')) { $data['to'] } else { '' })
            $new['State'] = $to; $new['StateAt'] = $evt.timestamp
            if ($to -eq 'Validating') {
                $Store[$script:AzlSonarArmValidationKey] = & $phaseOfRun $script:AzlSonarArmValidationKey
            }
            elseif ($to -in 'Deploying', 'Resumed') {
                $Store[$script:AzlSonarArmDeploymentKey] = & $phaseOfRun $script:AzlSonarArmDeploymentKey
            }
            elseif ($to -in 'ValidationPassed', 'AwaitingApproval') { $new['PastValidate'] = $true }
        }
        { $_ -in 'ValidationSubmitted', 'DeploymentSubmitted' } {
            $key = & $phaseKeyOf $_
            $p = & $phaseOfRun $key
            $p['DeploymentName'] = [string]$(if ($data.ContainsKey('deploymentName')) { $data['deploymentName'] } else { '' })
            $p['Submitted'] = $evt.timestamp
            $Store[$key] = $p
        }
        'ValidationSkipped' {
            $p = & $phaseOfRun $script:AzlSonarArmValidationKey
            $p['Skipped'] = $true
            $p['DeploymentName'] = [string]$(if ($data.ContainsKey('deploymentName')) { $data['deploymentName'] } else { '' })
            $Store[$script:AzlSonarArmValidationKey] = $p
        }
        'DeploymentResumed' {
            $p = & $phaseOfRun $script:AzlSonarArmDeploymentKey
            $p['Resumed'] = @{ Previous = [string]$(if ($data.ContainsKey('previous')) { $data['previous'] } else { '' }); Evidence = $evt.evidence; At = $evt.timestamp }
            if ($data.ContainsKey('deploymentName') -and $data['deploymentName']) { $p['DeploymentName'] = [string]$data['deploymentName'] }
            $Store[$script:AzlSonarArmDeploymentKey] = $p
        }
        { $_ -in 'ValidationStep', 'DeploymentStep' } {
            $key = & $phaseKeyOf $_
            $p = & $phaseOfRun $key
            $id = $evt.step
            if ($id) {
                $status = [string]$(if ($data.ContainsKey('status')) { $data['status'] } else { 'unknown' })
                if ($status -notin 'notstarted', 'running', 'success', 'error', 'skipped', 'unknown') { $status = 'unknown' }
                $stepName = [string]$(if ($data.ContainsKey('stepName') -and $data['stepName']) { $data['stepName'] } else { $id })
                $rawStatus = [string]$(if ($data.ContainsKey('rawStatus')) { $data['rawStatus'] } else { $status })
                $depth = [int]$(if ($data.ContainsKey('depth')) { $data['depth'] } else { 0 })
                # Evidence is "<name>: <raw status>[ - <first error>]" (Publish-AzlArmStepEvent).
                $errorText = ''
                $lead = "${stepName}: $rawStatus"
                if ($evt.evidence.StartsWith($lead + ' - ', [System.StringComparison]::Ordinal)) { $errorText = $evt.evidence.Substring($lead.Length + 3) }
                elseif ($status -eq 'error' -and $evt.evidence -and -not $evt.evidence.StartsWith($lead, [System.StringComparison]::Ordinal)) { $errorText = $evt.evidence }
                $list = [System.Collections.Generic.List[object]]::new()
                $found = $false
                foreach ($s in @($p['Steps'])) {
                    if ($s.Id -eq $id) {
                        $found = $true
                        $start = $s.Start
                        if ($null -eq $start -and $status -eq 'running') { $start = $evt.timestamp }
                        $end = if ($status -in 'success', 'error', 'skipped') { $evt.timestamp } else { $null }
                        $list.Add(@{ Id = $id; Name = $stepName; Depth = $depth; Status = $status; RawStatus = $rawStatus; FirstSeen = $s.FirstSeen; Start = $start; End = $end; Error = $errorText; Level = $evt.level })
                    }
                    else { $list.Add($s) }
                }
                if (-not $found) {
                    $start = if ($status -eq 'running') { $evt.timestamp } else { $null }
                    $end = if ($status -in 'success', 'error', 'skipped') { $evt.timestamp } else { $null }
                    $list.Add(@{ Id = $id; Name = $stepName; Depth = $depth; Status = $status; RawStatus = $rawStatus; FirstSeen = $evt.timestamp; Start = $start; End = $end; Error = $errorText; Level = $evt.level })
                }
                while ($list.Count -gt $script:AzlSonarArmMaxSteps) { $list.RemoveAt(0) }
                $p['Steps'] = $list.ToArray()
                $p['PollErrors'] = 0; $p['PollError'] = ''
            }
            $Store[$key] = $p
        }
        { $_ -in 'ValidationPassed', 'DeploymentSucceeded' } {
            $key = & $phaseKeyOf $_
            $p = & $phaseOfRun $key
            $p['Status'] = 'passed'; $p['Completed'] = $evt.timestamp; $p['Failing'] = $null; $p['KnownIssue'] = ''; $p['Message'] = $evt.evidence; $p['NextAction'] = $evt.nextAction; $p['Level'] = $evt.level
            if ($data.ContainsKey('skipped') -and [bool]$data['skipped']) { $p['Skipped'] = $true }
            $Store[$key] = $p
            if ($_ -eq 'ValidationPassed') { $new['PastValidate'] = $true }
        }
        { $_ -in 'ValidationFailed', 'ValidationTimedOut', 'DeploymentFailed', 'DeploymentTimedOut' } {
            $key = & $phaseKeyOf $_
            $p = & $phaseOfRun $key
            $timedOut = $_ -like '*TimedOut'
            $p['Status'] = if ($timedOut) { 'timedout' } else { 'failed' }
            $p['Completed'] = $evt.timestamp; $p['Message'] = $evt.evidence; $p['NextAction'] = $evt.nextAction; $p['Level'] = 'Error'
            $p['KnownIssue'] = [string]$(if ($data.ContainsKey('knownIssue')) { $data['knownIssue'] } else { '' })
            $p['Failing'] = if ($evt.step) { @{ Step = $evt.step; Name = [string]$(if ($data.ContainsKey('stepName')) { $data['stepName'] } else { '' }); Message = $evt.evidence } } else { $null }
            $Store[$key] = $p
        }
        'PhaseRefused' {
            $which = [string]$(if ($data.ContainsKey('phase')) { $data['phase'] } else { '' })
            $key = if ($which -eq 'Deploy') { $script:AzlSonarArmDeploymentKey } else { $script:AzlSonarArmValidationKey }
            $earlier = & $phaseEntry $key
            $p = New-AzlSonarArmPhase -Seq $runSeq -RunId $runId -Started $null
            $p['Status'] = 'refused'; $p['Completed'] = $evt.timestamp; $p['Level'] = 'Error'; $p['Message'] = $evt.evidence; $p['NextAction'] = $evt.nextAction
            $p['KnownIssue'] = [string]$(if ($data.ContainsKey('knownIssue')) { $data['knownIssue'] } else { '' })
            $p['Refused'] = @{ Message = $evt.evidence; NextAction = $evt.nextAction; KnownIssue = $p['KnownIssue']; Step = $evt.step; At = $evt.timestamp }
            if ($null -ne $earlier -and [int]$earlier['Seq'] -ne $runSeq) {
                # The refusal explains the failure the phase already had: keep that failure's steps in view, marked as earlier.
                $p['Steps'] = $earlier['Steps']; $p['Failing'] = $earlier['Failing']; $p['CarriedOver'] = $true
                if (-not $p['KnownIssue']) { $p['KnownIssue'] = [string]$earlier['KnownIssue'] }
                $p['Started'] = $earlier['Started']; $p['DeploymentName'] = $earlier['DeploymentName']
            }
            $Store[$key] = $p
        }
        'PollError' {
            $key = if ($new['State'] -eq 'Deploying') { $script:AzlSonarArmDeploymentKey } else { $script:AzlSonarArmValidationKey }
            $earlier = & $phaseEntry $key
            if ($null -ne $earlier -and [int]$earlier['Seq'] -eq $runSeq -and $earlier['Status'] -eq 'running') {
                $p = Copy-AzlSonarArmTable $earlier
                $p['PollErrors'] = [int]$(if ($data.ContainsKey('consecutive')) { $data['consecutive'] } else { [int]$p['PollErrors'] + 1 })
                $p['PollError'] = $evt.evidence
                $Store[$key] = $p
            }
        }
        { $_ -in 'ApprovalRequested', 'ApprovalGranted' } {
            $approval = Copy-AzlSonarArmTable $new['Approval']
            $approval['Mode'] = [string]$(if ($data.ContainsKey('approvalMode')) { $data['approvalMode'] } else { [string]$approval['Mode'] })
            if ($_ -eq 'ApprovalRequested') { $approval['RequestedAt'] = $evt.timestamp; $approval['Granted'] = $false }
            else { $approval['GrantedAt'] = $evt.timestamp; $approval['Granted'] = $true; $new['PastValidate'] = $true }
            $new['Approval'] = $approval
        }
        'RunFailed' {
            $new['Failed'] = $true; $new['Level'] = 'Error'; $new['Message'] = $evt.evidence; $new['NextAction'] = $evt.nextAction
        }
        'RunCompleted' {
            $new['Completed'] = $evt.timestamp
            $new['ExitCode'] = [int]$(if ($data.ContainsKey('exitCode')) { $data['exitCode'] } else { -1 })
            $new['FinalState'] = [string]$(if ($data.ContainsKey('state')) { $data['state'] } else { '' })
            if ($new['ExitCode'] -ne 0) { $new['Level'] = 'Error' }
            if ($evt.nextAction) { $new['NextAction'] = $evt.nextAction }
        }
    }
    $Store[$runKey] = $new
}

function Update-AzlSonarArmInfo {
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
        $evt = ConvertFrom-AzlSonarArmLine -Line $raw
        if ($null -eq $evt) { continue }
        $Info['Count'] = [long]$Info['Count'] + 1
        $when = $evt.when
        if ($null -eq $when) { $when = [datetime]::UtcNow }
        $current = ConvertTo-AzlSonarUtcDate $Info['LastEventAt']
        if ($null -eq $current -or $when -gt $current) { $Info['LastEventAt'] = Format-AzlSonarDate $when }
    }
}

function Invoke-AzlSonarArmEventLoop {
    <#
    .SYNOPSIS
        Background loop: follows the ARM event file and adds each event to the log pane and to the store until the stop flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [object]$Config,

        [double]$PollSeconds = 2
    )

    $path = [string](Get-AzlSonarMember $Config 'armEventsPath' '')
    if (-not $path) { return }
    $offset = [long]0
    while (-not $Shared.Stop) {
        try {
            $chunk = Read-AzlSonarArmEventChunk -Path $path -Offset $offset
            if ($chunk.Truncated -and $Shared.Contains('ArmEvents')) {
                # The file was replaced or emptied: what the store holds came from a file that is gone.
                foreach ($key in @($Shared['ArmEvents'].Keys)) { $Shared['ArmEvents'].Remove($key) }
            }
            $offset = [long]$chunk.Offset
            $lines = foreach ($raw in $chunk.Lines) { ConvertFrom-AzlSonarArmEvent -Line $raw }
            if (@($lines).Count -gt 0) { Add-AzlSonarLogLine -Shared $Shared -Line @($lines) }
            if ($Shared.Contains('ArmInfo')) { Update-AzlSonarArmInfo -Info $Shared['ArmInfo'] -Line @($chunk.Lines) }
            if ($Shared.Contains('ArmEvents')) { foreach ($raw in $chunk.Lines) { Add-AzlSonarArmEvent -Store $Shared['ArmEvents'] -Line $raw } }
        }
        catch { Write-Verbose "ARM event file poll failed: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds $PollSeconds
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The state: the arm object of /api/state
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSonarArmHintFor {
    <#
    .SYNOPSIS
        The hint for a known issue id, as { id, title, text, phase }, or $null for an empty id. An id this version does not know
        still gets a hint that names it and points at the toolkit's list.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][AllowEmptyString()][string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    if ($script:AzlSonarArmHint.Contains($Id)) {
        $h = $script:AzlSonarArmHint[$Id]
        return [ordered]@{ id = $Id; title = $h.Title; text = $h.Text; phase = $h.Phase }
    }
    return [ordered]@{ id = $Id; title = "Known issue $Id"; text = 'The toolkit matched this failure to a known issue; its cause and remediation are in config/known-issues/arm-deployment.json and in the run''s next action.'; phase = '' }
}

function ConvertTo-AzlSonarArmSeconds {
    # Whole seconds between two event timestamps (strings or dates), or $null.
    param([AllowNull()][object]$From, [AllowNull()][object]$To)
    $a = ConvertTo-AzlSonarUtcDate $From
    $b = ConvertTo-AzlSonarUtcDate $To
    if ($null -eq $a -or $null -eq $b) { return $null }
    return [long][math]::Max(0, ($b - $a).TotalSeconds)
}

function ConvertTo-AzlSonarArmCheckItem {
    # One precondition result as a tree item.
    param([Parameter(Mandatory)]$Check)
    $status = switch ($Check.Result) { 'Failed' { 'error' } 'Skipped' { 'skipped' } default { 'success' } }
    $label = $Check.Name
    if ($Check.Node -and $Check.Node -ne '*') { $label += " ($($Check.Node))" }
    $text = Protect-AzlSonarText -Text ([string]$Check.Evidence)
    return [ordered]@{
        id = "check:$($Check.Name)|$($Check.Node)"; name = $label; description = $text; status = $status; rawStatus = [string]$Check.Result
        start = $null; end = $null; durationSeconds = $null
        errors = @(if ($Check.Result -eq 'Failed' -and $text) { $text })
        children = @()
        arm = [ordered]@{ kind = 'check'; result = [string]$Check.Result; node = [string]$Check.Node; check = [string]$Check.Name; nextAction = (Protect-AzlSonarText -Text ([string]$Check.NextAction)); hint = '' }
    }
}

function ConvertTo-AzlSonarArmStepTree {
    <#
    .SYNOPSIS
        The steps of a phase (in the order first seen, each with its depth) as a nested tree of items.
    .DESCRIPTION
        A step with a greater depth than the one before it is its child; the depth is the one the run reported (the step tree
        of deploymentSettings). A step carries its status, its start (the event that first said running), its end and, when
        both are known, its duration. -FailingStep marks the step the run named as the failing one and -Hint is attached to it.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Step = @(),
        [string]$FailingStep = '',
        [AllowNull()][System.Collections.IDictionary]$Hint,
        [datetime]$Now = [datetime]::UtcNow
    )

    $roots = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.List[object]]::new()   # @{ Depth; Item; Kids }
    foreach ($s in @($Step | Where-Object { $_ })) {
        $running = $s.Status -eq 'running'
        $duration = $null
        if ($null -ne $s.Start -and $null -ne $s.End) { $duration = ConvertTo-AzlSonarArmSeconds $s.Start $s.End }
        elseif ($running -and $null -ne $s.Start) { $duration = ConvertTo-AzlSonarArmSeconds $s.Start $Now }
        $text = Protect-AzlSonarText -Text ([string]$s.Error)
        $isFailing = [bool]($FailingStep -and $s.Id -eq $FailingStep)
        $kids = [System.Collections.Generic.List[object]]::new()
        $item = [ordered]@{
            id = [string]$s.Id; name = [string]$s.Name; description = ''; status = [string]$s.Status; rawStatus = [string]$s.RawStatus
            start = $s.Start; end = $s.End; durationSeconds = $duration
            errors = @(if ($text) { $text })
            children = @()
            arm = [ordered]@{ kind = 'step'; step = [string]$s.Id; depth = [int]$s.Depth; failing = $isFailing; hint = $(if ($isFailing -and $null -ne $Hint) { [string]$Hint.title + ': ' + [string]$Hint.text } else { '' }) }
        }
        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Depth -ge [int]$s.Depth) { $stack.RemoveAt($stack.Count - 1) }
        if ($stack.Count -gt 0) { $stack[$stack.Count - 1].Kids.Add($item) } else { $roots.Add($item) }
        $stack.Add(@{ Depth = [int]$s.Depth; Item = $item; Kids = $kids })
        $item['__kids'] = $kids
    }
    # Turn each item's kid list into its children array (deepest first is not needed: the lists are shared).
    $finish = {
        param($items)
        foreach ($i in $items) {
            $k = $i['__kids']; $i.Remove('__kids')
            & $finish @($k)
            $i['children'] = @($k)
        }
    }
    & $finish @($roots)
    return @($roots)
}

function Test-AzlSonarArmItemFailed {
    # $true when a tree item, or anything below it, is in error.
    param($Item)
    if ($Item.status -eq 'error') { return $true }
    foreach ($c in @($Item.children)) { if (Test-AzlSonarArmItemFailed $c) { return $true } }
    return $false
}

function Get-AzlSonarArmPhaseState {
    <#
    .SYNOPSIS
        One phase (validation or deployment) of the arm object: its status, times, checks, step tree, failing step and hint.
    .DESCRIPTION
        status: notstarted, checking (the checks run), planned (a Plan run found nothing wrong), blocked (a check failed, nothing was
        submitted), running, passed, failed, timedout, refused. kind is the tree status word (notstarted, running, success,
        error). The checks come first in `tree`, failures first, then the steps (validation: a step in error, or with one below
        it, first; deployment: the order of the steps, because it is a progress). elapsedSeconds runs from the start of the
        phase to its end, or to -Now while it runs.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][ValidateSet('validation', 'deployment')][string]$Name,
        [AllowNull()][System.Collections.IDictionary]$Entry,
        [AllowNull()][System.Collections.IDictionary]$Checks,
        [AllowNull()][System.Collections.IDictionary]$Run,
        [datetime]$Now = [datetime]::UtcNow
    )

    $label = if ($Name -eq 'validation') { 'Validate' } else { 'Deploy' }
    $runSeq = if ($null -ne $Run) { [int]$Run['Seq'] } else { 0 }
    $runDone = $null -ne $Run -and $null -ne $Run['Completed']

    # The checks of the phase, failures first. A newer run's checks (not a Plan) make an older run's entry stale.
    $slotName = if ($Name -eq 'validation') { 'validate' } else { 'deploy' }
    $slot = if ($null -ne $Checks -and $Checks.ContainsKey($slotName)) { $Checks[$slotName] } else { $null }
    $items = if ($null -ne $slot) { @($slot['Items']) } else { @() }
    $rank = @{ Failed = 0; Warning = 1; Skipped = 2; Passed = 3 }
    $ordered = @($items | Sort-Object -Stable -Property @{ Expression = { $rank[[string]$_.Result] } })
    $failedChecks = @($items | Where-Object { $_.Result -eq 'Failed' }).Count
    $warnChecks = @($items | Where-Object { $_.Result -eq 'Warning' }).Count
    $skippedChecks = @($items | Where-Object { $_.Result -eq 'Skipped' }).Count
    $passedChecks = @($items | Where-Object { $_.Result -eq 'Passed' }).Count
    $slotIsPlan = $null -ne $slot -and $slot.ContainsKey('Plan') -and [bool]$slot['Plan']
    $slotSeq = if ($null -ne $slot) { [int]$slot['Seq'] } else { -1 }

    $usable = $null -ne $Entry
    if ($usable -and $null -ne $slot -and $slotSeq -gt [int]$Entry['Seq'] -and -not $slotIsPlan) { $usable = $false }
    $e = if ($usable) { $Entry } else { $null }

    $status = 'notstarted'
    if ($null -ne $e) { $status = [string]$e['Status'] }
    elseif ($items.Count -gt 0) {
        if ($failedChecks -gt 0) { $status = 'blocked' }
        elseif ($null -ne $Run -and $slotSeq -eq $runSeq -and $Run['Mode'] -eq 'Plan' -and ($runDone -or $Run['PlanCompleted'])) { $status = 'planned' }
        elseif ($null -ne $Run -and $slotSeq -eq $runSeq -and -not $runDone -and -not $Run['Failed']) { $status = 'checking' }
        elseif ($null -ne $Run -and $slotSeq -eq $runSeq -and $Run['Failed']) { $status = 'blocked' }
        else { $status = 'planned' }
    }
    $kind = switch ($status) {
        { $_ -in 'running', 'checking' } { 'running' }
        'passed' { 'success' }
        { $_ -in 'blocked', 'failed', 'timedout', 'refused' } { 'error' }
        default { 'notstarted' }
    }

    $skipped = $null -ne $e -and [bool]$e['Skipped']
    $resumed = $null
    if ($null -ne $e -and $null -ne $e['Resumed']) { $resumed = [ordered]@{ previous = [string]$e['Resumed']['Previous']; at = [string]$e['Resumed']['At']; text = (Protect-AzlSonarText -Text ([string]$e['Resumed']['Evidence'])) } }
    $steps = if ($null -ne $e) { @($e['Steps']) } else { @() }
    $failing = $null
    if ($null -ne $e -and $null -ne $e['Failing']) {
        $f = $e['Failing']
        $failing = [ordered]@{ step = [string]$f.Step; name = (Protect-AzlSonarText -Text ([string]$f.Name)); message = (Protect-AzlSonarText -Text ([string]$f.Message)) }
    }
    elseif ($status -in 'failed', 'timedout') {
        $firstErr = @($steps | Where-Object { $_.Status -eq 'error' } | Select-Object -Last 1)
        if ($firstErr.Count) { $failing = [ordered]@{ step = [string]$firstErr[0].Id; name = (Protect-AzlSonarText -Text ([string]$firstErr[0].Name)); message = (Protect-AzlSonarText -Text ([string]$firstErr[0].Error)) } }
    }
    $knownId = if ($null -ne $e) { [string]$e['KnownIssue'] } else { '' }
    $hintSource = 'event'
    # Step 0.41 in error is the stop of the device-ID Arc name problem even when the run matched no known issue (the failing
    # step it names may be a child, 0.41.2).
    if (-not $knownId -and $Name -eq 'deployment' -and ($status -in 'failed', 'timedout', 'refused') -and @($steps | Where-Object { $_.Id -eq '0.41' -and $_.Status -eq 'error' }).Count) {
        $knownId = 'arc-device-id-name-step-0-41'; $hintSource = 'step'
    }
    $hint = Get-AzlSonarArmHintFor -Id $knownId
    $preventive = $null
    $naming = @($items | Where-Object { $_.Name -eq 'ArcMachineNaming' -and $_.Result -in 'Warning', 'Failed' })
    if ($naming.Count -and $null -eq $hint) {
        $preventive = Get-AzlSonarArmHintFor -Id 'arc-device-id-name'
        $preventive['nodes'] = @($naming | ForEach-Object { [string]$_.Node } | Where-Object { $_ -and $_ -ne '*' })
    }

    $steps = @($steps)
    $stepTree = @(ConvertTo-AzlSonarArmStepTree -Step $steps -FailingStep $(if ($null -ne $failing) { $failing.step } else { '' }) -Hint $hint -Now $Now)
    if ($Name -eq 'validation') {
        $failedRoots = @($stepTree | Where-Object { Test-AzlSonarArmItemFailed $_ })
        $okRoots = @($stepTree | Where-Object { -not (Test-AzlSonarArmItemFailed $_) })
        $stepTree = @($failedRoots) + @($okRoots)
    }
    $stepCounts = [ordered]@{ total = $steps.Count; success = 0; running = 0; error = 0; skipped = 0; unknown = 0 }
    foreach ($s in $steps) { if ($stepCounts.Contains([string]$s.Status)) { $stepCounts[[string]$s.Status]++ } }
    $current = $null
    $runningSteps = @($steps | Where-Object { $_.Status -eq 'running' })
    if ($runningSteps.Count) { $r = $runningSteps[$runningSteps.Count - 1]; $current = [ordered]@{ step = [string]$r.Id; name = (Protect-AzlSonarText -Text ([string]$r.Name)) } }

    $tree = [System.Collections.Generic.List[object]]::new()
    if ($ordered.Count) {
        $checkKids = @($ordered | ForEach-Object { ConvertTo-AzlSonarArmCheckItem -Check $_ })
        $groupStatus = if ($failedChecks) { 'error' } else { 'success' }
        $groupText = "$passedChecks passed" + $(if ($failedChecks) { ", $failedChecks failed" }) + $(if ($warnChecks) { ", $warnChecks with a warning" }) + $(if ($skippedChecks) { ", $skippedChecks skipped" })
        $tree.Add([ordered]@{
                id = "$Name.checks"; name = "Checks before $label"; description = $groupText; status = $groupStatus; rawStatus = ''
                start = $null; end = $null; durationSeconds = $null; errors = @(); children = $checkKids
                arm = [ordered]@{ kind = 'group'; group = 'checks'; hint = '' }
            })
    }
    if ($stepTree.Count) {
        $groupStatus = if ($stepCounts.error) { 'error' } elseif ($stepCounts.running) { 'running' } elseif ($status -eq 'passed') { 'success' } else { 'running' }
        $groupText = if ($Name -eq 'validation') { "$($stepCounts.total) reported, failures first" } else { "$($stepCounts.total) reported, in order" }
        $tree.Add([ordered]@{
                id = "$Name.steps"; name = $(if ($Name -eq 'validation') { 'Validation results' } else { 'Deployment steps' }); description = $groupText; status = $groupStatus; rawStatus = ''
                start = $null; end = $null; durationSeconds = $null; errors = @(); children = $stepTree
                arm = [ordered]@{ kind = 'group'; group = 'steps'; hint = '' }
            })
    }

    $started = if ($null -ne $e) { $e['Started'] } else { $null }
    $completed = if ($null -ne $e) { $e['Completed'] } else { $null }
    $elapsed = $null
    if ($null -ne $started) {
        if ($null -ne $completed) { $elapsed = ConvertTo-AzlSonarArmSeconds $started $completed }
        elseif ($status -eq 'running') { $elapsed = ConvertTo-AzlSonarArmSeconds $started $Now }
    }
    $message = if ($null -ne $e) { Protect-AzlSonarText -Text ([string]$e['Message']) } else { '' }
    $nextAction = if ($null -ne $e) { Protect-AzlSonarText -Text ([string]$e['NextAction']) } else { '' }
    $refusedOut = $null
    if ($null -ne $e -and $null -ne $e['Refused']) { $refusedOut = [ordered]@{ message = (Protect-AzlSonarText -Text ([string]$e['Refused'].Message)); nextAction = (Protect-AzlSonarText -Text ([string]$e['Refused'].NextAction)); knownIssue = [string]$e['Refused'].KnownIssue } }
    if ($status -in 'blocked', 'checking', 'planned' -and $null -eq $e) {
        if ($null -ne $Run -and $Run['Message'] -and $slotSeq -eq $runSeq) { $message = Protect-AzlSonarText -Text ([string]$Run['Message']); $nextAction = Protect-AzlSonarText -Text ([string]$Run['NextAction']) }
        if ($status -eq 'blocked' -and -not $nextAction) {
            $firstFailed = @($ordered | Where-Object { $_.Result -eq 'Failed' } | Select-Object -First 1)
            if ($firstFailed.Count) { $nextAction = Protect-AzlSonarText -Text ([string]$firstFailed[0].NextAction); if (-not $message) { $message = "$failedChecks check$(if ($failedChecks -ne 1) { 's' }) failed: $(@($ordered | Where-Object { $_.Result -eq 'Failed' } | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ')." } }
        }
    }

    $text = switch ($status) {
        'notstarted' { 'Not started' }
        'checking' { "Checking before $label" }
        'planned' { "Plan ready: $($items.Count) check$(if ($items.Count -ne 1) { 's' }), none failed" }
        'blocked' { "Blocked: $failedChecks check$(if ($failedChecks -ne 1) { 's' }) failed, nothing was submitted" }
        'running' { $(if ($Name -eq 'validation') { 'Validating' } else { 'Deploying' }) + $(if ($null -ne $resumed) { ' (resumed)' } else { '' }) }
        'passed' { $(if ($Name -eq 'validation') { 'Validation passed' + $(if ($skipped) { ' (already validated with these parameters)' } else { '' }) } else { 'Deployment succeeded' + $(if ($null -ne $resumed -and $resumed.previous -eq 'Succeeded') { ' (already deployed)' } else { '' }) }) }
        'failed' { "$(if ($Name -eq 'validation') { 'Validation' } else { 'Deployment' }) failed" + $(if ($null -ne $failing) { " at step $($failing.step) $($failing.name)".TrimEnd() } else { '' }) }
        'timedout' { "$(if ($Name -eq 'validation') { 'Validation' } else { 'Deployment' }) timed out; Azure is still working" }
        'refused' { "$label was not started: $message" }
    }

    return [ordered]@{
        name           = $Name
        label          = $label
        status         = $status
        kind           = $kind
        text           = $text
        started        = $(if ($null -ne $started) { [string]$started } else { $null })
        completed      = $(if ($null -ne $completed) { [string]$completed } else { $null })
        elapsedSeconds = $elapsed
        deploymentName = $(if ($null -ne $e) { [string]$e['DeploymentName'] } else { '' })
        submitted      = $(if ($null -ne $e -and $null -ne $e['Submitted']) { [string]$e['Submitted'] } else { $null })
        attached       = [bool]($null -ne $e -and -not $skipped -and $null -eq $e['Submitted'] -and $steps.Count -gt 0 -and $null -eq $resumed)
        skipped        = $skipped
        resumed        = $resumed
        carriedOver    = [bool]($null -ne $e -and $e['CarriedOver'])
        runId          = $(if ($null -ne $e) { [string]$e['RunId'] } else { '' })
        checkCounts    = [ordered]@{ total = $items.Count; failed = $failedChecks; warning = $warnChecks; skipped = $skippedChecks; passed = $passedChecks }
        stepCounts     = $stepCounts
        current        = $current
        failing        = $failing
        knownIssue     = $knownId
        hint           = $hint
        hintSource     = $(if ($null -ne $hint) { $hintSource } else { '' })
        preventiveHint = $preventive
        refused        = $refusedOut
        message        = $message
        nextAction     = $nextAction
        pollErrors     = $(if ($null -ne $e) { [int]$e['PollErrors'] } else { 0 })
        pollError      = $(if ($null -ne $e) { Protect-AzlSonarText -Text ([string]$e['PollError']) } else { '' })
        tree           = $tree.ToArray()
    }
}

function Get-AzlSonarArmState {
    <#
    .SYNOPSIS
        The arm object of /api/state, from the ARM event store: the run, the validation and the deployment.
    .DESCRIPTION
        { configured, hasData, status (notstarted|running|success|error), state (waiting, checking, planned, validating,
        validated, awaitingapproval, deploying, deployed, failed), activePhase (validation|deployment|''), run{runId, mode,
        cluster, started, completed, exitCode, state, finalState, template, parameterHash, schemaVersion, lastEventAt, events,
        message, nextAction, failed, planned, offline, approval{mode, requested, granted}}, validation{...}, deployment{...},
        hints[], warnings[] } (the phases: Get-AzlSonarArmPhaseState). The active phase is the deployment once a deploy run
        (or its checks) is newer than the validation; Sonar uses it to pick the mode it shows. Nothing here changes the
        Azure-reported validation or deployment trees: those stay as they are.
    .PARAMETER Store
        Shared.ArmEvents (Add-AzlSonarArmEvent).
    .PARAMETER Config
        A config object; armEventsPath says whether the event file is followed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Store,

        [Parameter(Mandatory)]
        [object]$Config,

        [datetime]$Now = [datetime]::UtcNow
    )

    $configured = [bool][string](Get-AzlSonarMember $Config 'armEventsPath' '')
    $run = $null; $vEntry = $null; $dEntry = $null; $checks = $null
    if ($null -ne $Store) {
        $run = Get-AzlSonarArmEntry -Store $Store -Key $script:AzlSonarArmRunKey
        $vEntry = Get-AzlSonarArmEntry -Store $Store -Key $script:AzlSonarArmValidationKey
        $checks = Get-AzlSonarArmEntry -Store $Store -Key $script:AzlSonarArmChecksKey
        $dEntry = Get-AzlSonarArmEntry -Store $Store -Key $script:AzlSonarArmDeploymentKey
    }
    $validation = Get-AzlSonarArmPhaseState -Name validation -Entry $vEntry -Checks $checks -Run $run -Now $Now
    $deployment = Get-AzlSonarArmPhaseState -Name deployment -Entry $dEntry -Checks $checks -Run $run -Now $Now
    $hasData = $null -ne $run

    # The phase to watch: the deployment when it, or its checks, came at or after the validation.
    $seqOf = {
        param($entry, $slotName)
        $s = -1
        if ($null -ne $entry) { $s = [int]$entry['Seq'] }
        if ($null -ne $checks -and $checks.ContainsKey($slotName)) { $s = [math]::Max($s, [int]$checks[$slotName]['Seq']) }
        $s
    }
    $vSeq = & $seqOf $vEntry 'validate'
    $dSeq = & $seqOf $dEntry 'deploy'
    $activePhase = ''
    if ($dSeq -ge 0 -and $dSeq -ge $vSeq) { $activePhase = 'deployment' }
    elseif ($vSeq -ge 0) { $activePhase = 'validation' }
    $active = switch ($activePhase) { 'deployment' { $deployment } 'validation' { $validation } default { $null } }

    $approval = $null
    if ($null -ne $run -and $null -ne $run['Approval']) {
        $a = $run['Approval']
        $approval = [ordered]@{ mode = [string]$a['Mode']; requested = [bool]($a.ContainsKey('RequestedAt')); granted = [bool]($a.ContainsKey('Granted') -and $a['Granted']) }
    }
    $awaiting = $null -ne $run -and $run['State'] -eq 'AwaitingApproval' -and -not ($null -ne $approval -and $approval.granted)

    $word = 'waiting'; $status = 'notstarted'
    if ($hasData) {
        $word = 'checking'
        if ($null -ne $active) {
            $status = $active.kind
            $word = switch ($active.status) {
                'notstarted' { 'waiting' }
                'checking' { 'checking' }
                'planned' { 'planned' }
                { $_ -in 'blocked', 'failed', 'timedout', 'refused' } { 'failed' }
                'running' { if ($activePhase -eq 'validation') { 'validating' } else { 'deploying' } }
                'passed' { if ($activePhase -eq 'validation') { if ($awaiting) { 'awaitingapproval' } else { 'validated' } } else { 'deployed' } }
            }
        }
        elseif ($run['Failed']) { $status = 'error'; $word = 'failed' }
    }
    $hints = [System.Collections.Generic.List[object]]::new()
    foreach ($ph in @($validation, $deployment)) {
        if ($null -ne $ph.hint) { $hints.Add([ordered]@{ id = $ph.hint.id; title = $ph.hint.title; text = $ph.hint.text; phase = $ph.name; preventive = $false; step = $(if ($null -ne $ph.failing) { $ph.failing.step } else { '' }) }) }
        elseif ($null -ne $ph.preventiveHint) { $hints.Add([ordered]@{ id = $ph.preventiveHint.id; title = $ph.preventiveHint.title; text = $ph.preventiveHint.text; phase = $ph.name; preventive = $true; step = '0.41' }) }
    }
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($ph in @($validation, $deployment)) {
        if ($ph.pollErrors -gt 0) { $warnings.Add("$($ph.label): $($ph.pollError)") }
    }
    if ($hasData -and $run['Failed']) { $warnings.Add('The ARM run failed: ' + (Protect-AzlSonarText -Text ([string]$run['Message']))) }

    return [ordered]@{
        configured  = $configured
        hasData     = [bool]$hasData
        status      = $status
        state       = $word
        activePhase = $activePhase
        awaitingApproval = [bool]$awaiting
        run         = [ordered]@{
            runId         = $(if ($hasData) { [string]$run['RunId'] } else { '' })
            mode          = $(if ($hasData) { [string]$run['Mode'] } else { '' })
            cluster       = $(if ($hasData) { [string]$run['Cluster'] } else { '' })
            started       = $(if ($hasData) { [string]$run['Started'] } else { $null })
            completed     = $(if ($hasData -and $null -ne $run['Completed']) { [string]$run['Completed'] } else { $null })
            exitCode      = $(if ($hasData -and $null -ne $run['ExitCode']) { [int]$run['ExitCode'] } else { $null })
            state         = $(if ($hasData) { [string]$run['State'] } else { '' })
            finalState    = $(if ($hasData) { [string]$run['FinalState'] } else { '' })
            template      = $(if ($hasData) { [string]$run['Template'] } else { '' })
            parameterHash = $(if ($hasData) { [string]$run['ParameterHash'] } else { '' })
            schemaVersion = $(if ($hasData) { [string]$run['SchemaVersion'] } else { '' })
            lastEventAt   = $(if ($hasData) { [string]$run['LastEventAt'] } else { $null })
            events        = $(if ($hasData) { [int]$run['Events'] } else { 0 })
            message       = $(if ($hasData) { Protect-AzlSonarText -Text ([string]$run['Message']) } else { '' })
            nextAction    = $(if ($hasData) { Protect-AzlSonarText -Text ([string]$run['NextAction']) } else { '' })
            failed        = [bool]($hasData -and $run['Failed'])
            planned       = [bool]($hasData -and $run['PlanCompleted'])
            offline       = [bool]($hasData -and $run['Offline'])
            approval      = $approval
        }
        validation  = $validation
        deployment  = $deployment
        hints       = $hints.ToArray()
        warnings    = $warnings.ToArray()
        guide       = $script:AzlSonarArmGuide
    }
}
