@echo off
setlocal
chcp 65001 >nul
title HP Cloud Recovery Tool - UASP Patch Launcher

rem The PowerShell script handles self-elevation and passes -Language through.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-HPCloudRecovery-Patched.ps1" %*
set RC=%errorlevel%

echo.
pause
exit /b %RC%
