#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer go.ps1 und diag.ps1, Version 2.8.0: Korrekturen aus der externen Pruefung.
# Funktionen werden per AST geloest und ohne Geraet geprueft (kein Graph, kein Netz, nur kuenstliche Werte).

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:GoPath = Join-Path $script:Root 'Stick\HUPilot\go.ps1'
    $script:DiagPath = Join-Path $script:Root 'Stick\HUPilot\diag.ps1'
    $script:GoText = Get-Content -LiteralPath $script:GoPath -Raw -Encoding UTF8
    $script:DiagText = Get-Content -LiteralPath $script:DiagPath -Raw -Encoding UTF8
    function Get-FunctionText([string]$Path, [string[]]$Names) {
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tk, [ref]$er)
        $t = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Names -contains $_.Name } | ForEach-Object { $_.Extent.Text })
        if ($t.Count -ne $Names.Count) { throw ('Funktionen nicht (eindeutig) gefunden: ' + ($Names -join ', ')) }
        return ($t -join "`n")
    }
    function Get-GoFunctionText([string[]]$Names) { return (Get-FunctionText $script:GoPath $Names) }
    # Teil von go.ps1 nach dem Start der geplanten Aufgabe (Auswertung des Zuruecksetzens)
    $i = $script:GoText.IndexOf('$started = $false')
    $script:GoTail = $script:GoText.Substring($i)
}

Describe 'go 2.8.0 B1: nach dem Start des Zuruecksetzens nie "nicht zurueckgesetzt", wenn es noch starten kann' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-WipeOutcome', 'Get-WipeChanges', 'Get-WipeErrText', 'Get-WipeJetzt', 'Get-EndText', 'Format-EndLines', 'Get-EndLines')))
        $script:Called = @('2026-11-14 10:00:00  LAUF abc Start als SYSTEM', '2026-11-14 10:00:05  WIPE-AUFRUF doWipePersistProvisionedDataMethod')
        $script:NotCalled = @('2026-11-14 10:00:00  LAUF abc Start als SYSTEM')
    }
    It 'ReturnValue 0 = angenommen (Ok)' {
        (Get-WipeOutcome 'OK 0' $script:Called $true).Kind | Should -Be 'Ok'
    }
    It 'ReturnValue ungleich 0 oder leer = unklar, Wert im Text, nie Fehler' {
        $o = Get-WipeOutcome 'OK 5' $script:Called $true
        $o.Kind | Should -Be 'Unklar'; $o.Rv | Should -Be '5'; $o.Why | Should -Match '\(5\)'
        $o = Get-WipeOutcome 'OK' $script:Called $true
        $o.Kind | Should -Be 'Unklar'; $o.Why | Should -Match 'kein Wert'
        (Get-WipeOutcome 'OK 2147749891' @() $true).Kind | Should -Be 'Unklar'
    }
    It 'keine Rueckmeldung, Aufruf aber abgesetzt = unklar' {
        (Get-WipeOutcome '' $script:Called $true).Kind | Should -Be 'Unklar'
    }
    It 'keine Rueckmeldung und Aufgabe nicht stoppbar = unklar, auch ohne Aufruf im Log' {
        $o = Get-WipeOutcome '' $script:NotCalled $false
        $o.Kind | Should -Be 'Unklar'; $o.Why | Should -Match 'nicht stoppen'
    }
    It 'keine Rueckmeldung, gestoppt, kein Aufruf = sicher nicht zurueckgesetzt (Fehler)' {
        (Get-WipeOutcome '' $script:NotCalled $true).Kind | Should -Be 'Fehler'
    }
    It 'Fehlerzeile nach dem Aufruf = unklar, vor dem Aufruf = Fehler' {
        (Get-WipeOutcome 'ERR Wipe: Zugriff verweigert' $script:Called $true).Kind | Should -Be 'Unklar'
        (Get-WipeOutcome 'ERR Wipe: Klasse fehlt' $script:NotCalled $true).Kind | Should -Be 'Fehler'
    }
    It 'Text bei unklarem Ausgang: kann noch starten, nie "nicht zurückgesetzt"' {
        foreach ($c in @(@('OK 5', $script:Called, $true), @('', $script:Called, $true), @('', $script:NotCalled, $false), @('ERR Wipe: x', $script:Called, $true))) {
            $o = Get-WipeOutcome $c[0] $c[1] $c[2]
            $j = Get-WipeJetzt $o.Kind $o.Changes
            $j | Should -Match 'kann noch von selbst starten'
            $j | Should -Not -Match 'nicht zurückgesetzt'
            $o.Why | Should -Not -Match 'nicht zurückgesetzt'
        }
    }
    It 'Abschlussbild ResetNichtGestartet: angenommen, kann noch starten, warten, Foto an den Admin' {
        $e = Get-EndText 'ResetNichtGestartet'
        $e.Was | Should -Match 'angenommen'
        $e.Was | Should -Match '15 Minuten nicht begonnen'
        $e.Jetzt | Should -Be 'Es kann noch von selbst starten.'
        $e.Tun | Should -Match 'nicht benutzen und am Strom lassen'
        $e.Tun | Should -Match 'noch 15 Minuten warten'
        $e.Tun | Should -Match 'Foto von diesem Bild an den Admin'
    }
    It 'Einbau: ReturnValue deutlich ins Log, Bild NOCH NICHT BEGONNEN, Fail-Reset nur bei sicherem Fehler' {
        $script:GoTail | Should -Match 'ACHTUNG ReturnValue'
        $script:GoTail | Should -Match "Banner 'ZURÜCKSETZEN NOCH NICHT BEGONNEN'"
        $script:GoTail | Should -Not -Match 'NICHT GESTARTET'
        @([regex]::Matches($script:GoTail, 'Fail-Reset ')).Count | Should -Be 1   # nur der sichere Fehler
        $script:GoTail | Should -Match ([regex]::Escape("if (`$wo.Kind -eq 'Fehler') { Fail-Reset `$wo.Why"))
        $script:GoTail | Should -Not -Match "Fail-Reset 'keine Rückmeldung"
        $script:GoTail | Should -Not -Match 'Fail-Reset \$res'
        $script:GoTail | Should -Not -Match "'nicht zurückgesetzt|Nichts, das Gerät"
    }
    It 'Einbau: Stoppen wird geprueft (Stop-WipeTask: Zustand massgeblich, sonst Exitcode)' {
        $sw = Get-GoFunctionText 'Stop-WipeTask'
        $sw | Should -Match "-notin 'Running', 'Queued'"
        (Get-GoFunctionText 'Invoke-SchtasksEnd') | Should -Match '\$LASTEXITCODE -eq 0'
        $script:GoTail | Should -Match "\`$stopOk = Stop-WipeTask \`$tn 'keine Rückmeldung nach 5 Min'"
        $script:GoTail | Should -Match 'Get-WipeOutcome \$res \$wipeLines \$stopOk'
    }
}

