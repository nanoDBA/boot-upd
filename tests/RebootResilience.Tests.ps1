BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'

    function Get-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        return $ast
    }

    function Get-FunctionText {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
        $function = $Ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
        $function | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        return $function.Extent.Text
    }

    $invokeAst = Get-ScriptAst $invokePath
    $deployAst = Get-ScriptAst $deployPath
    $invokeSource = Get-Content $invokePath -Raw

    foreach ($functionName in @(
        'ConvertTo-BootUpdateTimestampString',
        'Test-BootUpdateSameBootSession',
        'Test-BootUpdateMonotonicBootMoved',
        'Update-BootUpdateBootSession',
        'Get-BootUpdateBootReading',
        'Update-BootUpdateStateForBootSession',
        'Get-BootUpdateLaunchContract',
        'Test-PostUpdateHealth',
        'Get-BootUpdateBootSessionId',
        'Set-BootUpdateRebootCheckpoint',
        'ConvertFrom-PendingFileRenamePath',
        'Get-PendingFileRenameOperations',
        'Get-ActionablePendingFileRenameOperations',
        'Get-PendingFileCleanupDisplaySummary',
        'Write-PendingFileRenameAdvisory',
        'Resolve-BootUpdateCompletionDisposition',
        'Stop-BootUpdateAtRebootLimit',
        'Stop-BootUpdateAtRetryLimit',
        'Update-BootUpdateStagedRetryCount',
        'Get-NextMaintenanceWindowStart',
        'Get-WindowsUpdateVerificationScope',
        'Get-WindowsUpdateEnvironmentFingerprint',
        'Remove-WindowsUpdateAssessmentCache',
        'Set-WindowsUpdateAssessmentCache',
        'Invoke-WindowsUpdateOfflineAssessment',
        'Test-WindowsUpdateAssessmentRecord',
        'Test-WindowsUpdateAssessmentCache',
        'Test-WindowsUpdateZeroEvidence',
        'Get-DefenderCommandPath',
        'Get-DefenderPlatformAttentionDetail',
        'Get-WindowsUpdateInstallOutputSummary',
        'Test-WindowsUpdateServiceReady',
        'Test-WindowsUpdateConvergence',
        'Get-WindowsUpdateReofferedAfterSuccess',
        'Get-WindowsUpdateInstallHistory',
          'Format-NativeExitCode',
          'Get-InstallerExitSummary',
          'Get-ProcessTreeActivity',
          'Get-BootUpdateUptimeSeconds',
          'Get-BootUpdateMonotonicBootId',
          'Test-CrashRecovery',
          'Add-BootUpdatePendingCleanupRecord',
          'Update-BootUpdatePendingFileRenameSnapshot',
          'Get-ConfirmedPendingReboot',
          'Test-BootUpdateInstallerMutexHeld',
          'Wait-BootUpdateInstallerMutex',
          'New-BootUpdateStateV2',
          'Update-BootUpdateStateSchema',
          'Update-BootUpdateResumeIdentity',
          'Resolve-BootUpdateResumeAccount',
          'Update-BootUpdateUserIdentityWait',
          'Test-BootUpdateInteractiveUserPresent',
          'Get-BootUpdateRetryTriggerTime',
          'ConvertTo-BootUpdatePrincipalSid',
          'Get-WingetInventoryPackageIds',
          'Get-WingetOutputSummary',
          'Get-ChocolateyOutputSummary',
          'Complete-ChocolateyFailureClassification',
          'Test-WingetExitReconciled',
          'Get-WingetRemediationCommand',
          'Complete-WingetFailureClassification',
          'Register-WingetAggressiveRepairAttempt',
          'Invoke-WingetFailureQuarantine',
          'Get-WingetQuarantineRecords',
          'Set-WingetQuarantineRecords',
          'Get-WingetResolvedAbsentRecords',
          'Set-WingetResolvedAbsentRecords',
          'Resolve-WingetStaleAbsentPresentation',
          'Write-WingetScopeSummary',
          'Update-WingetPackages',
          'Test-PipFatalInterpreterEvidence',
          'Get-PipInterpreterAttentionDetail',
          'Update-PipPackages',
          'Update-ChocolateyPackages',
          'Set-BootUpdateClipboardText',
          'Stop-BootUpdateForManualAttention',
          'Write-BootUpdateRepairPlan',
          'Get-BootUpdateCompletionClaim',
          'Add-BootUpdateDeferredInventory',
          'Get-BootUpdateDeferredInventory',
          'Get-BootUpdateDeferredInventorySummary',
          'Get-BootUpdateCompletionNotification'
    )) {
        . ([scriptblock]::Create((Get-FunctionText $invokeAst $functionName)))
    }
    function Write-Log { param([string]$Message, [string]$Level, [string]$Visibility) }
    function Set-BootUpdateState { param($State) }
    function Write-ProviderTranscript { param($Provider, $Scope, $Lines) }
    function Invoke-PackageManagerWithTimeout { param($Name, $ScriptBlock, $ArgumentList, $IdleTimeoutMinutes, $HardTimeoutMinutes, $Status, $IncompleteRebootExitCodes, [switch]$DeferExitCodeReporting) }
    function Write-EventLogEntry { param($EventId, $EntryType, $Message) }
    function Send-CompletionNotification { param($Kind, $Title, $Message) }
    function Enable-BootUpdateNtfsCompression { param($Path) }
    function Show-CycleBanner { param($Title, $AnsiColor, $Info) }
    function Unregister-BootUpdateTask {
        $script:UnregisterCalls++
        if ($script:FailUnregister) { throw 'simulated task removal failure' }
    }
    function Invoke-BootUpdateBackgroundOperation { param($Name, $Status, $TimeoutMinutes, $ScriptBlock, $ArgumentList) }
}

Describe 'Concise provider diagnostics' {
    It 'records a sanitized normalized launch contract for every session' {
        $script:AggressiveRepair = $true
        $script:StagedRollout = $false
        $script:IncludeDriverUpdates = $false
        $script:IncludeFirmwareUpdates = $false
        $script:UpdateWsl = $false
        $script:UpdateContainers = $false
        $script:AllowMetered = $false
        $script:DisableSelfUpdate = $false
        $script:OutputMode = 'Normal'
        $script:IncludePatterns = @()
        $script:ExcludePatterns = @()
        foreach ($name in @('SkipPip','SkipNpm','SkipOffice365','SkipAwsTooling','SkipPowerShellModules','SkipScoop','SkipDotnetTools','SkipVscode','SkipDefender','SkipRestorePoint','SkipHealthCheck','SkipBitLocker')) {
            Set-Variable -Scope Script -Name $name -Value $false
        }
        $Force = $true

        $contract = Get-BootUpdateLaunchContract -IsFirstIteration $false -IsSystem $true

        $contract | Should -Be 'Launch contract | Mode: aggressive-repair | Origin: resume-system | Scope: machine | Output: Normal | Flags: Force,AggressiveRepair | Skips: none | Filters: include=0,exclude=0'
        $contract | Should -Not -Match '(?i)user(name)?|domain|[A-Z]:\\'
    }

    It 'serializes Winget scopes because App Installer state is shared' {
        $invokeSource | Should -Match '\$runWingetScopesInParallel\s*=\s*\$false'
        $invokeSource | Should -Match '0x8A150001'
    }

    It 'learns repeated blank Winget execution failures as terminal' {
        $state = [pscustomobject]@{}
        $first = Complete-WingetFailureClassification -State $state -ExecutionFailures @('machine:-1978335231:no-output')
        $second = Complete-WingetFailureClassification -State $state -ExecutionFailures @('machine:-1978335231:no-output')

        $first.TerminalFailure | Should -BeFalse
        $second.TerminalFailure | Should -BeTrue
        $second.Signature | Should -Be 'execution:machine:-1978335231:no-output'
    }

    It 'keeps the VS Code url.parse deprecation out of the primary log replay' {
        $invokeSource | Should -Match "Write-ProviderTranscript -Provider Vscode"
        $invokeSource | Should -Match "DEP0169.*url\\\.parse"
    }

    It 'clears a stale Winget repair plan without relying on an undefined install path' {
        $script:InstallDir = $TestDrive
        $state = [pscustomobject]@{}
        { Complete-WingetFailureClassification -State $state -Failures @() } | Should -Not -Throw
        $state.WingetFailureSignature | Should -Be ''
    }

    It 'extracts package failures and inventory notes from noisy Winget output' {
        $lines = @(
            '1 package(s) have pins that prevent upgrade.',
            '(1/4) Found Logitech G HUB [Logitech.GHUB] Version 2026.4',
            'Successfully installed',
            '(2/4) Found Pandoc [JohnMacFarlane.Pandoc] Version 3.10',
            '   Uninstall failed with exit code: 1605',
            '(3/4) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1612',
            '(4/4) Found Corsair iCUE5 Software [Corsair.iCUE.5] Version 5.48',
            'Installer failed with exit code: 3221226525',
            '4 package(s) have version numbers that cannot be determined.',
            '1 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
        )
        $summary = Get-WingetOutputSummary -Lines $lines
        $summary.Attempted | Should -Be 4
        $summary.Updated | Should -Be 1
        $summary.Failures.Count | Should -Be 2
        $summary.StaleAbsent.Count | Should -Be 1
        $summary.StaleAbsent[0].Id | Should -Be 'JohnMacFarlane.Pandoc'
        $summary.StaleAbsent[0].ObservedVersion | Should -Be '3.10'
        $summary.StaleAbsent[0].Summary | Should -Be 'product is not currently installed'
        $summary.Failures[0].Summary | Should -Be 'installation source is unavailable'
        $summary.Failures[1].Hex | Should -Be '0xC000041D'
        $summary.Pinned | Should -Be 1
        $summary.Unknown | Should -Be 4
        $summary.TechnologyBlocked | Should -Be 1
    }

    It 'parses only valid Winget IDs and rejects prose footer rows' {
        $inventory = Get-WingetInventoryPackageIds -Lines @(
            'Name                         Id                         Version Available Source',
            '--------------------------------------------------------------------------------',
            'Example App                  Example.App                1.2.3   1.2.4     winget',
            'Winget (machine/n numbers that cannot be determ) returned ... 0x8A150014'
        )

        $inventory.HeaderRecognized | Should -BeTrue
        $inventory.PackageIds | Should -Be @('Example.App')
        $inventory.MalformedRows | Should -Be 1
    }

    It 'fails closed when targeted inventory contains no syntactically valid IDs' {
        $inventory = Get-WingetInventoryPackageIds -Lines @(
            'Name                         Id                         Version Available Source',
            '--------------------------------------------------------------------------------',
            'Winget (machine/n numbers that cannot be determ) returned ... 0x8A150014'
        )

        $inventory.PackageIds | Should -BeNullOrEmpty
        $inventory.MalformedRows | Should -Be 1
    }

    It 'reconciles aggregate Winget failure when all remaining work is deferred inventory' {
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/2) Found Example App [Example.App] Version 1.0',
            '(2/2) Found Another App [Another.App] Version 2.0',
            '4 package(s) have version numbers that cannot be determined.',
            '2 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
        )

        $summary.Updated | Should -Be 0
        $summary.Failures | Should -BeNullOrEmpty
        Test-WingetExitReconciled -Summary $summary -ExitCode -1978335188 | Should -BeTrue
    }

    It 'does not throw when a parsed failure record has no package ID' {
        <# A targeted single-package upgrade (`winget upgrade --id X`) does not always
           print the "(N/M) Found Name [Id] Version V" header that bulk `--all`
           enumeration uses, so a failure line can be parsed with Id=''. Building a
           remediation command for that record must not crash the whole phase. #>
        $lines = @('Installer failed with exit code: 1603')
        $summary = Get-WingetOutputSummary -Lines $lines
        $summary.Failures.Count | Should -Be 1
        $summary.Failures[0].Id | Should -BeNullOrEmpty

        { Get-WingetRemediationCommand -PackageId $summary.Failures[0].Id -Code $summary.Failures[0].Code } | Should -Not -Throw
        Get-WingetRemediationCommand -PackageId $summary.Failures[0].Id -Code $summary.Failures[0].Code | Should -BeNullOrEmpty

        $state = [pscustomobject]@{}
        { Complete-WingetFailureClassification -State $state -Failures $summary.Failures } | Should -Not -Throw
        $classification = Complete-WingetFailureClassification -State $state -Failures $summary.Failures
        $classification.Details.Count | Should -Be 1
        $classification.Details[0].Command | Should -BeNullOrEmpty
    }

    It 'does not throw when Get-WingetRemediationCommand receives a null PackageId' {
        { Get-WingetRemediationCommand -PackageId $null -Code 1603 } | Should -Not -Throw
        Get-WingetRemediationCommand -PackageId $null -Code 1603 | Should -BeNullOrEmpty
    }

    It 'reconciles a per-package exit code distinct from the aggregate code when fully accounted' {
        <# Targeted single-package upgrades return their own native exit code rather
           than the bulk `--all` aggregate code (-1978335188 / 0x8A15002C); reconciliation
           must not be gated on that one hardcoded value. #>
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/1) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1605'
        )
        Test-WingetExitReconciled -Summary $summary -ExitCode -1978335184 | Should -BeTrue
    }

    It 'never reconciles the known Winget success/reboot-pending exit codes' {
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/1) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1605'
        )
        foreach ($code in @(0, 1641, 3010)) {
            Test-WingetExitReconciled -Summary $summary -ExitCode $code | Should -BeFalse
        }
    }

    It 'does not log a contradictory partial-failure error for a fully reconciled per-package stale record' {
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'resolved-absent-per-package.json'
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        $lines = @(
            '(1/1) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1605'
        )

        $summary = Write-WingetScopeSummary -Scope 'machine/Microsoft.WindowsPCHealthCheck' -Lines $lines -ExitCode -1978335184

        $summary.ExitReconciled | Should -BeTrue
        Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -match 'partial failure, retry required' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^\[RESOLVED\].*MSI 1605' }
    }

    It 'reconciles MSI 1605, records verified absence once, and suppresses identical repeats' {
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'resolved-absent.json'
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        $lines = @(
            '(1/2) Found Example App [Example.App] Version 2.0',
            'Successfully installed',
            '(2/2) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1605'
        )

        $summary = Write-WingetScopeSummary -Scope machine -Lines $lines -ExitCode -1978335188
        $repeat = Write-WingetScopeSummary -Scope machine -Lines $lines -ExitCode -1978335188

        $summary.ExitReconciled | Should -BeTrue
        $repeat.ExitReconciled | Should -BeTrue
        $summary.Failures | Should -BeNullOrEmpty
        $summary.StaleAbsent.Count | Should -Be 1
        $script:CurrentWingetFailures.Count | Should -Be 0
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^\[RESOLVED\].*MSI 1605.*identical repeats will stay quiet' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match 'identical MSI 1605 stale-inventory result suppressed' -and $Visibility -eq 'Debug' }
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -match '^\[(STALE|install|remove|suppress)\]' }
        Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -match 'partial failure, retry required' }
        $record = @(Get-Content $script:WingetResolvedAbsentPath -Raw | ConvertFrom-Json)
        $record.Count | Should -Be 1
        $record[0].PackageId | Should -Be 'Microsoft.WindowsPCHealthCheck'
        $record[0].Scope | Should -Be 'machine'
        $record[0].ObservedVersion | Should -Be '4.0'
        $record[0].OutcomeKey | Should -Be 'microsoft.windowspchealthcheck|machine|1605|4.0|msi-unknown-product'
        $record[0].Evidence | Should -Be 'MSI_ERROR_UNKNOWN_PRODUCT'
        ($record[0].PSObject.Properties.Name -join ',') | Should -Not -Match '(?i)user|domain|path'
    }

    It 'invalidates remembered absence when the package later succeeds' {
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'resolved-absent-invalidate.json'
        Set-WingetResolvedAbsentRecords -Records @([pscustomobject]@{
            SchemaVersion=2; PackageId='Microsoft.WindowsPCHealthCheck'; Name='Windows PC Health Check'; Scope='machine'
            FailureCode=1605; ObservedVersion='4.0'; OutcomeKey='microsoft.windowspchealthcheck|machine|1605|4.0|msi-unknown-product'
            VerifiedAbsentAtUtc='2026-07-22T00:00:00Z'; Evidence='MSI_ERROR_UNKNOWN_PRODUCT'
        })
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        $lines = @(
            '(1/1) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Successfully installed'
        )

        $summary = Write-WingetScopeSummary -Scope machine -Lines $lines -ExitCode 0

        $summary.Updated | Should -Be 1
        @(Get-WingetResolvedAbsentRecords).Count | Should -Be 0
        Should -Invoke Write-Log -ParameterFilter { $Message -match 'invalidated 1 resolved-absence record' -and $Visibility -eq 'Debug' }
    }

    It 'reports a changed MSI 1605 version once and replaces the old signature' {
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'resolved-absent-version-change.json'
        Set-WingetResolvedAbsentRecords -Records @([pscustomobject]@{
            SchemaVersion=2; PackageId='Microsoft.WindowsPCHealthCheck'; Name='Windows PC Health Check'; Scope='machine'
            FailureCode=1605; ObservedVersion='4.0'; OutcomeKey='microsoft.windowspchealthcheck|machine|1605|4.0|msi-unknown-product'
            VerifiedAbsentAtUtc='2026-07-22T00:00:00Z'; Evidence='MSI_ERROR_UNKNOWN_PRODUCT'
        })
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }

        $summary = Write-WingetScopeSummary -Scope machine -Lines @(
            '(1/1) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.1',
            'Uninstall failed with exit code: 1605'
        ) -ExitCode -1978335188

        $summary.ExitReconciled | Should -BeTrue
        $records = @(Get-WingetResolvedAbsentRecords)
        $records.Count | Should -Be 1
        $records[0].ObservedVersion | Should -Be '4.1'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^\[RESOLVED\]' }
    }

    It 'does not claim resolution when durable persistence fails' {
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'resolved-absent-fail.json'
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        Mock Set-WingetResolvedAbsentRecords { throw 'simulated persistence failure' }
        $lines = @(
            '(1/1) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1605'
        )

        $summary = Write-WingetScopeSummary -Scope machine -Lines $lines -ExitCode -1978335188

        $summary.ExitReconciled | Should -BeTrue
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -match '^\[RESOLVED\]' }
        Should -Invoke Write-Log -ParameterFilter { $Message -match 'could not persist.*retaining the recovery choices' }
        Should -Invoke Write-Log -ParameterFilter { $Message -match '^\[STALE\]' }
    }

    It 'does not circularly ask Winget inventory to disprove its own stale record' {
        $invokeSource | Should -Not -Match 'Winget-verify-absent'
        $invokeSource | Should -Match 'MSI_ERROR_UNKNOWN_PRODUCT'
    }

    It 'does not reconcile 1605 when another attempted package is unaccounted for' {
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/2) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1605'
        )
        Test-WingetExitReconciled -Summary $summary -ExitCode -1978335188 | Should -BeFalse
    }

    It 'defers generic Winget exit warnings until structured output is classified' {
        $adapter = Get-FunctionText $invokeAst 'Invoke-PackageManagerWithTimeout'
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        $adapter | Should -Match 'DeferExitCodeReporting'
        $adapter | Should -Match '\$failed -and -not \$DeferExitCodeReporting'
        ([regex]::Matches($winget, '-DeferExitCodeReporting')).Count | Should -BeGreaterOrEqual 4
    }

    It 'completes the Winget phase when MSI 1605 is the only aggregate exception' {
        $script:PackageTimeoutMinutes = 30
        $script:ExcludePatterns = @()
        $script:IncludePatterns = @()
        $script:AggressiveRepair = $false
        $script:CurrentState = [pscustomobject]@{}
        $script:InstallDir = $TestDrive
        Mock Get-Command { [pscustomobject]@{ Source='C:\Program Files\WindowsApps\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        Mock Invoke-PackageManagerWithTimeout {
            if ($Name -match 'machine') {
                return @{
                    Output=@(
                        '(1/2) Found Example App [Example.App] Version 2.0',
                        'Successfully installed',
                        '(2/2) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
                        'Uninstall failed with exit code: 1605'
                    )
                    TimedOut=$false; Failed=$true; ExitCode=-1978335188; RebootRequired=$false
                }
            }
            return @{ Output=@('No installed package found matching input criteria'); TimedOut=$false; Failed=$false; ExitCode=0; RebootRequired=$false }
        }

        $result = Update-WingetPackages -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Count | Should -Be 1
        $result.TerminalFailure | Should -BeFalse
        $script:CurrentWingetFailures | Should -BeNullOrEmpty
        Should -Invoke Invoke-PackageManagerWithTimeout -Times 2 -ParameterFilter { $DeferExitCodeReporting }
    }

    It 'completes the Winget phase when remaining inventory is deferred' {
        $script:PackageTimeoutMinutes = 30
        $script:ExcludePatterns = @()
        $script:IncludePatterns = @()
        $script:AggressiveRepair = $false
        $script:CurrentState = [pscustomobject]@{}
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:InstallDir = $TestDrive
        Mock Get-Command { [pscustomobject]@{ Source='C:\Program Files\WindowsApps\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        Mock Invoke-PackageManagerWithTimeout {
            return @{
                Output=@(
                    '(1/2) Found Example App [Example.App] Version 1.0',
                    '(2/2) Found Another App [Another.App] Version 2.0',
                    '4 package(s) have version numbers that cannot be determined.',
                    '2 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
                )
                TimedOut=$false; Failed=$true; ExitCode=-1978335188; RebootRequired=$false
            }
        }

        $result = Update-WingetPackages -Confirm:$false

        $result.Success | Should -BeTrue
        $result.TerminalFailure | Should -BeFalse
        $script:CurrentWingetFailures | Should -BeNullOrEmpty
    }

    It 'recognizes restart-application success and hexadecimal installer failures' {
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/2) Found Example Chat [Example.Chat] Version 2.0',
            'Successfully installed. Restart the application to complete the upgrade.',
            '(2/2) Found Example System App [Example.System] Version 3.0',
            'Installer failed with exit code: 0x80070005 : Access is denied.'
        )

        $summary.Attempted | Should -Be 2
        $summary.Updated | Should -Be 1
        $summary.SuccessfulIds | Should -Be @('Example.Chat')
        $summary.Failures.Count | Should -Be 1
        $summary.Failures[0].Id | Should -Be 'Example.System'
        $summary.Failures[0].Code | Should -Be 2147942405
        $summary.Failures[0].Summary | Should -Be 'access is denied'
    }

    It 'classifies an elevated user-scope upgrade block as scope-blocked, not a failure' {
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/1) Found Syncthing [Syncthing.Syncthing] Version 2.1.2',
            'Successfully verified installer hash',
            'Extracting archive...',
            'Successfully extracted archive',
            'The package installed for user scope cannot be uninstalled when running with administrator privileges.'
        )

        $summary.Attempted | Should -Be 1
        $summary.Updated | Should -Be 0
        $summary.Failures | Should -BeNullOrEmpty
        $summary.ScopeBlocked.Count | Should -Be 1
        $summary.ScopeBlocked[0].Id | Should -Be 'Syncthing.Syncthing'
        $summary.ScopeBlocked[0].ObservedVersion | Should -Be '2.1.2'
        $summary.Recognized | Should -BeTrue
    }

    It 'reconciles the aggregate exit when every attempted package is scope-blocked' {
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/1) Found Syncthing [Syncthing.Syncthing] Version 2.1.2',
            'The package installed for user scope cannot be uninstalled when running with administrator privileges.'
        )
        Test-WingetExitReconciled -Summary $summary -ExitCode -1978335188 | Should -BeTrue
    }

    It 'does not reconcile when a scope-blocked package coexists with an unaccounted failure' {
        $summary = Get-WingetOutputSummary -Lines @(
            '(1/2) Found Syncthing [Syncthing.Syncthing] Version 2.1.2',
            'The package installed for user scope cannot be uninstalled when running with administrator privileges.',
            '(2/2) Found Example App [Example.App] Version 2.0',
            'Installer failed with exit code: 1603'
        )
        Test-WingetExitReconciled -Summary $summary -ExitCode -1978335188 | Should -BeFalse
    }

    It 'logs scope-blocked remediation without queueing a retry' {
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'resolved-absent-scope-blocked.json'
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        $lines = @(
            '(1/1) Found Syncthing [Syncthing.Syncthing] Version 2.1.2',
            'The package installed for user scope cannot be uninstalled when running with administrator privileges.'
        )

        $summary = Write-WingetScopeSummary -Scope user -Lines $lines -ExitCode -1978335188

        $summary.ExitReconciled | Should -BeTrue
        $script:CurrentWingetFailures.Count | Should -Be 0
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^\[BLOCKED\].*user-scope.*defers it rather than retrying' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^\[user\] Upgrade from a normal non-elevated session: winget upgrade --id Syncthing\.Syncthing' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^\[machine\] Or reinstall machine-scope.*--scope machine' }
        Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -match 'partial failure, retry required' }
    }

    It 'withholds remediation commands for scope-blocked packages with unsafe identifiers' {
        $script:CurrentWingetFailures = [Collections.Generic.List[object]]::new()
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'resolved-absent-unsafe-id.json'
        Mock Write-ProviderTranscript { }
        Mock Write-Log { }
        $lines = @(
            '(1/1) Found Weird App [Weird&App;Id] Version 1.0',
            'The package installed for user scope cannot be uninstalled when running with administrator privileges.'
        )

        $null = Write-WingetScopeSummary -Scope user -Lines $lines -ExitCode -1978335188

        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^\[BLOCKED\]' }
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -match '^\[(user|machine)\]' }
    }

    It 'uses targeted machine inventory to avoid retrying a user-scope success' {
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        $winget | Should -Match 'successfulPackageIds'
        $winget | Should -Match "scope -eq 'machine'.*successfulPackageIds.Count -gt 0"
        $winget | Should -Match 'already succeeded in user scope during this run'
        $winget | Should -Match 'refusing a duplicate --all mutation'
    }

    It 'creates paste-ready remediation only from safe package identifiers' {
        Get-WingetRemediationCommand -PackageId 'JohnMacFarlane.Pandoc' |
            Should -Be 'winget install --id JohnMacFarlane.Pandoc -e --source winget --force --accept-source-agreements --accept-package-agreements'
        Get-WingetRemediationCommand -PackageId 'Microsoft.WindowsPCHealthCheck' -Code 1612 |
            Should -Be 'winget repair --id Microsoft.WindowsPCHealthCheck -e --source winget --force --accept-source-agreements --accept-package-agreements'
        Get-WingetRemediationCommand -PackageId 'Corsair.iCUE.5' -Code 3221226525 |
            Should -Be 'winget install --id Corsair.iCUE.5 -e --source winget --force --accept-source-agreements --accept-package-agreements'
        Get-WingetRemediationCommand -PackageId 'safe; Remove-Item C:\' | Should -BeNullOrEmpty
    }

    It 'escalates only an identical Winget failure signature that repeats' {
        $state = [pscustomobject]@{ WingetFailureSignature=''; WingetFailureRepeatCount=0 }
        $failure = [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612; Hex='0x0000064C' }
        (Complete-WingetFailureClassification -State $state -Failures @($failure)).TerminalFailure | Should -BeFalse
        (Complete-WingetFailureClassification -State $state -Failures @($failure)).TerminalFailure | Should -BeTrue
        $changed = [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525; Hex='0xC000041D' }
        (Complete-WingetFailureClassification -State $state -Failures @($changed)).TerminalFailure | Should -BeFalse
    }

    It 'registers each aggressive Winget repair signature only once' {
        $state = [pscustomobject]@{ WingetAggressiveRepairSignatures=@() }

        Register-WingetAggressiveRepairAttempt -State $state -Signature 'Corsair.iCUE.5:3221226525' |
            Should -BeTrue
        Register-WingetAggressiveRepairAttempt -State $state -Signature 'Corsair.iCUE.5:3221226525' |
            Should -BeFalse
        Register-WingetAggressiveRepairAttempt -State $state -Signature 'Microsoft.WindowsPCHealthCheck:1612' |
            Should -BeTrue
        @($state.WingetAggressiveRepairSignatures).Count | Should -Be 2
    }

    It 'classifies Winget failures before deciding whether to run aggressive repair' {
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        foreach ($repairIndex in [regex]::Matches($winget, 'Invoke-WingetAggressiveRepair') | ForEach-Object Index) {
            $classificationIndex = $winget.LastIndexOf('Complete-WingetFailureClassification', $repairIndex)
            $classificationIndex | Should -BeGreaterThan -1
            $classificationIndex | Should -BeLessThan $repairIndex
        }
        $winget | Should -Match 'identical failure signature already attempted; verification only'
    }

    It 'quarantines every persistent Winget failure with reversible blocking pins' {
        $script:WingetQuarantinePath = Join-Path $TestDrive 'all-pinned-quarantine.json'
        $state = [pscustomobject]@{ WingetQuarantines=@() }
        $failures = @(
            [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612 },
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525 }
        )
        $script:pinArguments = @()
        Mock Invoke-PackageManagerWithTimeout {
            $script:pinArguments += ,@($ArgumentList)
            [pscustomobject]@{ ExitCode=0; TimedOut=$false; Failed=$false; Output=@('Pin added') }
        }
        Mock Write-ProviderTranscript { }

        $result = Invoke-WingetFailureQuarantine -WingetPath 'C:\winget.exe' -State $state `
            -Signature 'Corsair.iCUE.5:3221226525|Microsoft.WindowsPCHealthCheck:1612' -Failures $failures

        $result.AllPinned | Should -BeTrue
        @($result.PinnedIds).Count | Should -Be 2
        @($state.WingetQuarantines).Count | Should -Be 2
        @((Get-WingetQuarantineRecords)).Count | Should -Be 2
        @($script:pinArguments | ForEach-Object { $_[1] }) | Should -Contain 'Corsair.iCUE.5'
        @($script:pinArguments | ForEach-Object { $_[1] }) | Should -Contain 'Microsoft.WindowsPCHealthCheck'
        foreach ($record in $state.WingetQuarantines) {
            $record.PinCommand | Should -Be "winget pin add --id $($record.PackageId) -e --blocking --force --disable-interactivity"
            $record.UnpinCommand | Should -Be "upd uq $($record.PackageId)"
            $record.NativeUnpinCommand | Should -Be "winget pin remove --id $($record.PackageId) -e --disable-interactivity"
            $record.FailureSignature | Should -Not -BeNullOrEmpty
            $record.PinnedAt | Should -Not -BeNullOrEmpty
        }
        Assert-MockCalled Invoke-PackageManagerWithTimeout -Times 2 -Exactly
    }

    It 'withholds Winget quarantine success if any terminal failure was not pinned' {
        $script:WingetQuarantinePath = Join-Path $TestDrive 'partial-quarantine.json'
        $state = [pscustomobject]@{ WingetQuarantines=@() }
        $failures = @(
            [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612 },
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525 }
        )
        Mock Invoke-PackageManagerWithTimeout {
            if ($ArgumentList[1] -eq 'Corsair.iCUE.5') {
                return [pscustomobject]@{ ExitCode=1; TimedOut=$false; Failed=$true; Output=@('Pin failed') }
            }
            [pscustomobject]@{ ExitCode=0; TimedOut=$false; Failed=$false; Output=@('Pin added') }
        }
        Mock Write-ProviderTranscript { }

        $result = Invoke-WingetFailureQuarantine -WingetPath 'C:\winget.exe' -State $state `
            -Signature 'repeat' -Failures $failures

        $result.AllPinned | Should -BeFalse
        @($state.WingetQuarantines).Count | Should -Be 1
        $state.WingetQuarantines[0].PackageId | Should -Be 'Microsoft.WindowsPCHealthCheck'
    }

    It 'writes a durable plan with explanations outside a valid cmd copy block' {
        $script:InstallDir = $TestDrive
        Mock Set-BootUpdateClipboardText { $true }
        $items = @(
            [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612; Hex='0x0000064C'; Command='winget repair --id Microsoft.WindowsPCHealthCheck -e --force' },
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525; Hex='0xC000041D'; Command='winget install --id Corsair.iCUE.5 -e --force' }
        )
        $result = Write-BootUpdateRepairPlan -Items $items
        $path = $result.Path
        $result.ClipboardCopied | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeTrue
        $lines = Get-Content -LiteralPath $path
        $blockStart = [array]::IndexOf($lines,'COPY/PASTE BLOCK — ELEVATED COMMAND PROMPT') + 1
        $block = @($lines | Select-Object -Skip $blockStart)
        @($block | Where-Object { $_ -notmatch '^(?:REM(?:\s|$)|winget\s|upd$)' }).Count | Should -Be 0
        ($block -join "`n") | Should -Match 'winget repair --id Microsoft\.WindowsPCHealthCheck'
        ($block -join "`n") | Should -Match 'winget install --id Corsair\.iCUE\.5'
    }

    It 'times out a blocked clipboard helper and disposes it without losing the repair plan' {
        $fakeInput = [pscustomobject]@{}
        $fakeInput | Add-Member ScriptMethod WriteLine { param($value) }
        $fakeInput | Add-Member ScriptMethod Close { }
        $fake = [pscustomobject]@{ StandardInput=$fakeInput; ExitCode=0; Killed=$false; Disposed=$false }
        $fake | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $false }
        $fake | Add-Member ScriptMethod Kill { param($tree) $this.Killed = $true }
        $fake | Add-Member ScriptMethod Dispose { $this.Disposed = $true }

        Set-BootUpdateClipboardText -Value 'C:\repair-plan.txt' -TimeoutMilliseconds 100 -ProcessFactory { $fake } |
            Should -BeFalse
        $fake.Killed | Should -BeTrue
        $fake.Disposed | Should -BeTrue
    }

    It 'reports a durable repair plan even when clipboard delivery is unavailable' {
        $script:InstallDir = $TestDrive
        Mock Set-BootUpdateClipboardText { $false }
        $item = [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=1; Hex='0x00000001'; Command='winget install --id Corsair.iCUE.5 -e' }
        $result = Write-BootUpdateRepairPlan -Items @($item)

        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $result.ClipboardCopied | Should -BeFalse
    }

    It 'renders signed provider HRESULTs in recognizable hexadecimal form' {
        Format-NativeExitCode -Code -1978335188 | Should -Be '0x8A15002C'
    }

    It 'keeps raw provider chatter out of the primary structured log path' {
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        $choco = Get-FunctionText $invokeAst 'Update-ChocolateyPackages'
        $winget | Should -Match 'Write-WingetScopeSummary'
        $choco | Should -Match 'Write-ProviderTranscript'
        $winget | Should -Not -Match 'foreach \(\$line in \$jr\.Lines\)[\s\S]*?Write-Log \$line'
        $choco | Should -Not -Match 'Write-Log \$_'
    }

    It 'fails closed when a parallel Winget child process cannot start' {
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        $winget | Should -Match 'StartFailed = \$startFailed'
        $winget | Should -Match 'if \(\$jr\.StartFailed\)[\s\S]*?\$anyTimeout = \$true[\s\S]*?continue'
    }
}

