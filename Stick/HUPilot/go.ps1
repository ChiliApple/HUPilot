# =====================================================================
# HUPilot  go.ps1  (Version: HUPilot\Config\version.json)
# https://github.com/ChiliApple/HUPilot
# ZIELMASCHINE: neues Windows-Geraet im OOBE (Shift+F10 -> D:\go)
# Ablauf (Schritt x von 6 in Anzeige und Log):
#   1. Pruefen: config.json, Seriennummer, Edition, WLAN-Paket, Hardware-Hash - erst DANN die Fragen
#      (Tag, Benutzer, Zuruecksetzen), eine Zusammenfassung, ab da ohne Rueckfrage (ausser Sonderfaellen)
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
$Ver        = '2.8.1'   # Rueckfall - massgeblich ist HUPilot\Config\version.json
try { $vj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Config\version.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; if ("$($vj.version)".Trim()) { $Ver = "$($vj.version)".Trim() } } catch { }
# Update dieses Sticks wurde abgebrochen (Mischstand moeglich) -> nicht starten
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Config\pull-journal.json')) {
    Write-Host ''
    # Abschlussbild wie ueberall (drei Saetze); die Funktionen dafuer sind hier noch nicht geladen
    Write-Host '  Was ist passiert:' -ForegroundColor Red
    Write-Host '    Das letzte Update dieses Sticks wurde abgebrochen.' -ForegroundColor Red
    Write-Host '  Was passiert jetzt:' -ForegroundColor Red
    Write-Host '    Nichts, das Gerät wurde nicht verändert.' -ForegroundColor Red
    Write-Host '  Was musst du tun:' -ForegroundColor Red
    Write-Host '    Stick am PC anstecken und HUPilot-Setup.cmd starten,' -ForegroundColor Red
    Write-Host '    es stellt den Stand wieder her.' -ForegroundColor Red
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
        Write-Host '  Was ist passiert:' -ForegroundColor Red
        Write-Host '    Der Start mit Adminrechten wurde abgebrochen.' -ForegroundColor Red
        Write-Host '  Was passiert jetzt:' -ForegroundColor Red
        Write-Host '    Nichts, das Gerät wurde nicht verändert.' -ForegroundColor Red
        Write-Host '  Was musst du tun:' -ForegroundColor Red
        Write-Host '    Eingabeaufforderung mit Rechtsklick >' -ForegroundColor Red
        Write-Host '    "Als Administrator ausführen" öffnen,' -ForegroundColor Red
        Write-Host '    dann  D:  und  go' -ForegroundColor Red
        try { Read-Host '  Enter = Fenster schließen' | Out-Null } catch { }
    }
    exit 1
}
# Arbeitsverzeichnis weg vom Stick: go wird meist aus D:\ gestartet. Wird der Stick nach "STICK ABZIEHEN" gezogen,
# ist das Arbeitsverzeichnis ungueltig - jeder spaetere Programmaufruf (schtasks, cmd, provtool) scheitert dann mit
# "Der Verzeichnisname ist ungueltig" (19.10.2026; vermutlich auch 13.10.2026: schtasks ohne Ausgabe)
try { Set-Location -LiteralPath (Join-Path $env:SystemRoot 'System32'); [Environment]::CurrentDirectory = (Join-Path $env:SystemRoot 'System32') } catch { }
$MinBattery = 50     # % Akku ohne Netzteil, darunter wird vor dem Zuruecksetzen gewartet
$Start      = Get-Date
# Alle Wartezeiten laufen ueber eine Stoppuhr: unabhaengig von Uhrzeit und Zeitzone. Im Einrichtungsbildschirm stellt
# Windows die Uhr oder Zeitzone teils mitten im Lauf um (Test 05.11.2026: -6 h beim WLAN-Verbinden -> Warten haette 6 h gedauert)
$script:Mono = [Diagnostics.Stopwatch]::StartNew()
$script:ClockOff = 0.0
function Get-Mono { return $script:Mono.Elapsed.TotalSeconds }
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
$ProfileRounds = 4      # Weg Zuruecksetzen: hoechstens so viele Warterunden zu $ProfileWaitMin, ohne Profil wird nie von selbst zurueckgesetzt
$GB = 'https://graph.microsoft.com/beta'

# ---------- Live-Anzeige beim Warten: EINE Zeile, die sich jede Sekunde selbst aktualisiert ----------
# Zeit laeuft mit, Countdown bis zur naechsten Abfrage, drehendes Zeichen = Programm lebt.
# Aendert sich der Status, bleibt die alte Zeile stehen (Verlauf) und eine neue beginnt.
$script:LiveOn = $false
$script:SpinI = 0
# Schritt-Anzeige vorne in der Live-Zeile (Show-Step setzt sie), kurz fuer schmale Fenster
$script:LivePre = ''
$script:LivePreShort = ''
function Format-Dauer {
    param([double]$Sec)
    $s = [int][math]::Max(0, [math]::Floor($Sec))
    return ('{0}:{1:00}' -f [int][math]::Floor($s / 60), ($s % 60))
}
function Show-Live {
    # -NoPre: ohne Schritt-Anzeige (Fragen)
    param([string]$Text, [switch]$NoPre)
    $c = '|/-\'[$script:SpinI % 4]
    $script:SpinI++
    $pre = $(if ($NoPre) { '' } else { $script:LivePre })
    $line = '  ' + $pre + $Text + '   ' + $c
    try {
        $w = [Console]::WindowWidth - 1
        if ($line.Length -gt $w -and -not $NoPre -and $script:LivePreShort) { $line = '  ' + $script:LivePreShort + $Text + '   ' + $c }
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
    # $Since: Startpunkt der Anzeige (Get-Mono), -1 = jetzt
    param([int]$Seconds, [string]$Text, [double]$Since = -1, [int]$MaxSec = 0, [string]$Next = 'nächste Abfrage')
    if ($Since -lt 0) { $Since = Get-Mono }
    $end = (Get-Mono) + $Seconds
    do {
        Test-ClockJump
        $now = Get-Mono
        $el = Format-Dauer ($now - $Since)
        $mx = $(if ($MaxSec -gt 0) { ' / ' + (Format-Dauer $MaxSec) } else { '' })
        $cd = $(if ($Next) { [string][int][math]::Max(0, [math]::Ceiling($end - $now)) + ' s' } else { '' })
        $l = $Text + '  |  ' + $el + $mx + $(if ($cd) { '  |  ' + $Next + ' in ' + $cd } else { '' })
        # schmales Fenster (grosse Schrift): kuerzer, damit Zeit und Countdown sichtbar bleiben
        $w = 120; try { $w = [Console]::WindowWidth - 6 - $script:LivePreShort.Length } catch { }
        if ($l.Length -gt $w) { $l = $Text + ' | ' + $el + $(if ($cd) { ' | ' + $cd } else { '' }) }
        Show-Live $l
        $ms = [int][math]::Min(1000, [math]::Max(0, ($end - (Get-Mono)) * 1000))
        if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
    } while ((Get-Mono) -lt $end)
}

# Tastaturpuffer leeren - vor JEDER Frage, damit ein doppeltes Enter nicht die naechste Frage mitbeantwortet
function Clear-KeyBuffer {
    try { if (-not [Console]::IsInputRedirected) { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } } catch { }
}
function Test-KeyAnswer {
    # Taste auswerten: 'ENTER' = Standard, gueltige Taste = Antwort, '' = keine gueltige Antwort (Countdown anhalten)
    # Ohne Liste gueltiger Tasten zaehlt jede Taste als Antwort
    param([string]$Key, [string[]]$Valid = @())
    if ($Key -eq 'ENTER') { return 'ENTER' }
    if (-not $Valid -or -not @($Valid).Count) { return $Key }
    if ($Key -and (@($Valid) -contains $Key)) { return $Key }
    return ''
}
function Read-KeyTimeout {
    # Tastendruck mit Zeitlimit; zeigt live "<Label> in x s". Rueckgabe: 'ENTER', Taste (gross) oder '' (Zeit um = Standard)
    # -Valid: gueltige Tasten. Eine andere Taste haelt den Countdown an, dann wird auf eine gueltige Taste oder Enter gewartet.
    # Umgeleitete Eingabe (kein Konsolenpuffer): sofort '' = Standard
    param([int]$Seconds = 10, [string]$Label = 'ohne Eingabe weiter', [string[]]$Valid = @(), [string]$Hint = '')
    Clear-KeyBuffer
    $until = (Get-Mono) + $Seconds
    $res = ''
    $halt = $false
    $haltAt = 0.0
    if (-not $Hint) { $Hint = 'Enter' + $(if (@($Valid).Count) { ' oder ' + ((@($Valid) | Where-Object { $_ -ne 'Y' }) -join ' / ') } else { '' }) }
    try {
        if ([Console]::IsInputRedirected) {
            if (-not $script:KeyRedirLogged) { Log 'Tastatur: Eingabe umgeleitet - es gilt jeweils der Standard'; $script:KeyRedirLogged = $true }
            Complete-Live
            return ''
        }
        while ($halt -or (Get-Mono) -lt $until) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $raw = $(if ($key.Key -eq 'Enter') { 'ENTER' } else { ([string]$key.KeyChar).ToUpper() })
                $a = Test-KeyAnswer $raw $Valid
                if ($a) { $res = $a; break }
                if (-not $halt) { $halt = $true; Log 'Countdown angehalten (Taste ohne Bedeutung)' }
                $haltAt = Get-Mono
            }
            # Angehalten und 60 s keine weitere Taste: Countdown laeuft von vorn (unbeaufsichtigtes Geraet bleibt nicht ewig stehen)
            if ($halt -and ((Get-Mono) - $haltAt) -ge 60) { $halt = $false; $until = (Get-Mono) + $Seconds; Log 'Countdown läuft wieder (60 s ohne Taste)' }
            if ($halt) { Show-Live -NoPre ('Countdown angehalten - bitte ' + $Hint + ' drücken') }
            elseif ($Label) { Show-Live -NoPre ($Label + ' in ' + [int][math]::Ceiling($until - (Get-Mono)) + ' s') }
            Start-Sleep -Milliseconds 200
        }
    } catch { Log ('Tastatur-Abfrage: ' + $_) }
    Complete-Live
    return $res
}
function Read-Line {
    # Read-Host mit vorher geleertem Tastaturpuffer
    param([string]$Prompt)
    Clear-KeyBuffer
    $r = ''
    try { $r = [string](Read-Host $Prompt) } catch { }
    return $r
}
function Wait-Close {
    [void](Read-Line '  Enter = Fenster schließen')
}

