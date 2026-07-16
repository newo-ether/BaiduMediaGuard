@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
set "exitCode=%ERRORLEVEL%"
echo.
pause
exit /b %exitCode%
