Set-StrictMode -Version Latest

# Which account reads a node's logs. Until a node has reported BOTH OS configuration events DomainJoined and
# DomainAdminsConfigured (the step that adds the domain account to the node's local Administrators; a domain account is not
# an administrator of the node before that), or when the identity design is local, the local account is used:
# identity.local_admin from the master file, or the account given with -Credential or the prompt. After both events the
# domain account the operator supplies is used for that node: NETBIOS\user from identity.active_directory (netbios_name and
# domain_join_account.username), its password read from the Key Vault reference identity.active_directory.domain_join_account.password
# (keyvault://<vault>/<secret>[/<version>]). Sonar never uses the LCM user (identity.active_directory.lcm_user), for this or
# for anything else: that account belongs to the deployment.
#
# The domain account is a service account that other things depend on, so Sonar guards it:
#  - ONE circuit breaker for the account, shared by every node, decided under the lock. The first use of the account (and
#    the first use after any reset) is ONE probe: only that node gets the account until its connection reports ok. The first
#    authentication rejection by any node opens the breaker: no node is given the domain account for a back-off (15 minutes,
#    doubling to 2 hours). After the back-off exactly ONE probe is allowed at a time (a lease: a node that makes no attempt
#    loses the slot after AzlSonarProbeLeaseSeconds); a rejected probe doubles the back-off; after maxRejections rejections
#    (default 2) the breaker latches until the secret's version changes (then ONE probe, closing only on its ok), the operator
#    confirms the unlock, or Sonar restarts. A locked-out account latches at once. A rejected account is never retried per
#    poll. Every connection reports back with the ticket it was handed (an epoch): a result older than the breaker's last
#    change is ignored, and only the probe holder can close the breaker or release the slot.
#  - Key Vault is read by the probe holder, outside the lock.
#  - A credential that cannot be had (Key Vault outage, Az.KeyVault missing, an expired Azure sign-in) is not a rejection: the
#    local account is used and the credential is asked for again after 1, 2, then 5 minutes. No node is marked rejected.
#  - An account that logs on but is not an administrator of the node (authorization) does not open the breaker; the local
#    account is used for that node and the node is tried again after 5 minutes.
#  - Timeouts and network errors change nothing.
# The password is never kept as text: it lives in a SecureString inside the credential, and the masking of it uses a
# fingerprint (SecretMask.ps1). The state, Details and the page carry the account NAME, the breaker state and the reason, never
# a secret. All of it is kept in Shared under ONE lock (CredentialLock) as immutable records that are replaced, never edited.

$script:AzlSonarDomainKey = '*domain'
$script:AzlSonarBreakerKey = '*breaker'
$script:AzlSonarUnavailableKey = '*unavailable'
$script:AzlSonarBreakerStartMinutes = 15
$script:AzlSonarBreakerMaxMinutes = 120
$script:AzlSonarUnavailableMinutes = @(1, 2, 5)
$script:AzlSonarAuthorizationMinutes = 5
$script:AzlSonarDefaultMaxRejections = 2
$script:AzlSonarProbeLeaseSeconds = 120

function ConvertFrom-AzlSonarKeyVaultReference {
    <#
    .SYNOPSIS
        keyvault://<vault>/<secret>[/<version>] into { Vault, Secret, Version }, or $null when it is not a valid reference.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Reference)

    if (-not [string]::IsNullOrEmpty((Get-AzlSonarKeyVaultReferenceProblem -Reference $Reference))) { return $null }
    $m = [regex]::Match($Reference, '\Akeyvault://(?<vault>[^/]+)/(?<secret>[^/]+)(/(?<version>[^/]+))?\z')
    return @{ Vault = $m.Groups['vault'].Value; Secret = $m.Groups['secret'].Value; Version = $m.Groups['version'].Value }
}

function Get-AzlSonarKeyVaultReferenceProblem {
    <#
    .SYNOPSIS
        Why a Key Vault reference is not valid, or '' when it is. Never echoes the value.
    .DESCRIPTION
        keyvault://<vault>/<secret>[/<version>]. The vault name follows Azure's rules: 3 to 24 characters, starts with a
        letter, letters, digits and single hyphens, no leading or trailing hyphen. The secret name is 1 to 127 letters, digits
        and hyphens. The version, when given, is 32 hexadecimal characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Reference)

    $shape = 'a keyvault://<vault>/<secret>[/<version>] reference (a password never goes in the file)'
    # No white space or control character anywhere (a trailing line break must not slip past an end anchor), and \z, not $, below.
    if ([string]::IsNullOrWhiteSpace($Reference) -or $Reference -match '[\x00-\x20\x7f]' -or -not $Reference.StartsWith('keyvault://', [System.StringComparison]::Ordinal)) { return "is not $shape" }
    $parts = $Reference.Substring('keyvault://'.Length).Split('/')
    if ($parts.Count -lt 2 -or $parts.Count -gt 3) { return "is not $shape" }
    $vault = $parts[0]; $secret = $parts[1]
    if ($vault.Length -lt 3 -or $vault.Length -gt 24 -or $vault -notmatch '\A[A-Za-z][A-Za-z0-9-]*\z' -or $vault.EndsWith('-') -or $vault.Contains('--')) {
        return 'names a vault that Azure would not accept (3 to 24 characters, starts with a letter, letters, digits and single hyphens, no leading or trailing hyphen)'
    }
    if ($secret -notmatch '\A[A-Za-z0-9-]{1,127}\z') { return 'names a secret that Azure would not accept (1 to 127 letters, digits and hyphens)' }
    if ($parts.Count -eq 3 -and $parts[2] -notmatch '\A[0-9a-fA-F]{32}\z') { return 'has a version that is not 32 hexadecimal characters' }
    return ''
}

function Get-AzlSonarOsDomainState {
    <#
    .SYNOPSIS
        What the node has reported about the domain: { Joined, AdminsConfigured }.
    .DESCRIPTION
        Joined: DomainJoined, or a DomainJoin plan that found it already joined. AdminsConfigured: DomainAdminsConfigured (the
        domain account was added to the local Administrators). Both are kept apart from the node's events (store key
        '*domain'), so a new attempt or a new run does not forget them.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][System.Collections.IDictionary]$Store, [string]$Node)

    $none = @{ Joined = $false; AdminsConfigured = $false }
    if ($null -eq $Store -or -not $Store.Contains($script:AzlSonarDomainKey) -or $null -eq $Store[$script:AzlSonarDomainKey]) { return $none }
    $flags = $Store[$script:AzlSonarDomainKey]
    foreach ($k in $flags.Keys) {
        if ([string]$k -ieq $Node) { return @{ Joined = [bool]$flags[$k]['Joined']; AdminsConfigured = [bool]$flags[$k]['AdminsConfigured'] } }
    }
    return $none
}

