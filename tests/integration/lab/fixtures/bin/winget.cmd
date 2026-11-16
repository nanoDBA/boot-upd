@echo off
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0winget-fixture.ps1" %*
exit /b %ERRORLEVEL%
