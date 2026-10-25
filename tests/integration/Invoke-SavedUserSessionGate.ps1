#requires -Version 7.0
<# Tests the production console-session predicate as SYSTEM. Does not run updates or reboot. #>
[CmdletBinding()]
param(
    [ValidateSet('Controller','Probe')][string]$Mode='Controller',
    [string]$FixturePath,
    [string]$OrchestratorPath=(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Invoke-BootUpdateCycle.ps1'),
    [string]$ResultPath
)
$ErrorActionPreference='Stop'
if ($Mode -eq 'Probe') {
    $fixture=Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($fixture.Source,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Production source did not parse.' }
    foreach ($name in 'Resolve-BootUpdateResumeAccount','Test-BootUpdateInteractiveUserPresent') {
        $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if (-not $node) { throw "Missing production function $name" }
        . ([scriptblock]::Create($node.Extent.Text))
    }
    function Write-Log { param($Message,$Level) }
    $result=[ordered]@{
        IsSystem=([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
        SavedUserPresent=(Test-BootUpdateInteractiveUserPresent -ResumeUserSid $fixture.SavedSid)
        DifferentUserAbsent=(-not (Test-BootUpdateInteractiveUserPresent -ResumeUserSid $fixture.OtherSid))
        MissingUserAbsent=(-not (Test-BootUpdateInteractiveUserPresent -ResumeUser $fixture.MissingAccount))
        SourceHash=(Get-FileHash -LiteralPath $fixture.Source).Hash
    }
    $pendingOutput=$fixture.Output+".$PID.tmp"
    $result | ConvertTo-Json | Set-Content -LiteralPath $pendingOutput
    [IO.File]::Move($pendingOutput,$fixture.Output)
    exit 0
}
$principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from elevated PowerShell 7.' }
$consoleUser=(Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
if (-not $consoleUser) { throw 'NOT RUN: this probe needs an already signed-in console user.' }
$savedSid=([Security.Principal.NTAccount]$consoleUser).Translate([Security.Principal.SecurityIdentifier]).Value
$other=Get-LocalUser | Where-Object {$_.Sid.Value -ne $savedSid} | Select-Object -First 1
if (-not $other) { throw 'NOT RUN: no second resolvable local account is available.' }
$root=Join-Path ([IO.Path]::GetTempPath()) ('bootupd-user-session-'+[guid]::NewGuid().ToString('N'))
$taskName='BootUpd-TestSession-'+[guid]::NewGuid().ToString('N')
$passed=$false
$report=$null
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $source=Join-Path $root 'orchestrator.ps1'
    $probe=Join-Path $root 'probe.ps1'
    $fixtureFile=Join-Path $root 'fixture.json'
    $output=Join-Path $root 'result.json'
    Copy-Item -LiteralPath $OrchestratorPath -Destination $source
    Copy-Item -LiteralPath $PSCommandPath -Destination $probe
    [ordered]@{Source=$source;SavedSid=$savedSid;OtherSid=$other.Sid.Value;MissingAccount=('bootupd-missing-'+[guid]::NewGuid().ToString('N'));Output=$output} |
        ConvertTo-Json | Set-Content -LiteralPath $fixtureFile
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Probe -FixturePath "{1}"' -f $probe,$fixtureFile
    $action=New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path -Argument $arguments
    $owner=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $owner -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline=(Get-Date).AddSeconds(45)
    while (-not (Test-Path -LiteralPath $output) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $output)) { throw 'SYSTEM session probe did not publish a result.' }
    $result=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    $passed=$result.IsSystem -and $result.SavedUserPresent -and $result.DifferentUserAbsent -and
        $result.MissingUserAbsent -and $result.SourceHash -eq (Get-FileHash -LiteralPath $OrchestratorPath).Hash
    $report=[ordered]@{Gate='saved-user-session';Result='failed';Checks=$result}
    if ($ResultPath) { $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath }
    if (-not $passed) { throw 'SYSTEM did not distinguish the saved console account from absent accounts.' }
} finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw "Temporary test task $taskName was not removed." }
    if ($passed) {
        $resolved=[IO.Path]::GetFullPath($root)
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected temporary cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { Write-Warning "Session probe evidence retained at $root" }
    if ($report) {
        $report.Result=if ($passed) {'passed'} else {'failed'}
        $report['TemporaryTaskRemoved']=$true
        if ($ResultPath) { $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath }
    }
}
[pscustomobject]$report
