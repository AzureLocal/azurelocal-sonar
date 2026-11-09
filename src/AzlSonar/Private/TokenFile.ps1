Set-StrictMode -Version Latest

# The access-token file (Start-AzlSonar.ps1 -TokenFile, config key tokenFile): Sonar writes the per-start access token, and only
# the token, to a file only the current user can read, so automation can get it without scraping the launch output. The file
# is created with its permissions already set (no moment when it is readable by others), refused when the path holds
# something that is not a Sonar token file (unless -Force), and removed when Sonar stops.

function Test-AzlSonarTokenText {
    <#
    .SYNOPSIS
        $true when the text is an access token as Sonar makes it: 32 lower-case hexadecimal characters.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    return ([string]$Text) -cmatch '\A[0-9a-f]{32}\z'
}

function Get-AzlSonarTokenFileContent {
    <#
    .SYNOPSIS
        The trimmed text of a small file, or $null when the file is missing or larger than a token file can be.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Length -gt 256) { return $null }
    try {
        # Open with sharing so a reader that has the file open does not stop the check.
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            return $reader.ReadToEnd().Trim()
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
}

function Test-AzlSonarTokenFileOwned {
    <#
    .SYNOPSIS
        $true when an existing file is one Sonar may replace: empty, or holding just a token (a file left by an earlier start).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $content = Get-AzlSonarTokenFileContent -Path $Path
    if ($null -eq $content) { return $false }
    return ($content -eq '') -or (Test-AzlSonarTokenText -Text $content)
}

function Resolve-AzlSonarTokenFilePath {
    <#
    .SYNOPSIS
        The full path of the token file; a relative path is taken from the current folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) { throw 'The token file path is empty or has an invalid character.' }
    $expanded = $Path
    if ($expanded -eq '~' -or $expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path -Path ([Environment]::GetFolderPath('UserProfile')) -ChildPath $expanded.Substring(1).TrimStart('/', '\')
    }
    try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($expanded) }
    catch { throw "The token file path is not valid: $Path" }
}

function Assert-AzlSonarTokenFilePath {
    <#
    .SYNOPSIS
        Checks a token file path before Sonar starts and returns its full path. Writes nothing.
    .DESCRIPTION
        Refuses a folder, a missing parent folder, a link (a symbolic link or junction could send the token somewhere else) and
        an existing file that is not a Sonar token file (not empty and not just a token), unless -Force.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )

    $full = Resolve-AzlSonarTokenFilePath -Path $Path
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) { throw "The folder of the token file does not exist: $parent" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        if ($item.PSIsContainer) { throw "The token file path is a folder: $full" }
        if ($item.LinkType -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw "The token file path is a link; give the path of a file: $full" }
        if (-not $Force -and -not (Test-AzlSonarTokenFileOwned -Path $full)) {
            throw "The token file path already holds a file that is not a Sonar token file: $full. Give another path, or -Force to replace it."
        }
    }
    return $full
}

function Test-AzlSonarTokenFileSecure {
    <#
    .SYNOPSIS
        Checks that only the current user can read the file. Returns { Secure, Problem }.
    .DESCRIPTION
        Windows: the access control list is protected (no inherited entries) and holds only allow entries for the current user.
        Linux and macOS: the mode is 600 (no group or other bits).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Secure = $false; Problem = 'The file does not exist.' } }
    if ($IsWindows) {
        $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]::new($Path))
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if (-not $acl.AreAccessRulesProtected) { return [pscustomobject]@{ Secure = $false; Problem = 'The file inherits permissions from its folder.' } }
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        if ($rules.Count -eq 0) { return [pscustomobject]@{ Secure = $false; Problem = 'The file has no access entry.' } }
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or $rule.IdentityReference.Value -ne $me.Value) {
                return [pscustomobject]@{ Secure = $false; Problem = "The file has an access entry for another identity ($($rule.IdentityReference.Value))." }
            }
        }
        return [pscustomobject]@{ Secure = $true; Problem = '' }
    }
    $mode = [System.IO.File]::GetUnixFileMode($Path)
    $allowed = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
    if (([int]$mode -band (-bnot [int]$allowed)) -ne 0) { return [pscustomobject]@{ Secure = $false; Problem = "The file mode allows more than the owner ($mode)." } }
    return [pscustomobject]@{ Secure = $true; Problem = '' }
}

function New-AzlSonarTokenFile {
    <#
    .SYNOPSIS
        Writes the token, and only the token, to a new file that only the current user can read. Returns the full path.
    .DESCRIPTION
        An existing token file (or, with -Force, any file) is deleted first, so the new file never inherits permissions. The file
        is created with its permissions already set: Windows gets an access control list with one allow entry for the current
        user and no inheritance, Linux and macOS get mode 600. The result is checked and the file is deleted again when it is
        not private. Nothing here prints the token.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called by Sonar at start for a file the user asked for with -TokenFile.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Token,
        [switch]$Force
    )

    $full = Assert-AzlSonarTokenFilePath -Path $Path -Force:$Force
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force }
    $stream = $null
    try {
        if ($IsWindows) {
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $security = [System.Security.AccessControl.FileSecurity]::new()
            $security.SetAccessRuleProtection($true, $false)
            $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($me, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow))
            $stream = [System.IO.FileSystemAclExtensions]::Create([System.IO.FileInfo]::new($full), [System.IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None, $security)
        }
        else {
            $options = [System.IO.FileStreamOptions]::new()
            $options.Mode = [System.IO.FileMode]::CreateNew
            $options.Access = [System.IO.FileAccess]::Write
            $options.Share = [System.IO.FileShare]::None
            $options.UnixCreateMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
            $stream = [System.IO.FileStream]::new($full, $options)
        }
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Token)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose(); $stream = $null }
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
        throw "Cannot write the token file $full`: $($_.Exception.Message)"
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }

    $check = Test-AzlSonarTokenFileSecure -Path $full
    if (-not $check.Secure) {
        Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        throw "The token file $full is not private ($($check.Problem)) and was removed. Choose a folder where the current user can set permissions."
    }
    return $full
}

function Remove-AzlSonarTokenFile {
    <#
    .SYNOPSIS
        Removes the token file Sonar wrote, when it still holds that token. Falls back to emptying it. Never throws.
    .DESCRIPTION
        A file that now holds something else (the user replaced it, or a newer Sonar wrote its own token) is left alone.
        Returns $true when the file is gone or no longer holds the token.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Token
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    $content = Get-AzlSonarTokenFileContent -Path $Path
    if ($content -ne $Token) { return $true }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove the access token file')) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Force
        return $true
    }
    catch {
        try {
            [System.IO.File]::WriteAllText($Path, '')
            Write-Warning "Could not delete the token file $Path; it was emptied instead."
            return $true
        }
        catch {
            Write-Warning "Could not remove the token file $Path (it still holds a token that stops working when Sonar stops): $($_.Exception.Message)"
            return $false
        }
    }
}
