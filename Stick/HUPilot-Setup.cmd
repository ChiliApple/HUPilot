@echo off
REM HUPilot-Setup - ZIELMASCHINE: Admin-PC (Windows ADK fuer das WLAN-Paket)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HUPilot\Setup\HUPilot-Setup.ps1"
