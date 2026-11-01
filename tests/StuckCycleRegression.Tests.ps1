<# Regressions from two real machines (2026-10-30 to 2026-11-01, v2.5.87-v2.5.90): one
   package failure, a locked npm module or a republished Defender update stopped the cycle,
   and every later `upd` refused to start a fresh one. Transcripts below are the sanitized
   provider output those machines printed. #>
BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    function Get-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        return $ast
    }
    function Import-ScriptFunction {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string[]]$Name)
        foreach ($functionName in $Name) {
            $function = $Ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true)
            $function | Should -Not -BeNullOrEmpty -Because "production function '$functionName' must exist"
            . ([scriptblock]::Create($function.Extent.Text))
        }
    }
    $invokeAst = Get-ScriptAst (Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1')
    $deployAst = Get-ScriptAst (Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1')
    $script:BootUpdateStateSchemaVersion = 7
    . Import-ScriptFunction $invokeAst @(
        'New-BootUpdateStateV2', 'Update-BootUpdateStateSchema', 'Get-BootUpdateState', 'Set-BootUpdateState',
        'ConvertTo-BootUpdateTimestampString',
        'Get-WingetInventoryPackageIds', 'Get-WingetOutputSummary', 'Test-WingetExitReconciled',
        'Get-WingetDeferredInventoryRecords', 'Format-NativeExitCode', 'Get-InstallerExitSummary',
        'Get-WindowsUpdateReofferedAfterSuccess',
        'Invoke-NpmGlobalUpdate', 'Invoke-ScoopUpdate'
    )
    . Import-ScriptFunction $deployAst @('Reset-BootUpdateCycleState')
    function Write-Log { param([string]$Message, [string]$Level, [string]$Visibility) }
    function Unregister-BootUpdateTask { }
}

Describe 'upd starts a fresh cycle after a stop' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        $script:StatePath = Join-Path $dir 'BootUpdateCycle.state.json'
        $stopped = New-BootUpdateStateV2
        $stopped.StartTime = '2026-10-31T15:46:38.0000000-04:00'
        $stopped.Phase = 'RetryLimitReached'
        $stopped.LimitReason = 'Same-boot recovery limit 5 reached; incomplete phases: WindowsUpdate, Npm'
        $stopped.ConsecutiveRetryCount = 5
        Set-BootUpdateState -State $stopped
    }

    It 'keeps the stop in both copies, which is why deleting only the primary resurrected it' {
        Test-Path -LiteralPath "$script:StatePath.bak" | Should -BeTrue
        Remove-Item -LiteralPath $script:StatePath
        (Get-BootUpdateState).Phase | Should -Be 'RetryLimitReached'
    }

    It 'removes both copies so the next run starts from a new checkpoint, and reports the old stop' {
        $reason = Reset-BootUpdateCycleState -InstallDirectory (Split-Path $script:StatePath)
        $reason | Should -BeLike 'Same-boot recovery limit 5 reached*'
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
        Test-Path -LiteralPath "$script:StatePath.bak" | Should -BeFalse
        $fresh = Get-BootUpdateState
        $fresh.Phase | Should -Be 'Init'
        $fresh.StartTime | Should -BeNullOrEmpty
    }

    It 'keeps the checkpoint for -ResumeAfterAttention' {
        Reset-BootUpdateCycleState -InstallDirectory (Split-Path $script:StatePath) -KeepCheckpoint | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:StatePath | Should -BeTrue
        Test-Path -LiteralPath "$script:StatePath.bak" | Should -BeTrue
    }

    It 'still resets when the primary is already gone' {
        Remove-Item -LiteralPath $script:StatePath
        $null = Reset-BootUpdateCycleState -InstallDirectory (Split-Path $script:StatePath)
        Test-Path -LiteralPath "$script:StatePath.bak" | Should -BeFalse
    }
}

Describe 'Winget inventory footer sentences' {
    It 'does not read "N upgrades available." or "package(s) have" lines as package rows' {
        $inventory = Get-WingetInventoryPackageIds -Lines @(
            'Name       Id           Version Available Source'
            '------------------------------------------------'
            'Dolt (SQL) DoltHub.Dolt 2.6.1   2.6.2     winget'
            '2 upgrades available.'
            '1 package(s) have version numbers that cannot be determined. Use --include-unknown to see all results.'
        )
        $inventory.PackageIds | Should -Be @('DoltHub.Dolt')
        $inventory.MalformedRows | Should -Be 0
    }
}

