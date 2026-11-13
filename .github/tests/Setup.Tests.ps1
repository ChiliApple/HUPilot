#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer HUPilot-Setup.ps1: Fenster (XAML), Feldpruefung, Fingerabdruck des WLAN-Pakets,
# Secret-Ablauf, Kontrolle der kopierten Dateien. Das Setup selbst wird dabei NICHT gestartet (es hebt sich per UAC hoch).

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:SetupPath = Join-Path $script:Root 'Stick\HUPilot\Setup\HUPilot-Setup.ps1'
    $script:SetupText = Get-Content -LiteralPath $script:SetupPath -Raw -Encoding UTF8
    # Funktionen aus dem Setup holen (AST), ohne das Skript auszufuehren
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SetupPath, [ref]$tk, [ref]$er)
    $script:SetupAst = $ast
    $want = 'Get-TagPattern', 'Stop-Field', 'Test-Fields', 'Get-BytesSha', 'Get-StrHash', 'Get-FileSha', 'ConvertTo-UtcDate', 'Format-UtcText',
        'Get-SecretWarnLevel', 'Get-SecretExpiresValue', 'Get-TokenErrorKind', 'Get-PkgInputHash', 'Write-PkgFingerprint', 'Get-PkgState',
        'Test-StickCopy', 'Get-CfgBytesNoMak', 'Split-LogLevel', 'Hide-LogSecrets', 'Get-DeviceStand', 'Get-DeviceTodo', 'Export-StatusXlsx', 'Get-FileShaCached', 'Get-StaleStickPkg', 'Read-CfgFile', 'Hide-IcdText', 'Copy-ToStick'
    $script:Fns = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $_.Name })
    $script:FnText = ($script:Fns | ForEach-Object { $_.Extent.Text }) -join "`n"
    . ([scriptblock]::Create($script:FnText))
    # Umgebung, die das Setup sonst selbst anlegt
    $script:enc = New-Object System.Text.UTF8Encoding($false)
    $enc = $script:enc
    $script:Logs = New-Object System.Collections.Generic.List[string]
    function Out-Log([string]$m) { $script:Logs.Add($m) }
    $script:TestCfg = $null
    function Get-Cfg { return $script:TestCfg }
    function New-TestCfg {
        $o = [ordered]@{
            Tenant = 'Testschule'; TenantId = '11111111-2222-3333-4444-555555555555'; ClientId = '66666666-7777-8888-9999-000000000000'
            ClientSecret = 'abc~geheim'; GroupTag = 'SN-2026'; TagChoices = @('SN-2025', 'SN-2026')
            WlanSsid = 'Konfig'; WlanKey = 'wlanpasswort'; WlanPackage = 'HUPilot-WLAN.ppkg'
            AdminName = ''; AdminPassword = ''; Admin2Name = ''; Admin2Password = ''; AskUser = $false; RemoveOtherPackages = $false; EditionKey = ''
        }
        return $o
    }
    $script:SaveNames = @('Tenant', 'TenantId', 'ClientId', 'ClientSecret', 'GroupTag', 'WlanSsid', 'WlanKey')
    $script:TokenNames = @('TenantId', 'ClientId', 'ClientSecret')
    # XAML-Bloecke ([xml]$name = @' ... '@)
    $script:XamlBlocks = @([regex]::Matches($script:SetupText, "(?s)\[xml\]\`$(\w+) = @'\r?\n(.*?)\r?\n'@") | ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Xaml = $_.Groups[2].Value } })
}

