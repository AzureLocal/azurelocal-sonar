#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-SonarTestModule
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-10-10T18:10:00', [System.DateTimeKind]::Utc)
}

Describe 'ConvertTo-AzlSonarStepStatus' {
    It 'normalises <Raw> to <Expected>' -TestCases @(
        @{ Raw = 'Not Started'; Expected = 'notstarted' }
        @{ Raw = 'NotStarted'; Expected = 'notstarted' }
        @{ Raw = 'not_started'; Expected = 'notstarted' }
        @{ Raw = ''; Expected = 'notstarted' }
        @{ Raw = 'InProgress'; Expected = 'running' }
        @{ Raw = 'in progress'; Expected = 'running' }
        @{ Raw = 'RUNNING'; Expected = 'running' }
        @{ Raw = 'Success'; Expected = 'success' }
        @{ Raw = 'succeeded'; Expected = 'success' }
        @{ Raw = 'Completed'; Expected = 'success' }
        @{ Raw = 'Error'; Expected = 'error' }
        @{ Raw = 'Failed'; Expected = 'error' }
        @{ Raw = 'Skipped'; Expected = 'skipped' }
        @{ Raw = 'DeploymentSuccess'; Expected = 'success' }
        @{ Raw = 'DeploymentFailed'; Expected = 'error' }
        @{ Raw = 'DeploymentInProgress'; Expected = 'running' }
        @{ Raw = 'ValidationFailed'; Expected = 'error' }
        @{ Raw = 'Creating'; Expected = 'running' }
        @{ Raw = 'Canceled'; Expected = 'error' }
        @{ Raw = 'Paused'; Expected = 'unknown' }
    ) {
        param($Raw, $Expected)
        InModuleScope AzlSonar -Parameters @{ Raw = $Raw } { param($Raw) ConvertTo-AzlSonarStepStatus $Raw } | Should -Be $Expected
    }

    It 'treats $null as notstarted' {
        InModuleScope AzlSonar { ConvertTo-AzlSonarStepStatus $null } | Should -Be 'notstarted'
    }
}

