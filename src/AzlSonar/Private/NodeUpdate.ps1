Set-StrictMode -Version Latest

# The cluster's own update service, read-only.
#
# Azure's view of an update (clusters/updates, updateRuns, updateSummaries) lags the cluster by many minutes. On 9 Nov 2026 an
# SBE update ran on the cluster for 17 minutes in Preparing and HealthChecking while Azure still said "Ready", so Sonar said
# "Update available, not started". The cluster knows first. This file reads what the cluster itself says, on ONE reachable node,
# over WinRM (Negotiate), with Get-SolutionUpdate, Get-SolutionUpdateRun, Get-SolutionUpdateEnvironment and Get-ClusterNode.
# Those cmdlets only exist on the Azure Local update module, which loads in Windows PowerShell 5.1 on the node. Only Get-
# cmdlets are called: Sonar never starts, adds, removes or sets anything on the cluster.
#
# The account: Get-SolutionUpdate runs as the DEPLOYMENT account (a domain user), not as the local administrator that reads the
# logs. It is optional (config updateAccount, or -UpdateCredential). Without it Sonar keeps its Azure-only behaviour and says
# plainly on the Update tab that node-side reading is off and why. The password is a SecureString read from Key Vault with
# Get-AzKeyVaultSecret; it is never in a file, a state, a log or a recording. A rejected account is never retried per poll
# (a circuit breaker, see Register-AzlSonarUpdateFailure): a deployment account that gets locked out is worse than a missing tab.
#
# Shapes below were read from a live 12.2610 cluster (9 Nov 2026): Get-SolutionUpdate (ResourceId, State, Version, SbeVersion,
# PackageType, InstalledDate, UpdateStateProperties), Get-SolutionUpdateRun -UpdateId (ResourceId, State, TimeStarted,
# LastUpdatedTime, Duration, Progress as a tree of Name, Description, Status, StartTimeUtc, EndTimeUtc, ErrorMessage, Steps),
# Get-SolutionUpdateEnvironment (State, HealthState, CurrentVersion, CurrentSbeVersion, PackageVersions, HealthCheckResult).
# The names of the per-node steps carry the node name ("[SBE Partner] Install CAU Updates <node>"), which is how the per-node
# timeline is built. Whole updates were read from that run's history; Sonar has not yet followed an update live end to end.

# Seconds between reads while an update is active (on the cluster or in Azure) and while nothing happens.
$script:AzlSonarUpdateActiveSeconds = 10
$script:AzlSonarUpdateIdleSeconds = 30
# How long the last good read is shown when the next one fails (a node restarts; the next node answers soon).
$script:AzlSonarUpdateStaleMinutes = 10
# WinRM timeouts: a node that is restarting must fail fast so the next node is tried.
$script:AzlSonarUpdateOpenSeconds = 10
$script:AzlSonarUpdateOperationSeconds = 90
$script:AzlSonarUpdateRejectBackoffMinutes = 15
$script:AzlSonarUpdateRejectBackoffMaxMinutes = 120
$script:AzlSonarUpdateMaxRejections = 2
$script:AzlSonarUpdateRetrySeconds = 300
$script:AzlSonarUpdateMaxEvents = 40

$script:AzlSonarUpdateOffNoAccount = 'Node-side update reading is off. Sonar shows only what Azure reports, and Azure can be many minutes behind the cluster. To read the cluster''s own update service, give the deployment account: add updateAccount to the config, or start Sonar with -UpdateCredential.'

# ---------------------------------------------------------------------------------------------------------------- the setting

function Get-AzlSonarUpdateAccountProblem {
    <#
    .SYNOPSIS
        The problems of an updateAccount config section (empty when valid or absent). Names only; a password is refused.
    .DESCRIPTION
        updateAccount is { source (keyvault | parameter), username, domain, vault, usernameSecret, passwordSecret }. With source
        keyvault the vault, the password secret and a user name (username, or usernameSecret) are required. Never echoes a value.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object]$Account)

    $problems = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Account) { return $problems.ToArray() }
    if ($Account -isnot [System.Collections.IDictionary] -and $Account -isnot [pscustomobject]) {
        $problems.Add('updateAccount must be an object with source, username, domain, vault, usernameSecret and passwordSecret.')
        return $problems.ToArray()
    }
    foreach ($key in 'username', 'domain', 'vault', 'usernameSecret', 'passwordSecret') {
        $value = Get-AzlSonarMember $Account $key
        if ($null -ne $value -and ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -match '[\x00-\x1f\x7f]')) { $problems.Add("updateAccount.$key must be text.") }
    }
    $domain = Get-AzlSonarMember $Account 'domain'
    if ($domain -is [string] -and -not [string]::IsNullOrWhiteSpace($domain) -and $domain -notmatch '\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z') {
        $problems.Add('updateAccount.domain must be a domain name such as contoso.example.')
    }
    $source = Get-AzlSonarMember $Account 'source'
    if ($null -ne $source -and ($source -isnot [string] -or $source.ToLowerInvariant() -notin 'keyvault', 'parameter')) {
        $problems.Add('updateAccount.source must be keyvault or parameter.')
    }
    $vault = [string](Get-AzlSonarMember $Account 'vault' '')
    $effective = if ($source -is [string]) { $source.ToLowerInvariant() } elseif ($vault) { 'keyvault' } else { 'parameter' }
    if ($effective -eq 'keyvault') {
        foreach ($key in 'vault', 'passwordSecret') {
            if ([string]::IsNullOrWhiteSpace([string](Get-AzlSonarMember $Account $key ''))) { $problems.Add("updateAccount.$key is required when updateAccount.source is keyvault.") }
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-AzlSonarMember $Account 'username' '')) -and [string]::IsNullOrWhiteSpace([string](Get-AzlSonarMember $Account 'usernameSecret' ''))) {
            $problems.Add('updateAccount needs username or usernameSecret when updateAccount.source is keyvault.')
        }
        $secret = [string](Get-AzlSonarMember $Account 'passwordSecret' '')
        if ($vault -and $secret) {
            $why = Get-AzlSonarKeyVaultReferenceProblem -Reference ('keyvault://{0}/{1}' -f $vault, $secret)
            if ($why -and $why -notmatch '^is not ') { $problems.Add("updateAccount.vault or updateAccount.passwordSecret $why.") }
        }
        $userSecret = [string](Get-AzlSonarMember $Account 'usernameSecret' '')
        if ($userSecret -and $userSecret -notmatch '\A[A-Za-z0-9-]{1,127}\z') { $problems.Add('updateAccount.usernameSecret names a secret that Azure would not accept (1 to 127 letters, digits and hyphens).') }
    }
    foreach ($forbidden in 'password', 'secret', 'secretValue') {
        if ($null -ne (Get-AzlSonarMember $Account $forbidden)) { $problems.Add("updateAccount.$forbidden is not allowed: never put secrets in the config. Use Key Vault names (vault, usernameSecret, passwordSecret) or -UpdateCredential.") }
    }
    return $problems.ToArray()
}

function ConvertTo-AzlSonarUpdateAccountSetting {
    <#
    .SYNOPSIS
        The normalised updateAccount setting: { configured, source, username, domain, vault, usernameSecret, passwordSecret }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object]$Account)

    $vault = [string](Get-AzlSonarMember $Account 'vault' '')
    $source = [string](Get-AzlSonarMember $Account 'source' '')
    if (-not $source) { $source = if ($vault) { 'keyvault' } else { 'parameter' } }
    return [pscustomobject]@{
        configured     = $null -ne $Account
        source         = $source.ToLowerInvariant()
        username       = [string](Get-AzlSonarMember $Account 'username' '')
        domain         = [string](Get-AzlSonarMember $Account 'domain' '')
        vault          = $vault
        usernameSecret = [string](Get-AzlSonarMember $Account 'usernameSecret' '')
        passwordSecret = [string](Get-AzlSonarMember $Account 'passwordSecret' '')
    }
}

