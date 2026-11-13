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
        'Test-StickCopy', 'Get-CfgBytesNoMak', 'Split-LogLevel', 'Hide-LogSecrets', 'Get-DeviceStand', 'Get-DeviceTodo', 'Export-StatusXlsx', 'Get-FitWidth', 'Get-FileShaCached', 'Get-StaleStickPkg', 'Read-CfgFile', 'Hide-IcdText', 'Copy-ToStick',
        'Test-SkipForStick', 'Copy-IcdToStick', 'Get-IcdVersion', 'Compare-IcdVersion', 'Find-Icd', 'Get-IcdText', 'Get-IcdFileList', 'New-IcdManifest', 'Test-IcdCopy', 'Get-IcdCopyVersion',
        'Get-DriveSelection', 'Get-PrepKeep', 'Get-PrepKey', 'Get-ReadyTodo', 'New-StickId', 'Compare-StickId', 'Get-StickKey', 'Get-KeptLeft'
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
    It 'jedes Fenster laedt mit XamlReader (STA), ohne Theme, dunkel und hell, und schaltet zur Laufzeit um' {
        $get = { param($n) [regex]::Match($script:SetupText, "(?s)\`$script:$n = @'\r?\n(.*?)\r?\n'@").Groups[1].Value }
        $theme = & $get 'HuThemeXaml'; $dark = & $get 'HuColorsDark'; $light = & $get 'HuColorsLight'
        $fn = @($script:SetupAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in 'Add-HuTheme', 'Get-HuColorsXaml', 'Register-HuWindow', 'Set-HuTheme' } | ForEach-Object { $_.Extent.Text }) -join "`n"
        $theme | Should -Match '<ResourceDictionary'
        $fn | Should -Match 'function Set-HuTheme'
        $load = {
            param($blocks, $themeText, $darkText, $lightText, $fnText)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $script:HuThemeXaml = $themeText; $script:HuColorsDark = $darkText; $script:HuColorsLight = $lightText
            $script:HuWindows = New-Object System.Collections.ArrayList
            . ([scriptblock]::Create($fnText))
            foreach ($b in $blocks) {
                foreach ($mode in 'ohne', 'dunkel', 'hell') {
                    try {
                        $x = [xml]$b.Xaml
                        if ($mode -ne 'ohne') { $script:HuTheme = $mode; Add-HuTheme $x }
                        $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
                        if ($mode -ne 'ohne') {
                            $soll = $(if ($mode -eq 'hell') { '#FFF3F3F3' } else { '#FF1E1E1E' })
                            if ("$($w.Background)" -ne $soll) { throw "Hintergrund $($w.Background)" }
                            # zur Laufzeit auf das andere Theme und zurueck
                            Register-HuWindow $w
                            $other = $(if ($mode -eq 'hell') { 'dunkel' } else { 'hell' })
                            Set-HuTheme $other
                            $soll2 = $(if ($other -eq 'hell') { '#FFF3F3F3' } else { '#FF1E1E1E' })
                            if ("$($w.Background)" -ne $soll2) { throw "nach Umschalten Hintergrund $($w.Background)" }
                            Set-HuTheme $mode
                            $script:HuWindows.Clear()
                        }
                        "$($b.Name) $($mode): OK"
                    } catch { "$($b.Name) $($mode): $($_.Exception.Message)" }
                }
            }
        }
        $res = @()
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { $res = @(& $load $script:XamlBlocks $theme $dark $light $fn) }
        else {
            $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
            try { $ps = [powershell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript($load).AddArgument($script:XamlBlocks).AddArgument($theme).AddArgument($dark).AddArgument($light).AddArgument($fn); $res = @($ps.Invoke() | ForEach-Object { "$_" }) } finally { $rs.Close() }
        }
        @($res | Where-Object { $_ -notmatch ': OK$' }) | Should -BeNullOrEmpty
        $res.Count | Should -Be (3 * $script:XamlBlocks.Count)
    }
    It 'helles und dunkles Farb-Woerterbuch haben dieselben Schluessel, alle verwendeten Schluessel sind definiert' {
        $get = { param($n) [regex]::Match($script:SetupText, "(?s)\`$script:$n = @'\r?\n(.*?)\r?\n'@").Groups[1].Value }
        $keys = { param($t) @([regex]::Matches($t, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object) }
        $kd = & $keys (& $get 'HuColorsDark'); $kl = & $keys (& $get 'HuColorsLight')
        ($kd -join ',') | Should -Be ($kl -join ',')
        $used = @([regex]::Matches($script:SetupText, '(?:DynamicResource |SetResourceReference\([^,]+, '')(Hu[A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $used += @([regex]::Matches($script:SetupText, "= '(Hu(?:Ok|Warn|Err|Muted|LampOpen|Run))'") | ForEach-Object { $_.Groups[1].Value })
        $missing = @($used | Sort-Object -Unique | Where-Object { $kd -notcontains $_ })
        $missing | Should -BeNullOrEmpty
    }
    It 'keine festen Farben mehr in den Fenstern ausser Druck, Excel und Bildlaufleisten' {
        $blocks = @($script:XamlBlocks | ForEach-Object { $_.Xaml }) -join "`n"
        $hex = @([regex]::Matches($blocks, '(?:Foreground|Background|BorderBrush|Fill|Value)="(#[0-9A-Fa-f]{6,8})"') | ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '#FF6A6A6A|#18808080' } | Sort-Object -Unique)
        $hex | Should -BeNullOrEmpty
    }
    It 'Theme gemerkt in ui.json, Starttest zeigt beide Themes' {
        $script:SetupText | Should -Match "Set-UiSetting 'Theme' \`$script:HuTheme"
        $script:SetupText | Should -Match "if \(\[string\]\`$tj\.Theme -eq 'hell'\) \{ \`$script:HuTheme = 'hell' \}"
        $script:SetupText | Should -Match "foreach \(\`$th in @\(\`$\(if \(\`$t0 -eq 'hell'\) \{ 'dunkel' \} else \{ 'hell' \}\), \`$t0\)\) \{ Set-HuTheme \`$th"
        foreach ($v in 'win', 'pw', 'vw', 'dw', 'sw', 'gw', 'hw') { $script:SetupText | Should -Match ('Register-HuWindow \$' + $v + '\b') }
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
        # Stick-Auswahl in der festen Leiste beim Hauptknopf, nicht im Scrollbereich
        $x.SelectSingleNode("//w:ScrollViewer[@x:Name='svMain']//*[@x:Name='cDrive']", $ns) | Should -BeNullOrEmpty
        $x.SelectSingleNode("//w:Border[@x:Name='bdReady']//w:ComboBox[@x:Name='cDrive']", $ns) | Should -Not -BeNullOrEmpty
        $x.SelectSingleNode("//w:Border[@x:Name='bdReady']//w:Button[@x:Name='bReload']", $ns) | Should -Not -BeNullOrEmpty
        # Protokoll laesst dem Formular mindestens 200 px, der gemerkte Wert bleibt
        $script:SetupText | Should -Match 'return \[math\]::Max\(80, \[math\]::Min\(800, \$avail - \$form\)\)'
        $script:SetupText | Should -Match 'Set-UiSetting ''LogHeight'' \(\[int\]\$script:LogWanted\)'
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
        $script:SetupText | Should -Match "Where-Object \{ -not \(Test-SkipForStick \`$_\.Name\) \}"
        Test-SkipForStick 'logs' | Should -BeTrue
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
        $script:SetupText | Should -Match 'if \(\$g\.cAuto\.IsChecked -and -not \$sst\.Loading -and -not \$sst\.Dialog\) \{ & \$load \$true \}'
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
        $script:SetupText | Should -Match "Where-Object \{ -not \(Test-SkipForStick \`$_\.Name\) \}"
        Test-SkipForStick 'config.json' | Should -BeTrue
        # config.json wird vor der Kopierschleife geschrieben
        $i1 = $script:SetupText.IndexOf("[System.IO.File]::WriteAllBytes((Join-Path `$dst 'config.json'), `$cfgBytes)")
        $i2 = $script:SetupText.IndexOf("Where-Object { -not (Test-SkipForStick `$_.Name) }")
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
        $script:SetupText | Should -Match 'if \(\$g\.cAuto\.IsChecked -and -not \$sst\.Loading -and -not \$sst\.Dialog\) \{ & \$load \$true \} \} catch \{ \} \}\)'
        $script:SetupText | Should -Match '\$tok = Get-ApiTokenCached; if \(-not \$tok\) \{ return \$null \}'
        $script:SetupText | Should -Match "if \(\`$sst\.Fails -ge 2 -and \`$script:TokenErr -eq 'net'\) \{ \`$tm\.Stop\(\)"
        $script:SetupText | Should -Match 'try \{ & \$refresh \} catch \{ Out-Log'
    }
    It 'ui.json schreibt eine Spaltenliste auch mit einem Eintrag als Liste' {
        $o = [ordered]@{}; $o['StatusCols'] = @('Stand|0|120')
        ([pscustomobject]$o | ConvertTo-Json -Compress) | Should -Be '{"StatusCols":["Stand|0|120"]}'
    }
}

Describe 'Setup: Tabellen ganz anzeigen, nichts klebt zusammen' {
    It 'Unterfenster bleiben ganz im Bildschirm (nicht nur mittig ueber dem Hauptfenster)' {
        $script:SetupText | Should -Not -Match 'if \(\$w\.Owner -and \$fits\) \{ return \}'
        $script:SetupText | Should -Match '\$w\.Top = \[math\]::Max\(\$wa\.Top, \[math\]::Min\(\$top, \$wa\.Bottom - \$wh\)\)'
    }
    It 'Fenster so breit wie die Spalten: Status, Versionsauswahl, Tags, Hashes' {
        $script:SetupText | Should -Match 'function Set-GridWindowWidth\('
        $script:SetupText | Should -Match '\$vw\.Add_ContentRendered\(\{[^\r\n]*Set-GridWindowWidth \$vw'
        $script:SetupText | Should -Match '\$gw\.Add_ContentRendered\(\{[^\r\n]*Set-GridWindowWidth \$gw'
        $script:SetupText | Should -Match '\$hw\.Add_ContentRendered\(\{[^\r\n]*Set-GridWindowWidth \$hw'
        $script:SetupText | Should -Match 'Set-GridColumnsFit \$g\.dGrid @\(\$script:StatusView\)'
        $script:SetupText | Should -Not -Match 'Set-GridColumnsFit \$g\.dGrid \$script:SRows'
        $script:SetupText | Should -Not -Match 'MaxWidth = 460'
        $script:SetupText | Should -Not -Match 'Header="Datei" Binding="\{Binding Datei\}" Width="\*"'
    }
    It 'Gemerkte Spaltenbreiten nur, wenn sie mindestens so breit wie der Inhalt sind' {
        $script:SetupText | Should -Not -Match 'SavedW'
        Get-FitWidth 50 30 18 320 | Should -Be 68
        Get-FitWidth 20 60 18 320 | Should -Be 90
        Get-FitWidth 900 30 18 320 | Should -Be 320
        # Luft im Aufruf: 16 Zellabstand + 2 Rahmen + 4 fester Textrand der Textspalte
        $script:SetupText | Should -Match 'Get-FitWidth \(\$m \+ \$ex\) \$h 22 \$mx'
    }
    It 'Status: Breiten nach der angezeigten Liste, bei jeder Aenderung; von Hand Gezogenes und Fenstergroesse des Anwenders bleiben' {
        # $refresh (Filter, Suche, Kachel, Laden, automatisches Aktualisieren) passt danach Spalten und Fenster an
        $ref = [regex]::Match($script:SetupText, '(?s)\n    \$refresh = \{\r?\n(.*?)\r?\n    \}\r?\n').Groups[1].Value
        $ref | Should -Match '\$script:StatusView = \$v'
        $ref | Should -Match 'try \{ & \$fitCols \} catch \{ \}'
        $ref | Should -Match 'if \(\$sst\.FromSearch\) \{ \$wtm\.Stop\(\); \$wtm\.Start\(\) \} else \{ try \{ & \$fitWin \} catch \{ \} \}'
        $script:SetupText | Should -Match '\$sst\.FromSearch = \$true; try \{ & \$refresh \} finally \{ \$sst\.FromSearch = \$false \}'
        $script:SetupText | Should -Match '\$wtm\.Interval = \[TimeSpan\]::FromMilliseconds\(400\)'
        # von Hand gezogene Spalten werden uebersprungen
        $script:SetupText | Should -Match "@\('Stand'\) @\(\`$sst\.ManualCols\.Keys\)"
        $script:SetupText | Should -Match 'Thumb\]::DragCompletedEvent'
        # Fenster nur anpassen, solange der Anwender es nicht selbst veraendert oder maximiert hat
        $script:SetupText | Should -Match "if \(\`$sst\.UserSized -or \[string\]\`$sw\.WindowState -ne 'Normal'\) \{ return \}"
        $script:SetupText | Should -Match '\$sw\.Add_StateChanged\('
    }
    It 'Breite je Spalte = breitester Text der uebergebenen (angezeigten) Zeilen, leere Spalte = Ueberschrift' {
        $fn = @($script:SetupAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in 'Get-FitWidth', 'Measure-TextWidth', 'Measure-TextWidthRaw', 'Get-TrimStyle', 'Set-GridColumnsFit' } | ForEach-Object { $_.Extent.Text }) -join "`n"
        $fn | Should -Match 'function Set-GridColumnsFit'
        $calc = {
            param($fnText)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $script:TrimStyles = @{}
            . ([scriptblock]::Create($fnText))
            $g = New-Object System.Windows.Controls.DataGrid
            foreach ($k in 'Seriennr', 'Modell', 'Benutzer') {
                $c = New-Object System.Windows.Controls.DataGridTextColumn; $c.Header = $k; $c.Binding = New-Object System.Windows.Data.Binding($k); $g.Columns.Add($c)
            }
            # 289 geladen: 21 kurze fertige Geraete, der Rest mit langen Werten
            $kurz = @(1..21 | ForEach-Object { [pscustomobject]@{ Seriennr = 'PF' + $_; Modell = '82YT'; Benutzer = '' } })
            $lang = @(1..268 | ForEach-Object { [pscustomobject]@{ Seriennr = 'SN26-PF21W4LQA-SEHR-LANG-' + $_; Modell = 'HP ProBook 440 14 inch G10 Notebook PC'; Benutzer = 'mustermann.maximilian@example.org' } })
            $w = { param($rows, $skip) Set-GridColumnsFit $g $rows @{} @{} @() $skip; @($g.Columns | ForEach-Object { [double]$_.Width.Value }) }
            $nurKurz = & $w $kurz @()
            $alle = & $w @($kurz + $lang) @()
            $gefiltert = & $w $kurz @()
            $hs = @('Seriennr', 'Modell', 'Benutzer' | ForEach-Object { [double](Get-FitWidth 0 (Measure-TextWidth $_ (New-Object System.Windows.Media.Typeface($g.FontFamily, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)) $g.FontSize) 22 320) })
            # von Hand gezogene Spalte bleibt
            $g.Columns[1].Width = New-Object System.Windows.Controls.DataGridLength(250)
            $skip = & $w $kurz @('Modell')
            ($nurKurz -join ';') + '|' + ($alle -join ';') + '|' + ($gefiltert -join ';') + '|' + ($hs -join ';') + '|' + ($skip -join ';')
        }
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { $res = "$(& $calc $fn)" }
        else {
            $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
            try { $ps = [powershell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript($calc).AddArgument($fn); $res = "$(@($ps.Invoke())[-1])" } finally { $rs.Close() }
        }
        $p = $res -split '\|'
        $p.Count | Should -Be 5
        $kurz = @($p[0] -split ';' | ForEach-Object { [double]$_ }); $alle = @($p[1] -split ';' | ForEach-Object { [double]$_ })
        $gef = @($p[2] -split ';' | ForEach-Object { [double]$_ }); $hs = @($p[3] -split ';' | ForEach-Object { [double]$_ }); $skip = @($p[4] -split ';' | ForEach-Object { [double]$_ })
        # nach dem Filtern genau so breit wie mit nur den kurzen Zeilen, nicht wie mit allen geladenen
        ($gef -join ';') | Should -Be ($kurz -join ';')
        $gef[0] | Should -BeLessThan $alle[0]
        $gef[1] | Should -BeLessThan $alle[1]
        # Modell "82YT" ist kuerzer als die Ueberschrift: Spalte so breit wie die Ueberschrift; leere Spalte Benutzer ebenso
        $gef[1] | Should -Be $hs[1]
        $gef[2] | Should -Be $hs[2]
        $alle[1] | Should -BeGreaterThan $hs[1]
        # uebersprungene Spalte behaelt die gezogene Breite, die anderen werden berechnet
        $skip[1] | Should -Be 250
        $skip[0] | Should -Be $kurz[0]
    }
    It 'Luft in den Zellen, Stand nur als farbiges Schild' {
        $script:SetupText | Should -Match '<Setter Property="Padding" Value="8,3,8,3"/>'
        $script:SetupText | Should -Match '<Setter Property="MinRowHeight" Value="26"/>'
        $script:SetupText | Should -Match "if \(\`$col\.Key -eq 'Stand'\) \{ try \{ \`$dc\.ElementStyle = \`$standStyle \}"
        $script:SetupText | Should -Match 'HuStandOkBg'
    }
}

Describe 'Setup: Paketbau mitnehmen (Test)' {
    BeforeAll {
        $script:IcdSigExt = @('.exe', '.dll', '.sys', '.mui')
        # Attrappe fuer Signaturen: Dateien, deren Inhalt mit "MS-SIG" beginnt, gelten als eigene, gueltige Microsoft-Signatur,
        # "FREMD-SIG" als eigene Signatur eines anderen Herstellers, alles andere als unsigniert
        $script:FakeSig = {
            param($p)
            $s = [System.IO.File]::ReadAllText($p)
            if ($s.StartsWith('MS-SIG')) { return [pscustomobject]@{ Valid = $true; Ms = $true; Embedded = $true } }
            if ($s.StartsWith('FREMD-SIG')) { return [pscustomobject]@{ Valid = $true; Ms = $false; Embedded = $true } }
            return [pscustomobject]@{ Valid = $false; Ms = $false; Embedded = $false }
        }
        function New-FakeIcd([string]$Root) {
            $x86 = Join-Path $Root 'x86'
            if (Test-Path -LiteralPath $x86) { Remove-Item -LiteralPath $x86 -Recurse -Force }
            New-Item -ItemType Directory -Path (Join-Path $x86 'de') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $x86 'ICD.exe') -Value 'MS-SIG icd' -NoNewline
            Set-Content -LiteralPath (Join-Path $x86 'ICDCore.dll') -Value 'MS-SIG core' -NoNewline
            Set-Content -LiteralPath (Join-Path $x86 'Newtonsoft.Json.dll') -Value 'unsigniert im Original' -NoNewline
            Set-Content -LiteralPath (Join-Path $x86 'de\ICDUI.resources.dll') -Value 'unsigniert' -NoNewline
            Set-Content -LiteralPath (Join-Path $x86 'Microsoft-Common-Provisioning.dat') -Value 'speicher' -NoNewline
            $man = New-IcdManifest $x86 '10.0.28000.1' $script:FakeSig
            [System.IO.File]::WriteAllText((Join-Path $Root 'HUPilot-ICD.json'), ($man | ConvertTo-Json -Depth 4))
            return $x86
        }
    }
    BeforeEach {
        $script:IcdTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('HUPilot-IcdTest-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:IcdTmp -Force | Out-Null
    }
    AfterEach { Remove-Item -LiteralPath $script:IcdTmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Suchreihenfolge: zuerst das installierte ADK, sonst die Kopie, sonst nichts' {
        $inst = Join-Path $script:IcdTmp 'ADK\ICD.exe'; $cp = Join-Path $script:IcdTmp 'HUPilot\ADK-ICD\x86'
        New-Item -ItemType Directory -Path (Split-Path $inst -Parent), $cp -Force | Out-Null
        Find-Icd $inst $cp | Should -BeNullOrEmpty
        Get-IcdText (Find-Icd $inst $cp) | Should -Be 'ICD.exe fehlt'
        Set-Content -LiteralPath (Join-Path $cp 'ICD.exe') -Value 'x'
        (Find-Icd $inst $cp).Source | Should -Be 'Kopie'
        (Find-Icd $inst $cp).Path | Should -Be (Join-Path $cp 'ICD.exe')
        Get-IcdText (Find-Icd $inst $cp) | Should -Match '^ICD\.exe aus der Kopie in der Quelle \(Test\), Version'
        Set-Content -LiteralPath $inst -Value 'x'
        (Find-Icd $inst $cp).Source | Should -Be 'ADK'
        (Find-Icd $inst $cp).Path | Should -Be $inst
        Get-IcdText (Find-Icd $inst $cp) | Should -Match '^ICD\.exe aus dem Windows ADK am PC, Version'
        # ohne ADK und ohne Kopie: kein Fehler, nur "fehlt"
        Find-Icd '' '' | Should -BeNullOrEmpty
    }
    It 'Versionen vergleichen fuer den Hinweis "Kopie aktualisieren"' {
        Compare-IcdVersion '10.0.28000.1' '10.0.26100.1' | Should -Be 1
        Compare-IcdVersion '10.0.26100.1' '10.0.28000.1' | Should -Be -1
        Compare-IcdVersion '10.0.28000.1' '10.0.28000.1' | Should -Be 0
        Compare-IcdVersion '10.0.28000.1' 'unbekannt' | Should -Be 0
        Get-IcdCopyVersion (Join-Path $script:IcdTmp 'fehlt\x86') (Join-Path $script:IcdTmp 'fehlt\HUPilot-ICD.json') | Should -Be ''
    }
    It 'Pruefliste: SHA256 und eigene Signatur je Datei, Version, Kopie in Ordnung' {
        $x86 = New-FakeIcd $script:IcdTmp
        $man = Get-Content -LiteralPath (Join-Path $script:IcdTmp 'HUPilot-ICD.json') -Raw | ConvertFrom-Json
        $man.Version | Should -Be '10.0.28000.1'
        @($man.Files).Count | Should -Be 5
        (@($man.Files | Where-Object { $_.Path -eq 'ICD.exe' })[0]).Signed | Should -BeTrue
        (@($man.Files | Where-Object { $_.Path -eq 'Newtonsoft.Json.dll' })[0]).Signed | Should -BeFalse
        (@($man.Files | Where-Object { $_.Path -eq 'ICD.exe' })[0]).Sha256 | Should -Be (Get-FileSha (Join-Path $x86 'ICD.exe'))
        @(Test-IcdCopy $x86 (Join-Path $script:IcdTmp 'HUPilot-ICD.json') $script:FakeSig) | Should -BeNullOrEmpty
        Get-IcdCopyVersion $x86 (Join-Path $script:IcdTmp 'HUPilot-ICD.json') | Should -Be '10.0.28000.1'
    }
    It 'veraenderte, fehlende und zusaetzliche Dateien werden gemeldet' {
        $x86 = New-FakeIcd $script:IcdTmp; $m = Join-Path $script:IcdTmp 'HUPilot-ICD.json'
        Set-Content -LiteralPath (Join-Path $x86 'Newtonsoft.Json.dll') -Value 'boese' -NoNewline
        @(Test-IcdCopy $x86 $m $script:FakeSig) -join ';' | Should -Match 'Newtonsoft\.Json\.dll: verändert'
        $x86 = New-FakeIcd $script:IcdTmp
        Remove-Item -LiteralPath (Join-Path $x86 'de\ICDUI.resources.dll')
        @(Test-IcdCopy $x86 $m $script:FakeSig) -join ';' | Should -Match 'ICDUI\.resources\.dll: fehlt'
        $x86 = New-FakeIcd $script:IcdTmp
        Set-Content -LiteralPath (Join-Path $x86 'version.dll') -Value 'MS-SIG untergeschoben'
        @(Test-IcdCopy $x86 $m $script:FakeSig) -join ';' | Should -Match 'version\.dll: gehört nicht zur Kopie'
        # auch eine zusaetzliche Speicherdatei (sie koennte den Paketinhalt aendern)
        $x86 = New-FakeIcd $script:IcdTmp
        Set-Content -LiteralPath (Join-Path $x86 'Extra-Provisioning.dat') -Value 'x'
        @(Test-IcdCopy $x86 $m $script:FakeSig).Count | Should -Be 1
    }
    It 'Signatur: ICD.exe und im Original signierte Dateien muessen gueltig von Microsoft signiert sein' {
        # Datei und Pruefliste passend getauscht (Pruefsumme stimmt), aber ohne Microsoft-Signatur: wird nicht gestartet
        $x86 = New-FakeIcd $script:IcdTmp; $m = Join-Path $script:IcdTmp 'HUPilot-ICD.json'
        Set-Content -LiteralPath (Join-Path $x86 'ICD.exe') -Value 'FREMD-SIG icd' -NoNewline
        $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        foreach ($e in $o.Files) { if ($e.Path -eq 'ICD.exe') { $e.Sha256 = Get-FileSha (Join-Path $x86 'ICD.exe'); $e.Signed = $false } }
        [System.IO.File]::WriteAllText($m, ($o | ConvertTo-Json -Depth 4))
        @(Test-IcdCopy $x86 $m $script:FakeSig) -join ';' | Should -Match 'ICD\.exe: keine gültige Signatur von Microsoft'
        # signierte DLL durch unsignierte ersetzt (Pruefliste mitgezogen, Kennzeichen bleibt): gemeldet
        $x86 = New-FakeIcd $script:IcdTmp
        Set-Content -LiteralPath (Join-Path $x86 'ICDCore.dll') -Value 'unsigniert' -NoNewline
        $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        foreach ($e in $o.Files) { if ($e.Path -eq 'ICDCore.dll') { $e.Sha256 = Get-FileSha (Join-Path $x86 'ICDCore.dll') } }
        [System.IO.File]::WriteAllText($m, ($o | ConvertTo-Json -Depth 4))
        @(Test-IcdCopy $x86 $m $script:FakeSig) -join ';' | Should -Match 'ICDCore\.dll: keine gültige Signatur'
        # im Original unsignierte DLL traegt ploetzlich eine fremde Signatur: gemeldet
        $x86 = New-FakeIcd $script:IcdTmp
        Set-Content -LiteralPath (Join-Path $x86 'Newtonsoft.Json.dll') -Value 'FREMD-SIG' -NoNewline
        $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        foreach ($e in $o.Files) { if ($e.Path -eq 'Newtonsoft.Json.dll') { $e.Sha256 = Get-FileSha (Join-Path $x86 'Newtonsoft.Json.dll') } }
        [System.IO.File]::WriteAllText($m, ($o | ConvertTo-Json -Depth 4))
        @(Test-IcdCopy $x86 $m $script:FakeSig) -join ';' | Should -Match 'Newtonsoft\.Json\.dll: fremde oder ungültige Signatur'
        # -NoSig (Kontrolle nach dem Kopieren auf einen Stick) prueft nur die Pruefsummen
        @(Test-IcdCopy $x86 $m $script:FakeSig -NoSig) | Should -BeNullOrEmpty
    }
    It 'fehlende oder kaputte Pruefliste und Pfade mit .. werden abgelehnt' {
        $x86 = New-FakeIcd $script:IcdTmp; $m = Join-Path $script:IcdTmp 'HUPilot-ICD.json'
        Test-IcdCopy $x86 (Join-Path $script:IcdTmp 'gibtsnicht.json') $script:FakeSig | Should -Match 'Prüfliste HUPilot-ICD\.json fehlt'
        Set-Content -LiteralPath $m -Value '{kaputt'
        Test-IcdCopy $x86 $m $script:FakeSig | Should -Match 'fehlt oder ist beschädigt'
        $x86 = New-FakeIcd $script:IcdTmp
        $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        $o.Files += [pscustomobject]@{ Path = '..\..\Windows\evil.dll'; Sha256 = 'x'; Size = 1; Signed = $false }
        [System.IO.File]::WriteAllText($m, ($o | ConvertTo-Json -Depth 4))
        @(Test-IcdCopy $x86 $m $script:FakeSig) -join ';' | Should -Match 'ungültiger Pfad'
        Test-IcdCopy (Join-Path $script:IcdTmp 'nichtda') $m $script:FakeSig | Should -Be 'Ordner der Kopie fehlt'
    }
    It 'Stick: die Kopie kommt nie im allgemeinen Durchlauf mit, nur mit Haekchen (gemerkt, Standard aus)' {
        Test-SkipForStick 'ADK-ICD' | Should -BeTrue
        Test-SkipForStick 'ADK-ICD.neu' | Should -BeTrue
        Test-SkipForStick '_demo' | Should -BeTrue
        Test-SkipForStick 'config.json' | Should -BeTrue
        Test-SkipForStick 'Setup' | Should -BeFalse
        Test-SkipForStick 'go.ps1' | Should -BeFalse
        $script:SetupText | Should -Match "Copy-IcdToStick \`$dst \(\[bool\]\`$ui\.cIcdStick\.IsChecked"
        $script:SetupText | Should -Match "\`$ui\.cIcdStick\.IsChecked = \(\[string\]\(Get-UiSetting 'IcdToStick' \`$false\) -eq 'True'\)"
        $script:SetupText | Should -Match "Set-UiSetting 'IcdToStick'"
        # ohne Haekchen: eine Kopie am Stick bleibt, es wird nichts kopiert oder geloescht
        $dst = Join-Path $script:IcdTmp 'Stick\HUPilot'
        New-Item -ItemType Directory -Path (Join-Path $dst 'ADK-ICD\x86') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dst 'ADK-ICD\x86\ICD.exe') -Value 'alt'
        $script:Logs.Clear()
        Copy-IcdToStick $dst $false
        Test-Path -LiteralPath (Join-Path $dst 'ADK-ICD\x86\ICD.exe') | Should -BeTrue
        ($script:Logs -join ';') | Should -Match 'bleibt unverändert'
    }
    It 'Paketbau: Kopie wird vor jedem Start geprueft, ADK und Repo bleiben getrennt' {
        $b = [regex]::Match($script:SetupText, '(?s)function Build-PackageCore.*?\r?\n\}\r?\n').Value
        $b | Should -Match 'if \(\$fromCopy\) \{'
        $b | Should -Match '\$icdBad = @\(Test-IcdCopy \$icdCopyDir \$icdCopyMan\)'
        ($b.IndexOf('Test-IcdCopy') -lt $b.IndexOf('Start-Process -FilePath $icd')) | Should -BeTrue
        $b | Should -Match "Set-Step 'Pkg' 'err' 'Kopie des Paketbaus ungültig'; return \`$false"
        # Meldung bei fehlender ICD.exe nennt den neuen Weg
        $b | Should -Match 'an einem PC mit ADK "Paketbau mitnehmen" klicken'
        # nie ins Repo, kein Pull-Ausnahmefall noetig (Pull entfernt nur Dateien aus installed.json)
        $gi = Get-Content -LiteralPath (Join-Path $script:Root '.gitignore') -Raw
        $gi | Should -Match '(?m)^ADK-ICD/\r?$'
        $pull = Get-Content -LiteralPath (Join-Path $script:Root 'Stick\HUPilot\Setup\Pull.ps1') -Raw -Encoding UTF8
        $pull | Should -Match '\$prevFiles \| ForEach-Object'
        # die Kopie laedt nie selbst etwas aus dem Internet
        $fns = [regex]::Match($script:SetupText, '(?s)# ---------- Paketbau mitnehmen \(Test\).*?function Copy-IcdToStick').Value
        $fns | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|DownloadFile'
    }
}

