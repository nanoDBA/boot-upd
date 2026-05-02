# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Windows boot-time update automation. Runs package managers (Winget, Chocolatey, PSWindowsUpdate) and reboots in a loop until no pending reboots remain, then self-removes.

## Architecture

**Two deployment models:**

1. **Modular scripts** (development/testing):
   - `Invoke-BootUpdateCycle.ps1` - Main orchestrator with full ShouldProcess support
   - `Register-BootUpdateTask.ps1` - Creates scheduled task pointing to the above
   - `Unregister-BootUpdateTask.ps1` - Cleanup utility

2. **Single-file deployment** (`Deploy-BootUpdateCycle.ps1`):
   - Paste-to-console approach - copy entire script into elevated pwsh
   - Embeds `Invoke-BootUpdateCycle.ps1` as a here-string
   - **Direct-first-run**: Executes first iteration in user context (not via scheduled task)
   - Only registers scheduled task IF reboots are needed

**Winget scope strategy:**
- First run (user context): Updates BOTH user-scope AND machine-scope packages
- Subsequent runs (SYSTEM via task): Machine-scope only
- This is critical: user-scope packages are ONLY updated on the first interactive run

**State persistence:** JSON file (`BootUpdateCycle.state.json`) tracks iteration count and which update phases completed. Reset on reboot to re-run all phases.

**Safety:** Max iteration limit (default 5) prevents infinite reboot loops.

## Key Files

| File | Purpose |
|------|---------|
| `Deploy-BootUpdateCycle.ps1` | **Primary entry point** - paste-to-deploy single file |
| `Invoke-BootUpdateCycle.ps1` | Full-featured orchestrator (reference implementation) |
| `Repair-AwsTooling.ps1` | Optional AWS CLI v2 + AWS.Tools module maintenance |

## Common Operations

```powershell
# Deploy (paste entire Deploy-BootUpdateCycle.ps1 into elevated pwsh)

# Monitor running cycle
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.log" -Tail 50 -Wait

# View cycle history
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.history.json" | ConvertFrom-Json

# Stop/remove
Unregister-ScheduledTask -TaskName 'BootUpdateCycle' -Confirm:$false
Remove-Item "$env:ProgramData\BootUpdateCycle" -Recurse -Force
```

## Update Phases (in order)

1. **Pre-flight checks** (disk space, network, battery, conflicting installers, WU service)
2. Winget (`winget upgrade --all --scope user` then `--scope machine`) — smart idle-aware timeout
3. Chocolatey (`choco upgrade all -y`)
4. Windows Update (PSWindowsUpdate module, excludes SQL Server)
5. Driver/Firmware updates via PSWindowsUpdate (OFF by default — opt-in; `-IncludeDriverUpdates` / `-IncludeFirmwareUpdates`)
6. AWS tooling repair (off by default, `-SkipAwsTooling:$false` to enable)
7. Defender signature update (on by default, `-SkipDefender` to disable)
8. pip global packages (on by default, `-SkipPip` to disable)
9. npm global packages (on by default, `-SkipNpm` to disable)
10. Office 365 Click-to-Run (on by default, `-SkipOffice365` to disable)
11. PowerShell modules via `Update-Module` (on by default, `-SkipPowerShellModules` to disable)
12. WSL kernel + distro updates (OFF by default — opt-in; `-UpdateWsl`; user-scoped, skipped under SYSTEM)
13. Docker/Podman image refresh + prune (OFF by default — opt-in; `-UpdateContainers`; user-scoped, skipped under SYSTEM)
14. Scoop packages (on by default, `-SkipScoop` to disable; user-scoped, skipped under SYSTEM)
15. .NET global tools (OFF by default — high risk; `-SkipDotnetTools:$false` to enable)
16. VS Code extensions (on by default, `-SkipVscode` to disable; user-scoped, skipped under SYSTEM)

**Note:** Winget runs first for cleanest environment before Chocolatey potentially locks installers.

## Additional Features

