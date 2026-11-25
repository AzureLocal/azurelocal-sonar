#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The event feed contract (hardening 2610, gap 7): docs/reference/events.schema.json describes the JSON Lines that Sonar
# records and replays and that other tools may emit. The fixture recordings and everything Sonar writes must validate.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:Schema = Join-Path -Path $script:SonarRepoRoot -ChildPath 'docs/reference/events.schema.json'
    function script:Test-Line { param([string]$Json) Test-Json -Json $Json -SchemaFile $script:Schema -ErrorAction SilentlyContinue }
}

Describe 'events.schema.json' {
    It 'is valid JSON and a JSON Schema document' {
        $doc = Get-Content -LiteralPath $script:Schema -Raw | ConvertFrom-Json -Depth 64
        $doc.'$schema' | Should -Match 'json-schema.org'
        $doc.required | Should -Contain 'k'
        $doc.required | Should -Contain 't'
    }

    It 'accepts every line of the sample recording' {
        $bad = 0
        foreach ($line in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/recording-sample.jsonl') | Where-Object { $_ })) {
            if (-not (Test-Line $line)) { $bad++ }
        }
        $bad | Should -Be 0
    }

    It 'accepts the lines of a publishable recording made from it' {
        $out = Join-Path $TestDrive 'pub.jsonl'
        Import-SonarTestModule
        $null = Export-AzlSonarPublishableRecording -Path (Join-Path $PSScriptRoot 'fixtures/recording-sample.jsonl') -Destination $out
        $bad = 0
        foreach ($line in (Get-Content -LiteralPath $out | Where-Object { $_ })) { if (-not (Test-Line $line)) { $bad++ } }
        $bad | Should -Be 0
    }

    It 'accepts a minimal feed another tool can emit: session, a keyframe, a delta, a log line, end' {
        $lines = @(
            '{"t":"2026-10-11T08:00:00.000Z","k":"session","format":1,"tool":"my-tool","version":"1.0.0","cluster":"clus01","config":{"clusterName":"clus01","nodes":[{"name":"node-01","seed":true}]}}'
            '{"t":"2026-10-11T08:00:01.000Z","k":"state","full":{"cluster":"clus01","phase":"validation","validation":{"status":"running","tree":[{"id":"0","name":"Validate Network","status":"running"}]}}}'
            '{"t":"2026-10-11T08:00:21.000Z","k":"state","ops":[["s",["validation","tree",0,"status"],"success"],["t",["warnings"],0],["d",["pollError"]]]}'
            '{"t":"2026-10-11T08:00:22.000Z","k":"log","lines":[{"seq":1,"time":"2026-10-11T08:00:22.000Z","file":"C:\\Logs\\a.log","level":"info","text":"hello"}]}'
            '{"t":"2026-10-11T08:00:30.000Z","k":"end"}'
        )
        foreach ($l in $lines) { (Test-Line $l) | Should -BeTrue -Because $l }
    }

    It 'rejects what the reader would skip: no time, no kind, a log without lines, a delta with an unknown op, a newer format' -TestCases @(
        @{ Json = '{"k":"end"}' }
        @{ Json = '{"t":"2026-10-11T08:00:30.000Z"}' }
        @{ Json = '{"t":"2026-10-11T08:00:30.000Z","k":"log"}' }
        @{ Json = '{"t":"2026-10-11T08:00:30.000Z","k":"state","ops":[["x",["a"],1]]}' }
        @{ Json = '{"t":"2026-10-11T08:00:30.000Z","k":"session","format":2}' }
        @{ Json = '{"t":"2026-10-11T08:00:30.000Z","k":"log","lines":[{"seq":0,"time":"x","file":"f","level":"loud","text":"t"}]}' }
    ) {
        (Test-Line $Json) | Should -BeFalse
    }

    It 'lets another tool add its own kind (the reader ignores it) and Sonar reads the feed' {
        (Test-Line '{"t":"2026-10-11T08:00:30.000Z","k":"ztp","machine":"m1","step":"InstallOs"}') | Should -BeTrue
        Import-SonarTestModule
        $feed = Join-Path $TestDrive 'feed.jsonl'
        @(
            '{"t":"2026-10-11T08:00:00.000Z","k":"session","format":1,"tool":"my-tool","cluster":"clus01"}'
            '{"t":"2026-10-11T08:00:01.000Z","k":"state","full":{"cluster":"clus01","phase":"provisioning"}}'
            '{"t":"2026-10-11T08:00:02.000Z","k":"ztp","step":"x"}'
            '{"t":"2026-10-11T08:00:30.000Z","k":"end"}'
        ) | Set-Content -LiteralPath $feed
        $r = InModuleScope AzlSonar -Parameters @{ P = $feed } { param($P) Read-AzlSonarRecording -Path $P }
        $r.Events.Count | Should -Be 3
        $r.Ignored | Should -Be 1
        $r.Cluster | Should -Be 'clus01'
    }
}

