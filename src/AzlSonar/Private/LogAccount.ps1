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
#  - ONE circuit breaker for the account, shared by every node. The first authentication rejection by any node opens it: no
#    node is given the domain account for a back-off (15 minutes, doubling to 2 hours). After the back-off exactly ONE
#    probe is allowed at a time; a rejected probe doubles the back-off; after maxRejections rejections (default 2) the
#    breaker latches until the secret's version changes or Sonar restarts. A locked-out account opens it at once for the
#    longest back-off. A rejected account is never retried per poll.
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

function ConvertFrom-AzlSonarKeyVaultReference {
    <#
    .SYNOPSIS
        keyvault://<vault>/<secret>[/<version>] into { Vault, Secret, Version }, or $null when it is not a valid reference.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Reference)

    if (-not [string]::IsNullOrEmpty((Get-AzlSonarKeyVaultReferenceProblem -Reference $Reference))) { return $null }
    $m = [regex]::Match($Reference, '^keyvault://(?<vault>[^/]+)/(?<secret>[^/]+)(/(?<version>[^/]+))?$')
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
    if ([string]::IsNullOrWhiteSpace($Reference) -or -not $Reference.StartsWith('keyvault://', [System.StringComparison]::Ordinal)) { return "is not $shape" }
    $parts = $Reference.Substring('keyvault://'.Length).Split('/')
    if ($parts.Count -lt 2 -or $parts.Count -gt 3) { return "is not $shape" }
    $vault = $parts[0]; $secret = $parts[1]
    if ($vault.Length -lt 3 -or $vault.Length -gt 24 -or $vault -notmatch '^[A-Za-z][A-Za-z0-9-]*$' -or $vault.EndsWith('-') -or $vault.Contains('--')) {
        return 'names a vault that Azure would not accept (3 to 24 characters, starts with a letter, letters, digits and single hyphens, no leading or trailing hyphen)'
    }
    if ($secret -notmatch '^[A-Za-z0-9-]{1,127}$') { return 'names a secret that Azure would not accept (1 to 127 letters, digits and hyphens)' }
    if ($parts.Count -eq 3 -and $parts[2] -notmatch '^[0-9a-fA-F]{32}$') { return 'has a version that is not 32 hexadecimal characters' }
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
                $result.warning = "$domainName is locked out in Active Directory. Sonar stopped presenting it to every node. Using $localText."
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
    # One immutable breaker record. Records are replaced, never edited.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory record only.')]
    [CmdletBinding()]
    param(
        [string]$Account = '', [string]$State = 'closed', [int]$Failures = 0, [int]$MaxRejections = 2, [object]$OpenedAt, [object]$NextProbeAt,
        [int]$BackoffMinutes = 0, [bool]$ProbeInFlight = $false, [string]$LastClass = '', [string]$SecretVersion = ''
    )
    [pscustomobject]@{ Account = $Account; State = $State; Failures = $Failures; MaxRejections = $MaxRejections; OpenedAt = $OpenedAt; NextProbeAt = $NextProbeAt
        BackoffMinutes = $BackoffMinutes; ProbeInFlight = $ProbeInFlight; LastClass = $LastClass; SecretVersion = $SecretVersion }
}

function Get-AzlSonarAccountBreaker {
    <#
    .SYNOPSIS
        The breaker of the domain account as an immutable record: { Account, State (closed|open|latched), Failures, MaxRejections,
        OpenedAt, NextProbeAt, BackoffMinutes, ProbeInFlight, LastClass, SecretVersion }.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Table)

    if ($null -ne $Table -and $Table.Contains($script:AzlSonarBreakerKey) -and $null -ne $Table[$script:AzlSonarBreakerKey]) { return $Table[$script:AzlSonarBreakerKey] }
    return New-AzlSonarBreakerRecord -MaxRejections $script:AzlSonarDefaultMaxRejections
}

