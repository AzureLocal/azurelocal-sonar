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

$script:AzlSonarSbeContentGuide = 'https://learn.microsoft.com/azure/azure-local/update/solution-builder-extension?view=azloc-2610#the-additionalcontentrequired-update-state'
$script:AzlSonarUpdateFailureGuide = 'https://learn.microsoft.com/azure/azure-local/update/update-troubleshooting-23h2?view=azloc-2610#troubleshoot-update-failures'
# An Auto session that opens on a deployment that finished longer ago than this lands on the Update view when an update waits.
$script:AzlSonarOldDeploymentHours = 24

function Get-AzlSonarUpdateStateInfo {
    <#
    .SYNOPSIS
        What one update state (clusters/updates properties.state) means: { raw, kind, phase, level, word, nextAction }.
    .DESCRIPTION
        kind: running, failed, waiting (cannot start yet), ready, installed, ignored (superseded or not for this hardware) or unknown.
        phase is the update phase vocabulary of /api/state (installing, preparing, failed, waiting, available, idle). level is
        run, error, warn, ok or neutral. An unknown state keeps its raw word and is neutral, never green.
        States are from the Learn update-phases and REST reference; AdditionalContentRequired (SBE content to import) was
        seen on a live 12.2610 cluster.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][AllowEmptyString()][string]$State)

    $raw = [string]$State
    $info = [ordered]@{ raw = $raw; kind = 'unknown'; phase = 'idle'; level = 'neutral'; word = $(if ($raw) { $raw } else { 'Unknown' }); nextAction = $null }
    switch -Regex ($raw) {
        '^Installing$' { $info.kind = 'running'; $info.phase = 'installing'; $info.level = 'run'; $info.word = 'Installing' }
        '^Preparing$' { $info.kind = 'running'; $info.phase = 'preparing'; $info.level = 'run'; $info.word = 'Preparing' }
        '^Downloading$' { $info.kind = 'running'; $info.phase = 'preparing'; $info.level = 'run'; $info.word = 'Downloading' }
        '^HealthChecking$' { $info.kind = 'running'; $info.phase = 'preparing'; $info.level = 'run'; $info.word = 'Checking health' }
        '^ScanInProgress$' { $info.kind = 'running'; $info.phase = 'preparing'; $info.level = 'run'; $info.word = 'Scanning' }
        '^(InstallationFailed|PreparationFailed|HealthCheckFailed|DownloadFailed|ScanFailed)$' {
            $info.kind = 'failed'; $info.phase = 'failed'; $info.level = 'error'
            $info.word = switch ($raw) { 'InstallationFailed' { 'Installation failed' } 'PreparationFailed' { 'Preparation failed' } 'HealthCheckFailed' { 'Health check failed' } 'DownloadFailed' { 'Download failed' } default { 'Scan failed' } }
            $info.nextAction = [ordered]@{ text = 'Read the failing step and its error below. A failed update can be resumed from the Azure portal once the cause is fixed.'; guide = $script:AzlSonarUpdateFailureGuide }
        }
        '^AdditionalContentRequired$' {
            $info.kind = 'waiting'; $info.phase = 'waiting'; $info.level = 'warn'; $info.word = 'Waiting for content'
            $info.nextAction = [ordered]@{ text = 'The update package must be added (SBE side-load): the hardware vendor''s Solution Builder Extension files have to be downloaded and imported before this update can be prepared or installed. The Learn page explains how.'; guide = $script:AzlSonarSbeContentGuide }
        }
        '^HasPrerequisite$' {
            $info.kind = 'waiting'; $info.phase = 'waiting'; $info.level = 'warn'; $info.word = 'Needs another update first'
            $info.nextAction = [ordered]@{ text = 'Another update must be installed before this one.'; guide = $null }
        }
        '^(Ready|ReadyToInstall)$' {
            $info.kind = 'ready'; $info.phase = 'available'; $info.level = 'neutral'; $info.word = 'Ready to install'
            $info.nextAction = [ordered]@{ text = 'Ready to install. Sonar only watches: start the update from Azure.'; guide = $null }
        }
        '^(Installed|Succeeded)$' { $info.kind = 'installed'; $info.level = 'ok'; $info.word = 'Installed' }
        '^Obsolete$' { $info.kind = 'ignored'; $info.word = 'Superseded by a newer version' }
        '^Invalid$' { $info.kind = 'ignored'; $info.word = 'Does not match this hardware' }
        '^Recalled$' { $info.kind = 'ignored'; $info.word = 'Recalled' }
        '^NotApplicableBecauseAnotherUpdateIsInProgress$' { $info.kind = 'ignored'; $info.word = 'Held while another update runs' }
    }
    return $info
}

