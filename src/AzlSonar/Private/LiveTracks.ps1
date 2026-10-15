Set-StrictMode -Version Latest

# Hardening 2610, gaps 4 and 5.
#
# Gap 4 (S-14): Azure lags behind the node. Right after Deploy starts, and after a failed attempt until the new ARM
# deployment rewrites it, deploymentSettings still shows the previous state. This file reads what else is known
#   - the newest running ARM deployment in the resource group (Microsoft.Resources/deployments),
#   - the node log as the tailer received it (the role:interface that runs now, the Environment Checker files),
# and labels the mismatch instead of hiding it. It also says which stage of Deploy mode is running: Learn (12.2609, latest):
# "a limited Environment Checker run, a full Environment Checker run, and cloud deployment starts".
#
# Gap 5 (S-13): the update track. clusters/updateSummaries (overall state), clusters/updates (the update that installs)
# and clusters/updates/updateRuns (the step tree of a run), read-only, from the Learn REST/template reference only:
# the whole track is marked "unverified against a live run" in the state, the page and the docs.

$script:AzlSonarArmDeploymentsApiVersion = '2021-04-01'
$script:AzlSonarRoleInterfacePattern = '\[(?<role>[A-Za-z][A-Za-z0-9]*):(?<interface>[A-Za-z][A-Za-z0-9]*)\]'
$script:AzlSonarActiveUpdateStates = @('Preparing', 'Installing', 'HealthChecking', 'Downloading', 'ScanInProgress', 'ReadyToInstall', 'InstallationFailed', 'PreparationFailed', 'HealthCheckFailed', 'DownloadFailed', 'ScanFailed')

function Get-AzlSonarLogHintFromLine {
    <#
    .SYNOPSIS
        What the newest node log lines say about the run: the role:interface that executes now and which Environment Checker files wrote.
    .DESCRIPTION
        -Line are log line records (seq, time, received, file, text) oldest first. The role:interface is read from a
        "[Role:Interface]" fragment in the orchestrator logs (CloudDeployment*, Lcm_Controller_*); the Environment Checker
        runs from the file names (EnvironmentValidatorFull* is the full run, AzStackHciEnvironmentChecker* and other
        EnvironmentValidator* files are the limited run). File names were seen on a live 12.2609 run; Learn names none.
    .OUTPUTS
        { roleInterface, role, interface, file, at, deployActive, limitedSeen, fullSeen, checkerAt }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Line = @()
    )

    $hint = [ordered]@{ roleInterface = $null; role = $null; interface = $null; file = $null; at = $null; deployActive = $false; limitedSeen = $false; fullSeen = $false; checkerAt = $null }
    foreach ($entry in @($Line)) {
        if ($null -eq $entry) { continue }
        $file = [string](Get-AzlSonarMember $entry 'file' '')
        $name = [System.IO.Path]::GetFileName($file.Replace('\', '/'))
        $at = [string](Get-AzlSonarMember $entry 'time' '')
        if (-not $at) { $at = [string](Get-AzlSonarMember $entry 'received' '') }
        if ($name -match '^EnvironmentValidatorFull') { $hint.fullSeen = $true; $hint.checkerAt = $at }
        elseif ($name -match '^(AzStackHciEnvironmentChecker|EnvironmentValidator)') { $hint.limitedSeen = $true; $hint.checkerAt = $at }
        if ($name -match '^(CloudDeployment|Lcm_Controller_Start_Deployment|Lcm_Controller)') {
            $m = [regex]::Match([string](Get-AzlSonarMember $entry 'text' ''), $script:AzlSonarRoleInterfacePattern)
            if ($m.Success) {
                $hint.roleInterface = '{0}:{1}' -f $m.Groups['role'].Value, $m.Groups['interface'].Value
                $hint.role = $m.Groups['role'].Value
                $hint.interface = $m.Groups['interface'].Value
                $hint.file = $name
                $hint.at = $at
                if ($name -match '^(Lcm_Controller_Start_Deployment|CloudDeployment)') { $hint.deployActive = $true }
            }
        }
    }
    return $hint
}

function Get-AzlSonarLogHint {
    <#
    .SYNOPSIS
        The log hint for the poller, from the newest lines in the shared ring buffer (read-only).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [int]$Window = 600
    )

    $since = [Math]::Max([long]0, [long]$Shared.LogSeq - $Window)
    $lines = (Get-AzlSonarLogWindow -Shared $Shared -Since $since -Max $Window).Lines
    return Get-AzlSonarLogHintFromLine -Line $lines
}

