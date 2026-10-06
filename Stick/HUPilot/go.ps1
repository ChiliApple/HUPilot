# =====================================================================
# HUPilot  go.ps1  v2.2
# https://github.com/ChiliApple/HUPilot
# ZIELMASCHINE: neues Windows-Geraet im OOBE (Shift+F10 -> D:\go)
# Ablauf:
#   1. config.json vom Stick lesen, Group Tag waehlen, Edition pruefen
#   2. WLAN verbinden (falls noch kein Internet)
#   3. Hardware-Hash -> Autopilot-Import mit Group Tag (oder Tag setzen)
#   4. WLAN-Paket lokal kopieren -> GRUEN "STICK ABZIEHEN"
#   5. Warten bis Autopilot-Profil zugewiesen
#   6. WLAN-Paket anwenden (bleibt ueber das Zuruecksetzen erhalten),
#      Hersteller-Anpassungen (C:\Recovery\Customizations) wegschieben,
#      Zuruecksetzen per RemoteWipe doWipePersistProvisionedData (als SYSTEM)
#   KEIN CleanPC-Paket: es bleibt in ProgramData\Provisioning und loest nach
#   jedem Zuruecksetzen erneut aus (Schleife, Test 05.10.2026)
# Jeder Fehler VOR Schritt 6 -> ROT, KEIN Zuruecksetzen, Geraet bleibt im OOBE.
# Log: C:\Windows\Temp\HUPilot.log + Stick:\HUPilot\logs\
# =====================================================================

$ErrorActionPreference = 'Stop'
$Ver        = '2.2'
$MinBattery = 50     # % Akku ohne Netzteil, darunter wird vor dem Zuruecksetzen gewartet
$Start      = Get-Date
$CfgDir     = $PSScriptRoot
$LocalLog   = 'C:\Windows\Temp\HUPilot.log'
$StickLog   = $null
$Serial     = ''
$WlanPkgName = 'HUPilot-WLAN.ppkg'
$StickPkg   = $null
$TmpPkg     = 'C:\Windows\Temp\HUPilot-WLAN.ppkg'
$WipePs1    = 'C:\Windows\Temp\HUPilot-Wipe.ps1'
$WipeLog    = 'C:\Windows\Temp\HUPilot-Wipe.log'
$WipeResult = 'C:\Windows\Temp\HUPilot-Wipe.result'
$ProvLogDir = 'C:\Windows\Temp\HUPilot-ProvLogs'
$ProfileWaitMin = 20
$GB = 'https://graph.microsoft.com/beta'