Describe 'Winget installer download that the publisher has not published' {
    BeforeAll {
        $lines = @(
            'Name          Id                      Version       Available     Source'
            '------------------------------------------------------------------------'
            'BrowserOS neo BrowserOS.BrowserOS.Neo 155.0.8315.26 155.0.8317.26 winget'
            '1 upgrades available.'
            '(1/1) Found BrowserOS neo [BrowserOS.BrowserOS.Neo] Version 155.0.8317.26'
            'This application is licensed to you by its owner.'
            'Microsoft is not responsible for, nor does it grant any licenses to, third-party packages.'
            'Downloading https://example.invalid/BrowserOS_neo_installer.exe'
            'An unexpected error occurred while executing the command: '
            'Download request status is not success.'
            '0x80190194 : Not found (404).'
        )
        $summary = Get-WingetOutputSummary -Lines $lines
    }

    It 'names the package and the HTTP status instead of reporting 1 attempted, 0 failed' {
        @($summary.DownloadUnavailable).Count | Should -Be 1
        $summary.DownloadUnavailable[0].Id | Should -Be 'BrowserOS.BrowserOS.Neo'
        $summary.DownloadUnavailable[0].Hex | Should -Be '0x80190194'
        @($summary.Failures).Count | Should -Be 0
    }

    It 'accounts for the aggregate 0x8A15002C so the phase is not retried or escalated' {
        Test-WingetExitReconciled -Summary $summary -ExitCode (-1978335188) | Should -BeTrue
    }

    It 'records it as deferred inventory' {
        $records = @(Get-WingetDeferredInventoryRecords -Summaries $summary)
        ($records | Where-Object Kind -eq 'DownloadUnavailable').Count | Should -Be 1
    }
}

Describe 'Defender security intelligence republished under the same KB' {
    It 'treats a newer version of an update installed earlier in this run as a re-offer' {
        $since = [datetime]::new(2026, 10, 31, 19, 46, 0, [DateTimeKind]::Utc)
        $history = @([pscustomobject]@{
            Title = 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.441.120.0) - Current Channel (Broad)'
            ResultCode = 2
            InstalledAt = $since.AddMinutes(2)
        })
        $applicable = 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.441.168.0) - Current Channel (Broad)'
        $reoffered = @(Get-WindowsUpdateReofferedAfterSuccess -Applicable $applicable -History $history -SinceUtc $since)
        $reoffered.Count | Should -Be 1
        $reoffered[0].KB | Should -Be 'KB2267602'
    }

    It 'does not treat a different update as a re-offer' {
        $since = [datetime]::new(2026, 10, 31, 19, 46, 0, [DateTimeKind]::Utc)
        $history = @([pscustomobject]@{ Title = '2026-10 Cumulative Update (KB5099999)'; ResultCode = 2; InstalledAt = $since.AddMinutes(2) })
        @(Get-WindowsUpdateReofferedAfterSuccess -Applicable '2026-10 Cumulative Update (KB5098888)' -History $history -SinceUtc $since).Count | Should -Be 0
    }
}