Describe 'Setup: Fenster (XAML)' {
    It 'alle Fenster-Bloecke werden gefunden' {
        @($script:XamlBlocks | ForEach-Object { $_.Name }) | Should -Be @('xaml', 'px', 'vx', 'dx', 'sx', 'gx', 'hx')
    }
    It 'jedes Fenster laedt mit XamlReader (STA), ohne und mit Dark Theme' {
        $theme = [regex]::Match($script:SetupText, "(?s)\`$script:HuThemeXaml = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
        $fn = @($script:SetupAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Add-HuTheme' } | ForEach-Object { $_.Extent.Text }) -join "`n"
        $theme | Should -Match '<ResourceDictionary'
        $fn | Should -Match 'function Add-HuTheme'
        $load = {
            param($blocks, $themeText, $fnText)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $script:HuThemeXaml = $themeText
            . ([scriptblock]::Create($fnText))
            foreach ($b in $blocks) {
                foreach ($mode in 'ohne', 'mit') {
                    try {
                        $x = [xml]$b.Xaml
                        if ($mode -eq 'mit') { Add-HuTheme $x }
                        $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
                        if ($mode -eq 'mit' -and "$($w.Background)" -ne '#FF1E1E1E') { throw "Hintergrund $($w.Background)" }
                        "$($b.Name) $($mode): OK"
                    } catch { "$($b.Name) $($mode): $($_.Exception.Message)" }
                }
            }
        }
        $res = @()
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { $res = @(& $load $script:XamlBlocks $theme $fn) }
        else {
            $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
            try { $ps = [powershell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript($load).AddArgument($script:XamlBlocks).AddArgument($theme).AddArgument($fn); $res = @($ps.Invoke() | ForEach-Object { "$_" }) } finally { $rs.Close() }
        }
        @($res | Where-Object { $_ -notmatch ': OK$' }) | Should -BeNullOrEmpty
        $res.Count | Should -Be (2 * $script:XamlBlocks.Count)
    }
    It 'jedes Fenster bekommt das Dark Theme vor dem Laden' {
        foreach ($v in 'xaml', 'px', 'vx', 'dx', 'sx', 'gx', 'hx') { $script:SetupText | Should -Match ('Add-HuTheme \$' + $v + '\r?\n\s*\$\w+ = \[Windows\.Markup\.XamlReader\]::Load\(\(New-Object System\.Xml\.XmlNodeReader \$' + $v + '\)\)') }
    }
    It 'Protokoll liegt nicht mehr im Scrollbereich, Hauptknopf und Ampeln vorhanden' {
        $x = [xml]$script:XamlBlocks[0].Xaml
        $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
        $ns.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'); $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $x.SelectSingleNode("//w:ScrollViewer[@x:Name='svMain']//*[@x:Name='lLog']", $ns) | Should -BeNullOrEmpty
        $x.SelectSingleNode("//w:ListBox[@x:Name='lLog']", $ns) | Should -Not -BeNullOrEmpty
        $x.SelectSingleNode("//w:Button[@x:Name='bLogCopy']", $ns) | Should -Not -BeNullOrEmpty
        foreach ($n in 'bReady', 'thLog', 'bLogRev', 'bLogClear', 'eTest', 'eTags', 'eWrite', 'ePkg', 'eCopy', 'eStatus', 'eHash', 'tDirty', 'tPkg', 'pKey', 'pAdmPw', 'pAdm2Pw') {
            $x.SelectSingleNode("//*[@x:Name='$n']", $ns) | Should -Not -BeNullOrEmpty -Because $n
        }
    }
    It 'jedes bedienbare Steuerelement in allen Fenstern hat einen Tooltip' {
        $bad = @()
        foreach ($b in $script:XamlBlocks) {
            $x = [xml]$b.Xaml
            foreach ($el in $x.SelectNodes('//*')) {
                if ($el.LocalName -notin 'Button', 'TextBox', 'PasswordBox', 'CheckBox', 'ComboBox', 'ListBox', 'DataGrid', 'Thumb') { continue }
                if ($el.SelectSingleNode('ancestor::*[local-name()="Style" or local-name()="ControlTemplate"]')) { continue }   # Teil einer Vorlage (Bildlaufleiste)
                if (-not $el.GetAttribute('ToolTip')) { $bad += ($b.Name + ': ' + $el.LocalName + ' ' + $el.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')) }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'Unterfenster passen sich an kleine Bildschirme an (Set-WinFit)' {
        foreach ($w in '$pw', '$vw', '$dw', '$sw', '$gw', '$hw') { $script:SetupText | Should -Match ('Set-WinFit \' + $w + '\b') }
    }
}

Describe 'Setup: Feldpruefung an den Aufrufer gebunden' {
    BeforeEach { $script:TestCfg = New-TestCfg; $script:Logs.Clear() }
    It 'vollstaendige Daten: Speichern und Anmeldung ok' {
        Test-Fields $script:SaveNames -Admin | Should -BeTrue
        Test-Fields $script:TokenNames | Should -BeTrue
    }
    It 'halb ausgefuellter Admin blockiert die Anmeldung nicht, aber das Speichern' {
        $script:TestCfg.AdminName = 'kustode'; $script:TestCfg.AdminPassword = 'kurz'
        Test-Fields $script:TokenNames | Should -BeTrue
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match 'Admin-Kennwort'
    }
    It 'Admin-Kennwort ohne Namen und gleiche Namen nur mit -Admin' {
        $script:TestCfg.Admin2Password = 'langesKennwort'
        Test-Fields $script:TokenNames | Should -BeTrue
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:TestCfg = New-TestCfg
        $script:TestCfg.AdminName = 'admin'; $script:TestCfg.AdminPassword = 'langesKennwort'; $script:TestCfg.Admin2Name = 'admin'; $script:TestCfg.Admin2Password = 'langesKennwort'
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match 'sind gleich'
    }
    It 'falscher MAK und allgemeiner Schluessel nur beim Speichern' {
        $script:TestCfg.EditionKey = 'ABC'
        Test-Fields $script:TokenNames | Should -BeTrue
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:TestCfg.EditionKey = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match 'allgemeine'
    }
    It 'Group Tag mit Leerzeichen wird beim Speichern abgelehnt, bei der Anmeldung nicht' {
        $script:TestCfg.GroupTag = 'SN 2026'
        Test-Fields $script:TokenNames | Should -BeTrue
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match 'Group Tag'
    }
    It 'ungueltiger Eintrag in der Auswahl wird abgelehnt' {
        $script:TestCfg.TagChoices = @('SN-2025', '-falsch')
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match 'Auswahl'
        $script:FieldErr | Should -Match '-falsch'
    }
    It 'mehr als 9 Eintraege in der Auswahl: klare Meldung' {
        $script:TestCfg.TagChoices = @(1..10 | ForEach-Object { 'SN-20' + (10 + $_) })
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match '9'
        $script:TestCfg.TagChoices = @(1..9 | ForEach-Object { 'SN-20' + (10 + $_) })
        Test-Fields $script:SaveNames -Admin | Should -BeTrue
    }
    It 'TagPattern aus den Zusatzfeldern gilt wie in go.ps1' {
        $script:TestCfg['TagPattern'] = '^SN-\d{4}$'
        Test-Fields $script:SaveNames -Admin | Should -BeTrue
        $script:TestCfg.GroupTag = 'Lehrer'
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match 'TagPattern'
        $script:TestCfg['TagPattern'] = '^[unvollstaendig'
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Match 'kein gültiges Muster'
    }
    It 'Standardmuster ist dasselbe wie in go.ps1' {
        $g = Get-Content (Join-Path $script:Root 'Stick\HUPilot\go.ps1') -Raw -Encoding UTF8
        $gp = [regex]::Match($g, "(?m)^\`$TagPattern = '([^']+)'").Groups[1].Value
        Get-TagPattern @{} | Should -Be $gp
    }
    It 'Admin wird nur beim Speichern und beim Paketbau geprueft' {
        $script:SetupText | Should -Match "function Save-Cfg \{\s+if \(-not \(Test-Fields @\('Tenant', 'TenantId', 'ClientId', 'ClientSecret', 'GroupTag', 'WlanSsid', 'WlanKey'\) -Admin\)\)"
        $script:SetupText | Should -Match "Test-Fields @\('WlanSsid', 'WlanKey'\) -Admin"
        @([regex]::Matches($script:SetupText, 'Test-Fields [^\r\n]*-Admin')).Count | Should -Be 3
    }
}

Describe 'Setup: Anmeldung und Secret-Ablauf' {
    It 'unterscheidet kein Netz, abgelaufen, falsch, sonstige Anmeldefehler' {
        Get-TokenErrorKind 'AADSTS7000222: The provided client secret keys are expired' $true | Should -Be 'expired'
        Get-TokenErrorKind 'AADSTS7000215: Invalid client secret provided' $true | Should -Be 'wrong'
        Get-TokenErrorKind 'AADSTS90002: Tenant not found' $true | Should -Be 'config'
        Get-TokenErrorKind 'Der Remotename konnte nicht aufgelöst werden: login.microsoftonline.com' $false | Should -Be 'net'
        Get-TokenErrorKind 'The operation has timed out.' $false | Should -Be 'net'
        Get-TokenErrorKind 'Der Vorgang hat das Zeitlimit überschritten' $true | Should -Be 'net'
        Get-TokenErrorKind 'Bad Gateway' $true | Should -Be 'other'
    }
    It 'Startpruefung: kein Netz wird neutral gemeldet, nicht als ungueltiges Secret' {
        $script:SetupText | Should -Match "TokenErr -eq 'net'\) \{ Set-SubSecret 'Keine Verbindung - Secret nicht geprüft' \`$false"
    }
    It 'SecretExpires: UTC im Format yyyy-MM-ddTHH:mm:ssZ, auch aus Text oder DateTime' {
        $u = ConvertTo-UtcDate '2026-11-20T08:30:00Z'
        $u.Kind | Should -Be 'Utc'
        Format-UtcText $u | Should -Be '2026-11-20T08:30:00Z'
        Format-UtcText (ConvertTo-UtcDate ([datetime]::new(2026, 11, 20, 8, 30, 0, [DateTimeKind]::Utc))) | Should -Be '2026-11-20T08:30:00Z'
        $loc = [datetime]::new(2026, 11, 20, 9, 30, 0, [DateTimeKind]::Local)
        Format-UtcText (ConvertTo-UtcDate $loc) | Should -Be ($loc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') + 'Z')
        Format-UtcText (ConvertTo-UtcDate '2026-11-20T08:30:00.1234567Z') | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        ConvertTo-UtcDate '' | Should -BeNullOrEmpty
        ConvertTo-UtcDate 'kein Datum' | Should -BeNullOrEmpty
        Format-UtcText $null | Should -Be ''
    }
    It 'Warnstufe: abgelaufen, unter 3 Tagen, ok, unbekannt' {
        $now = [datetime]::new(2026, 11, 13, 12, 0, 0, [DateTimeKind]::Utc)
        Get-SecretWarnLevel $now.AddMinutes(-1) $now | Should -Be 'expired'
        Get-SecretWarnLevel $now.AddDays(2.9) $now | Should -Be 'soon'
        Get-SecretWarnLevel $now.AddDays(3.1) $now | Should -Be 'ok'
        Get-SecretWarnLevel $null $now | Should -Be 'unknown'
    }
    It 'Ablaufdatum gilt nur fuer genau das Secret, zu dem es gelesen wurde' {
        $script:SecretEnd = [datetime]::new(2026, 12, 1, 0, 0, 0, [DateTimeKind]::Utc); $script:SecretEndFor = Get-StrHash 'alt'
        $script:SecretExpLoaded = ''; $script:SecretExpLoadedFor = ''
        Get-SecretExpiresValue 'alt' | Should -Be '2026-12-01T00:00:00Z'
        Get-SecretExpiresValue 'neu' | Should -Be ''
        $script:SecretEnd = $null; $script:SecretExpLoaded = '2026-12-24T10:00:00Z'; $script:SecretExpLoadedFor = Get-StrHash 'neu'
        Get-SecretExpiresValue 'neu' | Should -Be '2026-12-24T10:00:00Z'
    }
    It 'SecretExpires bleibt aus den Zusatzfeldern heraus und wird gespeichert' {
        $script:SetupText | Should -Match "'EditionKey','SecretExpires'\) \{ \`$script:Extra"
        $script:SetupText | Should -Match "\`$expUtc = ConvertTo-UtcDate \(Get-SecretExpiresValue"
    }
}

Describe 'Setup: WLAN-Paket aktuell / veraltet / fehlt' {
    BeforeEach {
        $script:TestCfg = New-TestCfg
        $script:Pkg = Join-Path $TestDrive 'HUPilot-WLAN.ppkg'
        $script:Fp = Join-Path $TestDrive 'HUPilot-WLAN.fingerprint.json'
        Remove-Item -LiteralPath $script:Pkg, $script:Fp -Force -ErrorAction SilentlyContinue
    }
    It 'fehlt, aus, fremd' {
        Get-PkgState $script:TestCfg $script:Pkg $script:Fp | Should -Be 'fehlt'
        $script:TestCfg.WlanPackage = ''
        Get-PkgState $script:TestCfg $script:Pkg $script:Fp | Should -Be 'aus'
        $script:TestCfg.WlanPackage = 'Eigenes.ppkg'
        Get-PkgState $script:TestCfg $script:Pkg $script:Fp | Should -Be 'fremd'
    }
    It 'ohne Fingerabdruck: unbekannt; nach dem Bau: aktuell' {
        [System.IO.File]::WriteAllBytes($script:Pkg, [byte[]](1..50))
        Get-PkgState $script:TestCfg $script:Pkg $script:Fp | Should -Be 'unbekannt'
        Write-PkgFingerprint $script:TestCfg $script:Pkg $script:Fp
        Get-PkgState $script:TestCfg $script:Pkg $script:Fp | Should -Be 'aktuell'
    }
    It 'veraltet nach Aenderung von WLAN, Admin oder Paketdatei' {
        [System.IO.File]::WriteAllBytes($script:Pkg, [byte[]](1..50))
        Write-PkgFingerprint $script:TestCfg $script:Pkg $script:Fp
        foreach ($k in 'WlanSsid', 'WlanKey', 'AdminName', 'AdminPassword', 'Admin2Name', 'Admin2Password') {
            $c = New-TestCfg; $c[$k] = 'geaendert1'
            Get-PkgState $c $script:Pkg $script:Fp | Should -Be 'veraltet' -Because $k
        }
        $c = New-TestCfg; $c.Tenant = 'anders'; $c.ClientSecret = 'anders'; $c.GroupTag = 'SN-2030'
        Get-PkgState $c $script:Pkg $script:Fp | Should -Be 'aktuell'
        [System.IO.File]::WriteAllBytes($script:Pkg, [byte[]](1..51))
        Get-PkgState $script:TestCfg $script:Pkg $script:Fp | Should -Be 'veraltet'
    }
    It 'Fingerabdruck enthaelt kein Kennwort im Klartext und ist bei jedem Bau anders' {
        $script:TestCfg.AdminName = 'kustode'; $script:TestCfg.AdminPassword = 'AdminKennwort1'
        [System.IO.File]::WriteAllBytes($script:Pkg, [byte[]](1..50))
        Write-PkgFingerprint $script:TestCfg $script:Pkg $script:Fp
        $t1 = Get-Content -LiteralPath $script:Fp -Raw -Encoding UTF8
        foreach ($s in 'wlanpasswort', 'AdminKennwort1', 'Konfig', 'kustode') { $t1 | Should -Not -Match $s }
        Write-PkgFingerprint $script:TestCfg $script:Pkg $script:Fp
        $t2 = Get-Content -LiteralPath $script:Fp -Raw -Encoding UTF8
        ($t1 | ConvertFrom-Json).Input | Should -Not -Be ($t2 | ConvertFrom-Json).Input
    }
    It 'kaputter Fingerabdruck gilt als unbekannt' {
        [System.IO.File]::WriteAllBytes($script:Pkg, [byte[]](1..50))
        Set-Content -LiteralPath $script:Fp -Value '{kaputt' -Encoding UTF8
        Get-PkgState $script:TestCfg $script:Pkg $script:Fp | Should -Be 'unbekannt'
    }
    It 'Fingerabdruck und ui.json ueberstehen ein Update (Pull.ps1 schont sie) und kommen nie ins Repo' {
        $p = Get-Content (Join-Path $script:Root 'Stick\HUPilot\Setup\Pull.ps1') -Raw -Encoding UTF8
        $keep = [regex]::Match($p, "\`$keepDirs = '([^']+)'").Groups[1].Value
        'HUPilot/HUPilot-WLAN.fingerprint.json' | Should -Match $keep
        'HUPilot/Config/ui.json' | Should -Match $keep
        $gi = Get-Content (Join-Path $script:Root '.gitignore') -Raw -Encoding UTF8
        $gi | Should -Match 'HUPilot-WLAN\.fingerprint\.json'
        $gi | Should -Match 'Config/ui\.json'
    }
}

Describe 'Setup: Kopieren auf den Stick' {
    BeforeEach {
        $script:srcStick = Join-Path $TestDrive 'Quelle'; $script:srcHU = Join-Path $script:srcStick 'HUPilot'
        $srcStick = $script:srcStick; $srcHU = $script:srcHU
        $script:Dst = Join-Path $TestDrive 'Ziel'
        Remove-Item -LiteralPath $script:srcStick, $script:Dst -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:srcHU, (Join-Path $script:Dst 'HUPilot') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:srcStick 'go.cmd') -Value '@echo go' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:srcHU 'go.ps1') -Value '# go' -Encoding UTF8
        [System.IO.File]::WriteAllBytes((Join-Path $script:srcHU 'HUPilot-WLAN.ppkg'), [byte[]](1..80))
        $cfg = New-TestCfg; $cfg.EditionKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'; $cfg.TagChoices = @('SN-2026')
        [System.IO.File]::WriteAllText((Join-Path $script:srcHU 'config.json'), ($cfg | ConvertTo-Json -Depth 3), $script:enc)
        Copy-Item (Join-Path $script:srcStick 'go.cmd') $script:Dst
        Copy-Item (Join-Path $script:srcHU '*') (Join-Path $script:Dst 'HUPilot')
    }
    It 'Kontrolle per SHA256: gleich = keine Abweichung, veraendert oder fehlend = gemeldet' {
        $srcStick = $script:srcStick; $srcHU = $script:srcHU
        $cb = [System.IO.File]::ReadAllBytes((Join-Path $script:srcHU 'config.json'))
        @(Test-StickCopy $script:Dst $cb 'HUPilot-WLAN.ppkg') | Should -BeNullOrEmpty
        [System.IO.File]::WriteAllBytes((Join-Path $script:Dst 'HUPilot\HUPilot-WLAN.ppkg'), [byte[]](1..10))
        Remove-Item -LiteralPath (Join-Path $script:Dst 'go.cmd')
        $r = @(Test-StickCopy $script:Dst $cb 'HUPilot-WLAN.ppkg')
        ($r -join ';') | Should -Match 'go.cmd fehlt'
        ($r -join ';') | Should -Match 'HUPilot-WLAN.ppkg weicht ab'
    }
    It 'ohne MAK: nur EditionKey leer, alles andere gleich, Auswahl bleibt Liste' {
        $b = Get-CfgBytesNoMak (Join-Path $script:srcHU 'config.json')
        $o = $script:enc.GetString($b) | ConvertFrom-Json
        $o.EditionKey | Should -Be ''
        $o.GroupTag | Should -Be 'SN-2026'
        $o.ClientSecret | Should -Be 'abc~geheim'
        $script:enc.GetString($b) | Should -Match '"TagChoices":\s*\[\s*"SN-2026"\s*\]'
        (Get-Content (Join-Path $script:srcHU 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).EditionKey | Should -Be 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
    }
    It 'Hash-Import: Seriennummer im OData-Filter mit verdoppeltem Hochkomma' {
        $script:SetupText | Should -Match "contains\(serialNumber,'`" \+ \(\[string\]\`$r\.Seriennr\)\.Replace\(`"'`", `"''`"\)"
    }
    It 'Starttest bekommt nie eine Rueckfrage beim Schliessen' {
        $script:SetupText | Should -Match "\`$win\.Add_Closing\(\{\s+param\(\`$s, \`$e\)\s+if \(\`$SmokeTest\) \{ return \}"
    }
}

Describe 'Setup: Protokoll mit drei Stufen' {
    It 'alte Zeilenanfaenge werden zu Fehler oder Hinweis' {
        (Split-LogLevel 'FEHLER Anmeldung: x')[0] | Should -Be 'Fehler'
        (Split-LogLevel 'FEHLER Anmeldung: x')[1] | Should -Be 'Anmeldung: x'
        (Split-LogLevel 'FEHLT: WlanKey')[0] | Should -Be 'Fehler'
        (Split-LogLevel 'ACHTUNG: alt')[0] | Should -Be 'Hinweis'
        (Split-LogLevel 'Gespeichert')[0] | Should -Be ''
        (Split-LogLevel 'Fehlerfrei gespeichert')[0] | Should -Be ''
    }
    It 'Secrets, Kennwoerter und Schluessel kommen nie ins Protokoll' {
        $o = Hide-LogSecrets 'Secret abc~geheim1, WLAN wlanpasswort, MAK AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' @('abc~geheim1', 'wlanpasswort', '', 'ab')
        $o | Should -Not -Match 'abc~geheim1'
        $o | Should -Not -Match 'wlanpasswort'
        $o | Should -Not -Match 'AAAAA-BBBBB'
        $o | Should -Match '\*\*\*\*\*-\*\*\*\*\*-\*\*\*\*\*-\*\*\*\*\*-EEEEE'
        Hide-LogSecrets 'ab ab' @('ab') | Should -Be 'ab ab'
    }
    It 'fehlende Felder heissen wie im Fenster, mit naechstem Schritt' {
        $script:TestCfg = New-TestCfg; $script:TestCfg.WlanKey = ''
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Be 'WLAN-Kennwort fehlt. Bitte oben eintragen.'
        $script:TestCfg.WlanSsid = ''
        Test-Fields $script:SaveNames -Admin | Should -BeFalse
        $script:FieldErr | Should -Be 'Es fehlen: WLAN-Name, WLAN-Kennwort. Bitte oben eintragen.'
    }
    It 'keine alten Praefixe mehr in den Meldungen, Protokolldatei ohne Stick-Kopie' {
        @([regex]::Matches($script:SetupText, "(Out-Log|& \`$plog|& \`$hlog|Stop-Field) \(?'(FEHLER|FEHLT|ACHTUNG|WARNUNG|ABBRUCH)")).Count | Should -Be 0
        $script:SetupText | Should -Match "'setup_' \+ \(Get-Date -Format 'yyyyMMdd_HHmm'\) \+ '\.log'"
        $script:SetupText | Should -Match "Select-Object -Skip 19"
        $script:SetupText | Should -Match "Where-Object \{ \`$_\.Name -ne 'logs' -and"
    }
}

Describe 'Setup: Status in Klartext' {
    BeforeAll {
        $script:StandClass = @{ 'Fertig' = 'ok'; 'Wartet auf Profil' = 'warn'; 'Profil da, Gerät noch nicht angemeldet' = 'warn'; 'Kein Profil für diesen Tag' = 'err'; 'Fehler' = 'err' }
    }
    It 'Stand aus Profilstatus und Intune-Status' {
        Get-DeviceStand 'assignedInSync' 'enrolled' $true | Should -Be 'Fertig'
        Get-DeviceStand 'notAssigned' 'enrolled' $false | Should -Be 'Fertig'
        Get-DeviceStand 'assignedInSync' 'notContacted' $true | Should -Be 'Profil da, Gerät noch nicht angemeldet'
        Get-DeviceStand 'assignedOutOfSync' 'notContacted' $true | Should -Be 'Profil da, Gerät noch nicht angemeldet'
        Get-DeviceStand 'assignedInSync' 'notContacted' $false | Should -Be 'Wartet auf Profil'
        Get-DeviceStand 'pending' 'notContacted' $false | Should -Be 'Wartet auf Profil'
        Get-DeviceStand 'unknown' '' $false | Should -Be 'Wartet auf Profil'
        Get-DeviceStand 'notAssigned' 'notContacted' $false | Should -Be 'Kein Profil für diesen Tag'
        Get-DeviceStand 'assignedInSync' 'failed' $true | Should -Be 'Fehler'
        Get-DeviceStand 'assignedInSync' 'blocked' $true | Should -Be 'Fehler'
        Get-DeviceStand 'failed' 'notContacted' $false | Should -Be 'Fehler'
    }
    It 'Was tun: ein Satz je Stand' {
        Get-DeviceTodo 'Fertig' '' 'enrolled' | Should -Match '^Nichts'
        Get-DeviceTodo 'Wartet auf Profil' 'pending' '' | Should -Match 'läuft'
        Get-DeviceTodo 'Wartet auf Profil' 'assignedOutOfSync' '' | Should -Match 'Sync'
        Get-DeviceTodo 'Profil da, Gerät noch nicht angemeldet' '' '' | Should -Match 'WLAN'
        Get-DeviceTodo 'Kein Profil für diesen Tag' 'notAssigned' '' | Should -Match 'Tag prüfen'
        Get-DeviceTodo 'Fehler' '' 'blocked' | Should -Match 'blockiert'
        Get-DeviceTodo 'Fehler' '' 'failed' | Should -Match 'Intune'
        foreach ($s in $script:StandClass.Keys) { Get-DeviceTodo $s '' '' | Should -Not -BeNullOrEmpty -Because $s }
    }
    It 'Spalten mit deutschen Ueberschriften, feste Spalten statt automatisch' {
        $script:SetupText | Should -Match "Key = 'LetzterKontakt'; Header = 'Letzter Kontakt'"
        $script:SetupText | Should -Match "Key = 'WasTun'; Header = 'Was tun'"
        $sx = @($script:XamlBlocks | Where-Object { $_.Name -eq 'sx' })[0].Xaml
        $sx | Should -Match 'x:Name="dGrid"[^>]*AutoGenerateColumns="False"'
        $sx | Should -Match 'SelectionMode="Extended"'
    }
    It 'Excel bekommt die deutschen Ueberschriften und faerbt nach Stand' {
        $p = Join-Path $TestDrive 'status.xlsx'
        $rows = @([pscustomobject]@{ Stand = 'Fertig'; Seriennr = 'A1' }, [pscustomobject]@{ Stand = 'Fehler'; Seriennr = 'B2' }, [pscustomobject]@{ Stand = 'Wartet auf Profil'; Seriennr = 'C3' })
        Export-StatusXlsx -Rows $rows -Cols @('Stand', 'Seriennr') -Headers @('Stand', 'Seriennummer') -Path $p
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($p)
        try { $r = New-Object System.IO.StreamReader($z.GetEntry('xl/worksheets/sheet1.xml').Open()); $x = $r.ReadToEnd(); $r.Dispose() } finally { $z.Dispose() }
        $x | Should -Match '<t>Seriennummer</t>'
        $x | Should -Match 'r="A2" s="3"'
        $x | Should -Match 'r="A3" s="5"'
        $x | Should -Match 'r="A4" s="4"'
    }
    It 'Aktionen nur mit Rueckfrage, keine Loesch-Aktion, Sync 409/429 kein Fehler' {
        $script:SetupText | Should -Match "Tag `"' \+ \`$pick\.Tag \+ '`" setzen für"
        $script:SetupText | Should -Match "if \(\`$code -in 409, 429\)"
        $script:SetupText | Should -Not -Match "Method DELETE -Uri \('https://graph\.microsoft\.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/"
    }
    It 'Automatisch aktualisieren: Timer stoppt beim Schliessen, nicht bei offenem Dialog' {
        $script:SetupText | Should -Match '\$tm\.Add_Tick\(\{ if \(\$g\.cAuto\.IsChecked -and -not \$sst\.Loading -and -not \$sst\.Dialog\)'
        $script:SetupText | Should -Match '\$sw\.Add_Closing\(\{\s+\$tm\.Stop\(\)'
    }
}

Describe 'Setup: Befunde der Pruefung' {
    It 'Kopieren ohne MAK: config.json wird nie mit MAK auf den Stick geschrieben' {
        $srcStick = Join-Path $TestDrive 'MQ'; $srcHU = Join-Path $srcStick 'HUPilot'; $srcCfg = Join-Path $srcHU 'config.json'; $srcPkg = Join-Path $srcHU 'HUPilot-WLAN.ppkg'
        $dst = Join-Path $TestDrive 'MZ'
        New-Item -ItemType Directory -Path $srcHU, (Join-Path $dst 'HUPilot') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $srcStick 'go.cmd') -Value '@echo go' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $srcHU 'go.ps1') -Value '# go' -Encoding UTF8
        $cfg = New-TestCfg; $cfg.EditionKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'; $cfg.WlanPackage = ''
        [System.IO.File]::WriteAllText($srcCfg, ($cfg | ConvertTo-Json -Depth 3), $script:enc)
        # alte config.json mit MAK auf dem Stick: muss sofort ersetzt werden
        [System.IO.File]::WriteAllText((Join-Path $dst 'HUPilot\config.json'), ($cfg | ConvertTo-Json -Depth 3), $script:enc)
        $script:TestCfg = $cfg
        Copy-ToStick $dst $false | Should -BeTrue
        (Get-Content (Join-Path $dst 'HUPilot\config.json') -Raw -Encoding UTF8) | Should -Not -Match 'AAAAA-BBBBB'
        $script:SetupText | Should -Match "Where-Object \{ \`$_\.Name -ne 'logs' -and \`$_\.Name -ne 'config\.json' -and"
        # config.json wird vor der Kopierschleife geschrieben
        $i1 = $script:SetupText.IndexOf("[System.IO.File]::WriteAllBytes((Join-Path `$dst 'config.json'), `$cfgBytes)")
        $i2 = $script:SetupText.IndexOf("`$_.Name -ne 'config.json' -and")
        $i1 | Should -BeGreaterThan 0
        $i1 | Should -BeLessThan $i2
    }
    It 'altes WLAN-Paket am Stick, das nicht aus der Quelle stammt, wird entfernt und sonst gemeldet' {
        $srcStick = Join-Path $TestDrive 'PQ'; $srcHU = Join-Path $srcStick 'HUPilot'; $srcCfg = Join-Path $srcHU 'config.json'; $srcPkg = Join-Path $srcHU 'HUPilot-WLAN.ppkg'
        $dst = Join-Path $TestDrive 'PZ'
        New-Item -ItemType Directory -Path $srcHU, (Join-Path $dst 'HUPilot') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $srcStick 'go.cmd') -Value '@echo go' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $srcHU 'go.ps1') -Value '# go' -Encoding UTF8
        $cfg = New-TestCfg; [System.IO.File]::WriteAllText($srcCfg, ($cfg | ConvertTo-Json -Depth 3), $script:enc)
        foreach ($n in 'HUPilot-WLAN.ppkg', 'HUPilot-WLAN.cat', 'HUPilot-WLAN.fingerprint.json') { [System.IO.File]::WriteAllBytes((Join-Path $dst ('HUPilot\' + $n)), [byte[]](1..5)) }
        @(Get-StaleStickPkg $dst).Count | Should -Be 3
        $cb = [System.IO.File]::ReadAllBytes($srcCfg)
        (@(Test-StickCopy $dst $cb 'HUPilot-WLAN.ppkg') -join ';') | Should -Match 'HUPilot-WLAN\.ppkg liegt am Stick'
        $script:TestCfg = $cfg
        Copy-ToStick $dst $true | Should -BeTrue
        @(Get-StaleStickPkg $dst).Count | Should -Be 0
    }
    It 'kaputte config.json: Meldung ohne Dateiinhalt (unter 5.1 steht er in der Parser-Meldung)' {
        $p = Join-Path $TestDrive 'kaputt.json'
        [System.IO.File]::WriteAllText($p, '{"ClientSecret":"geheim-xyz" "WlanKey":"wlan-xyz"}', $script:enc)
        $r = Read-CfgFile $p
        $r.Cfg | Should -BeNullOrEmpty
        ($r.Error + $r.Detail) | Should -Not -Match 'geheim-xyz'
        ($r.Error + $r.Detail) | Should -Not -Match 'wlan-xyz'
        $r.Error | Should -Match '3\. Speichern'
        $ok = Join-Path $TestDrive 'gut.json'; [System.IO.File]::WriteAllText($ok, '{"Tenant":"T"}', $script:enc)
        (Read-CfgFile $ok).Cfg.Tenant | Should -Be 'T'
    }
    It 'SecretExpires aus config.json bleibt im Vertragsformat (PS 7 liefert DateTime), unlesbar = leer' {
        $o = '{"SecretExpires":"2026-11-20T08:30:00Z","Leer":"","Kaputt":"morgen"}' | ConvertFrom-Json
        Format-UtcText (ConvertTo-UtcDate $o.SecretExpires) | Should -Be '2026-11-20T08:30:00Z'
        Format-UtcText (ConvertTo-UtcDate $o.Leer) | Should -Be ''
        Format-UtcText (ConvertTo-UtcDate $o.Kaputt) | Should -Be ''
        $script:SetupText | Should -Match '\$script:SecretExpLoaded = Format-UtcText \(ConvertTo-UtcDate \$c\.SecretExpires\)'
        $script:SetupText | Should -Match "\`$o\['SecretExpires'\] = Format-UtcText \`$expUtc"
        $script:SetupText | Should -Not -Match '\(ConvertTo-UtcDate \$o\.SecretExpires\)\.ToLocalTime\(\)'
    }
    It 'ICD-Ausgabe: Kennwoerter roh und XML-escapt sowie der Base64-Block werden ausgeblendet' {
        $c = New-TestCfg; $c.WlanKey = 'a<b&c"d1'; $c.AdminPassword = 'Admin&Pw1'
        $b64 = 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo='
        $o = Hide-IcdText ('Key a&lt;b&amp;c&quot;d1 und a<b&c"d1, Admin&amp;Pw1, -EncodedCommand ' + $b64 + ' und -EncodedCommand QUJDREVGR0hJSktMTU5PUA==') $c $b64
        $o | Should -Not -Match 'a&lt;b'
        $o | Should -Not -Match 'a<b&c'
        $o | Should -Not -Match 'Admin&amp;Pw1'
        $o | Should -Not -Match 'QUJDREVGR0hJSktM'
    }
    It 'Stufen werden nicht mehr aus kleingeschriebenen Woertern geraten' {
        (Split-LogLevel 'Abbruch angefordert, warte')[0] | Should -Be ''
        (Split-LogLevel 'Fehlerhafte Zeile')[0] | Should -Be ''
        (Split-LogLevel 'FEHLER: x')[0] | Should -Be 'Fehler'
    }
    It 'Secret-Kennung (hint) nicht in der Protokolldatei, Knoepfe gesperrt, Busy vor Update-Neustart' {
        $script:SetupText | Should -Match "Out-Log \`$txt 'OK' '' \`$ftx"
        $script:SetupText | Should -Match "\`$ftx = 'Secret `"' \+ \`$pc\.displayName \+ '`" gültig bis"
        $script:SetupText | Should -Match "foreach \(\`$n in 'bReady', 'bTest', 'bTags', 'bWrite', 'bPkg', 'bCopy', 'bPrep', 'bLoad', 'bUpd'"
        $i1 = $script:SetupText.IndexOf('if ($script:Busy) { $e.Cancel = $true')
        $i2 = $script:SetupText.IndexOf('if ($script:NoClosePrompt) { return }')
        $i1 | Should -BeGreaterThan 0
        $i1 | Should -BeLessThan $i2
    }
    It 'Status: stilles Aktualisieren, Token wiederverwenden, Pause nach zwei Netzfehlern, Auffrischen abgesichert' {
        $script:SetupText | Should -Match '\$tm\.Add_Tick\(\{ if \(\$g\.cAuto\.IsChecked -and -not \$sst\.Loading -and -not \$sst\.Dialog\) \{ & \$load \$true \} \}\)'
        $script:SetupText | Should -Match '\$tok = Get-ApiTokenCached; if \(-not \$tok\) \{ return \$null \}'
        $script:SetupText | Should -Match "if \(\`$sst\.Fails -ge 2 -and \`$script:TokenErr -eq 'net'\) \{ \`$tm\.Stop\(\)"
        $script:SetupText | Should -Match 'try \{ & \$refresh \} catch \{ Out-Log'
    }
    It 'ui.json schreibt eine Spaltenliste auch mit einem Eintrag als Liste' {
        $o = [ordered]@{}; $o['StatusCols'] = @('Stand|0|120')
        ([pscustomobject]$o | ConvertTo-Json -Compress) | Should -Be '{"StatusCols":["Stand|0|120"]}'
    }
}