function Get-AzlSonarOsDomainJoined {
    <#
    .SYNOPSIS
        Has the node reported that it is joined to the domain? (Joined of Get-AzlSonarOsDomainState.)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][System.Collections.IDictionary]$Store, [string]$Node)

    return [bool](Get-AzlSonarOsDomainState -Store $Store -Node $Node).Joined
}

function Get-AzlSonarLogAccount {
    <#
    .SYNOPSIS
        The account that reads this node's logs and why: { kind (local|domain), userName, reason, warning, rejected, waitingForAdmins }.
    .DESCRIPTION
        Pure. Local until the node has reported DomainJoined and DomainAdminsConfigured, and always local for a local identity
        design. After both the domain account of the master file is used, unless a -Pause says it must not be presented now:
        { Kind (rejected | lockedOut | open | latched | unavailable | authorization), Until (UTC), Message }. userName is the
        account's name (NETBIOS\user), never a password.
    .PARAMETER LocalUserName
        The local account in use when it is known better than the file says (the -Credential or prompted user name).
    .PARAMETER Rejected
        The same as -Pause with Kind rejected.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [string]$Node = '',

        [bool]$DomainJoined = $false,

        # The node has reported DomainAdminsConfigured: the domain account is an administrator of the node.
        [bool]$AdminsConfigured = $false,

        [bool]$Rejected = $false,

        [AllowNull()]
        [object]$Pause,

        [string]$LocalUserName = ''
    )

    $accounts = Get-AzlSonarMember $Config 'logAccounts'
    $local = $LocalUserName
    if (-not $local) { $local = [string](Get-AzlSonarMember $accounts 'local.username' '') }
    $localText = if ($local) { $local } else { 'the local account' }
    $netbios = [string](Get-AzlSonarMember $accounts 'domain.netbios' '')
    $user = [string](Get-AzlSonarMember $accounts 'domain.username' '')
    $domainName = if ($user -and $netbios -and $user -notmatch '[\\@]') { "$netbios\$user" } else { $user }
    $identity = [string](Get-AzlSonarMember $Config 'identityModel' 'LocalIdentity')
    if ($Rejected -and $null -eq $Pause) { $Pause = [pscustomobject]@{ Kind = 'rejected'; Until = $null; Message = '' } }
    $result = [ordered]@{ kind = 'local'; userName = $local; reason = ''; warning = ''; rejected = $false; waitingForAdmins = $false; domainAccount = $domainName }
    $at = { param($d) if ($null -ne $d) { ' (next check ' + ([datetime]$d).ToUniversalTime().ToString('HH:mm', [cultureinfo]::InvariantCulture) + ' UTC)' } else { '' } }
    if ($identity -ne 'ActiveDirectory') {
        $result.reason = "workgroup (the identity design is local): using $localText"
    }
    elseif (-not $DomainJoined) {
        $result.reason = "workgroup: using $localText"
    }
    elseif (-not $AdminsConfigured) {
        # Joined, but the domain account is not yet a local administrator of the node: the local account still has to read the logs.
        $result.reason = "joined, waiting for domain administrators: using $localText"
        $result.waitingForAdmins = $true
    }
    elseif (-not $domainName) {
        $result.reason = "domain-joined, but the master file names no domain account (identity.active_directory.domain_join_account): using $localText"
        $result.warning = "$Node is domain-joined but Sonar has no domain account for it; set identity.active_directory.domain_join_account in the master file. Using $localText."
    }
    elseif ($null -ne $Pause) {
        $kind = [string](Get-AzlSonarMember $Pause 'Kind' 'rejected')
        $until = Get-AzlSonarMember $Pause 'Until'
        $message = [string](Get-AzlSonarMember $Pause 'Message' '')
        switch ($kind) {
            'unavailable' {
                $result.reason = "domain-joined, but the domain account is not available$(& $at $until): using $localText"
                $result.warning = "The password of $domainName could not be read$(if ($message) { ': ' + $message }) Using $localText; Sonar asks again later."
            }
            'authorization' {
                $result.reason = "domain-joined, but $domainName is not an administrator of the node$(& $at $until): using $localText"
                $result.warning = "$domainName logged on to $Node but is not an administrator of it. Using $localText."
            }
            'lockedOut' {
                $result.rejected = $true
                $result.reason = "domain-joined, but $domainName is locked out; the domain account is paused$(& $at $until): using $localText"
                $result.warning = "$domainName is locked out in Active Directory. Sonar stopped presenting it to every node until its password changes or the unlock is confirmed. Using $localText."
            }
            'probing' {
                $result.reason = "domain-joined, but another node is checking $domainName first: using $localText"
            }
            'open' {
                $result.rejected = $true
                $result.reason = "domain-joined, but $domainName was rejected; the domain account is paused for every node$(& $at $until): using $localText"
                $result.warning = "A node rejected $domainName; Sonar stopped presenting it to every node so the account is not locked out. Using $localText."
            }
            'latched' {
                $result.rejected = $true
                $result.reason = "domain-joined, but $domainName was rejected repeatedly; the domain account stays paused until its password changes or Sonar restarts: using $localText"
                $result.warning = "$domainName was rejected repeatedly. Sonar will not present it again until its secret changes or Sonar restarts. Using $localText."
            }
            default {
                $result.rejected = $true
                $result.reason = "domain-joined, but $domainName was rejected: using $localText"
                $result.warning = "The domain account $domainName was rejected on $Node; log access fell back to $localText."
            }
        }
    }
    else {
        $result.kind = 'domain'
        $result.userName = $domainName
        $result.reason = "domain-joined: using $domainName"
    }
    return $result
}