function ConvertTo-AzlSonarUpdateSummary {
    <#
    .SYNOPSIS
        The cluster-level update summary (clusters/updateSummaries/default) as Sonar shows it.
    .DESCRIPTION
        failedChecks lists the pre-update readiness checks that failed (healthCheckResult with a failed status), worst severity
        first, with checkCounts { total, failed, critical, error, warning, informational, other }. The severity decides what a
        check does to the Update tab: Critical and Error turn it red, Warning amber, Informational is only listed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][object]$Properties)

    $checks = ConvertTo-AzlSonarArray (Get-AzlSonarMember $Properties 'healthCheckResult')
    $failed = @($checks | Where-Object {
            $status = [string](Get-AzlSonarMember $_ 'status' '')
            $status -match 'Fail|Error' -or (-not $status -and [string](Get-AzlSonarMember $_ 'severity' '') -eq 'Critical')
        })
    $rank = @{ critical = 0; error = 1; warning = 2; informational = 3 }
    $counts = [ordered]@{ total = $checks.Count; failed = $failed.Count; critical = 0; error = 0; warning = 0; informational = 0; other = 0 }
    $items = foreach ($check in $failed) {
        $severity = [string](Get-AzlSonarMember $check 'severity' '')
        $key = $severity.ToLowerInvariant()
        if ($rank.ContainsKey($key)) { $counts[$key]++ } else { $counts.other++ }
        [pscustomobject]@{
            rank        = $(if ($rank.ContainsKey($key)) { $rank[$key] } else { 4 })
            title       = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $check 'title' (Get-AzlSonarMember $check 'displayName' (Get-AzlSonarMember $check 'name' ''))))
            severity    = $severity
            description = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $check 'description' ''))
            remediation = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $check 'remediation' ''))
        }
    }
    $sorted = @($items | Sort-Object -Property rank -Stable | Select-Object -First 25 | ForEach-Object {
            [ordered]@{ title = $_.title; severity = $_.severity; description = $_.description; remediation = $_.remediation }
        })
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
        checkCounts       = $counts
        failedChecks      = $sorted
    }
}

function Get-AzlSonarUpdateStatusFromState {
    <#
    .SYNOPSIS
        Rolls one update state (clusters/updates properties.state, or updateSummaries properties.state) up to notstarted, running, success or error.
    .DESCRIPTION
        The summary state AppliedSuccessfully is NOT success: it is what a cluster says before any update ever ran. Success
        needs a real update run (see Get-AzlSonarUpdateState); only an update whose own state is Installed rolls up to success here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$State)

    switch -Regex ($State) {
        '^(Preparing|Installing|HealthChecking|Downloading|ScanInProgress|UpdateInProgress|PreparationInProgress)$' { return 'running' }
        'Failed$|^NeedsAttention$' { return 'error' }
        '^(Installed|Succeeded)$' { return 'success' }
        default { return 'notstarted' }
    }
}

function Get-AzlSonarUpdateRunList {
    <#
    .SYNOPSIS
        The runs of one update (clusters/updates/{name}/updateRuns), newest first: { update, name, status, timeStarted, duration, lastUpdated, progress (raw) }.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$ClusterPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$UpdateName
    )

    if ($UpdateName -notmatch '^[A-Za-z0-9._\-]+$') { return @() }
    $response = Invoke-AzlSonarArmGet -Path ('{0}/updates/{1}/updateRuns?api-version={2}' -f $ClusterPath, [uri]::EscapeDataString($UpdateName), $Version)
    if ($response.StatusCode -ne 200) { return @() }
    $list = foreach ($run in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $response.Body 'value'))) {
        $started = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $run 'properties.timeStarted')
        $progress = Get-AzlSonarMember $run 'properties.progress'
        [pscustomobject]@{
            update      = $UpdateName
            name        = [string](Get-AzlSonarMember $run 'name' '')
            started     = $(if ($null -ne $started) { $started } else { [datetime]::MinValue.AddSeconds(1) })
            timeStarted = Format-AzlSonarDate $started
            duration    = [string](Get-AzlSonarMember $run 'properties.duration' '')
            lastUpdated = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $run 'properties.lastUpdatedTime'))
            rawStatus   = Get-AzlSonarMember $progress 'status'
            progress    = $progress
        }
    }
    return @($list | Sort-Object -Property started -Descending)
}

