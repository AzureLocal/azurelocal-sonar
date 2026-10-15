#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# Export bundle (S-9): timeline JSON and a self-contained HTML report from a recording. No Azure, no node.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/recording-sample.jsonl'
}

Describe 'Export-AzlSonarBundle' {
    BeforeAll {
        $script:Out = Join-Path $TestDrive 'bundle'
        $script:Result = Export-AzlSonarBundle -Recording $script:Fixture -OutDirectory $script:Out
        $script:Timeline = Get-Content -LiteralPath $script:Result.Timeline -Raw | ConvertFrom-Json -Depth 32
        $script:Html = Get-Content -LiteralPath $script:Result.Report -Raw
    }

    It 'writes the two files named after the recording' {
        Split-Path -Leaf $script:Result.Timeline | Should -Be 'recording-sample-timeline.json'
        Split-Path -Leaf $script:Result.Report | Should -Be 'recording-sample-report.html'
    }

    It 'the timeline has the recording, the phases in order with durations, the steps and the errors' {
        $script:Timeline.kind | Should -Be 'timeline'
        $script:Timeline.source.sessions | Should -Be 2
        $script:Timeline.cluster | Should -Be 'clus01'
        @($script:Timeline.phases.phase)[0..2] | Should -Be @('arc-registration', 'validation', 'deployment')
        ($script:Timeline.phases | Where-Object phase -eq 'validation').durationSeconds | Should -BeGreaterThan 0
        (@($script:Timeline.steps) | Where-Object { $_.section -eq 'deployment' -and $_.name -eq 'Deploy Arc resource bridge' }).Count | Should -BeGreaterThan 0
        @($script:Timeline.logLines | Where-Object level -eq 'error').Count | Should -BeGreaterThan 0
        $script:Timeline.logCounts.error | Should -BeGreaterThan 0
    }

    It 'keeps the secret masking: nothing is added back' {
        $script:Html | Should -Not -Match 'hunter2|Bearer [A-Za-z0-9]'
        (Get-Content -LiteralPath $script:Result.Timeline -Raw) | Should -Not -Match 'hunter2'
    }

    It 'the report is self-contained: no script, no link, no external resource' {
        $script:Html | Should -Not -Match '<script'
        $script:Html | Should -Not -Match '(src|href)\s*='
        $script:Html | Should -Not -Match 'https?://'
        $script:Html | Should -Match '<h1>AzL Sonar report: clus01</h1>'
        $script:Html | Should -Match 'Deployment steps'
        $script:Html | Should -Match 'unverified against a live run'
    }

    It 'HTML-encodes everything it shows' {
        $evil = Join-Path $TestDrive 'evil.jsonl'
        $lines = Get-Content -LiteralPath $script:Fixture | Where-Object { $_ }
        $lines = $lines | ForEach-Object { $_.Replace('Validate Hardware', 'Validate <img src=x onerror=alert(1)>').Replace('Deployment completed.', '<script>alert(2)</script> done') }
        [System.IO.File]::WriteAllLines($evil, $lines)
        $r = Export-AzlSonarBundle -Recording $evil -OutDirectory (Join-Path $TestDrive 'evil-out')
        $h = Get-Content -LiteralPath $r.Report -Raw
        $h | Should -Not -Match '<img'
        $h | Should -Not -Match '<script'
        $h | Should -Match '&lt;img src=x onerror=alert\(1\)&gt;'
    }

    It 'reads a gzip recording and honours -Name and -MaxLogLines' {
        $gz = Join-Path $TestDrive 'r.jsonl.gz'
        $in = [System.IO.File]::OpenRead($script:Fixture)
        $outStream = [System.IO.File]::Create($gz)
        $zip = [System.IO.Compression.GZipStream]::new($outStream, [System.IO.Compression.CompressionMode]::Compress)
        $in.CopyTo($zip); $zip.Dispose(); $outStream.Dispose(); $in.Dispose()
        $r = Export-AzlSonarBundle -Recording $gz -OutDirectory (Join-Path $TestDrive 'gz-out') -Name 'my run' -MaxLogLines 1
        Split-Path -Leaf $r.Timeline | Should -Be 'my_run-timeline.json'
        $r.LogLines | Should -Be 1
    }
}
