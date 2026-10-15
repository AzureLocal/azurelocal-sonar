#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A dummy test credential; no real secret.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Passes a PSCredential into InModuleScope; no plain text.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '', Justification = 'Passes a PSCredential into InModuleScope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Local test helper names.')]
param()
Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule

    $script:Utf8 = [System.Text.UTF8Encoding]::new($false)
    function Get-Bytes([string]$Text, [System.Text.Encoding]$Encoding = $script:Utf8) { , $Encoding.GetBytes($Text) }
    function Write-LogText([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
    function Add-LogText([string]$Path, [string]$Text) { [System.IO.File]::AppendAllText($Path, $Text, $script:Utf8) }
}

Describe 'Get-AzlSonarLineLevel' {
    # error = \b(error|exception|failed|fatal)\b, warning = \bwarn(ing)?\b, case-insensitive, error wins over warning.
    # Plural and compound words do not match (no word boundary), so 'errors=0' is info. Zero-count summaries
    # ('error=0', 'Failed: 0', '0 failed', 'warning count=0', 'errors: 0') are removed before matching, so they are info;
    # a real problem word elsewhere in the same line still counts.
    It '<Text> -> <Expected>' -TestCases @(
        @{ Text = 'ERROR: cannot reach node02'; Expected = 'error' }
        @{ Text = 'error: lower case'; Expected = 'error' }
        @{ Text = 'Unhandled Exception at step 3'; Expected = 'error' }
        @{ Text = 'Step Validate Network FAILED'; Expected = 'error' }
        @{ Text = 'Status: Failed'; Expected = 'error' }
        @{ Text = 'fatal: disk missing'; Expected = 'error' }
        @{ Text = 'error-code 5'; Expected = 'error' }
        @{ Text = 'WARNING: clock skew'; Expected = 'warning' }
        @{ Text = 'Warn: low disk'; Expected = 'warning' }
        @{ Text = '[warn] retrying'; Expected = 'warning' }
        @{ Text = 'warning: then the step failed'; Expected = 'error' }
        @{ Text = 'Validation passed'; Expected = 'info' }
        @{ Text = 'errors=0'; Expected = 'info' }
        @{ Text = 'Completed with 0 errors and 0 warnings'; Expected = 'info' }
        @{ Text = 'ErrorCount=0'; Expected = 'info' }
        @{ Text = 'error_code=0'; Expected = 'info' }
        @{ Text = 'NoError'; Expected = 'info' }
        @{ Text = 'No exceptions thrown'; Expected = 'info' }
        @{ Text = 'Fatality'; Expected = 'info' }
        @{ Text = 'Warnings: 0'; Expected = 'info' }
        @{ Text = 'error=0'; Expected = 'info' }
        @{ Text = 'Failed: 0'; Expected = 'info' }
        @{ Text = 'Tests: 12 passed, 0 failed'; Expected = 'info' }
        @{ Text = '0 failed'; Expected = 'info' }
        @{ Text = 'warning count=0'; Expected = 'info' }
        @{ Text = 'errors: 0'; Expected = 'info' }
        @{ Text = 'Error count: 0, Warnings = 0'; Expected = 'info' }
        @{ Text = 'Summary: 0 errors, 0 warnings, 0 exceptions'; Expected = 'info' }
        @{ Text = 'FAILED : 00'; Expected = 'info' }
        @{ Text = 'error=0x80070005'; Expected = 'error' }
        @{ Text = 'Failed: 3'; Expected = 'error' }
        @{ Text = 'Tests: 2 passed, 10 failed'; Expected = 'error' }
        @{ Text = 'error=0 but step Deploy FAILED'; Expected = 'error' }
        @{ Text = '0 errors, 1 warning'; Expected = 'warning' }
        @{ Text = 'Failed: 0.5 GB free'; Expected = 'error' }
        @{ Text = ''; Expected = 'info' }
    ) {
        param($Text, $Expected)
        InModuleScope AzlSonar -Parameters @{ Text = $Text } { param($Text) Get-AzlSonarLineLevel $Text } | Should -Be $Expected
    }

    It 'treats $null as info' {
        InModuleScope AzlSonar { Get-AzlSonarLineLevel $null } | Should -Be 'info'
    }
}

Describe 'Resolve-AzlSonarTailOffset' {
    It 'starts a new file at 0' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous $null -Size 500 -CreatedTicks 1 -StartAtEnd $false -InitialTailBytes 100 }
        $plan.Offset | Should -Be 0
        $plan.Reason | Should -Be 'new'
        $plan.SkipPartialLine | Should -BeFalse
        $plan.Reset | Should -BeFalse
    }

    It 'starts an existing file InitialTailBytes from its end on the first run and skips the partial line' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous $null -Size 100000 -CreatedTicks 1 -StartAtEnd $true -InitialTailBytes 16384 }
        $plan.Offset | Should -Be (100000 - 16384)
        $plan.SkipPartialLine | Should -BeTrue
        $plan.Reason | Should -Be 'initial-tail'
    }

    It 'reads a small existing file from 0 on the first run' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous $null -Size 1000 -CreatedTicks 1 -StartAtEnd $true -InitialTailBytes 16384 }
        $plan.Offset | Should -Be 0
        $plan.SkipPartialLine | Should -BeFalse
    }

    It 'continues from the stored offset when the file grew' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous @{ offset = 100; created = 5; skip = $false } -Size 250 -CreatedTicks 5 -StartAtEnd $true -InitialTailBytes 16384 }
        $plan.Offset | Should -Be 100
        $plan.Reason | Should -Be 'continue'
        $plan.Reset | Should -BeFalse
    }

    It 'continues (nothing to read) when the size equals the offset' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous @{ offset = 100; created = 5 } -Size 100 -CreatedTicks 5 -StartAtEnd $false -InitialTailBytes 0 }
        $plan.Offset | Should -Be 100
        $plan.Reason | Should -Be 'continue'
    }

    It 'keeps a pending skip flag' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous @{ offset = 10; created = 5; skip = $true } -Size 20 -CreatedTicks 5 -StartAtEnd $false -InitialTailBytes 0 }
        $plan.SkipPartialLine | Should -BeTrue
    }

    It 'resets to 0 when the file was truncated' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous @{ offset = 100; created = 5 } -Size 40 -CreatedTicks 5 -StartAtEnd $false -InitialTailBytes 0 }
        $plan.Offset | Should -Be 0
        $plan.Reset | Should -BeTrue
        $plan.Reason | Should -Be 'truncated'
    }

    It 'resets to 0 when the file was re-created, even if it is larger' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous @{ offset = 100; created = 5 } -Size 400 -CreatedTicks 6 -StartAtEnd $false -InitialTailBytes 0 }
        $plan.Offset | Should -Be 0
        $plan.Reset | Should -BeTrue
        $plan.Reason | Should -Be 'recreated'
    }

    It 'does not treat a missing creation time as re-created' {
        $plan = InModuleScope AzlSonar { Resolve-AzlSonarTailOffset -Previous @{ offset = 100; created = 0 } -Size 400 -CreatedTicks 6 -StartAtEnd $false -InitialTailBytes 0 }
        $plan.Reason | Should -Be 'continue'
    }
}

