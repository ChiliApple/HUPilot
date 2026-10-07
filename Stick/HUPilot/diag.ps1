# =====================================================================
# HUPilot  diag.ps1  - Diagnose mit Auswahlmenue (nur lesen, aendert nichts)
# ZIELMASCHINE: Geraet (OOBE Shift+F10 oder Admin-CMD) -> D:\diag
# Jede Anzeige passt auf einen Bildschirm -> abfotografieren.
# =====================================================================
$ErrorActionPreference = 'Continue'
$CfgDir   = $PSScriptRoot
$LocalLog = 'C:\Windows\Temp\HUPilot.log'
$WipeLog  = 'C:\Windows\Temp\HUPilot-Wipe.log'
try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray'; $Host.UI.RawUI.WindowTitle = 'HUPilot Diagnose' } catch { }

function Get-Serial { try { return ([string](Get-CimInstance Win32_BIOS).SerialNumber).Trim() } catch { return '?' } }
function Head([string]$t) {
    Clear-Host
    Write-Host ('  HUPilot Diagnose  |  ' + (Get-Serial) + '  |  ' + (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('  ' + $t) -ForegroundColor White
    Write-Host ('  ' + ('-' * 70))
}
function Tail([string]$File, [int]$N, [string]$Pattern) {
    if (-not (Test-Path $File)) { Write-Host ('  (nicht vorhanden: ' + $File + ')') -ForegroundColor Yellow; return }
    $l = @(Get-Content -Path $File -ErrorAction SilentlyContinue)
    if ($Pattern) { $l = @($l | Where-Object { $_ -match $Pattern }) }
    foreach ($x in @($l | Select-Object -Last $N)) {
        $c = 'Gray'
        if ($x -match 'FEHLER|ERR |Fehler') { $c = 'Red' } elseif ($x -match 'ACHTUNG|OFFLINE|Hinweis|nicht moeglich') { $c = 'Yellow' } elseif ($x -match ' OK|erfolgreich|gespeichert|zugewiesen') { $c = 'Green' }
        $t = $x; if ($t.Length -gt 150) { $t = $t.Substring(0, 150) }
        Write-Host ('  ' + $t) -ForegroundColor $c
    }
}
function Show-Device {
    Head 'Geraet'
    try { $os = Get-CimInstance Win32_OperatingSystem; Write-Host ('  Windows      : ' + $os.Caption + '  ' + $os.Version + '  (' + $os.OSArchitecture + ')') } catch { }
    try { $cs = Get-CimInstance Win32_ComputerSystem; Write-Host ('  Hersteller   : ' + $cs.Manufacturer + '  ' + $cs.Model) } catch { }
    try { $b = Get-CimInstance Win32_BIOS; Write-Host ('  Seriennummer : ' + $b.SerialNumber + '   BIOS ' + $b.SMBIOSBIOSVersion) } catch { }
    try {
        $bat = @(Get-CimInstance Win32_Battery)
        if ($bat.Count) { Write-Host ('  Akku         : ' + [int](($bat | Measure-Object EstimatedChargeRemaining -Average).Average) + ' %  Status ' + (($bat | ForEach-Object { $_.BatteryStatus }) -join ',') + '  (2/3/6-9 = Netzteil)') }
        else { Write-Host '  Akku         : keiner' }
    } catch { }
    Write-Host ('  Uhrzeit      : ' + (Get-Date -Format 'dd.MM.yyyy HH:mm:ss') + '  Zeitzone ' + (Get-TimeZone).Id)
    Write-Host ('  Angemeldet   : ' + [Environment]::UserName)
    try {
        $p = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -match '\\Users\\' })
        Write-Host ('  Profile      : ' + $(if ($p.Count) { ($p | ForEach-Object { Split-Path $_.LocalPath -Leaf }) -join ', ' } else { 'keine' }))
    } catch { }
    try { $tpm = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm; Write-Host ('  TPM          : aktiv ' + $tpm.IsEnabled_InitialValue + '  Version ' + $tpm.SpecVersion) } catch { Write-Host '  TPM          : nicht lesbar' }
    try {
        $dd = Get-CimInstance -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
        Write-Host ('  Hash         : ' + $(if ($dd.DeviceHardwareData) { 'lesbar (' + ([string]$dd.DeviceHardwareData).Length + ' Zeichen)' } else { 'NICHT lesbar' }))
    } catch { Write-Host '  Hash         : NICHT lesbar' -ForegroundColor Red }
    try { $c = Get-Content (Join-Path $CfgDir 'config.json') -Raw | ConvertFrom-Json; Write-Host ('  Stick-Config : ' + $c.Tenant + ' | Tag ' + $c.GroupTag + ' | WLAN ' + $c.WlanSsid) } catch { Write-Host '  Stick-Config : nicht lesbar' -ForegroundColor Red }
    try { $v = Select-String -Path (Join-Path $CfgDir 'go.ps1') -Pattern "^\`$Ver\s*=\s*'([^']+)'" | Select-Object -First 1; Write-Host ('  go.ps1       : v' + $v.Matches[0].Groups[1].Value) } catch { }
}
function Show-Net {
    Head 'Netzwerk / WLAN'
    try {
        $o = @(netsh wlan show interfaces 2>&1 | Where-Object { $_ -match 'Name|SSID|Status|State|Signal|Authentifizierung|Authentication|Kanal|Channel' } | Select-Object -First 10)
        foreach ($x in $o) { Write-Host ('  ' + ([string]$x).Trim()) }
    } catch { }
    Write-Host ''
    try {
        foreach ($a in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True')) {
            Write-Host ('  ' + $a.Description + ' : ' + (@($a.IPAddress) -join ', ') + '  GW ' + (@($a.DefaultIPGateway) -join ', ') + '  DNS ' + (@($a.DNSServerSearchOrder) -join ', '))
        }
    } catch { }
    Write-Host ''
    foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt', 'https://login.microsoftonline.com', 'https://graph.microsoft.com', 'https://ztd.dds.microsoft.com', 'https://enterpriseregistration.windows.net') {
        try { $r = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 8 -Method Head; Write-Host ('  OK    ' + $u + '  (' + $r.StatusCode + ')') -ForegroundColor Green }
        catch {
            $m = $_.Exception.Message
            if ($_.Exception.Response) { Write-Host ('  OK    ' + $u + '  (erreichbar, HTTP ' + [int]$_.Exception.Response.StatusCode + ')') -ForegroundColor Green }
            else { Write-Host ('  FEHLT ' + $u + '  ' + $m) -ForegroundColor Red }
        }
    }
    try {
        $r = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5
        $srv = [DateTimeOffset]::Parse([string]$r.Headers['Date'], [Globalization.CultureInfo]::InvariantCulture)
        Write-Host ('  Uhr-Abweichung zum Server: ' + [int]([DateTimeOffset]::UtcNow - $srv).TotalSeconds + ' s')
    } catch { }
}
function Show-Prov {
    Head 'WLAN-Paket / Bereitstellungspakete / Intune-Sperre'
    $d = 'C:\ProgramData\Microsoft\Provisioning'
    foreach ($f in @(Get-ChildItem -Path $d -Filter *.ppkg -ErrorAction SilentlyContinue)) { Write-Host ('  installiert: ' + $f.Name + '  ' + $f.Length + ' Bytes  ' + $f.LastWriteTime.ToString('dd.MM.yyyy HH:mm')) }
    if (-not @(Get-ChildItem -Path $d -Filter *.ppkg -ErrorAction SilentlyContinue).Count) { Write-Host '  installiert: keine' -ForegroundColor Yellow }
    $sp = Join-Path $CfgDir 'HUPilot-WLAN.ppkg'
    if (Test-Path $sp) { Write-Host ('  am Stick   : HUPilot-WLAN.ppkg  ' + (Get-Item $sp).Length + ' Bytes') }
    try {
        $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Security' -ErrorAction Stop
        $add = $k.AllowAddProvisioningPackage; $rem = $k.AllowRemoveProvisioningPackage
        Write-Host ('  Intune AllowAddProvisioningPackage   : ' + $(if ($null -eq $add) { 'nicht gesetzt (erlaubt)' } else { $add })) -ForegroundColor $(if ($add -eq 0) { 'Yellow' } else { 'Gray' })
        Write-Host ('  Intune AllowRemoveProvisioningPackage: ' + $(if ($null -eq $rem) { 'nicht gesetzt (erlaubt)' } else { $rem }))
    } catch { Write-Host '  Intune-Sperre: keine Richtlinie (erlaubt)' }
    Write-Host ''
    Write-Host '  C:\Recovery:' -ForegroundColor White
    foreach ($x in 'C:\Recovery\Customizations', 'C:\Recovery\AutoApply', 'C:\Recovery\HUPilot-OEM-Backup') {
        if (Test-Path $x) { $s = (Get-ChildItem $x -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; Write-Host ('  ' + $x + '  ' + [math]::Round($s / 1MB) + ' MB') } else { Write-Host ('  ' + $x + '  -') }
    }
    Write-Host ''
    Write-Host '  Geplante Aufgabe HUPilot-Wipe:' -ForegroundColor White
    $q = @(cmd.exe /c 'schtasks /query /tn HUPilot-Wipe /v /fo list 2>&1' | Where-Object { $_ -match 'Status|Letztes|Last Result|Energie|Power|existiert|exist' } | Select-Object -First 6)
    foreach ($x in $q) { Write-Host ('  ' + ([string]$x).Trim()) }
}
function Save-All {
    $sn = Get-Serial
    New-Item -ItemType Directory -Path (Join-Path $CfgDir 'logs') -Force | Out-Null
    $f = Join-Path $CfgDir ('logs\diag-' + $sn + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.txt')
    Head 'Alles in Datei am Stick speichern ...'
    $out = @()
    $out += (& { Show-Device; Show-Net; Show-Prov } *>&1 | Out-String)
    $out += "`r`n===== HUPilot.log =====`r`n"; if (Test-Path $LocalLog) { $out += (Get-Content $LocalLog -Tail 300 | Out-String) }
    $out += "`r`n===== HUPilot-Wipe.log =====`r`n"; if (Test-Path $WipeLog) { $out += (Get-Content $WipeLog | Out-String) }
    $out += "`r`n===== netsh wlan show interfaces =====`r`n" + (netsh wlan show interfaces 2>&1 | Out-String)
    $out += "`r`n===== ipconfig /all =====`r`n" + (ipconfig /all 2>&1 | Out-String)
    try { Set-Content -Path $f -Value $out -Encoding UTF8; Head 'Gespeichert'; Write-Host ('  ' + $f) -ForegroundColor Green; Write-Host '  Stick am PC anstecken und die Datei schicken.' }
    catch { Write-Host ('  FEHLER: ' + $_.Exception.Message) -ForegroundColor Red }
}

while ($true) {
    Head 'Menue'
    Write-Host '   [1]  HUPilot-Log  (letzte 30 Zeilen)'
    Write-Host '   [2]  HUPilot-Log  nur Fehler / Warnungen'
    Write-Host '   [3]  Zuruecksetzen  (Wipe-Log)'
    Write-Host '   [4]  Geraet  (Windows, Seriennr, Akku, Uhr, TPM, Hash, Stick-Config)'
    Write-Host '   [5]  Netzwerk / WLAN / Microsoft-Adressen'
    Write-Host '   [6]  WLAN-Paket, Intune-Sperre, Recovery, geplante Aufgabe'
    Write-Host '   [7]  ALLES in Datei am Stick speichern  (logs\diag-...txt)'
    Write-Host '   [0]  Ende'
    Write-Host ''
    $k = Read-Host '  Auswahl'
    switch ($k) {
        '1' { Head 'HUPilot.log - letzte 30 Zeilen'; Tail $LocalLog 30 '' }
        '2' { Head 'HUPilot.log - Fehler / Warnungen'; Tail $LocalLog 30 'FEHLER|ACHTUNG|OFFLINE|Hinweis|nicht moeglich|Exitcode|Abbruch|Fehler|START' }
        '3' { Head 'HUPilot-Wipe.log'; Tail $WipeLog 30 ''; Write-Host ''; Tail $LocalLog 8 'Zuruecksetzen|schtasks|Aufgabe|provtool|SYSTEM' }
        '4' { Show-Device }
        '5' { Show-Net }
        '6' { Show-Prov }
        '7' { Save-All }
        '0' { try { $Host.UI.RawUI.BackgroundColor = 'Black' } catch { }; exit 0 }
        default { continue }
    }
    Write-Host ''
    Read-Host '  Enter = zurueck zum Menue' | Out-Null
}
