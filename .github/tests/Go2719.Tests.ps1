#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer go.ps1, Version 2.7.19: Importfehler 806 und 808 von Windows Autopilot in Klartext.
# Funktionen werden per AST aus go.ps1 geloest und ohne Geraet geprueft (kein Graph, nur kuenstliche Werte).

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:GoPath = Join-Path $script:Root 'Stick\HUPilot\go.ps1'
    $script:GoText = Get-Content -LiteralPath $script:GoPath -Raw -Encoding UTF8
    $tk = $null; $er = $null
    $script:GoAst = [System.Management.Automation.Language.Parser]::ParseFile($script:GoPath, [ref]$tk, [ref]$er)
    $script:GoErr = $er
    $script:GoTop = @($script:GoAst.EndBlock.Statements)
    function Get-GoFunctionText([string[]]$Names) {
        $t = @($script:GoTop | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Names -contains $_.Name } | ForEach-Object { $_.Extent.Text })
        if ($t.Count -ne $Names.Count) { throw ('Funktionen nicht (eindeutig) in go.ps1: ' + ($Names -join ', ')) }
        return ($t -join "`n")
    }
}

Describe 'go 2.7.19: Importfehler 806 und 808 in Klartext' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-ImportErrorText', 'Split-NextStep', 'Get-EndText', 'Format-EndLines', 'Get-EndLines')))
    }
    It '806 per Code: alter Eintrag, Schritt im Setup unter Status' {
        $r = Get-ImportErrorText '806' 'ZtdDeviceAlreadyAssigned'
        $r.Nr | Should -Be '806'
        $r.Was | Should -Match 'schon in Autopilot'
        $r.Tun | Should -Match '"6\. Status"'
        $r.Tun | Should -Match 'Autopilot-Eintrag löschen \.\.\.'
        $r.Tun | Should -Match 'aus der Liste verschwunden'
        $r.Tun | Should -Match 'bis zu 30 Minuten'
        $r.Tun | Should -Not -Match 'einige Minuten'
        $r.Tun | Should -Match 'D:\\go'
        $r.Tun | Should -Match 'Admin'
    }
    It '806 nur per Name (Code fehlt oder 0) wird erkannt' {
        (Get-ImportErrorText '' 'ZtdDeviceAlreadyAssigned').Nr | Should -Be '806'
        (Get-ImportErrorText '0' 'ZtdDeviceAlreadyAssigned').Nr | Should -Be '806'
    }
    It '808 per Code: andere Organisation, nicht selbst loesbar, Admin verstaendigen' {
        $r = Get-ImportErrorText '808' 'ZtdDeviceAssignedToOtherTenant'
        $r.Nr | Should -Be '808'
        $r.Was | Should -Match 'anderen Organisation'
        $r.Tun | Should -Match 'nicht selbst'
        $r.Tun | Should -Match 'Admin'
        $r.Tun | Should -Match 'Händler oder Vorbesitzer'
        $r.Tun | Should -Not -Match 'D:\\go'
    }
    It '808 nur per Name wird erkannt und nicht mit 806 verwechselt' {
        (Get-ImportErrorText '' 'ZtdDeviceAssignedToOtherTenant').Nr | Should -Be '808'
        (Get-ImportErrorText '808' 'ZtdDeviceAlreadyAssigned').Nr | Should -Be '808'
    }
    It 'der rohe Code und Name bleiben im Text und im Log sichtbar' {
        foreach ($c in @(@('806', 'ZtdDeviceAlreadyAssigned'), @('808', 'ZtdDeviceAssignedToOtherTenant'))) {
            $r = Get-ImportErrorText $c[0] $c[1]
            $r.Was | Should -Match ([regex]::Escape($c[1] + ' ' + $c[0]))
            $r.Log | Should -Match ([regex]::Escape($c[0]))
            $r.Log | Should -Match ([regex]::Escape($c[1]))
        }
        (Get-ImportErrorText '806' '').Was | Should -Match '\(Fehler 806\)'
    }
    It 'andere Codes und leere Werte liefern nichts (Verhalten wie bisher)' {
        Get-ImportErrorText '801' 'ZtdDeviceDuplicated' | Should -BeNullOrEmpty
        Get-ImportErrorText '999' 'Unknown' | Should -BeNullOrEmpty
        Get-ImportErrorText '' '' | Should -BeNullOrEmpty
        Get-ImportErrorText '0' '' | Should -BeNullOrEmpty
        Get-ImportErrorText $null $null | Should -BeNullOrEmpty
        Get-ImportErrorText '8060' '' | Should -BeNullOrEmpty
    }
    It 'Abschlussbild: Was und Tun kommen unveraendert an, Rot heisst nicht zurueckgesetzt' {
        foreach ($c in '806', '808') {
            $r = Get-ImportErrorText $c ''
            $sp = Split-NextStep $r.Was
            $sp[0] | Should -Be $r.Was
            $e = Get-EndText 'Fehler' $sp[0] $r.Tun
            $e.Was | Should -Be $r.Was
            $e.Tun | Should -Be $r.Tun
            $e.Jetzt | Should -Match 'nicht zurückgesetzt'
            $l = @(Format-EndLines $e 40)
            $l | Should -Contain 'Was ist passiert:'
            $l | Should -Contain 'Was musst du tun:'
            foreach ($x in $l) { $x.Length | Should -BeLessOrEqual 40 }
            # nichts geht beim Umbruch verloren (auch bei 30 Zeichen Breite)
            $w = @(Format-EndLines $e 30)
            foreach ($x in $w) { $x.Length | Should -BeLessOrEqual 30 }
            $i = [array]::IndexOf($w, 'Was musst du tun:')
            ((@($w[($i + 1)..($w.Count - 1)]) | ForEach-Object { $_.Trim() }) -join ' ') | Should -Be $r.Tun
        }
    }
    It 'Texte ohne Pfeile, Gedankenstriche und typografische Anfuehrungszeichen' {
        foreach ($c in '806', '808') {
            $r = Get-ImportErrorText $c 'X'
            foreach ($t in $r.Was, $r.Tun, $r.Log) {
                $t | Should -Not -Match ('[' + [char]0x2192 + [char]0x2013 + [char]0x2014 + [char]0x201E + [char]0x201C + [char]0x201D + [char]0x2026 + ']')
            }
        }
    }
}