Describe 'go 2.8.0 B3: nur das Wipe-Log dieses Laufs zaehlt' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-WipeRunLines', 'Get-WipeOutcome', 'Get-WipeChanges', 'Get-WipeErrText')))
    }
    It 'ein alter Lauf mit WIPE-AUFRUF zaehlt nicht' {
        $l = @('09:00  [alt111]  LAUF alt111 Start als SYSTEM', '09:01  [alt111]  verschoben: C:\Recovery\OEM\x', '09:02  [alt111]  WIPE-AUFRUF doWipePersistProvisionedDataMethod', '10:00  [neu222]  LAUF neu222 Start als SYSTEM', '10:01  [neu222]  Paket bleibt: a.ppkg')
        $r = @(Get-WipeRunLines $l 'neu222')
        $r.Count | Should -Be 2
        ($r -join "`n") | Should -Not -Match 'WIPE-AUFRUF'
        (Get-WipeOutcome '' $r $true).Kind | Should -Be 'Fehler'
        @((Get-WipeOutcome '' $r $true).Changes).Count | Should -Be 0
    }
    It 'ohne Marke dieses Laufs: nichts' {
        @(Get-WipeRunLines @('09:00  [alt111]  LAUF alt111 Start', '09:02  [alt111]  WIPE-AUFRUF', '09:03  WIPE-AUFRUF ohne Kennung (alte Version)') 'neu222').Count | Should -Be 0
        @(Get-WipeRunLines @('x') '').Count | Should -Be 0
        @(Get-WipeRunLines @() 'neu222').Count | Should -Be 0
    }
    It 'Kennung als ganzes Wort (neu22 trifft nicht neu222)' {
        @(Get-WipeRunLines @('[neu222]  LAUF neu222 Start', '[neu222]  WIPE-AUFRUF') 'neu22').Count | Should -Be 0
    }
    It 'Einbau: altes Log weg, Kennung ins Script, nur dieser Lauf ins Log' {
        $script:GoText | Should -Match "L \('LAUF __RUNID__ Start als "
        $script:GoText | Should -Match "\.Replace\('__RUNID__', \`$WipeRun\)"
        $script:GoText | Should -Match 'Remove-Item -LiteralPath \$WipeLog -Force'
        $script:GoTail | Should -Match 'Get-WipeRunLines @\(Get-Content -LiteralPath \$WipeLog -Encoding UTF8 -ErrorAction Stop\) \$WipeRun'
        $script:GoTail | Should -Not -Match "Select-String -Path \`$WipeLog"
        # Loeschen des alten Logs kommt vor dem Start der Aufgabe
        $script:GoText.IndexOf('Remove-Item -LiteralPath $WipeLog') | Should -BeLessThan $script:GoText.IndexOf('Start-ScheduledTask -TaskName $tn')
    }
}

Describe 'go 2.8.0 B10: schon Veraendertes ehrlich benennen' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-WipeOutcome', 'Get-WipeChanges', 'Get-WipeErrText', 'Get-WipeJetzt')))
    }
    It 'Apps entfernt und Ordner verschoben werden erkannt' {
        $l = @('LAUF a Start', 'Vorinstallierte App entfernt: McAfee.X', 'verschoben: C:\Recovery\OEM\y', 'FEHLER verschieben: Zugriff verweigert')
        $c = @(Get-WipeChanges $l)
        $c | Should -Contain 'Hersteller-Apps entfernt'
        ($c -join ' ') | Should -Match 'Hersteller-Ordner nach C:\\Recovery\\HUPilot-OEM-Backup verschoben'
        $o = Get-WipeOutcome 'ERR verschieben: Zugriff verweigert' $l $true
        $o.Kind | Should -Be 'Fehler'
        $j = Get-WipeJetzt $o.Kind $o.Changes $o.LogFehlt
        $j | Should -Match '^Das Gerät wurde nicht zurückgesetzt, aber schon verändert: '
        $j | Should -Match 'Hersteller-Apps entfernt'
        $j | Should -Match 'verschoben'
    }
    It 'entfernte Pakete werden mit Sicherung genannt' {
        @(Get-WipeChanges @('Paket entfernt (fremdes Paket, Datei, Sicherung vorhanden): a.ppkg')) | Should -Contain 'alte Bereitstellungspakete entfernt (Sicherung in C:\Recovery\HUPilot-PPKG-Backup)'
    }
    It 'nichts veraendert: klares "nicht zurückgesetzt"' {
        $o = Get-WipeOutcome 'ERR WLAN-Paket auch als SYSTEM nicht installiert (provtool 1)' @('LAUF a Start') $true
        (Get-WipeJetzt $o.Kind $o.Changes $o.LogFehlt) | Should -Be 'Nichts, das Gerät wurde nicht zurückgesetzt.'
    }
    It 'Wipe-Log dieses Laufs fehlt: ob etwas veraendert wurde, ist unklar' {
        $o = Get-WipeOutcome 'ERR verschieben: x' @() $true
        $o.LogFehlt | Should -BeTrue
        (Get-WipeJetzt $o.Kind $o.Changes $o.LogFehlt) | Should -Match 'unklar'
        (Get-WipeOutcome 'ERR Pakete sichern: x' @() $true).LogFehlt | Should -BeFalse
    }
    It 'Veraendertes steht auch beim unklaren Ausgang' {
        (Get-WipeJetzt 'Unklar' @('Hersteller-Apps entfernt')) | Should -Be 'Es kann noch von selbst starten. Schon verändert: Hersteller-Apps entfernt.'
    }
}

