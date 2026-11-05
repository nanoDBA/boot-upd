BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $tokens = $null
    $errors = $null
    $script:invokeAst = [Management.Automation.Language.Parser]::ParseFile($invokePath, [ref]$tokens, [ref]$errors)
    $errors | Should -BeNullOrEmpty
    $script:invokeText = Get-Content -LiteralPath $invokePath -Raw

    $function = $invokeAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-BootUpdateCohortPhase'
    }, $true)
    $function | Should -Not -BeNullOrEmpty -Because 'the cohort settles each phase through this function'
    . ([scriptblock]::Create($function.Extent.Text))

    <# The function's collaborators, replaced by recorders. Receive-Job and Remove-Job are
       plain functions here so a fake job object binds; the real cmdlets take [Job[]]. #>
    function Write-Log { param($Message, $Level = 'Info', $Visibility) $script:LogLines.Add([pscustomobject]@{ Message = $Message; Level = $Level }) }
    function Write-PhaseResult { param($Num, $Total, $Name, $Success, [switch]$Deferred, $Minutes, $Count) $script:PhaseResults.Add([pscustomobject]@{ Num = $Num; Name = $Name; Success = $Success; Minutes = $Minutes; Count = $Count }) }
    function Write-EventLogEntry { param($EventId, $Message) $script:EventLog.Add($Message) }
    function Invoke-PhaseHook { param($EventName) $script:Hooks.Add($EventName) }
    function Write-BootUpdateResultLines { param($Lines) foreach ($l in @($Lines)) { $script:Replayed.Add($l) } }
    function Write-ProviderTranscript { param($Provider, $Lines) }
    function Add-BootUpdateDeferredInventory { param($State, $Provider, $Scope, $Records) }
    function Receive-Job { param($Job, $ErrorAction) $script:JobResult }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction) $script:Removed.Add($Job.PhaseName) }

    function New-FakeJob {
        param([string]$Phase, [string]$State = 'Completed', [double]$Minutes = 3.2)
        $end = Get-Date
        return [pscustomobject]@{
            PhaseName = $Phase; State = $State
            StartedAt = $end.AddMinutes(-$Minutes); PSBeginTime = $end.AddMinutes(-$Minutes)
            PSEndTime = if ($State -in @('Completed', 'Failed', 'Stopped')) { $end } else { $null }
        }
    }
}