function Get-AzlSonarBreakerSetting {
    <#
    .SYNOPSIS
        The breaker settings: { MaxRejections } from logAccounts.domain.maxRejections (1 to 5, default 2).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][object]$Config)

    $n = Get-AzlSonarMember $Config 'logAccounts.domain.maxRejections'
    $value = $script:AzlSonarDefaultMaxRejections
    if ($null -ne $n -and "$n" -ne '' -and [int]::TryParse("$n", [ref]$value) -and $value -ge 1 -and $value -le 5) { return @{ MaxRejections = $value } }
    return @{ MaxRejections = $script:AzlSonarDefaultMaxRejections }
}

function New-AzlSonarBreakerRecord {
    <#
    .SYNOPSIS
        One immutable breaker record. Records are replaced, never edited.
    .DESCRIPTION
        State closed|open|latched. Epoch counts the events that change what an earlier connection may report (a rejection, a
        reset, a reclaimed probe): a result that carries an older epoch is stale. ProbeInFlight/ProbeId/ProbeNode/ProbeStartedAt
        are the single probe slot (a lease: it is reclaimed after AzlSonarProbeLeaseSeconds). Verified: a connection with the
        current password has worked since the last reset; until then the account is given to ONE node at a time.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory record only.')]
    [CmdletBinding()]
    param(
        [string]$Account = '', [string]$State = 'closed', [int]$Failures = 0, [int]$MaxRejections = 2, [object]$OpenedAt, [object]$NextProbeAt,
        [int]$BackoffMinutes = 0, [bool]$ProbeInFlight = $false, [object]$ProbeStartedAt, [string]$ProbeNode = '', [string]$ProbeId = '',
        [long]$Epoch = 0, [bool]$Verified = $false, [string]$LastClass = '', [string]$SecretVersion = ''
    )
    [pscustomobject]@{
        Account = $Account; State = $State; Failures = $Failures; MaxRejections = $MaxRejections; OpenedAt = $OpenedAt; NextProbeAt = $NextProbeAt
        BackoffMinutes = $BackoffMinutes; ProbeInFlight = $ProbeInFlight; ProbeStartedAt = $ProbeStartedAt; ProbeNode = $ProbeNode; ProbeId = $ProbeId
        Epoch = $Epoch; Verified = $Verified; LastClass = $LastClass; SecretVersion = $SecretVersion
    }
}

function Copy-AzlSonarBreakerRecord {
    <#
    .SYNOPSIS
        A new breaker record: the base with the given properties changed. The base is not touched.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Base, [hashtable]$Change = @{})

    $copy = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties) { $copy[$p.Name] = $p.Value }
    foreach ($k in $Change.Keys) { $copy[$k] = $Change[$k] }
    return [pscustomobject]$copy
}

function Get-AzlSonarAccountBreaker {
    <#
    .SYNOPSIS
        The breaker of the domain account as an immutable record (see New-AzlSonarBreakerRecord).
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Table)

    if ($null -ne $Table -and $Table.Contains($script:AzlSonarBreakerKey) -and $null -ne $Table[$script:AzlSonarBreakerKey]) { return $Table[$script:AzlSonarBreakerKey] }
    return New-AzlSonarBreakerRecord -MaxRejections $script:AzlSonarDefaultMaxRejections
}

function Test-AzlSonarProbeLeaseExpired {
    # Has the probe slot been held for longer than its lease?
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object]$Breaker, [datetime]$Now = [datetime]::UtcNow)

    if (-not $Breaker.ProbeInFlight -or $null -eq $Breaker.ProbeStartedAt) { return $false }
    return (($Now - [datetime]$Breaker.ProbeStartedAt).TotalSeconds -ge $script:AzlSonarProbeLeaseSeconds)
}

function Get-AzlSonarUnavailablePause {
    # The credential-unavailable pause that is in force at $Now, or $null.
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Table, [datetime]$Now = [datetime]::UtcNow)

    if ($null -ne $Table -and $Table.Contains($script:AzlSonarUnavailableKey) -and $null -ne $Table[$script:AzlSonarUnavailableKey]) {
        $u = $Table[$script:AzlSonarUnavailableKey]
        if ($null -ne $u.Until -and $Now -lt $u.Until) { return [pscustomobject]@{ Kind = 'unavailable'; Until = $u.Until; Message = [string]$u.Message } }
    }
    return $null
}

function Get-AzlSonarNodePauseFor {
    <#
    .SYNOPSIS
        Why the domain account must not be presented to this node now: a -Pause record for Get-AzlSonarLogAccount, or $null.
    .DESCRIPTION
        Reads the account-wide breaker, the credential-unavailable record and the node's own record, from the table of
        Shared.LogAccount. Kinds: latched, lockedOut, open (with the time of the next check), probing (another node is
        checking the account first), unavailable, authorization. The node's published record is output only (what it was
        given); it is never read back as a reason to pause.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Table, [string]$Node, [datetime]$Now = [datetime]::UtcNow)

    if ($null -eq $Table) { return $null }
    $breaker = Get-AzlSonarAccountBreaker -Table $Table
    $locked = ($breaker.LastClass -eq 'lockedOut')
    if ($breaker.State -eq 'latched') { return [pscustomobject]@{ Kind = $(if ($locked) { 'lockedOut' } else { 'latched' }); Until = $null; Message = '' } }
    if ($breaker.State -eq 'open') {
        return [pscustomobject]@{ Kind = $(if ($locked) { 'lockedOut' } else { 'open' }); Until = $breaker.NextProbeAt; Message = '' }
    }
    $unavailable = Get-AzlSonarUnavailablePause -Table $Table -Now $Now
    if ($null -ne $unavailable) { return $unavailable }
    if ($Node -and $Table.Contains($Node) -and $null -ne $Table[$Node]) {
        $rec = $Table[$Node]
        $kind = [string](Get-AzlSonarMember $rec 'Kind' '')
        $until = Get-AzlSonarMember $rec 'Until'
        if ($kind -eq 'authorization' -and $null -ne $until -and $Now -lt [datetime]$until) { return [pscustomobject]@{ Kind = 'authorization'; Until = $until; Message = '' } }
    }
    if (-not $breaker.Verified -and $breaker.ProbeInFlight -and -not (Test-AzlSonarProbeLeaseExpired -Breaker $breaker -Now $Now)) { return [pscustomobject]@{ Kind = 'probing'; Until = $null; Message = '' } }
    return $null
}

