#Requires -Version 5.1
<#
.SYNOPSIS
    Automatische Pruefungen fuer HUPilot (GitHub Actions, Windows PowerShell 5.1) - blockierend.
.DESCRIPTION
    1. Syntax aller PowerShell-Dateien (Parser), UTF-8-BOM
    2. JSON- und XML-Dateien lesbar, WCD-Vorlage enthaelt nur WLAN
    3. Keine Geheimnisse im Repo (config.json, *.ppkg)
    4. PSScriptAnalyzer: keine Fehler (Schweregrad Error)
.NOTES
    Aufruf (auch lokal): powershell -NoProfile -ExecutionPolicy Bypass -File .github\tests\Invoke-CITests.ps1
    Zielmaschine: Windows-PC / GitHub-Runner mit Internet (PSScriptAnalyzer wird bei Bedarf installiert).
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
$all = @(Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' })

Step 'Syntax und UTF-8-BOM aller .ps1' {
    $bad = @()
    $files = @($all | Where-Object { $_.Extension -eq '.ps1' })
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

Step 'go.ps1 nur ASCII (Konsole im OOBE)' {
    $b = [System.IO.File]::ReadAllBytes((Join-Path $root 'Stick\HUPilot\go.ps1'))
    $n = @($b | Select-Object -Skip 3 | Where-Object { $_ -gt 127 }).Count
    if ($n) { throw "$n Nicht-ASCII-Bytes" }
}

Step 'JSON und XML lesbar' {
    foreach ($f in @($all | Where-Object { $_.Extension -eq '.json' })) { $null = Get-Content $f.FullName -Raw | ConvertFrom-Json }
    foreach ($f in @($all | Where-Object { $_.Extension -eq '.xml' })) { [xml]$null = Get-Content $f.FullName -Raw -Encoding UTF8 }
}

Step 'WCD-Vorlage: nur WLAN (kein CleanPC), Platzhalter' {
    [xml]$x = Get-Content (Join-Path $root 'Stick\HUPilot\Setup\WCD-Vorlage\HUPilot-WLAN\customizations.xml') -Raw -Encoding UTF8
    $common = $x.WindowsCustomizations.Settings.Customizations.Common
    $names = @($common.ChildNodes | ForEach-Object { $_.LocalName })
    $extra = @($names | Where-Object { $_ -ne 'ConnectivityProfiles' })
    if ($extra.Count) { throw "nicht erlaubt: $($extra -join ', ')" }
    $raw = Get-Content (Join-Path $root 'Stick\HUPilot\Setup\WCD-Vorlage\HUPilot-WLAN\customizations.xml') -Raw
    if ($raw -notmatch 'SSID="WLAN-NAME"' -or $raw -notmatch '<SecurityKey>WLAN-KENNWORT</SecurityKey>') { throw 'Platzhalter fehlen' }
}

Step 'Keine Geheimnisse im Repo' {
    $bad = @($all | Where-Object { $_.Name -eq 'config.json' -or $_.Extension -in '.ppkg', '.cat' } | ForEach-Object { $_.Name })
    if ($bad.Count) { throw "gefunden: $($bad -join ', ')" }
    $ex = Get-Content (Join-Path $root 'Stick\HUPilot\config.example.json') -Raw | ConvertFrom-Json
    if ($ex.ClientSecret -notmatch '^<') { throw 'config.example.json enthaelt ein Secret' }
}

Step 'PSScriptAnalyzer (Schweregrad Error)' {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Install-Module PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
    }
    $r = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
    if ($r.Count) { throw (($r | Select-Object -First 5 | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName)" }) -join '; ') }
}

Write-Host ''
if ($fail.Count) { Write-Host "$($fail.Count) Pruefung(en) fehlgeschlagen" -ForegroundColor Red; $fail | ForEach-Object { Write-Host " - $_" }; exit 1 }
Write-Host 'Alle Pruefungen bestanden' -ForegroundColor Green
