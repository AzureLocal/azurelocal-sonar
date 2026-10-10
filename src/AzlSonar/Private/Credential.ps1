Set-StrictMode -Version Latest

function Assert-AzlSonarAzContext {
    <#
    .SYNOPSIS
        Fails with a clear message when Az.Accounts is missing or nobody is signed in.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'Az PowerShell (Az.Accounts) is not installed. Run: Install-Module Az.Accounts -Scope CurrentUser; then Connect-AzAccount, and start Sonar again.'
    }
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if ($null -eq $context -or $null -eq (Get-AzlSonarMember $context 'Account')) {
        throw 'No Azure sign-in found in this PowerShell session. Run Connect-AzAccount (Az PowerShell) with an account that can read the resource group, then start Sonar again.'
    }
}

function Test-AzlSonarBuiltInAdministrator {
    <#
    .SYNOPSIS
        True when a user name is the built-in Administrator (with or without a domain or .\ prefix).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserName
    )

    if ([string]::IsNullOrWhiteSpace($UserName)) { return $false }
    $leaf = ($UserName -split '[\\/]')[-1]
    $leaf = ($leaf -split '@')[0]
    return ($leaf -eq 'Administrator')
}

function Resolve-AzlSonarCredential {
    <#
    .SYNOPSIS
        Gets the account that reads the node logs: -Credential, a prompt, or two Key Vault secrets.
    .DESCRIPTION
        An explicit -Credential always wins. credential.source prompt asks once with Get-Credential; parameter uses
        -Credential (or, when missing, the current Windows identity); keyvault reads the user name secret as text and
        the password secret as a SecureString with Az.KeyVault. The secret values are never logged or served.
        Warns (does not block) when the user name is the built-in Administrator: deployment renames it.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [AllowNull()]
        [pscredential]$Credential
    )

    $ErrorActionPreference = 'Stop'
    $result = $null
    $seed = $Config.seedNode
    if ($null -ne $Credential -and $Credential -ne [pscredential]::Empty) {
        $result = $Credential
    }
    else {
        switch ($Config.credential.source) {
            'parameter' {
                Write-Warning 'credential.source is parameter but -Credential was not given; the log tailer connects with the current Windows identity.'
            }
            'keyvault' {
                if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
                    throw 'credential.source is keyvault but Az.KeyVault is not installed. Run: Install-Module Az.KeyVault -Scope CurrentUser.'
                }
                $vault = $Config.credential.vault
                try {
                    $userName = Get-AzKeyVaultSecret -VaultName $vault -Name $Config.credential.usernameSecret -AsPlainText
                    $passwordSecret = Get-AzKeyVaultSecret -VaultName $vault -Name $Config.credential.passwordSecret
                }
                catch {
                    throw "Could not read the log account from Key Vault '$vault' (secrets '$($Config.credential.usernameSecret)', '$($Config.credential.passwordSecret)'): $($_.Exception.Message)"
                }
                if ([string]::IsNullOrWhiteSpace([string]$userName) -or $null -eq $passwordSecret) {
                    throw "Key Vault '$vault' did not return both the user name and the password secret."
                }
                $result = [pscredential]::new([string]$userName, $passwordSecret.SecretValue)
            }
            default {
                $result = Get-Credential -Message "Account that reads the deployment logs on $($seed.name) ($($seed.address))"
                if ($null -eq $result) {
                    Write-Warning 'No credential entered; the log tailer connects with the current Windows identity.'
                }
            }
        }
    }

    if ($null -ne $result -and (Test-AzlSonarBuiltInAdministrator -UserName $result.UserName)) {
        Write-Warning ("The log account is 'Administrator'. Deployment renames the built-in Administrator (ASBuiltInAdmin), " +
            'so this account may stop working mid-deployment. Use the non-built-in local admin (Local Identity) or the deployment account.')
    }
    return $result
}