function Get-AzlSonarNodePauseFor {
    <#
    .SYNOPSIS
        Why the domain account must not be presented to this node now: a -Pause record for Get-AzlSonarLogAccount, or $null.
    .DESCRIPTION
        Reads the account-wide breaker, the credential-unavailable record and the node's own record, from the table of Shared.LogAccount.
        The node's published record is output only (what it was given); it is never read back as a reason to pause.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Table, [string]$Node, [datetime]$Now = [datetime]::UtcNow)

    if ($null -eq $Table) { return $null }
    $breaker = Get-AzlSonarAccountBreaker -Table $Table
    if ($breaker.State -eq 'latched') { return [pscustomobject]@{ Kind = 'latched'; Until = $null; Message = '' } }
    if ($breaker.State -eq 'open') {
        $kind = if ($breaker.LastClass -eq 'lockedOut') { 'lockedOut' } else { 'open' }
        return [pscustomobject]@{ Kind = $kind; Until = $breaker.NextProbeAt; Message = '' }
    }
    if ($Table.Contains($script:AzlSonarUnavailableKey) -and $null -ne $Table[$script:AzlSonarUnavailableKey]) {
        $u = $Table[$script:AzlSonarUnavailableKey]
        if ($null -ne $u.Until -and $Now -lt $u.Until) { return [pscustomobject]@{ Kind = 'unavailable'; Until = $u.Until; Message = [string]$u.Message } }
    }
    if ($Node -and $Table.Contains($Node) -and $null -ne $Table[$Node]) {
        $rec = $Table[$Node]
        $kind = [string](Get-AzlSonarMember $rec 'Kind' '')
        $until = Get-AzlSonarMember $rec 'Until'
        if ($kind -eq 'authorization' -and $null -ne $until -and $Now -lt [datetime]$until) { return [pscustomobject]@{ Kind = 'authorization'; Until = $until; Message = '' } }
    }
    return $null
}