function Format-AzlSonarUpdateUserName {
    <#
    .SYNOPSIS
        Qualifies a user name that has no domain part with @domain (the vault often keeps it without one).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$UserName, [AllowNull()][AllowEmptyString()][string]$Domain)

    $name = ([string]$UserName).Trim()
    if (-not $name -or $name.Contains('@') -or $name.Contains('\') -or [string]::IsNullOrWhiteSpace($Domain)) { return $name }
    return ('{0}@{1}' -f $name, $Domain.Trim())
}

# ---------------------------------------------------------------------------------------------------------------- context and account

function New-AzlSonarUpdateContext {
    <#
    .SYNOPSIS
        The state the node-side update reader keeps between polls (Shared.UpdateLocal): the account, the last good read, the breaker.
    .DESCRIPTION
        Touched by the poller only. Holds a SecureString inside a credential and never a password as text.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return [hashtable]::Synchronized(@{
            ParameterCredential = $null   # -UpdateCredential
            Account             = $null   # { Status, Credential, UserName, Version, Message, Source, RetryAt }
            Cache               = $null   # the last good local record
            LastReadAt          = $null
            Node                = ''      # the node that answered last
            Rejections          = 0
            BreakUntil          = $null
            Latched             = $false
            BreakReason         = ''
            LockedVersion       = ''
            Observed            = $null   # { Key, Since }: when the cluster's current state was first seen
            PreRun              = $null   # { RunId, Solution, Sbe }: the versions seen before the run that is running
            NodeStates          = @{}
            Events              = [System.Collections.Generic.List[object]]::new()
        })
}

function Resolve-AzlSonarUpdateCredential {
    <#
    .SYNOPSIS
        Gets the update account: -UpdateCredential, or two Key Vault secrets. Returns { Status (ok | off | unavailable), Credential, UserName, Version, Message, Source }.
    .DESCRIPTION
        Status off means no account is set (or the parameter source has no -UpdateCredential): not an error. unavailable means the
        account is set but could not be read (Az.KeyVault missing, an expired sign-in, a secret that does not exist): the message
        names the vault and the secret, never a value. Sonar runs on without node-side reading and asks again later.
        Read-only: Get-AzKeyVaultSecret only. The password stays a SecureString.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][pscredential]$Credential
    )

    $setting = Get-AzlSonarMember $Config 'updateAccount'
    if ($null -eq $setting -or $null -eq (Get-AzlSonarMember $setting 'configured')) { $setting = ConvertTo-AzlSonarUpdateAccountSetting -Account $setting }
    $out = { param($status, $account, $user, $version, $message, $source) [pscustomobject]@{ Status = $status; Credential = $account; UserName = $user; Version = $version; Message = $message; Source = $source } }

    if ($null -ne $Credential -and $Credential -ne [pscredential]::Empty) {
        return & $out 'ok' $Credential $Credential.UserName '' '' 'parameter'
    }
    if (-not [bool]$setting.configured) { return & $out 'off' $null '' '' $script:AzlSonarUpdateOffNoAccount '' }
    if ($setting.source -eq 'parameter') {
        return & $out 'off' $null '' '' 'Node-side update reading is off. updateAccount.source is parameter, but Sonar was started without -UpdateCredential.' 'parameter'
    }
    $vault = [string]$setting.vault
    if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        return & $out 'unavailable' $null '' '' 'Node-side update reading is off. updateAccount.source is keyvault, but Az.KeyVault is not installed. Run: Install-Module Az.KeyVault -Scope CurrentUser. Sonar tries again every 5 minutes.' 'keyvault'
    }
    try {
        $userName = [string]$setting.username
        if (-not $userName) { $userName = [string](Get-AzKeyVaultSecret -VaultName $vault -Name $setting.usernameSecret -AsPlainText) }
        $secret = Get-AzKeyVaultSecret -VaultName $vault -Name $setting.passwordSecret
    }
    catch {
        $named = @($setting.usernameSecret, $setting.passwordSecret) | Where-Object { $_ }
        return & $out 'unavailable' $null '' '' ("Node-side update reading is off. Could not read the update account from Key Vault '$vault' (secrets '$($named -join ''', ''')'): $(Protect-AzlSonarText -Text $_.Exception.Message). Sonar tries again every 5 minutes.") 'keyvault'
    }
    if ([string]::IsNullOrWhiteSpace($userName) -or $null -eq $secret -or $null -eq (Get-AzlSonarMember $secret 'SecretValue')) {
        return & $out 'unavailable' $null '' '' "Node-side update reading is off. Key Vault '$vault' returned no value for the update account (user name or password secret). Sonar tries again every 5 minutes." 'keyvault'
    }
    $qualified = Format-AzlSonarUpdateUserName -UserName $userName -Domain $setting.domain
    return & $out 'ok' ([pscredential]::new($qualified, $secret.SecretValue)) $qualified ([string](Get-AzlSonarMember $secret 'Version' '')) '' 'keyvault'
}

function Get-AzlSonarUpdateAccount {
    <#
    .SYNOPSIS
        The update account record for this poll, resolved once and again only after an unavailable result has waited 5 minutes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [datetime]$Now = [datetime]::UtcNow
    )

    $account = $Context['Account']
    if ($null -ne $account) {
        $retry = Get-AzlSonarMember $account 'RetryAt'
        if ($account.Status -ne 'unavailable' -or $null -eq $retry -or $Now -lt $retry) { return $account }
    }
    $resolved = Resolve-AzlSonarUpdateCredential -Config $Config -Credential $Context['ParameterCredential']
    $resolved | Add-Member -NotePropertyName RetryAt -NotePropertyValue $(if ($resolved.Status -eq 'unavailable') { $Now.AddSeconds($script:AzlSonarUpdateRetrySeconds) } else { $null }) -Force
    $Context['Account'] = $resolved
    return $resolved
}

# ---------------------------------------------------------------------------------------------------------------- the account breaker

function Get-AzlSonarUpdateBreakerMessage {
    <#
    .SYNOPSIS
        Why the update account must not be presented now, or '' when it may be.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [datetime]$Now = [datetime]::UtcNow)

    if ([bool]$Context['Latched']) {
        return "Node-side update reading is paused: $($Context['BreakReason']) Sonar will not try the account again until Sonar restarts or the password secret changes in Key Vault, so the account is not locked out."
    }
    $until = $Context['BreakUntil']
    if ($null -ne $until -and $Now -lt $until) {
        return "Node-side update reading is paused: $($Context['BreakReason']) Sonar tries once more at $(Format-AzlSonarDate $until) (UTC)."
    }
    return ''
}

function Register-AzlSonarUpdateFailure {
    <#
    .SYNOPSIS
        Records what a failed connection told about the account (class from Get-AzlSonarConnectionFailureClass) and opens the breaker when needed.
    .DESCRIPTION
        rejected counts: the first opens a back-off (15 minutes, doubling to 2 hours), the second latches. lockedOut and
        accountUnusable latch at once (retrying cannot work, and a lockout must not be extended). authorization (the password was
        right, the account may not do this) backs off 5 minutes and is not counted. unreachable and other change nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [Parameter(Mandatory)][string]$Class,
        [AllowEmptyString()][string]$Reason = '',
        [datetime]$Now = [datetime]::UtcNow
    )

    switch ($Class) {
        'rejected' {
            $Context['Rejections'] = [int]$Context['Rejections'] + 1
            if ([int]$Context['Rejections'] -ge $script:AzlSonarUpdateMaxRejections) {
                $Context['Latched'] = $true
                $Context['BreakReason'] = "a node refused the update account $($Context['Rejections']) times ($Reason)."
            }
            else {
                $minutes = [Math]::Min($script:AzlSonarUpdateRejectBackoffMaxMinutes, $script:AzlSonarUpdateRejectBackoffMinutes * [Math]::Pow(2, [int]$Context['Rejections'] - 1))
                $Context['BreakUntil'] = $Now.AddMinutes($minutes)
                $Context['BreakReason'] = "a node refused the update account ($Reason)."
            }
        }
        { $_ -in 'lockedOut', 'accountUnusable' } {
            $Context['Latched'] = $true
            $Context['BreakReason'] = "the update account is not usable ($Reason)."
        }
        'authorization' {
            $Context['BreakUntil'] = $Now.AddMinutes(5)
            $Context['BreakReason'] = "the update account is not allowed to read the update service this way ($Reason)."
        }
    }
}

function Test-AzlSonarUpdateSecretChanged {
    <#
    .SYNOPSIS
        While the breaker is latched on a Key Vault account: has the password secret got a new version? Then the breaker resets.
    .DESCRIPTION
        Reads the secret again (Key Vault only, the account is not tried) at most every 5 minutes. A new version means the password
        was changed: the counters go back to zero and the next poll is one probe.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [datetime]$Now = [datetime]::UtcNow
    )

    $account = $Context['Account']
    if ($null -eq $account -or $account.Source -ne 'keyvault' -or -not [bool]$Context['Latched']) { return $false }
    $next = Get-AzlSonarMember $Context 'RecheckAt'
    if ($null -ne $next -and $Now -lt $next) { return $false }
    $Context['RecheckAt'] = $Now.AddSeconds($script:AzlSonarUpdateRetrySeconds)
    $fresh = Resolve-AzlSonarUpdateCredential -Config $Config -Credential $null
    if ($fresh.Status -ne 'ok' -or -not $fresh.Version -or $fresh.Version -eq [string]$account.Version) { return $false }
    $fresh | Add-Member -NotePropertyName RetryAt -NotePropertyValue $null -Force
    $Context['Account'] = $fresh
    $Context['Latched'] = $false
    $Context['Rejections'] = 0
    $Context['BreakUntil'] = $null
    $Context['BreakReason'] = ''
    return $true
}

# ---------------------------------------------------------------------------------------------------------------- the remote read