- **Pre-flight checks**: Validates disk space (>5GB), network, battery, conflicting installers, WU service before each iteration
- **Smart idle-aware timeouts**: Monitors process tree CPU activity; kills truly idle processes in 5 min but lets busy installs (VS, SQL) run to completion; hard timeout backstop
- **Crash recovery**: Detects if prior run crashed mid-phase (BSOD, power loss); logs warning and restarts that phase
- **Atomic state writes**: State file written via temp+rename to prevent corruption on power failure
- **State schema versioning**: v1→v2 auto-migration for renamed properties and new package managers
- **Log rotation**: 5 MB max per log, keeps 3 archives
- **History tracking**: `BootUpdateCycle.history.json` stores last 50 cycle summaries with package counts
- **Completion notifications**: BurntToast toast (user mode) and Windows Event Log (Application log, source: `BootUpdateCycle`)
- **Reboot warnings**: `shutdown.exe /r /t 120` with native Windows countdown dialog; users can abort with `shutdown /a`
- **DirectFirstRun mode** (default): First run executes in user console for user-scope winget access; task registered only if reboot needed

## Conventions

- All scripts require PowerShell 7+ and elevation
- **Deploy.ps1**: Copies Invoke.ps1 from source dir to ProgramData (no more embedded here-string duplication). Direct first run (user context), then SYSTEM scheduled task for post-reboot
- **Invoke.ps1**: Self-contained orchestrator; can register its own scheduled task for reboot without needing Register.ps1
- Log filters: spinner chars (`| / - \`), Unicode box-drawing/progress bars, download progress lines, source refresh messages
- Update functions return `@{ Success = [bool]; Count = [int] }` — Success=$true means "don't retry" (fail-forward pattern)
- State schema v3: all phase flags use `*Done` suffix consistently; versioned with auto-migration (v1→v2→v3)

## Key Config Options

| Option | Default | Purpose |
|--------|---------|---------|
| `DirectFirstRun` | `$true` | First run direct (user context) vs via task (SYSTEM) |
| `PackageTimeoutMin` | `30` | Hard timeout ceiling per package manager |
| `RebootDelaySec` | `120` | Seconds before reboot (user can abort) |
| `SkipPip/Npm/Office365` | `$false` | Disable specific package managers |
| `SkipPowerShellModules` | `$false` | Disable PowerShell module updates |
| `SkipScoop` | `$false` | Disable Scoop updates (user-scoped) |
| `SkipDotnetTools` | `$true` | .NET global tools (OFF — high risk) |
| `SkipVscode` | `$false` | Disable VS Code extension updates (user-scoped) |
| `SkipDefender` | `$false` | Disable Defender signature refresh |
| `IncludeDriverUpdates` | `$false` | Opt-in: install driver updates via PSWindowsUpdate |
| `IncludeFirmwareUpdates` | `$false` | Opt-in: install firmware updates via PSWindowsUpdate |
| `UpdateWsl` | `$false` | Opt-in: update WSL kernel and distro packages (user-scoped) |
| `UpdateContainers` | `$false` | Opt-in: pull updated Docker/Podman images and prune (user-scoped) |
| `PreCycleScript` | `''` | Path to a .ps1 hook executed after pre-flight, before the first phase |
| `PostCycleScript` | `''` | Path to a .ps1 hook executed after the final phase, before reboot decision |
| `HooksConfig` | `hooks.psd1` (sidecar) | Path to PSD1 sidecar with per-phase scriptblock hooks |
| `DisableSelfUpdate` | `$false` | Suppress GitHub self-update (lz1); also via `BOOT_UPDATE_NO_SELF_UPDATE` env var |
| `ConfigUrl` | `''` | URL to fleet-wide JSON config overrides (jzw). Empty = disabled. |

## Self-Update (lz1)

`Invoke-BootUpdateCycle.ps1` can update itself from the canonical GitHub release at `https://github.com/nanoDBA/boot-upd`. On each user-context run (never under SYSTEM), it queries the GitHub Releases API, compares the latest tag to `$script:BootUpdateCycleVersion`, and — if a newer version is available — downloads the `Invoke-BootUpdateCycle.ps1` asset, validates it with `[scriptblock]::Create()`, checks SHA256 if metadata is present, then atomically replaces the live file (backing up to `.bak`) and re-execs `pwsh -NoProfile -File` with the same arguments. If anything fails the current version continues. Disable with `-DisableSelfUpdate` or the `BOOT_UPDATE_NO_SELF_UPDATE` environment variable (for test environments).

## Remote Configuration (jzw)

Pass `-ConfigUrl <https://...>` to supply a fleet-wide JSON config override URL. `Get-RemoteConfig` fetches the URL (10 s timeout) and caches the result to `$env:ProgramData\BootUpdateCycle\remote-config.cache.json`. On network failure it falls back to the cache. `Apply-RemoteConfig` then overwrites any `$script:*` variable whose matching key appears in the JSON, **except** keys the operator explicitly passed on the command line (user always wins). Supported JSON keys: `ExcludePatterns`, `MaxIterations`, `RebootDelaySec`, `PackageTimeoutMinutes`, `MaintenanceWindowStart`, `MaintenanceWindowEnd`, `SkipPip`, `SkipNpm`, `SkipScoop`, `SkipDotnetTools`, `SkipVscode`, `SkipPowerShellModules`, `SkipOffice365`, `SkipAwsTooling`, `SkipDefender`, `SkipBitLocker`, `SkipRestorePoint`, `SkipHealthCheck`, `IncludeDriverUpdates`, `IncludeFirmwareUpdates`, `UpdateWsl`, `UpdateContainers`, `AllowMetered`, `DisableSelfUpdate`, `StagedRollout`.

## Extension Hooks

Two complementary hook mechanisms allow you to extend the orchestrator without modifying it.

### Cycle-level hooks (`-PreCycleScript` / `-PostCycleScript`)

Pass the path to a `.ps1` file. The script is dot-sourced (not spawned), so it runs in the same scope as the orchestrator.

- **PreCycle** fires after pre-flight checks pass and after the max-iterations safety check, immediately before the first update phase. It does NOT fire on abort paths (mutex collision, metered connection abort, pre-flight hard block).
- **PostCycle** fires after the final phase completes, before the reboot/completion decision is made. It fires on: normal cycle completion (no pending reboots), and max-iterations exceeded termination. It does NOT fire on the reboot path (the next boot is a new cycle invocation).

If the path does not exist, a Warn is logged and execution continues. Exceptions in the hook are caught and logged at Warn — they never abort the cycle.

### Per-phase hooks (`hooks.psd1` sidecar)

Create a file named `hooks.psd1` in the same directory as `Invoke-BootUpdateCycle.ps1` (or pass `-HooksConfig` with an alternate path). The file must evaluate to a hashtable of scriptblocks:

```powershell
@{
    BeforeWinget            = { Write-Host 'About to run Winget' }
    AfterWinget             = { Write-Host 'Winget done' }
    BeforeChoco             = { ... }
    AfterChoco              = { ... }
    BeforeWindowsUpdate     = { ... }
    AfterWindowsUpdate      = { ... }
    BeforeDefender          = { ... }
    AfterDefender           = { ... }
    BeforeDriverFirmware    = { ... }
    AfterDriverFirmware     = { ... }
    BeforeAwsTooling        = { ... }
    AfterAwsTooling         = { ... }
    BeforeOffice365         = { ... }
    AfterOffice365          = { ... }
    BeforePowerShellModules = { ... }
    AfterPowerShellModules  = { ... }
    BeforeWsl               = { ... }
    AfterWsl                = { ... }
    BeforeContainers        = { ... }
    AfterContainers         = { ... }
    # Parallel cohort — hooks fire on the parent thread (approximate order)
    BeforePip         = { ... }; AfterPip         = { ... }
    BeforeNpm         = { ... }; AfterNpm         = { ... }
    BeforeScoop       = { ... }; AfterScoop       = { ... }
    BeforeDotnetTools = { ... }; AfterDotnetTools = { ... }
    BeforeVscode      = { ... }; AfterVscode      = { ... }
}
```

Only keys present in the hashtable are called. Missing keys are silently skipped. Exceptions are caught and logged at Warn.

**Parallel cohort note:** Pip, Npm, Scoop, DotnetTools, and Vscode run as ThreadJob workers in isolated runspaces. Their Before hooks fire on the parent thread before the job batch launches; their After hooks fire on the parent thread as each job result is collected. This is approximate — not guaranteed to interleave with the actual job execution timeline.

### Scope and safety

All hooks (both cycle-level and per-phase) run in the same PowerShell scope as the orchestrator. They can read `$state`, `$script:PackageTimeoutMinutes`, `$script:LogPath`, and all other `$script:*` variables. Mutations are possible but unsupported — the orchestrator's state machine is authoritative.

The `hooks.psd1` file is evaluated as a scriptblock, not parsed in safe mode, so it can contain full PowerShell expressions. Treat it as local privileged code.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
