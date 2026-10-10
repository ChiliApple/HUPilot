#Requires -Version 5.1
<#
.SYNOPSIS
    Automatische Pruefungen fuer HUPilot (GitHub Actions, Windows PowerShell 5.1) - blockierend.
.DESCRIPTION
    1. Syntax aller PowerShell-Dateien (Parser), UTF-8-BOM
    2. XAML-Hauptfenster aus HUPilot-Setup.ps1 laden; alle im Code verwendeten Steuerelemente vorhanden
    3. Konfigurationsdateien (JSON) lesbar
    4. Version (Stick\HUPilot\Config\version.json) und CHANGELOG-Abschnitt
    5. Update-Bibliothek in Pull.ps1 und Core-Update.ps1 identisch
    6. PSScriptAnalyzer: keine Fehler (Schweregrad Error)
    7. Pester-Tests (.github\tests\*.Tests.ps1)
.NOTES
    Aufruf (auch lokal): powershell -NoProfile -ExecutionPolicy Bypass -File .github\tests\Invoke-CITests.ps1
    Zielmaschine: Windows-PC / GitHub-Runner mit Internet (PSScriptAnalyzer, Pester werden bei Bedarf installiert).
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fail = New-Object System.Collections.Generic.List[string]
function Step([string]$Name, [scriptblock]$Do) {
    Write-Host "== $Name" -ForegroundColor Cyan
    try { $r = & $Do; if ($r) { Write-Host "   $r" -ForegroundColor Green } else { Write-Host '   OK' -ForegroundColor Green } }
    catch { $fail.Add("$Name : $($_.Exception.Message)"); Write-Host "   FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host "HUPilot CI - PowerShell $($PSVersionTable.PSVersion) - $([Environment]::OSVersion.VersionString)"

# 1. Syntax + BOM
Step 'Syntax und UTF-8-BOM aller .ps1' {
    $bad = @()
    $files = @(Get-ChildItem -Path $root -Recurse -File -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\\.git\\' })
    foreach ($f in $files) {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        if ($e.Count) { $bad += "$($f.Name): " + (($e | Select-Object -First 2 | ForEach-Object { "Zeile $($_.Extent.StartLineNumber) $($_.Message)" }) -join ' | ') }
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $bad += "$($f.Name): kein UTF-8-BOM" }
    }
    if ($bad.Count) { throw ($bad -join '; ') }
    "$($files.Count) Dateien"
}

# 2. XAML + Steuerelemente
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$setupPs = Join-Path $root 'Stick\HUPilot\Setup\HUPilot-Setup.ps1'
$pullPs  = Join-Path $root 'Stick\HUPilot\Setup\Pull.ps1'
$libPs   = Join-Path $root 'Stick\HUPilot\Setup\Core-Update.ps1'
$verJson = Join-Path $root 'Stick\HUPilot\Config\version.json'
Step 'XAML Hauptfenster + alle Steuerelemente aus HUPilot-Setup.ps1' {
    $txt = Get-Content -LiteralPath $setupPs -Raw -Encoding UTF8
    $m = [regex]::Match($txt, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw 'XAML-Block nicht gefunden' }
    $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$m.Groups[1].Value)))
    $l = [regex]::Match($txt, "foreach \(\`$n in ('[^)]+?')\) \{ \`$ui\[\`$n\] = \`$win\.FindName\(\`$n\) \}")
    if (-not $l.Success) { throw 'Liste der Steuerelemente nicht gefunden' }
    $names = @([regex]::Matches($l.Groups[1].Value, "'([A-Za-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value })
    $miss = @($names | Where-Object { -not $w.FindName($_) })
    if ($miss.Count) { throw "fehlt im XAML: $($miss -join ', ')" }
    "$($names.Count) Steuerelemente"
}

# 3. JSON
Step 'Konfigurationsdateien (JSON)' {
    $n = 0
    foreach ($f in @((Get-Item $verJson), (Get-Item (Join-Path $root 'Stick\HUPilot\config.example.json')))) { [void](Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json); $n++ }
    "$n Dateien"
}

Step 'Version (Stick\HUPilot\Config\version.json) und CHANGELOG-Abschnitt' {
    $v = "$((Get-Content $verJson -Raw -Encoding UTF8 | ConvertFrom-Json).version)".Trim()
    if ($v -notmatch '^\d+\.\d+(\.\d+)?$') { throw "Version ungueltig: '$v'" }
    $cl = Get-Content (Join-Path $root 'CHANGELOG.md') -Raw -Encoding UTF8
    if ($cl -notmatch ('(?m)^## v' + [regex]::Escape($v) + '\b')) { throw "CHANGELOG.md ohne Abschnitt '## v$v'" }
    $s = [regex]::Match((Get-Content $setupPs -Raw -Encoding UTF8), "(?m)^\`$SetupVer = '([^']+)'").Groups[1].Value
    $g = [regex]::Match((Get-Content (Join-Path $root 'Stick\HUPilot\go.ps1') -Raw -Encoding UTF8), "(?m)^\`$Ver\s*=\s*'([^']+)'").Groups[1].Value
    if ($s -ne $v -or $g -ne $v) { throw "Rueckfall-Version passt nicht: Setup '$s', go.ps1 '$g', version.json '$v'" }
    "v$v"
}

# 5. Update-Bibliothek identisch
Step 'Update-Bibliothek Pull.ps1 = Core-Update.ps1' {
    $re = '(?s)#region HMUpdateLib.*?#endregion HMUpdateLib'
    $a = [regex]::Match((Get-Content $pullPs -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    $b = [regex]::Match((Get-Content $libPs -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    if (-not $a -or -not $b) { throw 'Bereich HMUpdateLib fehlt' }
    if ($a -ne $b) { throw 'Bereich HMUpdateLib unterscheidet sich - beide Dateien gleich halten' }
    "$(($a -split "`n").Count) Zeilen"
}

# 6. PSScriptAnalyzer
function Install-HMModule([string]$Name, [string]$Max = '') {
    if (Get-Module -ListAvailable -Name $Name | Where-Object { -not $Max -or $_.Version -le [Version]$Max } | Select-Object -First 1) { return }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }
    $p = @{ Name = $Name; Force = $true; Scope = 'CurrentUser'; SkipPublisherCheck = $true; AllowClobber = $true }
    if ($Max) { $p.MaximumVersion = $Max }
    Install-Module @p
}
Step 'PSScriptAnalyzer (Fehler)' {
    Install-HMModule 'PSScriptAnalyzer'
    Import-Module PSScriptAnalyzer
    $r = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
    if ($r.Count) { throw (($r | Select-Object -First 10 | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) -join ' | ') }
    'keine Fehler'
}

# 7. Pester
Step 'Pester-Tests' {
    Install-HMModule 'Pester' '5.99.99'
    Import-Module Pester -MaximumVersion 5.99.99 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $PSScriptRoot
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $res = Invoke-Pester -Configuration $cfg
    if ($res.FailedCount -gt 0) { throw "$($res.FailedCount) von $($res.TotalCount) Tests fehlgeschlagen" }
    "$($res.PassedCount) Tests bestanden"
}

Write-Host ''
if ($fail.Count) {
    Write-Host "FEHLGESCHLAGEN ($($fail.Count)):" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    if ($env:GITHUB_STEP_SUMMARY) { (@('### HUPilot CI: FEHLGESCHLAGEN') + @($fail | ForEach-Object { "- $_" })) | Add-Content $env:GITHUB_STEP_SUMMARY }
    exit 1
}
Write-Host 'ALLE PRUEFUNGEN BESTANDEN' -ForegroundColor Green
if ($env:GITHUB_STEP_SUMMARY) { '### HUPilot CI: alle Pruefungen bestanden' | Add-Content $env:GITHUB_STEP_SUMMARY }
exit 0
