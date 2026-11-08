Set-StrictMode -Version Latest

# Standalone monitors (Start-AzlSonar.ps1 -Monitor, or the monitor key of the config): Sonar can watch the whole flow (Auto)
# or just one stage of it. A single monitor shows only its own tile and section, reads only the sources it needs and lists
# only the log access it needs. Health is not a monitor: every machine card shows its Azure Arc status in every mode.

$script:AzlSonarMonitors = [ordered]@{
    Auto            = 'Auto'
    Discovery       = 'Discovery'
    Provisioning    = 'Provisioning'
    OsConfiguration = 'OsConfiguration'
    Validate        = 'Validate'
    Deployment      = 'Deployment'
    Update          = 'Update'
    AddNode         = 'AddNode'
    Repair          = 'Repair'
}

function Get-AzlSonarMonitorNameList {
    <#
    .SYNOPSIS
        The values -Monitor and the monitor key accept.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@($script:AzlSonarMonitors.Keys)
}

function Get-AzlSonarMonitorName {
    <#
    .SYNOPSIS
        The canonical monitor name for a value typed in any case (os-configuration, add-node and the like are accepted), or '' when it is none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Auto' }
    $key = $Value.Trim().ToLowerInvariant() -replace '[^a-z]', ''
    foreach ($name in $script:AzlSonarMonitors.Keys) { if ($name.ToLowerInvariant() -eq $key) { return $name } }
    return ''
}

function Get-AzlSonarMonitorPlan {
    <#
    .SYNOPSIS
        What a monitor needs: which sources are read and which log access is listed.
    .DESCRIPTION
        { monitor, standalone, azure (poll the Azure resources), ztpEvents, osConfigEvents, nodeProbe (OEM image route
        probes), tailer (the seed node's log), armEvents (the toolkit's ARM Validate and Deploy event file; Validate and Deployment only), discovery (the discovery files), phases (the log access phases listed) }.
        Auto is today's behaviour: everything. Discovery reads the discovery files only (no Azure sign-in, no node). Provisioning
        reads Azure and the ZTP event file. OsConfiguration reads the OS configuration event file (and the Arc run commands in
        Azure) but not the node logs. Validate, Deployment, Update, AddNode and Repair read the Azure resources of their
        operation and the seed node's log.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][AllowEmptyString()][string]$Monitor = 'Auto')

    $name = Get-AzlSonarMonitorName -Value $Monitor
    if (-not $name) { $name = 'Auto' }
    $plan = [ordered]@{ monitor = $name; standalone = ($name -ne 'Auto'); azure = $true; ztpEvents = $true; osConfigEvents = $true; nodeProbe = $true; tailer = $true; discovery = $true; armEvents = $true
        phases = @('provisioning', 'arc-registration', 'validation', 'deployment', 'post-deployment', 'update', 'add-node', 'repair') }
    switch ($name) {
        'Discovery' { $plan.azure = $false; $plan.armEvents = $false; $plan.ztpEvents = $false; $plan.osConfigEvents = $false; $plan.nodeProbe = $false; $plan.tailer = $false; $plan.phases = @() }
        'Provisioning' { $plan.armEvents = $false; $plan.osConfigEvents = $false; $plan.discovery = $false; $plan.tailer = $false; $plan.phases = @('provisioning', 'arc-registration') }
        'OsConfiguration' { $plan.armEvents = $false; $plan.ztpEvents = $false; $plan.nodeProbe = $false; $plan.discovery = $false; $plan.tailer = $false; $plan.phases = @('provisioning') }
        'Validate' { $plan.ztpEvents = $false; $plan.osConfigEvents = $false; $plan.nodeProbe = $false; $plan.discovery = $false; $plan.phases = @('validation') }
        'Deployment' { $plan.ztpEvents = $false; $plan.osConfigEvents = $false; $plan.nodeProbe = $false; $plan.discovery = $false; $plan.phases = @('deployment', 'post-deployment') }
        'Update' { $plan.armEvents = $false; $plan.ztpEvents = $false; $plan.osConfigEvents = $false; $plan.nodeProbe = $false; $plan.discovery = $false; $plan.phases = @('update') }
        'AddNode' { $plan.armEvents = $false; $plan.ztpEvents = $false; $plan.osConfigEvents = $false; $plan.nodeProbe = $false; $plan.discovery = $false; $plan.phases = @('add-node') }
        'Repair' { $plan.armEvents = $false; $plan.ztpEvents = $false; $plan.osConfigEvents = $false; $plan.nodeProbe = $false; $plan.discovery = $false; $plan.phases = @('repair') }
    }
    return $plan
}
