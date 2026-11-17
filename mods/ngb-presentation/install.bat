@echo off
setlocal
title Next-Gen Broadcast - install
color 0F

rem ===========================================================================
rem  NEXT-GEN FOOTBALL BROADCAST PRESENTATION  -  installer
rem  MOONFROS PRESENTS  -  created by MoonFros
rem
rem  Copies the mod into a Sider folder, installs the renderer DLL and
rem  registers the module in sider.ini (adding three lines, never rewriting
rem  anything else). Nothing is compiled and no extra window is started.
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

rem ---------------------------------------------------------------------------
rem  3. the renderer (this is what actually draws the cards)
rem ---------------------------------------------------------------------------
rem  NGB_Render.dll is a prebuilt 64-bit DLL that is loaded into the GAME
rem  process by the Lua module. It draws inside the game's own frame, so it
rem  works in windowed, borderless and exclusive fullscreen, focused or not.
rem  Nothing is compiled here: no Visual Studio, no compiler, no downloads.
rem ---------------------------------------------------------------------------
set "DLL_OK=0"
if exist "%HERE%\ngb-render\NGB_Render.dll" (
    if not exist "%SIDER%\ngb-render" mkdir "%SIDER%\ngb-render" >nul 2>&1
    copy /y "%HERE%\ngb-render\NGB_Render.dll" "%SIDER%\ngb-render\" >nul
    if errorlevel 1 (
        echo  [!] Could not copy NGB_Render.dll - is the folder read-only?
        >> "%LOG%" echo DLL copy failed
    ) else (
        set "DLL_OK=1"
        echo  ngb-render\NGB_Render.dll                installed
        >> "%LOG%" echo copied NGB_Render.dll
    )
) else (
    echo  [!] ngb-render\NGB_Render.dll is missing from this package.
    >> "%LOG%" echo DLL missing from package
)

rem ---- optional fallback: the C# overlay (only if the user already built it)
for %%I in ("%HERE%\ngb-overlay") do set "OSRC=%%~fI"
for %%I in ("%SIDER%\ngb-overlay") do set "ODST=%%~fI"
if /i "%OSRC%"=="%ODST%" (
    echo  ngb-overlay\                            already in place
) else if exist "%HERE%\ngb-overlay\NGB_Overlay.cs" (
    xcopy "%HERE%\ngb-overlay\*.*" "%SIDER%\ngb-overlay\" /E /I /Y /Q >nul
    echo  ngb-overlay\ (fallback)                installed
    >> "%LOG%" echo copied ngb-overlay fallback
)
if exist "%SIDER%\ngb-overlay" (
    > "%SIDER%\ngb-overlay\install_info.txt" echo Installed by MoonFros Next-Gen Broadcast
    >> "%SIDER%\ngb-overlay\install_info.txt" echo Sider folder: %SIDER%
    >> "%SIDER%\ngb-overlay\install_info.txt" echo Date: %DATE% %TIME%
    >> "%SIDER%\ngb-overlay\install_info.txt" echo Optional fallback renderer. The normal renderer is ngb-render\NGB_Render.dll.
)

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
rem  4. verification (no compiler, no second window)
rem ---------------------------------------------------------------------------
if /i not "%DLL_OK%"=="1" (
    echo.
    echo  ==================================================================
    echo   INSTALL INCOMPLETE  - the renderer DLL is missing
    echo.
    echo   modules\ and sider.ini are done, so the mod is registered, but
    echo   without ngb-render\NGB_Render.dll nothing can be drawn.
    echo   Re-download the package; ngb-render\NGB_Render.dll must sit next
    echo   to install.bat. Nothing has to be uninstalled first.
    echo  ==================================================================
    >> "%LOG%" echo INSTALL INCOMPLETE - no DLL
    echo.
    pause
    exit /b 1
)
echo  renderer                                 NGB_Render.dll (in-game, D3D11)
>> "%LOG%" echo renderer: NGB_Render.dll

rem ---------------------------------------------------------------------------
rem  5. done
rem ---------------------------------------------------------------------------
echo.
echo ==================================================================
echo   INSTALLATION COMPLETE  -  MOONFROS PRESENTS
echo.
echo   Start Football Life as usual - windowed, borderless or fullscreen.
echo   The cards are drawn inside the game's own frame, so they stay up even
echo   when the game window is not focused (click the desktop: they remain).
echo.
echo   In game:   [7] presentation style   [8] presentation on / off
echo              [9] shot analysis on / off
echo   Renderer:  F8 self-test card   F7 diagnostics   F12 cards on / off
echo.
echo   Cards: goals (real scorer, minute and score), shots and saves,
echo          brace / hat-trick milestones, half-time and full-time,
echo          Man of the Match.
echo.
echo   Logs if something is not showing:
echo     %SIDER%\sider.log                     (module, prefixed [NGB])
echo     %SIDER%\content\ngb-presentation\ngb-dll.log    (renderer)
echo     %SIDER%\content\ngb-presentation\heartbeat.txt  (module alive, 1/s)
echo     %SIDER%\content\ngb-presentation\render.txt     (renderer alive, 1/s)
echo     %SIDER%\content\ngb-presentation\state.json     (what the HUD was told)
echo.
echo   Uninstall: run uninstall.bat from this folder.
echo ==================================================================
>> "%LOG%" echo INSTALL OK
echo.
exit /b 0

:build_failed
echo.
echo  ==================================================================
echo   INSTALL INCOMPLETE
echo  ==================================================================
>> "%LOG%" echo INSTALL INCOMPLETE
echo.
pause
exit /b 1

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
