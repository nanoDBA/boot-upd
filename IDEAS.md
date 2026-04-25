# IDEAS.md

Future enhancements for Boot Update Cycle.

---

## 🔧 Quick Wins

| Idea | Notes | Effort |
|------|-------|--------|
| **Dry run mode** | `-WhatIf` that shows what *would* update without touching anything | Low |
| ~~**Pre-flight checks**~~ | ✅ DONE — disk, network, battery, conflicting installers, WU service | Low |
| ~~**dotnet tools**~~ | ✅ DONE — opt-in (`SkipDotnetTools = $true` by default) | Low |
| ~~**PowerShell modules**~~ | ✅ DONE — `Update-Module` with per-module timeout | Low |
| ~~**Scoop**~~ | ✅ DONE — user-scoped, auto-skips under SYSTEM | Low |

---

## 📊 Observability

| Idea | Notes | Effort |
|------|-------|--------|
| **Webhook/email** | POST to Teams/Slack/Discord on completion (works under SYSTEM) | Medium |
| **Update counts per cycle** | Already tracking in Summary, could graph over time | Low |
| **Health check** | Post-update smoke test — can critical services still start? | Medium |

---

## ⚠️ Safety/Control

| Idea | Notes | Effort |
|------|-------|--------|
| **Exclude patterns** | Beyond just SQL — allow `$Config.ExcludePatterns = @('Teams', 'OneDrive')` | Medium |
| **Maintenance window** | Only run updates between 2-5 AM, otherwise defer | Medium |
| **Staged rollout** | Update one package manager per iteration, not all at once | Medium |
| **Pre-update snapshot** | Create restore point before starting (risky on servers, handy on workstations) | Low |
| ~~**Idle detection timeout**~~ | ✅ DONE — process-tree CPU monitoring, 5 min idle + hard timeout backstop | Medium |

---

## 🚀 Ambitious

| Idea | Notes | Effort |
|------|-------|--------|
| **Office 365 (C2R)** | `OfficeC2RClient.exe /update user` — safe at boot time, risky during user session | Low |
| **Windows Store apps** | `Get-AppxPackage \| Update-AppxPackage` — messy but doable | High |
| ~~**VS Code extensions**~~ | ✅ DONE — `code --update-extensions`, auto-skips under SYSTEM | Low |
| **Driver updates** | Enable the 'Drivers' category in Windows Update (currently excluded) | Low |
| **Parallel execution** | Run Chocolatey + Winget simultaneously (risky, potential conflicts) | High |

---

## 📝 Implementation Notes

### dotnet tools
```powershell
function Update-DotnetTools {
    $dotnet = Get-Command dotnet -EA SilentlyContinue
    if (-not $dotnet) { Write-Log 'dotnet not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating dotnet global tools...'
    $tools = & dotnet tool list --global 2>$null | Select-Object -Skip 2 | ForEach-Object { ($_ -split '\s+')[0] }
    $count = 0
    foreach ($tool in $tools) {
        & dotnet tool update --global $tool 2>&1 | ForEach-Object { Write-Log $_ }
        $count++
    }
    return @{ Success = $true; Count = $count }
}
```

### PowerShell modules
```powershell
function Update-PowerShellModules {
    Write-Log 'Updating PowerShell modules...'
    $count = 0
    Get-InstalledModule | ForEach-Object {
        Write-Log "Checking: $($_.Name)"
        try {
            Update-Module $_.Name -Force -ErrorAction Stop
            $count++
        } catch {
            Write-Log "Failed to update $($_.Name): $_" -Level Warn
        }
    }
    return @{ Success = $true; Count = $count }
}
```

### Pre-flight checks
```powershell
function Test-PreFlightChecks {
    $issues = @()
    
    # Disk space
    $sysDrive = Get-PSDrive -Name ($env:SystemDrive -replace ':','')
    $freeGB = [math]::Round($sysDrive.Free / 1GB, 1)
    if ($freeGB -lt 5) { $issues += "Low disk space: ${freeGB}GB free on $env:SystemDrive" }
    
    # Network
    $ping = Test-Connection -ComputerName 'chocolatey.org' -Count 1 -Quiet
    if (-not $ping) { $issues += "No network connectivity to chocolatey.org" }
    
    return $issues
}
```