function Get-AzlSonarFailureCode {
    # The Windows error numbers a failure carries (ErrorCode, HResult in the Win32 facility, 0x8007xxxx in the text).
    [CmdletBinding()]
    [OutputType([int[]])]
    param([object[]]$Exception, [string]$Text)

    $codes = [System.Collections.Generic.List[int]]::new()
    foreach ($ex in $Exception) {
        if ($null -eq $ex) { continue }
        foreach ($name in 'ErrorCode', 'HResult') {
            if (-not $ex.PSObject.Properties[$name] -or $null -eq $ex.$name) { continue }
            $v = 0L
            if (-not [int64]::TryParse([string]$ex.$name, [ref]$v)) { continue }
            $u = $v -band 0xFFFFFFFFL
            if (($u -band 0xFFFF0000L) -eq 0x80070000L) { $codes.Add([int]($u -band 0xFFFFL)) }
            elseif ($name -eq 'ErrorCode' -and $v -gt 0 -and $v -lt 65536) { $codes.Add([int]$v) }
        }
    }
    foreach ($m in [regex]::Matches($Text, '(?i)0x8007([0-9a-f]{4})(?![0-9a-f])')) { $codes.Add([Convert]::ToInt32($m.Groups[1].Value, 16)) }
    return [int[]]$codes.ToArray()
}

function Get-AzlSonarConnectionFailureClass {
    <#
    .SYNOPSIS
        What a failed connection means for the account: { Class, Reason }, Class one of rejected, authorization, lockedOut,
        unreachable or other.
    .DESCRIPTION
        Numeric Windows error codes first (the language of the text is not reliable), then specific phrases; a broad word
        such as "authentication", "credential" or "logon failure" alone is NOT enough.
          lockedOut      1909 (0x80070775), "account locked out", "referenced account is currently locked out"
          authorization  1385 (0x80070569) "logon type not granted": the password was right, the account may not log on this way
          rejected       1326 (0x8007052e), 1331, 1330, 1907, 0x8009030c, "user name or password is incorrect", "bad password";
                         SSH "Permission denied (publickey,password)"; and "access is denied" (5, 0x80070005, AccessDenied) while
                         the session is being OPENED: over Negotiate a wrong password fails exactly like that
          authorization  "access is denied" AFTER a session opened (-Stage use): the account got in but may not do this
          unreachable    timeouts, "credential provider", network errors, a host that does not answer
        Only rejected and lockedOut count against the account's lockout threshold.
    .PARAMETER Transport
        winrm or ssh.
    .PARAMETER Stage
        open (the connection is being made; the default) or use (a session was open and a later step failed).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('winrm', 'ssh')]
        [string]$Transport = 'winrm',

        [AllowNull()]
        [object]$Exception,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message = '',

        [ValidateSet('open', 'use')]
        [string]$Stage = 'open'
    )

    $texts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($Message)) { $texts.Add($Message) }
    $typeNames = [System.Collections.Generic.List[string]]::new()
    $chain = [System.Collections.Generic.List[object]]::new()
    $ex = $Exception
    if ($ex -is [System.Management.Automation.ErrorRecord]) {
        if (-not [string]::IsNullOrEmpty($ex.FullyQualifiedErrorId)) { $texts.Add([string]$ex.FullyQualifiedErrorId) }
        $ex = $ex.Exception
    }
    $depth = 0
    while ($null -ne $ex -and $depth -lt 6) {
        $chain.Add($ex)
        $typeNames.Add($ex.GetType().FullName)
        if (-not [string]::IsNullOrEmpty($ex.Message)) { $texts.Add($ex.Message) }
        if ($ex.PSObject.Properties['TransportMessage'] -and $ex.TransportMessage) { $texts.Add([string]$ex.TransportMessage) }
        $ex = $ex.InnerException
        $depth++
    }
    $all = ($texts -join ' | ')
    $types = ($typeNames -join ' ')
    $codes = @(Get-AzlSonarFailureCode -Exception $chain.ToArray() -Text $all)
    $result = { param($c, $r) [pscustomobject]@{ Class = $c; Reason = $r } }

    if ($codes -contains 1909 -or $all -match '(?i)account locked out|referenced account is currently locked out|account has been locked') { return & $result 'lockedOut' 'the account is locked out' }
    if ($codes -contains 1385 -or $all -match '(?i)not been granted the requested logon type') { return & $result 'authorization' 'the account may not log on to the node this way (logon type not granted)' }
    if ($Transport -eq 'ssh') {
        if ($types -match 'SshAuthenticationException' -or $all -match '(?i)permission denied \(') { return & $result 'rejected' 'the node refused the password' }
        if ($all -match '(?i)timed? ?out|connection (refused|reset|attempt failed)|no such host|network|unreachable|host key') { return & $result 'unreachable' 'the node did not answer' }
        return & $result 'other' 'an error that says nothing about the account'
    }
    if (@($codes | Where-Object { $_ -in 1326, 1331, 1330, 1907 }).Count -gt 0 -or $all -match '(?i)0x8009030c|user name or password is incorrect|bad password') { return & $result 'rejected' 'the node refused the user name or password' }
    if ($all -match '(?i)credential provider|credential (could not|cannot|failed)|no credentials? are available|logon session') { return & $result 'unreachable' 'a credential provider failed before the account was tried' }
    if ($codes -contains 5 -or $all -match '(?i)access\s*(is\s*)?denied' -or $types -match 'UnauthorizedAccessException') {
        if ($Stage -eq 'open') { return & $result 'rejected' 'the node refused the account while the session was being opened (access denied)' }
        return & $result 'authorization' 'not an administrator of the node'
    }
    if ($all -match '(?i)timed? ?out|time-out|cannot connect|cannot complete the operation|no such host|name could not be resolved|network path|unreachable|connection (refused|reset)|0x803381a2|0x80338126|turned off|firewall|is not reachable') { return & $result 'unreachable' 'the node did not answer' }
    return & $result 'other' 'an error that says nothing about the account'
}

