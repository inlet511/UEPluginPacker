@echo off
rem UE Plugin Packager GUI. Drag a job file (.psd1) onto this file to load it.
where pwsh >nul 2>nul
if %errorlevel%==0 (
    start "" pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0UEPP.Gui.ps1" %*
) else (
    start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0UEPP.Gui.ps1" %*
)