Describe 'npm global packages locked by a running program' {
    BeforeAll {
        <# Stand-in for npm: two outdated packages; one is held open by a running MCP server. #>
        $fakeNpm = Join-Path $TestDrive 'npm.ps1'
        Set-Content -LiteralPath $fakeNpm -Value @'
if ($args[0] -eq 'outdated') {
    '{ "@wonderwhy-er/desktop-commander": { "current": "0.3.1", "wanted": "0.3.2", "latest": "0.3.2" }, "typescript": { "current": "5.9.2", "wanted": "5.9.3", "latest": "5.9.3" } }'
    exit 1
}
if ($args[2] -eq '@wonderwhy-er/desktop-commander') {
    # Native stderr, as node.exe writes it.
    cmd.exe /d /c "echo npm error code EBUSY 1>&2 & echo npm error syscall rename 1>&2 & echo npm error EBUSY: resource busy or locked, rename 'C:\Path\To\npm\node_modules\@wonderwhy-er\desktop-commander\dist' 1>&2"
    exit -4082
}
'changed 1 package in 2s'
exit 0
'@
    }

    It 'updates the free package and defers the locked one by name' {
        $result = Invoke-NpmGlobalUpdate -NpmPath $fakeNpm
        $result.Success | Should -BeTrue
        $result.Count | Should -Be 1
        @($result.Deferred).Count | Should -Be 1
        $result.Deferred[0].Kind | Should -Be 'in-use'
        $result.Deferred[0].Detail | Should -BeLike '@wonderwhy-er/desktop-commander*'
        @($result.LogLines | Where-Object { $_ -match '^\[Error\]' }).Count | Should -Be 0
    }

    It 'fails, rather than updating a package named "error", when the registry is unreachable' {
        $offlineNpm = Join-Path $TestDrive 'npm-offline.ps1'
        Set-Content -LiteralPath $offlineNpm -Value @'
if ($args[0] -eq 'outdated') { '{ "error": { "code": "ENOTFOUND", "summary": "request failed" } }'; exit 1 }
'should not run'; exit 0
'@
        $result = Invoke-NpmGlobalUpdate -NpmPath $offlineNpm
        $result.Success | Should -BeFalse
        $result.Count | Should -Be 0
        @($result.LogLines | Where-Object { $_ -eq 'should not run' }).Count | Should -Be 0
    }

    It 'still fails the phase for an npm error that is not a lock' {
        $brokenNpm = Join-Path $TestDrive 'npm-broken.ps1'
        Set-Content -LiteralPath $brokenNpm -Value @'
if ($args[0] -eq 'outdated') { '{ "typescript": { "current": "5.9.2", "wanted": "5.9.3", "latest": "5.9.3" } }'; exit 1 }
cmd.exe /d /c "echo npm error code E404 1>&2"
exit 1
'@
        $result = Invoke-NpmGlobalUpdate -NpmPath $brokenNpm
        $result.Success | Should -BeFalse
        @($result.Deferred).Count | Should -Be 0
    }
}

Describe 'Scoop output written with Write-Host' {
    It 'counts updated apps, defers running apps and drops bucket changelog lines' {
        $fakeScoop = Join-Path $TestDrive 'scoop.ps1'
        Set-Content -LiteralPath $fakeScoop -Value @'
if ($args.Count -eq 1) {
    Write-Host 'Updating Scoop...'
    Write-Host " * $([char]27)[33ma1b8b3bac6dd$([char]27)[m claude-code: Update to version 2.1.316    main    14 hours ago"
    Write-Host 'Scoop was updated successfully!'
    exit 0
}
Write-Host "Updating 'claude-code' (2.1.314 -> 2.1.316)"
Write-Host "'claude-code' (2.1.316) was installed successfully!"
Write-Host "Updating 'codex' (0.165.0 -> 0.166.0)"
Write-Host 'ERROR The following instances of "codex" are still running. Close them and try again.'
exit 1
'@
        $result = Invoke-ScoopUpdate -ScoopPath $fakeScoop
        $result.Count | Should -Be 1
        $result.Success | Should -BeTrue
        @($result.Deferred).Count | Should -Be 1
        $result.Deferred[0].Detail | Should -BeLike 'codex*'
        @($result.LogLines | Where-Object { $_ -match 'Update to version' }).Count | Should -Be 0
        @($result.LogLines | Where-Object { $_ -match "^Updating 'claude-code'" }).Count | Should -Be 1
        @($result.LogLines | Where-Object { $_ -like '`[Warn`] `[DEFERRED`]*codex*' }).Count | Should -Be 1
    }
}

