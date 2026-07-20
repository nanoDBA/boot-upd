@echo off
setlocal
:: BootUpdateCycleVersion=2.5.29
:: Friendly entry point. Argument parsing, safe demo modes, and elevation live in
:: tools\Invoke-UpdLauncher.ps1 so quoting and validation remain testable.

where pwsh >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell 7 ^(pwsh^) was not found on PATH.
    echo Install it with:  winget install Microsoft.PowerShell
    exit /b 1
)

set "UPD_ROOT=%~dp0"
set "UPD_LAUNCHER=%UPD_ROOT%tools\Invoke-UpdLauncher.ps1"
if /i "%~1"=="repair" goto bootstrap
if not exist "%UPD_LAUNCHER%" goto bootstrap
goto launch

:bootstrap
echo Recovering the checksummed UPD launcher from the latest GitHub release...
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $r=Invoke-RestMethod 'https://api.github.com/repos/nanoDBA/boot-upd/releases/latest' -Headers @{'User-Agent'='BootUpdateCycle-Bootstrap'} -TimeoutSec 15; $a=$r.assets|Where-Object name -eq 'Invoke-UpdLauncher.ps1'|Select-Object -First 1; $s=$r.assets|Where-Object name -eq 'Invoke-UpdLauncher.ps1.sha256'|Select-Object -First 1; if(-not $a -or -not $s){throw 'Latest release has no launcher/checksum pair'}; $e=((Invoke-RestMethod $s.browser_download_url -TimeoutSec 15)-split '\s+')[0].ToUpperInvariant(); if($e -notmatch '^[0-9A-F]{64}$'){throw 'Invalid launcher checksum'}; $t=[IO.Path]::GetTempFileName(); try{Invoke-WebRequest $a.browser_download_url -OutFile $t -TimeoutSec 60; if((Get-FileHash $t -Algorithm SHA256).Hash -ne $e){throw 'Launcher checksum mismatch'}; $x=$null;$z=$null;[void][Management.Automation.Language.Parser]::ParseFile($t,[ref]$x,[ref]$z);if($z.Count){throw $z[0].Message};New-Item -ItemType Directory -Path (Split-Path $env:UPD_LAUNCHER) -Force|Out-Null;Copy-Item $t $env:UPD_LAUNCHER -Force}finally{Remove-Item $t -Force -ErrorAction SilentlyContinue}"
if errorlevel 1 (
    echo ERROR: Could not recover the UPD launcher.
    exit /b 1
)
if /i "%~1"=="repair" goto repair

:launch

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_LAUNCHER%" %*
set "UPD_EXIT=%errorlevel%"
goto adopt

:repair
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_LAUNCHER%" update
set "UPD_EXIT=%errorlevel%"

:: The PowerShell bootstrap cannot safely replace the batch file that cmd.exe
:: is currently reading. Ask the launcher to checksum/version-gate and atomically
:: adopt a staged copy after the first PowerShell process exits.
:adopt
if exist "%UPD_ROOT%upd.cmd.next" (
    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPD_LAUNCHER%" adopt-staged-batch
    if errorlevel 1 (
        echo WARNING: upd.cmd.next was rejected or could not be adopted.
    ) else (
        echo Updated upd.cmd from the checksummed release bundle.
    )
)
exit /b %UPD_EXIT%
