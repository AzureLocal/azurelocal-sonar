Set-StrictMode -Version Latest

# Read-only facts for the page's Help box (/api/about) and its "What Sonar collected and is using" pop-down
# (/api/details). Everything here describes what Sonar already holds; nothing is fetched from Azure or a node, and nothing
# secret is ever added: a credential shows only as "set" or "not set", the subscription only as its first 8 characters.

$script:AzlSonarDocsBase = 'https://azurelocal.cloud/azurelocal-sonar/'
$script:AzlSonarRepoUrl = 'https://github.com/AzureLocal/azurelocal-sonar'

function Get-AzlSonarAbout {
    <#
    .SYNOPSIS
        The /api/about body: the Sonar version (from the module manifest) and the documentation links the Help box shows.
    .DESCRIPTION
        The page's files carry no http(s) URL, so the links come from here. Each link is { id, label, url }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([string]$Version = '')

    $base = $script:AzlSonarDocsBase
    return [ordered]@{
        name    = 'AzL Sonar'
        version = $Version
        summary = 'Watches an Azure Local build from provisioning and OS configuration through validation to deployment.'
        links   = @(
            [ordered]@{ id = 'docs'; label = 'Documentation'; url = $base }
            [ordered]@{ id = 'run'; label = 'Running Sonar, stage by stage'; url = $base + 'stages' }
            [ordered]@{ id = 'config'; label = 'Updating the config'; url = $base + 'config#update-the-configuration' }
            [ordered]@{ id = 'troubleshooting'; label = 'Troubleshooting'; url = $base + 'getting-started#if-something-does-not-work' }
            [ordered]@{ id = 'github'; label = 'Release notes and source on GitHub'; url = $script:AzlSonarRepoUrl }
        )
    }
}

function Get-AzlSonarConfigKeyName {
    <#
    .SYNOPSIS
        The key a setting has in the file Sonar was started from (infrastructure.yml schema 5, or the config file).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('cluster', 'resourceGroup', 'subscription', 'location', 'route', 'identity', 'nodes', 'address', 'ztpEvents', 'osConfigEvents', 'credential', 'pollSeconds')]
        [string]$Setting,

        [AllowEmptyString()]
        [string]$Kind = 'config'
    )

    $infrastructure = @{
        cluster = 'cluster.name'; resourceGroup = 'azure.resource_group'; subscription = 'azure.subscription_id'; location = 'azure.location'
        route = 'scenario.os_install'; identity = 'scenario.identity'; nodes = 'nodes[].name'; address = 'nodes[].network_adapters[]'
        ztpEvents = 'provisioning.simplified.evidence_path'; osConfigEvents = 'provisioning.simplified.evidence_path'; credential = 'credential.source (Sonar config only)'; pollSeconds = '-PollSeconds'
    }
    $configFile = @{
        cluster = 'clusterName'; resourceGroup = 'resourceGroup'; subscription = 'subscriptionId'; location = 'location'
        route = 'provisioningRoute'; identity = 'identityModel'; nodes = 'nodes[].name'; address = 'nodes[].address'
        ztpEvents = 'ztpEvents.path'; osConfigEvents = 'osConfigEventsPath'; credential = 'credential.source'; pollSeconds = 'pollSeconds'
    }
    if ($Kind -eq 'infrastructure') { return $infrastructure[$Setting] }
    return $configFile[$Setting]
}