function Get-AzlSonarWorstFailureClass {
    <#
    .SYNOPSIS
        The worst class over the transport legs of one connection attempt: { Class, Reason }.
    .DESCRIPTION
        A connection failure text reads 'WinRM: ... | SSH: ...'. Every leg is classified for its own transport (an SSH
        "Permission denied (" is a rejection however the WinRM leg failed), and the worst wins: lockedOut, rejected,
        authorization, unreachable, other.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Reason = '', [ValidateSet('open', 'use')][string]$Stage = 'open')

    $rank = @{ lockedOut = 5; rejected = 4; authorization = 3; unreachable = 2; other = 1 }
    $worst = [pscustomobject]@{ Class = 'other'; Reason = 'an error that says nothing about the account' }
    if ([string]::IsNullOrWhiteSpace($Reason)) { return $worst }
    foreach ($leg in [regex]::Split($Reason, '\s\|\s(?=(?:WinRM|SSH):)')) {
        $transport = if ($leg -match '^\s*SSH:') { 'ssh' } else { 'winrm' }
        $text = [regex]::Replace($leg, '^\s*(?:WinRM|SSH):\s*', '')
        $c = Get-AzlSonarConnectionFailureClass -Transport $transport -Message $text -Stage $Stage
        if ($rank[$c.Class] -gt $rank[$worst.Class]) { $worst = $c }
    }
    return $worst
}

function Resolve-AzlSonarDomainCredential {
    <#
    .SYNOPSIS
        The domain account as { Credential, Version }: NETBIOS\user with the password read from its Key Vault reference (read-only).
    .DESCRIPTION
        Passes the reference's version to Get-AzKeyVaultSecret when it names one. Throws a message that names the vault and
        the secret (never the value) when the reference is missing or invalid or the secret cannot be read; that error is a
        credentialUnavailable, never a rejection of the account. The password stays a SecureString.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Config)

    $accounts = Get-AzlSonarMember $Config 'logAccounts'
    $name = [string](Get-AzlSonarMember (Get-AzlSonarLogAccount -Config $Config -DomainJoined $true -AdminsConfigured $true) 'domainAccount' '')
    $reference = [string](Get-AzlSonarMember $accounts 'domain.passwordRef' '')
    if (-not $name -or -not $reference) { throw 'The master file has no domain account for Sonar (identity.active_directory.domain_join_account: username and password reference).' }
    $problem = Get-AzlSonarKeyVaultReferenceProblem -Reference $reference
    if ($problem) { throw "The domain account password reference $problem." }
    $parsed = ConvertFrom-AzlSonarKeyVaultReference -Reference $reference
    if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        throw 'Az.KeyVault is not installed, so the domain account password cannot be read. Run: Install-Module Az.KeyVault -Scope CurrentUser.'
    }
    $arguments = @{ VaultName = $parsed.Vault; Name = $parsed.Secret }
    if ($parsed.Version) { $arguments.Version = $parsed.Version }
    try { $secret = Get-AzKeyVaultSecret @arguments }
    catch { throw "Could not read the domain account password from Key Vault '$($parsed.Vault)' (secret '$($parsed.Secret)'): $($_.Exception.Message)" }
    if ($null -eq $secret -or $null -eq (Get-AzlSonarMember $secret 'SecretValue')) { throw "Key Vault '$($parsed.Vault)' returned no value for the secret '$($parsed.Secret)'." }
    return [pscustomobject]@{ Credential = [pscredential]::new($name, $secret.SecretValue); Version = [string](Get-AzlSonarMember $secret 'Version' $parsed.Version) }
}

function Add-AzlSonarRedaction {
    <#
    .SYNOPSIS
        Registers a SecureString for masking as a fingerprint: Shared.Redact is replaced by a new array (a snapshot readers can hold).
    .DESCRIPTION
        Call it inside the credential lock. No plaintext of the password is built or kept.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Shared, [Parameter(Mandatory)][securestring]$Secret)

    $fingerprint = New-AzlSonarSecretFingerprint -Secret $Secret
    if ($null -eq $fingerprint) { return }
    foreach ($existing in @($Shared['Redact'])) {
        # Already registered? The salts differ, so compare with the existing fingerprint's own salt.
        if ((Test-AzlSonarFingerprint -Value $existing) -and [int]$existing.Length -eq [int]$fingerprint.Length) {
            $again = New-AzlSonarSecretFingerprint -Secret $Secret -SaltBytes ([byte[]]$existing.Salt)
            if ($again.Sha256 -eq $existing.Sha256) { return }
        }
    }
    $Shared['Redact'] = @(@($Shared['Redact']) + $fingerprint)
}

