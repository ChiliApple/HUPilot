#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer go.ps1. go.ps1 laeuft nur im Einrichtungsbildschirm und setzt Geraete zurueck,
# deshalb werden einzelne Funktionen per AST herausgeloest und ohne Geraet geprueft, dazu Pruefungen am Quelltext.

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:GoPath = Join-Path $script:Root 'Stick\HUPilot\go.ps1'
    $script:GoText = Get-Content -LiteralPath $script:GoPath -Raw -Encoding UTF8
    $tk = $null; $er = $null
    $script:GoAst = [System.Management.Automation.Language.Parser]::ParseFile($script:GoPath, [ref]$tk, [ref]$er)
    $script:GoTop = @($script:GoAst.EndBlock.Statements)
    function Get-GoFunctionText([string[]]$Names) {
        $t = @($script:GoTop | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Names -contains $_.Name } | ForEach-Object { $_.Extent.Text })
        if ($t.Count -ne $Names.Count) { throw ('Funktionen nicht (eindeutig) in go.ps1: ' + ($Names -join ', ')) }
        return ($t -join "`n")
    }
    $script:Pat = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

Describe 'go: Tag-Auswahl aus config.json' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'Get-TagChoices'))) }
    It 'Feld fehlt: Rueckfall auf die Jahre' {
        $r = Get-TagChoices ('{"GroupTag":"SN-2026"}' | ConvertFrom-Json) $script:Pat 2026
        $r.Source | Should -Be 'Jahre'
        @($r.Choices) -join ',' | Should -Be 'SN-2021,SN-2022,SN-2023,SN-2024,SN-2025,SN-2026'
    }
    It 'Feld null: wie fehlend' {
        (Get-TagChoices ('{"TagChoices":null}' | ConvertFrom-Json) $script:Pat 2026).Source | Should -Be 'Jahre'
    }
    It 'Feld vorhanden und leer: keine Auswahl, kein Rueckfall' {
        $r = Get-TagChoices ('{"GroupTag":"SN-2026","TagChoices":[]}' | ConvertFrom-Json) $script:Pat 2026
        $r.Source | Should -Be 'Config'
        @($r.Choices).Count | Should -Be 0
        @($r.Hidden).Count | Should -Be 0
    }
    It 'mehr als 9 Eintraege: auf 9 abgeschnitten, Rest gemeldet' {
        $j = '{"TagChoices":[' + ((1..12 | ForEach-Object { '"T' + $_ + '"' }) -join ',') + ']}'
        $r = Get-TagChoices ($j | ConvertFrom-Json) $script:Pat 2026
        @($r.Choices).Count | Should -Be 9
        @($r.Choices)[8] | Should -Be 'T9'
        @($r.Cut) -join ',' | Should -Be 'T10,T11,T12'
    }
    It 'ungueltige Eintraege werden ausgeblendet und zaehlen nicht zu den 9' {
        $r = Get-TagChoices ('{"TagChoices":["SN-2024","bad tag","","SN 2","-x","SN-2025"," SN-2026 "]}' | ConvertFrom-Json) $script:Pat 2026
        @($r.Choices) -join ',' | Should -Be 'SN-2024,SN-2025,SN-2026'
        @($r.Hidden) -join ',' | Should -Be 'bad tag,SN 2,-x'
        @($r.Cut).Count | Should -Be 0
    }
    It 'eigenes Muster gilt auch fuer die Jahre' {
        $r = Get-TagChoices ('{}' | ConvertFrom-Json) '^LAB-\d+$' 2026
        @($r.Choices).Count | Should -Be 0
        @($r.Hidden).Count | Should -Be 6
    }
    It 'einzelner Text statt Liste wird als ein Eintrag genommen' {
        @((Get-TagChoices ('{"TagChoices":"SN-2024"}' | ConvertFrom-Json) $script:Pat 2026).Choices) -join ',' | Should -Be 'SN-2024'
    }
}

