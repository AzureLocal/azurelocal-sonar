#Requires -Version 7.0
<#
.SYNOPSIS
    Regenerates the toolkit event fixtures in this folder from the toolkit's own scripts, run offline.
.DESCRIPTION
    The *.update-events.jsonl, gate-plan.precluster-plan-events.jsonl and *.post-deployment-events.jsonl files next to this script are what the azurelocal-toolkit
    scripts write to their event feeds. This script produces them again, so the fixtures follow the toolkit when its output changes:

      check-available, check-uptodate, check-attention   Get-AvailableSolutionUpdate.ps1 (mode Check)
      start-whatif, start-install                        Start-AzureLocalSolutionUpdate.ps1 (mode WhatIf and Install)
      gate-plan                                          Invoke-AzlPreClusterVerification -Mode Plan (the toolkit's fc-san test file)
      plan-example                                       Invoke-AzlPostDeployment -Mode Plan with the toolkit's own step scripts against
                                                         config/variables/examples/infrastructure.example.yml (it stops at the first step that
                                                         needs a secret: nobody is signed in to Azure)
      plan-passed, plan-warning, apply-passed,           Invoke-AzlPostDeployment (Plan and Apply) with stub step scripts at the paths of the real
      apply-failed                                       step table, so every kind of step result is there (the toolkit's own tests use the same stubs)

    Nothing leaves this machine and nothing is started: Azure is blocked (Get-AzContext answers nobody, Get-AzKeyVaultSecret throws) and
    Invoke-Command is replaced by a function that returns a made-up update state
    of a made-up cluster ("clus01"), so no cluster, no node, no BMC and no Azure resource is read or changed. The work happens in a
    temporary folder that is removed at the end. Machine paths in the output (this machine's toolkit folder, the temporary folder)
    are replaced by C:\toolkit and C:\data before the files are written.
.PARAMETER Toolkit
    The folder of an azurelocal-toolkit checkout (the one that holds scripts and tests). Used read-only.
.PARAMETER Out
    Where the fixtures are written. Default: the folder of this script.
.EXAMPLE
    ./New-ToolkitEventFixtures.ps1 -Toolkit <path to azurelocal-toolkit>
.NOTES
    Needs the powershell-yaml module (Install-Module powershell-yaml -Scope CurrentUser). Run it in its own pwsh process: it shadows
    Invoke-Command and Start-Sleep in the global scope. Review the result with git diff before committing: timestamps and run ids
    change on every run, and the tests read the files, not the generator.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Toolkit,
    [string]$Out = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Toolkit = (Resolve-Path -LiteralPath $Toolkit).ProviderPath
$work = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('sonar-toolkit-fixtures-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$null = New-Item -ItemType Directory -Path $Out -Force
$Out = (Resolve-Path -LiteralPath $Out).ProviderPath

Import-Module powershell-yaml
foreach ($m in 'infrastructure\AzlInfrastructure.psm1', 'azure-local\AzlAzure.psm1', 'arm-deployment\AzlArmDeployment.psm1', 'arm-deployment\AzlArmDeploymentRun.psm1', 'arm-deployment\AzlPreClusterGate.psm1', 'arm-deployment\AzlPreClusterVerification.psm1') {
    Import-Module ([IO.Path]::Combine($Toolkit, 'scripts', 'common', $m)) -Force
}
$checkScript = [IO.Path]::Combine($Toolkit, 'scripts', 'deploy', '08-day2-operations', 'task-01-check-for-updates', 'powershell', 'Get-AvailableSolutionUpdate.ps1')
$startScript = [IO.Path]::Combine($Toolkit, 'scripts', 'deploy', '08-day2-operations', 'task-02-start-solution-update', 'powershell', 'Start-AzureLocalSolutionUpdate.ps1')

function New-Update([string]$Version, [string]$State = 'Ready', [string]$Type = 'Solution') {
    @{ ResourceId = "azl/$Type$Version"; Version = $Version; SbeVersion = '4.1.2410.5'; State = $State; PackageType = $Type; DisplayName = "update $Version"; UpdateStateProperties = '' }
}

# The scripts reach the cluster only through Invoke-Command: it answers from this made-up state instead.
$global:GenState = $null
function global:Invoke-Command {
    param($ComputerName, $ScriptBlock, $ArgumentList, $Credential, $Session, $ErrorAction)
    if ($ScriptBlock.ToString().Trim() -eq '$true') { return $true }
    if ($ArgumentList -and [string]$ArgumentList[0] -eq 'StartUpdate') { return 'instance-0001' }
    $global:GenState
}
function global:Start-Sleep { }
# Azure is blocked: nobody is signed in and no Key Vault answers, so a step that needs a secret stops with its own message.
function global:Get-AzContext { $null }
function global:Get-AzKeyVaultSecret { throw 'Azure is blocked while the fixtures are generated.' }

function New-Infra([string]$Name, [string]$Events) {
    $doc = [ordered]@{ cluster = [ordered]@{ name = 'clus01' }; operations = [ordered]@{ updates = [ordered]@{ install_after_deployment = $false } }; deployment = [ordered]@{ events_directory = $Events } }
    $file = Join-Path $work "$Name.yml"
    Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
    $file
}
function Reset-Folder([string]$Dir) { if (Test-Path -LiteralPath $Dir) { Remove-Item -Recurse -Force -LiteralPath $Dir }; $null = New-Item -ItemType Directory -Force -Path $Dir; $Dir }

# A path as it appears inside a JSON string (backslashes doubled).
function ConvertTo-JsonPath([string]$Path) { $Path.Replace('\', '\\') }

# Copies a feed to the fixture folder with this machine's paths replaced.
function Save-Fixture([string]$Source, [string]$Name, [hashtable]$Replace) {
    $text = [IO.File]::ReadAllText($Source)
    foreach ($from in @($Replace.Keys | Sort-Object { $_.Length } -Descending)) {
        $text = $text.Replace((ConvertTo-JsonPath $from), (ConvertTo-JsonPath $Replace[$from])).Replace($from, $Replace[$from])
    }
    [IO.File]::WriteAllText((Join-Path $Out $Name), $text, [Text.UTF8Encoding]::new($false))
}

try {
    # 1. Check, an update is offered (UpdateAvailable).
    $e1 = Reset-Folder (Join-Path $work 'check-available')
    $global:GenState = @{ CurrentVersion = '12.2607.1002.20'; CurrentSbeVersion = '4.1.2410.5'; State = 'UpdateAvailable'; HealthState = 'Success'; LastChecked = '2026-11-24T12:00:00.0000000Z'; HardwareModel = 'Model-1'; Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2611.1004.9')) }
    $null = & $checkScript -InfrastructureFile (New-Infra 'check-available' $e1) 6>&1 3>&1 2>&1
    Save-Fixture (Join-Path $e1 'update-events.jsonl') 'check-available.update-events.jsonl' @{}

    # 2. Check, up to date.
    $e2 = Reset-Folder (Join-Path $work 'check-uptodate')
    $global:GenState = @{ CurrentVersion = '12.2611.1004.9'; CurrentSbeVersion = '4.1.2410.5'; State = 'AppliedSuccessfully'; HealthState = 'Success'; LastChecked = '2026-11-24T12:00:00.0000000Z'; HardwareModel = 'Model-1'; Updates = @((New-Update '12.2611.1004.9' 'Installed')) }
    $null = & $checkScript -InfrastructureFile (New-Infra 'check-uptodate' $e2) 6>&1 3>&1 2>&1
    Save-Fixture (Join-Path $e2 'update-events.jsonl') 'check-uptodate.update-events.jsonl' @{}

    # 3. Check, a failed update (AttentionNeeded, RunFailed with exit code 1).
    $e3 = Reset-Folder (Join-Path $work 'check-attention')
    $global:GenState = @{ CurrentVersion = '12.2607.1002.20'; CurrentSbeVersion = '4.1.2410.5'; State = 'UpdateFailed'; HealthState = 'Success'; LastChecked = '2026-11-24T12:00:00.0000000Z'; HardwareModel = 'Model-1'; Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2611.1004.9' 'InstallationFailed')) }
    $null = & $checkScript -InfrastructureFile (New-Infra 'check-attention' $e3) 6>&1 3>&1 2>&1
    Save-Fixture (Join-Path $e3 'update-events.jsonl') 'check-attention.update-events.jsonl' @{}

    # 4. Start, -WhatIf (mode WhatIf).
    $e4 = Reset-Folder (Join-Path $work 'start-whatif')
    $global:GenState = @{ CurrentVersion = '12.2607.1002.20'; State = 'UpdateAvailable'; HealthState = 'Success'; Updates = @((New-Update '12.2611.1004.9')) }
    $null = & $startScript -InfrastructureFile (New-Infra 'start-whatif' $e4) -Mode OnDemand -WhatIf 6>&1 3>&1 2>&1
    Save-Fixture (Join-Path $e4 'update-events.jsonl') 'start-whatif.update-events.jsonl' @{}

    # 5. Start, an install that was submitted (mode Install). The shadowed Invoke-Command answers; nothing is sent anywhere.
    $e6 = Reset-Folder (Join-Path $work 'start-install')
    $global:GenState = @{ CurrentVersion = '12.2607.1002.20'; State = 'UpdateAvailable'; HealthState = 'Success'; Updates = @((New-Update '12.2611.1004.9')) }
    $null = & $startScript -InfrastructureFile (New-Infra 'start-install' $e6) -Mode OnDemand 6>&1 3>&1 2>&1
    Save-Fixture (Join-Path $e6 'update-events.jsonl') 'start-install.update-events.jsonl' @{}

    # 6. The pre-cluster verification gate, Plan mode (the toolkit's own fc-san test file, with the cluster renamed clus01).
    $e5 = Reset-Folder (Join-Path $work 'gate-plan')
    $source = [IO.Path]::Combine($Toolkit, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    $planInfra = Join-Path $work 'gate-plan.yml'
    Set-Content -LiteralPath $planInfra -Value ((Get-Content -LiteralPath $source -Raw) -replace 'iic-clus01', 'clus01')
    $doc = Get-Content -LiteralPath $planInfra -Raw | ConvertFrom-Yaml -Ordered
    if (-not $doc.Contains('deployment') -or $doc['deployment'] -isnot [System.Collections.IDictionary]) { $doc['deployment'] = [ordered]@{} }
    $doc['deployment']['events_directory'] = $e5
    Set-Content -LiteralPath $planInfra -Value (ConvertTo-Yaml $doc)
    $reports = Join-Path $work 'gate-plan-reports'
    $null = Invoke-AzlPreClusterVerification -InfrastructureFile $planInfra -Mode Plan -ReportDirectory $reports
    # The Plan's next action names the script, the file and the report folder it was run with: generic paths instead of this machine's.
    Save-Fixture (Join-Path $e5 'precluster-plan-events.jsonl') 'gate-plan.precluster-plan-events.jsonl' @{
        $reports = 'C:\data\arm-report\verification\live'
        $planInfra = 'C:\data\infrastructure.yml'
        $Toolkit = 'C:\toolkit'
    }
    # 7. The post-deployment orchestrator (phase 06). The real orchestrator (Invoke-AzlPostDeployment, what Invoke-AzureLocalPostDeployment.ps1
    #    calls) runs with Azure blocked and every cluster answer made up. plan-example runs the toolkit's own step scripts against its example file;
    #    the others run the same orchestrator and the real step table with stub scripts at the paths of the steps, so each kind of result is there.
    $global:GenState = 'NODE01'
    $pdTable = [IO.Path]::Combine($Toolkit, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'PostDeploymentSteps.psd1')
    $pdSteps = (Import-PowerShellDataFile -LiteralPath $pdTable).Steps

    # A root with a stub at the path of every script of the step table. A stub has the parameters of the real script it stands for and does
    # what the AZL_PD_BEHAVIOUR variable says for its step (pass, warn, fail).
    function New-PostDeploymentStubRoot([string]$Name) {
        $root = Join-Path $work "$Name-root"
        foreach ($s in $pdSteps) {
            $path = Join-Path $root ([string]$s.Script)
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)
            $binding = if ($s.Plan -eq 'WhatIf') { '[CmdletBinding(SupportsShouldProcess)]' } else { '[CmdletBinding()]' }
            $extra = @(if ($s.Plan -eq 'WhatIf') { '[string]$LogPath', '[string]$ComputerName', '[pscredential]$Credential' })
            if ($s.ContainsKey('Arguments')) { foreach ($a in $s.Arguments) { $extra += "[switch]`$$($a.Name)" } }
            $body = @"
$binding
param([Parameter(Mandatory)][string]`$InfrastructureFile$(if ($extra) { ', ' + ($extra -join ', ') }))
`$behaviour = @{}; foreach (`$pair in (`$env:AZL_PD_BEHAVIOUR -split ';')) { if (`$pair -match '^(.+?)=(.+)`$') { `$behaviour[`$Matches[1]] = `$Matches[2] } }
`$mode = `$behaviour['$($s.Id)']
Write-Information '$($s.Title): the file was read' -InformationAction Continue
if (`$mode -eq 'warn') { Write-Warning 'a warning of $($s.Id)' }
if (`$mode -eq 'fail') { Write-Error 'the failure of $($s.Id)' -ErrorAction Continue; exit 1 }
exit 0
"@
            Set-Content -LiteralPath $path -Value $body
        }
        $root
    }

    # The infrastructure file of the stub runs: every step applies unless the change says otherwise (the toolkit's own run tests use this shape).
    function New-PostDeploymentFile([string]$Name, [string]$Events, [hashtable]$Change = @{}) {
        $d = [ordered]@{
            cluster = [ordered]@{ name = 'clus01'; witness = [ordered]@{ type = 'cloud'; storage_account = 'stwit01' } }
            scenario = [ordered]@{ storage_architecture = 'hybrid' }
            sdn = [ordered]@{ enabled = $true; prefix = 'iic'; dns_records = 'dynamic'; acknowledge_maintenance_window = $true }
            identity = [ordered]@{ active_directory = [ordered]@{ security_groups = @([ordered]@{ name = 'g1'; local_groups = @('Administrators') }) } }
            storage = [ordered]@{ volumes = @([ordered]@{ name = 'vol1'; size_gib = 100 }); paths = @([ordered]@{ name = 'sp1'; path = 'C:\ClusterStorage\vol1' }); vm_images = @([ordered]@{ name = 'img1' }) }
            networking = [ordered]@{ network_security_groups = @([ordered]@{ name = 'nsg1' }); logical_networks = @([ordered]@{ name = 'lnet1' }) }
            hardware = [ordered]@{ sbe = [ordered]@{ requirement = 'required'; source_path = '\\share\sbe' } }
            deployment = [ordered]@{ events_directory = $Events }
        }
        foreach ($k in $Change.Keys) {
            $parts = $k -split '\.'
            $node = $d
            for ($i = 0; $i -lt $parts.Count - 1; $i++) { if (-not $node.Contains($parts[$i])) { $node[$parts[$i]] = [ordered]@{} }; $node = $node[$parts[$i]] }
            if ($null -eq $Change[$k]) { $node.Remove($parts[-1]) } else { $node[$parts[-1]] = $Change[$k] }
        }
        $file = Join-Path $work "$Name.yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $d)
        $file
    }

    function Invoke-PostDeploymentScenario([string]$Name, [string]$File, [string]$Mode, [string]$Behaviour = '', [string]$Root = '') {
        $env:AZL_PD_BEHAVIOUR = $Behaviour
        $arguments = @{ InfrastructureFile = $File; LogPath = (Join-Path $work "$Name-log"); Mode = $Mode; SkipValidation = $true; RemoteCommand = { param([hashtable]$Call) $true } }
        if ($Root) { $arguments.RepositoryRoot = $Root; $arguments.StepTablePath = $pdTable }
        $null = Invoke-AzlPostDeployment @arguments 6>&1 3>&1 2>&1
    }

    Import-Module ([IO.Path]::Combine($Toolkit, 'scripts', 'common', 'post-deployment', 'AzlPostDeploymentRun.psm1')) -Force

    # 7a. The toolkit's own step scripts, Plan mode, against the example file: the first step that needs a secret stops the run (exit 2).
    $e7 = Reset-Folder (Join-Path $work 'plan-example')
    $example = Join-Path $work 'plan-example.yml'
    $doc = Get-Content -LiteralPath ([IO.Path]::Combine($Toolkit, 'config', 'variables', 'examples', 'infrastructure.example.yml')) -Raw | ConvertFrom-Yaml -Ordered
    if (-not $doc.Contains('deployment') -or $doc['deployment'] -isnot [System.Collections.IDictionary]) { $doc['deployment'] = [ordered]@{} }
    $doc['deployment']['events_directory'] = $e7
    Set-Content -LiteralPath $example -Value (ConvertTo-Yaml $doc)
    $exampleCluster = [string]$doc['cluster']['name']
    Invoke-PostDeploymentScenario -Name 'plan-example' -File $example -Mode Plan
    Save-Fixture (Join-Path $e7 'post-deployment-events.jsonl') 'plan-example.post-deployment-events.jsonl' @{ $exampleCluster = 'clus01'; $work = 'C:\data'; $Toolkit = 'C:\toolkit' }

    # 7b. Stub steps: a Plan where every step applies but SDN and the VM images (Skipped with their reasons) and every other step is planned.
    $root = New-PostDeploymentStubRoot 'stubs'
    $e8 = Reset-Folder (Join-Path $work 'plan-passed')
    Invoke-PostDeploymentScenario -Name 'plan-passed' -File (New-PostDeploymentFile 'plan-passed' $e8 @{ 'sdn.enabled' = $false; 'storage.vm_images' = $null }) -Mode Plan -Root $root
    Save-Fixture (Join-Path $e8 'post-deployment-events.jsonl') 'plan-passed.post-deployment-events.jsonl' @{ $work = 'C:\data'; $Toolkit = 'C:\toolkit' }

    # 7c. A Plan that stops after a step with a warning (exit 3).
    $e9 = Reset-Folder (Join-Path $work 'plan-warning')
    Invoke-PostDeploymentScenario -Name 'plan-warning' -File (New-PostDeploymentFile 'plan-warning' $e9) -Mode Plan -Behaviour 'ssh=warn' -Root $root
    Save-Fixture (Join-Path $e9 'post-deployment-events.jsonl') 'plan-warning.post-deployment-events.jsonl' @{ $work = 'C:\data'; $Toolkit = 'C:\toolkit' }

    # 7d. Apply, every step passes.
    $e10 = Reset-Folder (Join-Path $work 'apply-passed')
    Invoke-PostDeploymentScenario -Name 'apply-passed' -File (New-PostDeploymentFile 'apply-passed' $e10) -Mode Apply -Root $root
    Save-Fixture (Join-Path $e10 'post-deployment-events.jsonl') 'apply-passed.post-deployment-events.jsonl' @{ $work = 'C:\data'; $Toolkit = 'C:\toolkit' }

    # 7e. Apply, the storage volumes step fails (exit 1) and the steps after it are not run.
    $e11 = Reset-Folder (Join-Path $work 'apply-failed')
    Invoke-PostDeploymentScenario -Name 'apply-failed' -File (New-PostDeploymentFile 'apply-failed' $e11) -Mode Apply -Behaviour 'storage-volumes=fail' -Root $root
    Save-Fixture (Join-Path $e11 'post-deployment-events.jsonl') 'apply-failed.post-deployment-events.jsonl' @{ $work = 'C:\data'; $Toolkit = 'C:\toolkit' }
    "Wrote the fixtures to $Out"
}
finally {
    Remove-Item -LiteralPath 'Function:\Invoke-Command', 'Function:\Start-Sleep', 'Function:\Get-AzContext', 'Function:\Get-AzKeyVaultSecret' -ErrorAction SilentlyContinue
    Remove-Item Env:AZL_PD_BEHAVIOUR -ErrorAction SilentlyContinue
    Remove-Variable -Name GenState -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) { Remove-Item -Recurse -Force -LiteralPath $work }
}
