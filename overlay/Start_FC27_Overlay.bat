@echo off
setlocal
title EA FC 27 Broadcast HUD

rem ===========================================================================
rem  Builds (only when needed) and starts the EA FC 27 transparent overlay.
rem  Needs nothing but Windows 10/11: the C# compiler ships with .NET
rem  Framework 4.x, which is part of every supported Windows install.
rem ===========================================================================

cd /d "%~dp0"

rem ---- already running? ---------------------------------------------------
tasklist /fi "imagename eq FC27_Overlay.exe" 2>nul | find /i "FC27_Overlay.exe" >nul
if not errorlevel 1 (
    echo  The overlay is already running.
    echo  In game: F8 = demo card, F9 = diagnostics, F12 = quit.
    timeout /t 3 >nul
    exit /b 0
)

if not exist "FC27_Overlay.cs" (
    echo  [X] FC27_Overlay.cs not found next to this script.
    pause
    exit /b 1
)

rem ---- locate the .NET Framework compiler ---------------------------------
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo.
    echo  [X] csc.exe not found - .NET Framework 4.x is missing on this system.
    echo      Install ".NET Framework 4.8" from Windows Update and run this again.
    if exist "FC27_Overlay.exe" (
        echo      Starting the previously built FC27_Overlay.exe instead.
        start "" "FC27_Overlay.exe"
        timeout /t 3 >nul
        exit /b 0
    )
    pause
    exit /b 1
)

echo  Compiling FC27_Overlay.exe ...
"%CSC%" /nologo /target:winexe /platform:x64 /optimize+ /warn:2 ^
    /out:"FC27_Overlay.exe" ^
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll ^
    /win32manifest:"app.manifest" ^
    "FC27_Overlay.cs"

if errorlevel 1 (
    echo.
    echo  [X] Build failed - see the compiler messages above.
    if exist "FC27_Overlay.exe" (
        echo      Starting the previously built FC27_Overlay.exe instead.
        start "" "FC27_Overlay.exe"
        timeout /t 3 >nul
        exit /b 0
    )
    pause
    exit /b 1
)

echo  Build OK - starting overlay ...
start "" "FC27_Overlay.exe"
timeout /t 2 >nul
echo.
echo  Overlay running. In game: F8 = demo card, F9 = diagnostics, F12 = quit.
exit /b 0