Describe 'events.schema.json: the toolkit feeds in the events folder (input to Sonar)' {
    BeforeAll {
        # A def of the schema as a schema of its own (Test-Json takes a root schema): the file's $defs travel with the $ref.
        function script:Test-Def {
            param([string]$Json, [string]$Def)
            $doc = Get-Content -LiteralPath $script:Schema -Raw | ConvertFrom-Json -Depth 64 -AsHashtable
            $root = [ordered]@{ '$schema' = $doc['$schema']; '$ref' = "#/`$defs/$Def"; '$defs' = $doc['$defs'] }
            Test-Json -Json $Json -Schema (ConvertTo-Json -InputObject $root -Depth 64) -ErrorAction SilentlyContinue
        }
        $script:ToolkitFixtures = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/toolkit-events'
    }

    It 'describes every line the toolkit writes to update-events.jsonl and precluster-plan-events.jsonl (its real output)' {
        $files = @(Get-ChildItem -LiteralPath $script:ToolkitFixtures -Filter '*.jsonl')
        $files.Count | Should -BeGreaterThan 4
        $bad = @()
        foreach ($file in $files) {
            foreach ($line in (Get-Content -LiteralPath $file.FullName | Where-Object { $_ })) { if (-not (Test-Def -Json $line -Def 'toolkitEvent')) { $bad += "$($file.Name): $line" } }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'rejects a line without the envelope and a level the toolkit never writes' -TestCases @(
        @{ Json = '{"node":"*","stage":"SolutionUpdate","state":"RunStarted"}' }
        @{ Json = '{"timestamp":"2026-11-24T21:16:07.2388664Z","node":"*","stage":"SolutionUpdate"}' }
        @{ Json = '{"timestamp":"2026-11-24T21:16:07.2388664Z","node":"*","stage":"SolutionUpdate","state":"RunStarted","level":"Fatal"}' }
    ) {
        (Test-Def -Json $Json -Def 'toolkitEvent') | Should -BeFalse
    }

    It 'describes the plan Sonar serves and refuses to call a plan pass or fail' {
        Import-SonarTestModule
        $lines = @(Get-Content -LiteralPath (Join-Path $script:ToolkitFixtures 'gate-plan.precluster-plan-events.jsonl'))
        $json = InModuleScope AzlSonar -Parameters @{ L = $lines } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarVerificationPlanEvent -Store $store -Line $x }
            ConvertTo-Json -InputObject (Get-AzlSonarVerificationPlanState -Store $store -Config ([pscustomobject]@{ armEventsPath = 'C:\ev\arm.jsonl' })) -Depth 8
        }
        (Test-Def -Json $json -Def 'verificationPlan') | Should -BeTrue
        $failing = ($json | ConvertFrom-Json -AsHashtable); $failing['status'] = 'fail'
        (Test-Def -Json (ConvertTo-Json -InputObject $failing -Depth 8) -Def 'verificationPlan') | Should -BeFalse
        $withVerdict = ($json | ConvertFrom-Json -AsHashtable); $withVerdict['verdict'] = 'Pass'
        (Test-Def -Json (ConvertTo-Json -InputObject $withVerdict -Depth 8) -Def 'verificationPlan') | Should -BeFalse
    }

    It 'describes the update events Sonar serves' {
        Import-SonarTestModule
        $lines = @(Get-Content -LiteralPath (Join-Path $script:ToolkitFixtures 'check-available.update-events.jsonl'))
        $json = InModuleScope AzlSonar -Parameters @{ L = $lines } {
            param($L)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarUpdateEvent -Store $store -Line $x }
            ConvertTo-Json -InputObject (Get-AzlSonarUpdateEventState -Store $store -Config ([pscustomobject]@{ updateEventsPath = 'x' })) -Depth 8
        }
        (Test-Def -Json $json -Def 'updateEventsState') | Should -BeTrue
    }

    It 'describes the post-deployment run Sonar serves for every real fixture, and refuses to call a Plan failed or red' {
        Import-SonarTestModule
        foreach ($name in 'plan-example', 'plan-passed', 'plan-warning', 'apply-passed', 'apply-failed') {
            $lines = @(Get-Content -LiteralPath (Join-Path $script:ToolkitFixtures "$name.post-deployment-events.jsonl"))
            $json = InModuleScope AzlSonar -Parameters @{ L = $lines } {
                param($L)
                $store = [hashtable]::Synchronized(@{})
                foreach ($x in $L) { Add-AzlSonarPostDeploymentEvent -Store $store -Line $x }
                ConvertTo-Json -InputObject (Get-AzlSonarPostDeploymentState -Store $store -Config ([pscustomobject]@{ armEventsPath = 'C:\ev\arm.jsonl' })) -Depth 8
            }
            (Test-Def -Json $json -Def 'postDeploymentState') | Should -BeTrue -Because $name
        }
        $planned = [ordered]@{ hasData = $true; status = 'failed'; kind = 'err'; mode = 'Plan' }
        (Test-Def -Json (ConvertTo-Json -InputObject $planned) -Def 'postDeploymentState') | Should -BeFalse
        $apply = [ordered]@{ hasData = $true; status = 'failed'; kind = 'err'; mode = 'Apply' }
        (Test-Def -Json (ConvertTo-Json -InputObject $apply) -Def 'postDeploymentState') | Should -BeTrue
        $stopped = [ordered]@{ hasData = $true; status = 'incomplete'; kind = 'warn'; mode = 'Plan' }
        (Test-Def -Json (ConvertTo-Json -InputObject $stopped) -Def 'postDeploymentState') | Should -BeTrue
    }
}
