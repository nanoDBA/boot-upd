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
5. AWS tooling repair (off by default, `-SkipAwsTooling:$false` to enable)
6. pip global packages (on by default, `-SkipPip` to disable)
7. npm global packages (on by default, `-SkipNpm` to disable)
8. Office 365 Click-to-Run (on by default, `-SkipOffice365` to disable)
9. PowerShell modules via `Update-Module` (on by default, `-SkipPowerShellModules` to disable)
10. Scoop packages (on by default, `-SkipScoop` to disable; user-scoped, skipped under SYSTEM)
11. .NET global tools (OFF by default — high risk; `-SkipDotnetTools:$false` to enable)
12. VS Code extensions (on by default, `-SkipVscode` to disable; user-scoped, skipped under SYSTEM)

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
- State schema v2: all phase flags use `*Done` suffix consistently; versioned with auto-migration

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
