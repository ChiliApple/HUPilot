@echo off
REM ZIELMASCHINE: Admin-PC mit Windows ADK
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HUPilot-Setup.ps1"
