# Boot Update Cycle

**Run `upd` as admin. Walk away. Come back fully patched.**

A Windows boot-time automation tool that runs every configured package manager, checkpoints its work, reboots when updates require it, and resumes until the configured scope verifies clean — then retires its resume tasks.

<img src="docs/img/splash-theme0.png" alt="Boot Update Cycle splash — neon gradient theme" width="684">

The BBS-style splash defaults to the neon gradient theme above; two more ship with it (`upd splash` previews them all; switch with `BOOT_UPDATE_SPLASH_THEME=0|1|2`):

<details>
<summary>The other two themes</summary>

<img src="docs/img/splash-theme1.png" alt="Boot Update Cycle outline dither theme" width="684">

<img src="docs/img/splash-theme2.png" alt="Boot Update Cycle classic 16-color theme" width="684">

</details>

## Updater in action

The default `Normal` view stays zoomed out while the animated `BOOT//PULSE` row shows the current operation:

<img src="docs/img/updater-progress.png" alt="Boot Update Cycle updating Windows in the compact Normal console view" width="900">

When the configured work, convergence checks, reboot checks, service health, and terminal cleanup all pass, the final screen has some earned personality:

<img src="docs/img/updater-complete.png" alt="Boot Update Cycle configured patch pass verified completion screen" width="900">

<sub>Representative v2.5.30 console captures rendered from the production UI text for deterministic, privacy-safe documentation; package counts and elapsed time are illustrative.</sub>

## What it updates

| Phase | Package Manager | Default | Notes |
|-------|----------------|---------|-------|
| 1 | **Winget** | On | User + machine scope; ARSO resumes user scope after reboot, with a delayed SYSTEM safety net |
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

Fresh install, repair, and run—the Chocolatey-style convenience form for an elevated
Command Prompt, PowerShell, or Win+R:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://github.com/nanoDBA/boot-upd/releases/latest/download/Install-UpdCompat.ps1' -OutFile ([IO.Path]::Combine([IO.Path]::GetTempPath(),'Install-UpdCompat.ps1')); & ([IO.Path]::Combine([IO.Path]::GetTempPath(),'Install-UpdCompat.ps1')) -CommandArguments run"
```

This convenience command trusts GitHub HTTPS and the repository's current latest release.
The downloaded installer then verifies every runtime asset against its published SHA256
sidecar and installs to `Program Files\BootUpdateCycle`, or transactionally repairs the
existing `upd.cmd` PATH winner. For a version-and-hash-pinned bootstrap, use the stricter
compatibility command below.

Already installed:

```
upd
```

That's it. Runs from an elevated command prompt, PowerShell, or the Run dialog (Win+R → `upd` → Ctrl+Shift+Enter).

`upd.cmd` auto-adds itself to your system PATH on first run, so it works from anywhere after that.

### Friendly launcher

The launcher accepts both commands and typed run options. Help, previews, planning,
version, and status do not request elevation; only `run` starts the UAC-protected updater.

```text
upd help                         Full command and option reference
upd /?                           Same help (also ?, /help, -h, --help, usage)
upd splash                       Preview all splash themes; no updates
upd demo 12                      Run the production BOOT//PULSE animation for 12 seconds
upd fun 12                       Splash parade followed by the animation
upd update                       Refresh the checksummed launcher bundle and exit
upd aws                          Update/repair AWS CLI v2 and AWS.Tools
upd repair                       Recover missing/corrupt launcher and core files
upd bootstrap                    Install/verify PowerShell 7, then show help
upd version                      Show the bundled version
upd status                       Show resume tasks and checkpoint state
upd plan --drivers --delay 120   Resolve options without elevation or changes

