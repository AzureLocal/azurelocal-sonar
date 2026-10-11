Set-StrictMode -Version Latest

function Get-AzlSonarPhaseGuidance {
    <#
    .SYNOPSIS
        Returns the phase guidance (which account reads which logs, where, when and how) for an identity model.
    .DESCRIPTION
        Reads data/phase-guidance.json from the module folder (or -Path), shaped
        { version, phases: [ { phase, identityModel, account, logPaths[], available, access, source, verified } ] },
        keeps the entries for the identity model (an entry with identityModel Any, Both, * or none applies to both;
        an entry for the exact model wins over a generic one for the same phase) and returns them keyed by phase:
        { identityModel, available, version, phases: { <phase>: { account, logPaths[], when, how, verified, source } } }.
        A missing file returns available = $false and no phases rather than failing.
    .PARAMETER IdentityModel
        LocalIdentity or ActiveDirectory.
    .PARAMETER Phase
        Optional: only this phase (provisioning, validation, deployment, post-deployment).
    .PARAMETER Path
        Optional: a guidance file other than the module's data/phase-guidance.json.
    .EXAMPLE
        (Get-AzlSonarPhaseGuidance -IdentityModel LocalIdentity).phases.deployment.account
    .OUTPUTS
        Ordered dictionary: identityModel, available, version, phases.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LocalIdentity', 'ActiveDirectory')]
        [string]$IdentityModel,

        [string]$Phase,

        [string]$Path
    )

    if (-not $Path) { $Path = Join-Path -Path $script:AzlSonarModuleRoot -ChildPath 'data/phase-guidance.json' }
    $phases = [ordered]@{}
    $result = [ordered]@{
        identityModel = $IdentityModel
        available     = $false
        version       = $null
        phases        = $phases
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Verbose "Phase guidance file not found: $Path"
        return $result
    }

    $document = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw) -Depth 32
    $result.version = Get-AzlSonarMember $document 'version'
    $exact = @{}
    foreach ($entry in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $document 'phases'))) {
        $name = [string](Get-AzlSonarMember $entry 'phase' '')
        if (-not $name) { continue }
        if ($Phase -and $name -ne $Phase) { continue }
        $model = [string](Get-AzlSonarMember $entry 'identityModel' '')
        $isExact = $model -eq $IdentityModel
        $isGeneric = (-not $model) -or $model -in 'Any', 'Both', '*'
        if (-not ($isExact -or $isGeneric)) { continue }
        if ($phases.Contains($name) -and $exact[$name] -and -not $isExact) { continue }
        $phases[$name] = [ordered]@{
            account  = Get-AzlSonarMember $entry 'account'
            logPaths = [string[]](ConvertTo-AzlSonarArray (Get-AzlSonarMember $entry 'logPaths'))
            when     = Get-AzlSonarMember $entry 'available'
            how      = Get-AzlSonarMember $entry 'access'
            verified = [bool](Get-AzlSonarMember $entry 'verified' $false)
            confirmedOn = Get-AzlSonarMember $entry 'confirmedOn'
            observed = Get-AzlSonarMember $entry 'observed'
            source   = Get-AzlSonarMember $entry 'source'
        }
        $exact[$name] = $isExact
    }
    $result.available = $true
    return $result
}