Describe 'go 2.7.19: Einbau im Import' {
    It 'go.ps1 parst ohne Fehler' {
        @($script:GoErr).Count | Should -Be 0
    }
    It 'Get-ImportErrorText ist vor der Verwendung definiert' {
        $def = $script:GoText.IndexOf('function Get-ImportErrorText')
        $use = $script:GoText.IndexOf('$ie = Get-ImportErrorText $ec $en')
        $def | Should -BeGreaterThan -1
        $use | Should -BeGreaterThan $def
    }
    It 'bei Status error: Import-Eintrag loeschen, Klartext mit Log und eigenem Schritt, sonst allgemeiner Fehler' {
        $m = [regex]::Match($script:GoText, "\n    if \(\`$state -eq 'error'\) \{\r?\n(?s:.*?)\r?\n    \}")
        $m.Success | Should -BeTrue
        $b = $m.Value
        $b | Should -Match 'Method DELETE'
        $b | Should -Match ([regex]::Escape('if ($ie) { Log $ie.Log; Fail $ie.Was -Tun $ie.Tun }'))
        $b | Should -Match ([regex]::Escape("Fail ('Microsoft meldet einen Import-Fehler: ' + `$en + ' (' + `$ec + '). Nochmal D:\go, sonst Foto an den Admin.')"))
        $b.IndexOf('Get-ImportErrorText') | Should -BeLessThan $b.IndexOf("Fail ('Microsoft meldet")
    }
}

