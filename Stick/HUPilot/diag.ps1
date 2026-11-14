# =====================================================================
# HUPilot  diag.ps1  - Diagnose mit Auswahlmenue (nur lesen, aendert nichts)
# ZIELMASCHINE: Geraet (OOBE Shift+F10 oder Admin-CMD) -> D:\diag
# Jede Anzeige passt auf einen Bildschirm -> abfotografieren.
# =====================================================================
$ErrorActionPreference = 'Continue'
$CfgDir   = $PSScriptRoot
$LocalLog = 'C:\Windows\Temp\HUPilot.log'
$WipeLog  = 'C:\Windows\Temp\HUPilot-Wipe.log'
# Ohne Administratorrechte (z. B. go.cmd per Doppelklick im Explorer) sind viele Werte nicht lesbar (Hash, TPM, WLAN)
#   -> mit Adminrechten in neuem Fenster neu starten (UAC); im Einrichtungsbildschirm (Shift+F10) sind die Rechte immer da
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  HUPilot-Diagnose braucht Administratorrechte.' -ForegroundColor Yellow
    Write-Host '  Starte neu mit Adminrechten (Windows fragt nach einem Admin-Konto) ...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"') -ErrorAction Stop
        Write-Host '  Weiter im neuen Fenster.' -ForegroundColor Green
        Start-Sleep -Seconds 3
    } catch {
        Write-Host '  Abgebrochen. Eingabeaufforderung mit Rechtsklick > "Als Administrator ausführen" öffnen, dann:  D:  und  diag' -ForegroundColor Red
        try { Read-Host '  Enter = Fenster schließen' | Out-Null } catch { }
    }
    exit 1
}
try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray'; $Host.UI.RawUI.WindowTitle = 'HUPilot Diagnose' } catch { }

