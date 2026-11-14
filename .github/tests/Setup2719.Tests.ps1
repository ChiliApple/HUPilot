#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer HUPilot-Setup.ps1, Neuerungen ab v2.7.19: lesbare Tooltips, Secret erneuern,
# Status (Hardware geaendert, Doppelt, Loeschen mit doppelter Abfrage), Details kopieren, Importfehler 806/808.
# Das Setup wird dabei NICHT gestartet, Graph wird nie aufgerufen (alles mit Mocks und kuenstlichen Daten).

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:SetupPath = Join-Path $script:Root 'Stick\HUPilot\Setup\HUPilot-Setup.ps1'
    $script:SetupText = Get-Content -LiteralPath $script:SetupPath -Raw -Encoding UTF8
    $tk = $null; $er = $null
    $script:SetupAst = [System.Management.Automation.Language.Parser]::ParseFile($script:SetupPath, [ref]$tk, [ref]$er)
    $script:ParseErrors = @($er)
    $script:AllFns = @($script:SetupAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
    # Funktionstext nach Namen (fuer Laeufe in einem eigenen STA-Runspace)
    $script:FnByName = @{}; foreach ($f in $script:AllFns) { $script:FnByName[$f.Name] = $f.Extent.Text }
    $want = @('Format-TechDetail', 'Hide-LogSecrets', 'Get-StrHash', 'Get-BytesSha', 'ConvertTo-UtcDate', 'Format-UtcText')
    . ([scriptblock]::Create((@($want | Where-Object { $script:FnByName.ContainsKey($_) } | ForEach-Object { $script:FnByName[$_] }) -join "`n")))
    # Theme-Texte
    $get = { param($n) [regex]::Match($script:SetupText, "(?s)\`$script:$n = @'\r?\n(.*?)\r?\n'@").Groups[1].Value }
    $script:ThemeXaml = & $get 'HuThemeXaml'; $script:DarkXaml = & $get 'HuColorsDark'; $script:LightXaml = & $get 'HuColorsLight'
    $script:XamlBlocks = @([regex]::Matches($script:SetupText, "(?s)\[xml\]\`$(\w+) = @'\r?\n(.*?)\r?\n'@") | ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Xaml = $_.Groups[2].Value } })
    # Skriptblock in einem STA-Runspace ausfuehren (WPF braucht STA), Rueckgabe als Liste
    function Invoke-Sta([scriptblock]$Block, [object[]]$Arguments = @()) {
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { return @(& $Block @Arguments) }
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        try {
            $ps = [powershell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript($Block)
            foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
            $r = @($ps.Invoke())
            if ($ps.Streams.Error.Count) { throw ($ps.Streams.Error | Select-Object -First 1 | Out-String) }
            return $r
        } finally { $rs.Close() }
    }
    # Kuenstliche Antworten (keine echten Kennungen)
    $script:AadJson = '{"error":"invalid_client","error_description":"AADSTS7000222: The provided client secret keys for app ''66666666-7777-8888-9999-000000000000'' are expired. Visit the Azure portal to create new keys for your app. Trace ID: 0000aaaa-1111-2222-3333-444455556666 Correlation ID: 9999bbbb-8888-7777-6666-555544443333 Timestamp: 2026-11-14 07:58:01Z","error_codes":[7000222],"timestamp":"2026-11-14 07:58:01Z","trace_id":"0000aaaa-1111-2222-3333-444455556666","correlation_id":"9999bbbb-8888-7777-6666-555544443333","error_uri":"https://login.microsoftonline.com/error?code=7000222"}'
    $script:GraphJson = '{"error":{"code":"Forbidden","message":"Application is not authorized to perform this operation.","innerError":{"date":"2026-11-14T07:58:01","request-id":"aaaa1111-2222-3333-4444-555566667777","client-request-id":"bbbb1111-2222-3333-4444-555566667777"}}}'
}

Describe 'v2.7.19: Datei vollstaendig' {
    It 'Setup parst ohne Fehler und endet sauber' {
        $script:ParseErrors | Should -BeNullOrEmpty
        $script:SetupText.TrimEnd() | Should -Match '\}$'
    }
}

Describe 'v2.7.19 Paket 1: Tooltips lesbar' {
    It 'Antwort des Anmeldedienstes: je Angabe eine Zeile, Kennungen nicht doppelt in der Beschreibung' {
        $t = Format-TechDetail $script:AadJson
        $l = @($t -split "`r`n")
        $l[0] | Should -Be 'Fehlercode: invalid_client (AADSTS7000222)'
        $l[1] | Should -Match '^Beschreibung: The provided client secret keys .* are expired\. Visit the Azure portal to create new keys for your app\.$'
        $l[2] | Should -Be 'Zeitpunkt: 2026-11-14 07:58:01Z'
        $l[3] | Should -Be 'Trace-ID: 0000aaaa-1111-2222-3333-444455556666'
        $l[4] | Should -Be 'Correlation-ID: 9999bbbb-8888-7777-6666-555544443333'
        $l.Count | Should -Be 5
    }
    It 'Antwort von Graph: Code, Beschreibung, Zeitpunkt, Kennungen' {
        $l = @((Format-TechDetail $script:GraphJson) -split "`r`n")
        $l | Should -Be @('Fehlercode: Forbidden', 'Beschreibung: Application is not authorized to perform this operation.', 'Zeitpunkt: 2026-11-14T07:58:01', 'Request-ID: aaaa1111-2222-3333-4444-555566667777', 'Client-Request-ID: bbbb1111-2222-3333-4444-555566667777')
    }
    It 'Text vor dem JSON bleibt als Meldung, verschachtelte Intune-Meldung wird entpackt' {
        $t = Format-TechDetail ('Der Remoteserver hat einen Fehler zurückgegeben: (400) Ungültige Anforderung. ' + $script:GraphJson)
        @($t -split "`r`n")[0] | Should -Be 'Meldung: Der Remoteserver hat einen Fehler zurückgegeben: (400) Ungültige Anforderung.'
        $inner = '{"error":{"code":"BadRequest","message":"{\r\n  \"_version\": 3,\r\n  \"Message\": \"An error has occurred - Operation ID (for customer support): 00000000-0000-0000-0000-000000000000\"\r\n}","innerError":{"date":"2026-11-14T08:00:00"}}}'
        @((Format-TechDetail $inner) -split "`r`n")[1] | Should -Match '^Beschreibung: An error has occurred - Operation ID'
    }
    It 'Rueckfall: Klartext und kaputtes JSON bleiben unveraendert, leer bleibt leer' {
        Format-TechDetail 'Zeitüberschreitung beim Vorgang' | Should -Be 'Zeitüberschreitung beim Vorgang'
        Format-TechDetail '{ kein json' | Should -Be '{ kein json'
        Format-TechDetail '{"foo":"bar"}' | Should -Be '{"foo":"bar"}'
        Format-TechDetail '' | Should -Be ''
    }
    It 'nie Secrets: Werte sind vorher ausgeblendet und bleiben es' {
        $raw = Hide-LogSecrets ('{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided: abc~geheimerWert123"}') @('abc~geheimerWert123')
        $t = Format-TechDetail $raw
        $t | Should -Not -Match 'geheimerWert'
        $t | Should -Match '\*\*\*'
    }
    It 'Protokollzeilen nutzen die gegliederte Meldung fuer Tooltip und Doppelklick' {
        $script:SetupText | Should -Match '\$fmt = Hide-LogSecrets \(Format-TechDetail \$Detail\) \(Get-LogSecretValues\)'
        $script:SetupText | Should -Match '\$it\.ToolTip = \$fmt'
    }
    It 'Tooltip hat im Theme eine feste Hoechstbreite und bricht um, hell und dunkel lesbar' {
        $res = Invoke-Sta {
            param($theme, $dark, $light)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $out = @()
            foreach ($col in @($dark, $light)) {
                $rd = New-Object System.Windows.ResourceDictionary
                $rd.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Parse($col))
                $rd.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Parse($theme))
                $tt = New-Object System.Windows.Controls.ToolTip
                $tt.Resources = $rd
                $tt.Style = $rd[[System.Windows.Controls.ToolTip]]
                $tt.Content = ('Fehlercode: invalid_client (AADSTS7000222) ' * 20) + "`r`nZeile zwei"
                $tt.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
                $out += [pscustomobject]@{ W = $tt.DesiredSize.Width; H = $tt.DesiredSize.Height; Max = $tt.MaxWidth; Fg = [string]$tt.Foreground; Bg = [string]$tt.Background }
            }
            $out
        } @($script:ThemeXaml, $script:DarkXaml, $script:LightXaml)
        $res.Count | Should -Be 2
        foreach ($r in $res) {
            $r.Max | Should -Be 520
            $r.W | Should -BeLessOrEqual 520
            $r.H | Should -BeGreaterThan 60   # umgebrochen, mehrere Zeilen
            $r.Fg | Should -Not -Be $r.Bg
        }
        $res[0].Bg | Should -Not -Be $res[1].Bg
    }
}