Describe 'go 2.8.0 U1: im Bild nur Klartext und Fehlercode, roher Text ins Log' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-ErrText', 'Get-ErrCode', 'Get-WipeErrText')))
        function New-FakeErr([int]$Status, [string]$Body, [string]$Msg = 'Der Remoteserver hat einen Fehler zurückgegeben.') {
            $resp = $null; if ($Status) { $resp = [pscustomobject]@{ StatusCode = $Status } }
            $det = $null; if ($Body) { $det = [pscustomobject]@{ Message = $Body } }
            return [pscustomobject]@{ Exception = [pscustomobject]@{ Message = $Msg; Response = $resp }; ErrorDetails = $det }
        }
    }
    It 'Graph-Fehler als JSON: HTTP-Status und Code, nicht die englische Meldung' {
        $c = Get-ErrCode (New-FakeErr 403 '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}}')
        $c | Should -Be 'HTTP 403 Authorization_RequestDenied'
        $c | Should -Not -Match 'Insufficient'
    }
    It 'Entra-Fehler: AADSTS-Code' {
        (Get-ErrCode (New-FakeErr 401 '{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided."}')) | Should -Be 'HTTP 401 invalid_client'
        (Get-ErrCode (New-FakeErr 0 '' 'AADSTS50034: The user account does not exist')) | Should -Be 'AADSTS50034'
    }
    It 'ohne erkennbaren Code: Hinweis aufs Log' {
        (Get-ErrCode (New-FakeErr 0 '' 'irgendwas')) | Should -Be 'Fehlercode unbekannt, Details im Log'
        (Get-ErrCode (New-FakeErr 0 '{"error":{"code":"<script>alert(1)</script>"}}')) | Should -Be 'Fehlercode unbekannt, Details im Log'
    }
    It 'Fehlerzeilen des SYSTEM-Scripts in Klartext' {
        Get-WipeErrText 'ERR Wipe: Generic failure 0x80041001' | Should -Be 'Windows hat den Aufruf zum Zurücksetzen abgelehnt'
        Get-WipeErrText 'ERR verschieben: Access denied' | Should -Not -Match 'Access'
        Get-WipeErrText 'ERR Paket a.ppkg nicht entfernbar: x' | Should -Match 'Bereitstellungspaket'
        Get-WipeErrText 'Unsinn' | Should -Match 'Details im Log'
    }
    It 'Einbau: kein roher Graph-Text in Fail-Aufrufen, Fail-Reset zeigt nur Klartext' {
        $script:GoText | Should -Not -Match "Fail \([^\r\n]*\(Get-ErrText \`$_\)"
        $script:GoText | Should -Not -Match "Fail \([^\r\n]*\`$_\.Exception\.Message"
        @([regex]::Matches($script:GoText, 'Get-ErrScreen \$_ ')).Count | Should -BeGreaterOrEqual 5
        $fr = Get-GoFunctionText 'Fail-Reset'
        $fr | Should -Match "Log \('FEHLER Zurücksetzen: ' \+ \`$Msg \+"
        ($fr -split "`n" | Where-Object { $_ -match 'Banner|Get-EndText' }) -join "`n" | Should -Not -Match '\$Detail'
        $script:GoText | Should -Not -Match "Fail-Reset \(\s*'[^']*: ' \+ \`$_\.Exception"
    }
}

Describe 'go 2.8.0 B4: erst bereinigen, dann kuerzen; mehr Varianten' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-ReportSecrets', 'Protect-ReportText', 'Get-CutText', 'New-GoReport')))
        $script:ReportTitleMax = 200; $script:ReportLinesMax = 30; $script:ReportLineLen = 600; $script:ReportLogLen = 400
        $ReportTitleMax = 200; $ReportLinesMax = 30; $ReportLineLen = 600; $ReportLogLen = 400
        $Ver = '0.0.0'; $StepTotal = 6
        $script:Cfg = [pscustomobject]@{ Tenant = 'Testschule'; TenantId = '00000000-1111-2222-3333-444444444444'; ClientId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; ClientSecret = 'Ab+c/d=e"f\g~SecretZZ'; WlanKey = 'WlanGeheim99'; TeamsWebhook = 'https://hook.example.invalid/x?sig=abc'; GroupTag = 'T1' }
    }
    It 'Geheimnis an der Schnittstelle wird nicht angeschnitten (Log 400, Zeile 600)' {
        $sec = Get-ReportSecrets $script:Cfg ''
        $logLine = ('x' * 390) + 'WlanGeheim99' + ' Rest'
        $rep = New-GoReport -End @{ Was = (('y' * 590) + 'WlanGeheim99'); Jetzt = ''; Tun = '' } -SerialNo 'SN1' -Cfg $script:Cfg -LogTail @($logLine) -Secrets $sec
        ($rep.Log -join "`n") | Should -Not -Match 'WlanG'
        ($rep.Lines -join "`n") | Should -Not -Match 'WlanG'
    }
    It 'URL-kodierte und JSON-escaped Varianten werden ersetzt' {
        $sec = Get-ReportSecrets $script:Cfg ''
        $sec | Should -Contain ([uri]::EscapeDataString('Ab+c/d=e"f\g~SecretZZ'))
        $u = 'client_id=x&client_secret=' + [uri]::EscapeDataString('Ab+c/d=e"f\g~SecretZZ') + '&scope=y'
        (Protect-ReportText $u $sec) | Should -Not -Match 'SecretZZ'
        $j = '{"detail":"Wert ' + 'Ab+c\/d=e\"f\\g~SecretZZ' + ' abgelehnt"}'
        (Protect-ReportText $j $sec) | Should -Not -Match 'SecretZZ'
    }
    It 'Muster "client_secret": "..." wird auch ohne bekannten Wert maskiert' {
        $t = Protect-ReportText '{"client_id":"abc","client_secret": "UnbekanntQQ77","scope":"x"}' @()
        $t | Should -Not -Match 'UnbekanntQQ77'
        $t | Should -Match '"client_id":"abc"'
        $t | Should -Match '"scope":"x"'
        (Protect-ReportText '{\"client_secret\":\"EscQQ88\"}' @()) | Should -Not -Match 'EscQQ88'
        (Protect-ReportText '"password" : "Pw\"mit\"Anf"' @()) | Should -Not -Match 'Pw|mit|Anf'
    }
    It 'Gegenbeispiel: harmlose Texte bleiben' {
        (Protect-ReportText 'Gerät: Lenovo 82TS, Schritt 3 von 6' @()) | Should -Be 'Gerät: Lenovo 82TS, Schritt 3 von 6'
        (Protect-ReportText '{"status":"complete","deviceErrorCode":0}' @()) | Should -Be '{"status":"complete","deviceErrorCode":0}'
    }
}

Describe 'go 2.8.0 B7: Hardware-Aenderung, automatischer Abgleich' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Get-HwChangeText'))) }
    It 'automaticRemediationRequired: Warten empfohlen, N bleibt moeglich' {
        $h = Get-HwChangeText 'automaticRemediationRequired'
        $h.Auto | Should -BeTrue
        ($h.Lines -join "`n") | Should -Match 'gleicht die Änderung selbst ab'
        ($h.Lines -join "`n") | Should -Match '\[Enter\] abbrechen \(empfohlen\)'
        ($h.Lines -join "`n") | Should -Match '\[N\] trotzdem neu registrieren'
        ($h.Lines -join "`n") | Should -Not -Match 'neu registrieren \(empfohlen\)'
        $h.Tun | Should -Match 'einer Stunde'
        $h.Tun | Should -Match 'D:\\go'
        $h.Tun | Should -Match 'Admin'
    }
    It 'manualRemediationRequired: wie bisher, neu registrieren empfohlen' {
        $h = Get-HwChangeText 'manualRemediationRequired'
        $h.Auto | Should -BeFalse
        ($h.Lines -join "`n") | Should -Match '\[N\] neu registrieren \(empfohlen\)'
    }
    It 'Zuordnung als Annahme gekennzeichnet, Abbruch gelb ohne Bericht' {
        (Get-GoFunctionText 'Get-HwChangeText') | Should -Match 'ANNAHME'
        $script:GoText | Should -Match ([regex]::Escape('if ($hwc.Auto) { Stop-ByUser $hwc.Was -Tun $hwc.Tun }'))
    }
}

