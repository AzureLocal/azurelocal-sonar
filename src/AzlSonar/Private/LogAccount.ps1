Set-StrictMode -Version Latest

# Which account reads a node's logs. Until a node has reported BOTH OS configuration events DomainJoined and
# DomainAdminsConfigured (the step that adds the domain account to the node's local Administrators; a domain account is not
# an administrator of the node before that), or when the identity design is local, the local account is used:
# identity.local_admin from the master file, or the account given with -Credential or the prompt. After both events the
# domain account is used for that node: NETBIOS\user from identity.active_directory (netbios_name, and the LCM user
# lcm_user.username, or domain_join_account.username when that optional override is present), its password read from the Key
# Vault reference of the same account (keyvault://<vault>/<secret>). When the node rejects the domain account, Sonar goes
# back to the local account and says so. The password is never logged, served or shown; the account NAME and the reason are
# (state.osConfiguration.nodes[].logAccount, Details, the Log access window).

$script:AzlSonarDomainKey = '*domain'

function ConvertFrom-AzlSonarKeyVaultReference {
    <#
    .SYNOPSIS
        keyvault://<vault>/<secret>[/<version>] into { Vault, Secret }, or $null when the text is not such a reference.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Reference)

    if ($Reference -notmatch '^keyvault://(?<vault>[A-Za-z0-9-]{3,24})/(?<secret>[A-Za-z0-9-]{1,127})(/(?<version>[A-Za-z0-9]+))?$') { return $null }
    return @{ Vault = $Matches['vault']; Secret = $Matches['secret'] }
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
        The account that reads this node's logs and why: { kind (local|domain), userName, reason, warning, rejected }.
    .DESCRIPTION
        Pure. Local until the node is domain-joined, and always local for a local identity design. After the join the domain
        account of the master file is used; with none named in the file, or after the node rejected it, the local account is
        used again with a warning. userName is the account's name (NETBIOS\user), never a password.
    .PARAMETER LocalUserName
        The local account in use when it is known better than the file says (the -Credential or prompted user name).
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
    $result = [ordered]@{ kind = 'local'; userName = $local; reason = ''; warning = ''; rejected = $false; waitingForAdmins = $false; domainAccount = $domainName }
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
        $result.reason = "domain-joined, but the master file names no domain account (identity.active_directory.lcm_user or domain_join_account): using $localText"
        $result.warning = "$Node is domain-joined but Sonar has no domain account for it; set identity.active_directory.lcm_user (or domain_join_account) in the master file. Using $localText."
    }
    elseif ($Rejected) {
        $result.rejected = $true
        $result.reason = "domain-joined, but $domainName was rejected: using $localText"
        $result.warning = "The domain account $domainName was rejected on $Node; log access fell back to $localText."
    }
    else {
        $result.kind = 'domain'
        $result.userName = $domainName
        $result.reason = "domain-joined: using $domainName"
    }
    return $result
}

function Resolve-AzlSonarDomainCredential {
    <#
    .SYNOPSIS
        The domain account as a credential: NETBIOS\user with the password read from its Key Vault reference (read-only).
    .DESCRIPTION
        Throws a message that names the vault and the secret (never the value) when the reference is missing, is not a
        keyvault:// reference, or cannot be read. The password is held as a SecureString.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param([Parameter(Mandatory)][object]$Config)

    $accounts = Get-AzlSonarMember $Config 'logAccounts'
    $name = [string](Get-AzlSonarMember (Get-AzlSonarLogAccount -Config $Config -DomainJoined $true -AdminsConfigured $true) 'domainAccount' '')
    $reference = [string](Get-AzlSonarMember $accounts 'domain.passwordRef' '')
    if (-not $name -or -not $reference) { throw 'The master file has no domain account for Sonar (identity.active_directory.lcm_user, or domain_join_account: username and password reference).' }
    $parsed = ConvertFrom-AzlSonarKeyVaultReference -Reference $reference
    if ($null -eq $parsed) { throw 'The domain account password in the master file must be a keyvault://<vault>/<secret> reference; Sonar never reads a password from the file.' }
    if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        throw 'Az.KeyVault is not installed, so the domain account password cannot be read. Run: Install-Module Az.KeyVault -Scope CurrentUser.'
    }
    try { $secret = Get-AzKeyVaultSecret -VaultName $parsed.Vault -Name $parsed.Secret }
    catch { throw "Could not read the domain account password from Key Vault '$($parsed.Vault)' (secret '$($parsed.Secret)'): $($_.Exception.Message)" }
    if ($null -eq $secret -or $null -eq (Get-AzlSonarMember $secret 'SecretValue')) { throw "Key Vault '$($parsed.Vault)' returned no value for the secret '$($parsed.Secret)'." }
    return [pscredential]::new($name, $secret.SecretValue)
}

