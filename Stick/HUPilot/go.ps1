# =====================================================================
# HUPilot  go.ps1  (Version: HUPilot\Config\version.json)
# https://github.com/ChiliApple/HUPilot
# ZIELMASCHINE: neues Windows-Geraet im OOBE (Shift+F10 -> D:\go)
# Ablauf:
#   1. config.json vom Stick lesen, Group Tag waehlen, Edition pruefen
#   2. WLAN verbinden (falls noch kein Internet)
#   3. Hardware-Hash -> Autopilot-Import mit Group Tag (oder Tag setzen)
#   4. WLAN-Paket lokal kopieren -> GRUEN "STICK ABZIEHEN"
#   5. Warten bis Autopilot-Profil zugewiesen
#   5b. "nur hochladen": WLAN-Paket installieren, im OOBE nach Profilzuweisung neu starten (shutdown /r /f)
#   6. WLAN-Paket anwenden (bleibt ueber das Zuruecksetzen erhalten),
#      Hersteller-Anpassungen (C:\Recovery\Customizations) wegschieben,
#      Zuruecksetzen per RemoteWipe doWipePersistProvisionedData (als SYSTEM)
#   KEIN CleanPC-Paket: es bleibt in ProgramData\Provisioning und loest nach
#   jedem Zuruecksetzen erneut aus (Schleife, Test 05.10.2026)
# Jeder Fehler VOR Schritt 6 -> ROT, KEIN Zuruecksetzen, Geraet bleibt im OOBE.
# Log: C:\Windows\Temp\HUPilot.log + Stick:\HUPilot\logs\
# =====================================================================

$ErrorActionPreference = 'Stop'
$Ver        = '2.7.8'   # Rueckfall - massgeblich ist HUPilot\Config\version.json
try { $vj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Config\version.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ("$($vj.version)".Trim()) { $Ver = "$($vj.version)".Trim() } } catch { }
# Update dieses Sticks wurde abgebrochen (Mischstand moeglich) -> nicht starten
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Config\pull-journal.json')) {
    Write-Host ''
    Write-Host '  HUPilot: Das letzte Update dieses Sticks wurde abgebrochen.' -ForegroundColor Red
    Write-Host '  Stick am PC anstecken und HUPilot-Setup.cmd starten - es stellt den Stand wieder her.' -ForegroundColor Red
    exit 1
}
# Ohne Administratorrechte (z. B. go.cmd per Doppelklick im Explorer) ist der Hardware-Hash nicht lesbar
#   -> mit Adminrechten in neuem Fenster neu starten (UAC); im Einrichtungsbildschirm (Shift+F10) sind die Rechte immer da
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  HUPilot braucht Administratorrechte.' -ForegroundColor Yellow
    Write-Host '  Starte neu mit Adminrechten (Windows fragt nach einem Admin-Konto) ...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"') -ErrorAction Stop
        Write-Host '  Weiter im neuen Fenster.' -ForegroundColor Green
        Start-Sleep -Seconds 3
    } catch {
        Write-Host '  Abgebrochen. Eingabeaufforderung mit Rechtsklick > "Als Administrator ausführen" öffnen, dann:  D:  und  go' -ForegroundColor Red
        try { Read-Host '  Enter = Fenster schließen' | Out-Null } catch { }
    }
    exit 1
}
# Arbeitsverzeichnis weg vom Stick: go wird meist aus D:\ gestartet. Wird der Stick nach "STICK ABZIEHEN" gezogen,
# ist das Arbeitsverzeichnis ungueltig - jeder spaetere Programmaufruf (schtasks, cmd, provtool) scheitert dann mit
# "Der Verzeichnisname ist ungueltig" (PF3T9PAN 19.10.2026; vermutlich auch MP24CF66 13.10.2026: schtasks ohne Ausgabe)
try { Set-Location -LiteralPath (Join-Path $env:SystemRoot 'System32'); [Environment]::CurrentDirectory = (Join-Path $env:SystemRoot 'System32') } catch { }
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
$ProfileWaitMin = 20
$GB = 'https://graph.microsoft.com/beta'

# ---------- Live-Anzeige beim Warten: EINE Zeile, die sich jede Sekunde selbst aktualisiert ----------
# Zeit laeuft mit, Countdown bis zur naechsten Abfrage, drehendes Zeichen = Programm lebt.
# Aendert sich der Status, bleibt die alte Zeile stehen (Verlauf) und eine neue beginnt.
$script:LiveOn = $false
$script:SpinI = 0
function Format-Dauer {
    param([double]$Sec)
    $s = [int][math]::Max(0, [math]::Floor($Sec))
    return ('{0}:{1:00}' -f [int][math]::Floor($s / 60), ($s % 60))
}
function Show-Live {
    param([string]$Text)
    $c = '|/-\'[$script:SpinI % 4]
    $script:SpinI++
    $line = '  ' + $Text + '   ' + $c
    try {
        $w = [Console]::WindowWidth - 1
        if ($line.Length -gt $w) { $line = $line.Substring(0, $w) }
        Write-Host ("`r" + $line.PadRight($w)) -NoNewline
    } catch { Write-Host ("`r" + $line) -NoNewline }
    $script:LiveOn = $true
}
function Complete-Live {
    if ($script:LiveOn) { Write-Host ''; $script:LiveOn = $false }
}
function Wait-Live {
    # wartet $Seconds; Anzeige: Text | gelaufen / hoechstens | <Next> in x s
    param([int]$Seconds, [string]$Text, [datetime]$Since = (Get-Date), [int]$MaxSec = 0, [string]$Next = 'nächste Abfrage')
    $end = (Get-Date).AddSeconds($Seconds)
    do {
        $now = Get-Date
        $el = Format-Dauer ($now - $Since).TotalSeconds
        $mx = $(if ($MaxSec -gt 0) { ' / ' + (Format-Dauer $MaxSec) } else { '' })
        $cd = $(if ($Next) { [string][int][math]::Max(0, [math]::Ceiling(($end - $now).TotalSeconds)) + ' s' } else { '' })
        $l = $Text + '  |  ' + $el + $mx + $(if ($cd) { '  |  ' + $Next + ' in ' + $cd } else { '' })
        # schmales Fenster (grosse Schrift): kuerzer, damit Zeit und Countdown sichtbar bleiben
        $w = 120; try { $w = [Console]::WindowWidth - 6 } catch { }
        if ($l.Length -gt $w) { $l = $Text + ' | ' + $el + $(if ($cd) { ' | ' + $cd } else { '' }) }
        Show-Live $l
        $ms = [int][math]::Min(1000, [math]::Max(0, ($end - (Get-Date)).TotalMilliseconds))
        if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
    } while ((Get-Date) -lt $end)
}

function Read-KeyTimeout {
    # Tastendruck mit Zeitlimit; zeigt live "<Label> in x s"
    param([int]$Seconds = 10, [string]$Label = 'ohne Eingabe weiter')
    $until = (Get-Date).AddSeconds($Seconds)
    $res = ''
    try {
        while ((Get-Date) -lt $until) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Enter') { $res = 'ENTER' } else { $res = ([string]$key.KeyChar).ToUpper() }
                break
            }
            if ($Label) { Show-Live ($Label + ' in ' + [int][math]::Ceiling(($until - (Get-Date)).TotalSeconds) + ' s') }
            Start-Sleep -Milliseconds 200
        }
    } catch { Log ('Tastatur-Abfrage: ' + $_.Exception.Message) }
    Complete-Live
    return $res
}

function Log {
    param([string]$Msg)
    $line = '{0}  [{1,5:N0}s]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ((Get-Date) - $Start).TotalSeconds, $Msg
    try { Add-Content -Path $LocalLog -Value $line -Encoding UTF8 } catch { }
    if ($StickLog) { try { Add-Content -Path $StickLog -Value $line -Encoding UTF8 } catch { } }
}
function Say {
    param([string]$Msg, [string]$Color = 'Gray')
    Complete-Live
    Write-Host ('  ' + $Msg) -ForegroundColor $Color
    Log $Msg
}
function Banner {
    param([string]$Text, [string]$Bg, [string[]]$Lines)
    Complete-Live
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
    # protokoll.csv bleibt ASCII (Setup liest sie so) - Umlaute umschreiben
    $Result = $Result.Replace([string][char]0xE4, 'ae').Replace([string][char]0xF6, 'oe').Replace([string][char]0xFC, 'ue').Replace([string][char]0xC4, 'Ae').Replace([string][char]0xD6, 'Oe').Replace([string][char]0xDC, 'Ue').Replace([string][char]0xDF, 'ss')
    try {
        $p = Join-Path $CfgDir 'logs\protokoll.csv'
        if (-not (Test-Path $p)) { Add-Content -Path $p -Value 'Zeit;Seriennr;Tenant;Tag;Ergebnis' -Encoding ASCII }
        Add-Content -Path $p -Value ('{0};{1};{2};{3};{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Serial, $cfg.Tenant, ([string]$cfg.GroupTag -replace ';', ','), $Result) -Encoding ASCII
    } catch { }
}
function Fail {
    param([string]$Msg)
    Log ('FEHLER: ' + $Msg)
    Protokoll ('FEHLER: ' + $Msg)
    Banner 'FEHLER  -  NICHT ZURÜCKGESETZT' 'DarkRed' @(
        '',
        ('Grund: ' + $Msg),
        '',
        'Nochmal versuchen: D:\go',
        'Klappt es wieder nicht: Foto von diesem Bild an den Admin.',
        ('Log: ' + $LocalLog))
    Read-Host '  Enter = Fenster schließen' | Out-Null
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
        if ($r.StatusCode -eq 200) { return $true }
        Log ('Internet-Test: HTTP ' + $r.StatusCode)
        return $false
    } catch { Log ('Internet-Test: ' + $_.Exception.Message); return $false }
}
# Steckt ein LAN-Kabel (physischer Ethernet-Adapter mit Verbindung)? Get-NetAdapter, Rueckfall .NET.
function Test-LanLink {
    try {
        $a = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' })
        if ($a.Count) { return [string]$a[0].InterfaceDescription }
        return ''
    } catch { }
    try {
        foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.NetworkInterfaceType -eq 'Ethernet' -and $n.OperationalStatus -eq 'Up' -and $n.Description -notmatch 'Virtual|Hyper-V|VPN|Loopback|Bluetooth') { return [string]$n.Description }
        }
    } catch { }
    return ''
}