Describe 'Split-AzlSonarLogChunk' {
    It 'returns complete lines and carries the partial last line over' {
        $bytes = Get-Bytes "first`r`nsecond`n`nthird-partial"
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B }
        $split.Lines | Should -Be @('first', 'second')
        $split.ConsumedBytes | Should -Be 15 -Because 'first CRLF (7) + second LF (7) + the blank line (1)'
    }

    It 'consumes blank lines but does not output them' {
        $bytes = Get-Bytes "a`n`n`nb`n"
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B }
        $split.Lines | Should -Be @('a', 'b')
        $split.ConsumedBytes | Should -Be $bytes.Length
    }

    It 'joins the carried-over partial line on the next read' {
        $first = Get-Bytes "one`ntw"
        $a = InModuleScope AzlSonar -Parameters @{ B = $first } { param($B) Split-AzlSonarLogChunk -Bytes $B }
        $a.Lines | Should -Be @('one')
        $a.ConsumedBytes | Should -Be 4
        $rest = Get-Bytes ("tw" + "o`nthree`n")
        $b = InModuleScope AzlSonar -Parameters @{ B = $rest } { param($B) Split-AzlSonarLogChunk -Bytes $B }
        $b.Lines | Should -Be @('two', 'three')
    }

    It 'honours -Count' {
        $bytes = Get-Bytes "abc`ndef`n"
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B -Count 4 }
        $split.Lines | Should -Be @('abc')
        $split.ConsumedBytes | Should -Be 4
    }

    It 'skips the first partial line when asked' {
        $bytes = Get-Bytes "tail-of-old-line`nnew line`n"
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B -SkipPartialLine $true }
        $split.Lines | Should -Be @('new line')
        $split.SkippedPartial | Should -BeTrue
        $split.ConsumedBytes | Should -Be $bytes.Length
    }

    It 'waits (consumes nothing) when skipping and no newline arrived yet' {
        $bytes = Get-Bytes 'still the same line'
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B -SkipPartialLine $true }
        @($split.Lines).Count | Should -Be 0
        $split.ConsumedBytes | Should -Be 0
        $split.SkippedPartial | Should -BeFalse
    }

    It 'consumes a full chunk without any newline as one line' {
        $bytes = Get-Bytes ('x' * 64)
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B -ChunkIsFull $true }
        @($split.Lines).Count | Should -Be 1
        $split.Lines[0].Length | Should -Be 64
        $split.ConsumedBytes | Should -Be 64
    }

    It 'stops at MaxLines and leaves the rest for the next poll' {
        $bytes = Get-Bytes "1`n2`n3`n"
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B -MaxLines 2 }
        $split.Lines | Should -Be @('1', '2')
        $split.ConsumedBytes | Should -Be 4
    }

    It 'splits UTF-16LE text on whole characters' {
        $bytes = Get-Bytes "one`r`ntwo`r`nthr" ([System.Text.Encoding]::Unicode)
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B -Encoding unicode }
        $split.Lines | Should -Be @('one', 'two')
        $split.ConsumedBytes | Should -Be 20
    }

    It 'splits UTF-16BE text' {
        $bytes = Get-Bytes "alpha`nbeta`n" ([System.Text.Encoding]::BigEndianUnicode)
        $split = InModuleScope AzlSonar -Parameters @{ B = $bytes } { param($B) Split-AzlSonarLogChunk -Bytes $B -Encoding bigendianunicode }
        $split.Lines | Should -Be @('alpha', 'beta')
        $split.ConsumedBytes | Should -Be $bytes.Length
    }

    It 'handles an empty chunk' {
        $split = InModuleScope AzlSonar { Split-AzlSonarLogChunk -Bytes ([byte[]]@()) }
        @($split.Lines).Count | Should -Be 0
        $split.ConsumedBytes | Should -Be 0
    }
}

Describe 'Get-AzlSonarBomEncoding' {
    It 'detects <Name> (BOM <Bom>)' -TestCases @(
        @{ Bytes = [byte[]](0xEF, 0xBB, 0xBF, 0x41); Name = 'utf8'; Bom = 3 }
        @{ Bytes = [byte[]](0xFF, 0xFE, 0x41, 0x00); Name = 'unicode'; Bom = 2 }
        @{ Bytes = [byte[]](0xFE, 0xFF, 0x00, 0x41); Name = 'bigendianunicode'; Bom = 2 }
        @{ Bytes = [byte[]](0x41, 0x00, 0x42, 0x00); Name = 'unicode'; Bom = 0 }
        @{ Bytes = [byte[]](0x41, 0x42, 0x43, 0x44); Name = 'utf8'; Bom = 0 }
        @{ Bytes = [byte[]]@(); Name = 'utf8'; Bom = 0 }
    ) {
        param($Bytes, $Name, $Bom)
        $result = InModuleScope AzlSonar -Parameters @{ B = $Bytes } { param($B) Get-AzlSonarBomEncoding -Bytes $B }
        $result.Name | Should -Be $Name
        $result.BomLength | Should -Be $Bom
    }
}

Describe 'Test-AzlSonarNameMatch' {
    It '<Name> -> <Expected>' -TestCases @(
        @{ Name = 'Deploy.log'; Expected = $true }
        @{ Name = 'report.XML'; Expected = $true }
        @{ Name = 'trace.etl'; Expected = $false }
        @{ Name = 'image.bin'; Expected = $false }
    ) {
        param($Name, $Expected)
        InModuleScope AzlSonar -Parameters @{ N = $Name } { param($N) Test-AzlSonarNameMatch -Name $N -Include @('*.log', '*.txt', '*.xml') -Exclude @('*.etl') } | Should -Be $Expected
    }

    It 'lets exclude win over include' {
        InModuleScope AzlSonar { Test-AzlSonarNameMatch -Name 'a.log' -Include @('*') -Exclude @('*.log') } | Should -BeFalse
    }

    It 'matches everything when include is empty' {
        InModuleScope AzlSonar { Test-AzlSonarNameMatch -Name 'anything.bin' -Include @() -Exclude @() } | Should -BeTrue
    }
}

