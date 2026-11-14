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
        $e.Was | Should -Match 'schon in Autopilot, unter einem alten Eintrag \(Fehler 806 ZtdDeviceAlreadyAssigned\)'
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
        foreach ($c in '806', '808') { $e = Get-ImportErrorText $c ''; ($e.Was + $e.Tun) | Should -Not -Match '[–—→„“…]' }
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
        function Show-SecretExpiry([string]$Token) { $script:SecretEnd = [datetime]::UtcNow.AddDays(14); $script:SecretEndFor = Get-StrHash $script:Secret }
        Invoke-SecretAutoCheck
        $script:SecMode | Should -Be 'ok'
        $script:SecEndText | Should -Match '^\d\d\.\d\d\.\d{4} \d\d:\d\d$'
        ($script:Logs -join "`n") | Should -Match 'Secret gültig bis .*neu bespielen'
        # gleicher Wert: keine zweite Pruefung
        $script:Logs.Clear(); Invoke-SecretAutoCheck; $script:Logs.Count | Should -Be 0
        $script:Secret = 'Neu2~0123456789abcdefghijklmnopqrstu'
        function Show-SecretExpiry([string]$Token) { }
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
        $script:SetupText | Should -Match '\$ui\.pSecret\.Add_PasswordChanged\(\$reqSecCheck\)'
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
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'automaticRemediationRequired' | Should -Be 'Hardware geändert'
        Get-DeviceStand 'assignedInSync' 'notContacted' $true 'manualRemediationRequired' | Should -Be 'Hardware geändert'
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'noRemediationRequired' | Should -Be 'Fertig'
        Get-DeviceStand 'assignedInSync' 'enrolled' $true 'unknown' | Should -Be 'Fertig'
        Get-DeviceStand 'assignedInSync' 'enrolled' $true | Should -Be 'Fertig'
    }
    It 'Was tun bei Hardware geaendert: ein Satz, bereinigen und neu registrieren' {
        $t = Get-DeviceTodo 'Hardware geändert' '' ''
        $t | Should -Match 'bereinigen'
        $t | Should -Match 'mit dem Stick neu registrieren\.$'
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
        Get-DuplicateTodo 2 'älter' | Should -Match '^Älterer von 2 Einträgen .*diesen löschen'
        Get-DuplicateTodo 2 'neuer' | Should -Match 'diesen behalten, den älteren löschen'
        Get-DuplicateTodo 3 'unklar' | Should -Match '^3 Einträge .*nicht sicher.*Details vergleichen'
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
        $script:SetupText | Should -Match "hw = 'Hardware geändert'; dup = 'Doppelt'; del = 'Wird gelöscht'"
        $script:SetupText | Should -Match "\('Hardware:          ' \+"
        $script:SetupText | Should -Match "\('Doppelt:           ' \+"
        $script:SetupText | Should -Match '\$id = \$\(if \(\$r\.Id\) \{ \[string\]\$r\.Id \} else \{ \$script:ApIds\[\[string\]\$r\.Seriennr\] \}\)'
        $script:SetupText | Should -Match '\$id = \$\(if \(\$Row\.Id\) \{ \[string\]\$Row\.Id \} else \{ \$script:ApIds\[\[string\]\$Row\.Seriennr\] \}\)'
    }
}