Describe 'Setup: Sticks von selbst erkennen, kurzer Hinweis beim Hauptknopf' {
    It 'Auswahl: gewaehlter Stick bleibt, auch wenn ein zweiter dazukommt' {
        $r = Get-DriveSelection @('E:') @('E:', 'F:') 'E:'
        $r.Sel | Should -Be 'E:'
        @($r.Added) | Should -Be @('F:')
        @($r.Removed).Count | Should -Be 0
    }
    It 'Auswahl: erster Stick kommt dazu und keiner war gewaehlt -> er wird gewaehlt' {
        $r = Get-DriveSelection @() @('G:') ''
        $r.Sel | Should -Be 'G:'
        @($r.Added) | Should -Be @('G:')
        # nur von leer auf genau einen: zwei auf einmal oder ein weiterer ohne Auswahl wird nicht still gewaehlt
        (Get-DriveSelection @() @('E:', 'F:') '').Sel | Should -Be ''
        (Get-DriveSelection @('E:') @('E:', 'F:') '').Sel | Should -Be ''
    }
    It 'Auswahl: gewaehlter Stick abgezogen -> Auswahl leer, nie ein anderer Stick' {
        $r = Get-DriveSelection @('E:', 'F:', 'H:') @('E:', 'H:') 'F:'
        $r.Sel | Should -Be ''
        $r.Lost | Should -Be 'F:'
        @($r.Removed) | Should -Be @('F:')
        (Get-DriveSelection @('E:', 'F:') @('E:') 'F:').Sel | Should -Be ''
        $r = Get-DriveSelection @('E:') @() 'E:'
        $r.Sel | Should -Be ''
        $r.Lost | Should -Be 'E:'
        @($r.Removed) | Should -Be @('E:')
        # derselbe Stick kommt wieder (Liste war nicht leer, weil ein anderer steckt): keine stille Auswahl
        (Get-DriveSelection @('H:') @('E:', 'H:') '').Sel | Should -Be ''
    }
    It 'Fertig-Text gilt nur fuer genau den bespielten Stick, Tausch unter gleichem Buchstaben und Namen wird erkannt' {
        $script:SetupText | Should -Match "\`$sig = \(@\(\`$list \| ForEach-Object \{ \`$_\.Letter \+ '\|' \+ \`$_\.Label \+ '\|' \+ \`$_\.Size \+ '\|' \+ \`$_\.Serial \}\) -join ';'\)"
        $script:SetupText | Should -Match "return \(\`$x\.Letter \+ '\|' \+ \`$x\.Size \+ '\|' \+ \`$x\.Serial\)"
        $script:SetupText | Should -Match "Set-ReadyText \('Stick ' \+ \`$script:LostDrive \+ ' entfernt\. Bitte Stick wählen\.'\) 'HuWarn'"
        @([regex]::Matches($script:SetupText, 'Show-Msg[^\r\n]*\r?\n\s*(# [^\r\n]*\r?\n\s*)?try \{ Update-Drives -Auto \} catch \{ \}')).Count | Should -BeGreaterOrEqual 2
    }
    It 'Auswahl: keine Aenderung ergibt keine Ereignisse' {
        $r = Get-DriveSelection @('E:', 'F:') @('E:', 'F:') 'F:'
        $r.Sel | Should -Be 'F:'
        @($r.Added).Count + @($r.Removed).Count | Should -Be 0
    }
    It 'Sticks vorbereiten: Markierung geht nie auf ein anderes Laufwerk ueber' {
        # gleicher Datentraeger, gleicher Buchstabe: bleibt; Stick weg: entfernt
        $k = Get-PrepKeep @('3|E', '4|F') @('3|E', '5|G')
        @($k.Keep) | Should -Be @('3|E')
        @($k.Dropped) | Should -Be @('4|F')
        # anderer Datentraeger unter demselben Buchstaben (Stick getauscht): Markierung entfernt
        $k = Get-PrepKeep @('3|E') @('6|E')
        @($k.Keep).Count | Should -Be 0
        @($k.Dropped) | Should -Be @('3|E')
        # Listenposition spielt keine Rolle
        $k = Get-PrepKeep @('4|F') @('9|D', '4|F')
        @($k.Keep) | Should -Be @('4|F')
    }
    It 'Formatieren: Identitaet erkennt Tausch bei gleichem Buchstaben, Namen und gleicher Groesse' {
        $script:StickIdFields = @('Letter', 'DiskUid', 'DiskSerial', 'DiskSize', 'DiskSig', 'PartOffset', 'VolUid', 'VolSerial', 'VolSize')
        function Get-VolSerial([string]$Letter) { return $script:FakeVolSerial }
        $disk = [pscustomobject]@{ UniqueId = 'USBSTOR\DISK&VEN_X&PROD_Y\AAAA1111&0:PC'; SerialNumber = '0000000005 '; Size = 30995907072; Signature = 20847240; Guid = $null }
        $part = [pscustomobject]@{ Offset = 32768 }
        $vol = [pscustomobject]@{ UniqueId = '\\?\Volume{1}\'; Size = 30995869696 }
        $script:FakeVolSerial = '22D22CFA'
        $a = New-StickId $disk $part $vol 'e'
        $a.Letter | Should -Be 'E'
        $a.DiskSerial | Should -Be '0000000005'
        @(Compare-StickId $a (New-StickId $disk $part $vol 'E')).Count | Should -Be 0
        # gleiches Modell, gleiche Groesse, gleicher Name HUPILOT, gleicher Buchstabe, nur ein anderes Geraet: erkannt
        $disk2 = [pscustomobject]@{ UniqueId = 'USBSTOR\DISK&VEN_X&PROD_Y\BBBB2222&0:PC'; SerialNumber = '0000000005'; Size = 30995907072; Signature = 11111111; Guid = $null }
        $vol2 = [pscustomobject]@{ UniqueId = '\\?\Volume{2}\'; Size = 30995869696 }
        $script:FakeVolSerial = '9A0B1C2D'
        $b = New-StickId $disk2 $part $vol2 'E'
        $d = @(Compare-StickId $a $b)
        $d | Should -Contain 'DiskUid'
        $d | Should -Contain 'VolSerial'
        $d | Should -Not -Contain 'Letter'
        $d | Should -Not -Contain 'DiskSize'
        # Seriennummer des Datentraegers gleich und unbrauchbar, Volume neu formatiert: Volume-Seriennummer allein reicht
        $script:FakeVolSerial = 'FFFF0000'
        @(Compare-StickId $a (New-StickId $disk $part $vol 'E')) | Should -Be @('VolSerial')
        # anderer Buchstabe oder nicht lesbar
        $script:FakeVolSerial = '22D22CFA'
        @(Compare-StickId $a (New-StickId $disk $part $vol 'F')) | Should -Be @('Letter')
        @(Compare-StickId $a $null) | Should -Be @('Stick nicht lesbar')
        # Schluessel fuer die Markierung aus der Identitaet: getauschter Stick erbt keine Markierung
        $k = Get-PrepKeep @((Get-StickKey $a)) @((Get-StickKey $b))
        @($k.Keep).Count | Should -Be 0
        @($k.Dropped).Count | Should -Be 1
        (Get-PrepKey ([pscustomobject]@{ Id = $a })) | Should -Be (Get-StickKey $a)
        (Get-StickKey $a).StartsWith('E|') | Should -BeTrue
    }
    It 'Formatieren: Pruefung direkt davor, ueber die Partition, keine geerbten Markierungen, Fenster nicht schliessbar' {
        $b = [regex]::Match($script:SetupText, '(?s)\$g\.bGo\.Add_Click\(\{.*?\r?\n    \}\)\r?\n').Value
        $b | Should -Match '\$diff = @\(Compare-StickId \$st\.Id \(New-StickId \$disk \$part \$vol \$dl\)\)'
        $b | Should -Match "Stick wurde getauscht, nicht formatiert\. Bitte neu markieren\.'\) 'Fehler'"
        $b | Should -Match 'Format-Volume -Partition \$part '
        $b | Should -Not -Match 'Format-Volume -DriveLetter'
        ($b.IndexOf('Compare-StickId') -lt $b.IndexOf('Format-Volume')) | Should -BeTrue
        $b | Should -Match '\$g\.lSticks\.UnselectAll\(\)'
        $script:SetupText | Should -Match '\$prepSig = \{ Get-DriveSig \}'
        $script:SetupText | Should -Match "if \(\`$pst\.Busy\) \{ \`$e\.Cancel = \`$true;"
    }
    It 'Hinweis nach einem Fehler: der eine Satz, was zu tun ist, ohne Anfuehrungszeichen' {
        Get-ReadyTodo ("Das Secret ist falsch.`r`n`r`nHäufiger Fehler: die Geheimnis-ID statt des WERTS kopiert. Den Wert bei `"Secret`" eintragen.") | Should -Be 'Häufiger Fehler: die Geheimnis-ID statt des WERTS kopiert.'
        Get-ReadyTodo ("Kein Ziel-Stick gewählt.`r`n`r`nStick anstecken, er wird von selbst erkannt, dann nochmal Stick fertig machen.") | Should -Be 'Stick anstecken, er wird von selbst erkannt, dann nochmal Stick fertig machen.'
        Get-ReadyTodo 'keine Verbindung zu Microsoft' | Should -Be 'keine Verbindung zu Microsoft'
        Get-ReadyTodo ('Bitte "4. WLAN-Paket bauen" klicken.') | Should -Be 'Bitte 4. WLAN-Paket bauen klicken.'
    }
    It 'Hinweistext: kurz, eine Zeile, je Zustand; kein alter Langtext mehr' {
        $script:SetupText | Should -Not -Match 'links auswählen \(ggf\.'
        $script:SetupText | Should -Match 'x:Name="tReady"[^>]*TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"'
        $script:SetupText | Should -Match "Set-ReadyText 'Kein Stick erkannt\. Stick anstecken\.' 'HuWarn'"
        $script:SetupText | Should -Match "Set-ReadyText \('Bereit für ' \+ \`$d"
        $script:SetupText | Should -Match "Set-ReadyText 'Prüfe Verbindung \.\.\.'"
        $script:SetupText | Should -Match "Set-ReadyText \('Kopiere auf ' \+ \`$dr \+ ' \.\.\.'\)"
        # Ergebnis bleibt stehen, bis ein anderer Stick gewaehlt wird
        $script:SetupText | Should -Match 'if \(\$key -eq \[string\]\$script:HintDrive\) \{ return \}'
    }
    It 'Erkennung: Timer nur bei Aenderung, Pause bei Vorgang, offener Liste und Unterfenster, nicht im Starttest' {
        $script:SetupText | Should -Match '\$script:DriveTimer\.Interval = \[TimeSpan\]::FromSeconds\(2\)'
        $script:SetupText | Should -Match 'if \(\$script:Busy -or \$ui\.cDrive\.IsDropDownOpen -or @\(\$win\.OwnedWindows\)\.Count\) \{ return \}'
        $script:SetupText | Should -Match 'if \(\$Auto -and \$sig -eq \$script:DriveSig\) \{ return \}'
        $script:SetupText | Should -Match "if \(\[string\]\`$d\.DriveType -ne 'Removable'\) \{ continue \}"
        $script:SetupText | Should -Match '\$win\.Add_Closed\(\{ try \{ \$script:DriveTimer\.Stop\(\) \} catch \{ \} \}\)'
        # Start nur im else-Zweig des Starttests
        $sm = [regex]::Match($script:SetupText, '(?s)if \(\$SmokeTest\) \{\r?\n    # Starttest.*?\r?\n\} else \{(.*?)\r?\n\}').Groups[1].Value
        $sm | Should -Match '\$script:DriveTimer\.Start\(\)'
        # Sticks vorbereiten: nie waehrend des Formatierens, Timer stoppt beim Schliessen, nicht im Starttest
        $script:SetupText | Should -Match 'if \(\$pst\.Busy -or \$script:Busy\) \{ return \}'
        $script:SetupText | Should -Match '\$pst\.Busy = \$true; Set-UiBusy \$true'
        $script:SetupText | Should -Match 'if \(-not \$SmokeTest\) \{ \$pw\.Add_ContentRendered\(\{ \$ptm\.Start\(\) \}\) \}'
        $script:SetupText | Should -Match '\$pw\.Add_Closed\(\{ \$ptm\.Stop\(\) \}\)'
        # Sicherheitspruefung direkt vor dem Formatieren unveraendert
        $script:SetupText | Should -Match "if \(\[string\]\`$disk\.BusType -ne 'USB' -or \`$disk\.IsBoot -or \`$disk\.IsSystem -or \[int\]\`$disk\.Number -eq \`$script:SrcDisk\) \{ throw 'kein reiner USB-Stick mehr - übersprungen' \}"
    }
}

Describe 'Setup: Status-Fenster stabil (verzoegerte Aktionen, Position, Messung)' {
    It 'verzoegerte Aktionen und Timer brauchen keine Variablen einer beendeten Funktion' {
        # kein BeginInvoke mehr mit $sst oder $hw direkt im Block
        $script:SetupText | Should -Not -Match 'BeginInvoke\(\[action\]\{ \$sst\.'
        $script:SetupText | Should -Not -Match 'BeginInvoke\(\[action\]\{ \$hw\.Close\(\) \}\)'
        @([regex]::Matches($script:SetupText, 'BeginInvoke\(\[action\]\(\{ try \{[^\r\n]*\}\.GetNewClosure\(\)\)')).Count | Should -BeGreaterOrEqual 2
        # Timer im Status und in Sticks vorbereiten: stoppen ueber den Absender, nur bei offenem Fenster, Fehler abgefangen
        $script:SetupText | Should -Match '\$tm\.Add_Tick\(\{ param\(\$s, \$e\) try \{ if \(-not \$sw -or -not \$sw\.IsVisible\) \{ \$s\.Stop\(\); return \}'
        $script:SetupText | Should -Match '\$wtm\.Add_Tick\(\{ param\(\$s, \$e\) try \{ \$s\.Stop\(\); if \(\$sw -and \$sw\.IsVisible\)'
        $script:SetupText | Should -Match 'if \(-not \$pw -or -not \$pw\.IsVisible\) \{ \$tmr\.Stop\(\); return \}'
        $script:SetupText | Should -Match '\$tm\.Stop\(\); \$wtm\.Stop\(\); \$ftm\.Stop\(\)'
    }
    It 'Breitenaenderung behaelt die Position, nur so weit verschieben wie noetig' {
        Get-KeptLeft 100 800 0 1920 | Should -Be 100
        Get-KeptLeft 1500 800 0 1920 | Should -Be 1120
        # zweiter Bildschirm rechts (Arbeitsbereich 1920 bis 3840)
        Get-KeptLeft 2000 900 1920 3840 | Should -Be 2000
        Get-KeptLeft 3500 900 1920 3840 | Should -Be 2940
        Get-KeptLeft 1800 900 1920 3840 | Should -Be 1920
        # breiter als der Arbeitsbereich: links buendig
        Get-KeptLeft 50 2500 0 1920 | Should -Be 0
        $script:SetupText | Should -Match 'if \(\$firstFit\) \{ Set-WinFit \$sw \} else \{ \$sw\.Left = Get-KeptLeft \$sw\.Left \$target \$wa\.Left \$wa\.Right \}'
        $script:SetupText | Should -Match '\$wa = Get-WinWorkArea \$sw'
        # nur Maximieren schaltet die automatische Breite ab
        $script:SetupText | Should -Match "\`$sw\.Add_StateChanged\(\{ if \(\[string\]\`$sw\.WindowState -eq 'Maximized'\) \{ \`$sst\.UserSized = \`$true \} \}\)"
    }
    It 'Textbreiten zwischengespeichert, Suche nach kurzer Pause' {
        $script:SetupText | Should -Match '\$script:TextWidthCache\.ContainsKey\(\$ck\)'
        $script:SetupText | Should -Match '\$ftm\.Interval = \[TimeSpan\]::FromMilliseconds\(250\)'
        $script:SetupText | Should -Match '\$g\.tFind\.Add_TextChanged\(\{ \$ftm\.Stop\(\); \$ftm\.Start\(\) \}\)'
    }
}