Describe 'Do-no-harm service health assessment' {
    It 'does not mutate services and accepts expected or policy-managed stopped states' {
        $services = @{ W32Time='Stopped'; WinDefend='Stopped'; Spooler='Stopped'; Dnscache='Running'; EventLog='Running' }
        $startModes = @{ W32Time='Manual'; WinDefend='Manual'; Spooler='Disabled'; Dnscache='Auto'; EventLog='Auto' }
        $result = Test-PostUpdateHealth -CriticalServices @($services.Keys) `
            -ServiceProvider { param($name) [pscustomobject]@{ Status=$services[$name] } } `
            -ConfigurationProvider { param($name) [pscustomobject]@{ StartMode=$startModes[$name] } } `
            -DefenderStatusProvider { [pscustomobject]@{ AMRunningMode='Passive'; AntivirusEnabled=$false } }

        $result.AllHealthy | Should -BeTrue
        $result.ExpectedStopped | Should -Contain 'W32Time'
        $result.PolicyManaged | Should -Contain 'WinDefend'
        $result.PolicyManaged | Should -Contain 'Spooler'
        $result.MutationsAttempted | Should -Be 0
        (Get-FunctionText $invokeAst 'Test-PostUpdateHealth') | Should -Not -Match 'Start-Service|Stop-Service|Set-Service|Start-Job'
    }

    It 'reports stopped active Defender and core resolver services without changing them' {
        $services = @{ WinDefend='Stopped'; Dnscache='Stopped'; W32Time='Stopped'; Spooler='Stopped' }
        $result = Test-PostUpdateHealth -CriticalServices @($services.Keys) `
            -ServiceProvider { param($name) [pscustomobject]@{ Status=$services[$name] } } `
            -ConfigurationProvider { param($name) [pscustomobject]@{ StartMode='Auto' } } `
            -DefenderStatusProvider { [pscustomobject]@{ AMRunningMode='Normal'; AntivirusEnabled=$true } }

        $result.AllHealthy | Should -BeFalse
        $result.FailedServices | Should -Contain 'WinDefend'
        $result.FailedServices | Should -Contain 'Dnscache'
        $result.FailedServices | Should -Contain 'W32Time'
        $result.FailedServices | Should -Contain 'Spooler'
        $result.MutationsAttempted | Should -Be 0
    }

    It 'separates provider triggers from verified update counts' {
        (Get-FunctionText $invokeAst 'Update-Office365') | Should -Match 'Count\s*=\s*0;\s*Triggered\s*=\s*1'
        (Get-FunctionText $invokeAst 'Update-VscodeExtensions') | Should -Match 'Count\s*=\s*\$count;\s*Triggered\s*=\s*1'
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $cycle | Should -Match 'verified updates'
        $cycle | Should -Match 'updater action\(s\) triggered'
    }
}

Describe 'BitLocker reboot targeting' {
    It 'queries and suspends only the Windows OS volume' {
        $text = Get-FunctionText $invokeAst 'Suspend-BitLockerForReboot'
        $text | Should -Match '\$osDrive = \[IO\.Path\]::GetPathRoot\(\$env:SystemRoot\)'
        $text | Should -Match 'Get-BitLockerVolume -MountPoint \$osDrive'
        $text | Should -Match '\$osVolume \| Suspend-BitLocker -RebootCount 1'
        $text | Should -Match 'protection is not currently On'
        $text | Should -Not -Match 'foreach \(\$vol in \$protectedVolumes\)'
    }
}

Describe 'Delayed and explicit reboot evidence' {
    It 'keeps routine cleanup out of Normal warnings while retaining compact and diagnostic evidence' {
        $script:LastPendingFileCleanupFingerprint = ''
        $operations = @(
            [pscustomobject]@{ IsBlocking=$false; Category='PackageManagementPrototypeCleanup'; Fingerprint='AAA111AAA111' },
            [pscustomobject]@{ IsBlocking=$false; Category='PackageManagementPrototypeCleanup'; Fingerprint='BBB222BBB222' }
        )
        Mock Write-Log { }

        Write-PendingFileRenameAdvisory -Operations $operations -Context 'before mutation'

        Should -Invoke Write-Log -Times 0 -ParameterFilter { $Level -eq 'Warn' }
        Should -Invoke Write-Log -Times 1 -ParameterFilter {
            $Level -eq 'Info' -and $Visibility -eq 'Verbose' -and
            $Message -match 'PackageManagementPrototypeCleanup=2' -and $Message -notmatch 'AAA111|BBB222'
        }
        Should -Invoke Write-Log -Times 1 -ParameterFilter {
            $Level -eq 'Info' -and $Visibility -eq 'Debug' -and
            $Message -match 'AAA111AAA111,BBB222BBB222'
        }
    }

    It 'translates internal pending-cleanup categories into plain completion language' {
        $operations = @(
            [pscustomobject]@{ Category='PackageManagementPrototypeCleanup' },
            [pscustomobject]@{ Category='PackageManagementPrototypeCleanup' }
        )

        Get-PendingFileCleanupDisplaySummary -Operations $operations |
            Should -Be 'legacy PackageManagement provider cleanup (2 delete requests)'
    }

    It 'ignores disposable PackageManagement prototype deletes and preserves real rename pairs' {
        $priorWindir = $env:windir
        try {
            $env:windir = 'C:\Windows'
            $entries = @(
                '\??\C:\Windows\SystemTemp\ChocolateyPrototype-2.8.5.130\1', '',
                '\??\C:\Program Files\Vendor\old.dll', '\??\C:\Program Files\Vendor\new.dll',
                '\??\C:\Windows\System32\pending.tmp', ''
            )
            $operations = @(Get-ActionablePendingFileRenameOperations -Entries $entries)
            $operations.Count | Should -Be 2
            $operations[0].Source | Should -Be 'C:\Program Files\Vendor\old.dll'
            $operations[0].Destination | Should -Be 'C:\Program Files\Vendor\new.dll'
            $operations[1].Source | Should -Be 'C:\Windows\System32\pending.tmp'
            $operations[1].Destination | Should -BeNullOrEmpty
        } finally { $env:windir = $priorWindir }
    }

    It 'normalizes modern numbered Session Manager prefixes' {
        ConvertFrom-PendingFileRenamePath '*1\??\C:\Program Files (x86)\Microsoft\EdgeUpdate\1.3.249.3' |
            Should -Be 'C:\Program Files (x86)\Microsoft\EdgeUpdate\1.3.249.3'
        ConvertFrom-PendingFileRenamePath '*2\??\C:\Temp\pending.tmp' |
            Should -Be 'C:\Temp\pending.tmp'
        ConvertFrom-PendingFileRenamePath '!\??\C:\Temp\replacement.tmp' |
            Should -Be 'C:\Temp\replacement.tmp'
    }

    It 'downgrades application cleanup across vendors but preserves protected Windows deletes' {
        $entries = @(
            '*1\??\C:\Program Files (x86)\Microsoft\EdgeUpdate\1.3.249.3', '',
            '*1\??\C:\Program Files\Dropbox\DropboxRecovery\scoped_dir16816_1351404682\UpdaterSetup.exe', '',
            '*2\??\D:\OneDrive\Company\stale.sync', '',
            '\??\C:\Program Files\UnfamiliarVendor\Updater\old.bin', '',
            '\??\C:\Windows\System32', ''
        )
        $operations = @(Get-PendingFileRenameOperations -Entries $entries)
        $operations.Count | Should -Be 5
        $operations[0].Category | Should -Be 'EdgeUpdateCleanup'
        $operations[0].IsBlocking | Should -BeFalse
        $operations[1].Category | Should -Be 'DropboxRecoveryCleanup'
        $operations[1].IsBlocking | Should -BeFalse
        $operations[2].Category | Should -Be 'CloudStorageCleanup'
        $operations[2].IsBlocking | Should -BeFalse
        $operations[3].Category | Should -Be 'ApplicationCleanup'
        $operations[3].IsBlocking | Should -BeFalse
        $operations[4].Category | Should -Be 'ProtectedWindowsDelete'
        $operations[4].IsBlocking | Should -BeTrue
        @($operations.Fingerprint | Where-Object { $_ -notmatch '^[0-9A-F]{12}$' }).Count | Should -Be 0
    }

    It 'keeps every rename or replacement blocking regardless of vendor' {
        $operations = @(Get-PendingFileRenameOperations -Entries @(
            '*1\??\D:\Google Drive\old.dll',
            '*2\??\D:\Google Drive\new.dll'
        ))
        $operations.Count | Should -Be 1
        $operations[0].Category | Should -Be 'FileReplacement'
        $operations[0].IsBlocking | Should -BeTrue
    }

    It 'does not ignore a PackageManagement prototype rename with a real destination' {
        $priorWindir = $env:windir
        try {
            $env:windir = 'C:\Windows'
            $operations = @(Get-ActionablePendingFileRenameOperations -Entries @(
                '\??\C:\Windows\SystemTemp\ChocolateyPrototype-2.8.5.130\1',
                '\??\C:\Windows\System32\not-disposable.dll'
            ))
            $operations.Count | Should -Be 1
        } finally { $env:windir = $priorWindir }
    }

    It 'does not use broad PackageManagement inventory probes that discover legacy providers' {
        $invokeSource | Should -Not -Match '(?m)(?<![-\w])Get-Package\b'
        $invokeSource | Should -Not -Match '(?m)(?<![-\w])Find-Package\b'
        $invokeSource | Should -Not -Match '(?m)(?<![-\w])Get-PackageProvider\b'
        $invokeSource | Should -Match "PackageManagement/OneGet's legacy"
    }

    It 'requires two clean registry probes separated by an animated settle interval' {
        $text = Get-FunctionText $invokeAst 'Get-ConfirmedPendingReboot'
        ([regex]::Matches($text, 'Test-PendingReboot')).Count | Should -Be 2
        $text | Should -Match 'RebootSignalSettleSeconds'
        $text | Should -Match 'Wait-BootUpdateUiInterval'
        $text | Should -Match 'Watching for delayed Windows reboot signals'
    }

    It 'uses the Windows Update Agent API as authoritative reboot evidence' {
        $detector = Get-FunctionText $invokeAst 'Test-PendingReboot'
        $installer = Get-FunctionText $invokeAst 'Install-WindowsUpdates'
        $detector | Should -Match 'Microsoft\.Update\.SystemInfo'
        $detector | Should -Match 'Windows Update Agent API reports RebootRequired'
        $installer | Should -Match 'BOOTUPDATE_WU_REBOOT\|Microsoft\.Update\.SystemInfo'
        $installer | Should -Match "Source='WindowsUpdate-SystemInfo'"
        $installer | Should -Match 'ExplicitRebootRequests = @\(\$script:ExplicitRebootRequests\)'
    }

    It 'preserves native 3010 and 1641 as successful reboot requests' {
        $text = Get-FunctionText $invokeAst 'Invoke-PackageManagerWithTimeout'
        $text | Should -Match 'BOOTUPDATE_NATIVE_EXIT'
        $text | Should -Match '\$effectiveExitCode -in @\(1641, 3010\)'
        $text | Should -Match '\$script:ExplicitRebootRequests\.Add'
        $text | Should -Match 'notin @\(0, 1641, 3010\)'
    }

    It 'treats Chocolatey 350 and 1604 as incomplete reboot barriers rather than generic failures' {
        $choco = Get-FunctionText $invokeAst 'Update-ChocolateyPackages'
        $runner = Get-FunctionText $invokeAst 'Invoke-PackageManagerWithTimeout'
        ([regex]::Matches($choco, 'IncompleteRebootExitCodes @\(350,1604\)')).Count | Should -Be 3
        $runner | Should -Match 'incompleteRebootExit'
        $runner | Should -Match 'stopped incomplete for reboot'
        $runner | Should -Match '\$failed = .*notin @\(0, 1641, 3010\)'
    }

    It 'uses confirmed reboot evidence for the final decision' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$pending = if \(\$WhatIfPreference\) \{'
        $text | Should -Match '\} else \{ Get-ConfirmedPendingReboot -Context ''after updates'' \}'
        <# -WhatIf must still skip the probe, and must now say that it skipped it rather
           than leaving the manifest to read the silence as "found nothing" (-h2z0). #>
        $text | Should -Match "Add-BootUpdatePendingCleanupRecord -Context 'after updates' -Observation 'phase-skipped'"
    }

    It 'also requires two clean probes before the first mutating phase' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$pending = @\(Get-ConfirmedPendingReboot -Context ''before mutation''\)'
        $text.IndexOf("`$pending = @(Get-ConfirmedPendingReboot -Context 'before mutation')") |
            Should -BeLessThan $text.IndexOf('Update-WingetPackages')
    }

    It 'preserves successful provider checkpoints across reboot instead of rerunning everything' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        ([regex]::Matches($text, 'Set-BootUpdateRebootCheckpoint')).Count | Should -Be 2
        $text | Should -Not -Match '\$state\.WingetDone = \$false; \$state\.ChocolateyDone = \$false'
        $text | Should -Not -Match 'foreach \(\$flag in .*WingetDone.*\) \{ \$state\.\$flag = \$false \}'
        $text | Should -Match 'Windows Update has its own identity-aware'

        $state = [pscustomobject]@{
            WingetDone=$true; ChocolateyDone=$true; WindowsUpdateDone=$false; AwsToolingDone=$false
            PipDone=$true; NpmDone=$false; Office365Done=$false; PowerShellModulesDone=$false
            ScoopDone=$false; DotnetToolsDone=$false; VscodeDone=$false; DefenderDone=$false
            DriverFirmwareDone=$false; WslDone=$false; ContainersDone=$false
            LastRebootSignals='old'; LastPhaseStarted='WindowsUpdate'; LastPhaseTimestamp='now'
            Phase='WindowsUpdate'; LastPreflightNetworkAt='now'; LastPreflightNetworkOk=$true
        }
        $completed = @(Set-BootUpdateRebootCheckpoint -State $state -SignalKey 'WUA' -ClearPhaseIntent)
        $completed | Should -Contain 'WingetDone'
        $completed | Should -Contain 'ChocolateyDone'
        $completed | Should -Contain 'PipDone'
        $state.WingetDone | Should -BeTrue
        $state.ChocolateyDone | Should -BeTrue
        $state.WindowsUpdateDone | Should -BeFalse
        $state.Phase | Should -Be 'Rebooting'
        $state.LastRebootSignals | Should -Be 'WUA'
        $state.LastPhaseStarted | Should -BeNullOrEmpty
        $state.LastPreflightNetworkOk | Should -BeNullOrEmpty
    }
}

Describe 'Bounded Windows Update service readiness' {
    BeforeEach {
        $WhatIfPreference = $false
        Mock Write-Log { }
    }

    It 'limits service recovery to 30 seconds and leaves only Windows Update incomplete on timeout' {
        Mock Invoke-BootUpdateBackgroundOperation {
            [pscustomobject]@{ Output=@(); Failed=$true; TimedOut=$true }
        }

        Test-WindowsUpdateServiceReady | Should -BeFalse
        Should -Invoke Invoke-BootUpdateBackgroundOperation -Times 1 -ParameterFilter {
            $Name -eq 'Preparing Windows Update service' -and $TimeoutMinutes -eq 0.5
        }
        Should -Invoke Write-Log -Times 1 -ParameterFilter {
            $Message -match 'Other providers are unaffected; only Windows Update will retry'
        }
    }

    It 'accepts only a successful ready marker' {
        Mock Invoke-BootUpdateBackgroundOperation {
            [pscustomobject]@{ Output=@('BOOTUPDATE_WU_SERVICE|READY'); Failed=$false; TimedOut=$false }
        }

        Test-WindowsUpdateServiceReady | Should -BeTrue
    }

    It 'treats an indefinitely StartPending service as a Windows Update-only retry' {
        Mock Invoke-BootUpdateBackgroundOperation {
            [pscustomobject]@{
                Output=@('BOOTUPDATE_WU_SERVICE|STARTPENDING')
                Failed=$true
                TimedOut=$true
            }
        }

        Test-WindowsUpdateServiceReady | Should -BeFalse
        Should -Invoke Invoke-BootUpdateBackgroundOperation -Times 1 -ParameterFilter {
            $TimeoutMinutes -eq 0.5
        }
        Should -Invoke Write-Log -Times 1 -ParameterFilter {
            $Message -match 'Other providers are unaffected; only Windows Update will retry'
        }
    }

    It 'keeps global preflight read-only and shows elapsed progress' {
        $preflight = Get-FunctionText $invokeAst 'Test-PreFlightChecks'
        $preflight | Should -Not -Match 'Start-Service'
        $preflight | Should -Match 'Windows Update phase'
        $preflight | Should -Match 'elapsed.*TotalSeconds'
        $preflight | Should -Match 'Write-BootUpdateProgress'
    }

    It 'treats a stopped Windows Update service as normal and warns only when it is Disabled' {
        <# wuauserv ships demand-start and trigger-registered; Microsoft's service guidance
           lists it as Manual, and the WUA COM API starts it on the first method call. So
           Stopped is the resting state of essentially every idle Windows 10/11 machine.
           Warning on it made all of them look degraded and buried Disabled, which is the
           one state that genuinely blocks servicing. #>
        $preflight = Get-FunctionText $invokeAst 'Test-PreFlightChecks'
        $preflight | Should -Match "StartType -eq 'Disabled'"
        $preflight | Should -Match 'normal idle state'
        <# The only -Level Warn in the service block must be the Disabled branch. A regression
           here is silent: the run still works, it just cries wolf on every healthy machine. #>
        $serviceBlock = [regex]::Match($preflight, '(?s)Get-Service wuauserv.*?catch \{[^}]*\}').Value
        $serviceBlock | Should -Not -BeNullOrEmpty
        ([regex]::Matches($serviceBlock, '-Level Warn')).Count |
            Should -Be 2 -Because 'one warning for Disabled, one for a failed observation, and none for a resting service'
    }

    It 'bounds escalated component recovery and records remediation only after verified recovery' {
        $repair = Get-FunctionText $invokeAst 'Repair-WindowsUpdateComponents'
        $install = Get-FunctionText $invokeAst 'Install-WindowsUpdates'
        $repair | Should -Match "Invoke-BootUpdateBackgroundOperation -Name 'Resetting Windows Update components'"
        $repair | Should -Match '-TimeoutMinutes 0\.5'
        $repair | Should -Not -Match '\b(?:Start|Stop)-Service\b'
        $repair | Should -Match 'BOOTUPDATE_WU_RESET_COMPLETE\|READY'
        $install | Should -Match '(?s)\$resetSucceeded = Repair-WindowsUpdateComponents.*?if \(\$resetSucceeded -and -not \$WhatIfPreference\).*?New-Item'
    }
}

