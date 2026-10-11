[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The Invoke-AzRestMethod stub only mirrors the real parameters.')]
param()
Set-StrictMode -Version Latest

# Shared helpers for the AzL Sonar Pester 5 suite. Dot-source in BeforeAll.
# No Azure, no node access: every ARM and remoting call is mocked; only localhost is used.

$script:SonarRepoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath
$script:SonarModuleRoot = Join-Path -Path $script:SonarRepoRoot -ChildPath 'src/AzlSonar'
$script:SonarManifest = Join-Path -Path $script:SonarModuleRoot -ChildPath 'AzlSonar.psd1'
$script:SonarExampleConfig = Join-Path -Path $script:SonarRepoRoot -ChildPath 'examples/sonar.config.example.json'

function Import-SonarTestModule {
    # Az.Accounts may be missing on a build agent; Pester can only mock a command that exists.
    if (-not (Get-Command -Name Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
        $stub = {
            [CmdletBinding()]
            param([string]$Method, [string]$Path, [string]$Payload)
            throw 'Invoke-AzRestMethod stub called without a mock.'
        }
        Set-Item -Path 'function:global:Invoke-AzRestMethod' -Value $stub
    }
    Import-Module -Name $script:SonarManifest -Force -ErrorAction Stop
}

function New-SonarConfigObject {
    <#
        A valid config as a PSCustomObject (the example file), ready to be changed by a test and serialised.
    #>
    return (Get-Content -LiteralPath $script:SonarExampleConfig -Raw | ConvertFrom-Json -Depth 32)
}

function ConvertTo-SonarConfigJson {
    param([Parameter(Mandatory)][object]$InputObject)
    return (ConvertTo-Json -InputObject $InputObject -Depth 32)
}

function Get-SonarValidationFixture {
    <#
        The validation status object as seen live on 10 Oct 2026: { status, steps[] }, statuses 'Not Started',
        'InProgress', 'Success', no exception[] on validation steps.
    #>
    param([string]$OverallStatus = 'InProgress')

    $json = @"
{
  "status": "$OverallStatus",
  "steps": [
    {
      "name": "Validate Network",
      "description": "Checks the network intents and adapters.",
      "fullStepIndex": "0",
      "startTimeUtc": "2026-10-10T18:00:00.0000000Z",
      "endTimeUtc": "2026-10-10T18:04:30.0000000Z",
      "status": "Success"
    },
    {
      "name": "Validate Hardware",
      "description": "Checks the hardware.",
      "fullStepIndex": "1",
      "startTimeUtc": "2026-10-10T18:04:30.0000000Z",
      "endTimeUtc": "",
      "status": "InProgress"
    },
    {
      "name": "Validate Active Directory",
      "description": "Checks the identity settings.",
      "fullStepIndex": "2",
      "startTimeUtc": "",
      "endTimeUtc": "",
      "status": "Not Started"
    }
  ]
}
"@
    return ($json | ConvertFrom-Json -Depth 64)
}

function Get-SonarValidationSuccessFixture {
    $json = @'
{
  "status": "Success",
  "steps": [
    { "name": "Validate Network", "description": "", "fullStepIndex": "0", "startTimeUtc": "2026-10-10T18:00:00Z", "endTimeUtc": "2026-10-10T18:04:30Z", "status": "Success" },
    { "name": "Validate Hardware", "description": "", "fullStepIndex": "1", "startTimeUtc": "2026-10-10T18:04:30Z", "endTimeUtc": "2026-10-10T18:09:00Z", "status": "Success" },
    { "name": "Validate Active Directory", "description": "", "fullStepIndex": "2", "startTimeUtc": "2026-10-10T18:09:00Z", "endTimeUtc": "2026-10-10T18:12:00Z", "status": "Success" }
  ]
}
'@
    return ($json | ConvertFrom-Json -Depth 64)
}

function Get-SonarDeploymentFixture {
    <#
        A nested deployment status: steps within steps, an exception[] on a failed child, one running leaf.
    #>
    $json = @'
{
  "status": "InProgress",
  "steps": [
    {
      "name": "Before Cloud Deployment",
      "description": "Environment checks.",
      "fullStepIndex": "0",
      "startTimeUtc": "2026-10-10T19:00:00Z",
      "endTimeUtc": "2026-10-10T19:20:00Z",
      "status": "Success",
      "steps": [
        { "name": "Limited Environment Checker", "description": "", "fullStepIndex": "0.0", "startTimeUtc": "2026-10-10T19:00:00Z", "endTimeUtc": "2026-10-10T19:05:00Z", "status": "Success" },
        { "name": "Retry once", "description": "", "fullStepIndex": "0.1", "startTimeUtc": "2026-10-10T19:05:00Z", "endTimeUtc": "2026-10-10T19:06:00Z", "status": "Error",
          "exception": [ "Type 'ValidateNode' of Role 'EnvironmentValidator' raised an exception:", "Node02 is not reachable." , "" ] },
        { "name": "Full Environment Checker", "description": "", "fullStepIndex": "0.2", "startTimeUtc": "2026-10-10T19:06:00Z", "endTimeUtc": "2026-10-10T19:20:00Z", "status": "Success" }
      ]
    },
    {
      "name": "Begin Cloud Deployment",
      "description": "",
      "fullStepIndex": "1",
      "startTimeUtc": "2026-10-10T19:20:00Z",
      "endTimeUtc": "",
      "status": "InProgress",
      "steps": [
        { "name": "Deploy Storage", "description": "", "fullStepIndex": "1.0", "startTimeUtc": "2026-10-10T19:20:00Z", "endTimeUtc": "2026-10-10T19:40:00Z", "status": "Success" },
        {
          "name": "Deploy Moc and ARB Stack", "description": "", "fullStepIndex": "1.1", "startTimeUtc": "2026-10-10T19:40:00Z", "endTimeUtc": "", "status": "InProgress",
          "steps": [
            { "name": "Install MOC", "description": "", "fullStepIndex": "1.1.0", "startTimeUtc": "2026-10-10T19:41:00Z", "endTimeUtc": "", "status": "InProgress" },
            { "name": "Install ARB", "description": "", "fullStepIndex": "1.1.1", "startTimeUtc": "", "endTimeUtc": "", "status": "Not Started" }
          ]
        }
      ]
    },
    { "name": "After Cloud Deployment", "description": "", "fullStepIndex": "2", "startTimeUtc": "", "endTimeUtc": "", "status": "Not Started" }
  ]
}
'@
    return ($json | ConvertFrom-Json -Depth 64)
}

function New-SonarArmResponse {
    <#
        What Invoke-AzRestMethod returns: an object with StatusCode and Content (JSON text).
    #>
    param(
        [int]$StatusCode = 200,
        [AllowNull()][object]$Body
    )
    $content = if ($null -eq $Body) { '' } elseif ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 64 }
    return [pscustomobject]@{ StatusCode = $StatusCode; Content = $content; Method = 'GET' }
}

function Get-SonarFreeTcpPort {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port }
    finally { $probe.Stop() }
}