function Get-AzlSonarRunningArmDeployment {
    <#
    .SYNOPSIS
        The newest ARM deployment of the resource group that is still running, best effort (read-only GET, errors ignored).
    .OUTPUTS
        { name, timestamp, mode } or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    try {
        $rgPath = Get-AzlSonarResourceGroupPath -Config $Config
        $path = '{0}/providers/Microsoft.Resources/deployments/?api-version={1}&$filter=provisioningState eq ''Running''' -f $rgPath, $script:AzlSonarArmDeploymentsApiVersion
        $response = Invoke-AzlSonarArmGet -Path $path
        if ($response.StatusCode -ne 200) { return $null }
        $best = $null
        foreach ($item in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $response.Body 'value'))) {
            $state = [string](Get-AzlSonarMember $item 'properties.provisioningState' '')
            if ($state -notin 'Running', 'Accepted') { continue }
            $stamp = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $item 'properties.timestamp')
            if ($null -eq $stamp) { continue }
            if ($null -eq $best -or $stamp -gt $best.stamp) { $best = @{ stamp = $stamp; name = [string](Get-AzlSonarMember $item 'name' ''); mode = [string](Get-AzlSonarMember $item 'properties.mode' '') } }
        }
        if ($null -eq $best) { return $null }
        return [ordered]@{ name = $best.name; timestamp = Format-AzlSonarDate $best.stamp; mode = $best.mode }
    }
    catch {
        Write-Verbose "ARM deployment list failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-AzlSonarEnvironmentCheckerStage {
    <#
    .SYNOPSIS
        Which part of Deploy mode runs now: the limited Environment Checker, the full one, or cloud deployment.
    .DESCRIPTION
        Learn (12.2609, latest): once Deploy mode starts, "there's a limited Environment Checker run, a full Environment
        Checker run, and cloud deployment starts". Azure reports no step for the two checks, so the stage comes from the
        deployment step tree (any step = cloud deployment) and the node log files (see Get-AzlSonarLogHintFromLine).
        stage: none | validate | starting | limited | full | cloud-deployment. source says where it was read.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][string]$Mode,
        [AllowNull()][AllowEmptyCollection()][object[]]$DeploymentTree = @(),
        [AllowNull()][string]$DeploymentStatus,
        [AllowNull()][string]$ProvisioningState,
        [AllowNull()][System.Collections.IDictionary]$LogHint
    )

    $result = [ordered]@{ stage = 'none'; label = ''; source = $null; verified = $false }
    if ($Mode -ne 'Deploy') {
        if ($Mode -eq 'Validate') { $result.stage = 'validate'; $result.label = 'Validate mode: the Environment Checker runs as part of Validate. Deploy mode runs a limited, then a full Environment Checker.' }
        return $result
    }
    $steps = ConvertTo-AzlSonarArray $DeploymentTree
    $terminal = $DeploymentStatus -in 'success', 'error'
    if ($steps.Count -gt 0) {
        $result.stage = 'cloud-deployment'
        $result.label = if ($terminal) { 'Cloud deployment finished' } else { 'Cloud deployment (the limited and full Environment Checker runs are done)' }
        $result.source = 'Azure steps'
        return $result
    }
    if ($ProvisioningState -in 'Failed', 'Canceled', 'Succeeded') { return $result }
    $hintFull = $null -ne $LogHint -and [bool]$LogHint['fullSeen']
    $hintLimited = $null -ne $LogHint -and [bool]$LogHint['limitedSeen']
    if ($null -ne $LogHint -and [bool]$LogHint['deployActive']) {
        $result.stage = 'cloud-deployment'
        $result.label = 'Cloud deployment has started on the seed node (the checker runs are done); Azure has not reported a step yet'
        $result.source = 'node log'
    }
    elseif ($hintFull) {
        $result.stage = 'full'
        $result.label = 'Full Environment Checker run (after the limited run; cloud deployment starts next)'
        $result.source = 'node log'
    }
    elseif ($hintLimited) {
        $result.stage = 'limited'
        $result.label = 'Limited Environment Checker run (then the full run, then cloud deployment)'
        $result.source = 'node log'
    }
    else {
        $result.stage = 'starting'
        $result.label = 'Deploy mode started: a limited Environment Checker run, then a full one, then cloud deployment (Learn). Azure shows no step for them yet.'
        $result.source = 'Learn'
    }
    return $result
}

