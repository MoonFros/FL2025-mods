@echo off
setlocal
title EA FC 27 HyperMotion Broadcast - install

rem ===========================================================================
rem  One-click installer.
rem  Copies the mod into a Sider folder, makes sure sider.ini references it,
rem  then builds and starts the broadcast HUD.
rem
rem  Usage:  double-click, or drag your Sider folder onto this file.
rem          (Or run:  Install.bat "C:\path\to\sider")
rem ===========================================================================

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "SRCMOD=%HERE%\modules"
set "SRCOV=%HERE%\fc27-overlay"

echo ==============================================================
echo   EA FC 27 HyperMotion Broadcast  -  installer
echo ==============================================================
echo.

if not exist "%SRCMOD%\FC27_Broadcast.lua" (
    echo  [X] Run this file from inside the mod folder:
    echo      ...\mods\fc27-broadcast\Install.bat
    goto end_fail
)

rem ---------------------------------------------------------------------------
rem  1. locate the Sider folder
rem ---------------------------------------------------------------------------
set "SIDER="
if not "%~1"=="" set "SIDER=%~1"
if not defined SIDER if exist "%HERE%\..\sider.ini" set "SIDER=%HERE%\.."
if not defined SIDER if exist "%HERE%\sider.ini" set "SIDER=%HERE%"
if not defined SIDER (
    echo  Where is Sider? Drag its folder - the one containing sider.exe
    echo  and sider.ini - onto this window and press Enter.
    echo  ^(or just press Enter to cancel^)
    echo.
    set /p "SIDER=  Sider folder: "
)
if not defined SIDER goto cancelled
set "SIDER=%SIDER:"=%"
for %%I in ("%SIDER%") do set "SIDER=%%~fI"
if "%SIDER:~-1%"=="\" set "SIDER=%SIDER:~0,-1%"

if not exist "%SIDER%\sider.ini" (
    echo.
    echo  [X] "%SIDER%\sider.ini" not found.
    echo      Pick the folder that contains sider.exe and sider.ini.
    goto end_fail
)
echo  Sider folder:  %SIDER%
echo.

rem ---------------------------------------------------------------------------
rem  2. copy modules\
rem ---------------------------------------------------------------------------
for %%I in ("%SRCMOD%") do set "MSRC=%%~fI"
for %%I in ("%SIDER%\modules") do set "MDST=%%~fI"
if /i "%MSRC%"=="%MDST%" (
    echo  modules\ ... already in place
) else (
    if not exist "%SIDER%\modules" md "%SIDER%\modules" >nul 2>&1
    xcopy "%SRCMOD%\*.*" "%SIDER%\modules\" /Y /Q >nul
    echo  modules\FC27_Broadcast.lua + FC27_Broadcast.ini ... copied
)

rem ---------------------------------------------------------------------------
rem  3. copy fc27-overlay\
rem ---------------------------------------------------------------------------
for %%I in ("%SRCOV%") do set "OSRC=%%~fI"
for %%I in ("%SIDER%\fc27-overlay") do set "ODST=%%~fI"
if /i "%OSRC%"=="%ODST%" (
    echo  fc27-overlay\ ... already in place
) else (
    xcopy "%SRCOV%\*.*" "%SIDER%\fc27-overlay\" /E /I /Y /Q >nul
    echo  fc27-overlay\ ... copied
)

rem ---------------------------------------------------------------------------
rem  4. sider.ini
rem ---------------------------------------------------------------------------
set "NEED=0"
findstr /i /c:"FC27_Broadcast.lua" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 set "NEED=1"
findstr /i /c:"luajit.ext.enabled" "%SIDER%\sider.ini" >nul 2>&1
if errorlevel 1 set "NEED=1"

if "%NEED%"=="0" (
    echo  sider.ini ... already enabled
) else (
    > "%TEMP%\fc27_lines.txt" echo luajit.ext.enabled = 1
    >> "%TEMP%\fc27_lines.txt" echo lua.module = "FC27_Broadcast.lua"
    type "%TEMP%\fc27_lines.txt" | clip
    echo.
    echo  ------------------------------------------------------------------
    echo   sider.ini open in Notepad. Two lines are already on your
    echo   clipboard - click at the END of the file, press Ctrl+V,
    echo   then Ctrl+S.  They are:
    echo.
    echo            luajit.ext.enabled = 1
    echo            lua.module = "FC27_Broadcast.lua"
    echo.
    echo   ^(if FC27_Broadcast.lua is already in the file, skip the paste^)
    echo  ------------------------------------------------------------------
    start "" notepad "%SIDER%\sider.ini"
    echo.
    pause
    findstr /i /c:"FC27_Broadcast.lua" "%SIDER%\sider.ini" >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] sider.ini still does not mention FC27_Broadcast.lua.
        echo      Add the two lines by hand, then run
        echo      "%SIDER%\fc27-overlay\Start_FC27_Overlay.bat"
        goto end_fail
    )
    echo  sider.ini ... updated
)

rem ---------------------------------------------------------------------------
rem  5. build + start the HUD
rem ---------------------------------------------------------------------------
echo.
if exist "%SIDER%\fc27-overlay\Start_FC27_Overlay.bat" (
    echo  Building the HUD ...
    call "%SIDER%\fc27-overlay\Start_FC27_Overlay.bat"
)
echo.
echo ==============================================================
echo   Installed. Start the game in BORDERLESS or WINDOWED mode.
echo   Cards appear on goals, shots and at full time.
echo   F8 demo card   F9 diagnostics   F12 quit the HUD
echo ==============================================================
echo.
pause
exit /b 0

:cancelled
echo.
echo  Cancelled - nothing was copied.
timeout /t 3 >nul
exit /b 1

:end_fail
echo.
echo  Install did not finish. Manual steps are in README.md
echo  ("Installation - 4 steps").
pause
exit /b 1
