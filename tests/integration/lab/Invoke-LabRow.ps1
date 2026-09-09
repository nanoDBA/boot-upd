#requires -Version 7.0
<#
.SYNOPSIS
    Run one boot-upd matrix row on a lab guest and collect independent evidence.

.DESCRIPTION
    Resets the guest to a cold checkpoint, syncs the working tree, optionally arms real
    pending-reboot state, runs a cycle, and collects evidence to a host directory.

    The evidence rule this encodes: NEVER trust the updater's log alone. Row A's log was
    internally consistent and wrong - it claimed two reboots where Windows event 6005
    recorded three. Every row therefore captures the OS's own boot record alongside the
    updater's account, and compares them.

    Reboots are armed from REAL servicing state. Enabling a restart-requiring optional
    feature sets CBS RebootPending, which is the signal the updater actually reads. Note
    TelnetClient does NOT require a restart and produces no signal; the features used here
    were each verified to set RebootPending.

    Reboots inside the guest always go through 'shutdown /r'. Restart-VM is a hard reset
    that discards unflushed registry and file writes, which in a gate about state surviving
    restarts would manufacture failures that do not exist.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$Row,
    [string]$Checkpoint   = 'staged',
    [string]$SourceRoot   = 'G:\My Drive\backups\projects\boot-upd',
    [string]$EvidenceRoot = 'C:\HyperV\evidence',
    [int]$ArmReboots      = 0,
    [string]$GuestUser    = 'updtest',
    [string]$GuestPassword,
    [int]$TimeoutMinutes  = 60,
    [switch]$SkipSync,
    [switch]$SystemContext,
    <# Fires inside the guest the first time the updater's log matches -InjectWhen. Rows C,
       D, E and G all work by disturbing the cycle at a specific moment rather than by
       letting it run clean, and the moment they care about is announced in the log. #>
    [string]$InjectWhen = '',
    [scriptblock]$InjectAction = $null,
    <# Extra arguments for Deploy-BootUpdateCycle.ps1. Row C needs -RebootDelaySec above
       zero: the default is 0, documented as "immediate, /f = force-close apps, no abort",
       so with the shipped default there is no countdown for a cancel to act on at all. #>
    [string]$DeployArgs = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabCredential.ps1')
if (-not $GuestPassword) { $GuestPassword = Get-BootUpdLabPassword }
if (-not $GuestPassword) {
    throw 'No lab guest password available. Store one with: . ./LabCredential.ps1; Set-BootUpdLabPassword -Generate'
}
$cred = New-Object System.Management.Automation.PSCredential($GuestUser,
        (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
$evidenceDir = Join-Path $EvidenceRoot ("{0}-{1}-{2}" -f $Row, $VMName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
function Say { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Cyan }

Say "row $Row on $VMName from checkpoint '$Checkpoint'"
Restore-VMCheckpoint -VMName $VMName -Name $Checkpoint -Confirm:$false
if ((Get-VM -Name $VMName).State -ne 'Running') { Start-VM -Name $VMName }

function Wait-Desktop {
    param([int]$Minutes = 10)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $p = Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ScriptBlock {
                [pscustomobject]@{ Exp = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
                                   Lui = @(Get-Process LogonUI -ErrorAction SilentlyContinue).Count }
            }
            if ($p.Exp -ge 1 -and $p.Lui -eq 0) { return $true }
        } catch { }
        Start-Sleep -Seconds 10
    }
    return $false
}
function Wait-Reachable {
    param([int]$Minutes = 10)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        try { Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ScriptBlock { 1 } | Out-Null; return $true } catch { }
        Start-Sleep -Seconds 10
    }
    return $false
}

# A no-autologon guest never reaches a desktop by design, so only require reachability there.
$needsDesktop = $Checkpoint -notmatch 'no-autologon'
if ($needsDesktop) { if (-not (Wait-Desktop)) { throw 'Guest never reached a desktop.' } }
else { if (-not (Wait-Reachable)) { throw 'Guest never became reachable.' } }
Say 'guest ready'