### Webhook notification
```powershell
function Send-WebhookNotification {
    param([string]$WebhookUrl, [string]$Title, [string]$Message)
    if (-not $WebhookUrl) { return }
    
    $body = @{
        text = "$Title`n$Message"
        # Teams/Slack format varies - this is generic
    } | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType 'application/json'
        Write-Log "Notification: Webhook sent"
    } catch {
        Write-Log "Notification: Webhook failed: $_" -Level Warn
    }
}
```

### Office 365 Click-to-Run
```powershell
function Update-Office365 {
    $c2rClient = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    if (-not (Test-Path $c2rClient)) {
        Write-Log 'Office C2R not found, skipping.' -Level Warn
        return @{ Success = $true; Count = 0 }
    }
    
    Write-Log 'Updating Office 365 (Click-to-Run)...'
    try {
        # updatepromptuser=false  - Don't prompt
        # forceappshutdown=true   - Close Office apps (safe at boot, no user session)
        # displaylevel=false      - Silent mode
        $output = & $c2rClient /update user updatepromptuser=false forceappshutdown=true displaylevel=false 2>&1
        $output | ForEach-Object { Write-Log $_ }
        
        # C2R doesn't give great exit codes, but we tried
        Write-Log 'Office 365 update triggered (may complete in background)'
        return @{ Success = $true; Count = 1 }
    } catch {
        Write-Log "Office 365 update error: $_" -Level Error
        return @{ Success = $true; Count = 0 }
    }
}
```
**Note:** Safe to run at boot (before user logon) since no Office apps are open. Risky during user session — `forceappshutdown=true` kills apps and loses unsaved work.

### Idle Detection Timeout (v2 feature)

**Problem:** Fixed timeout (30 min) is a blunt instrument.  
- VS installing for 45 minutes at 100% CPU? Killed. 😢  
- Winget hung at 0% CPU for 5 minutes? Still waiting. 😤

**Proposed solution:** Kill after N minutes of *inactivity* across the process tree, not wall clock time.

**Signals to monitor:**

| Signal | How | Reliability |
|--------|-----|-------------|
| CPU time delta | Compare `TotalProcessorTime` over interval | Good — but I/O-bound ops look idle |
| Child process count | Walk process tree, count children | Good — installers spawn msiexec, setup.exe |
| Handle count delta | `HandleCount` property changes | Decent proxy for "doing something" |

**Key gotcha:** Package managers spawn child processes. `winget.exe` might be idle while `msiexec.exe` burns 100% CPU installing VS. Must walk the process tree:

```powershell
function Get-ProcessTreeCpuTime {
    param([int]$ParentPid)
    
    $total = [timespan]::Zero
    $procs = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ParentPid -or $_.ProcessId -eq $ParentPid }
    
    foreach ($p in $procs) {
        try {
            $proc = Get-Process -Id $p.ProcessId -EA SilentlyContinue
            if ($proc) {
                $total += $proc.TotalProcessorTime
                # Recurse for grandchildren
                $total += Get-ProcessTreeCpuTime -ParentPid $p.ProcessId
            }
        } catch { }
    }
    return $total
}

function Wait-ProcessWithIdleTimeout {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$IdleTimeoutMinutes = 5,
        [int]$HardTimeoutMinutes = 60,
        [int]$PollIntervalSeconds = 30
    )
    
    $startTime = Get-Date
    $lastCpuTime = Get-ProcessTreeCpuTime -ParentPid $Process.Id
    $lastActivityTime = Get-Date
    
    while (-not $Process.HasExited) {
        Start-Sleep -Seconds $PollIntervalSeconds
        
        $elapsed = (Get-Date) - $startTime
        $currentCpuTime = Get-ProcessTreeCpuTime -ParentPid $Process.Id
        
        # Check for activity (CPU time increased)
        if ($currentCpuTime -gt $lastCpuTime) {
            $lastActivityTime = Get-Date
            $lastCpuTime = $currentCpuTime
            Write-Log "  Still active (CPU: $([math]::Round($currentCpuTime.TotalSeconds))s, elapsed: $([math]::Round($elapsed.TotalMinutes))m)"
        }
        
        $idleTime = (Get-Date) - $lastActivityTime
        
        # Idle timeout
        if ($idleTime.TotalMinutes -ge $IdleTimeoutMinutes) {
            Write-Log "IDLE TIMEOUT: No CPU activity for $IdleTimeoutMinutes minutes" -Level Error
            return @{ Reason = 'IdleTimeout'; Elapsed = $elapsed }
        }
        
        # Hard timeout (safety backstop)
        if ($elapsed.TotalMinutes -ge $HardTimeoutMinutes) {
            Write-Log "HARD TIMEOUT: Exceeded $HardTimeoutMinutes minutes total" -Level Error
            return @{ Reason = 'HardTimeout'; Elapsed = $elapsed }
        }
    }
    
    return @{ Reason = 'Completed'; Elapsed = (Get-Date) - $startTime }
}
```

**Recommended defaults:**
- `IdleTimeoutMinutes = 5` — If nothing's happening for 5 min, it's stuck
- `HardTimeoutMinutes = 60` — Absolute backstop, even if "active"
- `PollIntervalSeconds = 30` — Check every 30s, log heartbeat if active

**When to implement:** If users report timeouts killing legitimate long installs (VS, SQL Server, etc.) and the current "retry next boot" behavior isn't acceptable.

**Complexity:** ~40 lines of code, but edge cases abound (zombie processes, process tree walking on fast-exiting children, etc.).  Better to wait for real-world pain before building.

---

## 🗳️ Priority Voting

If implementing, suggested order:

1. ✅ Pre-flight checks (prevents wasted cycles) — IMPLEMENTED
2. ✅ PowerShell modules (generally safe, high value) — IMPLEMENTED
3. ⬜ Webhook notifications (remote monitoring)
4. ⬜ Exclude patterns (flexibility)
5. ✅ VS Code extensions — IMPLEMENTED
6. ✅ dotnet tools (opt-in, off by default) — IMPLEMENTED
7. ✅ Scoop packages — IMPLEMENTED
8. ✅ Smart idle-aware timeouts — IMPLEMENTED
9. ✅ Crash recovery / atomic state writes — IMPLEMENTED

---

## ⚠️ Risk Assessment

| Package Manager | Default | Risk | Reasoning |
|-----------------|---------|------|-----------|
| Chocolatey | ✅ On | Low | Machine-level apps, usually safe |
| Winget | ✅ On | Low | Machine-level apps, usually safe |
| Windows Update | ✅ On | Low | Excludes SQL, critical patches only |
| pip | ✅ On | Medium | Global packages, can break scripts |
| npm | ✅ On | Medium | Global packages, can break toolchains |
| **dotnet tools** | ❌ Off | **High** | SDK-coupled, version pinning matters |
| PowerShell modules | ⬜ TBD | Low-Med | Generally backwards compatible |
| Scoop | ⬜ TBD | Low | User-scoped, dev-focused |
| **Office 365 C2R** | ⬜ TBD | **Low at boot** | Safe when no Office apps running |