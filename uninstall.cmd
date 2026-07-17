@echo off
set "installDir=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -InstallDir "%~dp0." %*
set "exitCode=%ERRORLEVEL%"
exit /b %exitCode%
