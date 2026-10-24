#requires -Version 7.0
<#
.SYNOPSIS
    Test a parked lab cycle's next-sign-in continuation without starting the updater.
.DESCRIPTION
    Run after Invoke-LabRow -StopAtSavedUserWait on a disposable headless guest.
    Verifies the checkpoint and logon-only task, configures one lab autologon, and
    restarts the guest normally. Windows must launch the existing continuation.
    Credentials stay in Credential Manager and the guest's temporary autologon
    settings; they are never included in evidence. The host is never restarted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSourceSha256,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [string]$GuestUser='updtest',
    [string]$CredentialTarget='boot-upd-lab-guest',
    [ValidateRange(1,60)][int]$TimeoutMinutes=20
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'LabCredential.ps1')
. (Join-Path $PSScriptRoot 'LabEvidence.ps1')
$password=Get-BootUpdLabPassword -Target $CredentialTarget
$credential=[pscredential]::new($GuestUser,(ConvertTo-BootUpdLabSecureString $password))
$vm=Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne 'Running') { throw 'The parked guest must already be running.' }
$lockPath=Join-Path $env:ProgramData ("BootUpdateCycle-Lab/locks/{0}.lock" -f $vm.Id)
try { $lease=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','Read') }
catch { throw 'The guest is owned by another lab row; collect that row before resuming.' }
$evidenceDir=Join-Path $EvidenceRoot ('saved-user-resume-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$autologonConfigured=$false
$summary=$null
$verificationPassed=$false
try {
    # Require an idle, real parked cycle; never overwrite a running updater's checkpoint.
    $deadline=(Get-Date).AddMinutes(2)
    do {
        $before=Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock {
            $root='C:\ProgramData\BootUpdateCycle'
            $state=Get-Content (Join-Path $root 'BootUpdateCycle.state.json') -Raw | ConvertFrom-Json
            $tasks=@(Get-ScheduledTask -TaskName 'BootUpdateCycle*' -ErrorAction SilentlyContinue)
            $lines=@(Get-Content (Join-Path $root 'BootUpdateCycle.log'))
            [pscustomobject]@{
                State=$state; Tasks=@($tasks | ForEach-Object {
                    [pscustomobject]@{Name=$_.TaskName;UserId=$_.Principal.UserId;TriggerTypes=@($_.Triggers | ForEach-Object {$_.CimClass.CimClassName});Xml=(Export-ScheduledTask -TaskName $_.TaskName)}
                })
                SourceHash=(Get-FileHash (Join-Path $root 'Invoke-BootUpdateCycle.ps1')).Hash
                ConsoleUser=(Get-CimInstance Win32_ComputerSystem).UserName
                ExplorerCount=@(Get-Process explorer -ErrorAction SilentlyContinue).Count
                UpdaterCount=@(Get-CimInstance Win32_Process | Where-Object {$_.CommandLine -match '(?i)(-File\s+"?[^"\r\n]*Invoke-BootUpdateCycle\.ps1|Deploy-BootUpdateCycle\.ps1)'}).Count
                StartedAtUtc=[datetime]::UtcNow.ToString('o')
                LogLineCount=$lines.Count
                TaskOwnerSid=if ($tasks.Count -eq 1) {
                    $owner=$tasks[0].Principal.UserId
                    if ($owner -match '^S-1-') { $owner } else { ([Security.Principal.NTAccount]$owner).Translate([Security.Principal.SecurityIdentifier]).Value }
                } else { $null }
            }
        }
        if ($before.UpdaterCount -eq 0) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if ($before.UpdaterCount -ne 0) { throw 'Updater is still active; refusing to interrupt it for sign-in.' }
    if ($before.SourceHash -ne $ExpectedSourceSha256) { throw 'Installed candidate hash does not match the requested build.' }
    if ($before.ConsoleUser -or $before.ExplorerCount -ne 0) { throw 'This gate requires a verified headless starting point.' }
    if ($before.State.Phase -ne 'UserContextPending' -or -not $before.State.ResumeUserSid) { throw 'No saved-user checkpoint is pending.' }
    if ($before.Tasks.Count -ne 1 -or $before.Tasks[0].Name -ne 'BootUpdateCycle' -or
        $before.Tasks[0].TriggerTypes.Count -ne 1 -or $before.Tasks[0].TriggerTypes[0] -ne 'MSFT_TaskLogonTrigger') {
        throw 'Expected only the saved-user logon task, with no fallback or dated retry.'
    }
    if ($before.TaskOwnerSid -ne $before.State.ResumeUserSid) { throw 'Logon task principal does not match the saved user.' }
    $before | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $evidenceDir 'before.json')
    # One temporary guest sign-in. No Start-ScheduledTask call is allowed in this gate.
    $autologonConfigured=$true
    Invoke-Command -VMName $VMName -Credential $credential -ArgumentList $GuestUser,$password,$before.State.ResumeUserSid -ScriptBlock {
        param($User,$Password,$ExpectedSid)
        $sid=([Security.Principal.NTAccount]::new($env:COMPUTERNAME,$User)).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -ne $ExpectedSid) { throw 'Stored lab credential is not the checkpoint owner.' }
        $w='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $w -Name DefaultUserName -Value $User
        Set-ItemProperty $w -Name DefaultDomainName -Value $env:COMPUTERNAME
        Set-ItemProperty $w -Name DefaultPassword -Value $Password
        Set-ItemProperty $w -Name AutoAdminLogon -Value '1'
        New-ItemProperty $w -Name AutoLogonCount -Value 1 -PropertyType DWord -Force | Out-Null
    }
    Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock {
        & shutdown.exe /r /t 0
        if ($LASTEXITCODE -ne 0) { throw 'Guest restart command failed.' }
    }
    $deadline=(Get-Date).AddMinutes($TimeoutMinutes)
    $completed=$false
    do {
        Start-Sleep -Seconds 20
        try {
            $after=Invoke-Command -VMName $VMName -Credential $credential -ArgumentList $before.LogLineCount -ScriptBlock {
                param($PreviousLineCount)
                $root='C:\ProgramData\BootUpdateCycle'
                $lines=@(Get-Content (Join-Path $root 'BootUpdateCycle.log') -ErrorAction Stop)
                [pscustomobject]@{
                    Completed=@($lines | Select-Object -Skip $PreviousLineCount | Where-Object {$_ -match 'BOOT UPDATE CYCLE COMPLETE'}).Count -gt 0
                    TasksRemaining=@(Get-ScheduledTask -TaskName 'BootUpdateCycle*' -ErrorAction SilentlyContinue).Count
                    StateFileRemains=Test-Path (Join-Path $root 'BootUpdateCycle.state.json')
                    ConsoleUser=(Get-CimInstance Win32_ComputerSystem).UserName
                    CbsPending=Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
                }
            }
            $after | ConvertTo-Json -Compress | Add-Content (Join-Path $evidenceDir 'timeline.jsonl')
            $completed=$after.Completed -and $after.TasksRemaining -eq 0 -and -not $after.StateFileRemains
            if ($completed) { break }
        } catch { 'Guest temporarily unreachable' | Add-Content (Join-Path $evidenceDir 'timeline.jsonl') }
    } while ((Get-Date) -lt $deadline)
    $collected=Invoke-Command -VMName $VMName -Credential $credential -ArgumentList $before.StartedAtUtc,$before.LogLineCount -ScriptBlock {
        param($StartUtc,$PreviousLineCount)
        $lines=@(Get-Content 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.log')
        $events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational';StartTime=([datetime]$StartUtc).ToLocalTime()} -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            Log=$lines
            ResumedLog=@($lines | Select-Object -Skip $PreviousLineCount)
            Boots=@(Get-WinEvent -FilterHashtable @{LogName='System';Id=6005;StartTime=([datetime]$StartUtc).ToLocalTime()} -ErrorAction SilentlyContinue | Select-Object TimeCreated,Id)
            TaskEvents=@($events | ForEach-Object {$_.ToXml()})
            InstalledHash=(Get-FileHash 'C:\ProgramData\BootUpdateCycle\Invoke-BootUpdateCycle.ps1').Hash
        }
    }
    $collected.Log | Set-Content (Join-Path $evidenceDir 'BootUpdateCycle.log')
    $collected.Boots | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'os-boots.json')
    $taskEvents=@($collected.TaskEvents | ConvertFrom-BootUpdLabTaskEvent | Where-Object TaskName -eq '\BootUpdateCycle')
    ConvertTo-Json -InputObject @($taskEvents.Xml) | Set-Content (Join-Path $evidenceDir 'task-events.json')
    $userPattern='BOOT UPDATE CYCLE RESUMED.*Context: '+[regex]::Escape($GuestUser)+' \(user context\)'
    $userPassObserved=@($collected.ResumedLog | Where-Object {$_ -match $userPattern}).Count -gt 0
    $taskStartedAsUser=@($taskEvents | Where-Object { $_.Id -eq 100 -and $_.UserContext -match ('(?:^|\\)'+[regex]::Escape($GuestUser)+'$') }).Count -gt 0
    $summary=[ordered]@{
        Result='FAIL'
        Completed=$completed; HeadlessStartVerified=$true; ExistingLogonTaskOnly=$true
        ConsoleUser=$after.ConsoleUser; TasksRemaining=$after.TasksRemaining; StateFileRemains=$after.StateFileRemains
        CbsPending=$after.CbsPending; InstalledHash=$collected.InstalledHash
        CandidateMatches=($collected.InstalledHash -eq $ExpectedSourceSha256)
        UserContextPassObserved=$userPassObserved; TaskStartedAsSavedUser=$taskStartedAsUser
        HealthChecksPassed=(@($collected.ResumedLog | Where-Object {$_ -match 'Health check: policy-aware assessment passed'}).Count -gt 0)
        DeferredCompletion=(@($collected.ResumedLog | Where-Object {$_ -match 'BOOT UPDATE CYCLE COMPLETE[^\r\n]*DEFERRED INVENTORY'}).Count -gt 0)
        CompletionLine=($collected.ResumedLog | Where-Object {$_ -match 'BOOT UPDATE CYCLE COMPLETE'} | Select-Object -Last 1)
        TaskEventsObserved=$taskEvents.Count; SchedulerTotalEvents=@($collected.TaskEvents).Count
        GuestBootsObserved=@($collected.Boots).Count
        HarnessSha256=(Get-FileHash $PSCommandPath).Hash
        EventParserSha256=(Get-FileHash (Join-Path $PSScriptRoot 'LabEvidence.ps1')).Hash
        EvidenceDir=$evidenceDir
    }
    $summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'summary.json')
    if (-not $completed) { throw "Saved-user continuation did not finish within $TimeoutMinutes minutes; evidence collected." }
    if (-not $userPassObserved -or -not $taskStartedAsUser -or -not $summary.CandidateMatches -or
        -not $summary.HealthChecksPassed -or $summary.CbsPending) {
        throw 'Saved-user completion lacks required identity, health, convergence or source evidence.'
    }
    $verificationPassed=$true
} finally {
    $password=$null
    try {
      if ($autologonConfigured) {
        $cleaned=$false
        $cleanupDeadline=(Get-Date).AddMinutes(2)
        if ((Get-VM -Name $VMName).State -eq 'Off') { Start-VM -Name $VMName | Out-Null }
        do {
          try {
            Invoke-Command -VMName $VMName -Credential $credential -ErrorAction Stop -ScriptBlock {
            $w='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            foreach ($name in 'DefaultPassword','DefaultUserName','DefaultDomainName','AutoAdminLogon','AutoLogonCount') {
                Remove-ItemProperty $w -Name $name -ErrorAction SilentlyContinue
            }
            $remaining=Get-ItemProperty $w
            if ($remaining.PSObject.Properties.Name -contains 'DefaultPassword' -or $remaining.AutoAdminLogon -eq '1') { throw 'Temporary autologon settings remain.' }
            }
            $cleaned=$true
            break
          } catch { Start-Sleep -Seconds 5 }
        } while ((Get-Date) -lt $cleanupDeadline)
        [pscustomobject]@{AutologonCleanupVerified=$cleaned} | ConvertTo-Json | Set-Content (Join-Path $evidenceDir 'cleanup.json')
        if ($summary) {
            $summary['AutologonCleanupVerified']=$cleaned
            $summary['UserContinuationVerified']=($verificationPassed -and $cleaned)
            $summary.Result=Get-BootUpdLabContinuationResult -Verified $verificationPassed -CleanupVerified $cleaned -CompletionLine $summary.CompletionLine
            $summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'summary.json')
        }
        if (-not $cleaned) { throw "Temporary guest autologon cleanup failed; recover and scrub this guest before reuse. Evidence: $evidenceDir" }
      }
    } finally { $lease.Dispose() }
}
[pscustomobject]$summary
