#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer HUPilot-Setup.ps1, Korrekturen vor Stable 2.8.0: Daten am Stick vor dem Formatieren,
# grosse Datentraeger, Bereinigung (Varianten, Muster, Startprotokoll), Kodierung von hashes.csv, Fenster
# "Hashes importieren", Secret-Fuehrung, Ampel im Hauptknopf.
# Das Setup wird dabei NICHT gestartet, Graph wird nie aufgerufen, nichts wird formatiert (nur kuenstliche Daten).

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:SetupPath = Join-Path $script:Root 'Stick\HUPilot\Setup\HUPilot-Setup.ps1'
    $script:SetupText = Get-Content -LiteralPath $script:SetupPath -Raw -Encoding UTF8
    $tk = $null; $er = $null
    $script:SetupAst = [System.Management.Automation.Language.Parser]::ParseFile($script:SetupPath, [ref]$tk, [ref]$er)
    $script:ParseErrors = @($er)
    $script:FnByName = @{}
    foreach ($f in @($script:SetupAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) { $script:FnByName[$f.Name] = $f.Extent.Text }
    $want = @('Limit-MaskInput', 'Complete-MaskInput', 'Repair-HashTmp', 'Hide-SecretPatterns', 'Get-SecretVariants', 'Hide-LogSecrets', 'Limit-TeamsText', 'Protect-TeamsText', 'Test-PrepBigDisk', 'Get-CsvDataLines',
        'Get-StickDataWarnings', 'Read-HashText', 'Write-HashText', 'Move-HashDone', 'Read-HashCsv', 'Get-ImportErrorText', 'Get-HashRowLogText', 'Get-SecretBanner')
    . ([scriptblock]::Create((@($want | ForEach-Object { $script:FnByName[$_] }) -join "`n")))
    . ([scriptblock]::Create([regex]::Match($script:SetupText, '(?m)^\$script:PrepBigDiskGB = .*$').Value))
    $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hu280_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Hdr = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
    # Body einer Funktion ab einer Marke (fuer Reihenfolge-Pruefungen)
    function Get-FnText([string]$Name) { return [string]$script:FnByName[$Name] }
}
AfterAll { try { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Describe '2.8.0: Datei vollstaendig' {
    It 'Setup parst ohne Fehler und endet sauber' {
        $script:ParseErrors | Should -BeNullOrEmpty
        $script:SetupText.TrimEnd() | Should -Match '\}$'
    }
}

Describe '2.8.0 B4: Bereinigung mit Schreibweisen und Mustern' {
    It 'blendet den Wert woertlich, URL-kodiert (gross und klein), mit + und JSON-escaped aus' {
        $s = 'Ab+c/d~e=f&g"h\i'
        $u = [uri]::EscapeDataString($s)
        foreach ($form in @($s, $u, [regex]::Replace($u, '%[0-9A-F]{2}', { param($m) $m.Value.ToLowerInvariant() }),
                ($s.Replace('\', '\\').Replace('"', '\"')), ($s.Replace('\', '\\').Replace('"', '\"').Replace('/', '\/')),
                ($s.Replace('\', '\\').Replace('"', '\"').Replace('&', ('\' + 'u0026'))))) {
            $o = Hide-LogSecrets ('vorher ' + $form + ' nachher') @($s)
            $o | Should -Be 'vorher *** nachher'
        }
    }
    It 'Leerzeichen als + (Formular) wird erkannt' {
        Hide-LogSecrets 'client_id=x&secret=geheim+wert+1' @('geheim wert 1') | Should -Be 'client_id=x&secret=***'
    }
    It 'Muster ohne bekannten Wert: client_secret in JSON und Formular, Bearer, JWT, sig=' {
        Hide-LogSecrets '{"client_secret": "abc\"def", "x": 1}' @() | Should -Be '{"client_secret": "***", "x": 1}'
        Hide-LogSecrets 'grant_type=client_credentials&client_secret=Zz9~kk.QQ&scope=x' @() | Should -Be 'grant_type=client_credentials&client_secret=***&scope=x'
        Hide-LogSecrets 'Authorization: Bearer abcdefgh12345678' @() | Should -Be 'Authorization: Bearer ***'
        Hide-LogSecrets ('Token eyJ' + ('a' * 12) + '.' + ('b' * 12) + '.ccc Ende') @() | Should -Be 'Token *** Ende'
        Hide-LogSecrets ('an https://' + 'x.invalid/a?b=1&sig=' + ('A' * 20) + ' Ende') @() | Should -Be 'an (Webhook) Ende'
        Hide-LogSecrets '{"access_token":"xyz123456"}' @() | Should -Be '{"access_token":"***"}'
    }
    It 'Gegenbeispiele bleiben unveraendert' {
        foreach ($t in 'Das Wort client_secret allein', 'Bearer kurz', 'Secret abgelaufen am 13.11.2026', '{"client_id":"55555555-6666-7777-8888-999999999999"}', 'eyJ ist kein Token', 'https://example.invalid/pfad?x=1') {
            Hide-LogSecrets $t @('abc') | Should -Be $t
        }
        Hide-LogSecrets 'ab ab' @('ab') | Should -Be 'ab ab'
    }
    It 'Get-SecretVariants: leer ergibt nichts, Varianten ohne Doppel' {
        @(Get-SecretVariants '') | Should -HaveCount 0
        $v = @(Get-SecretVariants 'abcd'); $v | Should -HaveCount 1; $v[0] | Should -Be 'abcd'
        @(Get-SecretVariants 'a/b c') | Should -Contain 'a%2Fb%20c'
        @(Get-SecretVariants 'a/b c') | Should -Contain 'a%2Fb+c'
    }
    It 'erst maskieren, dann kuerzen: ein Secret an der Kuerzungsgrenze bleibt auch als Anfang unsichtbar' {
        $sec = 'GEHEIMgeheim12345678'
        $line = ('x' * 590) + $sec + ' Rest'
        $p = Protect-TeamsText $line @($sec) @()
        $c = Limit-TeamsText $p 600
        $c | Should -Not -Match 'GEHEIM'
        # Gegenprobe: in umgekehrter Reihenfolge waere ein Teil sichtbar
        (Limit-TeamsText $line 600) | Should -Match 'GEHEIMgeh'
    }
    It 'Karten werden immer erst bereinigt, dann von New-TeamsCard gekuerzt (Send-OutboxCore, An Admin senden)' {
        Get-FnText 'Send-OutboxCore' | Should -Match 'New-TeamsCard \$title @\(\$o\.lines \| ForEach-Object \{ & \$pt \$_ \}\)'
        Get-FnText 'Send-LogItemToAdmin' | Should -Match 'Protect-TeamsText \$_ \$ps\.S \$ps\.I'
        Get-FnText 'New-TeamsCard' | Should -Match 'Limit-TeamsText'
    }
}

Describe '2.8.0 B15: Startprotokoll und Fehlerdatei ohne Geheimes' {
    It 'Start-Log bereinigt jede Zeile mit den Mustern' {
        Get-FnText 'Start-Log' | Should -Match 'Hide-SecretPatterns \$m'
    }
    It 'Hide-SecretPatterns steht vor Start-Log und vor dem trap (gilt schon beim Start)' {
        $a = $script:SetupText.IndexOf('function Hide-SecretPatterns'); $b = $script:SetupText.IndexOf('function Start-Log'); $c = $script:SetupText.IndexOf('trap {')
        $a | Should -BeGreaterThan 0; $a | Should -BeLessThan $b; $b | Should -BeLessThan $c
    }
    It 'trap bereinigt die Fehlermeldung vor dem Schreiben (bekannte Werte, sonst Muster)' {
        $m = [regex]::Match($script:SetupText, '(?s)trap \{(.*?)\r?\n\}').Groups[1].Value
        $m | Should -Match 'Hide-LogSecrets \$msg \$hv'
        $m | Should -Match 'Hide-SecretPatterns \$msg'
        $m.IndexOf('Hide-LogSecrets') | Should -BeLessThan $m.IndexOf('HUPilot-Setup-Fehler.txt')
    }
    It 'typische Fehlermeldung einer Anmeldung: nur die Muster greifen, Text bleibt lesbar' {
        $raw = "Invoke-RestMethod : Body: grant_type=client_credentials&client_id=55555555-6666-7777-8888-999999999999&client_secret=Abc~123.xyz&scope=https%3A%2F%2Fgraph`r`nAuthorization: Bearer eyJ" + ('a' * 12) + '.' + ('b' * 12) + '.c'
        $o = Hide-SecretPatterns $raw
        $o | Should -Not -Match 'Abc~123'
        $o | Should -Not -Match 'eyJa'
        $o | Should -Match 'client_id=55555555'
        $o | Should -Match 'Invoke-RestMethod'
    }
}

Describe '2.8.0 B2: Daten am Stick vor dem Formatieren' {
    BeforeAll {
        $script:Free = @([char[]]'QRSTUVWXYZ' | Where-Object { -not [System.IO.Directory]::Exists("$($_):\") -and -not (Test-Path ("$($_):")) })[0]
        $script:StickDir = Join-Path $script:Tmp 'stick'
        New-Item -ItemType Directory -Path (Join-Path $script:StickDir 'HUPilot\logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:StickDir 'HUPilot\logs\hashes.csv') -Value @($script:Hdr, 'SN1,,HASH1,Klasse-2026,', '', 'SN2,,HASH2,Klasse-2026,') -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:StickDir 'HUPilot\logs\protokoll.csv') -Value @('Zeit;Seriennr;Tenant;Tag;Ergebnis', '2026-11-14 08:00:00;SN1;Muster;Klasse-2026;UPLOAD OK') -Encoding ASCII
        $script:Subst = $false
        if ($script:Free) { & subst.exe "$($script:Free):" $script:StickDir | Out-Null; $script:Subst = [System.IO.Directory]::Exists("$($script:Free):\") }
    }
    AfterAll { if ($script:Subst) { & subst.exe "$($script:Free):" /D | Out-Null } }
    It 'Get-CsvDataLines: fehlt = 0, nur Kopf = 0, Leerzeilen zaehlen nicht' {
        Get-CsvDataLines (Join-Path $script:Tmp 'gibtsnicht.csv') 'Device' | Should -Be 0
        $f = Join-Path $script:Tmp 'kopf.csv'; Set-Content -LiteralPath $f -Value $script:Hdr -Encoding ASCII
        Get-CsvDataLines $f 'Device Serial Number' | Should -Be 0
        Get-CsvDataLines (Join-Path $script:StickDir 'HUPilot\logs\hashes.csv') 'Device Serial Number' | Should -Be 2
    }
    It 'Get-CsvDataLines: von einem anderen Programm gesperrt = -1 (nicht 0)' {
        $f = Join-Path $script:Tmp 'gesperrt.csv'; Set-Content -LiteralPath $f -Value @($script:Hdr, 'SN9,,H,T,') -Encoding ASCII
        $lock = [System.IO.File]::Open($f, 'Open', 'ReadWrite', 'None')
        try { Get-CsvDataLines $f 'Device Serial Number' | Should -Be -1 } finally { $lock.Dispose() }
    }
    It 'Get-CsvDataLines: liest auch, wenn die Datei zum Schreiben offen ist (go schreibt gerade)' {
        $f = Join-Path $script:Tmp 'offen.csv'; Set-Content -LiteralPath $f -Value @($script:Hdr, 'SN9,,H,T,') -Encoding ASCII
        $h = [System.IO.File]::Open($f, 'Open', 'ReadWrite', 'ReadWrite')
        try { Get-CsvDataLines $f 'Device Serial Number' | Should -Be 1 } finally { $h.Dispose() }
    }
    It 'Get-StickDataWarnings: Hashes zuerst mit naechstem Schritt, dann das Stick-Protokoll' {
        if (-not $script:Subst) { Set-ItResult -Skipped -Because 'kein freier Laufwerksbuchstabe fuer subst'; return }
        $w = Get-StickDataWarnings @("$($script:Free)")
        $w.Hashes | Should -Be 2
        $w.Lines | Should -HaveCount 2
        $w.Lines[0] | Should -Be ('Stick ' + $script:Free + ': 2 nicht importierte Hashes gehen verloren. Zuerst abbrechen und "7. Hashes importieren".')
        $w.Lines[1] | Should -Match '^Stick .: das Stick-Protokoll \(1 Einträge, für "6\. Status"\) geht verloren\.$'
    }
    It 'Get-StickDataWarnings: ein Hash in Einzahl, Stick ohne Daten ohne Zeile' {
        if (-not $script:Subst) { Set-ItResult -Skipped -Because 'kein freier Laufwerksbuchstabe fuer subst'; return }
        $f = Join-Path $script:StickDir 'HUPilot\logs\hashes.csv'
        Set-Content -LiteralPath $f -Value @($script:Hdr, 'SN1,,HASH1,Klasse-2026,') -Encoding ASCII
        (Get-StickDataWarnings @("$($script:Free)")).Lines[0] | Should -Match ': 1 nicht importierter Hash geht verloren\.'
        Remove-Item -LiteralPath $f; Remove-Item -LiteralPath (Join-Path $script:StickDir 'HUPilot\logs\protokoll.csv')
        $w = Get-StickDataWarnings @("$($script:Free)")
        $w.Lines | Should -HaveCount 0; $w.Hashes | Should -Be 0
    }
    It 'Get-StickDataWarnings: leerer Buchstabe und fehlender Stick werfen nicht' {
        { Get-StickDataWarnings @('', $null) } | Should -Not -Throw
        (Get-StickDataWarnings @()).Lines | Should -HaveCount 0
    }
    It 'Sticks vorbereiten: Warnungen vor der Rueckfrage, Hashes vorne, dann Nein vorgewaehlt, Abbruch formatiert nichts' {
        $b = Get-FnText 'Show-PrepSticks'
        $iW = $b.IndexOf('Get-StickDataWarnings'); $iQ = $b.IndexOf("'HUPilot - Sticks formatieren'"); $iF = $b.IndexOf('Format-Volume')
        $iW | Should -BeGreaterThan 0; $iW | Should -BeLessThan $iQ; $iQ | Should -BeLessThan $iF
        $b | Should -Match '\$warnAll = @\(@\(\$dw\.Lines\) \+ \$obw\)'
        $b | Should -Match "'YesNo', 'Warning', \`$\(if \(\`$dw\.Hashes -gt 0\) \{ 'No' \} else \{ 'Yes' \}\)"
        $b | Should -Match "if \(\`$q -ne 'Yes'\) \{ & \`$plog 'Abgebrochen, nichts formatiert\.'; return \}"
    }
    It 'Stick fertig machen und 5. Auf Stick kopieren lassen logs am Stick stehen (nichts geht verloren)' {
        $c = Get-FnText 'Copy-ToStick'
        $c | Should -Not -Match 'Remove-Item[^\r\n]*logs'
        $c | Should -Not -Match 'robocopy|/MIR'
        $c | Should -Match 'Test-SkipForStick'
        Get-FnText 'Test-SkipForStick' | Should -Match 'logs'
    }
}

Describe '2.8.0 D4: grosse Datentraeger (vermutlich Festplatten)' {
    It 'Grenze ist eine Konstante (128 GB), genau einmal festgelegt' {
        $script:PrepBigDiskGB | Should -Be 128
        @([regex]::Matches($script:SetupText, '(?m)^\$script:PrepBigDiskGB = ')).Count | Should -Be 1
    }
    It 'Test-PrepBigDisk: bis 128 GB nein, darueber ja' {
        Test-PrepBigDisk (64GB) | Should -BeFalse
        Test-PrepBigDisk (128GB) | Should -BeFalse
        Test-PrepBigDisk (128GB + 1) | Should -BeTrue
        Test-PrepBigDisk (1TB) | Should -BeTrue
        Test-PrepBigDisk 0 | Should -BeFalse
    }
    It 'Grenze laesst sich an einer Stelle aendern' {
        $alt = $script:PrepBigDiskGB
        try { $script:PrepBigDiskGB = 64; Test-PrepBigDisk (100GB) | Should -BeTrue } finally { $script:PrepBigDiskGB = $alt }
    }
    It 'Liste: grosse Eintraege mit Zusatz, Modell und Groesse am Eintrag' {
        $u = Get-FnText 'Get-UsbSticks'
        $u | Should -Match "Big    = \`$big"
        $u | Should -Match '\(groß, Festplatte\?\)'
        $u | Should -Match 'Model = \[string\]\$disk\.FriendlyName'
    }
    It 'eigene rote Rueckfrage je grossem Datentraeger, Nein vorgewaehlt, nach der Hauptrueckfrage und vor Format-Volume' {
        $b = Get-FnText 'Show-PrepSticks'
        $iQ = $b.IndexOf("'HUPilot - Sticks formatieren'"); $iB = $b.IndexOf("'HUPilot - Festplatte formatieren?'"); $iF = $b.IndexOf('Format-Volume')
        $iB | Should -BeGreaterThan $iQ; $iB | Should -BeLessThan $iF
        $b | Should -Match "'HUPilot - Festplatte formatieren\?', 'YesNo', 'Stop', 'No'"
        $b | Should -Match 'Das ist vermutlich eine Festplatte, kein Stick\.'
        $b | Should -Match 'Wirklich formatieren\?'
        $b | Should -Match "if \(-not \`$sel\.Count\) \{ & \`$plog 'Nichts formatiert\.' 'Hinweis'; return \}"
    }
    It 'Pruefung direkt vor Format-Volume unveraendert (Vergleich der Identitaet, nur USB, kein Boot- oder Systemdatentraeger)' {
        $b = Get-FnText 'Show-PrepSticks'
        $iC = $b.IndexOf('Compare-StickId $st.Id (New-StickId $disk $part $vol $dl)'); $iU = $b.IndexOf("[string]`$disk.BusType -ne 'USB' -or `$disk.IsBoot -or `$disk.IsSystem"); $iF = $b.IndexOf('Format-Volume')
        $iC | Should -BeGreaterThan 0; $iC | Should -BeLessThan $iU; $iU | Should -BeLessThan $iF
        Get-FnText 'Compare-StickId' | Should -Match "Where-Object \{ \[string\]\`$Old\.\`$_ -ne \[string\]\`$New\.\`$_ \}"
    }
}

Describe '2.8.0 B13: hashes.csv ohne Verlust von Umlauten' {
    BeforeAll {
        $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
        $script:Ansi = [System.Text.Encoding]::GetEncoding(1252)
        $script:Lines3 = @($script:Hdr, 'SN1,,HASH1,Klasse-2026,', ('SN2,,HASH2,Klasse-2026,m' + [char]0xFC + 'ller@example.org'), 'SN3,,HASH3,Lehrer,')
    }
    It 'UTF-8: Umlaut bleibt in den restlichen Zeilen und in hashes-erledigt.csv, Datei bleibt UTF-8 ohne BOM' {
        $d = Join-Path $script:Tmp 'u8'; New-Item -ItemType Directory $d -Force | Out-Null
        $f = Join-Path $d 'hashes.csv'; [System.IO.File]::WriteAllText($f, (($script:Lines3 -join "`r`n") + "`r`n"), $script:Utf8)
        Move-HashDone $f @('SN1', 'SN3') | Should -Be 2
        $b = [System.IO.File]::ReadAllBytes($f); $b[0] | Should -Not -Be 0xEF
        $t = $script:Utf8.GetString($b)
        $t | Should -Be ($script:Hdr + "`r`n" + 'SN2,,HASH2,Klasse-2026,m' + [char]0xFC + "ller@example.org`r`n")
        $e = [System.IO.File]::ReadAllText((Join-Path $d 'hashes-erledigt.csv'), $script:Utf8)
        $e | Should -Be ($script:Hdr + "`r`nSN1,,HASH1,Klasse-2026,`r`nSN3,,HASH3,Lehrer,`r`n")
    }
    It 'Verschieben des Umlaut-Geraets: Umlaut kommt unversehrt in hashes-erledigt.csv' {
        $d = Join-Path $script:Tmp 'u8b'; New-Item -ItemType Directory $d -Force | Out-Null
        $f = Join-Path $d 'hashes.csv'; [System.IO.File]::WriteAllText($f, (($script:Lines3 -join "`r`n") + "`r`n"), $script:Utf8)
        [void](Move-HashDone $f @('SN2'))
        [System.IO.File]::ReadAllText((Join-Path $d 'hashes-erledigt.csv'), $script:Utf8) | Should -Match ('m' + [char]0xFC + 'ller@example\.org')
    }
    It 'ASCII wie von go: bleibt Byte fuer Byte ASCII (go liest die Datei weiter)' {
        $d = Join-Path $script:Tmp 'asc'; New-Item -ItemType Directory $d -Force | Out-Null
        $f = Join-Path $d 'hashes.csv'; Set-Content -LiteralPath $f -Value @($script:Hdr, 'SN1,,HASH1,Klasse-2026,', 'SN2,,HASH2,Klasse-2026,') -Encoding ASCII
        [void](Move-HashDone $f @('SN1'))
        $b = [System.IO.File]::ReadAllBytes($f)
        @($b | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        [System.Text.Encoding]::ASCII.GetString($b) | Should -Be ($script:Hdr + "`r`nSN2,,HASH2,Klasse-2026,`r`n")
    }
    It 'ANSI (z. B. aus Excel): Umlaut bleibt, Datei bleibt ANSI' {
        $d = Join-Path $script:Tmp 'ansi'; New-Item -ItemType Directory $d -Force | Out-Null
        $f = Join-Path $d 'hashes.csv'; [System.IO.File]::WriteAllText($f, (($script:Lines3 -join "`r`n") + "`r`n"), $script:Ansi)
        $r = Read-HashText $f
        ($r.Lines -join '|') | Should -Match ('m' + [char]0xFC + 'ller')
        [void](Move-HashDone $f @('SN1'))
        $b = [System.IO.File]::ReadAllBytes($f)
        $b | Should -Contain ([byte]0xFC)
        $script:Ansi.GetString($b) | Should -Match ('m' + [char]0xFC + 'ller@example\.org')
    }
    It 'Read-HashCsv liest UPN mit Umlaut aus UTF-8 mit BOM' {
        $f = Join-Path $script:Tmp 'bom.csv'; [System.IO.File]::WriteAllText($f, (($script:Lines3 -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        $rows = @(Read-HashCsv $f)
        $rows | Should -HaveCount 3
        $rows[1].Benutzer | Should -Be ('m' + [char]0xFC + 'ller@example.org')
        $rows[0].LogText | Should -Be ''
    }
    It 'keine Zeile mehr mit Get-Content ohne Kodierung oder Set-Content -Encoding ASCII beim Verschieben' {
        $b = Get-FnText 'Show-HashImport'
        $b | Should -Match 'Move-HashDone \$f \$done'
        $b | Should -Not -Match 'Set-Content -Path \$f -Value \$keep'
        $b | Should -Not -Match 'Get-Content -Path \$f\)'
    }
}

Describe '2.8.0: Fenster Hashes importieren (kurzer Stand, voller Text im Protokoll)' {
    It '806 und 808 haben eine Kurzform ohne waagrechten Rollbalken (hoechstens 50 Zeichen)' {
        foreach ($c in '806', '808') { $e = Get-ImportErrorText $c ''; $e.Kurz | Should -Match ('^Fehler ' + $c + ': '); $e.Kurz.Length | Should -BeLessOrEqual 50 }
    }
    It 'Texte je Fehler stehen in je einer Zeile in der Funktion (808 mit go gleichziehen = eine Zeile)' {
        $f = Get-FnText 'Get-ImportErrorText'
        foreach ($n in 'Was808', 'Tun808', 'Kurz808', 'Was806', 'Tun806', 'Kurz806') { @([regex]::Matches($f, "(?m)^\s*\`$$n = '[^\r\n]*'\s*$")).Count | Should -Be 1 }
    }
    It 'Tabelle bekommt die Kurzform, das Protokoll den vollen Text mit naechstem Schritt' {
        $b = Get-FnText 'Show-HashImport'
        $b | Should -Match '\$r\.Status = \$\(if \(\$ie\) \{ \$ie\.Kurz \}'
        $b | Should -Match "\`$r\.LogText = \`$\(if \(\`$ie\) \{ \`$ie\.Was \+ ' ' \+ \`$ie\.Tun \}"
        $b | Should -Match '& \$hlog \(Get-HashRowLogText \$r\)'
    }
    It 'Get-HashRowLogText: voller Text, "Fehler:" nur einmal (die Stufe steht schon vorne)' {
        $e = Get-ImportErrorText '806' 'ZtdDeviceAlreadyAssigned'
        $r = [pscustomobject]@{ Seriennr = 'SN26-X'; Status = $e.Kurz; LogText = ($e.Was + ' ' + $e.Tun) }
        $t = Get-HashRowLogText $r
        $t | Should -Be ('SN26-X: ' + $e.Was + ' ' + $e.Tun)
        $t | Should -Not -Match 'Fehler:'
        Get-HashRowLogText ([pscustomobject]@{ Seriennr = 'SN1'; Status = 'Fehler: von Microsoft abgelehnt, später nochmal versuchen (Details im Protokoll)'; LogText = '' }) | Should -Be 'SN1: von Microsoft abgelehnt, später nochmal versuchen (Details im Protokoll)'
        Get-HashRowLogText ([pscustomobject]@{ Seriennr = 'SN1'; Status = 'OK - importiert'; LogText = '' }) | Should -Be 'SN1: OK - importiert'
    }
    It 'Stufe bleibt Fehler (Kurzform beginnt mit "Fehler")' {
        (Get-ImportErrorText '808' '').Kurz | Should -BeLike 'Fehler*'
    }
}

Describe '2.8.0 U2: Secret abgelaufen, Fuehrung ohne Portalzugang' {
    It 'expired nennt den Admin fuer alle ohne Zugang und erklaert Secret und Entra-Portal' {
        $t = (Get-SecretBanner 'expired' '13.11.2026 10:00').Text
        $t | Should -Match 'Ohne Zugang zum Entra-Portal \(Verwaltung der App-Registrierungen bei Microsoft\): den Admin fragen'
        $t | Should -Match 'Secret \(der geheime Schlüssel, mit dem HUPilot sich bei Microsoft anmeldet\)'
        $t | Should -Match '\(seit 13\.11\.2026 10:00\)'
    }
    It 'awaiting erklaert Clientschluessel und Geheimnis-ID und nennt den Admin' {
        $t = (Get-SecretBanner 'awaiting').Text
        $t | Should -Match '"Neuer geheimer Clientschlüssel" \(so heißt das Secret im Portal\)'
        $t | Should -Match '"Geheimnis-ID", das ist nur die Kennung'
        $t | Should -Match 'Kein Zugang zum Portal: den Admin fragen\.'
    }
    It 'nur Tastaturzeichen in den Texten' {
        foreach ($m in 'expired', 'awaiting') { (Get-SecretBanner $m 'x').Text | Should -Not -Match '[\u2013\u2014\u2192\u201E\u201C\u2026]' }
    }
}

Describe '2.8.0 B12: Beispieladressen' {
    It 'keine Beispieladresse mit Schul-Domain im Setup (Beispiele nur example.org)' {
        $script:SetupText | Should -Not -Match '(?i)name@schule\.'
    }
}

Describe '2.8.0: Ampel im Hauptknopf sichtbar' {
    It 'Ampel liegt auf einem eigenen dunklen Grund (gruen auf gruenem Knopf war nicht zu sehen)' {
        $x = [regex]::Match($script:SetupText, '<Grid Width="17" Height="17"[^>]*><Ellipse Fill="\{DynamicResource HuPanel\}"[^>]*/><Ellipse x:Name="eReady"[^>]*/></Grid>').Value
        $x | Should -Not -BeNullOrEmpty
        $x | Should -Match 'Style="\{StaticResource HuLamp\}"'
    }
    It 'Hauptknopf: Ampel wird nach "fertig und kontrolliert" gruen gesetzt (ok oder warn)' {
        $script:SetupText | Should -Match "Set-Step 'Ready' \`$\(if \(\`$warn\.Count\) \{ 'warn' \} else \{ 'ok' \}\)"
    }
    It 'XAML des Hauptfensters laedt weiterhin (Ellipse in Grid)' {
        $x = [regex]::Match($script:SetupText, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
        { [xml]$x } | Should -Not -Throw
    }
}

Describe '2.8.0 Runde 2 (G2): Fehlertext im trap ohne Out-String' {
    It 'kein Out-String mehr im Setup, der trap setzt Meldung, Stelle und Aufrufkette selbst zusammen' {
        $script:SetupText | Should -Not -Match '\|\s*Out-String'
        $m = [regex]::Match($script:SetupText, '(?s)trap \{(.*?)\r?\n\}').Groups[1].Value
        $m | Should -Match '\$_\.Exception\.Message'
        $m | Should -Match '\$_\.InvocationInfo\.PositionMessage'
        $m | Should -Match '\$_\.ScriptStackTrace'
        $m.IndexOf('Hide-LogSecrets') | Should -BeGreaterThan $m.IndexOf('ScriptStackTrace')
    }
    It 'eine lange Adresse mit sig= in einer Meldung wird am Stueck erkannt' {
        $u = 'https://' + ('x' * 150) + '.invalid/workflows/abc?api-version=1&sig=' + ('S' * 43)
        Hide-LogSecrets ('Fehler beim Senden an ' + $u + ' Ende') @() | Should -Be 'Fehler beim Senden an (Webhook) Ende'
    }
}

Describe '2.8.0 Runde 2: lange Zeilen erst kappen, dann bereinigen, dann kuerzen' {
    It 'kurze Texte bleiben unveraendert' {
        $t = ('Wort ' * 900).TrimEnd()
        Limit-MaskInput $t | Should -Be $t
        Complete-MaskInput $t | Should -Be $t
    }
    It '30000 Zeichen ohne Leerzeichen mit vielen https:// sind schnell bereinigt' {
        $t = ('https://x.invalid/a' * 1600)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $o = Hide-LogSecrets $t @('geheimerWert1')
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3
        $o.Length | Should -BeLessOrEqual 4011
        $o | Should -Match ' \(gekürzt\)$'
    }
    It 'Geheimnis genau an der groben Schnittstelle: kein Teilstueck bleibt stehen (ohne Leerzeichen)' {
        $sec = 'QWERTZUIOPasdfghjkl1234567890yxcvbnmMNBV'
        $o = Hide-LogSecrets (('a' * 4990) + $sec + ('b' * 200)) @($sec)
        $o | Should -Not -Match 'QWERTZ'
        $o | Should -Match ' \(gekürzt\)$'
    }
    It 'Geheimnis an der Schnittstelle mit Leerzeichen davor: Ende bis zum letzten Leerzeichen weg' {
        $sec = 'QWERTZUIOPasdfghjkl1234567890yxcvbnmMNBV'
        $pre = ('wort ' * 998)                       # 4990 Zeichen
        $o = Hide-LogSecrets ($pre + $sec + ' Rest') @($sec)
        $o | Should -Not -Match 'QWERTZ'
        $o | Should -Match 'wort \(gekürzt\)$'
        $o.Length | Should -BeLessOrEqual 4011
    }
    It 'Muster ohne bekannten Wert an der Schnittstelle (sig=-Adresse angeschnitten) kommt nicht durch' {
        $o = Hide-SecretPatterns (('c ' * 2470) + 'https://y.invalid/p?a=1&s' + ('ig=' + ('Z' * 60)))
        $o | Should -Not -Match 'y\.invalid'
        $o | Should -Match ' \(gekürzt\)$'
    }
    It 'nur lange Zeilen werden gekuerzt, andere Zeilen bleiben' {
        $o = Hide-LogSecrets ("erste Zeile`n" + ('d' * 9000) + "`nletzte Zeile") @()
        $l = $o -split "`n"
        $l | Should -HaveCount 3
        $l[0] | Should -Be 'erste Zeile'; $l[2] | Should -Be 'letzte Zeile'
        $l[1] | Should -Match '^d+ \(gekürzt\)$'
        $l[1].Length | Should -BeLessOrEqual 4011
    }
    It 'Bereinigen und Kuerzen in Hide-LogSecrets: erst Limit, dann Werte und Muster, dann Complete' {
        $f = Get-FnText 'Hide-LogSecrets'
        $f.IndexOf('Limit-MaskInput') | Should -BeLessThan $f.IndexOf('Get-SecretVariants')
        $f.IndexOf('Get-SecretVariants') | Should -BeLessThan $f.IndexOf('Complete-MaskInput')
    }
}

Describe '2.8.0 Runde 2 (G6): Pruefung der Hashes darf nie still "keine" heissen' {
    It 'Ordner am Stick da, aber nicht lesbar: -1, nicht 0' {
        $d = Join-Path $script:Tmp 'gesperrt'; New-Item -ItemType Directory -Path (Join-Path $d 'logs') -Force | Out-Null
        $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe (Join-Path $d 'logs') /deny ($who + ':(RX)') | Out-Null
        try { Get-CsvDataLines (Join-Path $d 'logs\hashes.csv') 'Device Serial Number' | Should -Be -1 }
        finally { & icacls.exe (Join-Path $d 'logs') /remove:d $who | Out-Null }
    }
    It 'Ordner fehlt ganz: 0 (kein Stick-Protokoll, keine Hashes)' {
        Get-CsvDataLines (Join-Path $script:Tmp 'gibtsnicht\logs\hashes.csv') 'Device Serial Number' | Should -Be 0
    }
    It 'Ausnahme in der Pruefung: Warnzeile je Stick und Nein vorgewaehlt' {
        $b = Get-FnText 'Show-PrepSticks'
        $b | Should -Match "catch \{ \`$dw = \[pscustomobject\]@\{ Lines = @\(\`$sel \| ForEach-Object \{ 'Stick ' \+ \`$_\.Letter \+ ': Ob nicht importierte Hashes am Stick liegen, ließ sich nicht prüfen\.' \}\); Hashes = 1 \} \}"
    }
}

Describe '2.8.0 Runde 2 (G7): hashes.csv ueber eine Datei daneben ersetzen' {
    BeforeAll { $script:U8 = New-Object System.Text.UTF8Encoding($false) }
    It 'schreibt vollstaendig und laesst keine .tmp liegen (neue und bestehende Datei)' {
        $f = Join-Path $script:Tmp 'w1.csv'
        Write-HashText $f @('a', 'b') $script:U8
        [System.IO.File]::ReadAllText($f) | Should -Be "a`r`nb`r`n"
        Write-HashText $f @('c') $script:U8
        [System.IO.File]::ReadAllText($f) | Should -Be "c`r`n"
        Test-Path -LiteralPath ($f + '.tmp') | Should -BeFalse
    }
    It 'UTF-8 mit BOM bleibt mit BOM' {
        $f = Join-Path $script:Tmp 'w2.csv'
        Write-HashText $f @('x') (New-Object System.Text.UTF8Encoding($true))
        $b = [System.IO.File]::ReadAllBytes($f); $b[0] | Should -Be 0xEF; $b.Length | Should -Be 6
    }
    It 'Repair-HashTmp: beide da = .tmp ist ein Rest und kommt weg' {
        $f = Join-Path $script:Tmp 'r1.csv'; Set-Content -LiteralPath $f -Value 'alt' -Encoding ASCII; Set-Content -LiteralPath ($f + '.tmp') -Value 'halb' -Encoding ASCII
        Repair-HashTmp $f | Should -Be 'removed'
        Test-Path -LiteralPath ($f + '.tmp') | Should -BeFalse
        (Get-Content -LiteralPath $f) | Should -Be 'alt'
    }
    It 'Repair-HashTmp: nur .tmp da (Abbruch zwischen Loeschen und Umbenennen) = wird zur Datei' {
        $f = Join-Path $script:Tmp 'r2.csv'; Set-Content -LiteralPath ($f + '.tmp') -Value 'voll' -Encoding ASCII
        Repair-HashTmp $f | Should -Be 'restored'
        (Get-Content -LiteralPath $f) | Should -Be 'voll'
        Repair-HashTmp $f | Should -Be 'none'
    }
    It 'Read-HashCsv liest nach einem Abbruch die wiederhergestellte Datei, nie die .tmp als zusaetzliche Daten' {
        $d = Join-Path $script:Tmp 'rh'; New-Item -ItemType Directory $d -Force | Out-Null
        $f = Join-Path $d 'hashes.csv'
        Set-Content -LiteralPath $f -Value @($script:Hdr, 'SN1,,H1,T,') -Encoding ASCII
        Set-Content -LiteralPath ($f + '.tmp') -Value @($script:Hdr, 'SN1,,H1,T,', 'SN9,,H9,T,') -Encoding ASCII
        @(Read-HashCsv $f).Seriennr | Should -Be @('SN1')
        Test-Path -LiteralPath ($f + '.tmp') | Should -BeFalse
    }
    It 'Move-HashDone raeumt einen Rest auf und arbeitet danach normal' {
        $d = Join-Path $script:Tmp 'mh'; New-Item -ItemType Directory $d -Force | Out-Null
        $f = Join-Path $d 'hashes.csv'
        Set-Content -LiteralPath $f -Value @($script:Hdr, 'SN1,,H1,T,', 'SN2,,H2,T,') -Encoding ASCII
        Set-Content -LiteralPath ($f + '.tmp') -Value 'halb' -Encoding ASCII
        Move-HashDone $f @('SN1') | Should -Be 1
        Test-Path -LiteralPath ($f + '.tmp') | Should -BeFalse
        [System.IO.File]::ReadAllText($f) | Should -Be ($script:Hdr + "`r`nSN2,,H2,T,`r`n")
    }
    It 'Rueckfall ohne File.Replace (z. B. FAT32, exFAT): alte Datei loeschen, neue umbenennen' {
        $w = Get-FnText 'Write-HashText'
        $w | Should -Match 'try \{ \[System\.IO\.File\]::Replace\(\$tmp, \$Path, \$null\) \}'
        $w | Should -Match 'catch \{ \[System\.IO\.File\]::Delete\(\$Path\); \[System\.IO\.File\]::Move\(\$tmp, \$Path\) \}'
        $w | Should -Match 'FileOptions\]::WriteThrough'
        $w | Should -Match '\$fs\.Flush\(\$true\)'
    }
}

Describe 'v2.8.1: frisch registriertes Geraet ist kein Problem' {
    BeforeAll {
        $src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Stick\HUPilot\Setup\HUPilot-Setup.ps1') -Raw -Encoding UTF8
        $script:Src281 = $src
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
        $fns = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        . ([scriptblock]::Create((@($fns | Where-Object { $_.Name -in 'Get-FreshImportTodo', 'Get-DeviceTodo' } | ForEach-Object { $_.Extent.Text }) -join "`n")))
        $script:FreshImportMin = 30
    }
    It 'bis 30 Minuten nach dem Eintrag im Stick-Protokoll: Text mit Minuten, danach und ohne Zeit leer' {
        Get-FreshImportTodo 1 | Should -Be 'Nichts, läuft. Frisch registriert (vor 1 Min), das Profil kommt meist in 5 bis 15 Minuten.'
        Get-FreshImportTodo 0 | Should -Match 'vor 0 Min'
        Get-FreshImportTodo 30 | Should -Match 'vor 30 Min'
        Get-FreshImportTodo 30.5 | Should -Be ''
        Get-FreshImportTodo 600 | Should -Be ''
        # Uhr des Geraets geht etwas vor: bis 10 Minuten in der Zukunft gilt noch, weiter nicht
        Get-FreshImportTodo -5 | Should -Match 'vor 0 Min'
        Get-FreshImportTodo -11 | Should -Be ''
    }
    It 'Kein Profil nennt zuerst den harmlosen Fall, bleibt sonst bei Tag pruefen' {
        $t = Get-DeviceTodo 'Kein Profil für diesen Group Tag' 'notAssigned' ''
        $t | Should -Match '^Gerade registriert\? 15 Minuten warten\. Sonst "2\. Tags prüfen"'
        $t | Should -Match 'Tag ändern'
    }
    It 'Einbau: nur bei Kein Profil, nur mit Zeit aus dem Stick-Protokoll, nicht nach einem Fehler am Geraet, Stand wird Wartet auf Profil' {
        $i = $script:Src281.IndexOf("if (`$stand -eq 'Kein Profil für diesen Group Tag' -and `$pt -ne [datetime]::MinValue -and [string]`$pr.Ergebnis -notlike 'FEHLER*') {")
        $i | Should -BeGreaterThan -1
        $b = $script:Src281.Substring($i, 330)
        $b | Should -Match ([regex]::Escape('$fresh = Get-FreshImportTodo (($now - $pt).TotalMinutes)'))
        $b | Should -Match ([regex]::Escape("if (`$fresh) { `$stand = 'Wartet auf Profil'; `$todo = `$fresh }"))
        # nach Doppelt und Wird gelöscht (die setzen den Stand vorher um) und vor dem Bau der Zeile
        $i | Should -BeGreaterThan $script:Src281.IndexOf("elseif (`$dm) { `$stand = 'Doppelt'")
        $i | Should -BeLessThan $script:Src281.IndexOf('Klasse         = $script:StandClass[$stand]')
    }
}