function Get-AzlSonarNodeUpdateScript {
    <#
    .SYNOPSIS
        The script that runs on ONE node, in Windows PowerShell 5.1, and returns one JSON text. Get- cmdlets only.
    .DESCRIPTION
        Get-SolutionUpdate, Get-SolutionUpdateRun (every run of every update, newest first; the step tree of the newest run and
        of a run that is running or failed), Get-SolutionUpdateEnvironment and Get-ClusterNode. One failing cmdlet is reported in
        errors[] and does not hide the others. Dates are UTC ISO text, enums are their words, versions are text, so nothing
        depends on how the objects would be deserialised. Nothing is changed on the node.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    return {
        param([int]$MaxSteps = 1500, [int]$RunHistory = 10)
        $ErrorActionPreference = 'Stop'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $WarningPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        function Get-Word { param($v) if ($null -eq $v) { return '' }; if ($v -is [string]) { return $v }; if ($v.PSObject.Properties['Value'] -and $v.Value -is [string]) { return $v.Value }; return [string]$v }
        function Get-Time {
            param($v)
            if ($null -eq $v) { return '' }
            try {
                $d = [datetime]$v
                if ($d.Year -lt 2000) { return '' }
                if ($d.Kind -eq 'Unspecified') { $d = [datetime]::SpecifyKind($d, 'Utc') } else { $d = $d.ToUniversalTime() }
                return $d.ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            catch { return '' }
        }
        function Get-Limited { param($v, [int]$n) $s = [string]$v; if ($s.Length -gt $n) { return $s.Substring(0, $n) }; return $s }
        $stepLimit = $MaxSteps
        $counter = @{ n = 0 }
        function ConvertTo-Step {
            param($s, [int]$depth)
            $counter.n++
            $kids = @()
            if ($depth -lt 12) {
                foreach ($c in @($s.Steps)) {
                    if ($null -ne $c -and $counter.n -lt $stepLimit) { $kids += , (ConvertTo-Step $c ($depth + 1)) }
                }
            }
            return [ordered]@{
                name = Get-Limited $s.Name 200; description = Get-Limited $s.Description 300; status = Get-Word $s.Status
                start = Get-Time $s.StartTimeUtc; end = Get-Time $s.EndTimeUtc; error = Get-Limited $s.ErrorMessage 1500; steps = $kids
            }
        }

        $result = [ordered]@{ computer = $env:COMPUTERNAME; module = $false; updates = @(); runs = @(); environment = $null; clusterNodes = @(); errors = @() }
        if (-not (Get-Command -Name Get-SolutionUpdate -ErrorAction SilentlyContinue)) {
            $result.errors += 'Get-SolutionUpdate is not available on this node (the Azure Local update module did not load).'
            return ($result | ConvertTo-Json -Depth 5 -Compress)
        }
        $result.module = $true

        $list = @()
        try {
            $list = @(Get-SolutionUpdate 4>$null)
            $result.updates = @($list | ForEach-Object {
                    [ordered]@{
                        id = [string]$_.ResourceId; displayName = Get-Limited $_.DisplayName 200; version = [string]$_.Version; sbeVersion = [string]$_.SbeVersion
                        state = Get-Word $_.State; packageType = [string]$_.PackageType; publisher = [string]$_.Publisher; description = Get-Limited $_.Description 300
                        rebootRequired = Get-Word $_.RebootRequired; healthState = Get-Word $_.HealthState; installedDate = Get-Time $_.InstalledDate
                        availabilityType = Get-Word $_.AvailabilityType
                        progressPercentage = $(if ($null -ne $_.UpdateStateProperties) { $_.UpdateStateProperties.ProgressPercentage } else { $null })
                        notifyMessage = $(if ($null -ne $_.UpdateStateProperties) { Get-Limited $_.UpdateStateProperties.NotifyMessage 400 } else { '' })
                    }
                })
        }
        catch { $result.errors += 'Get-SolutionUpdate: ' + (Get-Limited $_.Exception.Message 300) }

        try {
            $all = @()
            foreach ($u in $list) {
                foreach ($r in @(Get-SolutionUpdateRun -UpdateId $u.ResourceId 4>$null)) { if ($null -ne $r) { $all += [pscustomobject]@{ Update = $u; Run = $r; Started = $r.TimeStarted } } }
            }
            $sorted = @($all | Sort-Object -Property Started -Descending | Select-Object -First $RunHistory)
            $trees = 0
            $result.runs = @(for ($i = 0; $i -lt $sorted.Count; $i++) {
                    $r = $sorted[$i].Run
                    $state = Get-Word $r.State
                    $tree = $null
                    if ($null -ne $r.Progress -and ($i -eq 0 -or ($state -match 'Progress|Running|Fail' -and $trees -lt 3))) { $counter.n = 0; $tree = ConvertTo-Step $r.Progress 0; $trees++ }
                    [ordered]@{
                        id = [string]$r.ResourceId; updateId = [string]$sorted[$i].Update.ResourceId; state = $state; type = Get-Word $r.UpdateRunType
                        started = Get-Time $r.TimeStarted; lastUpdated = Get-Time $r.LastUpdatedTime
                        durationSeconds = $(if ($null -ne $r.Duration) { [int][Math]::Floor(([timespan]$r.Duration).TotalSeconds) } else { $null })
                        progress = $tree
                    }
                })
        }
        catch { $result.errors += 'Get-SolutionUpdateRun: ' + (Get-Limited $_.Exception.Message 300) }

        try {
            $e = Get-SolutionUpdateEnvironment 4>$null
            if ($null -ne $e) {
                $result.environment = [ordered]@{
                    state = Get-Word $e.State; healthState = Get-Word $e.HealthState; currentVersion = [string]$e.CurrentVersion; currentSbeVersion = [string]$e.CurrentSbeVersion
                    lastUpdated = Get-Time $e.LastUpdated; lastChecked = Get-Time $e.LastChecked; healthCheckDate = Get-Time $e.HealthCheckDate
                    hardwareModel = [string]$e.HardwareModel; sbeFamily = [string]$e.SbeFamily
                    packageVersions = @(@($e.PackageVersions) | Where-Object { $null -ne $_ } | ForEach-Object { [ordered]@{ type = [string]$_.PackageType; version = [string]$_.Version; lastUpdated = Get-Time $_.LastUpdated } })
                    healthCheckResult = @(@($e.HealthCheckResult) | Where-Object { $null -ne $_ } | Select-Object -First 60 | ForEach-Object {
                            [ordered]@{ title = Get-Limited $_.Title 300; status = [string]$_.Status; severity = [string]$_.Severity; description = Get-Limited $_.Description 400; remediation = Get-Limited $_.Remediation 400 }
                        })
                }
            }
        }
        catch { $result.errors += 'Get-SolutionUpdateEnvironment: ' + (Get-Limited $_.Exception.Message 300) }

        try {
            $result.clusterNodes = @(Get-ClusterNode | ForEach-Object { [ordered]@{ name = [string]$_.Name; state = Get-Word $_.State } })
        }
        catch { $result.errors += 'Get-ClusterNode: ' + (Get-Limited $_.Exception.Message 300) }

        return ($result | ConvertTo-Json -Depth 32 -Compress)
    }
}

function Invoke-AzlSonarNodeUpdateCommand {
    <#
    .SYNOPSIS
        Runs the node update reader on one node over WinRM (Negotiate) as the update account and returns its JSON text. The one place that touches a node.
    .DESCRIPTION
        Invoke-Command -ComputerName reaches the Windows PowerShell 5.1 endpoint, where the update module loads. Short timeouts: a
        node that restarts must fail fast so the next node is tried. Nothing is written to the node.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    $options = New-PSSessionOption -OpenTimeout ($script:AzlSonarUpdateOpenSeconds * 1000) -OperationTimeout ($script:AzlSonarUpdateOperationSeconds * 1000) -NoMachineProfile
    # The remote module load writes verbose records: merge them into the output and keep only the text.
    $output = Invoke-Command -ComputerName $Address -Credential $Credential -Authentication Negotiate -SessionOption $options -ScriptBlock (Get-AzlSonarNodeUpdateScript) -ErrorAction Stop 4>&1
    return [string](@($output | Where-Object { $_ -is [string] }) | Select-Object -Last 1)
}

function Read-AzlSonarNodeUpdate {
    <#
    .SYNOPSIS
        Reads the cluster's update service from the first node that answers: { Ok, Node, Raw, Attempts[], Stop }.
    .DESCRIPTION
        The node that answered last goes first, then the nodes in the config order. A node that does not answer (it restarts during
        an update) is skipped and the next one is tried; that is not an error. A rejection, a lockout or a denial of the ACCOUNT
        stops the attempt at once (the same account would fail on every node, and every try counts at the domain) and is
        reported in Stop. Attempts lists what each node did, as { node, ok, class, reason }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][pscredential]$Credential,
        [AllowEmptyString()][string]$FirstNode = ''
    )

    $attempts = [System.Collections.Generic.List[object]]::new()
    $nodes = ConvertTo-AzlSonarArray (Get-AzlSonarMember $Config 'nodes')
    $ordered = @($nodes | Where-Object { $_.name -eq $FirstNode }) + @($nodes | Where-Object { $_.name -ne $FirstNode })
    foreach ($node in $ordered) {
        try {
            $json = Invoke-AzlSonarNodeUpdateCommand -Address ([string]$node.address) -Credential $Credential
            if ([string]::IsNullOrWhiteSpace($json)) { throw 'The node returned no data.' }
            $raw = ConvertFrom-Json -InputObject $json -Depth 64
            if (-not [bool](Get-AzlSonarMember $raw 'module' $false)) {
                $problemList = ConvertTo-AzlSonarArray (Get-AzlSonarMember $raw 'errors')
                $why = $problemList | Select-Object -First 1
                $attempts.Add([ordered]@{ node = [string]$node.name; ok = $false; class = 'module'; reason = $(if ($why) { [string]$why } else { 'the Azure Local update module is not available on this node' }) })
                continue
            }
            $attempts.Add([ordered]@{ node = [string]$node.name; ok = $true; class = 'ok'; reason = '' })
            return [ordered]@{ Ok = $true; Node = [string]$node.name; Raw = $raw; Attempts = $attempts.ToArray(); Stop = $null }
        }
        catch {
            $class = Get-AzlSonarConnectionFailureClass -Transport winrm -Exception $_ -Stage open
            $detail = Protect-AzlSonarText -Text ([string]$_.Exception.Message)
            if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 240) }
            $attempts.Add([ordered]@{ node = [string]$node.name; ok = $false; class = [string]$class.Class; reason = [string]$class.Reason; detail = ($detail -replace '\s+', ' ') })
            if ($class.Class -in 'lockedOut', 'accountUnusable', 'rejected', 'authorization') {
                return [ordered]@{ Ok = $false; Node = ''; Raw = $null; Attempts = $attempts.ToArray(); Stop = $class }
            }
        }
    }
    return [ordered]@{ Ok = $false; Node = ''; Raw = $null; Attempts = $attempts.ToArray(); Stop = $null }
}

