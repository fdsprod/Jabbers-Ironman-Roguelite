@echo off
REM Ironman Roguelite localisation report.
REM   locals.bat                 the spec that asserts it, then the report
REM   locals.bat --report        report only, skip the spec
REM   locals.bat --lax           do not fail on untranslated strings
REM   locals.bat --no-color      plain output
REM
REM Compares every MCM option label against gamedata\configs\text, in both
REM directions: a node with no translation renders as the raw string id, and a
REM translation with no node is usually a rename that left the old string
REM behind. Exit 1 on anything not already recorded in harness\mcm_labels.lua,
REM and on any untranslated string unless --lax is passed.
REM
REM The report runs LAST, on purpose. It is the part you came here to read, and
REM when it ran first its summary scrolled off behind the spec output -- the
REM last line on screen said PASS while 20 strings were untranslated, which is
REM the same never-noticed failure this whole tool exists to prevent.

setlocal
cd /d "%~dp0"

set LUA=
where luajit.exe >nul 2>&1 && set LUA=luajit.exe
if "%LUA%"=="" if exist "tools\luajit.exe" set LUA=tools\luajit.exe

if "%LUA%"=="" (
    echo.
    echo ERROR: no LuaJIT found.
    echo Put luajit.exe on PATH or at tests\tools\luajit.exe.
    echo A Lua 5.1-compatible VM is required -- the module loader uses setfenv,
    echo which was removed in Lua 5.2.
    exit /b 2
)

REM --report must come first if used; everything after it is forwarded on.
set "_REPORT_ONLY="
if /i "%~1"=="--report" (
    set "_REPORT_ONLY=1"
    shift /1
)

REM Rebuild the remaining args, preserving quoting.
set "_ARGS=%1"
:collect
shift /1
if not "%~1"=="" (
    set "_ARGS=%_ARGS% %1"
    goto collect
)

REM Coloured output needs code page 65001. Remember the current one and put it
REM back on the way out -- chcp changes outlive the batch file otherwise.
set "_OLDCP="
for /f "tokens=2 delims=:" %%a in ('chcp') do set "_OLDCP=%%a"
set "_OLDCP=%_OLDCP: =%"
chcp 65001 >nul 2>&1

REM Spec first, report last -- see the note at the top.
REM
REM `if errorlevel 1`, never `if not "%ERRORLEVEL%"=="0"`: inside a
REM parenthesised block cmd substitutes %ERRORLEVEL% when it PARSES the block,
REM so the comparison reads the value from before the command ran. That is why
REM a failing spec here used to leave the exit code alone unless the report
REM happened to fail too.
set "_RC=0"

if not defined _REPORT_ONLY (
    "%LUA%" run.lua --file mcm_localization %_ARGS%
    if errorlevel 1 set "_RC=1"
    echo.
)

"%LUA%" locals.lua %_ARGS%
if errorlevel 1 set "_RC=1"

if defined _OLDCP chcp %_OLDCP% >nul 2>&1
exit /b %_RC%