function Log {
    param([string]$Msg)
    $line = '{0}  [{1,5:N0}s]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ((Get-Date) - $Start).TotalSeconds, $Msg
    try { Add-Content -Path $LocalLog -Value $line -Encoding UTF8 } catch { }
    if ($StickLog) { try { Add-Content -Path $StickLog -Value $line -Encoding UTF8 } catch { } }
}
function Say {
    param([string]$Msg, [string]$Color = 'Gray')
    Write-Host ('  ' + $Msg) -ForegroundColor $Color
    Log $Msg
}
function Banner {
    param([string]$Text, [string]$Bg, [string[]]$Lines)
    try { $Host.UI.RawUI.BackgroundColor = $Bg; $Host.UI.RawUI.ForegroundColor = 'White'; Clear-Host } catch { }
    Write-Host ''
    Write-Host ('  ' + ('#' * 56))
    Write-Host ''
    Write-Host ('      ' + $Text)
    Write-Host ''
    Write-Host ('  ' + ('#' * 56))
    Write-Host ''
    Write-Host ('  Seriennummer: ' + $Serial)
    foreach ($l in $Lines) { Write-Host ('  ' + $l) }
    Write-Host ''
}
function Protokoll {
    param([string]$Result)
    try {
        $p = Join-Path $CfgDir 'logs\protokoll.csv'
        if (-not (Test-Path $p)) { Add-Content -Path $p -Value 'Zeit;Seriennr;Tenant;Tag;Ergebnis' -Encoding ASCII }
        Add-Content -Path $p -Value ('{0};{1};{2};{3};{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Serial, $cfg.Tenant, $cfg.GroupTag, $Result) -Encoding ASCII
    } catch { }
}
function Fail {
    param([string]$Msg)
    Log ('FEHLER: ' + $Msg)
    Protokoll ('FEHLER: ' + $Msg)
    Banner 'FEHLER  -  GERAET WURDE NICHT ZURUECKGESETZT' 'DarkRed' @(
        '',
        ('Grund: ' + $Msg),
        '',
        'Stick kann abgezogen werden. Geraet bleibt im OOBE.',
        'Nochmal: Stick rein, Shift+F10, D:\go',
        ('Log: ' + $LocalLog))
    Read-Host '  Enter = Fenster schliessen' | Out-Null
    exit 1
}
function Get-ErrText {
    param($Err)
    $m = $Err.Exception.Message
    if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) { $m = $Err.ErrorDetails.Message }
    return $m
}
function Test-Net {
    param([string]$TenantId)
    try {
        $r = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri ('https://login.microsoftonline.com/' + $TenantId + '/v2.0/.well-known/openid-configuration') -UseBasicParsing -TimeoutSec 8
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

try { $Host.UI.RawUI.WindowTitle = 'HUPilot v' + $Ver } catch { }
Clear-Host
Write-Host ''
Write-Host ('  HUPilot v' + $Ver) -ForegroundColor Cyan
Write-Host ''
Log ('===== START go.ps1 v' + $Ver + ' =====')

# ---------- 1. Config + Seriennummer ----------
$cfg = $null
try { $cfg = Get-Content (Join-Path $CfgDir 'config.json') -Raw | ConvertFrom-Json } catch { Fail ('config.json nicht lesbar: ' + $_.Exception.Message) }
foreach ($k in 'Tenant','TenantId','ClientId','ClientSecret','GroupTag','WlanSsid','WlanKey') {
    if (-not $cfg.$k) { Fail ('config.json: Feld ' + $k + ' fehlt') }
}
if ([string]$cfg.ClientSecret -match '^<.*>$' -or [string]$cfg.TenantId -match '^<.*>$') { Fail 'config.json: Platzhalter noch nicht ersetzt (TenantId / ClientSecret)' }
$TagPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
if ($cfg.TagPattern) { $TagPattern = [string]$cfg.TagPattern }
if ($cfg.GroupTag -notmatch $TagPattern) { Fail ('Group Tag ungueltig: ' + $cfg.GroupTag + ' (Muster ' + $TagPattern + ')') }

try { $Serial = ([string](Get-CimInstance Win32_BIOS).SerialNumber).Trim() } catch { }
if (-not $Serial) { Fail 'Seriennummer nicht lesbar' }
try {
    New-Item -ItemType Directory -Path (Join-Path $CfgDir 'logs') -Force | Out-Null
    $StickLog = Join-Path $CfgDir ('logs\{0}_{1}.log' -f $Serial, (Get-Date -Format 'yyyyMMdd_HHmm'))
} catch { $StickLog = $null }

function Read-KeyTimeout {
    param([int]$Seconds = 10)
    $until = (Get-Date).AddSeconds($Seconds)
    try {
        while ((Get-Date) -lt $until) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Enter') { return 'ENTER' }
                return ([string]$key.KeyChar).ToUpper()
            }
            Start-Sleep -Milliseconds 200
        }
    } catch { Log ('Tastatur-Abfrage: ' + $_.Exception.Message) }
    return ''
}

