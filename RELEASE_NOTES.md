# Boot Update Cycle - Release Notes

**Current Version:** v2.3.4  
**Release Date:** 2026-04-25  
**Status:** STABLE

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
