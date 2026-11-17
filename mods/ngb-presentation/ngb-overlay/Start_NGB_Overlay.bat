@echo off
setlocal
title Next-Gen Broadcast - overlay

rem ===========================================================================
rem  Builds (when needed) and starts the Next-Gen Broadcast overlay.
rem  Needs nothing but Windows 10/11: the C# compiler ships with .NET
rem  Framework 4.x, which is part of every supported Windows install.
rem ===========================================================================

cd /d "%~dp0"

tasklist /fi "imagename eq NGB_Overlay.exe" 2>nul | find /i "NGB_Overlay.exe" >nul
if not errorlevel 1 (
    echo  The overlay is already running.
    echo  F10 = demo card, F11 = diagnostics, F12 = quit.
    timeout /t 3 >nul
    exit /b 0
)

if not exist "NGB_Overlay.cs" (
    echo  [X] NGB_Overlay.cs not found next to this script.
    pause
    exit /b 1
)

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo.
    echo  [X] csc.exe not found - .NET Framework 4.x is missing on this system.
    echo      Install ".NET Framework 4.8" from Windows Update and try again.
    if exist "NGB_Overlay.exe" (
        echo      WARNING: starting an OLDER NGB_Overlay.exe instead
        for %%F in ("NGB_Overlay.exe") do echo      (built %%~tF) - the Sider overlay will say "OVERLAY STALE".
        start "" "NGB_Overlay.exe"
        timeout /t 3 >nul
        exit /b 1
    )
    pause
    exit /b 1
)

echo  Compiling NGB_Overlay.exe ...
"%CSC%" /nologo /target:winexe /platform:x64 /optimize+ /warn:2 ^
    /out:"NGB_Overlay.exe" ^
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll ^
    /win32manifest:"app.manifest" ^
    "NGB_Overlay.cs"

if errorlevel 1 (
    echo.
    echo  [X] Build failed - the compiler messages are above.
    echo      Copy them into a message; the overlay cannot start without them.
    if exist "NGB_Overlay.exe" (
        echo.
        echo      WARNING: an OLDER NGB_Overlay.exe is present and will start
        echo      instead. It does not contain the current fixes, and the Sider
        echo      overlay will label it "OVERLAY STALE".
        for %%F in ("NGB_Overlay.exe") do echo      that exe was built %%~tF
        echo      Delete NGB_Overlay.exe if you would rather see nothing than
        echo      an old build.
        start "" "NGB_Overlay.exe"
        timeout /t 4 >nul
        exit /b 1
    )
    pause
    exit /b 1
)

echo  Build OK - starting overlay ...
start "" "NGB_Overlay.exe"
timeout /t 2 >nul
echo.
echo  Overlay running.  F10 demo   F11 diagnostics   F12 quit
exit /b 0
