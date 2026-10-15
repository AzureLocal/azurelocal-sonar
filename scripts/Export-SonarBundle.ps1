<#
.SYNOPSIS
    Writes the export bundle of a recording: a timeline JSON (phases, steps, errors, durations) and a self-contained
    HTML report.
.DESCRIPTION
    Works on any recording (.jsonl or .jsonl.gz), including one made while a run was live (Start-AzlSonar.ps1 -Record).
    The report is plain HTML with inline CSS and no script. A recording made without -Publishable still holds the
    identifiers of the cluster and so does the bundle: run scripts/Protect-Recording.ps1 first when you will share it.
.PARAMETER Recording
    The recording to read.
.PARAMETER OutDirectory
    Where to write <name>-timeline.json and <name>-report.html.
.PARAMETER Name
    File name prefix; default is the recording's name.
.PARAMETER MaxLogLines
    Warning and error log lines kept (default 300).
.EXAMPLE
    ./scripts/Export-SonarBundle.ps1 -Recording ./recordings/clus01.publishable.jsonl.gz -OutDirectory ./bundle
#>
#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Recording,

    [Parameter(Mandatory, Position = 1)]
    [string]$OutDirectory,

    [string]$Name,

    [ValidateRange(0, 100000)]
    [int]$MaxLogLines = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../src/AzlSonar/AzlSonar.psd1') -Force

$parameters = @{ Recording = $Recording; OutDirectory = $OutDirectory; MaxLogLines = $MaxLogLines }
if ($Name) { $parameters.Name = $Name }
$result = Export-AzlSonarBundle @parameters
"Wrote $($result.Timeline)"
"Wrote $($result.Report)"
"$($result.Phases) phase(s), $($result.Steps) step(s), $($result.Errors) with errors, $($result.LogLines) warning/error log line(s)."