function Get-AzlSonarLagStatus {
    <#
    .SYNOPSIS
        Detects and labels a stale Azure state: deploymentSettings behind the node log, or behind a newer ARM deployment.
    .DESCRIPTION
        kinds:
          deploy-not-reported  Mode Deploy, no deployment step in Azure yet, but the seed node log shows the orchestrator
                               running a role:interface (shown as the live step, marked "from node log").
          rerun-pending        An ARM deployment is Running and newer than the last write to deploymentSettings: the steps
                               shown are from the previous attempt (validating / re-validating or deploying again).
        Both are read from sources other than the deployment steps; neither was verified against a live 12.2609 run end to end
        (the first was seen live on 11 Oct: deploymentSettings said Deploy not started while the seed node ran
        BareMetal:EnableWindowsFeaturesForDeployment).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][string]$Mode,
        [AllowNull()][AllowEmptyCollection()][object[]]$DeploymentTree = @(),
        [AllowNull()][string]$ProvisioningState,
        [AllowNull()][string]$SettingsModifiedAt,
        [AllowNull()][System.Collections.IDictionary]$LogHint,
        [AllowNull()][System.Collections.IDictionary]$ArmDeployment,
        [datetime]$Now = [datetime]::UtcNow,
        [int]$FreshSeconds = 300
    )

    $result = [ordered]@{ detected = $false; kind = $null; message = $null; source = $null; nodeStep = $null; since = $null; verified = $false }
    $nowUtc = $Now.ToUniversalTime()

    # A newer ARM deployment is the strongest sign: the portal itself shows the old result until it is rewritten.
    if ($null -ne $ArmDeployment) {
        $started = ConvertTo-AzlSonarUtcDate $ArmDeployment['timestamp']
        $modified = ConvertTo-AzlSonarUtcDate $SettingsModifiedAt
        if ($null -ne $started -and ($null -eq $modified -or $started -gt $modified)) {
            $what = if ($Mode -eq 'Deploy') { 'a new deployment' } elseif ($Mode -eq 'Validate') { 'a new validation' } else { 'a new validation or deployment' }
            $when = Format-AzlSonarDate $started
            $result.detected = $true
            $result.kind = 'rerun-pending'
            $result.source = 'ARM deployment'
            $result.since = $when
            $result.message = "An ARM deployment started at $when is still running in Azure ($what). The steps below are from the previous attempt until Azure rewrites them."
            return $result
        }
    }

    $steps = ConvertTo-AzlSonarArray $DeploymentTree
    if ($Mode -eq 'Deploy' -and $steps.Count -eq 0 -and $ProvisioningState -notin 'Failed', 'Canceled', 'Succeeded' -and $null -ne $LogHint -and $LogHint['roleInterface']) {
        $at = ConvertTo-AzlSonarUtcDate $LogHint['at']
        $fresh = $null -ne $at -and ($nowUtc - $at).TotalSeconds -le $FreshSeconds -and ($nowUtc - $at).TotalSeconds -ge -600
        if ($fresh -and [bool]$LogHint['deployActive']) {
            $result.detected = $true
            $result.kind = 'deploy-not-reported'
            $result.source = 'node log'
            $result.nodeStep = [string]$LogHint['roleInterface']
            $result.since = Format-AzlSonarDate $at
            $result.message = "Azure still shows Deploy not started, but the seed node is running $($LogHint['roleInterface']) (from the node log, $(Format-AzlSonarDate $at)). Azure usually catches up within minutes."
        }
    }
    return $result
}

function ConvertTo-AzlSonarUpdateStep {
    <#
    .SYNOPSIS
        Adapts an update run Step (name, description, status, startTimeUtc, endTimeUtc, errorMessage, steps[]) to the raw step
        shape the step tree converter reads (fullStepIndex, exception[]).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Step,
        [Parameter(Mandatory)][string]$Id
    )

    $children = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($child in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $Step 'steps'))) {
        $i++
        $children.Add((ConvertTo-AzlSonarUpdateStep -Step $child -Id ('{0}.{1}' -f $Id, $i)))
    }
    $message = [string](Get-AzlSonarMember $Step 'errorMessage' '')
    $status = [string](Get-AzlSonarMember $Step 'status' '')
    return [pscustomobject]@{
        name          = Get-AzlSonarMember $Step 'name'
        description   = Get-AzlSonarMember $Step 'description'
        fullStepIndex = $Id
        startTimeUtc  = Get-AzlSonarMember $Step 'startTimeUtc'
        endTimeUtc    = Get-AzlSonarMember $Step 'endTimeUtc'
        # 'Unknown status' is Learn's literal for a step with no status yet.
        status        = $(if ($status -match '^unknown') { $null } else { $status })
        exception     = $(if ($message) { @($message) } else { @() })
        steps         = $children.ToArray()
    }
}

