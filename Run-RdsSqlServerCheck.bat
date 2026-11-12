@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%Invoke-RdsSqlServerCustomerCheck.ps1"

if not exist "%SCRIPT_PATH%" (
    echo [NG] Customer diagnostic script was not found.
    echo Check that the complete distribution folder is present.
    goto :finish_error
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
set "RESULT=%ERRORLEVEL%"
goto :finish

:finish_error
set "RESULT=1"

:finish
echo.
pause
exit /b %RESULT%