# ---------- Bericht an den Admin (Teams-Workflow-Webhook) ----------
# Nie ein echter Webhook: alle Adressen sind kuenstlich (example.invalid), Invoke-WebRequest ist immer ersetzt.
Describe 'go 2.7.19: Bericht an den Admin' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-ReadableColor', 'Get-EndText', 'Test-WebhookUrl', 'Get-ReportSecrets', 'Protect-ReportText', 'Get-SafeFileName', 'New-ReportCard', 'Send-TeamsCard', 'Get-OutboxDir', 'Limit-Outbox', 'Save-OutboxReport', 'Get-ReportFooter', 'Send-Outbox', 'Get-DeviceReportLines', 'New-GoReport', 'Send-GoReport', 'Write-ReportLine')))
        function Log([string]$Msg) { $script:LogLines.Add($Msg) }
        $script:Ver = '2.7.19'; $script:StepTotal = 6
        $script:ReportTimeoutSec = 8; $script:ReportMaxBytes = 24000; $script:ReportLogLines = 50; $script:ReportLogSep = "`n`n"
        $script:OutboxKeepDays = 30; $script:OutboxMaxFiles = 50; $script:OutboxSendMax = 5
        $script:OldHook = 'https://firma.' + 'webhook' + '.office.com/webhookb2/x'   # alte Connector-Adresse, kuenstlich, zur Laufzeit zusammengesetzt
        $script:Url = 'https://example.invalid/workflows/abc/triggers/manual/paths/invoke?api-version=1&sp=x&sig=KUENSTLICHESIGNATUR0123456789'
        $script:Mak = 'ABCDE-FGHIJ-KLMNO-PQRST-UVW12'
        function New-TestCfg([string]$Hook) {
            [pscustomobject]@{ Tenant = 'Testschule'; TenantId = '11111111-2222-3333-4444-555555555555'; ClientId = '66666666-7777-8888-9999-000000000000'
                ClientSecret = 'GeheimesSecret~123456'; WlanSsid = 'TestNetz'; WlanKey = 'WlanKennwort987'; AdminPassword = 'AdminKennwort1'; Admin2Password = 'AdminKennwort2'
                EditionKey = $script:Mak; GroupTag = 'SN-2026'; TeamsWebhook = $Hook }
        }
        $script:SecretValues = @('GeheimesSecret~123456', 'WlanKennwort987', 'AdminKennwort1', 'AdminKennwort2', '11111111-2222-3333-4444-555555555555', '66666666-7777-8888-9999-000000000000', 'KUENSTLICHESIGNATUR0123456789', 'example.invalid', $script:Mak, 'eyJhbGciOiJSUzI1NiJ9')
    }
    BeforeEach {
        $script:LogLines = New-Object System.Collections.Generic.List[string]
        $script:CfgDir = Join-Path $TestDrive ('stick' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:CfgDir 'logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:CfgDir 'config.json') -Value '{}' -Encoding ASCII
        $script:LocalLog = Join-Path $script:CfgDir 'HUPilot.log'
        $logLines = @(1..80 | ForEach-Object { '2026-11-14 10:00:00  [    1s]  Zeile ' + $_ }) + @(
            'Token: eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXI', 'client_secret=GeheimesSecret~123456', 'WLAN WlanKennwort987', 'Admin AdminKennwort1 / AdminKennwort2',
            ('Tenant 11111111-2222-3333-4444-555555555555 App 66666666-7777-8888-9999-000000000000'), ('MAK ' + $script:Mak), ('Adresse ' + $script:Url), 'letzte Zeile')
        Set-Content -LiteralPath $script:LocalLog -Value $logLines -Encoding UTF8
        $script:cfg = New-TestCfg $script:Url
        $script:Serial = 'SN/123 45'
        $script:tok = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXI'
        $script:ReportDone = $false; $script:NetOk = $true; $script:ReportLevels = @('Error')
        $script:StepNo = 3; $script:StepName = 'Anmelden'
        $script:Bodies = New-Object System.Collections.Generic.List[string]
        Mock Get-DeviceReportLines { @{ Hw = 'Testhersteller Testmodell'; Win = 'Core Build 26100.1' } }
    }

    It 'Adresse: leer, http, alte Connector-Adresse, kein URI = ungueltig; https = gueltig' {
        Test-WebhookUrl '' | Should -Be 'leer'
        Test-WebhookUrl '   ' | Should -Be 'leer'
        Test-WebhookUrl 'http://example.invalid/x' | Should -Match 'https'
        Test-WebhookUrl $script:OldHook | Should -Match 'Office-365'
        Test-WebhookUrl 'kein uri' | Should -Not -BeNullOrEmpty
        Test-WebhookUrl $script:Url | Should -Be ''
        foreach ($u in '', 'http://example.invalid/x', $script:OldHook) { (Test-WebhookUrl $u) | Should -Not -Match 'example|office\.com/' }
    }
    It 'Bereinigung: Secret, Token, WLAN, Admin-Kennwoerter, Adresse, Tenant- und App-ID weg, MAK nur letzte 5 Zeichen' {
        $sec = Get-ReportSecrets $script:cfg $script:tok
        $t = Protect-ReportText ((Get-Content -LiteralPath $script:LocalLog -Encoding UTF8) -join "`n") $sec
        foreach ($s in $script:SecretValues) { $t | Should -Not -Match ([regex]::Escape($s)) }
        $t | Should -Match ([regex]::Escape('*****-UVW12'))
        $t | Should -Match 'letzte Zeile'
        Protect-ReportText 'https://irgendwo.example/x?a=1&sig=abcdef123' @() | Should -Be '(Adresse entfernt)'
        Protect-ReportText 'Authorization: Bearer abc.def.ghi' @() | Should -Not -Match 'abc\.def'
        Protect-ReportText 'Seriennummer PF3T9PAN ok' $sec | Should -Be 'Seriennummer PF3T9PAN ok'
    }
    It 'Karte: Adaptive Card 1.4, Titel rot, Zeilen, Log in Festbreite, Fusszeile' {
        $j = New-ReportCard -Title 'HUPilot: Fehler am Gerät X' -Lines @('a', '', 'b') -Log @('l1', 'l2') -Level 'Error' -Footer 'Testschule  |  14.11.2026 10:00  |  HUPilot go 2.7.19'
        $m = $j | ConvertFrom-Json
        $m.type | Should -Be 'message'
        $m.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $c = $m.attachments[0].content
        $c.version | Should -Be '1.4'
        $c.body[0].color | Should -Be 'Attention'
        $c.body[0].text | Should -Be 'HUPilot: Fehler am Gerät X'
        @($c.body | Where-Object { $_.text -eq '' }).Count | Should -Be 0
        $c.body[1].text | Should -Be 'a'; $c.body[2].text | Should -Be 'b'
        $c.body[3].fontType | Should -Be 'Monospace'; $c.body[3].wrap | Should -BeTrue
        $c.body[3].text | Should -Be ("l1`n`nl2")
        $c.body[4].isSubtle | Should -BeTrue
        $c.body[4].text | Should -Match 'HUPilot go 2\.7\.19$'
    }
    It 'Karte: langes Log wird von vorne gekuerzt, unter 24 KB, letzte Zeile bleibt, "(gekürzt)" steht vorne' {
        $log = @(1..300 | ForEach-Object { ('Zeile {0:000} ' -f $_) + ('ä' * 380) })
        $j = New-ReportCard -Title 'T' -Lines @('x') -Log $log -Footer 'F'
        [Text.Encoding]::UTF8.GetByteCount($j) | Should -BeLessThan 24000
        $b = ($j | ConvertFrom-Json).attachments[0].content.body
        $lg = @($b | Where-Object { $_.fontType -eq 'Monospace' })[0].text
        $lg | Should -Match '^\(gekürzt\)'
        $lg | Should -Match 'Zeile 300'
        $lg | Should -Not -Match 'Zeile 001 '
        ($b | Select-Object -Last 1).text | Should -Be 'F'
        (New-ReportCard -Title 'T' -Log @('a')) | Should -Not -Match 'gekürzt'
    }
    It 'Senden: ungueltige Adresse liefert Grund, Fehler wirft nie und verraet die Adresse nicht' {
        Mock Invoke-WebRequest { throw ('Verbindung zu ' + $Uri + ' fehlgeschlagen') }
        { Send-TeamsCard $script:Url '{}' 8 } | Should -Not -Throw
        $r = Send-TeamsCard $script:Url '{}' 8
        $r | Should -Match 'fehlgeschlagen'
        $r | Should -Not -Match 'KUENSTLICHESIGNATUR|example\.invalid'
        Send-TeamsCard $script:OldHook '{}' 8 | Should -Match 'ungültig'
        Send-TeamsCard '' '{}' 8 | Should -Match 'ungültig'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
    }
    It 'Senden: Body als UTF-8-Bytes, POST, Zeitlimit 8 s' {
        Mock Invoke-WebRequest { $script:Bodies.Add([Text.Encoding]::UTF8.GetString($Body)); [pscustomobject]@{ StatusCode = 202 } }
        Send-TeamsCard $script:Url '{"t":"Gerät"}' 8 | Should -Be ''
        $script:Bodies[0] | Should -Be '{"t":"Gerät"}'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $TimeoutSec -eq 8 -and $UseBasicParsing -and $Body -is [byte[]] -and $ContentType -match 'utf-8' }
    }
    It 'Ablage: Dateiname, UTF-8 ohne BOM, Felder nach Vertrag, Listen auch mit einem Eintrag' {
        $now = [datetime]::new(2026, 11, 14, 9, 5, 7, [DateTimeKind]::Utc)
        $p = Save-OutboxReport (Get-OutboxDir) @{ Level = 'Error'; Title = 'T'; Lines = @('nur eine'); Log = @('l') } 'SN/123 45' $now
        $p | Should -Not -BeNullOrEmpty
        (Split-Path $p -Leaf) | Should -Be ($now.ToLocalTime().ToString('yyyyMMdd-HHmmss') + '_SN_123_45.json')
        $bytes = [IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $raw = [Text.Encoding]::UTF8.GetString($bytes)
        $raw | Should -Match '"lines":\s*\[\s*"nur eine"\s*\]'
        $raw | Should -Match '"log":\s*\[\s*"l"\s*\]'
        $o = $raw | ConvertFrom-Json
        $o.v | Should -Be 1; $o.created | Should -Be '2026-11-14T09:05:07Z'; $o.source | Should -Be 'go'; $o.level | Should -Be 'Error'; $o.title | Should -Be 'T'
        @($o.PSObject.Properties.Name) -join ',' | Should -Be 'v,created,source,level,title,lines,log'
    }
    It 'Ablage: ohne Stick (keine config.json) oder nicht beschreibbar = leer, wirft nicht' {
        Remove-Item -LiteralPath (Join-Path $script:CfgDir 'config.json')
        { Save-OutboxReport (Get-OutboxDir) @{ Title = 'T' } 'X' } | Should -Not -Throw
        Save-OutboxReport (Get-OutboxDir) @{ Title = 'T' } 'X' | Should -Be ''
        Save-OutboxReport 'Q:\gibt\es\nicht\logs\outbox' @{ Title = 'T' } 'X' | Should -Be ''
    }
    It 'Verwerfen: aelter als 30 Tage weg, dann hoechstens 50 Dateien, aelteste zuerst' {
        $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $now = [datetime]::UtcNow
        for ($i = 0; $i -lt 60; $i++) { $f = Join-Path $d ('f{0:00}.json' -f $i); Set-Content -LiteralPath $f -Value '{}'; (Get-Item $f).LastWriteTimeUtc = $now.AddDays(-$i * 0.6) }
        $n = Limit-Outbox $d 30 50 $now
        $left = @(Get-ChildItem $d -Filter *.json | Sort-Object Name)
        $left.Count | Should -Be 50
        $n | Should -Be 10
        $left[0].Name | Should -Be 'f00.json'
        $left[-1].Name | Should -Be 'f49.json'
        Limit-Outbox (Join-Path $d 'fehlt') | Should -Be 0
    }
    It 'Verwerfen: mehr als 50 junge Dateien, die aeltesten gehen zuerst' {
        $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $now = [datetime]::UtcNow
        for ($i = 0; $i -lt 53; $i++) { $f = Join-Path $d ('g{0:00}.json' -f $i); Set-Content -LiteralPath $f -Value '{}'; (Get-Item $f).LastWriteTimeUtc = $now.AddMinutes(-$i) }
        Limit-Outbox $d 30 50 $now | Should -Be 3
        foreach ($n in 'g50.json', 'g51.json', 'g52.json') { Test-Path (Join-Path $d $n) | Should -BeFalse }
        Test-Path (Join-Path $d 'g49.json') | Should -BeTrue
    }
    It 'Nachsenden: hoechstens 5, aelteste zuerst, gesendete Dateien geloescht, Karte aus der Datei' {
        Mock Invoke-WebRequest { $script:Bodies.Add([Text.Encoding]::UTF8.GetString($Body)); [pscustomobject]@{ StatusCode = 202 } }
        $base = [datetime]::UtcNow.AddHours(-10)
        for ($i = 0; $i -lt 7; $i++) {
            $p = Save-OutboxReport (Get-OutboxDir) @{ Level = 'Error'; Title = ('Bericht ' + $i); Lines = @('z'); Log = @('l') } ('S' + $i) $base.AddMinutes($i)
            (Get-Item $p).LastWriteTimeUtc = $base.AddMinutes($i)
        }
        $n = Send-Outbox (Get-OutboxDir) $script:Url 5 8 @() 'Testschule'
        $n | Should -Be 5
        @(Get-ChildItem (Get-OutboxDir) -Filter *.json).Count | Should -Be 2
        ($script:Bodies[0] | ConvertFrom-Json).attachments[0].content.body[0].text | Should -Be 'Bericht 0'
        ($script:Bodies[4] | ConvertFrom-Json).attachments[0].content.body[0].text | Should -Be 'Bericht 4'
        ($script:Bodies[0] | ConvertFrom-Json).attachments[0].content.body[-1].text | Should -Match '^Testschule  \|  '
    }
    It 'Nachsenden: nach dem ersten Fehlschlag Schluss, Datei bleibt, wirft nicht; ungueltige Adresse sendet nichts' {
        Mock Invoke-WebRequest { throw 'offline' }
        for ($i = 0; $i -lt 3; $i++) { [void](Save-OutboxReport (Get-OutboxDir) @{ Level = 'Error'; Title = 'B'; Lines = @(); Log = @() } ('S' + $i) ([datetime]::UtcNow.AddMinutes(-$i))) }
        { Send-Outbox (Get-OutboxDir) $script:Url 5 8 } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        @(Get-ChildItem (Get-OutboxDir) -Filter *.json).Count | Should -Be 3
        Send-Outbox (Get-OutboxDir) $script:OldHook 5 8 | Should -Be 0
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        ($script:LogLines -join ' ') | Should -Not -Match 'KUENSTLICHESIGNATUR|example\.invalid'
    }
    It 'Nachsenden: kaputte Datei bleibt liegen, die anderen gehen raus' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 202 } }
        $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d '20260101-000000_kaputt.json') -Value 'kein json'
        (Get-Item (Join-Path $d '20260101-000000_kaputt.json')).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-1)
        [void](Save-OutboxReport $d @{ Level = 'Error'; Title = 'B'; Lines = @('z'); Log = @() } 'S')
        Send-Outbox $d $script:Url 5 8 | Should -Be 1
        Test-Path (Join-Path $d '20260101-000000_kaputt.json') | Should -BeTrue
    }
    It 'Fehler mit Internet: genau ein Bericht je Lauf, Inhalt nach Vertrag, nichts Geheimes in der Karte' {
        Mock Invoke-WebRequest { $script:Bodies.Add([Text.Encoding]::UTF8.GetString($Body)); [pscustomobject]@{ StatusCode = 202 } }
        $e = Get-EndText 'Fehler' 'Grund X.' 'Mach Y.'
        $r = Send-GoReport $e 'Error'
        $r.Text | Should -Be 'Bericht an den Admin gesendet.'
        Send-GoReport $e 'Error' | Should -BeNullOrEmpty
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        $c = ($script:Bodies[0] | ConvertFrom-Json).attachments[0].content
        $c.body[0].text | Should -Be 'HUPilot: Fehler am Gerät SN/123 45'
        $t = @($c.body | ForEach-Object { $_.text })
        $t | Should -Contain 'Anzeigename: Testschule'
        $t | Should -Contain 'Gerät: Testhersteller Testmodell'
        $t | Should -Contain 'Windows: Core Build 26100.1'
        $t | Should -Contain 'HUPilot go: 2.7.19'
        $t | Should -Contain 'Schritt 3 von 6: Anmelden'
        $t | Should -Contain 'Was ist passiert: Grund X.'
        $t | Should -Contain 'Was passiert jetzt: Nichts, das Gerät wurde nicht zurückgesetzt.'
        $t | Should -Contain 'Was musst du tun: Mach Y.'
        $t | Should -Contain 'Tag: SN-2026'
        $lg = @($c.body | Where-Object { $_.fontType -eq 'Monospace' })[0].text
        $lg | Should -Match 'letzte Zeile'
        $lg | Should -Not -Match 'Zeile 30\b'
        foreach ($s in $script:SecretValues) { $script:Bodies[0] | Should -Not -Match ([regex]::Escape($s)) }
        $script:Bodies[0] | Should -Match ([regex]::Escape('*****-UVW12'))
        @(Get-ChildItem (Join-Path $script:CfgDir 'logs') -Recurse -Filter *.json).Count | Should -Be 0
        ($script:LogLines -join ' ') | Should -Not -Match 'KUENSTLICHESIGNATUR|example\.invalid'
    }
    It 'Fehler, Senden scheitert: Datei am Stick, bereinigt, Zeile "gespeichert", wirft nicht' {
        Mock Invoke-WebRequest { throw ('Zeitlimit bei ' + $Uri) }
        { $script:r1 = Send-GoReport (Get-EndText 'Fehler' 'Grund.' 'Tun.') 'Error' } | Should -Not -Throw
        $script:r1.Text | Should -Be 'Bericht am Stick gespeichert, wird beim nächsten Mal mit Internet gesendet.'
        $f = @(Get-ChildItem (Join-Path $script:CfgDir 'logs\outbox') -Filter *.json)
        $f.Count | Should -Be 1
        $raw = [IO.File]::ReadAllText($f[0].FullName)
        foreach ($s in $script:SecretValues) { $raw | Should -Not -Match ([regex]::Escape($s)) }
        ($raw | ConvertFrom-Json).title | Should -Be 'HUPilot: Fehler am Gerät SN/123 45'
        ($script:LogLines -join ' ') | Should -Not -Match 'KUENSTLICHESIGNATUR|example\.invalid'
    }
    It 'Fehler ohne Internet: kein Sendeversuch, Datei am Stick' {
        Mock Invoke-WebRequest { throw 'darf nicht' }
        $script:NetOk = $false
        (Send-GoReport (Get-EndText 'Fehler' 'G.' 'T.') 'Error').Text | Should -Match 'am Stick gespeichert'
        Should -Invoke Invoke-WebRequest -Times 0
        @(Get-ChildItem (Join-Path $script:CfgDir 'logs\outbox') -Filter *.json).Count | Should -Be 1
    }
    It 'Fehler ohne Internet und ohne Stick: stiller Verzicht mit Logzeile, keine Zeile am Bildschirm' {
        Mock Invoke-WebRequest { throw 'darf nicht' }
        $script:NetOk = $false
        Remove-Item -LiteralPath (Join-Path $script:CfgDir 'config.json')
        Send-GoReport (Get-EndText 'Fehler' 'G.' 'T.') 'Error' | Should -BeNullOrEmpty
        ($script:LogLines -join ' ') | Should -Match 'verworfen'
    }
    It 'Ohne Adresse: nichts, keine Zeile; ungueltige Adresse: graue Hinweiszeile, kein Senden' {
        Mock Invoke-WebRequest { throw 'darf nicht' }
        $script:cfg = New-TestCfg ''
        Send-GoReport (Get-EndText 'Fehler') 'Error' | Should -BeNullOrEmpty
        $script:ReportDone | Should -BeFalse
        $script:cfg = New-TestCfg $script:OldHook
        $r = Send-GoReport (Get-EndText 'Fehler') 'Error'
        $r.Color | Should -Be 'Gray'
        $r.Text | Should -Match 'ungültig'
        $r.Text | Should -Not -Match 'webhook'
        $script:cfg = $null; $script:ReportDone = $false
        Send-GoReport (Get-EndText 'Fehler') 'Error' | Should -BeNullOrEmpty
        Should -Invoke Invoke-WebRequest -Times 0
    }
    It 'Stufen: nur Error loest aus, Warning erst nach Erweiterung der Liste (ohne Umbau)' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 202 } }
        Send-GoReport (Get-EndText 'Abbruch' 'X') 'Warning' | Should -BeNullOrEmpty
        Should -Invoke Invoke-WebRequest -Times 0
        $script:ReportLevels = @('Error', 'Warning')
        (Send-GoReport (Get-EndText 'Abbruch' 'X') 'Warning').Text | Should -Be 'Bericht an den Admin gesendet.'
    }
    It 'unerwarteter Fehler im Bericht wirft nie' {
        Mock Get-DeviceReportLines { throw 'kaputt' }
        { Send-GoReport (Get-EndText 'Fehler') 'Error' } | Should -Not -Throw
    }
}