function ConvertTo-AzlSonarUpdateSummary {
    <#
    .SYNOPSIS
        The cluster-level update summary (clusters/updateSummaries/default) as Sonar shows it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][object]$Properties)

    $checks = ConvertTo-AzlSonarArray (Get-AzlSonarMember $Properties 'healthCheckResult')
    $failed = @($checks | Where-Object { [string](Get-AzlSonarMember $_ 'status' '') -match 'Failed|Error' -or [string](Get-AzlSonarMember $_ 'severity' '') -eq 'Critical' })
    return [ordered]@{
        state             = [string](Get-AzlSonarMember $Properties 'state' '')
        healthState       = [string](Get-AzlSonarMember $Properties 'healthState' '')
        currentVersion    = [string](Get-AzlSonarMember $Properties 'currentVersion' '')
        currentSbeVersion = [string](Get-AzlSonarMember $Properties 'currentSbeVersion' '')
        currentOemVersion = [string](Get-AzlSonarMember $Properties 'currentOemVersion' '')
        hardwareModel     = [string](Get-AzlSonarMember $Properties 'hardwareModel' '')
        oemFamily         = [string](Get-AzlSonarMember $Properties 'oemFamily' '')
        lastChecked       = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $Properties 'lastChecked'))
        lastUpdated       = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $Properties 'lastUpdated'))
        failedChecks      = @($failed | Select-Object -First 5 | ForEach-Object {
                [ordered]@{
                    title       = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $_ 'title' (Get-AzlSonarMember $_ 'displayName' '')))
                    severity    = [string](Get-AzlSonarMember $_ 'severity' '')
                    remediation = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $_ 'remediation' ''))
                }
            })
    }
}

function Get-AzlSonarUpdateStatusFromState {
    <#
    .SYNOPSIS
        Rolls an update state (clusters/updates properties.state or updateSummaries properties.state) up to notstarted, running, success or error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$State)

    switch -Regex ($State) {
        '^(Preparing|Installing|HealthChecking|Downloading|ScanInProgress|UpdateInProgress|PreparationInProgress)$' { return 'running' }
        'Failed$|^NeedsAttention$' { return 'error' }
        '^(Installed|AppliedSuccessfully)$' { return 'success' }
        default { return 'notstarted' }
    }
}

