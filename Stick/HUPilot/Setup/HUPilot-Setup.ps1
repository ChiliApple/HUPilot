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
$SetupVer = '2.0'
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
        Title="HUPilot-Setup" Width="890" Height="840" WindowStartupLocation="CenterScreen" FontSize="13">
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
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
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
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Standard" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tTag" ToolTip="Group Tag, den die Geraete standardmaessig bekommen (z. B. SN-2026).&#x0a;Am Geraet: Enter oder 10 s warten = dieser Tag." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Auswahl (Komma)" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tTagChoices" ToolTip="Auswahl am Geraet (max. 9), durch Komma getrennt.&#x0a;Am Geraet mit Taste 1-9 waehlbar - z. B. fuer Nachzuegler aus anderen Jahrgaengen." ToolTipService.ShowDuration="30000" Margin="2"/>
        <CheckBox Grid.Row="2" Grid.Column="1" x:Name="cAskUser" Margin="2,4,0,0" Content="Am Geraet nach Benutzer (UPN) fragen und vorab zuweisen" ToolTip="go.ps1 fragt nach dem Tag nach einem Anmeldenamen (Enter = keiner) und weist ihn in Autopilot zu.&#x0a;Sinnvoll fuer Einzelgeraete, nicht fuer ganze Klassen. Pruefung des Namens: optional User.Read.All." ToolTipService.ShowDuration="30000"/>
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
    <GroupBox Grid.Row="3" Header="Lokaler Admin (optional - leer lassen = keiner)" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Admin-Name" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tAdmName" ToolTip="Lokales Administratorkonto fuer die Kustoden (max. 20 Zeichen, z. B. kustode).&#x0a;Kommt mit 3. WLAN-Paket bauen ins Paket und wird nach JEDEM Zuruecksetzen neu angelegt.&#x0a;Kennwort und Konto laufen nie ab. Leer lassen = kein lokaler Admin.&#x0a;Aenderung wirkt erst nach neuem Paket + Zuruecksetzen mit dem Stick." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Admin-Kennwort" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tAdmPw" ToolTip="Kennwort des lokalen Admins (mind. 8 Zeichen, auf allen Geraeten gleich).&#x0a;Steht im Klartext in config.json und im WLAN-Paket - Stick nicht aus der Hand geben." ToolTipService.ShowDuration="30000" Margin="2"/>
      </Grid>
    </GroupBox>
    <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="bLoad" ToolTip="config.json aus der Quelle neu laden (der Ordner, aus dem dieses Setup laeuft)." ToolTipService.ShowDuration="30000" Content="Neu laden" Padding="8,2"/>
      <TextBlock Text="Ziel-Stick:" VerticalAlignment="Center" Margin="16,0,6,0"/>
      <ComboBox x:Name="cDrive" ToolTip="Ziel-Stick fuer 4. Auf Stick kopieren. Das Laufwerk der Quelle selbst wird nicht angeboten." ToolTipService.ShowDuration="30000" Width="180"/>
      <Button x:Name="bReload" ToolTip="USB-Laufwerke neu einlesen." ToolTipService.ShowDuration="30000" Content="Aktualisieren" Margin="6,0,0,0" Padding="8,2"/>
      <Button x:Name="bPrep" ToolTip="Nur wenn das Setup vom PC laeuft: mehrere USB-Sticks auf einmal oder hintereinander&#x0a;formatieren, benennen und mit HUPilot befuellen. ALLE Daten auf den gewaehlten Sticks gehen verloren." ToolTipService.ShowDuration="30000" Content="Sticks vorbereiten ..." Margin="16,0,0,0" Padding="8,2"/>
    </StackPanel>
    <StackPanel Grid.Row="5" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="bTest" ToolTip="Holt mit App-ID und Secret ein Token und liest die Autopilot-Liste.&#x0a;Zeigt sofort, ob Secret abgelaufen/falsch ist oder die Berechtigung fehlt." ToolTipService.ShowDuration="30000" Content="1. Verbindung testen" Padding="10,4"/>
      <Button x:Name="bWrite" ToolTip="Speichert alle Felder als config.json in die Quelle.&#x0a;Zusaetzliche Felder (TagPattern, Reset, ...) bleiben erhalten." ToolTipService.ShowDuration="30000" Content="2. Speichern" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bPkg" ToolTip="Baut HUPilot-WLAN.ppkg (WLAN + optional lokaler Admin, kein CleanPC) in die Quelle.&#x0a;VORAUSSETZUNG: Windows ADK mit &quot;Imaging and Configuration Designer&quot; (WCD) auf diesem PC:&#x0a;C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe&#x0a;Die WCD-App aus dem Microsoft Store reicht NICHT (keine Kommandozeile).&#x0a;Ohne ADK: Tools\New-WcdProjekt.ps1 + WCD-Oberflaeche, siehe INSTALL.md." ToolTipService.ShowDuration="30000" Content="3. WLAN-Paket bauen" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bCopy" ToolTip="Speichert zuerst, dann kopiert die Quelle 1:1 auf den Ziel-Stick:&#x0a;go.cmd, HUPilot-Setup.cmd, HUPilot\ (go.ps1, config.json, WLAN-Paket, Setup).&#x0a;Nicht kopiert: logs und Ordner, die mit _ beginnen." ToolTipService.ShowDuration="30000" Content="4. Auf Stick kopieren" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bStatus" ToolTip="Zeigt alle Autopilot-Geraete des Tenants mit Tag, Profil und Intune-Registrierung.&#x0a;Filter nach Tag und nach Seriennummern aus protokoll.csv (Quelle und Ziel-Stick).&#x0a;Export als CSV und Drucken moeglich." ToolTipService.ShowDuration="30000" Content="5. Status" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bHelp" ToolTip="Anleitung oeffnen (F1)" Content="?" FontWeight="Bold" Width="32" Padding="0,4" Margin="8,0,0,0"/>
      <Button x:Name="bUpd" ToolTip="Prueft auf GitHub, ob es eine neuere HUPilot-Version gibt.&#x0a;Gold = Update verfuegbar - Klick aktualisiert die Programmdateien in der Quelle (Stick oder Ordner).&#x0a;config.json, WLAN-Paket und logs bleiben unveraendert." ToolTipService.ShowDuration="30000" Content="Update ..." Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <StackPanel Grid.Row="6" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="bTags" ToolTip="Zeigt je Group Tag: Anzahl Geraete in Autopilot, passende dynamische Gruppe und zugewiesenes Autopilot-Profil.&#x0a;So sieht man VOR dem Einsatz, ob fuer einen Tag ein Profil fehlt. Gruppen lesen: optional Group.Read.All." ToolTipService.ShowDuration="30000" Content="6. Tags pruefen" Padding="10,4"/>
      <Button x:Name="bHash" ToolTip="Hashes, die go.ps1 offline am Stick gespeichert hat (HUPilot\logs\hashes.csv), hochladen.&#x0a;Liest Quelle + Ziel-Stick, weitere CSV-Dateien koennen hinzugefuegt werden. Erledigte Zeilen wandern nach hashes-erledigt.csv." ToolTipService.ShowDuration="30000" Content="7. Hashes importieren" Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox Grid.Row="7" x:Name="tLog" ToolTip="Protokoll dieser Sitzung." ToolTipService.ShowDuration="30000" Margin="0,10,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
  </Grid>
  </DockPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'iLogo','tSub','tTenant','tTenantId','tClientId','tSecret','pSecret','cShow','tTag','tTagChoices','tSsid','tKey','tAdmName','tAdmPw','cAskUser','bTags','bHash','cDrive','bReload','bPrep','bLoad','bTest','bWrite','bPkg','bCopy','bStatus','bHelp','bUpd','tLog') { $ui[$n] = $win.FindName($n) }

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
        AdminName = $ui.tAdmName.Text.Trim(); AdminPassword = $ui.tAdmPw.Text; AskUser = [bool]$ui.cAskUser.IsChecked
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
    if ($c.AdminName) {
        if ($c.AdminName.Length -gt 20 -or $c.AdminName -match '["/\\\[\]:;|=,+*?<>@ ]') { Out-Log 'Admin-Name ungueltig (max. 20 Zeichen, keine Leer- oder Sonderzeichen wie / \ [ ] : ; | = , + * ? < > @)'; return $false }
        if ($c.AdminPassword.Length -lt 8) { Out-Log 'Admin-Kennwort kuerzer als 8 Zeichen'; return $false }
    }
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

