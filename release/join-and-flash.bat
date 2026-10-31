@echo off
rem CachyOS Nabu installer launcher for Windows (join split archive + flash).
rem UNTESTED ON WINDOWS / ON HARDWARE - see README, "Windows hosts".
rem Real implementation: join-and-flash.ps1 next to this file.
setlocal
where powershell >nul 2>nul
if errorlevel 1 (
    echo ERROR: powershell.exe not found. Windows PowerShell 5.1 is required.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0join-and-flash.ps1" %*
if errorlevel 1 (
    echo.
    echo join-and-flash.ps1 failed - see the error above. Slot B was not set active unless it says otherwise.
    pause
    exit /b 1
)
endlocal