function Get-PowerInfo {
    # Win32_Battery.BatteryStatus: 2/3 = Netzteil, 6-9 = laedt; kein Akku = Netzbetrieb
    try { $b = @(Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { return @{ Ok = $true; Text = 'unbekannt' } }
    if (-not $b.Count) { return @{ Ok = $true; Text = 'kein Akku (Netzbetrieb)' } }
    $ac  = @($b | Where-Object { [int]$_.BatteryStatus -in 2, 3, 6, 7, 8, 9 }).Count -gt 0
    $pct = [int](($b | Measure-Object -Property EstimatedChargeRemaining -Average).Average)
    $txt = 'Akku ' + $pct + ' %' + $(if ($ac) { ', Netzteil' } else { ', OHNE Netzteil' })
    return @{ Ok = ($ac -or $pct -ge $MinBattery); Text = $txt }
}
function Wait-Power {
    $p = Get-PowerInfo
    Log ('Strom: ' + $p.Text)
    if ($p.Ok) { return }
    while (-not $p.Ok) {
        Banner 'NETZTEIL ANSTECKEN' 'DarkYellow' @(
            '',
            ('Strom: ' + $p.Text + '  (mind. ' + $MinBattery + ' % oder Netzteil)'),
            'Zuruecksetzen ohne Strom kann das Geraet unbrauchbar machen.',
            '',
            'Wartet automatisch, bis das Netzteil steckt.   J = trotzdem weiter')
        $k = Read-KeyTimeout 5
        if ($k -eq 'J' -or $k -eq 'Y') { Log ('Strom-Warnung uebergangen: ' + $p.Text); break }
        $p = Get-PowerInfo
    }
    Log ('Strom jetzt: ' + $p.Text)
    try { $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
}

# ---------- Tag-Auswahl (10 s, sonst Standard) ----------
$choices = @()
if ($cfg.TagChoices) { $choices = @($cfg.TagChoices) }
else { $y = (Get-Date).Year; $choices = @(($y - 5)..$y | ForEach-Object { 'SN-' + $_ }) }
if ($choices.Count -gt 9) { $choices = $choices[0..8] }
Write-Host '  Group Tag waehlen:' -ForegroundColor Cyan
Write-Host ('    [Enter]  ' + $cfg.GroupTag + '   (Standard)') -ForegroundColor White
for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host ('    [' + ($i + 1) + ']      ' + $choices[$i]) }
Write-Host '  Ohne Eingabe nach 10 s automatisch Standard ...'
$sel = Read-KeyTimeout 10
if ($sel -match '^[1-9]$' -and [int]$sel -le $choices.Count) { $cfg.GroupTag = $choices[[int]$sel - 1] }
if ($cfg.GroupTag -notmatch $TagPattern) { Fail ('Group Tag ungueltig: ' + $cfg.GroupTag + ' (Muster ' + $TagPattern + ')') }
Write-Host ''

# ---------- Zuruecksetzen ja/nein (10 s, sonst Standard aus config.json "Reset") ----------
$DoReset = $true
if ($null -ne $cfg.Reset) { $DoReset = [bool]$cfg.Reset }
Write-Host '  Nach dem Upload zuruecksetzen?' -ForegroundColor Cyan
if ($DoReset) { Write-Host '    [Enter]  JA, zuruecksetzen   (Standard)' -ForegroundColor White; Write-Host '    [N]      nein, nur hochladen' }
else          { Write-Host '    [Enter]  NEIN, nur hochladen (Standard)' -ForegroundColor White; Write-Host '    [J]      ja, zuruecksetzen' }
Write-Host '  Ohne Eingabe nach 10 s automatisch Standard ...'
$k = Read-KeyTimeout 10
if ($k -eq 'N') { $DoReset = $false } elseif ($k -eq 'J' -or $k -eq 'Y') { $DoReset = $true }
Write-Host ''

Say ('Seriennummer : ' + $Serial) 'White'
Say ('Tenant       : ' + $cfg.Tenant) 'White'
Say ('Group Tag    : ' + $cfg.GroupTag) 'White'
Say ('Zuruecksetzen: ' + $(if ($DoReset) { 'JA' } else { 'NEIN - nur Upload' })) 'White'

$os = Get-CimInstance Win32_OperatingSystem
Say ('Windows      : ' + $os.Caption + ' ' + $os.Version)
if ($os.Caption -notmatch 'Pro|Education|Enterprise') {
    Fail ('Edition "' + $os.Caption + '" - Zuruecksetzen per RemoteWipe nur mit Pro/Education/Enterprise')
}
if ($null -ne $cfg.MinBattery) { $MinBattery = [int]$cfg.MinBattery }

# ---------- Schutz: nur im Einrichtungsbildschirm (OOBE) ohne Benutzerdaten ----------
if ($DoReset) {
    $me = [Environment]::UserName
    $prof = @()
    try {
        $prof = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {
            -not $_.Special -and $_.LocalPath -match '\\Users\\' -and $_.LocalPath -notmatch '\\defaultuser\d*$' })
    } catch { Log ('Benutzerprofile pruefen: ' + $_.Exception.Message) }
    Log ('Benutzer: ' + $me + ' | Profile: ' + (($prof | ForEach-Object { $_.LocalPath }) -join ', '))
    if ($prof.Count -or $me -notmatch '^defaultuser\d*$') {
        Banner 'ACHTUNG  -  GERAET IST SCHON EINGERICHTET' 'DarkRed' @(
            '',
            'HUPilot ist fuer neue Geraete im Einrichtungsbildschirm gedacht.',
            ('Angemeldet als: ' + $me),
            ('Benutzerprofile: ' + $(if ($prof.Count) { ($prof | ForEach-Object { Split-Path $_.LocalPath -Leaf }) -join ', ' } else { 'keine' })),
            '',
            'Beim Zuruecksetzen gehen ALLE Daten auf dem Geraet verloren.',
            'Zum Fortfahren  LOESCHEN  eintippen, sonst nur Enter (Abbruch).')
        $a = Read-Host '  Eingabe'
        if ($a -cne 'LOESCHEN') { Log 'Abbruch: Geraet hat Benutzerdaten'; Protokoll 'ABBRUCH: Benutzerdaten vorhanden'; exit 1 }
        Log 'Benutzerdaten-Warnung mit LOESCHEN bestaetigt'
        try { $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
    }
    Wait-Power
    Say ('Strom        : ' + (Get-PowerInfo).Text)
}

if ($null -ne $cfg.WlanPackage) { $WlanPkgName = [string]$cfg.WlanPackage }
if ($WlanPkgName -and $DoReset) {
    $StickPkg = Join-Path $CfgDir $WlanPkgName
    if (-not (Test-Path $StickPkg)) { Fail ('WLAN-Paket fehlt am Stick: ' + $StickPkg + '  (ohne WLAN-Paket: "WlanPackage": "" in config.json)') }
}

# ---------- 2. Netz / WLAN ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host ''
Say 'Pruefe Internet ...'
if (-not (Test-Net $cfg.TenantId)) {
    Say ('Kein Internet - verbinde WLAN "' + $cfg.WlanSsid + '" ...') 'Yellow'
    $ssidX = [System.Security.SecurityElement]::Escape([string]$cfg.WlanSsid)
    $keyX  = [System.Security.SecurityElement]::Escape([string]$cfg.WlanKey)
    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssidX</name>
  <SSIDConfig><SSID><name>$ssidX</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$keyX</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
"@
    $xmlPath = 'C:\Windows\Temp\hu-wlan.xml'
    try {
        Set-Content -Path $xmlPath -Value $xml -Encoding UTF8
        $o = netsh wlan add profile filename="$xmlPath" user=all 2>&1
        Log ('netsh add profile: ' + (($o | Out-String).Trim()))
    } catch { Log ('WLAN-Profil Fehler: ' + $_.Exception.Message) }
    finally { Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue }

    $ok = $false
    for ($i = 0; $i -lt 12; $i++) {          # 12 x 10 s = 2 Min
        if ($i % 3 -eq 0) {
            try {
                $o = netsh wlan connect name="$($cfg.WlanSsid)" ssid="$($cfg.WlanSsid)" 2>&1
                Log ('netsh connect: ' + (($o | Out-String).Trim()))
            } catch { Log ('netsh connect: ' + $_.Exception.Message) }
        }
        Start-Sleep -Seconds 10
        Write-Host '.' -NoNewline
        if (Test-Net $cfg.TenantId) { $ok = $true; break }
    }
    Write-Host ''
    if (-not $ok) {
        $st = ''
        try { $st = ((netsh wlan show interfaces | Select-String 'SSID|Status|State|Signal') -join ' / ') } catch { }
        Log ('WLAN-Status: ' + $st)
        Fail 'Kein Internet nach 2 Min (WLAN-Reichweite/Kennwort/Firewall pruefen)'
    }
}
Say 'Internet OK' 'Green'

# ---------- 3a. Token ----------
$tok = $null
for ($i = 1; $i -le 3 -and -not $tok; $i++) {
    try {
        $body = @{ grant_type = 'client_credentials'; client_id = $cfg.ClientId; client_secret = $cfg.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        $tok = (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $cfg.TenantId + '/oauth2/v2.0/token') -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
    } catch {
        $m = Get-ErrText $_
        Log ('Token-Versuch ' + $i + ': ' + $m)
        if ($m -match 'AADSTS7000222') { Fail 'Secret ABGELAUFEN - neues Secret in config.json eintragen' }
        if ($m -match 'AADSTS7000215') { Fail 'Secret FALSCH (Secret-ID statt Wert?)' }
        Start-Sleep -Seconds 5
    }
}
if (-not $tok) { Fail 'Anmeldung am Tenant fehlgeschlagen (siehe Log)' }
$h  = @{ Authorization = 'Bearer ' + $tok }
$hj = @{ Authorization = 'Bearer ' + $tok; 'Content-Type' = 'application/json' }
Say 'Anmeldung Tenant OK' 'Green'

# ---------- 3b. Hash ----------
$hash = $null
try {
    $dd = Get-CimInstance -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    $hash = $dd.DeviceHardwareData
} catch { Log ('Hash-Fehler: ' + $_.Exception.Message) }
if (-not $hash) { Fail 'Hardware-Hash nicht lesbar' }
Say ('Hash gelesen (' + $hash.Length + ' Zeichen)') 'Green'

# ---------- 3c. Autopilot ----------
function Get-ApDevice {
    try {
        $f = [uri]::EscapeDataString("contains(serialNumber,'" + $Serial + "')")
        $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities?$filter=' + $f) -Headers $h
        return @($r.value | Where-Object { $_.serialNumber -eq $Serial })[0]
    } catch { Log ('Autopilot-Abfrage: ' + (Get-ErrText $_)); return $null }
}
function Get-ApProfile {
    param([string]$Id)
    try {
        $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $Id + '?$expand=deploymentProfile') -Headers $h
        return $r.deploymentProfile
    } catch { Log ('Profil-Abfrage: ' + (Get-ErrText $_)); return $null }
}

$TagChanged = $false
$TagChangedAt = $null
$OldProfId = ''

$ap = Get-ApDevice
if ($ap) {
    Say ('Bereits in Autopilot (Tag "' + $ap.groupTag + '")') 'Yellow'
    if ([string]$ap.groupTag -ne [string]$cfg.GroupTag) {
        $op = Get-ApProfile $ap.id
        if ($op) { $OldProfId = [string]$op.id; Log ('Bisheriges Profil: ' + $op.displayName) }
        try {
            Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $ap.id + '/updateDeviceProperties') -Headers $hj -Body (@{ groupTag = $cfg.GroupTag } | ConvertTo-Json) | Out-Null
            Say ('Tag geaendert -> ' + $cfg.GroupTag) 'Green'
            $TagChanged = $true
            $TagChangedAt = Get-Date
        } catch { Fail ('Tag setzen fehlgeschlagen: ' + (Get-ErrText $_)) }
    }
}
else {
    Say 'Importiere in Autopilot ...'
    $imp = $null
    try {
        $body = @{
            '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
            serialNumber       = $Serial
            productKey         = ''
            groupTag           = $cfg.GroupTag
            hardwareIdentifier = $hash
            state              = @{
                '@odata.type'        = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'
                deviceImportStatus   = 'pending'
                deviceRegistrationId = ''
                deviceErrorCode      = 0
                deviceErrorName      = ''
            }
        } | ConvertTo-Json -Depth 4
        $imp = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities') -Headers $hj -Body $body
        Log ('Import gesendet, id ' + $imp.id)
    } catch { Fail ('Import abgelehnt: ' + (Get-ErrText $_)) }

    $state = ''
    $limit = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $limit) {
        Start-Sleep -Seconds 10
        Write-Host '.' -NoNewline
        try {
            $st = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities/' + $imp.id) -Headers $h
            $state = [string]$st.state.deviceImportStatus
            if ($state -eq 'complete') { break }
            if ($state -eq 'error') { break }
        } catch { Log ('Import-Status: ' + (Get-ErrText $_)) }
    }
    Write-Host ''
    if ($state -eq 'error') {
        $en = [string]$st.state.deviceErrorName; $ec = [string]$st.state.deviceErrorCode
        try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities/' + $imp.id) -Headers $h | Out-Null } catch { }
        if ($ec -eq '808' -or $en -match 'OtherTenant') { Fail ('Geraet ist in einem ANDEREN Tenant registriert (' + $en + ' ' + $ec + ')') }
        Fail ('Import-Fehler: ' + $en + ' (' + $ec + ')')
    }
    if ($state -ne 'complete') { Fail ('Import nach 10 Min nicht fertig (Status: ' + $state + ')') }
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities/' + $imp.id) -Headers $h | Out-Null } catch { }
    Say 'Import abgeschlossen' 'Green'
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/windowsAutopilotSettings/sync') -Headers $h | Out-Null; Log 'Autopilot-Sync angestossen' } catch { Log ('Sync: ' + (Get-ErrText $_)) }
}

