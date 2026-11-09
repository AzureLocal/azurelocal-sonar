Set-StrictMode -Version Latest

# Commands that create and edit Sonar's config file, and the guided setup. Each way of configuring Sonar (these commands,
# a hand-written file, or the master infrastructure.yml) ends in the same object: Read-AzlSonarConfig.
# Nothing here asks for or stores a password: the log account comes from -Credential, a prompt at start, or Key Vault.

function Write-AzlSonarConfigFile {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Config)

    $folder = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $json = ConvertTo-Json -InputObject $Config -Depth 32
    Set-Content -LiteralPath $Path -Value $json -Encoding utf8
}

function Read-AzlSonarRawConfigFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Sonar config file not found: $Path. Create it with New-AzlSonarConfig -Path $Path" }
    try { return ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw) -Depth 32 }
    catch { throw "Sonar config ($Path) is not valid JSON: $($_.Exception.Message)" }
}

function New-AzlSonarConfig {
    <#
    .SYNOPSIS
        Creates a Sonar config file (JSON) from the values you give, or asks for each value with -Interactive.
    .DESCRIPTION
        Writes the cluster, route, identity model, ZTP event file and poll interval. The file starts with no nodes: add them
        with Add-AzlSonarNode (the guided mode asks for them). The log account is not stored: the file says credential.source
        prompt, so Sonar asks for it at start, or give -Credential to Start-AzlSonar.ps1.
        With -Interactive, a signed-in Az context pre-fills the subscription (the subscriptions the account can see are
        listed) and the resource group. Never asks for a password.
    .PARAMETER Path
        Where to write the config file (for example ./config/clus01.json).
    .PARAMETER Route
        auto (default; Sonar works it out), simplified (simplified machine provisioning, azurelocal-ztp) or oem-image.
    .PARAMETER ZtpEventsPath
        The event file azurelocal-ztp writes (ztp-events.jsonl). Only for the simplified route.
    .EXAMPLE
        New-AzlSonarConfig -Path ./config/clus01.json -SubscriptionId $sub -ResourceGroup rg-example-azl -ClusterName clus01 -Route simplified
        Add-AzlSonarNode -Path ./config/clus01.json -Name node01 -Address 192.0.2.11 -Seed
    .EXAMPLE
        New-AzlSonarConfig -Path ./config/clus01.json -Interactive
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$SubscriptionId,

        [string]$ResourceGroup,

        [string]$ClusterName,

        [ValidateSet('auto', 'simplified', 'oem-image')]
        [string]$Route = 'auto',

        [ValidateSet('LocalIdentity', 'ActiveDirectory')]
        [string]$IdentityModel = 'LocalIdentity',

        [string]$ZtpEventsPath,

        [ValidateRange(5, 3600)]
        [int]$PollSeconds,

        [switch]$Interactive,

        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'
    if ((Test-Path -LiteralPath $Path) -and -not $Force) { throw "$Path already exists. Use -Force to replace it, or Add-AzlSonarNode to change its nodes." }

    $nodes = @()
    if ($Interactive) {
        $answers = Invoke-AzlSonarConfigWizard -Bound $PSBoundParameters
        $SubscriptionId = $answers.SubscriptionId; $ResourceGroup = $answers.ResourceGroup; $ClusterName = $answers.ClusterName
        $Route = $answers.Route; $IdentityModel = $answers.IdentityModel; $ZtpEventsPath = $answers.ZtpEventsPath
        if ($answers.PollSeconds) { $PollSeconds = $answers.PollSeconds }
        $nodes = @($answers.Nodes)
    }
    else {
        $missing = @(@{ N = 'SubscriptionId'; V = $SubscriptionId }, @{ N = 'ResourceGroup'; V = $ResourceGroup }, @{ N = 'ClusterName'; V = $ClusterName } | Where-Object { -not $_.V } | ForEach-Object { "-$($_.N)" })
        if ($missing.Count -gt 0) { throw "Missing $($missing -join ', '). Give them, or run New-AzlSonarConfig -Path $Path -Interactive to be asked for each value." }
    }

    $config = [ordered]@{
        subscriptionId    = $SubscriptionId.ToLowerInvariant()
        resourceGroup     = $ResourceGroup
        clusterName       = $ClusterName
        provisioningRoute = $Route
        identityModel     = $IdentityModel
    }
    if ($PollSeconds) { $config['pollSeconds'] = $PollSeconds }
    $config['nodes'] = @($nodes)
    if ($ZtpEventsPath) { $config['ztpEvents'] = [ordered]@{ path = $ZtpEventsPath } }
    $config['credential'] = [ordered]@{ source = 'prompt' }

    if ($PSCmdlet.ShouldProcess($Path, 'Create the Sonar config file')) {
        Write-AzlSonarConfigFile -Path $Path -Config $config
        $problems = @(Test-AzlSonarConfig -Path $Path)
        $remaining = @($problems | Where-Object { $_ -notlike 'nodes must list*' })
        if ($remaining.Count -gt 0) { Write-Warning ("The file was written but needs attention:`n - " + ($remaining -join "`n - ")) }
        if (@($nodes).Count -eq 0) { Write-Information -MessageData "Created $Path. Next: Add-AzlSonarNode -Path $Path -Name <node> -Address <ip or host> -Seed" -InformationAction Continue }
        else { Write-Information -MessageData "Created $Path. Start Sonar with: ./Start-AzlSonar.ps1 -ConfigPath $Path" -InformationAction Continue }
        return Get-Item -LiteralPath $Path
    }
}

