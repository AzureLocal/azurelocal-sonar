<#
.SYNOPSIS
    Starts AzL Sonar: a real-time, read-only monitor for an Azure Local deployment, in your browser.
.DESCRIPTION
    Imports the AzlSonar module, reads the config, checks the Az PowerShell sign-in (run Connect-AzAccount first),
    resolves the account that reads the seed node's logs, starts the local back end on http://localhost:<Port>/ and
    opens the browser. Runs until Ctrl+C. Sonar only reads: it never changes Azure or the nodes.
.PARAMETER ConfigPath
    Path to the cluster's Sonar config (see examples/sonar.config.example.json).
.PARAMETER Port
    Local port for the web view. Default 8642.
.PARAMETER NoBrowser
    Do not open the browser.
.PARAMETER Credential
    Account that reads the deployment logs on the seed node. Overrides credential.source in the config.
.EXAMPLE
    Connect-AzAccount
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json
.EXAMPLE
    ./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json -Port 9000 -Credential (Get-Credential)
#>
#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [ValidateRange(1, 65535)]
    [int]$Port = 8642,

    [switch]$NoBrowser,

    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'src/AzlSonar/AzlSonar.psd1') -Force

$serverParameters = @{
    ConfigPath = $ConfigPath
    Port       = $Port
    NoBrowser  = $NoBrowser
}
if ($PSBoundParameters.ContainsKey('Credential')) { $serverParameters.Credential = $Credential }

Start-AzlSonarServer @serverParameters
