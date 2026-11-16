@echo off
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0npm-fixture.ps1" %*
exit /b %ERRORLEVEL%
