#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

# The ARM Validate and Deploy views: the event reader and store, the state builder, the config key, the log line.
# The fixture arm-deployment-events.sample.jsonl was written by the toolkit's own Write-AzlArmEvent (a Validate that passed,
# then a Deploy that failed at step 0.41, with a fake Azure and a fake clock; names are examples). No Azure, no node.

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Sample = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/arm-deployment-events.sample.jsonl'

    # One event line of the contract (docs/design/arm-validate-deploy.md section 11 of the toolkit).
    function global:New-ArmLine {
        param([string]$At, [string]$State, [string]$Node = '*', [string]$Step = '', [string]$Evidence = '', [string]$Level = 'Info', [string]$NextAction = '', [string]$Mode = 'ValidateAndDeploy', [string]$RunId = 'r1', [hashtable]$Extra = @{})
        $o = [ordered]@{ timestamp = $At; node = $Node; stage = 'ArmDeployment'; step = $Step; state = $State; evidence = $Evidence; level = $Level; nextAction = $NextAction; schemaVersion = '5.6.0'; runId = $RunId; mode = $Mode; cluster = 'c1' }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        $o | ConvertTo-Json -Compress -Depth 6
    }
    $script:T0 = [datetime]::SpecifyKind([datetime]'2026-11-07T12:00:00', 'Utc')
    function global:Get-ArmTime([double]$Minutes) { $script:T0.AddMinutes($Minutes).ToString('o', [cultureinfo]::InvariantCulture) }
    # Feeds lines to a store and returns the arm state (-Now is fixed so elapsed times are exact).
    function global:Get-ArmFromLine {
        param([string[]]$Line, [double]$NowMinutes = 60)
        InModuleScope AzlSonar -Parameters @{ L = $Line; N = $script:T0.AddMinutes($NowMinutes) } {
            param($L, $N)
            $store = [hashtable]::Synchronized(@{})
            foreach ($x in $L) { Add-AzlSonarArmEvent -Store $store -Line $x }
            Get-AzlSonarArmState -Store $store -Config ([pscustomobject]@{ armEventsPath = 'x' }) -Now $N
        }
    }
}

AfterAll {
    foreach ($f in 'New-ArmLine', 'Get-ArmTime', 'Get-ArmFromLine') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'ConvertFrom-AzlSonarArmEvent (the log line)' {
    It 'leads with the event UTC time and names the run, state, step, evidence and next action' {
        $line = New-ArmLine -At '2026-11-07T12:00:30.0000000Z' -State DeploymentFailed -Step '0.41.2' -Evidence 'Deployment failed' -Level Error -NextAction 'Do not validate again' -Extra @{ knownIssue = 'arc-device-id-name' }
        $r = InModuleScope AzlSonar -Parameters @{ L = $line } { param($L) ConvertFrom-AzlSonarArmEvent -Line $L }
        $r.file | Should -Be 'arm-events'
        $r.text | Should -Be '2026-11-07T12:00:30.000Z [arm] * DeploymentFailed (0.41.2): Deployment failed -> next: Do not validate again'
    }
    It 'tags a warning and names a node' {
        $line = New-ArmLine -At (Get-ArmTime 1) -State PreconditionChecked -Node n1 -Step ArcMachineNaming -Evidence 'device id' -Level Warning
        (InModuleScope AzlSonar -Parameters @{ L = $line } { param($L) ConvertFrom-AzlSonarArmEvent -Line $L }).text | Should -Match '\[arm\] n1 PreconditionChecked \(ArcMachineNaming\): device id \(warning\)$'
    }
    It 'skips what is not an event: garbage, a half line, no node or state, another stage' {
        foreach ($bad in '', 'not json', '{"node":"*"', '{"node":"*"}', '{"state":"RunStarted"}', '[1,2]', '{"node":"n1","state":"NodeStarted","stage":"OsConfiguration"}') {
            InModuleScope AzlSonar -Parameters @{ L = $bad } { param($L) ConvertFrom-AzlSonarArmEvent -Line $L } | Should -BeNullOrEmpty
        }
    }
    It 'reads a timestamp as UTC whatever the culture is' {
        $old = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]'de-DE'
            $e = InModuleScope AzlSonar -Parameters @{ L = (New-ArmLine -At '2026-11-07T12:00:01.5000000Z' -State RunStarted) } { param($L) ConvertFrom-AzlSonarArmLine -Line $L }
            $e.timestamp | Should -Be '2026-11-07T12:00:01.500Z'
        }
        finally { [cultureinfo]::CurrentCulture = $old }
    }
}

