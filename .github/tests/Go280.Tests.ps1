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
    It 'Einbau: Stoppen wird geprueft (Exitcode von schtasks /End, Zustand Running)' {
        $script:GoTail | Should -Match '\$stopOk = \(\$LASTEXITCODE -eq 0\)'
        $script:GoTail | Should -Match "State -eq 'Running'"
        $script:GoTail | Should -Match 'Get-WipeOutcome \$res \$wipeLines \$stopOk'
    }
}

Describe 'go 2.8.0 B3: nur das Wipe-Log dieses Laufs zaehlt' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-WipeRunLines', 'Get-WipeOutcome', 'Get-WipeChanges', 'Get-WipeErrText')))
    }
    It 'ein alter Lauf mit WIPE-AUFRUF zaehlt nicht' {
        $l = @('09:00  LAUF alt111 Start als SYSTEM', '09:01  verschoben: C:\Recovery\OEM\x', '09:02  WIPE-AUFRUF doWipePersistProvisionedDataMethod', '10:00  LAUF neu222 Start als SYSTEM', '10:01  Paket bleibt: a.ppkg')
        $r = @(Get-WipeRunLines $l 'neu222')
        $r.Count | Should -Be 2
        ($r -join "`n") | Should -Not -Match 'WIPE-AUFRUF'
        (Get-WipeOutcome '' $r $true).Kind | Should -Be 'Fehler'
        @((Get-WipeOutcome '' $r $true).Changes).Count | Should -Be 0
    }
    It 'ohne Marke dieses Laufs: nichts' {
        @(Get-WipeRunLines @('09:00  LAUF alt111 Start', '09:02  WIPE-AUFRUF') 'neu222').Count | Should -Be 0
        @(Get-WipeRunLines @('x') '').Count | Should -Be 0
        @(Get-WipeRunLines @() 'neu222').Count | Should -Be 0
    }
    It 'Kennung als ganzes Wort (neu22 trifft nicht neu222)' {
        @(Get-WipeRunLines @('LAUF neu222 Start', 'WIPE-AUFRUF') 'neu22').Count | Should -Be 0
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
        $script:DiagText | Should -Match ([regex]::Escape('$out = @($out | ForEach-Object { Protect-DiagText ([string]$_) $script:DiagSecrets })'))
        $script:DiagText.IndexOf('Protect-DiagText ([string]$_)') | Should -BeLessThan $script:DiagText.IndexOf('Set-Content -Path $f -Value $out')
        $script:DiagText | Should -Match ([regex]::Escape('$t = Protect-DiagText $x $script:DiagSecrets'))
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
