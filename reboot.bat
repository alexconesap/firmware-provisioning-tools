@echo off
rem Double-clickable wrapper around lib\reboot.ps1 (see flash.bat for why this
rem exists instead of running the .ps1 directly on Windows).
rem Forwards all arguments untouched: reboot.bat <project> <module> [options]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\reboot.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
pause
exit /b %EXITCODE%
