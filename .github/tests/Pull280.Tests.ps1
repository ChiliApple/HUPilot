# Pull.ps1: Korrekturen aus der Pruefung vor 2.8.0 (Textpruefung, Pull.ps1 laedt echte Dateien und laeuft hier nicht)
BeforeAll {
    $script:PullPath = Join-Path $PSScriptRoot '..\..\Stick\HUPilot\Setup\Pull.ps1'
    $script:PullText = Get-Content -LiteralPath $script:PullPath -Raw -Encoding UTF8
}
Describe 'Pull 2.8.0: unvollstaendige Dateiliste' {
    It 'Pull.ps1 parst ohne Fehler' {
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:PullPath, [ref]$null, [ref]$e)
        @($e).Count | Should -Be 0
    }
    It 'gekuerzte Dateiliste bricht ab, bevor etwas geladen oder ersetzt wird' {
        $i = $script:PullText.IndexOf('if ($tree.truncated) { Stop-HMPull')
        $i | Should -BeGreaterThan -1
        $i | Should -BeLessThan $script:PullText.IndexOf('# --- 4. alles laden und pruefen')
        $script:PullText.Substring($i, 260) | Should -Match 'NICHTS verändert'
    }
    It 'jeder Eintrag der Pruefsummen-Datei unter Stick/ muss in der Dateiliste stehen, sonst Abbruch vor dem Laden' {
        $i = $script:PullText.IndexOf('$missing = @($manifest.Keys | Where-Object')
        $i | Should -BeGreaterThan -1
        $i | Should -BeLessThan $script:PullText.IndexOf('# --- 4. alles laden und pruefen')
        $script:PullText.Substring($i, 520) | Should -Match 'if \(\$missing\.Count\) \{ Stop-HMPull'
        # Logik nachgestellt: fehlender Eintrag wird gefunden, Eintraege ausserhalb von Stick/ zaehlen nicht
        $SrcPrefix = 'Stick/'
        $manifest = @{ 'Stick/a.ps1' = 'x'; 'Stick/b.ps1' = 'y'; 'README.md' = 'z' }
        $files = @([pscustomobject]@{ path = 'Stick/a.ps1' })
        $inTree = @{}; foreach ($f in $files) { $inTree["$($f.path)"] = $true }
        $missing = @($manifest.Keys | Where-Object { "$_".StartsWith($SrcPrefix) -and "$_".Length -gt $SrcPrefix.Length -and -not $inTree.ContainsKey("$_") })
        $missing.Count | Should -Be 1
        $missing[0] | Should -Be 'Stick/b.ps1'
    }
}