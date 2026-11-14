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
# Nie ein echter Webhook: alle Adressen sind kuenstlich (example.invalid), das Senden (Invoke-ReportPost) ist immer ersetzt.
Describe 'go 2.7.19: Bericht an den Admin' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-ReadableColor', 'Get-EndText', 'Test-WebhookUrl', 'Get-ReportSecrets', 'Protect-ReportText', 'Get-SafeFileName', 'Get-CutText', 'Get-ReportLog', 'New-ReportCard', 'Invoke-ReportPost', 'Send-TeamsCard', 'Get-OutboxDir', 'Limit-Outbox', 'Save-OutboxReport', 'Read-OutboxFile', 'Get-ReportFooter', 'Send-Outbox', 'Get-DeviceReportLines', 'New-GoReport', 'Send-GoReport', 'Write-ReportLine')))
        function Log([string]$Msg) { $script:LogLines.Add($Msg) }
        $script:Ver = '2.7.19'; $script:StepTotal = 6
        $script:ReportTimeoutSec = 8; $script:ReportMaxBytes = 24000; $script:ReportLogLines = 50; $script:ReportLogRead = 400; $script:ReportLogSep = "`n`n"
        $script:ReportTitleMax = 200; $script:ReportLinesMax = 30; $script:ReportLineLen = 600; $script:ReportLogLen = 400
        $script:OutboxKeepDays = 30; $script:OutboxMaxFiles = 50; $script:OutboxSendMax = 5; $script:OutboxFileMaxBytes = 262144
        # alte Connector-Adresse: das Muster steht in go.ps1 in einer Variablen, die Tests pruefen die Logik mit einem erfundenen Host
        $script:ReportOldHookHostRx = '(?i)(^|\.)alt\.example\.invalid$'
        $script:OldHook = 'https://firma.alt.example.invalid/webhookb2/x'
        # kuenstliche Adresse, zur Laufzeit zusammengesetzt (keine vollstaendige Webhook-Adresse als Literal im Repo)
        $script:Url = 'https://example.invalid/workflows/abc/triggers/manual/paths/invoke?api-version=1&sp=x&' + 'sig' + '=KUENSTLICHESIGNATUR0123456789'
        $script:Mak = 'ABCDE-FGHIJ-KLMNO-PQRST-UVW12'
        function New-TestCfg([string]$Hook) {
            [pscustomobject]@{ Tenant = 'Testschule'; TenantId = '11111111-2222-3333-4444-555555555555'; ClientId = '66666666-7777-8888-9999-000000000000'
                ClientSecret = 'GeheimesSecret~123456'; WlanSsid = 'TestNetz'; WlanKey = 'WlanKennwort987'; AdminPassword = 'AdminKennwort1'; Admin2Password = 'AdminKennwort2'
                EditionKey = $script:Mak; GroupTag = 'SN-2026'; TeamsWebhook = $Hook }
        }
        $script:SecretValues = @('GeheimesSecret~123456', 'WlanKennwort987', 'AdminKennwort1', 'AdminKennwort2', '11111111-2222-3333-4444-555555555555', '11111111222233334444555555555555', '66666666-7777-8888-9999-000000000000', 'KUENSTLICHESIGNATUR0123456789', 'example.invalid', $script:Mak, 'eyJhbGciOiJSUzI1NiJ9')
        function New-Box([int]$Count, [string]$Prefix = 'B', [int]$MinutesApart = 1) {
            # $Count lesbare Berichte, der erste ist der aelteste
            $base = [datetime]::UtcNow.AddHours(-20)
            # direkt schreiben, nicht ueber Save-OutboxReport (das raeumt nach jedem Speichern auf)
            $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
            for ($i = 0; $i -lt $Count; $i++) {
                $w = $base.AddMinutes($i * $MinutesApart)
                $p = Join-Path $d ($w.ToString('yyyyMMdd-HHmmss') + '_S' + $i + '.json')
                [IO.File]::WriteAllText($p, ('{"v":1,"created":"' + $w.ToString('yyyy-MM-ddTHH:mm:ssZ') + '","source":"go","level":"Error","title":"' + ('{0} {1:00}' -f $Prefix, $i) + '","lines":["z"],"log":["l"]}'))
                (Get-Item $p).LastWriteTimeUtc = $w
            }
        }
        function Get-SentTitles { @($script:Bodies | ForEach-Object { ($_ | ConvertFrom-Json).attachments[0].content.body[0].text }) }
    }
    BeforeEach {
        $script:LogLines = New-Object System.Collections.Generic.List[string]
        $script:CfgDir = Join-Path $TestDrive ('stick' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:CfgDir 'logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:CfgDir 'config.json') -Value '{}' -Encoding ASCII
        $script:LocalLog = Join-Path $script:CfgDir 'HUPilot.log'
        $logLines = @(1..80 | ForEach-Object { '2026-11-14 10:00:00  [    1s]  Zeile ' + $_ }) + @(
            'Token: eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXI', 'client_secret=GeheimesSecret~123456', 'WLAN WlanKennwort987', 'Admin AdminKennwort1 / AdminKennwort2',
            ('Tenant 11111111-2222-3333-4444-555555555555 App 66666666-7777-8888-9999-000000000000'), 'Host 11111111222233334444555555555555.environment.example', ('MAK ' + $script:Mak), ('Adresse ' + $script:Url),
            "Der Remotename konnte nicht aufgelöst werden: 'example.invalid'", 'letzte Zeile')
        Set-Content -LiteralPath $script:LocalLog -Value $logLines -Encoding UTF8
        $script:cfg = New-TestCfg $script:Url
        $script:Serial = 'SN/123 45'
        $script:tok = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXI'
        $script:ReportDone = $false; $script:ReportNetOk = $true
        $script:ReportAnlaesse = @{ Fehler = 'Error'; FehlerReset = 'Error'; ResetNichtGestartet = 'Error'; SecretAbgelaufen = 'Warning'; SecretFalsch = 'Warning'; KeinProfilEnde = 'Warning' }
        $script:StepNo = 3; $script:StepName = 'Anmelden'
        $script:Bodies = New-Object System.Collections.Generic.List[string]
        Mock Get-DeviceReportLines { @{ Hw = 'Testhersteller Testmodell'; Win = 'Core Build 26100.1' } }
        Mock Invoke-ReportPost { $script:Bodies.Add([Text.Encoding]::UTF8.GetString($Body)); [pscustomobject]@{ StatusCode = 202 } }
    }

    It 'Muster der alten Connector-Adresse steht als Variable in go.ps1 und wird in Test-WebhookUrl benutzt' {
        [regex]::Match($script:GoText, "(?m)^\`$script:ReportOldHookHostRx = '([^']+)'").Groups[1].Value | Should -Be '(?i)(^|\.)webhook\.office\.com$'
        (Get-GoFunctionText 'Test-WebhookUrl') | Should -Match '\$x\.Host -match \$script:ReportOldHookHostRx'
    }
    It 'Log im Bericht: nur der aktuelle Lauf, gleiche Meldungen einmal mit Zaehler, hoechstens Max Zeilen' {
        $p = { param($s, $m) '2026-11-14 16:55:{0:00}  [{1,5:N0}s]  {2}' -f ($s % 60), $s, $m }
        $in = @((& $p 1 'alter Lauf'), (& $p 2 '===== START go.ps1 v2.7.18 ====='), (& $p 3 'noch alt'),
            (& $p 4 '===== START go.ps1 v2.7.19 ====='), (& $p 5 'Schritt 1'), (& $p 6 'Internet-Test: X'), (& $p 16 'Uhr: Y'), (& $p 17 'Internet-Test: X'), (& $p 27 'Internet-Test: X'), (& $p 28 'FEHLER: Z'))
        $r = @(Get-ReportLog $in 50)
        $r.Count | Should -Be 5
        $r[0] | Should -Match 'START go\.ps1 v2\.7\.19'
        ($r -join '|') | Should -Not -Match 'alter Lauf|noch alt|2\.7\.18'
        $r[2] | Should -Match 'Internet-Test: X  \(3-mal\)$'
        $r[3] | Should -Match 'Uhr: Y$'
        $r[4] | Should -Match 'FEHLER: Z$'
        @(Get-ReportLog $in 2).Count | Should -Be 2
        (@(Get-ReportLog $in 2))[1] | Should -Match 'FEHLER: Z$'
        # ohne START-Zeile bleibt alles, leere Zeilen fallen weg, leer bleibt leer
        @(Get-ReportLog @('a', '', 'b') 50).Count | Should -Be 2
        @(Get-ReportLog @() 50).Count | Should -Be 0
        (Get-GoFunctionText 'Send-GoReport') | Should -Match ([regex]::Escape('Get-ReportLog @(Get-Content -LiteralPath $LocalLog -Tail $ReportLogRead'))
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
    It 'Bereinigung: Secret, Token, WLAN, Admin-Kennwoerter, Adresse, Host, Tenant-ID (auch ohne Bindestriche), App-ID weg, MAK nur letzte 5 Zeichen' {
        $sec = Get-ReportSecrets $script:cfg $script:tok
        $sec | Should -Contain 'example.invalid'
        $sec | Should -Contain '11111111222233334444555555555555'
        $t = Protect-ReportText ((Get-Content -LiteralPath $script:LocalLog -Encoding UTF8) -join "`n") $sec
        foreach ($s in $script:SecretValues) { $t | Should -Not -Match ([regex]::Escape($s)) }
        $t | Should -Match ([regex]::Escape('*****-UVW12'))
        $t | Should -Match "Remotename konnte nicht aufgelöst werden: '\*\*\*'"
        $t | Should -Match 'letzte Zeile'
        Protect-ReportText ('https://irgendwo.example/x?a=1&' + 'sig' + '=abcdef123') @() | Should -Be '(Adresse entfernt)'
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
        (New-ReportCard -Title 'T' -Level 'Warning' | ConvertFrom-Json).attachments[0].content.body[0].color | Should -Be 'Warning'
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
    It 'Karte: Titel hoechstens 200 Zeichen, hoechstens 30 Zeilen zu 600, Logzeilen 400' {
        $j = New-ReportCard -Title ('T' * 500) -Lines @(1..40 | ForEach-Object { 'Zeile ' + $_ + ' ' + ('x' * 900) }) -Log @('L' * 900) -Footer ('F' * 500)
        $b = ($j | ConvertFrom-Json).attachments[0].content.body
        $b[0].text.Length | Should -BeLessOrEqual 200
        $b[-1].text.Length | Should -BeLessOrEqual 200
        $txt = @($b | Where-Object { -not $_.fontType -and -not $_.isSubtle -and $_.text -like 'Zeile *' })
        $txt.Count | Should -BeLessOrEqual 30
        foreach ($x in $txt) { $x.text.Length | Should -BeLessOrEqual 600 }
        @($b | Where-Object { $_.text -eq '(gekürzt)' }).Count | Should -Be 1
        @($b | Where-Object { $_.fontType -eq 'Monospace' })[0].text.Length | Should -BeLessOrEqual 400
    }
    It 'Karte: reicht das Kuerzen des Logs nicht, werden die Zeilen von hinten gekuerzt, immer unter 24 KB' {
        $lines = @(1..30 | ForEach-Object { ('Zeile {0:00} ' -f $_) + ('ä' * 580) })
        $j = New-ReportCard -Title ('ä' * 300) -Lines $lines -Log @(1..50 | ForEach-Object { 'ä' * 400 }) -Footer ('ä' * 300)
        [Text.Encoding]::UTF8.GetByteCount($j) | Should -BeLessThan 24000
        $b = ($j | ConvertFrom-Json).attachments[0].content.body
        @($b | Where-Object { $_.fontType -eq 'Monospace' }).Count | Should -Be 0
        $b[1].text | Should -Match '^Zeile 01 '
        @($b | Where-Object { $_.text -like 'Zeile 30 *' }).Count | Should -Be 0
        @($b | Where-Object { $_.text -eq '(gekürzt)' }).Count | Should -Be 1
    }
    It 'Senden: Fehler wirft nie und verraet weder Adresse noch Host; ungueltige Adresse sendet nicht' {
        Mock Invoke-ReportPost { throw ("Der Remotename konnte nicht aufgelöst werden: 'example.invalid' bei " + $Url) }
        { Send-TeamsCard $script:Url '{}' 8 } | Should -Not -Throw
        $r = Send-TeamsCard $script:Url '{}' 8 (Get-ReportSecrets $script:cfg)
        $r | Should -Match 'fehlgeschlagen'
        $r | Should -Not -Match 'KUENSTLICHESIGNATUR|example\.invalid'
        Send-TeamsCard $script:OldHook '{}' 8 | Should -Match 'ungültig'
        Send-TeamsCard '' '{}' 8 | Should -Match 'ungültig'
        Should -Invoke Invoke-ReportPost -Times 2 -Exactly
    }
    It 'Senden: Body als UTF-8-Bytes, Zeitlimit 8 s; nur HTTP 2xx zaehlt, Weiterleitung = Fehlschlag' {
        Send-TeamsCard $script:Url '{"t":"Gerät"}' 8 | Should -Be ''
        $script:Bodies[0] | Should -Be '{"t":"Gerät"}'
        Should -Invoke Invoke-ReportPost -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 8 -and $Body -is [byte[]] -and $Url -eq $script:Url }
        Mock Invoke-ReportPost { [pscustomobject]@{ StatusCode = 302 } }
        Send-TeamsCard $script:Url '{}' 8 | Should -Match 'Weiterleitung'
        Mock Invoke-ReportPost { [pscustomobject]@{ StatusCode = 500 } }
        Send-TeamsCard $script:Url '{}' 8 | Should -Match 'HTTP 500'
        Mock Invoke-ReportPost { $null }
        Send-TeamsCard $script:Url '{}' 8 | Should -Match 'fehlgeschlagen'
    }
    It 'Senden im Quelltext: Modulname, ohne Weiterleitung, POST, UTF-8, Zeitlimit' {
        $t = Get-GoFunctionText 'Invoke-ReportPost'
        $t | Should -Match 'Microsoft\.PowerShell\.Utility\\Invoke-WebRequest'
        $t | Should -Match '-MaximumRedirection 0'
        $t | Should -Match '-Method Post'
        $t | Should -Match '-UseBasicParsing'
        $t | Should -Match "charset=utf-8"
        $t | Should -Match '-TimeoutSec \$TimeoutSec'
        @([regex]::Matches($script:GoText, 'Invoke-WebRequest')).Count | Should -Be @([regex]::Matches($script:GoText, 'Microsoft\.PowerShell\.Utility\\Invoke-WebRequest')).Count
        (Get-GoFunctionText 'Send-TeamsCard') | Should -Not -Match 'Invoke-WebRequest'
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
        # created im Rohtext pruefen: PowerShell 7 macht beim Einlesen ein DateTime daraus, 5.1 nicht
        $raw | Should -Match '"created":\s*"2026-11-14T09:05:07Z"'
        $o.v | Should -Be 1; $o.source | Should -Be 'go'; $o.level | Should -Be 'Error'; $o.title | Should -Be 'T'
        @($o.PSObject.Properties.Name) -join ',' | Should -Be 'v,created,source,level,title,lines,log'
    }
    It 'Ablage: ohne Stick (keine config.json) oder nicht beschreibbar = leer, wirft nicht' {
        Remove-Item -LiteralPath (Join-Path $script:CfgDir 'config.json')
        { Save-OutboxReport (Get-OutboxDir) @{ Title = 'T' } 'X' } | Should -Not -Throw
        Save-OutboxReport (Get-OutboxDir) @{ Title = 'T' } 'X' | Should -Be ''
        Save-OutboxReport 'Q:\gibt\es\nicht\logs\outbox' @{ Title = 'T' } 'X' | Should -Be ''
    }
    It 'Verwerfen: nie wegen des Alters, nur ueber 50 Dateien die aeltesten, mit Logzeile' {
        $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $now = [datetime]::UtcNow
        # Uhr am Geraet lag weit zurueck: Dateien wirken 1 bis 3 Jahre alt
        for ($i = 0; $i -lt 10; $i++) { $f = Join-Path $d ('alt{0:00}.json' -f $i); Set-Content -LiteralPath $f -Value '{}'; (Get-Item $f).LastWriteTimeUtc = $now.AddDays(-400 - $i * 60) }
        Limit-Outbox $d 50 | Should -Be 0
        @(Get-ChildItem $d -Filter *.json).Count | Should -Be 10
        for ($i = 0; $i -lt 43; $i++) { $f = Join-Path $d ('g{0:00}.json' -f $i); Set-Content -LiteralPath $f -Value '{}'; (Get-Item $f).LastWriteTimeUtc = $now.AddMinutes(-$i) }
        Limit-Outbox $d 50 | Should -Be 3
        @(Get-ChildItem $d -Filter *.json).Count | Should -Be 50
        foreach ($n in 'alt09.json', 'alt08.json', 'alt07.json') { Test-Path (Join-Path $d $n) | Should -BeFalse }
        Test-Path (Join-Path $d 'alt06.json') | Should -BeTrue
        ($script:LogLines -join ' ') | Should -Match '3 älteste verworfen'
        Limit-Outbox (Join-Path $d 'fehlt') | Should -Be 0
    }
    It 'Nachsenden: hoechstens 5, aelteste zuerst, gesendete Dateien geloescht, Karte aus der Datei' {
        New-Box 7 'Bericht'
        $n = Send-Outbox (Get-OutboxDir) $script:Url 5 8 @() 'Testschule'
        $n | Should -Be 5
        @(Get-ChildItem (Get-OutboxDir) -Filter *.json).Count | Should -Be 2
        (Get-SentTitles) -join ',' | Should -Be 'Bericht 00,Bericht 01,Bericht 02,Bericht 03,Bericht 04'
        ($script:Bodies[0] | ConvertFrom-Json).attachments[0].content.body[-1].text | Should -Match '^Testschule  \|  '
    }
    It 'Nachsenden: erst senden, dann aufraeumen (bei 53 Dateien geht der aelteste Bericht raus, nicht in den Papierkorb)' {
        New-Box 53 'Bericht'
        Send-Outbox (Get-OutboxDir) $script:Url 5 8 @() 'Testschule' | Should -Be 5
        @(Get-SentTitles)[0] | Should -Be 'Bericht 00'
        @(Get-ChildItem (Get-OutboxDir) -Filter *.json).Count | Should -Be 48
    }
    It 'Nachsenden: nach dem ersten Fehlschlag Schluss, Datei bleibt, wirft nicht; ungueltige Adresse sendet nichts' {
        Mock Invoke-ReportPost { throw 'offline' }
        for ($i = 0; $i -lt 3; $i++) { [void](Save-OutboxReport (Get-OutboxDir) @{ Level = 'Error'; Title = 'B'; Lines = @(); Log = @() } ('S' + $i) ([datetime]::UtcNow.AddMinutes(-$i))) }
        { Send-Outbox (Get-OutboxDir) $script:Url 5 8 } | Should -Not -Throw
        Should -Invoke Invoke-ReportPost -Times 1 -Exactly
        @(Get-ChildItem (Get-OutboxDir) -Filter *.json).Count | Should -Be 3
        Send-Outbox (Get-OutboxDir) $script:OldHook 5 8 | Should -Be 0
        Should -Invoke Invoke-ReportPost -Times 1 -Exactly
        ($script:LogLines -join ' ') | Should -Not -Match 'KUENSTLICHESIGNATUR|example\.invalid'
    }
    It 'Nachsenden: Fusszeile zeigt die Zeit aus created (unter 5.1 und 7 gleich)' {
        $when = [datetime]::new(2026, 10, 3, 7, 4, 0, [DateTimeKind]::Utc)
        [void](Save-OutboxReport (Get-OutboxDir) @{ Level = 'Error'; Title = 'B'; Lines = @('z'); Log = @() } 'S' $when)
        Send-Outbox (Get-OutboxDir) $script:Url 5 8 @() 'Testschule' | Should -Be 1
        ($script:Bodies[0] | ConvertFrom-Json).attachments[0].content.body[-1].text | Should -Be ('Testschule  |  ' + $when.ToLocalTime().ToString('dd.MM.yyyy HH:mm') + '  |  HUPilot go 2.7.19')
    }
    It 'Nachsenden: unlesbare Dateien (kaputt, v unbekannt oder kein Text, groesser als 256 KB) zaehlen nicht mit, bleiben liegen, wirft nicht' {
        $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $old = [datetime]::UtcNow.AddDays(-2)
        $bad = [ordered]@{
            'a_kaputt.json' = 'kein json'
            'b_v2.json'     = '{"v":2,"title":"x","lines":[],"log":[]}'
            'c_vtext.json'  = '{"v":"eins","title":"x","lines":[],"log":[]}'
            'd_vobj.json'   = '{"v":{"a":1},"title":"x","lines":[],"log":[]}'
            'e_leer.json'   = ''
            'f_gross.json'  = ('{"v":1,"title":"gross","lines":["' + ('x' * 270000) + '"],"log":[]}')
        }
        $i = 0
        foreach ($k in $bad.Keys) { [IO.File]::WriteAllText((Join-Path $d $k), $bad[$k]); (Get-Item (Join-Path $d $k)).LastWriteTimeUtc = $old.AddMinutes($i++) }
        New-Box 2 'Gut'
        { $script:n1 = Send-Outbox $d $script:Url 5 8 @() 'Testschule' } | Should -Not -Throw
        $script:n1 | Should -Be 2
        (Get-SentTitles) -join ',' | Should -Be 'Gut 00,Gut 01'
        foreach ($k in $bad.Keys) { Test-Path (Join-Path $d $k) | Should -BeTrue -Because $k }
        ($script:LogLines -join ' ') | Should -Match 'größer als 256 KB'
        ($script:LogLines -join ' ') | Should -Match 'unbekannte Version'
    }
    It 'Nachsenden: unlesbare Dateien aelter als 30 Tage werden verworfen, lesbare nie' {
        $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'alt_kaputt.json'), 'kein json'); (Get-Item (Join-Path $d 'alt_kaputt.json')).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-31)
        [IO.File]::WriteAllText((Join-Path $d 'neu_kaputt.json'), 'kein json'); (Get-Item (Join-Path $d 'neu_kaputt.json')).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-29)
        $p = Save-OutboxReport $d @{ Level = 'Error'; Title = 'Uralt'; Lines = @('z'); Log = @() } 'S' ([datetime]::UtcNow.AddDays(-900))
        (Get-Item $p).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-900)
        Mock Invoke-ReportPost { throw 'offline' }
        Send-Outbox $d $script:Url 5 8 | Should -Be 0
        Test-Path (Join-Path $d 'alt_kaputt.json') | Should -BeFalse
        Test-Path (Join-Path $d 'neu_kaputt.json') | Should -BeTrue
        Test-Path $p | Should -BeTrue
        ($script:LogLines -join ' ') | Should -Match 'älter als 30 Tage, verworfen: alt_kaputt\.json'
    }
    It 'Nachsenden: fehlt der Titel, gibt es einen Ersatztitel statt liegen zu lassen' {
        $d = Get-OutboxDir; New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'ohne.json'), '{"v":1,"created":"2026-11-14T09:00:00Z","source":"go","level":"Error","lines":["z"],"log":[]}')
        Send-Outbox $d $script:Url 5 8 @() 'Testschule' | Should -Be 1
        @(Get-SentTitles)[0] | Should -Be 'Testschule: Bericht vom Stick'
        [IO.File]::WriteAllText((Join-Path $d 'ohne2.json'), '{"v":1,"title":"  ","lines":[],"log":[]}')
        Send-Outbox $d $script:Url 5 8 @() '' | Should -Be 1
        @(Get-SentTitles)[1] | Should -Be 'HUPilot: Bericht vom Stick'
    }
    It 'Fehler mit Internet: genau ein Bericht je Lauf, Inhalt nach Vertrag, nichts Geheimes in der Karte' {
        $e = Get-EndText 'Fehler' 'Grund X.' 'Mach Y.'
        $r = Send-GoReport $e 'Fehler'
        $r.Text | Should -Be 'Bericht an den Admin gesendet.'
        Send-GoReport $e 'Fehler' | Should -BeNullOrEmpty
        Send-GoReport $e 'KeinProfilEnde' | Should -BeNullOrEmpty
        Should -Invoke Invoke-ReportPost -Times 1 -Exactly
        $c = ($script:Bodies[0] | ConvertFrom-Json).attachments[0].content
        $c.body[0].text | Should -Be 'Testschule: Fehler am Gerät SN/123 45'
        $c.body[0].color | Should -Be 'Attention'
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
    It 'Titel: Anzeigename vorne (ein Kanal fuer mehrere Schulen), leer = HUPilot; Zeile mit Anzeigename bleibt' {
        $e = Get-EndText 'Fehler' 'G.' 'T.'
        $r = New-GoReport -End $e -SerialNo 'ABC123' -Cfg (New-TestCfg '')
        $r.Title | Should -Be 'Testschule: Fehler am Gerät ABC123'
        $r.Lines | Should -Contain 'Anzeigename: Testschule'
        $c = New-TestCfg ''; $c.Tenant = '   '
        $r = New-GoReport -End $e -SerialNo 'ABC123' -Cfg $c
        $r.Title | Should -Be 'HUPilot: Fehler am Gerät ABC123'
        @($r.Lines | Where-Object { $_ -like 'Anzeigename:*' }).Count | Should -Be 0
        (New-GoReport -End $e -SerialNo '' -Cfg $null).Title | Should -Be 'HUPilot: Fehler am Gerät (Seriennummer unbekannt)'
        $script:ReportNetOk = $false
        [void](Send-GoReport $e 'Fehler')
        $f = @(Get-ChildItem (Join-Path $script:CfgDir 'logs\outbox') -Filter *.json)
        ([IO.File]::ReadAllText($f[0].FullName) | ConvertFrom-Json).title | Should -Be 'Testschule: Fehler am Gerät SN/123 45'
    }
    It 'Fehler, Senden scheitert: Datei am Stick, bereinigt, Zeile "gespeichert", wirft nicht' {
        Mock Invoke-ReportPost { throw ("Zeitlimit bei 'example.invalid' " + $Url) }
        { $script:r1 = Send-GoReport (Get-EndText 'Fehler' 'Grund.' 'Tun.') 'Fehler' } | Should -Not -Throw
        $script:r1.Text | Should -Be 'Bericht am Stick gespeichert, wird beim nächsten Mal mit Internet gesendet.'
        $f = @(Get-ChildItem (Join-Path $script:CfgDir 'logs\outbox') -Filter *.json)
        $f.Count | Should -Be 1
        $raw = [IO.File]::ReadAllText($f[0].FullName)
        foreach ($s in $script:SecretValues) { $raw | Should -Not -Match ([regex]::Escape($s)) }
        ($raw | ConvertFrom-Json).title | Should -Be 'Testschule: Fehler am Gerät SN/123 45'
        ($script:LogLines -join ' ') | Should -Not -Match 'KUENSTLICHESIGNATUR|example\.invalid'
    }
    It 'Fehler ohne Internet: kein Sendeversuch, Datei am Stick' {
        $script:ReportNetOk = $false
        (Send-GoReport (Get-EndText 'Fehler' 'G.' 'T.') 'Fehler').Text | Should -Match 'am Stick gespeichert'
        Should -Invoke Invoke-ReportPost -Times 0
        @(Get-ChildItem (Join-Path $script:CfgDir 'logs\outbox') -Filter *.json).Count | Should -Be 1
    }
    It 'Fehler ohne Internet und ohne Stick: stiller Verzicht mit Logzeile, keine Zeile am Bildschirm' {
        $script:ReportNetOk = $false
        Remove-Item -LiteralPath (Join-Path $script:CfgDir 'config.json')
        Send-GoReport (Get-EndText 'Fehler' 'G.' 'T.') 'Fehler' | Should -BeNullOrEmpty
        ($script:LogLines -join ' ') | Should -Match 'verworfen'
    }
    It 'Ohne Adresse: nichts, keine Zeile; ungueltige Adresse: graue Hinweiszeile mit naechstem Schritt, kein Senden' {
        $script:cfg = New-TestCfg ''
        Send-GoReport (Get-EndText 'Fehler') 'Fehler' | Should -BeNullOrEmpty
        $script:ReportDone | Should -BeFalse
        $script:cfg = New-TestCfg $script:OldHook
        $r = Send-GoReport (Get-EndText 'Fehler') 'Fehler'
        $r.Color | Should -Be 'Gray'
        $r.Text | Should -Be 'Hinweis: Das Feld Teams-Webhook am Stick ist ungültig, es geht kein Bericht an den Admin. Im Setup das Feld Teams-Webhook prüfen und den Stick neu bespielen.'
        $script:cfg = $null; $script:ReportDone = $false
        Send-GoReport (Get-EndText 'Fehler') 'Fehler' | Should -BeNullOrEmpty
        Should -Invoke Invoke-ReportPost -Times 0
    }
    It 'Anlaesse: rote Enden, Secret abgelaufen oder falsch, kein Profil am Ende senden; andere Gelb nicht' {
        foreach ($a in 'Abbruch', 'Offline', 'UploadKeinProfil', 'NeustartAbgebrochen', '', 'Error', 'Warning') {
            $script:ReportDone = $false
            Send-GoReport (Get-EndText 'Abbruch' 'X') $a | Should -BeNullOrEmpty -Because $a
        }
        Should -Invoke Invoke-ReportPost -Times 0
        foreach ($a in 'Fehler', 'FehlerReset', 'ResetNichtGestartet', 'SecretAbgelaufen', 'SecretFalsch', 'KeinProfilEnde') {
            $script:ReportDone = $false
            (Send-GoReport (Get-EndText 'Offline' 'X.' 'Y.') $a).Text | Should -Be 'Bericht an den Admin gesendet.' -Because $a
        }
        Should -Invoke Invoke-ReportPost -Times 6 -Exactly
        $titles = Get-SentTitles
        $titles[0..2] | ForEach-Object { $_ | Should -Be 'Testschule: Fehler am Gerät SN/123 45' }
        $titles[3..5] | ForEach-Object { $_ | Should -Be 'Testschule: Hinweis am Gerät SN/123 45' }
        ($script:Bodies[3] | ConvertFrom-Json).attachments[0].content.body[0].color | Should -Be 'Warning'
    }
    It 'Anlaesse: Liste erweiterbar ohne Umbau' {
        Send-GoReport (Get-EndText 'Abbruch' 'X') 'Abbruch' | Should -BeNullOrEmpty
        $script:ReportAnlaesse['Abbruch'] = 'Warning'
        (Send-GoReport (Get-EndText 'Abbruch' 'X') 'Abbruch').Text | Should -Be 'Bericht an den Admin gesendet.'
    }
    It 'unerwarteter Fehler im Bericht wirft nie' {
        Mock Get-DeviceReportLines { throw 'kaputt' }
        { Send-GoReport (Get-EndText 'Fehler') 'Fehler' } | Should -Not -Throw
    }
}

