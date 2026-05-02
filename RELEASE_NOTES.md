# Boot Update Cycle - Release Notes

**Current Version:** v2.5.2
**Release Date:** 2026-05-02
**Status:** STABLE

---

## v2.5.2 (2026-05-02)

**Splash compatibility fix.** Replaced the fragile Unicode BBS splash with a static ASCII-only BOOT banner.

### Fixes

- Startup art now renders cleanly in legacy `cmd.exe` consoles even when Unicode block and box-drawing glyphs fail.
- Keeps the BBS-style neon ANSI look, but removes animation and palette rotation.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.1.

---

## v2.5.1 (2026-05-02)

**Splash render fix.** The BBS startup splash was rendering as blank space on legacy `cmd.exe` consoles because `chcp.com 65001 > $null 2>&1` at script start was silently no-opping when stdout was redirected, leaving the console at CP437/CP1252 — which strips Unicode box-drawing/block-element chars (U+2500–U+259F) to nothing.

### Fixes

- `Show-StartupArt` now calls `kernel32!SetConsoleOutputCP(65001)` and `SetConsoleCP(65001)` directly via P/Invoke right before drawing, plus re-asserts `[Console]::OutputEncoding = UTF-8`. Idempotent and reliable regardless of how the parent process was launched.
- Reverted the v2.5.1-rc per-row palette rotation. Each splash invocation again picks one random palette from the constrained six-theme set and uses it across all 6 BBS rows.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.0.

---

## v2.5.0 (2026-05-02)

**Major feature release.** Concurrency safety, BitLocker support, parallelized cohort, four new update phases, extension-hook system, self-update, and remote configuration. All 25 open issues from the 2026-05 code review closed across seven coordinated phases. State schema v2 → v3 with automatic migration; all changes backwards-compatible.

### New features

- **Named-mutex concurrency guard** (`Global\BootUpdateCycle`). A duplicate orchestrator instance now logs and exits cleanly instead of racing on `$state.Iteration` and `shutdown.exe`. `AbandonedMutexException` from a crashed prior owner is recovered.
- **BitLocker suspend across reboot.** New `Suspend-BitLockerForReboot` runs `Suspend-BitLocker -RebootCount 1` (with `manage-bde.exe` fallback) immediately before `shutdown.exe /r`. Eliminates the recovery-prompt stall on protected machines. New `-SkipBitLocker` switch.
- **Parallel cohort.** Pip, Npm, Scoop, DotnetTools, and Vscode now run concurrently via `Start-ThreadJob`. ~30-40% wall-clock savings on the user-package phase.
- **Parallel Winget scopes.** `--scope user` and `--scope machine` run concurrently in user context (sequential fallback under SYSTEM and when `ExcludePatterns` is active).
- **Defender signature update phase** (default ON, `-SkipDefender` to disable). Runs after Windows Update.
- **Driver/firmware update phase** (opt-in, `-IncludeDriverUpdates` / `-IncludeFirmwareUpdates`). Honors regex-escaped `ExcludePatterns`.
- **WSL kernel + distro phase** (opt-in, `-UpdateWsl`). Runs `wsl --update` plus per-distro apt/dnf/pacman. SYSTEM-context skipped.
- **Container image refresh + prune** (opt-in, `-UpdateContainers`). Detects Docker or Podman, pulls all non-`<none>` images unique-deduped, then `system prune -f`. SYSTEM-context skipped.
- **Metered connection detection.** WinRT `GetConnectionCost` with CIM fallback. Aborts cleanly via `exit 0` (not the error path) unless `-AllowMetered` is set.
- **Pre-flight network cache.** DNS + TCP probes cached in state for 5 minutes. Saves ~5-10s per iteration on slow networks. Cleared on reboot.
- **Cycle-level hooks.** New `-PreCycleScript` / `-PostCycleScript` parameters dot-source user .ps1 files at cycle entry and at successful-completion / max-iterations paths.
- **Per-phase hooks via `hooks.psd1`.** Sidecar file with 30 named scriptblocks (Before/After x 15 phases). Loaded at script start; failures are logged and never crash the cycle.
- **Self-update from GitHub releases** (default ON, `-DisableSelfUpdate` to disable). User-context only. Checks the `latest` release, validates the downloaded asset parses, optionally verifies SHA256 from a sibling asset or release body, atomically replaces the live script, and re-execs with the original parameters.
- **Remote configuration URL.** New `-ConfigUrl` parameter pulls a JSON config; supported keys override `$script:*` defaults only when the user did not pass them on the command line. Successful fetches are cached at `ProgramData\BootUpdateCycle\remote-config.cache.json`.