Describe 'Truthful reboot safety limit' {
    It 'checks the reboot budget only after confirmed pending evidence exists' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $guard = Get-FunctionText $invokeAst 'Stop-BootUpdateAtRebootLimit'
        $cycle | Should -Not -Match '\$state\.Iteration -gt \$MaxIterations'
        ([regex]::Matches($cycle, 'Stop-BootUpdateAtRebootLimit')).Count | Should -Be 2
        $guard | Should -Match '\$State\.RebootCount -lt \$script:MaxIterations'
        $guard | Should -Match "Phase = 'LimitReached'"
        $guard | Should -Match 'LimitRebootSignals = \$evidence'
        $guard | Should -Not -Match 'Clear-BootUpdateState|Invoke-Hook'
    }

    It 'allows the final reboot to converge and preserves exact evidence only when still pending' {
        $script:MaxIterations = 5
        $script:StatePath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.state.json'
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $signal = [pscustomobject]@{ Source='CBS'; Detail='RebootPending key present' }
        $state = [pscustomobject]@{
            RebootCount=4; Phase='Rebooting'; StartTime='2026-07-20T09:00:00Z'
            LastRebootSignals=$null; LimitReachedAt=$null; LimitReason=$null; LimitRebootSignals=@()
        }

        (Stop-BootUpdateAtRebootLimit -State $state -PendingSignals @($signal) -Context 'before update phases') |
            Should -BeFalse
        $state.RebootCount = 5
        (Stop-BootUpdateAtRebootLimit -State $state -PendingSignals @($signal) -Context 'before update phases') |
            Should -BeTrue
        $state.Phase | Should -Be 'LimitReached'
        $state.LimitRebootSignals | Should -HaveCount 1
        $state.LimitRebootSignals[0].Source | Should -Be 'CBS'
        $state.LimitReason | Should -Match 'CBS: RebootPending key present'
        $script:UnregisterCalls | Should -Be 1
    }

    It 'bounds same-boot failure recovery separately from completed reboots' {
        $script:MaxRetryPasses = 3
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $state = [pscustomobject]@{
            ConsecutiveRetryCount=2; Phase='RetryPending'; StartTime='2026-07-20T09:00:00Z'
            LimitReachedAt=$null; LimitReason=$null
        }
        (Stop-BootUpdateAtRetryLimit -State $state -IncompletePhases @('Defender')) | Should -BeFalse
        $state.ConsecutiveRetryCount = 3
        (Stop-BootUpdateAtRetryLimit -State $state -IncompletePhases @('Defender')) | Should -BeTrue
        $state.Phase | Should -Be 'RetryLimitReached'
        $state.LimitReason | Should -Match 'incomplete phases: Defender'
        $script:UnregisterCalls | Should -Be 1
    }

    It 'charges repeated same-boot pending-reboot requests against the retry budget' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        ([regex]::Matches($cycle, '\$state\.ConsecutiveRetryCount\s*=\s*\[int\]\$state\.ConsecutiveRetryCount \+ 1')).Count |
            Should -BeGreaterOrEqual 3
        ([regex]::Matches($cycle, 'Pending reboot: \$_')).Count | Should -Be 2
        foreach ($restartCall in @(
            "Start-BootUpdateRestart -State `$state -Reason 'A reboot was already pending",
            'Start-BootUpdateRestart -State $state -Reason "Iteration'
        )) {
            $restart = $cycle.IndexOf($restartCall)
            $guard = $cycle.LastIndexOf('Stop-BootUpdateAtRetryLimit', $restart)
            $guard | Should -BeGreaterThan 0
            $guard | Should -BeLessThan $restart
        }
    }

    It 'does not mutate or enforce the retry budget during WhatIf' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        ([regex]::Matches($cycle, '(?s)if \(-not \$WhatIfPreference\) \{\s*\$state\.ConsecutiveRetryCount.*?Pending reboot: \$_.*?Stop-BootUpdateAtRetryLimit')).Count |
            Should -Be 2
    }

    It 'does not charge successful staged advancement against the retry budget' {
        $state = [pscustomobject]@{ ConsecutiveRetryCount=0 }
        foreach ($phase in 1..8) {
            Update-BootUpdateStagedRetryCount -State $state -TargetAttempted $true -TargetComplete $true |
                Should -Be 0
        }
        foreach ($failure in 1..3) {
            Update-BootUpdateStagedRetryCount -State $state -TargetAttempted $true -TargetComplete $false |
                Should -Be $failure
        }
        Update-BootUpdateStagedRetryCount -State $state -TargetAttempted $true -TargetComplete $true |
            Should -Be 0
    }

    It 'checks a stuck staged target before registering its next near-term retry' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $stagedStart = $cycle.IndexOf('$stagedRetryCount = Update-BootUpdateStagedRetryCount')
        $stagedStop = $cycle.IndexOf('Stop-BootUpdateAtRetryLimit', $stagedStart)
        $stagedRegister = $cycle.IndexOf('Register-BootUpdateTaskForReboot -RetrySoon', $stagedStart)
        $stagedStart | Should -BeGreaterThan 0
        $stagedStop | Should -BeGreaterThan $stagedStart
        $stagedStop | Should -BeLessThan $stagedRegister
    }

    It 'verifies both continuation tasks are absent before claiming they were removed' {
        $text = Get-FunctionText $invokeAst 'Unregister-BootUpdateTask'
        ([regex]::Matches($text, 'Get-ScheduledTask')).Count | Should -BeGreaterOrEqual 2
        $text | Should -Match 'Could not verify removal of scheduled task'
        $guard = Get-FunctionText $invokeAst 'Stop-BootUpdateAtRebootLimit'
        $guard.IndexOf('Unregister-BootUpdateTask') | Should -BeLessThan $guard.IndexOf('Send-CompletionNotification')
        $guard | Should -Match "Phase = 'LimitDisarmFailed'"
    }

    It 'retains a distinct terminal state when task disarming cannot be verified' {
        $script:MaxIterations = 1
        $script:FailUnregister = $true
        $state = [pscustomobject]@{
            RebootCount=1; Phase='Rebooting'; StartTime='2026-07-20T09:00:00Z'
            LastRebootSignals=$null; LimitReachedAt=$null; LimitReason=$null; LimitRebootSignals=@()
        }
        $signal = [pscustomobject]@{ Source='WU'; Detail='RebootRequired key present' }
        (Stop-BootUpdateAtRebootLimit -State $state -PendingSignals @($signal) -Context 'after update phases') |
            Should -BeTrue
        $state.Phase | Should -Be 'LimitDisarmFailed'
        $state.LimitReason | Should -Match 'simulated task removal failure'
        $script:FailUnregister = $false
    }
}

Describe 'Durable resume chain' {
    It 'uses ARSO user resume plus a delayed SYSTEM safety net' {
        $text = Get-FunctionText $invokeAst 'Register-BootUpdateTaskForReboot'
        $text | Should -Match 'New-ScheduledTaskTrigger -AtLogOn'
        $text | Should -Match 'BootUpdateCycleFallback'
        $text | Should -Match "Delay = 'PT3M'"
        $text | Should -Match 'fallbackRetryTrigger.*retryTime\.AddMinutes\(3\)'
        $text | Should -Match 'fallbackTriggers = if \(\$fallbackRetryTrigger\)'
    }

    It 'retries failures, rejects overlap, and verifies task registration' {
        foreach ($ast in @($invokeAst, $deployAst)) {
            $name = if ($ast -eq $invokeAst) { 'Register-BootUpdateTaskForReboot' } else { 'Register-ScheduledTaskNow' }
            $text = Get-FunctionText $ast $name
            $text | Should -Match '-RestartCount 3'
            $text | Should -Match '-RestartInterval'
            $text | Should -Match '-MultipleInstances IgnoreNew'
            $text | Should -Match 'Get-ScheduledTask'
            $text | Should -Match "State -eq 'Disabled'"
        }
    }

    It 'keeps resumed state after a transient preflight failure' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match 'Resume checkpoint preserved.*retry.*triggers are armed'
        $text.IndexOf('$state.Iteration++') | Should -BeGreaterThan $text.IndexOf('Test-PreFlightChecks')
    }

    It 'uses process-unique checkpoint temporary files' {
        $text = Get-FunctionText $invokeAst 'Set-BootUpdateState'
        $text | Should -Match '\$PID'
        $text | Should -Match '\[guid\]::NewGuid'
        $text | Should -Match '\[System\.IO\.File\]::Move'
    }

    It 'arms the resume checkpoint before any mutating update phase' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $checkpoint = $text.IndexOf("Resume checkpoint armed before update phases")
        $firstPhase = $text.IndexOf('Update-WingetPackages')
        $checkpoint | Should -BeGreaterThan 0
        $checkpoint | Should -BeLessThan $firstPhase
    }

    It 'arms a dated watchdog before a cancelable delayed restart' {
        $text = Get-FunctionText $invokeAst 'Start-BootUpdateRestart'
        $text | Should -Match 'restartWatchdog'
        $text | Should -Match 'Register-BootUpdateTaskForReboot -RetryAt'
        $text | Should -Match 'shutdown\.exe'
        $text | Should -Match '\$LASTEXITCODE -ne 0'
    }

    It 'round-trips structured arrays and behavior-changing resume switches' {
        $text = Get-FunctionText $invokeAst 'Register-BootUpdateTaskForReboot'
        $text | Should -Match 'ExcludePatternsBase64'
        $text | Should -Match 'IncludePatternsBase64'
        foreach ($switchName in @('SkipBitLocker','AllowMetered','DisableSelfUpdate','UpdateWsl','UpdateContainers','AggressiveRepair')) {
            $text | Should -Match ([regex]::Escape("-$switchName"))
        }
    }
}

Describe 'Behavioral reboot state transitions' {
    It 'does not consume or clear reboot evidence in the same boot' {
        $state = [pscustomobject]@{ LastBootSessionId='boot-a'; Phase='Rebooting'; RebootCount=2; ExplicitRebootRequests=@('3010') }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-a'
        $actual.RebootCount | Should -Be 2
        $actual.ExplicitRebootRequests | Should -HaveCount 1
    }

    It 'counts exactly one completed reboot and clears evidence after boot identity changes' {
        $state = [pscustomobject]@{ LastBootSessionId='boot-a'; Phase='Rebooting'; RebootCount=2; ExplicitRebootRequests=@('3010') }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-b'
        $actual.RebootCount | Should -Be 3
        $actual.ExplicitRebootRequests | Should -BeNullOrEmpty
        $again = Update-BootUpdateStateForBootSession -State $actual -CurrentBootSessionId 'boot-b'
        $again.RebootCount | Should -Be 3
    }

    It 'counts a surprise reboot persisted by native 1641 evidence before the post-phase checkpoint' {
        $state = [pscustomobject]@{
            LastBootSessionId='boot-a'; Phase='Chocolatey'; RebootCount=2
            ExplicitRebootRequests=@([pscustomobject]@{ Source='Chocolatey-exit-1641'; Detail='restart initiated' })
        }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-b'
        $actual.RebootCount | Should -Be 3
        $actual.ExplicitRebootRequests | Should -BeNullOrEmpty
        $actual.ConsecutiveRetryCount | Should -Be 0
    }

    It 'counts persisted native reboot evidence even if the post-phase marker was not reached' {
        $state = [pscustomobject]@{ LastBootSessionId='boot-a'; Phase='RetryPending'; RebootCount=2; ExplicitRebootRequests=@('3010') }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-b'
        $actual.RebootCount | Should -Be 3
        $actual.ExplicitRebootRequests | Should -BeNullOrEmpty
    }
}

Describe 'Jitter-tolerant boot session identity' {
    <# Diagnostics 2026-07-27: LastBootUpTime drifted between reads inside one boot, so every
       recovery pass logged a new boot session, zeroed ConsecutiveRetryCount, and the retry
       limit never fired — six passes on a permanently failing Defender phase in 18 minutes. #>
    It 'treats sub-tolerance LastBootUpTime drift as the same boot' {
        Test-BootUpdateSameBootSession -Left '2026-07-27T10:23:51.4978530Z' -Right '2026-07-27T10:23:53.1120000Z' |
            Should -BeTrue
    }

    It 'treats a genuine later boot as a new session' {
        Test-BootUpdateSameBootSession -Left '2026-07-27T10:23:51.4978530Z' -Right '2026-07-27T10:31:02.0000000Z' |
            Should -BeFalse
    }

    It 'preserves the same-boot retry budget across drifting passes' {
        $state = [pscustomobject]@{
            LastBootSessionId='2026-07-27T10:23:51.4978530Z'; Phase='RetryPending'
            RebootCount=0; ExplicitRebootRequests=@(); ConsecutiveRetryCount=4
        }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId '2026-07-27T10:23:52.8000000Z'
        $actual.ConsecutiveRetryCount | Should -Be 4
        $actual.RebootCount | Should -Be 0
    }

    It 'anchors on the first identity so drift cannot ratchet past the tolerance' {
        $state = [pscustomobject]@{
            LastBootSessionId='2026-07-27T10:23:51.0000000Z'; Phase='RetryPending'
            RebootCount=0; ExplicitRebootRequests=@(); ConsecutiveRetryCount=1
        }
        foreach ($drifted in @('2026-07-27T10:24:40.0000000Z','2026-07-27T10:25:20.0000000Z','2026-07-27T10:25:45.0000000Z')) {
            $state = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId $drifted
        }
        $state.LastBootSessionId | Should -Be '2026-07-27T10:23:51.0000000Z'
        $state.ConsecutiveRetryCount | Should -Be 1
    }

    It 'still resets the retry budget when the machine actually reboots' {
        $state = [pscustomobject]@{
            LastBootSessionId='2026-07-27T10:23:51.4978530Z'; Phase='Rebooting'
            RebootCount=1; ExplicitRebootRequests=@('3010'); ConsecutiveRetryCount=4
        }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId '2026-07-27T11:40:00.0000000Z'
        $actual.ConsecutiveRetryCount | Should -Be 0
        $actual.RebootCount | Should -Be 2
        $actual.LastBootSessionId | Should -Be '2026-07-27T11:40:00.0000000Z'
    }

    It 'keeps same-boot Windows Update zero evidence valid under drift' {
        $evidence = [pscustomobject]@{
            BootSessionId='2026-07-27T10:23:51.4978530Z'; ScopeSignature='scope-1'
            Source='PSWindowsUpdate-post-search-zero'
        }
        Test-WindowsUpdateZeroEvidence -Evidence $evidence -BootSessionId '2026-07-27T10:23:53.9000000Z' -ScopeSignature 'scope-1' |
            Should -BeTrue
    }
}

Describe 'Boot session identity survives the state-file round-trip' {
    <# Diagnostics 2026-08-24: the tolerance above was correct but never reached. State is
       persisted as JSON, and ConvertFrom-Json rehydrates an ISO-8601 value as [datetime];
       binding that to a [string] parameter rendered it in the current culture and dropped
       the offset, so the comparison picked up the machine's whole UTC offset (14399.5s
       observed against a 120s tolerance). Every pass logged a new boot session and zeroed
       ConsecutiveRetryCount, so MaxRetryPasses was unreachable and a permanently failing
       Chocolatey phase retried for 42 passes. The literal-string cases above all passed
       throughout — these exercise the boundary that actually broke. #>

    BeforeAll {
        function Get-RoundTrippedState {
            param([Parameter(Mandatory)][pscustomobject]$State)
            return ($State | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        }
    }

    It 'rehydrates a persisted boot session id as [datetime], not text' {
        <# Guards the premise: if this ever stops holding, the normalisation below is dead
           weight rather than silently-unnecessary. #>
        $roundTripped = Get-RoundTrippedState ([pscustomobject]@{ LastBootSessionId = '2026-08-24T15:54:52.5000000Z' })
        $roundTripped.LastBootSessionId | Should -BeOfType ([datetime])
    }

    It 'normalises a rehydrated UTC [datetime] back to round-trip form' {
        $roundTripped = Get-RoundTrippedState ([pscustomobject]@{ LastBootSessionId = '2026-08-24T15:54:52.5000000Z' })
        ConvertTo-BootUpdateTimestampString -Value $roundTripped.LastBootSessionId |
            Should -Be '2026-08-24T15:54:52.5000000Z'
    }

    It 'passes through a string and a null unchanged' {
        ConvertTo-BootUpdateTimestampString -Value '2026-08-24T15:54:52.5000000Z' |
            Should -Be '2026-08-24T15:54:52.5000000Z'
        ConvertTo-BootUpdateTimestampString -Value $null | Should -BeNullOrEmpty
    }

    It 'treats a rehydrated identity as the same boot as the value it was written from' {
        $roundTripped = Get-RoundTrippedState ([pscustomobject]@{ LastBootSessionId = '2026-08-24T15:54:52.5000000Z' })
        Test-BootUpdateSameBootSession -Left $roundTripped.LastBootSessionId -Right '2026-08-24T15:54:52.5000000Z' |
            Should -BeTrue
    }

    It 'preserves the retry budget across passes that reload state from JSON' {
        $state = [pscustomobject]@{
            LastBootSessionId='2026-08-24T15:54:52.5000000Z'; Phase='RetryPending'
            RebootCount=0; ExplicitRebootRequests=@(); ConsecutiveRetryCount=0
            WindowsUpdateZeroEvidence=[pscustomobject]@{ BootSessionId='2026-08-24T15:54:52.5000000Z' }
        }
        <# Five passes with no reboot: the budget must climb to MaxRetryPasses, not reset. #>
        foreach ($pass in 1..5) {
            $state = Get-RoundTrippedState $state
            $state = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId '2026-08-24T15:54:52.5000000Z'
            $state.ConsecutiveRetryCount = [int]$state.ConsecutiveRetryCount + 1
        }
        $state.ConsecutiveRetryCount | Should -Be 5
        $state.RebootCount | Should -Be 0
        $state.WindowsUpdateZeroEvidence | Should -Not -BeNullOrEmpty
    }

    It 'still detects a genuine reboot across the round-trip' {
        $state = Get-RoundTrippedState ([pscustomobject]@{
            LastBootSessionId='2026-08-24T15:54:52.5000000Z'; Phase='Rebooting'
            RebootCount=1; ExplicitRebootRequests=@('3010'); ConsecutiveRetryCount=4
        })
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId '2026-08-24T17:12:03.0000000Z'
        $actual.ConsecutiveRetryCount | Should -Be 0
        $actual.RebootCount | Should -Be 2
    }

    It 'normalises every persisted timestamp field on load' {
        <# Same defect class reaches WindowsUpdateZeroEvidence.ObservedAtUtc, which is read
           back with [datetime]::Parse([string]$_) and would age out an offset early. #>
        $text = Get-FunctionText $invokeAst 'Update-BootUpdateStateSchema'
        foreach ($field in @('StartTime','LastRun','LastPhaseTimestamp','LastPreflightNetworkAt','LastBootSessionId','LimitReachedAt')) {
            $text | Should -Match ([regex]::Escape("'$field'"))
        }
        $text | Should -Match 'ConvertTo-BootUpdateTimestampString'
        $text | Should -Match 'WindowsUpdateZeroEvidence\.ObservedAtUtc'
    }
}

Describe 'Defender platform executable resolution' {
    <# Live 2026-07-27 evidence, Windows Server 2016 (build 14393): the Program Files stub was
       4.10.14393.4651 and failed every signature update with hr=0x8007007F, while the serviced
       platform copy 4.18.26060.3008 returned exit 0 for the identical command. #>
    BeforeAll {
        <# Pester 5 runs It in a child scope that cannot see functions declared in the Describe
           body; BeforeAll definitions are visible. #>
        function New-FakePlatform {
            param([string]$Name, [switch]$WithoutExecutable)
            $dir = Join-Path $script:fakeProgramData "Microsoft\Windows Defender\Platform\$Name"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if (-not $WithoutExecutable) { Set-Content -LiteralPath (Join-Path $dir 'MpCmdRun.exe') -Value 'platform' }
            return $dir
        }
    }
    BeforeEach {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("defender-resolve-" + [guid]::NewGuid().ToString('N'))
        $script:fakeProgramData = Join-Path $script:sandbox 'ProgramData'
        $script:fakeProgramFiles = Join-Path $script:sandbox 'ProgramFiles'
        $script:realProgramData = $env:ProgramData
        $script:realProgramFiles = $env:ProgramFiles
        $env:ProgramData = $script:fakeProgramData
        $env:ProgramFiles = $script:fakeProgramFiles
        $script:inboxPath = Join-Path $script:fakeProgramFiles 'Windows Defender\MpCmdRun.exe'
        New-Item -ItemType Directory -Path (Split-Path $script:inboxPath -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:inboxPath -Value 'stub'
    }
    AfterEach {
        $env:ProgramData = $script:realProgramData
        $env:ProgramFiles = $script:realProgramFiles
        if (Test-Path -LiteralPath $script:sandbox) { Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'prefers the serviced platform copy over the frozen inbox stub' {
        $expected = Join-Path (New-FakePlatform -Name '4.18.26060.3008-0') 'MpCmdRun.exe'
        Get-DefenderCommandPath | Should -Be $expected
    }

    It 'orders platform directories as versions, not strings' {
        <# A lexical sort puts 4.18.9000.1 above 4.18.26060.3008 and would reselect an old build. #>
        $null = New-FakePlatform -Name '4.18.9000.1-0'
        $null = New-FakePlatform -Name '4.18.26040.7-0'
        $expected = Join-Path (New-FakePlatform -Name '4.18.26060.3008-0') 'MpCmdRun.exe'
        Get-DefenderCommandPath | Should -Be $expected
    }

    It 'ignores a platform directory that has no executable' {
        $null = New-FakePlatform -Name '4.18.26070.1-0' -WithoutExecutable
        $expected = Join-Path (New-FakePlatform -Name '4.18.26060.3008-0') 'MpCmdRun.exe'
        Get-DefenderCommandPath | Should -Be $expected
    }

    It 'ignores directory names that are not versions' {
        $null = New-FakePlatform -Name 'backup-copy'
        $expected = Join-Path (New-FakePlatform -Name '4.18.26060.3008-0') 'MpCmdRun.exe'
        Get-DefenderCommandPath | Should -Be $expected
    }

    It 'falls back to the inbox stub when no serviced platform exists' {
        Get-DefenderCommandPath | Should -Be $script:inboxPath
    }

    It 'reports nothing when Defender is absent entirely' {
        Remove-Item -LiteralPath $script:inboxPath -Force
        Get-DefenderCommandPath | Should -BeNullOrEmpty
    }
}

Describe 'Terminal Defender platform failure' {
    <# hr=0x8007007F is ERROR_PROC_NOT_FOUND from a broken Defender platform install:
       identical on every same-boot invocation, so it must not be retry fuel. #>
    It 'stops for attention instead of retrying a broken Defender platform' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            [pscustomobject]@{
                Name='Defender'; UserCompletionDeferred=$false; TerminalFailure=$true
                AttentionDetails=@(Get-DefenderPlatformAttentionDetail)
            }
        )
        $result.Kind | Should -Be 'Attention'
        $result.Phases[0].Name | Should -Be 'Defender'
    }

    It 'names the platform repair path in the attention detail' {
        $detail = Get-DefenderPlatformAttentionDetail
        $detail.Hex | Should -Be '0x8007007F'
        $detail.Command | Should -Match 'RemoveDefinitions'
    }

    It 'classifies the observed MpCmdRun platform failure as terminal' {
        $observed = @(
            'Signature update started . . .'
            'ERROR: Signature Update failed with hr=8007007F'
            'CmdTool: Failed with hr = 0x8007007F. Check C:\path\MpCmdRun.log'
        )
        @($observed | Where-Object { $_ -match '(?i)hr\s*=\s*0?x?8007007F' }).Count | Should -BeGreaterThan 0
    }

    It 'leaves an ordinary Defender signature failure retryable' {
        $observed = @('Signature update started . . .', 'ERROR: Signature Update failed with hr=80072EE2')
        @($observed | Where-Object { $_ -match '(?i)hr\s*=\s*0?x?8007007F' }).Count | Should -Be 0
    }
}

Describe 'Behavioral completion disposition' {
    It 'retries ordinary incomplete phases before considering completion' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            [pscustomobject]@{ Name='WindowsUpdate'; UserCompletionDeferred=$false },
            [pscustomobject]@{ Name='Scoop'; UserCompletionDeferred=$true }
        )
        $result.Kind | Should -Be 'Retry'
        $result.Phases.Name | Should -Contain 'WindowsUpdate'
    }

    It 'stops automatic retries for a persistent terminal provider failure' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            @{ Name='Winget'; UserCompletionDeferred=$false; TerminalFailure=$true; AttentionDetails=@('iCUE') }
        )
        $result.Kind | Should -Be 'Attention'
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $cycle | Should -Match "disposition\.Kind -eq 'Attention'[\s\S]*?Stop-BootUpdateForManualAttention"
    }

    It 'still disarms and presents the durable repair path when checkpoint persistence fails' {
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $script:StatePath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.state.json'
        $script:LogPath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.log'
        Mock Set-BootUpdateState { throw 'simulated checkpoint write failure' }
        Mock Write-BootUpdateRepairPlan {
            [pscustomobject]@{ Path='C:\ProgramData\BootUpdateCycle\BootUpdateCycle-repair-plan.txt'; ClipboardCopied=$false }
        }
        Mock Show-CycleBanner { }
        $state = [pscustomobject]@{ Phase='RetryPending'; LimitReachedAt=$null; LimitReason=$null }
        $phase = [pscustomobject]@{
            Name='Winget'; AttentionDetails=@([pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=1; Hex='0x00000001' })
        }

        { Stop-BootUpdateForManualAttention -State $state -Phases @($phase) } | Should -Not -Throw
        $script:UnregisterCalls | Should -Be 1
        Should -Invoke Show-CycleBanner -Times 1 -ParameterFilter {
            ($Info -join "`n") -match 'clipboard unavailable' -and
            ($Info -join "`n") -match 'diagnostic state could not be saved'
        }
    }

    It 'still presents terminal attention when repair-plan generation throws' {
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $script:StatePath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.state.json'
        $script:LogPath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.log'
        Mock Set-BootUpdateState { }
        Mock Write-BootUpdateRepairPlan { throw 'simulated repair-plan failure' }
        Mock Show-CycleBanner { }
        $state = [pscustomobject]@{ Phase='RetryPending'; LimitReachedAt=$null; LimitReason=$null }
        $phase = [pscustomobject]@{ Name='Winget'; AttentionDetails=@() }

        { Stop-BootUpdateForManualAttention -State $state -Phases @($phase) } | Should -Not -Throw
        $script:UnregisterCalls | Should -Be 1
        Should -Invoke Show-CycleBanner -Times 1 -ParameterFilter {
            ($Info -join "`n") -match 'Repair-plan creation failed'
        }
    }

    It 'retains a user-context pass when only user-scoped work remains' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            [pscustomobject]@{ Name='Scoop'; UserCompletionDeferred=$true }
        )
        $result.Kind | Should -Be 'UserContext'
    }

    It 'completes only an empty incomplete set' {
        (Resolve-BootUpdateCompletionDisposition).Kind | Should -Be 'Complete'
    }
}

