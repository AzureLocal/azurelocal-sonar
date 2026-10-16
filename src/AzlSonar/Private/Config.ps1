Set-StrictMode -Version Latest

# Live on the seed node during Deploy (10 Oct 2026): CloudDeployment\Logs appears only mid-deployment;
# CloudContent\MASLogs, MASLogs, Observability and Bootstrap\Logs are written from the start.
$script:AzlSonarDefaultLogPaths = @(
    'C:\CloudContent\MASLogs',
    'C:\MASLogs',
    'C:\CloudDeployment\Logs',
    'C:\Observability',
    'C:\Windows\System32\Bootstrap\Logs'
)
$script:AzlSonarDefaultLogInclude = @('*.log', '*.txt', '*.xml')
$script:AzlSonarDefaultLogExclude = @('*.etl')

function Test-AzlSonarConfig {
    <#
    .SYNOPSIS
        Validates a parsed Sonar config object and returns the list of problems (empty when valid).
    .DESCRIPTION
        Pure function: no file, Azure or node access. Read-AzlSonarConfig calls it before normalising.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Config) {
        $problems.Add('The config is empty.')
        return , $problems.ToArray()
    }

    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $subscriptionId = [string](Get-AzlSonarMember $Config 'subscriptionId' '')
    if ($subscriptionId -notmatch $guidPattern) {
        $problems.Add('subscriptionId must be a GUID.')
    }

    $resourceGroup = [string](Get-AzlSonarMember $Config 'resourceGroup' '')
    if ($resourceGroup -notmatch '^[-\w\.\(\)]{1,90}$' -or $resourceGroup.EndsWith('.')) {
        $problems.Add('resourceGroup must be a valid resource group name (1-90 characters: letters, digits, - _ . ( ), not ending in a period).')
    }

    $clusterName = [string](Get-AzlSonarMember $Config 'clusterName' '')
    if ([string]::IsNullOrWhiteSpace($clusterName) -or $clusterName -match '[/\\?#]') {
        $problems.Add('clusterName is required and must not contain / \ ? #.')
    }

    foreach ($versionKey in 'apiVersion', 'apiVersionFallback', 'edgeApiVersion') {
        $version = Get-AzlSonarMember $Config $versionKey
        if ($null -ne $version -and [string]$version -notmatch '^\d{4}-\d{2}-\d{2}(-preview)?$') {
            $problems.Add("$versionKey must look like 2025-09-15 or 2025-09-15-preview.")
        }
    }

    $patternValue = Get-AzlSonarMember $Config 'clusterPattern'
    if ($null -ne $patternValue -and ([string]$patternValue).ToLowerInvariant() -notin 'standard', 'rackaware') {
        $problems.Add('clusterPattern must be Standard or RackAware.')
    }
    $architectureValue = Get-AzlSonarMember $Config 'architecture'
    if ($null -ne $architectureValue -and ([string]$architectureValue).ToLowerInvariant() -notin 'hyperconverged', 'disaggregated') {
        $problems.Add('architecture must be hyperconverged or disaggregated.')
    }
    $trackValue = Get-AzlSonarMember $Config 'track'
    if ($null -ne $trackValue -and ([string]$trackValue).ToLowerInvariant() -notin 'auto', 'deployment', 'update', 'add-node', 'repair') {
        $problems.Add('track must be auto, deployment, update, add-node or repair.')
    }
    $updateTrackValue = Get-AzlSonarMember $Config 'updateTrack'
    if ($null -ne $updateTrackValue -and ([string]$updateTrackValue).ToLowerInvariant() -notin 'auto', 'off') {
        $problems.Add('updateTrack must be auto or off.')
    }

    $identityModel = [string](Get-AzlSonarMember $Config 'identityModel' '')
    if ($identityModel -notin @('LocalIdentity', 'ActiveDirectory')) {
        $problems.Add('identityModel must be LocalIdentity or ActiveDirectory.')
    }

    $route = Get-AzlSonarMember $Config 'provisioningRoute'
    if ($null -ne $route -and [string]$route -notin @('auto', 'simplified', 'oem-image')) {
        $problems.Add('provisioningRoute must be auto, simplified or oem-image.')
    }

    $pollSeconds = Get-AzlSonarMember $Config 'pollSeconds'
    if ($null -ne $pollSeconds) {
        $pollValue = 0
        if (-not [int]::TryParse([string]$pollSeconds, [ref]$pollValue) -or $pollValue -lt 5 -or $pollValue -gt 3600) {
            $problems.Add('pollSeconds must be a whole number from 5 to 3600.')
        }
    }

    $recordPath = Get-AzlSonarMember $Config 'recordPath'
    if ($null -ne $recordPath -and ($recordPath -isnot [string] -or [string]::IsNullOrWhiteSpace($recordPath))) {
        $problems.Add('recordPath must be a file path (a recording, for example ./recordings/clus01.jsonl) when given.')
    }

    $ztpEvents = Get-AzlSonarMember $Config 'ztpEvents'
    if ($null -ne $ztpEvents) {
        $ztpPath = Get-AzlSonarMember $ztpEvents 'path'
        if ($ztpPath -isnot [string] -or [string]::IsNullOrWhiteSpace($ztpPath)) {
            $problems.Add('ztpEvents.path must be the path of the ZTP event file (JSON Lines written by azurelocal-ztp), for example ./ztp-events.jsonl.')
        }
    }

    $nodes = ConvertTo-AzlSonarArray (Get-AzlSonarMember $Config 'nodes')
    if ($nodes.Count -eq 0) {
        $problems.Add('nodes must list at least one node.')
    }
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seedCount = 0
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $node = $nodes[$i]
        $name = [string](Get-AzlSonarMember $node 'name' '')
        if ([string]::IsNullOrWhiteSpace($name)) {
            $problems.Add("nodes[$i].name is required.")
        }
        elseif (-not $names.Add($name)) {
            $problems.Add("nodes[$i].name '$name' is listed more than once.")
        }
        $address = [string](Get-AzlSonarMember $node 'address' '')
        if ([string]::IsNullOrWhiteSpace($address) -or $address -match '\s') {
            $problems.Add("nodes[$i].address is required (host name or IP address).")
        }
        $arcName = Get-AzlSonarMember $node 'arcMachineName'
        if ($null -ne $arcName -and ([string]::IsNullOrWhiteSpace([string]$arcName) -or [string]$arcName -match '[/\\?#]')) {
            $problems.Add("nodes[$i].arcMachineName must be a resource name when given.")
        }
        $seed = Get-AzlSonarMember $node 'seed'
        if ($null -ne $seed) {
            if ($seed -isnot [bool]) { $problems.Add("nodes[$i].seed must be true or false.") }
            elseif ($seed) { $seedCount++ }
        }
    }
    if ($seedCount -gt 1) {
        $problems.Add('Only one node can be the seed node (seed: true).')
    }

    $logs = Get-AzlSonarMember $Config 'logs'
    if ($null -ne $logs) {
        $paths = Get-AzlSonarMember $logs 'paths'
        if ($null -ne $paths) {
            $pathList = ConvertTo-AzlSonarArray $paths
            if ($pathList.Count -eq 0 -or @($pathList | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                $problems.Add('logs.paths must be a list of non-empty paths.')
            }
        }
        foreach ($patternKey in 'include', 'exclude') {
            $patterns = Get-AzlSonarMember $logs $patternKey
            if ($null -ne $patterns) {
                $patternList = ConvertTo-AzlSonarArray $patterns
                $isEmptyAllowed = $patternKey -eq 'exclude'
                if ((-not $isEmptyAllowed -and $patternList.Count -eq 0) -or @($patternList | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                    $problems.Add("logs.$patternKey must be a list of file name patterns such as *.log.")
                }
            }
        }
        $limits = @(
            @{ Key = 'maxLinesPerPoll'; Min = 1; Max = 10000 },
            @{ Key = 'recurseDepth'; Min = 0; Max = 10 },
            @{ Key = 'pollSeconds'; Min = 1; Max = 3600 },
            @{ Key = 'activeWindowMinutes'; Min = 1; Max = 10080 }
        )
        foreach ($limit in $limits) {
            $value = Get-AzlSonarMember $logs $limit.Key
            if ($null -ne $value) {
                $number = 0
                if (-not [int]::TryParse([string]$value, [ref]$number) -or $number -lt $limit.Min -or $number -gt $limit.Max) {
                    $problems.Add("logs.$($limit.Key) must be a whole number from $($limit.Min) to $($limit.Max).")
                }
            }
        }
        $transport = Get-AzlSonarMember $logs 'transport'
        if ($null -ne $transport -and [string]$transport -notin @('auto', 'winrm', 'ssh')) {
            $problems.Add('logs.transport must be auto, winrm or ssh.')
        }
    }

    $credential = Get-AzlSonarMember $Config 'credential'
    if ($null -ne $credential) {
        $source = [string](Get-AzlSonarMember $credential 'source' 'prompt')
        if ($source -notin @('prompt', 'parameter', 'keyvault')) {
            $problems.Add('credential.source must be prompt, parameter or keyvault.')
        }
        if ($source -eq 'keyvault') {
            foreach ($key in 'vault', 'usernameSecret', 'passwordSecret') {
                if ([string]::IsNullOrWhiteSpace([string](Get-AzlSonarMember $credential $key ''))) {
                    $problems.Add("credential.$key is required when credential.source is keyvault.")
                }
            }
        }
        foreach ($forbidden in 'password', 'secret', 'secretValue') {
            if ($null -ne (Get-AzlSonarMember $credential $forbidden)) {
                $problems.Add("credential.$forbidden is not allowed: never put secrets in the config. Use prompt, -Credential or Key Vault.")
            }
        }
    }

    return , $problems.ToArray()
}

function Read-AzlSonarConfig {
    <#
    .SYNOPSIS
        Reads, validates and normalises a Sonar config file (sonar.config.json).
    .DESCRIPTION
        Applies the documented defaults (apiVersion, edgeApiVersion, provisioningRoute, pollSeconds, log paths, include and
        exclude patterns, recurseDepth, activeWindowMinutes, maxLinesPerPoll, logs.pollSeconds, logs.transport, credential
        source) and marks the seed node. nodes[].arcMachineName is optional: when it is missing, arcMachineName holds the
        node name and arcMachineNameSet is $false, so the poller may resolve the real Arc machine (simplified machine
        provisioning names it <device-id>-1, read from the edge machine's arcMachineResourceId). Throws one error listing every problem
        when the config is not valid. Never reads secrets: Key Vault secret names are kept as names only.
    .PARAMETER Path
        Path to the JSON config file.
    .PARAMETER Json
        The config as a JSON string (useful for tests).
    .EXAMPLE
        $config = Read-AzlSonarConfig -Path ./config/clus01.json
    .OUTPUTS
        PSCustomObject with subscriptionId, resourceGroup, clusterName, apiVersion, edgeApiVersion, provisioningRoute,
        identityModel, pollSeconds, nodes[] (name, address, arcMachineName, arcMachineNameSet, seed), seedNode, logs, recordPath,
        credential.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [string]$Json
    )

    $ErrorActionPreference = 'Stop'
    $source = 'JSON string'
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Sonar config file not found: $Path"
        }
        $source = (Resolve-Path -LiteralPath $Path).ProviderPath
        $Json = Get-Content -LiteralPath $source -Raw
    }

    try {
        $raw = ConvertFrom-Json -InputObject $Json -Depth 32
    }
    catch {
        throw "Sonar config ($source) is not valid JSON: $($_.Exception.Message)"
    }

    $problems = Test-AzlSonarConfig -Config $raw
    if ($problems.Count -gt 0) {
        throw ("Sonar config ($source) is not valid:`n - " + ($problems -join "`n - "))
    }

    $nodes = [System.Collections.Generic.List[object]]::new()
    $seedName = $null
    foreach ($node in (ConvertTo-AzlSonarArray $raw.nodes)) {
        $name = [string]$node.name
        $arcValue = Get-AzlSonarMember $node 'arcMachineName'
        $arcName = if ($null -ne $arcValue) { [string]$arcValue } else { $name }
        $isSeed = [bool](Get-AzlSonarMember $node 'seed' $false)
        if ($isSeed) { $seedName = $name }
        $nodes.Add([pscustomobject]@{
                name              = $name
                address           = [string]$node.address
                arcMachineName    = $arcName
                arcMachineNameSet = $null -ne $arcValue
                seed              = $isSeed
            })
    }
    if (-not $seedName) {
        $nodes[0].seed = $true
        $seedName = $nodes[0].name
        Write-Warning "No node is marked seed: true; using the first node ($seedName) as the seed node for logs."
    }

    $logs = Get-AzlSonarMember $raw 'logs'
    $pollSeconds = [int](Get-AzlSonarMember $raw 'pollSeconds' 20)
    $logPaths = Get-AzlSonarMember $logs 'paths'
    $include = Get-AzlSonarMember $logs 'include'
    $exclude = Get-AzlSonarMember $logs 'exclude'
    $logsNormalised = [pscustomobject]@{
        paths               = [string[]]$(if ($null -ne $logPaths) { ConvertTo-AzlSonarArray $logPaths } else { $script:AzlSonarDefaultLogPaths })
        include             = [string[]]$(if ($null -ne $include) { ConvertTo-AzlSonarArray $include } else { $script:AzlSonarDefaultLogInclude })
        exclude             = [string[]]$(if ($null -ne $exclude) { ConvertTo-AzlSonarArray $exclude } else { $script:AzlSonarDefaultLogExclude })
        maxLinesPerPoll     = [int](Get-AzlSonarMember $logs 'maxLinesPerPoll' 500)
        recurseDepth        = [int](Get-AzlSonarMember $logs 'recurseDepth' 3)
        activeWindowMinutes = [int](Get-AzlSonarMember $logs 'activeWindowMinutes' 30)
        pollSeconds         = [int](Get-AzlSonarMember $logs 'pollSeconds' $pollSeconds)
        transport           = ([string](Get-AzlSonarMember $logs 'transport' 'auto')).ToLowerInvariant()
    }

    $credential = Get-AzlSonarMember $raw 'credential'
    $credentialSource = [string](Get-AzlSonarMember $credential 'source' 'prompt')
    $credentialNormalised = [pscustomobject]@{
        source         = $credentialSource
        vault          = [string](Get-AzlSonarMember $credential 'vault' '')
        usernameSecret = [string](Get-AzlSonarMember $credential 'usernameSecret' '')
        passwordSecret = [string](Get-AzlSonarMember $credential 'passwordSecret' '')
    }

    $identityModel = if ([string]$raw.identityModel -eq 'ActiveDirectory') { 'ActiveDirectory' } else { 'LocalIdentity' }
    $nodeArray = $nodes.ToArray()

    # recordPath: relative to the config file's folder (to the current folder for a JSON string).
    $recordPath = [string](Get-AzlSonarMember $raw 'recordPath' '')
    if ($recordPath -and -not [System.IO.Path]::IsPathRooted($recordPath) -and $PSCmdlet.ParameterSetName -eq 'Path') {
        $recordPath = [System.IO.Path]::GetFullPath((Join-Path -Path ([System.IO.Path]::GetDirectoryName($source)) -ChildPath $recordPath))
    }

    # ztpEvents.path: the event file the ZTP provisioning scripts write; relative to the config file's folder.
    $ztpEventsPath = [string](Get-AzlSonarMember (Get-AzlSonarMember $raw 'ztpEvents') 'path' '')
    if ($ztpEventsPath -and -not [System.IO.Path]::IsPathRooted($ztpEventsPath) -and $PSCmdlet.ParameterSetName -eq 'Path') {
        $ztpEventsPath = [System.IO.Path]::GetFullPath((Join-Path -Path ([System.IO.Path]::GetDirectoryName($source)) -ChildPath $ztpEventsPath))
    }

    return [pscustomobject]@{
        subscriptionId = ([string]$raw.subscriptionId).ToLowerInvariant()
        resourceGroup  = [string]$raw.resourceGroup
        clusterName    = [string]$raw.clusterName
        # GA versions, current on Microsoft Learn for 12.2609 (latest); a preview version stays configurable. The fallback is
        # tried once when the first is not accepted ('' = no fallback).
        apiVersion     = [string](Get-AzlSonarMember $raw 'apiVersion' '2026-10-01')
        apiVersionFallback = [string](Get-AzlSonarMember $raw 'apiVersionFallback' '2025-10-01')
        edgeApiVersion = [string](Get-AzlSonarMember $raw 'edgeApiVersion' '2026-10-01')
        provisioningRoute = ([string](Get-AzlSonarMember $raw 'provisioningRoute' 'auto')).ToLowerInvariant()
        # Which operation is followed once the deployment is done: auto (an update when Azure reports one), update, add-node or repair.
        # The shape of the deployment (release 2609): what the page and the guidance say about it; the steps come from Azure either way.
        clusterPattern = $(if (([string](Get-AzlSonarMember $raw 'clusterPattern' 'Standard')).ToLowerInvariant() -eq 'rackaware') { 'RackAware' } else { 'Standard' })
        architecture   = ([string](Get-AzlSonarMember $raw 'architecture' 'hyperconverged')).ToLowerInvariant()
        internalDns    = [bool](Get-AzlSonarMember $raw 'internalDns' $false)
        track          = ([string](Get-AzlSonarMember $raw 'track' 'auto')).ToLowerInvariant()
        updateTrack    = ([string](Get-AzlSonarMember $raw 'updateTrack' 'auto')).ToLowerInvariant()
        identityModel  = $identityModel
        pollSeconds    = $pollSeconds
        nodes          = $nodeArray
        seedNode       = @($nodeArray | Where-Object { $_.seed })[0]
        logs           = $logsNormalised
        credential     = $credentialNormalised
        recordPath     = $recordPath
        ztpEventsPath  = $ztpEventsPath
        sourcePath     = $source
    }
}