function Add-AzlSonarNode {
    <#
    .SYNOPSIS
        Adds a node to a Sonar config file (JSON). -Seed makes it the seed node (the one whose logs are read).
    .NOTES
        The file is rewritten as plain JSON: comments in a hand-commented file are not kept.
    .EXAMPLE
        Add-AzlSonarNode -Path ./config/clus01.json -Name node02 -Address 192.0.2.12
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Address,
        [string]$ArcMachineName,
        [switch]$Seed
    )

    $ErrorActionPreference = 'Stop'
    if ($Name -match '[/\\?#]' -or [string]::IsNullOrWhiteSpace($Name)) { throw 'Name is required and must not contain / \ ? #.' }
    if ($Address -match '\s' -or [string]::IsNullOrWhiteSpace($Address)) { throw 'Address must be a host name or IP address without spaces.' }
    $config = Read-AzlSonarRawConfigFile -Path $Path
    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($node in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $config 'nodes'))) { $nodes.Add($node) }
    if (@($nodes | Where-Object { [string]$_.name -eq $Name }).Count -gt 0) { throw "Node '$Name' is already in $Path. Remove it first (Remove-AzlSonarNode) to change its address." }
    if ($Seed) { foreach ($node in $nodes) { if ($null -ne (Get-AzlSonarMember $node 'seed')) { $node.seed = $false } } }
    $entry = [ordered]@{ name = $Name; address = $Address }
    if ($ArcMachineName) { $entry['arcMachineName'] = $ArcMachineName }
    if ($Seed) { $entry['seed'] = $true }
    $nodes.Add([pscustomobject]$entry)
    $config | Add-Member -NotePropertyName nodes -NotePropertyValue $nodes.ToArray() -Force
    if ($PSCmdlet.ShouldProcess($Path, "Add node $Name")) { Write-AzlSonarConfigFile -Path $Path -Config $config }
}

function Remove-AzlSonarNode {
    <#
    .SYNOPSIS
        Removes a node from a Sonar config file (JSON). When the seed node is removed, the first remaining node becomes the seed.
    .EXAMPLE
        Remove-AzlSonarNode -Path ./config/clus01.json -Name node02
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $ErrorActionPreference = 'Stop'
    $config = Read-AzlSonarRawConfigFile -Path $Path
    $all = ConvertTo-AzlSonarArray (Get-AzlSonarMember $config 'nodes')
    if (@($all | Where-Object { [string]$_.name -eq $Name }).Count -eq 0) { throw "Node '$Name' is not in $Path (nodes: $((@($all | ForEach-Object { $_.name })) -join ', '))." }
    $remaining = @($all | Where-Object { [string]$_.name -ne $Name })
    $hadSeed = @($all | Where-Object { (Get-AzlSonarMember $_ 'seed') -eq $true }).Count -gt 0
    $stillSeed = @($remaining | Where-Object { (Get-AzlSonarMember $_ 'seed') -eq $true }).Count -gt 0
    if ($hadSeed -and -not $stillSeed -and $remaining.Count -gt 0) { $remaining[0] | Add-Member -NotePropertyName seed -NotePropertyValue $true -Force }
    $config | Add-Member -NotePropertyName nodes -NotePropertyValue $remaining -Force
    if ($PSCmdlet.ShouldProcess($Path, "Remove node $Name")) { Write-AzlSonarConfigFile -Path $Path -Config $config }
}

