#requires -Version 7.0
<# Exercise production SSMS helpers in an explicitly selected disposable guest.
   Use Invoke-LabRow.ps1 for checkpoint restores. Never services the host. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$SourceRoot=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$EvidenceRoot='C:\HyperV\evidence',
    [string]$GuestUser='updtest',
    [ValidateRange(1,120)][int]$TimeoutMinutes=45,
    [switch]$ExpectNoChange
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lab\LabCredential.ps1')
$credential=[pscredential]::new($GuestUser,(ConvertTo-BootUpdLabSecureString (Get-BootUpdLabPassword)))
if ((Get-VM -Name $VMName).State -ne 'Running') { throw 'Prepare and start the disposable guest through the lab harness first.' }
$evidenceDir=Join-Path $EvidenceRoot ('SSMS-provider-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$null=New-Item -ItemType Directory -Path $evidenceDir -Force
$production=Join-Path $SourceRoot 'Invoke-BootUpdateCycle.ps1'
$hash=(Get-FileHash -LiteralPath $production -Algorithm SHA256).Hash
$runId=[guid]::NewGuid().ToString('N')
$guestRoot='C:\Lab\ssms-gate'
$runnerPath=Join-Path $evidenceDir 'Run-SsmsProvider.ps1'
$runner=@'
#requires -Version 7.0
$ErrorActionPreference='Stop'
$root='C:\Lab\ssms-gate'
$payload=[ordered]@{RunId='__RUNID__';StartedUtc=[datetime]::UtcNow.ToString('o');Error=$null}
try {
    $payload.IdentitySid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($payload.IdentitySid -ne 'S-1-5-18'){throw 'Guest provider must run as SYSTEM.'}
    $source=Join-Path $root 'Invoke-BootUpdateCycle.ps1'
    if((Get-FileHash $source).Hash -ne '__HASH__'){throw 'Candidate hash mismatch.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    if($errors){throw 'Candidate parse failed.'}
    $names=@('Write-SsmsUpdateLog','ConvertTo-SsmsVersion','Test-SsmsSafeProviderArgument',
        'Get-SsmsVswherePath','Test-SsmsInstallationHint','Get-SsmsInstances','Get-SsmsJsonDocument',
        'Get-SsmsChannelTarget','Test-SsmsProcessOpen','Find-SsmsInstance','New-SsmsUpdateResult',
        'Register-SsmsRebootEvidence','Get-SsmsPendingUpdate','Save-SsmsPendingUpdate',
        'Confirm-SsmsPendingUpdate','Complete-SsmsUpdateAccounting','Reset-SsmsPendingVerification',
        'Update-SsmsInstances','Invoke-PackageManagerWithTimeout','Wait-ProcessWithIdleTimeout',
        'Get-ProcessTreeActivity','Test-BootUpdateInstallerMutexHeld','Wait-BootUpdateInstallerMutex',
        'New-BootUpdateStateV2')
    foreach($name in $names){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if(-not $node){throw "Missing production function $name"}
        . ([scriptblock]::Create($node.Extent.Text))
    }
    # Only rendering and the fixture's private checkpoint path are replaced.
    function Write-Log {param($Message,$Level='Info',$Visibility)
        Add-Content (Join-Path $root 'provider.log') "$([datetime]::UtcNow.ToString('o')) [$Level] $Message"
    }
    function Wait-BootUpdateUiInterval {param($Seconds,$Activity,$Status,$PercentComplete)
        Start-Sleep -Milliseconds ([int]($Seconds*1000))
    }
    function Set-BootUpdateState {param($State)
        $path=Join-Path $root 'checkpoint.json';$temp="$path.$PID.tmp"
        [IO.File]::WriteAllText($temp,($State|ConvertTo-Json -Depth 20))
        [IO.File]::Move($temp,$path,$true)
    }
    function Get-InventorySnapshot {
        $inventory=Get-SsmsInstances
        foreach($instance in $inventory.Instances){$instance.InstallationVersion=[string]$instance.InstallationVersion}
        return $inventory
    }
    $script:BootUpdateStateSchemaVersion=6
    $script:PackageTimeoutMinutes=__TIMEOUT__
    $script:ExplicitRebootRequests=[Collections.Generic.List[object]]::new()
    $script:CurrentState=New-BootUpdateStateV2
    $payload.Before=Get-InventorySnapshot
    $payload.CandidateHash='__HASH__'
    $payload.Result=Update-SsmsInstances -TimeoutMinutes __TIMEOUT__
    $script:CurrentState.Summary.Ssms += [int]$payload.Result.Count
    Complete-SsmsUpdateAccounting -State $script:CurrentState
    Set-BootUpdateState -State $script:CurrentState
    $payload.After=Get-InventorySnapshot
    $payload.RebootRequests=@($script:ExplicitRebootRequests)
    if($payload.Result.Success){
        $payload.SecondPass=Update-SsmsInstances -TimeoutMinutes __TIMEOUT__
        $payload.AfterSecond=Get-InventorySnapshot
    }
    $payload.FinalState=$script:CurrentState
    $payload.FinalRebootRequests=@($script:ExplicitRebootRequests)
}catch{$payload.Error=$_.Exception.ToString()}
$payload.FinishedUtc=[datetime]::UtcNow.ToString('o')
$payload|ConvertTo-Json -Depth 20|Set-Content (Join-Path $root 'result.json') -Encoding utf8
'@
$runner=$runner.Replace('__HASH__',$hash).Replace('__TIMEOUT__',[string]$TimeoutMinutes).Replace('__RUNID__',$runId)
[IO.File]::WriteAllText($runnerPath,$runner)
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($runnerPath,[ref]$tokens,[ref]$errors)
if($errors){throw 'Generated runner failed parsing.'}
Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'|Out-Null
Copy-VMFile -Name $VMName -SourcePath $production -DestinationPath "$guestRoot\Invoke-BootUpdateCycle.ps1" -CreateFullPath -FileSource Host -Force
Copy-VMFile -Name $VMName -SourcePath $runnerPath -DestinationPath "$guestRoot\Run-SsmsProvider.ps1" -CreateFullPath -FileSource Host -Force
Invoke-Command -VMName $VMName -Credential $credential -ArgumentList $TimeoutMinutes -ScriptBlock {
    param($Minutes)
    if((Get-ScheduledTask -TaskName 'Lab-RunSsmsProvider' -ErrorAction SilentlyContinue).State -eq 'Running'){throw 'Previous provider gate is still running.'}
    foreach($path in @('C:\Lab\ssms-gate\result.json','C:\Lab\ssms-gate\provider.log')){
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
    }
    $action=New-ScheduledTaskAction -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\ssms-gate\Run-SsmsProvider.ps1' -WorkingDirectory 'C:\Lab\ssms-gate'
    $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes($Minutes+35))
    Register-ScheduledTask -TaskName 'Lab-RunSsmsProvider' -Action $action -Principal $principal -Settings $settings -Force|Out-Null
    Start-ScheduledTask -TaskName 'Lab-RunSsmsProvider'
}|Out-Null
$deadline=[datetime]::UtcNow.AddMinutes($TimeoutMinutes+35)
$result=$null
while([datetime]::UtcNow -lt $deadline){
    $job=Invoke-Command -VMName $VMName -Credential $credential -AsJob -ScriptBlock {
        $task=Get-ScheduledTask -TaskName 'Lab-RunSsmsProvider'
        [pscustomobject]@{State=[string]$task.State;ExitCode=(Get-ScheduledTaskInfo $task.TaskName).LastTaskResult
            Result=if(Test-Path 'C:\Lab\ssms-gate\result.json'){[IO.File]::ReadAllText('C:\Lab\ssms-gate\result.json')}else{$null}}
    }
    try{
        if(Wait-Job $job -Timeout 30){
            $probe=Receive-Job $job -ErrorAction Stop
            Add-Content (Join-Path $evidenceDir 'host-timeline.txt') "$([datetime]::UtcNow.ToString('o')) $($probe.State) exit=$($probe.ExitCode)"
            if($probe.Result){$result=$probe.Result|ConvertFrom-Json;break}
            if($probe.State -ne 'Running'){throw "Guest runner stopped without evidence: exit $($probe.ExitCode)"}
        }
    }finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force}
    Start-Sleep -Seconds 15
}
if(-not $result){throw "Provider gate timed out; evidence: $evidenceDir"}
if($result.RunId -ne $runId -or $result.CandidateHash -ne $hash){throw 'Result is not from this candidate and invocation.'}
$result|ConvertTo-Json -Depth 20|Set-Content (Join-Path $evidenceDir 'result.json') -Encoding utf8
$logs=Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock {
    $files=@(Get-Item 'C:\Lab\ssms-gate\provider.log','C:\Lab\ssms-gate\checkpoint.json' -ErrorAction SilentlyContinue)
    $files+=@(Get-ChildItem 'C:\Windows\SystemTemp','C:\Windows\Temp' -Filter '*.log' -File -ErrorAction SilentlyContinue|Where-Object Name -match '^(dd_|ssms_)'|Sort-Object LastWriteTime -Descending|Select-Object -First 20)
    foreach($file in $files){[pscustomobject]@{Name=$file.Name;Content=[IO.File]::ReadAllText($file.FullName)}}
}
foreach($log in $logs){[IO.File]::WriteAllText((Join-Path $evidenceDir $log.Name),$log.Content)}
if($result.Error){throw "Guest provider error: $($result.Error). Evidence: $evidenceDir"}
if(-not $result.Result.Success){throw "Provider incomplete (reboot or retry required); evidence: $evidenceDir"}
if($result.IdentitySid -ne 'S-1-5-18'){throw 'Effective SYSTEM identity was not established.'}
$before=@($result.Before.Instances);$after=@($result.After.Instances)
if($result.Before.Broken -or $result.After.Broken -or -not $before.Count){throw 'Gate requires valid, nonempty SSMS inventory.'}
if(-not @($before|Where-Object {([version]$_.InstallationVersion).Major -eq 22}).Count){throw 'Gate requires an SSMS22 instance.'}
if($before.Count -ne $after.Count){throw 'Installed instance set changed.'}
$changed=0
foreach($instance in $before){
    $matching=@($after|Where-Object InstanceId -eq $instance.InstanceId)
    if($matching.Count -ne 1){throw 'Instance identity changed.'}
    $current=$matching[0]
    if($current.InstallationPath -ine $instance.InstallationPath -or $current.ChannelId -ine $instance.ChannelId -or $current.ChannelUri -cne $instance.ChannelUri){throw 'Instance path or source changed.'}
    if([version]$current.InstallationVersion -gt [version]$instance.InstallationVersion){$changed++}
    elseif([version]$current.InstallationVersion -lt [version]$instance.InstallationVersion){throw 'Instance was downgraded.'}
}
if($changed -ne [int]$result.Result.Count -or (-not $ExpectNoChange -and $changed -eq 0) -or ($ExpectNoChange -and $changed -ne 0)){throw 'Observed version changes did not match expected accounting.'}
if($result.FinalState.Summary.Ssms -ne $changed -or @($result.FinalState.SsmsPendingUpdates).Count -or
    @($result.FinalRebootRequests).Count -or @($result.FinalState.ExplicitRebootRequests).Count){throw 'Final accounting or reboot evidence is unsettled.'}
if(-not $result.SecondPass.Success -or $result.SecondPass.Count -ne 0 -or $result.SecondPass.Triggered){throw 'Second provider pass was not a verified no-op.'}
$second=@($result.AfterSecond.Instances)
if($result.AfterSecond.Broken -or $second.Count -ne $after.Count){throw 'Second-pass inventory changed or failed.'}
foreach($instance in $after){
    $matching=@($second|Where-Object InstanceId -eq $instance.InstanceId)
    if($matching.Count -ne 1 -or $matching[0].InstallationPath -ine $instance.InstallationPath -or
        $matching[0].ChannelId -ine $instance.ChannelId -or $matching[0].ChannelUri -cne $instance.ChannelUri -or
        $matching[0].InstallationVersion -ne $instance.InstallationVersion){throw 'Second-pass inventory was not unchanged.'}
}
$summary=[pscustomobject]@{Gate='SSMS native provider';Result='PASS';CandidateHash=$hash;InstancesChanged=$changed;SecondPass='verified no-op';EvidenceDir=$evidenceDir}
$summary|ConvertTo-Json|Set-Content (Join-Path $evidenceDir 'summary.json')
$summary
