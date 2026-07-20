@echo off
setlocal
:: BootUpdateCycleVersion=2.5.43
:: Friendly entry point. Argument parsing, safe demo modes, and elevation live in
:: tools\Invoke-UpdLauncher.ps1 so quoting and validation remain testable.

set "UPD_ROOT=%~dp0"
set "UPD_LAUNCHER=%UPD_ROOT%tools\Invoke-UpdLauncher.ps1"
set "UPD_BOOTSTRAP=%UPD_ROOT%tools\Invoke-UpdBootstrap.ps1"
set "UPD_PS7_BOOTSTRAP=%UPD_ROOT%tools\Install-PowerShell7.ps1"
call :find_pwsh
if defined UPD_PWSH goto runtime_ready

:: Read-only commands remain read-only even on a Windows PowerShell 5.1-only box.
if /i "%~1"=="/?" goto ps5_help
if /i "%~1"=="?" goto ps5_help
if /i "%~1"=="/help" goto ps5_help
if /i "%~1"=="help" goto ps5_help
if /i "%~1"=="-h" goto ps5_help
if /i "%~1"=="--help" goto ps5_help
if /i "%~1"=="usage" goto ps5_help
if /i "%~1"=="--usage" goto ps5_help
if /i "%~1"=="version" goto ps5_version
if /i "%~1"=="v" goto ps5_version
if /i "%~1"=="plan" goto ps7_required
if /i "%~1"=="p" goto ps7_required
if /i "%~1"=="status" goto ps7_required
if /i "%~1"=="st" goto ps7_required
if /i "%~1"=="splash" goto ps7_required
if /i "%~1"=="sp" goto ps7_required
if /i "%~1"=="demo" goto ps7_required
if /i "%~1"=="d" goto ps7_required
if /i "%~1"=="fun" goto ps7_required
if /i "%~1"=="f" goto ps7_required
if /i "%~1"=="bootstrap" set "UPD_BOOTSTRAP_ONLY=1"
if /i "%~1"=="b" set "UPD_BOOTSTRAP_ONLY=1"

if not exist "%UPD_PS7_BOOTSTRAP%" (
    echo ERROR: PowerShell 7 bootstrap not found: "%UPD_PS7_BOOTSTRAP%"
    echo Install PowerShell 7 with: winget install --id Microsoft.PowerShell --exact --source winget
    exit /b 1
)
echo Windows PowerShell 5.1 detected; bootstrapping PowerShell 7 for parallel execution...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_PS7_BOOTSTRAP%"
if errorlevel 1 exit /b %errorlevel%
call :find_pwsh
if not defined UPD_PWSH (
    echo ERROR: PowerShell 7 was installed but pwsh.exe could not be located.
    exit /b 1
)
if defined UPD_BOOTSTRAP_ONLY if not exist "%UPD_LAUNCHER%" goto bootstrap
if defined UPD_BOOTSTRAP_ONLY goto bootstrap_help

:runtime_ready
if /i "%~1"=="repair" goto bootstrap
if not exist "%UPD_LAUNCHER%" goto bootstrap
if /i "%~1"=="/?" goto launch_typed
if /i "%~1"=="?" goto launch_typed
if /i "%~1"=="/help" goto launch_typed
if /i "%~1"=="help" goto launch_typed
if /i "%~1"=="-h" goto launch_typed
if /i "%~1"=="--help" goto launch_typed
if /i "%~1"=="usage" goto launch_typed
if /i "%~1"=="--usage" goto launch_typed
call :classify_read_only "%~1"
if defined UPD_READ_ONLY goto launch_typed
call :classify_no_update %*
if defined UPD_NO_UPDATE goto launch_typed
goto bootstrap_stage0

:bootstrap
echo Recovering the checksummed UPD launcher from the latest GitHub release...
"%UPD_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $r=Invoke-RestMethod 'https://api.github.com/repos/nanoDBA/boot-upd/releases/latest' -Headers @{'User-Agent'='BootUpdateCycle-Bootstrap'} -TimeoutSec 15; $a=$r.assets|Where-Object name -eq 'Invoke-UpdLauncher.ps1'|Select-Object -First 1; $s=$r.assets|Where-Object name -eq 'Invoke-UpdLauncher.ps1.sha256'|Select-Object -First 1; if(-not $a -or -not $s){throw 'Latest release has no launcher/checksum pair'}; $e=((Invoke-RestMethod $s.browser_download_url -TimeoutSec 15)-split '\s+')[0].ToUpperInvariant(); if($e -notmatch '^[0-9A-F]{64}$'){throw 'Invalid launcher checksum'}; $t=[IO.Path]::GetTempFileName(); try{Invoke-WebRequest $a.browser_download_url -OutFile $t -TimeoutSec 60; if((Get-FileHash $t -Algorithm SHA256).Hash -ne $e){throw 'Launcher checksum mismatch'}; $x=$null;$z=$null;[void][Management.Automation.Language.Parser]::ParseFile($t,[ref]$x,[ref]$z);if($z.Count){throw $z[0].Message};New-Item -ItemType Directory -Path (Split-Path $env:UPD_LAUNCHER) -Force|Out-Null;Copy-Item $t $env:UPD_LAUNCHER -Force}finally{Remove-Item $t -Force -ErrorAction SilentlyContinue}"
if errorlevel 1 (
    echo ERROR: Could not recover the UPD launcher.
    exit /b 1
)
if /i "%~1"=="repair" goto repair