Describe 'go 2.7.19: Einbau des Berichts' {
    BeforeAll {
        $script:FailText = (Get-GoFunctionText 'Fail')
        $script:FailResetAst = $script:GoAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Fail-Reset' }, $true) | Select-Object -First 1
    }
    It 'Fail: Bericht nach dem roten Bild und vor Wait-Close, Exitcode bleibt 1' {
        $t = $script:FailText
        $t | Should -Match ([regex]::Escape("Write-ReportLine (Send-GoReport (Get-EndText 'Fehler' `$sp[0] `$Tun) 'Error')"))
        $t.IndexOf('Banner ') | Should -BeLessThan $t.IndexOf('Send-GoReport')
        $t.IndexOf('Send-GoReport') | Should -BeLessThan $t.IndexOf('Wait-Close')
        $t | Should -Match 'exit 1'
    }
    It 'Fail-Reset: Bericht nach dem roten Bild und vor Wait-Close, Exitcode bleibt 1' {
        $t = $script:FailResetAst.Extent.Text
        $t.IndexOf('Banner ') | Should -BeLessThan $t.IndexOf('Send-GoReport')
        $t.IndexOf('Send-GoReport') | Should -BeLessThan $t.IndexOf('Wait-Close')
        $t | Should -Match "Get-EndText 'FehlerReset'"
        $t | Should -Match 'exit 1'
    }
    It 'Bericht nur aus Fail und Fail-Reset, nicht aus gelben oder gruenen Abschluessen' {
        @([regex]::Matches($script:GoText, 'Send-GoReport \(')).Count | Should -Be 2
        foreach ($n in 'Stop-ByUser', 'Save-Offline') {
            ($script:GoAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $n }, $true) | Select-Object -First 1).Extent.Text | Should -Not -Match 'Send-GoReport'
        }
    }
    It 'Internet OK setzt NetOk, danach Nachsenden; alle Bericht-Funktionen vor Fail definiert' {
        $i = $script:GoText.IndexOf("Say 'Internet OK' 'Green'")
        $script:GoText.IndexOf('$script:NetOk = $true') | Should -BeGreaterThan $i
        $script:GoText.IndexOf('Send-Outbox (Get-OutboxDir)') | Should -BeGreaterThan $i
        $f = $script:GoText.IndexOf('function Fail {')
        foreach ($n in 'Test-WebhookUrl', 'Protect-ReportText', 'New-ReportCard', 'Send-TeamsCard', 'Save-OutboxReport', 'Send-Outbox', 'Send-GoReport', 'Write-ReportLine') {
            $script:GoText.IndexOf('function ' + $n + ' {') | Should -BeLessThan $f -Because $n
        }
    }
    It 'Show-Step merkt den Schritt fuer den Bericht' {
        (Get-GoFunctionText 'Show-Step') | Should -Match ([regex]::Escape('$script:StepNo = $N'))
    }
    It 'go.ps1 und diag.ps1 enthalten keine Webhook-Hosts und keine Signatur' {
        foreach ($p in $script:GoPath, (Join-Path $script:Root 'Stick\HUPilot\diag.ps1')) {
            $t = Get-Content -LiteralPath $p -Raw -Encoding UTF8
            $t | Should -Not -Match 'logic\.azure\.com'
            $t | Should -Not -Match 'sig='
        }
    }
    It 'diag.ps1: parst, prueft den Host der Teams-Adresse und gibt die Adresse nie aus' {
        $dp = Join-Path $script:Root 'Stick\HUPilot\diag.ps1'
        $tk = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($dp, [ref]$tk, [ref]$er)
        @($er).Count | Should -Be 0
        $t = Get-Content -LiteralPath $dp -Raw -Encoding UTF8
        $t | Should -Match 'TeamsWebhook'
        $t | Should -Match ([regex]::Escape("Teams-Bericht ' + `$x.Host"))
        $t | Should -Not -Match 'Write-Host[^\r\n]*\$tw\b'
    }
    It 'im Repo steht keine echte Webhook-Adresse (nur kuenstliche Werte in Tests)' {
        $files = @(Get-ChildItem -LiteralPath $script:Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Extension -in '.ps1', '.psm1', '.json', '.md', '.html', '.yml', '.cmd', '.txt', '.xaml' })
        $files.Count | Should -BeGreaterThan 5
        $hit = @()
        foreach ($f in $files) {
            $t = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $t) { continue }
            foreach ($m in [regex]::Matches($t, 'https://[^\s"''<>]+[?&]sig=[A-Za-z0-9%_-]{16,}')) { if ($m.Value -notmatch 'example\.invalid') { $hit += ($f.Name + ': ' + $m.Value.Substring(0, [math]::Min(40, $m.Value.Length))) } }
            if ($f.FullName -notmatch '\\\.github\\tests\\' -and $t -match 'https://[^\s"''<>]*logic\.azure\.com/[^\s"''<>]*sig=') { $hit += $f.Name }
        }
        $hit | Should -BeNullOrEmpty
    }
}
