BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $exportPath = Join-Path $repoRoot 'Export-BootUpdateDiagnostics.ps1'
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $exportTokens=$null; $exportErrors=$null
    $exportAst = [Management.Automation.Language.Parser]::ParseFile($exportPath,[ref]$exportTokens,[ref]$exportErrors)
    $exportErrors | Should -BeNullOrEmpty
    $invokeTokens=$null; $invokeErrors=$null
    $invokeAst = [Management.Automation.Language.Parser]::ParseFile($invokePath,[ref]$invokeTokens,[ref]$invokeErrors)
    $invokeErrors | Should -BeNullOrEmpty
    function Get-FunctionText {
        param($Ast,[string]$Name)
        $function = $Ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name },$true)
        $function | Should -Not -BeNullOrEmpty
        return $function.Extent.Text
    }
    foreach ($name in @('Protect-BootUpdateDiagnosticText','Assert-BootUpdateDiagnosticIsSanitized','Read-BootUpdateDiagnosticText','Copy-BootUpdateDiagnosticSnapshot','Get-BootUpdateDiagnosticActivity','Get-BootUpdateDiagnosticCurrentRunText','Get-BootUpdateDiagnosticCleanupSummary','Get-BootUpdateDiagnosticCleanupEvidence')) {
        . ([scriptblock]::Create((Get-FunctionText -Ast $exportAst -Name $name)))
    }
    foreach ($name in @('Enable-BootUpdateNtfsCompression','Invoke-BootUpdateLogRotation')) {
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name $name)))
    }
}