Describe 'go 2.8.0 B8: Merkdatei Edition sperrt hoechstens 24 Stunden' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Test-EdMarkOwner', 'Test-EdMarkBlocks'))) }
    It 'frisch, nicht aktiviert, eigenes Geraet: sperrt (Rueckfrage W)' {
        $now = [datetime]'2026-11-14 12:00:00'
        Test-EdMarkBlocks ([pscustomobject]@{ Seriennr = 'SN1'; Zeit = '2026-11-14 08:00:00'; Aktiviert = $false }) 'SN1' $now | Should -BeTrue
    }
    It 'aelter als 24 Stunden oder aktiviert: wieder die normale Frage J' {
        $now = [datetime]'2026-11-14 12:00:00'
        Test-EdMarkBlocks ([pscustomobject]@{ Seriennr = 'SN1'; Zeit = '2026-11-13 11:59:00'; Aktiviert = $false }) 'SN1' $now | Should -BeFalse
        Test-EdMarkBlocks ([pscustomobject]@{ Seriennr = 'SN1'; Zeit = '2026-11-14 08:00:00'; Aktiviert = $true }) 'SN1' $now | Should -BeFalse
    }
    It 'fremdes Geraet oder keine Datei: sperrt nicht; unlesbare Zeit: sperrt weiter (vorsichtig)' {
        $now = [datetime]'2026-11-14 12:00:00'
        Test-EdMarkBlocks ([pscustomobject]@{ Seriennr = 'SN2'; Zeit = '2026-11-14 08:00:00' }) 'SN1' $now | Should -BeFalse
        Test-EdMarkBlocks $null 'SN1' $now | Should -BeFalse
        Test-EdMarkBlocks ([pscustomobject]@{ Seriennr = 'SN1'; Zeit = 'kaputt' }) 'SN1' $now | Should -BeTrue
    }
    It 'Einbau: Frage W nur bei Sperre, hoechstens 2 Versuche bleiben' {
        $script:GoText | Should -Match ([regex]::Escape('if (Test-EdMarkBlocks $EdMark $Serial) {'))
        $script:GoText | Should -Match '\$edTry -lt 2'
    }
}

Describe 'go 2.8.0 B9: Akku nicht pruefbar wird nicht durchgewunken' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-PowerInfo')))
        $MinBattery = 50
    }
    It 'WMI-Fehler zweimal: nicht pruefbar, nicht Ok, genau ein zweiter Versuch' {
        Mock Get-CimInstance { throw 'WMI kaputt' }
        Mock Start-Sleep { }
        $p = Get-PowerInfo
        $p.Ok | Should -BeFalse
        $p.Unknown | Should -BeTrue
        $p.Text | Should -Match 'nicht prüfbar'
        Should -Invoke Get-CimInstance -Times 2 -Exactly
    }
    It 'Fehler einmal, dann Akku 80 % mit Netzteil: normal' {
        $script:n = 0
        Mock Get-CimInstance { $script:n++; if ($script:n -eq 1) { throw 'einmal' }; [pscustomobject]@{ BatteryStatus = 2; EstimatedChargeRemaining = 80 } }
        Mock Start-Sleep { }
        $p = Get-PowerInfo
        $p.Ok | Should -BeTrue
        $p.Unknown | Should -BeNullOrEmpty
    }
    It 'Standgeraet ohne Akku laeuft normal durch' {
        Mock Get-CimInstance { @() }
        $p = Get-PowerInfo
        $p.Ok | Should -BeTrue
        $p.Text | Should -Match 'kein Akku'
    }
    It 'zu wenig Akku ohne Netzteil: nicht Ok (wie bisher)' {
        Mock Get-CimInstance { [pscustomobject]@{ BatteryStatus = 1; EstimatedChargeRemaining = 20 } }
        (Get-PowerInfo).Ok | Should -BeFalse
    }
    It 'Einbau: eigenes Bild fuer nicht pruefbar, Rueckfrage J bleibt' {
        $w = Get-GoFunctionText 'Wait-Power'
        $w | Should -Match 'if \(\$p\.Unknown\)'
        $w | Should -Match 'nicht lesbar'
        $w | Should -Match "-eq 'J'"
    }
}

Describe 'go 2.8.0 U2, U3, U4: Texte' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Get-AdminHint', 'Get-ImportErrorText', 'Get-EndText'))) }
    It 'U2: Hinweis je nach dem, was mit dem Bericht wirklich passiert ist' {
        (Get-AdminHint @{ Sent = 'gesendet' }) | Should -Match 'hat schon eine Nachricht bekommen'
        (Get-AdminHint @{ Sent = 'gespeichert' }) | Should -Match 'sobald der Stick am PC im Setup steckt'
        (Get-AdminHint $null) | Should -Be ' Ohne Zugang zum Entra-Portal: den Admin fragen.'
        (Get-AdminHint @{ Sent = 'ungueltig' }) | Should -Be ' Ohne Zugang zum Entra-Portal: den Admin fragen.'
    }
    It 'U2: Bericht vor dem Bild, Feld Sent in allen Rueckgaben mit Text' {
        $so = Get-GoFunctionText 'Save-Offline'
        $so.IndexOf('Send-GoReport') | Should -BeLessThan $so.IndexOf('Banner ')
        $so | Should -Match ([regex]::Escape('$tun = $tun + (Get-AdminHint $rr)'))
        $sg = Get-GoFunctionText 'Send-GoReport'
        @([regex]::Matches($sg, 'return @\{ Text = ')).Count | Should -Be @([regex]::Matches($sg, "Sent = '")).Count
    }
    It 'U3: 808 nennt auch den alten Eintrag im eigenen Intune (Microsoft Learn)' {
        $r = Get-ImportErrorText '808' 'ZtdDeviceAssignedToOtherTenant'
        $r.Was | Should -Match 'anderen Organisation'
        $r.Was | Should -Match 'alten Eintrag im eigenen Intune'
        $r.Tun | Should -Match 'alten Eintrag im eigenen Intune'
        $r.Tun | Should -Match 'Händler oder Vorbesitzer'
        (Get-GoFunctionText 'Get-ImportErrorText') | Should -Match 'import-windows-autopilot-device-csv-files-errors'
    }
    It 'U4: erst zum naechsten Geraet, wenn es neu startet' {
        $e = Get-EndText 'ResetStart'
        $e.Tun | Should -Match 'wenn es neu startet \(etwa 5 Minuten\)'
        $e.Tun | Should -Not -Match 'und zum nächsten Gerät\.$'
    }
}