# ---------------------------------------------------------------------------------------------------------------- normalising what the node said

function ConvertTo-AzlSonarLocalStep {
    <#
    .SYNOPSIS
        Adapts a step from the node reader (name, description, status, start, end, error, steps[]) to the raw shape the step tree converter reads.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Step, [Parameter(Mandatory)][string]$Id)

    $children = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($child in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $Step 'steps'))) {
        $i++
        $children.Add((ConvertTo-AzlSonarLocalStep -Step $child -Id ('{0}.{1}' -f $Id, $i)))
    }
    $message = [string](Get-AzlSonarMember $Step 'error' '')
    return [pscustomobject]@{
        name          = Get-AzlSonarMember $Step 'name'
        description   = Get-AzlSonarMember $Step 'description'
        fullStepIndex = $Id
        startTimeUtc  = Get-AzlSonarMember $Step 'start'
        endTimeUtc    = Get-AzlSonarMember $Step 'end'
        status        = Get-AzlSonarMember $Step 'status'
        exception     = $(if ($message) { @($message) } else { @() })
        steps         = $children.ToArray()
    }
}

function Get-AzlSonarStepLeaf {
    <#
    .SYNOPSIS
        The leaf counts of a normalised tree: { done, total, running }. A leaf is a step with no children.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Tree)

    $done = 0; $total = 0; $running = 0
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($n in (ConvertTo-AzlSonarArray $Tree)) { $stack.Push($n) }
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        $kids = ConvertTo-AzlSonarArray $n['children']
        if ($kids.Count -eq 0) {
            $total++
            if ([string]$n['status'] -in 'success', 'skipped') { $done++ } elseif ([string]$n['status'] -eq 'running') { $running++ }
        }
        else { foreach ($k in $kids) { $stack.Push($k) } }
    }
    return [ordered]@{ done = $done; total = $total; running = $running }
}

function Find-AzlSonarFailedStep {
    <#
    .SYNOPSIS
        The deepest failed step of a normalised tree: { name, path[], error, start, end, node }, or $null. The error text is masked.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Tree, [string[]]$NodeName = @())

    $best = $null
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($n in (ConvertTo-AzlSonarArray $Tree)) { $stack.Push(@{ Node = $n; Path = @([string]$n['name']) }) }
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $n = $item.Node
        if ([string]$n['status'] -eq 'error') {
            if ($null -eq $best -or $item.Path.Count -ge $best.Path.Count) { $best = $item }
        }
        foreach ($k in (ConvertTo-AzlSonarArray $n['children'])) { $stack.Push(@{ Node = $k; Path = @($item.Path + [string]$k['name']) }) }
    }
    if ($null -eq $best) { return $null }
    $n = $best.Node
    $errorList = ConvertTo-AzlSonarArray $n['errors']
    $text = ($errorList -join ' ').Trim()
    if ($text.Length -gt 700) { $text = $text.Substring(0, 700) + '...' }
    # A generic leaf ("Track individual CAU step") is reported under the step that names the node.
    $reported = [string]$n['name']
    if ($reported -match '^Track individual' -and $best.Path.Count -gt 1) { $reported = [string]$best.Path[$best.Path.Count - 2] }
    $hay = (@($best.Path) -join ' ') + ' ' + $n['description']
    $nodeHit = ''
    foreach ($name in $NodeName) {
        if ($name -and $hay -match ('(?i)(?<![A-Za-z0-9-])' + [regex]::Escape($name) + '(?![A-Za-z0-9-])')) { $nodeHit = $name; break }
    }
    return [ordered]@{ name = $reported; path = [string[]]$best.Path; error = $text; start = $n['start']; end = $n['end']; node = $nodeHit }
}

function Get-AzlSonarNodeProgress {
    <#
    .SYNOPSIS
        The per-node timeline: for each cluster node, its state (Up, Paused, Down) and the steps of the run that name it.
    .DESCRIPTION
        The step names of the update run carry the node name. A node that is Paused is drained for patching; Down while a run
        is active is restarting. role is patching, draining, restarting, rejoining, done, failed, waiting, up, down or unknown.
        timeline lists the shallowest steps that name the node, oldest first (at most 30), without the node name in the step.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Tree,
        [AllowNull()][AllowEmptyCollection()][object[]]$ClusterNode,
        [bool]$RunActive = $false,
        [datetime]$Now = [datetime]::UtcNow
    )

    $flat = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($n in (ConvertTo-AzlSonarArray $Tree)) { $stack.Push(@{ Node = $n; Parent = $null }) }
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $flat.Add($item)
        foreach ($k in (ConvertTo-AzlSonarArray $item.Node['children'])) { $stack.Push(@{ Node = $k; Parent = $item.Node }) }
    }
    $rows = foreach ($cn in (ConvertTo-AzlSonarArray $ClusterNode)) {
        $name = [string](Get-AzlSonarMember $cn 'name' '')
        if (-not $name) { continue }
        $state = [string](Get-AzlSonarMember $cn 'state' '')
        $pattern = '(?i)(?<![A-Za-z0-9-])' + [regex]::Escape($name) + '(?![A-Za-z0-9-])'
        $hits = @($flat | Where-Object { ($_.Node['name'] + ' ' + $_.Node['description']) -match $pattern })
        $hitSet = [System.Collections.Generic.HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
        foreach ($h in $hits) { $null = $hitSet.Add($h.Node) }
        $top = @($hits | Where-Object { $null -eq $_.Parent -or -not $hitSet.Contains($_.Parent) })
        $starts = @($top | ForEach-Object { ConvertTo-AzlSonarUtcDate $_.Node['start'] } | Where-Object { $null -ne $_ })
        $ends = @($top | ForEach-Object { ConvertTo-AzlSonarUtcDate $_.Node['end'] } | Where-Object { $null -ne $_ })
        $runningHit = @($hits | Where-Object { [string]$_.Node['status'] -eq 'running' } | Sort-Object { ConvertTo-AzlSonarUtcDate $_.Node['start'] } | Select-Object -Last 1)
        $failedHit = @($hits | Where-Object { [string]$_.Node['status'] -eq 'error' } | Select-Object -Last 1)
        $allDone = $hits.Count -gt 0 -and @($hits | Where-Object { [string]$_.Node['status'] -notin 'success', 'skipped' }).Count -eq 0
        $clean = { param($text) ((([string]$text) -replace $pattern, '') -replace '^\s*\[[^\]]+\]\s*', '' -replace '\s{2,}', ' ').Trim() }
        $current = ''
        if ($runningHit.Count -gt 0) { $current = & $clean $runningHit[0].Node['name'] } elseif ($failedHit.Count -gt 0) { $current = & $clean $failedHit[0].Node['name'] }
        $role = 'unknown'; $word = $state
        switch -Regex ($state) {
            '^Paused$' { if ($runningHit.Count -gt 0) { $role = 'patching'; $word = 'Paused: drained and being patched' } else { $role = 'draining'; $word = 'Paused: drained for patching' } }
            '^Down$' { if ($RunActive) { $role = 'restarting'; $word = 'Down: restarting' } else { $role = 'down'; $word = 'Down' } }
            '^(Joining|Unknown)$' { $role = 'rejoining'; $word = 'Rejoining the cluster' }
            '^Up$' {
                if ($failedHit.Count -gt 0) { $role = 'failed'; $word = 'Up: a step failed' }
                elseif ($runningHit.Count -gt 0) { $role = 'patching'; $word = 'Up: being patched' }
                elseif ($allDone) { $role = 'done'; $word = 'Up: finished its steps' }
                elseif ($RunActive) { $role = 'waiting'; $word = 'Up: waiting its turn' }
                else { $role = 'up'; $word = 'Up' }
            }
        }
        $span = $null
        if ($starts.Count -gt 0) {
            $first = ($starts | Measure-Object -Minimum).Minimum
            $last = if ($runningHit.Count -gt 0 -or $ends.Count -eq 0) { $null } else { ($ends | Measure-Object -Maximum).Maximum }
            $span = @{ start = $first; end = $last }
        }
        $timeline = @($top | Sort-Object { ConvertTo-AzlSonarUtcDate $_.Node['start'] } | Select-Object -First 30 | ForEach-Object {
                [ordered]@{ name = (& $clean $_.Node['name']); status = [string]$_.Node['status']; start = $_.Node['start']; end = $_.Node['end']; durationSeconds = $_.Node['durationSeconds'] }
            })
        [ordered]@{
            name = $name; state = $state; role = $role; word = $word; step = $current
            stepStatus = $(if ($failedHit.Count -gt 0) { 'error' } elseif ($runningHit.Count -gt 0) { 'running' } elseif ($allDone) { 'success' } else { 'notstarted' })
            started = $(if ($span) { Format-AzlSonarDate $span.start } else { $null })
            ended = $(if ($span -and $span.end) { Format-AzlSonarDate $span.end } else { $null })
            durationSeconds = $(if ($span) { [long][Math]::Max(0, (($(if ($span.end) { $span.end } else { $Now })) - $span.start).TotalSeconds) } else { $null })
            steps = $hits.Count
            timeline = $timeline
        }
    }
    return , @($rows | Where-Object { $null -ne $_ })
}