$script:ClockOk = $false
function Sync-Clock {
    # Uhr per HTTP-Date-Header stellen (ohne TLS/NTP - eine falsche Uhr laesst Token/TLS scheitern)
    if ($script:ClockOk) { return }
    try {
        $r = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5
        $d = [string]$r.Headers['Date']
        if (-not $d) { return }
        $srv = [DateTimeOffset]::Parse($d, [Globalization.CultureInfo]::InvariantCulture)
        $diff = [int]([DateTimeOffset]::UtcNow - $srv).TotalSeconds
        $script:ClockOk = $true
        if ([Math]::Abs($diff) -gt 120) {
            Set-Date -Date $srv.LocalDateTime | Out-Null
            Log ('Uhr korrigiert um ' + (-$diff) + ' s (war ' + $diff + ' s daneben)')
        } else { Log ('Uhr OK (Abweichung ' + $diff + ' s)') }
    } catch { Log ('Uhrzeit-Prüfung: ' + $_.Exception.Message) }
}

$OfflineHdr = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
function Save-Offline {
    # Hash fuer spaeteren Upload am Stick speichern (Format wie Microsoft-CSV, ANSI, ohne Anfuehrungszeichen)
    param([string]$Why)
    Log ('OFFLINE: ' + $Why)
    try {
        $f = Join-Path $CfgDir 'logs\hashes.csv'
        $rows = @()
        if (Test-Path $f) { $rows = @(Get-Content -Path $f | Where-Object { $_ -and $_ -ne $OfflineHdr -and -not $_.StartsWith($Serial + ',') }) }
        $rows += ($Serial + ',,' + $hash + ',' + $cfg.GroupTag + ',' + $AssignUpn)
        Set-Content -Path $f -Value (@($OfflineHdr) + $rows) -Encoding ASCII -ErrorAction Stop
        Protokoll ('OFFLINE: Hash gespeichert (' + $Why + ')')
    } catch { Fail ($Why + '  (Hash konnte auch nicht am Stick gespeichert werden: ' + $_.Exception.Message + ')') }
    Banner 'HASH GESPEICHERT  -  SPÄTER HOCHLADEN' 'DarkYellow' @(
        '',
        ('Grund: ' + $Why),
        '',
        ('Hash + Tag ' + $cfg.GroupTag + ' liegen am Stick: HUPilot\logs\hashes.csv'),
        'Am PC: HUPilot-Setup > "Hashes importieren".',
        'Gerät wurde NICHT zurückgesetzt - Stick kann abgezogen werden.')
    Read-Host '  Enter = Fenster schließen' | Out-Null
    exit 2
}

$AssignUpn = ''
try { $Host.UI.RawUI.WindowTitle = 'HUPilot v' + $Ver } catch { }
# Schrift etwas groesser (Konsole, auch im OOBE) - Fehler egal
try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HuFont {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CFI { public uint cbSize; public uint nFont; public short X; public short Y; public int Family; public int Weight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Face; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref CFI f);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref CFI f);
    public static string AtLeast(short height) {
        IntPtr h = GetStdHandle(-11);
        CFI f = new CFI(); f.cbSize = (uint)Marshal.SizeOf(typeof(CFI));
        if (!GetCurrentConsoleFontEx(h, false, ref f)) return "get " + Marshal.GetLastWin32Error();
        short old = f.Y;
        if (f.Y >= height) return f.Face + " " + old + " (bleibt)";
        f.Y = height; f.X = 0;
        if (!SetCurrentConsoleFontEx(h, false, ref f)) return "set " + Marshal.GetLastWin32Error();
        return f.Face + " " + old + " -> " + f.Y;
    }
}
'@
    $FontInfo = [HuFont]::AtLeast(20)   # Standard ist meist 16 - mind. 20 (wiederholter Start vergroessert nicht weiter)
} catch { $FontInfo = $_.Exception.Message }
Log ('Schrift: ' + $FontInfo)
# Farben zuruecksetzen (nach einem frueheren Lauf im selben Fenster bleibt sonst gruen/gelb/rot stehen)
try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray' } catch { }
Clear-Host
Write-Host ''
Write-Host ('  HUPilot v' + $Ver) -ForegroundColor Cyan
Write-Host ''
Log ('===== START go.ps1 v' + $Ver + ' =====')