### Bug fixes

- `$SkipDotnetTools` now defaults to `$true` (matches documented OFF default; was running by accident).
- `shutdown.exe /c` comment is quoted (PS7.0-7.2 Legacy native-arg passing).
- pip per-package upgrade quotes the package name and applies `ExcludePatterns`.
- Windows Update `NotTitle` regex-escapes user-supplied `ExcludePatterns` (no more silent over-exclusion or parse errors).
- `Set-BootUpdateState` clears stale `.tmp` from a prior failed write and surfaces `Move-Item` failures via the logger.
- `Save-CycleHistory` writes atomically and tolerates a corrupted/empty history file (try/catch around `ConvertFrom-Json`).
- `$state.Iteration++` and the state write now happen AFTER the maintenance-window gate — narrow windows no longer burn iteration slots on misses.
- `Register-BootUpdateTaskForReboot` no longer early-returns when the task already exists; `Register-ScheduledTask -Force` always rewrites the action with the current arguments.
- `Update-BootUpdateStateSchema` warns and backs up state files written by a future schema version (`<path>.future-vN.bak`).
- `Repair-AwsTooling.ps1` passes its multi-line scriptblock to `pwsh.exe` via `-EncodedCommand` (newlines no longer drop across `CreateProcess`).
- `Send-MailMessage -AsJob` is awaited with a 30-second timeout, errors logged, and the job removed (no more job-object leak / silent SMTP failures).

### State schema

- Bumped v2 → v3. Adds `DefenderDone`, `DriverFirmwareDone`, `WslDone`, `ContainersDone`, `LastPreflightNetworkOk`, `LastPreflightNetworkAt`. Migration is automatic and idempotent.
- Forward-compat guard added: a state file at `v > $script:BootUpdateStateSchemaVersion` is backed up to `<path>.future-vN.bak` before the script proceeds.

### Compatibility

- New optional parameters; no removals or renames.
- `$SkipDotnetTools` default flipped from running → skipped, restoring documented behavior.
- All existing call sites and scheduled-task arg propagations updated.

---

## v2.4.0 (2026-04-25)

**Performance:** PowerShell module updates now run in parallel via `ForEach-Object -Parallel`.

- **PSResourceGet path** (PS 7.4+ / PSResourceGet installed): bulk `Update-PSResource` runs N modules concurrently inside the existing child job.
- **Legacy path** (PS 7.0-7.3): per-module `Update-Module` calls also run in parallel inside one child job (was sequential).
- Throttle limit: `min(8, max(2, ProcessorCount))` — caps concurrency to avoid repository contention and resource exhaustion.
- Same structured output format (`UPDATED|name|old|new`, `ERROR|name|msg`); same hard timeout via `PackageTimeoutMinutes`.

Expected: 3-5× faster module phase on machines with many installed modules.

---

## v2.3.4 (2026-04-25)

**Fix:** BBS splash rendered as blank when launched via `upd.cmd` — Unicode block-drawing chars stripped by inherited CP437/CP1252 console encoding.

- Forces UTF-8 console I/O on script start (`[Console]::OutputEncoding` + `chcp 65001`) so block/box-drawing chars (U+2588, U+2557, U+2550, etc.) survive the cmd.exe → pwsh handoff

---

## v2.3.3 (2026-04-25)

