@echo off
REM Ironman Roguelite spec suite.
REM   run.bat                  all specs (self-tests gate unit and e2e)
REM   run.bat self             harness self-tests only
REM   run.bat unit             unit specs only
REM   run.bat e2e              end-to-end journeys only
REM   run.bat --file stash     only spec files whose path contains "stash"
REM   run.bat -t "offline"     only tests whose full name contains "offline"
REM   run.bat --no-color       plain output
REM   run.bat --ascii          ok/XX instead of the tick and cross
REM
REM Spec files are discovered from self\, unit\ and e2e\ -- a new *.spec.lua
REM needs no registration. Either filter skips the self-test gate.

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

REM The tick and cross are UTF-8, so the console needs code page 65001.
REM Remember the current one and put it back on the way out -- chcp changes
REM outlive the batch file otherwise.
set "_OLDCP="
for /f "tokens=2 delims=:" %%a in ('chcp') do set "_OLDCP=%%a"
set "_OLDCP=%_OLDCP: =%"
chcp 65001 >nul 2>&1

"%LUA%" run.lua %*
set "_RC=%ERRORLEVEL%"

if defined _OLDCP chcp %_OLDCP% >nul 2>&1
exit /b %_RC%