Describe 'go: Ablauf des Secrets (SecretExpires)' {
    BeforeAll { . ([scriptblock]::Create((Get-GoFunctionText 'ConvertFrom-SecretExpires'))) }
    It 'liest yyyy-MM-ddTHH:mm:ssZ als UTC' {
        $d = ConvertFrom-SecretExpires '2026-11-20T08:30:00Z'
        $d | Should -BeOfType [datetime]
        $d.Kind | Should -Be 'Utc'
        $d.ToString('yyyy-MM-dd HH:mm:ss') | Should -Be '2026-11-20 08:30:00'
    }
    It 'liest den Wert aus config.json (PowerShell 5.1 und 7)' {
        $c = '{"SecretExpires":"2026-11-20T08:30:00Z"}' | ConvertFrom-Json
        (ConvertFrom-SecretExpires $c.SecretExpires).ToString('yyyy-MM-dd HH:mm:ss') | Should -Be '2026-11-20 08:30:00'
    }
    It 'fehlt, leer oder nicht lesbar = unbekannt' {
        ConvertFrom-SecretExpires $null | Should -BeNullOrEmpty
        ConvertFrom-SecretExpires '' | Should -BeNullOrEmpty
        ConvertFrom-SecretExpires '   ' | Should -BeNullOrEmpty
        ConvertFrom-SecretExpires 'morgen' | Should -BeNullOrEmpty
        ConvertFrom-SecretExpires '2026-11-20' | Should -BeNullOrEmpty
        ConvertFrom-SecretExpires '20.11.2026 08:30' | Should -BeNullOrEmpty
        $c = '{"Tenant":"x"}' | ConvertFrom-Json
        ConvertFrom-SecretExpires $c.SecretExpires | Should -BeNullOrEmpty
    }
    It 'Hinweis erst nach der Uhr-Korrektur, Datum bei AADSTS7000222 und 7000215' {
        $iSync = $script:GoText.IndexOf("Say 'Internet OK' 'Green'")
        $iExp = $script:GoText.IndexOf('$SecretExp = ConvertFrom-SecretExpires $cfg.SecretExpires')
        $iTok = $script:GoText.IndexOf('$tok = $null')
        $iSync | Should -BeGreaterThan 0
        $iExp | Should -BeGreaterThan $iSync
        $iTok | Should -BeGreaterThan $iExp
        $script:GoText | Should -Match "AADSTS7000222'\) \{ Save-Offline \('Secret ABGELAUFEN' \+ \`$expInfo"
        $script:GoText | Should -Match "AADSTS7000215'\) \{ Save-Offline \('Secret FALSCH[^']*' \+ \`$expInfo"
    }
}

Describe 'go: Merkdatei Edition mit gemerkten Antworten' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Save-EdMark', 'Get-EdMarkBase', 'Get-EdMarkAnswers')))
        function Log([string]$Msg) { }
    }
    It 'schreibt Antworten lokal und am Stick und liest sie wieder' {
        $EdMarkLocal = Join-Path $TestDrive 'lokal.json'
        $EdMarkStick = Join-Path $TestDrive 'edition_SER1.json'
        Save-EdMark @{ Seriennr = 'SER1'; Zeit = '2026-11-13 10:00:00'; Von = 'Core'; Ziel = 'Professional'; Aktiviert = $false; Antworten = @{ Tag = 'SN-2025'; Benutzer = 'max@test.example'; Zuruecksetzen = $true } }
        foreach ($f in $EdMarkLocal, $EdMarkStick) {
            Test-Path $f | Should -BeTrue
            $m = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            $a = Get-EdMarkAnswers $m $script:Pat
            $a.Tag | Should -Be 'SN-2025'
            $a.Benutzer | Should -Be 'max@test.example'
            $a.Reset | Should -BeTrue
        }
    }
    It 'keine Antworten nach erfolgter Aktivierung, ohne Antworten oder mit ungueltigen Werten' {
        $ok = '{"Aktiviert":false,"Antworten":{"Tag":"SN-2025","Benutzer":"","Zuruecksetzen":false}}' | ConvertFrom-Json
        $a = Get-EdMarkAnswers $ok $script:Pat
        $a.Reset | Should -BeFalse
        $a.Benutzer | Should -Be ''
        Get-EdMarkAnswers ('{"Aktiviert":true,"Antworten":{"Tag":"SN-2025","Benutzer":"","Zuruecksetzen":true}}' | ConvertFrom-Json) $script:Pat | Should -BeNullOrEmpty
        Get-EdMarkAnswers ('{"Aktiviert":false}' | ConvertFrom-Json) $script:Pat | Should -BeNullOrEmpty
        Get-EdMarkAnswers ('{"Aktiviert":false,"Antworten":{"Tag":"bad tag","Benutzer":"","Zuruecksetzen":true}}' | ConvertFrom-Json) $script:Pat | Should -BeNullOrEmpty
        Get-EdMarkAnswers ('{"Aktiviert":false,"Antworten":{"Tag":"SN-2025","Benutzer":"keine-mail","Zuruecksetzen":true}}' | ConvertFrom-Json) $script:Pat | Should -BeNullOrEmpty
        Get-EdMarkAnswers ('{"Aktiviert":false,"Antworten":{"Tag":"SN-2025","Benutzer":"","Zuruecksetzen":"ja"}}' | ConvertFrom-Json) $script:Pat | Should -BeNullOrEmpty
        Get-EdMarkAnswers $null $script:Pat | Should -BeNullOrEmpty
    }
    It 'Neuschreiben ohne Antworten behaelt die Merkdatei (kein stiller zweiter Versuch)' {
        $m = '{"Seriennr":"SER1","Zeit":"2026-11-13 10:00:00","Von":"Core","Ziel":"Professional","Aktiviert":false,"Antworten":{"Tag":"SN-2025","Benutzer":"","Zuruecksetzen":true}}' | ConvertFrom-Json
        $b = Get-EdMarkBase $m
        $b.Keys | Should -Not -Contain 'Antworten'
        $b.Seriennr | Should -Be 'SER1'
        $b.Von | Should -Be 'Core'
        $b.Aktiviert | Should -BeFalse
        $EdMarkLocal = Join-Path $TestDrive 'lokal2.json'
        $EdMarkStick = Join-Path $TestDrive 'stick2.json'
        Save-EdMark $b
        Test-Path $EdMarkLocal | Should -BeTrue
        Get-EdMarkAnswers (Get-Content -LiteralPath $EdMarkLocal -Raw -Encoding UTF8 | ConvertFrom-Json) $script:Pat | Should -BeNullOrEmpty
    }
    It 'in die Merkdatei kommen keine Schluessel' {
        $lines = @($script:GoText -split "`r?`n" | Where-Object { $_ -match 'Save-EdMark ' -and $_ -notmatch '^\s*function ' })
        $lines.Count | Should -BeGreaterThan 1
        foreach ($l in $lines) { $l | Should -Not -Match '\$EdKey\b|\$genKey|ProductKey' }
        $script:GoText | Should -Match "Antworten = @\{ Tag = \[string\]\`$cfg\.GroupTag; Benutzer = \[string\]\`$AssignUpn; Zuruecksetzen = \[bool\]\`$DoReset \}"
    }
    It 'Schutz bleibt: nach einem Fehlversuch nur mit Taste W ein neuer Versuch' {
        $script:GoText | Should -Match "Read-KeyTimeout 30 'ohne Eingabe: abbrechen' -Valid 'W'\s+if \(\`$k -ne 'W'\) \{ Fail"
    }
}

