@echo off
setlocal EnableExtensions

set "VARIABLE_NAME=DELPHI_TOOLS"
for %%I in ("%~dp0.") do set "TOOLS_ROOT=%%~fI"

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%ComSpec%' -Verb RunAs -ArgumentList '/c ""%~f0""'"
    exit /b 0
)

setx /M "%VARIABLE_NAME%" "%TOOLS_ROOT%" >nul
if errorlevel 1 (
    echo Failed to set the system environment variable %VARIABLE_NAME%.
    echo Run this file as an administrator and try again.
    exit /b 1
)

echo %VARIABLE_NAME% has been set to:
echo %TOOLS_ROOT%
echo.
echo Restart VS Code and terminals to load the new system environment.
endlocal
exit /b 0