# ---------- Sticks vorbereiten (nur wenn das Setup vom PC laeuft): formatieren + benennen + befuellen ----------
$script:SrcOnUsb = $false
$script:SrcDisk  = -1
try {
    $q = (Split-Path $srcStick -Qualifier).TrimEnd(':')
    $sd = Get-Partition -DriveLetter $q -ErrorAction Stop | Get-Disk -ErrorAction Stop
    $script:SrcDisk = [int]$sd.Number
    if ([string]$sd.BusType -eq 'USB') { $script:SrcOnUsb = $true }
} catch { }
if ($srcDrive -and ([System.IO.DriveInfo]::new($srcDrive)).DriveType -eq 'Removable') { $script:SrcOnUsb = $true }
if ($script:SrcOnUsb) { $ui.bPrep.Visibility = 'Collapsed' }

function Get-UsbSticks {
    $res = @()
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
        try {
            $dl = ([string]$v.DriveLetter).ToUpper()
            $disk = Get-Partition -DriveLetter $dl -ErrorAction Stop | Get-Disk -ErrorAction Stop
            if ([string]$disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem -or [int]$disk.Number -eq $script:SrcDisk) { continue }
            $res += [pscustomobject]@{
                Letter = $dl; Disk = [int]$disk.Number
                Text   = ('{0}:  {1,-12} {2,-6} {3,6:N1} GB   {4}' -f $dl, $(if ($v.FileSystemLabel) { $v.FileSystemLabel } else { '(ohne Name)' }), $v.FileSystem, ($v.Size / 1GB), $disk.FriendlyName)
            }
        } catch { }
    }
    return $res
}

function Show-PrepSticks {
    [xml]$px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot - Sticks vorbereiten" Width="720" Height="560" WindowStartupLocation="CenterOwner" FontSize="13">
  <DockPanel Margin="12">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="Firebrick" FontWeight="SemiBold" Margin="0,0,0,8"
      Text="ACHTUNG: Die gewaehlten USB-Sticks werden FORMATIERT - alle Daten darauf gehen verloren. Interne Laufwerke und der Quell-Datentraeger werden nie angezeigt."/>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock Text="Name:" VerticalAlignment="Center"/>
      <TextBox x:Name="tLabel" Width="120" Margin="6,0,0,0" MaxLength="11" ToolTip="Laufwerksname (max. 11 Zeichen, keine Sonderzeichen)."/>
      <TextBlock Text="Dateisystem:" VerticalAlignment="Center" Margin="16,0,0,0"/>
      <ComboBox x:Name="cFs" Width="90" Margin="6,0,0,0" ToolTip="NTFS empfohlen. FAT32 nur bis 32 GB."/>
      <Button x:Name="bScan" Content="Neu einlesen" Padding="8,2" Margin="16,0,0,0" ToolTip="Sticks tauschen, dann neu einlesen."/>
      <Button x:Name="bAll" Content="Alle waehlen" Padding="8,2" Margin="6,0,0,0"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bGo" Content="Gewaehlte formatieren + befuellen" Padding="10,4" FontWeight="SemiBold"/>
      <Button x:Name="bClose" Content="Schliessen" Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox x:Name="tPLog" DockPanel.Dock="Bottom" Height="150" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
    <ListBox x:Name="lSticks" SelectionMode="Multiple" FontFamily="Consolas"/>
  </DockPanel>
</Window>
'@
    $pw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $px))
    $pw.Owner = $win
    if ($win.Icon) { $pw.Icon = $win.Icon }
    $g = @{}; foreach ($n in 'tLabel','cFs','bScan','bAll','bGo','bClose','tPLog','lSticks') { $g[$n] = $pw.FindName($n) }
    foreach ($f in 'NTFS', 'exFAT', 'FAT32') { [void]$g.cFs.Items.Add($f) }
    $g.cFs.SelectedIndex = 0
    $g.tLabel.Text = 'HUPILOT'
    $script:PrepList = @()
    $plog = { param($m) $g.tPLog.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $m + "`r`n"); $g.tPLog.ScrollToEnd(); $pw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
    $scan = {
        $g.lSticks.Items.Clear()
        $script:PrepList = @(Get-UsbSticks)
        foreach ($st in $script:PrepList) { [void]$g.lSticks.Items.Add($st.Text) }
        & $plog ('' + $script:PrepList.Count + ' USB-Stick(s) gefunden')
    }
    $g.bScan.Add_Click($scan)
    $g.bAll.Add_Click({ $g.lSticks.SelectAll() })
    $g.bClose.Add_Click({ $pw.Close() })
    $g.bGo.Add_Click({
        $sel = @(); foreach ($i in @($g.lSticks.SelectedItems)) { $sel += @($script:PrepList | Where-Object { $_.Text -eq [string]$i }) }
        if (-not $sel.Count) { & $plog 'Keinen Stick gewaehlt (anklicken).'; return }
        $label = $g.tLabel.Text.Trim(); $fs = [string]$g.cFs.SelectedItem
        if ($label -notmatch '^[A-Za-z0-9_-]{1,11}$') { & $plog 'Name ungueltig (1-11 Zeichen: Buchstaben, Ziffern, - _)'; return }
        if (-not (Save-Cfg)) { & $plog 'Config nicht gespeichert - siehe Hauptfenster'; return }
        if (-not (Test-Path $srcPkg)) { & $plog 'Hinweis: kein WLAN-Paket in der Quelle (3. WLAN-Paket bauen)' }
        $list = ($sel | ForEach-Object { '   ' + $_.Text }) -join "`r`n"
        $q = [System.Windows.MessageBox]::Show($pw, ('Diese Sticks werden FORMATIERT (' + $fs + ', Name ' + $label + ') - alle Daten gehen verloren:' + "`r`n`r`n" + $list + "`r`n`r`nFortfahren?"), 'HUPilot - Sticks formatieren', 'YesNo', 'Warning')
        if ($q -ne 'Yes') { return }
        $ok = 0
        foreach ($st in $sel) {
            $dl = $st.Letter
            try {
                # Sicherheitscheck direkt vor dem Formatieren erneut
                $disk = Get-Partition -DriveLetter $dl -ErrorAction Stop | Get-Disk -ErrorAction Stop
                if ([string]$disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem -or [int]$disk.Number -eq $script:SrcDisk) { throw 'kein reiner USB-Stick mehr - uebersprungen' }
                if ($fs -eq 'FAT32' -and (Get-Volume -DriveLetter $dl).Size -gt 32GB) { throw 'FAT32 nur bis 32 GB - NTFS waehlen' }
                & $plog ($dl + ': formatiere ...')
                Format-Volume -DriveLetter $dl -FileSystem $fs -NewFileSystemLabel $label -Force -Confirm:$false -ErrorAction Stop | Out-Null
                & $plog ($dl + ': kopiere HUPilot ...')
                if (Copy-ToStick ($dl + ':')) { & $plog ($dl + ': OK - fertig, abziehen'); $ok++ } else { & $plog ($dl + ': FEHLER beim Kopieren') }
            } catch { & $plog ($dl + ': FEHLER ' + $_.Exception.Message) }
        }
        & $plog ('Fertig: ' + $ok + ' von ' + $sel.Count + ' Stick(s). Naechste Sticks anstecken -> Neu einlesen.')
        Out-Log ('Sticks vorbereitet: ' + $ok + ' von ' + $sel.Count)
        & $scan
    })
    & $scan
    [void]$pw.ShowDialog()
    Update-Drives
}
$ui.bPrep.Add_Click({ Show-PrepSticks })

