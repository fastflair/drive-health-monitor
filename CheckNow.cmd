@echo off
rem Runs the elevated scheduled task on demand (no UAC prompt) and opens the dashboard when done.
if not exist "%~dp0data" mkdir "%~dp0data"
echo.>"%~dp0data\show.flag"
schtasks /run /tn "Drive Health Monitor" >nul 2>&1
if errorlevel 1 (
  echo The "Drive Health Monitor" task isn't installed yet. Run Install.ps1 first.
  pause
)
