#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The cluster card of Validate, Deployment, Update, Add node and Repair: the cluster resource is read once (read-only GET), the rest
# comes from what the state already holds. The ARM answer is mocked: no Azure, no node.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Config = Read-AzlSonarConfig -Path $script:SonarExampleConfig
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-11-07T18:10:00', [System.DateTimeKind]::Utc)
    function global:New-ClusterReply {
        param([int]$Code = 200, $Body = $null, [string]$Message = '')
        [pscustomobject]@{ StatusCode = $Code; Body = $Body; ErrorMessage = $Message; ErrorCode = '' }
    }
    $script:ClusterBody = [pscustomobject]@{ properties = [pscustomobject]@{
            status = 'ConnectedRecently'; connectivityStatus = 'Connected'; provisioningState = 'Succeeded'
            reportedProperties = [pscustomobject]@{ clusterVersion = '12.2609.0.1'; nodes = @([pscustomobject]@{ name = 'n1' }, [pscustomobject]@{ name = 'n2' }) } } }
    $script:SettingsBody = [pscustomobject]@{ properties = [pscustomobject]@{ deploymentMode = 'Deploy'; provisioningState = 'Provisioning'
            reportedProperties = [pscustomobject]@{ validationStatus = $null; deploymentStatus = $null } } }
}

AfterAll { Remove-Item -LiteralPath 'Function:\New-ClusterReply' -ErrorAction SilentlyContinue }

Describe 'Get-AzlSonarClusterResource (one read-only GET)' {
    It 'reads status, connectivity, provisioning state, solution version and the machine count of a cluster that exists' {
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { New-ClusterReply 200 $script:ClusterBody }
        $r = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterResource -Config $C }
        $r.exists | Should -BeTrue
        $r.status | Should -Be 'ConnectedRecently'
        $r.connectivityStatus | Should -Be 'Connected'
        $r.provisioningState | Should -Be 'Succeeded'
        $r.solutionVersion | Should -Be '12.2609.0.1'
        $r.nodeCount | Should -Be 2
        Should -Invoke Invoke-AzlSonarArmGet -ModuleName AzlSonar -Times 1 -Exactly -ParameterFilter { $Path -match '/providers/Microsoft\.AzureStackHCI/clusters/[^/]+\?api-version=' }
    }
    It 'says the resource does not exist on a 404 (Validate creates it), and keeps an error as text on anything else' {
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { New-ClusterReply 404 $null 'HTTP 404' }
        $a = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterResource -Config $C }
        $a.exists | Should -BeFalse
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { New-ClusterReply 403 $null 'The client does not have authorization to perform action password = Sup3rSecret!x' }
        $b = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterResource -Config $C }
        $null -eq $b.exists | Should -BeTrue
        $b.error | Should -Match 'authorization'
        $b.error | Should -Not -Match 'Sup3rSecret'
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { throw 'network down' }
        $c = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterResource -Config $C }
        $c.error | Should -Be 'network down'
    }
    It 'a cluster that reports no nodes has no machine count' {
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { New-ClusterReply 200 ([pscustomobject]@{ properties = [pscustomobject]@{ status = 'NotYetRegistered' } }) }
        $r = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterResource -Config $C }
        $null -eq $r.nodeCount | Should -BeTrue
        $r.status | Should -Be 'NotYetRegistered'
    }
}

Describe 'Get-AzlSonarClusterObject' {
    It 'is not read by default; a missing deployment settings object means the cluster does not exist yet; a resource passes through' {
        $n = @($script:Config.nodes).Count
        $none = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterObject -Config $C -Resource $null }
        $none.read | Should -BeFalse
        $null -eq $none.exists | Should -BeTrue
        $none.nodesConfigured | Should -Be $n
        $none.name | Should -Be $script:Config.clusterName
        $missing = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterObject -Config $C -Resource $null -SettingsMissing }
        $missing.read | Should -BeTrue
        $missing.exists | Should -BeFalse
        $res = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarClusterObject -Config $C -Resource ([ordered]@{ exists = $true; status = 'Connected'; connectivityStatus = 'Connected'; provisioningState = 'Succeeded'; solutionVersion = '1'; nodeCount = 2; error = '' }) -DeploymentState 'Provisioning' -DeploymentMode 'Deploy' }
        $res.read | Should -BeTrue
        $res.deploymentState | Should -Be 'Provisioning'
        $res.deploymentMode | Should -Be 'Deploy'
        $res.nodeCount | Should -Be 2
        ($res | ConvertTo-Json -Depth 5 | ConvertFrom-Json).exists | Should -BeTrue
    }
}

Describe 'the cluster object of the poll state' {
    It 'is read once the deployment settings exist' {
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar {
            if ($Path -match 'deploymentSettings') { return New-ClusterReply 200 $script:SettingsBody }
            if ($Path -match '/clusters/[^/?]+\?api-version') { return New-ClusterReply 200 $script:ClusterBody }
            return New-ClusterReply 404 $null 'HTTP 404'
        }
        $s = InModuleScope AzlSonar -Parameters @{ C = $script:Config; N = $script:Now } { param($C, $N) Get-AzlSonarDeploymentState -Config $C -Now $N }
        $s.clusterResource.read | Should -BeTrue
        $s.clusterResource.exists | Should -BeTrue
        $s.clusterResource.status | Should -Be 'ConnectedRecently'
        $s.clusterResource.solutionVersion | Should -Be '12.2609.0.1'
        $s.clusterResource.deploymentState | Should -Be 'Provisioning'
        $s.clusterResource.deploymentMode | Should -Be 'Deploy'
    }
    It 'says the cluster does not exist yet when the deployment settings do not, and does not read the cluster resource' {
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar { New-ClusterReply 404 $null 'HTTP 404' }
        $m = InModuleScope AzlSonar -Parameters @{ C = $script:Config; N = $script:Now } { param($C, $N) Get-AzlSonarDeploymentState -Config $C -Now $N }
        $m.clusterResource.exists | Should -BeFalse
        Should -Invoke Invoke-AzlSonarArmGet -ModuleName AzlSonar -Times 0 -ParameterFilter { $Path -match '/clusters/[^/?]+\?api-version' -and $Path -notmatch 'deploymentSettings|updates|updateSummaries|edgeMachines' }
    }
    It 'a monitor that does not need the cluster (Discovery, Provisioning, OsConfiguration) never reads it' {
        Mock Invoke-AzlSonarArmGet -ModuleName AzlSonar {
            if ($Path -match 'deploymentSettings') { return New-ClusterReply 200 $script:SettingsBody }
            return New-ClusterReply 404 $null 'HTTP 404'
        }
        $cfg = $script:Config.PSObject.Copy()
        $cfg | Add-Member -NotePropertyName monitor -NotePropertyValue 'Provisioning' -Force
        $s = InModuleScope AzlSonar -Parameters @{ C = $cfg; N = $script:Now } { param($C, $N) Get-AzlSonarDeploymentState -Config $C -Now $N }
        $s.clusterResource.read | Should -BeFalse
        $null -eq $s.clusterResource.exists | Should -BeTrue
    }
    It 'the initial state has a cluster object that was not read' {
        $s = InModuleScope AzlSonar -Parameters @{ C = $script:Config } { param($C) Get-AzlSonarInitialState -Config $C }
        $s.clusterResource.read | Should -BeFalse
        $s.clusterResource.name | Should -Be $script:Config.clusterName
    }
}
