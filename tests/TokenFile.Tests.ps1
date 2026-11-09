#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Start-AzlSonar.ps1 -TokenFile and the tokenFile config key (src/AzlSonar/Private/TokenFile.ps1): the file holds only the
# token, only the current user can read it (Windows ACL / Linux mode 600), it is refused over a foreign file unless -Force,
# and it is gone when Sonar stops. No Azure, no node, localhost only.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Token = 'aaaabbbbccccddddeeeeffff00001111'
    $script:Windows = $IsWindows
}

Describe 'New-AzlSonarTokenFile: a file only the current user can read' {
    It 'writes just the token (no URL, no newline)' {
        $path = Join-Path $TestDrive 'a.token'
        $full = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        $full | Should -Be $path
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $script:Token
    }

    It 'sets the ACL to the current user only, with no inherited entries (Windows)' -Skip:(-not $IsWindows) {
        $path = Join-Path $TestDrive 'acl.token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        $acl = Get-Acl -LiteralPath $path
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AreAccessRulesProtected | Should -BeTrue
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $rules.Count | Should -Be 1
        $rules[0].IdentityReference.Value | Should -Be $me.Value
        $rules[0].AccessControlType | Should -Be 'Allow'
        @($rules | Where-Object { $_.IsInherited }) | Should -BeNullOrEmpty
        # Nobody else: no Everyone, Users, Authenticated Users, Administrators or SYSTEM entry.
        $names = @($rules.IdentityReference.Value)
        foreach ($sid in 'S-1-1-0', 'S-1-5-32-545', 'S-1-5-11', 'S-1-5-32-544', 'S-1-5-18') {
            if ($sid -ne $me.Value) { $names | Should -Not -Contain $sid }
        }
        InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) (Test-AzlSonarTokenFileSecure -Path $P).Secure } | Should -BeTrue
    }

    It 'sets mode 600 (Linux and macOS)' -Skip:($IsWindows) {
        $path = Join-Path $TestDrive 'mode.token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        [System.IO.File]::GetUnixFileMode($path) | Should -Be ([System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
    }

    It 'notices a file that is not private (Test-AzlSonarTokenFileSecure)' {
        $path = Join-Path $TestDrive 'open.token'
        Set-Content -LiteralPath $path -Value $script:Token -NoNewline
        if ($IsWindows) {
            # A new file inherits the folder's entries: not protected.
            $check = InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) Test-AzlSonarTokenFileSecure -Path $P }
            $check.Secure | Should -BeFalse
            $check.Problem | Should -Not -BeNullOrEmpty
        }
        else {
            [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead,OtherRead')
            (InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) Test-AzlSonarTokenFileSecure -Path $P }).Secure | Should -BeFalse
        }
    }

    It 'replaces a file an earlier start left (empty or just a token) and gives the new one fresh permissions' {
        $path = Join-Path $TestDrive 'stale.token'
        Set-Content -LiteralPath $path -Value '0123456789abcdef0123456789abcdef' -NoNewline
        $null = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $script:Token
        InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) (Test-AzlSonarTokenFileSecure -Path $P).Secure } | Should -BeTrue
        $emptied = Join-Path $TestDrive 'emptied.token'
        Set-Content -LiteralPath $emptied -Value '' -NoNewline
        $null = InModuleScope AzlSonar -Parameters @{ P = $emptied; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        [System.IO.File]::ReadAllText($emptied) | Should -BeExactly $script:Token
    }

    It 'refuses a file that is not a Sonar token file, and keeps it, unless -Force' {
        $path = Join-Path $TestDrive 'notes.txt'
        Set-Content -LiteralPath $path -Value 'my notes, not a token'
        { InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T } } | Should -Throw '*not a Sonar token file*-Force*'
        (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'my notes, not a token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T -Force }
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $script:Token
    }

    It 'refuses a large file even if it starts like a token' {
        $path = Join-Path $TestDrive 'big.token'
        Set-Content -LiteralPath $path -Value ($script:Token + ('x' * 1000))
        { InModuleScope AzlSonar -Parameters @{ P = $path } { param($P) Assert-AzlSonarTokenFilePath -Path $P } } | Should -Throw '*not a Sonar token file*'
    }

    It 'refuses a folder, a missing folder and a link' {
        { InModuleScope AzlSonar -Parameters @{ P = $TestDrive } { param($P) Assert-AzlSonarTokenFilePath -Path $P -Force } } | Should -Throw '*is a folder*'
        { InModuleScope AzlSonar -Parameters @{ P = (Join-Path $TestDrive 'nope/x.token') } { param($P) Assert-AzlSonarTokenFilePath -Path $P } } | Should -Throw '*folder of the token file does not exist*'
        $target = Join-Path $TestDrive 'real.txt'
        Set-Content -LiteralPath $target -Value ''
        $link = Join-Path $TestDrive 'link.token'
        $made = $false
        try { $null = New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop; $made = $true } catch { Write-Verbose 'Symbolic links need a privilege here.' }
        if ($made) {
            { InModuleScope AzlSonar -Parameters @{ P = $link } { param($P) Assert-AzlSonarTokenFilePath -Path $P -Force } } | Should -Throw '*is a link*'
        }
    }

    It 'rejects an empty path and a path with a NUL character' {
        { InModuleScope AzlSonar { Resolve-AzlSonarTokenFilePath -Path '  ' } } | Should -Throw
        { InModuleScope AzlSonar { Resolve-AzlSonarTokenFilePath -Path ("a`0b") } } | Should -Throw
    }

    It 'leaves nothing behind when the file cannot be written' {
        $path = Join-Path $TestDrive 'locked.token'
        $holder = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            # Sonar-owned (empty) but open elsewhere: the delete or the create fails; the message must not hold the token.
            $err = $null
            try { $null = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T } } catch { $err = $_ }
            if ($err) { $err.Exception.Message | Should -Not -Match $script:Token }
        }
        finally { $holder.Dispose() }
    }
}