Describe 'Each parallel phase is settled on its own' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[object]]::new()
        $script:PhaseResults = [System.Collections.Generic.List[object]]::new()
        $script:EventLog = [System.Collections.Generic.List[string]]::new()
        $script:Hooks = [System.Collections.Generic.List[string]]::new()
        $script:Replayed = [System.Collections.Generic.List[string]]::new()
        $script:Removed = [System.Collections.Generic.List[string]]::new()
        $script:State = [pscustomobject]@{ NpmDone = $false; Summary = [pscustomobject]@{ Npm = 0; ActionsTriggered = 0 } }
        $script:Defn = @{ Name = 'Npm'; Flag = 'NpmDone'; Key = 'Npm' }
    }

    It 'logs DONE with the phase''s own duration and package count, in the sequential-phase format' {
        $script:JobResult = @{ Phase = 'Npm'; Success = $true; Count = 2; LogLines = @('Updating npm packages...') }
        $outcome = Complete-BootUpdateCohortPhase -Job (New-FakeJob -Phase Npm -Minutes 3.2) -PhaseDefinition $Defn -State $State -PhaseNum 7 -TotalPhases 12
        $outcome | Should -BeTrue
        $done = @($LogLines | Where-Object { $_.Message -match '^<<< \[parallel\] Npm - DONE' })
        $done.Count | Should -Be 1
        $done[0].Message | Should -Match '^<<< \[parallel\] Npm - DONE \(3\.2 min, 2 pkg\)$'
        $done[0].Level | Should -Be 'Info'
        $State.NpmDone | Should -BeTrue
        $State.Summary.Npm | Should -Be 2
        $PhaseResults.Count | Should -Be 1
        $PhaseResults[0].Num | Should -Be 7
        $PhaseResults[0].Minutes | Should -BeGreaterOrEqual 3.1
        $PhaseResults[0].Minutes | Should -BeLessOrEqual 3.3
        $EventLog[0] | Should -Match '^Npm complete: 2 packages in 3\.2 min \(parallel cohort\)$'
        $Hooks | Should -Be @('AfterNpm')
        $Replayed | Should -Be @('Updating npm packages...')
        $Removed | Should -Be @('Npm')
    }

    It 'logs a replayed error as FAILED; RETRY PENDING with the duration and leaves the flag false' {
        $script:JobResult = @{ Phase = 'Npm'; Success = $true; Count = 0; LogLines = @('[Error] npm exited with code 1') }
        $outcome = Complete-BootUpdateCohortPhase -Job (New-FakeJob -Phase Npm -Minutes 0.5) -PhaseDefinition $Defn -State $State -PhaseNum 7 -TotalPhases 12
        $outcome | Should -BeFalse
        $failed = @($LogLines | Where-Object { $_.Message -match '^<<< \[parallel\] Npm - FAILED; RETRY PENDING \(0\.5 min, 0 pkg\)$' })
        $failed.Count | Should -Be 1
        $failed[0].Level | Should -Be 'Error'
        $State.NpmDone | Should -BeFalse
        $EventLog.Count | Should -Be 0
        $Hooks | Should -Be @('AfterNpm')
    }

    It 'reports a job that never completed with its state and elapsed time, and makes no phase claim' {
        $script:JobResult = $null
        $outcome = Complete-BootUpdateCohortPhase -Job (New-FakeJob -Phase Npm -State Running -Minutes 45) -PhaseDefinition $Defn -State $State -PhaseNum 7 -TotalPhases 12
        $null -eq $outcome | Should -BeTrue -Because 'the caller must not count a phase that made no claim'
        $notComplete = @($LogLines | Where-Object { $_.Message -match 'Thread job did not complete \(state: Running\) after 45 min' })
        $notComplete.Count | Should -Be 1
        $notComplete[0].Level | Should -Be 'Error'
        $State.NpmDone | Should -BeFalse
        $PhaseResults.Count | Should -Be 0
        $Hooks.Count | Should -Be 0
        $Removed | Should -Be @('Npm') -Because 'a job past the cohort deadline is stopped, not left running'
    }

    It 'carries terminal-failure classification and attention details to the phase definition' {
        $script:JobResult = @{ Phase = 'Npm'; Success = $false; Count = 0; TerminalFailure = $true; AttentionDetails = @([pscustomobject]@{ Name = 'npm' }); LogLines = @() }
        $null = Complete-BootUpdateCohortPhase -Job (New-FakeJob -Phase Npm) -PhaseDefinition $Defn -State $State -PhaseNum 7 -TotalPhases 12
        $Defn.TerminalFailure | Should -BeTrue
        @($Defn.AttentionDetails).Count | Should -Be 1
    }
}

Describe 'The cohort logs as events occur, not after the slowest phase' {
    It 'logs STARTING for each phase as its job launches' {
        $invokeText | Should -Match ">>> \[parallel\] \`$\(\`$cp\.Name\) - STARTING"
    }
    It 'settles jobs inside the wait loop, so a finished phase is logged while others still run' {
        $loop = [regex]::Match($invokeText, '(?s)\$cohortSettled = \[System\.Collections\.Generic\.HashSet\[string\]\].*?\} while \(-not \$pastDeadline\)')
        $loop.Success | Should -BeTrue
        $loop.Value | Should -Match 'Complete-BootUpdateCohortPhase -Job \$job'
        $loop.Value | Should -Match 'Wait-BootUpdateUiInterval'
    }
    It 'names the phases still running at a fixed cadence' {
        $invokeText | Should -Match 'still running: \$running ---'
        $invokeText | Should -Match '\$script:CohortHeartbeatSeconds\s*=\s*300'
    }
}
