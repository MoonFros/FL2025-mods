@echo off
setlocal
title Next-Gen Broadcast - uninstall
color 0F

rem ===========================================================================
rem  NEXT-GEN FOOTBALL BROADCAST PRESENTATION  -  uninstaller
rem  MOONFROS PRESENTS  -  created by MoonFros
rem
rem  Removes ONLY the files this mod installed and ONLY its two lines in
rem  sider.ini. Other mods, settings and game data are never touched.
rem ===========================================================================

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"

echo ==================================================================
echo   NEXT-GEN FOOTBALL BROADCAST PRESENTATION  -  uninstall
echo ==================================================================
echo.

rem ---------------------------------------------------------------------------
rem  1. find the Sider folder
rem ---------------------------------------------------------------------------
set "SIDER="
if not "%~1"=="" set "SIDER=%~1"
if defined SIDER goto validate

call :try "%HERE%\.."
call :try "%HERE%"
if defined SIDER goto validate

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
echo  Drag your Sider folder onto this window and press Enter.
echo  (Just press Enter to cancel.)
echo.
set "SIDER="
set /p "SIDER=  Sider folder: "
if not defined SIDER goto cancelled

:validate
set "SIDER=%SIDER:"=%"
for %%I in ("%SIDER%") do set "SIDER=%%~fI"
if "%SIDER:~-1%"=="\" set "SIDER=%SIDER:~0,-1%"
if not exist "%SIDER%\sider.ini" (
    echo  [X] "%SIDER%\sider.ini" not found - that is not a Sider folder.
    set "SIDER="
    goto ask
)

echo  Sider folder : %SIDER%
echo.
if not exist "%SIDER%\modules\NGB_Presentation.lua" (
    if not exist "%SIDER%\ngb-overlay\NGB_Overlay.cs" (
        echo  The mod does not look installed in that folder.
    )
)

echo  This will remove:
echo     modules\NGB_Presentation.lua
echo     modules\NGB_Presentation.ini
echo     ngb-overlay\           (the overlay and its build)
echo     content\ngb-presentation\   (runtime state file)
echo     the mod's two lines in sider.ini
echo.
echo  Nothing else is deleted.
echo.
choice /c YN /n /m "  Remove the Next-Gen Broadcast mod?  [Y/N] "
if errorlevel 2 goto cancelled
echo.

rem ---------------------------------------------------------------------------
rem  2. stop the overlay, delete only our files
rem ---------------------------------------------------------------------------
taskkill /f /im NGB_Overlay.exe >nul 2>&1
timeout /t 1 >nul

if exist "%SIDER%\modules\NGB_Presentation.lua" del /q "%SIDER%\modules\NGB_Presentation.lua"
if exist "%SIDER%\modules\NGB_Presentation.ini" del /q "%SIDER%\modules\NGB_Presentation.ini"
echo  modules\NGB_Presentation.*              removed

if exist "%SIDER%\ngb-overlay\NGB_Overlay.cs" (
    rd /s /q "%SIDER%\ngb-overlay"
    echo  ngb-overlay\                          removed
) else (
    if exist "%SIDER%\ngb-overlay" echo  ngb-overlay\ looks foreign - left untouched
)

if exist "%SIDER%\content\ngb-presentation" (
    rd /s /q "%SIDER%\content\ngb-presentation"
    echo  content\ngb-presentation\             removed
)

rem ---------------------------------------------------------------------------
rem  3. remove only our lines from sider.ini
rem ---------------------------------------------------------------------------
echo.
echo  sider.ini ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%\_ngb_ini.ps1" -Ini "%SIDER%\sider.ini" -Mode remove -Module "NGB_Presentation.lua"
if errorlevel 1 (
    echo.
    echo  [!] Could not edit sider.ini automatically.
    echo      Open %SIDER%\sider.ini and delete the line
    echo         lua.module = "NGB_Presentation.lua"
    echo      then save.  Everything else is already removed.
    pause
)

echo.
echo ==================================================================
echo   REMOVED.
echo.
echo   The files listed above and this mod's sider.ini lines are gone.
echo   Your other mods, sider.ini settings and game data are untouched.
echo   Thanks for trying MoonFros' Next-Gen Broadcast Presentation.
echo ==================================================================
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
echo  Cancelled - nothing was removed.
timeout /t 3 >nul
exit /b 1