if (-not $SkipSync) {
    Say 'syncing working tree'
    $s = New-PSSession -VMName $VMName -Credential $cred
    try {
        Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Path 'C:\Lab\boot-upd' -Force | Out-Null }
        $files = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File |
                 Where-Object { $_.FullName -notmatch '\\\.git\\|\\\.beads\\|\\testResults\.xml' }
        $dirs = $files | ForEach-Object { Split-Path ($_.FullName.Substring($SourceRoot.Length).TrimStart('\')) -Parent } |
                Where-Object { $_ } | Sort-Object -Unique
        Invoke-Command -Session $s -ArgumentList (, $dirs) -ScriptBlock {
            param($ds) foreach ($d in $ds) { New-Item -ItemType Directory -Path (Join-Path 'C:\Lab\boot-upd' $d) -Force | Out-Null }
        }
        foreach ($f in $files) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path 'C:\Lab\boot-upd' $f.FullName.Substring($SourceRoot.Length).TrimStart('\')) -ToSession $s -Force
        }
        $hash = Invoke-Command -Session $s -ScriptBlock { (Get-FileHash 'C:\Lab\boot-upd\Invoke-BootUpdateCycle.ps1' -Algorithm SHA256).Hash }
        $hostHash = (Get-FileHash (Join-Path $SourceRoot 'Invoke-BootUpdateCycle.ps1') -Algorithm SHA256).Hash
        if ($hash -ne $hostHash) { throw "Orchestrator hash mismatch: guest $hash vs host $hostHash" }
        Say "synced $($files.Count) files, orchestrator hash verified"
    } finally { Remove-PSSession $s }
}

if ($ArmReboots -gt 0) {
    Say "arming $ArmReboots real pending reboot(s)"
    Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $ArmReboots -ScriptBlock {
        param($Count)
        $gen = @'
$state = "C:\Lab\reboot-gen.txt"
$features = @("Microsoft-Hyper-V-All","Containers","Microsoft-Windows-Subsystem-Linux")
$limit = [int](Get-Content "C:\Lab\reboot-limit.txt")
$n = 0
if (Test-Path $state) { $n = [int](Get-Content $state) }
if ($n -lt $limit -and $n -lt $features.Count) {
    Enable-WindowsOptionalFeature -Online -FeatureName $features[$n] -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Set-Content $state ($n + 1)
}
'@
        Set-Content 'C:\Lab\Force-PendingReboot.ps1' -Value $gen -Encoding UTF8
        Set-Content 'C:\Lab\reboot-limit.txt' -Value $Count
        Set-Content 'C:\Lab\reboot-gen.txt' -Value 0
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\Force-PendingReboot.ps1'
        $t = New-ScheduledTaskTrigger -AtStartup
        $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'Lab-ForcePendingReboot' -Action $a -Trigger $t -Principal $p -Force | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Lab\Force-PendingReboot.ps1'
    } | Out-Null
}

<# An Interactive principal cannot run while nobody is signed in - the task just stays
   queued - so a no-user row has to launch as SYSTEM. That is also the context the
   updater's own BootUpdateCycleFallback task runs in, which is what such a row exercises. #>
if ($SystemContext) { Say 'launching the cycle as SYSTEM (no interactive user)' }
else { Say 'launching the cycle in the interactive session' }
Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $GuestUser, ([bool]$SystemContext), $DeployArgs -ScriptBlock {
    param($User, $AsSystem, $Extra)
    <# Capture Deploy's own stdout and stderr. Without this a failing deploy leaves nothing
       behind at all: the updater log stops wherever the script died, and everything the
       script itself printed goes to a scheduled task and is lost. Row B first failed with
       nothing but exit code 1 to go on. #>
    $inner = '& "C:\Lab\boot-upd\Deploy-BootUpdateCycle.ps1" -NonInteractive -OutputMode Normal EXTRA_ARGS *>&1 | Tee-Object -FilePath C:\Lab\deploy-output.txt'
    $inner = $inner.Replace('EXTRA_ARGS', $Extra)
    $argument = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner.Replace('"', '\"') + '"'
    $a = New-ScheduledTaskAction -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' `
         -Argument $argument `
         -WorkingDirectory 'C:\Lab\boot-upd'
    $p = if ($AsSystem) { New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest }
         else { New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$User" -LogonType Interactive -RunLevel Highest }
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromHours(6))
    Register-ScheduledTask -TaskName 'Lab-RunDeploy' -Action $a -Principal $p -Settings $s -Force | Out-Null
    Start-ScheduledTask -TaskName 'Lab-RunDeploy'
} | Out-Null

<# Confirm the task actually started something. A scheduled task whose Execute path does not
   exist fails instantly with 0x80070002 and reports that only as a task result, so the row
   below would monitor an empty log for its whole timeout and then call the run inconclusive.
   Forty minutes were spent that way on a guest with no PowerShell 7 installed. #>
Start-Sleep -Seconds 10
$launchProbe = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    [pscustomobject]@{
        Result  = (Get-ScheduledTaskInfo -TaskName 'Lab-RunDeploy').LastTaskResult
        State   = (Get-ScheduledTask     -TaskName 'Lab-RunDeploy').State
        HasPwsh = Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe'
    }
}
if ($launchProbe.State -ne 'Running' -and $launchProbe.Result -ne 0 -and $launchProbe.Result -ne 267009) {
    $hint = if (-not $launchProbe.HasPwsh) { ' PowerShell 7 is not installed in the guest, so pwsh.exe does not exist.' } else { '' }
    throw ("Deploy task did not start: LastTaskResult 0x{0:X8}, state {1}.{2}" -f $launchProbe.Result, $launchProbe.State, $hint)
}
Say 'monitoring'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
<# Append every poll line to the evidence file as it is produced. Accumulating the timeline
   in memory and writing it once at the end meant a row killed or timed out mid-run left no
   timeline at all, and nothing was tailable while the row ran. With this, Get-Content -Wait
   on one or several guests' host-timeline.txt is a live view that costs no agent at all. #>
$timelinePath = Join-Path $evidenceDir 'host-timeline.txt'
function Add-Timeline { param([string]$Line) Add-Content -LiteralPath $timelinePath -Value $Line }
$complete = $false
$injected = $false
$injectArmed = [bool]($InjectWhen -and $InjectAction)
if ($injectArmed) { Say "injection armed on /$InjectWhen/" }
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ArgumentList $InjectWhen -ScriptBlock {
            param($Pattern)
            $log = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.log'
            $lines = if (Test-Path $log) { @(Get-Content $log -ErrorAction SilentlyContinue) } else { @() }
            [pscustomobject]@{
                Lines    = $lines.Count
                Passes   = ($lines -match 'BOOT UPDATE CYCLE (STARTED|RESUMED)').Count
                Complete = ($lines -match 'BOOT UPDATE CYCLE COMPLETE').Count
                <# A cycle that stops itself at a limit is just as terminal as one that
                   converges, and waiting out the timeout after it has already disarmed and
                   reported adds nothing but wall-clock. Row B v5 sat here for eight minutes
                   after the updater had finished saying everything it had to say. #>
                Terminal = ($lines -match '(recovery limit|Reboot limit) .*reached').Count
                Tasks    = @(Get-ScheduledTask -TaskName 'BootUpdateCycle*' -ErrorAction SilentlyContinue).Count
                Last     = if ($lines.Count) { ($lines[-1] -replace '\s+', ' ').Trim() } else { '' }
                Matched  = if ($Pattern) { ($lines -match $Pattern).Count -gt 0 } else { $false }
            }
        }
        Add-Timeline (("{0} passes={1} lines={2} tasks={3} :: {4}" -f (Get-Date -Format 'HH:mm:ss'), $r.Passes, $r.Lines, $r.Tasks, $r.Last))
        if ($injectArmed -and -not $injected -and $r.Matched) {
            Say "injecting on match at $(Get-Date -Format 'HH:mm:ss')"
            Add-Timeline (("{0} INJECTED on /{1}/" -f (Get-Date -Format 'HH:mm:ss'), $InjectWhen))
            try { Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock $InjectAction -ErrorAction Stop | Out-Null }
            catch { Add-Timeline (("{0} injection failed: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)) }
            $injected = $true
        }
        if ($r.Complete -ge 1 -and $r.Tasks -eq 0) { $complete = $true; Say "cycle complete after $($r.Passes) pass(es)"; break }
        if ($r.Terminal -ge 1 -and $r.Tasks -eq 0) { Say "cycle stopped itself at a limit after $($r.Passes) pass(es)"; break }
    } catch { Add-Timeline (("{0} unreachable (rebooting)" -f (Get-Date -Format 'HH:mm:ss'))) }
    <# Poll fast while waiting to inject: a restart countdown is measured in seconds, so a
       40-second cadence would sail past the only moment the row cares about. #>
    Start-Sleep -Seconds $(if ($injectArmed -and -not $injected) { 3 } else { 40 })
}

Say 'collecting evidence'
$evidence = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    $log = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.log'
    $lines = if (Test-Path $log) { @(Get-Content $log -ErrorAction SilentlyContinue) } else { @() }
    # Event 6005 is the OS's own boot record, written by the event log service. It is the
    # independent check the updater's log cannot provide about itself.
    $boots = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6005 } -MaxEvents 40 -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty TimeCreated)
    [pscustomobject]@{
        Log             = $lines
        OsBootTimes     = $boots
        StateFileExists = Test-Path 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.state.json'
        TasksRemaining  = @(Get-ScheduledTask -TaskName 'BootUpdateCycle*' -ErrorAction SilentlyContinue).Count
        CbsPending      = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        <# For a no-user row, proof that no interactive session ever appeared is part of the
           result: a SYSTEM-fallback claim means nothing if somebody was quietly logged in. #>
        ConsoleUser     = (Get-CimInstance Win32_ComputerSystem).UserName
        ExplorerCount   = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
        DeployOutput    = if (Test-Path 'C:\Lab\deploy-output.txt') { @(Get-Content 'C:\Lab\deploy-output.txt' -ErrorAction SilentlyContinue) } else { @() }
        DeployTaskResult = (Get-ScheduledTaskInfo -TaskName 'Lab-RunDeploy' -ErrorAction SilentlyContinue).LastTaskResult
    }
}

$evidence.Log | Set-Content (Join-Path $evidenceDir 'BootUpdateCycle.log')
if ($evidence.DeployOutput.Count) { $evidence.DeployOutput | Set-Content (Join-Path $evidenceDir 'deploy-output.txt') }
& 'C:\HyperV\Get-VmScreen.ps1' -VMName $VMName -Path (Join-Path $evidenceDir 'console.png') | Out-Null

$startLine = $evidence.Log | Where-Object { $_ -match 'BOOT UPDATE CYCLE STARTED' } | Select-Object -First 1
$sessionStart = if ($startLine -match '\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') { [datetime]$Matches[1] } else { (Get-Date).AddHours(-2) }
<# Bound the window at BOTH ends. Filtering only on "at or after the session started" let a
   stray event stamped hours in the future - left in the image from its own creation - count
   as a boot, and the row then reported the updater under-claiming when it had not. An
   acceptance check that can produce a false accusation is as useless as one that can be
   silently satisfied. #>
$completionLine = $evidence.Log | Where-Object { $_ -match 'BOOT UPDATE CYCLE COMPLETE' } | Select-Object -Last 1
$sessionEnd = if ($completionLine -match '\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') { ([datetime]$Matches[1]).AddMinutes(2) } else { (Get-Date).AddMinutes(2) }
$bootsDuringRun = @($evidence.OsBootTimes | Where-Object { $_ -ge $sessionStart -and $_ -le $sessionEnd })
<# The claim is only made in a completion line, so a run that never completes has made no
   claim at all. Reporting that absence as 0 asserted something the updater never said, and
   RebootAccountingAgrees then read false - the row accusing the updater of under-counting
   reboots on a run where it had correctly declined to claim anything. $null says "no claim
   to compare", which is the truth, and keeps the disagreement flag meaningful. #>
$claimed = $null
$claimLine = $evidence.Log | Where-Object { $_ -match 'BOOT UPDATE CYCLE COMPLETE' } | Select-Object -Last 1
if ($claimLine -match '(\d+) reboot\(s\)') { $claimed = [int]$Matches[1] }

$summary = [pscustomobject]@{
    Row              = $Row
    VM               = $VMName
    Checkpoint       = $Checkpoint
    Completed        = $complete
    Passes           = ($evidence.Log -match 'BOOT UPDATE CYCLE (STARTED|RESUMED)').Count
    RebootsClaimed   = $claimed
    RebootsObservedOS = $bootsDuringRun.Count
    RebootAccountingAgrees = if ($null -eq $claimed) { $null } else { $claimed -eq $bootsDuringRun.Count }
    StateFileRemains = $evidence.StateFileExists
    TasksRemaining   = $evidence.TasksRemaining
    CbsPending       = $evidence.CbsPending
    Injected         = $injected
    DeployTaskResult = $evidence.DeployTaskResult
    DeployOutputTail = ($evidence.DeployOutput | Select-Object -Last 3) -join ' | '
    ConsoleUser      = $evidence.ConsoleUser
    ExplorerCount    = $evidence.ExplorerCount
    EvidenceDir      = $evidenceDir
}
$summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'summary.json')
$summary