Describe 'The feed the toolkit wrote (a Validate that passed, a Deploy that failed at step 0.41)' {
    BeforeAll { $script:Real = Get-ArmFromLine -Line @(Get-Content -LiteralPath $script:Sample) }
    It 'reads every line of the real writer as an event' {
        $n = InModuleScope AzlSonar -Parameters @{ F = $script:Sample } { param($F) @(Get-Content -LiteralPath $F | ForEach-Object { ConvertFrom-AzlSonarArmLine -Line $_ } | Where-Object { $_ }).Count }
        $n | Should -Be (@(Get-Content -LiteralPath $script:Sample)).Count
    }
    It 'knows the run: mode, template, hash, approval, the failed end and the exit code' {
        $s = $script:Real
        $s.configured | Should -BeTrue
        $s.hasData | Should -BeTrue
        $s.run.mode | Should -Be 'ValidateAndDeploy'
        $s.run.template | Should -Be 'create-cluster'
        $s.run.parameterHash | Should -Be 'afe7afd61584'
        $s.run.state | Should -Be 'DeploymentFailed'
        $s.run.exitCode | Should -Be 1
        $s.run.approval.granted | Should -BeTrue
        $s.status | Should -Be 'error'
        $s.state | Should -Be 'failed'
        $s.activePhase | Should -Be 'deployment'
    }
    It 'validation passed with its 17 checks (the warning first) and its two steps' {
        $v = $script:Real.validation
        $v.status | Should -Be 'passed'
        $v.checkCounts.total | Should -Be 17
        $v.checkCounts.warning | Should -Be 1
        $v.tree[0].children[0].arm.check | Should -Be 'SbeConsistent'
        $v.stepCounts.total | Should -Be 2
        $v.elapsedSeconds | Should -Be 15
        $v.deploymentName | Should -Be 'azl-validate-afe7afd61584'
    }
    It 'deployment names the failing step 0.41.2, keeps 0.41 as its parent and carries the known issue and its hint' {
        $d = $script:Real.deployment
        $d.status | Should -Be 'failed'
        $d.failing.step | Should -Be '0.41.2'
        $d.knownIssue | Should -Be 'arc-device-id-name'
        $d.hint.id | Should -Be 'arc-device-id-name'
        $d.nextAction | Should -Match '^Known issue arc-device-id-name:'
        $steps = ($d.tree | Where-Object { $_.id -eq 'deployment.steps' }).children
        @($steps.id) | Should -Be @('0.40', '0.41')
        $steps[1].children[0].id | Should -Be '0.41.2'
        $steps[1].children[0].arm.failing | Should -BeTrue
        $steps[1].children[0].arm.hint | Should -Match 'device ID'
        $steps[1].errors[0] | Should -Match 'ParentResourceNotFound'
        $d.checkCounts.total | Should -Be 17
    }
    It 'puts the hint in the state hints and leaves the success of the validation alone' {
        @($script:Real.hints).Count | Should -Be 1
        $script:Real.hints[0].phase | Should -Be 'deployment'
        $script:Real.validation.kind | Should -Be 'success'
    }
}