function Get-AzlSonarUpdateState {
    <#
    .SYNOPSIS
        The update track: what Azure offers, the update that installs (or last failed), its newest run as a step tree, the run history and the verdict.
    .DESCRIPTION
        Read-only GETs, all best effort (404 means the cluster has no update service data yet and returns an idle track):
        clusters/updateSummaries/default, clusters/updates and clusters/updates/{name}/updateRuns for the update that installs
        (or failed) or, when none does, for the newest installed updates (the history and the end state).
        Shapes come from the Learn template reference (api-version 2026-10-01); AdditionalContentRequired and the readiness
        failedChecks were seen on a live 12.2610 cluster. The result says verified = $false until a whole update was followed live.

        The verdict (status, level, label) never trusts the summary alone: AppliedSuccessfully is also what a cluster says
        before any update ever ran. status is success only when a real run finished Succeeded (or lastUpdated is set with an
        Installed update when Azure keeps no run) and the summary is AppliedSuccessfully. With no run and nothing installing the
        status is notstarted and the tab is neutral. level is the tab colour: error (a failed update, or a failed check of
        severity Critical or Error), run, warn (an update that cannot start yet, or a failed check of severity Warning),
        ok or neutral. A failed check of severity Informational is listed and never colours the tab.
    .OUTPUTS
        { verified, status, phase, level, label, ran, nextAction { text, guide }, summary, active, updates[], runs[], run, tree, counts }
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

    $result = [ordered]@{
        verified = $false; status = 'notstarted'; phase = 'idle'; level = 'neutral'; label = 'No update data from Azure yet'; ran = $false; nextAction = $null
        summary = $null; active = $null; updates = @(); runs = @(); run = $null; tree = @(); counts = (Measure-AzlSonarStepTree -Tree @())
    }
    $clusterPath = '{0}/providers/Microsoft.AzureStackHCI/clusters/{1}' -f (Get-AzlSonarResourceGroupPath -Config $Config), [uri]::EscapeDataString($Config.clusterName)
    $version = [string](Get-AzlSonarMember $Config 'apiVersion' '2026-10-01')
    try {
        $summaryResponse = Invoke-AzlSonarArmGet -Path ('{0}/updateSummaries/default?api-version={1}' -f $clusterPath, $version)
        if ($summaryResponse.StatusCode -ne 200) { return $result }
        $summary = ConvertTo-AzlSonarUpdateSummary -Properties (Get-AzlSonarMember $summaryResponse.Body 'properties')
        $result.summary = $summary
        $result.label = 'No update has run'

        # What Azure offers: every update the service knows, with what its state means.
        $items = @()
        $updatesResponse = Invoke-AzlSonarArmGet -Path ('{0}/updates?api-version={1}' -f $clusterPath, $version)
        if ($updatesResponse.StatusCode -eq 200) { $items = ConvertTo-AzlSonarArray (Get-AzlSonarMember $updatesResponse.Body 'value') }
        $offers = @(foreach ($item in $items) {
            $info = Get-AzlSonarUpdateStateInfo -State ([string](Get-AzlSonarMember $item 'properties.state' ''))
            $installed = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $item 'properties.installedDate')
            [pscustomobject]@{
                name = [string](Get-AzlSonarMember $item 'name' '')
                version = [string](Get-AzlSonarMember $item 'properties.version' '')
                displayName = [string](Get-AzlSonarMember $item 'properties.displayName' '')
                description = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $item 'properties.description' ''))
                packageType = [string](Get-AzlSonarMember $item 'properties.packageType' '')
                state = $info.raw
                stateWord = $info.word
                kind = $info.kind
                phase = $info.phase
                level = $info.level
                nextAction = $info.nextAction
                rebootRequired = [string](Get-AzlSonarMember $item 'properties.rebootRequired' '')
                availabilityType = [string](Get-AzlSonarMember $item 'properties.availabilityType' '')
                progressPercentage = Get-AzlSonarMember $item 'properties.progressPercentage'
                notifyMessage = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $item 'properties.notifyMessage' ''))
                installedDate = Format-AzlSonarDate $installed
                installed = $installed
            }
        })
        $kindOrder = @{ running = 0; failed = 1; waiting = 2; ready = 3; unknown = 4; ignored = 5; installed = 6 }
        $ordered = @($offers | Sort-Object -Property @{ Expression = { $kindOrder[$_.kind] } }, @{ Expression = { if ($null -ne $_.installed) { $_.installed } else { [datetime]::MinValue } }; Descending = $true } -Stable)
        $result.updates = @($ordered | Select-Object -First 20 | ForEach-Object {
                [ordered]@{
                    name = $_.name; version = $_.version; displayName = $_.displayName; description = $_.description; packageType = $_.packageType
                    state = $_.state; stateWord = $_.stateWord; phase = $_.phase; level = $_.level
                    nextAction = $_.nextAction; rebootRequired = $_.rebootRequired; availabilityType = $_.availabilityType
                    progressPercentage = $_.progressPercentage; notifyMessage = $_.notifyMessage; installedDate = $_.installedDate
                }
            })

        # The update that installs now, or the one that failed (a running update wins over a failed one).
        $active = $ordered | Where-Object { $_.kind -eq 'running' } | Select-Object -First 1
        if ($null -eq $active) { $active = $ordered | Where-Object { $_.kind -eq 'failed' } | Select-Object -First 1 }
        $waiting = $ordered | Where-Object { $_.kind -eq 'waiting' } | Select-Object -First 1
        $ready = $ordered | Where-Object { $_.kind -eq 'ready' } | Select-Object -First 1
        $installedUpdates = @($ordered | Where-Object { $_.kind -eq 'installed' })

        # Runs: those of the active update; with none, those of the newest installed updates (history and the end state).
        $runs = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $active) {
            $result.active = [ordered]@{ name = $active.name; version = $active.version; displayName = $active.displayName; state = $active.state; rebootRequired = $active.rebootRequired }
            foreach ($run in (Get-AzlSonarUpdateRunList -ClusterPath $clusterPath -Version $version -UpdateName $active.name)) { $runs.Add($run) }
        }
        else {
            foreach ($u in ($installedUpdates | Select-Object -First 3)) {
                foreach ($run in (Get-AzlSonarUpdateRunList -ClusterPath $clusterPath -Version $version -UpdateName $u.name)) { $runs.Add($run) }
            }
        }
        $sortedRuns = @($runs | Sort-Object -Property started -Descending)
        $newest = $sortedRuns | Select-Object -First 1
        $runStatus = 'notstarted'
        if ($null -ne $newest) {
            $root = ConvertTo-AzlSonarUpdateStep -Step $newest.progress -Id '1'
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject ([pscustomobject]@{ steps = @($root) }) -Now $Now)
            # The progress object is the root step of the run; show its children as the top-level steps when it has them.
            if ($tree.Count -eq 1 -and @($tree[0].children).Count -gt 0) { $tree = @($tree[0].children) }
            $runStatus = ConvertTo-AzlSonarStepStatus $newest.rawStatus
            if ($runStatus -in 'unknown', 'notstarted') { $runStatus = Get-AzlSonarRollupStatus -RawStatus $newest.rawStatus -Tree $tree }
            $result.run = [ordered]@{ name = $newest.name; update = $newest.update; status = $runStatus; timeStarted = $newest.timeStarted; duration = $newest.duration; lastUpdated = $newest.lastUpdated }
            $result.tree = $tree
            $result.counts = Measure-AzlSonarStepTree -Tree $tree
        }
        $result.runs = @($sortedRuns | Select-Object -First 10 | ForEach-Object {
                $st = ConvertTo-AzlSonarStepStatus $_.rawStatus
                [ordered]@{ name = $_.name; update = $_.update; status = $(if ($st -in 'unknown', 'notstarted') { 'unknown' } else { $st }); timeStarted = $_.timeStarted; duration = $_.duration; lastUpdated = $_.lastUpdated }
            })

        # Did an update ever run? A run is proof; lastUpdated together with an installed update is the other proof.
        $result.ran = ($sortedRuns.Count -gt 0) -or ([bool]$summary.lastUpdated -and $installedUpdates.Count -gt 0)

        # Status: only a real run or an update that is installing / failed moves it off notstarted.
        $summaryState = [string]$summary.state
        $status = 'notstarted'
        $phase = 'idle'
        if ($null -ne $active -and $active.kind -eq 'running') { $status = 'running'; $phase = $active.phase }
        elseif ($null -ne $active) { $status = 'error'; $phase = 'failed' }
        # A run left InProgress (an orphaned run) does not outvote an update that is Installed and a summary that says AppliedSuccessfully.
        elseif ($sortedRuns.Count -gt 0 -and $runStatus -eq 'running' -and $summaryState -ne 'AppliedSuccessfully') { $status = 'running'; $phase = 'installing' }
        elseif ($sortedRuns.Count -gt 0 -and $runStatus -eq 'error') { $status = 'error'; $phase = 'failed' }
        else {
            # The summary alone speaks only when the update list says nothing.
            switch ($summaryState) {
                'UpdateInProgress' { $status = 'running'; $phase = 'installing' }
                'PreparationInProgress' { $status = 'running'; $phase = 'preparing' }
                'UpdateFailed' { $status = 'error'; $phase = 'failed' }
                'PreparationFailed' { $status = 'error'; $phase = 'failed' }
                'NeedsAttention' { $status = 'error'; $phase = 'attention' }
            }
        }
        if ($status -eq 'notstarted') {
            if ($null -ne $waiting) { $phase = 'waiting' }
            elseif ($null -ne $ready -or $summaryState -eq 'UpdateAvailable') { $phase = 'available' }
            # The newest run says Succeeded; or Azure keeps no usable run (none, or a status Sonar cannot read) and lastUpdated is set with an installed update.
            $noUsableRun = $sortedRuns.Count -eq 0 -or $runStatus -in 'unknown', 'notstarted' -or ($runStatus -eq 'running' -and $summaryState -eq 'AppliedSuccessfully')
            $runSucceeded = ($sortedRuns.Count -gt 0 -and $runStatus -eq 'success') -or ($noUsableRun -and [bool]$summary.lastUpdated -and $installedUpdates.Count -gt 0)
            if ($runSucceeded -and $summaryState -eq 'AppliedSuccessfully' -and $phase -eq 'idle') { $status = 'success' }
        }
        $result.status = $status
        $result.phase = $phase

        # The tab colour: the worst of the update's own verdict and the failed checks, Informational checks never colour it.
        $counts = $summary.checkCounts
        $level = 'neutral'
        if ($status -eq 'error' -or $counts.critical -gt 0 -or $counts.error -gt 0 -or $summary.healthState -match '^(Failure|Failed|Critical|Error)$') { $level = 'error' }
        elseif ($status -eq 'running') { $level = 'run' }
        elseif ($phase -eq 'waiting' -or $counts.warning -gt 0 -or $summary.healthState -match 'Warning') { $level = 'warn' }
        elseif ($status -eq 'success') { $level = 'ok' }
        $result.level = $level

        $focus = if ($null -ne $active) { $active } elseif ($null -ne $waiting) { $waiting } elseif ($null -ne $ready) { $ready } else { $null }
        $label = switch ($phase) {
            'installing' { 'Installing' + $(if ($null -ne $active -and $active.version) { ' ' + $active.version } else { '' }) }
            'preparing' { 'Preparing the update' }
            'failed' { 'Update failed' }
            'attention' { 'Update needs attention' }
            'waiting' { $focus.stateWord }
            'available' { 'Update available' }
            default { $(if ($status -eq 'success') { 'Update succeeded' } else { 'No update has run' }) }
        }
        if ($status -eq 'success' -and $summary.currentVersion) { $label += ' (' + $summary.currentVersion + ')' }
        if ($level -eq 'error' -and $status -ne 'error') { $label = 'Readiness check failed' }
        elseif ($level -eq 'warn' -and $phase -eq 'idle' -and $status -ne 'success') { $label = 'Readiness warning' }
        $result.label = $label
        if ($null -ne $focus -and $focus.nextAction) { $result.nextAction = $focus.nextAction }
    }
    catch {
        if ($null -ne $Warnings) { $Warnings.Add("Update track: $($_.Exception.Message)") }
    }
    return $result
}