Describe 'go 2.8.0 B12 und Nebenbefunde' {
    It 'B12: Kommentar zum Arbeitsverzeichnis nennt nur Daten, keine Seriennummern' {
        $l = @($script:GoText -split "`r?`n" | Where-Object { $_ -match 'Der Verzeichnisname ist ungueltig' })
        $l.Count | Should -Be 1
        $l[0] | Should -Match '\(19\.10\.2026; vermutlich auch 13\.10\.2026'
        $l[0] | Should -Not -Match '[A-Z0-9]{8} \d\d\.\d\d\.\d{4}'
    }
    It 'B12: Beispieladresse example.org statt Schuldomain' {
        $script:GoText | Should -Match 'name@example\.org'
        $script:GoText | Should -Not -Match '@schule\.'
        $script:DiagText | Should -Not -Match '@schule\.'
    }
    It 'version.json wird mit -Encoding gelesen (go und diag)' {
        $script:GoText | Should -Match "'Config\\version\.json'\) -Raw -Encoding UTF8"
        $script:DiagText | Should -Match "'Config\\version\.json'\) -Raw -Encoding UTF8"
    }
    It 'SYSTEM-Script: UTF-8 mit BOM statt ASCII (Umlaute in Paket- und App-Namen bleiben)' {
        $s = $script:GoText.IndexOf("`$wipe = @'"); $e = $script:GoText.IndexOf("'@", $s + 10)
        $w = $script:GoText.Substring($s, $e - $s)
        $w | Should -Not -Match 'Encoding ASCII'
        $script:GoText | Should -Match ([regex]::Escape('[System.IO.File]::WriteAllText($WipePs1, $wipeText, (New-Object System.Text.UTF8Encoding $true))'))
        $script:GoText | Should -Not -Match 'Set-Content -Path \$WipePs1'
    }
    It 'UTF-8 mit BOM: Name mit Umlaut kommt in PowerShell 5.1 unveraendert an, ASCII-Inhalt bleibt gleich' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ('hup280_' + [guid]::NewGuid().ToString('N') + '.ps1')
        $o = Join-Path ([IO.Path]::GetTempPath()) ('hup280_' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            $name = 'WLAN-' + [char]0xC4 + [char]0xF6 + [char]0xFC + [char]0xDF + '.ppkg'
            [IO.File]::WriteAllText($f, ("`$k = '" + $name + "'`r`n[IO.File]::WriteAllText('" + $o + "', `$k, (New-Object System.Text.UTF8Encoding `$false))"), (New-Object System.Text.UTF8Encoding $true))
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f
            [IO.File]::ReadAllText($o, [Text.Encoding]::UTF8) | Should -BeExactly $name
            $b = [IO.File]::ReadAllBytes($f)
            ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
        } finally { Remove-Item -LiteralPath $f, $o -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'diag 2.8.0 B11: bereinigt, kein Host, Menue ohne zusaetzliches Enter' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionText $script:DiagPath 'Get-DiagSecrets', 'Protect-DiagText')))
        $script:Cfg = [pscustomobject]@{ TenantId = '00000000-1111-2222-3333-444444444444'; ClientId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; ClientSecret = 'Diag+Secret/1='; TeamsWebhook = 'https://abc123.example.invalid/workflows/x?sig=zz'; WlanKey = 'WlanDiag77' }
    }
    It 'Tenant-ID, App-ID, Secret, Host, UPN und JWT verschwinden aus dem Log' {
        $sec = Get-DiagSecrets $script:Cfg
        $log = @(
            "AADSTS700016: Application with identifier 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' was not found in the directory '00000000-1111-2222-3333-444444444444'.",
            "Der Remotename konnte nicht aufgelöst werden: 'abc123.example.invalid'",
            'Benutzer zuweisen: lehrer.test@example.org',
            'Tenant 00000000111122223333444444444444 im Host',
            'client_secret=' + [uri]::EscapeDataString('Diag+Secret/1='),
            'Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc'
        ) -join "`n"
        $t = Protect-DiagText $log $sec
        $t | Should -Not -Match 'aaaaaaaa-bbbb'
        $t | Should -Not -Match '00000000-1111'
        $t | Should -Not -Match '0000000011112222'
        $t | Should -Not -Match 'abc123'
        $t | Should -Not -Match 'lehrer\.test'
        $t | Should -Match '\*\*\*@example\.org'
        $t | Should -Not -Match 'Diag'
        $t | Should -Not -Match 'eyJhbGci'
    }
    It 'Gegenbeispiel: normale Zeilen bleiben' {
        (Protect-DiagText '2026-11-14 10:00:00  Schritt 2 von 6: Internet' @()) | Should -Be '2026-11-14 10:00:00  Schritt 2 von 6: Internet'
    }
    It 'Einbau: Datei am Stick und Anzeige bereinigt, Host nicht angezeigt' {
        $script:DiagText | Should -Match ([regex]::Escape('-split "`r?`n" | ForEach-Object { Protect-DiagText $_ $script:DiagSecrets $script:DiagNoCfg })'))
        $script:DiagText.IndexOf('ForEach-Object { Protect-DiagText $_ $script:DiagSecrets') | Should -BeLessThan $script:DiagText.IndexOf('Set-Content -Path $f -Value $out')
        $script:DiagText | Should -Match ([regex]::Escape('$t = Protect-DiagText $x $script:DiagSecrets $script:DiagNoCfg'))
        $script:DiagText | Should -Not -Match 'Write-Host[^\r\n]*\$x\.Host'
        $script:DiagText | Should -Match 'Bericht an den Admin: eingetragen, erreichbar'
        $script:DiagText | Should -Match 'Bericht an den Admin: eingetragen, nicht erreichbar'
    }
    It 'Menue: ungueltige Auswahl ohne zusaetzliches Enter' {
        $script:DiagText | Should -Not -Match 'Start-Sleep -Seconds 2; continue \}'
        $script:DiagText | Should -Match 'if \(-not \$back\) \{ continue \}'
        $script:DiagText.IndexOf('if (-not $back) { continue }') | Should -BeLessThan $script:DiagText.IndexOf("Read-Host '  Enter = zurück zum Menü'")
    }
    It 'diag.ps1 parst fehlerfrei' {
        $tk = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:DiagPath, [ref]$tk, [ref]$er)
        @($er).Count | Should -Be 0
    }
}

