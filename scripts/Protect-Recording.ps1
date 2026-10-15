<#
.SYNOPSIS
    Rewrites an existing AzL Sonar recording into a publishable one: every identifier replaced by a stable pseudonym,
    then verified. Nothing is written when the check finds an original identifier.
.DESCRIPTION
    A normal recording masks secrets only; it still holds subscription, tenant and principal GUIDs, IP and MAC
    addresses, host, domain, cluster, resource group and node names, and user names. This script replaces them with
    pseudonyms (the same value always gets the same token inside the output: sub-0001, node-01, 192.0.2.x,
    00000000-0000-0000-0000-00000000000N ...), keeps structure, timestamps, step names and durations, and reads the
    result back with the identifier detectors. The source file is never changed. See
    docs/reference/publishable-recordings.md for the token formats and the limits.
.PARAMETER Path
    The recording to protect (.jsonl or .jsonl.gz).
.PARAMETER Destination
    Where to write the publishable copy; gzip when it ends in .gz.
.PARAMETER ExtraTerm
    Strings that must not appear anywhere in the output (a company or site name, a tenant name). Each is replaced
    and checked, case-insensitively.
.PARAMETER MaxLogTextLength
    Cut log lines longer than this many characters (at a word boundary, before scrubbing). Default 2000; 0 keeps them whole.
.PARAMETER MaxInfoLinesPerEvent
    Keep at most this many info lines per log event (0 keeps all); warning and error lines are always kept. Makes a recording
    with hundreds of thousands of log lines light to replay.
.PARAMETER MaxIdleSeconds
    Close gaps between events longer than this many seconds (0 keeps them). Step times inside the state are untouched.
.PARAMETER MaxBytes
    Refuse to keep a result larger than this many bytes (0 = no limit).
.PARAMETER VerifyOnly
    Only scan -Path with the detectors and print the counts per category (no output file).
.PARAMETER Force
    Replace -Destination when it exists.
.EXAMPLE
    ./scripts/Protect-Recording.ps1 -Path ./recordings/clus01.jsonl -Destination ./recordings/clus01.publishable.jsonl.gz -ExtraTerm 'Infinite Improbability Corp' -MaxBytes 15MB
.EXAMPLE
    ./scripts/Protect-Recording.ps1 -Path ./recordings/clus01.publishable.jsonl.gz -VerifyOnly
#>
#Requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Protect')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory, ParameterSetName = 'Protect', Position = 1)]
    [string]$Destination,

    [string[]]$ExtraTerm = @(),

    [Parameter(ParameterSetName = 'Protect')]
    [ValidateRange(0, 10000000)]
    [int]$MaxLogTextLength = 2000,

    [Parameter(ParameterSetName = 'Protect')]
    [ValidateRange(0, 100000)]
    [int]$MaxInfoLinesPerEvent = 0,

    [Parameter(ParameterSetName = 'Protect')]
    [ValidateRange(0, 86400)]
    [double]$MaxIdleSeconds = 0,

    [Parameter(ParameterSetName = 'Protect')]
    [long]$MaxBytes = 0,

    [Parameter(Mandatory, ParameterSetName = 'Verify')]
    [switch]$VerifyOnly,

    [Parameter(ParameterSetName = 'Protect')]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../src/AzlSonar/AzlSonar.psd1') -Force

function Write-CountLine {
    param([System.Collections.IDictionary]$Counts)
    foreach ($entry in $Counts.GetEnumerator()) { '{0,-24} {1}' -f $entry.Key, $entry.Value }
}

if ($VerifyOnly) {
    $check = Test-AzlSonarPublishableRecording -Path $Path -ExtraTerm $ExtraTerm
    "Scanned $($check.Lines) line(s) of $($check.Path). Original identifiers found by category (values are never printed):"
    Write-CountLine $check.ByCategory
    if ($check.Clean) { 'Clean: no identifier is left.' } else { Write-Error "Not clean: $($check.Total) identifier(s) left." }
    return
}

$parameters = @{ Path = $Path; Destination = $Destination; ExtraTerm = $ExtraTerm; MaxLogTextLength = $MaxLogTextLength; MaxInfoLinesPerEvent = $MaxInfoLinesPerEvent; MaxIdleSeconds = $MaxIdleSeconds; MaxBytes = $MaxBytes; Force = $Force }
$result = Export-AzlSonarPublishableRecording @parameters
"Wrote $($result.Destination): $($result.Lines) line(s), $([Math]::Round($result.BytesIn / 1MB, 1)) MB in, $([Math]::Round($result.BytesOut / 1MB, 2)) MB out."
'Replacements by category:'
Write-CountLine $result.Replaced
'Distinct originals by category (each got one token):'
Write-CountLine $result.Distinct
'Verification of the written file (original identifiers left, by category):'
Write-CountLine $result.Verification.ByCategory
'Clean: the verification found nothing.'