function Get-AzlSonarTreeEnd {
    <#
    .SYNOPSIS
        The latest end time (UTC) in a step tree, or $null when no step has one.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[datetime]])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Tree)

    $max = $null
    foreach ($node in (ConvertTo-AzlSonarArray $Tree)) {
        $end = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $node 'end')
        if ($null -ne $end -and ($null -eq $max -or $end -gt $max)) { $max = $end }
        $child = Get-AzlSonarTreeEnd -Tree (Get-AzlSonarMember $node 'children')
        if ($null -ne $child -and ($null -eq $max -or $child -gt $max)) { $max = $child }
    }
    return $max
}

function Resolve-AzlSonarUpdatePhase {
    <#
    .SYNOPSIS
        Whether the update track takes over the phase, and which: { phase, activePhase, follow }.
    .DESCRIPTION
        An update that installs or prepares makes the phase update; one that failed makes it failed (activePhase update). The
        standalone Update monitor is always on the update. In Auto, a deployment that finished more than
        $script:AzlSonarOldDeploymentHours ago (or whose end time is unknown) hands the page over to the Update view when an
        update waits for content or is ready; right after a deployment the page stays on Deployment. follow is true when the
        phase moved and the update step tree supplies the current step.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][object]$Update,
        [string]$Phase,
        [string]$ActivePhase,
        [switch]$Standalone,
        [AllowNull()][object]$DeploymentEnd,
        [datetime]$Now = [datetime]::UtcNow
    )

    $out = [ordered]@{ phase = $Phase; activePhase = $ActivePhase; follow = $false }
    if ($null -eq $Update) { return $out }
    if ($Update.status -eq 'running' -and $Update.phase -in 'installing', 'preparing') {
        $out.phase = 'update'; $out.activePhase = 'update'; $out.follow = $true
    }
    elseif ($Update.status -eq 'error' -and $Update.phase -in 'failed', 'attention') {
        $out.phase = 'failed'; $out.activePhase = 'update'; $out.follow = $true
    }
    elseif ($Standalone) {
        $out.phase = 'update'; $out.activePhase = 'update'; $out.follow = $true
    }
    elseif ($Phase -eq 'done' -and $Update.phase -in 'waiting', 'available') {
        $old = $null -eq $DeploymentEnd -or ($Now - [datetime]$DeploymentEnd).TotalHours -ge $script:AzlSonarOldDeploymentHours
        if ($old) { $out.phase = 'update'; $out.activePhase = 'update'; $out.follow = $true }
    }
    return $out
}