function Log {
    param([string]$Msg)
    # Sobald config.json geladen ist: bekannte Geheimnisse (samt Varianten) und Muster schon beim Schreiben ersetzen,
    # in C:\Windows\Temp\HUPilot.log und im Log am Stick. Der restliche Text bleibt fuer die Fehlersuche lesbar.
    if ($script:LogSecrets) { try { $Msg = Protect-ReportText $Msg $script:LogSecrets -Cap 0 } catch { } }
    $line = '{0}  [{1,5:N0}s]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (Get-Mono), $Msg
    try { Add-Content -Path $LocalLog -Value $line -Encoding UTF8 } catch { }
    if ($StickLog) { try { Add-Content -Path $StickLog -Value $line -Encoding UTF8 } catch { } }
}
# Uhrsprung erkennen: Abstand Uhrzeit zu Stoppuhr aendert sich um mehr als 60 s -> einmal ins Log
function Test-ClockJump {
    try {
        $off = ((Get-Date) - $Start).TotalSeconds - (Get-Mono)
        $d = $off - $script:ClockOff
        if ([math]::Abs($d) -gt 60) { $script:ClockOff = $off; Log ('Hinweis: Uhr am Gerät um ' + [int]$d + ' s verstellt (Windows/Zeitzone) - Wartezeiten laufen unabhängig weiter') }
    } catch { }
}
function Get-ReadableColor {
    # Nach einem Banner hat die Konsole einen farbigen Hintergrund (gruen, gelb, blau, rot): dort ist eine Akzentfarbe
    # (Cyan, Gelb, Gruen ...) schlecht lesbar -> Weiss. Auf schwarzem Hintergrund bleibt die gewuenschte Farbe.
    param([string]$Color, [string]$Bg = '')
    if (-not $Bg) { try { $Bg = [string]$Host.UI.RawUI.BackgroundColor } catch { $Bg = 'Black' } }
    if (-not $Bg -or $Bg -eq 'Black' -or $Bg -eq '-1') { return $Color }
    return 'White'
}
function Say {
    param([string]$Msg, [string]$Color = 'Gray')
    Complete-Live
    Write-Host ('  ' + $Msg) -ForegroundColor (Get-ReadableColor $Color)
    Log $Msg
}
# Fortschritt: "Schritt x von 6: <Klartext>" als Meldung und vorne in der Live-Zeile (beide Wege haben 6 Schritte:
# Pruefen, Internet, Anmelden, Hochladen, Profil, Zuruecksetzen bzw. Neustart)
$StepTotal = 6
function Show-Step {
    param([int]$N, [string]$Name)
    $script:LivePre = 'Schritt ' + $N + '/' + $StepTotal + ' ' + $Name + ' | '
    $script:LivePreShort = '' + $N + '/' + $StepTotal + ' | '
    $script:StepNo = $N; $script:StepName = $Name   # fuer den Bericht an den Admin
    Write-Host ''
    Say ('Schritt ' + $N + ' von ' + $StepTotal + ': ' + $Name) 'Cyan'
}
function Banner {
    param([string]$Text, [string]$Bg, [string[]]$Lines)
    Complete-Live
    try { $Host.UI.RawUI.BackgroundColor = $Bg; $Host.UI.RawUI.ForegroundColor = 'White'; Clear-Host } catch { }
    $hw = 56; try { $hw = [math]::Max(20, [math]::Min(56, [Console]::WindowWidth - 3)) } catch { }   # schmale Konsole: Rahmen nicht umbrechen
    Write-Host ''
    Write-Host ('  ' + ('#' * $hw))
    Write-Host ''
    Write-Host ('      ' + $Text)
    Write-Host ''
    Write-Host ('  ' + ('#' * $hw))
    Write-Host ''
    Write-Host ('  Seriennummer: ' + $Serial)
    foreach ($l in $Lines) { Write-Host ('  ' + $l) }
    Write-Host ''
}
function Protokoll {
    param([string]$Result)
    # Ergebnis ohne Umlaute (Setup vergleicht Texte); Datei als UTF-8 ohne BOM (Setup liest mit ReadAllLines = UTF-8),
    # damit Anzeigename oder Tag mit Umlaut nicht zu "?" werden. Reines ASCII bleibt Byte fuer Byte gleich.
    $Result = $Result.Replace([string][char]0xE4, 'ae').Replace([string][char]0xF6, 'oe').Replace([string][char]0xFC, 'ue').Replace([string][char]0xC4, 'Ae').Replace([string][char]0xD6, 'Oe').Replace([string][char]0xDC, 'Ue').Replace([string][char]0xDF, 'ss')
    try {
        $p = Join-Path $CfgDir 'logs\protokoll.csv'
        $u8 = New-Object System.Text.UTF8Encoding $false
        if (-not (Test-Path $p)) { [System.IO.File]::AppendAllText($p, "Zeit;Seriennr;Tenant;Tag;Ergebnis`r`n", $u8) }
        [System.IO.File]::AppendAllText($p, (('{0};{1};{2};{3};{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Serial, $cfg.Tenant, ([string]$cfg.GroupTag -replace ';', ','), $Result) + "`r`n"), $u8)
    } catch { }
}
# ---------- Einheitliches Abschlussbild: jeder Endzustand zeigt dieselben drei Saetze ----------
# "Was ist passiert", "Was passiert jetzt", "Was musst du tun" - kurz umbrochen fuer schmale Konsole mit grosser Schrift.
# Rot heisst: nicht zurueckgesetzt. Ausnahme nach dem Start des Zuruecksetzens (ResetNichtGestartet): dort steht ehrlich,
# dass es noch starten kann; was das SYSTEM-Script schon veraendert hat, steht im Satz "Was passiert jetzt".
function Split-NextStep {
    # Trennt "Ursache. Naechster Schritt." in @(Ursache, Schritt); ohne erkennbaren Schritt: @(Text, '')
    param([string]$Msg)
    $m = [regex]::Match([string]$Msg, '^(.*?\.)\s+((?:Am PC|Gerät neu starten|Einige Minuten|Nochmal|Zum |Admin:|Foto|Später|Stick neu|Für die Umstellung).*)$', 'Singleline')
    if ($m.Success) { return @($m.Groups[1].Value.Trim(), $m.Groups[2].Value.Trim()) }
    return @(([string]$Msg).Trim(), '')
}
function Get-EndText {
    # Drei Saetze je Endzustand; -Was / -Tun / -Jetzt ersetzen den Standard (Fehlertext, Grund, schon Veraendertes)
    param([string]$State, [string]$Was = '', [string]$Tun = '', [string]$Jetzt = '')
    $min = 20; if ($ProfileWaitMin) { $min = [int]$ProfileWaitMin }
    $rounds = 4; if ($ProfileRounds) { $rounds = [int]$ProfileRounds }
    $nr = 'Nichts, das Gerät wurde nicht zurückgesetzt.'
    $t = switch ($State) {
        'Fehler'                    { 'Ein Fehler ist aufgetreten.', $nr, 'Nochmal D:\go, klappt es wieder nicht: Foto von diesem Bild an den Admin.' }
        'FehlerReset'               { 'Der Upload ist fertig, aber das Zurücksetzen ist nicht gestartet.', $nr, 'Stick rein, Shift+F10, D:\go (Upload wird übersprungen), klappt es wieder nicht: D:\diag fotografieren und an den Admin.' }
        'ResetNichtGestartet'       { 'Windows hat das Zurücksetzen angenommen, es hat aber nach 15 Minuten nicht begonnen.', 'Es kann noch von selbst starten.', 'Gerät nicht benutzen und am Strom lassen, noch 15 Minuten warten. Startet es nicht neu: Foto von diesem Bild an den Admin.' }
        'Offline'                   { 'Der Hash ist nur am Stick gespeichert, nicht hochgeladen.', $nr, 'Stick abziehen und am PC im Setup "Hashes importieren".' }
        'Abbruch'                   { 'Der Vorgang wurde abgebrochen.', $nr, 'Zum Fortsetzen nochmal D:\go starten.' }
        'NeustartAbgebrochen'       { 'Der Neustart wurde mit A abgebrochen.', 'Nichts, das Gerät startet nicht von selbst neu.', 'Stick abziehen und das Gerät von Hand neu starten.' }
        'ResetWarten'               { 'Das Gerät ist in Autopilot hochgeladen.', ('Es wartet bis zu ' + ($min * $rounds) + ' Minuten auf das Profil und setzt sich erst dann selbst zurück, ohne Profil nicht.'), 'Stick abziehen und zum nächsten Gerät, dieses Gerät nicht ausschalten.' }
        'ResetStart'                { 'Upload und Autopilot-Profil sind fertig.', 'Das Gerät setzt sich in wenigen Minuten selbst zurück und startet neu.', 'Nichts, Gerät nicht ausschalten. Erst zum nächsten Gerät, wenn es neu startet (etwa 5 Minuten).' }
        'ResetStartOhneProfil'      { 'Der Upload ist fertig, zurückgesetzt wird ohne Profil (Taste J).', 'Das Gerät setzt sich in wenigen Minuten selbst zurück, danach kommt das normale Windows-Setup.', 'Nichts, Gerät nicht ausschalten.' }
        'KeinProfilEnde'            { 'Es ist noch kein Autopilot-Profil da.', 'Nichts, das Gerät wurde nicht zurückgesetzt und bleibt im Einrichtungsbildschirm.', 'Später Stick rein, Shift+F10, D:\go, kommt das Profil nie: den Admin fragen.' }
        'UploadWarten'              { 'Das Gerät ist in Autopilot hochgeladen, ohne Zurücksetzen.', ('HUPilot wartet bis zu ' + $min + ' Minuten auf das Autopilot-Profil.'), 'Stick abziehen und das Fenster offen lassen.' }
        'UploadStickAbziehen'       { 'Das Autopilot-Profil ist da.', 'Sobald der Stick abgezogen ist, startet das Gerät neu.', 'Stick jetzt abziehen.' }
        'UploadNeustart'            { 'Upload und Autopilot-Profil sind fertig.', 'Das Gerät startet in 15 Sekunden neu, danach kommt die Schul-Anmeldung.', 'Nichts, zum nächsten Gerät (A = nicht neu starten).' }
        'UploadNeustartVonHand'     { 'Das Profil ist da, aber der Stick steckt nach 5 Minuten noch.', 'Nichts, das Gerät startet nicht von selbst neu.', 'Stick abziehen und das Gerät von Hand neu starten.' }
        'UploadFertig'              { 'Upload und Autopilot-Profil sind fertig.', $nr, 'Gerät zurücksetzen: Einstellungen > System > Wiederherstellung > PC zurücksetzen.' }
        'UploadKeinProfil'          { 'Der Upload ist fertig, das Autopilot-Profil fehlt aber noch.', $nr, 'Später nochmal D:\go starten.' }
        'ProUmstellung'             { 'Windows Home wird gerade auf Pro umgestellt.', 'Das Gerät startet von selbst neu, auch mehrmals (sonst nach 10 Minuten Rot).', 'Nicht ausschalten, Rückfragen von Windows bestätigen, nach dem Neustart Shift+F10 und D:\go.' }
        'ProNeustart'               { 'Windows ist auf Pro umgestellt.', 'Das Gerät startet in 10 Sekunden neu.', 'Danach Shift+F10 und D:\go, die Antworten von eben werden angeboten.' }
        default                     { '', '', '' }
    }
    $r = @{ Was = [string]$t[0]; Jetzt = [string]$t[1]; Tun = [string]$t[2] }
    if ($Was) { $r.Was = $Was }
    if ($Tun) { $r.Tun = $Tun }
    if ($Jetzt) { $r.Jetzt = $Jetzt }
    return $r
}
$EndStates = @('Fehler', 'FehlerReset', 'ResetNichtGestartet', 'Offline', 'Abbruch', 'NeustartAbgebrochen', 'ResetWarten', 'ResetStart', 'ResetStartOhneProfil', 'KeinProfilEnde', 'UploadWarten', 'UploadStickAbziehen', 'UploadNeustart', 'UploadNeustartVonHand', 'UploadFertig', 'UploadKeinProfil', 'ProUmstellung', 'ProNeustart')
function Format-EndLines {
    # Drei Ueberschriften, darunter der Satz eingerueckt und auf die Fensterbreite umbrochen (Banner rueckt 2 Zeichen ein)
    param([hashtable]$E, [int]$Width = 0)
    if ($Width -le 0) { $Width = 80; try { $Width = [Console]::WindowWidth - 1 } catch { } }
    $max = [math]::Max(24, $Width - 6)
    $out = New-Object System.Collections.Generic.List[string]
    $labels = 'Was ist passiert:', 'Was passiert jetzt:', 'Was musst du tun:'
    $texts = [string]$E.Was, [string]$E.Jetzt, [string]$E.Tun
    for ($i = 0; $i -lt 3; $i++) {
        $out.Add($labels[$i])
        $line = ''
        foreach ($w in @($texts[$i] -split '\s+' | Where-Object { $_ })) {
            while ($w.Length -gt $max) { if ($line) { $out.Add('  ' + $line); $line = '' }; $out.Add('  ' + $w.Substring(0, $max)); $w = $w.Substring($max) }
            if (-not $line) { $line = $w }
            elseif (($line.Length + 1 + $w.Length) -le $max) { $line += ' ' + $w }
            else { $out.Add('  ' + $line); $line = $w }
        }
        if ($line) { $out.Add('  ' + $line) }
    }
    return $out.ToArray()
}
function Get-EndLines {
    param([string]$State, [string]$Was = '', [string]$Tun = '', [string]$Jetzt = '')
    return (Format-EndLines (Get-EndText $State $Was $Tun $Jetzt))
}
# ---------- Bericht an den Admin (Teams-Workflow-Webhook, config.json "TeamsWebhook", im Setup Feld "Teams-Webhook") ----------
# Bei roten Abschluessen und zwei gelben, bei denen der Admin handeln muss, geht von selbst eine Adaptive Card an den Admin.
# Ohne Internet landet sie als Datei in HUPilot\logs\outbox am Stick (Setup oder ein spaeterer Lauf sendet sie nach). Vertrag mit dem Setup:
#   Datei <yyyyMMdd-HHmmss>_<Seriennr>.json, UTF-8 ohne BOM, { v, created (UTC), source, level, title, lines[], log[] },
#   Inhalt schon bereinigt; nach erfolgreichem Senden geloescht. Lesbare Berichte werden NIE wegen ihres Alters verworfen
#   (ohne Internet stellt go die Uhr nicht, sie kann weit zurueckliegen), nur ueber 50 Dateien die aeltesten (mit Logzeile).
#   Unlesbare Dateien (kaputt, unbekanntes v, groesser als 256 KB) bleiben liegen und werden erst nach 30 Tagen verworfen.
#   Grenzen der Karte: Titel 200 Zeichen, 30 Zeilen zu 600, Logzeilen 400, ganze Nachricht unter 24 KB.
# Die Adresse ist ein Geheimnis (wer sie kennt, kann posten): nie ausgeben, nie ins Log. Jeder Fehler wird geschluckt.
# Senden aendert nichts an Zuruecksetzen, Wartezeiten, Exitcode oder Reihenfolge.
# Ausloesende Anlaesse mit Stufe: nicht jedes Gelb sendet, nur die Anlaesse in dieser Liste (erweiterbar ohne Umbau).
$script:ReportAnlaesse = @{
    Fehler              = 'Error'     # Fail (nicht bei bewusstem Nein des Benutzers, -NoReport)
    FehlerReset         = 'Error'     # Fail-Reset
    ResetNichtGestartet = 'Error'     # 15 Minuten nach dem Zuruecksetzen kein Neustart
    SecretAbgelaufen    = 'Warning'   # Anmeldung von Microsoft abgelehnt, Hash am Stick gespeichert
    SecretFalsch        = 'Warning'
    KeinProfilEnde      = 'Warning'   # kein Profil nach allen Warterunden
}
$script:ReportDone   = $false       # genau ein Bericht je Lauf
$script:ReportNetOk  = $false       # Internet in diesem Lauf bestaetigt (erst dann direkt senden)
$script:StepNo       = 0
$script:StepName     = ''
$ReportTimeoutSec = 8
$ReportMaxBytes   = 24000           # ganze Nachricht unter 24 KB (Microsoft nennt etwa 28 KB als Grenze)
$ReportLogLines   = 50
$ReportLogRead    = 400             # so viele Zeilen vom Ende des Logs lesen, daraus der aktuelle Lauf
$ReportLogSep     = "`n`n"          # Zeilentrenner im Log-Block, gleich im Setup (Teams-Markdown: einfacher Umbruch wird teils verschluckt)
$ReportTitleMax   = 200
$ReportLinesMax   = 30
$ReportLineLen    = 600
$ReportLogLen     = 400
$OutboxKeepDays   = 30              # nur fuer unlesbare Dateien
$OutboxMaxFiles   = 50
$OutboxSendMax    = 5
$OutboxFileMaxBytes = 262144        # groessere Dateien werden nicht gelesen
# Hostname der alten Office-365-Connector-Adressen (gibt es nicht mehr), gleich im Setup
$script:ReportOldHookHostRx = '(?i)(^|\.)webhook\.office\.com$'
function Test-WebhookUrl {
    # '' = gueltig, sonst Grund (ohne die Adresse)
    param([string]$Url)
    $u = ([string]$Url).Trim()
    if (-not $u) { return 'leer' }
    $x = $null
    if (-not [uri]::TryCreate($u, [UriKind]::Absolute, [ref]$x) -or $x.Scheme -ne 'https') { return 'keine https-Adresse' }
    if ($x.Host -match $script:ReportOldHookHostRx) { return 'alte Office-365-Connector-Adresse, die gibt es nicht mehr' }
    return ''
}
function Get-ReportSecrets {
    # Alles, was nie in Karte oder Datei darf (wortgleich ersetzt). MAK nicht hier: er wird auf die letzten 5 Zeichen gekuerzt.
    param($Cfg, [string]$Token = '')
    $s = New-Object System.Collections.Generic.List[string]
    if ($Cfg) {
        foreach ($k in 'ClientSecret', 'WlanKey', 'AdminPassword', 'Admin2Password', 'TeamsWebhook', 'TenantId', 'ClientId') { $v = ([string]$Cfg.$k).Trim(); if ($v.Length -ge 3) { $s.Add($v) } }
        # Hostname der Adresse steht in Fehlermeldungen ohne https:// ("Der Remotename konnte nicht aufgeloest werden: '<Host>'")
        $x = $null
        if ([uri]::TryCreate(([string]$Cfg.TeamsWebhook).Trim(), [UriKind]::Absolute, [ref]$x) -and $x.Host.Length -ge 3) { $s.Add($x.Host) }
        # Tenant-ID ohne Bindestriche steckt bei neuen Workflow-Adressen im Hostnamen
        $tid = (([string]$Cfg.TenantId).Trim()) -replace '-', ''
        if ($tid.Length -ge 3) { $s.Add($tid) }
    }
    if (([string]$Token).Length -ge 3) { $s.Add([string]$Token) }
    # Varianten jedes Werts: URL-kodiert (Formular, Adresse) und JSON-escaped (Fehlermeldungen von Graph und Entra)
    foreach ($v in @($s.ToArray())) {
        try { $e = [uri]::EscapeDataString($v); if ($e -cne $v) { $s.Add($e) } } catch { }
        try { $j = (ConvertTo-Json -InputObject $v -Compress); $j = $j.Substring(1, $j.Length - 2); if ($j -cne $v) { $s.Add($j) } } catch { }
        $j2 = $v.Replace('\', '\\').Replace('"', '\"').Replace('/', '\/'); if ($j2 -cne $v) { $s.Add($j2) }
    }
    # laengste zuerst (ein Geheimnis kann Teil eines anderen sein); nicht -Unique mit -Property, das wirft gleich lange weg
    return @($s | Select-Object -Unique | Sort-Object -Property Length -Descending)
}
function Protect-ReportText {
    # Bereinigung vor Karte und Datei: Schluessel auf die letzten 5 Zeichen, Geheimnisse und signierte Adressen weg.
    # -Cap: grobe Grenze VOR den Mustern (lange Zeilen machen sie langsam); das letzte, evtl. angeschnittene Wort und ein am
    # Ende stehender Anfang eines bekannten Geheimnisses (Geheimnisse mit Leerzeichen) fallen weg, nie ein Teilstueck.
    # Das Log ruft mit -Cap 0 (volle Zeile bleibt fuer die Fehlersuche).
    param([string]$Text, [string[]]$Secrets = @(), [int]$Cap = 4000)
    $t = [string]$Text
    if (-not $t) { return '' }
    if ($Cap -gt 0 -and $t.Length -gt $Cap) {
        $t = $t.Substring(0, $Cap)
        $i = $t.LastIndexOfAny([char[]]@(' ', "`t", "`r", "`n"))
        $t = $(if ($i -ge 0) { $t.Substring(0, $i + 1) } else { '' })
        foreach ($x in @($Secrets)) { $x = [string]$x; for ($k = [math]::Min($x.Length - 1, $t.Length); $k -ge 3; $k--) { if ($t.EndsWith($x.Substring(0, $k), [StringComparison]::OrdinalIgnoreCase)) { $t = $t.Substring(0, $t.Length - $k); break } } }
        $t = $t.TrimEnd() + ' ...'
    }
    $t = [regex]::Replace($t, '[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}', { param($m) '*****-' + $m.Value.Substring($m.Value.Length - 5) })
    foreach ($x in @($Secrets)) { if ([string]$x) { $t = [regex]::Replace($t, [regex]::Escape([string]$x), '***', 'IgnoreCase') } }
    $t = [regex]::Replace($t, '(?i)https://\S*[?&]sig[=]\S*', '(Adresse entfernt)')
    $t = [regex]::Replace($t, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*', '***')
    # JSON-Felder mit Geheimnis: "client_secret": "...", auch escaped (\"client_secret\":\"...\")
    $t = [regex]::Replace($t, '(?i)((?<!\\)"(?:client_secret|clientsecret|access_token|refresh_token|password|adminpassword|admin2password|wlankey|teamswebhook)"\s*:\s*")((?:[^"\\]|\\.)*)', '$1***')
    $t = [regex]::Replace($t, '(?i)(\\"(?:client_secret|clientsecret|access_token|refresh_token|password|adminpassword|admin2password|wlankey|teamswebhook)\\"\s*:\s*\\")((?:(?!\\").)*)', '$1***')
    $t = [regex]::Replace($t, '(?i)(Bearer|client_secret[=:]|access_token["'':= ]+)\s*[^\s"''&]+', '$1 ***')
    return $t
}
function Get-SafeFileName([string]$Text) {
    $s = [regex]::Replace(([string]$Text).Trim(), '[^A-Za-z0-9._-]', '_')
    if (-not $s) { $s = 'unbekannt' }
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40) }
    return $s
}
function Get-CutText([string]$Text, [int]$Max) {
    # kuerzt auf hoechstens $Max Zeichen, mit " ..." am Ende
    $s = [string]$Text
    if ($Max -lt 8 -or $s.Length -le $Max) { return $s }
    return ($s.Substring(0, $Max - 4) + ' ...')
}
function Get-ReportLog {
    # Log fuer den Bericht: nur der aktuelle Lauf (ab dem letzten START), gleiche Meldungen nur einmal mit Zaehler
    # (z. B. der Internet-Test alle 10 Sekunden), davon die letzten $Max Zeilen. Ohne START-Zeile bleibt alles.
    param([string[]]$Lines = @(), [int]$Max = 50)
    $all = @(@($Lines) | Where-Object { ([string]$_).Trim() })
    $s = -1
    for ($i = 0; $i -lt $all.Count; $i++) { if ([string]$all[$i] -match '===== START go\.ps1') { $s = $i } }
    if ($s -gt 0) { $all = @($all[$s..($all.Count - 1)]) }
    $out = New-Object System.Collections.Generic.List[string]
    $idx = @{}; $cnt = @{}
    foreach ($l in $all) {
        $k = ([string]$l) -replace '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\s+\[\s*[\d.,]+s\]\s+', ''
        if ($idx.ContainsKey($k)) { $cnt[$k] = [int]$cnt[$k] + 1; continue }
        $idx[$k] = $out.Count; $cnt[$k] = 1; $out.Add([string]$l)
    }
    foreach ($k in @($idx.Keys)) { if ([int]$cnt[$k] -gt 1) { $out[[int]$idx[$k]] = $out[[int]$idx[$k]] + '  (' + [int]$cnt[$k] + '-mal)' } }
    return @($out | Select-Object -Last $Max)
}
function New-ReportCard {
    # Adaptive Card 1.4: Titel farbig, Zeilen, Log als ein Textblock in Festbreite, Fusszeile. Immer unter $MaxBytes (UTF-8):
    # zuerst das Log von vorne kuerzen (die letzten Zeilen bleiben, mit "(gekürzt)"), reicht das nicht, die Zeilen von hinten.
    param([string]$Title, [string[]]$Lines = @(), [string[]]$Log = @(), [string]$Level = 'Error', [string]$Footer = '', [int]$MaxBytes = 24000)
    $color = switch ($Level) { 'Error' { 'Attention' } 'Warning' { 'Warning' } 'OK' { 'Good' } default { 'Accent' } }
    $tt = Get-CutText $Title $ReportTitleMax
    $ft = Get-CutText $Footer $ReportTitleMax
    $all = @(@($Lines) | Where-Object { ([string]$_).Trim() } | ForEach-Object { Get-CutText ([string]$_) $ReportLineLen })
    $ls = @($all | Select-Object -First $ReportLinesMax)
    $lsShort = ($all.Count -gt $ls.Count)
    $lg = @(@($Log) | Where-Object { ([string]$_).Trim() } | ForEach-Object { Get-CutText ([string]$_) $ReportLogLen })
    $short = $false
    while ($true) {
        $body = New-Object System.Collections.Generic.List[object]
        $body.Add([ordered]@{ type = 'TextBlock'; text = [string]$tt; weight = 'Bolder'; size = 'Medium'; wrap = $true; color = $color })
        foreach ($l in $ls) { $body.Add([ordered]@{ type = 'TextBlock'; text = [string]$l; wrap = $true; spacing = 'Small' }) }
        if ($lsShort) { $body.Add([ordered]@{ type = 'TextBlock'; text = '(gekürzt)'; wrap = $true; spacing = 'Small'; isSubtle = $true }) }
        if ($lg.Count) {
            $txt = (@($(if ($short) { '(gekürzt)' })) + $lg | Where-Object { $_ }) -join $ReportLogSep
            $body.Add([ordered]@{ type = 'TextBlock'; text = $txt; fontType = 'Monospace'; size = 'Small'; wrap = $true; spacing = 'Medium' })
        }
        if ($ft) { $body.Add([ordered]@{ type = 'TextBlock'; text = [string]$ft; isSubtle = $true; size = 'Small'; wrap = $true; spacing = 'Medium' }) }
        $card = [ordered]@{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; body = $body.ToArray() }
        $msg = [ordered]@{ type = 'message'; attachments = @([ordered]@{ contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null; content = $card }) }
        $json = ConvertTo-Json -InputObject $msg -Depth 10 -Compress
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -lt $MaxBytes) { return $json }
        if ($lg.Count) {
            $short = $true
            $lg = @($lg | Select-Object -Skip ([math]::Max(1, [int][math]::Ceiling($lg.Count / 10))))
        } elseif ($ls.Count) {
            $lsShort = $true
            $ls = @($ls | Select-Object -First ([math]::Max(0, $ls.Count - [math]::Max(1, [int][math]::Ceiling($ls.Count / 10)))))
        } else { return $json }   # nur Titel und Fusszeile (je hoechstens 200 Zeichen): immer weit unter der Grenze
    }
}
function Invoke-ReportPost {
    # Die einzige Stelle, die den Bericht ins Netz schickt: ohne Weiterleitung, Body als UTF-8-Bytes
    param([string]$Url, [byte[]]$Body, [int]$TimeoutSec = 8)
    return (Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $Url -Method Post -Body $Body -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop)
}
function Send-TeamsCard {
    # '' = gesendet (HTTP 2xx), sonst Grund ohne Adresse. Eine Weiterleitung zaehlt als Fehlschlag. Wirft nie.
    param([string]$Url, [string]$Json, [int]$TimeoutSec = 8, [string[]]$Secrets = @())
    try {
        $why = Test-WebhookUrl $Url
        if ($why) { return ('Adresse ungültig: ' + $why) }
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $resp = Invoke-ReportPost $Url.Trim() ([System.Text.Encoding]::UTF8.GetBytes([string]$Json)) $TimeoutSec
        $sc = 0; try { $sc = [int]$resp.StatusCode } catch { }
        if ($sc -lt 200 -or $sc -ge 300) { return ('Senden fehlgeschlagen: Antwort HTTP ' + $sc + $(if ($sc -ge 300 -and $sc -lt 400) { ' (Weiterleitung)' } else { '' })) }
        return ''
    } catch {
        $m = [string]$_.Exception.Message
        if ($Url) { $m = $m.Replace($Url.Trim(), '(Webhook)') }
        $m = $m -replace 'https?://\S+', '(Webhook)'
        return ('Senden fehlgeschlagen: ' + (Protect-ReportText $m $Secrets))
    }
}
function Get-OutboxDir { return (Join-Path $CfgDir 'logs\outbox') }
function Limit-Outbox {
    # Hoechstens $Max Dateien, die aeltesten gehen zuerst (mit Logzeile). Nie wegen des Alters. Wirft nie.
    param([string]$Dir, [int]$Max = 50)
    $n = 0
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
        $all = @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc, Name)
        for ($i = 0; $i -lt ($all.Count - $Max); $i++) { try { Remove-Item -LiteralPath $all[$i].FullName -Force -ErrorAction Stop; $n++ } catch { } }
        if ($n) { Log ('Berichte an den Admin am Stick: mehr als ' + $Max + ' Dateien, ' + $n + ' älteste verworfen') }
    } catch { }
    return $n
}
function Save-OutboxReport {
    # Bericht als Datei am Stick ablegen. Rueckgabe: Pfad oder '' (Stick fehlt oder nicht beschreibbar). Wirft nie.
    param([string]$Dir, [hashtable]$Report, [string]$SerialNo = '', [datetime]$Now = [datetime]::UtcNow)
    try {
        $root = Split-Path (Split-Path $Dir -Parent) -Parent
        if (-not (Test-Path -LiteralPath (Join-Path $root 'config.json' -ErrorAction Stop))) { return '' }   # Stick abgezogen oder fremdes Laufwerk
        New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null
        $o = [ordered]@{ v = 1; created = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ'); source = 'go'; level = [string]$Report.Level; title = [string]$Report.Title; lines = @($Report.Lines | ForEach-Object { [string]$_ }); log = @($Report.Log | ForEach-Object { [string]$_ }) }
        $p = Join-Path $Dir ($Now.ToLocalTime().ToString('yyyyMMdd-HHmmss') + '_' + (Get-SafeFileName $SerialNo) + '.json')
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $o -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        [void](Limit-Outbox $Dir $OutboxMaxFiles)
        if (-not (Test-Path -LiteralPath $p)) { return '' }
        return $p
    } catch { return '' }
}
function Read-OutboxFile {
    # @{ Ok; Report; Why } - nie werfen; zu gross, kaputt oder unbekanntes v = nicht lesbar
    param($File)
    try {
        if ([long]$File.Length -gt $OutboxFileMaxBytes) { return @{ Ok = $false; Why = 'größer als 256 KB' } }
        $r = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $r) { return @{ Ok = $false; Why = 'leer' } }
        if (([string]$r.v).Trim() -ne '1') { return @{ Ok = $false; Why = 'unbekannte Version' } }
        return @{ Ok = $true; Report = $r }
    } catch { return @{ Ok = $false; Why = 'nicht lesbar' } }
}
function Get-ReportFooter {
    param([string]$Name, [datetime]$When)
    return ((@(([string]$Name).Trim(), $When.ToString('dd.MM.yyyy HH:mm'), ('HUPilot go ' + $Ver)) | Where-Object { $_ }) -join '  |  ')
}
function Send-Outbox {
    # Liegengebliebene Berichte nachsenden: hoechstens $Max gesendete, aelteste zuerst, nach dem ersten Fehlschlag Schluss
    # (haelt den Ablauf nie lange auf). Unlesbare zaehlen nicht mit und bleiben liegen (nach 30 Tagen verworfen, auch nach einem Fehlschlag).
    # Erst senden, dann aufraeumen (Grenze 50). Rueckgabe: Zahl gesendeter Berichte. Wirft nie.
    param([string]$Dir, [string]$Url, [int]$Max = 5, [int]$TimeoutSec = 8, [string[]]$Secrets = @(), [string]$Name = '')
    $sent = 0
    try {
        if (Test-WebhookUrl $Url) { return 0 }
        if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
        $stop = $false
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc, Name)) {
            $rd = Read-OutboxFile $f
            if (-not $rd.Ok) {
                if (([datetime]::UtcNow - $f.LastWriteTimeUtc).TotalDays -gt $OutboxKeepDays) {
                    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; Log ('Bericht am Stick ' + $rd.Why + ' und älter als ' + $OutboxKeepDays + ' Tage, verworfen: ' + $f.Name) } catch { }
                } else { Log ('Bericht am Stick ' + $rd.Why + ', bleibt liegen: ' + $f.Name) }
                continue
            }
            if ($stop -or $sent -ge $Max) { continue }
            $r = $rd.Report
            $when = [datetime]::UtcNow
            # PowerShell 7 macht aus "created" beim Einlesen schon ein DateTime, 5.1 laesst den Text
            try {
                if ($r.created -is [datetime]) { $when = $r.created.ToUniversalTime() }
                else { $when = [datetime]::ParseExact([string]$r.created, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal') }
            } catch { }
            $title = ([string]$r.title).Trim()
            if (-not $title) { $title = $(if (([string]$Name).Trim()) { ([string]$Name).Trim() } else { 'HUPilot' }) + ': Bericht vom Stick' }
            $lines = @(@($r.lines) | ForEach-Object { Protect-ReportText ([string]$_) $Secrets })
            $logl = @(@($r.log) | ForEach-Object { Protect-ReportText ([string]$_) $Secrets })
            $json = New-ReportCard -Title (Protect-ReportText $title $Secrets) -Lines $lines -Log $logl -Level ([string]$r.level) -Footer (Get-ReportFooter $Name $when.ToLocalTime()) -MaxBytes $ReportMaxBytes
            $why = Send-TeamsCard $Url $json $TimeoutSec $Secrets
            if ($why) { Log ('Bericht nachsenden: ' + $why + ' - bleibt am Stick'); $stop = $true; continue }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { Log ('Bericht gesendet, Datei nicht gelöscht: ' + $f.Name) }
            $sent++
        }
        [void](Limit-Outbox $Dir $OutboxMaxFiles)
    } catch { Log ('Bericht nachsenden: ' + (Protect-ReportText (([string]$_.Exception.Message) -replace 'https?://\S+', '(Webhook)') $Secrets)) }
    return $sent
}
function Get-DeviceReportLines {
    # Hersteller/Modell und Windows-Edition/Build fuer den Bericht; Fehler egal
    $hw = ''; $win = ''
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $hw = (([string]$cs.Manufacturer).Trim() + ' ' + ([string]$cs.Model).Trim()).Trim() } catch { }
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $win = ([string]$cv.EditionID + ' Build ' + [string]$cv.CurrentBuild + $(if ([string]$cv.UBR) { '.' + [string]$cv.UBR } else { '' })).Trim()
    } catch { }
    return @{ Hw = $hw; Win = $win }
}
function New-GoReport {
    # Titel, Klartextzeilen und letzte Logzeilen eines Endzustands, alles bereinigt
    param([hashtable]$End, [string]$Level = 'Error', [string]$SerialNo = '', $Cfg = $null, [string[]]$LogTail = @(), [hashtable]$Dev = @{}, [int]$Step = 0, [string]$StepText = '', [string[]]$Secrets = @())
    $sn = $(if (([string]$SerialNo).Trim()) { ([string]$SerialNo).Trim() } else { '(Seriennummer unbekannt)' })
    # Ein Kanal fuer mehrere Schulen: Anzeigename vorne im Titel, sonst "HUPilot"
    $who = 'HUPilot'; if ($Cfg -and ([string]$Cfg.Tenant).Trim()) { $who = ([string]$Cfg.Tenant).Trim() }
    $title = $who + $(switch ($Level) { 'Warning' { ': Hinweis am Gerät ' } 'OK' { ': Gerät fertig ' } default { ': Fehler am Gerät ' } }) + $sn
    $l = New-Object System.Collections.Generic.List[string]
    if ($Cfg -and ([string]$Cfg.Tenant).Trim()) { $l.Add('Anzeigename: ' + ([string]$Cfg.Tenant).Trim()) }
    if ($Dev.Hw) { $l.Add('Gerät: ' + $Dev.Hw) }
    if ($Dev.Win) { $l.Add('Windows: ' + $Dev.Win) }
    $l.Add('HUPilot go: ' + $Ver)
    if ($Step -gt 0) { $l.Add('Schritt ' + $Step + ' von ' + $StepTotal + $(if ($StepText) { ': ' + $StepText } else { '' })) }
    if ($End) {
        if ([string]$End.Was) { $l.Add('Was ist passiert: ' + $End.Was) }
        if ([string]$End.Jetzt) { $l.Add('Was passiert jetzt: ' + $End.Jetzt) }
        if ([string]$End.Tun) { $l.Add('Was musst du tun: ' + $End.Tun) }
    }
    if ($Cfg -and ([string]$Cfg.GroupTag).Trim()) { $l.Add('Tag: ' + ([string]$Cfg.GroupTag).Trim()) }
    # Erst bereinigen, dann kuerzen: sonst bliebe an der Schnittstelle ein Teilstueck eines Geheimnisses stehen
    return @{
        Level = $Level
        Title = (Get-CutText (Protect-ReportText $title $Secrets) $ReportTitleMax)
        Lines = @($l | Select-Object -First $ReportLinesMax | ForEach-Object { Get-CutText (Protect-ReportText $_ $Secrets) $ReportLineLen })
        Log   = @(@($LogTail) | ForEach-Object { Get-CutText (Protect-ReportText ([string]$_) $Secrets) $ReportLogLen })
    }
}
function Send-GoReport {
    # Bericht zu einem Endzustand: einmal je Lauf, nur fuer Anlaesse in $ReportAnlaesse und mit gueltigem Teams-Webhook.
    # Rueckgabe: @{ Text; Color } fuer die Zeile unter dem Abschlussbild, $null = keine Zeile. Wirft nie.
    param([hashtable]$End, [string]$Anlass = 'Fehler')
    try {
        if ($script:ReportDone) { return $null }
        $Level = [string]$script:ReportAnlaesse[$Anlass]
        if (-not $Level) { return $null }
        if (-not $cfg) { return $null }
        $url = ([string]$cfg.TeamsWebhook).Trim()
        if (-not $url) { return $null }
        $script:ReportDone = $true
        $why = Test-WebhookUrl $url
        if ($why) {
            Log ('Bericht an den Admin: Feld Teams-Webhook in config.json ungültig (' + $why + ') - kein Bericht')
            return @{ Text = 'Hinweis: Das Feld Teams-Webhook am Stick ist ungültig, es geht kein Bericht an den Admin. Im Setup das Feld Teams-Webhook prüfen und den Stick neu bespielen.'; Color = 'Gray'; Sent = 'ungueltig' }
        }
        $sec = Get-ReportSecrets $cfg ([string]$script:tok)
        $tail = @(); try { $tail = @(Get-ReportLog @(Get-Content -LiteralPath $LocalLog -Tail $ReportLogRead -Encoding UTF8 -ErrorAction Stop) $ReportLogLines) } catch { }
        $rep = New-GoReport -End $End -Level $Level -SerialNo $Serial -Cfg $cfg -LogTail $tail -Dev (Get-DeviceReportLines) -Step $script:StepNo -StepText $script:StepName -Secrets $sec
        if ($script:ReportNetOk) {
            Write-Host '  Sende Bericht an den Admin ...' -ForegroundColor (Get-ReadableColor 'Gray')
            $json = New-ReportCard -Title $rep.Title -Lines $rep.Lines -Log $rep.Log -Level $Level -Footer (Get-ReportFooter ([string]$cfg.Tenant) (Get-Date)) -MaxBytes $ReportMaxBytes
            $r = Send-TeamsCard $url $json $ReportTimeoutSec $sec
            if (-not $r) { Log ('Bericht an den Admin gesendet (' + $Anlass + ')'); return @{ Text = 'Bericht an den Admin gesendet.'; Color = 'Green'; Sent = 'gesendet' } }
            Log ('Bericht an den Admin: ' + $r)
        } else { Log 'Bericht an den Admin: in diesem Lauf kein Internet - wird am Stick gespeichert' }
        $p = Save-OutboxReport (Get-OutboxDir) $rep $Serial
        if ($p) { Log ('Bericht an den Admin am Stick gespeichert: logs\outbox\' + (Split-Path $p -Leaf)); return @{ Text = 'Bericht am Stick gespeichert, wird beim nächsten Mal mit Internet gesendet.'; Color = 'Yellow'; Sent = 'gespeichert' } }
        Log 'Bericht an den Admin: nicht gesendet und am Stick nicht speicherbar (Stick fehlt oder schreibgeschützt) - verworfen'
        return $null
    } catch {
        try { $m = ([string]$_.Exception.Message) -replace 'https?://\S+', '(Webhook)'; if ($sec) { $m = Protect-ReportText $m $sec }; Log ('Bericht an den Admin: ' + $m) } catch { }
        return $null
    }
}
function Write-ReportLine {
    param($R)
    if ($R -and $R.Text) { Write-Host ('  ' + $R.Text) -ForegroundColor (Get-ReadableColor $R.Color) }
}
function Fail {
    # Rot: nichts wurde zurueckgesetzt. "Ursache. Naechster Schritt." wird auf "Was ist passiert" und "Was musst du tun" verteilt.
    # -NoReport: Abbruch nach bewusstem Nein des Benutzers, kein Bericht an den Admin
    param([string]$Msg, [string]$Tun = '', [switch]$NoReport)
    Log ('FEHLER: ' + $Msg)
    Protokoll ('FEHLER: ' + $Msg)
    $sp = Split-NextStep $Msg
    if (-not $Tun) { $Tun = $sp[1] }
    Banner 'FEHLER  -  NICHT ZURÜCKGESETZT' 'DarkRed' (@('') + (Get-EndLines 'Fehler' $sp[0] $Tun) + @('', ('Log: ' + $LocalLog)))
    if ($NoReport) { Log 'Kein Bericht an den Admin: Abbruch auf Wunsch des Benutzers' }
    else { Write-ReportLine (Send-GoReport (Get-EndText 'Fehler' $sp[0] $Tun) 'Fehler') }
    Wait-Close
    exit 1
}
function Stop-ByUser {
    # Abbruch durch den Benutzer: gelb, nichts zurueckgesetzt
    param([string]$Was, [string]$State = 'Abbruch', [int]$Code = 1, [string]$Tun = '')
    Log ('Abbruch durch Benutzer: ' + $Was)
    Banner 'ABGEBROCHEN  -  NICHT ZURÜCKGESETZT' 'DarkYellow' (@('') + (Get-EndLines $State $Was $Tun))
    Wait-Close
    exit $Code
}
function Get-ErrText {
    param($Err)
    $m = $Err.Exception.Message
    if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) { $m = $Err.ErrorDetails.Message }
    return $m
}
function Get-ErrCode {
    # Kurzform eines Fehlers fuer das Abschlussbild: HTTP-Status und Fehlercode von Graph/Entra, nie der rohe (englische/JSON) Text
    param($Err)
    $parts = New-Object System.Collections.Generic.List[string]
    try { $sc = [int]$Err.Exception.Response.StatusCode; if ($sc -gt 0) { $parts.Add('HTTP ' + $sc) } } catch { }
    $m = ''; try { $m = [string](Get-ErrText $Err) } catch { }
    $c = ''
    try { $j = $m | ConvertFrom-Json -ErrorAction Stop; $c = [string]$j.error.code; if (-not $c) { $c = [string]$j.error } } catch { }
    if ($c -and $c -notmatch '^[A-Za-z0-9_.]{1,60}$') { $c = '' }
    if (-not $c -and $m -match '\b(AADSTS\d+)\b') { $c = $Matches[1] }
    if ($c) { $parts.Add($c) }
    if (-not $parts.Count) { return 'Fehlercode unbekannt, Details im Log' }
    return ($parts -join ' ')
}
function Get-ErrScreen {
    # Roher Fehler ins Log, fuer das Bild nur die Kurzform (Get-ErrCode)
    param($Err, [string]$Ctx)
    try { Log ($Ctx + ': ' + (Get-ErrText $Err)) } catch { }
    return (Get-ErrCode $Err)
}
function Get-ImportErrorText {
    # Klartext fuer bekannte Importfehler von Windows Autopilot, Quelle Microsoft Learn
    # "Error 806 or 808 when you import Windows Autopilot device CSV files in Intune":
    #   806 ZtdDeviceAlreadyAssigned       = Geraet ist schon im eigenen Tenant registriert
    #   808 ZtdDeviceAssignedToOtherTenant = Geraet ist einem anderen Tenant zugeordnet
    # Laut Microsoft kann bei beiden auch ein alter Datensatz im eigenen Tenant/Intune die Ursache sein
    # (learn.microsoft.com/troubleshoot/mem/intune/device-enrollment/import-windows-autopilot-device-csv-files-errors).
    # Rueckgabe @{ Nr; Was; Tun; Log } oder $null (andere Fehler bleiben wie bisher). Der rohe Code bleibt im Text.
    param([string]$Code, [string]$Name)
    $Code = ([string]$Code).Trim(); $Name = ([string]$Name).Trim()
    $roh = (@($Name, $Code) | Where-Object { $_ -and $_ -ne '0' }) -join ' '
    if (-not $roh) { return $null }
    if ($Code -eq '808' -or $Name -match 'AssignedToOtherTenant') {
        return @{
            Nr  = '808'
            Was = ('Das Gerät ist bei Microsoft schon registriert, meist bei einer anderen Organisation (zum Beispiel dem Vorbesitzer), manchmal unter einem alten Eintrag im eigenen Intune (Fehler ' + $roh + ').')
            Tun = 'Das kannst du nicht selbst lösen. Foto von diesem Bild an den Admin: er sucht zuerst einen alten Eintrag im eigenen Intune, sonst muss der Händler oder Vorbesitzer das Gerät freigeben.'
            Log = ('Import-Fehler 808 (anderer Tenant): Code ' + $Code + ', Name ' + $Name + '. Admin: alten Eintrag im eigenen Tenant/Intune prüfen, sonst Freigabe durch Händler/Vorbesitzer bzw. Microsoft Support.')
        }
    }
    if ($Code -eq '806' -or $Name -match 'AlreadyAssigned') {
        return @{
            Nr  = '806'
            Was = ('Das Gerät steht schon in Autopilot, unter einem alten Eintrag (Fehler ' + $roh + ').')
            Tun = 'Am PC im Setup unter "6. Status" den alten Eintrag mit "Autopilot-Eintrag löschen ..." entfernen und warten, bis er aus der Liste verschwunden ist (bis zu 30 Minuten). Dann Stick rein, Shift+F10, D:\go. Kein Eintrag zu finden: Foto an den Admin.'
            Log = ('Import-Fehler 806 (schon im eigenen Tenant): Code ' + $Code + ', Name ' + $Name + '. Eintrag unter dieser Seriennummer nicht gefunden: alter Eintrag mit anderer Seriennummer, Löschung läuft noch oder Rest-Datensatz in Intune.')
        }
    }
    return $null
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
            $script:ClockOff = ((Get-Date) - $Start).TotalSeconds - (Get-Mono)   # eigene Korrektur nicht als Uhrsprung melden
            Log ('Uhr korrigiert um ' + (-$diff) + ' s (war ' + $diff + ' s daneben)')
        } else { Log ('Uhr OK (Abweichung ' + $diff + ' s)') }
    } catch { Log ('Uhrzeit-Prüfung: ' + $_.Exception.Message) }
}

