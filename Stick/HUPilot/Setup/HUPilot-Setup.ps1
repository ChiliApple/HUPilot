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
$StartLog = Join-Path $env:PUBLIC 'HUPilot-Setup-Start.log'   # gleicher Ort fuer Benutzer + Admin-Konto
function Start-Log([string]$m) { try { Add-Content -Path $StartLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  PID ' + $PID + '  ' + $m) -Encoding UTF8 } catch { } }
Start-Log ('Start: ' + $PSCommandPath + '  als ' + [Environment]::UserName)

# --- Als Administrator neu starten (ICD-Kommandozeile braucht Adminrechte - MS Doku) ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Log 'nicht Admin -> Neustart mit UAC'
    try {
        Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"') -ErrorAction Stop
        Start-Log 'UAC bestaetigt, Admin-Prozess gestartet'
    } catch {
        Start-Log ('UAC abgelehnt/Fehler: ' + $_.Exception.Message)
        try { Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show('HUPilot-Setup braucht Administratorrechte (fuer ICD.exe).' + [Environment]::NewLine + $_.Exception.Message, 'HUPilot-Setup') } catch { }
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Start-Log 'als Admin gestartet'
# Nur eine Instanz
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\HUPilot-Setup')
if (-not $script:Mutex.WaitOne(0)) {
    Start-Log 'laeuft bereits -> Ende'
    [void][System.Windows.MessageBox]::Show('HUPilot-Setup laeuft bereits (evtl. unsichtbar im Hintergrund).' + [Environment]::NewLine + 'Task-Manager > Details > powershell.exe beenden und neu starten.', 'HUPilot-Setup')
    exit 0
}
# Fehler sichtbar machen (Fenster laeuft ohne Konsole)
trap {
    $msg = ($_ | Out-String)
    try { Set-Content -Path (Join-Path $env:PUBLIC 'HUPilot-Setup-Fehler.txt') -Value $msg -Encoding UTF8 } catch { }
    try { [void][System.Windows.MessageBox]::Show($msg, 'HUPilot-Setup - Fehler') } catch { }
    exit 1
}
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
$SetupVer = '2.5'
$GoVer    = '?'
try { $m = Select-String -Path (Join-Path $srcHU 'go.ps1') -Pattern "^\`$Ver\s*=\s*'([^']+)'" | Select-Object -First 1; if ($m) { $GoVer = $m.Matches[0].Groups[1].Value } } catch { }
$srcPkg   = Join-Path $srcHU 'HUPilot-WLAN.ppkg'
$icd      = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe'
$tplXml   = Join-Path $PSScriptRoot 'WCD-Vorlage\HUPilot-WLAN\customizations.xml'
$enc      = New-Object System.Text.UTF8Encoding($false)
$script:Extra = @{}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot-Setup" Width="720" Height="720" WindowStartupLocation="CenterScreen" FontSize="13">
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
        <TextBlock Grid.Row="0" Text="Anzeigename" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tTenant" ToolTip="Anzeigename des Tenants - nur fuer Log und Protokoll am Stick (z. B. Schulname)." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Tenant-ID" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tTenantId" ToolTip="Verzeichnis-(Mandanten-)ID des Tenants (GUID).&#x0a;Entra Admin Center &gt; Uebersicht &gt; Mandanten-ID." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="2" Text="App-ID (Client)" VerticalAlignment="Center"/><TextBox Grid.Row="2" Grid.Column="1" x:Name="tClientId" ToolTip="Anwendungs-(Client-)ID der App-Registrierung HUPilot-Upload (GUID).&#x0a;Berechtigung: DeviceManagementServiceConfig.ReadWrite.All (Anwendung) + Administratorzustimmung." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="3" Text="Secret (Wert)" VerticalAlignment="Center"/>
        <DockPanel Grid.Row="3" Grid.Column="1"><CheckBox x:Name="cShow" ToolTip="Secret im Klartext anzeigen." ToolTipService.ShowDuration="30000" Content="anzeigen" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="6,0,0,0"/><Grid><PasswordBox x:Name="pSecret" ToolTip="Geheimer Clientschluessel der App HUPilot-Upload - den WERT, nicht die Geheimnis-ID.&#x0a;Kurz gueltig halten (7-14 Tage) und vor jedem Einsatz erneuern." ToolTipService.ShowDuration="30000" Margin="2"/><TextBox x:Name="tSecret" ToolTip="Geheimer Clientschluessel (Wert) im Klartext." ToolTipService.ShowDuration="30000" Margin="2" Visibility="Collapsed"/></Grid></DockPanel>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="1" Header="Group Tag" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Standard" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tTag" ToolTip="Group Tag, den die Geraete standardmaessig bekommen (z. B. SN-2026).&#x0a;Am Geraet: Enter oder 10 s warten = dieser Tag." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Auswahl (Komma)" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tTagChoices" ToolTip="Auswahl am Geraet (max. 9), durch Komma getrennt.&#x0a;Am Geraet mit Taste 1-9 waehlbar - z. B. fuer Nachzuegler aus anderen Jahrgaengen." ToolTipService.ShowDuration="30000" Margin="2"/>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="2" Header="Konfigurations-WLAN (WPA2-Personal)" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="WLAN-Name" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tSsid" ToolTip="Name des Konfigurations-WLANs (WPA2-Personal).&#x0a;go.ps1 verbindet sich damit zum Hochladen; das WLAN-Paket bringt es nach dem Zuruecksetzen wieder mit." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Kennwort" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tKey" ToolTip="Kennwort des Konfigurations-WLANs (mind. 8 Zeichen).&#x0a;Steht im Klartext in config.json und im WLAN-Paket - Stick nicht aus der Hand geben." ToolTipService.ShowDuration="30000" Margin="2"/>
      </Grid>
    </GroupBox>
    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="bLoad" ToolTip="config.json aus der Quelle neu laden (der Ordner, aus dem dieses Setup laeuft)." ToolTipService.ShowDuration="30000" Content="Neu laden" Padding="8,2"/>
      <TextBlock Text="Ziel-Stick:" VerticalAlignment="Center" Margin="16,0,6,0"/>
      <ComboBox x:Name="cDrive" ToolTip="Ziel-Stick fuer 4. Auf Stick kopieren. Das Laufwerk der Quelle selbst wird nicht angeboten." ToolTipService.ShowDuration="30000" Width="180"/>
      <Button x:Name="bReload" ToolTip="USB-Laufwerke neu einlesen." ToolTipService.ShowDuration="30000" Content="Aktualisieren" Margin="6,0,0,0" Padding="8,2"/>
    </StackPanel>
    <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="bTest" ToolTip="Holt mit App-ID und Secret ein Token und liest die Autopilot-Liste.&#x0a;Zeigt sofort, ob Secret abgelaufen/falsch ist oder die Berechtigung fehlt." ToolTipService.ShowDuration="30000" Content="1. Verbindung testen" Padding="10,4"/>
      <Button x:Name="bWrite" ToolTip="Speichert alle Felder als config.json in die Quelle.&#x0a;Zusaetzliche Felder (TagPattern, Reset, ...) bleiben erhalten." ToolTipService.ShowDuration="30000" Content="2. Speichern" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bPkg" ToolTip="Baut HUPilot-WLAN.ppkg (nur das WLAN, kein CleanPC) in die Quelle.&#x0a;VORAUSSETZUNG: Windows ADK mit &quot;Imaging and Configuration Designer&quot; (WCD) auf diesem PC:&#x0a;C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe&#x0a;Die WCD-App aus dem Microsoft Store reicht NICHT (keine Kommandozeile).&#x0a;Ohne ADK: Tools\New-WcdProjekt.ps1 + WCD-Oberflaeche, siehe INSTALL.md." ToolTipService.ShowDuration="30000" Content="3. WLAN-Paket bauen" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bCopy" ToolTip="Speichert zuerst, dann kopiert die Quelle 1:1 auf den Ziel-Stick:&#x0a;go.cmd, HUPilot-Setup.cmd, HUPilot\ (go.ps1, config.json, WLAN-Paket, Setup).&#x0a;Nicht kopiert: logs und Ordner, die mit _ beginnen." ToolTipService.ShowDuration="30000" Content="4. Auf Stick kopieren" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bStatus" ToolTip="Zeigt alle Autopilot-Geraete des Tenants mit Tag, Profil und Intune-Registrierung.&#x0a;Filter nach Tag und nach Seriennummern aus protokoll.csv (Quelle und Ziel-Stick).&#x0a;Export als CSV und Drucken moeglich." ToolTipService.ShowDuration="30000" Content="5. Status" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bHelp" ToolTip="Anleitung oeffnen (F1)" Content="?" FontWeight="Bold" Width="32" Padding="0,4" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox Grid.Row="5" x:Name="tLog" ToolTip="Protokoll dieser Sitzung." ToolTipService.ShowDuration="30000" Margin="0,10,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
  </Grid>
  </DockPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'iLogo','tSub','tTenant','tTenantId','tClientId','tSecret','pSecret','cShow','tTag','tTagChoices','tSsid','tKey','cDrive','bReload','bLoad','bTest','bWrite','bPkg','bCopy','bStatus','bHelp','tLog') { $ui[$n] = $win.FindName($n) }

$win.Title = 'HUPilot-Setup v' + $SetupVer + '   (go.ps1 v' + $GoVer + ')'
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
$ShowHelp = {
    $f = Join-Path $PSScriptRoot 'Anleitung.html'
    if (Test-Path $f) { Start-Process -FilePath $f } else { Out-Log ('Anleitung fehlt: ' + $f) }
}
$ui.bHelp.Add_Click($ShowHelp)
$win.Add_KeyDown({ if ($_.Key -eq 'F1') { & $ShowHelp } })
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

function Get-ApiToken {
    if (-not (Test-Fields @('TenantId', 'ClientId', 'ClientSecret'))) { return $null }
    $c = Get-Cfg
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{ grant_type = 'client_credentials'; client_id = $c.ClientId; client_secret = $c.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        return (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $c.TenantId + '/oauth2/v2.0/token') -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
    } catch {
        $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }
        if ($m -match 'AADSTS7000222') { $m = 'Secret ABGELAUFEN' } elseif ($m -match 'AADSTS7000215') { $m = 'Secret FALSCH (Secret-ID statt Wert?)' }
        Out-Log ('FEHLER Anmeldung: ' + $m)
        return $null
    }
}

function Show-SecretExpiry([string]$Token) {
    # Secret-Ablauf (optional: braucht Application.Read.All fuer die App)
    $h = @{ Authorization = 'Bearer ' + $Token }
    try {
        $c = Get-Cfg
        $app = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ("https://graph.microsoft.com/v1.0/applications(appId='" + $c.ClientId + "')?`$select=displayName,passwordCredentials") -Headers $h
        $hint = $c.ClientSecret.Substring(0, [Math]::Min(3, $c.ClientSecret.Length))
        $mine = @($app.passwordCredentials | Where-Object { $_.hint -ceq $hint })
        $list = $(if ($mine.Count) { $mine } else { @($app.passwordCredentials) })
        $minDays = $null; $minEnd = $null
        foreach ($pc in $list) {
            $end = ([datetime]$pc.endDateTime).ToLocalTime()
            $days = [int][Math]::Floor(($end - (Get-Date)).TotalDays)
            if ($null -eq $minDays -or $days -lt $minDays) { $minDays = $days; $minEnd = $end }
            $txt = 'Secret "' + $pc.displayName + '" (' + $pc.hint + '...) gueltig bis ' + $end.ToString('dd.MM.yyyy HH:mm') + '  -> noch ' + $days + ' Tage'
            if ($days -lt 0) { $txt = 'ACHTUNG ABGELAUFEN: ' + $txt } elseif ($days -le 7) { $txt = 'ACHTUNG BALD ABGELAUFEN: ' + $txt }
            Out-Log $txt
        }
        if (-not $mine.Count) { Out-Log '  (verwendetes Secret nicht eindeutig erkannt - alle Secrets der App angezeigt)' }
        if ($mine.Count -and $null -ne $minDays) {
            Set-SubSecret ('Secret gueltig bis ' + $minEnd.ToString('dd.MM.yyyy HH:mm') + ' (noch ' + $minDays + ' Tage)') ($minDays -le 7)
        }
    } catch {
        Out-Log 'Secret-Ablauf nicht lesbar (optional: Anwendungsberechtigung Application.Read.All fuer HUPilot-Upload)'
    }
}
function Set-SubSecret([string]$Text, [bool]$Warn) {
    $ui.tSub.Text = $Text
    $ui.tSub.Foreground = $(if ($Warn) { [System.Windows.Media.Brushes]::Firebrick } else { [System.Windows.Media.Brushes]::DimGray })
}

$ui.bTest.Add_Click({
    $tok = Get-ApiToken; if (-not $tok) { return }
    Out-Log 'Token OK'
    $h = @{ Authorization = 'Bearer ' + $tok }
    try {
        $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?$top=1' -Headers $h
        Out-Log ('Autopilot-Zugriff OK (' + @($r.value).Count + ' Eintrag gelesen)')
    } catch { Out-Log ('FEHLER Autopilot-Zugriff (Berechtigung DeviceManagementServiceConfig.ReadWrite.All?): ' + $_.Exception.Message) }
    Show-SecretExpiry -Token $tok
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
        foreach ($it in @(Get-ChildItem -Path $srcHU -Force | Where-Object { $_.Name -ne 'logs' -and -not $_.Name.StartsWith('_') })) {
            Copy-Item -Path $it.FullName -Destination $dst -Recurse -Force
        }
        Out-Log ('Auf Stick kopiert: ' + $srcStick + ' -> ' + $dr + '\  (ohne logs und _Ordner)')
        $rootPkg = @(Get-ChildItem -Path ($dr + '\') -Filter *.ppkg -File -ErrorAction SilentlyContinue)
        if ($rootPkg.Count) { Out-Log ('ACHTUNG: .ppkg im Hauptverzeichnis entfernen (wird sonst im OOBE angewendet): ' + (($rootPkg | ForEach-Object { $_.Name }) -join ', ')) }
    } catch { Out-Log ('FEHLER: ' + $_.Exception.Message) }
})

$ui.bPkg.Add_Click({
    if (-not (Test-Fields @('WlanSsid', 'WlanKey'))) { return }
    if (-not (Test-Path $icd)) { Out-Log ('ICD.exe nicht gefunden: ' + $icd); Out-Log '  -> Windows ADK installieren, Feature "Imaging and Configuration Designer (ICD)". Die Store-App WCD hat keine Kommandozeile.'; Out-Log '  -> ohne ADK: Tools\New-WcdProjekt.ps1 + WCD-Oberflaeche (INSTALL.md)'; return }
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

function Read-Protokoll {
    $map = @{}
    $files = @(Join-Path $srcHU 'logs\protokoll.csv')
    $dr = Get-Drive; if ($dr) { $files += (Join-Path $dr 'HUPilot\logs\protokoll.csv') }
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        try {
            foreach ($row in @(Import-Csv -Path $f -Delimiter ';')) {
                if (-not $row.Seriennr) { continue }
                if (-not $map.ContainsKey($row.Seriennr) -or [string]$row.Zeit -gt [string]$map[$row.Seriennr].Zeit) { $map[$row.Seriennr] = $row }
            }
            Out-Log ('Protokoll gelesen: ' + $f)
        } catch { Out-Log ('Protokoll ' + $f + ': ' + $_.Exception.Message) }
    }
    return $map
}

function Show-Status {
    param($Rows, [hashtable]$Proto, [string]$Tenant)
    [xml]$sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot - Status" Width="1100" Height="640" WindowStartupLocation="CenterOwner" FontSize="12">
  <DockPanel Margin="10">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBlock Text="Tag:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <ComboBox x:Name="cTag" Width="140"/>
      <CheckBox x:Name="cProto" Content="nur Geraete aus protokoll.csv" VerticalAlignment="Center" Margin="14,0,0,0"/>
      <TextBox x:Name="tFind" Width="160" Margin="14,0,0,0" ToolTip="Suche in Seriennummer / Geraetename / Benutzer"/>
      <TextBlock x:Name="tCount" VerticalAlignment="Center" Margin="14,0,0,0" FontWeight="SemiBold"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bCsv" Content="CSV speichern" Padding="10,4"/>
      <Button x:Name="bPrint" Content="Drucken" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bClose" Content="Schliessen" Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <DataGrid x:Name="dGrid" AutoGenerateColumns="True" IsReadOnly="True" CanUserSortColumns="True" AlternatingRowBackground="#F3F3F3" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
    $sw.Owner = $win
    if ($win.Icon) { $sw.Icon = $win.Icon }
    $g = @{}; foreach ($n in 'cTag','cProto','tFind','tCount','bCsv','bPrint','bClose','dGrid') { $g[$n] = $sw.FindName($n) }
    [void]$g.cTag.Items.Add('Alle')
    foreach ($t in @($Rows | ForEach-Object { $_.Tag } | Where-Object { $_ } | Sort-Object -Unique)) { [void]$g.cTag.Items.Add($t) }
    $g.cTag.SelectedIndex = 0
    $g.cProto.IsChecked = ($Proto.Count -gt 0)
    $g.cProto.IsEnabled = ($Proto.Count -gt 0)
    $script:StatusView = @()
    $refresh = {
        $v = @($Rows)
        if ($g.cTag.SelectedItem -and [string]$g.cTag.SelectedItem -ne 'Alle') { $sel = [string]$g.cTag.SelectedItem; $v = @($v | Where-Object { $_.Tag -eq $sel }) }
        if ($g.cProto.IsChecked) { $v = @($v | Where-Object { $_.HUPilot }) }
        if ($g.tFind.Text) { $q = $g.tFind.Text; $v = @($v | Where-Object { $_.Seriennr -like ('*' + $q + '*') -or $_.Name -like ('*' + $q + '*') -or $_.Benutzer -like ('*' + $q + '*') }) }
        $script:StatusView = $v
        $g.dGrid.ItemsSource = $v
        $ok = @($v | Where-Object { $_.Intune -eq 'registriert' }).Count
        $g.tCount.Text = ('' + $v.Count + ' Geraete  |  ' + $ok + ' in Intune registriert  |  ' + ($v.Count - $ok) + ' offen')
    }
    $g.cTag.Add_SelectionChanged($refresh)
    $g.cProto.Add_Click($refresh)
    $g.tFind.Add_TextChanged($refresh)
    $g.bClose.Add_Click({ $sw.Close() })
    $g.bCsv.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'CSV (*.csv)|*.csv'
        $dlg.FileName = 'HUPilot-Status_' + ($Tenant -replace '[^A-Za-z0-9-]', '') + '_' + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '.csv'
        if ($dlg.ShowDialog()) {
            $script:StatusView | Export-Csv -Path $dlg.FileName -Delimiter ';' -NoTypeInformation -Encoding UTF8
            Out-Log ('Status gespeichert: ' + $dlg.FileName)
        }
    })
    $g.bPrint.Add_Click({
        $pd = New-Object System.Windows.Controls.PrintDialog
        if (-not $pd.ShowDialog()) { return }
        $doc = New-Object System.Windows.Documents.FlowDocument
        $doc.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
        $doc.FontSize = 9
        $doc.PagePadding = New-Object System.Windows.Thickness(40)
        $doc.ColumnWidth = $pd.PrintableAreaWidth
        $doc.PageWidth = $pd.PrintableAreaWidth
        $doc.PageHeight = $pd.PrintableAreaHeight
        $h1 = New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run('HUPilot - Status ' + $Tenant + '   ' + (Get-Date -Format 'dd.MM.yyyy HH:mm') + '   (' + $g.tCount.Text + ')'))
        $h1.FontSize = 12; $h1.FontWeight = [System.Windows.FontWeights]::Bold
        $doc.Blocks.Add($h1)
        $tbl = New-Object System.Windows.Documents.Table
        $tbl.CellSpacing = 0
        $cols = @('Seriennr', 'Tag', 'Profil', 'Intune', 'Benutzer', 'Name', 'LetzterSync', 'HUPilot')
        foreach ($c in $cols) { $tbl.Columns.Add((New-Object System.Windows.Documents.TableColumn)) }
        $rg = New-Object System.Windows.Documents.TableRowGroup
        $hr = New-Object System.Windows.Documents.TableRow
        foreach ($c in $cols) { $cell = New-Object System.Windows.Documents.TableCell((New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run($c)))); $cell.FontWeight = [System.Windows.FontWeights]::Bold; $cell.BorderBrush = [System.Windows.Media.Brushes]::Gray; $cell.BorderThickness = New-Object System.Windows.Thickness(0, 0, 0, 1); $hr.Cells.Add($cell) }
        $rg.Rows.Add($hr)
        foreach ($r in $script:StatusView) {
            $tr = New-Object System.Windows.Documents.TableRow
            foreach ($c in $cols) { $tr.Cells.Add((New-Object System.Windows.Documents.TableCell((New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run([string]$r.$c)))))) }
            $rg.Rows.Add($tr)
        }
        $tbl.RowGroups.Add($rg)
        $doc.Blocks.Add($tbl)
        $pd.PrintDocument(([System.Windows.Documents.IDocumentPaginatorSource]$doc).DocumentPaginator, 'HUPilot-Status')
        Out-Log 'Status gedruckt'
    })
    & $refresh
    [void]$sw.ShowDialog()
}