function ConvertTo-AzlSonarLocalUpdate {
    <#
    .SYNOPSIS
        Turns what the node reader returned into the update.local record: the cluster's own verdict, run, steps, node progress, history, versions and events.
    .DESCRIPTION
        Pure: no node, no Azure. The verdict follows the same words as the Azure track (status notstarted | running | success | error;
        phase idle, available, waiting, preparing, installing, failed, attention), from the update states of the cluster
        (Ready, Preparing, HealthChecking, HealthCheckFailed, Installing, InstallationFailed, Installed, AdditionalContentRequired,
        Invalid) and the newest run. A run that ended Succeeded with its update Installed is success, whatever Azure still says.
        -Context carries what Sonar saw earlier in this session (the versions before the run); it is optional.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Raw,
        [string]$Node = '',
        [AllowNull()][object[]]$Attempts,
        [datetime]$Now = [datetime]::UtcNow,
        [AllowNull()][System.Collections.IDictionary]$Context
    )

    $Now = $Now.ToUniversalTime()
    $environment = Get-AzlSonarMember $Raw 'environment'
    $clusterNodeList = ConvertTo-AzlSonarArray (Get-AzlSonarMember $Raw 'clusterNodes')
    $clusterNodes = @($clusterNodeList | Where-Object { $null -ne $_ })
    $nodeNames = [string[]]@($clusterNodes | ForEach-Object { [string](Get-AzlSonarMember $_ 'name' '') } | Where-Object { $_ })

    # The summary: the same shape as the Azure summary (the readiness checks are the same objects).
    $summary = ConvertTo-AzlSonarUpdateSummary -Properties ([pscustomobject]@{
            state = Get-AzlSonarMember $environment 'state' ''; healthState = Get-AzlSonarMember $environment 'healthState' ''
            currentVersion = Get-AzlSonarMember $environment 'currentVersion' ''; currentSbeVersion = Get-AzlSonarMember $environment 'currentSbeVersion' ''
            hardwareModel = Get-AzlSonarMember $environment 'hardwareModel' ''; oemFamily = Get-AzlSonarMember $environment 'sbeFamily' ''
            lastChecked = Get-AzlSonarMember $environment 'lastChecked'; lastUpdated = Get-AzlSonarMember $environment 'lastUpdated'
            healthCheckResult = Get-AzlSonarMember $environment 'healthCheckResult'
        })

    # Every update the cluster knows, with what its state means.
    $offers = @(foreach ($item in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $Raw 'updates'))) {
            $info = Get-AzlSonarUpdateStateInfo -State ([string](Get-AzlSonarMember $item 'state' ''))
            $id = [string](Get-AzlSonarMember $item 'id' '')
            $installed = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $item 'installedDate')
            [pscustomobject]@{
                id = $id; name = ($id -split '/')[-1]; version = [string](Get-AzlSonarMember $item 'version' ''); sbeVersion = [string](Get-AzlSonarMember $item 'sbeVersion' '')
                displayName = [string](Get-AzlSonarMember $item 'displayName' ''); description = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $item 'description' ''))
                packageType = [string](Get-AzlSonarMember $item 'packageType' ''); state = $info.raw; stateWord = $info.word; kind = $info.kind; phase = $info.phase; level = $info.level
                nextAction = $info.nextAction; rebootRequired = [string](Get-AzlSonarMember $item 'rebootRequired' ''); availabilityType = [string](Get-AzlSonarMember $item 'availabilityType' '')
                progressPercentage = Get-AzlSonarMember $item 'progressPercentage'; notifyMessage = Protect-AzlSonarText -Text ([string](Get-AzlSonarMember $item 'notifyMessage' ''))
                installedDate = Format-AzlSonarDate $installed; installed = $installed
            }
        })
    $kindOrder = @{ running = 0; failed = 1; waiting = 2; ready = 3; unknown = 4; ignored = 5; installed = 6 }
    $ordered = @($offers | Sort-Object -Property @{ Expression = { $kindOrder[$_.kind] } }, @{ Expression = { if ($null -ne $_.installed) { $_.installed } else { [datetime]::MinValue } }; Descending = $true } -Stable)
    $active = $ordered | Where-Object { $_.kind -eq 'running' } | Select-Object -First 1
    if ($null -eq $active) { $active = $ordered | Where-Object { $_.kind -eq 'failed' } | Select-Object -First 1 }
    $waiting = $ordered | Where-Object { $_.kind -eq 'waiting' } | Select-Object -First 1
    $ready = $ordered | Where-Object { $_.kind -eq 'ready' } | Select-Object -First 1
    $installedUpdates = @($ordered | Where-Object { $_.kind -eq 'installed' })
    $byId = @{}; foreach ($o in $offers) { if ($o.id) { $byId[$o.id] = $o } }

    # Runs: newest first. Only the newest (and a running or failed one) carries a step tree.
    $runs = @(foreach ($r in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $Raw 'runs'))) {
            $started = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $r 'started')
            $updated = ConvertTo-AzlSonarUtcDate (Get-AzlSonarMember $r 'lastUpdated')
            $status = ConvertTo-AzlSonarStepStatus (Get-AzlSonarMember $r 'state')
            $seconds = Get-AzlSonarMember $r 'durationSeconds'
            $updateId = [string](Get-AzlSonarMember $r 'updateId' '')
            $offer = if ($byId.ContainsKey($updateId)) { $byId[$updateId] } else { $null }
            $ended = $null
            if ($status -in 'success', 'error', 'skipped') {
                $ended = if ($null -ne $started -and $null -ne $seconds) { $started.AddSeconds([double]$seconds) } else { $updated }
            }
            [pscustomobject]@{
                id = [string](Get-AzlSonarMember $r 'id' ''); update = ($updateId -split '/')[-1]; updateId = $updateId
                version = $(if ($offer) { $offer.version } else { '' }); packageType = $(if ($offer) { $offer.packageType } else { '' })
                rawState = [string](Get-AzlSonarMember $r 'state' ''); status = $status; type = [string](Get-AzlSonarMember $r 'type' '')
                started = $(if ($null -ne $started) { $started } else { [datetime]::MinValue.AddSeconds(1) }); startedText = Format-AzlSonarDate $started
                lastUpdated = Format-AzlSonarDate $updated; ended = $ended; durationSeconds = $seconds
                progress = Get-AzlSonarMember $r 'progress'
            }
        })
    $runs = @($runs | Sort-Object -Property started -Descending)
    $newest = $runs | Select-Object -First 1

    $tree = @(); $counts = Measure-AzlSonarStepTree -Tree @(); $run = $null; $runStatus = 'notstarted'; $failed = $null
    $leaf = [ordered]@{ done = 0; total = 0; running = 0 }
    if ($null -ne $newest) {
        $runStatus = $newest.status
        if ($null -ne $newest.progress) {
            $root = ConvertTo-AzlSonarLocalStep -Step $newest.progress -Id '1'
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject ([pscustomobject]@{ steps = @($root) }) -Now $Now)
            if ($tree.Count -eq 1 -and @($tree[0].children).Count -gt 0) { $tree = @($tree[0].children) }
            $counts = Measure-AzlSonarStepTree -Tree $tree
            $leaf = Get-AzlSonarStepLeaf -Tree $tree
            $failed = Find-AzlSonarFailedStep -Tree $tree -NodeName $nodeNames
            if ($runStatus -in 'unknown', 'notstarted') { $runStatus = Get-AzlSonarRollupStatus -RawStatus $null -Tree $tree }
        }
        $end = $newest.ended
        if ($runStatus -in 'success', 'error' -and $null -eq $end) { $end = Get-AzlSonarTreeEnd -Tree $tree }
        $seconds = if ($null -ne $newest.durationSeconds) { [long]$newest.durationSeconds } elseif ($null -ne $end -and $newest.started.Year -gt 1) { [long][Math]::Max(0, ($end - $newest.started).TotalSeconds) } elseif ($runStatus -eq 'running' -and $newest.started.Year -gt 1) { [long][Math]::Max(0, ($Now - $newest.started).TotalSeconds) } else { $null }
        $run = [ordered]@{
            id = $newest.id; update = $newest.update; version = $newest.version; packageType = $newest.packageType; type = $newest.type; state = $newest.rawState; status = $runStatus
            started = $newest.startedText; lastUpdated = $newest.lastUpdated; ended = Format-AzlSonarDate $end; durationSeconds = $seconds
            duration = $(if ($null -ne $seconds) { ([timespan]::FromSeconds($seconds)).ToString('hh\:mm\:ss') } else { '' })
        }
    }

    # The verdict, in the Azure track's words.
    $envState = [string](Get-AzlSonarMember $environment 'state' '')
    $status = 'notstarted'; $phase = 'idle'
    $runUpdate = if ($null -ne $newest -and $byId.ContainsKey($newest.updateId)) { $byId[$newest.updateId] } else { $null }
    if ($null -ne $active -and $active.kind -eq 'running') { $status = 'running'; $phase = $active.phase }
    elseif ($null -ne $active) { $status = 'error'; $phase = 'failed' }
    elseif ($runStatus -eq 'running' -and $envState -ne 'AppliedSuccessfully') { $status = 'running'; $phase = 'installing' }
    elseif ($runStatus -eq 'error' -and ($null -eq $runUpdate -or $runUpdate.kind -ne 'installed')) { $status = 'error'; $phase = 'failed' }
    else {
        switch ($envState) {
            'UpdateInProgress' { $status = 'running'; $phase = 'installing' }
            'PreparationInProgress' { $status = 'running'; $phase = 'preparing' }
            'UpdateFailed' { $status = 'error'; $phase = 'failed' }
            'PreparationFailed' { $status = 'error'; $phase = 'failed' }
            'NeedsAttention' { $status = 'error'; $phase = 'attention' }
        }
    }
    if ($status -eq 'notstarted') {
        if ($null -ne $waiting) { $phase = 'waiting' }
        elseif ($null -ne $ready -or $envState -eq 'UpdateAvailable') { $phase = 'available' }
        $ranOk = $runStatus -eq 'success' -and ($installedUpdates.Count -gt 0 -or $envState -eq 'AppliedSuccessfully')
        if ($ranOk -and $phase -eq 'idle') { $status = 'success' }
    }
    $focus = if ($null -ne $active) { $active } elseif ($null -ne $waiting) { $waiting } elseif ($null -ne $ready) { $ready } else { $null }
    $activeOut = $null
    if ($null -ne $active) { $activeOut = [ordered]@{ name = $active.name; version = $active.version; displayName = $active.displayName; state = $active.state; rebootRequired = $active.rebootRequired } }
    $verdict = Get-AzlSonarUpdateVerdict -Status $status -Phase $phase -Summary $summary -Active $activeOut -Focus $focus

    # Versions before and after: the cluster keeps the old version until the run ends, so Sonar remembers what it saw while the run ran.
    $current = [ordered]@{ solution = [string]$summary.currentVersion; sbe = [string]$summary.currentSbeVersion }
    $subject = if ($null -ne $active) { $active } elseif ($null -ne $runUpdate) { $runUpdate } else { $null }
    $target = [ordered]@{ solution = ''; sbe = ''; packageType = '' }
    if ($null -ne $subject) {
        $target.packageType = $subject.packageType
        if ($subject.packageType -eq 'SBE') { $target.sbe = $subject.version } else { $target.solution = $subject.version; $target.sbe = $subject.sbeVersion }
    }
    $before = [ordered]@{ solution = ''; sbe = ''; known = $false }
    $after = [ordered]@{ solution = ''; sbe = ''; known = $false }
    if ($null -ne $newest) {
        $pre = if ($null -ne $Context) { $Context['PreRun'] } else { $null }
        if ($runStatus -eq 'running') {
            $before = [ordered]@{ solution = $current.solution; sbe = $current.sbe; known = $true }
        }
        elseif ($null -ne $pre -and [string]$pre.RunId -eq $newest.id) {
            $before = [ordered]@{ solution = [string]$pre.Solution; sbe = [string]$pre.Sbe; known = $true }
        }
        if ($runStatus -eq 'success') { $after = [ordered]@{ solution = $current.solution; sbe = $current.sbe; known = $true } }
        elseif ($runStatus -eq 'running' -and ($target.solution -or $target.sbe)) { $after = [ordered]@{ solution = $target.solution; sbe = $target.sbe; known = $false } }
    }

    $runActive = $status -eq 'running'
    $nodesOut = Get-AzlSonarNodeProgress -Tree $tree -ClusterNode $clusterNodes -RunActive $runActive -Now $Now

    # What happened, from the run itself: it needs no earlier poll, so a Sonar that starts mid-update still has the start.
    $events = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $run) {
        $what = if ($run.version -and $run.update -notlike "*$($run.version)*") { "$($run.update) $($run.version)" } else { [string]$run.update }
        if ($run.started) { $events.Add([ordered]@{ at = $run.started; kind = 'started'; text = "Update $what started on the cluster." }) }
        if ($run.status -eq 'success') { $events.Add([ordered]@{ at = $(if ($run.ended) { $run.ended } else { $run.lastUpdated }); kind = 'finished'; text = "Update $what finished on the cluster: succeeded after $($run.duration)." }) }
        elseif ($run.status -eq 'error') {
            $where = if ($null -ne $failed) { " at '$($failed.name)'" + $(if ($failed.node) { " on $($failed.node)" } else { '' }) } else { '' }
            $events.Add([ordered]@{ at = $(if ($run.ended) { $run.ended } else { $run.lastUpdated }); kind = 'failed'; text = "Update $what failed on the cluster$where." })
        }
    }
    $history = @($runs | Select-Object -First 10 | ForEach-Object {
            [ordered]@{
                id = $_.id; update = $_.update; version = $_.version; packageType = $_.packageType; type = $_.type; status = $_.status; state = $_.rawState
                started = $_.startedText; ended = Format-AzlSonarDate $_.ended; durationSeconds = $_.durationSeconds
                duration = $(if ($null -ne $_.durationSeconds) { ([timespan]::FromSeconds([double]$_.durationSeconds)).ToString('hh\:mm\:ss') } else { '' })
            }
        })

    $partialList = ConvertTo-AzlSonarArray (Get-AzlSonarMember $Raw 'errors')
    $partial = @($partialList | ForEach-Object { Protect-AzlSonarText -Text ([string]$_) })
    $updatesOut = @($ordered | Select-Object -First 20 | ForEach-Object {
            [ordered]@{
                name = $_.name; version = $_.version; displayName = $_.displayName; description = $_.description; packageType = $_.packageType
                state = $_.state; stateWord = $_.stateWord; phase = $_.phase; level = $_.level; nextAction = $_.nextAction; rebootRequired = $_.rebootRequired
                availabilityType = $_.availabilityType; progressPercentage = $_.progressPercentage; notifyMessage = $_.notifyMessage; installedDate = $_.installedDate
            }
        })
    $currentStep = Get-AzlSonarCurrentStep -Tree $tree -Phase 'update'
    return [ordered]@{
        enabled = $true; read = $true; stale = $false; reason = ''; reasonKind = ''
        node = $Node; nodeNote = ''; readAt = Format-AzlSonarDate $Now; ageSeconds = 0
        attempts = @($Attempts | Where-Object { $null -ne $_ })
        status = $status; phase = $phase; level = $verdict.level; label = $verdict.label; nextAction = $verdict.nextAction
        state = $(if ($null -ne $focus) { $focus.state } else { $envState }); stateWord = $(if ($null -ne $focus) { $focus.stateWord } else { $envState })
        active = $activeOut; summary = $summary; updates = $updatesOut
        run = $run; runStatus = $runStatus; tree = $tree; counts = $counts
        progress = [ordered]@{ done = $leaf.done; total = $leaf.total; running = $leaf.running; current = [string]$currentStep.stepName; elapsedSeconds = $(if ($null -ne $run) { $run.durationSeconds } else { $null }) }
        failed = $failed
        nodes = $nodesOut
        history = $history
        versions = [ordered]@{ current = $current; before = $before; after = $after; target = $target }
        events = $events.ToArray()
        partialErrors = $partial
    }
}

