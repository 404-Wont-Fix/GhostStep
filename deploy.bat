@echo off
setlocal

rem GhostStep3 deploy launcher.
rem The mirror-sync exclusion list lives in tools/gs.py (single source of truth);
rem this file only launches it, so there is nothing to keep in sync here.
rem NOTE: keep all comments ASCII-only. UTF-8 Chinese comments get mis-decoded
rem       by GBK codepage cmd and break into garbage commands ('ferences' bug).

echo.
echo [GhostStep3 Deploy]
echo.

python "%~dp0tools\gs.py" 4 --sync
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: deploy failed with code %ERRORLEVEL%
    pause
    exit /b 1
)

echo Done. Restart Isaac or press Ctrl+R in-game to reload Lua.
echo.
pause