Describe 'Sanitized diagnostic export' {
    It 'redacts identity, organization, machine, network, and path material' {
        $raw = @'
[Info] CONTOSO\Jane.Doe on SECRET-PC
[Info] C:\Users\Jane.Doe\OneDrive - Contoso\Private Client\tool.exe
[Info] jane.doe@contoso.example https://internal.contoso.example/api?token=secret 10.20.30.40
[Info] S-1-5-21-123456789-123456789-123456789-1001 HKLM:\SOFTWARE\Contoso\Agent
'@
        $values = @('CONTOSO','Jane.Doe','SECRET-PC','Contoso','contoso.example','internal.contoso.example')
        $safe = Protect-BootUpdateDiagnosticText -Text $raw -SensitiveValues $values
        { Assert-BootUpdateDiagnosticIsSanitized -Text $safe -SensitiveValues $values } | Should -Not -Throw
        $safe | Should -Not -Match 'Jane|CONTOSO|SECRET-PC|contoso\.example|C:\\|10\.20\.30\.40|S-1-5-21'
        $safe | Should -Match '<REDACTED>|<PATH>|<EMAIL>|<URL>|<IP>|<SID>|<REGISTRY_PATH>'
    }

    It 'retains safe pending-cleanup provenance while redacting the underlying path' {
        $raw = '[Warn] Pending-file cleanup advisory [after updates]: EdgeUpdateCleanup=1, DropboxRecoveryCleanup=2; id=0123456789AB. Source C:\Program Files\Dropbox\secret.exe'
        $safe = Protect-BootUpdateDiagnosticText -Text $raw
        $safe | Should -Match 'EdgeUpdateCleanup=1, DropboxRecoveryCleanup=2'
        $safe | Should -Match 'id=0123456789AB'
        $safe | Should -Match '<PATH>'
        $safe | Should -Not -Match 'Dropbox\\secret'
    }

    It 'preserves contextual dotted package versions while redacting real IP addresses' {
        $raw = @'
Name                         Id                         Version         Available       Source
Example App                  Example.App                2026.1.2.3      2026.1.2.4      winget
Version: 10.20.30.40; peer 10.20.30.41
'@
        $safe = Protect-BootUpdateDiagnosticText -Text $raw
        $safe | Should -Match '<VERSION_[0-9A-F]{12}>'
        $safe | Should -Not -Match '2026\.1\.2\.3|2026\.1\.2\.4|10\.20\.30\.40'
        $safe | Should -Match 'Version: <VERSION_[0-9A-F]{12}>'
        $safe | Should -Match 'peer <IP>'
    }

    It 'decodes UTF-8 and UTF-16 sources without mojibake and reports invalid bytes' {
        $utf8Path = Join-Path $TestDrive 'utf8.log'
        [IO.File]::WriteAllText($utf8Path, 'provider … café', [Text.UTF8Encoding]::new($false))
        $utf8 = Read-BootUpdateDiagnosticText -Path $utf8Path
        $utf8.Text | Should -Be 'provider … café'
        $utf8.Warning | Should -BeNullOrEmpty

        $utf16Path = Join-Path $TestDrive 'utf16.log'
        [IO.File]::WriteAllText($utf16Path, 'provider … café', [Text.UnicodeEncoding]::new($false, $true))
        (Read-BootUpdateDiagnosticText -Path $utf16Path).Text | Should -Be 'provider … café'

        $invalidPath = Join-Path $TestDrive 'invalid.log'
        [IO.File]::WriteAllBytes($invalidPath, [byte[]](0xC3, 0x28))
        (Read-BootUpdateDiagnosticText -Path $invalidPath).Warning | Should -Match 'Invalid byte sequence'
    }

    It 'marks a captured active cycle and preserves phase and iteration metadata' {
        $source = Join-Path $TestDrive 'active-source'; $output = Join-Path $TestDrive 'active-output'
        New-Item -ItemType Directory -Path $source,$output | Out-Null
        Set-Content (Join-Path $source 'BootUpdateCycle.log') "BOOT UPDATE CYCLE RESUMED`nPhase: WindowsUpdate`nIteration=3"
        $null = & $exportPath -SourceDirectory $source -OutputDirectory $output -NoClipboard 6>&1
        $zip = Get-ChildItem -LiteralPath $output -Filter 'BootUpdateCycle-diagnostics-*.zip' | Select-Object -First 1
        $expanded = Join-Path $TestDrive 'active-expanded'
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
        $manifest = Get-Content (Join-Path $expanded 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.CaptureState | Should -Be 'active-at-capture'
        $manifest.ActiveAtCapture | Should -BeTrue
        $manifest.Phase | Should -Be 'WindowsUpdate'
        $manifest.Iteration | Should -Be 3
    }

    It 'uses explicit pass markers and ignores phase prose when deriving activity metadata' {
        $text = @'
[2026-08-17 13:05:11] [Info] BOOT UPDATE CYCLE STARTED | Pass: 1
[2026-08-17 13:07:43] [Info] --- Parallel cohort: 7 phase(s): Pip, Npm, Scoop
[2026-08-17 13:08:25] [Info] BOOT UPDATE CYCLE COMPLETE WITH CLEANUP ADVISORY
'@
        $activity = Get-BootUpdateDiagnosticActivity -Text $text
        $activity.ActiveAtCapture | Should -BeFalse
        $activity.Phase | Should -BeNullOrEmpty
        $activity.Iteration | Should -Be 1
    }

    It 'never treats phase(s)/phases prose as a phase, across every such banner the orchestrator writes (-vla0)' {
        # Regression for -vla0: the manifest once reported Phase="s ran" and
        # Iteration=null for a completed run whose log plainly said Pass: 1,
        # because the phase matcher struck the word "phase(s)" in prose and
        # only "Iteration" (never "Pass") was recognized. Exercise every
        # phase(s)/phases prose line the orchestrator actually writes
        # (Invoke-BootUpdateCycle.ps1: parallel-cohort banner, staged-rollout
        # remaining count, incomplete-phase(s) verification-withheld notice,
        # and the Windows Update prefetch "other phases ran" aside) plus an
        # accumulated log with no explicit Pass/Iteration marker, alongside one
        # explicit anchored "Phase:" line to prove the matcher still fires on
        # the real thing.
        $noExplicitMarkerText = @'
[2026-08-17 17:00:00] [Info] BOOT UPDATE CYCLE STARTED
[2026-08-17 17:02:00] [Info] --- Parallel cohort: 5 phase(s): Pip, Npm, Scoop, DotnetTools, Vscode ---
[2026-08-17 17:05:00] [Info] Windows Update prefetch: complete (3 downloaded while other phases ran).
[2026-08-17 17:06:00] [Info] Staged rollout: 2 phase(s) remaining. A near-term checkpoint will run [Winget].
[2026-08-17 17:07:00] [Warn] Verification withheld: incomplete phase(s): Winget, WindowsUpdate. Automatic retry queued for two minutes.
[2026-08-17 17:09:00] [Info] BOOT UPDATE CYCLE COMPLETE
'@
        $noMarkerActivity = Get-BootUpdateDiagnosticActivity -Text $noExplicitMarkerText
        $noMarkerActivity.ActiveAtCapture | Should -BeFalse
        $noMarkerActivity.Phase | Should -BeNullOrEmpty
        $noMarkerActivity.Iteration | Should -BeNullOrEmpty

        $explicitPhaseText = @'
[2026-08-17 17:00:00] [Info] BOOT UPDATE CYCLE RESUMED | Pass: 4
[2026-08-17 17:02:00] [Info] --- Parallel cohort: 5 phase(s): Pip, Npm, Scoop, DotnetTools, Vscode ---
[2026-08-17 17:05:00] [Info] Windows Update prefetch: complete (3 downloaded while other phases ran).
[2026-08-17 17:06:00] [Info] Phase: WindowsUpdate
'@
        $explicitActivity = Get-BootUpdateDiagnosticActivity -Text $explicitPhaseText
        $explicitActivity.ActiveAtCapture | Should -BeTrue
        $explicitActivity.Phase | Should -Be 'WindowsUpdate'
        $explicitActivity.Iteration | Should -Be 4
    }

    It 'exports a completed run with a parallel-cohort banner to a manifest with Phase null and a valid Iteration, not "s ran" (-vla0)' {
        # Full pipeline regression for -vla0's exact reported symptom: a real
        # completed bundle whose manifest.json showed Phase="s ran" and
        # Iteration=null even though the core log plainly said Pass: 1.
        $source = Join-Path $TestDrive 'vla0-source'; $output = Join-Path $TestDrive 'vla0-output'
        New-Item -ItemType Directory -Path $source,$output | Out-Null
        Set-Content (Join-Path $source 'BootUpdateCycle.log') @'
[2026-08-17 17:00:00] [Info] BOOT UPDATE CYCLE STARTED | Pass: 1
[2026-08-17 17:02:00] [Info] --- Parallel cohort: 5 phase(s): Pip, Npm, Scoop, DotnetTools, Vscode ---
[2026-08-17 17:05:00] [Info] Windows Update prefetch: complete (3 downloaded while other phases ran).
[2026-08-17 17:06:00] [Info] Staged rollout: 2 phase(s) remaining. A near-term checkpoint will run [Winget].
[2026-08-17 17:07:00] [Warn] Verification withheld: incomplete phase(s): Winget, WindowsUpdate. Automatic retry queued for two minutes.
[2026-08-17 17:09:00] [Info] BOOT UPDATE CYCLE COMPLETE
'@
        $null = & $exportPath -SourceDirectory $source -OutputDirectory $output -NoClipboard 6>&1
        $zip = Get-ChildItem -LiteralPath $output -Filter 'BootUpdateCycle-diagnostics-*.zip' | Select-Object -First 1
        $expanded = Join-Path $TestDrive 'vla0-expanded'
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
        $manifestRaw = Get-Content (Join-Path $expanded 'manifest.json') -Raw
        $manifestRaw | Should -Not -Match 'Phase["\s:]*"?s ran'
        $manifest = $manifestRaw | ConvertFrom-Json
        $manifest.CaptureState | Should -Be 'completed'
        $manifest.ActiveAtCapture | Should -BeFalse
        $manifest.Phase | Should -BeNullOrEmpty
        $manifest.Iteration | Should -Be 1
    }

    It 'records persistent before-and-after cleanup fingerprints without exposing paths' {
        $text = @'
[Info] Pending-file cleanup [before mutation]: PackageManagementPrototypeCleanup=6. Routine delete-only housekeeping; no restart is required.
[Info] Pending-file cleanup detail [before mutation]: id=AAA111,BBB222
[Info] Pending-file cleanup [after updates]: PackageManagementPrototypeCleanup=6. Routine delete-only housekeeping; no restart is required.
[Info] Pending-file cleanup detail [after updates]: id=AAA111,BBB222
'@
        $summary = Get-BootUpdateDiagnosticCleanupSummary -Text $text
        $summary.Persistent | Should -BeTrue
        $summary.BeforeMutation.Categories.PackageManagementPrototypeCleanup | Should -Be 6
        @($summary.AfterUpdates.Fingerprints).Count | Should -Be 2
        ($summary | ConvertTo-Json -Depth 6) | Should -Not -Match '\\|[A-Za-z]:\\|ProgramData'
    }

    It 'scopes manifest activity and cleanup evidence to the latest run in an accumulated log' {
        $text = @'
[2026-08-17 07:58:42] [Info] BOOT UPDATE CYCLE STARTED | Pass: 1
[2026-08-17 07:58:50] [Info] Pending-file cleanup [before mutation]: PackageManagementPrototypeCleanup=33
[2026-08-17 07:59:00] [Info] Pending-file cleanup detail [before mutation]: id=OLD111
[2026-08-17 08:00:59] [Info] Pending-file cleanup [after updates]: PackageManagementPrototypeCleanup=33
[2026-08-17 08:01:00] [Info] Pending-file cleanup detail [after updates]: id=OLD111
[2026-08-17 15:08:23] [Info] BOOT UPDATE CYCLE STARTED | Pass: 1
[2026-08-17 15:08:33] [Info] Pending-file cleanup [before mutation]: PackageManagementPrototypeCleanup=6
[2026-08-17 15:08:34] [Info] Pending-file cleanup detail [before mutation]: id=AAA111,BBB222
[2026-08-17 15:09:58] [Info] Pending-file cleanup [after updates]: PackageManagementPrototypeCleanup=6
[2026-08-17 15:09:59] [Info] Pending-file cleanup detail [after updates]: id=AAA111,BBB222
[2026-08-17 15:10:21] [Info] BOOT UPDATE CYCLE COMPLETE WITH CLEANUP ADVISORY
'@
        $current = Get-BootUpdateDiagnosticCurrentRunText -Text $text
        (Get-BootUpdateDiagnosticActivity -Text $current).ActiveAtCapture | Should -BeFalse
        (Get-BootUpdateDiagnosticActivity -Text $current).Iteration | Should -Be 1
        (Get-BootUpdateDiagnosticCleanupSummary -Text $current).Persistent | Should -BeTrue
        (Get-BootUpdateDiagnosticCleanupSummary -Text $current).BeforeMutation.Categories.PackageManagementPrototypeCleanup | Should -Be 6
    }

    It 'exports active and archived core, provider, and AWS logs into one safe zip' {
        $source = Join-Path $TestDrive 'source'; $output = Join-Path $TestDrive 'output'
        New-Item -ItemType Directory -Path $source,$output | Out-Null
        Set-Content (Join-Path $source 'BootUpdateCycle.log') @'
[Info] ACME\Alice on BUILD-PC at C:\Users\Alice\work\tool.exe
[Info] Pending-file cleanup [before mutation]: PackageManagementPrototypeCleanup=6. Routine delete-only housekeeping; no restart is required.
[Info] Pending-file cleanup detail [before mutation]: id=AAA111,BBB222
[Info] Pending-file cleanup [after updates]: PackageManagementPrototypeCleanup=6. Routine delete-only housekeeping; no restart is required.
[Info] Pending-file cleanup detail [after updates]: id=AAA111,BBB222
'@
        Set-Content (Join-Path $source 'BootUpdateCycle.providers.20260721-010203.log') '[Winget] alice@acme.example 192.168.10.4'
        Set-Content (Join-Path $source 'BootUpdateCycle.aws.log') '[AWS] E:\OneDrive\ACME Holdings\PowerShell\Modules'
        Set-Content (Join-Path $source 'BootUpdateCycle-winget-quarantine.json') '[{"PackageId":"Corsair.iCUE.5","UnpinCommand":"winget pin remove --id Corsair.iCUE.5 -e --disable-interactivity"}]'
        Set-Content (Join-Path $source 'BootUpdateCycle-winget-resolved-absent.json') '[{"SchemaVersion":2,"PackageId":"Microsoft.WindowsPCHealthCheck","Scope":"machine","FailureCode":1605,"ObservedVersion":"4.0","OutcomeKey":"microsoft.windowspchealthcheck|machine|1605|4.0|msi-unknown-product","Evidence":"MSI_ERROR_UNKNOWN_PRODUCT"}]'
        $redactions = @('ACME','Alice','BUILD-PC','acme.example','ACME Holdings')
        $exportArguments = @{
            SourceDirectory = $source; OutputDirectory = $output; AdditionalRedaction = $redactions
            NoClipboard = $true
        }
        $display = & $exportPath @exportArguments 6>&1
        $zip = @(Get-ChildItem -LiteralPath $output -Filter 'BootUpdateCycle-diagnostics-*.zip')[0]
        $zip | Should -Not -BeNullOrEmpty
        ($display -join "`n") | Should -Match ([regex]::Escape($zip.FullName))
        @($display | Where-Object { $_ -is [IO.FileInfo] }).Count | Should -Be 0
        $expanded = Join-Path $TestDrive 'expanded'
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
        $safe = Get-Content (Join-Path $expanded 'BootUpdateCycle.sanitized.log') -Raw
        $safe | Should -Match 'BootUpdateCycle\.aws\.log'
        $safe | Should -Match 'BootUpdateCycle\.providers\.20260721-010203\.log'
        $safe | Should -Match 'BootUpdateCycle-winget-quarantine\.json'
        $safe | Should -Match 'BootUpdateCycle-winget-resolved-absent\.json'
        $safe | Should -Match 'winget pin remove --id Corsair\.iCUE\.5'
        $safe | Should -Not -Match 'ACME|Alice|BUILD-PC|acme\.example|C:\\|E:\\|192\.168\.10\.4'
        $manifest = Get-Content (Join-Path $expanded 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.Sanitized | Should -BeTrue
        $manifest.FormatVersion | Should -Be 2
        $manifest.SnapshotComplete | Should -BeTrue
        $manifest.PendingFileCleanup.Persistent | Should -BeTrue
        $manifest.PendingFileCleanup.BeforeMutation.Categories.PackageManagementPrototypeCleanup | Should -Be 6
        $manifest.SourceFiles.Count | Should -BeGreaterThan 0
        $manifest.SourceFiles[0].SHA256 | Should -Not -BeNullOrEmpty
    }

    It 'copies the one absolute ZIP path to the clipboard with a graceful fallback' {
        $source = Get-Content -LiteralPath $exportPath -Raw
        $source | Should -Match 'Set-Clipboard -Value \$Text'
        $source | Should -Match '\$Text \| & clip\.exe'
        $source | Should -Match 'Full ZIP path copied to the clipboard'
        $source | Should -Match 'could not be copied to the clipboard'
    }
}

Describe 'Bounded compressed log lifecycle' {
    It 'rotates independently and retains only three archives' {
        $path = Join-Path $TestDrive 'BootUpdateCycle.log'
        [IO.File]::WriteAllText($path, ('x' * 2048))
        1..5 | ForEach-Object {
            $archive = Join-Path $TestDrive ("BootUpdateCycle.2026070{0}-010203.log" -f $_)
            Set-Content $archive "archive $_"
            (Get-Item $archive).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-$_)
        }
        Invoke-BootUpdateLogRotation -Path $path -MaximumBytes 10 `
            -ArchiveNamePattern '^BootUpdateCycle\.\d{8}-\d{6}\.log$' -Keep 3
        Test-Path $path | Should -BeFalse
        @(Get-ChildItem $TestDrive -File | Where-Object Name -Match '^BootUpdateCycle\.\d{8}-\d{6}\.log$').Count | Should -Be 3
    }

    It 'applies compression to active and archived logs without making it a correctness dependency' {
        $compression = Get-FunctionText -Ast $invokeAst -Name 'Enable-BootUpdateNtfsCompression'
        $rotation = Get-FunctionText -Ast $invokeAst -Name 'Invoke-BootUpdateLogRotation'
        $compression | Should -Match 'compact\.exe /C /I /Q'
        $compression | Should -Match 'catch'
        $rotation | Should -Match 'Enable-BootUpdateNtfsCompression -Path \$Path'
        $rotation | Should -Match 'Enable-BootUpdateNtfsCompression -Path \$archivePath'
    }
}

Describe 'Pending-file cleanup is read from evidence, not from the absence of a log line' {
    <# -h2z0. Bundle 20260825-130554Z, a completed and converged run, reported
       PendingFileCleanup.BeforeMutation=null and Persistent=null. The truthful answer was
       Persistent=false: the two ApplicationCleanup entries were created by that cycle's own
       Chocolatey upgrade and cleared on the next reboot. The manifest could not say so
       because it inferred the before-state from whether one log line appeared, and the
       cycle declines to emit that line for four unrelated reasons. #>

    BeforeAll {
        function New-CleanupRecord {
            param(
                [string]$Context,
                [string]$Observation,
                [hashtable]$Categories = @{},
                [string[]]$Fingerprints = @(),
                [string]$SessionId = '2026-08-25T08:20:56.0000000Z',
                [int]$Pass = 1,
                [string]$Source = 'two-probe'
            )
            [pscustomobject]@{
                SessionId     = $SessionId
                Pass          = $Pass
                ProbeIndex    = 1
                Context       = $Context
                Observation   = $Observation
                Source        = $Source
                ObservedAtUtc = '2026-08-25T08:21:00.0000000Z'
                Categories    = [pscustomobject]$Categories
                Fingerprints  = @($Fingerprints)
            }
        }
        function ConvertTo-SidecarText { param([object[]]$Records) @($Records) | ConvertTo-Json -Depth 6 -AsArray }
    }

    It 'reports Persistent false for the observed-empty before-state that used to read null' {
        $text = ConvertTo-SidecarText @(
            (New-CleanupRecord -Context 'before mutation' -Observation 'observed-empty'),
            (New-CleanupRecord -Context 'after updates'   -Observation 'observed-nonempty' `
                -Categories @{ ApplicationCleanup = 2 } -Fingerprints @('5F8FDB30BE01','8956A7C22992'))
        )
        $summary = Get-BootUpdateDiagnosticCleanupEvidence -Text $text
        $summary.BeforeMutationState | Should -Be 'observed-empty'
        $summary.Persistent | Should -BeOfType [bool]
        $summary.Persistent | Should -BeFalse -Because 'new, self-inflicted and cleared on reboot is a different story from unknown'
        $summary.AfterUpdates.Categories.ApplicationCleanup | Should -Be 2
    }

    It 'reports Persistent true when the same fingerprints survive the whole run' {
        $text = ConvertTo-SidecarText @(
            (New-CleanupRecord -Context 'before mutation' -Observation 'observed-nonempty' -Categories @{ ApplicationCleanup = 1 } -Fingerprints @('AAAA1111BBBB')),
            (New-CleanupRecord -Context 'after updates'   -Observation 'observed-nonempty' -Categories @{ ApplicationCleanup = 1 } -Fingerprints @('AAAA1111BBBB'))
        )
        (Get-BootUpdateDiagnosticCleanupEvidence -Text $text).Persistent | Should -BeTrue
    }

    It 'reports Persistent false when both observed endpoints are empty' {
        $text = ConvertTo-SidecarText @(
            (New-CleanupRecord -Context 'before mutation' -Observation 'observed-empty'),
            (New-CleanupRecord -Context 'after updates'   -Observation 'observed-empty')
        )
        (Get-BootUpdateDiagnosticCleanupEvidence -Text $text).Persistent | Should -BeFalse
    }

    It 'says a suppressed duplicate was suppressed, and still compares it' {
        <# The duplicate guard stays in the log, but it no longer decides what is known. #>
        $text = ConvertTo-SidecarText @(
            (New-CleanupRecord -Context 'before mutation' -Observation 'suppressed-duplicate' -Categories @{ ApplicationCleanup = 1 } -Fingerprints @('AAAA1111BBBB')),
            (New-CleanupRecord -Context 'after updates'   -Observation 'observed-nonempty'    -Categories @{ ApplicationCleanup = 1 } -Fingerprints @('AAAA1111BBBB'))
        )
        $summary = Get-BootUpdateDiagnosticCleanupEvidence -Text $text
        $summary.BeforeMutationState | Should -Be 'suppressed-duplicate'
        $summary.Persistent | Should -BeTrue
    }

    It 'refuses to compare against a phase that never ran' {
        $text = ConvertTo-SidecarText @(
            (New-CleanupRecord -Context 'before mutation' -Observation 'observed-nonempty' -Categories @{ ApplicationCleanup = 1 } -Fingerprints @('AAAA1111BBBB')),
            (New-CleanupRecord -Context 'after updates'   -Observation 'phase-skipped' -Source 'whatif')
        )
        $summary = Get-BootUpdateDiagnosticCleanupEvidence -Text $text
        $summary.BeforeMutationState | Should -Be 'observed-nonempty'
        $summary.Persistent | Should -BeNullOrEmpty -Because 'a skipped phase is not evidence that nothing was pending'
        $summary.AfterUpdates.Observation | Should -Be 'phase-skipped'
    }

    It 'reports not-probed when the sidecar exists but never recorded a before-state' {
        $text = ConvertTo-SidecarText @(
            (New-CleanupRecord -Context 'after updates' -Observation 'observed-empty')
        )
        $summary = Get-BootUpdateDiagnosticCleanupEvidence -Text $text
        $summary.BeforeMutationState | Should -Be 'not-probed'
        $summary.Persistent | Should -BeNullOrEmpty
    }

    It 'never mixes one run session with another' {
        $text = ConvertTo-SidecarText @(
            (New-CleanupRecord -Context 'before mutation' -Observation 'observed-nonempty' -SessionId 'older-session' -Categories @{ ApplicationCleanup = 9 } -Fingerprints @('DEADBEEF0001')),
            (New-CleanupRecord -Context 'before mutation' -Observation 'observed-empty'    -SessionId 'current-session'),
            (New-CleanupRecord -Context 'after updates'   -Observation 'observed-empty'    -SessionId 'current-session')
        )
        $summary = Get-BootUpdateDiagnosticCleanupEvidence -Text $text
        $summary.SessionId | Should -Be 'current-session'
        $summary.BeforeMutationState | Should -Be 'observed-empty'
        $summary.Persistent | Should -BeFalse
    }

    It 'falls back to log parsing for a bundle that predates the sidecar, and labels it' {
        Get-BootUpdateDiagnosticCleanupEvidence -Text $null   | Should -BeNullOrEmpty
        Get-BootUpdateDiagnosticCleanupEvidence -Text 'not json at all' | Should -BeNullOrEmpty
        Get-BootUpdateDiagnosticCleanupEvidence -Text '[]'    | Should -BeNullOrEmpty -Because 'an empty array carries no observation to report'
    }
}