# ---------------------------------------------------------------------------------------------------------------- the state per poll

function Get-AzlSonarEmptyLocalUpdate {
    <#
    .SYNOPSIS
        An update.local record for a poll that has no cluster data: node-side reading is off, paused, or no node answered. Says why in plain words.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [bool]$Enabled,
        [AllowEmptyString()][string]$Reason,
        [string]$ReasonKind,
        [AllowNull()][object[]]$Attempts
    )

    return [ordered]@{
        enabled = $Enabled; read = $false; stale = $false; reason = $Reason; reasonKind = $ReasonKind
        node = ''; nodeNote = ''; readAt = $null; ageSeconds = $null; attempts = @($Attempts | Where-Object { $null -ne $_ })
        status = 'notstarted'; phase = 'idle'; level = 'neutral'; label = ''; nextAction = $null; state = ''; stateWord = ''; active = $null
        summary = $null; updates = @(); run = $null; runStatus = 'notstarted'; tree = @(); counts = (Measure-AzlSonarStepTree -Tree @())
        progress = [ordered]@{ done = 0; total = 0; running = 0; current = ''; elapsedSeconds = $null }
        failed = $null; nodes = @(); history = @()
        versions = [ordered]@{ current = [ordered]@{ solution = ''; sbe = '' }; before = [ordered]@{ solution = ''; sbe = ''; known = $false }; after = [ordered]@{ solution = ''; sbe = ''; known = $false }; target = [ordered]@{ solution = ''; sbe = ''; packageType = '' } }
        events = @(); partialErrors = @()
    }
}

function Add-AzlSonarUpdateEvent {
    <#
    .SYNOPSIS
        Keeps a short list of what Sonar saw change in this session: the update state, a node going Paused or Down.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory list only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][datetime]$At, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Text)

    $list = $Context['Events']
    $list.Add([ordered]@{ at = Format-AzlSonarDate $At; kind = $Kind; text = $Text })
    while ($list.Count -gt $script:AzlSonarUpdateMaxEvents) { $list.RemoveAt(0) }
}