function New-AzlSonarDetailFact {
    <#
    .SYNOPSIS
        The facts /api/details reports about the configuration, taken once at start (and updated when the file is re-read).
    .DESCRIPTION
        Holds names, the node list with addresses and the settings that are not set. Never the full subscription id (only
        its first 8 characters), never a credential, a Key Vault name or a secret name. Addresses are shown on this machine's
        loopback page only; they are not part of /api/config, the export or a recording.
    .OUTPUTS
        Ordered dictionary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [datetime]$ReadAt = [datetime]::UtcNow
    )

    $kind = [string](Get-AzlSonarMember $Config 'sourceKind' 'config')
    $path = [string](Get-AzlSonarMember $Config 'sourcePath' '')
    $fileName = if ($kind -eq 'json' -or -not $path) { '' } else { [System.IO.Path]::GetFileName($path) }
    $readFrom = switch ($kind) {
        'infrastructure' { 'infrastructure.yml' }
        'json' { 'a JSON string' }
        default { 'the config file' }
    }
    $key = { param($s) Get-AzlSonarConfigKeyName -Setting $s -Kind $kind }
    $subscription = [string](Get-AzlSonarMember $Config 'subscriptionId' '')
    $subscriptionShort = if ($subscription.Length -ge 8) { $subscription.Substring(0, 8) + '...' } elseif ($subscription) { $subscription.Substring(0, [Math]::Min(4, $subscription.Length)) + '...' } else { '' }
    $location = [string](Get-AzlSonarMember $Config 'location' '')
    $route = [string](Get-AzlSonarMember $Config 'provisioningRoute' 'auto')
    $identity = [string](Get-AzlSonarMember $Config 'identityModel' 'LocalIdentity')
    $ztpPath = [string](Get-AzlSonarMember $Config 'ztpEventsPath' '')
    $osConfigPath = [string](Get-AzlSonarMember $Config 'osConfigEventsPath' '')
    $domainAccount = [string](Get-AzlSonarLogAccount -Config $Config -DomainJoined $true -AdminsConfigured $true).domainAccount
    $maxRejections = (Get-AzlSonarBreakerSetting -Config $Config).MaxRejections

    $nodes = foreach ($node in @($Config.nodes)) {
        [ordered]@{ name = [string]$node.name; address = [string](Get-AzlSonarMember $node 'address' ''); seed = [bool](Get-AzlSonarMember $node 'seed' $false) }
    }
    $notSet = [System.Collections.Generic.List[object]]::new()
    if (-not $location) {
        $notSet.Add([ordered]@{ setting = 'location'; label = 'Region'; key = (& $key 'location'); effect = 'Sonar follows the deployment without it; the region is shown blank.' })
    }
    if ($route -ne 'oem-image' -and -not $ztpPath) {
        $notSet.Add([ordered]@{ setting = 'ztpEvents'; label = 'ZTP event file'; key = (& $key 'ztpEvents'); effect = 'The machine steps the nodes report (Device, Network, Restore) are not shown; Azure''s provisioning steps still are.' })
    }
    if (-not $osConfigPath) {
        $notSet.Add([ordered]@{ setting = 'osConfigEvents'; label = 'OS configuration event file'; key = (& $key 'osConfigEvents'); effect = 'The OS configuration mode shows no steps from the toolkit run; the machines show only what Azure reports.' })
    }
    $missingAddress = @($nodes | Where-Object { -not $_.address })
    if ($missingAddress.Count -gt 0) {
        $notSet.Add([ordered]@{ setting = 'address'; label = 'Node address'; key = (& $key 'address'); effect = "No address for $(($missingAddress | ForEach-Object { $_.name }) -join ', '): Sonar cannot read that node's log." })
    }

    return [ordered]@{
        cluster           = [string](Get-AzlSonarMember $Config 'clusterName' '')
        resourceGroup     = [string](Get-AzlSonarMember $Config 'resourceGroup' '')
        subscriptionShort = $subscriptionShort
        location          = $location
        route             = $route
        identity          = $identity
        pollSeconds       = [int](Get-AzlSonarMember $Config 'pollSeconds' 20)
        transport         = [string](Get-AzlSonarMember (Get-AzlSonarMember $Config 'logs') 'transport' 'auto')
        nodes             = @($nodes)
        ztpEventsFile     = $(if ($ztpPath) { [System.IO.Path]::GetFileName($ztpPath) } else { '' })
        ztpEventsPath     = $ztpPath
        osConfigEventsFile = $(if ($osConfigPath) { [System.IO.Path]::GetFileName($osConfigPath) } else { '' })
        osConfigEventsPath = $osConfigPath
        domainAccount     = $domainAccount
        maxRejections     = $maxRejections
        sourceKind        = $kind
        readFrom          = $readFrom
        fileName          = $fileName
        readAt            = Format-AzlSonarDate $ReadAt
        notSet            = @($notSet.ToArray())
        keys              = [ordered]@{
            cluster = (& $key 'cluster'); resourceGroup = (& $key 'resourceGroup'); subscription = (& $key 'subscription'); location = (& $key 'location')
            route = (& $key 'route'); identity = (& $key 'identity'); nodes = (& $key 'nodes'); ztpEvents = (& $key 'ztpEvents'); pollSeconds = (& $key 'pollSeconds')
        }
    }
}

