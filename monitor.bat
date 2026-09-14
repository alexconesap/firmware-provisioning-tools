@echo off
rem Double-clickable wrapper around monitor.ps1 (see flash.bat for why this
rem exists instead of running the .ps1 directly on Windows).
rem Forwards all arguments untouched: monitor.bat <project> <module> [options]
rem Runs until Ctrl+C.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
pause
exit /b %EXITCODE%
