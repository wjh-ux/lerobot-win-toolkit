@echo off
rem ============================================================
rem  LeRobot Windows Toolkit - CMD launcher
rem  Double-click to open the menu, or pass an argument:
rem     lerobot.bat 4        calibrate
rem     lerobot.bat install  same as 0
rem     lerobot.bat check    same as 1
rem     lerobot.bat hw       hardware check
rem  Keep this file next to lerobot-menu.ps1 / install-lerobot.ps1
rem  / test-lerobot.ps1 (same folder).
rem  ASCII-only on purpose: CMD uses the OEM code page, so any
rem  Chinese characters here would render as garbage.
rem ============================================================
setlocal
cd /d "%~dp0"

set "PS1=%~dp0lerobot-menu.ps1"

rem ---- was this started by double-click? then we pause at the end ----
set "DOUBLECLICK="
echo %cmdcmdline% | find /i "%~nx0" >nul 2>nul && set "DOUBLECLICK=1"

rem ---- remove Mark-of-the-Web: a downloaded zip marks files as untrusted, ----
rem ---- which RemoteSigned policies refuse to run. Harmless if absent.    ----
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Filter *.ps1 | Unblock-File" >nul 2>nul

if not exist "%PS1%" goto :no_ps1

where powershell >nul 2>nul
if errorlevel 1 goto :no_powershell

rem ---- friendly aliases ----
set "ARG=%~1"
if /i "%ARG%"=="install"  set "ARG=0"
if /i "%ARG%"=="setup"    set "ARG=0"
if /i "%ARG%"=="check"    set "ARG=1"
if /i "%ARG%"=="test"     set "ARG=1"
if /i "%ARG%"=="hw"       set "ARG=w"
if /i "%ARG%"=="hardware" set "ARG=w"

if "%ARG%"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARG%
)
set "RC=%ERRORLEVEL%"
if defined DOUBLECLICK goto :pause_ok
endlocal & exit /b %RC%

:no_ps1
echo.
echo  [ERROR] lerobot-menu.ps1 not found in this folder:
echo          %~dp0
echo.
echo  Put these four files in the SAME folder:
echo          lerobot.bat
echo          lerobot-menu.ps1
echo          install-lerobot.ps1
echo          test-lerobot.ps1
echo.
if defined DOUBLECLICK goto :pause_err
endlocal & exit /b 1

:no_powershell
echo.
echo  [ERROR] powershell.exe not found.
echo          This tool needs Windows PowerShell 5.1 or newer.
echo.
if defined DOUBLECLICK goto :pause_err
endlocal & exit /b 1

:pause_ok
echo.
echo  Press any key to close this window...
pause >nul
endlocal & exit /b 0

:pause_err
echo.
echo  Press any key to close this window...
pause >nul
endlocal & exit /b 1