Describe 'ConvertTo-AzlSonarStepTree' {
    Context 'the live validation shape' {
        BeforeAll {
            $script:tree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarValidationFixture) -Now $script:Now)
        }

        It 'returns one node per top-level step, in order' {
            $script:tree.Count | Should -Be 3
            $script:tree.ForEach({ $_.id }) | Should -Be @('0', '1', '2')
            $script:tree.ForEach({ $_.name }) | Should -Be @('Validate Network', 'Validate Hardware', 'Validate Active Directory')
        }

        It 'normalises the statuses and keeps the raw value' {
            $script:tree.ForEach({ $_.status }) | Should -Be @('success', 'running', 'notstarted')
            $script:tree.ForEach({ $_.rawStatus }) | Should -Be @('Success', 'InProgress', 'Not Started')
        }

        It 'has the documented keys' {
            @($script:tree[0].Keys) | Should -Be @('id', 'name', 'description', 'status', 'rawStatus', 'start', 'end', 'durationSeconds', 'errors', 'children')
        }

        It 'formats start and end as UTC ISO strings and leaves empty times null' {
            $script:tree[0].start | Should -Be '2026-10-10T18:00:00Z'
            $script:tree[0].end | Should -Be '2026-10-10T18:04:30Z'
            $script:tree[1].end | Should -BeNullOrEmpty
            $script:tree[2].start | Should -BeNullOrEmpty
        }

        It 'computes end - start for a finished step' {
            $script:tree[0].durationSeconds | Should -Be 270
        }

        It 'computes now - start for a running step' {
            # Started 18:04:30, Now 18:10:00.
            $script:tree[1].durationSeconds | Should -Be 330
        }

        It 'has no duration for a step that has not started' {
            $script:tree[2].durationSeconds | Should -BeNullOrEmpty
        }

        It 'has empty errors and children for flat validation steps' {
            @($script:tree[0].errors).Count | Should -Be 0
            @($script:tree[0].children).Count | Should -Be 0
        }
    }

    Context 'nested deployment steps' {
        BeforeAll {
            $script:deployNow = [datetime]::SpecifyKind([datetime]'2026-10-10T20:00:00', [System.DateTimeKind]::Utc)
            $script:dtree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarDeploymentFixture) -Now $script:deployNow)
        }

        It 'keeps the nesting' {
            $script:dtree.Count | Should -Be 3
            @($script:dtree[0].children).Count | Should -Be 3
            @($script:dtree[1].children).Count | Should -Be 2
            @($script:dtree[1].children[1].children).Count | Should -Be 2
            $script:dtree[1].children[1].children[0].id | Should -Be '1.1.0'
            $script:dtree[1].children[1].children[0].name | Should -Be 'Install MOC'
        }

        It 'collects exception[] strings as errors (blank entries dropped)' {
            $failed = $script:dtree[0].children[1]
            $failed.status | Should -Be 'error'
            @($failed.errors).Count | Should -Be 2
            $failed.errors[1] | Should -Be 'Node02 is not reachable.'
        }

        It 'computes running durations at every level' {
            $script:dtree[1].durationSeconds | Should -Be 2400            # 19:20 -> 20:00
            $script:dtree[1].children[1].durationSeconds | Should -Be 1200 # 19:40 -> 20:00
            $script:dtree[1].children[1].children[0].durationSeconds | Should -Be 1140
        }

        It 'never reports a negative duration (clock skew)' {
            $early = [datetime]::SpecifyKind([datetime]'2026-10-10T19:00:00', [System.DateTimeKind]::Utc)
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarDeploymentFixture) -Now $early)
            $tree[1].durationSeconds | Should -Be 0
        }
    }

    Context 'empty and odd input' {
        It 'returns nothing for an empty status object {}' {
            @(ConvertTo-AzlSonarStepTree -StatusObject ('{}' | ConvertFrom-Json) -Now $script:Now).Count | Should -Be 0
        }

        It 'returns nothing for an empty hashtable' {
            @(ConvertTo-AzlSonarStepTree -StatusObject @{} -Now $script:Now).Count | Should -Be 0
        }

        It 'returns nothing for $null' {
            @(ConvertTo-AzlSonarStepTree -StatusObject $null -Now $script:Now).Count | Should -Be 0
        }

        It 'returns nothing for a status with no steps' {
            @(ConvertTo-AzlSonarStepTree -StatusObject ([pscustomobject]@{ status = 'Success' }) -Now $script:Now).Count | Should -Be 0
        }

        It 'accepts an array of raw steps' {
            $steps = @(
                [pscustomobject]@{ name = 'a'; fullStepIndex = '0'; status = 'Success' }
                [pscustomobject]@{ name = 'b'; fullStepIndex = '1'; status = 'Error' }
            )
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $steps -Now $script:Now)
            $tree.ForEach({ $_.status }) | Should -Be @('success', 'error')
        }

        It 'maps an unknown status to unknown and keeps rawStatus' {
            $status = [pscustomobject]@{ steps = @([pscustomobject]@{ name = 'x'; fullStepIndex = '0'; status = 'Paused' }) }
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $status -Now $script:Now)
            $tree[0].status | Should -Be 'unknown'
            $tree[0].rawStatus | Should -Be 'Paused'
        }

        It 'generates ids and names when fullStepIndex and name are missing' {
            $status = [pscustomobject]@{ steps = @(
                    [pscustomobject]@{ status = 'Success'; steps = @([pscustomobject]@{ description = 'Only a description'; status = 'Success' }) }
                ) }
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $status -Now $script:Now)
            $tree[0].id | Should -Be '0'
            $tree[0].name | Should -Be 'Step 0'
            $tree[0].children[0].id | Should -Be '0.0'
            $tree[0].children[0].name | Should -Be 'Only a description'
        }

        It 'ignores placeholder dates before 1900' {
            $status = [pscustomobject]@{ steps = @([pscustomobject]@{ name = 'x'; status = 'Not Started'; startTimeUtc = '0001-01-01T00:00:00Z' }) }
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $status -Now $script:Now)
            $tree[0].start | Should -BeNullOrEmpty
        }

        It 'serialises to JSON with arrays kept as arrays' {
            $tree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarValidationFixture) -Now $script:Now)
            $json = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) ConvertTo-AzlSonarJson $Tree }
            $json | Should -BeLike '`[{"id":"0"*'
            $json | Should -BeLike '*"errors":`[`]*'
            $json | Should -BeLike '*"children":`[`]*'
        }
    }
}

