@echo off
setlocal

set "SRC=D:\Github\Game Mod\Binding of Isaac Repentance+\GhostStep"
set "DST=D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\GhostStep3"

echo.
echo [GhostStep3 Deploy]
echo   Source: %SRC%
echo   Target: %DST%
echo.

if not exist "%SRC%\main.lua" (
    echo ERROR: source not found
    pause
    exit /b 1
)

rem /MIR mirror sync (removes stale files e.g. old tests/)
rem NOTE: keep all comments ASCII-only. UTF-8 Chinese comments get mis-decoded
rem       by GBK codepage cmd and break into garbage commands ('ferences' bug).
rem /XD recordings: keep runtime replay data (protects it from /MIR deletion)
rem /XD .git .claude references: repo/reference dirs are not part of the mod
rem /XD tools: offline analysis tooling (Python), not loaded by the game
rem /XF ANALYSIS.md AGENTS.md: dev/agent docs live in the repo, not in the mod
robocopy "%SRC%" "%DST%" /MIR /XD tests recordings .git .claude references tools /XF deploy.bat .gitignore ANALYSIS.md AGENTS.md /NFL /NDL /NJH /NJS /NP >nul
if %ERRORLEVEL% GEQ 8 (
    echo ERROR: robocopy failed with code %ERRORLEVEL%
    pause
    exit /b 1
)

echo Done. Restart Isaac or press Ctrl+R in-game to reload Lua.
echo.
pause
