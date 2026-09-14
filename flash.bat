@echo off
rem Double-clickable wrapper around flash.ps1 for field machines whose
rem default PowerShell execution policy blocks unsigned scripts (the
rem "not digitally signed" / "running scripts is disabled" errors).
rem Forwards all arguments untouched: flash.bat <project> <module> [options]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
pause
exit /b %EXITCODE%
