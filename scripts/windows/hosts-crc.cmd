@echo off
setlocal
rem Adds the POC host names to the Windows hosts file, pointing at the GCP VM.
rem Usage: double-click (asks for the VM IP), or: hosts-crc.cmd 35.x.x.x
rem Needs administrator rights (UAC prompt). Re-run if the VM IP changes.
set "IP=%~1"
if "%IP%"=="" set /p IP=VM external IP: 
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%IP%' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hosts-crc.ps1" -Ip %IP%
echo.
pause
