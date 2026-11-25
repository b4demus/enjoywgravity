@echo off
setlocal
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Antigravity.ps1" %*
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