upd                              Run with defaults
upd 120                          Legacy shorthand: run with a 120-second reboot warning
upd --delay 120 --drivers --firmware
upd --staged --output-mode Verbose
upd --wsl --containers --allow-metered
upd --exclude Teams,OneDrive --skip-office365
```

Short forms keep everyday commands light: `upd d 12`, `upd f`, `upd p -drv -r 120`,
`upd r -s -o Verbose`, `upd a`, `upd u`, and `upd v`. Short commands do not use a
leading dash; ambiguous dashed forms fail before they can reach the update path. Long
names remain available for scripts and discoverability.

A stable raw-argument bootstrap now checks the latest GitHub release before an operational
command reaches the typed parser. Every executable
asset must have a valid SHA256 sidecar or the refresh is rejected. These checksums detect
corruption but are not code-signing signatures. PowerShell files are
verified and installed first; `upd.cmd` is staged as `upd.cmd.next` and adopted only after
the current PowerShell launcher exits, after a second checksum and version check. The
requested arguments are dispatched through the newly installed typed launcher rather than
the stale in-memory copy. Use `upd u` to request the refresh explicitly or `-nu` to skip the
automatic check for one run. `upd repair` can bootstrap a missing launcher and repair a
missing or corrupt core bundle.

An already-running historical batch cannot benefit from code it has not downloaded: some
pre-v2.5.29 launchers parse the first token as a reboot delay before self-update is reachable.
For those installations, run this version-pinned compatibility bridge **after the old batch
has exited**. It verifies the installer against the hash embedded below, then the installer
verifies and transactionally replaces the complete release bundle before forwarding `aws`:

```powershell
$u='https://github.com/nanoDBA/boot-upd/releases/download/v2.5.36/Install-UpdCompat.ps1'; $f=Join-Path $env:TEMP 'Install-UpdCompat-v2.5.36.ps1'; Invoke-WebRequest $u -OutFile $f; if((Get-FileHash $f -Algorithm SHA256).Hash -ne 'BEBF6F4AD105F7420B84F7DC152F72CA546D0433CC105A903671854BDD4F2293'){throw 'Compatibility installer hash mismatch'}; & $f -CommandArguments aws
```

This is the one-time chicken-and-egg escape hatch. It resolves the first `upd.cmd` on PATH,
stages outside cloud storage, preserves a rollback snapshot, detects sync races, and replaces
only runtime files. It deliberately does not use a mutable gist or `iex`.

Windows PowerShell 5.1 is supported as a bootstrap host. On an operational command,
`upd.cmd` installs PowerShell 7 side-by-side using WinGet when available, or a
Microsoft Authenticode-validated MSI on older Windows Server systems, then relaunches
the PS7 updater. Help and version remain read-only; preview/plan/status commands ask
the user to run `upd bootstrap` rather than silently installing anything. The updater
itself remains PowerShell 7-only so `Start-ThreadJob` and `ForEach-Object -Parallel`
execution are preserved.

Run `upd help` for the complete list, including provider opt-ins, skip switches,
timeouts, iteration limits, health/BitLocker controls, include/exclude filters, and
self-update control. `demo`, `fun`, and `splash` never deploy files, register tasks,
update packages, or reboot Windows.

### Console views

Interactive runs use a compact progress view by default: current phase, overall progress,
phase results, warnings, and errors. The complete timestamped detail stream still goes to
`BootUpdateCycle.log`.

Press `v` at any time during an interactive run to cycle through:

| Mode | Console output |
|---|---|
| `Quiet` | Errors and final/reboot status only |
| `Normal` | The themed splash, progress, phase results, warnings, and errors (default) |
| `Verbose` | Normal plus detailed package-manager output |
| `Debug` | Verbose plus process IDs and heartbeat diagnostics |

Choose the initial view explicitly with `-OutputMode Quiet|Normal|Verbose|Debug`, or set
`OutputMode` in `Deploy-BootUpdateCycle.ps1`. The interactive `BOOT//PULSE` row uses a
classic `| / - \` ASCII propeller with the existing 48-step cyan, blue, magenta, and acid-green
glow. Motion and color advance independently, preserving the gradual fade without abrupt flashes.
ASCII status text is kept immutable; non-ASCII glyphs are represented safely in the live row while
remaining untouched in the log. Key polling and animation disable themselves under SYSTEM,
redirected output, and non-console hosts; file logging is unchanged.

On VT consoles, steady-state frames overwrite the owned row in place to avoid ConsoleHost flicker;
a full erase is reserved for width changes, ordinary output, mode transitions, and cleanup.

All console rendering is built in; the updater does not install or import a third-party TUI module.
Phase headers and results use native ANSI/console output, and the themed splash remains unchanged.

To visually smoke-test animation without running any package updates:

```powershell
.\tools\Show-BootUpdateProgressDemo.ps1
```

The demo renders the same four-frame `BOOT//PULSE` propeller and interpolated neon gradient at the production
100 ms cadence, includes the photographed Windows Update status text, accepts live `v` mode
cycling, and restores its console row and cursor when complete.