Describe 'go: Tasten und Countdown' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Clear-KeyBuffer', 'Test-KeyAnswer', 'Read-KeyTimeout')))
        $script:SW = [Diagnostics.Stopwatch]::StartNew()
        function Get-Mono { return $script:SW.Elapsed.TotalSeconds }
        function Show-Live { param([string]$Text, [switch]$NoPre) }
        function Complete-Live { }
        function Log([string]$Msg) { }
    }
    It 'Enter nimmt den Standard, gueltige Taste ist die Antwort' {
        Test-KeyAnswer 'ENTER' @('J', 'N') | Should -Be 'ENTER'
        Test-KeyAnswer 'J' @('J', 'Y', 'N') | Should -Be 'J'
        Test-KeyAnswer '3' @('1', '2', '3') | Should -Be '3'
    }
    It 'andere Taste ist keine Antwort (Countdown haelt an)' {
        Test-KeyAnswer 'X' @('J', 'N') | Should -Be ''
        Test-KeyAnswer '5' @('1', '2') | Should -Be ''
        Test-KeyAnswer '' @('J') | Should -Be ''
    }
    It 'ohne Liste gueltiger Tasten zaehlt jede Taste' {
        Test-KeyAnswer 'X' @() | Should -Be 'X'
        Test-KeyAnswer 'X' | Should -Be 'X'
    }
    It 'umgeleitete Eingabe oder keine Taste: Standard (leer)' {
        $t0 = Get-Mono
        Read-KeyTimeout 1 'Test' -Valid 'J', 'N' | Should -Be ''
        ((Get-Mono) - $t0) | Should -BeLessThan 5
    }
    It 'Tastaturpuffer wird vor jeder Frage geleert' {
        $f = @($script:GoTop | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Read-KeyTimeout' })[0]
        $f.Body.Extent.Text | Should -Match '^\{\s*(#[^\r\n]*\s*)*param\([^\r\n]+\)\s+Clear-KeyBuffer'
        # Read-Host nur noch ueber Read-Line (leert den Puffer), ausser im Block fuer fehlende Adminrechte vor allen Funktionen
        $firstFn = @($script:GoTop | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })[0].Extent.StartOffset
        $rl = @($script:GoTop | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Read-Line' })[0]
        $bad = @($script:GoAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Read-Host' }, $true) | Where-Object {
            $_.Extent.StartOffset -gt $firstFn -and -not ($_.Extent.StartOffset -ge $rl.Extent.StartOffset -and $_.Extent.EndOffset -le $rl.Extent.EndOffset) })
        ($bad | ForEach-Object { 'Zeile ' + $_.Extent.StartLineNumber }) -join ', ' | Should -Be ''
    }
}

