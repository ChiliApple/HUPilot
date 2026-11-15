#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer go.ps1, Version 2.8.2: Aktivierung bei jedem Geraet, Auswertung auch am Stick.
# Funktionen werden per AST geloest und ohne Geraet geprueft (kein Graph, kein Netz, nur kuenstliche Werte).
# Diese Datei enthaelt nur ASCII (Umlaute in Mustern als Punkt).

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:GoPath = Join-Path $script:Root 'Stick\HUPilot\go.ps1'
    $script:GoText = Get-Content -LiteralPath $script:GoPath -Raw -Encoding UTF8
    function Get-GoFunctionText([string[]]$Names) {
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GoPath, [ref]$tk, [ref]$er)
        $t = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Names -contains $_.Name } | ForEach-Object { $_.Extent.Text })
        if ($t.Count -ne $Names.Count) { throw ('Funktionen nicht (eindeutig) gefunden: ' + ($Names -join ', ')) }
        return ($t -join "`n")
    }
    # Kuenstlicher Schluessel, kein echter
    $script:FakeKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
}

Describe 'go 2.8.2: Lizenzstatus lesen (Get-WinLicense)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-WinLicense')))
        $script:Gen = @('3V66T', 'PKCKT')
        $script:Rows = @()
        $script:CimThrow = $false
        $script:CimArgs = $null
        function Get-CimInstance {
            param($Query, $OperationTimeoutSec, $ErrorAction)
            $script:CimArgs = $PSBoundParameters
            if ($script:CimThrow) { throw 'Dienst antwortet nicht' }
            return $script:Rows
        }
    }
    BeforeEach { $script:Rows = @(); $script:CimThrow = $false }
    It 'Abfrage scheitert: nicht lesbar, nicht aktiviert, wirft nicht' {
        $script:CimThrow = $true
        $r = Get-WinLicense $script:Gen
        $r.Known | Should -BeFalse; $r.Licensed | Should -BeFalse; $r.Installed | Should -Be ''
    }
    It 'die Abfrage hat eine Zeitgrenze' {
        [void](Get-WinLicense $script:Gen)
        $script:CimArgs.OperationTimeoutSec | Should -Be 60
    }
    It '2.8.3: schlanke Abfrage (nur drei Felder, nur Windows), sonst dauert sie am Geraet 30 bis 60 s' {
        [void](Get-WinLicense $script:Gen)
        $script:CimArgs.Query | Should -Match '^SELECT Name, LicenseStatus, PartialProductKey FROM SoftwareLicensingProduct WHERE PartialProductKey IS NOT NULL AND ApplicationID = ''55c92734-d682-4d71-983e-d6ec3f16059f''$'
        $script:GoText | Should -Not -Match 'Get-CimInstance -ClassName SoftwareLicensingProduct'
    }
    It 'kein Schluessel eingetragen' {
        $r = Get-WinLicense $script:Gen
        $r.Known | Should -BeTrue; $r.Licensed | Should -BeFalse; $r.Installed | Should -Be ''
    }
    It 'nur der allgemeine Schluessel: generic, nicht aktiviert' {
        $script:Rows = @([pscustomobject]@{ Name = 'Windows(R), Professional edition'; LicenseStatus = 5; PartialProductKey = '3V66T' })
        $r = Get-WinLicense $script:Gen
        $r.Installed | Should -Be 'generic'; $r.Licensed | Should -BeFalse
    }
    It 'eigener Schluessel, noch nicht aktiviert: own' {
        $script:Rows = @([pscustomobject]@{ Name = 'Windows(R), Professional edition'; LicenseStatus = 5; PartialProductKey = 'ZZZZ9' })
        $r = Get-WinLicense $script:Gen
        $r.Installed | Should -Be 'own'; $r.Licensed | Should -BeFalse
    }
    It 'Status 1 = aktiviert' {
        $script:Rows = @([pscustomobject]@{ Name = 'Windows(R), Professional edition'; LicenseStatus = 1; PartialProductKey = 'ZZZZ9' })
        (Get-WinLicense $script:Gen).Licensed | Should -BeTrue
    }
    It 'der Text nennt nur die letzten 5 Zeichen' {
        $script:Rows = @([pscustomobject]@{ Name = 'Windows(R), Professional edition'; LicenseStatus = 5; PartialProductKey = 'ZZZZ9' })
        (Get-WinLicense $script:Gen).Text | Should -Be 'Windows(R), Professional edition = 5 (ZZZZ9)'
    }
}

