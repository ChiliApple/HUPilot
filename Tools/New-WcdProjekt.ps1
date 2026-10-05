<#
.SYNOPSIS
    HUPilot - erzeugt aus der WCD-Vorlage ein eigenes WCD-Projekt mit WLAN-Name und -Kennwort.
.DESCRIPTION
    ZIELMASCHINE: Admin-PC mit Windows Configuration Designer (WCD).
    Liest WlanSsid und WlanKey aus der config.json des Sticks (oder fragt nach),
    schreibt WCD-Projekt\HUPilot-WLAN\ mit neuer Paket-ID.
    Danach: WCD > Projekt oeffnen > HUPilot-WLAN.icdproj.xml > Exportieren >
    Bereitstellungspaket > ohne Verschluesselung/Signatur > HUPilot-WLAN.ppkg auf den Stick nach \HUPilot\
.NOTES
    Aufruf: powershell -ExecutionPolicy Bypass -File Tools\New-WcdProjekt.ps1
    Optional: -ConfigPath E:\HUPilot\config.json
#>
param([string]$ConfigPath = '')

$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot -Parent
$vorl   = Join-Path $root 'WCD-Vorlage\HUPilot-WLAN'
$ziel   = Join-Path $root 'WCD-Projekt\HUPilot-WLAN'

$ssid = ''; $key = ''
if (-not $ConfigPath) {
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $d.IsReady) { continue }
            $p = Join-Path $d.RootDirectory.FullName 'HUPilot\config.json'
            if (Test-Path $p) { $ConfigPath = $p; break }
        } catch { }
    }
}
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $ssid = [string]$cfg.WlanSsid; $key = [string]$cfg.WlanKey
    Write-Host ('config.json: ' + $ConfigPath)
}
if (-not $ssid -or $ssid -match '^<') { $ssid = Read-Host 'WLAN-Name (SSID)' }
if (-not $key  -or $key  -match '^<') { $key  = Read-Host 'WLAN-Kennwort (WPA2-Personal)' }
if (-not $ssid -or $key.Length -lt 8) { throw 'WLAN-Name fehlt oder Kennwort kuerzer als 8 Zeichen' }

New-Item -ItemType Directory -Path $ziel -Force | Out-Null
$id = '{' + [guid]::NewGuid().ToString() + '}'
$enc = New-Object System.Text.UTF8Encoding($true)

$x = [System.IO.File]::ReadAllText((Join-Path $vorl 'customizations.xml'), $enc)
$x = $x.Replace('SSID="WLAN-NAME"', 'SSID="' + [System.Security.SecurityElement]::Escape($ssid) + '"')
$x = $x.Replace('<SecurityKey>WLAN-KENNWORT</SecurityKey>', '<SecurityKey>' + [System.Security.SecurityElement]::Escape($key) + '</SecurityKey>')
$x = [regex]::Replace($x, '<ID>\{[0-9a-fA-F-]+\}</ID>', '<ID>' + $id + '</ID>')
[System.IO.File]::WriteAllText((Join-Path $ziel 'customizations.xml'), $x, $enc)

$p = [System.IO.File]::ReadAllText((Join-Path $vorl 'HUPilot-WLAN.icdproj.xml'), $enc)
$p = [regex]::Replace($p, 'Id="\{[0-9a-fA-F-]+\}"', 'Id="' + $id + '"')
[System.IO.File]::WriteAllText((Join-Path $ziel 'HUPilot-WLAN.icdproj.xml'), $p, $enc)

Write-Host ''
Write-Host ('WCD-Projekt erstellt: ' + $ziel) -ForegroundColor Green
Write-Host 'Weiter: WCD > Projekt oeffnen > HUPilot-WLAN.icdproj.xml > Exportieren > Bereitstellungspaket'
Write-Host '        ohne Verschluesselung > als HUPilot-WLAN.ppkg in den Ordner \HUPilot\ am Stick'
Write-Host 'ACHTUNG: WCD-Projekt\ enthaelt das WLAN-Kennwort - nicht weitergeben.' -ForegroundColor Yellow