# Bereinigung fuer Anzeige und Datei am Stick (gleiche Regeln wie der Bericht an den Admin in go.ps1, hier eigenstaendig,
# weil diag go.ps1 nicht laedt): Geheimnisse aus config.json samt URL- und JSON-Varianten, Host des Webhooks,
# Tenant-ID ohne Bindestriche, Schluessel auf die letzten 5 Zeichen, signierte Adressen, Tokens, E-Mail-Adressen (UPN).
function Get-DiagRawValues {
    # Rueckfall bei kaputter config.json: Werte der geheimen Felder per Muster aus dem Rohtext, so gut es geht
    # (auch ohne Doppelpunkt oder ohne Anfuehrungszeichen). Nur zum Ersetzen, nie zur Anzeige.
    param([string]$Raw)
    $h = @{}
    foreach ($k in 'ClientSecret', 'WlanKey', 'AdminPassword', 'Admin2Password', 'TeamsWebhook', 'TenantId', 'ClientId', 'EditionKey') {
        foreach ($m in [regex]::Matches([string]$Raw, '(?i)"?\b' + $k + '\b"?\s*[:=]?\s*(?:"((?:[^"\\\r\n]|\\.)*)"?|([^,\r\n}\s][^,\r\n}]*))')) {
            $v = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value })
            $v = ([string]$v).Trim()
            if ($v.Length -ge 3) { $h[$k] = $v }
        }
    }
    return $h
}
function Get-DiagSecrets {
    # $Cfg = gelesene config.json; ohne $Cfg die Werte aus dem Rohtext ($Raw, Rueckfall)
    param($Cfg, [string]$Raw = '')
    $s = New-Object System.Collections.Generic.List[string]
    $keys = 'ClientSecret', 'WlanKey', 'AdminPassword', 'Admin2Password', 'TeamsWebhook', 'TenantId', 'ClientId', 'EditionKey'
    $val = @{}
    if ($Cfg) { foreach ($k in $keys) { $val[$k] = ([string]$Cfg.$k).Trim() } }
    elseif ($Raw) { $val = Get-DiagRawValues $Raw }
    foreach ($k in $keys) { $v = [string]$val[$k]; if ($v.Length -ge 3) { $s.Add($v) } }
    $x = $null
    if ([uri]::TryCreate(([string]$val['TeamsWebhook']).Trim(), [UriKind]::Absolute, [ref]$x) -and $x.Host.Length -ge 3) { $s.Add($x.Host) }
    $tid = (([string]$val['TenantId']).Trim()) -replace '-', ''
    if ($tid.Length -ge 3) { $s.Add($tid) }
    foreach ($v in @($s.ToArray())) {
        try { $e = [uri]::EscapeDataString($v); if ($e -cne $v) { $s.Add($e) } } catch { }
        try { $j = (ConvertTo-Json -InputObject $v -Compress); $j = $j.Substring(1, $j.Length - 2); if ($j -cne $v) { $s.Add($j) } } catch { }
        $j2 = $v.Replace('\', '\\').Replace('"', '\"').Replace('/', '\/'); if ($j2 -cne $v) { $s.Add($j2) }
    }
    return @($s | Select-Object -Unique | Sort-Object -Property Length -Descending)
}
function Protect-DiagText {
    # -MaskIds: config.json nicht lesbar -> zusaetzlich alle GUIDs (Tenant-ID, App-ID) und 32-stellige Hex-Werte ersetzen
    param([string]$Text, [string[]]$Secrets = @(), [bool]$MaskIds = $false)
    $t = [string]$Text
    if (-not $t) { return '' }
    # Grob kappen (lange Zeilen machen Muster langsam): letztes, evtl. angeschnittenes Wort und ein am Ende stehender
    # Anfang eines Geheimnisses fallen weg, nie ein Teilstueck
    if ($t.Length -gt 4000) {
        $t = $t.Substring(0, 4000)
        $i = $t.LastIndexOfAny([char[]]@(' ', "`t", "`r", "`n"))
        $t = $(if ($i -ge 0) { $t.Substring(0, $i + 1) } else { '' })
        foreach ($x in @($Secrets)) { $x = [string]$x; for ($k = [math]::Min($x.Length - 1, $t.Length); $k -ge 3; $k--) { if ($t.EndsWith($x.Substring(0, $k), [StringComparison]::OrdinalIgnoreCase)) { $t = $t.Substring(0, $t.Length - $k); break } } }
        $t = $t.TrimEnd() + ' ...'
    }
    $t = [regex]::Replace($t, '[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}', { param($m) '*****-' + $m.Value.Substring($m.Value.Length - 5) })
    foreach ($x in @($Secrets)) { if ([string]$x) { $t = [regex]::Replace($t, [regex]::Escape([string]$x), '***', 'IgnoreCase') } }
    $t = [regex]::Replace($t, '(?i)https://\S*[?&]sig[=]\S*', '(Adresse entfernt)')
    $t = [regex]::Replace($t, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*', '***')
    $t = [regex]::Replace($t, '(?i)((?<!\\)"(?:client_secret|clientsecret|access_token|refresh_token|password|adminpassword|admin2password|wlankey|teamswebhook)"\s*:\s*")((?:[^"\\]|\\.)*)', '$1***')
    $t = [regex]::Replace($t, '(?i)(\\"(?:client_secret|clientsecret|access_token|refresh_token|password|adminpassword|admin2password|wlankey|teamswebhook)\\"\s*:\s*\\")((?:(?!\\").)*)', '$1***')
    $t = [regex]::Replace($t, '(?i)(Bearer|client_secret[=:]|access_token["'':= ]+)\s*[^\s"''&]+', '$1 ***')
    # E-Mail: Beginn nur am Anfang eines Namens (Lookbehind), sonst waere das Muster bei langen Zeilen quadratisch
    $t = [regex]::Replace($t, '(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}@([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,}', { param($m) '***@' + $m.Value.Split('@')[1] })
    if ($MaskIds) {
        $t = [regex]::Replace($t, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '***')
        $t = [regex]::Replace($t, '(?i)\b[0-9a-f]{32}\b', '***')
    }
    return $t
}
# config.json lesen; nie die Meldung von ConvertFrom-Json weitergeben (unter 5.1 steht der ganze JSON-Text darin)
$script:DiagSecrets = @()
$script:DiagNoCfg = $true
$cfgRaw = ''
try { $cfgRaw = [string](Get-Content (Join-Path $CfgDir 'config.json') -Raw -Encoding UTF8 -ErrorAction Stop) } catch { }
$cfgObj = $null
if ($cfgRaw) { try { $cfgObj = $cfgRaw | ConvertFrom-Json -ErrorAction Stop } catch { } }
if ($cfgObj) { $script:DiagNoCfg = $false; try { $script:DiagSecrets = @(Get-DiagSecrets $cfgObj) } catch { } }
elseif ($cfgRaw) { try { $script:DiagSecrets = @(Get-DiagSecrets $null $cfgRaw) } catch { } }
$cfgRaw = ''; $cfgObj = $null

function Get-Serial { try { return ([string](Get-CimInstance Win32_BIOS).SerialNumber).Trim() } catch { return '?' } }
function Head([string]$t) {
    Clear-Host
    Write-Host ('  HUPilot Diagnose  |  ' + (Get-Serial) + '  |  ' + (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('  ' + $t) -ForegroundColor White
    Write-Host ('  ' + ('-' * 70))
}
function Tail([string]$File, [int]$N, [string]$Pattern) {
    if (-not (Test-Path $File)) { Write-Host ('  (nicht vorhanden: ' + $File + ')') -ForegroundColor Yellow; return }
    $l = @(Get-Content -Path $File -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($Pattern) { $l = @($l | Where-Object { $_ -match $Pattern }) }
    foreach ($x in @($l | Select-Object -Last $N)) {
        $c = 'Gray'
        if ($x -match 'FEHLER|ERR |Fehler') { $c = 'Red' } elseif ($x -match 'ACHTUNG|OFFLINE|Hinweis|nicht m(ö|oe)glich') { $c = 'Yellow' } elseif ($x -match ' OK|erfolgreich|gespeichert|zugewiesen') { $c = 'Green' }
        $t = Protect-DiagText $x $script:DiagSecrets $script:DiagNoCfg; if ($t.Length -gt 150) { $t = $t.Substring(0, 150) }
        Write-Host ('  ' + $t) -ForegroundColor $c
    }
}
function Show-Device {
    Head 'Gerät'
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
    try { $c = Get-Content (Join-Path $CfgDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json; Write-Host ('  Stick-Config : ' + $c.Tenant + ' | Tag ' + $c.GroupTag + ' | WLAN ' + $c.WlanSsid) } catch { Write-Host '  Stick-Config : nicht lesbar' -ForegroundColor Red }
    try { $v = Get-Content -LiteralPath (Join-Path $CfgDir 'Config\version.json') -Raw -Encoding UTF8 | ConvertFrom-Json; Write-Host ('  HUPilot      : v' + $v.version + ' (' + $v.buildDate + ')') } catch { Write-Host '  HUPilot      : Version nicht lesbar' }
    try { $i = Get-Content -LiteralPath (Join-Path $CfgDir 'Config\installed.json') -Raw -Encoding UTF8 | ConvertFrom-Json; Write-Host ('  Update       : ' + $i.Date + ', ' + $i.Check) } catch { }
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
    # Bericht an den Admin (config.json "TeamsWebhook"): nur "eingetragen" und ob der Dienst erreichbar ist, nie Adresse oder Host (Geheimnis)
    $tw = ''; try { $tw = ([string](Get-Content (Join-Path $CfgDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).TeamsWebhook).Trim() } catch { }
    if ($tw) {
        $x = $null
        if (-not [uri]::TryCreate($tw, [UriKind]::Absolute, [ref]$x) -or $x.Scheme -ne 'https' -or $x.Host -match '(?i)(^|\.)webhook\.office\.com$') { Write-Host '  FEHLT Bericht an den Admin: Feld Teams-Webhook ungültig. Im Setup das Feld Teams-Webhook prüfen und den Stick neu bespielen.' -ForegroundColor Yellow }
        else {
            $th = 'https://' + $x.Host
            try { $null = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $th -UseBasicParsing -TimeoutSec 8 -Method Head; Write-Host '  OK    Bericht an den Admin: eingetragen, erreichbar' -ForegroundColor Green }
            catch {
                if ($_.Exception.Response) { Write-Host ('  OK    Bericht an den Admin: eingetragen, erreichbar (HTTP ' + [int]$_.Exception.Response.StatusCode + ')') -ForegroundColor Green }
                else { Write-Host ('  FEHLT Bericht an den Admin: eingetragen, nicht erreichbar (' + (Protect-DiagText ($_.Exception.Message -replace 'https?://\S+', '(Adresse)') $script:DiagSecrets $script:DiagNoCfg) + ')') -ForegroundColor Red }
            }
        }
    } else { Write-Host '  Bericht an den Admin: nicht eingetragen' }
    try { $ob = @(Get-ChildItem -LiteralPath (Join-Path $CfgDir 'logs\outbox') -Filter '*.json' -File -ErrorAction Stop).Count; if ($ob) { Write-Host ('  Berichte an den Admin am Stick, noch nicht gesendet: ' + $ob) -ForegroundColor Yellow } } catch { }
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
    foreach ($x in 'C:\Recovery\Customizations', 'C:\Recovery\AutoApply', 'C:\Recovery\OEM', 'C:\Recovery\HUPilot-OEM-Backup', 'C:\Recovery\HUPilot-PPKG-Backup') {
        try {
            $null = Get-Item -LiteralPath $x -Force -ErrorAction Stop
            $sz = (Get-ChildItem $x -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Write-Host ('  ' + $x + '  vorhanden, ' + [math]::Round($sz / 1MB) + ' MB')
        } catch [System.UnauthorizedAccessException] { Write-Host ('  ' + $x + '  kein Zugriff (nur SYSTEM) - Inhalt unbekannt') -ForegroundColor Yellow }
        catch {
            if ($_.FullyQualifiedErrorId -like '*UnauthorizedAccess*' -or $_.Exception.Message -match 'verweigert|denied') { Write-Host ('  ' + $x + '  kein Zugriff (nur SYSTEM) - Inhalt unbekannt') -ForegroundColor Yellow }
            else { Write-Host ('  ' + $x + '  nicht vorhanden') }
        }
    }
    Write-Host ''
    $appRx = 'McAfee'; try { $cc = Get-Content (Join-Path $CfgDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $cc.RemoveApps -and "$($cc.RemoveApps)") { $appRx = [string]$cc.RemoveApps } } catch { }
    Write-Host ('  Hersteller-Apps (' + $appRx + '):') -ForegroundColor White
    $hit = $false
    try { foreach ($x in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -match $appRx })) { Write-Host ('  vorinstallierte App: ' + $x.PackageName) -ForegroundColor Yellow; $hit = $true } } catch { Write-Host '  vorinstallierte Apps: nicht lesbar' }
    try { foreach ($x in @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -match $appRx })) { Write-Host ('  installierte App   : ' + $x.PackageFullName) -ForegroundColor Yellow; $hit = $true } } catch { }
    foreach ($x in @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $appRx })) { Write-Host ('  Programm           : ' + $x.DisplayName + ' ' + $x.DisplayVersion) -ForegroundColor Yellow; $hit = $true }
    if (-not $hit) { Write-Host '  keine gefunden' -ForegroundColor Green }
    Write-Host ''
    Write-Host '  Geplante Aufgabe HUPilot-Wipe:' -ForegroundColor White
    $all = @(cmd.exe /c 'schtasks /query /tn HUPilot-Wipe /v /fo list 2>&1')
    $q = @($all | Where-Object { $_ -match 'Status|Letztes|Last Result|Energie|Power' } | Select-Object -First 6)
    if ($LASTEXITCODE -ne 0 -or -not $q.Count) { Write-Host '  nicht vorhanden (normal, solange kein Zurücksetzen läuft)' }
    foreach ($x in $q) { Write-Host ('  ' + ([string]$x).Trim()) }
}
function Save-All {
    $sn = Get-Serial
    New-Item -ItemType Directory -Path (Join-Path $CfgDir 'logs') -Force | Out-Null
    $f = Join-Path $CfgDir ('logs\diag-' + $sn + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.txt')
    Head 'Alles in Datei am Stick speichern ...'
    $out = @()
    $out += (& { Show-Device; Show-Net; Show-Prov } *>&1 | Out-String)
    $out += "`r`n===== HUPilot.log =====`r`n"; if (Test-Path $LocalLog) { $out += (Get-Content $LocalLog -Tail 300 -Encoding UTF8 | Out-String) }
    $out += "`r`n===== HUPilot-Wipe.log =====`r`n"; if (Test-Path $WipeLog) { $out += (Get-Content $WipeLog -Encoding UTF8 | Out-String) }
    $out += "`r`n===== netsh wlan show interfaces =====`r`n" + (netsh wlan show interfaces 2>&1 | Out-String)
    $out += "`r`n===== ipconfig /all =====`r`n" + (ipconfig /all 2>&1 | Out-String)
    # Vor dem Ablegen am Stick bereinigen (Tenant-ID, App-ID, Secrets, UPN aus Fehlermeldungen)
    # zeilenweise (die Teile sind ganze Logs), dann Datei schreiben
    $out = @((($out | ForEach-Object { [string]$_ }) -join '') -split "`r?`n" | ForEach-Object { Protect-DiagText $_ $script:DiagSecrets $script:DiagNoCfg })
    try { Set-Content -Path $f -Value $out -Encoding UTF8; Head 'Gespeichert'; Write-Host ('  ' + $f) -ForegroundColor Green; Write-Host '  Stick am PC anstecken und die Datei schicken.' }
    catch { Write-Host ('  FEHLER: ' + $_.Exception.Message) -ForegroundColor Red }
}

while ($true) {
    Head 'Menü'
    Write-Host '   [1]  HUPilot-Log  (letzte 30 Zeilen)'
    Write-Host '   [2]  HUPilot-Log  nur Fehler / Warnungen'
    Write-Host '   [3]  Zurücksetzen  (Wipe-Log)'
    Write-Host '   [4]  Gerät  (Windows, Seriennr, Akku, Uhr, TPM, Hash, Stick-Config)'
    Write-Host '   [5]  Netzwerk / WLAN / Microsoft-Adressen'
    Write-Host '   [6]  WLAN-Paket, Intune-Sperre, Recovery, geplante Aufgabe'
    Write-Host '   [7]  ALLES in Datei am Stick speichern  (logs\diag-...txt)'
    Write-Host '   [0]  Ende'
    Write-Host ''
    $k = Read-Host '  Auswahl'
    $back = $true
    switch ($k) {
        '1' { Head 'HUPilot.log - letzte 30 Zeilen'; Tail $LocalLog 30 '' }
        '2' { Head 'HUPilot.log - Fehler / Warnungen'; Tail $LocalLog 30 'FEHLER|ACHTUNG|OFFLINE|Hinweis|nicht m(ö|oe)glich|Exitcode|Abbruch|Fehler|START' }
        '3' { Head 'HUPilot-Wipe.log'; Tail $WipeLog 30 ''; Write-Host ''; Tail $LocalLog 8 'Zur(ü|ue)cksetzen|schtasks|Aufgabe|provtool|SYSTEM' }
        '4' { Show-Device }
        '5' { Show-Net }
        '6' { Show-Prov }
        '7' { Save-All }
        '0' { try { $Host.UI.RawUI.BackgroundColor = 'Black' } catch { }; exit 0 }
        # continue im switch gilt nur fuer den switch (danach kaeme die Enter-Frage), deshalb ein Merker
        default { Write-Host '  Ungültige Auswahl - bitte 0 bis 7' -ForegroundColor Yellow; Start-Sleep -Seconds 2; $back = $false }
    }
    if (-not $back) { continue }
    Write-Host ''
    Read-Host '  Enter = zurück zum Menü' | Out-Null
}
