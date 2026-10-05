@echo off
REM HUPilot - Diagnose.cmd
REM ZIELMASCHINE: Geraet im OOBE (Shift+F10). Aufs Stick-Hauptverzeichnis kopieren, dann D:\Diagnose
REM Sammelt Infos nach Stick:\HUPilot\logs\diag-<PC>.txt - aendert NICHTS am Geraet.
set L=%~d0\HUPilot\logs\diag-%COMPUTERNAME%.txt
if not exist "%~d0\HUPilot\logs" mkdir "%~d0\HUPilot\logs"
echo ===== %date% %time% > "%L%"
whoami >> "%L%" 2>&1
echo --- Edition >> "%L%"
powershell -NoProfile -c "(Get-CimInstance Win32_OperatingSystem).Caption + ' ' + (Get-CimInstance Win32_OperatingSystem).Version" >> "%L%" 2>&1
echo --- ProgramData\Microsoft\Provisioning >> "%L%"
dir /a C:\ProgramData\Microsoft\Provisioning >> "%L%" 2>&1
echo --- C:\Recovery >> "%L%"
dir /a /s C:\Recovery\Customizations C:\Recovery\AutoApply C:\Recovery\HUPilot-OEM-Backup >> "%L%" 2>&1
echo --- WLAN >> "%L%"
netsh wlan show profiles >> "%L%" 2>&1
netsh wlan show interfaces >> "%L%" 2>&1
echo --- HUPilot.log >> "%L%"
type C:\Windows\Temp\HUPilot.log >> "%L%" 2>&1
echo --- HUPilot-Wipe.log >> "%L%"
type C:\Windows\Temp\HUPilot-Wipe.log >> "%L%" 2>&1
echo --- RemoteWipe-Aufgabe >> "%L%"
schtasks /Query /TN HUPilot-Wipe /V /FO LIST >> "%L%" 2>&1
echo.
echo Diagnose gespeichert: %L%
pause
