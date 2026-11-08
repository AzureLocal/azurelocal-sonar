Set-StrictMode -Version Latest

# The cluster resource (Microsoft.AzureStackHCI/clusters/<name>): Validate, Deployment, Update, Add node and Repair act on the
# cluster, not on one machine, so the page shows a cluster card for them. Most of what it shows is already in the state (the
# validation, deployment and update sections, the track). Only the cluster resource itself was not read: its status, connectivity,
# provisioning state, solution version and node count come from one read-only GET. Built from the Microsoft Learn REST reference
# (clusters, api-version 2026-10-01): unverified against a live run.

function Get-AzlSonarClusterResource {
    <#
    .SYNOPSIS
        One read-only GET of the cluster resource: { exists, status, connectivityStatus, provisioningState, solutionVersion, nodeCount, error }.
    .DESCRIPTION
        exists is $true for a 200, $false for a 404 (the resource is created by Validate) and $null when the answer is anything else
        (error then holds the text, never an exception). status is the cluster's own status, connectivityStatus its connection to Azure,
        provisioningState the ARM state, solutionVersion reportedProperties.clusterVersion and nodeCount the machines the cluster reports.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $out = [ordered]@{ exists = $null; status = ''; connectivityStatus = ''; provisioningState = ''; solutionVersion = ''; nodeCount = $null; error = '' }
    $path = '{0}/providers/Microsoft.AzureStackHCI/clusters/{1}?api-version={2}' -f (Get-AzlSonarResourceGroupPath -Config $Config), [uri]::EscapeDataString([string]$Config.clusterName), [string]$Config.apiVersion
    try { $response = Invoke-AzlSonarArmGet -Path $path }
    catch { $out.error = Protect-AzlSonarText -Text $_.Exception.Message; return $out }
    if ($response.StatusCode -eq 404) { $out.exists = $false; return $out }
    if ($response.StatusCode -ne 200) { $out.error = Protect-AzlSonarText -Text ([string]$response.ErrorMessage); return $out }
    $p = Get-AzlSonarMember $response.Body 'properties'
    $out.exists = $true
    $out.status = [string](Get-AzlSonarMember $p 'status' '')
    $out.connectivityStatus = [string](Get-AzlSonarMember $p 'connectivityStatus' '')
    $out.provisioningState = [string](Get-AzlSonarMember $p 'provisioningState' '')
    $out.solutionVersion = [string](Get-AzlSonarMember $p 'reportedProperties.clusterVersion' '')
    $nodes = Get-AzlSonarMember $p 'reportedProperties.nodes'
    if ($null -ne $nodes) { $out.nodeCount = @($nodes | Where-Object { $null -ne $_ }).Count }
    return $out
}

function Get-AzlSonarClusterObject {
    <#
    .SYNOPSIS
        The clusterResource object of /api/state (state.cluster is the cluster name): the cluster resource as read, plus the cluster-level facts the sections already hold.
    .DESCRIPTION
        { name, read (the resource was asked for), exists, status, connectivityStatus, provisioningState, solutionVersion, nodeCount,
        nodesConfigured, deploymentState (provisioningState of deploymentSettings), deploymentMode, error }. read is false when the
        monitor does not need the cluster (Discovery, Provisioning, OS configuration) or Azure has not been asked yet; exists is
        then $null. $Resource is the answer of Get-AzlSonarClusterResource, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [System.Collections.IDictionary]$Resource,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$DeploymentState = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$DeploymentMode = '',

        # deploymentSettings answered 404: the cluster resource cannot exist yet.
        [switch]$SettingsMissing
    )

    $cfgNodes = Get-AzlSonarMember $Config 'nodes' @()
    $configured = @($cfgNodes).Count
    $state = [ordered]@{
        name = [string](Get-AzlSonarMember $Config 'clusterName' ''); read = $false; exists = $null; status = ''; connectivityStatus = ''; provisioningState = ''
        solutionVersion = ''; nodeCount = $null; nodesConfigured = $configured
        deploymentState = [string]$DeploymentState; deploymentMode = [string]$DeploymentMode; error = ''
    }
    if ($null -ne $Resource) {
        $state.read = $true
        foreach ($k in 'exists', 'status', 'connectivityStatus', 'provisioningState', 'solutionVersion', 'nodeCount', 'error') { $state[$k] = $Resource[$k] }
    }
    elseif ($SettingsMissing) { $state.read = $true; $state.exists = $false }
    return $state
}
