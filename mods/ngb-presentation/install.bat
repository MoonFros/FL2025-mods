@echo off
setlocal
title Next-Gen Broadcast - install
color 0F

rem ===========================================================================
rem  NEXT-GEN FOOTBALL BROADCAST PRESENTATION  -  installer
rem  MOONFROS PRESENTS  -  created by MoonFros
rem
rem  Copies the mod into a Sider folder, registers it in sider.ini (adding two
rem  lines, never rewriting anything else), builds the overlay and starts it.
rem
rem  Usage:  double-click, drag your Sider folder onto this file, or
rem          install.bat "D:\Games\Football Life 2025\Sider"
rem ===========================================================================

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "LOG=%HERE%\install_log.txt"
> "%LOG%" echo Next-Gen Broadcast install log  %DATE% %TIME%

echo ==================================================================
echo   NEXT-GEN FOOTBALL BROADCAST PRESENTATION
echo   MOONFROS PRESENTS        created by MoonFros
echo ==================================================================
echo.

if not exist "%HERE%\modules\NGB_Presentation.lua" (
    echo  [X] Run this file from inside the mod folder, so that
    echo      modules\NGB_Presentation.lua sits next to it.
    goto end_fail
)

rem ---------------------------------------------------------------------------
rem  1. find the Sider folder
rem ---------------------------------------------------------------------------
set "SIDER="
if not "%~1"=="" set "SIDER=%~1"
if defined SIDER goto validate

call :try "%HERE%\.."
call :try "%HERE%"
if defined SIDER goto validate

rem look in the usual install locations on every drive
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined SIDER if exist "%%D:\" (
        call :try "%%D:\Football Life 2025"
        call :try "%%D:\Football Life 2025\Sider"
        call :try "%%D:\Games\Football Life 2025"
        call :try "%%D:\Games\Football Life 2025\Sider"
        call :try "%%D:\FL2025"
        call :try "%%D:\Sider"
        call :try "%%D:\Program Files\Football Life 2025"
        call :try "%%D:\Program Files\Football Life 2025\Sider"
        call :try "%%D:\SteamLibrary\steamapps\common\Football Life 2025"
        call :try "%%D:\SteamLibrary\steamapps\common\Football Life 2025\Sider"
        call :try "%%D:\Games\PES 2021"
        call :try "%%D:\Games\PES 2021\Sider"
    )
)

:ask
if defined SIDER goto validate
echo  Sider was not found automatically.
echo  Drag your Sider folder - the one containing sider.exe and sider.ini -
echo  onto this window, then press Enter.  (Just press Enter to cancel.)
echo.
set "SIDER="
set /p "SIDER=  Sider folder: "
if not defined SIDER goto cancelled
echo.

:validate
set "SIDER=%SIDER:"=%"
for %%I in ("%SIDER%") do set "SIDER=%%~fI"
if "%SIDER:~-1%"=="\" set "SIDER=%SIDER:~0,-1%"

if not exist "%SIDER%\sider.ini" (
    echo  [X] "%SIDER%\sider.ini" not found - that is not a Sider folder.
    echo.
    set "SIDER="
    goto ask
)
if not exist "%SIDER%\sider.dll" (
    echo  [!] sider.dll is not in that folder - continuing anyway.
)

echo  Sider folder : %SIDER%
>> "%LOG%" echo Sider folder: %SIDER%
echo.

rem ---------------------------------------------------------------------------
rem  2. copy the mod files (nothing else is touched)
rem ---------------------------------------------------------------------------
if not exist "%SIDER%\modules" md "%SIDER%\modules" >nul 2>&1
copy /y "%HERE%\modules\NGB_Presentation.lua" "%SIDER%\modules\" >nul
if errorlevel 1 (
    echo  [X] Could not copy NGB_Presentation.lua - is the folder read-only?
    goto end_fail
)
copy /y "%HERE%\modules\NGB_Presentation.ini" "%SIDER%\modules\" >nul
if not exist "%SIDER%\content" mkdir "%SIDER%\content" >nul 2>&1
if not exist "%SIDER%\content\ngb-presentation" mkdir "%SIDER%\content\ngb-presentation" >nul 2>&1
if exist "%SIDER%\content\ngb-presentation" (
    echo  content\ngb-presentation                 ready
) else (
    echo  [!] Could not create content\ngb-presentation - the module will retry.
)
echo  modules\NGB_Presentation.lua + .ini      installed
>> "%LOG%" echo copied modules

