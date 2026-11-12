@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"

if not exist "%SCRIPT_DIR%Invoke-RdsSqlServerCustomerCheck.ps1" (
    echo [NG] 実行スクリプトが見つかりません。
    echo 配布フォルダー一式を確認してください。
    goto :finish_error
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-RdsSqlServerCustomerCheck.ps1"
set "RESULT=%ERRORLEVEL%"
goto :finish

:finish_error
set "RESULT=1"

:finish
echo.
pause
exit /b %RESULT%
