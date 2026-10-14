<#
.SYNOPSIS
    Starts AzL Sonar: a real-time, read-only monitor for an Azure Local deployment, in your browser. Can record the run
    and replay it later.
.DESCRIPTION
    Imports the AzlSonar module, reads the config, checks the Az PowerShell sign-in (run Connect-AzAccount first),
    resolves the account that reads the seed node's logs, starts the local back end on http://localhost:<Port>/ and
    opens the browser. Runs until Ctrl+C. Sonar only reads: it never changes Azure or the nodes.
    With -Record it also appends everything the page is sent (state, step tree, log lines, all masked) to a local JSON
    Lines recording. With -Replay it plays a recording through the same page instead: no Azure sign-in, no node access.
.PARAMETER ConfigPath
    Path to the cluster's Sonar config (see examples/sonar.config.example.json).
.PARAMETER Replay
    Path to a recording (.jsonl or .jsonl.gz) to play instead of watching a live deployment.
.PARAMETER Port
    Local port for the web view. Default 8642.
.PARAMETER NoBrowser
    Do not open the browser.
.PARAMETER Credential
    Account that reads the deployment logs on the seed node. Overrides credential.source in the config.
.PARAMETER Record
    Append the run to this recording file (JSON Lines; created if missing, appended to after a restart). Overrides
    recordPath in the config.
.PARAMETER Speed
    Replay: starting speed, recorded seconds per real second (1, 30, 60, 240 are on the page). Default 60.
.PARAMETER StartAt
    Replay: where to start. An offset from the start of the recording (1:42:10, 90m, 1h30m), a UTC time inside the
    recording, or a phase (arc-registration, validation, deployment).
.PARAMETER Autoplay
    Replay: start playing at once instead of paused.
.EXAMPLE
    Connect-AzAccount
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json
.EXAMPLE
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json -Record ./recordings/my-cluster.jsonl
.EXAMPLE
    ./Start-AzlSonar.ps1 -Replay ./recordings/my-cluster.jsonl -Speed 240 -StartAt deployment
.EXAMPLE
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json -Port 9000 -Credential (Get-Credential)
#>
#Requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'Replay')]
    [string]$Replay,

    [ValidateRange(1, 65535)]
    [int]$Port = 8642,

    [switch]$NoBrowser,

    [Parameter(ParameterSetName = 'Live')]
    [pscredential]$Credential,

    [Parameter(ParameterSetName = 'Live')]
    [string]$Record,

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
if ($PSCmdlet.ParameterSetName -eq 'Replay') {
    $serverParameters.Replay = $Replay
    $serverParameters.Speed = $Speed
    $serverParameters.Autoplay = $Autoplay
    if ($PSBoundParameters.ContainsKey('StartAt')) { $serverParameters.StartAt = $StartAt }
}
else {
    $serverParameters.ConfigPath = $ConfigPath
    if ($PSBoundParameters.ContainsKey('Credential')) { $serverParameters.Credential = $Credential }
    if ($PSBoundParameters.ContainsKey('Record')) { $serverParameters.Record = $Record }
}

Start-AzlSonarServer @serverParameters