Describe 'go 2.7.19: Einbau des Berichts' {
    BeforeAll {
        function Get-GoFunctionAst([string]$Name) { $script:GoAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $Name }, $true) | Select-Object -First 1 }
        $script:FailText = (Get-GoFunctionText 'Fail')
        $script:FailResetAst = Get-GoFunctionAst 'Fail-Reset'
    }
    It 'Fail: Bericht nach dem roten Bild und vor Wait-Close, -NoReport ohne Bericht, Exitcode bleibt 1' {
        $t = $script:FailText
        $t | Should -Match ([regex]::Escape("[switch]`$NoReport"))
        $t | Should -Match ([regex]::Escape("if (`$NoReport) { Log 'Kein Bericht an den Admin: Abbruch auf Wunsch des Benutzers' }"))
        $t | Should -Match ([regex]::Escape("else { Write-ReportLine (Send-GoReport (Get-EndText 'Fehler' `$sp[0] `$Tun) 'Fehler') }"))
        $t.IndexOf('Banner ') | Should -BeLessThan $t.IndexOf('Send-GoReport')
        $t.IndexOf('Send-GoReport') | Should -BeLessThan $t.IndexOf('Wait-Close')
        $t | Should -Match 'exit 1'
    }
    It 'Fail-Reset: Bericht nach dem roten Bild und vor Wait-Close, -NoReport ohne Bericht, Exitcode bleibt 1' {
        $t = $script:FailResetAst.Extent.Text
        $t | Should -Match ([regex]::Escape("[switch]`$NoReport"))
        $t.IndexOf('Banner ') | Should -BeLessThan $t.IndexOf('Send-GoReport')
        $t.IndexOf('Send-GoReport') | Should -BeLessThan $t.IndexOf('Wait-Close')
        $t | Should -Match "Get-EndText 'FehlerReset'"
        $t | Should -Match "'FehlerReset'\) \}"
        $t | Should -Match 'exit 1'
    }
    It 'Bewusstes Nein des Benutzers: kein Bericht (alle vier Stellen mit -NoReport)' {
        $l = @($script:GoText -split "`r?`n")
        # 2.8.0: die Hardware-Aenderung steht jetzt in einem Block (eigene Zeile, ohne Klammer am Ende)
        foreach ($p in "if (`$k -ne 'W') { Fail ('Umstellung auf Pro hat nicht geklappt", "if (`$k -ne 'J' -and `$k -ne 'Y') { Fail (", "        Fail 'Autopilot meldet eine Hardware-Änderung", "if (`$a -notmatch '^[jJyY]') { Fail-Reset 'WLAN-Paket von Intune gesperrt") {
            $hit = @($l | Where-Object { $_.Contains($p) })
            $hit.Count | Should -Be 1 -Because $p
            $hit[0].TrimEnd() | Should -Match ' -NoReport( \})?$' -Because $p
        }
        @([regex]::Matches($script:GoText, ' -NoReport( \}|\r?\n)')).Count | Should -Be 4
    }
    It 'Bericht genau an den vereinbarten Stellen, mit dem passenden Anlass' {
        @([regex]::Matches($script:GoText, 'Send-GoReport \(')).Count | Should -Be 5
        $script:GoText | Should -Match ([regex]::Escape("Write-ReportLine (Send-GoReport (Get-EndText 'ResetNichtGestartet' `$wasN '' `$jetztN) 'ResetNichtGestartet')"))
        $script:GoText | Should -Match ([regex]::Escape("Write-ReportLine (Send-GoReport (Get-EndText 'KeinProfilEnde' `$kpWas `$kpTun) 'KeinProfilEnde')"))
        # Ende nach 15 Minuten: Bericht zwischen rotem Bild und Wait-Close
        $i = $script:GoText.IndexOf("Banner 'ZURÜCKSETZEN NOCH NICHT BEGONNEN'")
        $i | Should -BeGreaterThan 0
        $script:GoText.IndexOf("'ResetNichtGestartet')", $i) | Should -BeLessThan $script:GoText.IndexOf('Wait-Close', $i + 60)
        (Get-GoFunctionAst 'Stop-ByUser').Extent.Text | Should -Not -Match 'Send-GoReport'
        $so = (Get-GoFunctionAst 'Save-Offline').Extent.Text
        # 2.8.0: Bericht vor dem Bild (U2), die Zeile darunter bleibt
        $so | Should -Match ([regex]::Escape("if (`$Anlass) { `$rr = Send-GoReport (Get-EndText 'Offline' `$was `$tun) `$Anlass;"))
        $so | Should -Match ([regex]::Escape('Write-ReportLine $rr'))
        $so.IndexOf('Send-GoReport') | Should -BeLessThan $so.IndexOf('exit 2')
    }
    It 'Gelb mit Bericht nur bei Secret abgelaufen oder falsch, nicht bei kein Internet oder anderer Anmeldung' {
        $script:GoText | Should -Match ([regex]::Escape(". Am PC im Setup ein neues Secret eintragen') 'SecretAbgelaufen' }"))
        $script:GoText | Should -Match ([regex]::Escape(". Am PC im Setup den Wert des Secrets eintragen') 'SecretFalsch' }"))
        $script:GoText | Should -Match ([regex]::Escape("Save-Offline 'Kein Internet nach 2 Min (WLAN-Reichweite/Kennwort/Firewall prüfen)'`r`n"))
        $script:GoText | Should -Match ([regex]::Escape("Save-Offline 'Anmeldung am Tenant fehlgeschlagen (Details im Log). Am PC im Setup `"Verbindung testen`"' }"))
    }
    It 'Fenster wird beim Start maximiert, nach der Schrift, Fehler halten nichts auf' {
        $script:GoText | Should -Match ([regex]::Escape('ShowWindow(w, 3);'))
        $i = $script:GoText.IndexOf('[HuFont]::AtLeast(20)')
        $j = $script:GoText.IndexOf('try { $WinInfo = [HuFont]::Maximize()')
        $j | Should -BeGreaterThan $i
        $script:GoText.Substring($j, 400) | Should -Match 'catch \{ \$WinInfo = \$_\.Exception\.Message \}'
    }
    It 'Internet OK setzt ReportNetOk, danach Nachsenden; eindeutiger Name; alle Bericht-Funktionen vor Fail definiert' {
        $i = $script:GoText.IndexOf("Say 'Internet OK' 'Green'")
        $script:GoText.IndexOf('$script:ReportNetOk = $true') | Should -BeGreaterThan $i
        $script:GoText.IndexOf('Send-Outbox (Get-OutboxDir)') | Should -BeGreaterThan $i
        $script:GoText | Should -Not -Match '(?i)\$script:NetOk\b'
        $f = $script:GoText.IndexOf('function Fail {')
        foreach ($n in 'Test-WebhookUrl', 'Protect-ReportText', 'New-ReportCard', 'Invoke-ReportPost', 'Send-TeamsCard', 'Save-OutboxReport', 'Read-OutboxFile', 'Send-Outbox', 'Send-GoReport', 'Write-ReportLine') {
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
    It 'diag.ps1: parst, prueft den Host des Teams-Webhooks, gibt die Adresse nie aus, Hinweis mit naechstem Schritt' {
        $dp = Join-Path $script:Root 'Stick\HUPilot\diag.ps1'
        $tk = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($dp, [ref]$tk, [ref]$er)
        @($er).Count | Should -Be 0
        $t = Get-Content -LiteralPath $dp -Raw -Encoding UTF8
        $t | Should -Match 'TeamsWebhook'
        # 2.8.0 (B11): kein Host mehr, nur eingetragen und erreichbar
        $t | Should -Match ([regex]::Escape('Bericht an den Admin: eingetragen, erreichbar'))
        $t | Should -Not -Match 'Write-Host[^\r\n]*\$x\.Host'
        $t | Should -Match ([regex]::Escape('Feld Teams-Webhook ungültig. Im Setup das Feld Teams-Webhook prüfen und den Stick neu bespielen.'))
        $t | Should -Not -Match 'Write-Host[^\r\n]*\$tw\b'
        $t | Should -Not -Match 'Teams-Bericht|Teams-Adresse'
    }
    It 'Bezeichnungen einheitlich: Feld Teams-Webhook, Sache Bericht an den Admin' {
        $script:GoText | Should -Not -Match 'Teams-Adresse|Teams-Bericht'
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
