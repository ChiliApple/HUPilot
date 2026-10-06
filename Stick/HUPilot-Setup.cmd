@echo off
REM HUPilot-Setup - ZIELMASCHINE: Admin-PC (Windows ADK fuer das WLAN-Paket)
REM Stufe 1 laeuft sichtbar: Fehler (z. B. Ausfuehrungsrichtlinie) bleiben stehen
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0HUPilot\Setup\HUPilot-Setup.ps1"
if errorlevel 1 pause