function Get-AzlSonarConnectionFailureClass {
    <#
    .SYNOPSIS
        What a failed connection means for the account: { Class, Reason }, Class one of rejected, authorization, lockedOut,
        unreachable or other.
    .DESCRIPTION
        Typed exceptions first (PSRemotingTransportException, UnauthorizedAccessException, SshAuthenticationException), then
        the specific error codes and phrases of the transport. A broad word such as "authentication" or "credential" is NOT
        enough: a credential provider that failed or a Kerberos name that did not resolve is not a wrong password.
          lockedOut      0x80070775, "account locked out", "referenced account is currently locked out"
          rejected       0x8009030c, 0x8007052e, "logon failure", "the user name or password is incorrect", "unknown user name or
                         bad password"; SSH "Permission denied (publickey,password)"
          authorization  0x80070005 or "access is denied" with no logon-failure phrase: the account got in but may not do this
                         (not an administrator of the node)
          unreachable    timeouts, "credential provider", network errors, a host that does not answer
        Only rejected and lockedOut count against the account's lockout threshold.
    .PARAMETER Transport
        winrm or ssh.
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
        [string]$Message = ''
    )

    $texts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($Message)) { $texts.Add($Message) }
    $typeNames = [System.Collections.Generic.List[string]]::new()
    $ex = $Exception
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    $depth = 0
    while ($null -ne $ex -and $depth -lt 6) {
        $typeNames.Add($ex.GetType().FullName)
        if (-not [string]::IsNullOrEmpty($ex.Message)) { $texts.Add($ex.Message) }
        if ($ex.PSObject.Properties['TransportMessage'] -and $ex.TransportMessage) { $texts.Add([string]$ex.TransportMessage) }
        if ($ex.PSObject.Properties['HResult'] -and $ex.HResult) { $texts.Add(('0x{0:x8}' -f [uint32]([int64]$ex.HResult -band 0xFFFFFFFFL))) }
        if ($ex.PSObject.Properties['ErrorCode'] -and $ex.ErrorCode) { $texts.Add(('0x{0:x8}' -f [uint32]([int64]$ex.ErrorCode -band 0xFFFFFFFFL))) }
        $ex = $ex.InnerException
        $depth++
    }
    $all = ($texts -join ' | ')
    $types = ($typeNames -join ' ')
    $result = { param($c, $r) [pscustomobject]@{ Class = $c; Reason = $r } }

    if ($all -match '(?i)0x80070775|account locked out|referenced account is currently locked out|account has been locked') { return & $result 'lockedOut' 'the account is locked out' }
    if ($Transport -eq 'ssh') {
        if ($types -match 'SshAuthenticationException' -or $all -match '(?i)permission denied \(') { return & $result 'rejected' 'the node refused the password' }
        if ($all -match '(?i)timed? ?out|connection (refused|reset|attempt failed)|no such host|network|unreachable|host key') { return & $result 'unreachable' 'the node did not answer' }
        return & $result 'other' 'an error that says nothing about the account'
    }
    if ($all -match '(?i)0x8009030c|0x8007052e|logon failure|the user name or password is incorrect|unknown user name or bad password') { return & $result 'rejected' 'the node refused the user name or password' }
    if ($all -match '(?i)credential provider|credential (could not|cannot|failed)|no credentials? are available|logon session') { return & $result 'unreachable' 'a credential provider failed before the account was tried' }
    if ($all -match '(?i)0x80070005|access is denied' -or $types -match 'UnauthorizedAccessException') { return & $result 'authorization' 'not an administrator of the node' }
    if ($all -match '(?i)timed? ?out|time-out|cannot connect|cannot complete the operation|no such host|name could not be resolved|network path|unreachable|connection (refused|reset)|0x803381a2|0x80338126|turned off|firewall|is not reachable') { return & $result 'unreachable' 'the node did not answer' }
    return & $result 'other' 'an error that says nothing about the account'
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
        breaker latches after MaxRejections of them, a locked-out account opens it at once for the longest back-off. A probe
        that ends in any class releases the single probe slot.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][ValidateSet('ok', 'rejected', 'lockedOut', 'authorization', 'unreachable', 'other', 'credentialUnavailable')][string]$Class,
        [string]$Message = '',
        [datetime]$Now = [datetime]::UtcNow
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
        $release = { New-AzlSonarBreakerRecord -Account $b.Account -State $b.State -Failures $b.Failures -MaxRejections $max -OpenedAt $b.OpenedAt -NextProbeAt $b.NextProbeAt -BackoffMinutes $b.BackoffMinutes -ProbeInFlight $false -LastClass $b.LastClass -SecretVersion $b.SecretVersion }
        switch ($Class) {
            'ok' {
                $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $account -MaxRejections $max -SecretVersion $b.SecretVersion
                $table[$script:AzlSonarUnavailableKey] = $null
            }
            { $_ -in 'rejected', 'lockedOut' } {
                $failures = [int]$b.Failures + 1
                $backoff = if ($Class -eq 'lockedOut') { $script:AzlSonarBreakerMaxMinutes } elseif ([int]$b.BackoffMinutes -le 0) { $script:AzlSonarBreakerStartMinutes } else { [Math]::Min($script:AzlSonarBreakerMaxMinutes, 2 * [int]$b.BackoffMinutes) }
                $state = if ($failures -ge $max -and $Class -ne 'lockedOut') { 'latched' } else { 'open' }
                $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $account -State $state -Failures $failures -MaxRejections $max -OpenedAt $Now -NextProbeAt $Now.AddMinutes($backoff) -BackoffMinutes $backoff -LastClass $Class -SecretVersion $b.SecretVersion
            }
            'authorization' {
                $table[$Node] = [pscustomobject]@{ Node = $Node; Kind = 'authorization'; Until = $Now.AddMinutes($script:AzlSonarAuthorizationMinutes); Message = $clean; Rejected = $false }
                if ($b.ProbeInFlight) { $table[$script:AzlSonarBreakerKey] = & $release }
            }
            'credentialUnavailable' {
                $u = $table[$script:AzlSonarUnavailableKey]
                $attempt = if ($null -ne $u) { [int]$u.Attempt + 1 } else { 1 }
                $minutes = $script:AzlSonarUnavailableMinutes[[Math]::Min($attempt - 1, $script:AzlSonarUnavailableMinutes.Count - 1)]
                $table[$script:AzlSonarUnavailableKey] = [pscustomobject]@{ Attempt = $attempt; Until = $Now.AddMinutes($minutes); Message = $clean }
                if ($b.ProbeInFlight) { $table[$script:AzlSonarBreakerKey] = & $release }
            }
            default {
                # unreachable, other: nothing about the account; a probe that could not reach its node gives the slot back
                if ($b.ProbeInFlight) { $table[$script:AzlSonarBreakerKey] = & $release }
            }
        }
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Select-AzlSonarNodeAccount {
    <#
    .SYNOPSIS
        The credential to open a log connection to one node with, and the account that choice is (published for the page).
    .DESCRIPTION
        Uses the store's DomainJoined and DomainAdminsConfigured flags. For a node that may be given the domain account it takes
        the credential lock and, as ONE critical section, asks the breaker (closed: go on; open: only one probe at a time and
        only after the back-off; latched: no), reads the Key Vault secret when there is no cached credential (or for the probe),
        registers the password's fingerprint for masking, and publishes the credential. When the secret's version differs
        from the one the account was rejected with, the breaker is reset. A credential that cannot be had is a
        credentialUnavailable (retried after 1, 2, 5 minutes), never a rejection.
        Returns { Credential, Account, Probe } (Probe: this connection is the single probe of an open breaker).
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
    $pause = Get-AzlSonarNodePauseFor -Table $table -Node $Node -Now $Now
    $account = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $domain.Joined -AdminsConfigured $domain.AdminsConfigured -Pause $pause -LocalUserName $localName
    $credential = $Local
    $probe = $false

    $wantsDomain = $domain.Joined -and $domain.AdminsConfigured -and [string]$account.domainAccount -ne '' -and [string](Get-AzlSonarMember $Config 'identityModel' '') -eq 'ActiveDirectory'
    if ($wantsDomain -and $null -ne $pause -and $pause.Kind -in 'open', 'lockedOut' -and $null -ne $pause.Until -and $Now -ge [datetime]$pause.Until) {
        # the back-off is over: ONE controlled probe, if nobody else holds the slot
        [System.Threading.Monitor]::Enter($lock)
        try {
            $b = Get-AzlSonarAccountBreaker -Table $table
            if ($b.State -eq 'open' -and -not $b.ProbeInFlight -and $null -ne $b.NextProbeAt -and $Now -ge $b.NextProbeAt) {
                $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $b.Account -State 'open' -Failures $b.Failures -MaxRejections $b.MaxRejections -OpenedAt $b.OpenedAt -NextProbeAt $b.NextProbeAt -BackoffMinutes $b.BackoffMinutes -ProbeInFlight $true -LastClass $b.LastClass -SecretVersion $b.SecretVersion
                $probe = $true
            }
        }
        finally { [System.Threading.Monitor]::Exit($lock) }
        if ($probe) { $account = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $true -AdminsConfigured $true -LocalUserName $localName }
    }

    if ($wantsDomain -and $null -ne $pause -and $pause.Kind -eq 'latched') {
        # A latched breaker is left only by a changed password. Once per back-off the secret's VERSION is looked at (Key Vault is
        # read; the account is not tried, so nothing counts against its lockout threshold).
        $reset = $false
        [System.Threading.Monitor]::Enter($lock)
        try {
            $b = Get-AzlSonarAccountBreaker -Table $table
            if ($b.State -eq 'latched' -and $null -ne $b.NextProbeAt -and $Now -ge $b.NextProbeAt) {
                $next = $Now.AddMinutes([Math]::Max(5, [int]$b.BackoffMinutes))
                try {
                    $resolved = Resolve-AzlSonarDomainCredential -Config $Config
                    if ($b.SecretVersion -and $resolved.Version -and $b.SecretVersion -ne $resolved.Version) {
                        $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $b.Account -MaxRejections $b.MaxRejections -SecretVersion $resolved.Version
                        Add-AzlSonarRedaction -Shared $Shared -Secret $resolved.Credential.Password
                        $Shared['DomainCredential'] = $resolved.Credential
                        $table[$script:AzlSonarUnavailableKey] = $null
                        $reset = $true
                    }
                    else { $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $b.Account -State 'latched' -Failures $b.Failures -MaxRejections $b.MaxRejections -OpenedAt $b.OpenedAt -NextProbeAt $next -BackoffMinutes $b.BackoffMinutes -LastClass $b.LastClass -SecretVersion $b.SecretVersion }
                }
                catch { $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $b.Account -State 'latched' -Failures $b.Failures -MaxRejections $b.MaxRejections -OpenedAt $b.OpenedAt -NextProbeAt $next -BackoffMinutes $b.BackoffMinutes -LastClass $b.LastClass -SecretVersion $b.SecretVersion }
            }
        }
        finally { [System.Threading.Monitor]::Exit($lock) }
        if ($reset) {
            $pause = Get-AzlSonarNodePauseFor -Table $table -Node $Node -Now $Now
            $account = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $true -AdminsConfigured $true -Pause $pause -LocalUserName $localName
        }
    }

    if ($wantsDomain -and $account.kind -eq 'domain') {
        $failure = $null
        [System.Threading.Monitor]::Enter($lock)
        try {
            $needSecret = $probe -or -not $Shared.Contains('DomainCredential') -or $null -eq $Shared['DomainCredential']
            if ($needSecret) {
                try {
                    $resolved = Resolve-AzlSonarDomainCredential -Config $Config
                    $b = Get-AzlSonarAccountBreaker -Table $table
                    if ($probe -and $b.SecretVersion -and $resolved.Version -and $b.SecretVersion -ne $resolved.Version) {
                        # the secret was changed since the account was rejected: start over, the probe is an ordinary connection
                        $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $b.Account -MaxRejections $b.MaxRejections -SecretVersion $resolved.Version
                        $probe = $false
                    }
                    else {
                        $table[$script:AzlSonarBreakerKey] = New-AzlSonarBreakerRecord -Account $account.domainAccount -State $b.State -Failures $b.Failures -MaxRejections $b.MaxRejections -OpenedAt $b.OpenedAt -NextProbeAt $b.NextProbeAt -BackoffMinutes $b.BackoffMinutes -ProbeInFlight $b.ProbeInFlight -LastClass $b.LastClass -SecretVersion $resolved.Version
                    }
                    Add-AzlSonarRedaction -Shared $Shared -Secret $resolved.Credential.Password
                    $Shared['DomainCredential'] = $resolved.Credential
                    $table[$script:AzlSonarUnavailableKey] = $null
                }
                catch { $failure = $_.Exception.Message }
            }
            if ($null -eq $failure) { $credential = $Shared['DomainCredential'] }
        }
        finally { [System.Threading.Monitor]::Exit($lock) }
        if ($null -ne $failure) {
            Register-AzlSonarAccountResult -Shared $Shared -Config $Config -Node $Node -Class credentialUnavailable -Message $failure -Now $Now
            $pause = Get-AzlSonarNodePauseFor -Table $table -Node $Node -Now $Now
            $account = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $true -AdminsConfigured $true -Pause $pause -LocalUserName $localName
            $credential = $Local
            $probe = $false
        }
    }

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
    return @{ Credential = $credential; Account = $account; Probe = $probe }
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
        The breaker of the domain account for Details: { account, state, failures, maxRejections, backoffMinutes, nextProbeAt, lastClass, credential }. Never a secret.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][System.Collections.IDictionary]$Shared, [string]$AccountName = '', [int]$MaxRejections = 2, [datetime]$Now = [datetime]::UtcNow)

    $table = if ($null -ne $Shared -and $Shared.Contains('LogAccount')) { $Shared['LogAccount'] } else { $null }
    $b = Get-AzlSonarAccountBreaker -Table $table
    $name = $AccountName
    $u = if ($null -ne $table -and $table.Contains($script:AzlSonarUnavailableKey)) { $table[$script:AzlSonarUnavailableKey] } else { $null }
    $state = [string]$b.State
    if ($state -eq 'open' -and $b.ProbeInFlight) { $state = 'probing' }
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
        credential        = $credential
        credentialRetryAt = $(if ($credential -eq 'unavailable') { Format-AzlSonarDate $u.Until } else { $null })
    }
}