# ---------- 1. Config + Seriennummer ----------
$cfg = $null
try { $cfg = Get-Content (Join-Path $CfgDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Fail ('config.json nicht lesbar: ' + $_.Exception.Message) }
foreach ($k in 'Tenant','TenantId','ClientId','ClientSecret','GroupTag','WlanSsid','WlanKey') {
    if (-not $cfg.$k) { Fail ('config.json: Feld ' + $k + ' fehlt') }
}
if ([string]$cfg.ClientSecret -match '^<.*>$' -or [string]$cfg.TenantId -match '^<.*>$') { Fail 'config.json: Platzhalter noch nicht ersetzt (TenantId / ClientSecret)' }
$TagPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
if ($cfg.TagPattern) { $TagPattern = [string]$cfg.TagPattern }
if ($cfg.GroupTag -notmatch $TagPattern) { Fail ('Group Tag ungültig: ' + $cfg.GroupTag + ' (Muster ' + $TagPattern + ')') }

try { $Serial = ([string](Get-CimInstance Win32_BIOS).SerialNumber).Trim() } catch { }
if (-not $Serial) { Fail 'Seriennummer nicht lesbar' }
try {
    New-Item -ItemType Directory -Path (Join-Path $CfgDir 'logs') -Force | Out-Null
    $StickLog = Join-Path $CfgDir ('logs\{0}_{1}.log' -f $Serial, (Get-Date -Format 'yyyyMMdd_HHmm'))
} catch { $StickLog = $null }

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
    Banner 'NETZTEIL ANSTECKEN' 'DarkYellow' @(
        '',
        ('Mindestens ' + $MinBattery + ' % Akku oder Netzteil.'),
        'Zurücksetzen ohne Strom kann das Gerät unbrauchbar machen.',
        '',
        'Wartet, bis das Netzteil steckt.   J = trotzdem weiter')
    while (-not $p.Ok) {
        $k = Read-KeyTimeout 5 ('Strom: ' + $p.Text + '  |  nächste Prüfung')
        if ($k -eq 'J' -or $k -eq 'Y') { Log ('Strom-Warnung übergangen: ' + $p.Text); break }
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
Write-Host '  Group Tag wählen:' -ForegroundColor Cyan
Write-Host ('    [Enter]  ' + $cfg.GroupTag + '   (Standard)') -ForegroundColor White
for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host ('    [' + ($i + 1) + ']      ' + $choices[$i]) }
$sel = Read-KeyTimeout 10 ('ohne Eingabe: ' + $cfg.GroupTag)
if ($sel -match '^[1-9]$' -and [int]$sel -le $choices.Count) { $cfg.GroupTag = $choices[[int]$sel - 1] }
if ($cfg.GroupTag -notmatch $TagPattern) { Fail ('Group Tag ungültig: ' + $cfg.GroupTag + ' (Muster ' + $TagPattern + ')') }
Write-Host ''

# ---------- Optional: Benutzer vorab zuweisen (config "AskUser": true) ----------
if ($cfg.AskUser -eq $true) {
    Write-Host '  Benutzer vorab zuweisen? Anmeldename (UPN) eintippen, Enter = keiner' -ForegroundColor Cyan
    while ($true) {
        $u = ([string](Read-Host '  UPN')).Trim()
        if (-not $u) { break }
        if ($u -match '^[^@\s,]+@[^@\s,]+\.[^@\s,]+$') { $AssignUpn = $u; break }
        Write-Host '  Ungültig - Form name@schule.at' -ForegroundColor Yellow
    }
    Write-Host ''
}

# ---------- Zuruecksetzen ja/nein (10 s, sonst Standard aus config.json "Reset") ----------
$DoReset = $true
if ($null -ne $cfg.Reset) { $DoReset = [bool]$cfg.Reset }
Write-Host '  Nach dem Upload zurücksetzen?' -ForegroundColor Cyan
if ($DoReset) { Write-Host '    [Enter]  JA, zurücksetzen   (Standard)' -ForegroundColor White; Write-Host '    [N]      nein, nur hochladen' }
else          { Write-Host '    [Enter]  NEIN, nur hochladen (Standard)' -ForegroundColor White; Write-Host '    [J]      ja, zurücksetzen' }
$k = Read-KeyTimeout 10 ('ohne Eingabe: ' + $(if ($DoReset) { 'zurücksetzen' } else { 'nur hochladen' }))
if ($k -eq 'N') { $DoReset = $false } elseif ($k -eq 'J' -or $k -eq 'Y') { $DoReset = $true }
Write-Host ''

Say ('Seriennummer : ' + $Serial) 'White'
Say ('Tenant       : ' + $cfg.Tenant) 'White'
Say ('Group Tag    : ' + $cfg.GroupTag) 'White'
if ($AssignUpn) { Say ('Benutzer     : ' + $AssignUpn) 'White' }
Say ('Zurücksetzen: ' + $(if ($DoReset) { 'JA' } else { 'NEIN - nur Upload' })) 'White'

$os = Get-CimInstance Win32_OperatingSystem
Say ('Windows      : ' + $os.Caption + ' ' + $os.Version)
if ($os.Caption -notmatch 'Pro|Education|Enterprise') {
    Fail ('Edition "' + $os.Caption + '" - Zurücksetzen per RemoteWipe nur mit Pro/Education/Enterprise')
}
if ($null -ne $cfg.MinBattery) { $MinBattery = [int]$cfg.MinBattery }

# ---------- Schutz: nur im Einrichtungsbildschirm (OOBE) ohne Benutzerdaten ----------
if ($DoReset) {
    $me = [Environment]::UserName
    $prof = @()
    try {
        $prof = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {
            -not $_.Special -and $_.LocalPath -match '\\Users\\' -and $_.LocalPath -notmatch '\\defaultuser\d*$' })
    } catch { Log ('Benutzerprofile prüfen: ' + $_.Exception.Message) }
    Log ('Benutzer: ' + $me + ' | Profile: ' + (($prof | ForEach-Object { $_.LocalPath }) -join ', '))
    if ($prof.Count -or $me -notmatch '^defaultuser\d*$') {
        Banner 'ACHTUNG  -  GERÄT IST SCHON EINGERICHTET' 'DarkRed' @(
            '',
            'HUPilot ist für neue Geräte im Einrichtungsbildschirm gedacht.',
            ('Angemeldet als: ' + $me),
            ('Benutzerprofile: ' + $(if ($prof.Count) { ($prof | ForEach-Object { Split-Path $_.LocalPath -Leaf }) -join ', ' } else { 'keine' })),
            '',
            'Beim Zurücksetzen gehen ALLE Daten auf dem Gerät verloren.',
            'Zum Fortfahren  LÖSCHEN  eintippen, sonst nur Enter (Abbruch).')
        $a = Read-Host '  Eingabe'
        if ($a -cne 'LÖSCHEN' -and $a -cne 'LOESCHEN') { Log 'Abbruch: Gerät hat Benutzerdaten'; Protokoll 'ABBRUCH: Benutzerdaten vorhanden'; exit 1 }
        Log 'Benutzerdaten-Warnung mit LÖSCHEN bestätigt'
        try { $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
    }
    Wait-Power
    Say ('Strom        : ' + (Get-PowerInfo).Text)
}

if ($null -ne $cfg.WlanPackage) { $WlanPkgName = [string]$cfg.WlanPackage }
if ($WlanPkgName) {
    $StickPkg = Join-Path $CfgDir $WlanPkgName
    if (-not (Test-Path $StickPkg)) { Fail ('WLAN-Paket fehlt am Stick: ' + $StickPkg + '  (ohne WLAN-Paket: "WlanPackage": "" in config.json)') }
}

# ---------- Hash (vor dem Netz - wird bei Offline am Stick gespeichert) ----------
$hash = $null
try {
    $dd = Get-CimInstance -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    $hash = $dd.DeviceHardwareData
} catch { Log ('Hash-Fehler: ' + $_.Exception.Message) }
if (-not $hash) { Fail 'Hardware-Hash nicht lesbar' }
Say ('Hash gelesen (' + $hash.Length + ' Zeichen)') 'Green'


# ---------- 2. Netz / WLAN ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host ''
Say 'Prüfe Internet ...'
Sync-Clock
$netOk = Test-Net $cfg.TenantId
if (-not $netOk) {
    # LAN-Kabel steckt: erst bis 60 s auf eine Adresse/Internet warten, bevor das WLAN versucht wird
    $lan = Test-LanLink
    if ($lan) {
        Log ('LAN-Verbindung erkannt: ' + $lan)
        Say 'LAN verbunden - warte auf Internet (bis 60 s) ...' 'Yellow'
        $t0 = Get-Date
        for ($i = 0; $i -lt 6 -and -not $netOk; $i++) {
            Wait-Live 10 'LAN: warte auf Internet' $t0 60 'nächster Test'
            Show-Live 'LAN: teste Internet ...'
            Sync-Clock
            $netOk = Test-Net $cfg.TenantId
        }
        Complete-Live
        if (-not $netOk) { Say 'Über LAN kein Internet - versuche zusätzlich WLAN' 'Yellow' }
    }
}
if (-not $netOk) {
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
    $t0 = Get-Date
    for ($i = 0; $i -lt 12; $i++) {          # 12 x 10 s = 2 Min
        if ($i % 3 -eq 0) {
            try {
                $o = netsh wlan connect name="$($cfg.WlanSsid)" ssid="$($cfg.WlanSsid)" 2>&1
                Log ('netsh connect: ' + (($o | Out-String).Trim()))
            } catch { Log ('netsh connect: ' + $_.Exception.Message) }
        }
        Wait-Live 10 'WLAN: verbinde' $t0 120 'nächster Test'
        Show-Live 'WLAN: teste Internet ...'
        Sync-Clock
        if (Test-Net $cfg.TenantId) { $ok = $true; break }
    }
    Complete-Live
    if (-not $ok) {
        $st = ''
        try { $st = ((netsh wlan show interfaces | Select-String 'SSID|Status|State|Signal') -join ' / ') } catch { }
        Log ('WLAN-Status: ' + $st)
        Save-Offline 'Kein Internet nach 2 Min (WLAN-Reichweite/Kennwort/Firewall prüfen)'
    }
}
Say 'Internet OK' 'Green'
Sync-Clock

# ---------- 3a. Token ----------
$tok = $null
$TokAt = Get-Date
for ($i = 1; $i -le 3 -and -not $tok; $i++) {
    try {
        $body = @{ grant_type = 'client_credentials'; client_id = $cfg.ClientId; client_secret = $cfg.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        $tok = (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $cfg.TenantId + '/oauth2/v2.0/token') -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
    } catch {
        $m = Get-ErrText $_
        Log ('Token-Versuch ' + $i + ': ' + $m)
        if ($m -match 'AADSTS7000222') { Save-Offline 'Secret ABGELAUFEN - neues Secret in config.json eintragen' }
        if ($m -match 'AADSTS7000215') { Save-Offline 'Secret FALSCH (Secret-ID statt Wert?)' }
        if ($i -lt 3) { Wait-Live 5 ('Anmeldung fehlgeschlagen - Versuch ' + ($i + 1) + '/3') (Get-Date) 0 'neuer Versuch'; Complete-Live }
    }
}
if (-not $tok) { Save-Offline 'Anmeldung am Tenant fehlgeschlagen (siehe Log)' }
$h  = @{ Authorization = 'Bearer ' + $tok }
$hj = @{ Authorization = 'Bearer ' + $tok; 'Content-Type' = 'application/json' }
# Access-Token gilt laut MS Doku zufaellig 60-90 Min (learn.microsoft.com/entra/identity-platform/access-tokens#token-lifetime).
# Lange Laeufe (Hardwaretausch bis 30 Min + Import 10 + Profil 20) koennen das ueberschreiten -> ab 45 Min neu holen.
function Update-Token {
    if (((Get-Date) - $script:TokAt).TotalMinutes -lt 45) { return }
    try {
        $b = @{ grant_type = 'client_credentials'; client_id = $cfg.ClientId; client_secret = $cfg.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        $t = (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $cfg.TenantId + '/oauth2/v2.0/token') -Body $b -ContentType 'application/x-www-form-urlencoded').access_token
        if ($t) {
            $script:tok = $t
            $script:TokAt = Get-Date
            $script:h  = @{ Authorization = 'Bearer ' + $t }
            $script:hj = @{ Authorization = 'Bearer ' + $t; 'Content-Type' = 'application/json' }
            Log 'Token erneuert'
        }
    } catch { Log ('Token erneuern: ' + (Get-ErrText $_)) }
}
# Graph-GET mit Wiederholung bei Ueberlast (429/503/504): Retry-After beachten, sonst 5/15/45 s + Zufall 0-10 s.
# Viele Sticks gleichzeitig im selben Tenant teilen sich dasselbe Limit (MS Doku Graph throttling) - nur GET, daher gefahrlos wiederholbar.
function Invoke-GraphGet {
    param([string]$Uri)
    for ($try = 0; ; $try++) {
        try { return (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri $Uri -Headers $script:h) }
        catch {
            $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }
            if ($try -ge 3 -or $sc -notin 429, 503, 504) { throw }
            $wait = @(5, 15, 45)[$try]
            try { $ra = [int]("" + $_.Exception.Response.Headers['Retry-After']); if ($ra -gt 0) { $wait = [math]::Min($ra, 120) } } catch { }
            $wait += Get-Random -Minimum 0 -Maximum 11
            Log ('Graph ' + $sc + ' (Ueberlast) - neuer Versuch ' + ($try + 1) + '/3 in ' + $wait + ' s')
            Start-Sleep -Seconds $wait
        }
    }
}
# Autopilot-Sync: laut MS Doku 409 = Sync laeuft schon, 429 = letzter Sync vor weniger als 10 Min - beides kein Fehler
function Invoke-ApSync {
    param([string]$Grund)
    Update-Token
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/windowsAutopilotSettings/sync') -Headers $h | Out-Null; Log ('Autopilot-Sync angestoßen (' + $Grund + ')') }
    catch {
        $m = Get-ErrText $_
        $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }
        if ($sc -eq 409 -or $sc -eq 429 -or $m -match 'Conflict|TooManyRequests|Too Many Requests') { Log ('Autopilot-Sync (' + $Grund + '): läuft bereits oder vor weniger als 10 Min - ok') }
        else { Log ('Autopilot-Sync (' + $Grund + '): ' + $m) }
    }
}
Say 'Anmeldung Tenant OK' 'Green'