function Register-AzlSonarAccountResult {
    <#
    .SYNOPSIS
        Records what a connection told about the domain account, in the breaker, the credential-unavailable record or the node's record.
    .DESCRIPTION
        Class: ok (a connection with the domain account worked), rejected, lockedOut, authorization, unreachable, other,
        credentialUnavailable. All under Shared.CredentialLock, as new immutable records. Only rejected and lockedOut count
        against the account: the first one opens the breaker for every node (15 minutes, then doubling to 2 hours), the
        breaker latches after MaxRejections of them, and a locked-out account latches at once (until its secret changes or
        the operator confirms the unlock).
        -Ticket is what Select-AzlSonarNodeAccount handed out with the credential: { Epoch, StartedAt, Probe, ProbeId }. A
        result whose ticket is older than the breaker's last change (an earlier epoch, or started before it opened) is stale
        and ignored, so a second failure of the same wave does not double the back-off and a late ok does not close what
        another node just opened. ok closes the breaker, and any result releases the probe slot, ONLY when it comes from the
        probe holder. Without a ticket the holder is the node named in the slot.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][ValidateSet('ok', 'rejected', 'lockedOut', 'authorization', 'unreachable', 'other', 'credentialUnavailable')][string]$Class,
        [string]$Message = '',
        [datetime]$Now = [datetime]::UtcNow,
        [AllowNull()][object]$Ticket
    )

    $table = $Shared['LogAccount']
    $lock = $Shared['CredentialLock']
    if ($null -eq $table -or $null -eq $lock) { return }
    $clean = Protect-AzlSonarText -Text $Message -Secret $Shared['Redact']
    [System.Threading.Monitor]::Enter($lock)
    try {
        $b = Get-AzlSonarAccountBreaker -Table $table
        $max = (Get-AzlSonarBreakerSetting -Config $Config).MaxRejections
        $account = [string](Get-AzlSonarLogAccount -Config $Config -DomainJoined $true -AdminsConfigured $true).domainAccount
        if (Test-AzlSonarProbeLeaseExpired -Breaker $b -Now $Now) {
            $b = Copy-AzlSonarBreakerRecord -Base $b -Change @{ ProbeInFlight = $false; ProbeId = ''; ProbeNode = ''; ProbeStartedAt = $null; Epoch = [long]$b.Epoch + 1 }
            $table[$script:AzlSonarBreakerKey] = $b
        }
        $stale = $false
        $isProbe = $false
        if ($null -ne $Ticket) {
            $stale = ([long]$Ticket.Epoch -ne [long]$b.Epoch) -or ($null -ne $b.OpenedAt -and $null -ne $Ticket.StartedAt -and [datetime]$Ticket.StartedAt -lt [datetime]$b.OpenedAt)
            $isProbe = (-not $stale) -and [bool]$Ticket.Probe -and [bool]$b.ProbeInFlight -and [string]$Ticket.ProbeId -ne '' -and [string]$Ticket.ProbeId -eq [string]$b.ProbeId
        }
        else {
            $isProbe = [bool]$b.ProbeInFlight -and [string]$b.ProbeNode -eq $Node
        }
        $release = { Copy-AzlSonarBreakerRecord -Base $b -Change @{ ProbeInFlight = $false; ProbeId = ''; ProbeNode = ''; ProbeStartedAt = $null; Account = $account; MaxRejections = $max } }
        switch ($Class) {
            'ok' {
                if ($isProbe) {
                    $table[$script:AzlSonarBreakerKey] = Copy-AzlSonarBreakerRecord -Base $b -Change @{
                        State = 'closed'; Failures = 0; OpenedAt = $null; NextProbeAt = $null; BackoffMinutes = 0; ProbeInFlight = $false; ProbeId = ''; ProbeNode = ''
                        ProbeStartedAt = $null; Verified = $true; LastClass = ''; Account = $account; MaxRejections = $max
                    }
                    $table[$script:AzlSonarUnavailableKey] = $null
                }
            }
            { $_ -in 'rejected', 'lockedOut' } {
                if (-not $stale) {
                    $failures = [int]$b.Failures + 1
                    $backoff = if ($Class -eq 'lockedOut') { $script:AzlSonarBreakerMaxMinutes } elseif ([int]$b.BackoffMinutes -le 0) { $script:AzlSonarBreakerStartMinutes } else { [Math]::Min($script:AzlSonarBreakerMaxMinutes, 2 * [int]$b.BackoffMinutes) }
                    $state = if ($Class -eq 'lockedOut' -or $failures -ge $max) { 'latched' } else { 'open' }
                    $table[$script:AzlSonarBreakerKey] = Copy-AzlSonarBreakerRecord -Base $b -Change @{
                        State = $state; Failures = $failures; OpenedAt = $Now; NextProbeAt = $Now.AddMinutes($backoff); BackoffMinutes = $backoff; ProbeInFlight = $false; ProbeId = ''
                        ProbeNode = ''; ProbeStartedAt = $null; Epoch = [long]$b.Epoch + 1; Verified = $false; LastClass = $Class; Account = $account; MaxRejections = $max
                    }
                }
            }
            'authorization' {
                $table[$Node] = [pscustomobject]@{ Node = $Node; Kind = 'authorization'; Until = $Now.AddMinutes($script:AzlSonarAuthorizationMinutes); Message = $clean }
                if ($isProbe) { $table[$script:AzlSonarBreakerKey] = & $release }
            }
            'credentialUnavailable' {
                $u = $table[$script:AzlSonarUnavailableKey]
                $attempt = if ($null -ne $u) { [int]$u.Attempt + 1 } else { 1 }
                $minutes = $script:AzlSonarUnavailableMinutes[[Math]::Min($attempt - 1, $script:AzlSonarUnavailableMinutes.Count - 1)]
                $table[$script:AzlSonarUnavailableKey] = [pscustomobject]@{ Attempt = $attempt; Until = $Now.AddMinutes($minutes); Message = $clean }
                if ($isProbe) { $table[$script:AzlSonarBreakerKey] = & $release }
            }
            default {
                # unreachable, other: nothing about the account; a probe that could not reach its node gives the slot back
                if ($isProbe) { $table[$script:AzlSonarBreakerKey] = & $release }
            }
        }
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Request-AzlSonarDomainAccess {
    <#
    .SYNOPSIS
        Step 1 of choosing the domain account for a node, as ONE critical section: may this node be given it now?
    .DESCRIPTION
        Under Shared.CredentialLock, with the breaker read inside the lock (never before it):
          local    the domain account is not presented (a pause says why)
          use      the breaker is closed and verified and the credential is cached: hand it out (a plain ticket)
          read     this node holds the single probe slot and must read Key Vault (outside the lock) and report back with
                   Complete-AzlSonarDomainRead. Probes are: the first use after a start or a reset (nobody else gets the
                   account until the probe reports ok), the probe after an open breaker's back-off, and the version check of
                   a latched breaker.
        An expired probe slot (a node that made no attempt) is reclaimed here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Node,
        [datetime]$Now = [datetime]::UtcNow
    )

    $table = $Shared['LogAccount']
    $lock = $Shared['CredentialLock']
    [System.Threading.Monitor]::Enter($lock)
    try {
        $max = (Get-AzlSonarBreakerSetting -Config $Config).MaxRejections
        $account = [string](Get-AzlSonarLogAccount -Config $Config -DomainJoined $true -AdminsConfigured $true).domainAccount
        $b = Get-AzlSonarAccountBreaker -Table $table
        if (Test-AzlSonarProbeLeaseExpired -Breaker $b -Now $Now) {
            $b = Copy-AzlSonarBreakerRecord -Base $b -Change @{ ProbeInFlight = $false; ProbeId = ''; ProbeNode = ''; ProbeStartedAt = $null; Epoch = [long]$b.Epoch + 1 }
            $table[$script:AzlSonarBreakerKey] = $b
        }
        $local = { param($pause) @{ Action = 'local'; Pause = $pause } }
        $unavailable = Get-AzlSonarUnavailablePause -Table $table -Now $Now
        if ($null -ne $unavailable) { return & $local $unavailable }
        $pause = Get-AzlSonarNodePauseFor -Table $table -Node $Node -Now $Now
        $mode = ''
        if ($b.State -eq 'latched') {
            if (-not $b.ProbeInFlight -and $null -ne $b.NextProbeAt -and $Now -ge [datetime]$b.NextProbeAt) { $mode = 'check' } else { return & $local $pause }
        }
        elseif ($b.State -eq 'open') {
            if (-not $b.ProbeInFlight -and $null -ne $b.NextProbeAt -and $Now -ge [datetime]$b.NextProbeAt) { $mode = 'probe' } else { return & $local $pause }
        }
        else {
            if ($null -ne $pause) { return & $local $pause }
            if ($b.Verified -and $Shared.Contains('DomainCredential') -and $null -ne $Shared['DomainCredential']) {
                return @{ Action = 'use'; Credential = $Shared['DomainCredential']; Ticket = [pscustomobject]@{ Epoch = [long]$b.Epoch; StartedAt = $Now; Probe = $false; ProbeId = '' } }
            }
            if ($b.ProbeInFlight) { return & $local ([pscustomobject]@{ Kind = 'probing'; Until = $null; Message = '' }) }
            $mode = 'probe'
        }
        $id = [guid]::NewGuid().ToString('N')
        $granted = Copy-AzlSonarBreakerRecord -Base $b -Change @{ ProbeInFlight = $true; ProbeStartedAt = $Now; ProbeNode = $Node; ProbeId = $id; Account = $account; MaxRejections = $max }
        $table[$script:AzlSonarBreakerKey] = $granted
        return @{ Action = 'read'; Mode = $mode; ProbeId = $id; Epoch = [long]$granted.Epoch }
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Complete-AzlSonarDomainRead {
    <#
    .SYNOPSIS
        Step 2: publish what the Key Vault read of the probe holder found, under the lock.
    .DESCRIPTION
        A failed read is a credentialUnavailable (asked again after 1, 2, 5 minutes), never a rejection, and releases the slot.
        A read whose secret VERSION differs from the one the account was last rejected with resets the breaker to closed but
        unverified, and this node keeps the slot as the ONE probe: the breaker closes only on that probe's ok. A latched
        breaker whose version did not change stays latched and is looked at again after its back-off. A holder whose lease
        was reclaimed meanwhile publishes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][hashtable]$Request,
        [AllowNull()][object]$Resolved,
        [AllowNull()][string]$Failure,
        [datetime]$Now = [datetime]::UtcNow
    )

    $table = $Shared['LogAccount']
    $lock = $Shared['CredentialLock']
    $clean = if ($Failure) { Protect-AzlSonarText -Text $Failure -Secret $Shared['Redact'] } else { '' }
    [System.Threading.Monitor]::Enter($lock)
    try {
        $b = Get-AzlSonarAccountBreaker -Table $table
        if ([string]$b.ProbeId -ne [string]$Request.ProbeId -or -not $b.ProbeInFlight) {
            return @{ Action = 'local'; Pause = (Get-AzlSonarNodePauseFor -Table $table -Node $Node -Now $Now) }
        }
        $release = @{ ProbeInFlight = $false; ProbeId = ''; ProbeNode = ''; ProbeStartedAt = $null }
        if ($Failure) {
            $u = $table[$script:AzlSonarUnavailableKey]
            $attempt = if ($null -ne $u) { [int]$u.Attempt + 1 } else { 1 }
            $minutes = $script:AzlSonarUnavailableMinutes[[Math]::Min($attempt - 1, $script:AzlSonarUnavailableMinutes.Count - 1)]
            $pause = [pscustomobject]@{ Kind = 'unavailable'; Until = $Now.AddMinutes($minutes); Message = $clean }
            $table[$script:AzlSonarUnavailableKey] = [pscustomobject]@{ Attempt = $attempt; Until = $pause.Until; Message = $clean }
            $change = $release
            if ($Request.Mode -eq 'check') { $change = $release + @{ NextProbeAt = $Now.AddMinutes(5) } }
            $table[$script:AzlSonarBreakerKey] = Copy-AzlSonarBreakerRecord -Base $b -Change $change
            return @{ Action = 'local'; Pause = $pause }
        }
        Add-AzlSonarRedaction -Shared $Shared -Secret $Resolved.Credential.Password
        $Shared['DomainCredential'] = $Resolved.Credential
        $table[$script:AzlSonarUnavailableKey] = $null
        $version = [string]$Resolved.Version
        $changed = [bool]$b.SecretVersion -and [bool]$version -and ([string]$b.SecretVersion -ne $version)
        if ($changed) {
            $new = Copy-AzlSonarBreakerRecord -Base $b -Change @{
                State = 'closed'; Failures = 0; OpenedAt = $null; NextProbeAt = $null; BackoffMinutes = 0; Verified = $false; LastClass = ''
                SecretVersion = $version; Epoch = [long]$b.Epoch + 1; ProbeStartedAt = $Now
            }
        }
        elseif ($Request.Mode -eq 'check') {
            $table[$script:AzlSonarBreakerKey] = Copy-AzlSonarBreakerRecord -Base $b -Change ($release + @{ NextProbeAt = $Now.AddMinutes([Math]::Max(5, [int]$b.BackoffMinutes)) })
            return @{ Action = 'local'; Pause = (Get-AzlSonarNodePauseFor -Table $table -Node $Node -Now $Now) }
        }
        else {
            $new = Copy-AzlSonarBreakerRecord -Base $b -Change @{ SecretVersion = $(if ($version) { $version } else { [string]$b.SecretVersion }); ProbeStartedAt = $Now }
        }
        $table[$script:AzlSonarBreakerKey] = $new
        return @{ Action = 'use'; Credential = $Shared['DomainCredential']; Ticket = [pscustomobject]@{ Epoch = [long]$new.Epoch; StartedAt = $Now; Probe = $true; ProbeId = [string]$new.ProbeId } }
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Select-AzlSonarNodeAccount {
    <#
    .SYNOPSIS
        The credential to open a log connection to one node with, and the account that choice is (published for the page).
    .DESCRIPTION
        Uses the store's DomainJoined and DomainAdminsConfigured flags. For a node that may be given the domain account:
        Request-AzlSonarDomainAccess decides under the lock (breaker closed and verified: hand out the cached credential;
        otherwise at most ONE node at a time is the probe), the probe holder reads Key Vault OUTSIDE the lock, and
        Complete-AzlSonarDomainRead publishes the result under the lock (registering the password's fingerprint for
        masking). The caller reports how its connection went with Register-AzlSonarAccountResult and the returned Ticket.
        Returns { Credential, Account, Probe, Ticket } (Probe: this connection is the single probe).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Node,
        [AllowNull()][pscredential]$Local,
        [datetime]$Now = [datetime]::UtcNow
    )

    $store = if ($Shared.Contains('OsConfigEvents')) { $Shared['OsConfigEvents'] } else { $null }
    $table = $Shared['LogAccount']
    $lock = $Shared['CredentialLock']
    $localName = if ($null -ne $Local) { $Local.UserName } else { '' }
    $domain = Get-AzlSonarOsDomainState -Store $store -Node $Node
    $base = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $domain.Joined -AdminsConfigured $domain.AdminsConfigured -LocalUserName $localName
    $credential = $Local
    $ticket = $null
    $pause = $null

    $wantsDomain = $domain.Joined -and $domain.AdminsConfigured -and [string]$base.domainAccount -ne '' -and [string](Get-AzlSonarMember $Config 'identityModel' '') -eq 'ActiveDirectory'
    if ($wantsDomain) {
        $decision = Request-AzlSonarDomainAccess -Shared $Shared -Config $Config -Node $Node -Now $Now
        if ($decision.Action -eq 'read') {
            # The slot holder reads Key Vault with no lock held; nobody else reads meanwhile.
            $resolved = $null
            $failure = $null
            try { $resolved = Resolve-AzlSonarDomainCredential -Config $Config } catch { $failure = $_.Exception.Message }
            $decision = Complete-AzlSonarDomainRead -Shared $Shared -Node $Node -Request $decision -Resolved $resolved -Failure $failure -Now $Now
        }
        if ($decision.Action -eq 'use') { $credential = $decision.Credential; $ticket = $decision.Ticket }
        else { $pause = $decision.Pause }
    }
    $account = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $domain.Joined -AdminsConfigured $domain.AdminsConfigured -Pause $pause -LocalUserName $localName

    # publish what this node is given, as one immutable record (the state builder derives it from the same inputs)
    $public = [ordered]@{}
    foreach ($k in $account.Keys) { if ($k -ne 'domainAccount') { $public[$k] = $account[$k] } }
    [System.Threading.Monitor]::Enter($lock)
    try {
        $existing = if ($table.Contains($Node)) { $table[$Node] } else { $null }
        $table[$Node] = [pscustomobject]@{
            Node = $Node; Kind = [string](Get-AzlSonarMember $existing 'Kind' ''); Until = Get-AzlSonarMember $existing 'Until'
            Message = [string](Get-AzlSonarMember $existing 'Message' ''); Account = [pscustomobject]$public
        }
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
    return @{ Credential = $credential; Account = $account; Probe = ($null -ne $ticket -and [bool]$ticket.Probe); Ticket = $ticket }
}

function Confirm-AzlSonarAccountUnlock {
    <#
    .SYNOPSIS
        The operator confirms the domain account was unlocked (or its password reset): the breaker goes back to closed, unverified.
    .DESCRIPTION
        The next node that asks is the single probe. A latched breaker (rejected repeatedly, or locked out) is otherwise
        left only by a new secret version or by restarting Sonar.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Shared)

    $table = $Shared['LogAccount']
    $lock = $Shared['CredentialLock']
    [System.Threading.Monitor]::Enter($lock)
    try {
        $b = Get-AzlSonarAccountBreaker -Table $table
        $table[$script:AzlSonarBreakerKey] = Copy-AzlSonarBreakerRecord -Base $b -Change @{
            State = 'closed'; Failures = 0; OpenedAt = $null; NextProbeAt = $null; BackoffMinutes = 0; ProbeInFlight = $false; ProbeId = ''; ProbeNode = ''
            ProbeStartedAt = $null; Verified = $false; LastClass = ''; Epoch = [long]$b.Epoch + 1
        }
        $table[$script:AzlSonarUnavailableKey] = $null
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Set-AzlSonarLogAccountRejected {
    <#
    .SYNOPSIS
        Records that a node rejected the domain account (Register-AzlSonarAccountResult with Class rejected).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Shared, [Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][string]$Node, [string]$Message = '')

    Register-AzlSonarAccountResult -Shared $Shared -Config $Config -Node $Node -Class rejected -Message $Message
}

function Get-AzlSonarLogAccountDetail {
    <#
    .SYNOPSIS
        The breaker of the domain account for Details: { account, state, failures, maxRejections, backoffMinutes, nextProbeAt, lastClass, credential, verified }. Never a secret.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][System.Collections.IDictionary]$Shared, [string]$AccountName = '', [int]$MaxRejections = 2, [datetime]$Now = [datetime]::UtcNow)

    $table = if ($null -ne $Shared -and $Shared.Contains('LogAccount')) { $Shared['LogAccount'] } else { $null }
    $b = Get-AzlSonarAccountBreaker -Table $table
    $name = $AccountName
    $u = if ($null -ne $table -and $table.Contains($script:AzlSonarUnavailableKey)) { $table[$script:AzlSonarUnavailableKey] } else { $null }
    $state = [string]$b.State
    if ($state -in 'open', 'closed' -and $b.ProbeInFlight -and -not (Test-AzlSonarProbeLeaseExpired -Breaker $b -Now $Now)) { $state = 'probing' }
    $credential = 'ready'
    if ($null -ne $u -and $null -ne $u.Until -and $Now -lt $u.Until) { $credential = 'unavailable' }
    elseif ($null -eq $Shared -or -not $Shared.Contains('DomainCredential') -or $null -eq $Shared['DomainCredential']) { $credential = 'not read yet' }
    return [ordered]@{
        account           = $(if ($b.Account) { [string]$b.Account } else { $name })
        state             = $state
        failures          = [int]$b.Failures
        maxRejections     = $MaxRejections
        backoffMinutes    = [int]$b.BackoffMinutes
        nextProbeAt       = $(if ($null -ne $b.NextProbeAt) { Format-AzlSonarDate $b.NextProbeAt } else { $null })
        lastClass         = [string]$b.LastClass
        verified          = [bool]$b.Verified
        credential        = $credential
        credentialRetryAt = $(if ($credential -eq 'unavailable') { Format-AzlSonarDate $u.Until } else { $null })
    }
}