function ConvertTo-AzlSonarPublicConfig {
    <#
    .SYNOPSIS
        The config as served by /api/config and the export bundle: no secrets, no secret names, no addresses.
        { clusterName, cluster, resourceGroup, identityModel, provisioningRoute, nodes[{name, seed}], logs{paths[]}, pollSeconds,
          startedAt, serverId }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [object]$StartedAt,

        [AllowNull()]
        [string]$ServerId
    )

    $nodes = foreach ($node in $Config.nodes) {
        [ordered]@{ name = $node.name; seed = [bool]$node.seed }
    }
    return [ordered]@{
        clusterName   = $Config.clusterName
        cluster       = $Config.clusterName
        resourceGroup = $Config.resourceGroup
        identityModel = $Config.identityModel
        provisioningRoute = $Config.provisioningRoute
        nodes         = @($nodes)
        logs          = [ordered]@{ paths = [string[]]@($Config.logs.paths) }
        pollSeconds   = $Config.pollSeconds
        profile       = $(if ($null -ne (Get-AzlSonarMember $Config 'clusterPattern')) {
                $p = Get-AzlSonarDeploymentProfile -Config $Config
                [ordered]@{ clusterPattern = $p.clusterPattern; architecture = $p.architecture; internalDns = $p.internalDns; notes = [string[]]@($p.notes) }
            } else { $null })
        startedAt     = Format-AzlSonarDate $StartedAt
        serverId      = if ($ServerId) { $ServerId } else { $null }
    }
}