function Get-AzlSonarUpdateMonitorState {
    <#
    .SYNOPSIS
        The state of a standalone Update monitor (-Monitor Update): a cluster that is already running, updated weeks after its deployment.
    .DESCRIPTION
        Reads the cluster resource, the Arc machine of every node and the update track. It does not read deploymentSettings, the
        edge machines or any deployment, provisioning, ZTP, OS configuration or ARM event file, so no stale deployment tree
        appears and the config needs none of those keys. The phase is update (failed when the update failed).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Config,
        [datetime]$Now = [datetime]::UtcNow
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $state = Get-AzlSonarInitialState -Config $Config
    $targets = @(Resolve-AzlSonarArcTarget -Config $Config -Route 'oem-image' -EdgeMachines @())
    $state.nodes = @(Get-AzlSonarArcMachineStatus -Config $Config -Target $targets -Warnings $warnings)
    $resource = Get-AzlSonarClusterResource -Config $Config
    $state.clusterResource = Get-AzlSonarClusterObject -Config $Config -Resource $resource
    $state.provisioningState = [string]$state.clusterResource.provisioningState
    $update = Get-AzlSonarUpdateState -Config $Config -Now $Now -Warnings $warnings
    $move = Resolve-AzlSonarUpdatePhase -Update $update -Phase 'update' -ActivePhase 'update' -Standalone
    $state.phase = $move.phase
    $state.activePhase = $move.activePhase
    $state.update = $update
    $state.track = 'update'
    $state.current = Get-AzlSonarCurrentStep -Tree @($update.tree) -Phase 'update'
    $state.warnings = $warnings.ToArray()
    $state.polledAt = Format-AzlSonarDate $Now.ToUniversalTime()
    return $state
}