# ---------- Online-Versionserkennung + Update (oeffentliches GitHub-Repo, kein Token) ----------
$script:GhRepo    = 'ChiliApple/HUPilot'
$script:UpdRemote = ''
function Get-GhText([string]$Path) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $u = 'https://api.github.com/repos/' + $script:GhRepo + '/contents/' + (($Path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') + '?ref=main'
    $r = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $u -Headers @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HUPilot-Setup' } -UseBasicParsing -TimeoutSec 10
    if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($r.Content) }
    return [string]$r.Content
}
function Get-GitBlobSha([string]$File) {
    $b = [System.IO.File]::ReadAllBytes($File)
    $h = [System.Text.Encoding]::ASCII.GetBytes('blob ' + $b.Length + [char]0)
    $all = New-Object byte[] ($h.Length + $b.Length)
    [Array]::Copy($h, 0, $all, 0, $h.Length); [Array]::Copy($b, 0, $all, $h.Length, $b.Length)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    return (($sha.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Invoke-UpdateCheck {
    $ui.bUpd.Content = 'Pruefe ...'
    $win.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    try {
        $t = Get-GhText 'Stick/HUPilot/Setup/HUPilot-Setup.ps1'
        if ($t -notmatch "\`$SetupVer\s*=\s*'([^']+)'") { throw 'Version im Repo nicht gefunden' }
        $rv = $Matches[1]
        if ([version]$rv -gt [version]$SetupVer) {
            $script:UpdRemote = $rv
            $ui.bUpd.Content = 'Update v' + $rv
            $ui.bUpd.Background = [System.Windows.Media.Brushes]::Gold
            Out-Log ('NEUE VERSION v' + $rv + ' verfuegbar (installiert: v' + $SetupVer + ') - Knopf "Update" klicken')
        } else {
            $script:UpdRemote = ''
            $ui.bUpd.Content = 'Aktuell v' + $SetupVer
            $ui.bUpd.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
        }
    } catch {
        $ui.bUpd.Content = 'Update: offline'
        Out-Log ('Versionspruefung nicht moeglich: ' + $_.Exception.Message)
    }
}
function Invoke-Update {
    $q = [System.Windows.MessageBox]::Show(('HUPilot auf v' + $script:UpdRemote + ' aktualisieren?' + "`r`n`r`n" + 'Ziel: ' + $srcStick + "`r`n" + 'config.json, WLAN-Paket und logs bleiben unveraendert.' + "`r`n" + 'Das Setup startet danach neu.'), 'HUPilot - Update', 'YesNo', 'Question')
    if ($q -ne 'Yes') { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $hJ = @{ Accept = 'application/vnd.github.v3+json'; 'User-Agent' = 'HUPilot-Setup' }
        $tree = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $script:GhRepo + '/git/trees/main?recursive=1') -Headers $hJ -TimeoutSec 15
        $files = @($tree.tree | Where-Object { $_.type -eq 'blob' -and $_.path -like 'Stick/*' })
        if (-not $files.Count) { throw 'keine Dateien im Repo gefunden' }
        $n = 0; $same = 0
        foreach ($f in $files) {
            $rel = $f.path.Substring(6)
            $dst = Join-Path $srcStick ($rel -replace '/', '\')
            if ((Test-Path $dst) -and ((Get-GitBlobSha $dst) -eq $f.sha)) { $same++; continue }
            $dir = Split-Path $dst -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $tmp = $dst + '.new'
            $u = 'https://api.github.com/repos/' + $script:GhRepo + '/contents/' + (($f.path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') + '?ref=main'
            Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $u -Headers @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HUPilot-Setup' } -UseBasicParsing -TimeoutSec 30 -OutFile $tmp
            if ((Get-GitBlobSha $tmp) -ne $f.sha) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw ('Pruefsumme falsch: ' + $rel) }
            Move-Item -LiteralPath $tmp -Destination $dst -Force
            Out-Log ('  aktualisiert: ' + $rel); $n++
        }
        Out-Log ('Update fertig: ' + $n + ' Datei(en) neu, ' + $same + ' unveraendert')
    } catch { Out-Log ('FEHLER Update: ' + $_.Exception.Message); return }
    try { $script:Mutex.ReleaseMutex() } catch { }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'HUPilot-Setup.ps1') + '"'))
    $win.Close()
}
$ui.bUpd.Add_Click({ if ($script:UpdRemote) { Invoke-Update } else { Invoke-UpdateCheck } })
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
        $ui.tAdmName.Text = [string]$c.AdminName; $ui.tAdmPw.Text = [string]$c.AdminPassword; $ui.cAskUser.IsChecked = ($c.AskUser -eq $true)
        $script:Extra = @{}
        foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -notin 'Tenant','TenantId','ClientId','ClientSecret','GroupTag','TagChoices','WlanSsid','WlanKey','AdminName','AdminPassword','AskUser') { $script:Extra[$pr.Name] = $pr.Value } }
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