# ---------- 4. WLAN-Paket lokal kopieren ----------
if ($StickPkg) {
    try {
        Copy-Item -Path $StickPkg -Destination $TmpPkg -Force
        if ((Get-Item $TmpPkg).Length -ne (Get-Item $StickPkg).Length) { throw 'Groesse stimmt nicht' }
    } catch { Fail ('WLAN-Paket kopieren: ' + $_.Exception.Message) }
    Log 'WLAN-Paket lokal kopiert'
}
Protokoll $(if ($DoReset) { 'UPLOAD OK' } else { 'UPLOAD OK (ohne Zuruecksetzen)' })
Log '--- Stick wird ab jetzt nicht mehr gebraucht ---'
$StickLog = $null

if (-not $DoReset) {
    Log 'Nur Upload gewaehlt - kein Zuruecksetzen'
    Banner 'OK  -  HOCHGELADEN  -  STICK ABZIEHEN' 'DarkGreen' @(
        '',
        ('Group Tag: ' + $cfg.GroupTag),
        'Geraet wurde NICHT zurueckgesetzt.',
        'Fuer Autopilot: Geraet spaeter zuruecksetzen (Einstellungen > System >',
        'Wiederherstellung) oder per Intune "Zuruecksetzen".')
    Read-Host '  Enter = Fenster schliessen' | Out-Null
    exit 0
}