$ui.bStatus.Add_Click({
    $tok = Get-ApiToken; if (-not $tok) { return }
    $h = @{ Authorization = 'Bearer ' + $tok }
    Out-Log 'Lade Autopilot-Geraete ...'
    $all = @()
    try {
        $uri = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?$top=500'
        while ($uri) {
            $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri $uri -Headers $h
            $all += @($r.value)
            $uri = $r.'@odata.nextLink'
        }
    } catch { Out-Log ('FEHLER Autopilot-Liste: ' + $_.Exception.Message); return }
    # Optional: Intune-Geraete (Primaerer Benutzer, Geraetename, letzter Sync) - braucht DeviceManagementManagedDevices.Read.All
    $md = @{}
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,serialNumber,deviceName,userPrincipalName,lastSyncDateTime&`$top=999"
        while ($uri) {
            $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri $uri -Headers $h
            foreach ($m in @($r.value)) { if ($m.serialNumber) { $md[[string]$m.id] = $m; $md['SN:' + [string]$m.serialNumber] = $m } }
            $uri = $r.'@odata.nextLink'
        }
        Out-Log ('Intune-Geraete gelesen: ' + @($md.Keys | Where-Object { $_ -like 'SN:*' }).Count)
    } catch { Out-Log 'Primaerer Benutzer nicht lesbar (optional: Anwendungsberechtigung DeviceManagementManagedDevices.Read.All fuer HUPilot-Upload)' }
    $proto = Read-Protokoll
    $mapE = @{ enrolled = 'registriert'; notContacted = 'noch nicht'; failed = 'Fehler'; pendingReset = 'Reset ausstehend'; blocked = 'blockiert'; unknown = 'unbekannt' }
    $rows = foreach ($d in $all) {
        $ps = [string]$d.deploymentProfileAssignmentStatus
        $prof = $(if ($ps -like 'assigned*') { 'zugewiesen' } elseif ($ps -eq 'pending') { 'ausstehend' } elseif ($ps -eq 'notAssigned') { 'keins' } else { $ps })
        $es = [string]$d.enrollmentState
        $lc = ''
        try { $dt = [datetime]$d.lastContactedDateTime; if ($dt.Year -gt 2000) { $lc = $dt.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } } catch { }
        $pr = $null; if ($proto.ContainsKey([string]$d.serialNumber)) { $pr = $proto[[string]$d.serialNumber] }
        $im = $null
        if ($d.managedDeviceId -and $md.ContainsKey([string]$d.managedDeviceId)) { $im = $md[[string]$d.managedDeviceId] }
        elseif ($md.ContainsKey('SN:' + [string]$d.serialNumber)) { $im = $md['SN:' + [string]$d.serialNumber] }
        $sync = ''
        if ($im) { try { $sd = [datetime]$im.lastSyncDateTime; if ($sd.Year -gt 2000) { $sync = $sd.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } } catch { } }
        [pscustomobject]@{
            Seriennr       = [string]$d.serialNumber
            Tag            = [string]$d.groupTag
            Profil         = $prof
            Intune         = $(if ($mapE.ContainsKey($es)) { $mapE[$es] } else { $es })
            LetzterKontakt = $lc
            Benutzer       = $(if ($im -and $im.userPrincipalName) { [string]$im.userPrincipalName } else { [string]$d.userPrincipalName })
            Name           = $(if ($im) { [string]$im.deviceName } else { [string]$d.displayName })
            LetzterSync    = $sync
            Modell         = [string]$d.model
            HUPilot        = $(if ($pr) { [string]$pr.Zeit + ' ' + [string]$pr.Ergebnis } else { '' })
        }
    }
    Out-Log ('' + @($rows).Count + ' Autopilot-Geraete, ' + $proto.Count + ' aus protokoll.csv')
    Show-Status -Rows @($rows) -Proto $proto -Tenant ((Get-Cfg).Tenant)
})

Update-Drives
Out-Log ('Quelle: '  + $srcStick)
$ui.tSub.ToolTip = 'Quelle: ' + $srcStick
if (Test-Path $srcCfg) { $ui.bLoad.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
Out-Log ('ICD.exe: ' + $(if (Test-Path $icd) { 'gefunden' } else { 'NICHT gefunden - fuer 3. WLAN-Paket: Windows ADK mit Imaging and Configuration Designer installieren (Store-WCD reicht nicht)' }))
Start-Log 'Fenster wird angezeigt'
# Beim Start automatisch Secret-Ablauf anzeigen (nur wenn echte Werte eingetragen sind)
$win.Add_ContentRendered({
    $c = Get-Cfg
    if ($c.TenantId -notmatch '^[0-9a-fA-F-]{36}$' -or $c.ClientId -notmatch '^[0-9a-fA-F-]{36}$' -or -not $c.ClientSecret -or $c.ClientSecret.StartsWith('<')) { return }
    Out-Log 'Pruefe Secret ...'
    $win.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    $tok = Get-ApiToken
    if (-not $tok) { Set-SubSecret 'Secret UNGUELTIG - siehe Protokoll' $true; return }
    Show-SecretExpiry -Token $tok
})
[void]$win.ShowDialog()
Start-Log 'Fenster geschlossen'
try { $script:Mutex.ReleaseMutex() } catch { }