function Format-Rest([TimeSpan]$Span) {
    if ($Span.TotalSeconds -le 0) { return 'abgelaufen' }
    $d = [int][Math]::Floor($Span.TotalDays)
    return ('noch ' + $(if ($d) { '' + $d + ' Tag' + $(if ($d -ne 1) { 'e' } else { '' }) + ' ' } else { '' }) + $Span.Hours + ' Std')
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
            $span = $end - (Get-Date)
            $days = $span.TotalDays
            if ($null -eq $minDays -or $days -lt $minDays) { $minDays = $days; $minEnd = $end }
            $txt = 'Secret "' + $pc.displayName + '" (' + $pc.hint + '...) gueltig bis ' + $end.ToString('dd.MM.yyyy HH:mm') + '  -> ' + (Format-Rest $span)
            if ($days -lt 0) { $txt = 'ACHTUNG ABGELAUFEN: ' + $txt } elseif ($days -lt 1) { $txt = 'ACHTUNG BALD ABGELAUFEN: ' + $txt }
            Out-Log $txt
        }
        if (-not $mine.Count) { Out-Log '  (verwendetes Secret nicht eindeutig erkannt - alle Secrets der App angezeigt)' }
        if ($mine.Count -and $null -ne $minDays) {
            Set-SubSecret ('Secret gueltig bis ' + $minEnd.ToString('dd.MM.yyyy HH:mm') + ' (' + (Format-Rest ($minEnd - (Get-Date))) + ')') ($minDays -lt 1)
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

function Copy-ToStick([string]$dr) {
    try {
        foreach ($f in 'go.cmd', 'HUPilot-Setup.cmd') { $sf = Join-Path $srcStick $f; if (Test-Path $sf) { Copy-Item -Path $sf -Destination (Join-Path $dr $f) -Force -ErrorAction Stop } }
        $dst = Join-Path $dr 'HUPilot'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        foreach ($it in @(Get-ChildItem -Path $srcHU -Force | Where-Object { $_.Name -ne 'logs' -and -not $_.Name.StartsWith('_') })) {
            Copy-Item -Path $it.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
        }
        Out-Log ('Auf Stick kopiert: ' + $srcStick + ' -> ' + $dr + '\  (ohne logs und _Ordner)')
        $rootPkg = @(Get-ChildItem -Path ($dr + '\') -Filter *.ppkg -File -ErrorAction SilentlyContinue)
        if ($rootPkg.Count) { Out-Log ('ACHTUNG: .ppkg im Hauptverzeichnis entfernen (wird sonst im OOBE angewendet): ' + (($rootPkg | ForEach-Object { $_.Name }) -join ', ')) }
        return ((Test-Path (Join-Path $dr 'go.cmd')) -and (Test-Path (Join-Path $dr 'HUPilot\go.ps1')) -and (Test-Path (Join-Path $dr 'HUPilot\config.json')))
    } catch { Out-Log ('FEHLER kopieren ' + $dr + ': ' + $_.Exception.Message); return $false }
}
$ui.bCopy.Add_Click({
    $dr = Get-Drive; if (-not $dr) { Out-Log 'Kein Ziel-Stick gewaehlt'; return }
    if (-not (Save-Cfg)) { return }
    if (-not (Test-Path $srcPkg)) { Out-Log 'ACHTUNG: kein HUPilot-WLAN.ppkg in der Quelle - erst 3. WLAN-Paket bauen (oder "WlanPackage": "")' }
    [void](Copy-ToStick $dr)
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
        if ($c.AdminName) {
            # Optional: lokaler Admin per ProvisioningCommands (Geraetekontext, laeuft als SYSTEM - auch nach jedem Zuruecksetzen)
            $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
            $body = @(
                '# HUPilot: lokaler Admin (aus dem WLAN-Paket, laeuft als SYSTEM)',
                ('$n = ' + (& $q $c.AdminName)),
                ('$pw = ' + (& $q $c.AdminPassword)),
                '$log = Join-Path $env:SystemRoot ''Temp\HUPilot-Admin.log''',
                'function L([string]$m) { try { Add-Content -Path $log -Value ((Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') + ''  '' + $m) -Encoding UTF8 } catch { } }',
                'try {',
                '    $sec = ConvertTo-SecureString -String $pw -AsPlainText -Force',
                '    $u = Get-LocalUser -Name $n -ErrorAction SilentlyContinue',
                '    if ($u) { Set-LocalUser -Name $n -Password $sec -PasswordNeverExpires $true -AccountNeverExpires -ErrorAction Stop; Enable-LocalUser -Name $n -ErrorAction Stop; L (''Konto aktualisiert: '' + $n) }',
                '    else { New-LocalUser -Name $n -Password $sec -PasswordNeverExpires -AccountNeverExpires -Description ''HUPilot lokaler Admin'' -ErrorAction Stop | Out-Null; L (''Konto angelegt: '' + $n) }',
                '    $sid = (Get-LocalUser -Name $n).SID.Value',
                '    try { Add-LocalGroupMember -SID ''S-1-5-32-544'' -Member $sid -ErrorAction Stop; L ''zu Administratoren hinzugefuegt'' }',
                '    catch { if ($_.FullyQualifiedErrorId -like ''*MemberExists*'') { L ''bereits Administrator'' } else { throw } }',
                '} catch { L (''FEHLER: '' + $_.Exception.Message) }'
            ) -join "`r`n"
            # Ohne CommandFiles (ICD-Fehler beim Asset): Script als -EncodedCommand direkt in der CommandLine
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($body))
            $cl = 'cmd /c "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $b64
            $pc = '<ProvisioningCommands><DeviceContext><CommandLine>' + $cl + '</CommandLine></DeviceContext></ProvisioningCommands>'
            $x = $x.Replace('</Common>', $pc + '</Common>')
            $x = [regex]::Replace($x, '<Notes>.*?</Notes>', '<Notes>HUPilot: WLAN + lokaler Admin. KEIN Zuruecksetzen-Befehl im Paket.</Notes>')
            Out-Log ('Paket enthaelt lokalen Admin: ' + $c.AdminName)
        }
        $xmlPath = Join-Path $work 'customizations.xml'
        [System.IO.File]::WriteAllText($xmlPath, $x.TrimStart([char]0xFEFF), $enc)   # ohne BOM
        $ppkg = $srcPkg
        $cstore = Join-Path (Split-Path $icd -Parent) 'Microsoft-Common-Provisioning.dat'
        $stores = @($cstore)
        if ($c.AdminName) {
            # ProvisioningCommands gibt es nur im Desktop-Speicher (Common kennt sie nicht)
            $dstore = Join-Path (Split-Path $icd -Parent) 'Microsoft-Desktop-Provisioning.dat'
            if (-not (Test-Path $dstore)) { Out-Log ('FEHLER: ' + $dstore + ' fehlt - ADK-Feature "Imaging and Configuration Designer" vollstaendig installieren'); return }
            $stores = @(($cstore + ',' + $dstore), $dstore)
        }
        $okBuild = $false
        foreach ($store in $stores) {
            $icdArgs = @('/Build-ProvisioningPackage', ('/CustomizationXML:"' + $xmlPath + '"'), ('/PackagePath:"' + $ppkg + '"'), ('/StoreFile:"' + $store + '"'), '+Overwrite')
            Out-Log ('ICD.exe baut das Paket (' + ((@($store -split ',') | ForEach-Object { (Split-Path $_ -Leaf) -replace '-Provisioning\.dat$', '' }) -join ' + ') + ') ...')
            $outF = Join-Path $work 'icd-out.txt'; $errF = Join-Path $work 'icd-err.txt'
            $p = Start-Process -FilePath $icd -ArgumentList $icdArgs -Wait -PassThru -NoNewWindow -WorkingDirectory $work -RedirectStandardOutput $outF -RedirectStandardError $errF
            if ($p.ExitCode -eq 0 -and (Test-Path $ppkg)) { Out-Log ('WLAN-Paket OK: ' + $ppkg + ' (' + (Get-Item $ppkg).Length + ' Bytes)'); $okBuild = $true; break }
            Out-Log ('FEHLER: ICD.exe Exitcode ' + $p.ExitCode)
            $lines = @()
            foreach ($f in @($outF, $errF)) { if (Test-Path $f) { $lines += @(Get-Content -Path $f -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) } }
            foreach ($ln in @($lines | Select-Object -Last 30)) {
                foreach ($sec in @($c.WlanKey, $c.AdminPassword)) { if ($sec) { $ln = $ln.Replace($sec, '***') } }
                Out-Log ('  ' + $ln)
            }
            if (-not $lines.Count) { Out-Log '  (ICD.exe hat keine Ausgabe geliefert)' }
        }
        if (-not $okBuild) { Out-Log 'WLAN-Paket NICHT gebaut - das bisherige Paket (falls vorhanden) bleibt unveraendert.' }
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
      <Button x:Name="bReload" Content="Aktualisieren" Padding="10,2" Margin="14,0,0,0" ToolTip="Alle Daten neu aus Autopilot/Intune laden"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bCsv" Content="CSV speichern" Padding="10,4"/>
      <Button x:Name="bPrint" Content="Drucken" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bClose" Content="Schliessen" Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <DataGrid x:Name="dGrid" ToolTip="Doppelklick = Details (Profil live nachladen)" AutoGenerateColumns="True" IsReadOnly="True" CanUserSortColumns="True" AlternatingRowBackground="#F3F3F3" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
    $sw.Owner = $win
    if ($win.Icon) { $sw.Icon = $win.Icon }
    $g = @{}; foreach ($n in 'cTag','cProto','tFind','tCount','bCsv','bPrint','bClose','dGrid','bReload') { $g[$n] = $sw.FindName($n) }
    $script:SRows = @($Rows)
    $fillTags = {
        $keep = [string]$g.cTag.SelectedItem
        $g.cTag.Items.Clear(); [void]$g.cTag.Items.Add('Alle')
        foreach ($t in @($script:SRows | ForEach-Object { $_.Tag } | Where-Object { $_ } | Sort-Object -Unique)) { [void]$g.cTag.Items.Add($t) }
        if ($keep -and $g.cTag.Items.Contains($keep)) { $g.cTag.SelectedItem = $keep } else { $g.cTag.SelectedIndex = 0 }
    }
    & $fillTags
    $g.cProto.IsChecked = ($Proto.Count -gt 0)
    $g.cProto.IsEnabled = ($Proto.Count -gt 0)
    $script:StatusView = @()
    $refresh = {
        $v = @($script:SRows)
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
    $g.bReload.Add_Click({
        $g.bReload.IsEnabled = $false; $g.tCount.Text = 'lade ...'
        $sw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
        $d = Get-StatusData
        if ($d) { $script:SRows = @($d.Rows); & $fillTags }
        & $refresh
        $g.bReload.IsEnabled = $true
    })
    $g.dGrid.Add_MouseDoubleClick({
        $it = $g.dGrid.SelectedItem; if (-not $it) { return }
        $id = $script:ApIds[[string]$it.Seriennr]; if (-not $id) { return }
        $tok = Get-ApiToken; if (-not $tok) { return }
        try {
            $d = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ('https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/' + $id + '?$expand=deploymentProfile') -Headers @{ Authorization = 'Bearer ' + $tok }
            $fmt = { param($v) try { $t = [datetime]$v; if ($t.Year -gt 2000) { $t.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } else { '-' } } catch { '-' } }
            $txt = @(
                ('Seriennummer:      ' + $d.serialNumber),
                ('Group Tag:         ' + $d.groupTag),
                ('Profilstatus:      ' + $d.deploymentProfileAssignmentStatus),
                ('Profil:            ' + $(if ($d.deploymentProfile) { $d.deploymentProfile.displayName } else { '-' })),
                ('Profil zugewiesen: ' + (& $fmt $d.deploymentProfileAssignedDateTime)),
                ('Intune:            ' + $d.enrollmentState),
                ('Letzter Kontakt:   ' + (& $fmt $d.lastContactedDateTime)),
                ('Benutzer:          ' + $it.Benutzer),
                ('Name:              ' + $it.Name),
                ('Modell:            ' + $d.manufacturer + ' ' + $d.model),
                ('HUPilot:           ' + $it.HUPilot)
            ) -join "`r`n"
            [void][System.Windows.MessageBox]::Show($sw, $txt, ('Details ' + $d.serialNumber), 'OK', 'Information')
        } catch { Out-Log ('Details ' + $it.Seriennr + ': ' + $_.Exception.Message) }
    })
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

function Get-StatusData {
    $tok = Get-ApiToken; if (-not $tok) { return $null }
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
    } catch { Out-Log ('FEHLER Autopilot-Liste: ' + $_.Exception.Message); return $null }
    # Optional: Intune-Geraete (Primaerer Benutzer, Geraetename, letzter Sync) - braucht DeviceManagementManagedDevices.Read.All
    $md = @{}
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,serialNumber,deviceName,userPrincipalName,lastSyncDateTime,enrolledDateTime&`$top=999"
        while ($uri) {
            $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri $uri -Headers $h
            foreach ($m in @($r.value)) { if ($m.serialNumber) { $md[[string]$m.id] = $m; $md['SN:' + [string]$m.serialNumber] = $m } }
            $uri = $r.'@odata.nextLink'
        }
        Out-Log ('Intune-Geraete gelesen: ' + @($md.Keys | Where-Object { $_ -like 'SN:*' }).Count)
    } catch { Out-Log 'Primaerer Benutzer nicht lesbar (optional: Anwendungsberechtigung DeviceManagementManagedDevices.Read.All fuer HUPilot-Upload)' }
    $proto = Read-Protokoll
    $mapE = @{ enrolled = 'registriert'; notContacted = 'noch nicht'; failed = 'Fehler'; pendingReset = 'Reset ausstehend'; blocked = 'blockiert'; unknown = 'unbekannt' }
    $script:ApIds = @{}
    foreach ($d in $all) { if ($d.serialNumber) { $script:ApIds[[string]$d.serialNumber] = [string]$d.id } }
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
        $sync = ''; $reg = ''
        if ($im) { try { $sd = [datetime]$im.lastSyncDateTime; if ($sd.Year -gt 2000) { $sync = $sd.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } } catch { } }
        if ($im) { try { $rd = [datetime]$im.enrolledDateTime; if ($rd.Year -gt 2000) { $reg = $rd.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } catch { } }
        [pscustomobject]@{
            Seriennr       = [string]$d.serialNumber
            Tag            = [string]$d.groupTag
            Profil         = $prof
            Intune         = $(if ($mapE.ContainsKey($es)) { $mapE[$es] } else { $es })
            RegDatum       = $reg
            LetzterKontakt = $lc
            Benutzer       = $(if ($im -and $im.userPrincipalName) { [string]$im.userPrincipalName } else { [string]$d.userPrincipalName })
            Name           = $(if ($im) { [string]$im.deviceName } else { [string]$d.displayName })
            LetzterSync    = $sync
            Modell         = [string]$d.model
            HUPilot        = $(if ($pr) { [string]$pr.Zeit + ' ' + [string]$pr.Ergebnis } else { '' })
        }
    }
    # Neueste Intune-Registrierung oben, Geraete ohne Datum unten
    $rows = @(@($rows | Where-Object { $_.RegDatum } | Sort-Object RegDatum -Descending) + @($rows | Where-Object { -not $_.RegDatum }))
    Out-Log ('' + @($rows).Count + ' Autopilot-Geraete, ' + $proto.Count + ' aus protokoll.csv')
    return @{ Rows = $rows; Proto = $proto }
}
$ui.bStatus.Add_Click({
    $d = Get-StatusData; if (-not $d) { return }
    Show-Status -Rows @($d.Rows) -Proto $d.Proto -Tenant ((Get-Cfg).Tenant)
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

# ---------- Gemeinsam: Autopilot-Liste, Tag-Regeln ----------
function Get-ApAll($h) {
    $all = @()
    $uri = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?$top=500'
    while ($uri) {
        $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri $uri -Headers $h
        $all += @($r.value)
        $uri = $r.'@odata.nextLink'
    }
    return $all
}
function Test-RuleTag([string]$Rule, [string]$Tag) {
    if (-not $Rule) { return $false }
    $full = '[OrderID]:' + $Tag
    foreach ($m in [regex]::Matches($Rule, '-(eq|startsWith|contains|match)\s*"(\[OrderID\]:[^"]*)"', 'IgnoreCase')) {
        $op = $m.Groups[1].Value.ToLower(); $v = $m.Groups[2].Value
        if ($op -eq 'eq' -and $full -ieq $v) { return $true }
        if ($op -eq 'startswith' -and $full.StartsWith($v, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($op -eq 'contains' -and $full.IndexOf($v, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        if ($op -eq 'match') { try { if ($full -match $v) { return $true } } catch { } }
    }
    return $false
}
function Show-Grid {
    param([string]$Title, $Rows, [string]$Info)
    [xml]$gx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1000" Height="520" WindowStartupLocation="CenterOwner" FontSize="12">
  <DockPanel Margin="10">
    <TextBlock x:Name="tInfo" DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <Button x:Name="bClose" DockPanel.Dock="Bottom" HorizontalAlignment="Right" Content="Schliessen" Padding="10,4" Margin="0,8,0,0"/>
    <DataGrid x:Name="dGrid" AutoGenerateColumns="True" IsReadOnly="True" AlternatingRowBackground="#F3F3F3" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $gw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $gx))
    $gw.Owner = $win; $gw.Title = $Title
    if ($win.Icon) { $gw.Icon = $win.Icon }
    $gw.FindName('tInfo').Text = $Info
    $gw.FindName('dGrid').ItemsSource = @($Rows)
    $gw.FindName('bClose').Add_Click({ $gw.Close() })
    [void]$gw.ShowDialog()
}

# ---------- 6. Tags pruefen ----------
$ui.bTags.Add_Click({
    $tok = Get-ApiToken; if (-not $tok) { return }
    $h = @{ Authorization = 'Bearer ' + $tok }
    Out-Log 'Lade Profile, Gruppen und Geraete ...'
    $win.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    try { $profs = @((Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments' -Headers $h).value) }
    catch { Out-Log ('FEHLER Profile lesen: ' + $_.Exception.Message); return }
    $gcache = @{}; $gErr = $false; $targets = @()
    foreach ($p in $profs) {
        foreach ($a in @($p.assignments)) {
            $ty = [string]$a.target.'@odata.type'
            if ($ty -like '*allDevicesAssignmentTarget') { $targets += [pscustomobject]@{ Profil = [string]$p.displayName; Gruppe = 'Alle Geraete'; Rule = '*' }; continue }
            if ($ty -notlike '*.groupAssignmentTarget') { continue }
            $gid = [string]$a.target.groupId
            if (-not $gcache.ContainsKey($gid)) {
                try { $gcache[$gid] = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ('https://graph.microsoft.com/v1.0/groups/' + $gid + '?$select=displayName,membershipRule') -Headers $h }
                catch {
                    $em = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $em = $_.ErrorDetails.Message }
                    if ($em -match 'Authorization_RequestDenied|Forbidden|403|Insufficient privileges') { $gErr = $true; $gcache[$gid] = [pscustomobject]@{ displayName = $gid; membershipRule = '' } }
                    else { Out-Log ('Profil "' + $p.displayName + '" ist einer nicht mehr vorhandenen Gruppe zugewiesen: ' + $gid); $gcache[$gid] = [pscustomobject]@{ displayName = ('(geloescht) ' + $gid); membershipRule = '' } }
                }
            }
            $targets += [pscustomobject]@{ Profil = [string]$p.displayName; Gruppe = [string]$gcache[$gid].displayName; Rule = [string]$gcache[$gid].membershipRule }
        }
    }
    $devs = @(); try { $devs = @(Get-ApAll $h) } catch { Out-Log ('Autopilot-Liste: ' + $_.Exception.Message) }
    $c = Get-Cfg
    $tags = @(@($c.GroupTag) + @($c.TagChoices) + @($devs | ForEach-Object { [string]$_.groupTag }) | Where-Object { $_ } | Sort-Object -Unique)
    $rows = foreach ($t in $tags) {
        $m = @($targets | Where-Object { $_.Rule -eq '*' -or (Test-RuleTag $_.Rule $t) })
        $n = @($devs | Where-Object { [string]$_.groupTag -eq $t }).Count
        [pscustomobject]@{
            Tag       = $t
            AmStick   = $(if ($t -eq $c.GroupTag) { 'Standard' } elseif (@($c.TagChoices) -contains $t) { 'Auswahl' } else { '' })
            Geraete   = $n
            Profil    = (@($m | ForEach-Object { $_.Profil } | Select-Object -Unique) -join ', ')
            Gruppe    = (@($m | ForEach-Object { $_.Gruppe } | Select-Object -Unique) -join ', ')
            Status    = $(if ($m.Count) { 'OK' } elseif ($gErr) { 'unklar (Gruppen nicht lesbar)' } else { 'KEIN PROFIL' })
        }
    }
    $bad = @($rows | Where-Object { $_.Status -eq 'KEIN PROFIL' -and $_.AmStick })
    Out-Log ('Tags: ' + @($rows).Count + ', ohne Profil (am Stick waehlbar): ' + $bad.Count + $(if ($gErr) { '  - Gruppen nicht lesbar: Group.Read.All fuer HUPilot-Upload ergaenzen' } else { '' }))
    $info = 'Je Tag: Geraete in Autopilot, passende dynamische Gruppe ([OrderID]-Regel) und daran zugewiesenes Autopilot-Profil.'
    if ($bad.Count) { $info += '  ACHTUNG: ' + (($bad | ForEach-Object { $_.Tag }) -join ', ') + ' am Stick waehlbar, aber ohne Profil.' }
    if ($gErr) { $info += '  Gruppen nicht lesbar - Anwendungsberechtigung Group.Read.All ergaenzen.' }
    Show-Grid -Title ('HUPilot - Tags  (' + $c.Tenant + ')') -Rows $rows -Info $info
})

# ---------- 7. Offline-Hashes importieren ----------
function Read-HashCsv([string]$File) {
    $out = @()
    foreach ($l in @(Get-Content -Path $File -ErrorAction SilentlyContinue)) {
        if (-not $l -or $l -like 'Device Serial Number*') { continue }
        $p = $l.Split(',')
        if ($p.Count -lt 3 -or -not $p[0] -or -not $p[2]) { continue }
        $out += [pscustomobject]@{ Seriennr = $p[0].Trim(); Tag = $(if ($p.Count -gt 3) { $p[3].Trim() } else { '' }); Benutzer = $(if ($p.Count -gt 4) { $p[4].Trim() } else { '' }); Status = 'offen'; Datei = $File; Hash = $p[2].Trim(); ImpId = ''; Done = $false }
    }
    return $out
}
function Show-HashImport {
    [xml]$hx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot - Hashes importieren" Width="1000" Height="560" WindowStartupLocation="CenterOwner" FontSize="12">
  <DockPanel Margin="10">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8" Text="Offline gespeicherte Hashes (HUPilot\logs\hashes.csv aus Quelle und Ziel-Stick). Schon vorhandene Geraete bekommen nur den Tag. Erledigte Zeilen wandern nach hashes-erledigt.csv."/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bAdd" Content="CSV hinzufuegen ..." Padding="10,4"/>
      <Button x:Name="bImp" Content="Importieren" FontWeight="SemiBold" Padding="10,4" Margin="8,0,0,0"/>
      <Button x:Name="bClose" Content="Schliessen" Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox x:Name="tHLog" DockPanel.Dock="Bottom" Height="110" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas"/>
    <DataGrid x:Name="dGrid" AutoGenerateColumns="False" IsReadOnly="True" AlternatingRowBackground="#F3F3F3" HeadersVisibility="Column">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Seriennr" Binding="{Binding Seriennr}"/>
        <DataGridTextColumn Header="Tag" Binding="{Binding Tag}"/>
        <DataGridTextColumn Header="Benutzer" Binding="{Binding Benutzer}"/>
        <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="260"/>
        <DataGridTextColumn Header="Datei" Binding="{Binding Datei}" Width="*"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@
    $hw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $hx))
    $hw.Owner = $win
    if ($win.Icon) { $hw.Icon = $win.Icon }
    $g = @{}; foreach ($n in 'bAdd','bImp','bClose','tHLog','dGrid') { $g[$n] = $hw.FindName($n) }
    $script:HRows = @()
    $hlog = { param($m) $g.tHLog.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $m + "`r`n"); $g.tHLog.ScrollToEnd(); $hw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
    $refresh = { $g.dGrid.ItemsSource = $null; $g.dGrid.ItemsSource = @($script:HRows); $hw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
    $addFile = {
        param($f)
        if (-not (Test-Path $f)) { return }
        $new = @(Read-HashCsv $f)
        foreach ($r in $new) { $script:HRows = @($script:HRows | Where-Object { $_.Seriennr -ne $r.Seriennr }) + $r }
        & $hlog ('' + $new.Count + ' Hash(es) aus ' + $f)
    }
    & $addFile (Join-Path $srcHU 'logs\hashes.csv')
    $dr = Get-Drive; if ($dr) { & $addFile (Join-Path $dr 'HUPilot\logs\hashes.csv') }
    & $refresh
    $g.bClose.Add_Click({ $hw.Close() })
    $g.bAdd.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'CSV (*.csv)|*.csv'; $dlg.Multiselect = $true
        if ($dlg.ShowDialog()) { foreach ($f in $dlg.FileNames) { & $addFile $f }; & $refresh }
    })
    $g.bImp.Add_Click({
        $todo = @($script:HRows | Where-Object { -not $_.Done })
        if (-not $todo.Count) { & $hlog 'Nichts zu importieren.'; return }
        $tok = Get-ApiToken; if (-not $tok) { & $hlog 'Anmeldung fehlgeschlagen - siehe Hauptfenster'; return }
        $h  = @{ Authorization = 'Bearer ' + $tok }
        $hj = @{ Authorization = 'Bearer ' + $tok; 'Content-Type' = 'application/json' }
        $GB = 'https://graph.microsoft.com/beta/deviceManagement'
        $c = Get-Cfg
        foreach ($r in $todo) {
            if (-not $r.Tag) { $r.Tag = $c.GroupTag }
            try {
                $f = [uri]::EscapeDataString("contains(serialNumber,'" + $r.Seriennr + "')")
                $ex = @(@((Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ($GB + '/windowsAutopilotDeviceIdentities?$filter=' + $f) -Headers $h).value) | Where-Object { $_.serialNumber -eq $r.Seriennr })[0]
                if ($ex) {
                    if ([string]$ex.groupTag -ne $r.Tag) { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/windowsAutopilotDeviceIdentities/' + $ex.id + '/updateDeviceProperties') -Headers $hj -Body (@{ groupTag = $r.Tag } | ConvertTo-Json) | Out-Null; $r.Status = 'war vorhanden - Tag gesetzt' }
                    else { $r.Status = 'war vorhanden (Tag passt)' }
                    if ($r.Benutzer) { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/windowsAutopilotDeviceIdentities/' + $ex.id + '/assignUserToDevice') -Headers $hj -Body (@{ userPrincipalName = $r.Benutzer; addressableUserName = $r.Benutzer.Split('@')[0] } | ConvertTo-Json) | Out-Null; $r.Status += ', Benutzer zugewiesen' }
                    $r.Done = $true
                } else {
                    $body = @{
                        '@odata.type' = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
                        serialNumber = $r.Seriennr; productKey = ''; groupTag = $r.Tag; hardwareIdentifier = $r.Hash
                        state = @{ '@odata.type' = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'; deviceImportStatus = 'pending'; deviceRegistrationId = ''; deviceErrorCode = 0; deviceErrorName = '' }
                    }
                    if ($r.Benutzer) { $body.assignedUserPrincipalName = $r.Benutzer }
                    $imp = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/importedWindowsAutopilotDeviceIdentities') -Headers $hj -Body ($body | ConvertTo-Json -Depth 4)
                    $r.ImpId = [string]$imp.id; $r.Status = 'Import laeuft ...'
                }
            } catch { $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }; $r.Status = 'FEHLER: ' + $m }
            & $hlog ($r.Seriennr + ': ' + $r.Status)
        }
        & $refresh
        $limit = (Get-Date).AddMinutes(15)
        while (@($script:HRows | Where-Object { $_.ImpId -and -not $_.Done -and $_.Status -like 'Import*' }).Count -and (Get-Date) -lt $limit) {
            for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 1000; $hw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
            foreach ($r in @($script:HRows | Where-Object { $_.ImpId -and -not $_.Done -and $_.Status -like 'Import*' })) {
                try {
                    $st = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ($GB + '/importedWindowsAutopilotDeviceIdentities/' + $r.ImpId) -Headers $h
                    $s2 = [string]$st.state.deviceImportStatus
                    if ($s2 -eq 'complete') { $r.Status = 'OK - importiert'; $r.Done = $true }
                    elseif ($s2 -eq 'error') { $r.Status = 'FEHLER: ' + [string]$st.state.deviceErrorName + ' (' + [string]$st.state.deviceErrorCode + ')' }
                    if ($s2 -in 'complete', 'error') {
                        try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/importedWindowsAutopilotDeviceIdentities/' + $r.ImpId) -Headers $h | Out-Null } catch { }
                        & $hlog ($r.Seriennr + ': ' + $r.Status)
                    }
                } catch { }
            }
            & $refresh
        }
        foreach ($r in @($script:HRows | Where-Object { -not $_.Done -and $_.Status -like 'Import*' })) { $r.Status = 'Import nach 15 Min nicht fertig - spaeter nochmal' }
        try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ($GB + '/windowsAutopilotSettings/sync') -Headers $h | Out-Null } catch { }
        # Erledigte Zeilen aus den Dateien nehmen und nach hashes-erledigt.csv verschieben
        foreach ($f in @($script:HRows | ForEach-Object { $_.Datei } | Select-Object -Unique)) {
            try {
                $done = @($script:HRows | Where-Object { $_.Done -and $_.Datei -eq $f } | ForEach-Object { $_.Seriennr })
                if (-not $done.Count) { continue }
                $lines = @(Get-Content -Path $f)
                $keep = @($lines | Where-Object { $sn = $_.Split(',')[0]; -not ($done -contains $sn) })
                $moved = @($lines | Where-Object { $sn = $_.Split(',')[0]; $done -contains $sn })
                $erl = Join-Path (Split-Path $f -Parent) 'hashes-erledigt.csv'
                if (-not (Test-Path $erl)) { Set-Content -Path $erl -Value 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User' -Encoding ASCII }
                Add-Content -Path $erl -Value $moved -Encoding ASCII
                Set-Content -Path $f -Value $keep -Encoding ASCII
                & $hlog ('' + $moved.Count + ' erledigt -> ' + $erl)
            } catch { & $hlog ('Datei ' + $f + ': ' + $_.Exception.Message) }
        }
        & $refresh
        $ok = @($script:HRows | Where-Object { $_.Done }).Count
        & $hlog ('Fertig: ' + $ok + ' von ' + @($script:HRows).Count + ' erledigt.')
        Out-Log ('Hashes importiert: ' + $ok + ' von ' + @($script:HRows).Count)
    })
    [void]$hw.ShowDialog()
}
$ui.bHash.Add_Click({ Show-HashImport })
$win.Add_ContentRendered({ Invoke-UpdateCheck })
[void]$win.ShowDialog()
Start-Log 'Fenster geschlossen'
try { $script:Mutex.ReleaseMutex() } catch { }