Describe 'Add-AzlSonarArmEvent (the store)' {
    It 'a failed check before anything is submitted blocks the phase, failures first, with the next action' {
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate -Extra @{ nodes = @('n1', 'n2'); runMode = 'Validate' })
            (New-ArmLine -At (Get-ArmTime 0) -State PreconditionChecked -Step AzureContext -Evidence 'Signed in' -Mode Validate -Extra @{ name = 'AzureContext'; result = 'Passed' })
            (New-ArmLine -At (Get-ArmTime 0) -State PreconditionChecked -Node n2 -Step ArcMachineNaming -Evidence 'n2 is named abc-1' -Level Warning -Mode Validate -Extra @{ name = 'ArcMachineNaming'; result = 'Warning' })
            (New-ArmLine -At (Get-ArmTime 0) -State PreconditionChecked -Step Permissions -Evidence 'No write on role assignments' -Level Error -NextAction 'Grant User Access Administrator' -Mode Validate -Extra @{ name = 'Permissions'; result = 'Failed' })
            (New-ArmLine -At (Get-ArmTime 0) -State PlanCompleted -Level Error -Evidence '1 precondition(s) failed: Permissions.' -Mode Validate -Extra @{ failedPreconditions = 1; offline = $false })
            (New-ArmLine -At (Get-ArmTime 0) -State RunCompleted -Level Error -Mode Validate -Extra @{ exitCode = 1 })
        )
        $s = Get-ArmFromLine -Line $lines
        $s.validation.status | Should -Be 'blocked'
        $s.validation.kind | Should -Be 'error'
        $s.validation.checkCounts.failed | Should -Be 1
        $s.validation.nextAction | Should -Be 'Grant User Access Administrator'
        @($s.validation.tree[0].children.rawStatus) | Should -Be @('Failed', 'Warning', 'Passed')
        $s.validation.tree[0].children[0].arm.nextAction | Should -Be 'Grant User Access Administrator'
        $s.deployment.status | Should -Be 'notstarted'
        $s.activePhase | Should -Be 'validation'
        $s.hints[0].preventive | Should -BeTrue
        $s.hints[0].id | Should -Be 'arc-device-id-name'
    }
    It 'a Plan that found nothing wrong is planned, and does not hide an earlier passed validation' {
        $validate = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate -RunId a)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Validate -RunId a -Extra @{ from = 'Prepared'; to = 'Validating' })
            (New-ArmLine -At (Get-ArmTime 5) -State ValidationPassed -Mode Validate -RunId a -Evidence 'Validation succeeded.')
        )
        $plan = @(
            (New-ArmLine -At (Get-ArmTime 20) -State RunStarted -Mode Plan -RunId b)
            (New-ArmLine -At (Get-ArmTime 20) -State PreconditionChecked -Step AzureContext -Mode Plan -RunId b -Extra @{ name = 'AzureContext'; result = 'Passed' })
            (New-ArmLine -At (Get-ArmTime 20) -State PlanCompleted -Mode Plan -RunId b -Extra @{ failedPreconditions = 0; offline = $true })
            (New-ArmLine -At (Get-ArmTime 20) -State RunCompleted -Mode Plan -RunId b -Extra @{ exitCode = 0 })
        )
        (Get-ArmFromLine -Line $plan).validation.status | Should -Be 'planned'
        $both = Get-ArmFromLine -Line ($validate + $plan)
        $both.validation.status | Should -Be 'passed'
        $both.validation.checkCounts.total | Should -Be 1
    }
    It 'a later Validate run replaces the validation of an earlier one; a Deploy run keeps it and starts the deployment' {
        $first = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate -RunId a)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Validate -RunId a -Extra @{ to = 'Validating' })
            (New-ArmLine -At (Get-ArmTime 1) -State ValidationStep -Step '0.1' -Mode Validate -RunId a -Evidence 'A: Error - boom' -Level Error -Extra @{ status = 'error'; rawStatus = 'Error'; stepName = 'A'; depth = 0 })
            (New-ArmLine -At (Get-ArmTime 1) -State ValidationFailed -Step '0.1' -Level Error -Mode Validate -RunId a -Evidence 'Validation failed at step 0.1' -Extra @{ stepName = 'A'; status = 'Failed'; knownIssue = '' })
        )
        $second = @(
            (New-ArmLine -At (Get-ArmTime 10) -State RunStarted -Mode Validate -RunId b)
            (New-ArmLine -At (Get-ArmTime 10) -State RunStateChanged -Mode Validate -RunId b -Extra @{ to = 'Validating' })
        )
        $deploy = @(
            (New-ArmLine -At (Get-ArmTime 20) -State RunStarted -Mode Deploy -RunId c)
            (New-ArmLine -At (Get-ArmTime 20) -State RunStateChanged -Mode Deploy -RunId c -Extra @{ to = 'Deploying' })
        )
        (Get-ArmFromLine -Line $first).validation.status | Should -Be 'failed'
        $s2 = Get-ArmFromLine -Line ($first + $second)
        $s2.validation.status | Should -Be 'running'
        $s2.validation.stepCounts.total | Should -Be 0
        $s3 = Get-ArmFromLine -Line ($first + $deploy)
        $s3.validation.status | Should -Be 'failed'
        $s3.deployment.status | Should -Be 'running'
        $s3.activePhase | Should -Be 'deployment'
    }
    It 'a step is updated by its number in the order first seen; a failing validation lists its failed step first' {
        $step = { param($m, $id, $name, $status, $raw, $depth) New-ArmLine -At (Get-ArmTime $m) -State ValidationStep -Step $id -Mode Validate -Evidence "${name}: $raw" -Extra @{ status = $status; rawStatus = $raw; stepName = $name; depth = $depth } }
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Validate -Extra @{ to = 'Validating' })
            (& $step 1 '0.1' 'First' running InProgress 0)
            (& $step 2 '0.2' 'Second' running InProgress 0)
            (& $step 3 '0.1' 'First' success Success 0)
            (& $step 4 '0.2' 'Second' error Failed 0)
            (& $step 5 '0.3' 'Third' success Success 0)
        )
        $s = Get-ArmFromLine -Line $lines -NowMinutes 6
        $steps = ($s.validation.tree | Where-Object { $_.id -eq 'validation.steps' }).children
        @($steps.id) | Should -Be @('0.2', '0.1', '0.3')
        $steps[1].durationSeconds | Should -Be 120
        $s.validation.stepCounts.error | Should -Be 1
        $s.validation.current | Should -BeNullOrEmpty
        $s.validation.elapsedSeconds | Should -Be 360
    }
    It 'children are nested by the depth the run reports' {
        $step = { param($m, $id, $depth) New-ArmLine -At (Get-ArmTime $m) -State DeploymentStep -Step $id -Mode Deploy -Evidence "S${id}: Success" -Extra @{ status = 'success'; rawStatus = 'Success'; stepName = "S$id"; depth = $depth } }
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Deploy)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Deploy -Extra @{ to = 'Deploying' })
            (& $step 1 '1' 0), (& $step 1 '1.1' 1), (& $step 1 '1.1.1' 2), (& $step 1 '1.2' 1), (& $step 1 '2' 0)
        )
        $tree = (Get-ArmFromLine -Line $lines).deployment.tree[0].children
        @($tree.id) | Should -Be @('1', '2')
        @($tree[0].children.id) | Should -Be @('1.1', '1.2')
        @($tree[0].children[0].children.id) | Should -Be @('1.1.1')
    }
    It 'a refused Deploy keeps the earlier failure in view and says why nothing started' {
        $earlier = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Deploy -RunId a)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Deploy -RunId a -Extra @{ to = 'Deploying' })
            (New-ArmLine -At (Get-ArmTime 1) -State DeploymentStep -Step '0.41' -Mode Deploy -RunId a -Level Error -Evidence 'Arc: Error - x' -Extra @{ status = 'error'; rawStatus = 'Error'; stepName = 'Arc'; depth = 0 })
            (New-ArmLine -At (Get-ArmTime 1) -State DeploymentFailed -Step '0.41' -Level Error -Mode Deploy -RunId a -Extra @{ stepName = 'Arc'; knownIssue = 'arc-device-id-name' })
        )
        $refused = @(
            (New-ArmLine -At (Get-ArmTime 30) -State RunStarted -Mode Deploy -RunId b)
            (New-ArmLine -At (Get-ArmTime 30) -State PhaseRefused -Step '0.41' -Level Error -Mode Deploy -RunId b -Evidence 'The last failure is known issue arc-device-id-name.' -NextAction 'Fix the cause first.' -Extra @{ knownIssue = 'arc-device-id-name'; phase = 'Deploy' })
        )
        $d = (Get-ArmFromLine -Line ($earlier + $refused)).deployment
        $d.status | Should -Be 'refused'
        $d.carriedOver | Should -BeTrue
        $d.refused.nextAction | Should -Be 'Fix the cause first.'
        $d.hint.id | Should -Be 'arc-device-id-name'
        $d.stepCounts.error | Should -Be 1
    }
    It 'attached and resumed runs say so; an already validated run is passed with no step' {
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate)
            (New-ArmLine -At (Get-ArmTime 0) -State ValidationSkipped -Mode Validate -Extra @{ deploymentName = 'azl-validate-x' })
            (New-ArmLine -At (Get-ArmTime 0) -State ValidationPassed -Mode Validate -Extra @{ skipped = $true })
        )
        $v = (Get-ArmFromLine -Line $lines).validation
        $v.status | Should -Be 'passed'
        $v.skipped | Should -BeTrue
        $v.text | Should -Match 'already validated'
        $res = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Deploy)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Deploy -Extra @{ to = 'Resumed' })
            (New-ArmLine -At (Get-ArmTime 0) -State DeploymentResumed -Level Warning -Mode Deploy -Evidence 'resubmitted' -Extra @{ deploymentName = 'azl-deploy-x'; previous = 'Failed' })
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Deploy -Extra @{ to = 'Deploying' })
        )
        $d = (Get-ArmFromLine -Line $res).deployment
        $d.status | Should -Be 'running'
        $d.resumed.previous | Should -Be 'Failed'
        $d.text | Should -Match 'resumed'
    }
    It 'validate and approval: a good validation waits for approval in stop mode, then deploy checks go to the deployment' {
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted)
            (New-ArmLine -At (Get-ArmTime 0) -State PreconditionChecked -Step A -Extra @{ name = 'A'; result = 'Passed' })
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Extra @{ to = 'Validating' })
            (New-ArmLine -At (Get-ArmTime 5) -State RunStateChanged -Extra @{ to = 'ValidationPassed' })
            (New-ArmLine -At (Get-ArmTime 5) -State ValidationPassed)
            (New-ArmLine -At (Get-ArmTime 5) -State ApprovalRequested -Extra @{ approvalMode = 'stop' })
            (New-ArmLine -At (Get-ArmTime 5) -State RunStateChanged -Extra @{ to = 'AwaitingApproval' })
        )
        $s = Get-ArmFromLine -Line $lines
        $s.awaitingApproval | Should -BeTrue
        $s.state | Should -Be 'awaitingapproval'
        $s.run.approval.granted | Should -BeFalse
        $more = $lines + @(
            (New-ArmLine -At (Get-ArmTime 6) -State ApprovalGranted -Extra @{ approvalMode = 'none' })
            (New-ArmLine -At (Get-ArmTime 6) -State PreconditionChecked -Step B -Extra @{ name = 'B'; result = 'Failed' } -Level Error)
        )
        $t = Get-ArmFromLine -Line $more
        $t.validation.checkCounts.total | Should -Be 1
        $t.deployment.checkCounts.failed | Should -Be 1
        $t.deployment.status | Should -Be 'blocked'
    }
    It 'poll errors show on the running phase and clear when a step arrives' {
        $base = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Validate -Extra @{ to = 'Validating' })
            (New-ArmLine -At (Get-ArmTime 1) -State PollError -Level Warning -Mode Validate -Evidence 'Reading the validate status failed (2 in a row): 503' -Extra @{ consecutive = 2 })
        )
        $s = Get-ArmFromLine -Line $base
        $s.validation.pollErrors | Should -Be 2
        @($s.warnings)[0] | Should -Match '503'
        $ok = $base + (New-ArmLine -At (Get-ArmTime 2) -State ValidationStep -Step '0.1' -Mode Validate -Evidence 'A: InProgress' -Extra @{ status = 'running'; rawStatus = 'InProgress'; stepName = 'A'; depth = 0 })
        (Get-ArmFromLine -Line $ok).validation.pollErrors | Should -Be 0
    }
    It 'step 0.41 in error gets the device-ID hint even when the run matched no known issue' {
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Deploy)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Deploy -Extra @{ to = 'Deploying' })
            (New-ArmLine -At (Get-ArmTime 1) -State DeploymentStep -Step '0.41' -Level Error -Mode Deploy -Evidence 'X: Error' -Extra @{ status = 'error'; rawStatus = 'Error'; stepName = 'X'; depth = 0 })
            (New-ArmLine -At (Get-ArmTime 1) -State DeploymentFailed -Step '0.41' -Level Error -Mode Deploy -Extra @{ stepName = 'X'; knownIssue = '' })
        )
        $d = (Get-ArmFromLine -Line $lines).deployment
        $d.knownIssue | Should -Be 'arc-device-id-name-step-0-41'
        $d.hintSource | Should -Be 'step'
    }
    It 'an unknown known-issue id still shows a hint that names it' {
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Validate -Extra @{ to = 'Validating' })
            (New-ArmLine -At (Get-ArmTime 1) -State ValidationFailed -Level Error -Mode Validate -Extra @{ knownIssue = 'new-thing-2027' })
        )
        $h = (Get-ArmFromLine -Line $lines).validation.hint
        $h.id | Should -Be 'new-thing-2027'
        $h.text | Should -Match 'known-issues'
    }
    It 'has a hint for every known issue id of the toolkit (config/known-issues/arm-deployment.json)' {
        $ids = 'arc-device-id-name', 'arc-device-id-name-step-0-41', 'unsupported-os-version', 'registration-5901', 'role-assignment-already-exists', 'role-assignment-zombie', 'license-sync-after-failed-validate', 'ad-prerequisites', 'dns-resolution', 'vmswitch-not-bound'
        foreach ($id in $ids) {
            (InModuleScope AzlSonar -Parameters @{ I = $id } { param($I) $script:AzlSonarArmHint.Contains($I) }) | Should -BeTrue -Because "hint for $id"
        }
    }
    It 'never keeps a secret: a password in free text is masked in the state' {
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Validate)
            (New-ArmLine -At (Get-ArmTime 0) -State PreconditionChecked -Step KeyVaultSecrets -Level Error -Mode Validate -Evidence 'login failed password=Sup3rS3cret! for x' -NextAction 'access_token=abc123def456ghi' -Extra @{ name = 'KeyVaultSecrets'; result = 'Failed' })
        )
        $json = (Get-ArmFromLine -Line $lines) | ConvertTo-Json -Depth 12
        $json | Should -Not -Match 'Sup3rS3cret'
        $json | Should -Not -Match 'abc123def456ghi'
    }
    It 'keeps at most the step limit (2000; lowered here to keep the test quick) and ignores a line that is not an event' {
        $lines = @(
            (New-ArmLine -At (Get-ArmTime 0) -State RunStarted -Mode Deploy)
            (New-ArmLine -At (Get-ArmTime 0) -State RunStateChanged -Mode Deploy -Extra @{ to = 'Deploying' })
            'garbage'
        ) + @(1..60 | ForEach-Object { New-ArmLine -At (Get-ArmTime 1) -State DeploymentStep -Step "9.$_" -Mode Deploy -Evidence "S${_}: Success" -Extra @{ status = 'success'; rawStatus = 'Success'; stepName = "S$_"; depth = 0 } })
        $n = InModuleScope AzlSonar -Parameters @{ L = $lines } {
            param($L)
            $was = $script:AzlSonarArmMaxSteps
            $script:AzlSonarArmMaxSteps = 25
            try {
                $store = [hashtable]::Synchronized(@{})
                foreach ($x in $L) { Add-AzlSonarArmEvent -Store $store -Line $x }
                @($store['*deployment']['Steps']).Count
            }
            finally { $script:AzlSonarArmMaxSteps = $was }
        }
        $n | Should -Be 25
        (InModuleScope AzlSonar { $script:AzlSonarArmMaxSteps }) | Should -Be 2000
    }
}

