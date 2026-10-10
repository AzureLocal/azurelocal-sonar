Set-StrictMode -Version Latest

# AzL Sonar: real-time, read-only monitor for Azure Local deployments.
$script:AzlSonarModuleRoot = $PSScriptRoot
$script:AzlSonarModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath 'AzlSonar.psd1'

foreach ($file in @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -File | Sort-Object -Property Name)) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'Start-AzlSonarServer',
    'Get-AzlSonarDeploymentState',
    'ConvertTo-AzlSonarStepTree',
    'Get-AzlSonarPhaseGuidance',
    'Read-AzlSonarConfig'
)