# Keys Set-AzlSonarConfig can change: the dotted key, its kind (text, number, flag, list) and the allowed words when it
# has a short fixed list. nodes are changed with Add-AzlSonarNode and Remove-AzlSonarNode.
$script:AzlSonarSettableKeys = [ordered]@{
    'subscriptionId'            = @{ Kind = 'text' }
    'resourceGroup'             = @{ Kind = 'text' }
    'clusterName'               = @{ Kind = 'text' }
    'location'                  = @{ Kind = 'text' }
    'identityModel'             = @{ Kind = 'text'; Words = @('LocalIdentity', 'ActiveDirectory') }
    'provisioningRoute'         = @{ Kind = 'text'; Words = @('auto', 'simplified', 'oem-image') }
    'accessToken'               = @{ Kind = 'flag' }
    'tokenFile'                 = @{ Kind = 'text' }
    'maxEventStreams'           = @{ Kind = 'number' }
    'pollSeconds'               = @{ Kind = 'number' }
    'recordPath'                = @{ Kind = 'text' }
    'clusterPattern'            = @{ Kind = 'text'; Words = @('Standard', 'RackAware') }
    'architecture'              = @{ Kind = 'text'; Words = @('hyperconverged', 'disaggregated') }
    'internalDns'               = @{ Kind = 'flag' }
    'track'                     = @{ Kind = 'text'; Words = @('auto', 'deployment', 'update', 'add-node', 'repair') }
    'monitor'                   = @{ Kind = 'text'; Words = @('Auto', 'Discovery', 'Provisioning', 'OsConfiguration', 'Validate', 'Deployment', 'Update', 'AddNode', 'Repair') }
    'updateTrack'               = @{ Kind = 'text'; Words = @('auto', 'off') }
    'apiVersion'                = @{ Kind = 'text' }
    'apiVersionFallback'        = @{ Kind = 'text' }
    'edgeApiVersion'            = @{ Kind = 'text' }
    'ztpEvents.path'            = @{ Kind = 'text' }
    'osConfigEventsPath'        = @{ Kind = 'text' }
    'armEventsPath'             = @{ Kind = 'text' }
    'verificationEventsPath'    = @{ Kind = 'text' }
    'discoveryPath'             = @{ Kind = 'text' }
    'credential.source'         = @{ Kind = 'text'; Words = @('prompt', 'parameter', 'keyvault') }
    'credential.vault'          = @{ Kind = 'text' }
    'credential.usernameSecret' = @{ Kind = 'text' }
    'credential.passwordSecret' = @{ Kind = 'text' }
    'logs.paths'                = @{ Kind = 'list' }
    'logs.include'              = @{ Kind = 'list' }
    'logs.exclude'              = @{ Kind = 'list' }
    'logs.recurseDepth'         = @{ Kind = 'number' }
    'logs.activeWindowMinutes'  = @{ Kind = 'number' }
    'logs.maxLinesPerPoll'      = @{ Kind = 'number' }
    'logs.pollSeconds'          = @{ Kind = 'number' }
    'logs.transport'            = @{ Kind = 'text'; Words = @('auto', 'winrm', 'ssh') }
}