function Get-AzlSonarIdentityMeaning {
    <#
    .SYNOPSIS
        One plain sentence on what the identity model means for the machines and for reading their logs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$IdentityModel)

    if ($IdentityModel -eq 'ActiveDirectory') {
        return 'Machines join your domain at deployment; Sonar reads the deployment log with a domain or local account.'
    }
    return 'Machines stay in a workgroup (local identity); Sonar reads the logs with the local administrator account.'
}

function ConvertTo-AzlSonarSafeText {
    <#
    .SYNOPSIS
        Free text for the page's Details: a local path is cut to its file name, secrets are masked, the length is capped.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Max = 240)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $out = [regex]::Replace($Text, '(?<![\w])(?:[A-Za-z]:[\\/]|\\\\)[^\s''";,)]*', { param($m) ($m.Value -split '[\\/]')[-1] })
    $out = Protect-AzlSonarText -Text $out
    if ($out.Length -gt $Max) { $out = $out.Substring(0, $Max - 1) + '...' }
    return $out
}

function Get-AzlSonarDetail {
    <#
    .SYNOPSIS
        The /api/details body: what Sonar collected and is using, each value with where it came from and when.
    .DESCRIPTION
        Target (cluster, resource group, the subscription's first 8 characters, region), Mode (route, identity and what it
        means), Nodes (name, address, seed), Sources (the Azure poll interval and its last answer, the ZTP event file with its
        event count and last event, the node log access state) and Config (the file read from, when it was read, the settings
        that are not set with their key, the Sonar version). Read-only; reads the shared state and the facts, nothing else.
        In a replay the facts come from the recording's config and the sources say they are recorded.
    .OUTPUTS
        Ordered dictionary.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server,

        [datetime]$Now = [datetime]::UtcNow
    )

    $facts = $Server['Facts']
    $shared = $Server.Shared
    $replaying = $Server['Mode'] -eq 'replay'
    $kind = if ($null -ne $facts) { [string]$facts.sourceKind } else { 'config' }
    $state = $null
    try { if ($shared.StateJson -and $shared.StateJson -ne 'null') { $state = ConvertFrom-Json -InputObject $shared.StateJson -Depth 64 } } catch { Write-Verbose "State not readable for the details: $($_.Exception.Message)" }
    $tailer = $shared['Tailer']

    $route = if ($null -ne $facts) { [string]$facts.route } else { '' }
    $routeShown = $route
    $routeSource = 'config'
    $provisioning = Get-AzlSonarMember $state 'provisioning'
    if ($route -eq 'auto' -or -not $route) {
        $detected = [string](Get-AzlSonarMember $provisioning 'route' '')
        if ($detected) { $routeShown = $detected; $routeSource = 'detected from Azure (the edge machines for the nodes)' }
    }
    $routeLabel = switch ($routeShown) {
        'simplified' { 'Simplified machine provisioning (ZTP)' }
        'oem-image' { 'OEM image + Arc registration' }
        default { 'Not known yet' }
    }
    $identity = if ($null -ne $facts) { [string]$facts.identity } else { 'LocalIdentity' }
    $identityLabel = if ($identity -eq 'ActiveDirectory') { 'Active Directory' } else { 'Local identity' }

    $configSource = if ($replaying) { 'the recording' } elseif ($null -ne $facts -and $facts.fileName) { $facts.fileName } else { 'the config' }
    $keyOf = { param($name) if ($null -ne $facts -and $facts.Contains('keys')) { $facts.keys[$name] } else { $null } }
    $fromKey = { param($name) if ($replaying) { 'from the recording' } else { "from $configSource" + $(if (& $keyOf $name) { ' ' + (& $keyOf $name) } else { '' }) } }

    $polledAt = Format-AzlSonarDate (ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $state 'polledAt'))
    $pollError = Get-AzlSonarMember $state 'pollError'
    $ztpInfo = $shared['ZtpInfo']
    $ztpEvents = if ($null -ne $ztpInfo -and $null -ne $ztpInfo['Count']) { [long]$ztpInfo['Count'] } else { 0 }
    $ztpFileFound = $false
    if ($null -ne $facts -and $facts.ztpEventsPath) { $ztpFileFound = Test-Path -LiteralPath $facts.ztpEventsPath -PathType Leaf }
    $osInfo = $shared['OsConfigInfo']
    $osEvents = if ($null -ne $osInfo -and $null -ne $osInfo['Count']) { [long]$osInfo['Count'] } else { 0 }
    $osFileFound = $false
    if ($null -ne $facts -and $facts.osConfigEventsPath) { $osFileFound = Test-Path -LiteralPath $facts.osConfigEventsPath -PathType Leaf }
    $lastLine = $null
    if (-not $replaying) {
        $window = Get-AzlSonarLogWindow -Shared $shared -Since ([Math]::Max([long]0, [long]$shared.LogSeq - 1))
        if (@($window.Lines).Count -gt 0) { $lastLine = [string]$window.Lines[-1]['received'] }
    }
    $watch = $shared['ConfigInfo']

    return [ordered]@{
        generatedAt = Format-AzlSonarDate $Now
        mode        = [string]$(if ($replaying) { 'replay' } else { 'live' })
        target      = [ordered]@{
            cluster       = [ordered]@{ value = [string](Get-AzlSonarMember $state 'cluster' $(if ($null -ne $facts) { $facts.cluster } else { $Server.ClusterName })); source = (& $fromKey 'cluster') }
            resourceGroup = [ordered]@{ value = $(if ($null -ne $facts) { [string]$facts.resourceGroup } else { '' }); source = (& $fromKey 'resourceGroup') }
            subscription  = [ordered]@{ value = $(if ($null -ne $facts) { [string]$facts.subscriptionShort } else { '' }); source = (& $fromKey 'subscription'); note = 'first 8 characters only' }
            region        = [ordered]@{ value = $(if ($null -ne $facts) { [string]$facts.location } else { '' }); source = (& $fromKey 'location') }
        }
        route       = [ordered]@{ value = $routeShown; label = $routeLabel; source = $(if ($routeSource -eq 'config') { & $fromKey 'route' } else { $routeSource }) }
        identity    = [ordered]@{ value = $identity; label = $identityLabel; meaning = (Get-AzlSonarIdentityMeaning -IdentityModel $identity); source = (& $fromKey 'identity') }
        nodes       = @($(if ($null -ne $facts) { $facts.nodes }))
        # the account-wide breaker of the domain account (its name and state, never a secret)
        logAccount  = Get-AzlSonarLogAccountDetail -Shared $shared -AccountName $(if ($null -ne $facts -and $facts.Contains('domainAccount')) { [string]$facts.domainAccount } else { '' }) -MaxRejections $(if ($null -ne $facts -and $facts.Contains('maxRejections')) { [int]$facts.maxRejections } else { 2 }) -Now $Now
        sources     = [ordered]@{
            azure     = [ordered]@{
                pollSeconds  = $(if ($null -ne $facts) { [int]$facts.pollSeconds } else { 0 })
                lastAnswerAt = $(if ($polledAt) { $polledAt } else { $null })
                ok           = $(if ($null -eq $state) { $false } else { -not $pollError })
                message      = $(if ($pollError) { ConvertTo-AzlSonarSafeText ([string]$pollError) } else { '' })
            }
            ztpEvents = [ordered]@{
                configured  = [bool]($null -ne $facts -and $facts.ztpEventsFile)
                file        = $(if ($null -ne $facts) { [string]$facts.ztpEventsFile } else { '' })
                fileFound   = [bool]$ztpFileFound
                events      = $ztpEvents
                lastEventAt = $(if ($null -ne $ztpInfo -and $ztpInfo['LastEventAt']) { [string]$ztpInfo['LastEventAt'] } else { $null })
            }
            osConfigEvents = [ordered]@{
                configured  = [bool]($null -ne $facts -and $facts.osConfigEventsFile)
                file        = $(if ($null -ne $facts) { [string]$facts.osConfigEventsFile } else { '' })
                fileFound   = [bool]$osFileFound
                events      = $osEvents
                lastEventAt = $(if ($null -ne $osInfo -and $osInfo['LastEventAt']) { [string]$osInfo['LastEventAt'] } else { $null })
            }
            nodeLogs  = [ordered]@{
                state       = [string](Get-AzlSonarMember $tailer 'state' 'unknown')
                node        = [string](Get-AzlSonarMember $tailer 'node' '')
                credential  = [string](Get-AzlSonarMember $tailer 'credential' '')
                transport   = $(if ($null -ne $facts) { [string]$facts.transport } else { '' })
                reason      = ConvertTo-AzlSonarSafeText ([string](Get-AzlSonarMember $tailer 'reason' ''))
                lastLineAt  = $lastLine
            }
        }
        config      = [ordered]@{
            readFrom        = $(if ($replaying) { 'the recording' } elseif ($null -ne $facts) { [string]$facts.readFrom } else { '' })
            file            = $(if ($null -ne $facts) { [string]$facts.fileName } else { '' })
            sourceKind      = $kind
            readAt          = $(if ($null -ne $watch -and $watch['ReadAt']) { [string]$watch['ReadAt'] } elseif ($null -ne $facts) { [string]$facts.readAt } else { $null })
            checkedAt       = $(if ($null -ne $watch -and $watch['CheckedAt']) { [string]$watch['CheckedAt'] } else { $null })
            checkEverySeconds = $(if ($kind -eq 'infrastructure' -and -not $replaying) { 60 } else { $null })
            lastChangeAt    = $(if ($null -ne $watch -and $watch['ChangedAt']) { [string]$watch['ChangedAt'] } else { $null })
            lastChangeNote  = $(if ($null -ne $watch -and $watch['Note']) { ConvertTo-AzlSonarSafeText ([string]$watch['Note']) } else { '' })
            notSet          = @($(if ($null -ne $facts -and -not $replaying) { $facts.notSet }))
            version         = [string]$Server.Version
        }
    }
}