# ---------- Tag-Pruefung: gibt es fuer den Tag ein Autopilot-Profil? (optional Group.Read.All) ----------
function Test-RuleTag {
    param([string]$Rule, [string]$Tag)
    if (-not $Rule) { return $false }
    $full = '[OrderID]:' + $Tag
    foreach ($m in [regex]::Matches($Rule, '-(eq|startsWith|contains|match)\s*"(\[OrderID\]:[^"]*)"', 'IgnoreCase')) {
        $op = $m.Groups[1].Value.ToLower(); $v = $m.Groups[2].Value
        if ($op -eq 'eq' -and $full -ieq $v) { return $true }
        if ($op -eq 'startswith' -and $full.StartsWith($v, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($op -eq 'contains' -and $full.IndexOf($v, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        if ($op -eq 'match') { try { if ($full -match $v) { return $true } } catch { } }
    }
    return $false
}
function Get-TagProfiles {
    # Rueckgabe: Liste der Profilnamen fuer den Tag; $null = nicht pruefbar
    # Nebenbei: $script:TagProfIds = ID des Profils, das das Geraet laut MS-Prioritaetsregel bekommt (erwartetes Profil beim Warten)
    # MS Doku (learn.microsoft.com/autopilot/profiles "Windows Autopilot profile priority"):
    #   mehrere passende Gruppen-Profile -> das AELTESTE (createdDateTime) gewinnt;
    #   ein Profil fuer "Alle Geraete" gilt nur, wenn kein anderes Profil passt.
    # Ausschluesse (exclusionGroupAssignmentTarget), deren Gruppenregel auf den Tag passt, schliessen das Profil aus.
    param([string]$Tag)
    $script:TagProfIds = $null
    try { $pr = @((Invoke-GraphGet ($GB + '/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments')).value) }
    catch { Log ('Tag-Prüfung Profile: ' + (Get-ErrText $_)); return $null }
    $gcache = @{}
    $grp = @(); $all = @()
    foreach ($p in $pr) {
        $inc = $false; $incAll = $false; $exc = $false; $gname = ''
        foreach ($a in @($p.assignments)) {
            $t = $a.target; $ty = [string]$t.'@odata.type'
            if ($ty -like '*allDevicesAssignmentTarget') { $incAll = $true; continue }
            $isExc = ($ty -like '*exclusionGroupAssignmentTarget')
            if (-not $isExc -and $ty -notlike '*.groupAssignmentTarget') { continue }
            $gid = [string]$t.groupId
            if (-not $gcache.ContainsKey($gid)) {
                try { $gcache[$gid] = Invoke-GraphGet ('https://graph.microsoft.com/v1.0/groups/' + $gid + '?$select=displayName,membershipRule') }
                catch {
                    $em = Get-ErrText $_
                    if ($em -match 'Authorization_RequestDenied|Forbidden|403|Insufficient privileges') { Log ('Tag-Prüfung Gruppe (Group.Read.All fehlt): ' + $em); return $null }
                    Log ('Tag-Prüfung: Gruppe ' + $gid + ' nicht lesbar/gelöscht - übersprungen'); $gcache[$gid] = [pscustomobject]@{ displayName = $gid; membershipRule = '' }
                }
            }
            if (Test-RuleTag ([string]$gcache[$gid].membershipRule) $Tag) {
                if ($isExc) { $exc = $true } else { $inc = $true; $gname = [string]$gcache[$gid].displayName }
            }
        }
        if ($exc) { Log ('Tag-Prüfung: Profil ' + $p.displayName + ' schließt die Tag-Gruppe aus'); continue }
        $cd = [datetime]::MaxValue; try { if ($p.createdDateTime) { $cd = [datetime]$p.createdDateTime } } catch { }
        if ($inc) { $grp += [pscustomobject]@{ Id = [string]$p.id; Name = ([string]$p.displayName + ' (' + $gname + ')'); Created = $cd } }
        elseif ($incAll) { $all += [pscustomobject]@{ Id = [string]$p.id; Name = ([string]$p.displayName + ' (Alle Geräte)'); Created = $cd } }
    }
    $cand = @(if ($grp.Count) { $grp } else { $all })
    if (-not $cand.Count) { $script:TagProfIds = @(); return ,@() }
    $win = @($cand | Sort-Object Created)[0]
    if ($cand.Count -gt 1) { Log ('Tag-Prüfung: ' + $cand.Count + ' Profile passen, ältestes gewinnt: ' + $win.Name) }
    $script:TagProfIds = @($win.Id)
    # Komma: leere Liste NICHT zu $null aufloesen lassen ($null = nicht pruefbar)
    return ,@($win.Name)
}
$tp = Get-TagProfiles $cfg.GroupTag
if ($null -eq $tp) { Log 'Tag-Prüfung nicht möglich (optional: Group.Read.All für die App)'; Say 'Hinweis: Profil kann nicht geprüft werden (Recht Group.Read.All fehlt) - im Intune kontrollieren' 'Yellow' }
elseif ($tp.Count) { Say ('Profil für Tag: ' + ($tp -join ', ')) 'Green' }
else {
    Log ('Tag-Prüfung: KEIN Profil für ' + $cfg.GroupTag)
    Write-Host ''
    Write-Host ('  ACHTUNG: Für Tag "' + $cfg.GroupTag + '" ist KEIN Autopilot-Profil zugewiesen.') -ForegroundColor Yellow
    Write-Host '  Das Gerät würde nach dem Upload vergeblich auf ein Profil warten.' -ForegroundColor Yellow
    Write-Host '  [A] Abbrechen   -   [Enter] trotzdem hochladen' -ForegroundColor Yellow
    $k = Read-KeyTimeout 20 'ohne Eingabe: trotzdem hochladen'
    if ($k -eq 'A') { Log 'Abbruch: kein Profil für Tag'; Protokoll 'ABBRUCH: kein Profil für Tag'; exit 1 }
}

# ---------- Benutzer pruefen (optional User.Read.All) ----------
$AssignName = ''
if ($AssignUpn) {
    try {
        $usr = Invoke-GraphGet ('https://graph.microsoft.com/v1.0/users/' + [uri]::EscapeDataString($AssignUpn) + '?$select=displayName,userPrincipalName')
        $AssignName = [string]$usr.displayName
        Say ('Benutzer gefunden: ' + $AssignName) 'Green'
    } catch {
        $m = Get-ErrText $_
        if ($m -match 'Request_ResourceNotFound|does not exist') { Say ('Benutzer ' + $AssignUpn + ' NICHT gefunden - wird nicht zugewiesen') 'Yellow'; $AssignUpn = '' }
        else { Log ('Benutzer-Prüfung nicht möglich (User.Read.All?): ' + $m) }
    }
    if (-not $AssignName -and $AssignUpn) { $AssignName = $AssignUpn.Split('@')[0] }
}

# ---------- 3c. Autopilot ----------
function Get-ApDevice {
    Update-Token
    $script:ApLookupFailed = $false
    try {
        # OData: einfaches Hochkomma im Wert verdoppeln
        $f = [uri]::EscapeDataString("contains(serialNumber,'" + $Serial.Replace("'", "''") + "')")
        $r = Invoke-GraphGet ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities?$filter=' + $f)
        $m = @($r.value | Where-Object { $_.serialNumber -eq $Serial })
        if ($m.Count -gt 1) { Log ('ACHTUNG: ' + $m.Count + ' Autopilot-Einträge mit Seriennummer ' + $Serial + ' - verwende den mit der jüngsten Profilzuweisung') }
        return @($m | Sort-Object { [string]$_.deploymentProfileAssignedDateTime } -Descending)[0]
    } catch { Log ('Autopilot-Abfrage: ' + (Get-ErrText $_)); $script:ApLookupFailed = $true; return $null }
}
function Get-ApProfile {
    param([string]$Id)
    Update-Token
    try {
        $r = Invoke-GraphGet ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $Id + '?$expand=deploymentProfile')
        return $r.deploymentProfile
    } catch { Log ('Profil-Abfrage: ' + (Get-ErrText $_)); return $null }
}

$TagChanged = $false

# Erste Abfrage: ein Fehler (Netz, 429, 5xx) darf NICHT als "nicht registriert" gelten - sonst wuerde ein vorab
# importiertes Geraet neu importiert und der Import scheitert irrefuehrend mit 806/808. 3 Versuche, dann Abbruch.
$ap = $null
for ($i = 1; $i -le 3; $i++) {
    $ap = Get-ApDevice
    if (-not $script:ApLookupFailed) { break }
    if ($i -lt 3) { Log ('Autopilot-Abfrage fehlgeschlagen - Versuch ' + ($i + 1) + '/3'); Wait-Live 15 ('Autopilot-Abfrage fehlgeschlagen - Versuch ' + ($i + 1) + '/3') (Get-Date) 0 'neuer Versuch'; Complete-Live }
}
if ($script:ApLookupFailed) { Fail 'Autopilot-Abfrage 3x fehlgeschlagen (Netz/Graph, siehe Log) - nochmal go' }
# Hardware geaendert (z. B. Mainboardtausch beim Support): Autopilot zeigt "Fix ausstehend" / "Achtung erforderlich",
# der gespeicherte Hash passt nicht mehr. MS Doku (Autopilot motherboard replacement / Deregister a device):
# zuerst Intune-Eintrag loeschen, dann Autopilot-Eintrag loeschen, dann mit neuem Hash neu registrieren.
if ($ap -and ([string]$ap.remediationState -in 'automaticRemediationRequired', 'manualRemediationRequired')) {
    Log ('Hardware-Änderung erkannt: remediationState=' + $ap.remediationState + ', Tag ' + $ap.groupTag)
    Write-Host ''
    Write-Host '  ACHTUNG: Autopilot meldet eine HARDWARE-ÄNDERUNG (z. B. Mainboardtausch).' -ForegroundColor Yellow
    Write-Host '  Der gespeicherte Hash passt nicht mehr - das Autopilot-Profil greift so nicht.' -ForegroundColor Yellow
    Write-Host '  Neu registrieren = Intune-Eintrag und Autopilot-Eintrag löschen, neuen Hash hochladen.' -ForegroundColor Yellow
    Write-Host '  [N] neu registrieren (empfohlen)   -   [Enter] abbrechen' -ForegroundColor Yellow
    $k = ''
    try { $k = ([string](Read-Host '  Auswahl')).Trim().ToUpper() } catch { }
    if ($k -ne 'N') { Fail 'Hardware geändert - nicht neu registriert (Abbruch)' }
    # 1. Intune-Eintraege mit dieser Seriennummer loeschen
    $md = @()
    try {
        $f = [uri]::EscapeDataString("serialNumber eq '" + $Serial + "'")
        $md = @((Invoke-GraphGet ($GB + '/deviceManagement/managedDevices?$filter=' + $f + '&$select=id,deviceName,serialNumber')).value | Where-Object { $_.serialNumber -eq $Serial })
    } catch { Fail ('Intune-Einträge lesen: ' + (Get-ErrText $_) + ' (App-Berechtigung DeviceManagementManagedDevices.ReadWrite.All nötig)') }
    foreach ($d in $md) {
        try {
            Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/managedDevices/' + $d.id) -Headers $h | Out-Null
            Say ('Intune-Eintrag gelöscht: ' + $d.deviceName) 'Yellow'
        } catch { Fail ('Intune-Eintrag ' + $d.deviceName + ' nicht löschbar: ' + (Get-ErrText $_) + ' - im Intune-Portal löschen oder App-Berechtigung DeviceManagementManagedDevices.ReadWrite.All ergänzen, dann nochmal go') }
    }
    if (-not $md.Count) { Log 'Kein Intune-Eintrag mit dieser Seriennummer' }
    # 2. Benutzer-Zuweisung aufheben (sonst laesst sich der Eintrag nicht loeschen)
    if ([string]$ap.userPrincipalName) {
        try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $ap.id + '/unassignUserFromDevice') -Headers $h | Out-Null; Log ('Benutzer-Zuweisung aufgehoben: ' + $ap.userPrincipalName) }
        catch { Log ('Benutzer-Zuweisung aufheben: ' + (Get-ErrText $_)) }
    }
    # 3. Autopilot-Eintrag loeschen und warten, bis er weg ist
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $ap.id) -Headers $h | Out-Null }
    catch { Fail ('Autopilot-Eintrag löschen: ' + (Get-ErrText $_)) }
    Say 'Autopilot-Eintrag gelöscht - warte, bis er verschwunden ist (bis 30 Min) ...'
    Invoke-ApSync 'nach Löschen'
    $gone = $false
    $t0 = Get-Date
    $lim = $t0.AddMinutes(30)
    while ((Get-Date) -lt $lim) {
        Wait-Live 30 'Alter Eintrag wird gelöscht' $t0 1800
        Show-Live 'Alter Eintrag wird gelöscht  |  frage ab ...'
        Update-Token
        try {
            $f = [uri]::EscapeDataString("contains(serialNumber,'" + $Serial.Replace("'", "''") + "')")
            $r = Invoke-GraphGet ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities?$filter=' + $f)
            if (-not @($r.value | Where-Object { $_.serialNumber -eq $Serial }).Count) { $gone = $true; break }
        } catch { Log ('Autopilot-Abfrage: ' + (Get-ErrText $_)) }
    }
    Complete-Live
    if (-not $gone) { Fail 'Autopilot-Eintrag nach 30 Min noch vorhanden - später nochmal go (das Gerät wird dann normal neu importiert)' }
    Say 'Alter Autopilot-Eintrag entfernt - importiere neu mit aktuellem Hash' 'Green'
    $ap = $null
}
$AlreadyReg = [bool]$ap
if ($ap) {
    Say ('Bereits in Autopilot (Tag "' + $ap.groupTag + '")') 'Yellow'
    # Vorab importierte Geraete (z. B. Haendler-CSV): vorhandenen Tag NICHT stillschweigend ueberschreiben.
    # Weicht der gewaehlte Tag ab, wird gefragt; ohne Eingabe (10 s) bleibt der vorhandene Tag.
    if ([string]$ap.groupTag -and [string]$ap.groupTag -ne [string]$cfg.GroupTag) {
        Write-Host ''
        Write-Host ('  Gerät hat schon den Tag "' + $ap.groupTag + '", gewählt ist "' + $cfg.GroupTag + '".') -ForegroundColor Yellow
        Write-Host ('    [Enter]  Tag "' + $ap.groupTag + '" behalten   (Standard)') -ForegroundColor White
        Write-Host ('    [J]      auf "' + $cfg.GroupTag + '" ändern')
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }   # alte Tastendruecke verwerfen
        $k = Read-KeyTimeout 10 ('ohne Eingabe: Tag ' + $ap.groupTag + ' behalten')
        if ($k -eq 'J' -or $k -eq 'Y') { Log ('Tag-Änderung bestätigt: ' + $ap.groupTag + ' -> ' + $cfg.GroupTag) }
        else {
            Log ('Vorhandener Tag bleibt: ' + $ap.groupTag + ' (gewählt war ' + $cfg.GroupTag + ')')
            $cfg.GroupTag = [string]$ap.groupTag
            if ($cfg.GroupTag -notmatch $TagPattern) { Log ('Hinweis: vorhandener Tag passt nicht zum Muster ' + $TagPattern + ': ' + $cfg.GroupTag) }
            # erwartetes Profil fuer den behaltenen Tag neu bestimmen (Tag-Pruefung lief mit dem gewaehlten Tag)
            $tp = Get-TagProfiles $cfg.GroupTag
            if ($null -eq $tp) { Log 'Tag-Prüfung nicht möglich (optional: Group.Read.All für die App)' }
            elseif ($tp.Count) { Say ('Profil für Tag: ' + ($tp -join ', ')) 'Green' }
            else {
                Log ('Tag-Prüfung: KEIN Profil für behaltenen Tag ' + $cfg.GroupTag)
                Write-Host ('  ACHTUNG: Für den vorhandenen Tag "' + $cfg.GroupTag + '" ist KEIN Autopilot-Profil zugewiesen.') -ForegroundColor Yellow
                Write-Host '  Das Gerät würde vergeblich auf ein Profil warten (Tippfehler in der CSV?).' -ForegroundColor Yellow
                Write-Host '  [A] Abbrechen   -   [Enter] trotzdem weiter' -ForegroundColor Yellow
                try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
                $k2 = Read-KeyTimeout 20 'ohne Eingabe: trotzdem weiter'
                if ($k2 -eq 'A') { Log 'Abbruch: kein Profil für behaltenen Tag'; Protokoll 'ABBRUCH: kein Profil für Tag'; exit 1 }
            }
        }
        Write-Host ''
    }
    if ([string]$ap.groupTag -ne [string]$cfg.GroupTag) {
        $op = Get-ApProfile $ap.id
        if ($op) { Log ('Bisheriges Profil: ' + $op.displayName) }
        try {
            Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $ap.id + '/updateDeviceProperties') -Headers $hj -Body (@{ groupTag = $cfg.GroupTag } | ConvertTo-Json) | Out-Null
            Say ('Tag geändert -> ' + $cfg.GroupTag) 'Green'
            $TagChanged = $true
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
    $t0 = Get-Date
    $limit = $t0.AddMinutes(10)
    while ((Get-Date) -lt $limit) {
        Wait-Live 10 ('Import läuft' + $(if ($state -and $state -notin 'unknown', 'pending') { ' (' + $state + ')' } else { '' })) $t0 600
        Show-Live 'Import läuft  |  frage ab ...'
        Update-Token
        $prev = $state
        try {
            $st = Invoke-GraphGet ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities/' + $imp.id)
            $state = [string]$st.state.deviceImportStatus
            if ($state -ne $prev) { Log ('Import-Status: ' + $state) }
            if ($state -eq 'complete') { break }
            if ($state -eq 'error') { break }
        } catch { Log ('Import-Status: ' + (Get-ErrText $_)) }
    }
    Complete-Live
    if ($state -eq 'error') {
        $en = [string]$st.state.deviceErrorName; $ec = [string]$st.state.deviceErrorCode
        try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities/' + $imp.id) -Headers $h | Out-Null } catch { }
        # MS Doku (Error 806 or 808 when you import ...): auch ein Rest-Datensatz im EIGENEN Tenant/Intune kann 806/808 ausloesen
        if ($ec -eq '808' -or $en -match 'OtherTenant') { Fail ('Gerät ist in einem ANDEREN Tenant registriert oder es gibt noch einen alten Datensatz im eigenen Tenant/Intune (' + $en + ' ' + $ec + ')') }
        Fail ('Import-Fehler: ' + $en + ' (' + $ec + ')')
    }
    if ($state -ne 'complete') { Fail ('Import nach 10 Min nicht fertig (Status: ' + $state + ')') }
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities/' + $imp.id) -Headers $h | Out-Null } catch { }
    Say 'Import abgeschlossen' 'Green'
}

