Set-StrictMode -Version Latest

# Arc registration on the OEM image route, read on each node with the node's own read-only status cmdlets.
# Cmdlet names, the { Version, Response } shape and the step names were read live on 11 Oct 2026 (module
# AzureEdgeBootstrap 1.0.0): Get-ArcZeroDaySolutionUpdateStatus (Update: Scan, Download, Install) and
# Get-ArcBootstrapStatus (Bootstrap: NetworkConfig, RemoteConfig, WebProxy, TimeServer, HostName, ArcConfiguration
# with ArtifactsUpload, ConnectivityValidation, ArcRegistration, ArcExtensionInstall).
$script:AzlSonarProbe = @{
    UpdateCommand      = 'Get-ArcZeroDaySolutionUpdateStatus'
    BootstrapCommand   = 'Get-ArcBootstrapStatus'
    SessionOpenMs      = 15000
    SessionOperationMs = 60000
}

function Get-AzlSonarNodeProbeScript {
    <#
    .SYNOPSIS
        Builds the read-only script Sonar runs on a node during Arc registration (OEM image route).
    .DESCRIPTION
        Runs Get-ArcZeroDaySolutionUpdateStatus and Get-ArcBootstrapStatus with -ErrorAction SilentlyContinue (and
        -JsonResult when the command has that parameter). A command that does not exist on the node (simplified route
        nodes, other images) is reported as not available, not as an error. Object output is turned into plain data
        first (enums as names, dates as ISO 8601 UTC), because Windows PowerShell 5.1 ConvertTo-Json writes enums as
        numbers. Nothing on the node changes; no credential or secret is read or printed. Output: one string
        '<<AZLSONAR>>{ computer, polledAtUtc, update{available,json,error}, bootstrap{available,json,error} }<<END>>'.
        Runs on Windows PowerShell 5.1.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    $text = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$plain = $null
$plain = {
    param($Value, [int]$Depth)
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 12) { return [string]$Value }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [enum]) { return $Value.ToString() }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in @($Value.Keys)) { $h[[string]$k] = & $plain $Value[$k] ($Depth + 1) }
        return $h
    }
    if ($Value -is [System.Collections.IEnumerable]) { return , @(foreach ($i in $Value) { & $plain $i ($Depth + 1) }) }
    $h = [ordered]@{}
    foreach ($p in $Value.PSObject.Properties) {
        if ($p.MemberType -notmatch 'Property') { continue }
        try { $h[$p.Name] = & $plain $p.Value ($Depth + 1) } catch { $h[$p.Name] = $null }
    }
    return $h
}
$read = {
    param([string]$Name)
    $entry = [ordered]@{ available = $false; json = $null; error = $null }
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $entry }
    $entry.available = $true
    try {
        $arguments = @{ ErrorAction = 'SilentlyContinue' }
        if ($null -ne $command.Parameters -and $command.Parameters.ContainsKey('JsonResult')) { $arguments['JsonResult'] = $true }
        $output = @(& $command @arguments 2>$null)
        $objects = @($output | Where-Object { $null -ne $_ -and $_ -isnot [string] })
        if ($objects.Count -gt 0) { $entry.json = ConvertTo-Json -InputObject (& $plain $objects[-1] 0) -Depth 30 -Compress }
        elseif ($output.Count -gt 0) { $entry.json = (@($output | ForEach-Object { [string]$_ }) -join "`n") }
        else { $entry.error = 'The command returned nothing.' }
    }
    catch { $entry.error = $_.Exception.Message }
    return $entry
}
$result = [ordered]@{
    computer    = $env:COMPUTERNAME
    polledAtUtc = [datetime]::UtcNow.ToString('o')
    update      = & $read '__UPDATE__'
    bootstrap   = & $read '__BOOTSTRAP__'
}
'<<AZLSONAR>>' + (ConvertTo-Json -InputObject $result -Depth 5 -Compress) + '<<END>>'
'@
    $text = $text.Replace('__UPDATE__', $script:AzlSonarProbe.UpdateCommand).Replace('__BOOTSTRAP__', $script:AzlSonarProbe.BootstrapCommand)
    return [scriptblock]::Create($text)
}