Describe 'v2.7.19 Paket 5: Autopilot-Eintrag loeschen mit doppelter Abfrage' {
    BeforeAll {
        . ([scriptblock]::Create((@('Get-ErrCode', 'Get-ErrText', 'Get-TokenRoles', 'Test-DeleteSelection', 'Test-DeleteConfirm', 'Get-DeleteWarnings', 'Get-DeletePlanText', 'Invoke-ApDeleteOne', 'Get-DeleteSummary') | ForEach-Object { $script:FnByName[$_] }) -join "`n"))
        $script:DelMax = 5
        $script:DelGB = 'https://graph.microsoft.com/beta/deviceManagement'
        # Graph ersetzt: jeder Aufruf wird mitgeschrieben, die Antwort kommt aus $script:Fake (nie ein echter Aufruf)
        $script:Calls = New-Object System.Collections.Generic.List[string]
        function Invoke-HuGraph([string]$Method, [string]$Uri, [string]$Token) {
            $script:Calls.Add($Method + ' ' + $Uri.Replace($script:DelGB, ''))
            return (& $script:Fake $Method $Uri.Replace($script:DelGB, ''))
        }
        function New-Row([string]$Sn = 'SN100', [string]$Id = 'ap1', [string]$IntuneId = 'md1', [int]$Dup = 0) {
            [pscustomobject]@{ Seriennr = $Sn; Id = $Id; IntuneId = $IntuneId; DupCount = $Dup; Stand = 'Hardware geändert'; Name = 'PC-01'; Tag = 'SN-2026'; Benutzer = ''; EnrollState = 'notContacted'; SyncSort = '' }
        }
        # Standard: alles passt (Seriennummer SN100, verknuepfter Intune-Eintrag md1, Benutzer zugewiesen)
        $script:FakeOk = {
            param($m, $u)
            if ($m -eq 'GET' -and $u -eq '/windowsAutopilotDeviceIdentities/ap1') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'SN100'; managedDeviceId = 'md1'; userPrincipalName = 'schueler1@example.org' } }
            if ($m -eq 'GET' -and $u -like '/managedDevices/md1*') { return [pscustomobject]@{ id = 'md1'; serialNumber = 'SN100'; deviceName = 'PC-01' } }
            return $null
        }
    }
    BeforeEach { $script:Calls.Clear(); $script:Fake = $script:FakeOk }
    It 'Auswahl: nichts markiert, mehr als 5, Zeile wird schon geloescht, ohne Kennung = nichts tun, mit Klartext' {
        (Test-DeleteSelection @()).Ok | Should -BeFalse
        (Test-DeleteSelection @()).Msg | Should -Match 'markieren'
        $six = @(1..6 | ForEach-Object { New-Row ('SN' + $_) ('ap' + $_) })
        $r6 = Test-DeleteSelection $six
        $r6.Ok | Should -BeFalse
        $r6.Msg | Should -Match 'Höchstens 5 Geräte auf einmal\. Markiert sind 6\..*nichts gelöscht'
        (Test-DeleteSelection @($six[0..4])).Ok | Should -BeTrue
        $p = New-Row; $p.Stand = 'Wird gelöscht'
        (Test-DeleteSelection @($p)).Msg | Should -Match 'wird schon gelöscht'
        (Test-DeleteSelection @((New-Row 'SN9' ''))).Msg | Should -Match 'Kennung fehlt'
    }
    It 'zweite Abfrage streng: ein Geraet Seriennummer genau, mehrere das Wort LÖSCHEN' {
        Test-DeleteConfirm 'SN100' @('SN100') | Should -BeTrue
        Test-DeleteConfirm 'sn100' @('SN100') | Should -BeFalse
        Test-DeleteConfirm 'SN100 ' @('SN100') | Should -BeFalse
        Test-DeleteConfirm 'LÖSCHEN' @('SN100') | Should -BeFalse
        Test-DeleteConfirm '' @('SN100') | Should -BeFalse
        Test-DeleteConfirm 'LÖSCHEN' @('SN1', 'SN2') | Should -BeTrue
        Test-DeleteConfirm 'löschen' @('SN1', 'SN2') | Should -BeFalse
        Test-DeleteConfirm 'LOESCHEN' @('SN1', 'SN2') | Should -BeFalse
        Test-DeleteConfirm 'SN1' @('SN1', 'SN2') | Should -BeFalse
    }
    It 'Rechte aus dem Token, unlesbar = leer' {
        $pl = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"roles":["DeviceManagementServiceConfig.ReadWrite.All","DeviceManagementManagedDevices.ReadWrite.All"]}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $r = Get-TokenRoles ('eyJ0eXAiOiJKV1QifQ.' + $pl + '.sig')
        $r | Should -Contain 'DeviceManagementManagedDevices.ReadWrite.All'
        @(Get-TokenRoles 'kaputt').Count | Should -Be 0
        @(Get-TokenRoles '').Count | Should -Be 0
    }
    It 'erste Rueckfrage nennt je Geraet Seriennummer, Name, Tag, Benutzer und was verloren geht, warnt bei Fertig und in Benutzung' {
        $a = New-Row; $b = New-Row 'SN200' 'ap2' ''; $b.Stand = 'Fertig'; $b.EnrollState = 'enrolled'; $b.Benutzer = 'lehrer1@example.org'; $b.SyncSort = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd HH:mm')
        $t = Get-DeletePlanText @($a, $b) $true (Get-Date)
        $t | Should -Match 'Seriennummer: SN100'
        $t | Should -Match 'Gerätename:   PC-01'
        $t | Should -Match 'Tag:          SN-2026'
        $t | Should -Match 'Benutzer:     lehrer1@example\.org'
        $t | Should -Match 'Was verloren geht:'
        $t | Should -Match 'Rückgängig machen geht nicht'
        $t | Should -Match 'bis zu 30 Minuten'
        $t | Should -Match 'ACHTUNG: Das Gerät ist fertig eingerichtet'
        $t | Should -Match 'ACHTUNG: Das Gerät ist in Benutzung'
        $t | Should -Match 'Der Intune-Eintrag \(bei 1 Gerät\)'
        $t2 = Get-DeletePlanText @($a) $false (Get-Date)
        $t2 | Should -Match 'Nicht gelöscht wird der Intune-Eintrag.*DeviceManagementManagedDevices\.ReadWrite\.All'
        $t2 | Should -Match 'Eintrag bleibt stehen \(Recht fehlt\)'
        $t2 | Should -Not -Match '[–—→„“…]'
    }
    It 'Reihenfolge wie in go.ps1: Intune, Benutzer-Zuweisung, Autopilot, vor jedem Loeschen neu gelesen' {
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
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
    It 'Seriennummer passt beim Neulesen nicht: uebersprungen, nichts geloescht' {
        $script:Fake = { param($m, $u) if ($m -eq 'GET' -and $u -like '/windowsAutopilotDeviceIdentities/*') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'ANDERE'; managedDeviceId = 'md1' } } }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        @($script:Calls | Where-Object { $_ -like 'DELETE*' -or $_ -like 'POST*' }).Count | Should -Be 0
        $x.Deleted | Should -BeFalse
        $x.Text | Should -Match 'Übersprungen, nichts gelöscht'
    }
    It 'Eintrag schon weg (404) oder nicht lesbar: nichts geloescht' {
        $script:Fake = { param($m, $u) throw 'Response status code does not indicate success: 404 (Not Found).' }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        $x.Level | Should -Be 'Hinweis'; $x.Deleted | Should -BeFalse
        $script:Fake = { param($m, $u) throw 'Zeitüberschreitung' }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        $x.Level | Should -Be 'Fehler'; $x.Deleted | Should -BeFalse
        @($script:Calls | Where-Object { $_ -like 'DELETE*' }).Count | Should -Be 0
    }
    It 'verknuepfter Intune-Eintrag gehoert zu anderer Seriennummer: uebersprungen, nichts geloescht' {
        $script:Fake = { param($m, $u) if ($u -like '/managedDevices/*') { return [pscustomobject]@{ id = 'md1'; serialNumber = 'FREMD' } }; & $script:FakeOk $m $u }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        @($script:Calls | Where-Object { $_ -like 'DELETE*' -or $_ -like 'POST*' }).Count | Should -Be 0
        $x.Text | Should -Match 'anderen Seriennummer'
    }
    It 'Intune-Eintrag nicht loeschbar: Autopilot-Eintrag bleibt unveraendert' {
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/managedDevices/*') { throw 'Response status code does not indicate success: 403 (Forbidden).' }; & $script:FakeOk $m $u }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        @($script:Calls | Where-Object { $_ -like 'DELETE /windowsAutopilot*' }).Count | Should -Be 0
        $x.Deleted | Should -BeFalse
        $x.Text | Should -Match 'Autopilot-Eintrag bleibt deshalb unverändert'
        $x.Detail | Should -Match '403'
    }
    It 'Teilerfolg wird ausdruecklich gemeldet: Intune weg, Autopilot nicht' {
        $script:Fake = { param($m, $u) if ($m -eq 'DELETE' -and $u -like '/windowsAutopilot*') { throw 'Response status code does not indicate success: 500 (Internal Server Error).' }; & $script:FakeOk $m $u }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        $x.Deleted | Should -BeFalse
        $x.Level | Should -Be 'Fehler'
        $x.Text | Should -Match 'TEILWEISE: Intune-Eintrag gelöscht, Autopilot-Eintrag NICHT gelöscht'
    }
    It 'Eintrag aendert sich zwischen den Schritten: Autopilot nicht geloescht, Teilerfolg gemeldet' {
        $script:N = 0
        $script:Fake = { param($m, $u) if ($m -eq 'GET' -and $u -eq '/windowsAutopilotDeviceIdentities/ap1') { $script:N++; if ($script:N -gt 1) { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'NEU' } } }; & $script:FakeOk $m $u }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        @($script:Calls | Where-Object { $_ -eq 'DELETE /windowsAutopilotDeviceIdentities/ap1' }).Count | Should -Be 0
        $x.Text | Should -Match 'TEILWEISE.*geändert'
    }
    It 'ohne Schreibrecht fuer Intune: nur der Autopilot-Eintrag, Intune bleibt, Hinweis an den Admin' {
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $false
        @($script:Calls | Where-Object { $_ -like '*managedDevices*' }).Count | Should -Be 0
        $x.Deleted | Should -BeTrue
        $x.Level | Should -Be 'Hinweis'
        $x.Text | Should -Match 'Intune-Eintrag bleibt \(Recht fehlt\).*Admin im Intune-Portal'
    }
    It 'doppelte Seriennummer ohne Verknuepfung: der Intune-Eintrag des anderen Eintrags bleibt unberuehrt' {
        $script:Fake = { param($m, $u) if ($m -eq 'GET' -and $u -like '/windowsAutopilot*') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'SN100'; managedDeviceId = '00000000-0000-0000-0000-000000000000' } } }
        $x = Invoke-ApDeleteOne (New-Row 'SN100' 'ap1' 'mdAnders' 2) 'tok' $true
        @($script:Calls | Where-Object { $_ -like '*managedDevices*' }).Count | Should -Be 0
        $x.Deleted | Should -BeTrue
        # ohne Doppel: Intune-Eintrag aus der Liste (gleiche Seriennummer) wird verwendet
        $script:Calls.Clear()
        $script:Fake = { param($m, $u) if ($m -eq 'GET' -and $u -like '/windowsAutopilot*') { return [pscustomobject]@{ id = 'ap1'; serialNumber = 'SN100'; managedDeviceId = '' } }; if ($u -like '/managedDevices/*') { return [pscustomobject]@{ id = 'mdListe'; serialNumber = 'SN100' } } }
        $x = Invoke-ApDeleteOne (New-Row 'SN100' 'ap1' 'mdListe' 0) 'tok' $true
        $script:Calls | Should -Contain 'DELETE /managedDevices/mdListe'
    }
    It 'Benutzer-Zuweisung scheitert: kein Abbruch, Hinweis im Ergebnis' {
        $script:Fake = { param($m, $u) if ($m -eq 'POST') { throw 'Response status code does not indicate success: 400 (Bad Request).' }; & $script:FakeOk $m $u }
        $x = Invoke-ApDeleteOne (New-Row) 'tok' $true
        $x.Deleted | Should -BeTrue
        $x.Level | Should -Be 'Hinweis'
        $x.Text | Should -Match 'Benutzer-Zuweisung NICHT aufgehoben'
    }
    It 'Zusammenfassung: Zahl, je Geraet eine Zeile, 30 Minuten, Hinweis bei Fehlern' {
        $r = @([pscustomobject]@{ Deleted = $true; Text = 'SN1: gelöscht' }, [pscustomobject]@{ Deleted = $false; Text = 'SN2: TEILWEISE' })
        $t = Get-DeleteSummary $r
        $t | Should -Match '^Gelöscht: 1 von 2\.'
        $t | Should -Match 'SN2: TEILWEISE'
        $t | Should -Match 'bis zu 30 Minuten'
        $t | Should -Match 'Nicht alles hat geklappt'
    }
    It 'Verdrahtung: nur per Klick, Busy-Sperre, Timer pausiert, Fenster schliesst nicht waehrend des Loeschens' {
        $script:SetupText | Should -Match '\$g\.bDelete\.Add_Click\(\{\s+if \(\$sst\.Busy -or \$sst\.Loading\) \{ return \}'
        $script:SetupText | Should -Match '\$sst\.Busy = \$true; \$sst\.Dialog = \$true; \$tm\.Stop\(\)'
        $script:SetupText | Should -Match '\$sw\.Add_Closing\(\{ param\(\$s, \$e\) if \(\$sst\.Busy\) \{ \$e\.Cancel = \$true \} \}\)'
        $script:SetupText | Should -Match 'if \(-not \(Show-DeleteConfirm \$sel \$canI \$sw\)\)'
        $script:SetupText | Should -Match 'Out-Log \$x\.Text \$x\.Level \$x\.Detail'
        $script:SetupText | Should -Match '\$script:DelMax = 5'
        # kein Loeschen aus Timer oder verzoegerter Aktion
        foreach ($m in [regex]::Matches($script:SetupText, '(?s)Add_Tick\(\{.*?\}\)\r?\n')) { $m.Value | Should -Not -Match 'Invoke-ApDeleteOne|bDelete' }
        foreach ($m in [regex]::Matches($script:SetupText, 'BeginInvoke\([^\r\n]*')) { $m.Value | Should -Not -Match 'Invoke-ApDeleteOne|DELETE' }
        # nur hier wird geloescht (Graph DELETE auf Autopilot und Intune nur ueber Invoke-ApDeleteOne)
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
}
