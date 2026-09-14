@echo off
setlocal
set "CONDUIT_SCRIPT=%~dp0conduit-main.ps1"
if not exist "%CONDUIT_SCRIPT%" set "CONDUIT_SCRIPT=%~dp0conduit.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CONDUIT_SCRIPT%" %*
exit /b %ERRORLEVEL%