if ($AssignUpn) {
    $apU = $null
    $t0 = Get-Date
    for ($i = 0; $i -lt 6 -and -not $apU; $i++) { $apU = Get-ApDevice; if (-not $apU) { Wait-Live 10 'Warte auf Autopilot-Eintrag' $t0 60 } }
    Complete-Live
    if ($apU) {
        try {
            Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $apU.id + '/assignUserToDevice') -Headers $hj -Body (@{ userPrincipalName = $AssignUpn; addressableUserName = $AssignName } | ConvertTo-Json) | Out-Null
            Say ('Benutzer zugewiesen: ' + $AssignUpn) 'Green'
        } catch { Say ('Benutzer zuweisen fehlgeschlagen: ' + (Get-ErrText $_)) 'Yellow' }
    } else { Say 'Benutzer zuweisen: Gerät in Autopilot noch nicht sichtbar - später im Portal' 'Yellow' }
}
if (-not $ap -or $TagChanged -or $AssignUpn -or ([string]$ap.deploymentProfileAssignmentStatus -notin 'assignedInSync', 'assignedUnkownSyncState')) { Invoke-ApSync 'nach Import/Tag/Benutzer bzw. noch ohne Profil' }

# ---------- 4. WLAN-Paket lokal kopieren ----------
if ($StickPkg) {
    try {
        Copy-Item -Path $StickPkg -Destination $TmpPkg -Force
        if ((Get-Item $TmpPkg).Length -ne (Get-Item $StickPkg).Length) { throw 'Größe stimmt nicht' }
    } catch { Fail ('WLAN-Paket kopieren: ' + $_.Exception.Message) }
    Log 'WLAN-Paket lokal kopiert'
}
Protokoll ($(if ($AlreadyReg) { 'BEREITS REGISTRIERT' } else { 'UPLOAD OK' }) + $(if ($DoReset) { '' } else { ' (ohne Zurücksetzen)' }))
Log '--- Stick wird ab jetzt nicht mehr gebraucht ---'
$StickLog = $null

