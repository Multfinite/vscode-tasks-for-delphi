@echo off
setlocal
set "SCRIPT=%~dp0Delphi7Tasks.ps1"

if not exist "%SCRIPT%" (
    echo [Delphi] Script not found: "%SCRIPT%".
    endlocal & exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
