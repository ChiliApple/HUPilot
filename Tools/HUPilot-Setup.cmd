@echo off
REM HUPilot-Setup aus dem Repo - ZIELMASCHINE: Admin-PC
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Stick\HUPilot\Setup\HUPilot-Setup.ps1"
if errorlevel 1 pause
