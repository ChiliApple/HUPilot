@echo off
REM HUPilot-Setup aus dem Repo - ZIELMASCHINE: Admin-PC
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0..\Stick\HUPilot\Setup\HUPilot-Setup.ps1"
