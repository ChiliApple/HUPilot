<#
.SYNOPSIS
    HUPilot-Setup - Stick vorbereiten: config.json schreiben, Scripts kopieren, WLAN-Paket bauen.
.DESCRIPTION
    ZIELMASCHINE: Admin-PC (Windows 10/11) mit Windows ADK (Windows Configuration Designer).
    - Verbindung testen: Token holen + Autopilot-Liste lesen (prueft App-Berechtigung)
    - Stick schreiben: go.cmd, HUPilot\go.ps1, HUPilot\config.json
    - WLAN-Paket bauen: ICD.exe /Build-ProvisioningPackage -> Stick:\HUPilot\HUPilot-WLAN.ppkg
.NOTES
    Start: Stick:\HUPilot-Setup.cmd oder Repo: Tools\HUPilot-Setup.cmd (fragt nach Adminrechten - noetig fuer ICD.exe)
    Quelle = der Ordner, aus dem das Setup laeuft (Stick ODER Vorbereitungsordner am PC).
    Laden/Speichern/WLAN-Paket immer in der Quelle; 'Auf Stick kopieren' kopiert die Quelle 1:1 auf einen Stick.
#>
$ErrorActionPreference = 'Stop'

# --- Als Administrator neu starten (ICD-Kommandozeile braucht Adminrechte - MS Doku) ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"')
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
try {
    Add-Type -Name Win -Namespace HUPilot -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
    [void][HUPilot.Win]::ShowWindow([HUPilot.Win]::GetConsoleWindow(), 0)
} catch { }
# Laeuft vom Stick (X:\HUPilot\Setup) oder aus dem Repo (Stick\HUPilot\Setup)
$srcHU    = Split-Path $PSScriptRoot -Parent
$srcStick = Split-Path $srcHU -Parent
$srcDrive = $null
if ($srcStick -match '^[A-Za-z]:\\?$') { $srcDrive = $srcStick.Substring(0, 2).ToUpper() }
$srcCfg   = Join-Path $srcHU 'config.json'
$srcPkg   = Join-Path $srcHU 'HUPilot-WLAN.ppkg'
$icd      = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe'
$tplXml   = Join-Path $PSScriptRoot 'WCD-Vorlage\HUPilot-WLAN\customizations.xml'
$enc      = New-Object System.Text.UTF8Encoding($false)
$script:Extra = @{}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot-Setup" Width="640" Height="720" WindowStartupLocation="CenterScreen" FontSize="13">
  <DockPanel Margin="14">
  <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
    <Image x:Name="iLogo" Width="44" Height="44"/>
    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="HUPilot" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock x:Name="tSub" Text="Stick vorbereiten - Windows Autopilot per USB" Foreground="Gray"/>
    </StackPanel>
  </StackPanel>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <GroupBox Grid.Row="0" Header="Tenant / App-Registrierung" Padding="6">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Anzeigename" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tTenant" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Tenant-ID" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tTenantId" Margin="2"/>
        <TextBlock Grid.Row="2" Text="App-ID (Client)" VerticalAlignment="Center"/><TextBox Grid.Row="2" Grid.Column="1" x:Name="tClientId" Margin="2"/>
        <TextBlock Grid.Row="3" Text="Secret (Wert)" VerticalAlignment="Center"/>
        <DockPanel Grid.Row="3" Grid.Column="1"><CheckBox x:Name="cShow" Content="anzeigen" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="6,0,0,0"/><Grid><PasswordBox x:Name="pSecret" Margin="2"/><TextBox x:Name="tSecret" Margin="2" Visibility="Collapsed"/></Grid></DockPanel>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="1" Header="Group Tag" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Standard" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tTag" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Auswahl (Komma)" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tTagChoices" Margin="2"/>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="2" Header="Konfigurations-WLAN (WPA2-Personal)" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="WLAN-Name" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tSsid" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Kennwort" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tKey" Margin="2"/>
      </Grid>
    </GroupBox>
    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="bLoad" Content="Neu laden" Padding="8,2"/>
      <TextBlock Text="Ziel-Stick:" VerticalAlignment="Center" Margin="16,0,6,0"/>
      <ComboBox x:Name="cDrive" Width="180"/>
      <Button x:Name="bReload" Content="Aktualisieren" Margin="6,0,0,0" Padding="8,2"/>
    </StackPanel>
    <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="bTest" Content="1. Verbindung testen" Padding="10,4"/>
      <Button x:Name="bWrite" Content="2. Speichern" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bPkg" Content="3. WLAN-Paket bauen" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bCopy" Content="4. Auf Stick kopieren" Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox Grid.Row="5" x:Name="tLog" Margin="0,10,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
  </Grid>
  </DockPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'iLogo','tSub','tTenant','tTenantId','tClientId','tSecret','pSecret','cShow','tTag','tTagChoices','tSsid','tKey','cDrive','bReload','bLoad','bTest','bWrite','bPkg','bCopy','tLog') { $ui[$n] = $win.FindName($n) }