Banner 'OK  -  STICK ABZIEHEN  -  naechstes Geraet' 'DarkGreen' @(
    '',
    'Geraet NICHT ausschalten. Es wartet jetzt auf das',
    'Autopilot-Profil und setzt sich dann selbst zurueck.')

# ---------- 5. Auf Profil warten ----------
$assigned = $false
$limit = (Get-Date).AddMinutes($ProfileWaitMin)
while ((Get-Date) -lt $limit) {
    $ap = Get-ApDevice
    $ps = ''
    $pn = ''
    $pi = ''
    if ($ap) {
        $ps = [string]$ap.deploymentProfileAssignmentStatus
        if ($ps -like 'assigned*') {
            $pr = Get-ApProfile $ap.id
            if ($pr) { $pn = [string]$pr.displayName; $pi = [string]$pr.id }
        }
    }
    $txt = $(if ($ps) { $ps } else { 'noch nicht sichtbar' })
    if ($pn) { $txt = $txt + '  (' + $pn + ')' }
    Write-Host ('  {0}  Profil: {1}' -f (Get-Date -Format 'HH:mm:ss'), $txt)
    Log ('Profilstatus: ' + $txt)
    if ($ps -like 'assigned*') {
        if (-not $TagChanged) { $assigned = $true; break }
        if ($OldProfId -and $pi -and $pi -ne $OldProfId) { Log 'Neues Profil nach Tag-Aenderung zugewiesen'; $assigned = $true; break }
        if (-not $OldProfId -and $pi) { $assigned = $true; break }
        if (((Get-Date) - $TagChangedAt).TotalMinutes -ge 10) { Log 'Profil nach 10 Min unveraendert - wird akzeptiert (evtl. gleiches Profil fuer beide Tags)'; $assigned = $true; break }
        Write-Host '            (Tag geaendert - warte auf Profil der neuen Gruppe)'
    }
    Start-Sleep -Seconds 30
}