Describe 'go: Ablauf und Sicherheit (Quelltext)' {
    It 'MinBattery wird vor der ersten Verwendung von Wait-Power gelesen' {
        $iMin = @($script:GoTop | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Extent.Text -match '\$cfg\.MinBattery' })[0].Extent.StartOffset
        $iUse = @($script:GoTop | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-Power' }, $true).Count })[0].Extent.StartOffset
        $iMin | Should -BeLessThan $iUse
    }
    It 'erst pruefen, dann fragen: Hash, WLAN-Paket und Edition vor der ersten Frage' {
        $iQ = $script:GoText.IndexOf("Write-Host '  Group Tag wählen:'")
        $iQ | Should -BeGreaterThan 0
        foreach ($s in "Fail 'Der Hardware-Hash ist nicht lesbar", "Fail ('Das WLAN-Paket fehlt am Stick", "Fail ('In config.json fehlt das Feld", "if (`$EdKeyIsGeneric) { Fail", "Fail 'Die Seriennummer des Geräts ist nicht lesbar") {
            $i = $script:GoText.IndexOf($s)
            $i | Should -BeGreaterThan 0 -Because $s
            $i | Should -BeLessThan $iQ -Because $s
        }
        $script:GoText.IndexOf("Write-Host '  Nach dem Upload zurücksetzen?'") | Should -BeGreaterThan $iQ
        $script:GoText.IndexOf('---------- Zusammenfassung ----------') | Should -BeGreaterThan $script:GoText.IndexOf("Write-Host '  Nach dem Upload zurücksetzen?'")
    }
    It 'Seriennummer im OData-Filter mit verdoppeltem Hochkomma (alle Stellen)' {
        $all = @([regex]::Matches($script:GoText, "serialNumber(,| eq )'"" \+ \`$Serial[^)]*\)"))
        $all.Count | Should -BeGreaterThan 2
        foreach ($m in $all) { $m.Value | Should -Match ([regex]::Escape("`$Serial.Replace(""'"", ""''"")")) }
    }
    It 'provtool im Zweig Zuruecksetzen mit Zeitlimit und Ausweichweg als SYSTEM' {
        $main = $script:GoText.Substring(0, $script:GoText.IndexOf("`$wipe = @'"))
        $main | Should -Not -Match 'provtool[^\r\n]*-Wait\b'
        $main | Should -Not -Match 'Start-Process -FilePath \$prov [^\r\n]*-Wait\b'
        $main | Should -Match '\$pr\.WaitForExit\(120000\)\) \{ Log \(''provtool Exitcode'
        $main | Should -Match "if \(-not \`$prOk\) \{ Log 'provtool fehlgeschlagen - neuer Versuch als SYSTEM im Hilfsscript'; \`$SysPkg = \`$TmpPkg \}"
    }
    It 'ohne Profil wird nur mit Taste J zurueckgesetzt, Standard ist weiter warten' {
        $loop = @($script:GoAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -eq '-not $wr.Assigned' }, $true))
        $loop.Count | Should -Be 1
        $brk = @($loop[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.BreakStatementAst] }, $true))
        $brk.Count | Should -Be 1
        $p = $brk[0].Parent
        while ($p -and $p -isnot [System.Management.Automation.Language.IfStatementAst]) { $p = $p.Parent }
        $p.Clauses[0].Item1.Extent.Text | Should -Be "`$k -eq 'J' -or `$k -eq 'Y'"
        $loop[0].Body.Extent.Text | Should -Match "Read-KeyTimeout 60 'ohne Eingabe: weiter warten' -Valid 'J', 'Y', 'N'"
        $script:GoText | Should -Match '(?m)^\$ProfileRounds = 4\r?$'
        $script:GoText | Should -Not -Match "Read-Host '  J / N'"
    }
    It 'Schutz vor eingerichteten Geraeten (LOESCHEN) und Akku-Pruefung bleiben' {
        $script:GoText | Should -Match "if \(\`$a -cne 'LÖSCHEN' -and \`$a -cne 'LOESCHEN'\) \{ Log 'Abbruch: Gerät hat Benutzerdaten'"
        $script:GoText | Should -Match "Show-Step 6 'Zurücksetzen'\s+Wait-Power"
        $script:GoText | Should -Match 'if \(\$okCount -ge 2\) \{'
    }
}