Describe 'Get-AzlSonarArmState with no events' {
    It 'is waiting, with the config key saying whether a file is followed' {
        $off = InModuleScope AzlSonar { Get-AzlSonarArmState -Store $null -Config ([pscustomobject]@{ armEventsPath = '' }) }
        $on = InModuleScope AzlSonar { Get-AzlSonarArmState -Store @{} -Config ([pscustomobject]@{ armEventsPath = 'x' }) }
        $off.configured | Should -BeFalse
        $on.configured | Should -BeTrue
        foreach ($s in $off, $on) {
            $s.hasData | Should -BeFalse
            $s.state | Should -Be 'waiting'
            $s.status | Should -Be 'notstarted'
            $s.validation.status | Should -Be 'notstarted'
            $s.deployment.status | Should -Be 'notstarted'
            @($s.validation.tree).Count | Should -Be 0
        }
    }
}

Describe 'The reader, the config key and the server state' {
    It 'reads only complete lines and starts over when the file is replaced' {
        $f = Join-Path $TestDrive 'arm.jsonl'
        (New-ArmLine -At (Get-ArmTime 0) -State RunStarted) + "`n" + '{"node":"*","state":"Run' | Set-Content -LiteralPath $f -NoNewline
        $c = InModuleScope AzlSonar -Parameters @{ P = $f } { param($P) Read-AzlSonarArmEventChunk -Path $P -Offset 0 }
        @($c.Lines).Count | Should -Be 1
        $t = InModuleScope AzlSonar -Parameters @{ P = $f; O = ($c.Offset + 100000) } { param($P, $O) Read-AzlSonarArmEventChunk -Path $P -Offset $O }
        $t.Truncated | Should -BeTrue
        @($t.Lines).Count | Should -Be 1
        (InModuleScope AzlSonar -Parameters @{ P = (Join-Path $TestDrive 'none.jsonl') } { param($P) Read-AzlSonarArmEventChunk -Path $P }).Lines.Count | Should -Be 0
    }
    It 'the loop adds log lines, fills the store and counts the events' {
        $f = Join-Path $TestDrive 'loop.jsonl'
        Get-Content -LiteralPath $script:Sample | Set-Content -LiteralPath $f
        $r = InModuleScope AzlSonar -Parameters @{ P = $f } {
            param($P)
            $shared = [hashtable]::Synchronized(@{ Stop = $false; ArmEvents = [hashtable]::Synchronized(@{}); ArmInfo = [hashtable]::Synchronized(@{ Count = [long]0; LastEventAt = $null }) })
            Mock Add-AzlSonarLogLine { $script:armLogged += @($Line) }
            Mock Wait-AzlSonarInterval { $Shared.Stop = $true }
            $script:armLogged = @()
            Invoke-AzlSonarArmEventLoop -Shared $shared -Config ([pscustomobject]@{ armEventsPath = $P })
            @{ Logged = @($script:armLogged).Count; Info = $shared.ArmInfo.Count; Run = $shared.ArmEvents['*'].Events; Last = $shared.ArmInfo.LastEventAt }
        }
        $r.Logged | Should -Be 56
        $r.Info | Should -Be 56
        $r.Run | Should -Be 56
        $r.Last | Should -Be '2026-11-07T12:00:30Z'
    }
    It 'armEventsPath is validated, made absolute against the config file and settable' {
        $json = New-SonarConfigObject
        $json | Add-Member -NotePropertyName armEventsPath -NotePropertyValue './arm/events.jsonl' -Force
        $path = Join-Path $TestDrive 'arm-config.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
        $cfg = Read-AzlSonarConfig -Path $path
        $cfg.armEventsPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'arm/events.jsonl')))
        $json.armEventsPath = ''
        $bad = Join-Path $TestDrive 'arm-bad.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $bad
        { Read-AzlSonarConfig -Path $bad } | Should -Throw '*armEventsPath*'
    }
    It 'a master file follows the toolkit default report directory of the cluster' {
        $infra = Read-AzlSonarConfig -InfrastructureFile (Join-Path $script:SonarRepoRoot 'tests/fixtures/infrastructure.3node.yml') 3>$null
        $infra.armEventsPath | Should -Be (Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) ('azl-arm-' + $infra.clusterName)) 'arm-deployment-events.jsonl')
    }
    It 'the state before the first poll, and a poll with a store, both carry an arm object' {
        $path = Join-Path $TestDrive 'poll.json'
        ConvertTo-SonarConfigJson (New-SonarConfigObject) | Set-Content -LiteralPath $path
        $cfg = Read-AzlSonarConfig -Path $path
        $init = InModuleScope AzlSonar -Parameters @{ C = $cfg } { param($C) (Get-AzlSonarInitialState -Config $C).arm }
        $init.state | Should -Be 'waiting'
        $init.hasData | Should -BeFalse
    }
    It 'the Details sources and the not-set list know the ARM file' {
        $json = New-SonarConfigObject
        $path = Join-Path $TestDrive 'bare2.json'
        ConvertTo-SonarConfigJson $json | Set-Content -LiteralPath $path
        $f = InModuleScope AzlSonar -Parameters @{ C = (Read-AzlSonarConfig -Path $path) } { param($C) New-AzlSonarDetailFact -Config $C }
        @($f.notSet).setting | Should -Contain 'armEvents'
        $f.armEventsFile | Should -Be ''
    }
}

Describe 'Sonar reads the feed and nothing else about the run' {
    It 'never mentions the LCM account and never uses a credential in the ARM reader' {
        $src = Get-Content -LiteralPath (Join-Path $script:SonarModuleRoot 'Private/ArmEvents.ps1') -Raw
        $src | Should -Not -Match '(?i)\blcm[-_ ]?(user|account|admin)\b.*(Get-Credential|PSCredential|Invoke-Command|New-PSSession)'
        $src | Should -Not -Match 'Get-Credential|PSCredential|Invoke-Command|New-PSSession|Invoke-AzRestMethod|Invoke-RestMethod|Invoke-WebRequest'
        $src | Should -Not -Match 'Set-Content|Add-Content|Out-File|Remove-Item|New-Item'
    }
}