function Get-AdminHint {
    # Zusatz zum Schritt bei Secret abgelaufen/falsch, je nachdem, was mit dem Bericht an den Admin wirklich passiert ist
    param($R)
    $s = ''; if ($R) { $s = [string]$R.Sent }
    switch ($s) {
        'gesendet'    { return ' Ohne Zugang zum Entra-Portal: den Admin fragen, er hat schon eine Nachricht bekommen.' }
        'gespeichert' { return ' Ohne Zugang zum Entra-Portal: den Admin fragen, er bekommt eine Nachricht, sobald der Stick am PC im Setup steckt.' }
        default       { return ' Ohne Zugang zum Entra-Portal: den Admin fragen.' }
    }
}
function Read-TextAuto {
    # Textdatei lesen wie das Setup: BOM, sonst strenges UTF-8, sonst ANSI (Codepage des Systems, z. B. von Excel)
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    $enc = $null; $skip = 0
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $enc = New-Object System.Text.UTF8Encoding($false); $skip = 3 }
    elseif ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $enc = New-Object System.Text.UnicodeEncoding($false, $false); $skip = 2 }
    else {
        try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($b); $enc = New-Object System.Text.UTF8Encoding($false) }
        catch { try { $enc = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { $enc = [System.Text.Encoding]::Default } }
    }
    return @($enc.GetString($b, $skip, $b.Length - $skip) -split "`r?`n" | Where-Object { $_ -ne '' })
}
function Save-HashRow {
    # Zeile dieses Geraets in hashes.csv ersetzen bzw. anhaengen. Schreibt UTF-8 ohne BOM (reines ASCII bleibt Byte fuer
    # Byte gleich), Umlaute (z. B. im UPN) bleiben auch in den Zeilen anderer Geraete erhalten. Wirft bei Fehlern.
    param([string]$File, [string]$Header, [string]$SerialNo, [string]$Row)
    $rows = @()
    if ([System.IO.File]::Exists($File)) { $rows = @(Read-TextAuto $File | Where-Object { $_ -and $_ -ne $Header -and -not $_.StartsWith($SerialNo + ',') }) }
    $rows += $Row
    [System.IO.File]::WriteAllLines($File, [string[]](@($Header) + $rows), (New-Object System.Text.UTF8Encoding $false))
}
$OfflineHdr = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
function Save-Offline {
    # Hash fuer spaeteren Upload am Stick speichern (Format wie Microsoft-CSV, UTF-8 ohne BOM, ohne Anfuehrungszeichen)
    # -Anlass: Bericht an den Admin, wenn er handeln muss (Secret abgelaufen oder falsch); 'kein Internet' sendet nichts
    param([string]$Why, [string]$Anlass = '')
    Log ('OFFLINE: ' + $Why)
    try {
        $f = Join-Path $CfgDir 'logs\hashes.csv'
        Save-HashRow $f $OfflineHdr $Serial ($Serial + ',,' + $hash + ',' + $cfg.GroupTag + ',' + $AssignUpn)
        Protokoll ('OFFLINE: Hash gespeichert (' + $Why + ')')
    } catch { Log ('Hash am Stick speichern: ' + $_.Exception.Message); Fail ('Kein Upload möglich (' + (Split-NextStep $Why)[0] + ') und der Hash ließ sich auch nicht am Stick speichern (Details im Log).') 'Stick neu anstecken und nochmal D:\go, klappt es wieder nicht: Foto von diesem Bild an den Admin.' }
    # Grund mit eigenem naechsten Schritt (z. B. Secret erneuern): erst das, dann Hashes importieren
    $sp = Split-NextStep $Why
    $tun = $(if ($sp[1]) { $sp[1].TrimEnd('.') + ', danach am PC "Hashes importieren".' } else { '' })
    $was = 'Der Hash ist nur am Stick gespeichert, nicht hochgeladen: ' + $sp[0]
    # Bericht zuerst, damit das Bild sagen kann, was der Admin wirklich bekommt (Secret: wer keinen Zugang zum Portal hat, fragt ihn)
    $rr = $null
    if ($Anlass) { $rr = Send-GoReport (Get-EndText 'Offline' $was $tun) $Anlass; $tun = $tun + (Get-AdminHint $rr) }
    Banner 'HASH GESPEICHERT  -  SPÄTER HOCHLADEN' 'DarkYellow' (@('') + (Get-EndLines 'Offline' $was $tun) + @('', ('Am Stick: HUPilot\logs\hashes.csv (Tag ' + $cfg.GroupTag + ')')))
    Write-ReportLine $rr
    Wait-Close
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
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr w, int cmd);
    public static string Maximize() {
        IntPtr w = GetConsoleWindow();
        if (w == IntPtr.Zero) return "kein Konsolenfenster";
        ShowWindow(w, 3);   // SW_MAXIMIZE
        return "maximiert";
    }
}
'@
    $FontInfo = [HuFont]::AtLeast(20)   # Standard ist meist 16 - mind. 20 (wiederholter Start vergroessert nicht weiter)
} catch { $FontInfo = $_.Exception.Message }
Log ('Schrift: ' + $FontInfo)
# Fenster immer so gross wie der Bildschirm (nach der Schrift, damit die Groesse stimmt) - Fehler egal
try { $WinInfo = [HuFont]::Maximize(); Start-Sleep -Milliseconds 200; $WinInfo += ', ' + [Console]::WindowWidth + ' x ' + [Console]::WindowHeight + ' Zeichen' } catch { $WinInfo = $_.Exception.Message }
Log ('Fenster: ' + $WinInfo)
# Farben zuruecksetzen (nach einem frueheren Lauf im selben Fenster bleibt sonst gruen/gelb/rot stehen)
try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray' } catch { }
Clear-Host
Write-Host ''
Write-Host ('  HUPilot v' + $Ver) -ForegroundColor Cyan
Write-Host ''
Log ('===== START go.ps1 v' + $Ver + ' =====')