# Icon (Titelleiste + Taskleiste) und Logo
try {
    $ico = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path $ico) { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($ico))) }
    $png = Join-Path $PSScriptRoot 'logo64.png'
    if (Test-Path $png) { $ui.iLogo.Source = New-Object System.Windows.Media.Imaging.BitmapImage((New-Object System.Uri($png))) }
} catch { }

function Out-Log([string]$m) { $ui.tLog.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $m + "`r`n"); $ui.tLog.ScrollToEnd() }
function Get-Drive { if ($ui.cDrive.SelectedItem) { return ([string]$ui.cDrive.SelectedItem).Substring(0, 2) } return $null }
function Update-Drives {
    $ui.cDrive.Items.Clear()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try { if ($d.IsReady -and $d.DriveType -eq 'Removable' -and $d.Name.Substring(0, 2).ToUpper() -ne $srcDrive) { [void]$ui.cDrive.Items.Add(('{0} {1} ({2:N1} GB)' -f $d.Name.TrimEnd('\'), $d.VolumeLabel, ($d.TotalSize / 1GB))) } } catch { }
    }
    if ($ui.cDrive.Items.Count) {
        $ui.cDrive.SelectedIndex = 0
    } else { Out-Log 'Kein Ziel-Stick gefunden (nur fuer 4. noetig).' }
}
function Get-Cfg {
    $choices = @($ui.tTagChoices.Text -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $o = [ordered]@{
        Tenant = $ui.tTenant.Text.Trim(); TenantId = $ui.tTenantId.Text.Trim(); ClientId = $ui.tClientId.Text.Trim()
        ClientSecret = (Get-Secret); GroupTag = $ui.tTag.Text.Trim(); TagChoices = $choices
        WlanSsid = $ui.tSsid.Text.Trim(); WlanKey = $ui.tKey.Text; WlanPackage = 'HUPilot-WLAN.ppkg'
    }
    foreach ($k in $script:Extra.Keys) { if (-not $o.Contains($k) -or $k -eq 'WlanPackage') { $o[$k] = $script:Extra[$k] } }
    return $o
}
function Test-Fields([string[]]$Names) {
    $c = Get-Cfg
    $miss = @($Names | Where-Object { -not $c[$_] })
    if ($miss.Count) { Out-Log ('FEHLT: ' + ($miss -join ', ')); return $false }
    if ($Names -contains 'TenantId' -and $c.TenantId -notmatch '^[0-9a-fA-F-]{36}$') { Out-Log 'Tenant-ID ist keine GUID'; return $false }
    if ($Names -contains 'ClientId' -and $c.ClientId -notmatch '^[0-9a-fA-F-]{36}$') { Out-Log 'App-ID ist keine GUID'; return $false }
    if ($Names -contains 'WlanKey' -and $c.WlanKey.Length -lt 8) { Out-Log 'WLAN-Kennwort kuerzer als 8 Zeichen'; return $false }
    return $true
}

function Get-Secret { if ($ui.cShow.IsChecked) { return $ui.tSecret.Text.Trim() } return $ui.pSecret.Password.Trim() }
function Set-Secret([string]$v) { $ui.pSecret.Password = $v; $ui.tSecret.Text = $v }
$ui.cShow.Add_Checked({ $ui.tSecret.Text = $ui.pSecret.Password; $ui.pSecret.Visibility = 'Collapsed'; $ui.tSecret.Visibility = 'Visible' })
$ui.cShow.Add_Unchecked({ $ui.pSecret.Password = $ui.tSecret.Text; $ui.tSecret.Visibility = 'Collapsed'; $ui.pSecret.Visibility = 'Visible' })
$ui.bReload.Add_Click({ Update-Drives })

$ui.bLoad.Add_Click({
    $p = $srcCfg
    if (-not (Test-Path $p)) { Out-Log ('Noch keine config.json in der Quelle: ' + $p + ' - Felder ausfuellen, dann 2. Speichern'); return }
    try {
        $c = Get-Content $p -Raw | ConvertFrom-Json
        $ui.tTenant.Text = [string]$c.Tenant; $ui.tTenantId.Text = [string]$c.TenantId; $ui.tClientId.Text = [string]$c.ClientId
        Set-Secret ([string]$c.ClientSecret); $ui.tTag.Text = [string]$c.GroupTag; $ui.tTagChoices.Text = (@($c.TagChoices) -join ', ')
        $ui.tSsid.Text = [string]$c.WlanSsid; $ui.tKey.Text = [string]$c.WlanKey
        $script:Extra = @{}
        foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -notin 'Tenant','TenantId','ClientId','ClientSecret','GroupTag','TagChoices','WlanSsid','WlanKey') { $script:Extra[$pr.Name] = $pr.Value } }
        Out-Log ('Geladen: ' + $p)
    } catch { Out-Log ('Fehler beim Laden: ' + $_.Exception.Message) }
})

$ui.bTest.Add_Click({
    if (-not (Test-Fields @('TenantId', 'ClientId', 'ClientSecret'))) { return }
    $c = Get-Cfg
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{ grant_type = 'client_credentials'; client_id = $c.ClientId; client_secret = $c.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        $tok = (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $c.TenantId + '/oauth2/v2.0/token') -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
        Out-Log 'Token OK'
        $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?$top=1' -Headers @{ Authorization = 'Bearer ' + $tok }
        Out-Log ('Autopilot-Zugriff OK (' + @($r.value).Count + ' Eintrag gelesen)')
    } catch {
        $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }
        if ($m -match 'AADSTS7000222') { $m = 'Secret ABGELAUFEN' } elseif ($m -match 'AADSTS7000215') { $m = 'Secret FALSCH (Secret-ID statt Wert?)' }
        Out-Log ('FEHLER: ' + $m)
    }
})

function Save-Cfg {
    if (-not (Test-Fields @('Tenant', 'TenantId', 'ClientId', 'ClientSecret', 'GroupTag', 'WlanSsid', 'WlanKey'))) { return $false }
    try {
        [System.IO.File]::WriteAllText($srcCfg, (Get-Cfg | ConvertTo-Json -Depth 3), $enc)
        Out-Log ('Gespeichert: ' + $srcCfg)
        return $true
    } catch { Out-Log ('FEHLER Speichern: ' + $_.Exception.Message); return $false }
}

$ui.bWrite.Add_Click({ [void](Save-Cfg) })

$ui.bCopy.Add_Click({
    $dr = Get-Drive; if (-not $dr) { Out-Log 'Kein Ziel-Stick gewaehlt'; return }
    if (-not (Save-Cfg)) { return }
    if (-not (Test-Path $srcPkg)) { Out-Log 'ACHTUNG: kein HUPilot-WLAN.ppkg in der Quelle - erst 3. WLAN-Paket bauen (oder "WlanPackage": "")' }
    try {
        foreach ($f in 'go.cmd', 'HUPilot-Setup.cmd') { $sf = Join-Path $srcStick $f; if (Test-Path $sf) { Copy-Item -Path $sf -Destination (Join-Path $dr $f) -Force } }
        $dst = Join-Path $dr 'HUPilot'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        foreach ($it in @(Get-ChildItem -Path $srcHU -Force | Where-Object { $_.Name -ne 'logs' })) {
            Copy-Item -Path $it.FullName -Destination $dst -Recurse -Force
        }
        Out-Log ('Auf Stick kopiert: ' + $srcStick + ' -> ' + $dr + '\  (ohne logs)')
        $rootPkg = @(Get-ChildItem -Path ($dr + '\') -Filter *.ppkg -File -ErrorAction SilentlyContinue)
        if ($rootPkg.Count) { Out-Log ('ACHTUNG: .ppkg im Hauptverzeichnis entfernen (wird sonst im OOBE angewendet): ' + (($rootPkg | ForEach-Object { $_.Name }) -join ', ')) }
    } catch { Out-Log ('FEHLER: ' + $_.Exception.Message) }
})

$ui.bPkg.Add_Click({
    if (-not (Test-Fields @('WlanSsid', 'WlanKey'))) { return }
    if (-not (Test-Path $icd)) { Out-Log ('ICD.exe nicht gefunden (Windows ADK > Imaging and Configuration Designer): ' + $icd); return }
    $c = Get-Cfg
    $work = Join-Path $env:TEMP ('HUPilot-WCD-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $x = [System.IO.File]::ReadAllText($tplXml)
        $x = $x.Replace('SSID="WLAN-NAME"', 'SSID="' + [System.Security.SecurityElement]::Escape($c.WlanSsid) + '"')
        $x = $x.Replace('<SecurityKey>WLAN-KENNWORT</SecurityKey>', '<SecurityKey>' + [System.Security.SecurityElement]::Escape($c.WlanKey) + '</SecurityKey>')
        $x = [regex]::Replace($x, '<ID>\{[0-9a-fA-F-]+\}</ID>', '<ID>{' + [guid]::NewGuid().ToString() + '}</ID>')
        $xmlPath = Join-Path $work 'customizations.xml'
        [System.IO.File]::WriteAllText($xmlPath, $x.TrimStart([char]0xFEFF), $enc)   # ohne BOM
        $ppkg = $srcPkg
        $store = Join-Path (Split-Path $icd -Parent) 'Microsoft-Common-Provisioning.dat'
        $icdArgs = @('/Build-ProvisioningPackage', ('/CustomizationXML:"' + $xmlPath + '"'), ('/PackagePath:"' + $ppkg + '"'), ('/StoreFile:"' + $store + '"'), '+Overwrite')
        Out-Log 'ICD.exe baut das Paket ...'
        $p = Start-Process -FilePath $icd -ArgumentList $icdArgs -Wait -PassThru -WindowStyle Hidden -WorkingDirectory $work
        if ($p.ExitCode -eq 0 -and (Test-Path $ppkg)) { Out-Log ('WLAN-Paket OK: ' + $ppkg + ' (' + (Get-Item $ppkg).Length + ' Bytes)') }
        else {
            Out-Log ('FEHLER: ICD.exe Exitcode ' + $p.ExitCode)
            $l = Get-ChildItem -Path $work -Filter *.log -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($l) { Get-Content $l.FullName -Tail 15 | ForEach-Object { Out-Log ('  ' + $_) } }
        }
    } catch { Out-Log ('FEHLER: ' + $_.Exception.Message) }
    finally { Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue }   # enthaelt das WLAN-Kennwort
})

Update-Drives
Out-Log ('Quelle: ' + $srcStick)
$ui.tSub.Text = 'Quelle: ' + $srcStick
if (Test-Path $srcCfg) { $ui.bLoad.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
Out-Log ('ICD.exe: ' + $(if (Test-Path $icd) { 'gefunden' } else { 'NICHT gefunden - Windows ADK installieren' }))
[void]$win.ShowDialog()
