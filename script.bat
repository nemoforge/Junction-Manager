@echo off
setlocal
set "JUNCTION_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "JUNCTION_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%JUNCTION_PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Junction.ps1"
exit /b %errorlevel%