Describe 'Terminal pip interpreter failure' {
    It 'recognizes fatal interpreter-startup evidence and ignores ordinary pip errors' {
        Test-PipFatalInterpreterEvidence -Lines @(
            'Could not find platform independent libraries <prefix>'
        ) | Should -BeTrue
        Test-PipFatalInterpreterEvidence -Lines @(
            'Fatal Python error: Failed to import encodings module'
        ) | Should -BeTrue
        Test-PipFatalInterpreterEvidence -Lines @(
            'ERROR: Could not install packages due to an OSError: [Errno 13] Permission denied',
            'WARNING: Retrying (Retry(total=4)) after connection broken'
        ) | Should -BeFalse
        Test-PipFatalInterpreterEvidence | Should -BeFalse
    }

    It 'classifies a broken interpreter as terminal instead of queueing retries' {
        Mock Write-Log { }
        Mock Get-Command { [pscustomobject]@{ Source='C:\Path\To\Scripts\pip.exe' } } -ParameterFilter { $Name -eq 'pip' }
        Mock Get-Command { [pscustomobject]@{ Source='C:\Path\To\python.exe' } } -ParameterFilter { $Name -eq 'python' }
        Mock Invoke-BootUpdateBackgroundOperation {
            @{ Failed=$true; TimedOut=$false; Output=@(
                'Could not find platform independent libraries <prefix>',
                'Fatal Python error: Failed to import encodings module'
            ) }
        }
        $script:PackageTimeoutMinutes = 30

        $result = Update-PipPackages -Confirm:$false

        $result.Success | Should -BeFalse
        $result.TerminalFailure | Should -BeTrue
        @($result.AttentionDetails).Count | Should -Be 1
        $result.AttentionDetails[0].Name | Should -Be 'Python interpreter'
        $result.AttentionDetails[0].Command | Should -Match 'Repair or reinstall Python'
        Should -Invoke Invoke-BootUpdateBackgroundOperation -Times 1 -Exactly
    }

    It 'keeps an ordinary pip inventory failure retryable' {
        Mock Write-Log { }
        Mock Get-Command { [pscustomobject]@{ Source='C:\Path\To\Scripts\pip.exe' } } -ParameterFilter { $Name -eq 'pip' }
        Mock Get-Command { [pscustomobject]@{ Source='C:\Path\To\python.exe' } } -ParameterFilter { $Name -eq 'python' }
        Mock Invoke-BootUpdateBackgroundOperation {
            if ($Name -eq 'Updating pip') { return @{ Failed=$false; TimedOut=$false; Output=@('Requirement already satisfied: pip') } }
            @{ Failed=$true; TimedOut=$false; Output=@('WARNING: Retrying (Retry(total=4)) after connection broken') }
        }
        $script:PackageTimeoutMinutes = 30

        $result = Update-PipPackages -Confirm:$false

        $result.Success | Should -BeFalse
        [bool]$result.TerminalFailure | Should -BeFalse
    }

    It 'keeps the cohort scriptblock evidence pattern aligned with the shared helper' {
        $helper = Get-FunctionText $invokeAst 'Test-PipFatalInterpreterEvidence'
        $helper -match "\`$pattern = '([^']+)'" | Should -BeTrue
        $helperPattern = $Matches[1]
        $invokeSource | Should -Match ([regex]::Escape("`$fatalPattern = '$helperPattern'"))
    }

    It 'propagates cohort terminal failures to the completion disposition' {
        $invokeSource | Should -Match ([regex]::Escape('$phaseDefn.TerminalFailure = [bool]$jr.TerminalFailure'))
        $invokeSource | Should -Match ([regex]::Escape('$phaseDefn.AttentionDetails = @($jr.AttentionDetails)'))
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            @{ Name='Pip'; UserCompletionDeferred=$false; TerminalFailure=$true; AttentionDetails=@('Python interpreter') }
        )
        $result.Kind | Should -Be 'Attention'
    }
}

Describe 'Behavioral dated retries' {
    BeforeEach {
        $script:MaintenanceWindowStart = 22
    }

    It 'uses today when the maintenance start is still ahead' {
        (Get-NextMaintenanceWindowStart -Now ([datetime]'2026-07-20T10:00:00')) |
            Should -Be ([datetime]'2026-07-20T22:00:00')
    }

    It 'uses tomorrow when the maintenance start has passed' {
        (Get-NextMaintenanceWindowStart -Now ([datetime]'2026-07-20T23:00:00')) |
            Should -Be ([datetime]'2026-07-21T22:00:00')
    }
}

Describe 'Behavioral Windows Update convergence' {
    BeforeEach {
        $script:ExcludePatterns = @('SQL')
        $script:PackageTimeoutMinutes = 30
        $script:CurrentState = $null
        Mock Get-Module { [pscustomobject]@{ Name='PSWindowsUpdate' } }
        Mock Get-BootUpdateBootSessionId { 'boot-a' }
        Mock Write-Log {}
        Mock Set-WindowsUpdateAssessmentCache {}
        <# Pin the two environment reads the re-offer classification makes, so these tests
           say nothing about the machine they happen to run on. #>
        $script:TestBootInstant = [datetime]::new(2026, 9, 9, 12, 40, 0, [System.DateTimeKind]::Utc)
        Mock Get-WindowsUpdateInstallHistory { @() }
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = $script:TestBootInstant } } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
    }

    It 'verifies zero applicable updates' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'accepts only exact post-search zero evidence and does not count zero download/install summaries' {
        $summary = Get-WindowsUpdateInstallOutputSummary -Lines @(
            'Downloaded [0] Updates',
            'Installed [0] Updates',
            'Found [0] Updates in post search criteria'
        )
        $summary.Installed | Should -Be 0
        $summary.PostSearchZero | Should -BeTrue

        (Get-WindowsUpdateInstallOutputSummary -Lines @('Found [0] Updates in pre search criteria')).PostSearchZero | Should -BeFalse
        (Get-WindowsUpdateInstallOutputSummary -Lines @('Found [1] Updates in post search criteria')).PostSearchZero | Should -BeFalse
    }

    It 'counts the installed aggregate without double-counting downloaded updates' {
        $summary = Get-WindowsUpdateInstallOutputSummary -Lines @('Downloaded [3] Updates','Installed [2] Updates')
        $summary.Installed | Should -Be 2
    }

    It 'does not count the legacy empty applicable marker as an update' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_APPLICABLE||','BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
        Assert-MockCalled Write-Log -Times 0 -ParameterFilter { $Message -like 'Final WU scan:*' }
    }

    It 'reports remaining applicable updates' {
        Mock Get-WindowsUpdateEnvironmentFingerprint { 'fingerprint' }
        Mock Set-WindowsUpdateAssessmentCache {}
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_APPLICABLE|id-1|7|Update','BOOTUPDATE_SCAN_COMPLETE|1'); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 1
        $result.Unexplained | Should -Be 1 -Because 'an update with no successful install behind it is outstanding work'
        @($result.Reoffered).Count | Should -Be 0
    }

    It 'explains an update Windows Update says it already installed in this boot' {
        <# -k610 end to end through the convergence check: the scan still offers KB5007651,
           and the agent's own history says it installed it successfully twenty minutes ago,
           after the last restart. Count stays 1 because the update really is applicable;
           Unexplained drops to 0 because none of it is work this cycle can do. #>
        $title = 'Update for Windows Security platform - KB5007651 (Version 10.0.29628.1000)'
        Mock Get-WindowsUpdateEnvironmentFingerprint { 'fingerprint' }
        Mock Set-WindowsUpdateAssessmentCache {}
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@("BOOTUPDATE_APPLICABLE|id-1|204|$title",'BOOTUPDATE_SCAN_COMPLETE|1'); Failed=$false; TimedOut=$false } }
        Mock Get-WindowsUpdateInstallHistory {
            @([pscustomobject]@{ Title = $title; ResultCode = 2; InstalledAt = $script:TestBootInstant.AddMinutes(20) })
        }

        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 1
        $result.Unexplained | Should -Be 0
        @($result.Reoffered).Count | Should -Be 1
        @($result.Reoffered)[0].KB | Should -Be 'KB5007651'
    }

    It 'does not classify anything when the scan itself could not be verified' {
        <# Guessing about an unverified scan would turn a scan failure into a qualified
           completion claim, which is the exact failure mode this release is correcting. #>
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_ERROR|offline'); Failed=$false; TimedOut=$false } }
        Mock Get-WindowsUpdateInstallHistory { throw 'the history must not be consulted for an unverified scan' }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeFalse
        @($result.Reoffered).Count | Should -Be 0
    }

    It 'withholds verification after a scan error' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_ERROR|offline'); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeFalse
    }

    It 'withholds verification when the child exits without a completion marker' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@(); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeFalse
    }

    It 'withholds verification when the completion count disagrees with update records' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{
            Output=@('BOOTUPDATE_APPLICABLE|id-1|7|Update','BOOTUPDATE_SCAN_COMPLETE|0')
            Failed=$false; TimedOut=$false
        } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeFalse
    }

    It 'reuses exact post-search zero evidence only on the same boot and scope' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $evidence = [pscustomobject]@{
            BootSessionId='boot-a'; ScopeSignature=$verificationScope.Signature
            Source='PSWindowsUpdate-post-search-zero'; ObservedAt=[datetime]::UtcNow.ToString('o')
        }
        $script:CurrentState = [pscustomobject]@{ WindowsUpdateZeroEvidence = $evidence }
        Mock Invoke-BootUpdateBackgroundOperation { throw 'redundant scan should not run' }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
        Assert-MockCalled Invoke-BootUpdateBackgroundOperation -Times 0
    }

    It 'invalidates cached zero evidence after a boot change and performs the scan' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $evidence = [pscustomobject]@{
            BootSessionId='old-boot'; ScopeSignature=$verificationScope.Signature
            Source='PSWindowsUpdate-post-search-zero'; ObservedAt=[datetime]::UtcNow.ToString('o')
        }
        $script:CurrentState = [pscustomobject]@{ WindowsUpdateZeroEvidence = $evidence }
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeTrue
        $script:CurrentState.WindowsUpdateZeroEvidence | Should -BeNullOrEmpty
        Assert-MockCalled Invoke-BootUpdateBackgroundOperation -Times 1
    }

    It 'invalidates cached zero evidence when exclusions change' {
        $oldScope = Get-WindowsUpdateVerificationScope
        $evidence = [pscustomobject]@{
            BootSessionId='boot-a'; ScopeSignature=$oldScope.Signature
            Source='PSWindowsUpdate-post-search-zero'; ObservedAt=[datetime]::UtcNow.ToString('o')
        }
        $script:CurrentState = [pscustomobject]@{ WindowsUpdateZeroEvidence = $evidence }
        $script:ExcludePatterns = @('SQL','Preview')
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeTrue
        Assert-MockCalled Invoke-BootUpdateBackgroundOperation -Times 1
    }

}

Describe 'Cross-session Windows Update assessment cache' {
    BeforeEach {
        $script:WindowsUpdateAssessmentPath = Join-Path $TestDrive 'wu-assessment.json'
        $script:WindowsUpdateOnlineAssessmentTtlHours = 6
        $script:ExcludePatterns = @('SQL')
        Mock Get-WindowsUpdateEnvironmentFingerprint { 'same-environment' }
    }

    It 'accepts a fresh assessment across a boot boundary when scope and environment match' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $record = [pscustomobject]@{ SchemaVersion=1; ObservedAtUtc=[datetime]::UtcNow.AddHours(-1).ToString('o');
           BootSessionId='previous-boot'; ScopeSignature=$verificationScope.Signature;
           EnvironmentFingerprint='same-environment'; ApplicableUpdates=@() }
        Test-WindowsUpdateAssessmentRecord -Record $record -Scope $verificationScope -EnvironmentFingerprint 'same-environment' -TtlHours 6 | Should -BeTrue
    }

    It 'requires an online assessment when the TTL expires' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $record = [pscustomobject]@{ SchemaVersion=1; ObservedAtUtc=[datetime]::UtcNow.AddHours(-7).ToString('o');
           BootSessionId='previous-boot'; ScopeSignature=$verificationScope.Signature;
           EnvironmentFingerprint='same-environment'; ApplicableUpdates=@() }
        Test-WindowsUpdateAssessmentRecord -Record $record -Scope $verificationScope -EnvironmentFingerprint 'same-environment' -TtlHours 6 | Should -BeFalse
    }

    It 'requires online work when the local catalog still has applicable updates' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        @{ SchemaVersion=1; ObservedAtUtc=[datetime]::UtcNow.AddMinutes(-20).ToString('o');
           BootSessionId='previous-boot'; ScopeSignature=$verificationScope.Signature;
           EnvironmentFingerprint='same-environment'; ApplicableUpdates=@() } |
            ConvertTo-Json | Set-Content $script:WindowsUpdateAssessmentPath
        $offline = [pscustomobject]@{ Verified=$true; Updates=@([pscustomobject]@{UpdateID='id';RevisionNumber=2}); Error=$null }
        (Test-WindowsUpdateAssessmentCache -Scope $verificationScope -Path $script:WindowsUpdateAssessmentPath -TtlHours 6 -EnvironmentFingerprint 'same-environment' -OfflineAssessmentResult $offline) | Should -BeFalse
    }

    It 'bounds offline WUA work and requires a count-matched completion contract' {
        $text = Get-FunctionText $invokeAst 'Invoke-WindowsUpdateOfflineAssessment'
        $text | Should -Match 'Invoke-BootUpdateBackgroundOperation'
        $text | Should -Match 'TimeoutMinutes'
        $text | Should -Match 'BOOTUPDATE_SCAN_COMPLETE'
        $text | Should -Match '\$declared -ne \$records.Count'
    }

    It 'fingerprints registered update services as well as policy and history' {
        $text = Get-FunctionText $invokeAst 'Get-WindowsUpdateEnvironmentFingerprint'
        $text | Should -Match 'Microsoft.Update.ServiceManager'
        $text | Should -Match 'ServerSelection'
        $text | Should -Match 'ServiceID'
    }

    It 'uses a count-preserving identity fallback for PSWindowsUpdate result shapes' {
        $text = Get-FunctionText $invokeAst 'Test-WindowsUpdateConvergence'
        $text | Should -Match '\$_.Identity'
        $text | Should -Match 'identity-unavailable'
        $text | Should -Match 'RevisionNumber'
    }

    It 'does not delete assessment evidence during WhatIf' {
        (Get-FunctionText $invokeAst 'Remove-WindowsUpdateAssessmentCache') | Should -Match '\$WhatIfPreference -and -not \$Force'
    }
}

Describe 'Evidence-backed completion' {
    It 'queues a near-term retry instead of congratulating an incomplete phase set' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$incompletePhases'
        $text | Should -Match 'Register-BootUpdateTaskForReboot -RetrySoon'
        $text | Should -Match 'R E C O V E R Y   P A S S   Q U E U E D'
        $text.IndexOf('$incompletePhases') | Should -BeLessThan $text.IndexOf('U P D A T E S   C O M P L E T E')
    }

    It 'returns success after the retry checkpoint transaction is durably armed' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $retryStart = $text.IndexOf("if (-not `$WhatIfPreference -and `$disposition.Kind -eq 'Retry')")
        $nextDisposition = $text.IndexOf("if (-not `$WhatIfPreference -and `$disposition.Kind -eq 'UserContext')", $retryStart)
        $retryBranch = $text.Substring($retryStart, $nextDisposition - $retryStart)

        $retryBranch | Should -Match 'Set-BootUpdateState'
        $retryBranch | Should -Match 'Register-BootUpdateTaskForReboot -RetrySoon'
        $retryBranch | Should -Match 'R E C O V E R Y   P A S S   Q U E U E D'
        $retryBranch | Should -Match 'No action needed.*window may close'
        $retryBranch | Should -Match 'exit\s+0'
        $retryBranch | Should -Match 'Stop-BootUpdateAtRetryLimit[\s\S]*exit\s+3'
    }

    It 'continues treating Defender native exit code 2 as a retryable phase failure' {
        $text = Get-FunctionText $invokeAst 'Update-DefenderSignatures'
        $text | Should -Match '\$exitCode -ne 0'
        $text | Should -Match 'exited with code \$exitCode'
        $text | Should -Match 'Success = \$false'
    }

    It 'congratulates only the verified green path and reports its evidence' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match 'NICE WORK.*selected updates finished and verification passed'
        $text | Should -Match '\[RESTART\] NOT REQUIRED'
        $text | Should -Match 'configured phases completed'
        $text | Should -Match '\[RESTART\] NOT REQUIRED.*no blocking restart evidence remains'
        $text | Should -Match 'Housekeeping remains.*restarting later is optional'
        $text | Should -Match 'service state\(s\) assessed read-only'
        $text | Should -Not -Match 'FULLY PATCHED'
    }

    It 'cleans and verifies terminal artifacts before success notification and banner' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $cleanup = $text.LastIndexOf('Unregister-BootUpdateTask')
        $verify = $text.LastIndexOf('Terminal cleanup verification failed')
        <# Anchored on the call, not on its argument text: the message is composed by
           Get-BootUpdateCompletionNotification, so pinning the literal here would couple
           this ordering invariant to wording it does not care about. #>
        $notify = $text.LastIndexOf('Send-CompletionNotification')
        $banner = $text.LastIndexOf('Show-CycleBanner -Title $completionTitle')
        $cleanup | Should -BeLessThan $verify
        $verify | Should -BeLessThan $notify
        $notify | Should -BeLessThan $banner
    }

    It 'reports durable Winget quarantine as degraded completion rather than fully patched' {
        <# The claim string and the toast wording are composed by dedicated functions and
           asserted behaviourally in 'Completion claim composition' and 'Completion
           notification severity'. What this guards is that the orchestrator still feeds
           quarantine into both, and still surfaces the record so a human can undo it. #>
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match "'WINGET QUARANTINE'"
        $text | Should -Match 'WingetQuarantinePath'
        $text | Should -Match 'Repeatedly failing packages were skipped to prevent another loop'
        $text | Should -Match 'were not updated'
        Get-BootUpdateCompletionClaim -Qualifiers @('WINGET QUARANTINE') |
            Should -Be 'COMPLETE WITH WINGET QUARANTINE'
        $toast = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 1 -QuarantineCount 1
        $toast.Title | Should -Match 'Updates complete.*no restart required'
        $toast.Message | Should -Match 'No action is required now'
        (Get-FunctionText $invokeAst 'Clear-BootUpdateState') | Should -Not -Match 'WingetQuarantine'
    }

    It 'makes confirmed restart state prominent in Normal output at both checkpoints' {
        $status = Get-FunctionText $invokeAst 'Show-BootUpdateRestartStatus'
        $status | Should -Match 'RESTART STATUS'
        $status | Should -Match 'Windows must restart before this update run can continue'
        $status | Should -Match 'continue automatically after restart'
        $status | Should -Match 'NOT REQUIRED'
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        ([regex]::Matches($cycle, 'Show-BootUpdateRestartStatus -State Required')).Count | Should -Be 2
        ([regex]::Matches($cycle, 'Show-BootUpdateRestartStatus -State NotRequired')).Count | Should -Be 2
    }

    It 'requires completed thread jobs and structured success' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match "jobState -ne 'Completed'"
        $text | Should -Match 'phaseSucceeded = \$jobState -eq ''Completed''.*jr\.Success'
    }
}