Describe 'Measure-AzlSonarStepTree' {
    It 'counts every level by status' {
        $tree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarDeploymentFixture) -Now $script:Now)
        $counts = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Measure-AzlSonarStepTree -Tree $Tree }
        $counts.total | Should -Be 10
        $counts.success | Should -Be 4
        $counts.running | Should -Be 3
        $counts.notstarted | Should -Be 2
        $counts.error | Should -Be 1 -Because 'one nested child failed'
        $counts.unknown | Should -Be 0
    }

    It 'returns zero counts for an empty tree' {
        $counts = InModuleScope AzlSonar { Measure-AzlSonarStepTree -Tree @() }
        $counts.total | Should -Be 0
        @($counts.Keys) | Should -Be @('total', 'notstarted', 'running', 'success', 'error', 'skipped', 'unknown')
    }

    It 'counts unknown statuses' {
        $status = [pscustomobject]@{ steps = @([pscustomobject]@{ name = 'x'; status = 'Paused' }, [pscustomobject]@{ name = 'y'; status = 'Skipped' }) }
        $tree = @(ConvertTo-AzlSonarStepTree -StatusObject $status -Now $script:Now)
        $counts = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Measure-AzlSonarStepTree -Tree $Tree }
        $counts.unknown | Should -Be 1
        $counts.skipped | Should -Be 1
        $counts.total | Should -Be 2
    }
}

Describe 'Get-AzlSonarRollupStatus' {
    BeforeAll {
        function Get-Leaf([string]$Status) { [ordered]@{ id = '0'; name = 'n'; status = $Status; children = @() } }
    }

    It 'uses the reported status when present' {
        InModuleScope AzlSonar { Get-AzlSonarRollupStatus -RawStatus 'Success' -Tree @() } | Should -Be 'success'
        InModuleScope AzlSonar { Get-AzlSonarRollupStatus -RawStatus 'InProgress' -Tree @() } | Should -Be 'running'
    }

    It 'derives <Expected> from top-level steps <Statuses>' -TestCases @(
        @{ Statuses = @(); Expected = 'notstarted' }
        @{ Statuses = @('success', 'error'); Expected = 'error' }
        @{ Statuses = @('success', 'running'); Expected = 'running' }
        @{ Statuses = @('success', 'skipped'); Expected = 'success' }
        @{ Statuses = @('success', 'notstarted'); Expected = 'running' }
        @{ Statuses = @('notstarted', 'unknown'); Expected = 'unknown' }
        @{ Statuses = @('notstarted', 'notstarted'); Expected = 'notstarted' }
    ) {
        param($Statuses, $Expected)
        $tree = @(foreach ($s in $Statuses) { Get-Leaf $s })
        InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Get-AzlSonarRollupStatus -RawStatus $null -Tree $Tree } | Should -Be $Expected
    }
}