:bootstrap_stage0
echo Verifying the current raw-argument bootstrap from the latest GitHub release...
set "UPD_BOOTSTRAP_ACTIVE=%TEMP%\BootUpdateCycle\Invoke-UpdBootstrap-verified-%RANDOM%-%RANDOM%.ps1"
"%UPD_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $r=Invoke-RestMethod 'https://api.github.com/repos/nanoDBA/boot-upd/releases/latest' -Headers @{'User-Agent'='BootUpdateCycle-Bootstrap'} -TimeoutSec 15; $a=$r.assets|Where-Object name -eq 'Invoke-UpdBootstrap.ps1'|Select-Object -First 1; $s=$r.assets|Where-Object name -eq 'Invoke-UpdBootstrap.ps1.sha256'|Select-Object -First 1; if(-not $a -or -not $s){throw 'Latest release has no bootstrap/checksum pair'}; $e=((Invoke-RestMethod $s.browser_download_url -TimeoutSec 15)-split '\s+')[0].ToUpperInvariant(); if($e -notmatch '^[0-9A-F]{64}$'){throw 'Invalid bootstrap checksum'}; $t=$env:UPD_BOOTSTRAP_ACTIVE; try{New-Item -ItemType Directory -Path (Split-Path $t) -Force|Out-Null; Invoke-WebRequest $a.browser_download_url -OutFile $t -TimeoutSec 60; if((Get-FileHash $t -Algorithm SHA256).Hash -ne $e){throw 'Bootstrap checksum mismatch'}; $x=$null;$z=$null;[void][Management.Automation.Language.Parser]::ParseFile($t,[ref]$x,[ref]$z);if($z.Count){throw $z[0].Message}}catch{Remove-Item $t -Force -ErrorAction SilentlyContinue;throw}"
if errorlevel 1 (
    echo ERROR: Could not recover the verified UPD argument bootstrap.
    echo Run "upd repair" or use the versioned release recovery command.
    exit /b 1
)

:launch
"%UPD_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_BOOTSTRAP_ACTIVE%" %*
set "UPD_EXIT=%errorlevel%"
goto adopt

:launch_typed
"%UPD_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_LAUNCHER%" %*
set "UPD_EXIT=%errorlevel%"
goto adopt

:repair
"%UPD_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_LAUNCHER%" update
set "UPD_EXIT=%errorlevel%"

:: The PowerShell bootstrap cannot safely replace the batch file that cmd.exe
:: is currently reading. Adoption swaps this file on disk, so the adopt call and
:: everything after it must be ONE physical line — cmd buffers a full line before
:: executing, so nothing is re-read from the replaced file at a stale byte offset.
:adopt
if defined UPD_BOOTSTRAP_ACTIVE del /f /q "%UPD_BOOTSTRAP_ACTIVE%" >nul 2>&1
if not exist "%UPD_ROOT%upd.cmd.next" exit /b %UPD_EXIT%
"%UPD_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_LAUNCHER%" adopt-staged-batch && (echo Updated upd.cmd from the checksummed release bundle.) || (echo WARNING: upd.cmd.next was rejected or could not be adopted.) & exit /b %UPD_EXIT%

:bootstrap_help
"%UPD_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_LAUNCHER%" help
exit /b %errorlevel%

:ps5_help
echo.
echo   UPD // Boot Update Cycle
echo   Windows PowerShell 5.1 is present; PowerShell 7 is not installed.
echo.
echo   upd bootstrap   Install PowerShell 7 side-by-side, then show full help
echo   upd             Bootstrap PowerShell 7 and start the parallel update cycle
echo   upd v           Show the bundled updater version without installing anything
echo.
echo   Help is read-only. Operational commands bootstrap PowerShell 7 automatically.
exit /b 0

:ps5_version
echo Boot Update Cycle v2.5.43 ^(PowerShell 7 runtime not installed^)
exit /b 0

:ps7_required
echo ERROR: This read-only command needs PowerShell 7; no changes were made.
echo Run: upd bootstrap
exit /b 2

:find_pwsh
set "UPD_PWSH="
where pwsh.exe >nul 2>&1
if not errorlevel 1 set "UPD_PWSH=pwsh.exe"
if not defined UPD_PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "UPD_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined UPD_PWSH if exist "%LocalAppData%\Microsoft\WindowsApps\pwsh.exe" set "UPD_PWSH=%LocalAppData%\Microsoft\WindowsApps\pwsh.exe"
exit /b 0

:classify_read_only
set "UPD_READ_ONLY="
for %%C in ("/?" "?" "/help" "help" "-h" "--help" "usage" "--usage" "-v" "-d" "-f" "-st" "version" "v" "plan" "p" "status" "st" "splash" "sp" "demo" "d" "--demo" "/demo" "fun" "f" "--fun" "/fun" "bootstrap" "b") do if /i "%~1"=="%%~C" set "UPD_READ_ONLY=1"
exit /b 0

:classify_no_update
set "UPD_NO_UPDATE="
:classify_no_update_loop
if "%~1"=="" exit /b 0
if /i "%~1"=="-nu" set "UPD_NO_UPDATE=1"
if /i "%~1"=="--no-update" set "UPD_NO_UPDATE=1"
if /i "%~1"=="--disable-self-update" set "UPD_NO_UPDATE=1"
shift
goto classify_no_update_loop