Built-in operations that can block for more than a moment run behind a process-tree-aware,
progress-pumped adapter, keeping both animation and `v` key handling responsive. Administrator-supplied
hooks intentionally retain same-scope execution semantics; a long hook must provide its own
console feedback because isolating it would change how hook variables and side effects work.

### What happens

1. Pre-flight checks validate disk space, network, battery, and conflicting installers
2. First iteration runs in **your** console (user context) — the only chance for user-scoped winget/Scoop/VS Code
3. Before mutation, two reboot-signal probes span a 20-second servicing-settle window; an existing reboot requirement is a hard phase barrier
4. Native `3010`/`1641` results and Windows reboot indicators are persisted as reboot evidence until a new Windows boot identity is observed
5. Verified resume tasks are armed before updates start: user-at-logon plus a delayed SYSTEM fallback, with dated watchdogs for canceled shutdowns and deferred retries
6. `shutdown /g` restarts Windows; the checkpoint resumes automatically, preserves user-only work for user context, and retries real provider failures without marking them complete
7. Completion requires every enabled phase, a zero-applicable Windows Update scan, and two clean reboot probes (max 5 successful mutation iterations safety valve)
8. Hooks run, resume tasks and state are removed and verified absent, and only then does the final screen congratulate the user and send the success notification

### Reboot delay

```
upd        # immediate reboot (0 sec delay)
upd 120    # 2-minute countdown — users can cancel with: shutdown /a
```

## Requirements

- **Windows 10/11**
- **PowerShell 7+ runtime** (`upd.cmd` can install it side-by-side from Windows PowerShell 5.1)
- **Administrator privileges**

Package managers are auto-detected. Missing ones are skipped with a warning.

## Files

| File | Purpose |
|------|---------|
| `upd.cmd` | Entry point — run this |
| `tools/Invoke-UpdBootstrap.ps1` | Stable raw-argument preflight and verified current-launcher handoff |
| `tools/Invoke-UpdLauncher.ps1` | Typed commands, compact aliases, UAC boundary, and runtime-bundle updates |
| `tools/Install-UpdCompat.ps1` | One-time repair bridge for historical batch parsers |
| `tools/Install-PowerShell7.ps1` | Windows PowerShell 5.1-compatible PS7 bootstrap |
| `Deploy-BootUpdateCycle.ps1` | Deploys scripts to ProgramData + runs first iteration |
| `Invoke-BootUpdateCycle.ps1` | The orchestrator — runs all updates, manages reboots |
| `Register-BootUpdateTask.ps1` | Standalone task registration (alternative to Deploy) |
| `Unregister-BootUpdateTask.ps1` | Emergency stop — removes the scheduled task |
| `Repair-AwsTooling.ps1` | Optional AWS CLI v2 + module maintenance |
| `tools/Initialize-BootUpdateWebhook.ps1` | Securely configures a notification webhook outside Git and task arguments |

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

### Notification webhook

Never commit a Teams, Slack, or Discord webhook URL or place it in a scheduled-task
command line. Configure it once from an elevated PowerShell prompt; the tool prompts
without echo and stores the URL under ProgramData with access limited to SYSTEM and
local Administrators:

```powershell
./tools/Initialize-BootUpdateWebhook.ps1

# Remove it later
./tools/Initialize-BootUpdateWebhook.ps1 -Remove
```

The legacy `WebhookUrl` deployment setting remains as a one-time migration path. If
set, deployment immediately moves its value into the protected local file and clears
the in-memory configuration before registering a task. Do not save a real URL in a
tracked copy of `Deploy-BootUpdateCycle.ps1`.

### Extension-hook trust boundary

Pre-cycle, post-cycle, and `hooks.psd1` extensions must be located inside the deployed
BootUpdateCycle directory. The orchestrator rejects hooks outside that directory,
hooks reached through reparse points, and hooks whose file or parent directory grants
write access to Everyone, Authenticated Users, or the built-in Users group.

## Smart timeouts

Package managers get killed if they're truly stuck, but busy installs are left alone:

- **Idle timeout (5 min)**: If the entire process tree (winget + msiexec + setup.exe + children) has zero CPU activity for 5 minutes, it's stuck — kill it
- **Hard timeout (configurable)**: Absolute ceiling regardless of activity
- **Timed-out packages retry next boot** — not lost, just delayed

This means Visual Studio can install for 45 minutes (busy CPU = fine), but a hung winget source refresh gets killed in 5 minutes (zero CPU = stuck).

## License

MIT
