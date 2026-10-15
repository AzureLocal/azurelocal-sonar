Set-StrictMode -Version Latest

# Azure Local 12.2609 (latest) deployment shapes that change what an operator should expect (hardening 2610, gap 3).
# The step tree is rendered from deploymentSettings whatever the shape is, so there is no new step logic: the config says
# which shape this is, and the page and the guidance say what Learn says about it.
#   identity   Local Identity with Azure Key Vault (previously AD-less), with or without Internal DNS (preview); Active Directory
#   pattern    Standard, or rack aware (two racks; deploymentSettings clusterPattern 'RackAware')
#   architecture  hyperconverged, or disaggregated (SAN)

function Get-AzlSonarDeploymentProfile {
    <#
    .SYNOPSIS
        What the config says about the shape of the deployment, with Learn's notes and warnings for combinations Learn does not support.
    .OUTPUTS
        { identityModel, clusterPattern, architecture, internalDns, notes[], warnings[] }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][object]$Config)

    $identity = [string](Get-AzlSonarMember $Config 'identityModel' '')
    $pattern = [string](Get-AzlSonarMember $Config 'clusterPattern' 'Standard')
    $architecture = [string](Get-AzlSonarMember $Config 'architecture' 'hyperconverged')
    $internalDns = [bool](Get-AzlSonarMember $Config 'internalDns' $false)
    $notes = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($identity -eq 'LocalIdentity') {
        $notes.Add('Local Identity with Azure Key Vault (previously AD-less): no Active Directory; one Key Vault per cluster; nodes stay in a workgroup; the local administrator is a non-built-in account with the same name on every node, which you keep up; SSH must be enabled on each node.')
        if ($internalDns) { $notes.Add('Internal DNS (preview, release 2609): Azure Local deploys the DNS service for cluster operations and infrastructure name resolution only; it is not for VMs, Arc VMs, Kubernetes or application records. The Networking tab asks for a zone name and a zone forwarder IP.') }
    }
    elseif ($identity -eq 'ActiveDirectory') {
        $notes.Add('Active Directory: the domain is prepared before deployment (OU, deployment user, naming prefix); the deployment (LCM) user is added to the local Administrators of the nodes and the nodes join the domain during deployment.')
        if ($internalDns) { $warnings.Add('internalDns is set, but Internal DNS (preview) belongs to Local Identity with Azure Key Vault deployments (Learn, release 2609); it is ignored for Active Directory.') }
    }

    if ($pattern -eq 'RackAware') {
        $notes.Add('Rack aware cluster: two racks (two rooms or buildings) with at most 1 ms round trip between them; a dedicated storage network intent; a cloud witness is required; new deployments only (Learn).')
        if ($identity -eq 'LocalIdentity') {
            $warnings.Add('Learn is not consistent about rack aware with Local Identity: the portal deployment article says a rack aware cluster can only be deployed with Active Directory in this release, while the Local Identity overview lists rack aware clustering as supported. Check the current Learn page before you rely on this combination.')
        }
    }
    if ($architecture -eq 'disaggregated') {
        $notes.Add('Disaggregated deployment (SAN): each node connects to the SAN before deployment; install the operating system and drivers, connect the SAN, then register with Arc. The orchestrator, the step tree and the logs are the same as for a hyperconverged deployment.')
    }
    return [ordered]@{
        identityModel = $identity
        clusterPattern = $pattern
        architecture  = $architecture
        internalDns   = $internalDns
        notes         = $notes.ToArray()
        warnings      = $warnings.ToArray()
    }
}