function New-AzlSonarReplayDetailFact {
    <#
    .SYNOPSIS
        The details facts of a replay: only what the recording's config holds (names, route, identity, node names).
    .DESCRIPTION
        A recording keeps no subscription, no region and no addresses, so those stay empty and the page says the recording
        does not carry them.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [string]$ConfigJson,

        [string]$Cluster = '',

        [datetime]$ReadAt = [datetime]::UtcNow
    )

    $recorded = $null
    if ($ConfigJson -and $ConfigJson -ne 'null') {
        try { $recorded = ConvertFrom-Json -InputObject $ConfigJson -Depth 32 } catch { Write-Verbose "The recorded config is not readable: $($_.Exception.Message)" }
    }
    $recordedNodes = Get-AzlSonarMember $recorded 'nodes' @()
    $nodes = foreach ($n in $recordedNodes) {
        [pscustomobject]@{ name = [string](Get-AzlSonarMember $n 'name' ''); address = ''; seed = [bool](Get-AzlSonarMember $n 'seed' $false) }
    }
    $config = [pscustomobject]@{
        clusterName       = [string](Get-AzlSonarMember $recorded 'clusterName' $Cluster)
        resourceGroup     = [string](Get-AzlSonarMember $recorded 'resourceGroup' '')
        subscriptionId    = ''
        location          = ''
        provisioningRoute = [string](Get-AzlSonarMember $recorded 'provisioningRoute' 'auto')
        identityModel     = [string](Get-AzlSonarMember $recorded 'identityModel' 'LocalIdentity')
        pollSeconds       = [int](Get-AzlSonarMember $recorded 'pollSeconds' 20)
        nodes             = @($nodes)
        logs              = [pscustomobject]@{ transport = '' }
        ztpEventsPath     = ''
        osConfigEventsPath = ''
        sourceKind        = 'config'
        sourcePath        = ''
    }
    return New-AzlSonarDetailFact -Config $config -ReadAt $ReadAt
}
