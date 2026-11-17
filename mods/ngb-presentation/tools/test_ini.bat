@echo off
rem Runs the sider.ini add/remove test (problem 9). Needs Windows PowerShell,
rem which every supported Windows has.
title NGB - sider.ini test
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_ini.ps1"
if errorlevel 1 (
    echo.
    echo  TEST FAILED - please send this window's text with your report.
    pause
    exit /b 1
)
echo.
echo  All sider.ini cases passed.
pause
exit /b 0
