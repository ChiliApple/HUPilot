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
        $script:SetupText | Should -Match '\$fmt = Format-TechDetail \$Detail'
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