Describe 'go 2.8.2: Entscheidung zur Aktivierung (Get-ActPlan)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Get-ActPlan')))
    }
    It 'schon aktiviert: nichts tun, kein MAK, keine Zeile' {
        $p = Get-ActPlan 'Professional' $true $true 'generic' $script:FakeKey $false '*****-EEEEE' $false
        $p.Ato | Should -BeFalse; $p.Mak | Should -BeFalse; $p.Hint | Should -Be ''
    }
    It 'Status nicht lesbar: nichts tun und nichts behaupten' {
        $p = Get-ActPlan 'Professional' $false $false '' $script:FakeKey $false '*****-EEEEE' $false
        $p.Ato | Should -BeFalse; $p.Mak | Should -BeFalse; $p.Hint | Should -Be ''
    }
    It 'Windows Home: nichts tun (laeuft ueber die Umstellung auf Pro)' {
        $p = Get-ActPlan 'Core' $true $false 'generic' $script:FakeKey $false '*****-EEEEE' $true
        $p.Ato | Should -BeFalse; $p.Mak | Should -BeFalse; $p.Hint | Should -Be ''
    }
    It 'eigener Schluessel im Geraet: nur dieser wird versucht, der MAK nie, auch wenn er am Stick liegt' -ForEach @(
        @{ Ed = 'Professional' }, @{ Ed = 'ProfessionalEducation' }, @{ Ed = 'Education' }, @{ Ed = 'Enterprise' }
    ) {
        $p = Get-ActPlan $Ed $true $false 'own' $script:FakeKey $false '*****-EEEEE' $false
        $p.Ato | Should -BeTrue; $p.Mak | Should -BeFalse; $p.Warn | Should -BeFalse
        $p.Hint | Should -Match 'eigenen Schl.ssel'
        $p.Hint | Should -Match 'geht trotzdem weiter'
    }
    It 'Pro ohne eigenen Schluessel (keiner oder nur der allgemeine), echter MAK: gleich der MAK' -ForEach @(
        @{ Inst = '' }, @{ Inst = 'generic' }
    ) {
        $p = Get-ActPlan 'Professional' $true $false $Inst $script:FakeKey $false '*****-EEEEE' $false
        $p.Ato | Should -BeFalse; $p.Mak | Should -BeTrue; $p.Warn | Should -BeTrue
        $p.Hint | Should -Match 'geht trotzdem weiter'
        $p.Hint | Should -Match 'EEEEE'
    }
    It 'Pro ohne eigenen Schluessel, kein MAK am Stick: nur Warnung mit naechstem Schritt' {
        $p = Get-ActPlan 'Professional' $true $false 'generic' '' $false '' $false
        $p.Ato | Should -BeFalse; $p.Mak | Should -BeFalse; $p.Warn | Should -BeTrue
        $p.Hint | Should -Match 'nicht aktiviert'
        $p.Hint | Should -Match 'Admin'
    }
    It 'Pro, allgemeiner Schluessel im Feld MAK: nie als MAK verwenden' {
        $p = Get-ActPlan 'Professional' $true $false 'generic' $script:FakeKey $true '*****-EEEEE' $false
        $p.Mak | Should -BeFalse
        $p.Hint | Should -Match 'allgemeine'
    }
    It 'andere Editionen ohne eigenen Schluessel: MAK nie, auch wenn einer am Stick liegt' -ForEach @(
        @{ Ed = 'ProfessionalN' }, @{ Ed = 'ProfessionalEducation' }, @{ Ed = 'ProfessionalWorkstation' },
        @{ Ed = 'Education' }, @{ Ed = 'Enterprise' }, @{ Ed = 'ServerRdsh' }, @{ Ed = '' }
    ) {
        $p = Get-ActPlan $Ed $true $false 'generic' $script:FakeKey $false '*****-EEEEE' $false
        $p.Mak | Should -BeFalse; $p.Ato | Should -BeFalse
        $p.Hint | Should -Match 'nicht aktiviert'
        $p.Hint | Should -Match 'geht trotzdem weiter'
    }
    It 'Versuch mit dem Schluessel des Geraets und MAK schliessen sich immer aus' {
        foreach ($ed in 'Professional', 'Education', '') { foreach ($inst in '', 'generic', 'own') { foreach ($k in '', $script:FakeKey) { foreach ($gen in $true, $false) {
            $p = Get-ActPlan $ed $true $false $inst $k $gen '*****-EEEEE' $false
            ($p.Ato -and $p.Mak) | Should -BeFalse
            if ($p.Mak) { $ed | Should -Be 'Professional'; $inst | Should -Not -Be 'own'; $k | Should -Not -Be ''; $gen | Should -BeFalse }
        } } } }
    }
    It 'kein Hinweis nennt den ganzen Schluessel' {
        foreach ($ed in 'Professional', 'Education') { foreach ($inst in '', 'generic', 'own') { foreach ($gen in $true, $false) {
            (Get-ActPlan $ed $true $false $inst $script:FakeKey $gen '*****-EEEEE' $false).Hint | Should -Not -Match 'AAAAA-BBBBB'
        } } }
    }
}

