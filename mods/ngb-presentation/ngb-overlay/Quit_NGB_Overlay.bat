@echo off
rem Stops the broadcast overlay (same as pressing F12 in game).
taskkill /f /im NGB_Overlay.exe >nul 2>&1
if errorlevel 1 (
    echo  The overlay was not running.
) else (
    echo  Overlay stopped.
)
timeout /t 2 >nul