Describe 'Chocolatey terminal failure classification' {
    <# Diagnostics 2026-08-24: choco upgrade all failed identically on every pass because a
       package's published checksum no longer matched the artifact the vendor was serving.
       The phase reported only Success/Count, so the failure was indistinguishable from a
       transient one and consumed the whole retry budget without ever saying why. #>

    BeforeAll {
        <# Real captured output, with the user profile path sanitized. Chocolatey reports
           "exited -1" for any failing install script, so the exit code alone cannot tell
           this apart from a disk or network failure of the same package (ADR-0002). #>
        $script:ChocoChecksumFailure = @(
            'Chocolatey v2.7.4'
            'Upgrading the following packages:'
            'all'
            'chocolatey v2.7.4 is the latest version available based on your source(s).'
            'Firefox v154.0.0 is the latest version available based on your source(s).'
            ''
            'You have GoogleChrome v152.0.7977.42 installed. Version 152.0.7977.54 is available based on your source(s).'
            "Downloading package from source 'https://community.chocolatey.org/api/v2/'"
            ''
            'GoogleChrome v152.0.7977.54 [Approved]'
            'GoogleChrome package files upgrade completed. Performing other installation steps.'
            'File appears to be downloaded already. Verifying with package checksum to determine if it needs to be redownloaded.'
            "Error - hashes do not match. Actual value was 'B5F03C8D228C79A4EAFB071BE89AA34AFA46EDE60E898EC1988600BBB5D7B451'."
            'Downloading googlechrome 64 bit'
            "  from 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'"
            ''
            'Download of googlechromestandaloneenterprise64.msi (-1 B) completed.'
            "Error - hashes do not match. Actual value was 'B5F03C8D228C79A4EAFB071BE89AA34AFA46EDE60E898EC1988600BBB5D7B451'."
            "ERROR: Checksum for 'C:\Users\Example\AppData\Local\Temp\chocolatey\GoogleChrome\152.0.7977.54\googlechromestandaloneenterprise64.msi' did not meet '693e6efefec1d8d776eb221804bfafb8f86289210d687c7024bdb89ef7034d40' for checksum type 'sha256'. Consider passing the actual checksums through with --checksum --checksum64 once you validate the checksums are appropriate. A less secure option is to pass --ignore-checksums if necessary."
            'The upgrade of GoogleChrome was NOT successful.'
            "Error while running 'C:\ProgramData\chocolatey\lib\GoogleChrome\tools\chocolateyInstall.ps1'."
            ' See log for details.'
            'googledrive v129.0.1 is the latest version available based on your source(s).'
            'powertoys v0.100.2 is the latest version available based on your source(s).'
            ''
            'Chocolatey upgraded 0/14 packages. 1 packages failed.'
            ' See the log for details (C:\ProgramData\chocolatey\logs\chocolatey.log).'
            ''
            'Failures'
            " - GoogleChrome (exited -1) - Error while running 'C:\ProgramData\chocolatey\lib\GoogleChrome\tools\chocolateyInstall.ps1'."
            ' See log for details.'
        )
    }

    It 'extracts the failing package and its exit code from the Failures block' {
        $summary = Get-ChocolateyOutputSummary -Lines $script:ChocoChecksumFailure
        @($summary.Failures).Count | Should -Be 1
        $summary.Failures[0].Name | Should -Be 'GoogleChrome'
        $summary.Failures[0].Code | Should -Be -1
    }

    It 'associates the expected and actual checksums with the failing package' {
        $summary = Get-ChocolateyOutputSummary -Lines $script:ChocoChecksumFailure
        $summary.Failures[0].ExpectedChecksum | Should -Be '693e6efefec1d8d776eb221804bfafb8f86289210d687c7024bdb89ef7034d40'
        $summary.Failures[0].ActualChecksum | Should -Be 'B5F03C8D228C79A4EAFB071BE89AA34AFA46EDE60E898EC1988600BBB5D7B451'
    }

    It 'treats the same checksum failure on consecutive passes as terminal' {
        $state = [pscustomobject]@{}
        $summary = Get-ChocolateyOutputSummary -Lines $script:ChocoChecksumFailure
        $first = Complete-ChocolateyFailureClassification -State $state -Failures $summary.Failures
        $second = Complete-ChocolateyFailureClassification -State $state -Failures $summary.Failures
        $first.TerminalFailure | Should -BeFalse -Because 'one sighting does not prove a failure is permanent'
        $second.TerminalFailure | Should -BeTrue
    }

    It 'stops treating a failure as terminal once the package is fixed upstream' {
        <# The maintainer refreshing stale metadata changes the expected checksum, which
           changes the signature, which re-arms the retry budget with no human involved. #>
        $state = [pscustomobject]@{}
        $summary = Get-ChocolateyOutputSummary -Lines $script:ChocoChecksumFailure
        $null = Complete-ChocolateyFailureClassification -State $state -Failures $summary.Failures
        (Complete-ChocolateyFailureClassification -State $state -Failures $summary.Failures).TerminalFailure |
            Should -BeTrue

        $refreshed = $script:ChocoChecksumFailure -replace '693e6efefec1d8d776eb221804bfafb8f86289210d687c7024bdb89ef7034d40', '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0'
        $refreshedSummary = Get-ChocolateyOutputSummary -Lines $refreshed
        $refreshedSummary.Failures[0].Name | Should -Be 'GoogleChrome' -Because 'same package and exit code as before'
        $refreshedSummary.Failures[0].Code | Should -Be -1
        (Complete-ChocolateyFailureClassification -State $state -Failures $refreshedSummary.Failures).TerminalFailure |
            Should -BeFalse
    }

    It 'reports a repeated Chocolatey failure as terminal from the phase itself' {
        Mock Write-Log { }
        Mock Get-Command { [pscustomobject]@{ Source='C:\ProgramData\chocolatey\bin\choco.exe' } } -ParameterFilter { $Name -eq 'choco' }
        Mock Invoke-BootUpdateBackgroundOperation { @{ Failed=$true; TimedOut=$false; Output=$script:ChocoChecksumFailure } }
        $script:PackageTimeoutMinutes = 30
        $script:ExcludePatterns = @()
        $script:IncludePatterns = @()
        $script:CurrentState = [pscustomobject]@{}

        $first = Update-ChocolateyPackages -Confirm:$false
        $second = Update-ChocolateyPackages -Confirm:$false

        $first.Success | Should -BeFalse
        [bool]$first.TerminalFailure | Should -BeFalse
        [bool]$second.TerminalFailure | Should -BeTrue
    }

    It 'hands over both checksums and never names the bypass' {
        <# ADR-0001: the repair plan states the mismatch so a human can compare against the
           vendor's published hash, and offers no command, because none is safe to run blind.
           Write-BootUpdateRepairPlan feeds Command into a copy/paste block, so a bypass
           placed there would be the path of least resistance. #>
        Mock Write-Log { }
        Mock Get-Command { [pscustomobject]@{ Source='C:\ProgramData\chocolatey\bin\choco.exe' } } -ParameterFilter { $Name -eq 'choco' }
        Mock Invoke-BootUpdateBackgroundOperation { @{ Failed=$true; TimedOut=$false; Output=$script:ChocoChecksumFailure } }
        $script:PackageTimeoutMinutes = 30
        $script:ExcludePatterns = @()
        $script:IncludePatterns = @()
        $script:CurrentState = [pscustomobject]@{}

        $null = Update-ChocolateyPackages -Confirm:$false
        $terminal = Update-ChocolateyPackages -Confirm:$false

        $detail = @($terminal.AttentionDetails)[0]
        $detail.Name | Should -Be 'GoogleChrome'
        $detail.Hex | Should -Match '693e6efefec1d8d776eb221804bfafb8f86289210d687c7024bdb89ef7034d40'
        $detail.Hex | Should -Match 'B5F03C8D228C79A4EAFB071BE89AA34AFA46EDE60E898EC1988600BBB5D7B451'
        [string]$detail.Command | Should -BeNullOrEmpty
        ($terminal.AttentionDetails | Out-String) | Should -Not -Match 'ignore-checksums'
    }

    It 'routes a terminal Chocolatey phase to manual attention' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            @{ Name='Chocolatey'; UserCompletionDeferred=$false; TerminalFailure=$true }
        )
        $result.Kind | Should -Be 'Attention'
    }

    It 'attributes each checksum to its own package when one is not [Approved]' {
        <# Packages from non-community sources print no [Approved] marker, so tracking the
           current package by that line alone wrote the second package's hash into the
           first package's record, corrupting both signatures. #>
        $lines = @(
            'PackageOne v1.0.0 [Approved]'
            "Error - hashes do not match. Actual value was 'AAAA1111'."
            "ERROR: Checksum for 'C:\Users\Example\AppData\Local\Temp\chocolatey\PackageOne\1.0.0\one.msi' did not meet 'EEEE1111' for checksum type 'sha256'."
            'The upgrade of PackageOne was NOT successful.'
            "Error - hashes do not match. Actual value was 'BBBB2222'."
            "ERROR: Checksum for 'C:\Users\Example\AppData\Local\Temp\chocolatey\PackageTwo\2.0.0\two.msi' did not meet 'EEEE2222' for checksum type 'sha256'."
            'The upgrade of PackageTwo was NOT successful.'
            'Failures'
            ' - PackageOne (exited -1) - Error while running install script.'
            ' - PackageTwo (exited -1) - Error while running install script.'
        )
        $summary = Get-ChocolateyOutputSummary -Lines $lines
        @($summary.Failures).Count | Should -Be 2
        $one = @($summary.Failures | Where-Object { $_.Name -eq 'PackageOne' })[0]
        $two = @($summary.Failures | Where-Object { $_.Name -eq 'PackageTwo' })[0]
        $one.ExpectedChecksum | Should -Be 'EEEE1111'
        $one.ActualChecksum | Should -Be 'AAAA1111'
        $two.ExpectedChecksum | Should -Be 'EEEE2222'
        $two.ActualChecksum | Should -Be 'BBBB2222'
    }

    It 'clears a stale repair plan when Chocolatey recovers' {
        $script:InstallDir = $TestDrive
        $plan = Join-Path $TestDrive 'BootUpdateCycle-repair-plan.txt'
        Set-Content -LiteralPath $plan -Value 'stale plan from an earlier pass'
        $state = [pscustomobject]@{ ChocolateyFailureSignature='GoogleChrome:-1:abc'; ChocolateyFailureRepeatCount=3 }

        $result = Complete-ChocolateyFailureClassification -State $state -Failures @()

        $result.TerminalFailure | Should -BeFalse
        $state.ChocolateyFailureRepeatCount | Should -Be 0
        Test-Path -LiteralPath $plan | Should -BeFalse -Because 'the failure it described is resolved'
    }

    It 'clears the failure signature when Chocolatey is no longer installed' {
        <# The skip path reported success while leaving the counter set, so the next real
           failure with the same signature went terminal on its first sighting. #>
        Mock Write-Log { }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'choco' }
        $script:InstallDir = $TestDrive
        $script:CurrentState = [pscustomobject]@{ ChocolateyFailureSignature='GoogleChrome:-1:abc'; ChocolateyFailureRepeatCount=1 }

        $result = Update-ChocolateyPackages -Confirm:$false

        $result.Success | Should -BeTrue
        $script:CurrentState.ChocolateyFailureRepeatCount | Should -Be 0
        [string]$script:CurrentState.ChocolateyFailureSignature | Should -BeNullOrEmpty
    }
}

Describe 'Completion claim composition' {
    <# ADR-0003: deferred inventory does not fail a phase, but it does prevent an
       unqualified claim of convergence. The claim string is the log-facing carrier of
       that qualification. Export-BootUpdateDiagnostics matches
       'BOOT UPDATE CYCLE COMPLETE\b', so every claim must keep COMPLETE as its first
       word or a completed cycle stops being recognised as completed. #>

    It 'claims unqualified completion when nothing is outstanding' {
        Get-BootUpdateCompletionClaim -Qualifiers @() | Should -Be 'COMPLETE'
    }

    It 'qualifies the claim when deferred inventory remains' {
        Get-BootUpdateCompletionClaim -Qualifiers @('DEFERRED INVENTORY') |
            Should -Be 'COMPLETE WITH DEFERRED INVENTORY'
    }

    It 'preserves the established single-qualifier claims' {
        Get-BootUpdateCompletionClaim -Qualifiers @('WINGET QUARANTINE') |
            Should -Be 'COMPLETE WITH WINGET QUARANTINE'
        Get-BootUpdateCompletionClaim -Qualifiers @('CLEANUP ADVISORY') |
            Should -Be 'COMPLETE WITH CLEANUP ADVISORY'
    }

    It 'joins two qualifiers with AND' {
        Get-BootUpdateCompletionClaim -Qualifiers @('WINGET QUARANTINE', 'CLEANUP ADVISORY') |
            Should -Be 'COMPLETE WITH WINGET QUARANTINE AND CLEANUP ADVISORY'
    }

    It 'joins three qualifiers with a serial comma' {
        Get-BootUpdateCompletionClaim -Qualifiers @('WINGET QUARANTINE', 'CLEANUP ADVISORY', 'DEFERRED INVENTORY') |
            Should -Be 'COMPLETE WITH WINGET QUARANTINE, CLEANUP ADVISORY, AND DEFERRED INVENTORY'
    }

    It 'orders qualifiers canonically rather than by argument order' {
        <# The claim is written to a log humans and greps read across runs; the same set of
           outstanding work must render identically however the call site assembled it. #>
        Get-BootUpdateCompletionClaim -Qualifiers @('DEFERRED INVENTORY', 'WINGET QUARANTINE') |
            Should -Be 'COMPLETE WITH WINGET QUARANTINE AND DEFERRED INVENTORY'
    }

    It 'ignores empty and duplicate qualifiers' {
        Get-BootUpdateCompletionClaim -Qualifiers @('DEFERRED INVENTORY', '', 'DEFERRED INVENTORY', $null) |
            Should -Be 'COMPLETE WITH DEFERRED INVENTORY'
    }

    It 'always begins with COMPLETE so the diagnostics completion probe still matches' {
        $claim = Get-BootUpdateCompletionClaim -Qualifiers @('WINGET QUARANTINE', 'CLEANUP ADVISORY', 'DEFERRED INVENTORY')
        "BOOT UPDATE CYCLE $claim" | Should -Match '(?im)^\s*(?:\[[^\]]+\]\s*)*BOOT UPDATE CYCLE COMPLETE\b'
    }
}

Describe 'Deferred inventory durability' {
    <# ADR-0003: deferred inventory qualifies the completion claim. The claim is made in
       whichever pass finishes the cycle, but the inventory is observed while a provider
       phase runs — and a phase already marked done does not run again in a later pass. So
       the observation must live in cycle state, not in a per-run variable, or the claim is
       made by a pass that never saw it. #>

    BeforeAll {
        function New-DeferredState { [pscustomobject]@{ DeferredInventory = @() } }
        function Get-RoundTripped {
            param([Parameter(Mandatory)][pscustomobject]$State)
            return ($State | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        }
    }

    It 'records an observation so a later pass can read it back' {
        $state = New-DeferredState
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'TechnologyBlocked'; Count = 1 })
        $actual = @(Get-BootUpdateDeferredInventory -State $state)
        $actual.Count | Should -Be 1
        $actual[0].Provider | Should -Be 'Winget'
        $actual[0].Scope | Should -Be 'machine'
        $actual[0].Kind | Should -Be 'TechnologyBlocked'
    }

    It 'survives the state file round-trip' {
        <# The safety rule requires this assertion across ConvertTo-Json/ConvertFrom-Json:
           literal-only tests cannot see rehydration defects. #>
        $state = New-DeferredState
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'TechnologyBlocked'; Count = 1 })
        $reloaded = Get-RoundTripped $state
        $actual = @(Get-BootUpdateDeferredInventory -State $reloaded)
        $actual.Count | Should -Be 1
        $actual[0].Kind | Should -Be 'TechnologyBlocked'
    }

    It 'returns a single rehydrated record as a collection, not a scalar' {
        <# ConvertTo-Json renders a one-element array as a bare object, so a caller that
           reads .Count off the rehydrated value gets $null and silently claims a clean
           cycle. This is the exact shape of the defect the round-trip rule exists for. #>
        $state = New-DeferredState
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'Pinned'; Count = 2 })
        $reloaded = Get-RoundTripped $state
        $result = Get-BootUpdateDeferredInventory -State $reloaded
        @($result).Count | Should -Be 1
        $result.Count | Should -Not -BeNullOrEmpty -Because 'a collection must report its own Count'
    }

    It 'replaces the prior observation for the same provider and scope' {
        <# A re-run that finds less outstanding work must shrink the inventory, never
           accumulate it, or a resolved deferral would qualify the claim forever. #>
        $state = New-DeferredState
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'Pinned'; Count = 2 })
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'TechnologyBlocked'; Count = 1 })
        $actual = @(Get-BootUpdateDeferredInventory -State $state)
        $actual.Count | Should -Be 1
        $actual[0].Kind | Should -Be 'TechnologyBlocked'
    }

    It 'clears the observation when a re-run finds nothing outstanding' {
        $state = New-DeferredState
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'Pinned'; Count = 2 })
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' -Records @()
        @(Get-BootUpdateDeferredInventory -State $state).Count | Should -Be 0
    }

    It 'keeps observations from other scopes and providers independent' {
        $state = New-DeferredState
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'TechnologyBlocked'; Count = 1 })
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'user' `
            -Records @([pscustomobject]@{ Kind = 'Pinned'; Count = 3 })
        Add-BootUpdateDeferredInventory -State $state -Provider 'Chocolatey' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'Quarantined'; Count = 1 })
        @(Get-BootUpdateDeferredInventory -State $state).Count | Should -Be 3
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'machine' -Records @()
        $remaining = @(Get-BootUpdateDeferredInventory -State $state)
        $remaining.Count | Should -Be 2
        @($remaining | Where-Object { $_.Provider -eq 'Winget' -and $_.Scope -eq 'machine' }).Count | Should -Be 0
    }

    It 'tolerates state that predates the field' {
        <# Continuation across a self-update means a pass can load a checkpoint written by
           an older build that has no DeferredInventory property at all. #>
        $legacy = [pscustomobject]@{ Iteration = 3 }
        @(Get-BootUpdateDeferredInventory -State $legacy).Count | Should -Be 0
        { Add-BootUpdateDeferredInventory -State $legacy -Provider 'Winget' -Scope 'machine' `
            -Records @([pscustomobject]@{ Kind = 'Pinned'; Count = 1 }) } | Should -Not -Throw
        @(Get-BootUpdateDeferredInventory -State $legacy).Count | Should -Be 1
    }
}

Describe 'Completion notification severity' {
    <# The regression this fixes, observed 2026-08-24 17:00 on real hardware: the cycle
       logged "Winget machine: deferred inventory - 1 install-technology blocked"
       (Microsoft.Edge) and then sent a Success toast claiming the machine was up to date.
       The toast is the surface a human actually reads, so it is where the false
       reassurance landed. ADR-0003: nothing failed, so this is not an Error — but it is
       not an unqualified success either. #>

    BeforeAll {
        function New-DeferredRecord {
            param([string]$Kind = 'TechnologyBlocked', [int]$Count = 1, [string]$Detail = '')
            [pscustomobject]@{ Provider = 'Winget'; Scope = 'machine'; Kind = $Kind; Count = $Count; Detail = $Detail }
        }
    }

    It 'claims unqualified success when nothing is outstanding' {
        $actual = Get-BootUpdateCompletionNotification -TotalVerified 3 -DurationMinutes 2.3
        $actual.Kind | Should -Be 'Success'
    }

    It 'does not claim success when deferred inventory remains' {
        $actual = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 2.3 `
            -DeferredInventory @(New-DeferredRecord)
        $actual.Kind | Should -Not -Be 'Success' -Because 'the machine is not fully up to date'
    }

    It 'does not report deferred inventory as an error, because nothing failed' {
        $actual = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 2.3 `
            -DeferredInventory @(New-DeferredRecord)
        $actual.Kind | Should -Not -Be 'Error'
    }

    It 'drops the all-clear wording when deferred inventory remains' {
        <# The unqualified message ends "you are all set", which is a claim of full
           convergence and is false while work is outstanding. #>
        $clean = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 2.3
        $clean.Message | Should -Match 'all set'
        $qualified = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 2.3 `
            -DeferredInventory @(New-DeferredRecord)
        $qualified.Message | Should -Not -Match 'all set'
    }

    It 'names the outstanding work in the message' {
        $actual = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 2.3 `
            -DeferredInventory @(New-DeferredRecord -Kind 'TechnologyBlocked' -Count 1)
        $actual.Message | Should -Match 'Winget'
    }

    It 'preserves the existing quarantine downgrade' {
        $actual = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 2.3 -QuarantineCount 2
        $actual.Kind | Should -Be 'Progress'
        $actual.Message | Should -Match 'pinned'
    }

    It 'reports both when a run carries quarantine and deferred inventory' {
        $actual = Get-BootUpdateCompletionNotification -TotalVerified 1 -DurationMinutes 2.3 `
            -QuarantineCount 1 -DeferredInventory @(New-DeferredRecord)
        $actual.Kind | Should -Be 'Progress'
        $actual.Message | Should -Match 'pinned'
        $actual.Message | Should -Match 'Winget'
    }

    It 'keeps the verified count truthful in every variant' {
        <# Deferred work is never a verified update; qualifying the claim must not inflate
           or suppress the count of things that genuinely changed. #>
        foreach ($deferred in @(@(), @((New-DeferredRecord)))) {
            $actual = Get-BootUpdateCompletionNotification -TotalVerified 7 -DurationMinutes 2.3 `
                -DeferredInventory $deferred
            $actual.Message | Should -Match '\b7\b'
        }
    }
}

Describe 'Deferred inventory summary' {
    It 'summarises one provider scope' {
        Get-BootUpdateDeferredInventorySummary -Records @(
            [pscustomobject]@{ Provider = 'Winget'; Scope = 'machine'; Kind = 'TechnologyBlocked'; Count = 1 }
        ) | Should -Match 'Winget machine'
    }

    It 'reports nothing for an empty inventory' {
        Get-BootUpdateDeferredInventorySummary -Records @() | Should -BeNullOrEmpty
    }

    It 'groups multiple kinds within a scope' {
        $actual = Get-BootUpdateDeferredInventorySummary -Records @(
            [pscustomobject]@{ Provider = 'Winget'; Scope = 'machine'; Kind = 'TechnologyBlocked'; Count = 1 }
            [pscustomobject]@{ Provider = 'Winget'; Scope = 'machine'; Kind = 'Pinned'; Count = 2 }
        )
        $actual | Should -Match 'TechnologyBlocked'
        $actual | Should -Match 'Pinned'
    }
}

Describe 'Repair plan reports deferred inventory' {
    <# ADR-0003 names the repair plan as a carrier of the qualified claim. It is only
       written when the cycle stops for manual attention, so this covers the run that both
       failed something terminally AND left work it could not attempt: the human gets the
       whole picture rather than only the failure. #>

    BeforeEach {
        $script:InstallDir = $TestDrive
        Mock Set-BootUpdateClipboardText { $true }
    }

    It 'states deferred inventory as fact without prescribing a remedy' {
        <# ADR-0001: the plan states facts and options and never steers the reader toward
           weakening a verification boundary. Winget's own advice for an install-technology
           block is "uninstall each package, then install the newer version", which for a
           system component like Edge is actively wrong, so it is not reproduced here. #>
        $result = Write-BootUpdateRepairPlan -Items @(
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=1; Hex='0x1'; Command='winget install --id Corsair.iCUE.5 -e --force' }
        ) -DeferredInventory @(
            [pscustomobject]@{ Provider='Winget'; Scope='machine'; Kind='TechnologyBlocked'; Count=1 }
        )
        $text = (Get-Content -LiteralPath $result.Path) -join "`n"
        $text | Should -Match 'Winget machine'
        $text | Should -Match 'TechnologyBlocked'
        $text | Should -Not -Match '(?i)uninstall each package'
        $text | Should -Not -Match '(?i)ignore-checksums'
    }

    It 'keeps the deferred section out of the copy/paste block' {
        <# The block is consumed verbatim by an elevated Command Prompt; a prose line in it
           is a syntax error at the moment the reader is least able to diagnose one. #>
        $result = Write-BootUpdateRepairPlan -Items @(
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=1; Hex='0x1'; Command='winget install --id Corsair.iCUE.5 -e --force' }
        ) -DeferredInventory @(
            [pscustomobject]@{ Provider='Winget'; Scope='machine'; Kind='TechnologyBlocked'; Count=1 }
        )
        $lines = Get-Content -LiteralPath $result.Path
        $blockStart = [array]::IndexOf($lines,'COPY/PASTE BLOCK — ELEVATED COMMAND PROMPT') + 1
        $block = @($lines | Select-Object -Skip $blockStart)
        @($block | Where-Object { $_ -notmatch '^(?:REM(?:\s|$)|winget\s|upd$)' }).Count | Should -Be 0
    }

    It 'omits the section entirely when nothing was deferred' {
        $result = Write-BootUpdateRepairPlan -Items @(
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=1; Hex='0x1'; Command='winget install --id Corsair.iCUE.5 -e --force' }
        )
        ((Get-Content -LiteralPath $result.Path) -join "`n") | Should -Not -Match '(?i)could not be attempted'
    }
}

Describe 'Deferred inventory records only canonical Winget scopes' {
    <# Write-WingetScopeSummary is also called with synthetic scope labels — "machine-retry"
       for the retry attempt and "machine/<PackageId>" for a targeted single-package run.
       Those are sub-observations of a real scope, not scopes of their own. Recording them
       as separate ledger entries double-reports the same deferral and, because an entry is
       only ever replaced by another summary for the identical label, strands a
       "machine-retry" entry that nothing clears for the rest of the cycle. #>

    BeforeEach {
        $script:CurrentState = [pscustomobject]@{ DeferredInventory = @() }
        $script:WingetResolvedAbsentPath = Join-Path $TestDrive 'winget-resolved-absent.json'
    }

    It 'records the canonical machine scope' {
        $null = Write-WingetScopeSummary -Scope 'machine' -ExitCode 0 -Lines @(
            'Name Id Version Available Source'
            '1 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
        )
        $actual = @(Get-BootUpdateDeferredInventory -State $script:CurrentState)
        $actual.Count | Should -Be 1
        $actual[0].Scope | Should -Be 'machine'
    }

    It 'does not create a separate entry for the retry sub-observation' {
        $lines = @(
            'Name Id Version Available Source'
            '1 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
        )
        $null = Write-WingetScopeSummary -Scope 'machine' -ExitCode 0 -Lines $lines
        $null = Write-WingetScopeSummary -Scope 'machine-retry' -ExitCode 0 -Lines $lines
        $actual = @(Get-BootUpdateDeferredInventory -State $script:CurrentState)
        $actual.Count | Should -Be 1 -Because 'the retry is the same scope, not a second one'
        $actual[0].Scope | Should -Be 'machine'
    }

    It 'does not create a per-package entry for a targeted single-package run' {
        $null = Write-WingetScopeSummary -Scope 'machine/Microsoft.Edge' -ExitCode 0 -Lines @(
            'Name Id Version Available Source'
            '1 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
        )
        @(Get-BootUpdateDeferredInventory -State $script:CurrentState).Count | Should -Be 0
    }

    It 'keeps user and machine as independent canonical scopes' {
        $lines = @(
            'Name Id Version Available Source'
            '1 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
        )
        $null = Write-WingetScopeSummary -Scope 'machine' -ExitCode 0 -Lines $lines
        $null = Write-WingetScopeSummary -Scope 'user' -ExitCode 0 -Lines $lines
        @(Get-BootUpdateDeferredInventory -State $script:CurrentState).Count | Should -Be 2
    }
}


Describe 'Process activity measurement' {
    <# Regression cover for a silent instrument failure: Win32_Process exposes
       ProcessId/ParentProcessId as UInt32 while the traversal queue is Queue[int].
       A Hashtable keyed by UInt32 never matched the Int32 probe, so the walk always
       reported an empty tree with zero CPU. Because the idle timer only advances on
       CPU growth, the idle clock never reset and every package longer than the idle
       threshold was killed mid-install regardless of how busy it was. The observable
       symptom in shipped logs was 'heartbeat: CPU=0s procs=0' for phases that were
       demonstrably working, then 'Tree at kill: 0 processes, handles=0'. #>

    It 'observes a live process tree instead of reporting it empty' {
        <# Measured against this very process: it is guaranteed present in Win32_Process
           and guaranteed to have consumed CPU, so a zero here means the walk is broken
           rather than that the target was quiet. Spawning a child would reintroduce the
           tree-membership instability tracked in -y9es and make this test flaky. #>
        $activity = Get-ProcessTreeActivity -ParentPid $PID
        $activity.ProcessCount |
            Should -BeGreaterThan 0 -Because 'a running process must be visible to the idle detector'
        $activity.HandleCount |
            Should -BeGreaterThan 0 -Because 'an observed process always holds handles'
        $activity.TotalCpuTime.TotalSeconds |
            Should -BeGreaterThan 0 -Because 'a process that has executed must report consumed CPU'
    }

    It 'does not shadow its own root parameter while indexing processes' {
        <# PowerShell variable names are case-insensitive, so a loop local named
           $parentPid overwrites the $ParentPid parameter and silently reroots the walk
           on whichever process CIM enumerated last. That produced readings for one PID
           swinging between 0.08s and 73 minutes. No behavioural assertion catches this
           reliably: a mis-rooted walk still returns a plausible non-zero tree, and an
           observed buggy run reported MORE CPU than the correct one. Assert the shape. #>
        $text = Get-FunctionText $invokeAst 'Get-ProcessTreeActivity'
        $body = $text.Substring($text.IndexOf('$allProcs'))
        $body | Should -Not -Match '(?i)\$parentPid\s*='
        $body | Should -Match '\$childMap\[\$parentKey\]'
    }

    It 'accumulates CPU time for a busy tree so the idle clock can advance' {
        $first = Get-ProcessTreeActivity -ParentPid $PID
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $sink = 0.0
        while ($stopwatch.Elapsed.TotalSeconds -lt 2) { $sink += [math]::Sqrt($stopwatch.ElapsedTicks) }
        $second = Get-ProcessTreeActivity -ParentPid $PID
        $second.TotalCpuTime |
            Should -BeGreaterThan $first.TotalCpuTime -Because 'ongoing work must move the idle detector off its last reading'
    }

    It 'holds the idle clock when the tree cannot be observed' {
        <# Absence of a measurement is not evidence of idleness. msiexec is parented to
           services.exe, so a package whose real work runs out-of-tree legitimately reads
           as zero processes; killing on that reading is how a healthy install dies. #>
        $text = Get-FunctionText $invokeAst 'Wait-ProcessWithIdleTimeout'
        $text | Should -Match '\$activity\.ProcessCount -eq 0'
        $text | Should -Match 'not observable'
        $text.IndexOf('$activity.ProcessCount -eq 0') |
            Should -BeLessThan $text.IndexOf('$idleFor -ge $idleLimit') -Because 'the guard must run before the kill decision'
    }
}

Describe 'Installer exit-code vocabulary' {
    It 'names Windows Installer contention rather than logging it as unknown' {
        <# Six machine-scope packages failed 0x00000652 in one shipped run while a
           concurrent msiexec held the installer mutex. Reported as an opaque hex code
           it read as six unexplained package defects. #>
        Get-InstallerExitSummary -Code 1618 | Should -Match 'already in progress'
    }

    It 'still formats genuinely unknown codes as hex' {
        Get-InstallerExitSummary -Code 123456 | Should -Match '0x0001E240'
    }
}


