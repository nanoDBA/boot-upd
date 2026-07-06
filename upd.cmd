@echo off
:: Quick launcher for Deploy-BootUpdateCycle.ps1
:: Usage: upd [delay_seconds]
::   upd       - immediate reboot (0 sec delay)
::   upd 30    - 30 second delay before reboot
::   upd /?    - show this help
:: Self-adds to system PATH on first run (idempotent)
:: Can be run from: elevated cmd, Run dialog (Ctrl+Shift+Enter), or double-click
setlocal EnableDelayedExpansion

:: Help
if /i "%~1"=="/?" goto :help
if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help

:: Validate optional delay argument (digits only) BEFORE elevating
set "DELAY=0"
if "%~1"=="" goto :argok
echo %~1| findstr /r /x "[0-9][0-9]*" >nul
if errorlevel 1 goto :badarg
set "DELAY=%~1"
:argok

:: Verify PowerShell 7 is available before doing anything else
where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: PowerShell 7 ^(pwsh^) not found on PATH.
    echo Install it first:  winget install Microsoft.PowerShell
    pause
    exit /b 1
)

:: Check for admin rights - if not elevated, relaunch elevated via PowerShell
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting elevation...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    ) else (
        powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%DELAY%'"
    )
    exit /b
)

:: Now we're elevated - proceed

:: Get the directory where this batch file lives (remove trailing backslash)
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: Sanity check: the deploy script must exist next to this launcher
if not exist "%SCRIPT_DIR%\Deploy-BootUpdateCycle.ps1" (
    echo ERROR: Deploy-BootUpdateCycle.ps1 not found in "%SCRIPT_DIR%"
    pause
    exit /b 1
)

:: Check Machine PATH via registry (not process PATH) to avoid stale-inherit false negatives
powershell -NoProfile -Command ^
    "$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine');" ^
    "$dir = '%SCRIPT_DIR%';" ^
    "$entries = $machinePath -split ';' | Where-Object { $_ };" ^
    "if ($entries -notcontains $dir) {" ^
    "    $newPath = ($entries + $dir) -join ';';" ^
    "    if ($newPath.Length -gt 2047) {" ^
    "        Write-Host 'WARNING: Machine PATH would exceed 2047 chars - aborting PATH update';" ^
    "        exit 1;" ^
    "    }" ^
    "    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine');" ^
    "    Write-Host 'Added %SCRIPT_DIR% to Machine PATH. Future sessions will find upd automatically.';" ^
    "} else {" ^
    "    Write-Host 'Already in Machine PATH.';" ^
    "}"

if %errorlevel% neq 0 (
    echo WARNING: PATH update failed or was aborted.
)

:: Brief startup message
echo.
echo Starting Boot Update Cycle in 5 seconds... (reboot delay: %DELAY%s)
echo (NonInteractive mode - no keypress required)
echo.

:: Launch PowerShell 7 with the deploy script (NonInteractive mode)
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 5; & '%SCRIPT_DIR%\Deploy-BootUpdateCycle.ps1' -RebootDelaySec %DELAY% -NonInteractive; if ($LASTEXITCODE -ne 0) { Write-Host 'Press Enter to exit...' -ForegroundColor Red; Read-Host }"
exit /b %errorlevel%

:help
echo upd - Boot Update Cycle launcher
echo.
echo Usage: upd [delay_seconds]
echo   upd        Run update cycle, immediate reboot if needed
echo   upd 30     Run update cycle, 30 second warning before reboot
echo   upd /?     Show this help
echo.
echo Self-elevates via UAC if not already admin.
echo Adds its own directory to the Machine PATH on first run.
echo Monitor progress:  Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.log" -Tail 50 -Wait
exit /b 0

:badarg
echo ERROR: delay must be a whole number of seconds, got "%~1"
echo Run "upd /?" for usage.
exit /b 1