Describe 'go 2.8.2: slmgr mit Zeitgrenze (Invoke-Slmgr)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Invoke-Slmgr')))
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('hupilot-slmgr-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $script:VbsEcho = Join-Path $script:Tmp 'echo.vbs'
        $script:VbsSleep = Join-Path $script:Tmp 'sleep.vbs'
        Set-Content -LiteralPath $script:VbsEcho -Value 'WScript.Echo "ARG " & WScript.Arguments(0)' -Encoding ASCII
        Set-Content -LiteralPath $script:VbsSleep -Value 'WScript.Sleep 30000' -Encoding ASCII
        $script:Vbs = $script:VbsEcho
        function Get-SysExe([string]$Name) {
            if ($Name -eq 'cscript.exe') { return (Join-Path $env:SystemRoot 'System32\cscript.exe') }
            return $script:Vbs
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
    It 'liefert die Ausgabe des Aufrufs' {
        $script:Vbs = $script:VbsEcho
        $r = Invoke-Slmgr @('/ato') 30
        $r.TimedOut | Should -BeFalse
        $r.Out | Should -Match 'ARG /ato'
    }
    It 'haengt der Aufruf, wird er beendet und der Ablauf geht weiter' {
        $script:Vbs = $script:VbsSleep
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Slmgr @('/ato') 2
        $sw.Stop()
        $r.TimedOut | Should -BeTrue
        $r.Out | Should -Match 'keine Antwort'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
    }
    It 'wirft nie, auch wenn das Programm fehlt' {
        function Get-SysExe([string]$Name) { return 'C:\gibt-es-nicht\x.exe' }
        $r = Invoke-Slmgr @('/ato') 2
        $r.Out | Should -Match 'gescheitert'
    }
}

Describe 'go 2.8.2: Auswertung des Zuruecksetzens auch am Stick (Write-StickLate)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-GoFunctionText 'Write-StickLate')))
        function Get-Mono { return 12 }
        function Protect-ReportText { param([string]$Text, $Secrets, [int]$Cap) foreach ($s in $Secrets) { $Text = $Text.Replace([string]$s, '***') } return $Text }
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('hupilot-late-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    }
    AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach { $script:LogSecrets = $null }
    It 'haengt die Zeile an, wenn die Logdatei dieses Laufs noch da ist' {
        $f = Join-Path $script:Tmp 'a.log'
        Set-Content -LiteralPath $f -Value 'erste Zeile' -Encoding UTF8
        (Write-StickLate 'Auswertung: Ok, "OK 0"' $f) | Should -BeTrue
        $l = @(Get-Content -LiteralPath $f -Encoding UTF8)
        $l.Count | Should -Be 2
        $l[0] | Should -Be 'erste Zeile'
        $l[1] | Should -Match 'Auswertung: Ok, "OK 0"$'
        $l[1] | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  \['
    }
    It 'Stick abgezogen (Datei fehlt): nichts schreiben, nichts anlegen, kein Fehler' {
        $f = Join-Path $script:Tmp 'fehlt\b.log'
        (Write-StickLate 'x' $f) | Should -BeFalse
        Test-Path -LiteralPath $f | Should -BeFalse
        Test-Path -LiteralPath (Split-Path $f -Parent) | Should -BeFalse
    }
    It 'ohne gemerkten Pfad: nichts' {
        (Write-StickLate 'x' '') | Should -BeFalse
    }
    It 'bereinigt wie das Log' {
        $f = Join-Path $script:Tmp 'c.log'
        Set-Content -LiteralPath $f -Value 'a' -Encoding UTF8
        $script:LogSecrets = @('GEHEIM123')
        (Write-StickLate 'Wert GEHEIM123 Ende' $f) | Should -BeTrue
        $t = Get-Content -LiteralPath $f -Raw -Encoding UTF8
        $t | Should -Not -Match 'GEHEIM123'
        $t | Should -Match 'Wert \*\*\* Ende'
    }
    It 'scheitert die Bereinigung, wird nichts geschrieben' {
        $f = Join-Path $script:Tmp 'd.log'
        Set-Content -LiteralPath $f -Value 'a' -Encoding UTF8
        function Protect-ReportText { throw 'kaputt' }
        $script:LogSecrets = @('GEHEIM123')
        (Write-StickLate 'Wert GEHEIM123 Ende' $f) | Should -BeFalse
        (Get-Content -LiteralPath $f -Raw -Encoding UTF8) | Should -Not -Match 'GEHEIM123'
    }
}

Describe 'go 2.8.2: Einbau in den Ablauf' {
    It 'Aktivierung erst nach dem Hochladen (kein MAK fuer Geraete, die nicht registriert wurden), vor dem Ende des Stick-Logs' {
        $iTok = $script:GoText.IndexOf("Show-Step 3 'Anmelden'")
        $iUp = $script:GoText.IndexOf("Show-Step 4 'Hochladen'")
        $iPkg = $script:GoText.IndexOf("Log 'WLAN-Paket lokal kopiert'")
        $iAct = $script:GoText.IndexOf('$wl = Get-WinLicense $actGenTails')
        $iProt = $script:GoText.IndexOf("Protokoll (`$(if (`$AlreadyReg) { 'BEREITS REGISTRIERT' } else { 'UPLOAD OK' })")
        $iEnd = $script:GoText.IndexOf("Log '--- Stick wird ab jetzt nicht mehr gebraucht ---'")
        $iTok | Should -BeGreaterThan 0
        $iUp | Should -BeGreaterThan $iTok
        $iPkg | Should -BeGreaterThan $iUp
        $iAct | Should -BeGreaterThan $iPkg
        # der Eintrag zum Upload bleibt die neueste Zeile im Stick-Protokoll
        $iProt | Should -BeGreaterThan $iAct
        $iEnd | Should -BeGreaterThan $iProt
        ([regex]::Matches($script:GoText, 'Get-WinLicense \$actGenTails')).Count | Should -Be 3
    }
    It 'der MAK wird nur an einer Stelle eingetragen, und nur wenn der Plan es sagt und Windows noch nicht aktiviert ist' {
        ([regex]::Matches($script:GoText, "'/ipk'")).Count | Should -Be 1
        ([regex]::Matches($script:GoText, 'Invoke-Slmgr @\(''/ipk''')).Count | Should -Be 1
        $script:GoText | Should -Not -Match '\$slmgr /ipk'
        $script:GoText | Should -Match '\} elseif \(\$actPlan\.Mak\) \{\s+\$actMak = \$true\s+Say[^\r\n]+\s+\$r2 = Invoke-Slmgr @\(''/ipk'', \$EdKey\)'
        # nach der eigenen Umstellung von Home auf Pro bleibt der MAK-Weg, auch bei nicht lesbarem Status
        $script:GoText | Should -Match '\$actBlind = \(\[bool\]\$EdActivate -and -not \$wl\.Known\)'
    }
    It 'die Ausgabe von slmgr geht nur mit ersetztem Schluessel ins Log' {
        foreach ($m in [regex]::Matches($script:GoText, 'Log \(''slmgr [^\r\n]+')) { $m.Value | Should -Match 'Hide-Key \$r\d\.Out' }
        ([regex]::Matches($script:GoText, 'Log \(''slmgr ')).Count | Should -Be 3
    }
    It 'nicht aktiviert ist nie Rot: im Aktivierungs-Block steht kein Fail' {
        $a = $script:GoText.IndexOf('# ---------- Aktivierung: bei jedem Geraet pruefen')
        $b = $script:GoText.IndexOf('# Erst jetzt der Eintrag zum Upload')
        $a | Should -BeGreaterThan 0; $b | Should -BeGreaterThan $a
        $block = $script:GoText.Substring($a, $b - $a)
        $block | Should -Not -Match '\bFail\b'
        $block | Should -Not -Match '\bexit\b'
        $block | Should -Match 'Say \(\$\(if \(\$actPlan\.Warn\) \{ ''WARNUNG: '' \} else \{ ''Hinweis: '' \}\) \+ \$actPlan\.Hint\) ''Yellow'''
    }
    It 'der Pfad des Stick-Logs wird gemerkt, bevor das laufende Stick-Log endet' {
        $script:GoText | Should -Match '\$script:StickLogLate = \$StickLog\r?\n\$StickLog = \$null'
    }
    It 'die Auswertung des Zuruecksetzens geht ueber Log-Late (Geraet und Stick)' {
        $script:GoText | Should -Match "Log-Late \('Auswertung Zur.cksetzen: '"
        $script:GoText | Should -Not -Match "(?m)^Log \('Auswertung Zur.cksetzen: '"
    }
    It '2.8.4: das Abschlussbild verspricht nicht, das Fenster zu schliessen (go laeuft in der Eingabeaufforderung)' {
        $script:GoText | Should -Not -Match 'Enter = Fenster schlie'
        ([regex]::Matches($script:GoText, 'Enter = beenden \(das Fenster bleibt offen\)')).Count | Should -Be 2
    }
    It 'Rueckfrage Home auf Pro nennt im laufenden Windows den Neustart' {
        $script:GoText | Should -Match "UserName -notmatch '\^defaultuser\\d\*\$'\) \{ Write-Host '  Windows l.uft schon mit einem Benutzer: vorher offene Programme schlie.en"
    }
}