Describe 'Fast reboot accounting' {
    <# Regression cover for -6qpf, found by VM matrix row A on real hardware-equivalent
       runs. Windows event 6005 recorded three boots; the updater counted two. Two of the
       boots were 96 seconds apart, inside the 120-second boot-session tolerance, so one was
       absorbed as the same session. That count gates the reboot limit, so a fast reboot
       loop could run past the cap - this project's namesake failure. #>

    BeforeEach {
        $script:BootSessionToleranceSeconds = 120
    }

    It 'counts a fast reboot even when uptime crept FORWARD across it' {
        <# The case that defeated the first fix. Uptime only runs backwards if the earlier
           pass ran later in its boot than the current pass does in its own. Observed on the
           lab guest: each pass ran ~40s after its boot, so uptime went 40 -> 45 across a real
           restart and the reboot was missed anyway. The monotonic boot instant does not care
           where in each boot the passes land. #>
        $now = [datetime]::UtcNow
        $firstBoot  = $now.AddMinutes(-3)          # pass 3 ran 40s into this boot
        $secondBoot = $firstBoot.AddSeconds(81)    # real restart, 81s later
        $state = [pscustomobject]@{
            LastBootSessionId   = $firstBoot.ToString('o')
            LastUptimeSeconds   = 40
            LastMonotonicBootId = $firstBoot.ToString('o')
            RebootCount         = 1
            Phase               = 'Rebooting'
            ExplicitRebootRequests = @()
        }
        $updated = Update-BootUpdateStateForBootSession -State $state `
            -CurrentBootSessionId $secondBoot.ToString('o') `
            -CurrentUptimeSeconds 45 `
            -CurrentMonotonicBootId $secondBoot.ToString('o')

        $updated.RebootCount |
            Should -Be 2 -Because 'the boot instant moved 81s even though uptime went 40 -> 45'
    }

    It 'treats a stable monotonic boot instant as one session however the timestamp jitters' {
        $now = [datetime]::UtcNow
        $boot = $now.AddMinutes(-30)
        $state = [pscustomobject]@{
            LastBootSessionId   = $boot.ToString('o')
            LastUptimeSeconds   = 400
            LastMonotonicBootId = $boot.ToString('o')
            RebootCount         = 1
            Phase               = 'Rebooting'
            ExplicitRebootRequests = @()
        }
        # Boot timestamp jitters by 4s; the monotonic instant moves by 2s. Same boot.
        $updated = Update-BootUpdateStateForBootSession -State $state `
            -CurrentBootSessionId $boot.AddSeconds(4).ToString('o') `
            -CurrentUptimeSeconds 460 `
            -CurrentMonotonicBootId $boot.AddSeconds(2).ToString('o')

        $updated.RebootCount | Should -Be 1 -Because 'a couple of seconds of drift is not a restart'
        $updated.LastBootSessionId | Should -Be $boot.ToString('o')
    }

    It 'reconstructs a boot instant that is stable across successive reads' {
        $a = Get-BootUpdateMonotonicBootId
        Start-Sleep -Milliseconds 1500
        $b = Get-BootUpdateMonotonicBootId
        $drift = [math]::Abs((([datetimeoffset]$b) - ([datetimeoffset]$a)).TotalSeconds)
        $drift | Should -BeLessThan 5 -Because 'within one boot the reconstructed instant must barely move'
    }

    It 'counts two boots that fall inside the tolerance window' {
        <# The original row A observation: real boots 96 seconds apart, inside the
           120-second LastBootUpTime tolerance, so the second was absorbed and the
           completed-reboot count under-reported it. #>
        $first  = [datetime]::UtcNow.AddMinutes(-10)
        $second = $first.AddSeconds(96)   # the exact gap observed in row A
        $state = [pscustomobject]@{
            LastBootSessionId   = $first.ToString('o')
            LastUptimeSeconds   = 400
            LastMonotonicBootId = $first.ToString('o')
            RebootCount         = 1
            Phase               = 'Rebooting'
            ExplicitRebootRequests = @()
        }
        $updated = Update-BootUpdateStateForBootSession -State $state `
            -CurrentBootSessionId $second.ToString('o') `
            -CurrentUptimeSeconds 30 `
            -CurrentMonotonicBootId $second.ToString('o')

        $updated.RebootCount |
            Should -Be 2 -Because 'the boot instant moved 96s, far past the 15s monotonic tolerance'
        $updated.LastUptimeSeconds | Should -Be 30
        $updated.LastMonotonicBootId | Should -Be $second.ToString('o')
    }

    It 'still treats same-boot jitter as one session when uptime keeps climbing' {
        <# The protection the tolerance exists for. Repeated LastBootUpTime reads inside one
           boot differ by seconds; treating those as new boots zeroes the same-boot retry
           budget and lets a permanently failing phase retry forever. #>
        $first  = [datetime]::UtcNow.AddMinutes(-10)
        $jitter = $first.AddSeconds(3)
        $state = [pscustomobject]@{
            LastBootSessionId = $first.ToString('o')
            LastUptimeSeconds = 400
            RebootCount       = 1
            Phase             = 'Rebooting'
            ExplicitRebootRequests = @()
        }
        $updated = Update-BootUpdateStateForBootSession -State $state `
            -CurrentBootSessionId $jitter.ToString('o') -CurrentUptimeSeconds 460

        $updated.RebootCount | Should -Be 1 -Because 'uptime advanced, so the machine never restarted'
        $updated.LastBootSessionId |
            Should -Be $first.ToString('o') -Because 'the anchor must not drift with jitter'
    }

    It 'records uptime on same-boot passes so the next comparison is against a fresh reading' {
        <# Anchoring uptime the way LastBootSessionId is anchored would compare a long
           same-boot recovery chain against a stale tiny value and read every pass as a boot. #>
        $boot = [datetime]::UtcNow.AddMinutes(-10)
        $state = [pscustomobject]@{
            LastBootSessionId = $boot.ToString('o')
            LastUptimeSeconds = 100
            RebootCount       = 0
            Phase             = 'Init'
            ExplicitRebootRequests = @()
        }
        $updated = Update-BootUpdateStateForBootSession -State $state `
            -CurrentBootSessionId $boot.ToString('o') -CurrentUptimeSeconds 700
        $updated.LastUptimeSeconds | Should -Be 700
        $updated.RebootCount | Should -Be 0
    }

    It 'reports a monotonic uptime that does not depend on the jittering boot timestamp' {
        $a = Get-BootUpdateUptimeSeconds
        Start-Sleep -Milliseconds 1200
        $b = Get-BootUpdateUptimeSeconds
        $a | Should -BeGreaterThan 0
        $b | Should -BeGreaterOrEqual $a
    }
}


Describe 'Resume account resolution' {
    <# Regression cover for -2jsd, found by VM matrix row B. With nobody signed in,
       resume-user discovery falls through to LogonUI's LastLoggedOnSAMUser, which returns
       the '.\name' form. Task Scheduler cannot map that to a SID, so Register-ScheduledTask
       threw a terminating error, the cycle died right after pre-flight, and no continuation
       task was registered at all - a headless machine could never resume. #>

    It 'resolves every account form Windows might hand back to the same identity' {
        <# The three shapes that reach this function: the '.\name' form LogonUI writes, a
           bare name, and an already-qualified name. All must land on the same principal.
           They resolve to a SID rather than a name because Task Scheduler stores a SID
           regardless, and the SID sidesteps the name grammar that rejects '.\name'. #>
        $expected = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        Resolve-BootUpdateResumeAccount -Account ".\$env:USERNAME"                  | Should -Be $expected
        Resolve-BootUpdateResumeAccount -Account $env:USERNAME                      | Should -Be $expected
        Resolve-BootUpdateResumeAccount -Account "$env:COMPUTERNAME\$env:USERNAME"  | Should -Be $expected
    }
    It 'returns nothing for an account that cannot be resolved, rather than throwing' {
        <# The caller falls back to the SYSTEM-only resume chain on $null. Throwing here is
           what killed the cycle outright, which is strictly worse than a SYSTEM-only
           continuation on a machine with no resolvable user. #>
        Resolve-BootUpdateResumeAccount -Account '.
osuchuser_zzq' | Should -BeNullOrEmpty
    }

    It 'returns nothing for empty input' {
        Resolve-BootUpdateResumeAccount -Account '' | Should -BeNullOrEmpty
        Resolve-BootUpdateResumeAccount -Account $null | Should -BeNullOrEmpty
    }
}

Describe 'Bounded wait for an interactive user' {
    <# Regression cover for the unbounded UserContextPending loop. Scope deferral is defined
       in CONTEXT.md as a handoff to a later user-context pass; on a machine nobody signs
       into there is no later pass, and the cycle retried every two minutes forever, exempt
       from the iteration safety valve. Microsoft documents a device with no signed-in user
       as the *unblocked* servicing path, so never finishing there is a defect. #>

    It 'keeps waiting while the wait budget remains' {
        $state = [pscustomobject]@{ UserIdentityWaitCount = 0 }
        $exhausted = Update-BootUpdateUserIdentityWait -State $state -UserUnknown $true -MaxWaits 3
        $exhausted | Should -BeFalse
        $state.UserIdentityWaitCount | Should -Be 1
    }

    It 'reports exhaustion once the budget is spent' {
        $state = [pscustomobject]@{ UserIdentityWaitCount = 3 }
        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $true -MaxWaits 3 |
            Should -BeTrue -Because 'the fourth attempt exceeds a budget of three'
    }

    It 'never bounds the wait when a user is known' {
        <# The laptop case. A logon-triggered continuation costs nothing and must keep
           waiting: an owner who returns tomorrow has not stopped having a user. #>
        $state = [pscustomobject]@{ UserIdentityWaitCount = 99 }
        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $false -MaxWaits 3 |
            Should -BeFalse
    }

    It 'resets the counter when a user becomes known again' {
        <# Prevents an intermittent identity lookup accumulating its way to a false
           exhaustion on a machine that does have a user. #>
        $state = [pscustomobject]@{ UserIdentityWaitCount = 2 }
        $null = Update-BootUpdateUserIdentityWait -State $state -UserUnknown $false -MaxWaits 3
        $state.UserIdentityWaitCount | Should -Be 0
    }

    It 'starts counting on a state that has never carried the property' {
        $state = [pscustomobject]@{ Phase = 'Running' }
        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $true -MaxWaits 1 | Should -BeFalse
        $state.UserIdentityWaitCount | Should -Be 1
        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $true -MaxWaits 1 | Should -BeTrue
    }

    It 'survives a state-file round trip, so the budget cannot silently reset each pass' {
        <# The counter only bounds anything if it persists across passes; each pass is a
           fresh process reading state back from JSON. #>
        $state = [pscustomobject]@{ UserIdentityWaitCount = 0 }
        1..2 | ForEach-Object {
            $null = Update-BootUpdateUserIdentityWait -State $state -UserUnknown $true -MaxWaits 5
            $state = $state | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        }
        $state.UserIdentityWaitCount | Should -Be 2
        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $true -MaxWaits 5 | Should -BeFalse
    }
}

Describe 'Resume account prefers the recorded SID' {
    <# LogonUI records LastLoggedOnUserSID beside LastLoggedOnSAMUser. The name it writes is
       the '.\user' form, which is outside the documented input grammar of LookupAccountName
       and fails with ERROR_NONE_MAPPED. The SID also covers AzureAD\ and MicrosoftAccount\
       forms that no string expansion would fix, and Task Scheduler normalises a resolvable
       name to a SID on write anyway. #>

    It 'returns the SID when one is recorded, ignoring an unusable name' {
        $mySid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        Resolve-BootUpdateResumeAccount -Account '.\definitely_not_a_user_zzq' -PreferredSid $mySid |
            Should -Be $mySid
    }

    It 'falls back to the name when the recorded SID is unusable' {
        Resolve-BootUpdateResumeAccount -Account $env:USERNAME -PreferredSid 'not-a-sid' |
            Should -Not -BeNullOrEmpty
    }

    It 'resolves a name to a SID rather than returning the name' {
        <# Task Scheduler stores a SID regardless; returning one keeps the value stable across
           an account rename and sidesteps the name grammar entirely. #>
        Resolve-BootUpdateResumeAccount -Account ".\$env:USERNAME" |
            Should -Match '^S-1-5-'
    }

    It 'still yields nothing when neither the SID nor the name resolves' {
        Resolve-BootUpdateResumeAccount -Account '.\nosuchuser_zzq' -PreferredSid 'S-1-5-21-0-0-0-9999' |
            Should -BeNullOrEmpty
    }
}

Describe 'Principal comparison accepts names and SIDs on either side' {
    <# Regression cover for a self-inflicted break. Once the resume account resolved to a
       SID, the resume-chain verifier still converted the EXPECTED value with
       [NTAccount]::Translate, which throws on a SID string. Its fallback then compared the
       leaf name 'updtest' against a full SID, never matched, and threw "wrong principal" -
       so the cycle registered its own continuation tasks and then killed itself one line
       later. Verified on the lab: tasks present, log ending at registration, exit code 1. #>

    It 'normalises an account name to a SID' {
        ConvertTo-BootUpdatePrincipalSid -Value "$env:COMPUTERNAME\$env:USERNAME" |
            Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    }

    It 'passes a SID through unchanged' {
        $sid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        ConvertTo-BootUpdatePrincipalSid -Value $sid | Should -Be $sid
    }

    It 'maps both spellings of SYSTEM to its well-known SID' {
        ConvertTo-BootUpdatePrincipalSid -Value 'SYSTEM'              | Should -Be 'S-1-5-18'
        ConvertTo-BootUpdatePrincipalSid -Value 'NT AUTHORITY\SYSTEM' | Should -Be 'S-1-5-18'
    }

    It 'matches a SID against the name that Task Scheduler reads back' {
        <# The exact shape that broke: expected side a SID, actual side a name. #>
        $sid  = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        $name = "$env:COMPUTERNAME\$env:USERNAME"
        (ConvertTo-BootUpdatePrincipalSid -Value $sid) |
            Should -Be (ConvertTo-BootUpdatePrincipalSid -Value $name)
    }

    It 'returns nothing for an unresolvable value so the caller can fall back' {
        ConvertTo-BootUpdatePrincipalSid -Value 'nosuchprincipal_zzq' | Should -BeNullOrEmpty
        ConvertTo-BootUpdatePrincipalSid -Value 'S-1-5-not-a-sid'     | Should -BeNullOrEmpty
        ConvertTo-BootUpdatePrincipalSid -Value ''                    | Should -BeNullOrEmpty
    }
}

Describe 'Boot instant survives the state file' {
    <# Regression cover for the row B unbounded retry loop. LastMonotonicBootId is persisted,
       and ConvertFrom-Json rehydrates an ISO-8601 string as a [datetime]. Coercing that back
       to text for a parse uses the current culture, which emits no offset, so a UTC instant is
       read as local and the comparison picks up the machine's whole UTC offset instead of
       seconds of jitter. Every same-boot pass then reads as a fresh boot, which zeroes
       ConsecutiveRetryCount, so the same-boot recovery limit never fires and a permanently
       applicable update retries forever. The lab guest ran 7 passes on 2 reboots and only
       stopped when the harness timed out.

       These assertions go through a real ConvertTo-Json/ConvertFrom-Json round-trip. The
       earlier tests fed string literals straight in, which cannot see this class of defect at
       all - the same reason the boot-session tolerance rule already demands round-trip
       assertions. #>

    BeforeEach {
        $script:BootSessionToleranceSeconds = 120
    }

    It 'keeps one boot session across a round-trip when the machine is not on UTC' {
        $boot = [datetime]::UtcNow.AddMinutes(-30)
        $state = [pscustomobject]@{
            LastBootSessionId      = $boot.ToString('o')
            LastUptimeSeconds      = 1800
            LastMonotonicBootId    = $boot.ToString('o')
            RebootCount            = 1
            ConsecutiveRetryCount  = 3
            Phase                  = 'Running'
            ExplicitRebootRequests = @()
        }
        # Exactly what the next pass reads back off disk.
        $rehydrated = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json

        $updated = Update-BootUpdateStateForBootSession -State $rehydrated `
            -CurrentBootSessionId $boot.AddSeconds(2).ToString('o') `
            -CurrentUptimeSeconds 2100 `
            -CurrentMonotonicBootId $boot.AddSeconds(1).ToString('o')

        $updated.ConsecutiveRetryCount |
            Should -Be 3 -Because 'a same-boot recovery pass must not reset the retry budget'
        $updated.RebootCount | Should -Be 1
    }

    It 'still catches a real fast reboot across a round-trip' {
        <# The fix must not buy same-boot stability by going blind to fast restarts, which is
           the defect the monotonic signal was added for in the first place. #>
        $firstBoot  = [datetime]::UtcNow.AddMinutes(-3)
        $secondBoot = $firstBoot.AddSeconds(81)
        $state = [pscustomobject]@{
            LastBootSessionId      = $firstBoot.ToString('o')
            LastUptimeSeconds      = 40
            LastMonotonicBootId    = $firstBoot.ToString('o')
            RebootCount            = 1
            ConsecutiveRetryCount  = 3
            Phase                  = 'Rebooting'
            ExplicitRebootRequests = @()
        }
        $rehydrated = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json

        $updated = Update-BootUpdateStateForBootSession -State $rehydrated `
            -CurrentBootSessionId $secondBoot.ToString('o') `
            -CurrentUptimeSeconds 45 `
            -CurrentMonotonicBootId $secondBoot.ToString('o')

        $updated.RebootCount | Should -Be 2
        $updated.ConsecutiveRetryCount | Should -Be 0 -Because 'a real boot does reset the budget'
    }

    It 'compares a rehydrated [datetime] against an ISO string without inventing an offset' {
        <# The narrowest statement of the bug: the two sides arrive as different types, and the
           helper must normalise both. A local-time [datetime] on an Eastern machine sat about
           4-5 hours from the UTC string it was written from. #>
        $boot = [datetime]::UtcNow.AddMinutes(-30)
        $asDateTime = ([pscustomobject]@{ V = $boot.ToString('o') } | ConvertTo-Json | ConvertFrom-Json).V

        Test-BootUpdateMonotonicBootMoved -Prior $asDateTime -Current $boot.AddSeconds(1).ToString('o') |
            Should -BeFalse -Because 'one second of jitter is not a reboot, whatever the local offset is'

        Test-BootUpdateMonotonicBootMoved -Prior $asDateTime -Current $boot.AddSeconds(81).ToString('o') |
            Should -BeTrue -Because '81 seconds is a real restart'
    }
}

Describe 'Resume identity discovery through the state object' {
    <# -35qb.1. These tests exist because the direct-call tests below could not see the
       defect: Resolve-BootUpdateResumeAccount was always correct, and the SID never
       reached it. The chain that matters is constructor -> discovery -> resolver, so
       that is the chain these walk. #>

    BeforeAll {
        Set-Variable -Name 'BootUpdateStateSchemaVersion' -Value 6 -Scope Script -Force
    }

    It 'declares ResumeUserSid on a freshly constructed state' {
        <# The whole defect in one assertion. A [pscustomobject] throws on assignment to an
           undeclared property, and the discovery assigned this one inside an empty catch,
           so an undeclared property meant a permanently null SID and no symptom. #>
        (New-BootUpdateStateV2).PSObject.Properties.Name | Should -Contain 'ResumeUserSid'
    }

    It 'adds ResumeUserSid to a state written before the property existed' {
        $legacy = New-BootUpdateStateV2
        $legacy.PSObject.Properties.Remove('ResumeUserSid')
        $legacy.PSObject.Properties.Name | Should -Not -Contain 'ResumeUserSid'

        Update-BootUpdateStateSchema -State $legacy

        $legacy.PSObject.Properties.Name | Should -Contain 'ResumeUserSid' -Because 'the add-if-missing normaliser is the other half of the declaration'
    }

    It 'records the LogonUI SID beside the name when nobody is signed in' {
        $state = New-BootUpdateStateV2
        $null = Update-BootUpdateResumeIdentity -State $state `
            -IdentityName 'NT AUTHORITY\SYSTEM' -IdentitySid 'S-1-5-18' `
            -ConsoleUserProvider { $null } `
            -LastLogonProvider { [pscustomobject]@{ Name = '.\updtest'; Sid = 'S-1-5-21-1-2-3-1001' } }

        $state.ResumeUser    | Should -Be '.\updtest'
        $state.ResumeUserSid | Should -Be 'S-1-5-21-1-2-3-1001'
    }

    It 'hands the discovered SID to the resolver, which prefers it over the unusable name' {
        <# The '.\name' form is outside Task Scheduler's input grammar, so on a machine
           where only that name is known the SID is the only thing that resolves. This is
           the AzureAD\ and MicrosoftAccount\ case too, and it was dead in v2.5.78. #>
        $mySid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        $state = New-BootUpdateStateV2
        $null = Update-BootUpdateResumeIdentity -State $state `
            -IdentityName 'NT AUTHORITY\SYSTEM' -IdentitySid 'S-1-5-18' `
            -ConsoleUserProvider { $null } `
            -LastLogonProvider { [pscustomobject]@{ Name = '.\definitely_not_a_user_zzq'; Sid = $mySid } }

        $state.ResumeUserSid | Should -Be $mySid

        Resolve-BootUpdateResumeAccount -Account $state.ResumeUser -PreferredSid ([string]$state.ResumeUserSid) |
            Should -Be $mySid -Because 'the resolver can only prefer a SID the discovery actually recorded'
    }

    It 'takes the running identity directly when a user is signed in' {
        $state = New-BootUpdateStateV2
        $null = Update-BootUpdateResumeIdentity -State $state `
            -IdentityName 'LABHOST\alice' -IdentitySid 'S-1-5-21-1-2-3-500' `
            -ConsoleUserProvider { throw 'the console lookup must not run for an interactive identity' } `
            -LastLogonProvider  { throw 'the LogonUI lookup must not run for an interactive identity' }

        $state.ResumeUser    | Should -Be 'LABHOST\alice'
        $state.ResumeUserSid | Should -Be 'S-1-5-21-1-2-3-500' -Because 'the name and the SID must always describe the same account'
    }

    It 'replaces a SID recorded for a different account rather than leaving it beside the new name' {
        <# The failure this prevents: a SYSTEM pass records LogonUI's SID for one user, a
           later pass runs as another, and the resolver - which prefers the SID absolutely -
           registers the resume task for the first. Harmless while the SID path was dead,
           which is why a fresh-state assertion could not see it. #>
        $state = New-BootUpdateStateV2
        $state.ResumeUser    = 'LABHOST\alice'
        $state.ResumeUserSid = 'S-1-5-21-9-9-9-1001'

        $null = Update-BootUpdateResumeIdentity -State $state `
            -IdentityName 'LABHOST\bob' -IdentitySid 'S-1-5-21-1-2-3-500' `
            -ConsoleUserProvider { throw 'must not look' } -LastLogonProvider { throw 'must not look' }

        $state.ResumeUser    | Should -Be 'LABHOST\bob'
        $state.ResumeUserSid | Should -Be 'S-1-5-21-1-2-3-500' -Because 'a stale SID outranks the fresh name at the resolver'
    }
}

