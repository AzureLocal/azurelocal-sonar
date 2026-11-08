<#
.SYNOPSIS
    Starts AzL Sonar: a real-time, read-only monitor for an Azure Local deployment, in your browser. Can record the run
    and replay it later.
.DESCRIPTION
    Imports the AzlSonar module, builds the configuration (from the master infrastructure.yml with -InfrastructureFile, or from
    a config file with -ConfigPath; with neither it prints the ways to configure Sonar and offers the guided setup), checks the Az PowerShell sign-in (run Connect-AzAccount first),
    resolves the account that reads the seed node's logs, starts the local back end on http://localhost:<Port>/ and
    opens the browser. Runs until Ctrl+C. Sonar only reads: it never changes Azure or the nodes.
    With -Record it also appends everything the page is sent (state, step tree, log lines, all masked) to a local JSON
    Lines recording. With -Replay it plays a recording through the same page instead: no Azure sign-in, no node access.
.PARAMETER InfrastructureFile
    Path to the master infrastructure.yml (schema 5, azurelocal-toolkit). Sonar builds its configuration from it in memory:
    cluster, subscription, resource group, route, identity model, the nodes and their management addresses, and the ZTP event
    file. The file is checked every 60 seconds; when its node set changes Sonar logs a notice to restart it. The log account
    still comes from -Credential or a prompt: the file only holds keyvault:// references and Sonar never reads them.
.PARAMETER ConfigPath
    Path to the cluster's Sonar config file (the older option; see examples/sonar.config.commented.jsonc).
.PARAMETER PollSeconds
    Seconds between Azure polls (5 to 3600). Overrides pollSeconds in the config; the default is 20.
.PARAMETER Monitor
    Which stage to watch. Auto (the default) follows the whole flow: Discovery, Provisioning, OS configuration, Validate,
    Deployment, Update. One of Discovery, Provisioning, OsConfiguration, Validate, Deployment, Update, AddNode or Repair runs
    that monitor on its own: only its tile and section show, only the sources it needs are read (Discovery reads the discovery
    files and needs no Azure sign-in; OsConfiguration does not read the node logs; Validate, Deployment, Update, AddNode and
    Repair read their Azure resources and the seed node's log), the page title names it, and Log access lists only its phases.
    Overrides monitor in the config.
.PARAMETER Replay
    Path to a recording (.jsonl or .jsonl.gz) to play instead of watching a live deployment.
.PARAMETER Port
    Local port for the web view. Default 8642.
.PARAMETER NoAccessToken
    Turns the per-start access token off (also: accessToken: false in the config). The page then answers any account on this
    machine. For a single-user machine only. By default Sonar prints and opens a URL that carries a one-time token.
.PARAMETER NoBrowser
    Do not open the browser.
.PARAMETER Credential
    Account that reads the deployment logs on the seed node. Overrides credential.source in the config.
.PARAMETER Record
    Append the run to this recording file (JSON Lines; created if missing, appended to after a restart). Overrides
    recordPath in the config.
.PARAMETER Publishable
    With -Record: also replace every identifier (GUIDs, IP and MAC addresses, host and domain names, subscription,
    resource group, cluster and node names, user names) with stable pseudonyms, so the recording can be shared. Needs a
    new file. The finished file is verified with the identifier detectors; a failed check renames it .NOT-PUBLISHABLE.
.PARAMETER ExtraTerm
    With -Publishable: extra strings that must never appear (for example a company or site name).
.PARAMETER Speed
    Replay: starting speed, recorded seconds per real second (1, 30, 60, 240 are on the page). Default 60.
.PARAMETER StartAt
    Replay: where to start. An offset from the start of the recording (1:42:10, 90m, 1h30m), a UTC time inside the
    recording, or a phase (arc-registration, validation, deployment).
.PARAMETER Autoplay
    Replay: start playing at once instead of paused.
.EXAMPLE
    Connect-AzAccount
    ./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
.EXAMPLE
    ./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Monitor OsConfiguration
.EXAMPLE
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json
.EXAMPLE
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json -Record ./recordings/my-cluster.jsonl
.EXAMPLE
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json -Record ./recordings/my-cluster.shareable.jsonl -Publishable
.EXAMPLE
    ./Start-AzlSonar.ps1 -Replay ./recordings/my-cluster.jsonl -Speed 240 -StartAt deployment
.EXAMPLE
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json -Port 9000 -Credential (Get-Credential)
#>
#Requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(ParameterSetName = 'Live')]
    [string]$InfrastructureFile,

    [Parameter(ParameterSetName = 'Live')]
    [string]$ConfigPath,

    [Parameter(ParameterSetName = 'Live')]
    [ValidateRange(5, 3600)]
    [int]$PollSeconds,

    [Parameter(Mandatory, ParameterSetName = 'Replay')]
    [string]$Replay,

    [ValidateRange(1, 65535)]
    [int]$Port = 8642,

    [switch]$NoBrowser,

    [switch]$NoAccessToken,

    [Parameter(ParameterSetName = 'Live')]
    [ValidateSet('Auto', 'Discovery', 'Provisioning', 'OsConfiguration', 'Validate', 'Deployment', 'Update', 'AddNode', 'Repair')]
    [string]$Monitor,

    [Parameter(ParameterSetName = 'Live')]
    [pscredential]$Credential,

    [Parameter(ParameterSetName = 'Live')]
    [string]$Record,

    [Parameter(ParameterSetName = 'Live')]
    [switch]$Publishable,

    [Parameter(ParameterSetName = 'Live')]
    [string[]]$ExtraTerm,

    [Parameter(ParameterSetName = 'Replay')]
    [ValidateRange(0.1, 3600)]
    [double]$Speed = 60,

    [Parameter(ParameterSetName = 'Replay')]
    [string]$StartAt,

    [Parameter(ParameterSetName = 'Replay')]
    [switch]$Autoplay
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'src/AzlSonar/AzlSonar.psd1') -Force