Describe 'Remote tail script (run locally against a temp folder)' {
    BeforeAll {
        $script:TailScript = InModuleScope AzlSonar { Get-AzlSonarRemoteTailScript }
        function Invoke-Tail {
            param(
                [string[]]$Paths,
                [hashtable]$FileState = @{},
                [bool]$FirstRun = $false,
                [int]$MaxLines = 500,
                [int]$ActiveWindowMinutes = 30,
                [long]$InitialTailBytes = 16384,
                [int]$MaxBytesPerFile = 1048576,
                [bool]$Discover = $true,
                [int]$MaxStateEntries = 2000
            )
            & $script:TailScript -Paths $Paths -Include @('*.log', '*.txt', '*.xml') -Exclude @('*.etl') -RecurseDepth 3 `
                -ActiveWindowMinutes $ActiveWindowMinutes -FileState $FileState -MaxLines $MaxLines -FirstRun $FirstRun -MaxFiles 300 `
                -MaxBytesPerFile $MaxBytesPerFile -InitialTailBytes $InitialTailBytes -Discover $Discover -MaxStateEntries $MaxStateEntries
        }
        function Get-Texts([object]$Result) { @($Result.lines | ForEach-Object { $_.text }) }
    }

    BeforeEach {
        $script:LogDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:LogDir
        $script:LogFile = Join-Path $script:LogDir 'Deploy.log'
    }

    It 'is a scriptblock that parses as Windows PowerShell-compatible code' {
        $script:TailScript | Should -BeOfType [scriptblock]
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script:TailScript.ToString(), [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'reads a new file from the start and reports its offset' {
        Write-LogText $script:LogFile "line 1`nline 2 ERROR`n"
        $result = Invoke-Tail -Paths @($script:LogDir)
        Get-Texts $result | Should -Be @('line 1', 'line 2 ERROR')
        @($result.files).Count | Should -Be 1
        $result.files[0].path | Should -Be $script:LogFile
        $result.files[0].offset | Should -Be (Get-Item $script:LogFile).Length
        $result.files[0].size | Should -Be (Get-Item $script:LogFile).Length
        $result.lines[0].file | Should -Be $script:LogFile
        @($result.missingPaths).Count | Should -Be 0
        @($result.errors).Count | Should -Be 0
        $result.state[$script:LogFile].offset | Should -Be (Get-Item $script:LogFile).Length
    }

    It 'returns only appended lines on the next poll' {
        Write-LogText $script:LogFile "a`nb`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        Add-LogText $script:LogFile "c`nd`n"
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('c', 'd')
        $third = Invoke-Tail -Paths @($script:LogDir) -FileState $second.state
        @($third.lines).Count | Should -Be 0
    }

    It 'carries a partial line over until it is complete' {
        Write-LogText $script:LogFile "done`nhalf"
        $first = Invoke-Tail -Paths @($script:LogDir)
        Get-Texts $first | Should -Be @('done')
        $first.files[0].offset | Should -Be 5
        Add-LogText $script:LogFile " written`n"
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('half written')
    }

    It 'starts from 0 again when the file is truncated (rotation in place)' {
        Write-LogText $script:LogFile "old 1`nold 2`nold 3`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        Write-LogText $script:LogFile "new 1`n"
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('new 1')
    }

    It 'starts from 0 again when the file is re-created, even if larger' {
        Write-LogText $script:LogFile "old`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        Remove-Item -LiteralPath $script:LogFile
        Write-LogText $script:LogFile "recreated 1`nrecreated 2`nrecreated 3`n"
        # NTFS tunnelling keeps the old creation time for a name re-created within 15 s; set a new one explicitly.
        [System.IO.File]::SetCreationTimeUtc($script:LogFile, [datetime]::UtcNow.AddMinutes(1))
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('recreated 1', 'recreated 2', 'recreated 3')
    }

    It 'carries the offset over to a renamed (rotated) file: its lines are not sent again' {
        Write-LogText $script:LogFile "before rotation`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        Add-LogText $script:LogFile "written just before the rename`n"
        $rotated = Join-Path $script:LogDir 'Deploy.1.log'
        Rename-Item -LiteralPath $script:LogFile -NewName 'Deploy.1.log'
        Write-LogText $script:LogFile "after rotation`n"
        [System.IO.File]::SetCreationTimeUtc($script:LogFile, [datetime]::UtcNow.AddMinutes(1))
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        $texts = Get-Texts $second
        $texts | Should -Contain 'after rotation'
        $texts | Should -Contain 'written just before the rename' -Because 'the renamed file continues from the carried offset'
        $texts | Should -Not -Contain 'before rotation' -Because 'lines already sent under the old name are not sent again'
        @($second.renamed).Count | Should -Be 1
        $second.renamed[0].from | Should -Be $script:LogFile
        $second.renamed[0].to | Should -Be $rotated
        $second.state[$rotated].offset | Should -Be (Get-Item -LiteralPath $rotated).Length
        $second.state.ContainsKey($script:LogFile) | Should -BeTrue
    }

    It 'handles rename rotation when the new file keeps the old creation time (NTFS tunnelling)' {
        Write-LogText $script:LogFile "before rotation`n"
        $created = (Get-Item -LiteralPath $script:LogFile).CreationTimeUtc
        $first = Invoke-Tail -Paths @($script:LogDir)
        Rename-Item -LiteralPath $script:LogFile -NewName 'Deploy.1.log'
        Write-LogText $script:LogFile "after rotation, a first line longer than the old offset`n"
        [System.IO.File]::SetCreationTimeUtc($script:LogFile, $created)
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('after rotation, a first line longer than the old offset') -Because 'the new file is read from 0 and the renamed one continues'
        @($second.renamed).Count | Should -Be 1
        $second.renamed[0].to | Should -Be (Join-Path $script:LogDir 'Deploy.1.log')
    }

    It 're-reads a file re-created under the same name with the same creation time but other content' {
        Write-LogText $script:LogFile "old`n"
        $created = (Get-Item -LiteralPath $script:LogFile).CreationTimeUtc
        $first = Invoke-Tail -Paths @($script:LogDir)
        Remove-Item -LiteralPath $script:LogFile
        Write-LogText $script:LogFile "new 1`nnew 2`n"
        [System.IO.File]::SetCreationTimeUtc($script:LogFile, $created)
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('new 1', 'new 2')
    }

    It 'does not carry an offset to a new file whose first bytes differ (not a rename)' {
        Write-LogText $script:LogFile "first file`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        $created = (Get-Item -LiteralPath $script:LogFile).CreationTimeUtc
        Remove-Item -LiteralPath $script:LogFile
        $other = Join-Path $script:LogDir 'Other.log'
        Write-LogText $other "a different file`n"
        [System.IO.File]::SetCreationTimeUtc($other, $created)
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('a different file')
        @($second.renamed).Count | Should -Be 0
    }

    It 'keeps a file that vanished between listings until the next listing can match its new name' {
        Write-LogText $script:LogFile "line one`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        $rotated = Join-Path $script:LogDir 'Deploy.1.log'
        Rename-Item -LiteralPath $script:LogFile -NewName 'Deploy.1.log'
        $quiet = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state -Discover $false
        $quiet.vanished | Should -Be 1
        $quiet.state[$script:LogFile].gone | Should -BeTrue
        $quiet.state[$script:LogFile].active | Should -BeFalse
        Add-LogText $rotated "line two`n"
        $listed = Invoke-Tail -Paths @($script:LogDir) -FileState $quiet.state -Discover $true
        Get-Texts $listed | Should -Be @('line two')
        $listed.renamed[0].from | Should -Be $script:LogFile
        $listed.state.ContainsKey($script:LogFile) | Should -BeFalse
    }

    It 'excludes *.etl and files that match no include pattern' {
        Write-LogText $script:LogFile "keep`n"
        Write-LogText (Join-Path $script:LogDir 'trace.etl') "binary-ish error`n"
        Write-LogText (Join-Path $script:LogDir 'data.bin') "skip`n"
        $result = Invoke-Tail -Paths @($script:LogDir)
        @($result.files.path) | Should -Be @($script:LogFile)
        Get-Texts $result | Should -Be @('keep')
    }

    It 'finds files in sub folders' {
        $sub = Join-Path $script:LogDir 'sub\deeper'
        $null = New-Item -ItemType Directory -Path $sub
        Write-LogText (Join-Path $sub 'nested.txt') "nested line`n"
        $result = Invoke-Tail -Paths @($script:LogDir)
        Get-Texts $result | Should -Be @('nested line')
    }

    It 'reports a path that does not exist yet and still reads the others' {
        Write-LogText $script:LogFile "present`n"
        $missing = Join-Path $script:LogDir 'CloudDeployment\Logs'
        $result = Invoke-Tail -Paths @($missing, $script:LogDir)
        @($result.missingPaths) | Should -Be @($missing)
        Get-Texts $result | Should -Be @('present')
    }

    It 'leaves out files not written within the active window' {
        Write-LogText $script:LogFile "fresh`n"
        $old = Join-Path $script:LogDir 'Old.log'
        Write-LogText $old "stale`n"
        [System.IO.File]::SetLastWriteTimeUtc($old, [datetime]::UtcNow.AddHours(-2))
        $result = Invoke-Tail -Paths @($script:LogDir) -ActiveWindowMinutes 30
        @($result.files.path) | Should -Be @($script:LogFile)
    }

    It 'starts an existing large file near its end on the first run, at a line boundary' {
        $builder = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt 2000; $i++) { $null = $builder.Append(('line {0:D5} padding padding padding' -f $i)).Append("`n") }
        Write-LogText $script:LogFile $builder.ToString()
        $result = Invoke-Tail -Paths @($script:LogDir) -FirstRun $true -InitialTailBytes 1024
        $texts = Get-Texts $result
        $texts.Count | Should -BeGreaterThan 0
        $texts.Count | Should -BeLessThan 40
        $texts[-1] | Should -Be 'line 01999 padding padding padding'
        $texts | ForEach-Object { $_ | Should -Match '^line \d{5} padding padding padding$' }
    }

    It 'caps the lines per poll and continues next poll' {
        Write-LogText $script:LogFile (((1..10) | ForEach-Object { "l$_" }) -join "`n")
        Add-LogText $script:LogFile "`n"
        $first = Invoke-Tail -Paths @($script:LogDir) -MaxLines 4
        Get-Texts $first | Should -Be @('l1', 'l2', 'l3', 'l4')
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state -MaxLines 4
        Get-Texts $second | Should -Be @('l5', 'l6', 'l7', 'l8')
    }

    It 'reads UTF-16LE logs with a BOM' {
        [System.IO.File]::WriteAllText($script:LogFile, "unicode one`r`nunicode two`r`n", [System.Text.Encoding]::Unicode)
        $first = Invoke-Tail -Paths @($script:LogDir)
        Get-Texts $first | Should -Be @('unicode one', 'unicode two')
        $first.state[$script:LogFile].encoding | Should -Be 'unicode'
        [System.IO.File]::AppendAllText($script:LogFile, "unicode three`r`n", [System.Text.Encoding]::Unicode)
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state
        Get-Texts $second | Should -Be @('unicode three')
    }

    It 'reports the node UTC offset and whether it listed the folders' {
        Write-LogText $script:LogFile "x`n"
        $result = Invoke-Tail -Paths @($script:LogDir)
        $expected = [int][Math]::Round([TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now).TotalMinutes)
        $result.utcOffsetMinutes | Should -Be $expected
        $result.utcOffsetMinutes | Should -BeOfType [int]
        $result.discovered | Should -BeTrue
        $result.state[$script:LogFile].active | Should -BeTrue
        $result.state[$script:LogFile].head | Should -Be ([Convert]::ToBase64String($script:Utf8.GetBytes("x`n")))
    }

    It 'between listings tails the known active files without Get-ChildItem and finds new files at the next listing' {
        Write-LogText $script:LogFile "a`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        Add-LogText $script:LogFile "b`n"
        $newFile = Join-Path $script:LogDir 'New.log'
        Write-LogText $newFile "new file line`n"
        $quiet = Invoke-Tail -Paths @($script:LogDir, (Join-Path $script:LogDir 'missing')) -FileState $first.state -Discover $false
        Get-Texts $quiet | Should -Be @('b')
        $quiet.discovered | Should -BeFalse
        @($quiet.missingPaths).Count | Should -Be 0 -Because 'paths are only checked when the folders are listed'
        @($quiet.files.path) | Should -Be @($script:LogFile) -Because 'the new file is not seen until the next listing'
        $listed = Invoke-Tail -Paths @($script:LogDir) -FileState $quiet.state -Discover $true
        Get-Texts $listed | Should -Be @('new file line')
    }

    It 'does not call Get-ChildItem between listings' {
        Write-LogText $script:LogFile "a`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        Add-LogText $script:LogFile "b`n"
        Mock Get-ChildItem { throw 'Get-ChildItem must not run between listings.' }
        $quiet = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state -Discover $false
        Get-Texts $quiet | Should -Be @('b')
        Should -Invoke Get-ChildItem -Times 0 -Exactly
    }

    It 'between listings ignores tracked files that were not active at the last listing' {
        Write-LogText $script:LogFile "fresh`n"
        $old = Join-Path $script:LogDir 'Old.log'
        Write-LogText $old "stale`n"
        $first = Invoke-Tail -Paths @($script:LogDir)
        [System.IO.File]::SetLastWriteTimeUtc($old, [datetime]::UtcNow.AddHours(-2))
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state -ActiveWindowMinutes 30
        $second.state[$old].active | Should -BeFalse -Because 'outside the active window, still tracked'
        $second.state[$old].offset | Should -Be (Get-Item -LiteralPath $old).Length
        Add-LogText $old "written again`n"
        [System.IO.File]::SetLastWriteTimeUtc($old, [datetime]::UtcNow.AddHours(-2))
        $quiet = Invoke-Tail -Paths @($script:LogDir) -FileState $second.state -Discover $false
        @($quiet.files.path) | Should -Be @($script:LogFile)
        $quiet.state[$old].offset | Should -Be $second.state[$old].offset -Because 'inactive entries are carried unchanged'
    }

    It 'caps the tracked state at MaxStateEntries, evicting the least recently written first' {
        $paths = foreach ($i in 1..5) {
            $p = Join-Path $script:LogDir ("f$i.log")
            Write-LogText $p "line $i`n"
            [System.IO.File]::SetLastWriteTimeUtc($p, [datetime]::UtcNow.AddMinutes(-10 + $i))
            $p
        }
        $result = Invoke-Tail -Paths @($script:LogDir) -MaxStateEntries 3
        $result.stateEvicted | Should -Be 2
        @($result.state.Keys | Sort-Object) | Should -Be @($paths[2..4] | Sort-Object)
    }

    It 'keeps active files over inactive ones when it evicts' {
        $paths = foreach ($i in 1..4) {
            $p = Join-Path $script:LogDir ("g$i.log")
            Write-LogText $p "line $i`n"
            $p
        }
        $first = Invoke-Tail -Paths @($script:LogDir)
        # g3 and g4 leave the active window (older than 30 min); g1 and g2 stay active.
        [System.IO.File]::SetLastWriteTimeUtc($paths[2], [datetime]::UtcNow.AddHours(-2))
        [System.IO.File]::SetLastWriteTimeUtc($paths[3], [datetime]::UtcNow.AddHours(-3))
        $second = Invoke-Tail -Paths @($script:LogDir) -FileState $first.state -MaxStateEntries 3
        $second.stateEvicted | Should -Be 1
        $second.state.ContainsKey($paths[0]) | Should -BeTrue
        $second.state.ContainsKey($paths[1]) | Should -BeTrue
        $second.state.ContainsKey($paths[2]) | Should -BeTrue -Because 'the newer of the inactive files stays'
        $second.state.ContainsKey($paths[3]) | Should -BeFalse
    }

    It 'reads a file another process holds open for writing' {
        $stream = [System.IO.File]::Open($script:LogFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = $script:Utf8.GetBytes("locked writer`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $result = Invoke-Tail -Paths @($script:LogDir)
            @($result.errors).Count | Should -Be 0
            # NTFS keeps a stale directory-listing size while a writer holds the file open; the tail script refreshes it.
            Get-Texts $result | Should -Be @('locked writer')
        }
        finally {
            $stream.Dispose()
        }
    }
}

Describe 'Log ring buffer (Add-AzlSonarLogLine / Get-AzlSonarLogLine)' {
    It 'numbers lines, classifies them and caps the buffer at RingSize' {
        $result = InModuleScope AzlSonar {
            $shared = Initialize-AzlSonarSharedState -RingSize 5
            $lines = foreach ($i in 1..8) { [pscustomobject]@{ file = 'C:\MASLogs\a.log'; text = $(if ($i -eq 8) { 'ERROR eight' } else { "line $i" }) } }
            Add-AzlSonarLogLine -Shared $shared -Line @($lines) -Time ([datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00.123', 'Utc'))
            [pscustomobject]@{
                Count  = $shared.Lines.Count
                Seq    = $shared.LogSeq
                All    = Get-AzlSonarLogLine -Shared $shared
                Since6 = Get-AzlSonarLogLine -Shared $shared -Since 6
                Max2   = Get-AzlSonarLogLine -Shared $shared -Since 0 -Max 2
                After  = Get-AzlSonarLogLine -Shared $shared -Since 8
            }
        }
        $result.Count | Should -Be 5
        $result.Seq | Should -Be 8
        @($result.All).ForEach({ $_.seq }) | Should -Be @(4, 5, 6, 7, 8)
        @($result.Since6).ForEach({ $_.seq }) | Should -Be @(7, 8)
        @($result.Max2).ForEach({ $_.seq }) | Should -Be @(4, 5)
        @($result.After).Count | Should -Be 0
        $result.All[-1].level | Should -Be 'error'
        $result.All[0].level | Should -Be 'info'
        $result.All[0].time | Should -Be '2026-10-10T18:00:00.123Z'
        $result.All[0].received | Should -Be '2026-10-10T18:00:00.123Z'
        $result.All[0].timeSource | Should -Be 'received'
        $result.All[0].file | Should -Be 'C:\MASLogs\a.log'
        @($result.All[0].Keys) | Should -Be @('seq', 'time', 'received', 'timeSource', 'file', 'level', 'text')
    }

    It 'sets time to the event time from the line or the file name, and keeps the receive time' {
        $lines = InModuleScope AzlSonar {
            $shared = Initialize-AzlSonarSharedState
            Add-AzlSonarLogLine -Shared $shared -UtcOffsetMinutes 120 -Time ([datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', 'Utc')) -Line @(
                [pscustomobject]@{ file = 'C:\MASLogs\Deploy.log'; text = '2026-10-10 17:58:01.250 starting step' }
                [pscustomobject]@{ file = 'C:\MASLogs\Deploy.log'; text = '2026-10-10T15:58:02Z utc line' }
                [pscustomobject]@{ file = 'C:\CloudContent\MASLogs\BareMetal_Step_20261010-174500.log'; text = 'no timestamp here' }
                [pscustomobject]@{ file = 'C:\MASLogs\Deploy.log'; text = 'continuation line' }
            )
            Get-AzlSonarLogLine -Shared $shared
        }
        $lines[0].time | Should -Be '2026-10-10T15:58:01.250Z' -Because 'node-local +02:00 converted to UTC'
        $lines[0].timeSource | Should -Be 'line'
        $lines[0].received | Should -Be '2026-10-10T18:00:00.000Z'
        $lines[1].time | Should -Be '2026-10-10T15:58:02.000Z'
        $lines[1].timeSource | Should -Be 'line'
        $lines[2].time | Should -Be '2026-10-10T15:45:00.000Z'
        $lines[2].timeSource | Should -Be 'file'
        $lines[3].time | Should -Be '2026-10-10T18:00:00.000Z'
        $lines[3].timeSource | Should -Be 'received'
    }

    It 'ignores an empty batch' {
        $seq = InModuleScope AzlSonar {
            $shared = Initialize-AzlSonarSharedState
            Add-AzlSonarLogLine -Shared $shared -Line @()
            Add-AzlSonarLogLine -Shared $shared -Line $null
            $shared.LogSeq
        }
        $seq | Should -Be 0
    }

    It 'masks the log account password before storing a line' {
        $text = InModuleScope AzlSonar {
            $shared = Initialize-AzlSonarSharedState
            $shared.Redact = @('Sup3r-Secret!')
            Add-AzlSonarLogLine -Shared $shared -Line @([pscustomobject]@{ file = 'x'; text = 'connecting with Sup3r-Secret! now' })
            (Get-AzlSonarLogLine -Shared $shared)[0].text
        }
        $text | Should -Not -BeLike '*Sup3r-Secret!*'
        $text | Should -BeLike 'connecting with * now'
    }
}

Describe 'Get-AzlSonarLogEventTime' {
    # Received 2026-10-10 18:00:00Z; the node runs at UTC+02:00 unless a case says otherwise.
    It '<Name>' -TestCases @(
        @{ Name = 'ISO 8601 with Z'; Text = '2026-10-10T16:16:42Z Starting'; File = ''; Offset = 120; Expected = '2026-10-10T16:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'ISO 8601 with 7-digit fraction and Z'; Text = '2026-10-10T16:16:42.1234567Z x'; File = ''; Offset = 120; Expected = '2026-10-10T16:16:42.1234567Z'; Source = 'line' }
        @{ Name = 'ISO 8601 with offset'; Text = '2026-10-10T16:16:42.500+02:00 x'; File = ''; Offset = 0; Expected = '2026-10-10T14:16:42.5000000Z'; Source = 'line' }
        @{ Name = 'ISO 8601 with negative offset, no colon'; Text = '2026-10-10T06:16:42-0700 x'; File = ''; Offset = 0; Expected = '2026-10-10T13:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'ISO 8601 without offset is node-local'; Text = '2026-10-10T16:16:42 x'; File = ''; Offset = 120; Expected = '2026-10-10T14:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'yyyy-MM-dd HH:mm:ss'; Text = '2026-10-10 16:16:42 Info: x'; File = ''; Offset = 120; Expected = '2026-10-10T14:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'yyyy-MM-dd HH:mm:ss.fff'; Text = '2026-10-10 16:16:42.123 x'; File = ''; Offset = -300; Expected = '2026-10-10T21:16:42.1230000Z'; Source = 'line' }
        @{ Name = 'yyyy-MM-dd HH:mm:ss,fff (comma)'; Text = '2026-10-10 16:16:42,250 x'; File = ''; Offset = 0; Expected = '2026-10-10T16:16:42.2500000Z'; Source = 'line' }
        @{ Name = '[yyyy-MM-dd HH:mm:ss]'; Text = '[2026-10-10 16:16:42] [Info] x'; File = ''; Offset = 120; Expected = '2026-10-10T14:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'MM/dd/yyyy HH:mm:ss'; Text = '10/09/2026 23:59:59 x'; File = ''; Offset = 60; Expected = '2026-10-09T22:59:59.0000000Z'; Source = 'line' }
        @{ Name = '[MM/dd/yyyy h:mm:ss PM]'; Text = '[10/10/2026 4:16:42 PM] x'; File = ''; Offset = 0; Expected = '2026-10-10T16:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'MM/dd/yyyy 12:05:00 AM'; Text = '10/10/2026 12:05:00 AM x'; File = ''; Offset = 0; Expected = '2026-10-10T00:05:00.0000000Z'; Source = 'line' }
        @{ Name = 'transcript Start time'; Text = 'Start time: 20261010161642'; File = 'C:\x\PowerShell_transcript.N1.ab.txt'; Offset = 120; Expected = '2026-10-10T14:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'leading byte order mark and spaces'; Text = ([string][char]0xFEFF + '  2026-10-10T16:16:42Z x'); File = ''; Offset = 0; Expected = '2026-10-10T16:16:42.0000000Z'; Source = 'line' }
        @{ Name = 'file name yyyyMMdd-HHmmss (node-local)'; Text = 'no time'; File = 'C:\CloudContent\MASLogs\BareMetal_Deploy_20261010-161642.log'; Offset = 120; Expected = '2026-10-10T14:16:42.0000000Z'; Source = 'file' }
        @{ Name = 'file name yyyyMMdd-HHmmssZ (UTC)'; Text = 'no time'; File = 'C:\MASLogs\Install-LCMController_20261010-174335Z.log'; Offset = 120; Expected = '2026-10-10T17:43:35.0000000Z'; Source = 'file' }
        @{ Name = 'transcript file name yyyyMMddHHmmss'; Text = 'PS> Get-Thing'; File = 'C:\Logs\PowerShell_transcript.NODE01.Ab1cD2eF.20261010161642.txt'; Offset = 0; Expected = '2026-10-10T16:16:42.0000000Z'; Source = 'file' }
        @{ Name = 'line time wins over the file name'; Text = '2026-10-10T17:00:00Z x'; File = 'C:\x\Step_20261010-161642.log'; Offset = 0; Expected = '2026-10-10T17:00:00.0000000Z'; Source = 'line' }
        @{ Name = 'no timestamp anywhere'; Text = 'Running step 3'; File = 'C:\MASLogs\Deploy.log'; Offset = 0; Expected = '2026-10-10T18:00:00.0000000Z'; Source = 'received' }
        @{ Name = 'timestamp not at the start is not used'; Text = 'Step started at 2026-10-10 16:16:42'; File = ''; Offset = 0; Expected = '2026-10-10T18:00:00.0000000Z'; Source = 'received' }
        @{ Name = 'invalid date'; Text = '2026-13-45 16:16:42 x'; File = ''; Offset = 0; Expected = '2026-10-10T18:00:00.0000000Z'; Source = 'received' }
        @{ Name = 'a number that only looks like a date'; Text = '2026-10-10 16:16:425 x'; File = ''; Offset = 0; Expected = '2026-10-10T18:00:00.0000000Z'; Source = 'received' }
        @{ Name = 'more than a day in the future'; Text = '2026-10-20T00:00:00Z x'; File = ''; Offset = 0; Expected = '2026-10-10T18:00:00.0000000Z'; Source = 'received' }
    ) {
        param($Text, $File, $Offset, $Expected, $Source)
        $r = InModuleScope AzlSonar -Parameters @{ Text = $Text; File = $File; Offset = $Offset } {
            param($Text, $File, $Offset)
            Get-AzlSonarLogEventTime -Text $Text -File $File -UtcOffsetMinutes $Offset -Received ([datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', 'Utc'))
        }
        $r.Source | Should -Be $Source
        $r.Time.Kind | Should -Be ([System.DateTimeKind]::Utc)
        $r.Time.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be $Expected
    }

    It 'does not place a node-local time when the node offset is unknown' {
        $r = InModuleScope AzlSonar {
            Get-AzlSonarLogEventTime -Text '2026-10-10 16:16:42 x' -File 'C:\x\Step_20261010-161642.log' -UtcOffsetMinutes $null -Received ([datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', 'Utc'))
        }
        $r.Source | Should -Be 'received'
        $r.Time | Should -Be ([datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', 'Utc'))
    }

    It 'still uses explicit Z and offsets when the node offset is unknown' {
        $r = InModuleScope AzlSonar {
            Get-AzlSonarLogEventTime -Text '2026-10-10T16:16:42Z x' -UtcOffsetMinutes $null -Received ([datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', 'Utc'))
        }
        $r.Source | Should -Be 'line'
    }
}

Describe 'Test-AzlSonarDiscoveryDue' {
    It 'lists on the first poll, then on every 3rd poll' {
        $due = InModuleScope AzlSonar {
            $now = [datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', 'Utc')
            @(
                Test-AzlSonarDiscoveryDue -PollsSinceDiscovery 0 -LastDiscoveryUtc $null -Now $now
                Test-AzlSonarDiscoveryDue -PollsSinceDiscovery 0 -LastDiscoveryUtc $now -Now $now.AddSeconds(20)
                Test-AzlSonarDiscoveryDue -PollsSinceDiscovery 1 -LastDiscoveryUtc $now -Now $now.AddSeconds(40)
                Test-AzlSonarDiscoveryDue -PollsSinceDiscovery 2 -LastDiscoveryUtc $now -Now $now.AddSeconds(50)
            )
        }
        $due | Should -Be @($true, $false, $false, $true)
    }

    It 'lists when 60 s passed since the last listing, even on a fast poll' {
        InModuleScope AzlSonar {
            $now = [datetime]::SpecifyKind([datetime]'2026-10-10T18:00:00', 'Utc')
            Test-AzlSonarDiscoveryDue -PollsSinceDiscovery 0 -LastDiscoveryUtc $now -Now $now.AddSeconds(61)
        } | Should -BeTrue
    }

    It 'lists when forced (a file vanished or the session was re-opened)' {
        InModuleScope AzlSonar {
            $now = [datetime]::UtcNow
            Test-AzlSonarDiscoveryDue -PollsSinceDiscovery 0 -LastDiscoveryUtc $now -Now $now -Force
        } | Should -BeTrue
    }
}

Describe 'Test-AzlSonarTrustedHost' {
    It "TrustedHosts '<Value>' covers '<Address>': <Expected>" -TestCases @(
        @{ Value = '*'; Address = '192.0.2.11'; Expected = $true }
        @{ Value = '*'; Address = 'node01'; Expected = $true }
        @{ Value = 'node01'; Address = 'node01'; Expected = $true }
        @{ Value = 'node01'; Address = 'NODE01'; Expected = $true }
        @{ Value = 'node01'; Address = 'node02'; Expected = $false }
        @{ Value = '192.0.2.*'; Address = '192.0.2.11'; Expected = $true }
        @{ Value = '192.0.2.*'; Address = '198.51.100.11'; Expected = $false }
        @{ Value = 'other, 192.0.2.11'; Address = '192.0.2.11'; Expected = $true }
        @{ Value = ''; Address = '192.0.2.11'; Expected = $false }
        @{ Value = ' '; Address = '192.0.2.11'; Expected = $false }
        @{ Value = ',,'; Address = '192.0.2.11'; Expected = $false }
    ) {
        param($Value, $Address, $Expected)
        InModuleScope AzlSonar -Parameters @{ V = $Value; A = $Address } { param($V, $A) Test-AzlSonarTrustedHost -TrustedHosts $V -Address $A } | Should -Be $Expected
    }

    It 'treats $null as not trusted' {
        InModuleScope AzlSonar { Test-AzlSonarTrustedHost -TrustedHosts $null -Address 'node01' } | Should -BeFalse
    }
}

Describe 'Get-AzlSonarTrustedHostStatus' {
    It 'is not required for Active Directory with a host name' {
        $status = InModuleScope AzlSonar { Get-AzlSonarTrustedHostStatus -Address 'node01.contoso.example' -IdentityModel ActiveDirectory -TrustedHostsValue '' -UseValue }
        $status.required | Should -BeFalse
        $status.trusted | Should -BeNullOrEmpty
    }

    It 'is required for an IP address even with Active Directory' {
        $status = InModuleScope AzlSonar { Get-AzlSonarTrustedHostStatus -Address '192.0.2.11' -IdentityModel ActiveDirectory -TrustedHostsValue '192.0.2.*' -UseValue }
        $status.required | Should -BeTrue
        if ($IsWindows) { $status.trusted | Should -BeTrue }
    }

    It 'explains how to fix a missing entry and never sets it' -Skip:(-not $IsWindows) {
        Mock -ModuleName AzlSonar -CommandName Set-Item -MockWith { throw 'Set-Item must not be called' }
        $status = InModuleScope AzlSonar { Get-AzlSonarTrustedHostStatus -Address '192.0.2.11' -IdentityModel LocalIdentity -TrustedHostsValue 'node09' -UseValue }
        $status.required | Should -BeTrue
        $status.trusted | Should -BeFalse
        $status.message | Should -BeLike '*not in the WinRM client TrustedHosts*Sonar never changes it*'
        Should -Invoke -ModuleName AzlSonar -CommandName Set-Item -Times 0 -Exactly
    }
}

Describe 'Invoke-AzlSonarTailerLoop (mocked New-PSSession / Invoke-Command)' {
    BeforeAll {
        $script:TailerConfig = Read-AzlSonarConfig -Path $script:SonarExampleConfig
    }

    BeforeEach {
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $Shared.Stop = $true }
        Mock -ModuleName AzlSonar -CommandName Get-AzlSonarTrustedHostsValue -MockWith { 'node09' }
        Mock -ModuleName AzlSonar -CommandName Remove-PSSession -RemoveParameterType Session -MockWith { }
    }

    It 'reports unavailable with the reason and the TrustedHosts hint when the session cannot open' {
        Mock -ModuleName AzlSonar -CommandName New-PSSession -MockWith { throw 'WinRM cannot complete the operation.' }
        Mock -ModuleName AzlSonar -CommandName Invoke-Command -RemoveParameterType Session -MockWith { throw 'must not run' }
        $shared = InModuleScope AzlSonar -Parameters @{ Config = $script:TailerConfig } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarTailerLoop -Shared $shared -Config $Config -Credential $null
            $shared
        }
        $shared.Tailer.state | Should -Be 'unavailable'
        $shared.Tailer.reason | Should -BeLike '*node01 (192.0.2.11)*WinRM cannot complete the operation.*'
        if ($IsWindows) { $shared.Tailer.reason | Should -BeLike '*TrustedHosts*' }
        $shared.Tailer.retryInSeconds | Should -Be 60
        $shared.Tailer.node | Should -Be 'node01'
        $shared.Tailer.credential | Should -Be 'current Windows identity'
        $shared.TailerVersion | Should -Be 2 -Because 'connecting, then unavailable'
        Should -Invoke -ModuleName AzlSonar -CommandName Invoke-Command -Times 0 -Exactly
        Should -Invoke -ModuleName AzlSonar -CommandName New-PSSession -Times 1 -Exactly -ParameterFilter { $ComputerName -eq '192.0.2.11' }
    }

    It 'tails the logs through the session and fills the ring buffer' {
        $logDir = Join-Path $TestDrive 'tailer-loop'
        $null = New-Item -ItemType Directory -Path $logDir -Force
        [System.IO.File]::WriteAllText((Join-Path $logDir 'Deploy.log'), "starting`nWARNING: slow`nstep FAILED`n")
        $config = Read-AzlSonarConfig -Path $script:SonarExampleConfig
        $config.logs.paths = [string[]]@($logDir, (Join-Path $TestDrive 'not-there'))

        Mock -ModuleName AzlSonar -CommandName New-PSSession -MockWith { [pscustomobject]@{ State = 'Opened'; Name = 'AzlSonar' } }
        # Run the real remote script locally, exactly as the node would.
        Mock -ModuleName AzlSonar -CommandName Invoke-Command -RemoveParameterType Session -MockWith { & $ScriptBlock @ArgumentList }

        $credential = [pscredential]::new('corpeader', (ConvertTo-SecureString -String 'not-a-real-password' -AsPlainText -Force))
        $shared = InModuleScope AzlSonar -Parameters @{ Config = $config; Credential = $credential } {
            param($Config, $Credential)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarTailerLoop -Shared $shared -Config $Config -Credential $Credential
            $shared
        }
        $shared.Tailer.state | Should -Be 'connected'
        $shared.Tailer.credential | Should -Be 'supplied'
        $shared.Tailer.filesTracked | Should -Be 1
        $shared.Tailer.reason | Should -BeLike 'Not created yet*not-there*'
        @($shared.Tailer.missingPaths).Count | Should -Be 1
        $shared.Tailer.lastPollUtc | Should -Match 'Z$'
        $shared.LogSeq | Should -Be 3
        @($shared.Lines.ToArray()).ForEach({ $_.level }) | Should -Be @('info', 'warning', 'error')
        @($shared.Files).Count | Should -Be 1
        $shared.Files[0].path | Should -BeLike '*Deploy.log'
        $shared.TailerJson | Should -Not -BeLike '*not-a-real-password*'
        Should -Invoke -ModuleName AzlSonar -CommandName New-PSSession -Times 1 -Exactly -ParameterFilter { $null -ne $Credential -and $Credential.UserName -eq 'corpeader' }
        Should -Invoke -ModuleName AzlSonar -CommandName Remove-PSSession -Times 1 -Exactly
    }

    It 'lists the folders on every 3rd poll only and converts node-local times with the reported offset' {
        $script:PollCalls = [System.Collections.Generic.List[object]]::new()
        $script:WaitCalls = 0
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $script:WaitCalls++; if ($script:WaitCalls -ge 4) { $Shared.Stop = $true } }
        Mock -ModuleName AzlSonar -CommandName New-PSSession -MockWith { [pscustomobject]@{ State = 'Opened'; Name = 'AzlSonar' } }
        Mock -ModuleName AzlSonar -CommandName Invoke-Command -RemoveParameterType Session -MockWith {
            $script:PollCalls.Add([bool]$ArgumentList[11])
            [pscustomobject]@{
                utcOffsetMinutes = 120
                discovered       = [bool]$ArgumentList[11]
                files            = @()
                lines            = @([pscustomobject]@{ file = 'C:\MASLogs\Deploy.log'; text = '2026-10-10 17:00:00 local line' })
                state            = @{}
                missingPaths     = @()
                errors           = @()
                renamed          = @()
                vanished         = 0
            }
        }
        $shared = InModuleScope AzlSonar -Parameters @{ Config = $script:TailerConfig } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarTailerLoop -Shared $shared -Config $Config -Credential $null
            $shared
        }
        @($script:PollCalls) | Should -Be @($true, $false, $false, $true)
        $first = @($shared.Lines.ToArray())[0]
        $first.time | Should -Be '2026-10-10T15:00:00.000Z'
        $first.timeSource | Should -Be 'line'
        $shared.Tailer.nodeUtcOffsetMinutes | Should -Be 120
        $shared.Tailer.lastDiscoveryUtc | Should -Match 'Z$'
    }

    It 'lists the folders again on the next poll after a tracked file vanished' {
        $script:PollCalls = [System.Collections.Generic.List[object]]::new()
        $script:WaitCalls = 0
        Mock -ModuleName AzlSonar -CommandName Wait-AzlSonarInterval -MockWith { $script:WaitCalls++; if ($script:WaitCalls -ge 3) { $Shared.Stop = $true } }
        Mock -ModuleName AzlSonar -CommandName New-PSSession -MockWith { [pscustomobject]@{ State = 'Opened'; Name = 'AzlSonar' } }
        Mock -ModuleName AzlSonar -CommandName Invoke-Command -RemoveParameterType Session -MockWith {
            $script:PollCalls.Add([bool]$ArgumentList[11])
            [pscustomobject]@{
                utcOffsetMinutes = 0; discovered = [bool]$ArgumentList[11]; files = @(); lines = @(); state = @{}
                missingPaths = @(); errors = @(); renamed = @(); vanished = $(if ($script:PollCalls.Count -eq 2) { 1 } else { 0 })
            }
        }
        $null = InModuleScope AzlSonar -Parameters @{ Config = $script:TailerConfig } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarTailerLoop -Shared $shared -Config $Config -Credential $null
        }
        @($script:PollCalls) | Should -Be @($true, $false, $true)
    }

    It 'reports unavailable and drops the session when a poll fails' {
        Mock -ModuleName AzlSonar -CommandName New-PSSession -MockWith { [pscustomobject]@{ State = 'Opened'; Name = 'AzlSonar' } }
        Mock -ModuleName AzlSonar -CommandName Invoke-Command -RemoveParameterType Session -MockWith { throw 'The session state is Broken.' }
        $shared = InModuleScope AzlSonar -Parameters @{ Config = $script:TailerConfig } {
            param($Config)
            $shared = Initialize-AzlSonarSharedState
            Invoke-AzlSonarTailerLoop -Shared $shared -Config $Config -Credential $null
            $shared
        }
        $shared.Tailer.state | Should -Be 'unavailable'
        $shared.Tailer.reason | Should -BeLike 'Reading the logs on node01 failed: The session state is Broken.*'
        Should -Invoke -ModuleName AzlSonar -CommandName Remove-PSSession -Times 1 -Exactly
    }
}
