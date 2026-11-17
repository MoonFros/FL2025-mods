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
>> "%LOG%" echo step 0: started, looking for the Sider folder
>> "%LOG%" echo package folder: %HERE%

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
>> "%LOG%" echo step 1: Sider folder accepted
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
>> "%LOG%" echo step 2: modules copied

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
        >> "%LOG%" echo step 3: renderer DLL installed
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
echo  calling the sider.ini editor ...
>> "%LOG%" echo step 4: calling _ngb_ini.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%\_ngb_ini.ps1" -Ini "%SIDER%\sider.ini" -Mode add -Module "NGB_Presentation.lua" >> "%LOG%" 2>&1
>> "%LOG%" echo step 4: powershell exit %ERRORLEVEL%
if errorlevel 1 goto ini_batch

findstr /i /c:"NGB_Presentation.lua" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 goto ini_batch
findstr /i /c:"match-stats.enabled" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 goto ini_batch
goto ini_ok

rem ---------------------------------------------------------------------------
rem  The PowerShell editor above is the tidy way (it inserts the lines next to
rem  your other lua.module lines). If PowerShell is blocked or fails, this is
rem  the plain way: add only the lines that are missing, at the end of the file.
rem  No clipboard, no Notepad, no window to close by accident.
rem ---------------------------------------------------------------------------
:ini_batch
echo.
echo  PowerShell could not edit sider.ini. Adding the lines the simple way ...
>> "%LOG%" echo step 4b: batch fallback
rem  if the file does not end with a newline, an append would glue itself onto
rem  the last line; one empty line first makes that impossible
>> "%SIDER%\sider.ini" echo.
findstr /i /c:"luajit.ext.enabled" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 (
    >> "%SIDER%\sider.ini" echo luajit.ext.enabled = 1
    echo  added: luajit.ext.enabled = 1
    >> "%LOG%" echo added luajit.ext.enabled
)
findstr /i /c:"match-stats.enabled" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 (
    >> "%SIDER%\sider.ini" echo match-stats.enabled = 1
    echo  added: match-stats.enabled = 1
    >> "%LOG%" echo added match-stats.enabled
)
findstr /i /c:"NGB_Presentation.lua" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 (
    >> "%SIDER%\sider.ini" echo lua.module = "NGB_Presentation.lua"
    echo  added: lua.module = "NGB_Presentation.lua"
    >> "%LOG%" echo added lua.module
)
findstr /i /c:"NGB_Presentation.lua" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 goto ini_manual
findstr /i /c:"luajit.ext.enabled = 0" "%SIDER%\sider.ini" >nul 2>&1
if not errorlevel 1 (
    echo.
    echo  [!] sider.ini still says "luajit.ext.enabled = 0" somewhere.
    echo      Change that to 1, or the module cannot load the DLL.
    >> "%LOG%" echo WARNING luajit.ext.enabled is 0
)
echo  sider.ini : lines added at the end of the file
>> "%LOG%" echo step 4c: batch fallback succeeded
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
echo   Doctor:    NGB_Doctor.bat (says why nothing shows, writes a report)
echo   This log:  install_log.txt (next to install.bat)
echo   Uninstall: run uninstall.bat from this folder.
echo ==================================================================
>> "%LOG%" echo INSTALL OK
>> "%LOG%" echo step 6: finished successfully
echo.
echo   ----------------------------------------------------------------
echo    Finished. This window stays open on purpose - read it, then
echo    press any key to close it.
echo.
echo    If nothing shows in the game, run NGB_Doctor.bat (same folder as
echo    install.bat). It writes ngb_doctor.txt, and that file says why.
echo   ----------------------------------------------------------------
echo.
pause
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
>> "%LOG%" echo cancelled by the user
pause
exit /b 1

:end_fail
echo.
echo  Installation did not finish. See README.txt for the manual steps.
>> "%LOG%" echo INSTALL FAILED
pause
exit /b 1