function Update-AzlSonarUpdateObservation {
    <#
    .SYNOPSIS
        Remembers what the cluster said this poll: when its current state was first seen, the versions before a run, node state changes.
    .DESCRIPTION
        Returns the record with the session events merged in and the first-seen time of the current state added as observedSince.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Local,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [datetime]$Now = [datetime]::UtcNow
    )

    $key = '{0}|{1}|{2}' -f $Local.status, $Local.phase, $Local.state
    $observed = $Context['Observed']
    if ($null -eq $observed -or $observed.Key -ne $key) {
        if ($null -ne $observed) { Add-AzlSonarUpdateEvent -Context $Context -At $Now -Kind 'state' -Text ("The cluster's update state changed to {0}." -f $(if ($Local.stateWord) { $Local.stateWord } else { $Local.phase })) }
        $observed = @{ Key = $key; Since = $Now }
        $Context['Observed'] = $observed
    }
    $run = $Local.run
    if ($null -ne $run -and $run.status -eq 'running' -and ($null -eq $Context['PreRun'] -or [string]$Context['PreRun'].RunId -ne [string]$run.id)) {
        $Context['PreRun'] = @{ RunId = [string]$run.id; Solution = [string]$Local.versions.current.solution; Sbe = [string]$Local.versions.current.sbe }
        $Local.versions.before = [ordered]@{ solution = [string]$Local.versions.current.solution; sbe = [string]$Local.versions.current.sbe; known = $true }
    }
    $previous = $Context['NodeStates']
    foreach ($n in $Local.nodes) {
        $old = if ($previous.ContainsKey($n.name)) { [string]$previous[$n.name] } else { '' }
        if ($old -and $old -ne $n.state) { Add-AzlSonarUpdateEvent -Context $Context -At $Now -Kind 'node' -Text ("Node {0} went from {1} to {2}." -f $n.name, $old, $n.state) }
        $previous[$n.name] = $n.state
    }
    $Local.observedSince = Format-AzlSonarDate $observed.Since
    $merged = @($Local.events) + @($Context['Events'].ToArray())
    $Local.events = @($merged | Sort-Object -Property { ConvertTo-AzlSonarUtcDate $_.at } | Select-Object -Last 60)
    return $Local
}

function Copy-AzlSonarLocalRecord {
    <#
    .SYNOPSIS
        A shallow copy of a local record (the cache holds one; a changed copy is returned, the cache is not edited).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Local)

    $copy = [ordered]@{}
    foreach ($k in $Local.Keys) { $copy[$k] = $Local[$k] }
    return $copy
}

function Format-AzlSonarAttemptSummary {
    <#
    .SYNOPSIS
        One plain sentence about the nodes that did not answer, for example "n01 did not answer".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object[]]$Attempts)

    $bad = @($Attempts | Where-Object { $null -ne $_ -and -not $_.ok })
    if ($bad.Count -eq 0) { return '' }
    $parts = foreach ($a in $bad) {
        $why = switch ($a.class) {
            'unreachable' { 'did not answer' }
            'module' { 'has no Azure Local update module' }
            default {
                $hint = if ([string]$a.detail -match 'TrustedHosts') { 'cannot be reached by IP address: use its host name or add it to TrustedHosts' } elseif ($a.class -eq 'other' -and $a.detail) { [string]$a.detail } else { [string]$a.reason }
                "failed ($hint)"
            }
        }
        "$($a.node) $why"
    }
    return ($parts -join '; ')
}

function Get-AzlSonarLocalUpdateState {
    <#
    .SYNOPSIS
        update.local for this poll: reads the cluster's own update service, or says plainly why it did not.
    .DESCRIPTION
        Off (no account): Azure-only, with the reason. Paused (the account was rejected): the breaker message. Otherwise it reads
        one node at most every 10 seconds while an update is running (in the cluster or in Azure) and every 30 seconds otherwise,
        and shows the last good read in between. When no node answers the last good read stays for 10 minutes, marked stale, and
        the record says that the node being read is probably restarting; it is not an error. Never throws.
    .PARAMETER AzureActive
        Azure shows an update running: read at the fast pace.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][System.Collections.IDictionary]$Context,
        [datetime]$Now = [datetime]::UtcNow,
        [bool]$AzureActive = $false
    )

    $Now = $Now.ToUniversalTime()
    if ($null -eq $Context) { $Context = New-AzlSonarUpdateContext }
    try {
        $account = Get-AzlSonarUpdateAccount -Config $Config -Context $Context -Now $Now
        if ($account.Status -ne 'ok') { return (Get-AzlSonarEmptyLocalUpdate -Enabled $false -Reason $account.Message -ReasonKind $account.Status) }
        $null = Test-AzlSonarUpdateSecretChanged -Config $Config -Context $Context -Now $Now
        $account = $Context['Account']
        $block = Get-AzlSonarUpdateBreakerMessage -Context $Context -Now $Now
        $cache = $Context['Cache']
        if ($block) {
            if ($null -ne $cache) { $held = Copy-AzlSonarLocalRecord -Local $cache; $held.stale = $true; $held.reason = $block; $held.reasonKind = 'credential'; return $held }
            return (Get-AzlSonarEmptyLocalUpdate -Enabled $true -Reason $block -ReasonKind 'credential')
        }

        $last = $Context['LastReadAt']
        $fast = $AzureActive -or ($null -ne $cache -and $cache.status -eq 'running')
        $gap = if ($fast) { $script:AzlSonarUpdateActiveSeconds } else { $script:AzlSonarUpdateIdleSeconds }
        if ($null -ne $cache -and $null -ne $last -and ($Now - $last).TotalSeconds -lt $gap -and ($Now - $last).TotalSeconds -ge 0) {
            $held = Copy-AzlSonarLocalRecord -Local $cache
            $held.ageSeconds = [int][Math]::Floor(($Now - $last).TotalSeconds)
            return $held
        }

        $read = Read-AzlSonarNodeUpdate -Config $Config -Credential $account.Credential -FirstNode ([string]$Context['Node'])
        if ($read.Ok) {
            $local = ConvertTo-AzlSonarLocalUpdate -Raw $read.Raw -Node $read.Node -Attempts $read.Attempts -Now $Now -Context $Context
            $skipped = Format-AzlSonarAttemptSummary -Attempts $read.Attempts
            if ($skipped) { $local.nodeNote = "$skipped, so $($read.Node) was read. A node restarts during an update; this is normal." }
            elseif ($Context['Node'] -and $Context['Node'] -ne $read.Node) { $local.nodeNote = "Reading from $($read.Node) now." }
            $Context['Node'] = $read.Node
            $Context['Rejections'] = 0
            $local = Update-AzlSonarUpdateObservation -Local $local -Context $Context -Now $Now
            $Context['Cache'] = $local
            $Context['LastReadAt'] = $Now
            return $local
        }

        # No node gave data.
        if ($null -ne $read.Stop) {
            Register-AzlSonarUpdateFailure -Context $Context -Class ([string]$read.Stop.Class) -Reason ([string]$read.Stop.Reason) -Now $Now
            $why = Get-AzlSonarUpdateBreakerMessage -Context $Context -Now $Now
            if (-not $why) { $why = "Node-side update reading failed: $($read.Stop.Reason)." }
            if ($null -ne $cache) { $held = Copy-AzlSonarLocalRecord -Local $cache; $held.stale = $true; $held.reason = $why; $held.reasonKind = 'credential'; $held.attempts = $read.Attempts; return $held }
            return (Get-AzlSonarEmptyLocalUpdate -Enabled $true -Reason $why -ReasonKind 'credential' -Attempts $read.Attempts)
        }
        $tried = Format-AzlSonarAttemptSummary -Attempts $read.Attempts
        if ($null -ne $cache -and $null -ne $last -and ($Now - $last).TotalMinutes -le $script:AzlSonarUpdateStaleMinutes) {
            $held = Copy-AzlSonarLocalRecord -Local $cache
            $held.stale = $true
            $held.ageSeconds = [int][Math]::Floor(($Now - $last).TotalSeconds)
            $held.reasonKind = 'unreachable'
            $held.reason = "No node answered just now ($tried). The node being read is probably restarting. Sonar keeps trying the next node and shows the cluster's last answer from $(Format-AzlSonarDate $last) (UTC)."
            $held.attempts = $read.Attempts
            return $held
        }
        $text = if ($tried) { "No node answered ($tried). Showing what Azure reports until one does." } else { 'No node is configured to read.' }
        return (Get-AzlSonarEmptyLocalUpdate -Enabled $true -Reason $text -ReasonKind 'unreachable' -Attempts $read.Attempts)
    }
    catch {
        return (Get-AzlSonarEmptyLocalUpdate -Enabled $true -Reason ("Node-side update reading failed: $(Protect-AzlSonarText -Text $_.Exception.Message)") -ReasonKind 'error')
    }
}

# ---------------------------------------------------------------------------------------------------------------- merging with Azure

function Format-AzlSonarMinute {
    <#
    .SYNOPSIS
        "1 minute" or "17 minutes".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Minute)

    if ($Minute -eq 1) { return '1 minute' }
    return "$Minute minutes"
}