**UX:** BBS-style startup splash (`Show-StartupArt`) now renders on every iteration instead of only the first. Visible on every `upd.cmd` invocation and on post-reboot SYSTEM task runs.

---

## v2.3.2 (2026-04-25)

**Fix:** Banner version was hardcoded as `v2.1` in three places. Extracted to `$script:BootUpdateCycleVersion` variable — single source of truth for all version displays.

---

## v2.3.1 (2026-04-25)

**Enhancement:** Comprehensive pending reboot detection based on Boxstarter/Brian Wilhite's `Get-PendingReboot`.

| Check | Before | After |
|-------|--------|-------|
| CBS RebootPending | Property lookup | Subkey existence (`Test-Path`) |
| WU RebootRequired | Property lookup | Subkey existence (`Test-Path`) |
| PendingFileRenameOperations | Property exists | Verify entries count > 0 |
| Netlogon JoinDomain | Property only | `JoinDomain` OR `AvoidSpnSet` |
| SCCM CCM_ClientUtilities | Not checked | Added (WMI, graceful skip if no SCCM client) |

---

## v2.3.0 (2026-04-25)

**Major:** Migrate PowerShell module updates from sequential `Update-Module` to bulk `Update-PSResource` (PSResourceGet).

- **Primary path** (PS 7.4+ / PSResourceGet installed): single `Start-Job` runs `Update-PSResource` for all modules in one child process. ~2x faster, C#-native, no PackageManagement dependency conflicts.
- **Legacy fallback** (PS 7.0-7.3): existing per-module `Update-Module` via `Start-Job` preserved.
- Child process avoids module-in-use file locks.
- Structured output parsing (`UPDATED|name|old|new`, `ERROR|name|msg`).

---

## v2.2.1 (2026-04-25)

**Fixes:**
- **AWS.Tools.* stale repository** — all AWS.Tools modules failed with `Unable to find repository` error. Now uses `Update-AWSToolsModule -CleanUp` instead of generic `Update-Module`.
- **Az meta-module timeout** — `Az` wrapper (80+ sub-modules) exceeded 5-minute timeout. Excluded from generic loop; sub-modules update individually.
- **PackageManagement noise** — filtered `module is currently in use` warning from logs.

---

## v2.2.0 (2026-04-25)

**Major:** Resolves all remaining open issues (7 bugs + 4 enhancements) via 4 parallel agents.

### Bugs Fixed

| Issue | Description |
|-------|-------------|
| #2 | pip JSON parsing breaks on single outdated package (wrapped in `@()`) |
| #3 | Crash recovery treats unknown phase names as crashes (now warns and ignores) |
| #4 | `$LASTEXITCODE` stale value — webhook uses `-ErrorAction Stop` |
| #5 | Module update job failures not detected (State checked before `Remove-Job`) |
| #6 | `Repair-AwsTooling` cmd.exe injection — uses `msiexec.exe` directly, non-MSI skipped |
| #16 | ExcludePatterns with special chars break task args (single quotes escaped) |
| #19 | `Stop-Job` leaves orphan pwsh.exe (child process killed via `ProcessId`) |

### Enhancements

| Issue | Description |
|-------|-------------|
| #17 | WebhookUrl validated with `[ValidateScript]` (must be `http`/`https` or empty) |
| #18 | SMTP auth via `[pscredential]$SmtpCredential` parameter |
| #20 | Webhook retry with exponential backoff (3 attempts, 2s/4s delays) |
| #21 | ASCII art splash picks random neon palette from 6 curated schemes |

---

## v2.1.4 (2026-04-25)

**Fixes from full codebase review:**
- Deploy: `SkipHealthCheck`, `MaintenanceWindowStart`, `MaintenanceWindowEnd` now forwarded to scheduled task args (were silently dropped after reboot)
- ExcludePatterns uses `.IndexOf()` instead of `-like` (no wildcard bugs with `[]`, `?`, `*`)
- `Show-BootUpdateHistory`: empty JSON array `[]` handled gracefully
- `[ValidateRange(-1, 23)]` added to `MaintenanceWindowStart`/`MaintenanceWindowEnd`