# ---------- Zweite Runde (Pruefung der Korrekturen) ----------

Describe 'go 2.8.0 M1: Ergebnisdatei nur mit der Kennung dieses Laufs' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Get-WipeResult', 'Get-WipeOutcome', 'Get-WipeChanges', 'Get-WipeErrText'))) }
    It 'eigene Kennung: Ergebnis zaehlt' {
        Get-WipeResult 'LAUF abc123 OK 0' 'abc123' | Should -Be 'OK 0'
        Get-WipeResult "LAUF abc123 ERR Wipe: x`r`n" 'abc123' | Should -Be 'ERR Wipe: x'
    }
    It 'altes ERR oder altes OK 0 ohne Kennung, fremde Kennung, halbe Zeile: noch keine Rueckmeldung' {
        Get-WipeResult 'ERR verschieben: alt' 'abc123' | Should -Be ''
        Get-WipeResult 'OK 0' 'abc123' | Should -Be ''
        Get-WipeResult 'LAUF alt999 OK 0' 'abc123' | Should -Be ''
        Get-WipeResult 'LAUF abc1234 OK 0' 'abc123' | Should -Be ''
        Get-WipeResult 'LAUF abc123' 'abc123' | Should -Be ''
        Get-WipeResult '' 'abc123' | Should -Be ''
        Get-WipeResult 'LAUF abc123 OK 0' '' | Should -Be ''
    }
    It 'altes ERR fuehrt so nie zu "nicht zurueckgesetzt", solange die Aufgabe nicht nachweislich steht' {
        $res = Get-WipeResult 'ERR verschieben: alt' 'abc123'
        (Get-WipeOutcome $res @('[abc123]  LAUF abc123 Start') $false).Kind | Should -Be 'Unklar'
    }
    It 'altes OK 0 ergibt nie "angenommen"' {
        $res = Get-WipeResult 'OK 0' 'abc123'
        (Get-WipeOutcome $res @('[abc123]  LAUF abc123 Start') $true).Kind | Should -Not -Be 'Ok'
    }
    It 'Fehlerzeile ohne Aufruf: Fehler nur, wenn die Aufgabe nicht mehr laeuft' {
        $l = @('[abc123]  LAUF abc123 Start', '[abc123]  FEHLER verschieben: x')
        (Get-WipeOutcome 'ERR verschieben: x' $l $true).Kind | Should -Be 'Fehler'
        $o = Get-WipeOutcome 'ERR verschieben: x' $l $false
        $o.Kind | Should -Be 'Unklar'
        $o.Why | Should -Match 'läuft aber noch oder ließ sich nicht stoppen'
    }
    It 'Einbau: Kennung im Ergebnis des SYSTEM-Scripts, altes Ergebnis mit Kontrolle geloescht, Stoppen vor Fail-Reset' {
        $script:GoText | Should -Match ([regex]::Escape("Set-Content -Path `$res -Value ('LAUF __RUNID__ ' + `$v)"))
        @([regex]::Matches($script:GoText, 'Set-Content -Path \$res')).Count | Should -Be 1
        @([regex]::Matches($script:GoText, 'Write-WipeRes \(')).Count | Should -Be 6
        $script:GoText | Should -Not -Match 'function R\('
        $script:GoText | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $WipeResult -Force -ErrorAction Stop'))
        $script:GoText | Should -Not -Match 'Remove-Item -Path \$WipeResult -Force -ErrorAction SilentlyContinue'
        $script:GoTail | Should -Match ([regex]::Escape('$res = Get-WipeResult $raw $WipeRun'))
        $i = $script:GoTail.IndexOf("if (`$wo.Kind -eq 'Fehler' -and `$res) {")
        $i | Should -BeGreaterThan 0
        $script:GoTail.IndexOf("Stop-WipeTask `$tn 'Fehler gemeldet'", $i) | Should -BeLessThan $script:GoTail.IndexOf("if (`$wo.Kind -eq 'Fehler') { Fail-Reset", $i)
    }
    It 'Hinweis: r ist ein Alias (Invoke-History), darum heisst die Funktion Write-WipeRes' {
        (Get-Alias -Name r -ErrorAction SilentlyContinue).Definition | Should -Be 'Invoke-History'
    }
}

Describe 'go 2.8.0 G1: Kennung in jeder Zeile des SYSTEM-Scripts' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Get-WipeRunLines', 'Get-WipeOutcome', 'Get-WipeChanges', 'Get-WipeErrText'))) }
    It 'fehlt nur die Startzeile, zaehlen WIPE-AUFRUF und Aenderungen trotzdem' {
        $l = @('10:01  [neu222]  verschoben: C:\Recovery\OEM\x', '10:02  [neu222]  WIPE-AUFRUF doWipePersistProvisionedDataMethod')
        $r = @(Get-WipeRunLines $l 'neu222')
        $r.Count | Should -Be 2
        $o = Get-WipeOutcome '' $r $true
        $o.Called | Should -BeTrue
        $o.Kind | Should -Be 'Unklar'
    }
    It 'ERR Wipe und kein Log dieses Laufs: unklar (vor oder nach dem Aufruf)' {
        (Get-WipeOutcome 'ERR Wipe: x' @() $true).Kind | Should -Be 'Unklar'
    }
    It 'Einbau: L schreibt die Kennung in jede Zeile' {
        $script:GoText | Should -Match ([regex]::Escape("(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  [__RUNID__]  ' + `$m"))
    }
}

Describe 'go 2.8.0 G8: Zustand der Aufgabe ist massgeblich' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Stop-WipeTask', 'Invoke-SchtasksEnd')))
        function Log([string]$Msg) { $script:LogLines += $Msg }
    }
    BeforeEach { $script:LogLines = @(); Mock Start-Sleep { } }
    It 'beide Befehle scheitern, Zustand Ready: gestoppt' {
        Mock Stop-ScheduledTask { throw 'Die Aufgabe wird nicht ausgefuehrt' }
        Mock Invoke-SchtasksEnd { @{ Ok = $false; Out = 'FEHLER'; Code = 1 } }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Stop-WipeTask 'HUPilot-Wipe' 'Test' | Should -BeTrue
    }
    It 'Stoppen meldet Erfolg, Zustand Running oder Queued: nicht gestoppt' {
        Mock Stop-ScheduledTask { }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Running' } }
        Stop-WipeTask 'HUPilot-Wipe' 'Test' | Should -BeFalse
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Queued' } }
        Stop-WipeTask 'HUPilot-Wipe' 'Test' | Should -BeFalse
        ($script:LogLines -join "`n") | Should -Match 'ließ sich nicht stoppen'
    }
    It 'Zustand nicht lesbar: Ergebnis der Befehle zaehlt' {
        Mock Get-ScheduledTask { throw 'nicht lesbar' }
        Mock Stop-ScheduledTask { }
        Stop-WipeTask 'HUPilot-Wipe' 'Test' | Should -BeTrue
        Mock Stop-ScheduledTask { throw 'x' }
        Mock Invoke-SchtasksEnd { @{ Ok = $false; Out = ''; Code = 1 } }
        Stop-WipeTask 'HUPilot-Wipe' 'Test' | Should -BeFalse
        Mock Invoke-SchtasksEnd { @{ Ok = $true; Out = 'OK'; Code = 0 } }
        Stop-WipeTask 'HUPilot-Wipe' 'Test' | Should -BeTrue
    }
}