# ---------- Hilfsfunktionen ohne Seiteneffekte (einzeln geprueft in .github\tests\Go.Tests.ps1) ----------
function Get-TagChoices {
    # Auswahl fuer die Tag-Frage aus config.json "TagChoices":
    #   Feld fehlt (oder null)  -> Jahre SN-<Jahr-5> bis SN-<Jahr> (bisheriger Rueckfall)
    #   Feld vorhanden und leer -> keine Auswahl, nur der Standard-Tag (die Tag-Frage entfaellt)
    #   Eintraege, die nicht zum TagPattern passen -> Hidden (mit Hinweis ausgeblendet), mehr als 9 gueltige -> Cut (abgeschnitten)
    param($Cfg, [string]$Pattern, [int]$Year = (Get-Date).Year)
    $src = 'Config'
    $raw = @()
    if ($null -eq $Cfg -or -not (@($Cfg.PSObject.Properties.Name) -contains 'TagChoices') -or $null -eq $Cfg.TagChoices) {
        $src = 'Jahre'
        $raw = @(($Year - 5)..$Year | ForEach-Object { 'SN-' + $_ })
    } else { $raw = @($Cfg.TagChoices) }
    $ok = @(); $bad = @()
    foreach ($e in $raw) {
        $t = ([string]$e).Trim()
        if (-not $t) { continue }
        $m = $false
        try { $m = ($t -match $Pattern) } catch { }
        if ($m) { $ok += $t } else { $bad += $t }
    }
    $cut = @()
    if ($ok.Count -gt 9) { $cut = @($ok[9..($ok.Count - 1)]); $ok = @($ok[0..8]) }
    return [pscustomobject]@{ Choices = $ok; Hidden = $bad; Cut = $cut; Source = $src }
}
function ConvertFrom-SecretExpires {
    # config.json "SecretExpires" (schreibt das Setup): UTC im Format yyyy-MM-ddTHH:mm:ssZ
    # Rueckgabe [datetime] in UTC oder $null = unbekannt (Feld fehlt, leer oder nicht lesbar)
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }   # PowerShell 7 wandelt ISO-Zeiten beim Einlesen selbst um
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    $d = [datetime]::MinValue
    $st = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParseExact($s, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, $st, [ref]$d)) { return $d }
    return $null
}
function Get-HwChangeText {
    # Anzeige bei einer Hardware-Aenderung in Autopilot (remediationState). ANNAHME (nicht an einem Geraet belegt):
    #   automaticRemediationRequired = Microsoft gleicht die Aenderung selbst ab -> warten empfehlen, N bleibt moeglich
    #   manualRemediationRequired    = von Hand loesen -> neu registrieren empfehlen (wie bisher)
    param([string]$State)
    if ($State -eq 'automaticRemediationRequired') {
        return @{
            Auto  = $true
            Lines = @(
                'ACHTUNG: Autopilot meldet eine HARDWARE-ÄNDERUNG (z. B. Mainboardtausch).',
                'Microsoft gleicht die Änderung selbst ab, das dauert meist bis zu einer Stunde.',
                'Empfohlen: abbrechen und in einer Stunde nochmal D:\go, oder den Admin fragen.',
                'Neu registrieren = Intune-Eintrag und Autopilot-Eintrag löschen, neuen Hash hochladen.',
                '[Enter] abbrechen (empfohlen)   -   [N] trotzdem neu registrieren')
            Was   = 'Autopilot meldet eine Hardware-Änderung, Microsoft gleicht sie selbst ab.'
            Tun   = 'In einer Stunde nochmal Stick rein, Shift+F10, D:\go. Kommt die Meldung dann wieder: den Admin fragen.'
        }
    }
    return @{
        Auto  = $false
        Lines = @(
            'ACHTUNG: Autopilot meldet eine HARDWARE-ÄNDERUNG (z. B. Mainboardtausch).',
            'Der gespeicherte Hash passt nicht mehr - das Autopilot-Profil greift so nicht.',
            'Neu registrieren = Intune-Eintrag und Autopilot-Eintrag löschen, neuen Hash hochladen.',
            '[N] neu registrieren (empfohlen)   -   [Enter] abbrechen')
        Was   = ''
        Tun   = ''
    }
}
function Test-EdMarkBlocks {
    # Sperrt die Merkdatei Edition die normale Frage J? Nur fuer dieses Geraet, nur wenn nicht aktiviert und hoechstens
    # 24 Stunden alt. Aelter oder Aktiviert=true: wieder die normale Frage (je Lauf bleiben es hoechstens 2 Versuche).
    # Unlesbare Zeit: sperrt weiter (vorsichtig, keine Neustart-Schleife).
    param($M, [string]$Serial, [datetime]$Now = (Get-Date))
    if (-not (Test-EdMarkOwner $M $Serial)) { return $false }
    if ($M.Aktiviert -eq $true) { return $false }
    $z = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(([string]$M.Zeit).Trim(), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$z)) { return $true }
    return ([math]::Abs(($Now - $z).TotalHours) -le 24)
}
function Get-EdMarkBase {
    # Felder der Merkdatei Edition ohne die gemerkten Antworten (zum Neuschreiben)
    param($M)
    $h = @{}
    foreach ($n in 'Seriennr', 'Zeit', 'Von', 'Ziel', 'Aktiviert', 'AktiviertAm') { if ($M -and (@($M.PSObject.Properties.Name) -contains $n)) { $h[$n] = $M.$n } }
    return $h
}
$UpnPattern = '^[^@\s,]+@[^@\s,]+\.[^@\s,]+$'
function Test-EdMarkOwner {
    # Gehoert die Merkdatei Edition zu diesem Geraet? (Seriennummer gleich, sonst wie nicht vorhanden behandeln)
    param($M, [string]$Serial)
    return [bool]($M -and $Serial -and ([string]$M.Seriennr).Trim() -ceq $Serial.Trim())
}
function Get-EdMarkAnswers {
    # Gemerkte Antworten (Tag, Benutzer, Zuruecksetzen) aus der Merkdatei Edition, sonst $null.
    # Nur fuer dieses Geraet (Seriennummer), hoechstens 24 Stunden alt (Feld Zeit, unlesbar = nicht anbieten),
    # vollstaendig und gueltig; nach erfolgter Aktivierung nicht mehr. Schluessel stehen nie in der Merkdatei.
    param($M, [string]$Pattern, [string]$Serial, [datetime]$Now = (Get-Date))
    if (-not $M -or $M.Aktiviert -eq $true) { return $null }
    if (-not (Test-EdMarkOwner $M $Serial)) { return $null }
    $z = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(([string]$M.Zeit).Trim(), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$z)) { return $null }
    if ([math]::Abs(($Now - $z).TotalHours) -gt 24) { return $null }
    $a = $M.Antworten
    if (-not $a) { return $null }
    $tag = ([string]$a.Tag).Trim()
    $okTag = $false
    try { $okTag = ($tag -and $tag -match $Pattern) } catch { }
    if (-not $okTag) { return $null }
    $u = ([string]$a.Benutzer).Trim()
    if ($u -and $u -notmatch '^[^@\s,]+@[^@\s,]+\.[^@\s,]+$') { return $null }
    if ($a.Zuruecksetzen -isnot [bool]) { return $null }
    return @{ Tag = $tag; Benutzer = $u; Reset = [bool]$a.Zuruecksetzen }
}
function Get-JsonErrPos {
    # Nur die Position eines JSON-Fehlers (ohne Inhalt): 5.1 "... (49): <Text>", 7 "... line 1, position 49."
    param([string]$Msg)
    $m = [regex]::Match([string]$Msg, 'line (\d+), position (\d+)')
    if ($m.Success) { return ('Zeile ' + $m.Groups[1].Value + ', Zeichen ' + $m.Groups[2].Value) }
    $m = [regex]::Match([string]$Msg, '\((\d+)\):')
    if ($m.Success) { return ('Zeichen ' + $m.Groups[1].Value) }
    return ''
}
function Get-WipeRunLines {
    # Nur die Zeilen, die das SYSTEM-Script in DIESEM Lauf geschrieben hat: jede Zeile traegt "[<Kennung>]" (die erste
    # zusaetzlich "LAUF <Kennung>"). Fehlt eine einzelne Zeile, zaehlen die anderen weiter; alte Laeufe zaehlen nie.
    param([string[]]$Lines = @(), [string]$RunId)
    if (-not $RunId) { return @() }
    $rx = '\[' + [regex]::Escape($RunId) + '\]|\bLAUF ' + [regex]::Escape($RunId) + '\b'
    return @(@($Lines) | Where-Object { [string]$_ -match $rx })
}
function Get-WipeResult {
    # Ergebnis des SYSTEM-Scripts nur mit der Kennung dieses Laufs ("LAUF <Kennung> OK 0"); ohne oder mit fremder
    # Kennung = noch keine Rueckmeldung (eine alte Datei darf weder "angenommen" noch "Fehler" vortaeuschen)
    param([string]$Raw, [string]$RunId)
    if (-not $RunId) { return '' }
    $m = [regex]::Match(([string]$Raw).Trim(), '^LAUF ' + [regex]::Escape($RunId) + '\s+(\S.*)$', 'Singleline')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}
function Invoke-SchtasksEnd {
    param([string]$Name)
    $o = cmd.exe /c ('schtasks /End /TN "' + $Name + '" 2>&1')
    return @{ Ok = ($LASTEXITCODE -eq 0); Out = (($o | Out-String).Trim()); Code = $LASTEXITCODE }
}
function Stop-WipeTask {
    # Aufgabe stoppen. Massgeblich ist danach ihr Zustand, wenn er lesbar ist (Ready = gestoppt, auch wenn die Befehle
    # scheiterten, weil sie schon fertig war; Running oder Queued = laeuft noch). Sonst zaehlt der Erfolg der Befehle.
    param([string]$Name, [string]$Why)
    $cmdOk = $false
    try { Stop-ScheduledTask -TaskName $Name -ErrorAction Stop; $cmdOk = $true; Log ('Aufgabe gestoppt (' + $Why + ')') }
    catch {
        Log ('Stop-ScheduledTask: ' + $_.Exception.Message)
        $e = Invoke-SchtasksEnd $Name
        $cmdOk = [bool]$e.Ok
        Log ('schtasks end (Exitcode ' + $e.Code + '): ' + $e.Out)
    }
    Start-Sleep -Seconds 2
    $state = ''
    try { $state = [string](Get-ScheduledTask -TaskName $Name -ErrorAction Stop).State } catch { Log ('Zustand der Aufgabe nicht lesbar: ' + $_.Exception.Message) }
    $ok = $cmdOk
    if ($state) { $ok = ($state -notin 'Running', 'Queued'); Log ('Zustand der Aufgabe: ' + $state) }
    if (-not $ok) { Log 'Aufgabe ließ sich nicht stoppen - Zurücksetzen kann noch starten' }
    return $ok
}
function Get-WipeChanges {
    # Was das SYSTEM-Script laut Log dieses Laufs schon veraendert hat (Klartext, fuer Bild und Log)
    param([string[]]$RunLines = @())
    $c = New-Object System.Collections.Generic.List[string]
    if (@($RunLines | Where-Object { $_ -match 'Paket entfernt \(' }).Count) { $c.Add('alte Bereitstellungspakete entfernt (Sicherung in C:\Recovery\HUPilot-PPKG-Backup)') }
    if (@($RunLines | Where-Object { $_ -match '(Vorinstallierte )?App entfernt: ' }).Count) { $c.Add('Hersteller-Apps entfernt') }
    if (@($RunLines | Where-Object { $_ -match 'verschoben: ' }).Count) { $c.Add('Hersteller-Ordner nach C:\Recovery\HUPilot-OEM-Backup verschoben') }
    return @($c)
}
function Get-WipeErrText {
    # Klartext zur Fehlerzeile des SYSTEM-Scripts (der rohe Text kommt nur ins Log)
    param([string]$Res)
    $r = ([string]$Res).Trim()
    if ($r -like 'ERR WLAN-Paket*') { return 'das WLAN-Paket ließ sich auch als SYSTEM nicht installieren' }
    if ($r -like 'ERR Pakete sichern*') { return 'die alten Bereitstellungspakete ließen sich nicht sichern' }
    if ($r -like 'ERR Paket *') { return 'ein altes Bereitstellungspaket ließ sich nicht entfernen' }
    if ($r -like 'ERR verschieben*') { return 'die Hersteller-Ordner ließen sich nicht ganz verschieben' }
    if ($r -like 'ERR Wipe*') { return 'Windows hat den Aufruf zum Zurücksetzen abgelehnt' }
    return 'Fehler im Hilfsprogramm zum Zurücksetzen, Details im Log'
}
function Get-WipeOutcome {
    # Bewertung nach dem Start der geplanten Aufgabe. Kind:
    #   Ok     = Aufruf mit ReturnValue 0 angenommen
    #   Unklar = kann noch zuruecksetzen (Aufruf war abgesetzt, ReturnValue nicht 0 oder leer, oder Aufgabe nicht stoppbar):
    #            nie "nicht zurueckgesetzt" melden. Welche Werte ein erfolgreicher Aufruf liefert, ist nicht belegt
    #            (Microsoft Learn nennt nur uint32 ohne Tabelle), deshalb ist ungleich 0 nur "unklar", nicht "Fehler".
    #   Fehler = sicher nicht zurueckgesetzt: kein Aufruf in diesem Lauf UND die Aufgabe laeuft nachweislich nicht mehr
    #            ($StopOk). Changes nennt schon Veraendertes.
    param([string]$Res, [string[]]$RunLines = @(), [bool]$StopOk = $true)
    $r = ([string]$Res).Trim()
    $called = [bool](@($RunLines | Where-Object { $_ -match 'WIPE-AUFRUF' }).Count)
    # LogFehlt: kein Eintrag dieses Laufs lesbar -> ob schon etwas veraendert wurde, ist unbekannt (ausser bei Fehlern vor jeder Aenderung)
    $o = @{ Kind = ''; Why = ''; Rv = ''; Called = $called; Changes = @(Get-WipeChanges $RunLines); Detail = $r; LogFehlt = (-not @($RunLines).Count -and $r -notlike 'ERR WLAN-Paket*' -and $r -notlike 'ERR Pakete sichern*') }
    if ($r -match '^OK\b') {
        $o.Rv = $r.Substring(2).Trim()
        if ($o.Rv -eq '0') { $o.Kind = 'Ok' }
        else { $o.Kind = 'Unklar'; $o.Why = 'Windows hat den Aufruf zum Zurücksetzen mit einem unklaren Wert beantwortet (' + $(if ($o.Rv) { $o.Rv } else { 'kein Wert' }) + '), nach 15 Minuten hat es nicht begonnen.' }
    } elseif (-not $r) {
        if ($called) { $o.Kind = 'Unklar'; $o.Why = 'Das Zurücksetzen wurde aufgerufen, ohne Rückmeldung, und hat nach 20 Minuten nicht begonnen.' }
        elseif (-not $StopOk) { $o.Kind = 'Unklar'; $o.Why = 'Das Hilfsprogramm zum Zurücksetzen hat sich nicht gemeldet und ließ sich nicht stoppen, nach 20 Minuten hat das Zurücksetzen nicht begonnen.' }
        else { $o.Kind = 'Fehler'; $o.Why = 'keine Rückmeldung vom Hilfsprogramm nach 5 Minuten, es wurde gestoppt' }
    } elseif ($called -or ($r -like 'ERR Wipe*' -and -not @($RunLines).Count)) {
        # Fehler beim Aufruf, oder Log dieses Laufs fehlt: der Fehler kann vor oder nach dem Aufruf entstanden sein
        $o.Kind = 'Unklar'; $o.Why = 'Windows hat beim Aufruf zum Zurücksetzen einen Fehler gemeldet, nach 15 Minuten hat es nicht begonnen.'
    } elseif (-not $StopOk) {
        $o.Kind = 'Unklar'; $o.Why = 'Das Hilfsprogramm zum Zurücksetzen hat einen Fehler gemeldet, läuft aber noch oder ließ sich nicht stoppen, nach 20 Minuten hat das Zurücksetzen nicht begonnen.'
    } else {
        $o.Kind = 'Fehler'; $o.Why = Get-WipeErrText $r
    }
    return $o
}
function Get-WipeJetzt {
    # Satz "Was passiert jetzt" nach dem Start des Zuruecksetzens: ehrlich mit dem, was schon veraendert wurde
    param([string]$Kind, [string[]]$Changes = @(), [bool]$LogFehlt = $false)
    $ch = @($Changes | Where-Object { $_ })
    if ($Kind -eq 'Fehler') {
        if ($LogFehlt -and -not $ch.Count) { return 'Das Gerät wurde nicht zurückgesetzt. Ob schon etwas verändert wurde, ist unklar (Wipe-Log fehlt).' }
        if ($ch.Count) { return ('Das Gerät wurde nicht zurückgesetzt, aber schon verändert: ' + ($ch -join ', ') + '.') }
        return 'Nichts, das Gerät wurde nicht zurückgesetzt.'
    }
    return ('Es kann noch von selbst starten.' + $(if ($ch.Count) { ' Schon verändert: ' + ($ch -join ', ') + '.' } else { '' }))
}

