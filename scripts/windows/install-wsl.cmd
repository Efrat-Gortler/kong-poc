@echo off
setlocal
rem ---------------------------------------------------------------------------
rem Kong POC - one-time Windows setup. Needs administrator rights, then a reboot.
rem   1. installs WSL2 with Ubuntu 24.04 (not launched yet)
rem   2. limits WSL to 5 GB RAM / 6 CPUs (writes %USERPROFILE%\.wslconfig,
rem      an existing file is kept as .wslconfig.bak)
rem Safe to run twice. Nothing else on the computer is changed.
rem ---------------------------------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo.
echo === 1/2  Writing %USERPROFILE%\.wslconfig
if exist "%USERPROFILE%\.wslconfig" copy /y "%USERPROFILE%\.wslconfig" "%USERPROFILE%\.wslconfig.bak" >nul
(
  echo [wsl2]
  echo memory=5GB
  echo processors=6
  echo swap=4GB
  echo localhostForwarding=true
  echo.
  echo [experimental]
  echo autoMemoryReclaim=gradual
  echo sparseVhd=true
) > "%USERPROFILE%\.wslconfig"
type "%USERPROFILE%\.wslconfig"

echo.
echo === 2/2  Installing WSL2 + Ubuntu 24.04 (downloads about 1 GB)
wsl --install -d Ubuntu-24.04 --no-launch
if errorlevel 1 (
  echo.
  echo WSL install returned an error - copy this window's text to Claude.
) else (
  echo.
  echo Done. Restart Windows now, then open "Ubuntu 24.04" from the Start menu once
  echo and choose a Linux username and password.
)
echo.
pause