function Get-AzlSonarUpdateState {
    <#
    .SYNOPSIS
        The update track: the cluster update summary, the update that installs or last failed, and its newest run as a step tree.
    .DESCRIPTION
        Three read-only GETs, all best effort (404 means the cluster has no update service data yet, for example during
        deployment, and returns an idle track): clusters/updateSummaries/default, clusters/updates and, for the update that
        is installing (or failed), clusters/updates/{name}/updateRuns. Shapes come from the Learn template reference
        (api-version 2026-10-01); nothing here was run against a live cluster, and the result says verified = $false.
    .OUTPUTS
        { verified, status, phase, summary, active { name, version, displayName, state }, run { name, status, timeStarted, duration, lastUpdated, tree, counts }, tree, counts }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [datetime]$Now = [datetime]::UtcNow,

        [AllowNull()]
        [System.Collections.Generic.List[string]]$Warnings
    )

    $idle = [ordered]@{ verified = $false; status = 'notstarted'; phase = 'idle'; summary = $null; active = $null; run = $null; tree = @(); counts = (Measure-AzlSonarStepTree -Tree @()) }
    $clusterPath = '{0}/providers/Microsoft.AzureStackHCI/clusters/{1}' -f (Get-AzlSonarResourceGroupPath -Config $Config), [uri]::EscapeDataString($Config.clusterName)
    $version = [string](Get-AzlSonarMember $Config 'apiVersion' '2026-10-01')
    try {
        $summaryResponse = Invoke-AzlSonarArmGet -Path ('{0}/updateSummaries/default?api-version={1}' -f $clusterPath, $version)
        if ($summaryResponse.StatusCode -ne 200) { return $idle }
        $summary = ConvertTo-AzlSonarUpdateSummary -Properties (Get-AzlSonarMember $summaryResponse.Body 'properties')
        $idle.summary = $summary
        $summaryStatus = Get-AzlSonarUpdateStatusFromState $summary.state
        $idle.status = $summaryStatus
        $idle.phase = switch ($summary.state) {
            'UpdateInProgress' { 'installing' }
            'PreparationInProgress' { 'preparing' }
            'UpdateAvailable' { 'available' }
            'UpdateFailed' { 'failed' }
            'PreparationFailed' { 'failed' }
            'NeedsAttention' { 'attention' }
            default { 'idle' }
        }
        # The step tree is only worth reading while an update runs or has just failed.
        if ($summary.state -notin 'UpdateInProgress', 'PreparationInProgress', 'UpdateFailed', 'PreparationFailed', 'NeedsAttention') { return $idle }

        $updates = Invoke-AzlSonarArmGet -Path ('{0}/updates?api-version={1}' -f $clusterPath, $version)
        if ($updates.StatusCode -ne 200) { return $idle }
        $active = $null
        foreach ($item in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $updates.Body 'value'))) {
            $state = [string](Get-AzlSonarMember $item 'properties.state' '')
            if ($state -in $script:AzlSonarActiveUpdateStates -and $state -notin 'ReadyToInstall') {
                $active = $item
                break
            }
        }
        if ($null -eq $active) { return $idle }
        $name = [string](Get-AzlSonarMember $active 'name' '')
        $idle.active = [ordered]@{
            name        = $name
            version     = [string](Get-AzlSonarMember $active 'properties.version' '')
            displayName = [string](Get-AzlSonarMember $active 'properties.displayName' '')
            state       = [string](Get-AzlSonarMember $active 'properties.state' '')
            rebootRequired = [string](Get-AzlSonarMember $active 'properties.rebootRequired' '')
        }
        if (-not $name -or $name -notmatch '^[A-Za-z0-9._\-]+$') { return $idle }

        $runs = Invoke-AzlSonarArmGet -Path ('{0}/updates/{1}/updateRuns?api-version={2}' -f $clusterPath, [uri]::EscapeDataString($name), $version)
        if ($runs.StatusCode -ne 200) { return $idle }
        $newest = $null
        $newestStart = [datetime]::MinValue
        foreach ($run in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $runs.Body 'value'))) {
            $started = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $run 'properties.timeStarted')
            if ($null -eq $started) { $started = [datetime]::MinValue.AddSeconds(1) }
            if ($null -eq $newest -or $started -gt $newestStart) { $newest = $run; $newestStart = $started }
        }
        if ($null -eq $newest) { return $idle }
        $progress = Get-AzlSonarMember $newest 'properties.progress'
        $root = ConvertTo-AzlSonarUpdateStep -Step $progress -Id '1'
        $tree = @(ConvertTo-AzlSonarStepTree -StatusObject ([pscustomobject]@{ steps = @($root) }) -Now $Now)
        # The progress object is the root step of the run; show its children as the top-level steps when it has them.
        if ($tree.Count -eq 1 -and @($tree[0].children).Count -gt 0) { $tree = @($tree[0].children) }
        $runStatus = ConvertTo-AzlSonarStepStatus (Get-AzlSonarMember $progress 'status')
        if ($runStatus -in 'unknown', 'notstarted') { $runStatus = Get-AzlSonarRollupStatus -RawStatus (Get-AzlSonarMember $progress 'status') -Tree $tree }
        $idle.run = [ordered]@{
            name        = [string](Get-AzlSonarMember $newest 'name' '')
            status      = $runStatus
            timeStarted = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $newest 'properties.timeStarted'))
            duration    = [string](Get-AzlSonarMember $newest 'properties.duration' '')
            lastUpdated = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $newest 'properties.lastUpdatedTime'))
        }
        $idle.tree = $tree
        $idle.counts = Measure-AzlSonarStepTree -Tree $tree
        if ($runStatus -in 'running', 'error', 'success') { $idle.status = $runStatus }
    }
    catch {
        if ($null -ne $Warnings) { $Warnings.Add("Update track: $($_.Exception.Message)") }
    }
    return $idle
}