# ---------- Schritt 1: Pruefen - alles, was ohne Netz geht, VOR den Fragen ----------
Show-Step 1 'Prüfen'
$cfg = $null
# Nie die Meldung von ConvertFrom-Json weitergeben: unter 5.1 enthaelt sie den ganzen JSON-Text (Secrets, Kennwoerter)
$cfgRaw = $null
try { $cfgRaw = Get-Content (Join-Path $CfgDir 'config.json') -Raw -Encoding UTF8 -ErrorAction Stop } catch { Log ('config.json lesen: Datei nicht lesbar (' + $_.Exception.GetType().Name + ')'); Fail 'config.json am Stick ist nicht lesbar. Stick neu anstecken, sonst am PC im Setup öffnen und neu speichern.' }
try { $cfg = $cfgRaw | ConvertFrom-Json -ErrorAction Stop } catch { $jp = Get-JsonErrPos $_.Exception.Message; Log ('config.json ist kein gültiges JSON' + $(if ($jp) { ' (' + $jp + ')' } else { '' })); Fail ('config.json am Stick ist kein gültiges JSON' + $(if ($jp) { ' (' + $jp + ')' } else { '' }) + '. Am PC im Setup öffnen und neu speichern.') }
$cfgRaw = $null
if (-not $cfg) { Fail 'config.json am Stick ist leer. Am PC im Setup ausfüllen und speichern.' }
try { $script:LogSecrets = @(Get-ReportSecrets $cfg '') } catch { }
foreach ($k in 'Tenant','TenantId','ClientId','ClientSecret','GroupTag','WlanSsid','WlanKey') {
    if (-not $cfg.$k) { Fail ('In config.json fehlt das Feld ' + $k + '. Am PC im Setup ausfüllen und speichern.') }
}
if ([string]$cfg.ClientSecret -match '^<.*>$' -or [string]$cfg.TenantId -match '^<.*>$') { Fail 'config.json enthält noch Platzhalter (TenantId oder ClientSecret). Am PC im Setup die echten Werte eintragen und speichern.' }
$TagPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
if ($cfg.TagPattern) { $TagPattern = [string]$cfg.TagPattern }
try { [void][regex]::new($TagPattern) } catch { Fail ('TagPattern in config.json ist kein gültiger Ausdruck (' + $TagPattern + '). Am PC in config.json korrigieren oder das Feld löschen.') }
if ($cfg.GroupTag -notmatch $TagPattern) { Fail ('Der Standard-Tag "' + $cfg.GroupTag + '" passt nicht zum erlaubten Muster ' + $TagPattern + '. Am PC im Setup den Group Tag korrigieren.') }
# Mindest-Akku VOR der ersten Verwendung lesen (Wait-Power bei Home auf Pro und vor dem Zuruecksetzen)
if ($null -ne $cfg.MinBattery) {
    try { $MinBattery = [int][math]::Max(0, [int]$cfg.MinBattery) } catch { Log ('MinBattery in config.json ungültig (' + [string]$cfg.MinBattery + ') - bleibt ' + $MinBattery) }
}
Log ('Mindest-Akku ohne Netzteil: ' + $MinBattery + ' %')
# Tag-Auswahl gleich pruefen: ungueltige Eintraege ausblenden statt erst nach der Wahl rot abzubrechen
$TagSel = Get-TagChoices $cfg $TagPattern
$choices = @($TagSel.Choices)
if ($TagSel.Source -eq 'Jahre') { Log ('TagChoices fehlt in config.json - Auswahl: ' + ($choices -join ', ')) }
elseif (-not $choices.Count -and -not @($TagSel.Hidden).Count) { Log 'TagChoices leer - keine Auswahl, nur der Standard-Tag' }
if (@($TagSel.Hidden).Count) { Log ('TagChoices: passt nicht zum Muster ' + $TagPattern + ', ausgeblendet: ' + (@($TagSel.Hidden) -join ', ')) }
if (@($TagSel.Cut).Count) { Log ('TagChoices: mehr als 9 Einträge, abgeschnitten: ' + (@($TagSel.Cut) -join ', ')) }

try { $Serial = ([string](Get-CimInstance Win32_BIOS).SerialNumber).Trim() } catch { }
if (-not $Serial) { Fail 'Die Seriennummer des Geräts ist nicht lesbar (BIOS). Gerät neu starten, dann nochmal D:\go.' }
try {
    New-Item -ItemType Directory -Path (Join-Path $CfgDir 'logs') -Force | Out-Null
    $StickLog = Join-Path $CfgDir ('logs\{0}_{1}.log' -f $Serial, (Get-Date -Format 'yyyyMMdd_HHmm'))
} catch { $StickLog = $null }

function Get-PowerInfo {
    # Win32_Battery.BatteryStatus: 2/3 = Netzteil, 6-9 = laedt; kein Akku = Netzbetrieb
    # WMI-Fehler: einmal wiederholen, dann "nicht prüfbar" wie zu wenig Akku (warten bzw. Rueckfrage J), nie still weiter
    $b = $null
    for ($try = 1; $try -le 2 -and $null -eq $b; $try++) {
        try { $b = @(Get-CimInstance Win32_Battery -ErrorAction Stop) }
        catch { if ($try -lt 2) { Start-Sleep -Seconds 2 } else { return @{ Ok = $false; Text = 'Akku nicht prüfbar'; Unknown = $true } } }
    }
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
    if ($p.Unknown) {
        Log 'Akku nicht prüfbar - Gerät wartet auf Netzteil und J'
        Banner 'NETZTEIL ANSTECKEN  -  GERÄT WARTET' 'DarkYellow' @(
            '',
            'Der Akku-Stand ist auf diesem Gerät nicht lesbar.',
            'Zurücksetzen ohne Strom kann das Gerät unbrauchbar machen.',
            'Das Gerät wartet hier und macht erst weiter, wenn J gedrückt ist.',
            '',
            'Netzteil anstecken, dann J drücken.')
    } else {
        Banner 'NETZTEIL ANSTECKEN' 'DarkYellow' @(
            '',
            ('Mindestens ' + $MinBattery + ' % Akku oder Netzteil.'),
            'Zurücksetzen ohne Strom kann das Gerät unbrauchbar machen.',
            '',
            'Wartet, bis das Netzteil steckt.   J = trotzdem weiter')
    }
    while (-not $p.Ok) {
        # ohne -Valid: jede Taste kehrt zurueck, damit der Strom weiter alle 5 s geprueft wird
        $t0 = Get-Mono
        $k = Read-KeyTimeout 5 ('Strom: ' + $p.Text + '  |  nächste Prüfung')
        # kam sofort zurueck (umgeleitete Eingabe): selbst 5 s warten, damit die Schleife nicht ohne Pause dreht
        if (-not $k) { $rest = 5 - ((Get-Mono) - $t0); if ($rest -gt 0.5) { Start-Sleep -Milliseconds ([int]($rest * 1000)) } }
        if ($k -eq 'J' -or $k -eq 'Y') { Log ('Strom-Warnung übergangen: ' + $p.Text); break }
        $was = [bool]$p.Unknown
        $p = Get-PowerInfo
        if ($p.Unknown -and -not $was) { Log 'Akku jetzt nicht prüfbar - Gerät wartet auf Netzteil und J' }
    }
    Log ('Strom jetzt: ' + $p.Text)
    try { $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
}

$os = Get-CimInstance Win32_OperatingSystem
Log ('Windows: ' + $os.Caption + ' ' + $os.Version)

# ---------- Edition: Windows Home -> Pro (optional, config.json "EditionKey" = MAK fuer Pro) ----------
# Ablauf: Rueckfrage -> Dienste starten -> changepk mit dem GENERISCHEN Pro-Schluessel (stellt nur die Edition um,
# verbraucht keine Aktivierung) -> Windows startet neu -> D:\go erneut -> nach dem Netz MAK installieren + aktivieren.
# Merkdatei (lokal + am Stick je Seriennummer) verhindert eine Schleife: nach einem Fehlversuch kein zweiter Versuch.
# Sie merkt sich auch die Antworten (Tag, Benutzer, Zuruecksetzen) fuer den Start nach dem Neustart - nie Schluessel.
# Im OOBE tat changepk mit dem MAK direkt nichts (Test 13.11.2026, Dienste vermutlich gestoppt) - daher dieser Weg.
# Hier nur PRUEFEN (ohne Netz); Rueckfrage bei den Fragen, Umstellung nach der Zusammenfassung.
$EdKey = ([string]$cfg.EditionKey).Trim().ToUpper()
if ($EdKey -and $EdKey -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { Fail 'Der MAK (Pro) in config.json hat nicht die Form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX. Am PC im Setup korrigieren oder leeren.' }
# Allgemeine Schluessel von Microsoft (Installation/KMS-Client) aktivieren nicht - als MAK abgelehnt (Verwechslung im Test 13.11.2026)
$EdGenericKeys = @('VK7JG-NPHTM-C97JM-9MPGT-3V66T', '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT', 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7', 'W269N-WFGWX-YVC9B-4J6C9-T83GX', 'MH37W-N47XK-V7XM9-C7227-GCQG9')
$EdKeyIsGeneric = ($EdKey -and $EdGenericKeys -contains $EdKey)
$EdMarkLocal = 'C:\Windows\Temp\HUPilot-Edition.json'
$EdMarkStick = Join-Path $CfgDir ('logs\edition_' + $Serial + '.json')
$EdMark = $null
foreach ($f in $EdMarkLocal, $EdMarkStick) {
    if ($EdMark -or -not (Test-Path -LiteralPath $f)) { continue }
    $m = $null
    try { $m = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Log ('Merkdatei Edition nicht lesbar: ' + $f) }
    # Nur die Merkdatei dieses Geraets zaehlt (Rueckfrage W, Aktivierung, gemerkte Antworten)
    if ($m -and -not (Test-EdMarkOwner $m $Serial)) { Log ('Merkdatei Edition gehört zu einem anderen Gerät (Seriennr ' + [string]$m.Seriennr + ') - wie nicht vorhanden behandelt: ' + $f); continue }
    $EdMark = $m
}
$EdId = ''
try { $EdId = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID } catch { }
Log ('EditionID: ' + $EdId)
function Get-KeyTail([string]$Key) { if ($Key.Length -ge 5) { return '*****-' + $Key.Substring($Key.Length - 5) } return '' }
function Hide-Key([string]$Text) {
    # Schluessel nie ins Log: MAK und generische Schluessel durch die letzten 5 Zeichen ersetzen
    if ($EdKey) { $Text = $Text.Replace($EdKey, (Get-KeyTail $EdKey)) }
    return [regex]::Replace($Text, '[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}', { param($m) Get-KeyTail $m.Value })
}
function Save-EdMark([hashtable]$Data) {
    $j = $Data | ConvertTo-Json -Compress -Depth 3
    foreach ($f in $EdMarkLocal, $EdMarkStick) { try { [System.IO.File]::WriteAllText($f, $j, (New-Object System.Text.UTF8Encoding($false))) } catch { Log ('Merkdatei Edition nicht schreibbar: ' + $f + ' - ' + $_.Exception.Message) } }
}
function Get-SysExe([string]$Name) {
    # 32-Bit-PowerShell auf 64-Bit-Windows sieht System32 umgeleitet -> Sysnative
    $d = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $d = Join-Path $env:SystemRoot 'Sysnative' }
    return (Join-Path $d $Name)
}
function Start-EdService([string]$Name) {
    try {
        $s = Get-Service -Name $Name -ErrorAction Stop
        if ($s.StartType -eq 'Disabled') { Set-Service -Name $Name -StartupType Manual -ErrorAction Stop }
        if ($s.Status -ne 'Running') { Start-Service -Name $Name -ErrorAction Stop }
        Log ('Dienst ' + $Name + ': ' + (Get-Service -Name $Name).Status)
    } catch { Log ('Dienst ' + $Name + ' nicht gestartet: ' + $_.Exception.Message) }
}
$IsHome = $EdId -match '^Core' -or ($os.Caption -notmatch 'Pro|Education|Enterprise')
$genKey = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'   # generischer Schluessel Windows Pro (Microsoft), aktiviert nicht
$target = 'Professional'
if ($EdId -eq 'CoreN') { $genKey = '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT'; $target = 'ProfessionalN' }
$cpk = Get-SysExe 'changepk.exe'
$homeMsg = 'Windows "' + $os.Caption + '" lässt sich nicht mit Intune verwalten, nötig ist Pro oder Pro Education (auch Education, Enterprise)'
if ($IsHome) {
    if (-not $EdKey) { Fail ($homeMsg + '. Für die Umstellung auf Pro am PC im Setup den MAK (Pro) eintragen.') }
    if ($EdKeyIsGeneric) { Fail ($homeMsg + '. Im Setup steht bei MAK (Pro) der allgemeine Schlüssel von Microsoft (' + (Get-KeyTail $EdKey) + '), der aktiviert nicht. Am PC im Setup den MAK der Schule eintragen.') }
    $te = ''
    try { $te = ((& (Get-SysExe 'dism.exe') /English /Online /Get-TargetEditions 2>&1) | Out-String) } catch { $te = $_.Exception.Message }
    Log ('Zieleditionen: ' + (($te -split "`r?`n" | Where-Object { $_ -match 'Target Edition' } | ForEach-Object { ($_ -split ':')[-1].Trim() }) -join ', '))
    if ($te -notmatch ('(?m)Target Edition\s*:\s*' + $target + '\s*$')) {
        Fail ($homeMsg + '. Windows bietet ' + $target + ' nicht als Ziel an' + $(if ($EdId -eq 'CoreN') { ' (Home N braucht einen Pro-N-Schlüssel)' } else { '' }) + '. Foto an den Admin.')
    }
    if (-not (Test-Path -LiteralPath $cpk)) { Fail ($homeMsg + '. changepk.exe fehlt auf diesem Gerät (' + $cpk + '). Foto an den Admin.') }
}

# WLAN-Paket am Stick vorhanden?
if ($null -ne $cfg.WlanPackage) { $WlanPkgName = [string]$cfg.WlanPackage }
if ($WlanPkgName) {
    $StickPkg = Join-Path $CfgDir $WlanPkgName
    if (-not (Test-Path $StickPkg)) { Fail ('Das WLAN-Paket fehlt am Stick (' + $StickPkg + '). Am PC im Setup das WLAN-Paket bauen und auf den Stick kopieren. Ohne WLAN-Paket: in config.json "WlanPackage": "" eintragen.') }
}

# Hardware-Hash (vor dem Netz - wird bei Offline am Stick gespeichert)
$hash = $null
try {
    $dd = Get-CimInstance -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    $hash = $dd.DeviceHardwareData
} catch { Log ('Hash-Fehler: ' + $_.Exception.Message) }
if (-not $hash) { Fail 'Der Hardware-Hash ist nicht lesbar (Windows-Verwaltung). Gerät neu starten, dann nochmal D:\go.' }
Log ('Hash gelesen (' + $hash.Length + ' Zeichen)')
Say 'Geprüft: Einstellungen, Seriennummer, Windows, WLAN-Paket, Hardware-Hash' 'Green'
Write-Host ''

# ---------- Fragen: Windows Home, gemerkte Antworten, Tag, Benutzer, Zuruecksetzen ----------
$edRetry = $false
if ($IsHome) {
    if ($EdMark -and -not (Test-EdMarkBlocks $EdMark $Serial)) { Log ('Merkdatei Edition älter als 24 Stunden oder aktiviert (' + [string]$EdMark.Zeit + ') - normale Frage') }
    if (Test-EdMarkBlocks $EdMark $Serial) {
        # Frueherer Versuch gescheitert: nie von selbst wiederholen, nur auf ausdruecklichen Tastendruck
        Write-Host ('  Umstellung auf Pro hat beim letzten Mal nicht geklappt (' + [string]$EdMark.Zeit + '), Edition weiter ' + $EdId + '.') -ForegroundColor Yellow
        Write-Host '    [W]      nochmal versuchen' -ForegroundColor White
        Write-Host '    [Enter]  abbrechen   (Standard)'
        $k = Read-KeyTimeout 30 'ohne Eingabe: abbrechen' -Valid 'W'
        if ($k -ne 'W') { Fail ('Umstellung auf Pro hat nicht geklappt (Versuch ' + [string]$EdMark.Zeit + ', Edition weiter ' + $EdId + '). Nochmal: D:\go und W drücken. Sonst über Windows: Einrichtung mit lokalem Konto abschließen, Einstellungen > Aktivierung > Product Key ändern') -NoReport }
        Log 'Umstellung auf Pro: erneuter Versuch auf Tastendruck'
        $edRetry = $true
    } else {
        Write-Host '  Windows Home erkannt - Intune-Verwaltung braucht Pro oder Pro Education.' -ForegroundColor Yellow
        Write-Host '  Auf Windows Pro umstellen? Gerät startet dabei neu, danach D:\go erneut starten.' -ForegroundColor Yellow
        Write-Host '    [J]      ja, auf Pro umstellen' -ForegroundColor White
        Write-Host '    [Enter]  nein, abbrechen   (Standard)'
        $k = Read-KeyTimeout 30 'ohne Eingabe: abbrechen' -Valid 'J', 'Y'
        if ($k -ne 'J' -and $k -ne 'Y') { Fail ($homeMsg + '. Umstellung auf Pro wurde abgelehnt. Zum Umstellen nochmal D:\go und J drücken.') -NoReport }
    }
    Write-Host ''
}

# Gemerkte Antworten vom Start vor dem Neustart (Home auf Pro): Enter = uebernehmen, andere Taste = neu fragen
$DoReset = $true
if ($null -ne $cfg.Reset) { $DoReset = [bool]$cfg.Reset }
$useSaved = $false
$Saved = Get-EdMarkAnswers $EdMark $TagPattern $Serial
if ($Saved) {
    Write-Host ('  Antworten vom letzten Start (' + [string]$EdMark.Zeit + '):') -ForegroundColor Cyan
    Write-Host ('    Group Tag    : ' + $Saved.Tag)
    if ($cfg.AskUser -eq $true) { Write-Host ('    Benutzer     : ' + $(if ($Saved.Benutzer) { $Saved.Benutzer } else { 'keiner' })) }
    Write-Host ('    Zurücksetzen : ' + $(if ($Saved.Reset) { 'JA' } else { 'NEIN, nur hochladen' }))
    Write-Host '    [Enter]          übernehmen   (Standard)' -ForegroundColor White
    Write-Host '    [andere Taste]   neu wählen'
    $k = Read-KeyTimeout 20 'ohne Eingabe: übernehmen'
    if ($k -eq '' -or $k -eq 'ENTER') {
        $useSaved = $true
        $cfg.GroupTag = $Saved.Tag
        if ($cfg.AskUser -eq $true) { $AssignUpn = $Saved.Benutzer }
        $DoReset = $Saved.Reset
        Log ('Gemerkte Antworten übernommen: Tag ' + $cfg.GroupTag + ', Benutzer ' + $AssignUpn + ', Zurücksetzen ' + $DoReset)
    } else { Log 'Gemerkte Antworten verworfen - neu fragen' }
    Write-Host ''
}

# ---------- Tag-Auswahl (10 s, sonst Standard) - entfaellt bei leerer Auswahl ----------
if (-not $useSaved -and $choices.Count) {
    Write-Host '  Group Tag wählen:' -ForegroundColor Cyan
    Write-Host ('    [Enter]  ' + $cfg.GroupTag + '   (Standard)') -ForegroundColor White
    for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host ('    [' + ($i + 1) + ']      ' + $choices[$i]) }
    if (@($TagSel.Hidden).Count) { Write-Host ('  Hinweis: ungültige Tags in der Auswahl ausgeblendet: ' + (@($TagSel.Hidden) -join ', ') + ' (Admin: im Setup korrigieren)') -ForegroundColor Yellow }
    $sel = Read-KeyTimeout 10 ('ohne Eingabe: ' + $cfg.GroupTag) -Valid @(1..$choices.Count | ForEach-Object { [string]$_ })
    if ($sel -match '^[1-9]$' -and [int]$sel -le $choices.Count) { $cfg.GroupTag = $choices[[int]$sel - 1] }
    Write-Host ''
} elseif (-not $useSaved -and @($TagSel.Hidden).Count) {
    Say ('Hinweis: alle Tags der Auswahl sind ungültig und ausgeblendet (' + (@($TagSel.Hidden) -join ', ') + '), es gilt der Standard-Tag. Admin: im Setup korrigieren') 'Yellow'
}
if ($cfg.GroupTag -notmatch $TagPattern) { Fail ('Der Group Tag "' + $cfg.GroupTag + '" passt nicht zum erlaubten Muster ' + $TagPattern + '. Am PC im Setup korrigieren.') }

# ---------- Optional: Benutzer vorab zuweisen (config "AskUser": true) ----------
if (-not $useSaved -and $cfg.AskUser -eq $true) {
    Write-Host '  Benutzer vorab zuweisen? Anmeldename (UPN) eintippen, Enter = keiner' -ForegroundColor Cyan
    while ($true) {
        $u = (Read-Line '  UPN').Trim()
        if (-not $u) { break }
        if ($u -match $UpnPattern) { $AssignUpn = $u; break }
        Write-Host '  Ungültig - Form name@example.org' -ForegroundColor Yellow
    }
    Write-Host ''
}

# ---------- Zuruecksetzen ja/nein (10 s, sonst Standard aus config.json "Reset") ----------
if (-not $useSaved) {
    Write-Host '  Nach dem Upload zurücksetzen?' -ForegroundColor Cyan
    if ($DoReset) { Write-Host '    [Enter]  JA, zurücksetzen   (Standard)' -ForegroundColor White; Write-Host '    [N]      nein, nur hochladen' }
    else          { Write-Host '    [Enter]  NEIN, nur hochladen (Standard)' -ForegroundColor White; Write-Host '    [J]      ja, zurücksetzen' }
    $k = Read-KeyTimeout 10 ('ohne Eingabe: ' + $(if ($DoReset) { 'zurücksetzen' } else { 'nur hochladen' })) -Valid 'J', 'Y', 'N'
    if ($k -eq 'N') { $DoReset = $false } elseif ($k -eq 'J' -or $k -eq 'Y') { $DoReset = $true }
    Write-Host ''
}

# ---------- Zusammenfassung - ab hier ohne weitere Rueckfrage (ausser Sonderfaellen) ----------
Write-Host '  ---------- Zusammenfassung ----------' -ForegroundColor Cyan
Say ('Seriennummer : ' + $Serial) 'White'
Say ('Tenant       : ' + $cfg.Tenant) 'White'
Say ('Group Tag    : ' + $cfg.GroupTag) 'White'
if ($cfg.AskUser -eq $true -or $AssignUpn) { Say ('Benutzer     : ' + $(if ($AssignUpn) { $AssignUpn } else { 'keiner' })) 'White' }
Say ('Zurücksetzen : ' + $(if ($DoReset) { 'JA' } else { 'NEIN, nur hochladen' })) 'White'
Say ('Windows      : ' + $os.Caption + ' ' + $os.Version + $(if ($IsHome) { '  ->  wird auf Pro umgestellt (Neustart)' } else { '' })) 'White'
if ($EdMark -and $EdId -match '^Professional') { Say ('Edition      : auf ' + $EdId + ' umgestellt (' + [string]$EdMark.Zeit + ')') 'Green' }
if ($EdMark -and $EdKeyIsGeneric -and -not $EdMark.Aktiviert -and $EdId -match '^Professional') { Say ('WARNUNG: keine Aktivierung - bei MAK (Pro) steht der allgemeine Schlüssel von Microsoft (' + (Get-KeyTail $EdKey) + '). Im Setup den MAK der Schule eintragen') 'Yellow' }
Write-Host '  Ab hier läuft alles ohne weitere Fragen.' -ForegroundColor Gray
Write-Host ''

# ---------- Windows Home auf Pro umstellen (Rueckfrage war oben) ----------
if ($IsHome) {
    Wait-Power
    Say ('Stelle auf ' + $target + ' um (MAK ' + (Get-KeyTail $EdKey) + ' wird nach dem Neustart aktiviert) ...') 'Cyan'
    # Antworten fuer den Start nach dem Neustart mitschreiben (keine Schluessel)
    Save-EdMark @{ Seriennr = $Serial; Zeit = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Von = $EdId; Ziel = $target; Aktiviert = $false; Antworten = @{ Tag = [string]$cfg.GroupTag; Benutzer = [string]$AssignUpn; Zuruecksetzen = [bool]$DoReset } }
    Protokoll ('EDITION: Umstellung ' + $EdId + ' -> ' + $target + ' gestartet')
    Banner 'WINDOWS WIRD AUF PRO UMGESTELLT' 'DarkBlue' (@('') + (Get-EndLines 'ProUmstellung'))
    # changepk kehrt meist sofort zurueck, Windows stellt im Hintergrund um und startet selbst neu.
    # Deshalb: sichtbar und ohne Warten starten (ein verstecktes Rueckfrage-Fenster wuerde sonst alles blockieren),
    # 10 Min ueberwachen, einmal wiederholen, und selbst neu starten, sobald die Registry die neue Edition zeigt.
    $t0 = Get-Mono
    $edTry = 0
    $edLast = -1000.0
    $edProc = $null
    $edDone = $false
    while ((Get-Mono) - $t0 -lt 600) {
        $nowId = ''
        try { $nowId = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID } catch { }
        if ($nowId -and $nowId -notmatch '^Core') { $edDone = $true; break }
        if ($edProc -and $edProc.HasExited) { Complete-Live; Log ('changepk beendet, Code ' + $edProc.ExitCode); $edProc = $null }
        $busy = $false
        try { $busy = @(Get-Process -Name 'changepk', 'SetupHost', 'LicensingUI' -ErrorAction SilentlyContinue).Count -gt 0 } catch { }
        if (-not $busy -and $edTry -lt 2 -and ((Get-Mono) - $edLast) -gt 180) {
            $edTry++
            $edLast = Get-Mono
            Complete-Live
            # Dienste bei jedem Versuch: im Einrichtungsbildschirm sind sie teils gestoppt, dann tut changepk nichts
            foreach ($svc in 'sppsvc', 'ClipSVC', 'LicenseManager', 'wuauserv') { Start-EdService $svc }
            try {
                $edProc = Start-Process -FilePath $cpk -ArgumentList '/ProductKey', $genKey -PassThru -ErrorAction Stop
                Log ('changepk gestartet (Versuch ' + $edTry + ' von 2)')
            } catch { Log ('changepk nicht startbar (Versuch ' + $edTry + '): ' + (Hide-Key $_.Exception.Message)) }
        }
        Wait-Live 10 ('Umstellung läuft (Versuch ' + $edTry + ' von 2), warte auf Neustart') $t0 600 'nächste Prüfung'
    }
    Complete-Live
    if ($edDone) {
        # Edition steht schon in der Registry, Windows hat aber nicht selbst neu gestartet -> selbst neu starten
        Log ('Edition jetzt ' + $nowId + ' - Neustart durch HUPilot (shutdown /r /f /t 10)')
        Protokoll ('EDITION: jetzt ' + $nowId + ', Neustart')
        Banner 'UMGESTELLT  -  NEUSTART IN 10 s' 'DarkBlue' (@('') + (Get-EndLines 'ProNeustart'))
        Start-Process -FilePath (Get-SysExe 'shutdown.exe') -ArgumentList '/r', '/f', '/t', '10' -WindowStyle Hidden
        Start-Sleep -Seconds 60
        exit 0
    }
    Protokoll 'EDITION: Umstellung ohne Wirkung (kein Neustart nach 10 Min)'
    Fail ('Windows hat nach 2 Versuchen nicht auf Pro umgestellt - Edition weiter ' + $EdId + '. Nochmal: D:\go und W drücken. Sonst über Windows: Einrichtung mit lokalem Konto abschließen, Einstellungen > Aktivierung > Product Key ändern, dann HUPilot erneut')
}
# Nach erfolgreicher Umstellung: Merkdatei da, Edition jetzt Pro -> nach dem Netz aktivieren (siehe unten)
$EdActivate = ($EdMark -and (Test-EdMarkOwner $EdMark $Serial) -and $EdKey -and -not $EdKeyIsGeneric -and -not $EdMark.Aktiviert -and $EdId -match '^Professional')

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
        $a = Read-Line '  Eingabe'
        if ($a -cne 'LÖSCHEN' -and $a -cne 'LOESCHEN') { Log 'Abbruch: Gerät hat Benutzerdaten'; Protokoll 'ABBRUCH: Benutzerdaten vorhanden'; Stop-ByUser 'Das Gerät ist schon eingerichtet, LÖSCHEN wurde nicht eingetippt.' }
        Log 'Benutzerdaten-Warnung mit LÖSCHEN bestätigt'
        try { $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
    }
    Wait-Power
    Say ('Strom        : ' + (Get-PowerInfo).Text)
}