$serverParameters = @{
    Port      = $Port
    NoBrowser = $NoBrowser
}
if ($NoAccessToken) { $serverParameters.NoAccessToken = $true }
if ($PSCmdlet.ParameterSetName -eq 'Replay') {
    $serverParameters.Replay = $Replay
    $serverParameters.Speed = $Speed
    $serverParameters.Autoplay = $Autoplay
    if ($PSBoundParameters.ContainsKey('StartAt')) { $serverParameters.StartAt = $StartAt }
}
else {
    if ($ConfigPath -and $InfrastructureFile) { throw 'Give -InfrastructureFile or -ConfigPath, not both.' }
    if (-not $ConfigPath -and -not $InfrastructureFile) {
        # No arguments: use a config in the usual place, else explain the three ways and offer the guided setup.
        $found = & (Get-Module -Name AzlSonar) { Find-AzlSonarDefaultConfig }
        if ($found) { $ConfigPath = $found; Write-Information -MessageData "No -ConfigPath or -InfrastructureFile given: using $found." -InformationAction Continue }
        else {
            $ConfigPath = & (Get-Module -Name AzlSonar) { Invoke-AzlSonarNoConfigGuide }
            if (-not $ConfigPath) { return }
        }
    }
    if ($ConfigPath) { $serverParameters.ConfigPath = $ConfigPath }
    if ($InfrastructureFile) { $serverParameters.InfrastructureFile = $InfrastructureFile }
    if ($PSBoundParameters.ContainsKey('PollSeconds')) { $serverParameters.PollSeconds = $PollSeconds }
    if ($PSBoundParameters.ContainsKey('Monitor')) { $serverParameters.Monitor = $Monitor }
    if ($PSBoundParameters.ContainsKey('Credential')) { $serverParameters.Credential = $Credential }
    if ($PSBoundParameters.ContainsKey('Record')) { $serverParameters.Record = $Record }
    if ($Publishable) { $serverParameters.Publishable = $true }
    if ($PSBoundParameters.ContainsKey('ExtraTerm')) { $serverParameters.ExtraTerm = $ExtraTerm }
}

Start-AzlSonarServer @serverParameters
