@echo off
rem ===========================================================================
rem  NEXT-GEN BROADCAST  -  doctor  (MoonFros Presents)
rem
rem  Double-click this to find out why nothing is showing.
rem  It changes NOTHING on your PC. It reads files and writes a report.
rem
rem  Optional: drag your Sider folder onto this file to skip the search.
rem ===========================================================================
setlocal
title Next-Gen Broadcast - doctor

if not exist "%~dp0NGB_Doctor.ps1" goto:missing

where powershell >nul 2>&1
if errorlevel 1 goto:no_ps

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0NGB_Doctor.ps1" "%~1"

echo.
echo ==================================================================
echo  The report is in ngb_doctor.txt, in this same folder.
echo  Open it with Notepad if you want to read it again.
echo ==================================================================
echo.
pause
exit /b 0

:missing
echo.
echo  [X] NGB_Doctor.ps1 is not next to this file.
echo      Keep both files in the same folder and run it again.
echo.
pause
exit /b 1

:no_ps
echo.
echo  [X] Windows PowerShell was not found on this PC.
echo      That usually means a very old or a stripped-down Windows.
echo      Send me sider.log and ngb-dll.log instead - those two files
echo      answer the same question.
echo.
pause
exit /b 1