for %%I in ("%HERE%\ngb-overlay") do set "OSRC=%%~fI"
for %%I in ("%SIDER%\ngb-overlay") do set "ODST=%%~fI"
if /i "%OSRC%"=="%ODST%" (
    echo  ngb-overlay\                            already in place
) else (
    xcopy "%HERE%\ngb-overlay\*.*" "%SIDER%\ngb-overlay\" /E /I /Y /Q >nul
    echo  ngb-overlay\                            installed
    >> "%LOG%" echo copied ngb-overlay
)
> "%SIDER%\ngb-overlay\install_info.txt" echo Installed by MoonFros Next-Gen Broadcast
>> "%SIDER%\ngb-overlay\install_info.txt" echo Sider folder: %SIDER%
>> "%SIDER%\ngb-overlay\install_info.txt" echo Date: %DATE% %TIME%
>> "%SIDER%\ngb-overlay\install_info.txt" echo Remove with uninstall.bat (or delete this folder).

rem ---------------------------------------------------------------------------
rem  3. register the module in sider.ini
rem ---------------------------------------------------------------------------
echo.
echo  sider.ini ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%\_ngb_ini.ps1" -Ini "%SIDER%\sider.ini" -Mode add -Module "NGB_Presentation.lua"
if errorlevel 1 goto ini_manual

findstr /i /c:"NGB_Presentation.lua" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 goto ini_manual
findstr /i /c:"match-stats.enabled" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 (
    echo  [!] sider.ini has no match-stats.enabled line - the live score and
    echo      clock need it. Adding it with the clipboard fallback.
    goto ini_manual
)
goto ini_ok

:ini_manual
echo.
echo  ------------------------------------------------------------------
echo   Could not edit sider.ini automatically.  It is now open in Notepad
echo   and these three lines are on your clipboard: click at the END of the
echo   file, press Ctrl+V, then Ctrl+S.
echo.
echo              luajit.ext.enabled = 1
echo              match-stats.enabled = 1
echo              lua.module = "NGB_Presentation.lua"
echo  ------------------------------------------------------------------
> "%TEMP%\ngb_lines.txt" echo luajit.ext.enabled = 1
>> "%TEMP%\ngb_lines.txt" echo match-stats.enabled = 1
>> "%TEMP%\ngb_lines.txt" echo lua.module = "NGB_Presentation.lua"
type "%TEMP%\ngb_lines.txt" | clip
start "" notepad "%SIDER%\sider.ini"
pause
findstr /i /c:"NGB_Presentation.lua" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 (
    echo  [!] sider.ini still does not mention NGB_Presentation.lua.
    echo      Add the line by hand and start the game; everything else is installed.
    goto end_fail
)
echo  sider.ini : updated by hand

:ini_ok
>> "%LOG%" echo sider.ini configured

rem ---------------------------------------------------------------------------
rem  4. build + start the overlay
rem ---------------------------------------------------------------------------
echo.
if exist "%SIDER%\ngb-overlay\Start_NGB_Overlay.bat" (
    call "%SIDER%\ngb-overlay\Start_NGB_Overlay.bat"
)

rem ---------------------------------------------------------------------------
rem  5. done
rem ---------------------------------------------------------------------------
echo.
echo ==================================================================
echo   INSTALLATION COMPLETE  -  MOONFROS PRESENTS
echo.
echo   Start Football Life in BORDERLESS or WINDOWED mode.
echo.
echo   In game:   [7] presentation style   [8] presentation on / off
echo              [9] shot analysis on / off
echo   Overlay:   F10 demo   F11 diagnostics   F12 quit
echo.
echo   Cards: goals (spotlight + shot analysis), shots and saves,
echo          brace / hat-trick milestones, full-time Man of the Match.
echo.
echo   Uninstall: run uninstall.bat from this folder.
echo ==================================================================
>> "%LOG%" echo INSTALL OK
echo.
pause
exit /b 0

rem ---------------------------------------------------------------------------
:try
if defined SIDER goto :eof
if exist "%~1\sider.ini" set "SIDER=%~1"
goto :eof

:cancelled
echo.
echo  Cancelled - nothing was installed.
timeout /t 3 >nul
exit /b 1

:end_fail
echo.
echo  Installation did not finish. See README.txt for the manual steps.
>> "%LOG%" echo INSTALL FAILED
pause
exit /b 1