# ---------- 5. Auf Profil warten (Funktion, auch fuer "nur hochladen") ----------
# Zurueckgesetzt wird erst, wenn die drei Bedingungen aus der MS Doku erfuellt sind
# (learn.microsoft.com/autopilot/profiles "Assignment of Windows Autopilot deployment profiles to devices"):
#   1. Profilstatus "Assigned"   -> Graph assignedInSync oder assignedUnkownSyncState
#      (im Tenant stehen ALLE registrierten Geraete dauerhaft auf assignedUnkownSyncState - ein reines assignedInSync wuerde nie erreicht)
#   2. "Date assigned" gesetzt   -> deploymentProfileAssignedDateTime
#   3. "Assigned profile" = erwartetes Profil -> Profil-ID = Profil, das laut MS-Prioritaetsregel fuer den Tag gewinnt (Tag-Pruefung, Group.Read.All)
#   zusaetzlich: deploymentProfileAssignmentDetailedStatus leer oder 'none' (sonst meldet Intune ein Problem mit dem Profil)
# v2.6 hat nur 1. geprueft und ein Geraet ohne fertige Zuweisung zurueckgesetzt. Ausserdem muessen 2 Abfragen hintereinander passen.
# Nach Tag-Aenderung ohne moegliche Tag-Pruefung: keine automatische Freigabe (altes Profil waere nicht vom neuen unterscheidbar).
function Test-ApDate {
    param($v)
    if ($null -eq $v -or "$v" -eq '') { return $false }
    try { return (([datetime]$v).Year -gt 2000) } catch { return $false }
}
# Graph-Werte fuer die Anzeige auf Deutsch (ins Log kommt weiter der Originalwert)
function ConvertTo-PsText {
    param([string]$Ps)
    switch ($Ps) {
        ''                        { return 'noch nicht sichtbar' }
        'notAssigned'             { return 'kein Profil zugewiesen' }
        'pending'                 { return 'Zuweisung läuft' }
        'assignedInSync'          { return 'zugewiesen' }
        'assignedUnkownSyncState' { return 'zugewiesen' }
        'assignedOutOfSync'       { return 'zugewiesen, nicht synchron' }
        'failed'                  { return 'Zuweisung fehlgeschlagen' }
        'unknown'                 { return 'unbekannt' }
        default                   { return $Ps }
    }
}
function ConvertTo-DetailText {
    param([string]$D)
    switch ($D) {
        'hardwareRequirementsNotMet'  { return 'Hardware erfüllt die Voraussetzungen nicht' }
        'windowsPcProfileNotSupported' { return 'Profil für Windows-PC nicht unterstützt' }
        default                       { return $D }
    }
}
function Wait-ApProfile {
    # Rueckgabe: Assigned ($true = Bedingungen erfuellt), LastTxt (letzter Status), Profil (Name)
    # -NoDateMin > 0: passt alles ausser dem Zuweisungsdatum, nach so vielen Minuten trotzdem freigeben
    #   (nur fuer Neustart im OOBE - Test 30.10.2026: Profil kam ohne Datum an; ein Irrtum kostet nur einen Neustart)
    param([int]$NoDateMin = 0)
    $assigned = $false
    $noDateSince = $null
    $shownTxt = ''
    $t0 = Get-Date
    $pn = ''
    $okCount = 0
    $lastTxt = ''
    $extra = $false
    if ($TagChanged -and $null -eq $TagProfIds) { Log 'Tag geändert, Tag-Prüfung nicht möglich - keine automatische Freigabe' }
    $limit = (Get-Date).AddMinutes($ProfileWaitMin)
    $syncAt = Get-Date
    while ((Get-Date) -lt $limit -or ($okCount -eq 1 -and -not $extra)) {
        # Noch nicht zugewiesen: Autopilot-Sync alle 5 Min wiederholen. Der Sync nach dem Import kann mit 429 abgewiesen werden,
        # wenn kurz vorher (< 10 Min, MS Doku) schon einer lief - z. B. vom vorigen Geraet. Dann kommt die Zuweisung sonst erst spaet.
        if ($okCount -eq 0 -and ((Get-Date) - $syncAt).TotalMinutes -ge 5) { Invoke-ApSync 'Warten auf Profil'; $syncAt = Get-Date }
        if ((Get-Date) -ge $limit -and $okCount -eq 1) { $extra = $true }   # erster Treffer kam kurz vor Ablauf: genau eine Kontrollrunde zusaetzlich
        # Abfrage-Hinweis an die aktuelle Zeile anhaengen, damit bei Statuswechsel der ALTE Status als Verlauf stehen bleibt
        if ($shownTxt) { Show-Live ('Profil: ' + $shownTxt + '  |  ' + (Format-Dauer ((Get-Date) - $t0).TotalSeconds) + '  |  frage ab ...') } else { Show-Live 'Profil: frage ab ...' }
        $ap = Get-ApDevice
        $ps = ''
        $pn = ''
        $pi = ''
        $pd = $false
        if ($ap) {
            $ps = [string]$ap.deploymentProfileAssignmentStatus
            $pd = Test-ApDate $ap.deploymentProfileAssignedDateTime
            if ($ps -like 'assigned*') {
                $pr = Get-ApProfile $ap.id
                if ($pr) { $pn = [string]$pr.displayName; $pi = [string]$pr.id }
            }
        }
        # Entscheidung (unveraendert) - Grund nur fuers Log
        $ready = $false
        $why = ''
        $wrong = $false; $noDate = $false
        if ($ps -in 'assignedInSync', 'assignedUnkownSyncState') {
            if (-not $pi) { $why = 'Profil nicht lesbar' }
            elseif ([string]$ap.deploymentProfileAssignmentDetailedStatus -notin '', 'none') { $why = ConvertTo-DetailText ([string]$ap.deploymentProfileAssignmentDetailedStatus) }
            elseif ($null -ne $TagProfIds -and -not $TagProfIds.Count) { $why = 'für den Tag ist kein Profil zugewiesen'; $wrong = $true }
            elseif ($null -ne $TagProfIds -and ($TagProfIds -notcontains $pi)) { $why = 'anderes Profil als für den Tag erwartet'; $wrong = $true }
            elseif ($TagChanged -and $null -eq $TagProfIds) { $why = 'Tag geändert, erwartetes Profil unbekannt' }
            elseif (-not $pd) {
                $noDate = $true
                if (-not $noDateSince) { $noDateSince = Get-Date }
                if ($NoDateMin -gt 0 -and ((Get-Date) - $noDateSince).TotalMinutes -ge $NoDateMin) { $ready = $true; $why = 'ohne Zuweisungsdatum freigegeben (' + $NoDateMin + ' Min stabil, nur OOBE-Neustart)' }
                else { $why = 'Zuweisungsdatum leer' }
            }
            else { $ready = $true }
        } else { $why = 'Status ' + $(if ($ps) { $ps } else { 'leer' }) }
        if (-not $noDate) { $noDateSince = $null }
        # Ohne Datum (nur OOBE): Wartezeit so verlaengern, dass die NoDateMin-Frist sicher ablaufen kann (nur nach oben)
        if ($noDateSince -and $NoDateMin -gt 0) { $lim2 = $noDateSince.AddMinutes($NoDateMin + 1.5); if ($lim2 -gt $limit) { $limit = $lim2 } }
        if ($ready) { $okCount++ } else { $okCount = 0 }
        # Anzeige: EINE Live-Zeile; aendert sich der Status, bleibt die alte Zeile als Verlauf stehen
        $pnTxt = $(if ($pn) { ' (' + $pn + ')' } else { '' })
        if (-not $ps)          { $txt = 'noch nicht sichtbar' }
        elseif ($ready)        { $txt = 'zugewiesen' + $pnTxt }
        elseif ($wrong)        { $txt = 'falsches Profil' + $pnTxt }
        elseif ($ps -eq 'failed') { $txt = 'Zuweisung fehlgeschlagen' }
        elseif ($noDate)       { $txt = 'zugewiesen - Datum fehlt noch' }
        else                   { $txt = 'Zuweisung fehlt' }
        $lastTxt = $txt
        Log ('Profilstatus: ' + $txt + ' | Graph ' + $ps + ' | Grund ' + $why + ' | Profil ' + $pn + ' ' + $pi + ' | Datum ' + [string]$ap.deploymentProfileAssignedDateTime)
        if ($shownTxt -and $txt -ne $shownTxt) { Complete-Live }   # alte Zeile bleibt stehen
        $shownTxt = $txt
        if ($okCount -ge 2) {
            Show-Live ('Profil: ' + $txt + '  |  ' + (Format-Dauer ((Get-Date) - $t0).TotalSeconds) + '  |  OK')
            Complete-Live
            $assigned = $true; break
        }
        if ($extra) { Complete-Live; break }
        $lt = 'Profil: ' + $txt
        if ($noDate -and $NoDateMin -gt 0) { $lt += ' (Neustart in ' + [int][math]::Max(1, [math]::Ceiling($NoDateMin - ((Get-Date) - $noDateSince).TotalMinutes)) + ' Min)' }
        Wait-Live (Get-Random -Minimum 26 -Maximum 35) $lt $t0 ([int]($limit - $t0).TotalSeconds) $(if ($okCount -eq 1) { 'Kontrolle' } else { 'nächste Abfrage' })
    }
    Complete-Live
    return [pscustomobject]@{ Assigned = $assigned; LastTxt = $lastTxt; Profil = $pn }
}