Describe 'Self-updating AI command-line tools' {
    BeforeAll {
        . Import-ScriptFunction $invokeAst @('Invoke-AiToolSelfUpdate')
        $profileRoot = Join-Path $TestDrive 'profile'
        $bin = Join-Path $profileRoot '.local\bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        $script:claude = Join-Path $bin 'claude.ps1'
        $versionFile = Join-Path $TestDrive 'claude-version.txt'
        Set-Content -LiteralPath $versionFile -Value '2.1.314 (Claude Code)'
        Set-Content -LiteralPath $script:claude -Value @"
if (`$args[0] -eq '--version') { Get-Content -LiteralPath '$versionFile'; exit 0 }
if (`$args[0] -eq 'update') { Set-Content -LiteralPath '$versionFile' -Value '2.1.316 (Claude Code)'; 'Successfully updated'; exit 0 }
"@
        $script:hermes = Join-Path $TestDrive 'hermes.ps1'
        Set-Content -LiteralPath $script:hermes -Value @'
if ($args[0] -eq '--version') { 'Hermes Agent v0.21.5'; exit 0 }
if ($args -contains '--check') { 'Update available: 12 commits behind origin/main.'; exit 0 }
if ($args -contains '--list-venv-holders') { '[{"pid": 1, "kind": "gateway"}]'; exit 3 }
'unexpected update'; exit 9
'@
    }

    It 'updates the native Claude Code install and counts the version change' {
        $result = Invoke-AiToolSelfUpdate -ClaudePath $script:claude -UserProfile $profileRoot
        $result.Success | Should -BeTrue
        $result.Count | Should -Be 1
        $result.LogLines | Should -Contain 'Claude Code: updated 2.1.314 (Claude Code) -> 2.1.316 (Claude Code).'
    }

    It 'defers, rather than fails, when an updater refuses or errors' {
        $managedHermes = Join-Path $TestDrive 'hermes-managed.ps1'
        Set-Content -LiteralPath $managedHermes -Value "if (`$args[0] -eq '--version') { 'Hermes Agent v1' ; exit 0 }; 'Managed by the desktop app'; exit 2"
        $managed = Invoke-AiToolSelfUpdate -HermesPath $managedHermes -UserProfile $profileRoot
        $managed.Success | Should -BeTrue
        @($managed.Deferred).Count | Should -Be 0

        $offlineHermes = Join-Path $TestDrive 'hermes-offline.ps1'
        Set-Content -LiteralPath $offlineHermes -Value "if (`$args[0] -eq '--version') { 'Hermes Agent v1' ; exit 0 }; 'fetch failed'; exit 1"
        $offline = Invoke-AiToolSelfUpdate -HermesPath $offlineHermes -UserProfile $profileRoot
        $offline.Success | Should -BeTrue
        $offline.Deferred[0].Kind | Should -Be 'updater-unavailable'
        @($offline.LogLines | Where-Object { $_ -like '`[Warn`] `[DEFERRED`] Hermes*' }).Count | Should -Be 1
    }

    It 'leaves a package-managed Claude Code to its package manager' {
        $result = Invoke-AiToolSelfUpdate -ClaudePath 'C:\Path\To\npm\claude.cmd' -UserProfile $profileRoot
        $result.Count | Should -Be 0
        @($result.LogLines | Where-Object { $_ -match 'package manager' }).Count | Should -Be 1
    }

    It 'defers Hermes by name while its environment is held, instead of forcing the update' {
        $result = Invoke-AiToolSelfUpdate -HermesPath $script:hermes -UserProfile $profileRoot
        $result.Success | Should -BeTrue
        @($result.Deferred).Count | Should -Be 1
        $result.Deferred[0].Detail | Should -BeLike 'Hermes Agent*'
        @($result.LogLines | Where-Object { $_ -match 'unexpected update' }).Count | Should -Be 0
    }
}

Describe 'Staged provider cores keep their result across the child-process boundary' {
    BeforeAll {
        . Import-ScriptFunction $invokeAst @('New-BootUpdateProviderCoreScript', 'ConvertFrom-BootUpdateProviderCoreOutput')
        $fakeScoop = Join-Path $TestDrive 'scoop-staged.ps1'
        Set-Content -LiteralPath $fakeScoop -Value @'
if ($args.Count -eq 1) { Write-Host 'Scoop was updated successfully!'; exit 0 }
Write-Host 'ERROR The following instances of "codex" are still running. Close them and try again.'
exit 1
'@
    }

    It 'round-trips success, count, log lines and deferrals through one JSON line' {
        $script = New-BootUpdateProviderCoreScript -Function 'Invoke-ScoopUpdate'
        $output = @(& $script ([pscustomobject]@{ ScoopPath = $fakeScoop; IsWhatIf = $false }) | ForEach-Object { "$_" })
        $result = ConvertFrom-BootUpdateProviderCoreOutput -Name 'Scoop update' -Run @{ Output = $output; TimedOut = $false; Failed = $false }
        $result.Success | Should -BeTrue
        @($result.Deferred).Count | Should -Be 1
        $result.Deferred[0].Detail | Should -BeLike 'codex*'
        @($result.LogLines | Where-Object { $_ -like '`[Warn`] `[DEFERRED`] Scoop: codex is running*' }).Count | Should -Be 1
    }

    It 'fails the phase when the child times out before reporting' {
        $result = ConvertFrom-BootUpdateProviderCoreOutput -Name 'npm update' -Run @{ Output = @('partial'); TimedOut = $true; Failed = $true }
        $result.Success | Should -BeFalse
        $result.LogLines[-1] | Should -Be '[Error] npm update timed out.'
    }
}