Describe 'Remove-AzlSonarTokenFile' {
    It 'removes the file that holds the token' {
        $path = Join-Path $TestDrive 'r.token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) Remove-AzlSonarTokenFile -Path $P -Token $T } | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'leaves a file that now holds something else (a newer Sonar, or the user)' {
        $path = Join-Path $TestDrive 'other.token'
        Set-Content -LiteralPath $path -Value '99998888777766665555444433332222' -NoNewline
        InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) Remove-AzlSonarTokenFile -Path $P -Token $T } | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'is fine when the file is already gone' {
        InModuleScope AzlSonar -Parameters @{ P = (Join-Path $TestDrive 'gone.token'); T = $script:Token } { param($P, $T) Remove-AzlSonarTokenFile -Path $P -Token $T } | Should -BeTrue
    }

    It 'empties the file when it cannot be deleted' {
        $path = Join-Path $TestDrive 'stuck.token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        Mock -ModuleName AzlSonar -CommandName Remove-Item -MockWith { throw 'access denied' }
        InModuleScope AzlSonar -Parameters @{ P = $path; T = $script:Token } { param($P, $T) Remove-AzlSonarTokenFile -Path $P -Token $T -WarningAction SilentlyContinue } | Should -BeTrue
        (Get-Item -LiteralPath $path).Length | Should -Be 0
    }
}