Describe 'No interactive user exhausts the bounded wait and completes with deferred inventory' {
    <# -35qb.4. Only the counter (Update-BootUpdateUserIdentityWait) had cover; the branch
       the counter unlocks had none, and that branch is what the release notes describe as
       producing a qualified claim. grep NoInteractiveUser tests/ returned nothing.

       The three assertions the ticket asks for are split by what can carry them. The
       inventory record and the claim are composed by real functions, so those are driven
       behaviourally. The fall-through - Phase set to Running, no further continuation task
       registered - lives inline in Invoke-BootUpdateCycle, so it is pinned the way this
       file already pins orchestrator-inline invariants, against the function's own text. #>

    BeforeAll {
        $script:MaxUserIdentityWaits = 2
    }

    It 'stops deferring only after the configured number of rediscovery attempts' {
        $state = New-BootUpdateStateV2
        $state.ResumeUser = $null

        <# The production call passes -UserUnknown from an empty ResumeUser, so drive it the
           same way rather than hard-coding $true. #>
        $unknown = [string]::IsNullOrWhiteSpace([string]$state.ResumeUser)
        $unknown | Should -BeTrue

        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $unknown -MaxWaits $script:MaxUserIdentityWaits | Should -BeFalse
        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $unknown -MaxWaits $script:MaxUserIdentityWaits | Should -BeFalse
        Update-BootUpdateUserIdentityWait -State $state -UserUnknown $unknown -MaxWaits $script:MaxUserIdentityWaits |
            Should -BeTrue -Because 'the bound is a bound: the wait ends, it does not repeat forever'
    }

    It 'records the unattemptable user-scope work as NoInteractiveUser deferred inventory' {
        $state = New-BootUpdateStateV2
        $state.ResumeUser = $null
        $phases = @([pscustomobject]@{ Name = 'Winget' }, [pscustomobject]@{ Name = 'Scoop' })

        $exhausted = $false
        while (-not $exhausted) {
            $exhausted = Update-BootUpdateUserIdentityWait -State $state -UserUnknown $true -MaxWaits $script:MaxUserIdentityWaits
        }
        foreach ($phase in $phases) {
            Add-BootUpdateDeferredInventory -State $state -Provider $phase.Name -Scope 'user' -Records @(
                [pscustomobject]@{ Kind = 'NoInteractiveUser'; Count = 1; Detail = 'No interactive user signed in, so user-scope work could not be attempted from this machine.' }
            )
        }

        $inventory = @(Get-BootUpdateDeferredInventory -State $state)
        $inventory.Count | Should -Be 2
        @($inventory | Where-Object Kind -eq 'NoInteractiveUser').Count | Should -Be 2
        @($inventory | Where-Object Scope -eq 'user').Count | Should -Be 2 -Because 'the work was never attemptable in machine scope'
        ($inventory | Where-Object Provider -eq 'Winget').Detail | Should -Match 'No interactive user'

        <# It must survive the state file: the completion that reads it back may be a later
           pass in a different process. #>
        $roundTripped = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        @(Get-BootUpdateDeferredInventory -State $roundTripped | Where-Object Kind -eq 'NoInteractiveUser').Count | Should -Be 2

        Get-BootUpdateDeferredInventorySummary -Records $inventory |
            Should -Match 'Winget user \(NoInteractiveUser=1\)'
    }

    It 'qualifies the completion claim rather than claiming full convergence' {
        $state = New-BootUpdateStateV2
        Add-BootUpdateDeferredInventory -State $state -Provider 'Winget' -Scope 'user' -Records @(
            [pscustomobject]@{ Kind = 'NoInteractiveUser'; Count = 1; Detail = 'No interactive user signed in.' }
        )
        $hasDeferredInventory = @(Get-BootUpdateDeferredInventory -State $state).Count -gt 0
        $hasDeferredInventory | Should -BeTrue

        Get-BootUpdateCompletionClaim -Qualifiers @(if ($hasDeferredInventory) { 'DEFERRED INVENTORY' }) |
            Should -Be 'COMPLETE WITH DEFERRED INVENTORY'

        <# And the surface a human reads must not say all-clear. #>
        $toast = Get-BootUpdateCompletionNotification -TotalVerified 3 -DurationMinutes 12 `
            -DeferredInventory @(Get-BootUpdateDeferredInventory -State $state)
        $toast.Kind | Should -Not -Be 'Error' -Because 'nothing failed; the work was simply not attemptable here'
        $toast.Kind | Should -Be 'Progress' -Because 'a run that could not attempt user-scope work is not an all-clear'
        $toast.Message | Should -Match 'Winget user \(NoInteractiveUser=1\)'
        $toast.Message | Should -Not -Match 'you are all set'
    }

    It 'falls through to the ordinary completion path instead of arming another retry' {
        <# This is assertion (c): the exhausted branch must NOT register a further
           continuation, and must hand the run to the same completion path whose cleanup and
           verification ordering is pinned in 'Evidence-backed completion'. #>
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $start = $text.IndexOf('$identityExhausted = Update-BootUpdateUserIdentityWait')
        $start | Should -BeGreaterThan 0
        $branch = $text.Substring($start, $text.IndexOf('$disposition.Kind -eq ''UserContext'' -and $state.Phase -eq ''UserContextPending''', $start) - $start)

        $exhausted = $branch.Substring($branch.IndexOf('if ($identityExhausted)'), $branch.IndexOf('} else {') - $branch.IndexOf('if ($identityExhausted)'))
        $exhausted | Should -Match "Kind = 'NoInteractiveUser'"
        $exhausted | Should -Match "-Scope 'user'"
        $exhausted | Should -Match "\`$state\.Phase = 'Running'"
        $exhausted | Should -Not -Match 'Register-BootUpdateTaskForReboot' -Because 'an exhausted wait completes; it does not schedule another rediscovery'
        $exhausted | Should -Match 'No interactive user appeared after' -Because 'the lab row reads this line as its evidence that the bound fired'
    }
}

Describe 'A withheld phase is not reported as a crash' {
    <# -9nj2. An unfinished phase leaves one footprint - LastPhaseStarted set, Done false -
       for three different histories, and only one of them is a crash. Lab row B emitted
       "Previous run crashed during [WindowsUpdate]" on every one of seven passes while the
       phase had run correctly and the claim had been withheld on purpose, which makes a
       healthy retry cycle read as repeated crashes in the log and in every diagnostics
       bundle built from it. #>

    BeforeAll {
        $script:CrashLog = [System.Collections.Generic.List[object]]::new()
        function Write-Log { param([string]$Message, [string]$Level, [string]$Visibility)
            $script:CrashLog.Add([pscustomobject]@{ Message = $Message; Level = $Level })
        }
        function New-UnfinishedPhaseState {
            param([string]$Phase)
            $state = New-BootUpdateStateV2
            $state.Phase              = $Phase
            $state.LastPhaseStarted   = 'WindowsUpdate'
            $state.LastPhaseTimestamp = (Get-Date).AddMinutes(-3).ToString('o')
            $state.WindowsUpdateDone  = $false
            return $state
        }
    }

    BeforeEach { $script:CrashLog.Clear() }


    It 'names a deliberately withheld verification as withheld, not as a crash' {
        Test-CrashRecovery -State (New-UnfinishedPhaseState -Phase 'RetryPending') | Should -BeTrue
        $entry = $script:CrashLog[-1]
        $entry.Message | Should -Match 'did not verify \[WindowsUpdate\]'
        $entry.Message | Should -Match 'nothing crashed'
        $entry.Message | Should -Not -Match 'crashed during'
        $entry.Level   | Should -Be 'Info' -Because 'a withhold-and-retry cycle is the design working, not a warning'
    }

    It 'treats a pass still waiting for a user context the same way' {
        Test-CrashRecovery -State (New-UnfinishedPhaseState -Phase 'UserContextPending') | Should -BeTrue
        $script:CrashLog[-1].Message | Should -Not -Match 'crashed during'
    }

    It 'names a planned restart as a restart' {
        Test-CrashRecovery -State (New-UnfinishedPhaseState -Phase 'Rebooting') | Should -BeTrue
        $entry = $script:CrashLog[-1]
        $entry.Message | Should -Match 'restarted Windows during \[WindowsUpdate\]'
        $entry.Message | Should -Not -Match 'crashed during'
    }

    It 'still reports a real crash as a crash' {
        <# Phase left mid-run with no terminal disposition: the process died. This is the
           case the message was written for and it must keep its warning. #>
        Test-CrashRecovery -State (New-UnfinishedPhaseState -Phase 'WindowsUpdate') | Should -BeTrue
        $entry = $script:CrashLog[-1]
        $entry.Message | Should -Match 'Previous run crashed during \[WindowsUpdate\]'
        $entry.Level   | Should -Be 'Warn'
    }

    It 'says nothing at all about a phase that finished' {
        $state = New-UnfinishedPhaseState -Phase 'RetryPending'
        $state.WindowsUpdateDone = $true
        Test-CrashRecovery -State $state | Should -BeFalse
        $script:CrashLog.Count | Should -Be 0
    }
}

Describe 'Every pending-file cleanup probe is recorded, whatever the log does' {
    <# -h2z0. Write-PendingFileRenameAdvisory declines to emit its log line for four
       unrelated reasons and the manifest read all four as the same null. The log line is
       still suppressed where suppression is right; what changed is that the record is
       written first and unconditionally, because the log is no longer the evidence. #>

    BeforeAll {
        $script:PendingCleanupEvidencePath = Join-Path ([IO.Path]::GetTempPath()) ("pending-cleanup-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $script:PendingCleanupProbeIndex = 0
        $script:CurrentState = [pscustomobject]@{ StartTime = '2026-09-09T08:00:00.0000000Z'; Iteration = 2 }
        $script:LastPendingFileCleanupFingerprint = $null

        function Get-CleanupRecords {
            if (-not (Test-Path -LiteralPath $script:PendingCleanupEvidencePath)) { return @() }
            @(Get-Content -LiteralPath $script:PendingCleanupEvidencePath -Raw | ConvertFrom-Json)
        }
        function New-AdvisoryOperation {
            param([string]$Category = 'ApplicationCleanup', [string]$Fingerprint = 'AAAA1111BBBB')
            [pscustomobject]@{ IsBlocking = $false; Category = $Category; Fingerprint = $Fingerprint }
        }
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:PendingCleanupEvidencePath -Force -ErrorAction SilentlyContinue
        $script:LastPendingFileCleanupFingerprint = $null
    }

    AfterAll { Remove-Item -LiteralPath $script:PendingCleanupEvidencePath -Force -ErrorAction SilentlyContinue }

    It 'records an empty advisory set as observed-empty instead of saying nothing' {
        Write-PendingFileRenameAdvisory -Operations @() -Context 'before mutation'
        $records = Get-CleanupRecords
        $records.Count | Should -Be 1
        $records[-1].Observation | Should -Be 'observed-empty'
        $records[-1].Context     | Should -Be 'before mutation'
    }

    It 'records a repeat probe as suppressed-duplicate while still suppressing the log line' {
        $ops = @(New-AdvisoryOperation)
        Write-PendingFileRenameAdvisory -Operations $ops -Context 'before mutation'
        Write-PendingFileRenameAdvisory -Operations $ops -Context 'before mutation'
        $records = Get-CleanupRecords
        $records.Count | Should -Be 2 -Because 'Get-ConfirmedPendingReboot probes twice on purpose'
        $records[0].Observation | Should -Be 'observed-nonempty'
        $records[1].Observation | Should -Be 'suppressed-duplicate'
        $records[1].Fingerprints | Should -Contain 'AAAA1111BBBB' -Because 'a suppressed record still has to carry what it saw'
    }

    It 'keeps the observation content so a later comparison is possible' {
        Write-PendingFileRenameAdvisory -Operations @(New-AdvisoryOperation) -Context 'after updates'
        $record = (Get-CleanupRecords)[-1]
        $record.Categories.ApplicationCleanup | Should -Be 1
        $record.Pass       | Should -Be 2
        <# ConvertFrom-Json rehydrates an ISO-8601 value as [datetime], so the session key
           has to be normalised before it is compared - the trap this repo has been bitten
           by before with LastBootSessionId. #>
        ConvertTo-BootUpdateTimestampString -Value $record.SessionId | Should -Be '2026-09-09T08:00:00.0000000Z'
        $record.Source     | Should -Be 'two-probe'
        $record.ProbeIndex | Should -BeGreaterThan 0
    }

    It 'ignores blocking operations, which are not cleanup advisories' {
        Write-PendingFileRenameAdvisory -Context 'before mutation' -Operations @(
            [pscustomobject]@{ IsBlocking = $true; Category = 'RealRename'; Fingerprint = 'CCCC2222DDDD' }
        )
        (Get-CleanupRecords)[-1].Observation | Should -Be 'observed-empty'
    }

    It 'appends across passes rather than overwriting the previous observation' {
        Write-PendingFileRenameAdvisory -Operations @() -Context 'before mutation'
        $script:CurrentState.Iteration = 3
        Write-PendingFileRenameAdvisory -Operations @(New-AdvisoryOperation) -Context 'after updates'
        $records = Get-CleanupRecords
        $records.Count | Should -Be 2
        @($records.Pass) | Should -Be @(2,3) -Because 'whether a fingerprint survived a restart is only answerable across passes'
        $script:CurrentState.Iteration = 2
    }

    It 'writes the record even under -WhatIf, which is the whole point of an evidence lifecycle' {
        <# Behavioural, not a source-text match, because a source-text match is what let the
           last claim of this kind survive a release. Set-Content implements ShouldProcess and
           therefore obeys $WhatIfPreference like any other cmdlet: without an explicit
           -WhatIf:$false the artifact was never written under -WhatIf, the phase-skipped
           record that exists only for that path recorded nothing, and the exporter then
           stamped unknown-legacy-log on a current-format bundle - which ADR-0004 names as a
           bug. "The phase did not run" is precisely the state this artifact was created to be
           able to state. #>
        $WhatIfPreference = $true
        Add-BootUpdatePendingCleanupRecord -Context 'after updates' -Observation 'phase-skipped' -Source 'whatif'

        Test-Path -LiteralPath $script:PendingCleanupEvidencePath | Should -BeTrue -Because 'evidence is not a mutation the run is asked to simulate'
        $record = (Get-CleanupRecords)[-1]
        $record.Observation | Should -Be 'phase-skipped'
        $record.Source      | Should -Be 'whatif'
    }

    It 'never lets a recording failure break the run' {
        $saved = $script:PendingCleanupEvidencePath
        try {
            $script:PendingCleanupEvidencePath = 'Z:\no-such-volume\pending-cleanup.json'
            { Write-PendingFileRenameAdvisory -Operations @() -Context 'before mutation' } | Should -Not -Throw
        } finally { $script:PendingCleanupEvidencePath = $saved }
    }
}

Describe 'An explicit 3010 records pending-file state instead of skipping it' {
    <# -qibm. Get-ConfirmedPendingReboot returns early on an explicit 3010/1641 request,
       before Test-PendingReboot and before the cleanup advisory. That short-circuit is
       correct - the evidence is durable for the process and must not pay for two probes and
       a 20-second settle - but it also skipped the RECORDING, and it fires precisely when
       real servicing has just happened, which is when the pending-file evidence is most
       worth capturing. A reboot was about to occur and the bundle said nothing about what
       was queued to be deleted across it. #>

    BeforeAll {
        $script:PendingCleanupEvidencePath = Join-Path ([IO.Path]::GetTempPath()) ("qibm-cleanup-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $script:PendingCleanupProbeIndex = 0
        $script:CurrentState = [pscustomobject]@{ StartTime = '2026-09-09T09:00:00.0000000Z'; Iteration = 4 }
        $script:RebootSignalSettleSeconds = 20

        function Get-CleanupRecords {
            if (-not (Test-Path -LiteralPath $script:PendingCleanupEvidencePath)) { return @() }
            @(Get-Content -LiteralPath $script:PendingCleanupEvidencePath -Raw | ConvertFrom-Json)
        }
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:PendingCleanupEvidencePath -Force -ErrorAction SilentlyContinue
        $script:LastPendingFileCleanupFingerprint = $null
        $script:LastPendingFileRenameOperations = @()
        $script:ExplicitRebootRequests = [System.Collections.Generic.List[object]]::new()
        $script:SettleWaits = 0
        $script:ProbeCount = 0
        function Wait-BootUpdateUiInterval { param($Seconds,$Activity,$Status,$PercentComplete) $script:SettleWaits++ }
        function Test-PendingReboot { $script:ProbeCount++; @() }
        function Update-BootUpdatePendingFileRenameSnapshot {
            $script:LastPendingFileRenameOperations = @(
                [pscustomobject]@{ IsBlocking = $false; Category = 'ApplicationCleanup'; Fingerprint = 'EEEE3333FFFF' }
            )
            return @($script:LastPendingFileRenameOperations)
        }
    }

    AfterAll { Remove-Item -LiteralPath $script:PendingCleanupEvidencePath -Force -ErrorAction SilentlyContinue }

    It 'records what was queued for deletion before returning the explicit request' {
        $script:ExplicitRebootRequests.Add([pscustomobject]@{ Source = 'Chocolatey'; Detail = 'exit 3010' })

        $result = @(Get-ConfirmedPendingReboot -Context 'before mutation')

        $result.Count | Should -Be 1
        $result[0].Source | Should -Be 'Chocolatey' -Because 'the short-circuit itself must be unchanged'
        $records = Get-CleanupRecords
        $records.Count | Should -Be 1
        $records[-1].Observation | Should -Be 'observed-nonempty' -Because 'not-probed was the whole complaint'
        $records[-1].Context     | Should -Be 'before mutation'
        $records[-1].Fingerprints | Should -Contain 'EEEE3333FFFF'
    }

    It 'marks the record as taken on the explicit-reboot path' {
        $script:ExplicitRebootRequests.Add([pscustomobject]@{ Source = 'Winget'; Detail = 'exit 1641' })
        $null = Get-ConfirmedPendingReboot -Context 'after updates'
        (Get-CleanupRecords)[-1].Source | Should -Be 'explicit-reboot' -Because 'a reader must be able to tell this from a full two-probe confirmation'
    }

    It 'introduces no settle wait and no second pending-reboot probe on that path' {
        $script:ExplicitRebootRequests.Add([pscustomobject]@{ Source = 'Chocolatey'; Detail = 'exit 3010' })
        $null = Get-ConfirmedPendingReboot -Context 'after updates'
        $script:SettleWaits | Should -Be 0 -Because 'explicit 3010/1641 evidence is durable and must not pay for the wait'
        $script:ProbeCount  | Should -Be 0 -Because 'the bypass of the two-probe confirmation is the behaviour being preserved'
    }

    It 'still runs the ordinary two-probe confirmation when no explicit request exists' {
        $null = Get-ConfirmedPendingReboot -Context 'after updates'
        $script:ProbeCount  | Should -Be 2
        $script:SettleWaits | Should -Be 1
    }
}

Describe 'A killed package tree does not race the installer it orphaned' {
    <# -ynvn. Remove-ProcessTree kills the provider and its descendants, but msiexec.exe is
       parented to services.exe and is not in that tree. Observed 2026-09-06: a killed
       Acrobat Reader install left msiexec PID 41352 alive for 28 minutes and six
       machine-scope packages in the following passes failed 0x652 = 1618 against the
       updater's own orphan - three iterations, 39.6 minutes. Killing harder is not the
       answer; tearing down an MSI transaction mid-write is how a machine ends up with a
       half-installed product. The cycle waits for the transaction instead.

       These tests drive a private mutex rather than Global\_MSIExecute. A test has no
       business creating the machine-wide Windows Installer mutex: doing so would make
       every real installer on the host believe an installation was in progress. #>

    BeforeAll {
        function New-TestMutexName { 'Local\boot-upd-test-{0}' -f [guid]::NewGuid().ToString('N') }

        <# Held in a separate thread job, because a mutex is reentrant for its owning
           thread: acquiring it on this thread would report free and the test would prove
           nothing. The job signals through a file so the assertion cannot run before the
           mutex is actually held. #>
        function Start-MutexHolder {
            param([string]$Name, [string]$SignalPath, [int]$HoldSeconds = 30)
            $job = Start-ThreadJob -ArgumentList $Name, $SignalPath, $HoldSeconds -ScriptBlock {
                param($Name, $SignalPath, $HoldSeconds)
                $mutex = [System.Threading.Mutex]::new($false, $Name)
                $null = $mutex.WaitOne()
                Set-Content -LiteralPath $SignalPath -Value 'held'
                $deadline = (Get-Date).AddSeconds($HoldSeconds)
                while ((Get-Date) -lt $deadline -and (Test-Path -LiteralPath $SignalPath)) { Start-Sleep -Milliseconds 100 }
                $mutex.ReleaseMutex(); $mutex.Dispose()
            }
            $waited = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $SignalPath) -and $waited.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 50 }
            return $job
        }
        function Stop-MutexHolder {
            param($Job, [string]$SignalPath)
            Remove-Item -LiteralPath $SignalPath -Force -ErrorAction SilentlyContinue
            $null = Wait-Job $Job -Timeout 15
            Remove-Job $Job -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        $script:UiWaits = 0
        function Wait-BootUpdateUiInterval { param($Seconds,$Activity,$Status,$PercentComplete) $script:UiWaits++ }
        $script:Logged = [System.Collections.Generic.List[object]]::new()
        function Write-Log { param([string]$Message,[string]$Level,[string]$Visibility) $script:Logged.Add([pscustomobject]@{ Message=$Message; Level=$Level }) }
    }

    It 'reports no transaction when the mutex does not exist' {
        Test-BootUpdateInstallerMutexHeld -MutexName (New-TestMutexName) | Should -BeFalse
    }

    It 'reports no transaction for a mutex that exists but is free' {
        $name = New-TestMutexName
        $mutex = [System.Threading.Mutex]::new($false, $name)
        try { Test-BootUpdateInstallerMutexHeld -MutexName $name | Should -BeFalse -Because 'existing is not the same as held' }
        finally { $mutex.Dispose() }
    }

    It 'reports a transaction in progress while the mutex is held elsewhere' {
        $name = New-TestMutexName
        $signal = Join-Path ([IO.Path]::GetTempPath()) ("mutex-held-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $job = Start-MutexHolder -Name $name -SignalPath $signal
        try {
            Test-Path -LiteralPath $signal | Should -BeTrue -Because 'the holder must actually hold it before this asserts anything'
            Test-BootUpdateInstallerMutexHeld -MutexName $name | Should -BeTrue
        } finally { Stop-MutexHolder -Job $job -SignalPath $signal }
    }

    It 'returns at once and says nothing when no transaction is in progress' {
        Wait-BootUpdateInstallerMutex -MutexName (New-TestMutexName) -TimeoutMinutes 1 -PollSeconds 0.2 | Should -BeTrue
        $script:UiWaits | Should -Be 0 -Because 'the ordinary path must not pay for this check'
        $script:Logged.Count | Should -Be 0
    }

    It 'waits, bounded, and admits it when the transaction outlives the bound' {
        $name = New-TestMutexName
        $signal = Join-Path ([IO.Path]::GetTempPath()) ("mutex-held-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $job = Start-MutexHolder -Name $name -SignalPath $signal
        try {
            Test-Path -LiteralPath $signal | Should -BeTrue
            Wait-BootUpdateInstallerMutex -MutexName $name -TimeoutMinutes (3/60) -PollSeconds 0.2 |
                Should -BeFalse -Because 'a wait that can run forever is not a recovery'
            $script:UiWaits | Should -BeGreaterThan 0
            @($script:Logged | Where-Object { $_.Message -match 'still in progress after' -and $_.Level -eq 'Warn' }).Count |
                Should -BeGreaterThan 0 -Because 'a caller that proceeds anyway must be able to say the transaction was still held'
        } finally { Stop-MutexHolder -Job $job -SignalPath $signal }
    }

    It 'returns as soon as the orphaned transaction finishes' {
        $name = New-TestMutexName
        $signal = Join-Path ([IO.Path]::GetTempPath()) ("mutex-held-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $job = Start-MutexHolder -Name $name -SignalPath $signal -HoldSeconds 2
        try {
            Test-Path -LiteralPath $signal | Should -BeTrue
            Wait-BootUpdateInstallerMutex -MutexName $name -TimeoutMinutes 1 -PollSeconds 0.2 |
                Should -BeTrue -Because 'the point is to resume the moment the machine is free, not to sleep out a fixed delay'
            @($script:Logged | Where-Object { $_.Message -match 'finished; continuing' }).Count | Should -Be 1
        } finally { Stop-MutexHolder -Job $job -SignalPath $signal }
    }

    It 'waits for the orphan on both timeout kill paths, after the tree kill' {
        <# The kill and the wait are inline in Wait-ProcessWithIdleTimeout, so the ordering
           invariant is pinned against the function's own text the way this file already
           pins orchestrator-inline invariants. Order matters: waiting before the kill would
           wait on the transaction the cycle is about to terminate. #>
        $text = Get-FunctionText $invokeAst 'Wait-ProcessWithIdleTimeout'
        ([regex]::Matches($text, 'Wait-BootUpdateInstallerMutex')).Count | Should -Be 2
        foreach ($reason in @('HardTimeout','IdleTimeout')) {
            $at = $text.IndexOf("Reason = '$reason'")
            $at | Should -BeGreaterThan 0
            $kill = $text.LastIndexOf('Remove-ProcessTree -RootPid $Process.Id', $at)
            $wait = $text.LastIndexOf('Wait-BootUpdateInstallerMutex', $at)
            $kill | Should -BeGreaterThan 0
            $wait | Should -BeGreaterThan $kill -Because 'the wait is for what the kill left behind'
        }
    }
}

Describe 'An update the machine says it installed and offers again is inventory, not retry fuel' {
    <# -k610. On the lab image KB5007651, the Windows Security platform update, installs,
       genuinely advances the platform, is recorded by Windows Update with result code 2, and
       is offered again by the very next scan. Diagnosed 2026-09-09 from
       C:\HyperV\evidence\k610-diagnosis-20260909-083408: AMProductVersion moved
       4.18.23110.3 -> 4.18.26080.3 and a Platform directory 4.18.26080.3-0 appeared where
       there had been none, while WU history gained five KB5007651 entries, every one result
       code 2 - and the update stayed applicable. Six passes, no convergence, the whole
       budget spent in a loop the machine cannot exit.

       So the environment re-offers it. The truthful response is to name it as deferred
       inventory and qualify the claim, not to retry forever and not to pretend it converged.
       Only result code 2 qualifies: a failed install is a real failure and stays retryable,
       which is the whole reason for reading the result code rather than a log line. #>

    BeforeAll {
        $script:Boot = [datetime]::new(2026, 9, 9, 12, 40, 0, [System.DateTimeKind]::Utc)
        $script:Kb5007651 = 'Update for Windows Security platform - KB5007651 (Version 10.0.29628.1000)'
        function New-HistoryEntry {
            param([string]$Title, [int]$ResultCode = 2, [datetime]$At)
            [pscustomobject]@{ Title = $Title; ResultCode = $ResultCode; InstalledAt = $At }
        }
    }

    It 'classifies an update installed successfully in this boot and offered again' {
        $history = @(
            (New-HistoryEntry -Title $script:Kb5007651 -At $script:Boot.AddMinutes(6)),
            (New-HistoryEntry -Title $script:Kb5007651 -At $script:Boot.AddMinutes(35))
        )
        $records = @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) -History $history -SinceUtc $script:Boot)

        $records.Count | Should -Be 1
        $records[0].KB | Should -Be 'KB5007651' -Because 'the record has to name the update a human will go looking for'
        $records[0].Installs | Should -Be 2
        $records[0].LastSuccess | Should -Be $script:Boot.AddMinutes(35)
    }

    It 'leaves a genuinely outstanding update alone' {
        $records = @(Get-WindowsUpdateReofferedAfterSuccess `
            -Applicable @('2026-09 Security Update (KB5124008) (26100.9445)') `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $script:Boot.AddMinutes(6))) `
            -SinceUtc $script:Boot)
        $records.Count | Should -Be 0 -Because 'an update nobody has installed is work, not inventory'
    }

    It 'does not excuse a failed install' {
        foreach ($code in 3, 4, 5) {
            $records = @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) `
                -History @((New-HistoryEntry -Title $script:Kb5007651 -ResultCode $code -At $script:Boot.AddMinutes(6))) `
                -SinceUtc $script:Boot)
            $records.Count | Should -Be 0 -Because "result code $code is not success, and a failure must stay retryable"
        }
    }

    It 'does not count a success from before the window' {
        <# A success from before the run began proves nothing about it, and accepting one
           would let a stale record suppress real work indefinitely. #>
        $records = @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $script:Boot.AddMinutes(-20))) `
            -SinceUtc $script:Boot)
        $records.Count | Should -Be 0
    }

    It 'counts a success from an earlier boot of the same run' {
        <# The defect lab row B found on the second guest. The update installs successfully,
           the cycle reboots for an unrelated pending signal, and the final scan in the next
           boot re-offers it. Under a boot-scoped window there is no success "since this boot",
           so the re-offer read as outstanding work and the cycle withheld, retried, rebooted
           and looped - six passes, no convergence, 45-minute timeout. The first guest
           converged only because its installs and its final scan happened to land in the same
           boot. The window has to be the run. #>
        $runStart   = $script:Boot.AddMinutes(-30)
        $installedBeforeTheReboot = $script:Boot.AddMinutes(-10)

        @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $installedBeforeTheReboot)) `
            -SinceUtc $script:Boot).Count |
            Should -Be 0 -Because 'this is what the boot-scoped window saw, and why the row looped'

        $records = @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $installedBeforeTheReboot)) `
            -SinceUtc $runStart)
        $records.Count | Should -Be 1
        $records[0].KB | Should -Be 'KB5007651'
    }

    It 'takes the window from the run, falling back to the boot instant when there is no run' {
        <# Pinned at the call site: the caller chooses the window, and choosing the boot
           instant is what broke it. The fallback is stricter than the run, never looser. #>
        $text = Get-FunctionText $invokeAst 'Test-WindowsUpdateConvergence'
        $text | Should -Match '-SinceUtc \$sessionStart'
        $text | Should -Match '\$script:CurrentState\.StartTime'
        $text | Should -Match 'ConvertTo-BootUpdateTimestampString -Value \$script:CurrentState\.StartTime'
        $text | Should -Not -Match '-SinceUtc \$bootInstant'
    }

    It 'treats an Unspecified-kind history date as the UTC it already is' {
        <# Caught in row B's own log: an install that happened at 14:12:42Z was reported as
           18:12:42Z, the local offset added twice. IUpdateHistoryEntry::Date is documented
           UTC but arrives from COM with DateTimeKind Unspecified, and a blind
           ToUniversalTime() shifts it. The printed timestamp was the visible symptom; the
           real hazard is that the same shift lets a success from up to one offset BEFORE
           the last boot pass a since-boot test, and suppress work that is genuinely
           outstanding. #>
        $installedUtc = [datetime]::new(2026, 9, 9, 14, 12, 42, [System.DateTimeKind]::Unspecified)
        $records = @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $installedUtc)) `
            -SinceUtc $script:Boot)

        $records.Count | Should -Be 1
        $records[0].LastSuccess.ToString('yyyy-MM-dd HH:mm:ss') | Should -Be '2026-09-09 14:12:42' -Because 'the reported moment must be the one the machine recorded'
        $records[0].LastSuccess.Kind | Should -Be ([System.DateTimeKind]::Utc)
    }

    It 'does not let the local offset drag a pre-boot success across the boot line' {
        <# One minute before the boot, tagged Unspecified. Under the old blind conversion an
           offset-hours shift would have carried it past SinceUtc and excused an update
           nobody had installed since the restart. #>
        $justBeforeBoot = [datetime]::SpecifyKind($script:Boot.AddMinutes(-1), [System.DateTimeKind]::Unspecified)
        @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $justBeforeBoot)) `
            -SinceUtc $script:Boot).Count | Should -Be 0
    }

    It 'still accepts a genuinely Local-kind moment by converting it' {
        $localNow = [datetime]::SpecifyKind($script:Boot.AddMinutes(30).ToLocalTime(), [System.DateTimeKind]::Local)
        @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $localNow)) `
            -SinceUtc $script:Boot).Count | Should -Be 1
    }

    It 'reports nothing when the history is unreadable' {
        @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651) -History @() -SinceUtc $script:Boot).Count |
            Should -Be 0 -Because 'no history is no evidence; the update stays outstanding and retryable'
    }

    It 'separates re-offers from real work when both are present' {
        $real = '2026-09 .NET Framework Security Update (KB5126052)'
        $records = @(Get-WindowsUpdateReofferedAfterSuccess -Applicable @($script:Kb5007651, $real) `
            -History @((New-HistoryEntry -Title $script:Kb5007651 -At $script:Boot.AddMinutes(6))) `
            -SinceUtc $script:Boot)
        $records.Count | Should -Be 1
        $records[0].Title | Should -Be $script:Kb5007651
    }

    It 'withholds convergence while any update is unexplained, and qualifies it when none is' {
        <# The call-site rule, pinned against the orchestrator's own text: the withhold is
           driven by Unexplained, not by the raw applicable count, and the qualified branch
           records deferred inventory instead of clearing WindowsUpdateDone. #>
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\[int\]\$wuConvergence\.Unexplained -gt 0'
        $text | Should -Match "Kind   = 'ReofferedAfterSuccess'"
        $text | Should -Match 'Windows Update convergence qualified'

        $start = $text.IndexOf('$wuConvergence = Test-WindowsUpdateConvergence')
        $start | Should -BeGreaterThan 0
        $block = $text.Substring($start, $text.IndexOf('$incompletePhases = @($enabledPhases', $start) - $start)
        $qualified = $block.Substring($block.IndexOf('} elseif ($reoffered.Count -gt 0) {'))
        $qualified | Should -Not -Match '\$state\.WindowsUpdateDone = \$false' -Because 'a re-offer is not an incomplete phase, so it must not become retry fuel'

        <# And a clean pass must retract a previous pass's observation, or resolved work would
           qualify the claim for the rest of the cycle. #>
        $block | Should -Match "Add-BootUpdateDeferredInventory -State \`$state -Provider 'WindowsUpdate' -Scope 'machine' -Records @\(\)"
    }

    It 'produces a qualified claim from that inventory, not an all-clear' {
        $state = New-BootUpdateStateV2
        Add-BootUpdateDeferredInventory -State $state -Provider 'WindowsUpdate' -Scope 'machine' -Records @(
            [pscustomobject]@{ Kind = 'ReofferedAfterSuccess'; Count = 1; Detail = 'KB5007651 was installed successfully 5 time(s) in this boot session.' }
        )
        $inventory = @(Get-BootUpdateDeferredInventory -State $state)
        $inventory.Count | Should -Be 1
        $inventory[0].Kind | Should -Be 'ReofferedAfterSuccess'

        Get-BootUpdateCompletionClaim -Qualifiers @('DEFERRED INVENTORY') | Should -Be 'COMPLETE WITH DEFERRED INVENTORY'
        $toast = Get-BootUpdateCompletionNotification -TotalVerified 4 -DurationMinutes 20 -DeferredInventory $inventory
        $toast.Kind | Should -Be 'Progress'
        $toast.Message | Should -Not -Match 'you are all set'
    }
}