---

## v2.1.3 (2026-04-25)

**Fix:** Filter `System.__ComObject` noise from Windows Update log output. PSWindowsUpdate emits COM objects whose `.ToString()` renders as the type name.

---

## v2.1.2 (2026-04-25)

**Fix:** Banner version strings updated from `v2.0` to `v2.1` (ASCII splash, normal banner, WhatIf banner).

---

## v2.1.1 (2026-04-25)

**Fix:** Windows Update `-NotTitle` parameter type error. Parameter is `[String]`, not `[String[]]` — joined ExcludePatterns array with `|` to produce regex alternation string.

---

## v2.1 (2026-04-25)

**Major release** adding 8 features across three capability areas:

### Observability
- **Webhook & Email Notifications** — Teams/Slack/Discord auto-detection, dual notifications (completion + reboot warning), proxy support, async email
- **Trend Visualization** (`Show-BootUpdateHistory.ps1`) — Table/Graph/JSON output, ASCII bar charts with ANSI colors, read-only (no elevation)
- **Post-Update Health Check** — validates W32Time, WinDefend, Dnscache, Spooler, EventLog; service recovery; state tracking

### Safety & Control
- **Exclude Patterns** — skip packages by substring match across Winget, Chocolatey, Windows Update
- **Maintenance Window** — hour-based scheduling with midnight-crossing support; defers (doesn't fail)
- **Staged Rollout** — one package manager per boot; state persistence; isolated failure domains

### Quality of Life
- **WhatIf/Dry-Run Mode** — `ShouldProcess` guards on all external calls; zero side effects
- **System Restore Point** — opt-in snapshot before first iteration; SYSTEM/Server SKU tolerant

**Defaults:** All features disabled by default except health check. 100% backward compatible with v2.0.

---

## v2.0 (2026-04-25)

**Initial release.** Full-featured boot-time update orchestrator:

- 11 package manager phases (Winget, Chocolatey, Windows Update, pip, npm, Office 365, PowerShell modules, Scoop, dotnet tools, VS Code extensions, AWS tooling)
- Pre-flight checks (disk, network, battery, conflicts, WU service)
- Smart idle-aware timeouts with process tree monitoring
- Crash recovery with atomic state writes
- State schema versioning with auto-migration
- Log rotation, history tracking, toast notifications, event logging
- DirectFirstRun mode for user-scope Winget access
- Self-destructing scheduled task on completion

---

## Configuration

```powershell
$Config = @{
    # Safety & Control
    SkipRestorePoint         = $true      # Set $false to enable restore point
    SkipHealthCheck          = $false     # Health check on by default
    StagedRollout            = $false     # One manager per boot
    ExcludePatterns          = @()        # Skip packages by substring
    MaintenanceWindowStart   = -1         # Hour (0-23), -1 = no restriction
    MaintenanceWindowEnd     = -1         # Hour (0-23), -1 = no restriction

    # Notifications
    WebhookUrl               = ''         # Teams/Slack/Discord webhook
    NotifyEmail              = ''         # Email recipient
    SmtpServer               = ''         # SMTP relay
    # SmtpCredential         = (Get-Credential)  # Optional SMTP auth

    # Core
    RebootDelaySec           = 0          # Immediate forced reboot
    MaxIterations            = 5          # Safety valve
    PackageTimeoutMin        = 30         # Hard timeout per manager
}
```

---

## Getting Help

```powershell
# Monitor running cycle
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.log" -Tail 50 -Wait

# View cycle history
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.history.json" | ConvertFrom-Json

# Event log
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='BootUpdateCycle'}

# Trend visualization
.\Show-BootUpdateHistory.ps1 -Format Graph

# Preview without changes
.\Invoke-BootUpdateCycle.ps1 -WhatIf -Force

# Uninstall
& "$env:ProgramData\BootUpdateCycle\Uninstall.ps1"
```

---

## License

MIT - See LICENSE file