Describe 'tokenFile in the config file' {
    BeforeAll {
        function Get-ConfigPathWith {
            param([hashtable]$Extra)
            $object = New-SonarConfigObject
            foreach ($key in $Extra.Keys) { $object | Add-Member -NotePropertyName $key -NotePropertyValue $Extra[$key] -Force }
            $path = Join-Path $TestDrive ("cfg-{0}.json" -f [guid]::NewGuid().ToString('N'))
            ConvertTo-SonarConfigJson $object | Set-Content -LiteralPath $path
            return $path
        }
    }

    It 'is read relative to the config file and kept as a full path' {
        $path = Get-ConfigPathWith @{ tokenFile = './run/sonar.token' }
        $config = Read-AzlSonarConfig -Path $path
        $config.tokenFile | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'run/sonar.token')))
    }

    It 'keeps an absolute path as it is and is empty when not set' {
        $absolute = Join-Path $TestDrive 'abs.token'
        (Read-AzlSonarConfig -Path (Get-ConfigPathWith @{ tokenFile = $absolute })).tokenFile | Should -Be $absolute
        (Read-AzlSonarConfig -Path (Get-ConfigPathWith @{})).tokenFile | Should -Be ''
    }

    It 'passes validation, and is rejected when empty, not text, or with accessToken false' {
        @(InModuleScope AzlSonar -Parameters @{ P = (Get-ConfigPathWith @{ tokenFile = './sonar.token' }) } { param($P) Test-AzlSonarConfig -Path $P }) | Should -BeNullOrEmpty
        foreach ($bad in '', '   ', 5, $true) {
            $problems = @(InModuleScope AzlSonar -Parameters @{ P = (Get-ConfigPathWith @{ tokenFile = $bad }) } { param($P) Test-AzlSonarConfig -Path $P })
            ($problems -join ' ') | Should -BeLike '*tokenFile must be the path*' -Because "tokenFile '$bad'"
        }
        $conflict = @(InModuleScope AzlSonar -Parameters @{ P = (Get-ConfigPathWith @{ tokenFile = './sonar.token'; accessToken = $false }) } { param($P) Test-AzlSonarConfig -Path $P })
        ($conflict -join ' ') | Should -BeLike '*tokenFile needs the access token*'
    }

    It 'can be set and removed with Set-AzlSonarConfig' {
        $path = Get-ConfigPathWith @{}
        Set-AzlSonarConfig -Path $path -Key tokenFile -Value './sonar.token'
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).tokenFile | Should -Be './sonar.token'
        Set-AzlSonarConfig -Path $path -Key tokenFile -Remove
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'tokenFile'
    }
}

Describe 'Start-AzlSonar.ps1 -TokenFile / -Force' {
    It 'has the parameters, documented, and passes them on' {
        $path = Join-Path $script:SonarRepoRoot 'Start-AzlSonar.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'TokenFile'
        $names | Should -Contain 'Force'
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '\.PARAMETER TokenFile'
        $text | Should -Match '\.PARAMETER Force'
        $text | Should -Match 'serverParameters\.TokenFile'
        $text | Should -Match 'serverParameters\.Force'
        (Get-Command Start-AzlSonarServer).Parameters.Keys | Should -Contain 'TokenFile'
    }
}