Describe 'A pass that followed no reboot does not say it resumed after one' {
    <# Found in matrix row D (-n6qn) on 2026-09-09, evidence dir
       C:\HyperV\evidence\D-failed-restart-lab-b-20260909-092536. With shutdown.exe rejecting
       every restart, five passes each announced "BOOT UPDATE CYCLE RESUMED (after reboot)"
       while the same line correctly reported "Reboots: 0/5". The counter was right and the
       banner beside it was not - the same family of defect as -9nj2, where a deliberate
       withhold was announced as a crash. #>

    It 'chooses the banner verb from the boot observation, not from the pass number' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match "elseif \(\`$newBootObserved\) \{ 'RESUMED \(after reboot\)' \}"
        $text | Should -Match "else \{ 'RESUMED \(same boot\)' \}"
        <# The observation must be established before the banner reads it. Both offsets are
           required to be real first: an IndexOf that returns -1 for a string the code no
           longer contains makes this assertion pass no matter what the order is, which is
           exactly what happened when the boot-session restructure landed a commit later. #>
        $observationAt = $text.IndexOf('$newBootObserved = $bootObservation.NewBoot')
        $bannerAt      = $text.IndexOf('$cycleVerb = if ($isFirstIteration)')
        $observationAt | Should -BeGreaterThan 0
        $bannerAt      | Should -BeGreaterThan 0
        $observationAt | Should -BeLessThan $bannerAt
    }

    It 'keeps both spellings matchable by everything that greps for a pass' {
        <# The lab harness counts passes with 'BOOT UPDATE CYCLE (STARTED|RESUMED)' and the
           diagnostics exporter detects a session the same way, so the new wording must stay
           inside that prefix or a same-boot retry chain would become invisible. #>
        foreach ($verb in 'RESUMED (after reboot)', 'RESUMED (same boot)') {
            "BOOT UPDATE CYCLE $verb | Session: x | Pass: 2" |
                Should -Match 'BOOT UPDATE CYCLE (STARTED|RESUMED)'
            "[2026-09-09 09:34:47] [Info] BOOT UPDATE CYCLE $verb | Pass: 2" |
                Should -Match '(?im)^\s*(?:\[[^\]]+\]\s*)*BOOT UPDATE CYCLE (?:STARTED|RESUMED)\b'
        }
    }
}

Describe 'The bounded wait is about an absent session, not an unknown name' {
    <# Found on lab-a on 2026-09-09, evidence
       C:\HyperV\evidence\B-k610-fix-boot-upd-matrix-20260909-093402. Making the resume-SID
       preference work (it had been dead code) had a consequence nobody predicted: on a guest
       nobody signs into, LogonUI still records a PAST session, so ResumeUser became populated
       and the cycle concluded a user was known. It then waited on a logon trigger that will
       never fire, took no further pass, and sat at UserContextPending with both tasks armed
       and nothing to fire them - the exact unbounded wait MaxUserIdentityWaits exists to
       prevent, reintroduced through the back door.

       The question the bound must ask is whether a user-context pass can still happen. #>

    It 'treats a cycle running as the user as an interactive session, without looking further' {
        Test-BootUpdateInteractiveUserPresent -ConsoleUserProvider { throw 'a user-context pass must not need to look' } |
            Should -BeTrue -Because 'this cycle IS the interactive session'
    }

    It 'reports no interactive user when SYSTEM finds no console session' {
        <# Only meaningful when the test itself is not SYSTEM, which it is not. #>
        $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
        $isSystem | Should -BeFalse -Because 'the gate runs elevated but as a user'
    }

    It 'bounds the wait for a machine with no session and never bounds one with a session' {
        <# The decision the orchestrator makes, exercised through the counter it drives. A
           headless machine reaches exhaustion; a machine with a signed-in user never does,
           however many passes go by. #>
        $headless = New-BootUpdateStateV2
        $headless.ResumeUser = 'LABHOST\updtest'   # known, from a past session - and irrelevant
        $exhausted = $false
        for ($i = 0; $i -lt 5 -and -not $exhausted; $i++) {
            $exhausted = Update-BootUpdateUserIdentityWait -State $headless -UserUnknown $true -MaxWaits 2
        }
        $exhausted | Should -BeTrue -Because 'a machine nobody signs into must be able to finish'

        $attended = New-BootUpdateStateV2
        $attended.ResumeUser = 'LABHOST\alice'
        for ($i = 0; $i -lt 20; $i++) {
            Update-BootUpdateUserIdentityWait -State $attended -UserUnknown $false -MaxWaits 2 |
                Should -BeFalse -Because 'a laptop whose owner is signed in has a pass coming, and waiting costs nothing'
        }
    }

    It 'drives the bound from the session test rather than from ResumeUser' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$retryForUnknownUser = -not \(Test-BootUpdateInteractiveUserPresent\)'
        $text | Should -Not -Match '\$retryForUnknownUser = \[string\]::IsNullOrWhiteSpace\(\[string\]\$state\.ResumeUser\)'
        <# The same flag still decides whether a dated retry is armed. Without it no further
           pass runs, the counter never advances, and the bound can never be reached - which
           is precisely how the headless guest came to sit there. #>
        $text | Should -Match 'Register-BootUpdateTaskForReboot -RetrySoon:\$retryForUnknownUser'
    }
}

Describe 'The dated watchdog trigger is actually armed' {
    <# Found by matrix row C on 2026-09-09, evidence
       C:\HyperV\evidence\C-cancelled-restart-v3-lab-b-20260909-101428. Start-BootUpdateRestart
       arms a dated watchdog before every restart, for the case the code comment names: if
       the user takes the documented `shutdown /a` escape hatch, neither startup nor logon
       fires, so a time trigger is what keeps the chain alive. It had never been armed.

       The parameter was declared [Nullable[datetime]], but PowerShell's parameter binder
       converts that to a plain System.DateTime. The bound variable has no HasValue member,
       so `$RetryAt.HasValue` evaluated to $null - never $true - and the retry trigger was
       always $null. On the guest, after the cancel, Export-ScheduledTask showed exactly one
       LogonTrigger and nothing else; the task never ran and the cycle sat there for the
       whole 40-minute row. -RetrySoon is a [switch], so the two-minute retries everywhere
       else kept working and hid this for every release that shipped it. #>

    It 'reproduces the binder behaviour the old test relied on' {
        <# Stated as a test because it is the entire cause and it is counter-intuitive:
           declaring [Nullable[datetime]] does not give you a Nullable at the other end. #>
        function Test-NullableBinding { param([Nullable[datetime]]$Value = $null) $Value }
        $bound = Test-NullableBinding -Value ([datetime]'2026-09-09T10:23:42')
        $bound.GetType().Name | Should -Be 'DateTime'
        $bound.HasValue | Should -BeNullOrEmpty -Because 'a System.DateTime has no HasValue member, so the old guard could never be true'
        ($null -ne $bound) | Should -BeTrue -Because 'a null test is what actually distinguishes supplied from omitted'
    }

    It 'returns the requested moment when a dated retry is asked for' {
        $at = [datetime]'2026-09-09T10:30:42'
        Get-BootUpdateRetryTriggerTime -RetryAt $at -RetrySoon $false | Should -Be $at
    }

    It 'still honours the two-minute retry switch' {
        $now = [datetime]'2026-09-09T10:00:00'
        Get-BootUpdateRetryTriggerTime -RetrySoon $true -Now $now | Should -Be $now.AddMinutes(2)
    }

    It 'prefers an explicit moment over the switch' {
        $at = [datetime]'2026-09-09T11:00:00'
        Get-BootUpdateRetryTriggerTime -RetryAt $at -RetrySoon $true -Now ([datetime]'2026-09-09T10:00:00') |
            Should -Be $at
    }

    It 'asks for no trigger when neither is requested' {
        Get-BootUpdateRetryTriggerTime | Should -BeNullOrEmpty
        Get-BootUpdateRetryTriggerTime -RetryAt $null -RetrySoon $false | Should -BeNullOrEmpty
    }

    It 'survives the binder that broke it, end to end through a declared Nullable parameter' {
        <# The regression this file exists to prevent: call it the way the orchestrator does,
           through a [Nullable[datetime]] parameter, and require a trigger time back. #>
        function Invoke-LikeTheOrchestrator {
            param([switch]$RetrySoon, [Nullable[datetime]]$RetryAt = $null)
            Get-BootUpdateRetryTriggerTime -RetryAt $RetryAt -RetrySoon ([bool]$RetrySoon)
        }
        $watchdog = [datetime]'2026-09-09T10:30:42'
        Invoke-LikeTheOrchestrator -RetryAt $watchdog | Should -Be $watchdog
        Invoke-LikeTheOrchestrator | Should -BeNullOrEmpty
    }

    It 'makes the registration expect the time trigger it just asked for' {
        <# If the trigger is armed, the resume-chain verification must also expect it -
           otherwise a missing watchdog would still verify clean, which is how this survived
           a release with 'Resume chain verified' printed beside it. #>
        $text = Get-FunctionText $invokeAst 'Register-BootUpdateTaskForReboot'
        $text | Should -Match 'Get-BootUpdateRetryTriggerTime -RetryAt \$RetryAt -RetrySoon \(\[bool\]\$RetrySoon\)'
        $text | Should -Not -Match '\$RetryAt\.HasValue'
        $text | Should -Match "MSFT_TaskTimeTrigger"
    }
}

Describe 'One call decides whether this pass followed a reboot' {
    <# -jjyx. The boot-session cluster produced the same defect class twice - a persisted
       timestamp compared without normalisation - and both times the cause was the shape of
       the interface, not the logic. Callers gathered three readings through three getters,
       handed raw timestamps to the state update, and then RE-DERIVED the new-boot decision
       at the logging site from those same raw values. The invariant "normalise a persisted
       timestamp before comparing it" lived in the caller's head, and the interface let a new
       signal bypass the normaliser, which is exactly what happened.

       Now the caller passes state and consumes an observation. It never sees a timestamp, so
       it cannot mishandle one. #>

    BeforeAll {
        function New-Reading {
            param([string]$SessionId, $Uptime = 600, $Monotonic = $null)
            [pscustomobject]@{ SessionId = $SessionId; UptimeSeconds = $Uptime; MonotonicBootId = $Monotonic }
        }
    }

    It 'reports no new boot on the first pass a machine ever takes' {
        $state = New-BootUpdateStateV2
        $boot = ([datetime]::UtcNow).ToString('o')
        $observation = Update-BootUpdateBootSession -State $state -Reading (New-Reading -SessionId $boot -Monotonic $boot)

        $observation.NewBoot | Should -BeFalse -Because 'there is nothing to have moved away from yet'
        $observation.Reason | Should -BeNullOrEmpty
        $observation.RebootCounted | Should -BeFalse
        $observation.State.LastBootSessionId | Should -Be $boot
    }

    It 'names the signal that decided a reboot happened' {
        $first = [datetime]::UtcNow
        $state = (Update-BootUpdateBootSession -State (New-BootUpdateStateV2) `
            -Reading (New-Reading -SessionId $first.ToString('o') -Monotonic $first.ToString('o'))).State
        $state.Phase = 'Rebooting'

        $second = $first.AddHours(3)
        $observation = Update-BootUpdateBootSession -State $state `
            -Reading (New-Reading -SessionId $second.ToString('o') -Monotonic $second.ToString('o'))

        $observation.NewBoot | Should -BeTrue
        $observation.Reason | Should -Be 'identity'
        $observation.RebootCounted | Should -BeTrue
        $observation.State.RebootCount | Should -Be 1
    }

    It 'attributes a fast restart inside the identity tolerance to the monotonic signal' {
        <# The whole reason the monotonic reading exists: 67 and 58 seconds apart is inside
           the 120-second identity window, so identity alone would call it the same boot. #>
        $first = [datetime]::UtcNow
        $state = (Update-BootUpdateBootSession -State (New-BootUpdateStateV2) `
            -Reading (New-Reading -SessionId $first.ToString('o') -Monotonic $first.ToString('o'))).State
        $state.Phase = 'Rebooting'

        $fast = $first.AddSeconds(67)
        $observation = Update-BootUpdateBootSession -State $state `
            -Reading (New-Reading -SessionId $fast.ToString('o') -Monotonic $fast.ToString('o'))

        $observation.NewBoot | Should -BeTrue
        $observation.Reason | Should -Be 'monotonic' -Because 'identity could not see it, and the log should say which signal did'
        $observation.State.RebootCount | Should -Be 1
    }

    It 'does not charge a reboot the updater never asked for to the budget' {
        $first = [datetime]::UtcNow
        $state = (Update-BootUpdateBootSession -State (New-BootUpdateStateV2) `
            -Reading (New-Reading -SessionId $first.ToString('o') -Monotonic $first.ToString('o'))).State
        $state.Phase = 'Running'   # a crash-and-restart, not a planned reboot

        $observation = Update-BootUpdateBootSession -State $state `
            -Reading (New-Reading -SessionId $first.AddHours(2).ToString('o') -Monotonic $first.AddHours(2).ToString('o'))

        $observation.NewBoot | Should -BeTrue
        $observation.RebootCounted | Should -BeFalse -Because 'the increment is gated on the phase, and that gate is what kept the count truthful'
        $observation.State.RebootCount | Should -Be 0
    }

    It 'survives the state file without the caller normalising anything' {
        <# The defect class itself. Round-trip the state through real JSON, which rehydrates
           every ISO-8601 string as a [datetime], and pass the SAME boot instant again. A
           caller that had to normalise would get this wrong; a caller that never sees the
           timestamp cannot. #>
        $boot = [datetime]::UtcNow.AddMinutes(-40)
        $state = (Update-BootUpdateBootSession -State (New-BootUpdateStateV2) `
            -Reading (New-Reading -SessionId $boot.ToString('o') -Monotonic $boot.ToString('o'))).State
        $state.ConsecutiveRetryCount = 3

        $reloaded = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $reloaded.LastBootSessionId | Should -BeOfType [datetime] -Because 'this is the rehydration that caused the defect twice'

        $observation = Update-BootUpdateBootSession -State $reloaded `
            -Reading (New-Reading -SessionId $boot.AddSeconds(1).ToString('o') -Monotonic $boot.AddSeconds(1).ToString('o'))

        $observation.NewBoot | Should -BeFalse -Because 'one second of jitter is not a restart, whatever the local offset is'
        $observation.State.ConsecutiveRetryCount | Should -Be 3 -Because 'a same-boot pass must not reset the retry budget'
    }

    It 'takes the reading itself when the caller does not supply one' {
        $reading = Get-BootUpdateBootReading
        foreach ($field in 'SessionId','UptimeSeconds','MonotonicBootId') {
            $reading.PSObject.Properties.Name | Should -Contain $field
        }
        $reading.SessionId | Should -Not -BeNullOrEmpty
    }

    It 'leaves the cycle nothing to re-derive' {
        <# The specific shape being retired: the logging site used to recompute the decision
           from raw timestamps it had gathered itself, which is how a log came to disagree
           with the machine while staying internally consistent. #>
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$bootObservation = Update-BootUpdateBootSession -State \$state'
        $text | Should -Match '\$newBootObserved = \$bootObservation\.NewBoot'
        $text | Should -Not -Match '\$monotonicMoved = Test-BootUpdateMonotonicBootMoved'
        $text | Should -Not -Match 'Update-BootUpdateStateForBootSession'
        $text | Should -Not -Match '\$currentBootSessionId = Get-BootUpdateBootSessionId'
    }

    It 'keeps the compatibility shim free of decisions of its own' {
        $shim = Get-FunctionText $invokeAst 'Update-BootUpdateStateForBootSession'
        $shim | Should -Match 'Update-BootUpdateBootSession'
        $shim | Should -Not -Match 'Test-BootUpdateSameBootSession'
        $shim | Should -Not -Match 'RebootCount'
    }
}

Describe 'The convergence check returns one shape, whichever way it returns' {
    <# Found by the v2.5.79 Standards review, and it was a crash on the ORDINARY path. Two
       early returns of Test-WindowsUpdateConvergence omitted the fields the re-offer
       classification added. The caller read $wuConvergence.Reoffered as @($null), whose
       .Count is 1 - the array-collapse trap this same release fixes in the lab harness - so
       a pass that reused fresh post-install zero-work evidence took the QUALIFIED branch,
       claimed qualified convergence on a machine with nothing applicable, and then threw on
       [datetime]$null while building the record.

       Every unit test missed it because they all mock the background scan, which means they
       only ever drive the full-scan return. #>

    BeforeEach {
        $script:ExcludePatterns = @('SQL')
        $script:PackageTimeoutMinutes = 30
        $script:CurrentState = $null
        Mock Get-Module { [pscustomobject]@{ Name='PSWindowsUpdate' } }
        Mock Get-BootUpdateBootSessionId { 'boot-a' }
        Mock Write-Log {}
        Mock Set-WindowsUpdateAssessmentCache {}
        Mock Get-WindowsUpdateInstallHistory { @() }
    }

    It 'reuses fresh post-install zero evidence without claiming a re-offer' {
        Mock Test-WindowsUpdateZeroEvidence { $true }
        $script:CurrentState = [pscustomobject]@{ WindowsUpdateZeroEvidence = [pscustomobject]@{ Source = 'test' } }
        Mock Invoke-BootUpdateBackgroundOperation { throw 'the scan must not run when fresh evidence is reused' }

        $result = Test-WindowsUpdateConvergence

        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
        @($result.Reoffered).Count | Should -Be 0 -Because '@($null) has one element, and one element takes the qualified branch'
        $result.Unexplained | Should -Be 0
    }

    It 'gives the unavailable-module return the same shape, with nothing claimed as known' {
        Mock Test-WindowsUpdateZeroEvidence { $false }
        Mock Get-Module { $null }

        $result = Test-WindowsUpdateConvergence

        $result.Verified | Should -BeFalse
        $result.Count | Should -Be -1
        @($result.Reoffered).Count | Should -Be 0
        $result.Unexplained | Should -Be -1 -Because 'not zero and not known are different, and zero reads as nothing outstanding'
    }

    It 'never lets a null reach the deferred-inventory record builder' {
        <# The call site's own guard, stated separately from the contract above, because the
           two must both hold: a partial shape from anywhere must not become a record. #>
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$reoffered = @\(\$wuConvergence\.Reoffered \| Where-Object \{ \$null -ne \$_ \}\)'
    }
}

Describe 'An installer mutex that cannot be examined is not an absent one' {
    <# ADR-0005, applied to the probe added for -ynvn. OpenExisting throws
       WaitHandleCannotBeOpenedException when the mutex genuinely does not exist, and
       UnauthorizedAccessException when it exists but the caller may not open it. Catching
       both as "absent" would send the cycle straight into the next package against a live
       transaction - the 1618 the wait exists to prevent. #>

    BeforeEach {
        $script:InstallerMutexProbeWarned = $false
        $script:Logged = [System.Collections.Generic.List[object]]::new()
        function Write-Log { param([string]$Message,[string]$Level,[string]$Visibility) $script:Logged.Add([pscustomobject]@{ Message=$Message; Level=$Level }) }
    }

    It 'reports absent only for the exception that means absent' {
        Test-BootUpdateInstallerMutexHeld -MutexName ('Local\boot-upd-absent-{0}' -f [guid]::NewGuid().ToString('N')) |
            Should -BeFalse
        $script:Logged.Count | Should -Be 0 -Because 'an absent mutex is the ordinary case and must be silent'
    }

    It 'still reports absent for a name too long to name anything' {
        <# Checked rather than assumed: an over-long name throws
           WaitHandleCannotBeOpenedException, the same exception as genuine absence, so it
           belongs on the absent side and not on the unobservable one. #>
        Test-BootUpdateInstallerMutexHeld -MutexName ('Local\' + ('x' * 400)) | Should -BeFalse
    }

    It 'treats an unopenable mutex as held, and says so once' {
        <# An empty name throws ArgumentException, which is the not-WaitHandle branch under
           test - the same shape an ACL denial takes on a real machine. #>
        Test-BootUpdateInstallerMutexHeld -MutexName '' | Should -BeTrue -Because 'unobservable is not absent'
        Test-BootUpdateInstallerMutexHeld -MutexName '' | Should -BeTrue
        @($script:Logged | Where-Object { $_.Message -match 'could not be examined' }).Count |
            Should -Be 1 -Because 'the caller polls, so this must not be logged on every probe'
    }

    It 'carries the outcome out with the timeout result instead of discarding it' {
        $text = Get-FunctionText $invokeAst 'Wait-ProcessWithIdleTimeout'
        ([regex]::Matches($text, 'InstallerMutexHeld = \(-not \$mutexClear\)')).Count |
            Should -Be 2 -Because 'a later 1618 should be attributable to this orphan rather than guessed at'
        $text | Should -Not -Match '\$null = Wait-BootUpdateInstallerMutex'
    }
}