function Set-AzlSonarConfig {
    <#
    .SYNOPSIS
        Changes one setting in a Sonar config file (JSON), or removes it so the default applies again.
    .DESCRIPTION
        The command for "update the config file" without opening an editor. -Key is the key as written in
        docs/config.md (a dotted path such as logs.transport or ztpEvents.path). The new value is checked by the same
        rules Sonar applies at start: when the change would make the file invalid, nothing is written and the problem is
        named. Problems the file already had (for example no nodes yet) do not stop the change.
        Nodes are changed with Add-AzlSonarNode and Remove-AzlSonarNode. A secret is never accepted (credential.password
        and the like are refused): the log account comes from the prompt, -Credential or Key Vault names.
        List settings (logs.paths, logs.include, logs.exclude) take several values: -Value 'C:\MASLogs', 'C:\Other'.
        Without -Key, lists the keys this command can set.
    .NOTES
        The file is rewritten as plain JSON: comments in a hand-commented file are not kept.
    .PARAMETER Path
        The config file.
    .PARAMETER Key
        The setting, for example pollSeconds, identityModel, logs.transport.
    .PARAMETER Value
        The new value. A number key takes a whole number, accessToken takes true or false, a list key takes one or more values.
    .PARAMETER Remove
        Remove the key so Sonar's default applies. Required keys cannot be removed (Sonar then reports them missing).
    .EXAMPLE
        Set-AzlSonarConfig -Path ./config/clus01.json -Key pollSeconds -Value 30
    .EXAMPLE
        Set-AzlSonarConfig -Path ./config/clus01.json -Key logs.paths -Value 'C:\MASLogs', 'C:\CloudDeployment\Logs'
    .EXAMPLE
        Set-AzlSonarConfig -Path ./config/clus01.json -Key logs.transport -Remove
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$Path,
        [string]$Key,
        [string[]]$Value,
        [switch]$Remove
    )

    $ErrorActionPreference = 'Stop'
    if (-not $Key) {
        return @($script:AzlSonarSettableKeys.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Key = $_.Key; Kind = $_.Value['Kind']; Allowed = $(if ($_.Value['Words']) { $_.Value['Words'] -join ', ' } else { '' }) }
            })
    }
    if (-not $Path) { throw 'Give -Path, the config file to change.' }
    if ($Key -match '^credential\.(password|secret|secretValue)$') { throw "$Key is not allowed: never put secrets in the config. Use the prompt, -Credential or Key Vault names (credential.vault, credential.usernameSecret, credential.passwordSecret)." }
    if ($Key -eq 'nodes' -or $Key -like 'nodes[[]*') { throw 'Change nodes with Add-AzlSonarNode and Remove-AzlSonarNode.' }
    $matchedKey = @($script:AzlSonarSettableKeys.Keys | Where-Object { $_ -ieq $Key })
    if ($matchedKey.Count -eq 0) { throw "'$Key' is not a setting this command changes. Run Set-AzlSonarConfig with no -Key to list them, or see docs/config.md." }
    $Key = $matchedKey[0]
    $kind = $script:AzlSonarSettableKeys[$Key]['Kind']
    $words = $script:AzlSonarSettableKeys[$Key]['Words']
    if ($Remove -eq [bool]$PSBoundParameters.ContainsKey('Value')) { throw 'Give -Value to set the key, or -Remove to remove it, not both and not neither.' }

    $config = Read-AzlSonarRawConfigFile -Path $Path
    $before = @(Test-AzlSonarConfig -Config $config)

    $typed = $null
    if (-not $Remove) {
        $values = @($Value)
        if ($kind -ne 'list' -and $values.Count -ne 1) { throw "$Key takes one value." }
        switch ($kind) {
            'number' { $number = 0; if (-not [int]::TryParse($values[0], [ref]$number)) { throw "$Key must be a whole number." }; $typed = $number }
            'flag' { if ($values[0] -notin 'true', 'false') { throw "$Key must be true or false." }; $typed = ($values[0] -eq 'true') }
            'list' { $typed = @($values) }
            default {
                if ($words) {
                    $word = @($words | Where-Object { $_ -ieq $values[0] })
                    if ($word.Count -eq 0) { throw "$Key must be one of: $($words -join ', ')." }
                    $typed = $word[0]
                }
                else { $typed = $values[0] }
            }
        }
    }

    $segments = $Key -split '\.'
    $holder = $config
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $child = Get-AzlSonarMember $holder $segments[$i]
        if ($null -eq $child -or $child -isnot [pscustomobject]) {
            if ($Remove) { $holder = $null; break }
            $child = [pscustomobject]@{}
            $holder | Add-Member -NotePropertyName $segments[$i] -NotePropertyValue $child -Force
        }
        $holder = $child
    }
    $leaf = $segments[-1]
    if ($Remove) {
        if ($null -ne $holder -and $holder.PSObject.Properties[$leaf]) { $holder.PSObject.Properties.Remove($leaf) }
        if ($segments.Count -gt 1) {
            $parent = Get-AzlSonarMember $config $segments[0]
            if ($null -ne $parent -and @($parent.PSObject.Properties).Count -eq 0) { $config.PSObject.Properties.Remove($segments[0]) }
        }
    }
    else { $holder | Add-Member -NotePropertyName $leaf -NotePropertyValue $typed -Force }

    $new = @(Test-AzlSonarConfig -Config $config | Where-Object { $_ -notin $before })
    if ($new.Count -gt 0) { throw "Not changed. $Key would make the file invalid:`n - $($new -join "`n - ")" }

    $what = if ($Remove) { "Remove $Key" } else { "Set $Key to $(@($Value) -join ', ')" }
    if ($PSCmdlet.ShouldProcess($Path, $what)) {
        Write-AzlSonarConfigFile -Path $Path -Config $config
        Write-Information -MessageData "${what}: $Path. A running Sonar keeps the old value until it is restarted." -InformationAction Continue
    }
}

function Get-AzlSonarConfig {
    <#
    .SYNOPSIS
        Returns the configuration Sonar would run with: from a config file, or from the master infrastructure.yml.
    .EXAMPLE
        Get-AzlSonarConfig -Path ./config/clus01.json
    .EXAMPLE
        Get-AzlSonarConfig -InfrastructureFile ./infrastructure.yml | Select-Object -ExpandProperty nodes
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'InfrastructureFile')][string]$InfrastructureFile
    )

    if ($PSCmdlet.ParameterSetName -eq 'InfrastructureFile') { return Read-AzlSonarConfig -InfrastructureFile $InfrastructureFile }
    return Read-AzlSonarConfig -Path $Path
}

function ConvertTo-AzlSonarConfig {
    <#
    .SYNOPSIS
        Generates a Sonar config file once from the master infrastructure.yml (schema 5).
    .DESCRIPTION
        Same mapping as Start-AzlSonar.ps1 -InfrastructureFile, written to a file you can commit or edit. Run it again when the
        master file changes; add -Force to replace the file. Secrets are never read: the file says credential.source prompt.
    .EXAMPLE
        ConvertTo-AzlSonarConfig -InfrastructureFile ./infrastructure.yml -OutFile ./config/clus01.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string]$InfrastructureFile,
        [Parameter(Mandatory)][string]$OutFile,
        [ValidateRange(5, 3600)][int]$PollSeconds,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'
    if ((Test-Path -LiteralPath $OutFile) -and -not $Force) { throw "$OutFile already exists. Use -Force to replace it." }
    $arguments = @{ InfrastructureFile = $InfrastructureFile }
    if ($PSBoundParameters.ContainsKey('PollSeconds')) { $arguments.PollSeconds = $PollSeconds }
    $null = Read-AzlSonarConfig @arguments 3>$null   # throws, naming the schema 5 key, when the file is not usable
    $mapped = Read-AzlSonarInfrastructureFile -Path $InfrastructureFile -PollSeconds $(if ($PSBoundParameters.ContainsKey('PollSeconds')) { $PollSeconds } else { $null })
    if ($PSCmdlet.ShouldProcess($OutFile, 'Write the Sonar config file')) {
        Write-AzlSonarConfigFile -Path $OutFile -Config $mapped
        return Get-Item -LiteralPath $OutFile
    }
}

# --- Guided setup ----------------------------------------------------------------------------------------------------

function Get-AzlSonarAzChoice {
    # What the signed-in Az context can offer the wizard. Empty when Az is not loaded or nobody is signed in.
    [CmdletBinding()]
    param()

    $result = @{ SubscriptionId = ''; Subscriptions = @(); ResourceGroup = '' }
    try {
        if (-not (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue)) { return $result }
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if ($null -eq $context) { return $result }
        $result.SubscriptionId = [string]$context.Subscription.Id
        if (Get-Command -Name Get-AzSubscription -ErrorAction SilentlyContinue) {
            $result.Subscriptions = @(Get-AzSubscription -ErrorAction SilentlyContinue | ForEach-Object { @{ Id = [string]$_.Id; Name = [string]$_.Name } })
        }
        if (Get-Command -Name Get-AzDefault -ErrorAction SilentlyContinue) {
            $default = Get-AzDefault -ResourceGroup -ErrorAction SilentlyContinue
            if ($default) { $result.ResourceGroup = [string]$default.Name }
        }
    }
    catch { Write-Verbose "Az context not available: $($_.Exception.Message)" }
    return $result
}

function Read-AzlSonarPromptValue {
    <#
    .SYNOPSIS
        Asks for one value (Read-Host) with an explanation and a default; asks again when the answer fails the check.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Help,
        [string]$Default,
        [scriptblock]$Validate,
        [string]$ErrorText = 'That value is not valid.',
        [switch]$AllowEmpty
    )

    if ($Help) { Write-Information -MessageData "  $Help" -InformationAction Continue }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $answer = [string](Read-Host -Prompt $label)
        if (-not $answer.Trim() -and $Default) { $answer = $Default }
        $answer = $answer.Trim()
        if (-not $answer -and $AllowEmpty) { return '' }
        if ($answer -and ($null -eq $Validate -or (& $Validate $answer))) { return $answer }
        Write-Information -MessageData "  $ErrorText" -InformationAction Continue
    }
    throw "No valid value for '$Prompt' after 5 tries."
}

function Invoke-AzlSonarConfigWizard {
    <#
    .SYNOPSIS
        The guided setup behind New-AzlSonarConfig -Interactive. Values given as parameters are not asked again.
    #>
    [CmdletBinding()]
    param([hashtable]$Bound = @{})

    $info = { param($t) Write-Information -MessageData $t -InformationAction Continue }
    & $info 'AzL Sonar setup. Press Enter to accept the value in [brackets]. No password is asked for or stored.'
    $az = Get-AzlSonarAzChoice
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

    if ($Bound.ContainsKey('SubscriptionId')) { $subscription = $Bound['SubscriptionId'] }
    else {
        $default = $az.SubscriptionId
        if (@($az.Subscriptions).Count -gt 0) {
            & $info 'Subscriptions this account can see (type a number, or paste a subscription ID):'
            $number = 0
            foreach ($s in $az.Subscriptions) { $number++; & $info ("  {0}. {1} ({2})" -f $number, $s.Name, $s.Id) }
        }
        $answer = Read-AzlSonarPromptValue -Prompt 'Subscription' -Default $default -Help 'The subscription that holds the cluster and its resource group.' -ErrorText 'Enter a subscription number from the list or a subscription ID (a GUID).' -Validate {
            param($v) $v -match $guid -or ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le @($az.Subscriptions).Count)
        }
        $subscription = if ($answer -match '^\d+$') { @($az.Subscriptions)[[int]$answer - 1].Id } else { $answer }
    }

    $resourceGroup = if ($Bound.ContainsKey('ResourceGroup')) { $Bound['ResourceGroup'] } else {
        Read-AzlSonarPromptValue -Prompt 'Resource group' -Default $az.ResourceGroup -Help 'The resource group the deployment creates the cluster in.' -ErrorText 'Use 1-90 letters, digits, - _ . ( ), not ending in a period.' -Validate { param($v) $v -match '^[-\w\.\(\)]{1,90}$' -and -not $v.EndsWith('.') }
    }
    $clusterName = if ($Bound.ContainsKey('ClusterName')) { $Bound['ClusterName'] } else {
        Read-AzlSonarPromptValue -Prompt 'Cluster name' -Help 'The name of the Azure Local cluster (up to 15 characters).' -ErrorText 'The name must not contain / \ ? #.' -Validate { param($v) $v -notmatch '[/\\?#]' }
    }
    $route = if ($Bound.ContainsKey('Route')) { $Bound['Route'] } else {
        Read-AzlSonarPromptValue -Prompt 'How are the machines prepared (auto, simplified, oem-image)' -Default 'auto' -Help 'simplified: simplified machine provisioning (azurelocal-ztp). oem-image: OEM image or ISO plus Arc registration. auto: Sonar works it out.' -ErrorText 'Enter auto, simplified or oem-image.' -Validate { param($v) $v -in 'auto', 'simplified', 'oem-image' }
    }
    $identityModel = if ($Bound.ContainsKey('IdentityModel')) { $Bound['IdentityModel'] } else {
        Read-AzlSonarPromptValue -Prompt 'Identity model (LocalIdentity, ActiveDirectory)' -Default 'LocalIdentity' -Help 'LocalIdentity: no Active Directory, secrets in Key Vault. ActiveDirectory: the machines join a domain.' -ErrorText 'Enter LocalIdentity or ActiveDirectory.' -Validate { param($v) $v -in 'LocalIdentity', 'ActiveDirectory' }
    }
    $ztpPath = ''
    if ($Bound.ContainsKey('ZtpEventsPath')) { $ztpPath = $Bound['ZtpEventsPath'] }
    elseif ($route -ne 'oem-image') {
        $ztpPath = Read-AzlSonarPromptValue -Prompt 'ZTP event file (Enter to skip)' -AllowEmpty -Help 'Only for azurelocal-ztp runs: the ztp-events.jsonl file in the evidence folder. Leave empty when you do not use ZTP.'
    }
    $poll = 0
    if ($Bound.ContainsKey('PollSeconds')) { $poll = $Bound['PollSeconds'] }
    else {
        $answer = Read-AzlSonarPromptValue -Prompt 'Seconds between Azure polls' -Default '20' -Help 'How often Sonar reads Azure (5 to 3600).' -ErrorText 'Enter a whole number from 5 to 3600.' -Validate { param($v) $v -match '^\d+$' -and [int]$v -ge 5 -and [int]$v -le 3600 }
        $poll = [int]$answer
        if ($poll -eq 20) { $poll = 0 }   # the default: leave it out of the file
    }

    & $info 'Nodes: the machines to watch. The first is the seed node, whose deployment logs Sonar reads.'
    $nodes = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $isFirst = $nodes.Count -eq 0
        $nodeName = Read-AzlSonarPromptValue -Prompt $(if ($isFirst) { 'Node name' } else { 'Next node name (Enter to finish)' }) -AllowEmpty:(-not $isFirst) -ErrorText 'The name must not contain / \ ? #.' -Validate { param($v) $v -notmatch '[/\\?#]' }
        if (-not $nodeName) { break }
        $nodeAddress = Read-AzlSonarPromptValue -Prompt "Address of $nodeName" -Help 'Its management IP address or host name.' -ErrorText 'Enter an address without spaces.' -Validate { param($v) $v -notmatch '\s' }
        $entry = [ordered]@{ name = $nodeName; address = $nodeAddress }
        if ($isFirst) { $entry['seed'] = $true }
        $nodes.Add([pscustomobject]$entry)
    }
    return @{
        SubscriptionId = $subscription; ResourceGroup = $resourceGroup; ClusterName = $clusterName; Route = $route
        IdentityModel = $identityModel; ZtpEventsPath = $ztpPath; PollSeconds = $poll; Nodes = $nodes.ToArray()
    }
}

# --- Starting without a config ---------------------------------------------------------------------------------------

function Find-AzlSonarDefaultConfig {
    # A config file in the usual places, relative to the current folder; $null when there is none.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($candidate in './sonar.config.json', './config/sonar.config.json') {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
    }
    return $null
}

function Get-AzlSonarNoConfigMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
AzL Sonar needs to know which cluster to watch, and found no config. Pick one of three ways:

  1. From the master infrastructure file (recommended):
       ./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml

  2. With the guided setup, which asks for each value and saves a config file:
       Import-Module ./src/AzlSonar/AzlSonar.psd1
       New-AzlSonarConfig -Path ./config/sonar.config.json -Interactive
       ./Start-AzlSonar.ps1 -ConfigPath ./config/sonar.config.json

  3. By hand: copy examples/sonar.config.commented.jsonc (every key explained), fill it in, then
       ./Start-AzlSonar.ps1 -ConfigPath ./config/sonar.config.json

To only replay a recording: ./Start-AzlSonar.ps1 -Replay ./recordings/<file>.jsonl
'@
}

function Test-AzlSonarNonInteractiveSwitch {
    # True when the command line has pwsh's -NonInteractive switch (or an abbreviation down to -noni). Read-Host throws in
    # such a session even when the console is a real terminal, so Sonar must not prompt.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]]$Arguments = [Environment]::GetCommandLineArgs())

    foreach ($argument in $Arguments) {
        if ($argument -match '^[-/](?i:noni\w*)$') { return $true }
    }
    return $false
}

function Test-AzlSonarInteractiveSession {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not (Test-AzlSonarNonInteractiveSwitch))
}

function Invoke-AzlSonarNoConfigGuide {
    <#
    .SYNOPSIS
        Prints the three ways to configure Sonar and, in an interactive session, offers to run the guided setup.
    .OUTPUTS
        The path of the config file the guided setup wrote, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$SetupPath = './config/sonar.config.json')

    Write-Information -MessageData (Get-AzlSonarNoConfigMessage) -InformationAction Continue
    if (-not (Test-AzlSonarInteractiveSession)) { return $null }
    $answer = [string](Read-Host -Prompt 'Run the guided setup now? [Y/n]')
    if ($answer.Trim() -and $answer.Trim() -notmatch '^(?i:y|yes)$') { return $null }
    $null = New-AzlSonarConfig -Path $SetupPath -Interactive -Force:(Test-Path -LiteralPath $SetupPath)
    return $SetupPath
}