function Test-AzlSonarAuthenticationFailure {
    <#
    .SYNOPSIS
        Does a connection error say the account was refused (not that the node is unreachable)?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return [bool]($Message -match '(?i)access is denied|logon failure|authentication|credential|unauthori[sz]ed|user name or password|0x8007052e|0x80070005|0x80090311|kerberos|NTLM|rejected')
}

function Select-AzlSonarNodeAccount {
    <#
    .SYNOPSIS
        The credential to open a log connection to one node with, and the account that choice is (published for the page).
    .DESCRIPTION
        Uses the store's DomainJoined flag and Shared.LogAccount (the nodes that rejected the domain account). Resolves the
        domain credential once and keeps it in Shared.DomainCredential (never serialised); its password is added to
        Shared.Redact so no text can carry it. A domain credential that cannot be built (Key Vault unreadable) is reported
        like a rejection: the local account is used and the reason says why.
        Returns { Credential, Account }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Node,
        [AllowNull()][pscredential]$Local
    )

    $store = if ($Shared.Contains('OsConfigEvents')) { $Shared['OsConfigEvents'] } else { $null }
    $info = if ($Shared.Contains('LogAccount')) { $Shared['LogAccount'] } else { $null }
    $rejected = $false
    if ($null -ne $info -and $info.Contains($Node) -and $null -ne $info[$Node]) { $rejected = [bool]$info[$Node]['Rejected'] }
    $localName = if ($null -ne $Local) { $Local.UserName } else { '' }
    $domain = Get-AzlSonarOsDomainState -Store $store -Node $Node
    $account = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $domain.Joined -AdminsConfigured $domain.AdminsConfigured -Rejected $rejected -LocalUserName $localName
    $credential = $Local
    if ($account.kind -eq 'domain') {
        try {
            if (-not $Shared.Contains('DomainCredential') -or $null -eq $Shared['DomainCredential']) {
                $cred = Resolve-AzlSonarDomainCredential -Config $Config
                $Shared['DomainCredential'] = $cred
                $Shared.Redact = @($Shared.Redact) + $cred.GetNetworkCredential().Password
            }
            $credential = $Shared['DomainCredential']
        }
        catch {
            $message = Protect-AzlSonarText -Text $_.Exception.Message -Secret $Shared.Redact
            Set-AzlSonarLogAccountRejected -Shared $Shared -Node $Node -Message $message
            $account = Get-AzlSonarLogAccount -Config $Config -Node $Node -DomainJoined $true -AdminsConfigured $true -Rejected $true -LocalUserName $localName
            $account.warning = "The domain account for $Node could not be used: $message Using $(if ($localName) { $localName } else { 'the local account' })."
            $account.reason = "domain-joined, but the domain account could not be used: using $(if ($localName) { $localName } else { 'the local account' })"
        }
    }
    $copy = [ordered]@{}
    foreach ($k in $account.Keys) { if ($k -ne 'domainAccount') { $copy[$k] = $account[$k] } }
    if ($null -ne $info) {
        $message = if ($info.Contains($Node) -and $null -ne $info[$Node] -and $info[$Node].ContainsKey('Message')) { [string]$info[$Node]['Message'] } else { '' }
        $info[$Node] = @{ Rejected = [bool]($account.rejected -or $rejected); Message = $message; Account = $copy }
    }
    return @{ Credential = $credential; Account = $account }
}

function Set-AzlSonarLogAccountRejected {
    <#
    .SYNOPSIS
        Remembers that a node refused the domain account, so the local account is used for it from now on (until Sonar restarts).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory table only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Shared, [Parameter(Mandatory)][string]$Node, [string]$Message = '')

    if (-not $Shared.Contains('LogAccount') -or $null -eq $Shared['LogAccount']) { return }
    $Shared['LogAccount'][$Node] = @{ Rejected = $true; Message = $Message; Account = $null }
}