Describe 'go 2.8.0 M2: nie die Meldung von ConvertFrom-Json einer config.json weitergeben' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Get-JsonErrPos'))) }
    It 'nur die Position, kein Inhalt (Meldung dieser PowerShell, unter 5.1 mit dem ganzen JSON-Text)' {
        $msg = ''
        try { '{"ClientSecret": "GEHEIM-Wert-123", "WlanKey": "WlanX99" ' | ConvertFrom-Json -ErrorAction Stop } catch { $msg = $_.Exception.Message }
        $msg | Should -Not -BeNullOrEmpty
        if ($PSVersionTable.PSVersion.Major -le 5) { $msg | Should -Match 'GEHEIM-Wert-123' }   # belegt das Problem unter 5.1
        $pos = Get-JsonErrPos $msg
        $pos | Should -Match '^(Zeile \d+, )?Zeichen \d+$'
        $pos | Should -Not -Match 'GEHEIM|WlanX'
    }
    It 'Formen von 5.1 und 7, sonst leer' {
        Get-JsonErrPos 'Ein ungültiges Objekt wurde übergeben. Erwartet wurde ":" oder "}". (49): {"a": "geheim"' | Should -Be 'Zeichen 49'
        Get-JsonErrPos "Unexpected end when deserializing object. Path 'WlanKey', line 1, position 49." | Should -Be 'Zeile 1, Zeichen 49'
        Get-JsonErrPos 'irgendwas' | Should -Be ''
    }
    It 'Einbau go: Meldung wird weder geloggt noch angezeigt, Merkdatei ebenso' {
        $l = @($script:GoText -split "`r?`n" | Where-Object { $_ -match "\`$cfg = \`$cfgRaw \| ConvertFrom-Json" })
        $l.Count | Should -Be 1
        $l[0] | Should -Match 'Get-JsonErrPos \$_\.Exception\.Message'
        $l[0] | Should -Not -Match "Log \([^)]*\`$_\.Exception\.Message"
        $l[0] | Should -Not -Match "Fail \([^\r\n]*\`$_\.Exception\.Message"
        $script:GoText | Should -Not -Match "config\.json lesen: ' \+ \`$_\.Exception\.Message"
        $m = @($script:GoText -split "`r?`n" | Where-Object { $_ -match "Merkdatei Edition nicht lesbar" })
        ($m -join "`n") | Should -Not -Match 'Exception'
    }
    It 'Einbau diag: config nur ohne Meldung gelesen, Rueckfall auf den Rohtext' {
        $script:DiagText | Should -Match ([regex]::Escape('elseif ($cfgRaw) { try { $script:DiagSecrets = @(Get-DiagSecrets $null $cfgRaw) } catch { } }'))
    }
}

Describe 'diag 2.8.0 M2: Rueckfall bei kaputter config.json' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionText $script:DiagPath 'Get-DiagRawValues', 'Get-DiagSecrets', 'Protect-DiagText'))) }
    It 'Werte aus dem Rohtext, auch ohne Doppelpunkt oder Anfuehrungszeichen' {
        $raw = "{`n  `"TenantId`": `"11111111-2222-3333-4444-555555555555`",`n  `"ClientId`" `"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee`",`n  ClientSecret: Roh+Geheim/77,`n  `"WlanKey`": `"Wlan Kennwort 1`"`n  `"TeamsWebhook`": `"https://h0st.example.invalid/x?sig=q`""
        $v = Get-DiagRawValues $raw
        $v['TenantId'] | Should -Be '11111111-2222-3333-4444-555555555555'
        $v['ClientId'] | Should -Be 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $v['ClientSecret'] | Should -Be 'Roh+Geheim/77'
        $v['WlanKey'] | Should -Be 'Wlan Kennwort 1'
        $sec = Get-DiagSecrets $null $raw
        $t = Protect-DiagText ("Fehler mit Roh+Geheim/77 und Wlan Kennwort 1 bei h0st.example.invalid, Tenant 11111111222233334444555555555555") $sec $true
        $t | Should -Not -Match 'Roh\+Geheim|Wlan Kennwort|h0st|1111111122'
    }
    It 'config nicht lesbar: GUIDs und 32-stellige Hex-Werte werden maskiert, sonst nicht' {
        $line = "App 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' im Verzeichnis 0123456789abcdef0123456789abcdef"
        (Protect-DiagText $line @() $true) | Should -Be "App '***' im Verzeichnis ***"
        (Protect-DiagText $line @() $false) | Should -Be $line
    }
}

Describe 'go und diag 2.8.0 G3: grob kappen vor der Bereinigung, nie ein Teilstueck' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Protect-ReportText', 'Get-CutText', 'New-GoReport')))
        . ([scriptblock]::Create((Get-FunctionText $script:DiagPath 'Protect-DiagText')))
        $ReportTitleMax = 200; $ReportLinesMax = 30; $ReportLineLen = 600; $ReportLogLen = 400; $Ver = '0.0.0'; $StepTotal = 6
    }
    It 'Geheimnis ohne Leerzeichen an der Grenze 4000: kein Teilstueck' {
        foreach ($f in 'Protect-ReportText', 'Protect-DiagText') {
            $t = & $f ((' x' * 1997) + 'GrenzGeheimnisABC123' + ' danach') @('GrenzGeheimnisABC123')
            $t | Should -Not -Match 'Grenz' -Because $f
            $t | Should -Match ' \.\.\.$' -Because $f
        }
    }
    It 'Geheimnis mit Leerzeichen an der Grenze: auch der Anfang faellt weg' {
        $sec = @('mein langes geheimes Wort')
        foreach ($f in 'Protect-ReportText', 'Protect-DiagText') {
            $t = & $f (('y' * 3990) + ' mein langes geheimes Wort und mehr') $sec
            $t | Should -Not -Match 'mein|langes' -Because $f
        }
    }
    It 'kurze Zeilen bleiben unveraendert, das Log kappt nicht (-Cap 0)' {
        Protect-ReportText 'kurz' @() | Should -Be 'kurz'
        (Protect-ReportText ('z ' * 3000) @() -Cap 0).Length | Should -Be 6000
    }
    It 'sehr lange Zeilen sind schnell (30000 Zeichen ohne Leerzeichen)' {
        $long = 'a' * 30000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void](Protect-DiagText $long @('geheim1') $true)
        [void](Protect-ReportText $long @('geheim1'))
        [void](New-GoReport -End @{ Was = $long } -SerialNo 'S' -LogTail @($long, $long) -Secrets @('geheim1'))
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3
    }
    It 'E-Mail-Muster in diag ohne Kappen linear (Lookbehind)' {
        $rx = [regex]::Match($script:DiagText, "\[regex\]::Replace\(\`$t, '(\(\?<!\[A-Za-z0-9\._%\+-\]\)[^']+)'").Groups[1].Value
        $rx | Should -Not -BeNullOrEmpty
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void][regex]::Replace(('b' * 30000), $rx, 'x')
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 1
    }
}