function ConvertFrom-AzlSonarProbeOutput {
    <#
    .SYNOPSIS
        Reads the '<<AZLSONAR>>{...}<<END>>' result of the node probe script (WinRM or SSH output); throws when absent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object]$Output)

    $text = (@($Output) | ForEach-Object { [string]$_ }) -join "`n"
    $start = $text.IndexOf('<<AZLSONAR>>')
    $end = $text.LastIndexOf('<<END>>')
    if ($start -lt 0 -or $end -le $start) {
        $snippet = $text.Trim()
        throw "The node probe returned no result. $($snippet.Substring(0, [Math]::Min(300, $snippet.Length)))"
    }
    return ($text.Substring($start + 12, $end - $start - 12) | ConvertFrom-Json -Depth 8)
}

function Invoke-AzlSonarSshScript {
    <#
    .SYNOPSIS
        Runs a script block on a node over SSH (Posh-SSH session) through 'powershell -Command -' and returns stdout.
    .DESCRIPTION
        The script travels base64-encoded through stdin (nothing is written on the node, no command-line limit).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$SshSession,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutMs = $script:AzlSonarProbe.SessionOperationMs
    )

    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ScriptBlock.ToString()))
    $stdin = @(
        '$ErrorActionPreference = ''Continue''; $ProgressPreference = ''SilentlyContinue'''
        "`$sb = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))"
        '[Console]::Out.Write([string]((& $sb) -join ''''))'
        'exit'
    ) -join "`n"
    $command = $SshSession.Session.CreateCommand('powershell -NoProfile -NonInteractive -Command -')
    $command.CommandTimeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
    $async = $command.BeginExecute()
    $stdinStream = $command.CreateInputStream()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($stdin + "`n")
        $stdinStream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stdinStream.Dispose() }
    $null = $command.EndExecute($async)
    $text = [string]$command.Result
    if ($text.IndexOf('<<AZLSONAR>>') -lt 0) {
        $err = ([string]$command.Error).Trim()
        throw "SSH: no result (exit $($command.ExitStatus)). $($err.Substring(0, [Math]::Min(300, $err.Length)))"
    }
    return $text
}

function Open-AzlSonarNodeConnection {
    <#
    .SYNOPSIS
        Opens a connection to one node: WinRM first, then SSH (Posh-SSH) as the log tailer does. Never changes the
        workstation (TrustedHosts is only reported by the tailer).
    .OUTPUTS
        Hashtable { Session; Ssh; Reason } - Session or Ssh set when connected, else Reason says why not.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [AllowNull()][pscredential]$Credential,
        [ValidateSet('auto', 'winrm', 'ssh')][string]$Transport = 'auto'
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Transport -in 'auto', 'winrm') {
        try {
            $options = New-PSSessionOption -OpenTimeout $script:AzlSonarProbe.SessionOpenMs -OperationTimeout $script:AzlSonarProbe.SessionOperationMs -NoMachineProfile
            $parameters = @{ ComputerName = $Address; SessionOption = $options; Name = 'AzlSonarProbe'; ErrorAction = 'Stop' }
            if ($null -ne $Credential) { $parameters.Credential = $Credential }
            return @{ Session = (New-PSSession @parameters); Ssh = $null; Reason = $null }
        }
        catch { $reasons.Add("WinRM: $($_.Exception.Message)") }
    }
    if ($Transport -in 'auto', 'ssh') {
        if ($null -eq $Credential) { $reasons.Add('SSH: needs a credential.') }
        elseif (-not (Get-Module -ListAvailable -Name Posh-SSH)) { $reasons.Add('SSH: the Posh-SSH module is not installed on this workstation.') }
        else {
            try {
                Import-Module Posh-SSH -ErrorAction Stop
                $ssh = New-SSHSession -ComputerName $Address -Credential $Credential -AcceptKey -ConnectionTimeout ([int]($script:AzlSonarProbe.SessionOpenMs / 1000)) -ErrorAction Stop -WarningAction SilentlyContinue
                return @{ Session = $null; Ssh = $ssh; Reason = $null }
            }
            catch { $reasons.Add("SSH: $($_.Exception.Message)") }
        }
    }
    return @{ Session = $null; Ssh = $null; Reason = ($reasons -join ' | ') }
}

function Close-AzlSonarNodeConnection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Closes Sonar''s own remoting session only.')]
    [CmdletBinding()]
    param([AllowNull()][hashtable]$Connection)

    if ($null -eq $Connection) { return }
    if ($null -ne $Connection.Session) { Remove-PSSession -Session $Connection.Session -ErrorAction SilentlyContinue }
    if ($null -ne $Connection.Ssh) { $null = Remove-SSHSession -SessionId $Connection.Ssh.SessionId -ErrorAction SilentlyContinue }
}

function Update-AzlSonarNodeProbeEntry {
    <#
    .SYNOPSIS
        The node's probe record after one attempt: a result replaces the data; a failure keeps the last data and marks
        the node unreachable since the first failure (a node rebooting during the OS image update is not a failure).
    .OUTPUTS
        Hashtable { state (ok|unreachable), reason, transport, lastProbeUtc, lastSuccessUtc, unreachableSince,
        updateAvailable, updateJson, updateError, bootstrapAvailable, bootstrapJson, bootstrapError }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory record only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Previous,
        [AllowNull()][object]$Result,
        [AllowNull()][string]$Failure,
        [AllowNull()][string]$Transport,
        [datetime]$Now = [datetime]::UtcNow
    )

    $stamp = Format-AzlSonarDate $Now
    $entry = @{
        state = 'ok'; reason = $null; transport = $Transport; lastProbeUtc = $stamp; lastSuccessUtc = $null; unreachableSince = $null
        updateAvailable = $null; updateJson = $null; updateError = $null; bootstrapAvailable = $null; bootstrapJson = $null; bootstrapError = $null
    }
    if ($null -ne $Previous) {
        foreach ($key in 'lastSuccessUtc', 'unreachableSince', 'updateAvailable', 'updateJson', 'updateError', 'bootstrapAvailable', 'bootstrapJson', 'bootstrapError') {
            if ($Previous.Contains($key)) { $entry[$key] = $Previous[$key] }
        }
        if (-not $Transport -and $Previous.Contains('transport')) { $entry.transport = $Previous['transport'] }
    }
    if ($null -eq $Result) {
        $entry.state = 'unreachable'
        $entry.reason = if ($Failure) { $Failure } else { 'No answer from the node.' }
        if (-not $entry.unreachableSince) { $entry.unreachableSince = $stamp }
        return $entry
    }
    $entry.lastSuccessUtc = $stamp
    $entry.unreachableSince = $null
    foreach ($kind in 'update', 'bootstrap') {
        $part = Get-AzlSonarMember $Result $kind
        $entry["${kind}Available"] = [bool](Get-AzlSonarMember $part 'available' $false)
        $json = Get-AzlSonarMember $part 'json'
        $entry["${kind}Json"] = if ($null -ne $json -and -not [string]::IsNullOrWhiteSpace([string]$json)) { [string]$json } else { $null }
        $err = Get-AzlSonarMember $part 'error'
        $entry["${kind}Error"] = if ($err) { [string]$err } else { $null }
    }
    return $entry
}

function Get-AzlSonarNodeStatusResponse {
    <#
    .SYNOPSIS
        The Response object of a node status JSON ({ Version, Response: { Name, Status, ... } }), or the object itself
        when it already is one; $null when the text is empty or not JSON.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { $doc = ConvertFrom-Json -InputObject $Json -Depth 64 -ErrorAction Stop } catch { return $null }
    $response = Get-AzlSonarMember $doc 'Response'
    if ($null -ne $response) { return $response }
    if ($null -ne (Get-AzlSonarMember $doc 'Status')) { return $doc }
    return $null
}

function Get-AzlSonarNodeProbePlan {
    <#
    .SYNOPSIS
        Which nodes the probe reads now: only on the OEM image route, only while the active phase is arc-registration,
        and only nodes that are not finished (finished: Arc machine Connected and bootstrap Succeeded, or the bootstrap
        command is not on the node).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][System.Collections.IDictionary]$Probe
    )

    $route = [string](Get-AzlSonarMember $State 'provisioning.route' '')
    $active = [string](Get-AzlSonarMember $State 'activePhase' '')
    if ($route -ne 'oem-image' -or $active -ne 'arc-registration') { return , [string[]]@() }
    $names = foreach ($node in $Config.nodes) {
        $arc = $null
        foreach ($n in (ConvertTo-AzlSonarArray (Get-AzlSonarMember $State 'nodes'))) { if ((Get-AzlSonarMember $n 'name') -eq $node.name) { $arc = $n; break } }
        $connected = [string](Get-AzlSonarMember $arc 'arcStatus' '') -eq 'Connected'
        $entry = if ($null -ne $Probe -and $Probe.Contains($node.name)) { $Probe[$node.name] } else { $null }
        $finished = $false
        if ($connected -and $null -ne $entry -and $entry['lastSuccessUtc']) {
            if ($entry['bootstrapAvailable'] -eq $false) { $finished = $true }
            else {
                $response = Get-AzlSonarNodeStatusResponse -Json ([string]$entry['bootstrapJson'])
                $finished = (ConvertTo-AzlSonarStepStatus (Get-AzlSonarMember $response 'Status')) -eq 'success'
            }
        }
        if (-not $finished) { $node.name }
    }
    return , [string[]]@($names)
}

function Invoke-AzlSonarNodeProbe {
    <#
    .SYNOPSIS
        Runs the probe script once over an open connection and returns the parsed result.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Connection)

    $probeScript = Get-AzlSonarNodeProbeScript
    $output = if ($null -ne $Connection.Session) {
        Invoke-Command -Session $Connection.Session -ScriptBlock $probeScript -ErrorAction Stop
    }
    else {
        Invoke-AzlSonarSshScript -SshSession $Connection.Ssh -ScriptBlock $probeScript
    }
    return (ConvertFrom-AzlSonarProbeOutput -Output $output)
}

function Invoke-AzlSonarNodeProbeLoop {
    <#
    .SYNOPSIS
        Background loop: during Arc registration on the OEM image route, reads Get-ArcZeroDaySolutionUpdateStatus and
        Get-ArcBootstrapStatus on every unfinished node every pollSeconds and stores the result in Shared.NodeProbe.
    .DESCRIPTION
        Same transport and account as the log tailer (WinRM, then SSH through Posh-SSH; logs.transport). One
        connection per node, kept between polls and closed when the node is finished or the phase moves on. A node
        that does not answer (it reboots after the OS image update) keeps its last data and is marked unreachable
        since the first failed attempt. Read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][pscredential]$Credential
    )

    $transport = [string](Get-AzlSonarMember $Config.logs 'transport' 'auto')
    $connections = @{}
    try {
        while (-not $Shared.Stop) {
            $plan = Get-AzlSonarNodeProbePlan -State $Shared.State -Config $Config -Probe $Shared.NodeProbe
            foreach ($node in $Config.nodes) {
                if ($Shared.Stop) { break }
                if ($plan -notcontains $node.name) {
                    if ($connections.ContainsKey($node.name)) { Close-AzlSonarNodeConnection $connections[$node.name]; $connections.Remove($node.name) }
                    continue
                }
                $previous = if ($Shared.NodeProbe.Contains($node.name)) { $Shared.NodeProbe[$node.name] } else { $null }
                $connection = if ($connections.ContainsKey($node.name)) { $connections[$node.name] } else { $null }
                $alive = $null -ne $connection -and (($null -ne $connection.Session -and $connection.Session.State -eq 'Opened') -or ($null -ne $connection.Ssh -and $connection.Ssh.Connected))
                if (-not $alive) {
                    if ($null -ne $connection) { Close-AzlSonarNodeConnection $connection }
                    $connection = Open-AzlSonarNodeConnection -Address $node.address -Credential $Credential -Transport $transport
                    $connections[$node.name] = $connection
                }
                $kind = if ($null -ne $connection.Session) { 'winrm' } elseif ($null -ne $connection.Ssh) { 'ssh' } else { $null }
                if (-not $kind) {
                    $Shared.NodeProbe[$node.name] = Update-AzlSonarNodeProbeEntry -Previous $previous -Failure $connection.Reason
                    $connections.Remove($node.name)
                    continue
                }
                try {
                    $result = Invoke-AzlSonarNodeProbe -Connection $connection
                    $Shared.NodeProbe[$node.name] = Update-AzlSonarNodeProbeEntry -Previous $previous -Result $result -Transport $kind
                }
                catch {
                    $Shared.NodeProbe[$node.name] = Update-AzlSonarNodeProbeEntry -Previous $previous -Failure $_.Exception.Message -Transport $kind
                    Close-AzlSonarNodeConnection $connection
                    $connections.Remove($node.name)
                }
            }
            Wait-AzlSonarInterval -Shared $Shared -Seconds $Config.pollSeconds
        }
    }
    finally {
        foreach ($c in @($connections.Values)) { Close-AzlSonarNodeConnection $c }
    }
}
