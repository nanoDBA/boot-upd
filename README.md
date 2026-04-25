# Boot Update Cycle

**Run `upd` as admin. Walk away. Come back fully patched.**

A Windows boot-time automation tool that runs every package manager you have, reboots when updates require it, and repeats until no pending reboots remain — then self-destructs. Solves the "restart required" whack-a-mole problem once and for all.

## What it updates

| Phase | Package Manager | Default | Notes |
|-------|----------------|---------|-------|
| 1 | **Winget** | On | User + machine scope on first run; machine-only after reboot |
| 2 | **Chocolatey** | On | `choco upgrade all -y` |
| 3 | **Windows Update** | On | Security, Critical, Definition updates (excludes SQL Server) |
| 4 | **AWS Tooling** | Off | Optional CLI v2 + AWS.Tools repair |
| 5 | **pip** | On | All outdated global packages |
| 6 | **npm** | On | All global packages |
| 7 | **Office 365** | On | Click-to-Run silent update |
| 8 | **PowerShell Modules** | On | All user-installed modules via `Update-Module` |
| 9 | **Scoop** | On | User-scoped; skipped under SYSTEM |
| 10 | **.NET Global Tools** | **Off** | High risk — can break SDK-dependent builds |
| 11 | **VS Code Extensions** | On | User-scoped; skipped under SYSTEM |

## Quick start

```
upd
```

That's it. Runs from an elevated command prompt, PowerShell, or the Run dialog (Win+R → `upd` → Ctrl+Shift+Enter).

`upd.cmd` auto-adds itself to your system PATH on first run, so it works from anywhere after that.

### What happens

1. Pre-flight checks validate disk space, network, battery, and conflicting installers
2. First iteration runs in **your** console (user context) — the only chance for user-scoped winget/Scoop/VS Code
3. If any updates need a reboot, a scheduled task is registered and `shutdown /r` fires
4. Post-reboot iterations run as SYSTEM via the scheduled task
5. Repeats until no pending reboots remain (max 5 iterations safety valve)
6. Self-destructs: removes the scheduled task, cleans up state

### Reboot delay

```
upd        # immediate reboot (0 sec delay)
upd 120    # 2-minute countdown — users can cancel with: shutdown /a
```

## Requirements

- **Windows 10/11**
- **PowerShell 7+** (`pwsh`)
- **Administrator privileges**

Package managers are auto-detected. Missing ones are skipped with a warning.

## Files

| File | Purpose |
|------|---------|
| `upd.cmd` | Entry point — run this |
| `Deploy-BootUpdateCycle.ps1` | Deploys scripts to ProgramData + runs first iteration |
| `Invoke-BootUpdateCycle.ps1` | The orchestrator — runs all updates, manages reboots |
| `Register-BootUpdateTask.ps1` | Standalone task registration (alternative to Deploy) |
| `Unregister-BootUpdateTask.ps1` | Emergency stop — removes the scheduled task |
| `Repair-AwsTooling.ps1` | Optional AWS CLI v2 + module maintenance |

## Monitoring

```powershell
# Live log tail
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.log" -Tail 50 -Wait

# Cycle history (last 50 runs with package counts)
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.history.json" | ConvertFrom-Json

# Windows Event Log
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='BootUpdateCycle'} | Select-Object -First 10
```

## Emergency stop

```powershell
# Cancel a pending reboot
shutdown /a

# Remove the scheduled task (stops the cycle)
Unregister-ScheduledTask -TaskName 'BootUpdateCycle' -Confirm:$false

# Full cleanup
& "$env:ProgramData\BootUpdateCycle\Uninstall.ps1" -RemoveFolder
```

## Configuration

Edit the `$Config` block in `Deploy-BootUpdateCycle.ps1`:

```powershell
$Config = @{
    MaxIterations         = 5       # Safety valve
    PackageTimeoutMin     = 30      # Hard timeout per package manager
    RebootDelaySec        = 120     # Countdown before reboot (0 = immediate)
    SkipPip               = $false
    SkipNpm               = $false
    SkipOffice365         = $false
    SkipAwsTooling        = $true   # Off by default
    SkipPowerShellModules = $false
    SkipScoop             = $false
    SkipDotnetTools       = $true   # Off by default — high risk
    SkipVscode            = $false
}
```

## Smart timeouts

Package managers get killed if they're truly stuck, but busy installs are left alone:

- **Idle timeout (5 min)**: If the entire process tree (winget + msiexec + setup.exe + children) has zero CPU activity for 5 minutes, it's stuck — kill it
- **Hard timeout (configurable)**: Absolute ceiling regardless of activity
- **Timed-out packages retry next boot** — not lost, just delayed

This means Visual Studio can install for 45 minutes (busy CPU = fine), but a hung winget source refresh gets killed in 5 minutes (zero CPU = stuck).

## License

MIT