if (-not $assigned) {
    Log 'Profil nach Wartezeit NICHT zugewiesen'
    Banner 'ACHTUNG  -  Autopilot-Profil noch nicht zugewiesen' 'DarkYellow' @(
        '',
        'Ohne Profil kommt nach dem Reset das normale Windows-Setup.',
        '',
        'J = trotzdem zuruecksetzen     N = abbrechen (kein Reset)')
    $a = Read-Host '  J / N'
    if ($a -notmatch '^[jJyY]') { Log 'Abbruch durch Benutzer (kein Reset)'; exit 1 }
}

# ---------- 6. WLAN-Paket + Zuruecksetzen ohne Hersteller-Anpassungen ----------
Wait-Power
$ErrorActionPreference = 'Continue'
function Fail-Reset {
    param([string]$Msg)
    Log ('FEHLER Zuruecksetzen: ' + $Msg)
    Banner 'FEHLER beim Zuruecksetzen' 'DarkRed' @(
        '',
        'Autopilot-Upload ist OK, nur das Zuruecksetzen ist nicht gestartet.',
        ('Grund: ' + $Msg),
        ('Log: ' + $LocalLog + ' und ' + $WipeLog),
        'Nochmal: Stick rein, Shift+F10, D:\go  (Upload wird uebersprungen)')
    Read-Host '  Enter = Fenster schliessen' | Out-Null
    exit 1
}

