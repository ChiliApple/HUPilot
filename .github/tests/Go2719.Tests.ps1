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
