#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Controller','Hold','Attempt')][string]$Mode = 'Controller',
    [string]$MutexName,
    [string]$ReadyPath,
    [string]$ReleasePath,
    [string]$ResultPath,
    [string]$OrchestratorPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $OrchestratorPath) { $OrchestratorPath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1' }

function Import-MutexFunctions {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $OrchestratorPath, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count) { throw "Orchestrator parse failed: $($errors[0].Message)" }
    foreach ($name in 'Test-SelfUpdateHandoff','Enter-BootUpdateMutex') {
        $node = $ast.Find({
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $candidate.Name -eq $name
        }, $true)
        if (-not $node) { throw "Production function '$name' is missing." }
        $body = $node.Body.Extent.Text
        $body = $body.Substring(1, $body.Length - 2)
        Set-Item -Path "Function:\global:$name" -Value ([scriptblock]::Create($body))
    }
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    $temp = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $Value | ConvertTo-Json -Compress | Set-Content -LiteralPath $temp -Encoding utf8
    [IO.File]::Move($temp, $Path)
}

function Wait-Path {
    param([Parameter(Mandatory)][string]$Path,[int]$Seconds = 20)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Path"
}

function Write-Log { param([string]$Message,[string]$Level) }
function Test-LegacySelfUpdateHandoff { return $false }

if ($Mode -ne 'Controller') {
    Import-MutexFunctions
    $granted = Enter-BootUpdateMutex -MutexName $MutexName
    Write-AtomicJson -Path $ResultPath -Value ([ordered]@{
        Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        IsSystem = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
        Granted = $granted
        OwnsMutex = $null -ne $script:BootUpdateMutex
    })
    if ($Mode -eq 'Hold') {
        Write-AtomicJson -Path $ReadyPath -Value @{ Ready = $true; ProcessId = $PID }
        Wait-Path -Path $ReleasePath
    }
    if ($script:BootUpdateMutex) {
        $script:BootUpdateMutex.ReleaseMutex()
        $script:BootUpdateMutex.Dispose()
    }
    exit 0
}

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Cross-context mutex gate must run elevated.'
}

Import-MutexFunctions
$gateRoot = Join-Path $env:ProgramData ('BootUpdateCycle-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $gateRoot
$MutexName = 'Global\BootUpdateCycle-Gate-' + [guid]::NewGuid().ToString('N')
$taskName = 'BootUpdateCycleMutexGate-' + [guid]::NewGuid().ToString('N')
$pwsh = (Get-Command pwsh).Source
$workerScript = Join-Path $gateRoot 'Invoke-CrossContextMutexGate.ps1'
$workerCore = Join-Path $gateRoot 'Invoke-BootUpdateCycle.ps1'
Copy-Item -LiteralPath $PSCommandPath -Destination $workerScript
Copy-Item -LiteralPath $orchestratorPath -Destination $workerCore

function Invoke-SystemWorker {
    param([ValidateSet('Hold','Attempt')][string]$WorkerMode,[string]$Result,[string]$Ready='',[string]$Release='')
    $argument = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $workerScript),
        '-Mode',$WorkerMode,'-MutexName',('"{0}"' -f $MutexName),'-ResultPath',('"{0}"' -f $Result),
        '-OrchestratorPath',('"{0}"' -f $workerCore)
    )
    if ($Ready) { $argument += @('-ReadyPath',('"{0}"' -f $Ready)) }
    if ($Release) { $argument += @('-ReleasePath',('"{0}"' -f $Release)) }
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ($argument -join ' ')
    $system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $system -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
}

try {
    $systemHold = Join-Path $gateRoot 'system-hold.json'
    $systemReady = Join-Path $gateRoot 'system-ready.json'
    $systemRelease = Join-Path $gateRoot 'system-release.signal'
    Invoke-SystemWorker -WorkerMode Hold -Result $systemHold -Ready $systemReady -Release $systemRelease
    Wait-Path $systemReady

    $userWhileSystem = Enter-BootUpdateMutex -MutexName $MutexName
    if ($userWhileSystem -or $script:BootUpdateMutex) {
        throw 'Elevated-user contender entered while SYSTEM owned the mutex.'
    }
    $systemOwner = Get-Content $systemHold -Raw | ConvertFrom-Json
    if (-not $systemOwner.IsSystem -or -not $systemOwner.Granted -or -not $systemOwner.OwnsMutex) {
        throw 'SYSTEM did not acquire the production mutex as expected.'
    }
    New-Item -ItemType File -Path $systemRelease | Out-Null
    do { Start-Sleep -Milliseconds 100; $info = Get-ScheduledTaskInfo -TaskName $taskName } while ($info.LastTaskResult -eq 267009)

    if (-not (Enter-BootUpdateMutex -MutexName $MutexName)) {
        throw 'Elevated user could not acquire the mutex after SYSTEM released it.'
    }
    $systemAttempt = Join-Path $gateRoot 'system-attempt.json'
    Invoke-SystemWorker -WorkerMode Attempt -Result $systemAttempt
    Wait-Path $systemAttempt
    $systemContender = Get-Content $systemAttempt -Raw | ConvertFrom-Json
    if ($systemContender.Granted -or $systemContender.OwnsMutex) {
        throw 'SYSTEM contender entered while the elevated user owned the mutex.'
    }
    [pscustomobject]@{
        Gate = 'cross-context-mutex'
        Result = 'passed'
        SystemIdentity = $systemOwner.Identity
        UserIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    } | ConvertTo-Json
} finally {
    if ($script:BootUpdateMutex) {
        try { $script:BootUpdateMutex.ReleaseMutex() } catch { }
        $script:BootUpdateMutex.Dispose()
        $script:BootUpdateMutex = $null
    }
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $gateRoot) { Remove-Item -LiteralPath $gateRoot -Recurse -Force }
}
