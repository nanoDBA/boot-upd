@echo off
:: Quick launcher for Deploy-BootUpdateCycle.ps1
:: Usage: upd [delay_seconds]
::   upd       - immediate reboot (0 sec delay)
::   upd 30    - 30 second delay before reboot
:: Self-adds to system PATH on first run (idempotent)
:: Can be run from: elevated cmd, Run dialog (Ctrl+Shift+Enter), or double-click
setlocal EnableDelayedExpansion

:: Check for admin rights - if not elevated, relaunch elevated via PowerShell
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting elevation...
    if "%~1"=="" (
        powershell -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    ) else (
        powershell -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
    )
    exit /b
)

:: Now we're elevated - proceed

:: Get the directory where this batch file lives (remove trailing backslash)
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

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

:: Default to 0 (immediate reboot), or use first arg
set "DELAY=0"
if not "%~1"=="" set "DELAY=%~1"

:: Brief startup message
echo.
echo Starting Boot Update Cycle in 5 seconds...
echo (NonInteractive mode - no keypress required)
echo.

:: Launch PowerShell 7 with the deploy script (NonInteractive mode)
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 5; & '%SCRIPT_DIR%\Deploy-BootUpdateCycle.ps1' -RebootDelaySec %DELAY% -NonInteractive; if ($LASTEXITCODE -ne 0) { Write-Host 'Press Enter to exit...' -ForegroundColor Red; Read-Host }"