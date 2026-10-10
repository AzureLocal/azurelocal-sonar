@{
    RootModule           = 'AzlSonar.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '5d6ee105-e406-4e6b-8227-b2dcd7c9e3c6'
    Author               = 'AzureLocal'
    CompanyName          = 'AzureLocal'
    Copyright            = '(c) AzureLocal. All rights reserved.'
    Description          = 'AzL Sonar: real-time, read-only monitor for Azure Local deployments (step tree from Azure, live logs from the seed node, local web view).'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Start-AzlSonarServer',
        'Get-AzlSonarDeploymentState',
        'ConvertTo-AzlSonarStepTree',
        'Get-AzlSonarPhaseGuidance',
        'Read-AzlSonarConfig'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('AzureLocal', 'AzureStackHCI', 'Deployment', 'Monitoring')
            ProjectUri = 'https://github.com/AzureLocal/azurelocal-sonar'
        }
    }
}