Describe 'Get-AzlSonarCurrentStep' {
    It 'returns the deepest running step with its path' {
        $tree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarDeploymentFixture) -Now $script:Now)
        $current = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Get-AzlSonarCurrentStep -Tree $Tree -Phase 'deployment' }
        $current.phase | Should -Be 'deployment'
        $current.stepId | Should -Be '1.1.0'
        $current.stepName | Should -Be 'Install MOC'
        $current.status | Should -Be 'running'
        $current.stepPath | Should -Be @('1', '1.1', '1.1.0')
        $current.stepNames | Should -Be @('Begin Cloud Deployment', 'Deploy Moc and ARB Stack', 'Install MOC')
    }

    It 'returns the running validation step' {
        $tree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarValidationFixture) -Now $script:Now)
        $current = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Get-AzlSonarCurrentStep -Tree $Tree -Phase 'validation' }
        $current.stepName | Should -Be 'Validate Hardware'
        $current.stepPath | Should -Be @('1')
    }

    It 'returns the last finished step when nothing runs' {
        $tree = @(ConvertTo-AzlSonarStepTree -StatusObject (Get-SonarValidationSuccessFixture) -Now $script:Now)
        $current = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Get-AzlSonarCurrentStep -Tree $Tree -Phase 'validation' }
        $current.stepName | Should -Be 'Validate Active Directory'
        $current.status | Should -Be 'success'
    }

    It 'prefers the deeper finished step when end times tie' {
        $tree = @(
            [ordered]@{ id = '0'; name = 'parent'; status = 'success'; start = '2026-10-10T18:00:00Z'; end = '2026-10-10T18:10:00Z'; children = @(
                    [ordered]@{ id = '0.0'; name = 'child'; status = 'success'; start = '2026-10-10T18:00:00Z'; end = '2026-10-10T18:10:00Z'; children = @() }
                ) }
        )
        $current = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Get-AzlSonarCurrentStep -Tree $Tree }
        $current.stepName | Should -Be 'child'
        $current.stepPath | Should -Be @('0', '0.0')
    }

    It 'returns an empty path for an empty tree' {
        $current = InModuleScope AzlSonar { Get-AzlSonarCurrentStep -Tree @() -Phase 'provisioning' }
        @($current.stepPath).Count | Should -Be 0
        $current.stepName | Should -BeNullOrEmpty
        $current.phase | Should -Be 'provisioning'
    }

    It 'returns an empty path when every step is not started' {
        $tree = @([ordered]@{ id = '0'; name = 'a'; status = 'notstarted'; start = $null; end = $null; children = @() })
        $current = InModuleScope AzlSonar -Parameters @{ Tree = $tree } { param($Tree) Get-AzlSonarCurrentStep -Tree $Tree }
        $current.stepName | Should -BeNullOrEmpty
    }
}

Describe 'Get-AzlSonarPhase' {
    BeforeAll {
        $script:someSteps = @([ordered]@{ id = '0'; name = 'a'; status = 'success'; children = @() })
    }

    It 'is provisioning when neither status has steps' {
        $phase = InModuleScope AzlSonar { Get-AzlSonarPhase -ValidationTree @() -ValidationStatus 'notstarted' -DeploymentTree @() -DeploymentStatus 'notstarted' }
        $phase.phase | Should -Be 'provisioning'
        $phase.activePhase | Should -Be 'provisioning'
    }

    It 'is <Expected> for validation <Status>' -TestCases @(
        @{ Status = 'running'; Expected = 'validation' }
        @{ Status = 'success'; Expected = 'validation' }
        @{ Status = 'error'; Expected = 'failed' }
    ) {
        param($Status, $Expected)
        $phase = InModuleScope AzlSonar -Parameters @{ T = $script:someSteps; S = $Status } { param($T, $S) Get-AzlSonarPhase -ValidationTree $T -ValidationStatus $S -DeploymentTree @() -DeploymentStatus 'notstarted' }
        $phase.phase | Should -Be $Expected
        $phase.activePhase | Should -Be 'validation'
    }

    It 'is <Expected> for deployment <Status>' -TestCases @(
        @{ Status = 'running'; Expected = 'deployment' }
        @{ Status = 'success'; Expected = 'done' }
        @{ Status = 'error'; Expected = 'failed' }
    ) {
        param($Status, $Expected)
        $phase = InModuleScope AzlSonar -Parameters @{ T = $script:someSteps; S = $Status } { param($T, $S) Get-AzlSonarPhase -ValidationTree $T -ValidationStatus 'success' -DeploymentTree $T -DeploymentStatus $S }
        $phase.phase | Should -Be $Expected
        $phase.activePhase | Should -Be 'deployment'
    }
}