Describe 'go 2.8.0 G4: hashes.csv mit Umlauten' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Read-TextAuto', 'Save-HashRow')))
        $script:Hdr = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
    }
    BeforeEach { $script:F = Join-Path ([IO.Path]::GetTempPath()) ('hup280_' + [guid]::NewGuid().ToString('N') + '.csv') }
    AfterEach { Remove-Item -LiteralPath $script:F -Force -ErrorAction SilentlyContinue }
    It 'UPN mit Umlaut bleibt erhalten, auch in der ANSI-Zeile eines anderen Geraets' {
        $ue = [string][char]0xFC
        $ansi = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        [IO.File]::WriteAllText($script:F, ($script:Hdr + "`r`nSN-ALT,,HASHALT,T1,m" + $ue + "ller@example.org`r`n"), $ansi)
        Save-HashRow $script:F $script:Hdr 'SN-NEU' ('SN-NEU,,HASHNEU,T1,j' + $ue + 'rgen@example.org')
        $t = [IO.File]::ReadAllText($script:F, (New-Object Text.UTF8Encoding($false, $true)))
        $t | Should -Match ('SN-ALT,,HASHALT,T1,m' + $ue + 'ller@example\.org')
        $t | Should -Match ('SN-NEU,,HASHNEU,T1,j' + $ue + 'rgen@example\.org')
        $b = [IO.File]::ReadAllBytes($script:F); ($b[0] -eq 0xEF) | Should -BeFalse   # ohne BOM
    }
    It 'gleiche Seriennummer wird ersetzt, UTF-8 mit BOM wird gelesen' {
        [IO.File]::WriteAllText($script:F, ($script:Hdr + "`r`nSN1,,ALT,T1,`r`nSN2,,X,T1,`r`n"), (New-Object Text.UTF8Encoding $true))
        Save-HashRow $script:F $script:Hdr 'SN1' 'SN1,,NEU,T2,'
        $l = @([IO.File]::ReadAllLines($script:F))
        $l | Should -Be @($script:Hdr, 'SN2,,X,T1,', 'SN1,,NEU,T2,')
    }
    It 'reines ASCII: Byte fuer Byte wie bisher (Set-Content -Encoding ASCII)' {
        Save-HashRow $script:F $script:Hdr 'SN1' 'SN1,,HASH,T1,a@example.org'
        $ref = Join-Path ([IO.Path]::GetTempPath()) ('hup280_ref_' + [guid]::NewGuid().ToString('N') + '.csv')
        try {
            Set-Content -Path $ref -Value @($script:Hdr, 'SN1,,HASH,T1,a@example.org') -Encoding ASCII
            [IO.File]::ReadAllBytes($script:F) | Should -Be ([IO.File]::ReadAllBytes($ref))
        } finally { Remove-Item -LiteralPath $ref -Force -ErrorAction SilentlyContinue }
    }
    It 'Einbau: Save-Offline nutzt Save-HashRow, protokoll.csv als UTF-8 ohne BOM' {
        (Get-GoFunctionText 'Save-Offline') | Should -Match 'Save-HashRow \$f \$OfflineHdr \$Serial'
        (Get-GoFunctionText 'Save-Offline') | Should -Not -Match 'Encoding ASCII'
        $pk = Get-GoFunctionText 'Protokoll'
        $pk | Should -Match 'UTF8Encoding \$false'
        $pk | Should -Not -Match 'Encoding ASCII'
    }
}

Describe 'go 2.8.0 G5 und Log an der Quelle' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Log', 'Protect-ReportText', 'Get-ReportSecrets'))) }
    It 'G5: Bild sagt, dass das Geraet wartet, mit Logzeile beim Wechsel' {
        $w = Get-GoFunctionText 'Wait-Power'
        $w | Should -Match 'GERÄT WARTET'
        $w | Should -Match 'macht erst weiter, wenn J gedrückt ist'
        $w | Should -Match "Log 'Akku nicht prüfbar - Gerät wartet auf Netzteil und J'"
        $w | Should -Match "Log 'Akku jetzt nicht prüfbar"
    }
    It 'Log ersetzt bekannte Geheimnisse, sobald die config geladen ist, und laesst den Rest lesbar' {
        $LocalLog = Join-Path ([IO.Path]::GetTempPath()) ('hup280_log_' + [guid]::NewGuid().ToString('N') + '.log')
        $StickLog = $null
        function Get-Mono { 1 }
        try {
            $script:LogSecrets = @()
            Log 'vorher ohne config: AppGeheim42'
            $script:LogSecrets = @(Get-ReportSecrets ([pscustomobject]@{ ClientSecret = 'AppGeheim42'; ClientId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }) '')
            Log "AADSTS7000215: Invalid client secret provided for app 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' (AppGeheim42)"
            $t = [IO.File]::ReadAllText($LocalLog)
            $t | Should -Match 'vorher ohne config: AppGeheim42'
            $t | Should -Match "AADSTS7000215: Invalid client secret provided for app '\*\*\*' \(\*\*\*\)"
        } finally { $script:LogSecrets = @(); Remove-Item -LiteralPath $LocalLog -Force -ErrorAction SilentlyContinue }
    }
    It 'Einbau: Geheimnisse fuer das Log direkt nach dem Laden der config' {
        $script:GoText | Should -Match ([regex]::Escape("try { `$script:LogSecrets = @(Get-ReportSecrets `$cfg '') } catch { }"))
        (Get-GoFunctionText 'Log') | Should -Match 'Protect-ReportText \$Msg \$script:LogSecrets -Cap 0'
    }
}