# ---------- 2. Netz / WLAN ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Show-Step 2 'Internet'
Say 'Prüfe Internet ...'
Sync-Clock
$netOk = Test-Net $cfg.TenantId
if (-not $netOk) {
    # LAN-Kabel steckt: erst bis 60 s auf eine Adresse/Internet warten, bevor das WLAN versucht wird
    $lan = Test-LanLink
    if ($lan) {
        Log ('LAN-Verbindung erkannt: ' + $lan)
        Say 'LAN verbunden - warte auf Internet (bis 60 s) ...' 'Yellow'
        $t0 = Get-Mono
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
    $t0 = Get-Mono
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
$script:ReportNetOk = $true
Sync-Clock
# Liegengebliebene Berichte an den Admin nachsenden (hoechstens 5, je 8 s, haelt den Ablauf nicht auf)
if (([string]$cfg.TeamsWebhook).Trim()) {
    $twWhy = Test-WebhookUrl ([string]$cfg.TeamsWebhook)
    if ($twWhy) { Log ('Feld Teams-Webhook in config.json ungültig (' + $twWhy + ') - Bericht an den Admin ist aus. Im Setup das Feld Teams-Webhook prüfen und den Stick neu bespielen.') }
    else {
        $nOut = Send-Outbox (Get-OutboxDir) ([string]$cfg.TeamsWebhook) $OutboxSendMax $ReportTimeoutSec (Get-ReportSecrets $cfg) ([string]$cfg.Tenant)
        if ($nOut) { Log ('Liegengebliebene Berichte an den Admin gesendet: ' + $nOut) }
    }
}

# ---------- Edition: nach Umstellung auf Pro den MAK installieren und aktivieren ----------
# Fehler hier sind nur Warnungen: Autopilot braucht keine Aktivierung. Kein zweiter Versuch, wenn schon aktiviert.
if ($EdActivate) {
    Say ('Aktiviere Windows mit MAK ' + (Get-KeyTail $EdKey) + ' ...') 'Cyan'
    $slmgr = Get-SysExe 'slmgr.vbs'
    $cs = Get-SysExe 'cscript.exe'
    $okAct = $false
    try {
        $o1 = ((& $cs //Nologo $slmgr /ipk $EdKey 2>&1) | Out-String).Trim()
        Log ('slmgr /ipk: ' + (Hide-Key $o1))
        $o2 = ((& $cs //Nologo $slmgr /ato 2>&1) | Out-String).Trim()
        Log ('slmgr /ato: ' + (Hide-Key $o2))
        $lic = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction Stop)
        $okAct = @($lic | Where-Object { [int]$_.LicenseStatus -eq 1 }).Count -gt 0
        Log ('Lizenzstatus: ' + (($lic | ForEach-Object { $_.Name + ' = ' + $_.LicenseStatus + ' (' + $_.PartialProductKey + ')' }) -join ' | '))
    } catch { Log ('Aktivierung: ' + (Hide-Key $_.Exception.Message)) }
    if ($okAct) {
        Say 'Windows aktiviert' 'Green'
        Save-EdMark @{ Seriennr = $Serial; Zeit = [string]$EdMark.Zeit; Von = [string]$EdMark.Von; Ziel = [string]$EdMark.Ziel; Aktiviert = $true; AktiviertAm = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
        Protokoll ('EDITION: ' + $EdId + ' aktiviert (MAK ' + (Get-KeyTail $EdKey) + ')')
    } else {
        Say 'WARNUNG: Aktivierung nicht bestätigt - geht trotzdem weiter (Details im Log)' 'Yellow'
        Protokoll ('EDITION: ' + $EdId + ' NICHT aktiviert')
    }
}

# ---------- 3a. Token ----------
Show-Step 3 'Anmelden'
# Ablaufdatum des Secrets (config.json "SecretExpires", schreibt das Setup) - erst nach der Uhr-Korrektur bewerten.
# Nur Hinweis, kein Abbruch: die Uhr am Geraet kann trotzdem falsch sein.
$SecretExp = ConvertFrom-SecretExpires $cfg.SecretExpires
$SecretExpTxt = ''
if ($SecretExp) {
    $SecretExpTxt = $SecretExp.ToLocalTime().ToString('dd.MM.yyyy HH:mm')
    $hLeft = ($SecretExp - [datetime]::UtcNow).TotalHours
    Log ('Secret gültig bis ' + $SecretExp.ToString('yyyy-MM-dd HH:mm') + ' UTC (noch ' + [int]$hLeft + ' h)')
    if ($hLeft -le 0) {
        Write-Host ''
        Say ('ACHTUNG: Das Secret ist laut Setup seit ' + $SecretExpTxt + ' abgelaufen. Anmeldung wird trotzdem versucht.') 'Yellow'
        Say 'Klappt sie nicht: am PC im Setup ein neues Secret eintragen und den Stick neu bespielen.' 'Yellow'
        Write-Host ''
    } elseif ($hLeft -lt 24) {
        Say ('Hinweis: Das Secret läuft am ' + $SecretExpTxt + ' ab (in ' + [int][math]::Ceiling($hLeft) + ' Std). Bald im Setup erneuern.') 'Yellow'
    }
} else { Log 'Secret-Ablauf unbekannt (SecretExpires fehlt oder nicht lesbar)' }
$tok = $null
$TokAt = Get-Mono
for ($i = 1; $i -le 3 -and -not $tok; $i++) {
    try {
        $body = @{ grant_type = 'client_credentials'; client_id = $cfg.ClientId; client_secret = $cfg.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        $tok = (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $cfg.TenantId + '/oauth2/v2.0/token') -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
    } catch {
        $m = Get-ErrText $_
        Log ('Token-Versuch ' + $i + ': ' + $m)
        $expInfo = $(if ($SecretExpTxt) { ' (laut Setup gültig bis ' + $SecretExpTxt + ')' } else { '' })
        if ($m -match 'AADSTS7000222') { Save-Offline ('Secret ABGELAUFEN' + $expInfo + '. Am PC im Setup ein neues Secret eintragen') 'SecretAbgelaufen' }
        if ($m -match 'AADSTS7000215') { Save-Offline ('Secret FALSCH (Secret-ID statt Wert?)' + $expInfo + '. Am PC im Setup den Wert des Secrets eintragen') 'SecretFalsch' }
        if ($i -lt 3) { Wait-Live 5 ('Anmeldung fehlgeschlagen - Versuch ' + ($i + 1) + '/3') -1 0 'neuer Versuch'; Complete-Live }
    }
}
if (-not $tok) { Save-Offline 'Anmeldung am Tenant fehlgeschlagen (Details im Log). Am PC im Setup "Verbindung testen"' }
$h  = @{ Authorization = 'Bearer ' + $tok }
$hj = @{ Authorization = 'Bearer ' + $tok; 'Content-Type' = 'application/json' }
# Access-Token gilt laut MS Doku zufaellig 60-90 Min (learn.microsoft.com/entra/identity-platform/access-tokens#token-lifetime).
# Lange Laeufe (Hardwaretausch bis 30 Min + Import 10 + Profil 20) koennen das ueberschreiten -> ab 45 Min neu holen.
function Update-Token {
    if (((Get-Mono) - $script:TokAt) / 60 -lt 45) { return }
    try {
        $b = @{ grant_type = 'client_credentials'; client_id = $cfg.ClientId; client_secret = $cfg.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        $t = (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $cfg.TenantId + '/oauth2/v2.0/token') -Body $b -ContentType 'application/x-www-form-urlencoded').access_token
        if ($t) {
            $script:tok = $t
            $script:TokAt = Get-Mono
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
elseif ($tp.Count) { Say ('Profil für Group Tag: ' + ($tp -join ', ')) 'Green' }
else {
    Log ('Tag-Prüfung: KEIN Profil für ' + $cfg.GroupTag)
    Write-Host ''
    Write-Host ('  ACHTUNG: Für Tag "' + $cfg.GroupTag + '" ist KEIN Autopilot-Profil zugewiesen.') -ForegroundColor Yellow
    Write-Host '  Das Gerät würde nach dem Upload vergeblich auf ein Profil warten.' -ForegroundColor Yellow
    Write-Host '  [A] Abbrechen   -   [Enter] trotzdem hochladen' -ForegroundColor Yellow
    $k = Read-KeyTimeout 20 'ohne Eingabe: trotzdem hochladen' -Valid 'A'
    if ($k -eq 'A') { Log 'Abbruch: kein Profil für Group Tag'; Protokoll 'ABBRUCH: kein Profil für Group Tag'; Stop-ByUser ('Für den Group Tag ' + $cfg.GroupTag + ' gibt es kein Autopilot-Profil, mit A abgebrochen.') }
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
Show-Step 4 'Hochladen'

# Erste Abfrage: ein Fehler (Netz, 429, 5xx) darf NICHT als "nicht registriert" gelten - sonst wuerde ein vorab
# importiertes Geraet neu importiert und der Import scheitert irrefuehrend mit 806/808. 3 Versuche, dann Abbruch.
$ap = $null
for ($i = 1; $i -le 3; $i++) {
    $ap = Get-ApDevice
    if (-not $script:ApLookupFailed) { break }
    if ($i -lt 3) { Log ('Autopilot-Abfrage fehlgeschlagen - Versuch ' + ($i + 1) + '/3'); Wait-Live 15 ('Autopilot-Abfrage fehlgeschlagen - Versuch ' + ($i + 1) + '/3') -1 0 'neuer Versuch'; Complete-Live }
}
if ($script:ApLookupFailed) { Fail 'Die Abfrage bei Autopilot ist 3-mal fehlgeschlagen (Netz oder Microsoft gestört, Details im Log). Einige Minuten warten, dann nochmal D:\go.' }
# Hardware geaendert (z. B. Mainboardtausch beim Support): Autopilot zeigt "Fix ausstehend" / "Achtung erforderlich",
# der gespeicherte Hash passt nicht mehr. MS Doku (Autopilot motherboard replacement / Deregister a device):
# zuerst Intune-Eintrag loeschen, dann Autopilot-Eintrag loeschen, dann mit neuem Hash neu registrieren.
if ($ap -and ([string]$ap.remediationState -in 'automaticRemediationRequired', 'manualRemediationRequired')) {
    Log ('Hardware-Änderung erkannt: remediationState=' + $ap.remediationState + ', Tag ' + $ap.groupTag)
    $hwc = Get-HwChangeText ([string]$ap.remediationState)
    Write-Host ''
    foreach ($x in $hwc.Lines) { Write-Host ('  ' + $x) -ForegroundColor Yellow }
    $k = (Read-Line '  Auswahl').Trim().ToUpper()
    if ($k -ne 'N') {
        if ($hwc.Auto) { Stop-ByUser $hwc.Was -Tun $hwc.Tun }
        Fail 'Autopilot meldet eine Hardware-Änderung, neu registrieren wurde abgelehnt. Zum Neu-Registrieren nochmal D:\go und N drücken, sonst den Admin fragen.' -NoReport
    }
    # 1. Intune-Eintraege mit dieser Seriennummer loeschen
    $md = @()
    try {
        # OData: einfaches Hochkomma im Wert verdoppeln
        $f = [uri]::EscapeDataString("serialNumber eq '" + $Serial.Replace("'", "''") + "'")
        $md = @((Invoke-GraphGet ($GB + '/deviceManagement/managedDevices?$filter=' + $f + '&$select=id,deviceName,serialNumber')).value | Where-Object { $_.serialNumber -eq $Serial })
    } catch { Fail ('Intune-Einträge sind nicht lesbar (' + (Get-ErrScreen $_ 'Intune-Einträge lesen') + '). Admin: App-Berechtigung DeviceManagementManagedDevices.ReadWrite.All prüfen, dann nochmal D:\go.') }
    foreach ($d in $md) {
        try {
            Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/managedDevices/' + $d.id) -Headers $h | Out-Null
            Say ('Intune-Eintrag gelöscht: ' + $d.deviceName) 'Yellow'
        } catch { Fail ('Intune-Eintrag ' + $d.deviceName + ' ist nicht löschbar (' + (Get-ErrScreen $_ 'Intune-Eintrag löschen') + '). Admin: im Intune-Portal löschen oder App-Berechtigung DeviceManagementManagedDevices.ReadWrite.All ergänzen, dann nochmal D:\go.') }
    }
    if (-not $md.Count) { Log 'Kein Intune-Eintrag mit dieser Seriennummer' }
    # 2. Benutzer-Zuweisung aufheben (sonst laesst sich der Eintrag nicht loeschen)
    if ([string]$ap.userPrincipalName) {
        try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $ap.id + '/unassignUserFromDevice') -Headers $h | Out-Null; Log ('Benutzer-Zuweisung aufgehoben: ' + $ap.userPrincipalName) }
        catch { Log ('Benutzer-Zuweisung aufheben: ' + (Get-ErrText $_)) }
    }
    # 3. Autopilot-Eintrag loeschen und warten, bis er weg ist
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/windowsAutopilotDeviceIdentities/' + $ap.id) -Headers $h | Out-Null }
    catch { Fail ('Der alte Autopilot-Eintrag ist nicht löschbar (' + (Get-ErrScreen $_ 'Autopilot-Eintrag löschen') + '). Admin: im Intune-Portal löschen, dann nochmal D:\go.') }
    Say 'Autopilot-Eintrag gelöscht - warte, bis er verschwunden ist (bis 30 Min) ...'
    Invoke-ApSync 'nach Löschen'
    $gone = $false
    $t0 = Get-Mono
    $lim = $t0 + 1800
    while ((Get-Mono) -lt $lim) {
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
    if (-not $gone) { Fail 'Der alte Autopilot-Eintrag ist nach 30 Minuten noch nicht verschwunden. Später nochmal D:\go, das Gerät wird dann normal neu importiert.' }
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
        $k = Read-KeyTimeout 10 ('ohne Eingabe: Tag ' + $ap.groupTag + ' behalten') -Valid 'J', 'Y'   # leert vorher den Tastaturpuffer
        if ($k -eq 'J' -or $k -eq 'Y') { Log ('Tag-Änderung bestätigt: ' + $ap.groupTag + ' -> ' + $cfg.GroupTag) }
        else {
            Log ('Vorhandener Tag bleibt: ' + $ap.groupTag + ' (gewählt war ' + $cfg.GroupTag + ')')
            $cfg.GroupTag = [string]$ap.groupTag
            if ($cfg.GroupTag -notmatch $TagPattern) { Log ('Hinweis: vorhandener Tag passt nicht zum Muster ' + $TagPattern + ': ' + $cfg.GroupTag) }
            # erwartetes Profil fuer den behaltenen Tag neu bestimmen (Tag-Pruefung lief mit dem gewaehlten Tag)
            $tp = Get-TagProfiles $cfg.GroupTag
            if ($null -eq $tp) { Log 'Tag-Prüfung nicht möglich (optional: Group.Read.All für die App)' }
            elseif ($tp.Count) { Say ('Profil für Group Tag: ' + ($tp -join ', ')) 'Green' }
            else {
                Log ('Tag-Prüfung: KEIN Profil für behaltenen Tag ' + $cfg.GroupTag)
                Write-Host ('  ACHTUNG: Für den vorhandenen Tag "' + $cfg.GroupTag + '" ist KEIN Autopilot-Profil zugewiesen.') -ForegroundColor Yellow
                Write-Host '  Das Gerät würde vergeblich auf ein Profil warten (Tippfehler in der CSV?).' -ForegroundColor Yellow
                Write-Host '  [A] Abbrechen   -   [Enter] trotzdem weiter' -ForegroundColor Yellow
                $k2 = Read-KeyTimeout 20 'ohne Eingabe: trotzdem weiter' -Valid 'A'
                if ($k2 -eq 'A') { Log 'Abbruch: kein Profil für behaltenen Tag'; Protokoll 'ABBRUCH: kein Profil für Group Tag'; Stop-ByUser ('Für den vorhandenen Tag ' + $cfg.GroupTag + ' gibt es kein Autopilot-Profil, mit A abgebrochen.') }
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
        } catch { Fail ('Der Group Tag ließ sich in Autopilot nicht ändern (' + (Get-ErrScreen $_ 'Tag ändern') + '). Nochmal D:\go, sonst Foto an den Admin (App-Berechtigung DeviceManagementServiceConfig.ReadWrite.All).') }
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
    } catch { Fail ('Microsoft hat den Import abgelehnt (' + (Get-ErrScreen $_ 'Import') + '). Nochmal D:\go, sonst Foto an den Admin.') }

    $state = ''
    $t0 = Get-Mono
    $limit = $t0 + 600
    while ((Get-Mono) -lt $limit) {
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
        # 806/808 in Klartext mit naechstem Schritt (Get-ImportErrorText), andere Codes wie bisher
        $ie = Get-ImportErrorText $ec $en
        if ($ie) { Log $ie.Log; Fail $ie.Was -Tun $ie.Tun }
        Fail ('Microsoft meldet einen Import-Fehler: ' + $en + ' (' + $ec + '). Nochmal D:\go, sonst Foto an den Admin.')
    }
    if ($state -ne 'complete') { Fail ('Der Import ist nach 10 Minuten nicht fertig (Status: ' + $state + '). Nochmal D:\go, ein inzwischen fertiger Import wird erkannt.') }
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/deviceManagement/importedWindowsAutopilotDeviceIdentities/' + $imp.id) -Headers $h | Out-Null } catch { }
    Say 'Import abgeschlossen' 'Green'
}

if ($AssignUpn) {
    $apU = $null
    $t0 = Get-Mono
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
    } catch { Log ('WLAN-Paket kopieren: ' + $_.Exception.Message); Fail ('Das WLAN-Paket ließ sich nicht vom Stick kopieren (Details im Log). Stick neu anstecken, dann nochmal D:\go.') }
    Log 'WLAN-Paket lokal kopiert'
}
Protokoll ($(if ($AlreadyReg) { 'BEREITS REGISTRIERT' } else { 'UPLOAD OK' }) + $(if ($DoReset) { '' } else { ' (ohne Zurücksetzen)' }))
# Upload fertig: gemerkte Antworten (Home auf Pro) nicht bei spaeteren Laeufen wieder anbieten.
# Die Merkdatei selbst bleibt (Schutz gegen einen stillen zweiten Umstellungsversuch). Stick ist hier noch da.
if ($EdMark -and $EdMark.Antworten) {
    $mk = Get-EdMarkBase $EdMark
    if ($EdActivate -and $okAct) { $mk.Aktiviert = $true; $mk.AktiviertAm = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    Save-EdMark $mk
    Log 'Merkdatei Edition: gemerkte Antworten entfernt (Upload fertig)'
}
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
    # -Round: nur Anzeige (Zaehler der Warterunden), die Entscheidung bleibt unveraendert
    param([int]$NoDateMin = 0, [string]$Round = '')
    $lbl = 'Profil' + $(if ($Round) { ' (Runde ' + $Round + ')' } else { '' }) + ': '
    $assigned = $false
    $noDateSince = $null
    $shownTxt = ''
    $t0 = Get-Mono
    $pn = ''
    $okCount = 0
    $lastTxt = ''
    $extra = $false
    if ($TagChanged -and $null -eq $TagProfIds) { Log 'Tag geändert, Tag-Prüfung nicht möglich - keine automatische Freigabe' }
    $limit = (Get-Mono) + $ProfileWaitMin * 60
    $syncAt = Get-Mono
    while ((Get-Mono) -lt $limit -or ($okCount -eq 1 -and -not $extra)) {
        # Noch nicht zugewiesen: Autopilot-Sync alle 5 Min wiederholen. Der Sync nach dem Import kann mit 429 abgewiesen werden,
        # wenn kurz vorher (< 10 Min, MS Doku) schon einer lief - z. B. vom vorigen Geraet. Dann kommt die Zuweisung sonst erst spaet.
        if ($okCount -eq 0 -and ((Get-Mono) - $syncAt) / 60 -ge 5) { Invoke-ApSync 'Warten auf Profil'; $syncAt = Get-Mono }
        if ((Get-Mono) -ge $limit -and $okCount -eq 1) { $extra = $true }   # erster Treffer kam kurz vor Ablauf: genau eine Kontrollrunde zusaetzlich
        # Abfrage-Hinweis an die aktuelle Zeile anhaengen, damit bei Statuswechsel der ALTE Status als Verlauf stehen bleibt
        if ($shownTxt) { Show-Live ($lbl + $shownTxt + '  |  ' + (Format-Dauer ((Get-Mono) - $t0)) + '  |  frage ab ...') } else { Show-Live ($lbl + 'frage ab ...') }
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
            elseif ($null -ne $TagProfIds -and -not $TagProfIds.Count) { $why = 'für den Group Tag ist kein Profil zugewiesen'; $wrong = $true }
            elseif ($null -ne $TagProfIds -and ($TagProfIds -notcontains $pi)) { $why = 'anderes Profil als für den Group Tag erwartet'; $wrong = $true }
            elseif ($TagChanged -and $null -eq $TagProfIds) { $why = 'Tag geändert, erwartetes Profil unbekannt' }
            elseif (-not $pd) {
                $noDate = $true
                if ($null -eq $noDateSince) { $noDateSince = Get-Mono }
                if ($NoDateMin -gt 0 -and ((Get-Mono) - $noDateSince) / 60 -ge $NoDateMin) { $ready = $true; $why = 'ohne Zuweisungsdatum freigegeben (' + $NoDateMin + ' Min stabil, nur OOBE-Neustart)' }
                else { $why = 'Zuweisungsdatum leer' }
            }
            else { $ready = $true }
        } else { $why = 'Status ' + $(if ($ps) { $ps } else { 'leer' }) }
        if (-not $noDate) { $noDateSince = $null }
        # Ohne Datum (nur OOBE): Wartezeit so verlaengern, dass die NoDateMin-Frist sicher ablaufen kann (nur nach oben)
        if ($null -ne $noDateSince -and $NoDateMin -gt 0) { $lim2 = $noDateSince + ($NoDateMin + 1.5) * 60; if ($lim2 -gt $limit) { $limit = $lim2 } }
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
            Show-Live ($lbl + $txt + '  |  ' + (Format-Dauer ((Get-Mono) - $t0)) + '  |  OK')
            Complete-Live
            $assigned = $true; break
        }
        if ($extra) { Complete-Live; break }
        $lt = $lbl + $txt
        if ($noDate -and $NoDateMin -gt 0) { $lt += ' (Neustart in ' + [int][math]::Max(1, [math]::Ceiling($NoDateMin - ((Get-Mono) - $noDateSince) / 60)) + ' Min)' }
        Wait-Live (Get-Random -Minimum 26 -Maximum 35) $lt $t0 ([int]($limit - $t0)) $(if ($okCount -eq 1) { 'Kontrolle' } else { 'nächste Abfrage' })
    }
    Complete-Live
    return [pscustomobject]@{ Assigned = $assigned; LastTxt = $lastTxt; Profil = $pn }
}

function Test-StickDrive {
    # Laeuft go von einem Stick? $false nur, wenn sicher kein Stick (z. B. Testkopie auf der Festplatte),
    # im Zweifel $true (lieber auf "Stick abziehen" warten: ein steckender Ventoy-Stick koennte beim Neustart booten)
    param([string]$Root)
    if (-not $Root -or $Root -notmatch '^[A-Za-z]:') { return $false }
    $dl = $Root.Substring(0, 1)
    if ($env:SystemDrive -and $Root.Substring(0, 2) -ieq $env:SystemDrive) { return $false }
    try {
        $di = New-Object System.IO.DriveInfo($dl)
        if (-not $di.IsReady) { return $false }
        if ([string]$di.DriveType -eq 'Network') { return $false }
        if ([string]$di.DriveType -ne 'Fixed') { return $true }
    } catch { return $true }
    # Fixed: USB-Festplatten und manche Sticks melden sich als fest -> Bus pruefen
    try { return ([string](Get-Partition -DriveLetter $dl -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType -in 'USB', 'SD', 'MMC') } catch { return $true }
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
    Banner 'OK  -  HOCHGELADEN  -  STICK ABZIEHEN' 'DarkGreen' (@('', ('Group Tag: ' + $cfg.GroupTag + $(if ($AssignUpn) { '   Benutzer: ' + $AssignUpn } else { '' })), '') + (Get-EndLines 'UploadWarten'))
    Show-Step 5 'Profil'
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
        elseif (-not (Test-StickDrive $stickRoot)) { Log ('go läuft nicht von einem Stick (' + $stickRoot + ') - kein Warten auf Stick abziehen'); $stickRoot = 'Z:\HUPilot-kein-Stick' }
        Show-Step 6 'Neustart'
        $t0 = Get-Mono
        $wait = $t0 + 300
        $shown = $false
        while ((Test-Path -LiteralPath ($stickRoot + '\')) -and (Get-Mono) -lt $wait) {
            if (-not $shown) {
                Banner 'PROFIL DA  -  JETZT STICK ABZIEHEN' 'DarkYellow' (@('') + (Get-EndLines 'UploadStickAbziehen'))
                $shown = $true
            }
            Wait-Live 2 'Warte, bis der Stick abgezogen ist' $t0 300 ''
        }
        Complete-Live
        if (Test-Path -LiteralPath ($stickRoot + '\')) {
            Log 'Stick nach 5 Min noch gesteckt - kein automatischer Neustart'
            Banner 'PROFIL DA  -  NEUSTART VON HAND' 'DarkYellow' (@('') + (Get-EndLines 'UploadNeustartVonHand'))
            Wait-Close
            exit 0
        }
        Banner 'OK  -  PROFIL DA  -  NEUSTART IN 15 s' 'DarkGreen' (@('') + (Get-EndLines 'UploadNeustart'))
        $k = Read-KeyTimeout 15 'Neustart' -Valid 'A'
        if ($k -eq 'A') { Log 'Neustart abgebrochen'; Stop-ByUser '' 'NeustartAbgebrochen' 0 }
        # /f: offene Programme (z. B. "Program Manager" im OOBE) duerfen den Neustart nicht blockieren
        Log 'Neustart (shutdown /r /f /t 0)'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/r', '/f', '/t', '0' -WindowStyle Hidden
        exit 0
    }
    if ($wr.Assigned) {
        Log ('Nur Upload: Profil zugewiesen: ' + $wr.Profil)
        Banner 'OK  -  PROFIL DA' 'DarkGreen' (@('') + (Get-EndLines 'UploadFertig'))
    } else {
        Log ('Nur Upload: Profil nach Wartezeit NICHT sicher zugewiesen, letzter Status: ' + $wr.LastTxt)
        Banner 'NOCH KEIN PROFIL' 'DarkYellow' (@('') + (Get-EndLines 'UploadKeinProfil'))
    }
    Wait-Close
    exit 0
}

Banner 'OK  -  STICK ABZIEHEN  -  nächstes Gerät' 'DarkGreen' (@('', ('Group Tag: ' + $cfg.GroupTag + $(if ($AssignUpn) { '   Benutzer: ' + $AssignUpn } else { '' })), '') + (Get-EndLines 'ResetWarten'))
$GreenAt = Get-Mono

# ---------- 5. Auf Profil warten ----------
# Kein Profil nach einer Runde ($ProfileWaitMin): Standard ist "weiter warten" (neue Runde Wait-ApProfile),
# zurueckgesetzt wird ohne Profil NUR auf ausdruecklichen Tastendruck J, N bricht ab.
# Hoechstens $ProfileRounds Runden (4 x 20 Min = 80 Min), danach gelb und NICHT zurueckgesetzt.
Show-Step 5 'Profil'
$round = 1
$wr = Wait-ApProfile -Round ('1/' + $ProfileRounds)
while (-not $wr.Assigned) {
    Log ('Profil nach Runde ' + $round + ' von ' + $ProfileRounds + ' NICHT sicher zugewiesen, letzter Status: ' + $wr.LastTxt)
    $minSoFar = [int][math]::Round(((Get-Mono) - $GreenAt) / 60)
    if ($round -ge $ProfileRounds) {
        Protokoll ('ABBRUCH: kein Profil nach ' + $minSoFar + ' Min, nicht zurückgesetzt')
        $kpWas = 'Der Upload ist fertig, aber nach ' + $minSoFar + ' Minuten ist noch kein Autopilot-Profil da (letzter Stand: ' + $wr.LastTxt + ').'
        $kpTun = 'Später Stick rein, Shift+F10, D:\go (Upload wird übersprungen), kommt das Profil nie: den Admin fragen.'
        Banner 'NOCH KEIN PROFIL  -  NICHT ZURÜCKGESETZT' 'DarkYellow' (@('') + (Get-EndLines 'KeinProfilEnde' $kpWas $kpTun))
        Write-ReportLine (Send-GoReport (Get-EndText 'KeinProfilEnde' $kpWas $kpTun) 'KeinProfilEnde')
        Wait-Close
        exit 1
    }
    Banner 'NOCH KEIN PROFIL' 'DarkYellow' @(
        '',
        ('Seit ' + $minSoFar + ' Minuten kein Autopilot-Profil (letzter Stand: ' + $wr.LastTxt + ').'),
        'Ohne Profil kommt nach dem Zurücksetzen das normale Windows-Setup.',
        '',
        ('[Enter]  weiter warten und erneut prüfen, Runde ' + ($round + 1) + ' von ' + $ProfileRounds + '   (Standard)'),
        '[J]      trotzdem zurücksetzen, ohne Profil',
        '[N]      abbrechen, später nochmal D:\go')
    $k = Read-KeyTimeout 60 'ohne Eingabe: weiter warten' -Valid 'J', 'Y', 'N'
    if ($k -eq 'N') { Log 'Abbruch durch Benutzer (kein Reset)'; Protokoll 'ABBRUCH: kein Profil, abgebrochen (N)'; Stop-ByUser 'Der Upload ist fertig, das Warten auf das Profil wurde mit N abgebrochen.' }
    if ($k -eq 'J' -or $k -eq 'Y') { Log 'Zurücksetzen OHNE Profil mit Taste J bestätigt'; break }
    $round++
    try { $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
    Write-Host ''
    Say ('Weiter warten auf das Profil: Runde ' + $round + ' von ' + $ProfileRounds + '. Gerät NICHT ausschalten.') 'Cyan'
    Invoke-ApSync 'neue Warterunde'
    $wr = Wait-ApProfile -Round ('' + $round + '/' + $ProfileRounds)
}
$assigned = $wr.Assigned
$lastTxt = $wr.LastTxt

# Gruenen Hinweis mind. 60 s stehen lassen (damit man ihn sieht und den Stick abzieht)
$rest = 60 - [int]((Get-Mono) - $GreenAt)
if ($rest -gt 0) { Log ('Grün bleibt noch ' + $rest + ' s stehen'); Wait-Live $rest $(if ($assigned) { 'Profil da' } else { 'Ohne Profil (J gedrückt)' }) -1 0 'Zurücksetzen startet'; Complete-Live }
# ---------- 6. WLAN-Paket + Zuruecksetzen ohne Hersteller-Anpassungen ----------
Show-Step 6 'Zurücksetzen'
Wait-Power
$ErrorActionPreference = 'Continue'
function Fail-Reset {
    # $Msg = Klartext fuer das Bild, $Detail = roher Text nur ins Log, $Jetzt = schon Veraendertes (sonst "nicht zurueckgesetzt")
    param([string]$Msg, [string]$Detail = '', [string]$Jetzt = '', [switch]$NoReport)
    Log ('FEHLER Zurücksetzen: ' + $Msg + $(if ($Detail) { ' | ' + $Detail } else { '' }))
    $wasR = 'Der Upload ist fertig, aber das Zurücksetzen ist nicht gestartet (' + $Msg.TrimEnd('.') + ').'
    Banner 'FEHLER beim Zurücksetzen' 'DarkRed' (@('') + (Get-EndLines 'FehlerReset' $wasR '' $Jetzt) + @('', ('Log: ' + $LocalLog + ' und ' + $WipeLog)))
    if ($NoReport) { Log 'Kein Bericht an den Admin: Abbruch auf Wunsch des Benutzers' }
    else { Write-ReportLine (Send-GoReport (Get-EndText 'FehlerReset' $wasR '' $Jetzt) 'FehlerReset') }
    Wait-Close
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
        Write-Host '  Hinweis: Intune sperrt neue Pakete auf diesem Gerät.' -ForegroundColor (Get-ReadableColor 'Yellow')
        Write-Host '  Das vorhandene WLAN-Paket bleibt - Änderungen (z. B. lokaler Admin) kommen NICHT mit.' -ForegroundColor (Get-ReadableColor 'Yellow')
        [void](Read-KeyTimeout 30 'beliebige Taste oder weiter')
    }
    elseif ($ppBlocked) {
        Log 'Intune sperrt Bereitstellungspakete (AllowAddProvisioningPackage=0) und es ist kein WLAN-Paket installiert'
        Banner 'ACHTUNG  -  WLAN-PAKET VON INTUNE GESPERRT' 'DarkYellow' @(
            '',
            'Intune verbietet auf diesem Gerät neue Bereitstellungspakete.',
            'Nach dem Zurücksetzen ist das Konfigurations-WLAN NICHT da:',
            'LAN-Kabel anstecken oder WLAN im Einrichtungsbildschirm von Hand wählen.')
        $a = Read-Line '  J = trotzdem zurücksetzen, Enter = abbrechen'
        if ($a -notmatch '^[jJyY]') { Fail-Reset 'WLAN-Paket von Intune gesperrt, abgebrochen' -Detail 'AllowAddProvisioningPackage=0' -NoReport }
        Log 'Trotzdem zurücksetzen (ohne WLAN-Paket) bestätigt'
    }
    else {
        $prov = Join-Path $env:SystemRoot 'System32\provtool.exe'
        if (-not (Test-Path $prov)) { Fail-Reset 'das Windows-Programm für das WLAN-Paket fehlt' -Detail ('provtool.exe nicht gefunden: ' + $prov) }
        Log ('provtool.exe ' + $TmpPkg + ' /quiet')
        # Zeitlimit 2 Min wie im Zweig "nur hochladen"; haengt provtool, gilt das wie ein Fehler: neuer Versuch als SYSTEM im Hilfsscript
        $pr = $null
        $prOk = $false
        Show-Live 'WLAN-Paket wird installiert ...'
        try {
            $pr = Start-Process -FilePath $prov -ArgumentList ('"' + $TmpPkg + '"', '/quiet') -PassThru -WindowStyle Hidden -ErrorAction Stop
            if ($pr.WaitForExit(120000)) { Log ('provtool Exitcode: ' + $pr.ExitCode); $prOk = ($pr.ExitCode -eq 0) }
            else { Log 'provtool nach 2 Min nicht fertig - abgebrochen'; try { $pr.Kill() } catch { } }
        } catch { Log ('provtool: ' + $_.Exception.Message) }
        Complete-Live
        if (-not $prOk) { Log 'provtool fehlgeschlagen - neuer Versuch als SYSTEM im Hilfsscript'; $SysPkg = $TmpPkg }
        elseif (-not (Test-Path $persist)) { Log ('Hinweis: ' + $persist + ' nicht gefunden - WLAN nach dem Zurücksetzen evtl. von Hand') }
        else { Log 'WLAN-Paket in ProgramData\Provisioning gespeichert' }
    }
}

# 6b. Hilfsscript fuer SYSTEM schreiben (WMI-Bridge braucht LocalSystem - MS Doku)
$wipe = @'
$log = 'C:\Windows\Temp\HUPilot-Wipe.log'
$res = 'C:\Windows\Temp\HUPilot-Wipe.result'
# Jede Logzeile und das Ergebnis tragen die Laufkennung: go wertet nur Zeilen und ein Ergebnis dieses Laufs aus
function L([string]$m) { try { Add-Content -Path $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  [__RUNID__]  ' + $m) -Encoding UTF8 } catch { } }
function Write-WipeRes([string]$v) { try { Set-Content -Path $res -Value ('LAUF __RUNID__ ' + $v) -Encoding UTF8 } catch { L ('Ergebnis nicht schreibbar: ' + $_.Exception.Message) } }
L ('LAUF __RUNID__ Start als ' + [Environment]::UserName)
# 0. WLAN-Paket als SYSTEM installieren (nur wenn es als Benutzer nicht ging)
$pkg = '__SYSPKG__'
if ($pkg) {
    $persist = Join-Path $env:ProgramData ('Microsoft\Provisioning\' + (Split-Path $pkg -Leaf))
    # Altes Paket NICHT entfernen: neues Paket hat eine eigene ID und wird zusaetzlich installiert
    $pr = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\provtool.exe') -ArgumentList ('"' + $pkg + '"', '/quiet') -Wait -PassThru -WindowStyle Hidden
    L ('provtool als SYSTEM Exitcode: ' + $pr.ExitCode)
    $ok = $false
    if (Test-Path $persist) { try { $ok = ((Get-FileHash -Path $persist -Algorithm SHA256).Hash -eq (Get-FileHash -Path $pkg -Algorithm SHA256).Hash) } catch { } }
    if (-not $ok) { L 'FEHLER: WLAN-Paket nicht installiert - kein Zuruecksetzen'; Write-WipeRes ('ERR WLAN-Paket auch als SYSTEM nicht installiert (provtool ' + $pr.ExitCode + ')'); exit 1 }
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
    } catch { L ('FEHLER Pakete sichern: ' + $_.Exception.Message + ' - nichts entfernt'); Write-WipeRes ('ERR Pakete sichern: ' + $_.Exception.Message); exit 1 }
    # Schritt 2: entfernen (offiziell), sonst Datei loeschen - die Sicherung ist geprueft
    foreach ($c in $cand) {
        if ($prov) { try { Remove-ProvisioningPackage -Path $c.File.FullName -ErrorAction Stop | Out-Null } catch { L ('Remove-ProvisioningPackage ' + $c.File.Name + ': ' + $_.Exception.Message) } }
        if (Test-Path -LiteralPath $c.File.FullName) {
            try { Remove-Item -LiteralPath $c.File.FullName -Force -ErrorAction Stop; L ('Paket entfernt (' + $c.Why + ', Datei, Sicherung vorhanden): ' + $c.File.Name) }
            catch { L ('FEHLER Paket entfernen ' + $c.File.Name + ': ' + $_.Exception.Message); Write-WipeRes ('ERR Paket ' + $c.File.Name + ' nicht entfernbar: ' + $_.Exception.Message); exit 1 }
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
} catch { L ('FEHLER verschieben: ' + $_.Exception.Message); Write-WipeRes ('ERR verschieben: ' + $_.Exception.Message); exit 1 }
# 3. Zuruecksetzen ("Alles entfernen"), Provisioning-Pakete bleiben erhalten
try {
    $ns = 'root\cimv2\mdm\dmmap'
    $session = New-CimSession
    $params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
    $param = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param', '', 'String', 'In')
    $params.Add($param)
    $inst = Get-CimInstance -Namespace $ns -ClassName 'MDM_RemoteWipe' -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" -ErrorAction Stop
    L 'WIPE-AUFRUF doWipePersistProvisionedDataMethod'
    $r = $session.InvokeMethod($ns, $inst, 'doWipePersistProvisionedDataMethod', $params)
    $rv = [string]$r.ReturnValue.Value
    L ('doWipePersistProvisionedDataMethod ReturnValue: ' + $rv)
    Write-WipeRes ('OK ' + $rv)
} catch { L ('FEHLER Wipe: ' + $_.Exception.Message); Write-WipeRes ('ERR Wipe: ' + $_.Exception.Message); exit 1 }
'@
# Optionen fuer das SYSTEM-Script - VOR dem Ersetzen der Platzhalter bestimmen
$RmOther = ($cfg.RemoveOtherPackages -eq $true)
# Hersteller-Apps (Regex auf den App-Namen), Standard McAfee; "RemoveApps": "" schaltet es aus
$RmApps = 'McAfee'
if ($null -ne $cfg.RemoveApps) { $RmApps = [string]$cfg.RemoveApps }
try { [void][regex]::new($RmApps) } catch { Log ('RemoveApps ist kein gültiger Ausdruck - aus: ' + $RmApps); $RmApps = '' }
$KeepHash = ''
if (Test-Path -LiteralPath $TmpPkg) { try { $KeepHash = (Get-FileHash -LiteralPath $TmpPkg -Algorithm SHA256).Hash } catch { } }
# Laufkennung fuer das Wipe-Log; altes Log und Ergebnis vorher wegraeumen (gelingt das nicht, zaehlt trotzdem nur dieser Lauf)
$WipeRun = [guid]::NewGuid().ToString('N').Substring(0, 12)
try {
    if (Test-Path -LiteralPath $WipeResult) { try { Remove-Item -LiteralPath $WipeResult -Force -ErrorAction Stop } catch { Log ('Alte Ergebnisdatei nicht entfernt (zählt nicht, nur Ergebnisse mit der Kennung dieses Laufs): ' + $_.Exception.Message) } }
    if (Test-Path -LiteralPath $WipeLog) { try { Remove-Item -LiteralPath $WipeLog -Force -ErrorAction Stop } catch { Log ('Altes Wipe-Log nicht entfernt: ' + $_.Exception.Message) } }
    # UTF-8 mit BOM: Namen mit Umlauten (WLAN-Paket, RemoveApps) kommen unveraendert an; ASCII-Inhalt bleibt gleich (nur BOM davor)
    $wipeText = $wipe.Replace('__SYSPKG__', $SysPkg).Replace('__RMOTHER__', $(if ($RmOther) { '$true' } else { '$false' })).Replace('__KEEPPKG__', ([string]$WlanPkgName).Replace("'", "''")).Replace('__KEEPHASH__', $KeepHash).Replace('__RMAPPS__', $RmApps.Replace("'", "''")).Replace('__RUNID__', $WipeRun)
    [System.IO.File]::WriteAllText($WipePs1, $wipeText, (New-Object System.Text.UTF8Encoding $true))
    Log ('Hilfsscript geschrieben, Lauf ' + $WipeRun)
} catch { Fail-Reset 'das Hilfsprogramm zum Zurücksetzen ließ sich nicht anlegen' -Detail ('Hilfsscript schreiben: ' + $_.Exception.Message) }

# Fremde Bereitstellungspakete anzeigen (werden im SYSTEM-Script entfernt)
$other = @(Get-ChildItem -Path (Join-Path $env:ProgramData 'Microsoft\Provisioning') -Filter *.ppkg -ErrorAction SilentlyContinue | Where-Object { $_.Name -ine $WlanPkgName -and $_.Name -notlike 'HUPilot*' } | ForEach-Object { $_.Name })
if ($other.Count) {
    if ($RmOther) { Say ('Fremde Bereitstellungspakete werden entfernt: ' + ($other -join ', ')) 'Yellow' }
    else { Log ('Fremde Bereitstellungspakete bleiben (RemoveOtherPackages=false): ' + ($other -join ', ')) }
}
Banner 'ZURÜCKSETZEN STARTET' 'DarkBlue' (@('') + (Get-EndLines $(if ($assigned) { 'ResetStart' } else { 'ResetStartOhneProfil' })))

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
try { [System.IO.File]::WriteAllText($taskFile, $taskXml.Replace('__PS1__', $WipePs1), [System.Text.Encoding]::Unicode) } catch { Fail-Reset 'die geplante Aufgabe ließ sich nicht anlegen' -Detail ('Aufgaben-XML schreiben: ' + $_.Exception.Message) }
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
    else { Fail-Reset 'die geplante Aufgabe ließ sich nicht anlegen' -Detail ('Geplante Aufgabe nicht angelegt: ' + $(if ($q) { $q } else { '(schtasks ohne Ausgabe)' })) }
}
$started = $false
try { Start-ScheduledTask -TaskName $tn -ErrorAction Stop; $started = $true; Log 'Aufgabe gestartet (Start-ScheduledTask)' } catch { Log ('Start-ScheduledTask: ' + $_.Exception.Message) }
if (-not $started) {
    $o = cmd.exe /c ('schtasks /Run /TN "' + $tn + '" 2>&1')
    Log ('schtasks run: ' + (($o | Out-String).Trim()))
}
$res = ''
$foreignRes = $false
$t0 = Get-Mono
for ($i = 0; $i -lt 100; $i++) {          # 100 x 3 s = 5 Min (Hersteller-Apps entfernen kann dauern)
    Wait-Live 3 'Zurücksetzen wird vorbereitet' $t0 300 ''
    if (Test-Path $WipeResult) {
        $raw = ''; try { $raw = [string](Get-Content -Path $WipeResult -Raw -Encoding UTF8 -ErrorAction Stop) } catch { }
        $res = Get-WipeResult $raw $WipeRun
        if ($res) { break }
        if ($raw.Trim() -and -not $foreignRes -and $raw.Trim() -notmatch ('^LAUF ' + [regex]::Escape($WipeRun) + '\b')) { $foreignRes = $true; Log 'Ergebnisdatei ohne die Kennung dieses Laufs - zählt nicht' }
    }
}
Complete-Live
$stopOk = $true
if (-not $res) {
    # Keine Rueckmeldung: Aufgabe stoppen, sonst setzt das SYSTEM-Script nach dem roten Banner doch noch zurueck
    $stopOk = Stop-WipeTask $tn 'keine Rückmeldung nach 5 Min'
    if (Test-Path $WipeResult) { try { $res = Get-WipeResult ([string](Get-Content -Path $WipeResult -Raw -Encoding UTF8 -ErrorAction Stop)) $WipeRun } catch { } }
}
# Nur Zeilen dieses Laufs zaehlen (Kennung in jeder Zeile)
function Read-WipeRunLines { try { return @(Get-WipeRunLines @(Get-Content -LiteralPath $WipeLog -Encoding UTF8 -ErrorAction Stop) $WipeRun) } catch { return @() } }
$wipeLines = @(Read-WipeRunLines)
$wo = Get-WipeOutcome $res $wipeLines $stopOk
if ($wo.Kind -eq 'Fehler' -and $res) {
    # Fehler gemeldet: "nicht zurueckgesetzt" nur, wenn die Aufgabe nachweislich nicht mehr laeuft
    $stopOk = Stop-WipeTask $tn 'Fehler gemeldet'
    $wipeLines = @(Read-WipeRunLines)
    $wo = Get-WipeOutcome $res $wipeLines $stopOk
}
if (-not $wipeLines.Count) { Log ('Wipe-Log ohne Einträge dieses Laufs (' + $WipeRun + ')') }
foreach ($x in $wipeLines) { Log ('[SYSTEM] ' + $x) }
Log ('Auswertung Zurücksetzen: ' + $wo.Kind + ', Rückmeldung "' + $res + '", Aufruf ' + $(if ($wo.Called) { 'abgesetzt' } else { 'nicht abgesetzt' }) + ', Aufgabe ' + $(if ($stopOk) { 'läuft nicht mehr' } else { 'läuft evtl. noch' }) + $(if ($wo.Rv -and $wo.Rv -ne '0') { ', ACHTUNG ReturnValue ' + $wo.Rv + ' (erwartet 0, Bedeutung nicht belegt)' } elseif ($wo.Kind -eq 'Unklar' -and $res -match '^OK') { ', ACHTUNG ReturnValue leer' } else { '' }))
if (@($wo.Changes).Count) { Log ('Schon verändert: ' + (@($wo.Changes) -join ', ')) }
if ($wo.Kind -eq 'Fehler') { Fail-Reset $wo.Why -Detail $res -Jetzt (Get-WipeJetzt 'Fehler' $wo.Changes $wo.LogFehlt) }
Write-Host ''
if ($wo.Kind -eq 'Ok') { Log ('Zurücksetzen angenommen: ' + $res); Write-Host '  Zurücksetzen angenommen - Neustart folgt in Kürze (etwa 5 Minuten).' -ForegroundColor White }
else { Write-Host '  Zurücksetzen aufgerufen, die Antwort von Windows ist unklar - warte auf den Neustart.' -ForegroundColor White }
Wait-Live 900 'Warte auf Neustart' -1 0 ''
Log 'Nach 15 Min kein Neustart - Zuruecksetzen hat (noch) nicht begonnen'
Protokoll 'FEHLER: Zuruecksetzen nach 15 Min nicht begonnen'
# Nie "nicht zurueckgesetzt": der Aufruf ist abgesetzt bzw. nicht sicher gestoppt, es kann noch starten
$wasN = $(if ($wo.Kind -eq 'Unklar') { $wo.Why } else { '' })
$jetztN = Get-WipeJetzt $wo.Kind $wo.Changes
Banner 'ZURÜCKSETZEN NOCH NICHT BEGONNEN' 'DarkRed' (@('') + (Get-EndLines 'ResetNichtGestartet' $wasN '' $jetztN) + @('', ('Log: ' + $LocalLog + ' und ' + $WipeLog)))
Write-ReportLine (Send-GoReport (Get-EndText 'ResetNichtGestartet' $wasN '' $jetztN) 'ResetNichtGestartet')
Wait-Close