if (-not $DoReset) {
    Log 'Nur Upload gewählt - kein Zurücksetzen, prüfe Profilzuweisung'
    # WLAN-Paket (WLAN + ggf. lokaler Admin) auch ohne Zuruecksetzen installieren
    if ($StickPkg) {
        $persist = Join-Path $env:ProgramData ('Microsoft\Provisioning\' + $WlanPkgName)
        $same = $false
        if (Test-Path $persist) { try { $same = ((Get-FileHash -Path $persist -Algorithm SHA256).Hash -eq (Get-FileHash -Path $TmpPkg -Algorithm SHA256).Hash) } catch { Log ('Hash-Vergleich: ' + $_.Exception.Message) } }
        if ($same) { Log 'WLAN-Paket ist bereits installiert (identisch)' }
        else {
            $pr = $null
            Log ('provtool.exe ' + $TmpPkg + ' /quiet (ohne Zurücksetzen)')
            Show-Live 'WLAN-Paket wird installiert ...'
            try {
                $pr = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\provtool.exe') -ArgumentList ('"' + $TmpPkg + '"', '/quiet') -PassThru -WindowStyle Hidden
                if (-not $pr.WaitForExit(120000)) { Log 'provtool nach 2 Min nicht fertig - abgebrochen'; try { $pr.Kill() } catch { }; $pr = $null }
            } catch { Log ('provtool: ' + $_.Exception.Message); $pr = $null }
            Complete-Live
            if ($pr -and $pr.ExitCode -eq 0) { Log 'WLAN-Paket installiert (ohne Zurücksetzen)'; Say 'WLAN-Paket installiert' 'Green' }
            else { Log ('WLAN-Paket NICHT installiert, provtool Exitcode ' + $(if ($pr) { $pr.ExitCode } else { '-' })); Say 'WLAN-Paket konnte nicht installiert werden' 'Yellow' }
        }
    }
    Banner 'OK  -  HOCHGELADEN  -  STICK ABZIEHEN' 'DarkGreen' @(
        '',
        ('Group Tag: ' + $cfg.GroupTag + $(if ($AssignUpn) { '   Benutzer: ' + $AssignUpn } else { '' })),
        ('Warte auf das Autopilot-Profil (max. ' + $ProfileWaitMin + ' Min).'),
        'Fenster offen lassen.')
    # Im Einrichtungsbildschirm (OOBE) reicht ein Neustart: Windows holt das Autopilot-Profil bei jedem Neustart neu
    # (MS Doku: learn.microsoft.com/autopilot/troubleshooting-faq "How are Windows Autopilot device profiles downloaded?").
    $inOobe = $false
    try {
        $realProf = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath -match '\\Users\\' -and $_.LocalPath -notmatch '\\defaultuser\d*$' })
        $inOobe = ([Environment]::UserName -match '^defaultuser\d*$') -and -not $realProf.Count
    } catch { Log ('OOBE-Erkennung: ' + $_.Exception.Message) }
    # Im OOBE nach 11 Min auch ohne Zuweisungsdatum neu starten (Datum kommt normal nach ~10 Min)
    $wr = Wait-ApProfile -NoDateMin $(if ($inOobe) { 11 } else { 0 })
    if ($wr.Assigned -and $inOobe) {
        Log ('Nur Upload im OOBE: Profil zugewiesen (' + $wr.Profil + ') - Neustart')
        # Stick muss weg, sonst bootet das Geraet evtl. vom Stick (Ventoy)
        $stickRoot = ''
        try { $stickRoot = Split-Path -Qualifier $PSScriptRoot } catch { Log ('Stick-Laufwerk: ' + $_.Exception.Message) }
        if (-not $stickRoot) { $stickRoot = 'Z:\HUPilot-kein-Stick' }   # Pfad gibt es nicht -> nicht warten
        $t0 = Get-Date
        $wait = $t0.AddMinutes(5)
        $shown = $false
        while ((Test-Path -LiteralPath ($stickRoot + '\')) -and (Get-Date) -lt $wait) {
            if (-not $shown) {
                Banner 'PROFIL DA  -  JETZT STICK ABZIEHEN' 'DarkYellow' @(
                    '',
                    'Stick abziehen - dann startet das Gerät von selbst neu.')
                $shown = $true
            }
            Wait-Live 2 'Warte, bis der Stick abgezogen ist' $t0 300 ''
        }
        Complete-Live
        if (Test-Path -LiteralPath ($stickRoot + '\')) {
            Log 'Stick nach 5 Min noch gesteckt - kein automatischer Neustart'
            Banner 'PROFIL DA  -  NEUSTART VON HAND' 'DarkYellow' @(
                '',
                'Stick abziehen, dann Gerät neu starten.')
            Read-Host '  Enter = Fenster schließen' | Out-Null
            exit 0
        }
        Banner 'OK  -  PROFIL DA  -  NEUSTART IN 15 s' 'DarkGreen' @(
            '',
            'Danach kommt die Schul-Anmeldung.',
            '[A] = nicht neu starten')
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
        $k = Read-KeyTimeout 15 'Neustart'
        if ($k -eq 'A') { Log 'Neustart abgebrochen'; Read-Host '  Enter = Fenster schließen' | Out-Null; exit 0 }
        # /f: offene Programme (z. B. "Program Manager" im OOBE) duerfen den Neustart nicht blockieren
        Log 'Neustart (shutdown /r /f /t 0)'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/r', '/f', '/t', '0' -WindowStyle Hidden
        exit 0
    }
    if ($wr.Assigned) {
        Log ('Nur Upload: Profil zugewiesen: ' + $wr.Profil)
        Banner 'OK  -  PROFIL DA' 'DarkGreen' @(
            '',
            'Jetzt Gerät zurücksetzen:',
            'Einstellungen > System > Wiederherstellung > PC zurücksetzen')
    } else {
        Log ('Nur Upload: Profil nach Wartezeit NICHT sicher zugewiesen, letzter Status: ' + $wr.LastTxt)
        Banner 'NOCH KEIN PROFIL' 'DarkYellow' @(
            '',
            'Upload ist fertig, das Profil fehlt noch.',
            'Später nochmal D:\go starten.')
    }
    Read-Host '  Enter = Fenster schließen' | Out-Null
    exit 0
}

Banner 'OK  -  STICK ABZIEHEN  -  nächstes Gerät' 'DarkGreen' @(
    '',
    ('Group Tag: ' + $cfg.GroupTag + $(if ($AssignUpn) { '   Benutzer: ' + $AssignUpn } else { '' })),
    'Gerät NICHT ausschalten.',
    'Es setzt sich selbst zurück, sobald das Profil da ist.')
$GreenAt = Get-Date

# ---------- 5. Auf Profil warten ----------
$wr = Wait-ApProfile
$assigned = $wr.Assigned
$lastTxt = $wr.LastTxt

if (-not $assigned) {
    Log ('Profil nach Wartezeit NICHT sicher zugewiesen, letzter Status: ' + $lastTxt)
    Banner 'NOCH KEIN PROFIL' 'DarkYellow' @(
        '',
        'Ohne Profil kommt nach dem Zurücksetzen das normale Windows-Setup.',
        '',
        'N = abbrechen, später nochmal go  (empfohlen)',
        'J = trotzdem zurücksetzen')
    $a = Read-Host '  J / N'
    if ($a -notmatch '^[jJyY]') { Log 'Abbruch durch Benutzer (kein Reset)'; exit 1 }
}

# Gruenen Hinweis mind. 60 s stehen lassen (damit man ihn sieht und den Stick abzieht)
$rest = 60 - [int]((Get-Date) - $GreenAt).TotalSeconds
if ($rest -gt 0) { Log ('Grün bleibt noch ' + $rest + ' s stehen'); Wait-Live $rest 'Profil da' (Get-Date) 0 'Zurücksetzen startet'; Complete-Live }
# ---------- 6. WLAN-Paket + Zuruecksetzen ohne Hersteller-Anpassungen ----------
Wait-Power
$ErrorActionPreference = 'Continue'
function Fail-Reset {
    param([string]$Msg)
    Log ('FEHLER Zurücksetzen: ' + $Msg)
    Banner 'FEHLER beim Zurücksetzen' 'DarkRed' @(
        '',
        'Autopilot-Upload ist OK, nur das Zurücksetzen ist nicht gestartet.',
        ('Grund: ' + $Msg),
        ('Log: ' + $LocalLog + ' und ' + $WipeLog),
        'Nochmal: Stick rein, Shift+F10, D:\go  (Upload wird übersprungen)',
        'Diagnose zum Abfotografieren: D:\diag')
    Read-Host '  Enter = Fenster schließen' | Out-Null
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
    # Intune-Richtlinie Security/AllowAddProvisioningPackage = 0 sperrt neue Pakete (auch fuer SYSTEM)
    $ppBlocked = $false
    try { $pv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Security' -Name 'AllowAddProvisioningPackage' -ErrorAction Stop; if ([int]$pv.AllowAddProvisioningPackage -eq 0) { $ppBlocked = $true } } catch { }
    if ($same) { Log 'WLAN-Paket ist bereits installiert (identisch) - provtool übersprungen' }
    elseif ($ppBlocked -and (Test-Path $persist)) {
        Log 'Intune sperrt Bereitstellungspakete (AllowAddProvisioningPackage=0) - vorhandenes WLAN-Paket bleibt, neues wird NICHT installiert'
        Write-Host ''
        Write-Host '  Hinweis: Intune sperrt neue Pakete auf diesem Gerät.' -ForegroundColor Yellow
        Write-Host '  Das vorhandene WLAN-Paket bleibt - Änderungen (z. B. lokaler Admin) kommen NICHT mit.' -ForegroundColor Yellow
        [void](Read-KeyTimeout 30 'beliebige Taste oder weiter')
    }
    elseif ($ppBlocked) {
        Log 'Intune sperrt Bereitstellungspakete (AllowAddProvisioningPackage=0) und es ist kein WLAN-Paket installiert'
        Banner 'ACHTUNG  -  WLAN-PAKET VON INTUNE GESPERRT' 'DarkYellow' @(
            '',
            'Intune verbietet auf diesem Gerät neue Bereitstellungspakete.',
            'Nach dem Zurücksetzen ist das Konfigurations-WLAN NICHT da:',
            'LAN-Kabel anstecken oder WLAN im Einrichtungsbildschirm von Hand wählen.')
        $a = Read-Host '  J = trotzdem zurücksetzen, Enter = abbrechen'
        if ($a -notmatch '^[jJyY]') { Fail-Reset 'WLAN-Paket von Intune gesperrt (AllowAddProvisioningPackage=0) - abgebrochen' }
        Log 'Trotzdem zurücksetzen (ohne WLAN-Paket) bestätigt'
    }
    else {
        $prov = Join-Path $env:SystemRoot 'System32\provtool.exe'
        if (-not (Test-Path $prov)) { Fail-Reset 'provtool.exe nicht gefunden' }
        Log ('provtool.exe ' + $TmpPkg + ' /quiet')
        $pr = Start-Process -FilePath $prov -ArgumentList ('"' + $TmpPkg + '"', '/quiet') -Wait -PassThru -WindowStyle Hidden
        Log ('provtool Exitcode: ' + $pr.ExitCode)
        if ($pr.ExitCode -ne 0) { Log 'provtool fehlgeschlagen - neuer Versuch als SYSTEM im Hilfsscript'; $SysPkg = $TmpPkg }
        elseif (-not (Test-Path $persist)) { Log ('Hinweis: ' + $persist + ' nicht gefunden - WLAN nach dem Zurücksetzen evtl. von Hand') }
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
    # Altes Paket NICHT entfernen: neues Paket hat eine eigene ID und wird zusaetzlich installiert
    $pr = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\provtool.exe') -ArgumentList ('"' + $pkg + '"', '/quiet') -Wait -PassThru -WindowStyle Hidden
    L ('provtool als SYSTEM Exitcode: ' + $pr.ExitCode)
    $ok = $false
    if (Test-Path $persist) { try { $ok = ((Get-FileHash -Path $persist -Algorithm SHA256).Hash -eq (Get-FileHash -Path $pkg -Algorithm SHA256).Hash) } catch { } }
    if (-not $ok) { L 'FEHLER: WLAN-Paket nicht installiert - kein Zuruecksetzen'; Set-Content -Path $res -Value ('ERR WLAN-Paket auch als SYSTEM nicht installiert (provtool ' + $pr.ExitCode + ')') -Encoding ASCII; exit 1 }
    L 'WLAN-Paket als SYSTEM installiert'
}
# 1. Persistierte Pakete aufraeumen - das Zuruecksetzen stellt alles aus ProgramData\Microsoft\Provisioning wieder her (MS Doku RemoteWipe CSP)
#    __RMOTHER__ = $true: alle Pakete ausser dem HUPilot-WLAN-Paket entfernen (alte Schul-/MDM-Pakete koennen Autopilot stoeren)
#    sonst: nur Pakete mit CleanPC (wuerden nach dem Zuruecksetzen erneut zuruecksetzen)
#    Zwei Schritte: erst ALLE Kandidaten nach C:\Recovery\HUPilot-PPKG-Backup\<Zeit> kopieren und pruefen, dann entfernen.
#    Gesperrt (Intune AllowRemoveProvisioningPackage=0) -> Datei verschieben (die Kopie liegt schon in der Sicherung)
$rmOther = __RMOTHER__
$keepPkg = '__KEEPPKG__'
$keepHash = '__KEEPHASH__'
$dir = Join-Path $env:ProgramData 'Microsoft\Provisioning'
$pbak = Join-Path 'C:\Recovery\HUPilot-PPKG-Backup' (Get-Date -Format 'yyyyMMdd-HHmmss')
$prov = $true
try { Import-Module Provisioning -ErrorAction Stop } catch { $prov = $false; L ('Provisioning-Modul: ' + $_.Exception.Message) }
$all = @()
try { $all = @(Get-ChildItem -Path $dir -Filter *.ppkg -File -ErrorAction Stop) } catch { L ('Pakete auflisten ' + $dir + ': ' + $_.Exception.Message) }
$cand = @()
foreach ($p in $all) {
    $h = ''; try { $h = (Get-FileHash -LiteralPath $p.FullName -Algorithm SHA256).Hash } catch { }
    if (($keepPkg -and $p.Name -ieq $keepPkg) -or ($keepHash -and $h -eq $keepHash) -or $p.Name -like 'HUPilot*') { L ('Paket bleibt (HUPilot): ' + $p.Name); continue }
    $why = ''
    if ($rmOther) { $why = 'fremdes Paket' }
    elseif ($prov) {
        $tmp = Join-Path $env:TEMP ('hupx_' + [guid]::NewGuid().ToString('N'))
        try {
            Export-ProvisioningPackage -Path $p.FullName -OutputFolder $tmp -AnswerFileOnly -Overwrite -ErrorAction Stop | Out-Null
            if (@(Get-ChildItem -Path $tmp -Recurse -File | Select-String -Pattern 'CleanPCWithoutRetainingUserData|CleanPCRetainingUserData' -List).Count) { $why = 'CleanPC' }
        } catch { L ('Paket pruefen ' + $p.Name + ': ' + $_.Exception.Message) }
        finally { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($why) { $cand += [pscustomobject]@{ File = $p; Why = $why; Hash = $h } } else { L ('Paket bleibt: ' + $p.Name) }
}
if ($cand.Count) {
    # Schritt 1: sichern + pruefen - schlaegt etwas fehl, wird NICHTS entfernt und nicht zurueckgesetzt
    try {
        New-Item -ItemType Directory -Path $pbak -Force -ErrorAction Stop | Out-Null
        foreach ($c in $cand) {
            $dst = Join-Path $pbak $c.File.Name
            Copy-Item -LiteralPath $c.File.FullName -Destination $dst -Force -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne $c.Hash) { throw ('Kopie von ' + $c.File.Name + ' fehlerhaft') }
        }
        L ('Pakete gesichert nach ' + $pbak + ': ' + (($cand | ForEach-Object { $_.File.Name }) -join ', '))
    } catch { L ('FEHLER Pakete sichern: ' + $_.Exception.Message + ' - nichts entfernt'); Set-Content -Path $res -Value ('ERR Pakete sichern: ' + $_.Exception.Message) -Encoding ASCII; exit 1 }
    # Schritt 2: entfernen (offiziell), sonst Datei loeschen - die Sicherung ist geprueft
    foreach ($c in $cand) {
        if ($prov) { try { Remove-ProvisioningPackage -Path $c.File.FullName -ErrorAction Stop | Out-Null } catch { L ('Remove-ProvisioningPackage ' + $c.File.Name + ': ' + $_.Exception.Message) } }
        if (Test-Path -LiteralPath $c.File.FullName) {
            try { Remove-Item -LiteralPath $c.File.FullName -Force -ErrorAction Stop; L ('Paket entfernt (' + $c.Why + ', Datei, Sicherung vorhanden): ' + $c.File.Name) }
            catch { L ('FEHLER Paket entfernen ' + $c.File.Name + ': ' + $_.Exception.Message); Set-Content -Path $res -Value ('ERR Paket ' + $c.File.Name + ' nicht entfernbar: ' + $_.Exception.Message) -Encoding ASCII; exit 1 }
        } else { L ('Paket entfernt (' + $c.Why + '): ' + $c.File.Name) }
    }
}
# 1b. Hersteller-Apps (z. B. McAfee) als vorinstallierte Store-App entfernen - das Zuruecksetzen stellt vorinstallierte
#     Store-Apps sonst aus seiner Sicherung wieder her (MS Doku Push-button reset). Fehler hier brechen nicht ab.
$rmApps = '__RMAPPS__'
if ($rmApps) {
    try {
        foreach ($pp in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -match $rmApps -or $_.PackageName -match $rmApps })) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -AllUsers -ErrorAction Stop | Out-Null; L ('Vorinstallierte App entfernt: ' + $pp.PackageName) }
            catch { L ('Vorinstallierte App ' + $pp.PackageName + ': ' + $_.Exception.Message) }
        }
    } catch { L ('Vorinstallierte Apps lesen: ' + $_.Exception.Message) }
    try {
        foreach ($ap in @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -match $rmApps })) {
            try { Remove-AppxPackage -Package $ap.PackageFullName -AllUsers -ErrorAction Stop; L ('App entfernt: ' + $ap.PackageFullName) }
            catch { L ('App ' + $ap.PackageFullName + ': ' + $_.Exception.Message) }
        }
    } catch { L ('Apps lesen: ' + $_.Exception.Message) }
}
# 2. Hersteller-Anpassungen wegschieben - das Zuruecksetzen spielt sonst wieder ein:
#    C:\Recovery\Customizations (Pakete mit Hersteller-Programmen), AutoApply, OEM (ResetConfig.xml = Herstellerskripte)
try {
    $bak = 'C:\Recovery\HUPilot-OEM-Backup'
    foreach ($src in 'C:\Recovery\Customizations', 'C:\Recovery\AutoApply', 'C:\Recovery\OEM') {
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
# Optionen fuer das SYSTEM-Script - VOR dem Ersetzen der Platzhalter bestimmen
$RmOther = ($cfg.RemoveOtherPackages -eq $true)
# Hersteller-Apps (Regex auf den App-Namen), Standard McAfee; "RemoveApps": "" schaltet es aus
$RmApps = 'McAfee'
if ($null -ne $cfg.RemoveApps) { $RmApps = [string]$cfg.RemoveApps }
try { [void][regex]::new($RmApps) } catch { Log ('RemoveApps ist kein gültiger Ausdruck - aus: ' + $RmApps); $RmApps = '' }
$KeepHash = ''
if (Test-Path -LiteralPath $TmpPkg) { try { $KeepHash = (Get-FileHash -LiteralPath $TmpPkg -Algorithm SHA256).Hash } catch { } }
try {
    Remove-Item -Path $WipeResult -Force -ErrorAction SilentlyContinue
    Set-Content -Path $WipePs1 -Value ($wipe.Replace('__SYSPKG__', $SysPkg).Replace('__RMOTHER__', $(if ($RmOther) { '$true' } else { '$false' })).Replace('__KEEPPKG__', ([string]$WlanPkgName).Replace("'", "''")).Replace('__KEEPHASH__', $KeepHash).Replace('__RMAPPS__', $RmApps.Replace("'", "''"))) -Encoding ASCII -ErrorAction Stop
} catch { Fail-Reset ('Hilfsscript schreiben: ' + $_.Exception.Message) }

# Fremde Bereitstellungspakete anzeigen (werden im SYSTEM-Script entfernt)
$other = @(Get-ChildItem -Path (Join-Path $env:ProgramData 'Microsoft\Provisioning') -Filter *.ppkg -ErrorAction SilentlyContinue | Where-Object { $_.Name -ine $WlanPkgName -and $_.Name -notlike 'HUPilot*' } | ForEach-Object { $_.Name })
if ($other.Count) {
    if ($RmOther) { Say ('Fremde Bereitstellungspakete werden entfernt: ' + ($other -join ', ')) 'Yellow' }
    else { Log ('Fremde Bereitstellungspakete bleiben (RemoveOtherPackages=false): ' + ($other -join ', ')) }
}
Banner 'ZURÜCKSETZEN STARTET' 'DarkBlue' @(
    '',
    'Hersteller-Anpassungen werden entfernt, dann setzt sich das Gerät zurück.',
    'Danach kommt das Schul-Anmeldefenster (Autopilot).')

# 6c. Als SYSTEM starten (geplante Aufgabe) und auf Ergebnis warten
$tn = 'HUPilot-Wipe'
# Aufgabe per XML: schtasks /SC ONCE startet sonst NICHT im Akkubetrieb (bleibt "In Warteschlange")
$taskXml = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>HUPilot - Zurücksetzen als SYSTEM</Description></RegistrationInfo>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "__PS1__"</Arguments></Exec></Actions>
</Task>
'@
$taskFile = Join-Path $env:SystemRoot 'Temp\HUPilot-Wipe.xml'
try { [System.IO.File]::WriteAllText($taskFile, $taskXml.Replace('__PS1__', $WipePs1), [System.Text.Encoding]::Unicode) } catch { Fail-Reset ('Aufgaben-XML schreiben: ' + $_.Exception.Message) }
try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction Stop } catch { try { & schtasks.exe /Delete /TN $tn /F 2>&1 | Out-Null } catch { } }
$regOk = $false
# 1. Weg: ScheduledTasks-Modul (XML inkl. Akkubetrieb erlaubt)
try {
    Register-ScheduledTask -TaskName $tn -Xml ([System.IO.File]::ReadAllText($taskFile)) -Force -ErrorAction Stop | Out-Null
    Log 'Aufgabe angelegt (Register-ScheduledTask)'; $regOk = $true
} catch { Log ('Register-ScheduledTask: ' + $_.Exception.Message) }
# 2. Weg: schtasks mit derselben XML
if (-not $regOk) {
    $o = cmd.exe /c ('schtasks /Create /TN "' + $tn + '" /XML "' + $taskFile + '" /F 2>&1')
    Log ('schtasks create: ' + (($o | Out-String).Trim()))
}
# Pruefen, ob die Aufgabe wirklich existiert (Exitcodes sind hier unzuverlaessig).
# Zuerst ueber das ScheduledTasks-Modul - schtasks /Query lieferte auf manchen Geraeten gar keine Ausgabe (13.10.2026)
$taskOk = $false
try { if (Get-ScheduledTask -TaskName $tn -ErrorAction Stop) { $taskOk = $true; Log 'Aufgabe vorhanden (Get-ScheduledTask)' } } catch { Log ('Get-ScheduledTask: ' + $_.Exception.Message) }
if (-not $taskOk) {
    $q = (cmd.exe /c ('schtasks /Query /TN "' + $tn + '" 2>&1') | Out-String).Trim()
    if ($q -match [regex]::Escape($tn)) { $taskOk = $true; Log 'Aufgabe vorhanden (schtasks)' }
    else { Fail-Reset ('Geplante Aufgabe nicht angelegt: ' + $(if ($q) { $q } else { '(schtasks ohne Ausgabe)' })) }
}
$started = $false
try { Start-ScheduledTask -TaskName $tn -ErrorAction Stop; $started = $true; Log 'Aufgabe gestartet (Start-ScheduledTask)' } catch { Log ('Start-ScheduledTask: ' + $_.Exception.Message) }
if (-not $started) {
    $o = cmd.exe /c ('schtasks /Run /TN "' + $tn + '" 2>&1')
    Log ('schtasks run: ' + (($o | Out-String).Trim()))
}
$res = ''
$t0 = Get-Date
for ($i = 0; $i -lt 60; $i++) {
    Wait-Live 3 'Zurücksetzen wird vorbereitet' $t0 180 ''
    if (Test-Path $WipeResult) { $res = ([string](Get-Content -Path $WipeResult -Raw)).Trim(); break }
}
Complete-Live
try { Get-Content -Path $WipeLog -ErrorAction Stop | ForEach-Object { Log ('[SYSTEM] ' + $_) } } catch { }
if (-not $res) { Fail-Reset 'keine Rückmeldung vom SYSTEM-Script (3 Min)' }
if ($res -notlike 'OK*') { Fail-Reset $res }
Log ('Zurücksetzen angenommen: ' + $res)
Write-Host ''
Write-Host '  Zurücksetzen angenommen - Neustart folgt in Kürze.' -ForegroundColor White
Wait-Live 900 'Warte auf Neustart' (Get-Date) 0 ''
Log 'Nach 15 Min kein Neustart - Zuruecksetzen hat nicht begonnen'
Protokoll 'FEHLER: Zuruecksetzen nach 15 Min nicht begonnen'
Banner 'ZURÜCKSETZEN NICHT GESTARTET' 'DarkRed' @(
    '',
    'Nach 15 Minuten kein Neustart.',
    'Foto von diesem Bild an den Admin.',
    ('Log: ' + $LocalLog + ' und ' + $WipeLog))
Read-Host '  Enter = Fenster schließen' | Out-Null