Describe 'Start-AzlSonarServer -TokenFile end to end (random port, mocked poller and tailer)' {
    BeforeAll {
        Add-Type -AssemblyName System.Net.Http
        $json = New-SonarConfigObject
        $script:ConfigPath = Join-Path $TestDrive 'sonar.config.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $script:ConfigPath
        $script:Seen = @{ Content = $null; Secure = $null; Existed = $false; Cookie = $null; Status = $null; Calls = 0 }

        function Initialize-ServerMock {
            Mock -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -MockWith { }
            Mock -ModuleName AzlSonar -CommandName Resolve-AzlSonarCredential -MockWith { $null }
            Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith {
                @{ Name = $Name; Handle = [pscustomobject]@{ IsCompleted = $false }; Reported = $false; PowerShell = $null; Runspace = $null }
            }
            Mock -ModuleName AzlSonar -CommandName Stop-AzlSonarWorker -MockWith { }
            Mock -ModuleName AzlSonar -CommandName Start-Process -MockWith { }
            Mock -ModuleName AzlSonar -CommandName Invoke-AzRestMethod -MockWith { throw 'No ARM call is expected.' }
        }
    }

    It 'writes the token file while running (user-only, just the token), shows the path and not the token, and removes it at stop' {
        Initialize-ServerMock
        $tokenPath = Join-Path $TestDrive 'run.token'
        $port = Get-SonarFreeTcpPort
        $script:Seen = @{ Content = $null; Secure = $null; Existed = $false; Opened = $null; Calls = 0 }
        $script:E2E = @{ Path = $tokenPath; Port = $port }
        Mock -ModuleName AzlSonar -CommandName Send-AzlSonarSseUpdate -MockWith {
            # The loop that serves requests also calls this, so the request is sent now and its answer collected on a later turn.
            $seen = $script:Seen
            $seen.Calls++
            $p = $script:E2E.Path
            if ($seen.Calls -eq 1) {
                $seen.Existed = Test-Path -LiteralPath $p
                if ($seen.Existed) {
                    $seen.Content = [System.IO.File]::ReadAllText($p)
                    $seen.Secure = (& (Get-Module AzlSonar) { param($File) Test-AzlSonarTokenFileSecure -Path $File } $p).Secure
                    $handler = [System.Net.Http.HttpClientHandler]::new()
                    $handler.AllowAutoRedirect = $false; $handler.UseProxy = $false
                    $seen.Client = [System.Net.Http.HttpClient]::new($handler)
                    $seen.Task = $seen.Client.GetAsync("http://localhost:$($script:E2E.Port)/?t=$($seen.Content)")
                    $seen.Started = [datetime]::UtcNow
                    return
                }
            }
            if ($seen.ContainsKey('Task') -and -not $seen.Task.IsCompleted -and ([datetime]::UtcNow - $seen.Started).TotalSeconds -lt 20) { return }
            if ($seen.ContainsKey('Task') -and $seen.Task.IsCompleted -and -not $seen.Task.IsFaulted) { $seen.Status = [int]$seen.Task.Result.StatusCode }
            if ($seen.ContainsKey('Client')) { $seen.Client.Dispose() }
            throw 'AZLSONAR-TEST-STOP'
        }
        $captured = & {
            try { Start-AzlSonarServer -ConfigPath $script:ConfigPath -Port $port -NoBrowser -TokenFile $tokenPath } catch { $_.Exception.Message }
        } 6>&1 3>&1 2>&1
        $text = ($captured | ForEach-Object { "$_" }) -join "`n"
        $text | Should -BeLike '*AZLSONAR-TEST-STOP*'
        $script:Seen.Existed | Should -BeTrue
        $script:Seen.Content | Should -Match '^[0-9a-f]{32}$'
        $script:Seen.Secure | Should -BeTrue
        # The token works with the real listener.
        $script:Seen.Status | Should -Be 302
        # The launch output names the file and never the token (no URL with ?t=).
        $text | Should -Match 'Access token file: '
        $text | Should -Match ([regex]::Escape($tokenPath))
        $text | Should -Not -Match $script:Seen.Content
        $text | Should -Not -Match '\?t='
        $text | Should -Match 'listening on http://localhost:'
        # Removed at stop (the stop path is the finally block).
        Test-Path -LiteralPath $tokenPath | Should -BeFalse
        Should -Invoke -ModuleName AzlSonar -CommandName Start-Process -Times 0 -Exactly
    }

    It 'takes tokenFile from the config file, and -TokenFile wins over it' {
        Initialize-ServerMock
        $viaConfig = Join-Path $TestDrive 'from-config.token'
        $viaParam = Join-Path $TestDrive 'from-param.token'
        $json = New-SonarConfigObject
        $json | Add-Member -NotePropertyName tokenFile -NotePropertyValue $viaConfig
        $configFile = Join-Path $TestDrive 'with-tokenfile.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $configFile
        $script:Seen2 = @{ Config = $false; Param = $false }
        $script:Paths = @{ Config = $viaConfig; Param = $viaParam }
        Mock -ModuleName AzlSonar -CommandName Send-AzlSonarSseUpdate -MockWith {
            $script:Seen2.Config = Test-Path -LiteralPath $script:Paths.Config
            $script:Seen2.Param = Test-Path -LiteralPath $script:Paths.Param
            throw 'AZLSONAR-TEST-STOP'
        }
        { Start-AzlSonarServer -ConfigPath $configFile -Port (Get-SonarFreeTcpPort) -NoBrowser -InformationAction SilentlyContinue } | Should -Throw '*AZLSONAR-TEST-STOP*'
        $script:Seen2.Config | Should -BeTrue
        Test-Path -LiteralPath $viaConfig | Should -BeFalse
        { Start-AzlSonarServer -ConfigPath $configFile -Port (Get-SonarFreeTcpPort) -NoBrowser -TokenFile $viaParam -InformationAction SilentlyContinue } | Should -Throw '*AZLSONAR-TEST-STOP*'
        $script:Seen2.Param | Should -BeTrue
        $script:Seen2.Config | Should -BeFalse
        Test-Path -LiteralPath $viaParam | Should -BeFalse
    }

    It 'refuses a foreign file before anything starts, and replaces it with -Force' {
        Initialize-ServerMock
        $foreign = Join-Path $TestDrive 'foreign.txt'
        Set-Content -LiteralPath $foreign -Value 'not a token'
        Mock -ModuleName AzlSonar -CommandName Send-AzlSonarSseUpdate -MockWith { throw 'AZLSONAR-TEST-STOP' }
        { Start-AzlSonarServer -ConfigPath $script:ConfigPath -Port (Get-SonarFreeTcpPort) -NoBrowser -TokenFile $foreign } | Should -Throw '*not a Sonar token file*'
        Should -Invoke -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -Times 0 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName Assert-AzlSonarAzContext -Times 0 -Exactly
        (Get-Content -LiteralPath $foreign -Raw).Trim() | Should -Be 'not a token'
        { Start-AzlSonarServer -ConfigPath $script:ConfigPath -Port (Get-SonarFreeTcpPort) -NoBrowser -TokenFile $foreign -Force -InformationAction SilentlyContinue } | Should -Throw '*AZLSONAR-TEST-STOP*'
        # Replaced, then removed at stop.
        Test-Path -LiteralPath $foreign | Should -BeFalse
    }

    It 'refuses a token file when the access token is off' {
        Initialize-ServerMock
        { Start-AzlSonarServer -ConfigPath $script:ConfigPath -Port (Get-SonarFreeTcpPort) -NoBrowser -NoAccessToken -TokenFile (Join-Path $TestDrive 'off.token') } | Should -Throw '*needs the access token*'
        Test-Path -LiteralPath (Join-Path $TestDrive 'off.token') | Should -BeFalse
    }

    It 'removes the file also when the server fails after writing it' {
        Initialize-ServerMock
        $tokenPath = Join-Path $TestDrive 'fail.token'
        Mock -ModuleName AzlSonar -CommandName Start-AzlSonarWorker -MockWith { throw 'worker failed to start' }
        { Start-AzlSonarServer -ConfigPath $script:ConfigPath -Port (Get-SonarFreeTcpPort) -NoBrowser -TokenFile $tokenPath -InformationAction SilentlyContinue } | Should -Throw '*worker failed to start*'
        Test-Path -LiteralPath $tokenPath | Should -BeFalse
    }

    It 'the helper reads the token from the file Sonar wrote (the two features together)' {
        Initialize-ServerMock
        . (Join-Path $PSScriptRoot 'FakeSonar.ps1')
        $tokenPath = Join-Path $TestDrive 'together.token'
        $null = InModuleScope AzlSonar -Parameters @{ P = $tokenPath; T = $script:Token } { param($P, $T) New-AzlSonarTokenFile -Path $P -Token $T }
        $fake = Start-FakeSonar -Token $script:Token
        try {
            Set-FakeSonarDefault $fake '/api/about' @{ Body = '{"name":"AzL Sonar"}' }
            (Invoke-AzlSonarApi /api/about -BaseUrl $fake.BaseUrl -TokenFile $tokenPath).name | Should -Be 'AzL Sonar'
            # No private-file warning: the file is user-only.
            $null = Invoke-AzlSonarApi /api/about -BaseUrl $fake.BaseUrl -TokenFile $tokenPath -WarningVariable warned -WarningAction SilentlyContinue
            "$warned" | Should -BeNullOrEmpty
        }
        finally { Stop-FakeSonar $fake; InModuleScope AzlSonar { Clear-AzlSonarApiSession } }
    }
}