Describe 'v2.7.19 Punkt 8: Verweise in Tooltips zeigen auf vorhandene Stellen' {
    BeforeAll {
        $dec = { param($s) [System.Net.WebUtility]::HtmlDecode(($s -replace '&#x0a;', "`n")) }
        # Alle Tooltips: XAML-Attribute aller Fenster, im Code gesetzte Texte (.ToolTip = '...') und der Text des Haekchens Paketbau
        $script:Tips = New-Object System.Collections.Generic.List[object]
        foreach ($b in $script:XamlBlocks) { foreach ($m in [regex]::Matches($b.Xaml, 'ToolTip="([^"]*)"')) { $script:Tips.Add([pscustomobject]@{ Where = $b.Name; Text = (& $dec $m.Groups[1].Value) }) } }
        foreach ($m in [regex]::Matches($script:SetupText, "\.ToolTip = '((?:[^']|'')*)'")) { $script:Tips.Add([pscustomobject]@{ Where = 'Code'; Text = $m.Groups[1].Value.Replace("''", "'") }) }
        $icd = [regex]::Match($script:SetupText, '(?s)\$tip = (.*?)\r?\n\s*\$ui\.cIcdStick\.ToolTip = \$tip').Groups[1].Value
        $script:Tips.Add([pscustomobject]@{ Where = 'Haekchen Paketbau'; Text = ((@([regex]::Matches($icd, "'((?:[^']|'')*)'") | ForEach-Object { $_.Groups[1].Value })) -join ' ') })
        # zusammengesetzte Tooltips: Merker am Stick (Get-StickFlags) und Abfragetexte der Tooltips im Code
        foreach ($fn in 'Get-StickFlags') { $src = $script:FnByName[$fn]; foreach ($m in [regex]::Matches($src, "(?s)Tip = (\(.*?\)|'(?:[^']|'')*')")) { $script:Tips.Add([pscustomobject]@{ Where = $fn; Text = ((@([regex]::Matches($m.Groups[1].Value, "'((?:[^']|'')*)'") | ForEach-Object { $_.Groups[1].Value })) -join ' ') }) } }
        # Knopfnamen (Knoepfe, Menues) ohne Nummer und ohne ' ...', mindestens zwei Woerter
        $cores = New-Object System.Collections.Generic.HashSet[string]
        foreach ($b in $script:XamlBlocks) { foreach ($m in [regex]::Matches($b.Xaml, '<Button [^>]*Content="([^"{]+)"')) { [void]$cores.Add((& $dec $m.Groups[1].Value)) }; foreach ($m in [regex]::Matches($b.Xaml, '(?s)<Button [^>]*>(?:(?!</Button>).)*?<TextBlock [^>]*?Text="([^"{]+)"')) { [void]$cores.Add((& $dec $m.Groups[1].Value)) } }
        foreach ($m in [regex]::Matches($script:SetupText, "& \`$add[UI] '([^']+)'")) { [void]$cores.Add($m.Groups[1].Value) }
        $script:Cores = @($cores | ForEach-Object { (($_ -replace '^[1-7]\. ', '') -replace '\s*\.\.\.$', '').Trim() } | Where-Object { @($_ -split ' ').Count -ge 2 } | Sort-Object -Unique)
        # Alle Beschriftungen: Knoepfe, Felder, Haekchen, Ueberschriften, Kacheln, Menues, Spalten, Staende
        $lab = New-Object System.Collections.Generic.HashSet[string]
        foreach ($b in $script:XamlBlocks) { foreach ($m in [regex]::Matches($b.Xaml, '(?:Content|Text|Header|Title)="([^"{]+)"')) { [void]$lab.Add((& $dec $m.Groups[1].Value).Trim()) } }
        foreach ($m in [regex]::Matches($script:SetupText, "& \`$add[UI] '([^']+)'")) { [void]$lab.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($script:SetupText, "\.(?:Content|Header) = '([^']+)'")) { [void]$lab.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($script:SetupText, "Header = '([^']+)'")) { [void]$lab.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches([regex]::Match($script:SetupText, '(?m)^\$script:StandClass = (@\{.*\})\r?$').Groups[1].Value, "'([^']+)' = ")) { [void]$lab.Add($m.Groups[1].Value) }
        $script:Labels = $lab
        # Namen ausserhalb des Setups, die ein Tooltip in Anfuehrung nennen darf (Microsoft-Oberflaechen, Werkzeuge)
        $script:External = @('Imaging and Configuration Designer', 'Zertifikate & Geheimnisse', 'Neuer geheimer Clientschlüssel', 'Hinzufügen', 'Wert', 'Geheimnis-ID', 'Benutzerdefiniert')
    }
    It 'es werden Tooltips aus allen Fenstern und aus dem Code gefunden' {
        $script:Tips.Count | Should -BeGreaterThan 100
        @($script:Tips | Where-Object { $_.Where -eq 'Code' }).Count | Should -BeGreaterThan 1
        @($script:Tips | Where-Object { $_.Where -eq 'Haekchen Paketbau' })[0].Text | Should -Match 'Rechtsklick'
    }
    It 'jeder in Anfuehrung genannte Name existiert als Beschriftung (oder steht auf der Liste der fremden Namen)' {
        $bad = @()
        foreach ($t in $script:Tips) {
            foreach ($m in [regex]::Matches($t.Text, '"([^"\n]{2,60})"')) {
                $n = $m.Groups[1].Value.Trim()
                if (-not $script:Labels.Contains($n) -and $script:External -notcontains $n) { $bad += ($t.Where + ': "' + $n + '"') }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'jeder nummerierte Schritt (z. B. "5. Auf Stick kopieren") heisst so wie der Knopf' {
        $steps = @{}; foreach ($l in $script:Labels) { if ($l -match '^([1-7])\. (.+)$') { $steps[$Matches[1]] = $Matches[2] } }
        $steps.Count | Should -Be 7
        $bad = @()
        foreach ($t in $script:Tips) {
            foreach ($m in [regex]::Matches($t.Text, '(?<![\d.])([1-7])\. (?=[A-ZÄÖÜ])')) {
                $rest = $t.Text.Substring($m.Index + $m.Length)
                if (-not $rest.StartsWith($steps[$m.Groups[1].Value])) { $bad += ($t.Where + ': ' + $m.Value + $rest.Substring(0, [math]::Min(30, $rest.Length))) }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'kein Verweis der Form "Tooltip der/des ..." ohne Ziel, keine internen Testangaben fuer Kustoden' {
        foreach ($t in $script:Tips) {
            $t.Text | Should -Not -Match 'Tooltip (der|des|von|im) ' -Because $t.Where
            $t.Text | Should -Not -Match 'geprüft mit ICD \d' -Because $t.Where
        }
    }
    It 'Knopfnamen ohne Anfuehrung: wo die ersten zwei Woerter eines Knopfs stehen, steht der Name vollstaendig' {
        $script:Cores.Count | Should -BeGreaterThan 15
        $script:Cores | Should -Contain 'Stick fertig machen'
        $bad = @()
        foreach ($tip in $script:Tips) {
            foreach ($c in $script:Cores) {
                $w = (($c -split ' ')[0..1]) -join ' '
                $i = $tip.Text.IndexOf($w, [StringComparison]::Ordinal)
                while ($i -ge 0) {
                    if (-not $tip.Text.Substring($i).StartsWith($c, [StringComparison]::Ordinal)) { $bad += ($tip.Where + ': ' + $tip.Text.Substring($i, [math]::Min(40, $tip.Text.Length - $i)) + ' (Knopf: ' + $c + ')') }
                    $i = $tip.Text.IndexOf($w, $i + 1, [StringComparison]::Ordinal)
                }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'zusammengesetzte Tooltips der Merker sind mitgeprueft' {
        @($script:Tips | Where-Object { $_.Where -eq 'Get-StickFlags' }).Count | Should -BeGreaterOrEqual 2
    }
    It 'Knopf "4. WLAN-Paket bauen" nennt die benutzte ICD.exe selbst' {
        $script:SetupText | Should -Match "\`$ui\.bPkg\.ToolTip = \`$script:PkgTipBase \+ ""``n"" \+ 'Benutzt wird: ' \+ \(Get-IcdText \`$script:Icd\)"
        $script:SetupText | Should -Not -Match 'steht im Tooltip der Ampel'
    }
}

Describe 'v2.7.19 Punkt 9: Merker MAK am Stick' {
    BeforeAll {
        . ([scriptblock]::Create((@('Get-StickMakInfo', 'Get-StickFlags') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        $script:Key = 'ABCDE-FGHIJ-KLMNO-PQRST-UVW12'
        function New-Stick([string]$Name, $Content) {
            $d = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path (Join-Path $d 'HUPilot') -Force | Out-Null
            if ($null -ne $Content) { [System.IO.File]::WriteAllText((Join-Path $d 'HUPilot\config.json'), $Content, (New-Object System.Text.UTF8Encoding($false))) }
            return $d
        }
    }
    It 'MAK gefuellt: Merker mit den letzten 5 Zeichen, der ganze Schluessel erscheint nirgends' {
        $i = Get-StickMakInfo (New-Stick 'voll' ('{"Tenant":"Test","EditionKey":"' + $script:Key + '"}'))
        $i.HasMak | Should -BeTrue
        $i.Tail | Should -Be 'UVW12'
        ($i | ConvertTo-Json -Compress) | Should -Not -Match 'ABCDE'
        $f = @(Get-StickFlags $i)
        $f.Count | Should -Be 1
        $f[0].Text | Should -Be 'MAK am Stick'
        $f[0].Color | Should -Be 'HuStandErrBg'
        $f[0].Tip | Should -Match 'endet auf UVW12'
        $f[0].Tip | Should -Match 'Nein wählen'
        ($f | ConvertTo-Json -Compress) | Should -Not -Match 'ABCDE|FGHIJ|PQRST'
    }
    It 'MAK leer, Feld fehlt, Datei fehlt, kein Stick: kein Merker, kein Fehler' {
        foreach ($c in @(@('leer', '{"EditionKey":""}'), @('blank', '{"EditionKey":"   "}'), @('ohne', '{"Tenant":"Test"}'), @('fehlt', $null))) {
            $i = Get-StickMakInfo (New-Stick $c[0] $c[1])
            @(Get-StickFlags $i).Count | Should -Be 0 -Because $c[0]
        }
        Get-StickMakInfo '' | Should -BeNullOrEmpty
        Get-StickMakInfo (Join-Path $TestDrive 'gibtsnicht') | Should -BeNullOrEmpty
        @(Get-StickFlags $null).Count | Should -Be 0
    }
    It 'kurzer Schluessel: Merker ohne Endung' {
        $i = Get-StickMakInfo (New-Stick 'kurz' '{"EditionKey":"AB"}')
        $i.HasMak | Should -BeTrue; $i.Tail | Should -Be ''
        (Get-StickFlags $i)[0].Tip | Should -Not -Match 'endet auf'
    }
    It 'config.json wird mit Kodierung gelesen, Merker wird bei allen Anlaessen aktualisiert' {
        $script:FnByName['Get-StickMakInfo'] | Should -Match '\[System\.IO\.File\]::ReadAllText\(\$p, \[System\.Text\.Encoding\]::UTF8\)'
        $script:SetupText | Should -Match 'function Update-ReadyHint \{\r?\n\s+Update-StickFlags'
        $script:SetupText | Should -Match '\$ui\.bReload\.Add_Click\(\{ Update-Drives; Update-StickFlags -Force \}\)'
        $script:SetupText | Should -Match "finally \{ Set-UiBusy \`$false; Update-StickFlags -Force \}\r?\n\}\r?\n\`$ui\.bReady\.Add_Click"
        $script:SetupText | Should -Match "Set-Step 'Copy' 'err' \`$script:CopyErr \}\r?\n\s+\} finally \{ Set-UiBusy \`$false; Update-StickFlags -Force \}"
        $script:SetupText | Should -Match "try \{ Update-ReadyHint \} catch \{ \}; Update-StickFlags -Force \}"
        # Merker hinter dem Text, der Text kuerzt (nicht der Merker)
        $x = @($script:XamlBlocks | Where-Object { $_.Name -eq 'xaml' })[0].Xaml
        $x | Should -Match '<DockPanel x:Name="dpReady"[^>]*HorizontalAlignment="Left"'
        $x | Should -Match '<StackPanel x:Name="spFlags" DockPanel\.Dock="Right"'
    }
    It 'Merker bleibt bei langem Text ganz sichtbar, der Text wird gekuerzt (STA, beide Themes)' {
        $res = Invoke-Sta {
            param($xamlText, $theme, $dark, $light, $fnText)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $script:HuThemeXaml = $theme; $script:HuColorsDark = $dark; $script:HuColorsLight = $light; $script:HuWindows = New-Object System.Collections.ArrayList
            . ([scriptblock]::Create($fnText))
            foreach ($th in 'dunkel', 'hell') {
                $script:HuTheme = $th
                $x = [xml]$xamlText; Add-HuTheme $x
                $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
                $w.Width = 890
                $w.FindName('tReady').Text = 'Stick E: ist fertig und kontrolliert (10:40), mit Hinweisen im Protokoll und noch viel mehr Text, der nicht passt'
                $bd = New-Object System.Windows.Controls.Border; $bd.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'HuStandErrBg')
                $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = 'MAK am Stick'; $tb.FontWeight = 'Bold'; $bd.Child = $tb; $bd.Margin = '8,0,0,0'; $bd.Padding = '6,1,6,1'
                [void]$w.FindName('spFlags').Children.Add($bd)
                # Fenster wird nicht gezeigt: Inhalt mit den Ressourcen des Fensters herausloesen und selbst anordnen
                $root = $w.Content; $rs = $w.Resources; $w.Content = $null; $root.Resources = $rs
                $root.Measure((New-Object System.Windows.Size(862, 700))); $root.Arrange((New-Object System.Windows.Rect(0, 0, 862, 700))); $root.UpdateLayout()
                $p = $bd.TranslatePoint((New-Object System.Windows.Point(0, 0)), $w.FindName('bdReady'))
                '' + [int]$bd.ActualWidth + '|' + [int]($p.X + $bd.ActualWidth) + '|' + [int]$w.FindName('bdReady').ActualWidth + '|' + [int]$tb.DesiredSize.Width
            }
        } @(@($script:XamlBlocks | Where-Object { $_.Name -eq 'xaml' })[0].Xaml, $script:ThemeXaml, $script:DarkXaml, $script:LightXaml, ((@('Add-HuTheme', 'Get-HuColorsXaml') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        $res.Count | Should -Be 2
        foreach ($r in $res) {
            $v = @($r.Split('|') | ForEach-Object { [int]$_ })
            $v[0] | Should -BeGreaterThan ($v[3])          # Merker ganz so breit wie sein Text
            $v[1] | Should -BeLessOrEqual $v[2]             # endet innerhalb der Leiste
        }
    }
}

Describe 'v2.7.19 Zusatz: Details kopieren per Rechtsklick' {
    BeforeAll { . ([scriptblock]::Create($script:FnByName['Get-DetailCopyText'])) }
    It 'Zeile plus gegliederte Meldung, ohne Secrets' {
        $det = '{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided: Geheim~0123456789abcdef. Trace ID: x"}'
        $t = Get-DetailCopyText '10:00:00  Fehler: Das Secret ist falsch.' $det @('Geheim~0123456789abcdef')
        $l = @($t -split "`r`n")
        $l[0] | Should -Be '10:00:00  Fehler: Das Secret ist falsch.'
        $l[1] | Should -Be ''
        $l[2] | Should -Be 'Fehlercode: invalid_client (AADSTS7000215)'
        $t | Should -Not -Match 'Geheim~'
        $t | Should -Match 'Invalid client secret provided: \*\*\*'
    }
    It 'Protokollzeilen mit Details bekommen das Kontextmenue, auch in den Unterfenstern (gleiche Funktion)' {
        $script:SetupText | Should -Match "\`$mi\.Header = 'Details kopieren'"
        $script:SetupText | Should -Match '\[System\.Windows\.Clipboard\]::SetText\(\(Get-DetailCopyText \$this\.Tag\.Text \$this\.Tag\.Detail\)\)'
        $script:SetupText | Should -Match '\$it\.ContextMenu = \$cm'
        # Unterfenster schreiben ueber Out-SubLog in dieselbe Add-LogItem
        $script:SetupText | Should -Match 'Add-LogItem \$List \$Level \(\$time \+ ''  '' \+ \$text\) \$Detail \$false'
    }
    It 'Kontextmenue laedt im Theme (STA), hell und dunkel' {
        $res = Invoke-Sta {
            param($theme, $dark, $light)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            foreach ($col in @($dark, $light)) {
                $rd = New-Object System.Windows.ResourceDictionary
                $rd.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Parse($col)); $rd.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Parse($theme))
                $cm = New-Object System.Windows.Controls.ContextMenu; $cm.Resources = $rd; $cm.Style = $rd[[System.Windows.Controls.ContextMenu]]
                $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = 'Details kopieren'; [void]$cm.Items.Add($mi)
                $cm.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
                '' + ($cm.DesiredSize.Width -gt 0) + '|' + [string]$cm.Background
            }
        } @($script:ThemeXaml, $script:DarkXaml, $script:LightXaml)
        $res.Count | Should -Be 2
        foreach ($r in $res) { $r | Should -Match '^True\|#' }
        $res[0] | Should -Not -Be $res[1]
    }
}

Describe 'v2.7.19 Zusatz: Importfehler 806 und 808 in Klartext' {
    BeforeAll { . ([scriptblock]::Create($script:FnByName['Get-ImportErrorText'])) }
    It '806: alter Eintrag im eigenen Tenant, naechster Schritt im Status' {
        $e = Get-ImportErrorText '806' 'ZtdDeviceAlreadyAssigned'
        $e.Nr | Should -Be '806'
        $e.Was | Should -Match 'schon in Autopilot, unter einem alten Eintrag \(Fehler ZtdDeviceAlreadyAssigned 806\)'
        $e.Tun | Should -Match 'Autopilot-Eintrag löschen.*nochmal importieren'
        (Get-ImportErrorText '' 'ZtdDeviceAlreadyAssigned').Nr | Should -Be '806'
    }
    It '808: anderer Tenant, zuerst eigenen alten Eintrag pruefen, sonst Freigabe' {
        $e = Get-ImportErrorText '808' 'ZtdDeviceAssignedToOtherTenant'
        $e.Nr | Should -Be '808'
        $e.Was | Should -Match 'anderen Organisation'
        $e.Tun | Should -Match 'alten Eintrag.*Händler oder Vorbesitzer'
        (Get-ImportErrorText '0' 'ZtdDeviceAssignedToOtherTenant').Nr | Should -Be '808'
    }
    It 'andere Codes und leer: kein Klartext, die bisherige Meldung bleibt' {
        Get-ImportErrorText '801' 'ZtdDeviceDuplicated' | Should -BeNullOrEmpty
        Get-ImportErrorText '' '' | Should -BeNullOrEmpty
        Get-ImportErrorText '0' '' | Should -BeNullOrEmpty
        $script:SetupText | Should -Match '\$ie = Get-ImportErrorText \(\[string\]\$st\.state\.deviceErrorCode\) \(\[string\]\$st\.state\.deviceErrorName\)'
    }
    It 'Texte ohne typografische Zeichen' {
        foreach ($c in '806', '808') { $e = Get-ImportErrorText $c ''; ($e.Was + $e.Tun) | Should -Not -Match '[\u2013\u2014\u2192\u201E\u201C\u2026]' }
    }
}

Describe 'v2.7.19 Paket 2: Secret abgelaufen, gefuehrt erneuern' {
    BeforeAll {
        . ([scriptblock]::Create((@('Get-SecretBanner', 'Get-SecretPortalUrl', 'Update-SecretBanner', 'Set-SecretMode', 'Invoke-SecretAutoCheck', 'Open-SecretPortal', 'Test-SecretDateExpired', 'Get-SecretExpiresValue') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        # Umgebung des Setups, ohne Oberflaeche und ohne Netz
        $script:ui = @{}
        $script:Secret = ''
        $script:Cfg = @{ TenantId = '11111111-2222-3333-4444-555555555555'; ClientId = '66666666-7777-8888-9999-000000000000' }
        function Get-Secret { return $script:Secret }
        function Get-Cfg { return $script:Cfg }
        function Set-UiBusy([bool]$On) { $script:BusyCalls += @($On) }
        function Set-Step([string]$Step, [string]$State, [string]$Note = '') { $script:LastStep = $State }
        function Step-Ui { }
        function Set-SubSecret([string]$Text, [bool]$Warn) { $script:Sub = $Text }
        $script:Logs = New-Object System.Collections.Generic.List[string]
        function Out-Log([string]$m, [string]$Level = '') { $script:Logs.Add($Level + ': ' + $m) }
        function Open-InfoLink([string]$Target) { $script:Opened = $Target }
        $script:SecTimer = [pscustomobject]@{ Starts = 0 } | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Starts++ } -PassThru | Add-Member -MemberType ScriptMethod -Name Stop -Value { } -PassThru
    }
    BeforeEach {
        $script:SecMode = ''; $script:SecEndText = ''; $script:SecAwait = $false; $script:SecChecking = $false; $script:SecCheckedFor = ''
        $script:Busy = $false; $script:BusyCalls = @(); $script:Logs.Clear(); $script:SecretEnd = $null; $script:SecretEndFor = ''
        $script:SecretExpLoaded = ''; $script:SecretExpLoadedFor = ''
    }
    It 'Texte je Modus: abgelaufen mit Knopf, ohne Netz nie ungueltig, gueltig mit Erinnerung an die Sticks' {
        $b = Get-SecretBanner 'expired' '13.11.2026 10:00'
        $b.Show | Should -BeTrue; $b.Button | Should -BeTrue; $b.Color | Should -Be 'HuErr'
        $b.Text | Should -Match 'abgelaufen \(seit 13\.11\.2026 10:00\)'
        $b.Text | Should -Match 'Neues Secret anlegen'
        $n = Get-SecretBanner 'net'
        $n.Text | Should -Match 'noch nicht geprüft'
        $n.Text | Should -Match 'ungültig ist es deshalb nicht'
        $n.Color | Should -Not -Be 'HuErr'
        (Get-SecretBanner 'ok' '28.11.2026 09:00').Text | Should -Match '^Neues Secret gültig bis 28\.11\.2026 09:00\. Jetzt speichern .*jeden Stick neu bespielen'
        (Get-SecretBanner 'okNoEnd').Text | Should -Match '^Neues Secret gültig, Ablauf unbekannt\.'
        (Get-SecretBanner 'saved').Text | Should -Match 'Stick neu bespielen'
        (Get-SecretBanner '').Show | Should -BeFalse
        foreach ($m in 'expired', 'awaiting', 'checking', 'net', 'wrong', 'fail', 'ok', 'okNoEnd', 'saved') {
            $t = (Get-SecretBanner $m 'x').Text
            $t | Should -Not -Match '[\u2013\u2014\u2192\u201E\u201C\u2026]' -Because $m
        }
    }
    It 'Portal-Link aus der App-ID, ohne gueltige App-ID die Liste der App-Registrierungen' {
        Get-SecretPortalUrl '66666666-7777-8888-9999-000000000000' | Should -Be 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/66666666-7777-8888-9999-000000000000'
        Get-SecretPortalUrl 'ABCDEF00-7777-8888-9999-000000000000' | Should -Match 'appId/abcdef00-'
        Get-SecretPortalUrl '' | Should -Be 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade'
        Get-SecretPortalUrl 'keine-guid' | Should -Match 'ApplicationsListBlade$'
    }
    It 'Knopf ohne App-ID: Liste oeffnen und Klartext, kein Absturz' {
        $script:Cfg = @{ TenantId = '11111111-2222-3333-4444-555555555555'; ClientId = '' }
        Open-SecretPortal
        $script:Opened | Should -Match 'ApplicationsListBlade$'
        ($script:Logs -join "`n") | Should -Match 'App-ID \(Client\) fehlt'
        $script:Cfg.ClientId = '66666666-7777-8888-9999-000000000000'
        Open-SecretPortal
        $script:Opened | Should -Match 'Credentials/appId/66666666'
        $script:SecMode | Should -Be 'awaiting'
        $script:SecAwait | Should -BeTrue
    }
    It 'nach dem Einfuegen: ohne Internet Modus net, nie ungueltig' {
        $script:Secret = 'Neu~0123456789abcdefghijklmnopqrstuv'
        function Get-ApiToken { $script:TokenErr = 'net'; $script:TokenMsg = 'Keine Verbindung'; return $null }
        Invoke-SecretAutoCheck
        $script:SecMode | Should -Be 'net'
        $script:LastStep | Should -Be 'warn'
        $script:BusyCalls | Should -Be @($true, $false)
    }
    It 'nach dem Einfuegen: gueltig bis ..., ohne Leserecht Ablauf unbekannt' {
        $script:Secret = 'Neu~0123456789abcdefghijklmnopqrstuv'
        function Get-ApiToken { $script:TokenErr = ''; return 'tok' }
        function Show-SecretExpiry([string]$Token, [int]$TimeoutSec = 30) { $script:SecretEnd = [datetime]::UtcNow.AddDays(14); $script:SecretEndFor = Get-StrHash $script:Secret }
        Invoke-SecretAutoCheck
        $script:SecMode | Should -Be 'ok'
        $script:SecEndText | Should -Match '^\d\d\.\d\d\.\d{4} \d\d:\d\d$'
        ($script:Logs -join "`n") | Should -Match 'Secret gültig bis .*neu bespielen'
        # gleicher Wert: keine zweite Pruefung
        $script:Logs.Clear(); Invoke-SecretAutoCheck; $script:Logs.Count | Should -Be 0
        $script:Secret = 'Neu2~0123456789abcdefghijklmnopqrstu'
        function Show-SecretExpiry([string]$Token, [int]$TimeoutSec = 30) { }
        Invoke-SecretAutoCheck
        $script:SecMode | Should -Be 'okNoEnd'
        $script:Sub | Should -Be 'Secret gültig, Ablauf unbekannt'
    }
    It 'falsches Secret eingefuegt: Modus wrong mit Knopf' {
        $script:Secret = 'Neu~0123456789abcdefghijklmnopqrstuv'
        function Get-ApiToken { $script:TokenErr = 'wrong'; $script:TokenMsg = 'falsch'; return $null }
        Invoke-SecretAutoCheck
        $script:SecMode | Should -Be 'wrong'
        $script:LastStep | Should -Be 'err'
    }
    It 'Pruefung laeuft schon oder Stick fertig machen laeuft: spaeter nochmal, keine zweite Anmeldung' {
        $script:Secret = 'Neu~0123456789abcdefghijklmnopqrstuv'
        $script:Calls = 0
        function Get-ApiToken { $script:Calls++; return $null }
        $script:SecChecking = $true; $s0 = $script:SecTimer.Starts
        Invoke-SecretAutoCheck
        $script:Calls | Should -Be 0
        $script:SecTimer.Starts | Should -Be ($s0 + 1)
        $script:SecChecking = $false; $script:Busy = $true
        Invoke-SecretAutoCheck
        $script:Calls | Should -Be 0
    }
    It 'unvollstaendiger Wert oder fehlende App-ID: keine Anmeldung' {
        $script:Calls = 0
        function Get-ApiToken { $script:Calls++; return $null }
        $script:Secret = 'kurz'; Invoke-SecretAutoCheck
        $script:Secret = 'Neu~0123456789abcdefghijklmnopqrstuv'; $script:Cfg = @{ TenantId = ''; ClientId = '' }
        Invoke-SecretAutoCheck
        $script:Calls | Should -Be 0
        ($script:Logs -join "`n") | Should -Match 'fehlen Tenant-ID oder App-ID'
        $script:Cfg = @{ TenantId = '11111111-2222-3333-4444-555555555555'; ClientId = '66666666-7777-8888-9999-000000000000' }
    }
    It 'abgelaufen laut gespeichertem Datum (ohne Netz), nur fuer genau dieses Secret' {
        $script:Secret = 'Alt~0123456789abcdefghijklmnopqrstuv'
        $script:SecretExpLoaded = '2026-01-01T00:00:00Z'; $script:SecretExpLoadedFor = Get-StrHash $script:Secret
        Test-SecretDateExpired
        $script:SecMode | Should -Be 'expired'
        $script:SecAwait | Should -BeTrue
        $script:SecMode = ''; $script:Secret = 'Anderes~0123456789abcdefghijklmnop'
        Test-SecretDateExpired
        $script:SecMode | Should -Be ''
    }
    It 'Verdrahtung: abgelaufen beim Anmelden, gespeichert erinnert an die Sticks, Merker ungespeichert bleibt' {
        $script:SetupText | Should -Match "if \(\`$kind -eq 'expired'\) \{ Set-SecretMode 'expired' \}"
        $script:SetupText | Should -Match "if \(\`$script:SecMode -in 'ok', 'okNoEnd'\) \{ Set-SecretMode 'saved'"
        $script:SetupText | Should -Match '\[System\.Windows\.DataObject\]::AddPastingHandler\(\$sf, \[System\.Windows\.DataObjectPastingEventHandler\]\$reqSecCheck\)'
        $script:SetupText | Should -Match "foreach \(\`$n in 'pSecret','pEdKey','pKey','pAdmPw','pAdm2Pw'\) \{ \`$ui\[\`$n\]\.Add_PasswordChanged\(\{ Update-Dirty \}\) \}"
        $x = [xml]@($script:XamlBlocks | Where-Object { $_.Name -eq 'xaml' })[0].Xaml
        $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        foreach ($n in 'bdSecret', 'bSecNew', 'tSecBanner', 'bReadySec') { $x.SelectSingleNode("//*[@x:Name='$n']", $ns) | Should -Not -BeNullOrEmpty -Because $n }
    }
}

Describe 'v2.7.19 Pakete 3 und 4: Hardware geaendert und doppelte Seriennummern' {
    BeforeAll {
        . ([scriptblock]::Create((@('Get-DeviceStand', 'Get-DeviceTodo', 'Get-DuplicateMarks', 'Get-DuplicateTodo', 'Get-PendingTodo') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        # Staende und Kacheln wie im Setup
        $cls = [regex]::Match($script:SetupText, '(?m)^\$script:StandClass = (@\{.*\})\r?$').Groups[1].Value
        $til = [regex]::Match($script:SetupText, '(?m)^\$script:StandTile = (@\{.*\})\r?$').Groups[1].Value
        $script:StandClass = Invoke-Expression $cls
        $script:StandTile = Invoke-Expression $til
    }
    It 'Hardware geaendert bei automatic- und manualRemediationRequired, vor Fertig' {
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'manualRemediationRequired' | Should -Be 'Hardware geändert'
        Get-DeviceStand 'assignedInSync' 'notContacted' $true 'manualRemediationRequired' | Should -Be 'Hardware geändert'
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'noRemediationRequired' | Should -Be 'Fertig'
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'unknown' | Should -Be 'Fertig'
        Get-DeviceStand 'assignedInSync' 'enrolled' $true | Should -Be 'Fertig'
    }
    It 'Was tun bei Hardware geaendert: ein Satz, bereinigen und neu registrieren' {
        $t = Get-DeviceTodo 'Hardware geändert' '' ''
        $t | Should -Match 'Autopilot-Eintrag löschen'
        $t | Should -Match 'neu registrieren\.$'
        @([regex]::Matches($t, '\.(\s|$)')).Count | Should -Be 1
    }
    It 'neue Staende haben Farbe und Kachel, rot fuer Hardware und Doppelt (Filter nur Probleme)' {
        foreach ($s in 'Hardware geändert', 'Doppelt', 'Wird gelöscht') { $script:StandClass.ContainsKey($s) | Should -BeTrue; $script:StandTile.ContainsKey($s) | Should -BeTrue }
        $script:StandClass['Hardware geändert'] | Should -Be 'err'
        $script:StandClass['Doppelt'] | Should -Be 'err'
        $script:StandClass['Wird gelöscht'] | Should -Be 'warn'
        $script:StandTile['Hardware geändert'] | Should -Be 'hw'
        $script:StandTile['Doppelt'] | Should -Be 'dup'
    }
    It 'doppelt: juengste Spur ist der neuere Eintrag, die anderen sind aelter' {
        $recs = @(
            [pscustomobject]@{ id = 'a1'; serialNumber = 'SN100'; lastContactedDateTime = '2026-01-10T08:00:00Z'; deploymentProfileAssignedDateTime = '2025-09-01T08:00:00Z' },
            [pscustomobject]@{ id = 'a2'; serialNumber = 'sn100 '; lastContactedDateTime = '0001-01-01T00:00:00Z'; deploymentProfileAssignedDateTime = '2026-11-13T08:00:00Z' },
            [pscustomobject]@{ id = 'b1'; serialNumber = 'SN200'; lastContactedDateTime = '2026-11-13T08:00:00Z' }
        )
        $m = Get-DuplicateMarks $recs
        $m.Count | Should -Be 2
        $m['a2'].Rank | Should -Be 'neuer'
        $m['a1'].Rank | Should -Be 'älter'
        $m['a1'].Count | Should -Be 2
        $m.ContainsKey('b1') | Should -BeFalse
    }
    It 'doppelt: gleich alt oder ohne Spur ist unklar, leere Seriennummern nie doppelt' {
        $recs = @(
            [pscustomobject]@{ id = 'c1'; serialNumber = 'SN300' },
            [pscustomobject]@{ id = 'c2'; serialNumber = 'SN300' },
            [pscustomobject]@{ id = 'd1'; serialNumber = 'SN400'; lastContactedDateTime = '2026-11-13T08:00:00Z' },
            [pscustomobject]@{ id = 'd2'; serialNumber = 'SN400'; lastContactedDateTime = '2026-11-13T08:00:00Z' },
            [pscustomobject]@{ id = 'e1'; serialNumber = '' },
            [pscustomobject]@{ id = 'e2'; serialNumber = '  ' },
            [pscustomobject]@{ id = 'e3'; serialNumber = $null }
        )
        $m = Get-DuplicateMarks $recs
        $m['c1'].Rank | Should -Be 'unklar'
        $m['c2'].Rank | Should -Be 'unklar'
        $m['d1'].Rank | Should -Be 'unklar'
        foreach ($i in 'e1', 'e2', 'e3') { $m.ContainsKey($i) | Should -BeFalse }
    }
    It 'doppelt: PowerShell 7 liefert DateTime statt Text, gleiches Ergebnis' {
        $recs = @(
            [pscustomobject]@{ id = 'f1'; serialNumber = 'SN500'; lastContactedDateTime = [datetime]::SpecifyKind([datetime]'2026-03-01T08:00:00', 'Utc') },
            [pscustomobject]@{ id = 'f2'; serialNumber = 'SN500'; lastContactedDateTime = [datetime]::SpecifyKind([datetime]'2026-10-01T08:00:00', 'Utc') }
        )
        $m = Get-DuplicateMarks $recs
        $m['f2'].Rank | Should -Be 'neuer'
        $m['f1'].Rank | Should -Be 'älter'
    }
    It 'Was tun bei doppelt: aelterer loeschen, neuester behalten, unklar vergleichen' {
        Get-DuplicateTodo 2 'älter' | Should -Match '^Älterer von 2 Einträgen: diesen löschen'
        Get-DuplicateTodo 2 'neuer' | Should -Match 'behalten, den älteren löschen'
        Get-DuplicateTodo 3 'unklar' | Should -Match '^3 Einträge, Alter unklar: in den Details vergleichen'
    }
    It 'Was tun der neuen Staende passt in die Spalte (hoechstens 420 px, Segoe UI 12)' {
        $res = Invoke-Sta {
            param($fnText)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            . ([scriptblock]::Create($fnText))
            $tf = New-Object System.Windows.Media.Typeface((New-Object System.Windows.Media.FontFamily('Segoe UI')), [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
            $t0 = Get-Date '2026-11-14 10:00'
            foreach ($s in @((Get-DeviceTodo 'Hardware geändert' '' ''), (Get-DuplicateTodo 2 'älter'), (Get-DuplicateTodo 2 'neuer'), (Get-DuplicateTodo 3 'unklar'), (Get-PendingTodo $t0 $t0), (Get-PendingTodo $t0 $t0.AddHours(1)))) {
                $ft = New-Object System.Windows.Media.FormattedText($s, [Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $tf, 12.0, [System.Windows.Media.Brushes]::Black)
                '' + [math]::Ceiling($ft.WidthIncludingTrailingWhitespace) + '|' + $s
            }
        } @((@('Get-DeviceTodo', 'Get-DuplicateTodo', 'Get-PendingTodo') | ForEach-Object { $script:FnByName[$_] }) -join "`n")
        $res.Count | Should -Be 6
        foreach ($r in $res) { [int]($r.Split('|')[0]) | Should -BeLessThan 390 -Because $r }
    }
    It 'Wird geloescht: bis 30 Minuten nichts tun, danach Hinweis' {
        $t0 = Get-Date '2026-11-14 10:00'
        Get-PendingTodo $t0 $t0.AddMinutes(5) | Should -Match '^Nichts tun\..*bis zu 30 Minuten'
        Get-PendingTodo $t0 $t0.AddMinutes(31) | Should -Match 'über 30 Minuten'
    }
    It 'Status: Rangfolge Wird geloescht vor Doppelt vor den uebrigen, geloeschte zaehlen nicht als doppelt' {
        $script:SetupText | Should -Match '\$dup = Get-DuplicateMarks @\(\$all \| Where-Object \{ -not \$pend\.ContainsKey\(\[string\]\$_\.id\) \}\)'
        $script:SetupText | Should -Match "if \(\`$pend\.ContainsKey\(\`$id\)\) \{ \`$stand = 'Wird gelöscht'"
        $script:SetupText | Should -Match "elseif \(\`$dm\) \{ \`$stand = 'Doppelt'"
        $script:SetupText | Should -Match '\$stand = Get-DeviceStand \$ps \$es \$hasDate \$rem'
    }
    It 'Status: Kacheln, Druck und Details kennen die neuen Staende, Aktionen nutzen die Kennung der Zeile' {
        $sx = @($script:XamlBlocks | Where-Object { $_.Name -eq 'sx' })[0].Xaml
        foreach ($n in 'kHw', 'kDup', 'kDel', 'nHw', 'nDup', 'nDel') { $sx | Should -Match ('x:Name="' + $n + '"') }
        $script:SetupText | Should -Match "hw = 'Hardware geändert'; hwa = 'Hardware wird abgeglichen'; dup = 'Doppelt'; del = 'Wird gelöscht'"
        $script:SetupText | Should -Match "\('Hardware:          ' \+"
        $script:SetupText | Should -Match "\('Doppelt:           ' \+"
        $script:SetupText | Should -Match '\$id = \$\(if \(\$r\.Id\) \{ \[string\]\$r\.Id \} else \{ \$script:ApIds\[\[string\]\$r\.Seriennr\] \}\)'
        $script:SetupText | Should -Match '\$id = \$\(if \(\$Row\.Id\) \{ \[string\]\$Row\.Id \} else \{ \$script:ApIds\[\[string\]\$Row\.Seriennr\] \}\)'
    }
}

Describe 'v2.7.19 Paket 5: Autopilot-Eintrag loeschen mit doppelter Abfrage (mit Korrekturrunde 1)' {
    BeforeAll {
        . ([scriptblock]::Create((@('Get-ErrCode', 'Get-ErrText', 'Get-TokenRoles', 'Test-SerialPlaceholder', 'Resolve-IntuneLink', 'Get-IntunePlan', 'Test-DeleteSelection', 'Test-DeleteConfirm', 'Get-DeleteAskText', 'Get-DeleteWarnings', 'Get-DeletePlanText', 'Get-DeleteOutcome', 'Invoke-ApDeleteOne', 'Get-DeleteSummary') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        . ([scriptblock]::Create([regex]::Match($script:SetupText, '(?m)^\$script:SerialPlaceholders = @\(.*\)\r?$').Value))
        $script:DelMax = 5
        $script:DelGB = 'https://graph.microsoft.com/beta/deviceManagement'
        # Graph ersetzt: jeder Aufruf wird mitgeschrieben, die Antwort kommt aus $script:Fake (nie ein echter Aufruf)
        $script:Calls = New-Object System.Collections.Generic.List[string]
        function Invoke-HuGraph([string]$Method, [string]$Uri, [string]$Token) {
            $script:Calls.Add($Method + ' ' + $Uri.Replace($script:DelGB, ''))
            return (& $script:Fake $Method $Uri.Replace($script:DelGB, ''))
        }
        function New-Row([string]$Sn = 'SN100', [string]$Id = 'ap1', [string]$IntuneId = 'md1', [int]$Dup = 0, [string]$Link = 'ms', [int]$SnCount = 1, [bool]$Ambig = $false) {
            [pscustomobject]@{ Seriennr = $Sn; Id = $Id; IntuneId = $IntuneId; IntuneLink = $(if ($IntuneId) { $Link } else { '' }); IntuneAmbig = $Ambig; IntuneSnCount = $SnCount; DupCount = $Dup; DupRank = ''
                Stand = 'Hardware geändert'; Name = 'PC-01'; Tag = 'SN-2026'; Benutzer = ''; EnrollState = 'notContacted'; SyncSort = ''; LetzterKontakt = '13.11.2026 09:10' }
        }
        function Plan($Row, [bool]$Can = $true) { Get-IntunePlan $Row $Can }
        # Standard: alles passt (Seriennummer SN100, verknuepfter Intune-Eintrag md1, Benutzer zugewiesen)
        $script:FakeOk = {
            param($m, $u)
            if ($m -eq 'GET' -and $u -eq '/windowsAutopilotDeviceIdentities/ap1') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'SN100'; managedDeviceId = 'md1'; userPrincipalName = 'schueler1@example.org' } }
            if ($m -eq 'GET' -and $u -like '/managedDevices/md1*') { return [pscustomobject]@{ id = 'md1'; serialNumber = 'SN100'; deviceName = 'PC-01' } }
            return $null
        }
        $script:FakeNoLink = {
            param($m, $u)
            if ($m -eq 'GET' -and $u -like '/windowsAutopilot*') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'SN100'; managedDeviceId = '00000000-0000-0000-0000-000000000000' } }
            if ($m -eq 'GET' -and $u -like '/managedDevices/mdListe*') { return [pscustomobject]@{ id = 'mdListe'; serialNumber = 'SN100' } }
            return $null
        }
    }
    BeforeEach { $script:Calls.Clear(); $script:Fake = $script:FakeOk }
    It 'Auswahl: nichts markiert, mehr als 5, wird schon geloescht, ohne Kennung, ohne Seriennummer = nichts tun, mit Klartext' {
        (Test-DeleteSelection @()).Ok | Should -BeFalse
        (Test-DeleteSelection @()).Msg | Should -Match 'markieren'
        $six = @(1..6 | ForEach-Object { New-Row ('SN10' + $_) ('ap' + $_) })
        $r6 = Test-DeleteSelection $six
        $r6.Ok | Should -BeFalse
        $r6.Msg | Should -Match 'Höchstens 5 Geräte auf einmal\. Markiert sind 6\..*nichts gelöscht'
        $ok = Test-DeleteSelection @($six[0..4])
        $ok.Ok | Should -BeTrue
        @($ok.Rows).Count | Should -Be 5
        $p = New-Row; $p.Stand = 'Wird gelöscht'
        (Test-DeleteSelection @($p)).Msg | Should -Match 'wird schon gelöscht'
        (Test-DeleteSelection @((New-Row 'SN109' ''))).Msg | Should -Match 'Kennung fehlt'
        $e = Test-DeleteSelection @((New-Row ''), (New-Row 'SN200' 'ap2'))
        $e.Ok | Should -BeFalse
        $e.Msg | Should -Match '^Eintrag ohne Seriennummer.*Admin im Intune-Portal'
        (Test-DeleteSelection @((New-Row '   '))).Ok | Should -BeFalse
    }
    It 'zweite Abfrage streng, Text und Pruefung aus derselben Liste' {
        Test-DeleteConfirm 'SN100' @('SN100') | Should -BeTrue
        Test-DeleteConfirm 'sn100' @('SN100') | Should -BeFalse
        Test-DeleteConfirm 'SN100 ' @('SN100') | Should -BeFalse
        Test-DeleteConfirm 'LÖSCHEN' @('SN100') | Should -BeFalse
        Test-DeleteConfirm '' @('SN100') | Should -BeFalse
        Test-DeleteConfirm 'LÖSCHEN' @('SN1', 'SN2') | Should -BeTrue
        Test-DeleteConfirm 'löschen' @('SN1', 'SN2') | Should -BeFalse
        Test-DeleteConfirm 'SN1' @('SN1', 'SN2') | Should -BeFalse
        Get-DeleteAskText @('SN100') | Should -Match 'Seriennummer SN100 genau so eintippen'
        Get-DeleteAskText @('SN1', 'SN2') | Should -Match 'das Wort LÖSCHEN'
        $script:SetupText | Should -Match '\$c\.tAsk\.Text = Get-DeleteAskText \$sns'
        $script:SetupText | Should -Match '\$sel = @\(\$chk\.Rows\)'
    }
    It 'Einfuegen in die zweite Abfrage ist gesperrt, Tooltip sagt es' {
        $lx = @($script:XamlBlocks | Where-Object { $_.Name -eq 'lx' })[0].Xaml
        $lx | Should -Match 'x:Name="tType"[^>]*AllowDrop="False"[^>]*ToolTip="Bitte tippen, Einfügen ist hier gesperrt\.'
        $script:SetupText | Should -Match '\[System\.Windows\.DataObject\]::AddPastingHandler\(\$c\.tType, \[System\.Windows\.DataObjectPastingEventHandler\]\{ param\(\$s, \$e\) \$e\.CancelCommand\(\) \}\)'
        $script:SetupText | Should -Match '\$c\.tType\.Add_PreviewDrop\('
        $script:SetupText | Should -Match 'ApplicationCommands\]::Paste'
        # Text der ersten Seite bleibt markier- und kopierbar (nur lesend, kein Sperren)
        $lx | Should -Match 'x:Name="tPlan" IsReadOnly="True"'
    }
    It 'Einfuegen ist im echten Eingabefeld wirkungslos (STA)' {
        $res = Invoke-Sta {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $tb = New-Object System.Windows.Controls.TextBox
            [System.Windows.DataObject]::AddPastingHandler($tb, [System.Windows.DataObjectPastingEventHandler]{ param($s, $e) $e.CancelCommand() })
            $tb.CommandBindings.Add((New-Object System.Windows.Input.CommandBinding([System.Windows.Input.ApplicationCommands]::Paste, { param($s, $e) $e.Handled = $true }, { param($s, $e) $e.CanExecute = $false; $e.Handled = $true }))) | Out-Null
            # ohne Zwischenablage (im Test nicht verfuegbar und nicht anzufassen): der Befehl Einfuegen ist im Feld nicht ausfuehrbar
            $w = New-Object System.Windows.Window; $w.Content = $tb; $w.ShowInTaskbar = $false
            '' + [System.Windows.Input.ApplicationCommands]::Paste.CanExecute($null, $tb)
        }
        @($res)[0] | Should -Be 'False'
    }
    It 'Rechte aus dem Token, unlesbar oder ohne roles = leer (unbekannt)' {
        $mk = { param($json) 'eyJ0eXAiOiJKV1QifQ.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_') + '.sig' }
        Get-TokenRoles (& $mk '{"roles":["DeviceManagementServiceConfig.ReadWrite.All","DeviceManagementManagedDevices.ReadWrite.All"]}') | Should -Contain 'DeviceManagementManagedDevices.ReadWrite.All'
        @(Get-TokenRoles (& $mk '{"aud":"x"}')).Count | Should -Be 0
        @(Get-TokenRoles 'kaputt').Count | Should -Be 0
        @(Get-TokenRoles '').Count | Should -Be 0
    }
    It 'ohne DeviceManagementServiceConfig.ReadWrite.All wird nichts angeboten (nur bei lesbaren Rechten)' {
        $script:SetupText | Should -Match "if \(\`$roles\.Count -and \`$roles -notcontains 'DeviceManagementServiceConfig\.ReadWrite\.All'\) \{"
        $script:SetupText | Should -Match 'Der App fehlt das Recht DeviceManagementServiceConfig\.ReadWrite\.All\. Damit lässt sich kein Autopilot-Eintrag löschen\. Es wurde nichts gelöscht'
        # die Pruefung steht vor der Rueckfrage
        $i1 = $script:SetupText.IndexOf("`$roles -notcontains 'DeviceManagementServiceConfig.ReadWrite.All'"); $i2 = $script:SetupText.IndexOf('if (-not (Show-DeleteConfirm $sel $canI $sw $plans))')
        $i1 | Should -BeGreaterThan 0; $i1 | Should -BeLessThan $i2
    }
    It 'Hersteller-Platzhalter und unsichere Seriennummern' {
        foreach ($s in 'To be filled by O.E.M.', 'System Serial Number', 'Default string', 'None', '0', 'AAAAAAAA', '1111', '', '   ', 'abc', 'not specified') { Test-SerialPlaceholder $s | Should -BeTrue -Because "[$s]" }
        foreach ($s in 'SN26-PF07W4LQA', 'PF4ABC12', '5CG1234XYZ') { Test-SerialPlaceholder $s | Should -BeFalse -Because $s }
    }
    It 'Zuordnung zum Intune-Eintrag: Verknuepfung gewinnt, Rueckfall nur eindeutig, Mehrfachtreffer gemerkt' {
        $md = @{ 'm1' = [pscustomobject]@{ id = 'm1' }; 'SN:SN100' = [pscustomobject]@{ id = 'm1' }; 'SN:SN300' = [pscustomobject]@{ id = 'm3b' }; 'SN:To be filled by O.E.M.' = [pscustomobject]@{ id = 'm9' } }
        $cnt = @{ 'SN:SN100' = 1; 'SN:SN300' = 2; 'SN:To be filled by O.E.M.' = 1 }
        $a = Resolve-IntuneLink 'mX' 'SN300' $md $cnt
        $a.Link | Should -Be 'ms'; $a.Id | Should -Be 'mX'; $a.SnCount | Should -Be 2
        $b = Resolve-IntuneLink '00000000-0000-0000-0000-000000000000' 'SN100' $md $cnt
        $b.Link | Should -Be 'sn'; $b.Id | Should -Be 'm1'
        $c = Resolve-IntuneLink '' 'SN300' $md $cnt
        $c.Id | Should -Be ''; $c.Ambig | Should -BeTrue; $c.SnCount | Should -Be 2
        $d = Resolve-IntuneLink '' 'To be filled by O.E.M.' $md $cnt
        $d.Id | Should -Be ''; $d.Ambig | Should -BeTrue
        $e = Resolve-IntuneLink '' 'SN100' $md $cnt $true
        $e.Id | Should -Be ''; $e.Ambig | Should -BeTrue
        $f = Resolve-IntuneLink '' 'SN555' $md $cnt
        $f.Id | Should -Be ''; $f.Ambig | Should -BeFalse
        $script:SetupText | Should -Match "\`$mdCnt\[\`$k\] = 1 \+ \[int\]\`$mdCnt\[\`$k\]"
    }
    It 'Intune-Plan: eine Quelle fuer Rueckfrage und Ausfuehrung' {
        (Plan (New-Row)).Kind | Should -Be 'delete'
        (Plan (New-Row)).Text | Should -Be 'Eintrag md1 wird gelöscht'
        (Plan (New-Row) $false).Kind | Should -Be 'right'
        (Plan (New-Row 'SN100' 'ap1' '' 0 '' 2 $true)).Kind | Should -Be 'ambig'
        (Plan (New-Row 'SN100' 'ap1' '' 0 '' 2 $true)).Text | Should -Be 'Intune-Eintrag nicht eindeutig zuordenbar, bleibt stehen, Admin im Intune-Portal'
        (Plan (New-Row 'SN100' 'ap1' '')).Kind | Should -Be 'none'
        $script:SetupText | Should -Match '\$plans = @\(\$sel \| ForEach-Object \{ Get-IntunePlan \$_ \$canI \}\)'
        $script:SetupText | Should -Match '\$x = Invoke-ApDeleteOne \$r \$tok \$plans\[\$i\]'
        $script:FnByName['Get-DeletePlanText'] | Should -Match 'Get-IntunePlan \$_ \$CanIntune'
    }
    It 'erste Rueckfrage: Autopilot-ID, letzter Kontakt, Rang bei Doppel, Intune-Plan, Warnungen' {
        $a = New-Row; $b = New-Row 'SN200' 'ap2' ''; $b.Stand = 'Fertig'; $b.EnrollState = 'enrolled'; $b.Benutzer = 'lehrer1@example.org'; $b.SyncSort = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd HH:mm')
        $t = Get-DeletePlanText @($a, $b) $true (Get-Date)
        $t | Should -Match 'Seriennummer: SN100'
        $t | Should -Match 'Autopilot-ID: ap1'
        $t | Should -Match 'Letzter Kontakt: 13\.11\.2026 09:10'
        $t | Should -Match 'Gerätename:   PC-01'
        $t | Should -Match 'Benutzer:     lehrer1@example\.org'
        $t | Should -Match 'Intune:       Eintrag md1 wird gelöscht'
        $t | Should -Match 'Intune:       kein Eintrag bekannt'
        $t | Should -Match 'ACHTUNG: Das Gerät ist fertig eingerichtet'
        $t | Should -Match 'ACHTUNG: Das Gerät ist in Benutzung'
        $t | Should -Match 'Der Intune-Eintrag \(bei 1 Gerät\)'
        $t | Should -Match 'Rückgängig machen geht nicht'
        $t2 = Get-DeletePlanText @($a) $false (Get-Date)
        $t2 | Should -Match 'Nicht gelöscht wird der Intune-Eintrag.*DeviceManagementManagedDevices\.ReadWrite\.All'
        $t2 | Should -Match 'Eintrag bleibt stehen \(Recht fehlt\)'
        $t3 = Get-DeletePlanText @((New-Row 'SN100' 'ap1' '' 0 '' 2 $true)) $true (Get-Date)
        $t3 | Should -Match 'nicht eindeutig zuordenbar'
        $t3 | Should -Match 'Nicht angefasst wird der Intune-Eintrag'
        $t | Should -Not -Match '[–—→„“…]'
    }
    It 'Zwillinge: Rang je Eintrag, beide markiert = eigene ACHTUNG-Zeile' {
        $x = New-Row 'SN300' 'apA' '' 2; $x.DupRank = 'älter'
        $y = New-Row 'SN300' 'apB' '' 2; $y.DupRank = 'neuer'
        $t = Get-DeletePlanText @($x, $y) $true (Get-Date)
        $t | Should -Match 'Autopilot-ID: apA'
        $t | Should -Match 'Autopilot-ID: apB'
        $t | Should -Match 'Doppelt:      älterer von 2'
        $t | Should -Match 'Doppelt:      neuerer von 2'
        @([regex]::Matches($t, 'ACHTUNG: Beide Einträge dieser Seriennummer sind markiert\. Danach ist das Gerät nicht mehr in Autopilot\.')).Count | Should -Be 2
        $t1 = Get-DeletePlanText @($x) $true (Get-Date)
        $t1 | Should -Not -Match 'Beide Einträge'
        $z = New-Row 'SN300' 'apC' '' 2; $z.DupRank = 'unklar'
        (Get-DeletePlanText @($z) $true (Get-Date)) | Should -Match 'Doppelt:      Alter unklar \(2 Einträge\)'
    }
    It 'Auswahl nach dem Auffrischen ueber die Kennung, nie ueber die Seriennummer' {
        $script:SetupText | Should -Match '\$selId = @\(\$g\.dGrid\.SelectedItems \| ForEach-Object \{ \[string\]\$_\.Id \} \| Where-Object \{ \$_ \}\)'
        $script:SetupText | Should -Match 'if \(\$it\.Id -and \$selId -contains \[string\]\$it\.Id\) \{ \[void\]\$g\.dGrid\.SelectedItems\.Add\(\$it\) \}'
        $script:SetupText | Should -Not -Match '\$selSn'
    }
    It 'Reihenfolge wie in go.ps1: Intune, Benutzer-Zuweisung, Autopilot, vor jedem Loeschen neu gelesen' {
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        @($script:Calls) | Should -Be @(
            'GET /windowsAutopilotDeviceIdentities/ap1',
            'GET /managedDevices/md1?$select=id,serialNumber,deviceName',
            'DELETE /managedDevices/md1',
            'POST /windowsAutopilotDeviceIdentities/ap1/unassignUserFromDevice',
            'GET /windowsAutopilotDeviceIdentities/ap1',
            'DELETE /windowsAutopilotDeviceIdentities/ap1')
        $x.Deleted | Should -BeTrue
        $x.Level | Should -Be 'OK'
        $x.Text | Should -Match '^SN100: Autopilot-Eintrag gelöscht \(Intune-Eintrag gelöscht, Benutzer-Zuweisung aufgehoben\)'
    }
    It 'Verknuepfung frisch anders als angezeigt, oder neu verknuepft: uebersprungen, nichts geloescht' {
        $script:Fake = { param($m, $u) if ($m -eq 'GET' -and $u -like '/windowsAutopilot*') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'SN100'; managedDeviceId = 'mdNeu' } } }
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        @($script:Calls | Where-Object { $_ -notlike 'GET*' }).Count | Should -Be 0
        $x.Text | Should -Match 'Eintrag hat sich geändert, übersprungen, nichts gelöscht\. Bitte "Aktualisieren" und nochmal\.'
        # vorher kein Intune-Eintrag bekannt, jetzt verknuepft
        $script:Calls.Clear()
        $r2 = New-Row 'SN100' 'ap1' ''
        $x2 = Invoke-ApDeleteOne $r2 'tok' (Plan $r2)
        @($script:Calls | Where-Object { $_ -notlike 'GET*' }).Count | Should -Be 0
        $x2.Deleted | Should -BeFalse
        # nicht eindeutig angezeigt, jetzt verknuepft: auch uebersprungen
        $script:Calls.Clear()
        $r3 = New-Row 'SN100' 'ap1' '' 0 '' 2 $true
        (Invoke-ApDeleteOne $r3 'tok' (Plan $r3)).Deleted | Should -BeFalse
        @($script:Calls | Where-Object { $_ -notlike 'GET*' }).Count | Should -Be 0
    }
    It 'Seriennummer passt beim Neulesen nicht, Eintrag weg oder nicht lesbar: nichts geloescht' {
        $script:Fake = { param($m, $u) if ($m -eq 'GET' -and $u -like '/windowsAutopilotDeviceIdentities/*') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'ANDERE'; managedDeviceId = 'md1' } } }
        $r = New-Row
        (Invoke-ApDeleteOne $r 'tok' (Plan $r)).Text | Should -Match 'Übersprungen, nichts gelöscht'
        $script:Fake = { param($m, $u) throw 'Response status code does not indicate success: 404 (Not Found).' }
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $x.Level | Should -Be 'Hinweis'; $x.Deleted | Should -BeFalse
        $script:Fake = { param($m, $u) throw 'Zeitüberschreitung' }
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $x.Level | Should -Be 'Fehler'; $x.Deleted | Should -BeFalse
        @($script:Calls | Where-Object { $_ -like 'DELETE*' }).Count | Should -Be 0
    }
    It 'verknuepfter Intune-Eintrag gehoert zu anderer Seriennummer: uebersprungen' {
        $script:Fake = { param($m, $u) if ($u -like '/managedDevices/*') { return [pscustomobject]@{ id = 'md1'; serialNumber = 'FREMD' } }; & $script:FakeOk $m $u }
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        @($script:Calls | Where-Object { $_ -like 'DELETE*' -or $_ -like 'POST*' }).Count | Should -Be 0
        $x.Text | Should -Match 'anderen Seriennummer'
    }
    It 'Rueckfall ueber die Seriennummer: frisch gelesene Seriennummer muss da und gleich sein, leer heisst nicht loeschen' {
        $script:Fake = $script:FakeNoLink
        $r = New-Row 'SN100' 'ap1' 'mdListe' 0 'sn'
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $script:Calls | Should -Contain 'DELETE /managedDevices/mdListe'
        $x.Deleted | Should -BeTrue
        $script:Calls.Clear()
        $script:Fake = { param($m, $u) if ($u -like '/managedDevices/*') { return [pscustomobject]@{ id = 'mdListe'; serialNumber = '' } }; & $script:FakeNoLink $m $u }
        $x2 = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        @($script:Calls | Where-Object { $_ -like 'DELETE*' -or $_ -like 'POST*' }).Count | Should -Be 0
        $x2.Text | Should -Match 'passt nicht mehr sicher'
    }
    It 'nicht eindeutig zuordenbar: Intune-Eintrag nicht angefasst, Autopilot geloescht, Ergebnis sagt es' {
        $script:Fake = $script:FakeNoLink
        $r = New-Row 'SN100' 'ap1' '' 2 '' 2 $true
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        @($script:Calls | Where-Object { $_ -like '*managedDevices*' }).Count | Should -Be 0
        $x.Deleted | Should -BeTrue
        $x.Level | Should -Be 'Hinweis'
        $x.Text | Should -Match 'Intune-Eintrag nicht eindeutig zuordenbar, bleibt stehen.*Admin im Intune-Portal'
    }
    It 'ohne Schreibrecht fuer Intune: nur der Autopilot-Eintrag, Hinweis an den Admin' {
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r $false)
        @($script:Calls | Where-Object { $_ -like '*managedDevices*' }).Count | Should -Be 0
        $x.Deleted | Should -BeTrue
        $x.Level | Should -Be 'Hinweis'
        $x.Text | Should -Match 'Intune-Eintrag bleibt \(Recht fehlt\).*Admin im Intune-Portal'
    }
    It 'weitere Intune-Eintraege mit derselben Seriennummer: Ergebnis und Rueckfrage nennen sie' {
        $r = New-Row 'SN100' 'ap1' 'md1' 0 'ms' 3
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $x.Text | Should -Match 'Es gibt weitere Intune-Einträge mit dieser Seriennummer, die bleiben stehen \(Admin\)\.'
        $x.Level | Should -Be 'Hinweis'
        (Get-DeletePlanText @($r) $true (Get-Date)) | Should -Match 'Es gibt weitere Intune-Einträge mit dieser Seriennummer'
    }
    It 'Intune-Eintrag eindeutig abgelehnt (403): Autopilot-Eintrag bleibt unveraendert' {
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/managedDevices/*') { throw 'Response status code does not indicate success: 403 (Forbidden).' }; & $script:FakeOk $m $u }
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        @($script:Calls | Where-Object { $_ -like 'DELETE /windowsAutopilot*' }).Count | Should -Be 0
        $x.Text | Should -Match 'Autopilot-Eintrag bleibt deshalb unverändert'
    }
    It 'unklarer Ausgang beim Intune-DELETE: neu lesen, 404 = geloescht, sonst Stand unklar und Autopilot unveraendert' {
        $script:Gone = $false
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/managedDevices/*') { $script:Gone = $true; throw 'Zeitüberschreitung beim Vorgang' }; if ($m -eq 'GET' -and $u -eq '/managedDevices/md1' -and $script:Gone) { throw 'Response status code does not indicate success: 404 (Not Found).' }; & $script:FakeOk $m $u }
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $x.Deleted | Should -BeTrue
        $x.Text | Should -Match 'Intune-Eintrag gelöscht'
        $script:Calls.Clear()
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/managedDevices/*') { throw 'Response status code does not indicate success: 503 (Service Unavailable).' }; & $script:FakeOk $m $u }
        $x2 = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $x2.Deleted | Should -BeFalse
        $x2.Text | Should -Match 'Intune-Eintrag: Stand unklar.*"Aktualisieren" und prüfen'
        @($script:Calls | Where-Object { $_ -like 'DELETE /windowsAutopilot*' }).Count | Should -Be 0
    }
    It 'unklarer Ausgang beim Autopilot-DELETE: Stand unklar statt "nicht geloescht"; 404 beim DELETE = schon weg' {
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/windowsAutopilot*') { throw 'Response status code does not indicate success: 500 (Internal Server Error).' }; & $script:FakeOk $m $u }
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $x.Deleted | Should -BeFalse
        $x.Text | Should -Match 'TEILWEISE: Intune-Eintrag gelöscht, Autopilot-Eintrag Stand unklar'
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/windowsAutopilot*') { throw 'Response status code does not indicate success: 404 (Not Found).' }; & $script:FakeOk $m $u }
        (Invoke-ApDeleteOne $r 'tok' (Plan $r)).Deleted | Should -BeTrue
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/windowsAutopilot*') { throw 'Response status code does not indicate success: 403 (Forbidden).' }; & $script:FakeOk $m $u }
        (Invoke-ApDeleteOne $r 'tok' (Plan $r)).Text | Should -Match 'TEILWEISE: Intune-Eintrag gelöscht, Autopilot-Eintrag NICHT gelöscht'
    }
    It 'Eintrag aendert sich zwischen den Schritten: Autopilot nicht geloescht, Teilerfolg gemeldet' {
        $script:N = 0
        $script:Fake = { param($m, $u) if ($m -eq 'GET' -and $u -eq '/windowsAutopilotDeviceIdentities/ap1') { $script:N++; if ($script:N -gt 1) { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'NEU' } } }; & $script:FakeOk $m $u }
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        @($script:Calls | Where-Object { $_ -eq 'DELETE /windowsAutopilotDeviceIdentities/ap1' }).Count | Should -Be 0
        $x.Text | Should -Match 'TEILWEISE.*geändert'
    }
    It 'Benutzer-Zuweisung scheitert: kein Abbruch, Hinweis im Ergebnis' {
        $script:Fake = { param($m, $u) if ($m -eq 'POST') { throw 'Response status code does not indicate success: 400 (Bad Request).' }; & $script:FakeOk $m $u }
        $r = New-Row
        $x = Invoke-ApDeleteOne $r 'tok' (Plan $r)
        $x.Deleted | Should -BeTrue
        $x.Level | Should -Be 'Hinweis'
        $x.Text | Should -Match 'Benutzer-Zuweisung NICHT aufgehoben'
    }
    It 'ohne Seriennummer oder Plan: nichts geloescht, kein Aufruf' {
        (Invoke-ApDeleteOne (New-Row '') 'tok' (Plan (New-Row ''))).Deleted | Should -BeFalse
        (Invoke-ApDeleteOne (New-Row) 'tok' $null).Deleted | Should -BeFalse
        $script:Calls.Count | Should -Be 0
    }
    It 'Zusammenfassung: Zahl, je Geraet eine Zeile, 30 Minuten, Hinweis bei Fehlern' {
        $r = @([pscustomobject]@{ Deleted = $true; Text = 'SN1: gelöscht' }, [pscustomobject]@{ Deleted = $false; Text = 'SN2: TEILWEISE' })
        $t = Get-DeleteSummary $r
        $t | Should -Match '^Gelöscht: 1 von 2\.'
        $t | Should -Match 'SN2: TEILWEISE'
        $t | Should -Match 'bis zu 30 Minuten'
        $t | Should -Match 'Nicht alles hat geklappt'
    }
    It 'Verdrahtung: nur per Klick, Busy-Sperre, Laden meldet sich, catch statt trap, Doppelklick gesperrt' {
        $script:SetupText | Should -Match '\$g\.bDelete\.Add_Click\(\{\s+# alles im geschuetzten Bereich[^\r\n]*\r?\n\s+\$mine = \$false; \$btns = @\(\); \$results = @\(\)\r?\n\s+try \{\r?\n\s+if \(\$sst\.Busy\) \{ return \}\r?\n\s+if \(\$sst\.Loading\) \{ Show-Msg ''Die Liste lädt noch, bitte kurz warten\.'''
        $script:SetupText | Should -Match '\$sst\.Busy = \$true; \$sst\.Dialog = \$true; \$tm\.Stop\(\)'
        $script:SetupText | Should -Match '\$btns = @\(\$g\.bDelete, \$g\.bTagSet, \$g\.bSync, \$g\.bReload, \$g\.bDetail, \$g\.bCsv, \$g\.bXlsx, \$g\.bPrint\)'
        $script:SetupText | Should -Match '\$sw\.Add_Closing\(\{ param\(\$s, \$e\) if \(\$sst\.Busy\) \{ \$e\.Cancel = \$true \} \}\)'
        $script:SetupText | Should -Match '\} catch \{\r?\n\s+# nie ins globale trap'
        $script:SetupText | Should -Match '\$detail = \{\r?\n\s+if \(\$sst\.Busy\) \{ return \}'
        $script:SetupText | Should -Match 'Out-Log \$x\.Text \$x\.Level \$x\.Detail'
        $script:SetupText | Should -Match '\$script:DelMax = 5'
        foreach ($m in [regex]::Matches($script:SetupText, '(?s)Add_Tick\(\{.*?\}\)\r?\n')) { $m.Value | Should -Not -Match 'Invoke-ApDeleteOne|bDelete' }
        foreach ($m in [regex]::Matches($script:SetupText, 'BeginInvoke\([^\r\n]*')) { $m.Value | Should -Not -Match 'Invoke-ApDeleteOne|DELETE' }
        @([regex]::Matches($script:SetupText, "Invoke-HuGraph 'DELETE'")).Count | Should -Be 2
    }
    It 'Abfragefenster: Abbrechen ist Standard, Endgueltig loeschen erst nach richtiger Eingabe' {
        $lx = [xml]@($script:XamlBlocks | Where-Object { $_.Name -eq 'lx' })[0].Xaml
        $ns = New-Object System.Xml.XmlNamespaceManager($lx.NameTable); $ns.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'); $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $c = $lx.SelectSingleNode("//w:Button[@x:Name='bCancel']", $ns)
        $c.IsCancel | Should -Be 'True'; $c.IsDefault | Should -Be 'True'
        $d = $lx.SelectSingleNode("//w:Button[@x:Name='bDel']", $ns)
        $d.IsEnabled | Should -Be 'False'; $d.Visibility | Should -Be 'Collapsed'
        $script:SetupText | Should -Match '\$c\.tType\.Add_TextChanged\(\{ \$c\.bDel\.IsEnabled = \(Test-DeleteConfirm \$c\.tType\.Text \$sns\) \}\)'
        $script:SetupText | Should -Match '\$c\.bDel\.Add_Click\(\{ if \(Test-DeleteConfirm \$c\.tType\.Text \$sns\) \{ \$st\.Ok = \$true; \$lw\.Close\(\) \} \}\)'
    }
    It 'Statustext nach Stick fertig machen: Text samt Uhrzeit und Merker passen bei 890 px (STA, beide Themes)' {
        $script:SetupText | Should -Match "Set-ReadyText \('Stick ' \+ \`$dr \+ ' fertig und kontrolliert \(' \+ \(Get-Date -Format 'HH:mm'\) \+ '\)'"
        $res = Invoke-Sta {
            param($xamlText, $theme, $dark, $light, $fnText)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $script:HuThemeXaml = $theme; $script:HuColorsDark = $dark; $script:HuColorsLight = $light; $script:HuWindows = New-Object System.Collections.ArrayList
            . ([scriptblock]::Create($fnText))
            foreach ($th in 'dunkel', 'hell') {
                $script:HuTheme = $th
                $x = [xml]$xamlText; Add-HuTheme $x
                $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
                $w.FindName('cDrive').Items.Add('E: HUPILOT (28,9 GB)') | Out-Null; $w.FindName('cDrive').SelectedIndex = 0
                $w.FindName('tReadyBtn').Text = 'Stick fertig machen  (E:)'
                $tr = $w.FindName('tReady'); $tr.Text = 'Stick E: fertig und kontrolliert (10:40)'
                $bd = New-Object System.Windows.Controls.Border; $bd.Margin = '8,0,0,0'; $bd.Padding = '6,1,6,1'
                $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = 'MAK am Stick'; $tb.FontWeight = 'Bold'; $bd.Child = $tb
                [void]$w.FindName('spFlags').Children.Add($bd)
                # Fensterbreite 890: Inhalt ohne Rahmen und Rand (2 x 14 px Rand, etwa 16 px Rahmen)
                $root = $w.Content; $rs = $w.Resources; $w.Content = $null; $root.Resources = $rs
                $root.Measure((New-Object System.Windows.Size(874, 700))); $root.Arrange((New-Object System.Windows.Rect(0, 0, 874, 700))); $root.UpdateLayout()
                $ft = New-Object System.Windows.Media.FormattedText($tr.Text, [Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, (New-Object System.Windows.Media.Typeface($tr.FontFamily, $tr.FontStyle, $tr.FontWeight, $tr.FontStretch)), $tr.FontSize, [System.Windows.Media.Brushes]::Black, $null, [System.Windows.Media.TextFormattingMode]::Display, 1.0)
                '' + [math]::Ceiling($ft.WidthIncludingTrailingWhitespace) + '|' + [math]::Floor($tr.ActualWidth)
            }
        } @(@($script:XamlBlocks | Where-Object { $_.Name -eq 'xaml' })[0].Xaml, $script:ThemeXaml, $script:DarkXaml, $script:LightXaml, ((@('Add-HuTheme', 'Get-HuColorsXaml') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        $res.Count | Should -Be 2
        foreach ($r in $res) { $v = @($r.Split('|') | ForEach-Object { [int]$_ }); $v[0] | Should -BeLessOrEqual $v[1] -Because ('Text ' + $v[0] + ' px, Platz ' + $v[1] + ' px') }
    }
}

Describe 'v2.7.19 Korrekturrunde 2' {
    BeforeAll {
        . ([scriptblock]::Create((@('Get-DuplicateMarks', 'Get-DeviceStand', 'Get-DeviceTodo', 'Get-SecretBanner', 'Update-SecretBanner', 'Set-SecretMode', 'Set-SecretLoginOk', 'Get-SecretExpiresValue', 'Get-TokenErrorKind', 'Get-DetailCopyText', 'Format-TechDetail', 'Hide-LogSecrets', 'Get-StickMakInfo', 'Get-StickFlags', 'Get-ImportErrorText') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        $cls = [regex]::Match($script:SetupText, '(?m)^\$script:StandClass = (@\{.*\})\r?$').Groups[1].Value
        $til = [regex]::Match($script:SetupText, '(?m)^\$script:StandTile = (@\{.*\})\r?$').Groups[1].Value
        $script:StandClass = Invoke-Expression $cls; $script:StandTile = Invoke-Expression $til
        $script:ui = @{}
        function New-Stick([string]$Name, $Content) {
            $d = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path (Join-Path $d 'HUPilot') -Force | Out-Null
            if ($null -ne $Content) { [System.IO.File]::WriteAllText((Join-Path $d 'HUPilot\config.json'), $Content, (New-Object System.Text.UTF8Encoding($false))) }
            return $d
        }
    }
    It '1: doppelt, ein Eintrag ohne Spur (frisch hochgeladen): fuer alle Alter unklar, nie "aelter: loeschen"' {
        $recs = @(
            [pscustomobject]@{ id = 'alt'; serialNumber = 'SN700'; lastContactedDateTime = '2025-05-01T08:00:00Z' },
            [pscustomobject]@{ id = 'neu'; serialNumber = 'SN700' }
        )
        $m = Get-DuplicateMarks $recs
        $m['alt'].Rank | Should -Be 'unklar'
        $m['neu'].Rank | Should -Be 'unklar'
        # beide mit Spur, klar verschieden: weiter eindeutig
        $recs[1] | Add-Member -NotePropertyName deploymentProfileAssignedDateTime -NotePropertyValue '2026-11-14T08:00:00Z'
        $m2 = Get-DuplicateMarks $recs
        $m2['neu'].Rank | Should -Be 'neuer'; $m2['alt'].Rank | Should -Be 'älter'
    }
    It '2: nach erfolgreicher Anmeldung wird ein Problem-Hinweis zu "gueltig", egal welcher Knopf' {
        $script:Secret = 'Neu~0123456789abcdefghijklmnopqrstuv'
        foreach ($mode in 'net', 'fail', 'expired', 'wrong', 'awaiting') {
            $script:SecMode = $mode; $script:SecretEnd = $null; $script:SecretEndFor = ''; $script:SecretExpLoaded = ''; $script:SecretExpLoadedFor = ''
            Set-SecretLoginOk $script:Secret
            $script:SecMode | Should -Be 'okNoEnd' -Because $mode
        }
        # Ablauf bekannt: gueltig bis
        $script:SecMode = 'net'; $script:SecretEnd = [datetime]::UtcNow.AddDays(10); $script:SecretEndFor = Get-StrHash $script:Secret
        Set-SecretLoginOk $script:Secret
        $script:SecMode | Should -Be 'ok'
        $script:SecEndText | Should -Match '^\d\d\.\d\d\.\d{4} \d\d:\d\d$'
        # kein Hinweis bleibt kein Hinweis, gespeichert bleibt gespeichert (Erinnerung an die Sticks)
        foreach ($mode in '', 'saved', 'ok') { $script:SecMode = $mode; Set-SecretLoginOk $script:Secret; $script:SecMode | Should -Be $mode }
        $script:SetupText | Should -Match '# zentral fuer alle Knoepfe: Anmeldung mit dem eingetragenen Secret klappt, Hinweis zum Secret richtigstellen\r?\n\s+Set-SecretLoginOk \(\[string\]\$c\.ClientSecret\)'
        # danach Ablaufdatum aus der App: aus "gueltig, Ablauf unbekannt" wird "gueltig bis"
        $script:SetupText | Should -Match "elseif \(\`$script:SecMode -in 'ok', 'okNoEnd'\) \{ Set-SecretMode 'ok' \`$minEnd\.ToString\('dd\.MM\.yyyy HH:mm'\) \}"
        # Uebergang zu "gespeichert" kommt dann wie gehabt beim Speichern
        $script:SetupText | Should -Match "if \(\`$script:SecMode -in 'ok', 'okNoEnd'\) \{ Set-SecretMode 'saved'"
    }
    It '3: Hardware: manuell rot vor Fertig, automatisch gelb hinter Fertig, Fehler und Kein Profil' {
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'manualRemediationRequired' | Should -Be 'Hardware geändert'
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'automaticRemediationRequired' | Should -Be 'Fertig'
        Get-DeviceStand 'assignedInSync' 'notContacted' $true 'automaticRemediationRequired' | Should -Be 'Hardware wird abgeglichen'
        Get-DeviceStand 'assignedInSync' 'failed' $true 'automaticRemediationRequired' | Should -Be 'Fehler'
        Get-DeviceStand 'notAssigned' 'notContacted' $false 'automaticRemediationRequired' | Should -Be 'Kein Profil für diesen Tag'
        $script:StandClass['Hardware geändert'] | Should -Be 'err'
        $script:StandClass['Hardware wird abgeglichen'] | Should -Be 'warn'
        $script:StandTile['Hardware wird abgeglichen'] | Should -Be 'hwa'
        Get-DeviceTodo 'Hardware geändert' '' '' | Should -Match '^Mit "Autopilot-Eintrag löschen" entfernen'
        Get-DeviceTodo 'Hardware wird abgeglichen' '' '' | Should -Match '^Microsoft gleicht selbst ab, warten\. Bleibt es: löschen, neu registrieren\.$'
        $script:SetupText | Should -Match "'automaticRemediationRequired' \{ 'geändert, Microsoft versucht die Korrektur selbst' \+ \`$\(if \(\[string\]\`$Row\.Stand -eq 'Fertig'\)"
        $script:SetupText | Should -Match 'ANNAHME \(so nicht auf Learn\): automaticRemediationRequired = Fix pending'
        $sx = @($script:XamlBlocks | Where-Object { $_.Name -eq 'sx' })[0].Xaml
        $sx | Should -Match 'x:Name="kHwa"[^>]*Microsoft versucht die Korrektur selbst'
    }
    It '3: neue Was-tun-Texte passen in die Spalte (STA)' {
        $res = Invoke-Sta {
            param($fnText)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            . ([scriptblock]::Create($fnText))
            $tf = New-Object System.Windows.Media.Typeface((New-Object System.Windows.Media.FontFamily('Segoe UI')), [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
            foreach ($s in @((Get-DeviceTodo 'Hardware geändert' '' ''), (Get-DeviceTodo 'Hardware wird abgeglichen' '' ''))) {
                $ft = New-Object System.Windows.Media.FormattedText($s, [Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $tf, 12.0, [System.Windows.Media.Brushes]::Black)
                '' + [math]::Ceiling($ft.WidthIncludingTrailingWhitespace) + '|' + $s
            }
        } @($script:FnByName['Get-DeviceTodo'])
        @($res).Count | Should -Be 2
        foreach ($r in @($res)) { [int]($r.Split('|')[0]) | Should -BeLessThan 390 -Because $r }
    }
    It '4: Pruefung nach dem Einfuegen mit kurzen Zeitlimits, Zustand vorher gezeichnet' {
        $script:SetupText | Should -Match '\$script:TokenTimeoutSec = 10\r?\n\s+try \{ \$tok = Get-ApiToken \} finally \{ \$script:TokenTimeoutSec = 0 \}'
        $script:SetupText | Should -Match 'Show-SecretExpiry -Token \$tok -TimeoutSec 10'
        $script:SetupText | Should -Match "Set-SecretMode 'checking'; Set-Step 'Test' 'run'; try \{ \`$win\.UpdateLayout\(\) \} catch \{ \}; Step-Ui"
        $script:FnByName['Get-ApiToken'] | Should -Match '-TimeoutSec \$\(if \(\$script:TokenTimeoutSec -gt 0\) \{ \$script:TokenTimeoutSec \} else \{ 30 \}\)'
        $script:FnByName['Show-SecretExpiry'] | Should -Match '-TimeoutSec \$TimeoutSec'
    }
    It '5: automatisch nur nach Einfuegen, Ziehen oder Fokusverlust, nie nach Tipp-Pausen' {
        $script:SetupText | Should -Not -Match 'Add_PasswordChanged\(\$reqSecCheck\)'
        $script:SetupText | Should -Not -Match 'Add_TextChanged\(\$reqSecCheck\)'
        $script:SetupText | Should -Match '\$sf\.Add_PreviewDrop\(\$reqSecCheck\)'
        $script:SetupText | Should -Match '\$sf\.Add_LostKeyboardFocus\(\$reqSecCheck\)'
        # jede Anmeldung (auch fehlgeschlagen) gilt als Pruefung dieses Werts, kein zweiter Versuch beim Fokusverlust
        $script:FnByName['Get-ApiToken'] | Should -Match 'SecCheckedFor = Get-StrHash \(\[string\]\$c\.ClientSecret\)'
    }
    It '6: Antwort ohne AADSTS-Code ist ein Netzfall, nie "Microsoft lehnt ab"' {
        Get-TokenErrorKind '<html><body>Bitte im Gastnetz anmelden</body></html>' $true | Should -Be 'proxy'
        Get-TokenErrorKind 'AADSTS90002: Tenant not found' $true | Should -Be 'config'
        $script:FnByName['Get-ApiToken'] | Should -Match "\`$script:TokenErr = \`$\(if \(\`$kind -eq 'proxy'\) \{ 'net' \} else \{ \`$kind \}\)"
        $script:FnByName['Get-ApiToken'] | Should -Match "'Die Antwort kam nicht von Microsoft \(Gastnetz oder Proxy\?\)\. Internet prüfen\. Das Secret wurde nicht geprüft\.'"
    }
    It '7: nach dem Gliedern nochmal ausgeblendet (Geheimnis erst nach dem Aufloesen der Escapes sichtbar)' {
        $det = '{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided: Geheim\u007e0123456789abc"}'
        $t = Get-DetailCopyText 'Zeile' $det @('Geheim~0123456789abc')
        $t | Should -Not -Match 'Geheim~'
        $t | Should -Match 'provided: \*\*\*'
        $script:SetupText | Should -Match '\$fmt = Hide-LogSecrets \(Format-TechDetail \$Detail\) \(Get-LogSecretValues\)'
    }
    It '8: Zeiten fuer die Filter je Kennung' {
        $script:SetupText | Should -Match 'if \(\$id\) \{ \$script:StatusTimes\[\$id\] = @\{ Reg = \$tReg; Imp = \$tImp \} \}'
        $script:SetupText | Should -Not -Match 'StatusTimes\[\[string\]\$_\.Seriennr\]'
        @([regex]::Matches($script:SetupText, 'StatusTimes\[\[string\]\$_\.Id\]')).Count | Should -Be 2
    }
    It '9: config.json nicht lesbar: gelber Merker "Stick prüfen" statt keinem Merker' {
        foreach ($c in @(@('kaputt2', '{ "EditionKey": "ABC'), @('liste2', '[1,2]'))) {
            $i = Get-StickMakInfo (New-Stick $c[0] $c[1])
            $i.Unreadable | Should -BeTrue -Because $c[0]
            $f = @(Get-StickFlags $i)
            $f.Count | Should -Be 1
            $f[0].Text | Should -Be 'Stick prüfen'
            $f[0].Color | Should -Be 'HuStandWarnBg'
            $f[0].Tip | Should -Be 'Die Einstellungen am Stick sind nicht lesbar. Stick fertig machen wiederholen.'
        }
        $big = New-Stick 'gross' ''; [System.IO.File]::WriteAllBytes((Join-Path $big 'HUPilot\config.json'), (New-Object byte[] (1MB + 10)))
        (Get-StickMakInfo $big).Unreadable | Should -BeTrue
        # Datei fehlt (z. B. leerer Stick): kein Merker
        @(Get-StickFlags (Get-StickMakInfo (New-Stick 'ohneDatei' $null))).Count | Should -Be 0
        (Get-StickMakInfo (New-Stick 'ok2' '{"EditionKey":""}')).Unreadable | Should -BeFalse
    }
    It '10: "Details kopieren" heisst beim naechsten Oeffnen wieder so' {
        $script:SetupText | Should -Match "\`$cm\.Add_Opened\(\{ foreach \(\`$x in @\(\`$this\.Items\)\) \{ try \{ \`$x\.Header = 'Details kopieren' \} catch \{ \} \} \}\)"
    }
    It '11: Hinweis nach dem Klick ohne feste Ablaufwerte, Portal-Begriffe in Anfuehrung' {
        $b = (Get-SecretBanner 'awaiting').Text
        $b | Should -Not -Match '14 Tage'
        $b | Should -Match 'Ablauf wählen \(möglichst kurz, über "Benutzerdefiniert"\)'
        $b | Should -Match '"Geheimnis-ID"'
        (Get-SecretBanner 'wrong').Text | Should -Not -MatchExactly 'WERT'
        $script:SetupText | Should -Not -Match 'neues Geheimnis anlegen'
    }
    It '12: Altbestand: "Secret (Wert)" und Verweis auf "Neues Secret anlegen"' {
        $script:SetupText | Should -Match "'Besser: oben auf ""Neues Secret anlegen"" klicken, den neuen Wert bei ""Secret \(Wert\)"" einfügen und speichern\.'"
        $script:FnByName['Get-ApiToken'] | Should -Match "'Das Secret ist abgelaufen\. Oben auf ""Neues Secret anlegen"" klicken und den neuen Wert bei ""Secret \(Wert\)"" einfügen\.'"
        $script:FnByName['Confirm-CopyPrereqs'] | Should -Match "if \(\`$script:SecMode -ne 'expired'\) \{ Set-SecretMode 'expired'"
        $script:SetupText | Should -Not -Match 'bei "Secret" eintragen'
    }
    It '13: 806/808 wie in go: Name vor Code, warten bis zu 30 Minuten' {
        $e = Get-ImportErrorText '806' 'ZtdDeviceAlreadyAssigned'
        $e.Was | Should -Match '\(Fehler ZtdDeviceAlreadyAssigned 806\)'
        $e.Tun | Should -Match 'warten, bis der Eintrag aus der Liste verschwunden ist \(bis zu 30 Minuten\)'
        $e.Tun | Should -Not -Match 'einige Minuten'
        $e8 = Get-ImportErrorText '808' 'ZtdDeviceAssignedToOtherTenant'
        $e8.Was | Should -Match '\(Fehler ZtdDeviceAssignedToOtherTenant 808\)'
        $e8.Tun | Should -Match 'bis zu 30 Minuten'
    }
    It '15: Merker am Tooltip-Stil zu Objekten statt Text' {
        $script:SetupText | Should -Match 'Merken: Ein Tooltip mit einem Objekt \(kein Text, kein Steuerelement\) zeigt hier nur dessen Typnamen'
    }
}

Describe 'v2.7.19 Korrekturrunde 3' {
    BeforeAll {
        . ([scriptblock]::Create((@('Get-SecretBanner', 'Update-SecretBanner', 'Set-SecretMode', 'Set-SecretLoginFail', 'Test-SerialPlaceholder', 'Resolve-IntuneLink', 'Get-IntunePlan', 'Get-DeletePlanText', 'Get-DeleteWarnings') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        . ([scriptblock]::Create([regex]::Match($script:SetupText, '(?m)^\$script:SerialPlaceholders = @\(.*\)\r?$').Value))
        $til = [regex]::Match($script:SetupText, '(?m)^\$script:StandTile = (@\{.*\})\r?$').Groups[1].Value
        $script:StandTile = Invoke-Expression $til
        $script:ui = @{}
    }
    It '1: fehlgeschlagene Anmeldung stellt einen sichtbaren Hinweis um, nie bleibt "gueltig" stehen' {
        foreach ($c in @(@('ok', 'wrong', 'wrong'), @('okNoEnd', 'config', 'fail'), @('saved', 'net', 'net'), @('ok', 'proxy', 'net'), @('ok', 'other', 'fail'))) {
            $script:SecMode = $c[0]
            Set-SecretLoginFail $c[1]
            $script:SecMode | Should -Be $c[2] -Because ($c[0] + ' + ' + $c[1])
        }
        # ohne Hinweis bleibt es ohne Hinweis; abgelaufen und fehlende Felder stellt diese Stelle nicht um
        $script:SecMode = ''; Set-SecretLoginFail 'wrong'; $script:SecMode | Should -Be ''
        $script:SecMode = 'ok'; Set-SecretLoginFail 'fields'; $script:SecMode | Should -Be 'ok'
        $script:FnByName['Get-ApiToken'] | Should -Match "if \(\`$kind -eq 'expired'\) \{ Set-SecretMode 'expired' \}\r?\n(\s+#[^\r\n]*\r?\n)?\s+Set-SecretLoginFail \`$kind"
    }
    It '2: Intune-Liste unvollstaendig: kein Rueckfall ueber die Seriennummer, Verknuepfung bleibt nutzbar, Hinweis im Fenster' {
        $md = @{ 'SN:SN100' = [pscustomobject]@{ id = 'm1' } }; $cnt = @{ 'SN:SN100' = 1 }
        $a = Resolve-IntuneLink '' 'SN100' $md $cnt $false $true
        $a.Id | Should -Be ''; $a.Ambig | Should -BeTrue
        (Get-IntunePlan ([pscustomobject]@{ IntuneId = $a.Id; IntuneLink = $a.Link; IntuneAmbig = $a.Ambig; IntuneSnCount = $a.SnCount }) $true).Kind | Should -Be 'ambig'
        $b = Resolve-IntuneLink 'mX' 'SN100' $md $cnt $false $true
        $b.Link | Should -Be 'ms'; $b.Id | Should -Be 'mX'
        # ganz geladen: wie bisher eindeutig
        (Resolve-IntuneLink '' 'SN100' $md $cnt $false $false).Link | Should -Be 'sn'
        $script:SetupText | Should -Match 'if \(\$md\.Count\) \{ \$mdPartial = \$true; Out-Log ''Intune-Angaben unvollständig'
        $script:SetupText | Should -Match '\$md \$mdCnt \(\[bool\]\(\$dm\)\) \$mdPartial'
        $script:SetupText | Should -Match 'IntunePartial = \$mdPartial'
        $script:SetupText | Should -Match '\$g\.tLoad\.Text = \$\(if \(\$d\.IntunePartial\) \{ ''Intune-Angaben unvollständig'
    }
    It '3: Plan nur einmal berechnet und an die Rueckfrage uebergeben' {
        $script:SetupText | Should -Match 'Show-DeleteConfirm \$sel \$canI \$sw \$plans'
        $script:SetupText | Should -Match '\$c\.tPlan\.Text = Get-DeletePlanText \$Rows \$CanIntune \(Get-Date\) \$Plans'
        # uebergebener Plan wird benutzt, nicht neu berechnet
        $r = [pscustomobject]@{ Seriennr = 'SN100'; Id = 'ap1'; IntuneId = 'md1'; IntuneLink = 'ms'; IntuneAmbig = $false; IntuneSnCount = 1; DupCount = 0; Stand = 'Fertig'; Name = ''; Tag = ''; Benutzer = ''; EnrollState = ''; SyncSort = ''; LetzterKontakt = '' }
        $fake = [pscustomobject]@{ Kind = 'right'; Id = 'md1'; Link = 'ms'; More = $false; Text = 'Eintrag bleibt stehen (Recht fehlt)' }
        (Get-DeletePlanText @($r) $true (Get-Date) @($fake)) | Should -Match 'Intune:       Eintrag bleibt stehen \(Recht fehlt\)'
    }
    It '4: verknuepfter Eintrag anders als der einzige Treffer ueber die Seriennummer: weitere Eintraege genannt' {
        $md = @{ 'SN:SN100' = [pscustomobject]@{ id = 'mAnders' } }; $cnt = @{ 'SN:SN100' = 1 }
        $a = Resolve-IntuneLink 'mVerkn' 'SN100' $md $cnt
        $a.SnCount | Should -Be 2
        (Get-IntunePlan ([pscustomobject]@{ IntuneId = $a.Id; IntuneLink = $a.Link; IntuneAmbig = $false; IntuneSnCount = $a.SnCount }) $true).More | Should -BeTrue
        (Resolve-IntuneLink 'mAnders' 'SN100' $md $cnt).SnCount | Should -Be 1
    }
    It '5: Kachel "Hardware geändert" zaehlt nur rot, eigene gelbe Kachel, Druck und Filter mitgezogen' {
        $script:StandTile['Hardware geändert'] | Should -Be 'hw'
        $script:StandTile['Hardware wird abgeglichen'] | Should -Be 'hwa'
        $sx = @($script:XamlBlocks | Where-Object { $_.Name -eq 'sx' })[0].Xaml
        $sx | Should -Match '<Button x:Name="kHwa" Style="\{StaticResource HuTile\}" Tag="hwa" Visibility="Collapsed"'
        $sx | Should -Match 'x:Name="nHwa"[^>]*Foreground="\{DynamicResource HuWarn\}"'
        $sx | Should -Not -Match 'x:Name="kHw" [^>]*\(gelb\)'
        $script:SetupText | Should -Match "foreach \(\`$k in 'hw', 'hwa', 'dup', 'del'\)"
        $script:SetupText | Should -Match "hwa = 'Hardware wird abgeglichen'"
        $script:SetupText | Should -Match "@\(\`$g\.nHwa, 'Hardware wird abgeglichen'\)"
    }
    It '6 und 7: Kommentar stimmt, Klick-Handler raeumt nur auf, was er gesetzt hat' {
        $script:SetupText | Should -Not -Match '1,5 s nach dem letzten Tastendruck'
        $script:SetupText | Should -Match 'if \(\$mine\) \{ \$sst\.Busy = \$false; \$sst\.Dialog = \$false;'
        $script:SetupText | Should -Match "try \{ Out-Log 'Autopilot-Eintrag löschen unerwartet abgebrochen\."
        $script:SetupText | Should -Match '\$mine = \$true; \$sst\.Busy = \$true; \$sst\.Dialog = \$true; \$tm\.Stop\(\)'
    }
}