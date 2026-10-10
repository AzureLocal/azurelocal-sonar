Set-StrictMode -Version Latest

function Get-AzlSonarMember {
    <#
    .SYNOPSIS
        Reads a dotted property path from a PSObject or dictionary without failing under strict mode.
    .DESCRIPTION
        Returns $Default when any segment is missing or null. Arrays are returned intact (not enumerated).
    #>
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Path,

        [Parameter(Position = 2)]
        [AllowNull()]
        [object]$Default = $null
    )

    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
        }
        else {
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) { return $Default }
            $current = $property.Value
        }
    }
    if ($null -eq $current) { return $Default }
    if ($current -is [System.Collections.IEnumerable] -and $current -isnot [string] -and $current -isnot [System.Collections.IDictionary]) {
        return , $current
    }
    return $current
}

function ConvertTo-AzlSonarArray {
    <#
    .SYNOPSIS
        Turns $null into an empty array and a scalar into a one-element array; arrays stay as they are.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return , @() }
    if ($InputObject -is [string] -or $InputObject -is [System.Collections.IDictionary]) { return , @($InputObject) }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return , @($InputObject | Where-Object { $null -ne $_ })
    }
    return , @($InputObject)
}

function ConvertTo-AzlSonarUtcDate {
    <#
    .SYNOPSIS
        Converts an ARM timestamp (string, DateTime or DateTimeOffset) to a UTC DateTime, or $null.
    .DESCRIPTION
        PowerShell 7 ConvertFrom-Json turns ISO 8601 strings into DateTime, so both forms are accepted.
        Empty values and placeholder dates before the year 1900 return $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    $result = $null
    if ($Value -is [datetime]) {
        $result = if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        else {
            $Value.ToUniversalTime()
        }
    }
    elseif ($Value -is [System.DateTimeOffset]) {
        $result = $Value.UtcDateTime
    }
    else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $parsed = [System.DateTimeOffset]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
        if (-not [System.DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $null
        }
        $result = $parsed.UtcDateTime
    }
    if ($result.Year -lt 1900) { return $null }
    return $result
}

function Format-AzlSonarDate {
    <#
    .SYNOPSIS
        Formats a UTC DateTime as yyyy-MM-ddTHH:mm:ssZ; $null stays $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Date
    )

    if ($null -eq $Date) { return $null }
    $utc = ([datetime]$Date).ToUniversalTime()
    return $utc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-AzlSonarJson {
    <#
    .SYNOPSIS
        Compressed JSON with enough depth for nested step trees. Arrays stay arrays.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return 'null' }
    return (ConvertTo-Json -InputObject $InputObject -Depth 64 -Compress -WarningAction SilentlyContinue)
}

function Wait-AzlSonarInterval {
    <#
    .SYNOPSIS
        Sleeps up to $Seconds, waking every 250 ms to honour the shared stop flag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Shared,

        [Parameter(Mandatory)]
        [double]$Seconds
    )

    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    while (-not $Shared['Stop'] -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
}

function Protect-AzlSonarText {
    <#
    .SYNOPSIS
        Masks secrets in text from a node or from Azure before Sonar stores, serves or exports it.
    .DESCRIPTION
        Replaces exact secret values (for example the credential Sonar connected with) and common secret formats:
        password/pwd/secret/token/key assignments, Bearer tokens, storage AccountKey and SharedAccessSignature/sig values,
        and connection-string passwords. Read-only: returns the masked text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [string[]]$Secret = @()
    )
    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    $out = $Text
    foreach ($s in $Secret) {
        if (-not [string]::IsNullOrEmpty($s) -and $s.Length -ge 4) { $out = $out.Replace($s, '***') }
    }
    $patterns = @(
        '(?i)(\b(?:password|passwd|pwd|secret|client_?secret|access_?token|refresh_?token|api_?key|accountkey|sharedaccesskey)\b\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s;,&]+)',
        '(?i)(\bBearer\s+)[A-Za-z0-9\-\._~\+/]+=*',
        '(?i)(\b(?:sig|se|skoid|sktid)=)[^&\s"]+',
        '(?i)(-(?:Password|AsPlainText\s+-Force)\s+)("[^"]*"|''[^'']*''|\S+)'
    )
    foreach ($p in $patterns) { $out = [regex]::Replace($out, $p, '${1}***') }
    return $out
}