function Merge-AzlSonarUpdateSource {
    <#
    .SYNOPSIS
        Merges what the cluster says (update.local) into the Azure update verdict and adds update.sources.
    .DESCRIPTION
        The cluster's state wins when it was read (even from the last good read while a node restarts) and differs from Azure's.
        Both are shown: update.sources has the Azure side, the cluster side, who wins and, when Azure is behind, by how many
        minutes. The step tree, run and history come from the cluster when its run is the newer. A run that ended Succeeded on
        the cluster shows "Update succeeded" even when Azure still says Ready. With no cluster data update.sources says so and
        the Azure verdict stays as it was.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Azure,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Local,
        [datetime]$Now = [datetime]::UtcNow
    )

    $Now = $Now.ToUniversalTime()
    $azRun = $Azure['run']
    $azState = if ($null -ne $Azure['active']) { [string]$Azure['active'].state } elseif ($null -ne $Azure['summary']) { [string]$Azure['summary'].state } else { '' }
    $azureSide = [ordered]@{
        read = ($null -ne $Azure['summary']) -or @($Azure['updates']).Count -gt 0
        state = $azState; status = [string]$Azure['status']; phase = [string]$Azure['phase']; label = [string]$Azure['label']
        runUpdated = $(if ($null -ne $azRun) { [string]$azRun.lastUpdated } else { $null })
    }
    $clusterSide = [ordered]@{
        enabled = [bool]$Local['enabled']; read = [bool]$Local['read']; stale = [bool]$Local['stale']; node = [string]$Local['node']
        state = [string]$Local['state']; status = [string]$Local['status']; phase = [string]$Local['phase']; label = [string]$Local['label']
        readAt = $Local['readAt']; reason = [string]$Local['reason']
    }
    $sources = [ordered]@{ azure = $azureSide; cluster = $clusterSide; winner = 'azure'; agree = $true; lagMinutes = $null; lagSince = $null; lagBasis = ''; message = '' }
    $Azure['local'] = $Local
    $Azure['sources'] = $sources

    if (-not [bool]$Local['read']) {
        $sources.message = $(if ($Local['reason']) { [string]$Local['reason'] } else { 'The cluster was not read; this is what Azure reports.' })
        return $Azure
    }

    $agree = ($azureSide.status -eq $clusterSide.status) -and ($azureSide.phase -eq $clusterSide.phase)
    $sources.agree = $agree
    $sources.winner = 'cluster'
    $localRun = $Local['run']

    # Run, steps and history: the cluster's when its run is the newer one (or Azure has none).
    $useLocalRun = $false
    if ($null -ne $localRun) {
        $azStart = if ($null -ne $azRun) { ConvertTo-AzlSonarUtcDate $azRun.timeStarted } else { $null }
        $localStart = ConvertTo-AzlSonarUtcDate $localRun.started
        $useLocalRun = $null -eq $azStart -or ($null -ne $localStart -and $localStart -ge $azStart)
    }
    if ($useLocalRun) {
        $Azure['run'] = [ordered]@{ name = [string]$localRun.id; update = [string]$localRun.update; status = [string]$localRun.status; timeStarted = $localRun.started; duration = [string]$localRun.duration; lastUpdated = $localRun.lastUpdated; source = 'cluster' }
        $Azure['tree'] = $Local['tree']
        $Azure['counts'] = $Local['counts']
        $Azure['ran'] = $true
        if (@($Local['history']).Count -ge @($Azure['runs']).Count) {
            $Azure['runs'] = @($Local['history'] | ForEach-Object { [ordered]@{ name = $_.id; update = $_.update; status = $_.status; timeStarted = $_.started; duration = $_.duration; lastUpdated = $_.ended; source = 'cluster' } })
        }
    }
    if ($null -eq $Azure['summary']) { $Azure['summary'] = $Local['summary'] }

    if (-not $agree) {
        $Azure['status'] = $Local['status']
        $Azure['phase'] = $Local['phase']
        $Azure['active'] = $Local['active']
        $Azure['updates'] = $Local['updates']
        $Azure['ran'] = [bool]$Azure['ran'] -or $null -ne $localRun
        $focus = @($Local['updates'] | Where-Object { $_.phase -eq $Local['phase'] } | Select-Object -First 1)
        $verdict = Get-AzlSonarUpdateVerdict -Status ([string]$Local['status']) -Phase ([string]$Local['phase']) -Summary $Azure['summary'] -Active $Local['active'] -Focus $(if ($focus.Count) { $focus[0] } else { $null })
        $Azure['level'] = $verdict.level
        $Azure['label'] = $verdict.label
        $Azure['nextAction'] = $verdict.nextAction
        if ($Local['status'] -eq 'running' -or $Local['status'] -eq 'error') { $Azure['label'] = [string]$Local['label'] }

        # How far behind is Azure? From when the cluster entered the state Azure does not show yet.
        $since = $null; $basis = ''
        if ($null -ne $localRun) {
            if ($Local['status'] -eq 'running') { $since = ConvertTo-AzlSonarUtcDate $localRun.started; $basis = 'run' }
            elseif ($localRun.ended) { $since = ConvertTo-AzlSonarUtcDate $localRun.ended; $basis = 'run' }
            else { $since = ConvertTo-AzlSonarUtcDate $localRun.lastUpdated; $basis = 'run' }
        }
        if ($null -eq $since -and $Local.Contains('observedSince') -and $Local['observedSince']) { $since = ConvertTo-AzlSonarUtcDate $Local['observedSince']; $basis = 'observed' }
        if ($null -ne $since) {
            $minutes = [int][Math]::Max(0, [Math]::Floor(($Now - $since).TotalMinutes))
            $sources.lagMinutes = $minutes
            $sources.lagSince = Format-AzlSonarDate $since
            $sources.lagBasis = $basis
            $azWord = if ($azureSide.label) { $azureSide.label } else { $azureSide.phase }
            $behind = if ($minutes -lt 1) { 'Azure is behind the cluster' } else { "Azure is behind the cluster by $(Format-AzlSonarMinute $minutes)" }
            $sources.message = "$behind. The cluster says: $($clusterSide.label). Azure still says: $azWord. Sonar shows the cluster's state."
        }
        else {
            $sources.message = "Azure and the cluster disagree. The cluster says: $($clusterSide.label). Azure says: $($azureSide.label). Sonar shows the cluster's state."
        }
    }
    elseif ($null -ne $localRun -and $Local['status'] -eq 'running' -and $null -ne $azRun) {
        # Both say running: is Azure's run record behind?
        $a = ConvertTo-AzlSonarUtcDate $azRun.lastUpdated
        $l = ConvertTo-AzlSonarUtcDate $localRun.lastUpdated
        if ($null -ne $a -and $null -ne $l -and ($l - $a).TotalMinutes -ge 5) {
            $minutes = [int][Math]::Floor(($l - $a).TotalMinutes)
            $sources.lagMinutes = $minutes
            $sources.lagSince = Format-AzlSonarDate $a
            $sources.lagBasis = 'run'
            $sources.message = "Azure is behind the cluster by $(Format-AzlSonarMinute $minutes). Both say the update is running, but Azure's last step is older. Sonar shows the cluster's steps."
        }
    }
    if ($Local['stale']) {
        $note = [string]$Local['reason']
        if ($note) { $sources.message = (@($sources.message, $note) | Where-Object { $_ }) -join ' ' }
    }
    return $Azure
}

function Register-AzlSonarUpdateRedaction {
    <#
    .SYNOPSIS
        Registers the update account's password for masking (as a fingerprint, no plaintext) once, under the credential lock.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Shared)

    if (-not $Shared.Contains('UpdateLocal')) { return }
    $context = $Shared['UpdateLocal']
    $account = $context['Account']
    if ($null -eq $account -or $account.Status -ne 'ok' -or $null -eq $account.Credential -or [bool](Get-AzlSonarMember $context 'RedactAdded' $false)) { return }
    $lock = if ($Shared.Contains('CredentialLock')) { $Shared['CredentialLock'] } else { $Shared['Lock'] }
    [System.Threading.Monitor]::Enter($lock)
    try {
        Add-AzlSonarRedaction -Shared $Shared -Secret $account.Credential.Password
        $context['RedactAdded'] = $true
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Get-AzlSonarLocalUpdateSnapshot {
    <#
    .SYNOPSIS
        update.local for this poll when a background reader runs: the reader's latest record, without touching a node.
    .DESCRIPTION
        The reader (Invoke-AzlSonarUpdateReaderLoop) takes seconds per read on its own thread, so the Azure poll never waits for a node.
        Marks the context as wanted: the reader reads only while the poller asks for the update track (a deployment still in progress
        is never read, because the deployment account does not exist on a workgroup node and every try would be a failed sign-in).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [datetime]$Now = [datetime]::UtcNow, [bool]$AzureActive = $false)

    $Context['WantedAt'] = $Now.ToUniversalTime()
    $Context['AzureActive'] = $AzureActive
    $latest = $Context['Latest']
    if ($null -ne $latest) { return $latest }
    return (Get-AzlSonarEmptyLocalUpdate -Enabled $true -Reason 'Reading the cluster''s update service for the first time.' -ReasonKind 'pending')
}

function Invoke-AzlSonarUpdateReaderLoop {
    <#
    .SYNOPSIS
        Background loop: reads the cluster's own update service while the update track is wanted, and keeps the latest record in Shared.UpdateLocal.
    .DESCRIPTION
        Idle until the poller has asked for the update track in the last two minutes. Then it calls Get-AzlSonarLocalUpdateState
        (which keeps its own pace: 10 seconds while an update runs, 30 otherwise, and the breaker for a refused account).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config
    )

    $context = $Shared['UpdateLocal']
    $context['Background'] = $true
    while (-not $Shared.Stop) {
        try {
            $now = [datetime]::UtcNow
            $wanted = $context['WantedAt']
            if ($null -ne $wanted -and ($now - $wanted).TotalSeconds -le 120) {
                $context['Latest'] = Get-AzlSonarLocalUpdateState -Config $Config -Context $context -Now $now -AzureActive ([bool]$context['AzureActive'])
            }
        }
        catch { Write-Verbose "Update reader: $($_.Exception.Message)" }
        Wait-AzlSonarInterval -Shared $Shared -Seconds 3
    }
}
