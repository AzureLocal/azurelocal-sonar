<#
.SYNOPSIS
    Calls a route of AzL Sonar's read-only HTTP API: the script form of the module function Invoke-AzlSonarApi.
.DESCRIPTION
    Does the access-token handshake (cookie session), pages /api/logs with -All (reports gaps and Sonar restarts), follows
    /api/events with -Follow, and saves /api/export with -OutFile. Sends only GET, only to this machine, and never prints the
    token. Get the token from the file Start-AzlSonar.ps1 -TokenFile wrote. See docs/api.md.
.PARAMETER Route
    /api/config, /api/about, /api/guidance, /api/details, /api/state, /api/logs, /api/events, /api/export or /api/replay.
.PARAMETER Since
    /api/logs: the lines after this sequence number. Default 0.
.PARAMETER All
    /api/logs: page until caught up and report gaps and restarts.
.PARAMETER Follow
    /api/events: write one object per event as it arrives.
.PARAMETER EventName
    -Follow: only these events (hello, state, tailer, log).
.PARAMETER DurationSeconds
    -Follow: stop after this many seconds (default 0: until the stream ends).
.PARAMETER ServerId
    -All: the server id of your last call; a different one means Sonar restarted.
.PARAMETER BaseUrl
    Where Sonar listens. Default http://localhost:8642 (this machine only).
.PARAMETER Token
    The access token. Prefer -TokenFile.
.PARAMETER TokenFile
    The file Start-AzlSonar.ps1 -TokenFile wrote.
.PARAMETER Raw
    Return the body as text (alias AsJson); with -All or -Follow one JSON line per result or event.
.PARAMETER OutFile
    Save the answer to this file (for /api/export) and return the file.
.PARAMETER TimeoutSeconds
    Seconds one request may take (for -Follow the longest quiet time on the stream). Default 30.
.PARAMETER MaxRetry
    Retries after 429, each after Retry-After seconds (at most 120). Default 2.
.EXAMPLE
    ./scripts/Invoke-AzlSonarApi.ps1 /api/state -TokenFile ./sonar.token | Select-Object phase, activePhase
.EXAMPLE
    ./scripts/Invoke-AzlSonarApi.ps1 /api/logs -All -TokenFile ./sonar.token
#>
#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('/api/config', '/api/about', '/api/guidance', '/api/details', '/api/state', '/api/logs', '/api/events', '/api/export', '/api/replay')]
    [string]$Route,

    [ValidateRange(0, 999999999999999)]
    [long]$Since = 0,

    [switch]$All,

    [switch]$Follow,

    [ValidateSet('hello', 'state', 'tailer', 'log')]
    [string[]]$EventName,

    [ValidateRange(0, 86400)]
    [int]$DurationSeconds = 0,

    [string]$ServerId,

    [string]$BaseUrl = 'http://localhost:8642',

    [string]$Token,

    [string]$TokenFile,

    [Alias('AsJson')]
    [switch]$Raw,

    [string]$OutFile,

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 30,

    [ValidateRange(0, 10)]
    [int]$MaxRetry = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../src/AzlSonar/AzlSonar.psd1') -Force

$parameters = @{}
foreach ($key in $PSBoundParameters.Keys) { $parameters[$key] = $PSBoundParameters[$key] }
Invoke-AzlSonarApi @parameters