# 6a. WLAN-Paket anwenden (nur WLAN - wird beim Zuruecksetzen gesichert und danach wieder angewendet)
$SysPkg = ''
if ($StickPkg) {
    $persist = Join-Path $env:ProgramData ('Microsoft\Provisioning\' + $WlanPkgName)
    $same = $false
    if (Test-Path $persist) {
        try { $same = ((Get-FileHash -Path $persist -Algorithm SHA256).Hash -eq (Get-FileHash -Path $TmpPkg -Algorithm SHA256).Hash) } catch { Log ('Hash-Vergleich: ' + $_.Exception.Message) }
    }
    if ($same) { Log 'WLAN-Paket ist bereits installiert (identisch) - provtool uebersprungen' }
    else {
        $prov = Join-Path $env:SystemRoot 'System32\provtool.exe'
        if (-not (Test-Path $prov)) { Fail-Reset 'provtool.exe nicht gefunden' }
        Log ('provtool.exe ' + $TmpPkg + ' /quiet')
        $pr = Start-Process -FilePath $prov -ArgumentList ('"' + $TmpPkg + '"', '/quiet') -Wait -PassThru -WindowStyle Hidden
        Log ('provtool Exitcode: ' + $pr.ExitCode)
        if ($pr.ExitCode -ne 0) { Log 'provtool fehlgeschlagen - neuer Versuch als SYSTEM im Hilfsscript'; $SysPkg = $TmpPkg }
        elseif (-not (Test-Path $persist)) { Log ('Hinweis: ' + $persist + ' nicht gefunden - WLAN nach dem Zuruecksetzen evtl. von Hand') }
        else { Log 'WLAN-Paket in ProgramData\Provisioning gespeichert' }
    }
}

# 6b. Hilfsscript fuer SYSTEM schreiben (WMI-Bridge braucht LocalSystem - MS Doku)
$wipe = @'
$log = 'C:\Windows\Temp\HUPilot-Wipe.log'
$res = 'C:\Windows\Temp\HUPilot-Wipe.result'
function L([string]$m) { try { Add-Content -Path $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding ASCII } catch { } }
L ('Start als ' + [Environment]::UserName)
# 0. WLAN-Paket als SYSTEM installieren (nur wenn es als Benutzer nicht ging)
$pkg = '__SYSPKG__'
if ($pkg) {
    $persist = Join-Path $env:ProgramData ('Microsoft\Provisioning\' + (Split-Path $pkg -Leaf))
    if (Test-Path $persist) {
        try { Import-Module Provisioning -ErrorAction Stop; Remove-ProvisioningPackage -Path $persist -ErrorAction Stop | Out-Null; L 'altes WLAN-Paket entfernt' } catch { L ('altes WLAN-Paket entfernen: ' + $_.Exception.Message) }
    }
    $pr = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\provtool.exe') -ArgumentList ('"' + $pkg + '"', '/quiet') -Wait -PassThru -WindowStyle Hidden
    L ('provtool als SYSTEM Exitcode: ' + $pr.ExitCode)
    $ok = $false
    if (Test-Path $persist) { try { $ok = ((Get-FileHash -Path $persist -Algorithm SHA256).Hash -eq (Get-FileHash -Path $pkg -Algorithm SHA256).Hash) } catch { } }
    if (-not $ok) { L 'FEHLER: WLAN-Paket nicht installiert - kein Zuruecksetzen'; Set-Content -Path $res -Value ('ERR WLAN-Paket auch als SYSTEM nicht installiert (provtool ' + $pr.ExitCode + ')') -Encoding ASCII; exit 1 }
    L 'WLAN-Paket als SYSTEM installiert'
}
# 1. Persistierte Pakete mit CleanPC entfernen (wuerden nach dem Zuruecksetzen erneut zuruecksetzen)
try {
    Import-Module Provisioning -ErrorAction Stop
    $dir = Join-Path $env:ProgramData 'Microsoft\Provisioning'
    foreach ($p in @(Get-ChildItem -Path $dir -Filter *.ppkg -ErrorAction SilentlyContinue)) {
        $tmp = Join-Path $env:TEMP ('hupx_' + [guid]::NewGuid().ToString('N'))
        try {
            Export-ProvisioningPackage -Path $p.FullName -OutputFolder $tmp -AnswerFileOnly -Overwrite -ErrorAction Stop | Out-Null
            $hit = @(Get-ChildItem -Path $tmp -Recurse -File | Select-String -Pattern 'CleanPCWithoutRetainingUserData|CleanPCRetainingUserData' -List)
            if ($hit.Count) { Remove-ProvisioningPackage -Path $p.FullName -ErrorAction Stop | Out-Null; L ('Paket mit CleanPC entfernt: ' + $p.Name) }
            else { L ('Paket bleibt: ' + $p.Name) }
        } catch { L ('Paket pruefen ' + $p.Name + ': ' + $_.Exception.Message) }
        finally { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
} catch { L ('Provisioning-Modul: ' + $_.Exception.Message) }
# 2. Hersteller-Anpassungen wegschieben (Zuruecksetzen spielt C:\Recovery\Customizations sonst wieder ein)
try {
    $bak = 'C:\Recovery\HUPilot-OEM-Backup'
    foreach ($src in 'C:\Recovery\Customizations', 'C:\Recovery\AutoApply') {
        if (Test-Path $src) {
            $dst = Join-Path $bak (Split-Path $src -Leaf)
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            foreach ($f in @(Get-ChildItem -Path $src -Force)) { Move-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction Stop; L ('verschoben: ' + $f.FullName) }
        }
    }
} catch { L ('FEHLER verschieben: ' + $_.Exception.Message); Set-Content -Path $res -Value ('ERR verschieben: ' + $_.Exception.Message) -Encoding ASCII; exit 1 }
# 3. Zuruecksetzen ("Alles entfernen"), Provisioning-Pakete bleiben erhalten
try {
    $ns = 'root\cimv2\mdm\dmmap'
    $session = New-CimSession
    $params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
    $param = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param', '', 'String', 'In')
    $params.Add($param)
    $inst = Get-CimInstance -Namespace $ns -ClassName 'MDM_RemoteWipe' -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" -ErrorAction Stop
    $r = $session.InvokeMethod($ns, $inst, 'doWipePersistProvisionedDataMethod', $params)
    $rv = [string]$r.ReturnValue.Value
    L ('doWipePersistProvisionedDataMethod ReturnValue: ' + $rv)
    Set-Content -Path $res -Value ('OK ' + $rv) -Encoding ASCII
} catch { L ('FEHLER Wipe: ' + $_.Exception.Message); Set-Content -Path $res -Value ('ERR Wipe: ' + $_.Exception.Message) -Encoding ASCII; exit 1 }
'@
try {
    Remove-Item -Path $WipeResult -Force -ErrorAction SilentlyContinue
    Set-Content -Path $WipePs1 -Value ($wipe.Replace('__SYSPKG__', $SysPkg)) -Encoding ASCII -ErrorAction Stop
} catch { Fail-Reset ('Hilfsscript schreiben: ' + $_.Exception.Message) }

Banner 'ZURUECKSETZEN STARTET' 'DarkBlue' @(
    '',
    'Hersteller-Anpassungen werden entfernt, dann setzt sich das Geraet zurueck.',
    'Danach kommt das Schul-Anmeldefenster (Autopilot).')

# 6c. Als SYSTEM starten (geplante Aufgabe) und auf Ergebnis warten
$tn = 'HUPilot-Wipe'
$tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $WipePs1
$o = & schtasks.exe /Create /TN $tn /RU SYSTEM /SC ONCE /ST 23:59 /RL HIGHEST /TR $tr /F 2>&1
Log ('schtasks create: ' + (($o | Out-String).Trim()))
$o = & schtasks.exe /Run /TN $tn 2>&1
Log ('schtasks run: ' + (($o | Out-String).Trim()))
$res = ''
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 3
    if (Test-Path $WipeResult) { $res = ([string](Get-Content -Path $WipeResult -Raw)).Trim(); break }
}
try { Get-Content -Path $WipeLog -ErrorAction Stop | ForEach-Object { Log ('[SYSTEM] ' + $_) } } catch { }
if (-not $res) { Fail-Reset 'keine Rueckmeldung vom SYSTEM-Script (3 Min)' }
if ($res -notlike 'OK*') { Fail-Reset $res }
Log ('Zuruecksetzen angenommen: ' + $res)
Write-Host ''
Write-Host '  Zuruecksetzen angenommen - Neustart folgt in Kuerze.' -ForegroundColor White
Start-Sleep -Seconds 900
