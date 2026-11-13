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
    Update: Knopf oben rechts -> Pull.ps1 (GitHub-Release, Pruefsumme + Signatur). Version: HUPilot\Config\version.json
    -SmokeTest <Datei>: nur Fenster oeffnen, 2 s laufen lassen, schliessen, Ergebnis in <Datei> (automatische Tests)
#>
param([string]$SmokeTest = '')
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
        Start-Log 'UAC bestätigt, Admin-Prozess gestartet'
    } catch {
        Start-Log ('UAC abgelehnt/Fehler: ' + $_.Exception.Message)
        try { Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show('HUPilot-Setup braucht Administratorrechte (für ICD.exe).' + [Environment]::NewLine + $_.Exception.Message, 'HUPilot-Setup') } catch { }
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Start-Log 'als Admin gestartet'
# Fehler sichtbar machen (Fenster laeuft ohne Konsole)
trap {
    $msg = ($_ | Out-String)
    try { Set-Content -Path (Join-Path $env:PUBLIC 'HUPilot-Setup-Fehler.txt') -Value $msg -Encoding UTF8 } catch { }
    if ($SmokeTest) { try { Set-Content -LiteralPath $SmokeTest -Value ('FEHLER: ' + $msg) -Encoding UTF8 } catch { } }
    else { try { [void][System.Windows.MessageBox]::Show($msg, 'HUPilot-Setup - Fehler') } catch { } }
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
$CfgDirHU = Join-Path $srcHU 'Config'
# Version: massgeblich ist HUPilot\Config\version.json - die Zeile darunter nur fuer die Update-Pruefung bis v2.1
$SetupVer = '2.7.17'
try { $vj = Get-Content -LiteralPath (Join-Path $CfgDirHU 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json; if ("$($vj.version)".Trim()) { $SetupVer = "$($vj.version)".Trim() } } catch { }
# Nur eine Instanz je Ablage (Stick bzw. Ordner)
$mxName = 'Local\HUPilot-Setup_' + ((([System.Security.Cryptography.SHA1]::Create()).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($srcStick.ToLower())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }) -join '')
$script:Mutex = New-Object System.Threading.Mutex($false, $mxName)
if (-not $script:Mutex.WaitOne(0)) {
    Start-Log 'läuft bereits -> Ende'
    [void][System.Windows.MessageBox]::Show('HUPilot-Setup läuft bereits für ' + $srcStick + ' (evtl. unsichtbar im Hintergrund).' + [Environment]::NewLine + 'Task-Manager > Details > powershell.exe beenden und neu starten.', 'HUPilot-Setup')
    exit 0
}
# Abgebrochenes Update: nicht mit einem Mischstand starten - Pull.ps1 stellt den bisherigen Stand wieder her
if (Test-Path -LiteralPath (Join-Path $CfgDirHU 'pull-journal.json')) {
    Start-Log 'pull-journal.json vorhanden -> kein Start'
    $q = [System.Windows.MessageBox]::Show('Das letzte Update wurde abgebrochen (HUPilot\Config\pull-journal.json).' + [Environment]::NewLine + [Environment]::NewLine + 'Jetzt Pull.ps1 ausführen? Es stellt den bisherigen Stand wieder her und lädt die Version neu.', 'HUPilot-Setup', 'YesNo', 'Warning')
    try { $script:Mutex.ReleaseMutex() } catch { }
    if ($q -eq 'Yes') { Start-Process -FilePath powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Pull.ps1') + '" -Target "' + $srcStick.TrimEnd('\') + '"') }
    exit 0
}
$srcPkg   = Join-Path $srcHU 'HUPilot-WLAN.ppkg'
$icd      = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe'
$tplXml   = Join-Path $PSScriptRoot 'WCD-Vorlage\HUPilot-WLAN\customizations.xml'
$enc      = New-Object System.Text.UTF8Encoding($false)
$script:Extra = @{}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot-Setup" Width="890" Height="980" MinWidth="640" MinHeight="420" WindowStartupLocation="CenterScreen" FontSize="13" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style x:Key="HuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="4" Background="#FF6A6A6A"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="HuPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton">
        <Border Background="Transparent"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="14"/><Setter Property="MinWidth" Value="14"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Border Background="#18808080" CornerRadius="4"><Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource HuPage}"/></Track.DecreaseRepeatButton>
          <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource HuPage}"/></Track.IncreaseRepeatButton>
          <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="2,0"/></Track.Thumb>
        </Track></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="14"/><Setter Property="MinHeight" Value="14"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Border Background="#18808080" CornerRadius="4"><Track x:Name="PART_Track">
              <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource HuPage}"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource HuPage}"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="0,2"/></Track.Thumb>
            </Track></Border>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="HuMain" TargetType="Button">
      <Setter Property="Background" Value="#FF2E7D32"/><Setter Property="Foreground" Value="White"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF388E3C"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF1B5E20"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="HuLamp" TargetType="Ellipse">
      <Setter Property="Width" Value="10"/><Setter Property="Height" Value="10"/><Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Fill" Value="#FF9E9E9E"/><Setter Property="ToolTip" Value="Stand: offen"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="14">
  <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
      <Button VerticalAlignment="Center" x:Name="bLnk" FontFamily="Segoe MDL2 Assets" Content="&#xE718;" Width="32" Padding="0,5" Margin="0,0,8,0" ToolTip="Desktop-Verknüpfung zu diesem Ordner anlegen (öffentlicher Desktop, mit HUPilot-Symbol)." ToolTipService.ShowDuration="30000"/>
      <Button VerticalAlignment="Center" x:Name="bHelp" ToolTip="Anleitung öffnen (F1)" Content="?" FontWeight="Bold" Width="32" Padding="0,4" Margin="0,0,0,0"/>
      <Button VerticalAlignment="Center" x:Name="bUpd" ToolTip="Prüft auf GitHub, ob es eine neuere HUPilot-Version gibt.&#x0a;Gold = Update verfügbar - Klick aktualisiert die Programmdateien in der Quelle (Stick oder Ordner).&#x0a;config.json, WLAN-Paket und logs bleiben unverändert." ToolTipService.ShowDuration="30000" Content="Update ..." Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <Image x:Name="iLogo" Width="44" Height="44"/>
    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="HUPilot" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock x:Name="tSub" Text="Stick vorbereiten - Windows Autopilot per USB" Foreground="Gray"/>
    </StackPanel>
  </DockPanel>
  <!-- Protokoll fest unten (nicht im Scrollbereich), Hoehe per Ziehgriff, gemerkt in HUPilot\Config\ui.json -->
  <DockPanel x:Name="pLog" DockPanel.Dock="Bottom" Margin="0,4,0,0">
    <Thumb x:Name="thLog" DockPanel.Dock="Top" Height="10" Cursor="SizeNS" ToolTip="Höhe des Protokolls anpassen (ziehen) - wird gemerkt." ToolTipService.ShowDuration="30000">
      <Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="Transparent"><Border Background="#FF9E9E9E" Opacity="0.6" Height="4" Width="80" CornerRadius="2" VerticalAlignment="Center"/></Border></ControlTemplate></Thumb.Template>
    </Thumb>
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
      <Button x:Name="bLogClear" DockPanel.Dock="Right" Content="Löschen" Padding="8,1" Margin="6,0,0,0" ToolTip="Protokoll dieser Sitzung leeren (die Dateien am Stick bleiben unverändert)." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bLogRev" DockPanel.Dock="Right" Content="Umkehren" Padding="8,1" ToolTip="Reihenfolge umkehren: neueste Zeile oben oder unten (wird gemerkt)." ToolTipService.ShowDuration="30000"/>
      <TextBlock Text="Protokoll" FontWeight="SemiBold" VerticalAlignment="Center" ToolTip="Was das Setup in dieser Sitzung gemacht hat." ToolTipService.ShowDuration="30000"/>
    </DockPanel>
    <TextBox x:Name="tLog" Height="160" ToolTip="Protokoll dieser Sitzung (neueste Zeile oben, mit Umkehren änderbar)." ToolTipService.ShowDuration="30000" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
  </DockPanel>
  <!-- Hauptknopf: alles in einem Durchgang -->
  <Border x:Name="bdReady" DockPanel.Dock="Bottom" Margin="0,8,0,0" Padding="8" CornerRadius="4" BorderThickness="1" BorderBrush="#FF2E7D32" Background="#142E7D32">
    <DockPanel>
      <Button x:Name="bReady" DockPanel.Dock="Left" Style="{StaticResource HuMain}" Padding="18,8" FontSize="15" FontWeight="Bold" ToolTip="Macht den gewählten Stick in einem Durchgang fertig:&#x0a;Felder prüfen, Verbindung und Secret prüfen, Tags prüfen (nur Warnung), speichern,&#x0a;WLAN-Paket bauen, wenn es fehlt oder veraltet ist, auf den Stick kopieren und die kopierten Dateien kontrollieren.&#x0a;Bricht beim ersten echten Fehler ab und sagt, was zu tun ist." ToolTipService.ShowDuration="60000">
        <StackPanel Orientation="Horizontal"><Ellipse x:Name="eReady" Style="{StaticResource HuLamp}" Width="12" Height="12" Margin="0,0,8,0"/><TextBlock x:Name="tReadyBtn" Text="Stick fertig machen"/></StackPanel>
      </Button>
      <TextBlock x:Name="tReady" Margin="12,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap" Text="Stick anstecken, bei &quot;Stick&quot; auswählen, dann hier klicken." ToolTip="Ergebnis des letzten Durchgangs. Einzelschritte 1 bis 7 gibt es weiterhin, jeder mit eigener Ampel." ToolTipService.ShowDuration="30000"/>
    </DockPanel>
  </Border>
  <ScrollViewer x:Name="svMain" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
  <Grid Margin="0,0,8,0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <GroupBox Grid.Row="0" Header="Tenant / App-Registrierung" Padding="6">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Anzeigename" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tTenant" ToolTip="Anzeigename des Tenants - nur für Log und Protokoll am Stick (z. B. Schulname)." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Tenant-ID" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tTenantId" ToolTip="Verzeichnis-(Mandanten-)ID des Tenants (GUID).&#x0a;Entra Admin Center &gt; Übersicht &gt; Mandanten-ID." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="2" Text="App-ID (Client)" VerticalAlignment="Center"/><TextBox Grid.Row="2" Grid.Column="1" x:Name="tClientId" ToolTip="Anwendungs-(Client-)ID der App-Registrierung HUPilot-Upload (GUID).&#x0a;Berechtigung: DeviceManagementServiceConfig.ReadWrite.All (Anwendung) + Administratorzustimmung." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="3" Text="Secret (Wert)" VerticalAlignment="Center"/>
        <DockPanel Grid.Row="3" Grid.Column="1"><CheckBox x:Name="cShow" ToolTip="Secret im Klartext anzeigen." ToolTipService.ShowDuration="30000" Content="anzeigen" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="6,0,0,0"/><Grid><PasswordBox x:Name="pSecret" ToolTip="Geheimer Clientschlüssel der App HUPilot-Upload - den WERT, nicht die Geheimnis-ID.&#x0a;Kurz gültig halten (7-14 Tage) und vor jedem Einsatz erneuern." ToolTipService.ShowDuration="30000" Margin="2"/><TextBox x:Name="tSecret" ToolTip="Geheimer Clientschlüssel (Wert) im Klartext." ToolTipService.ShowDuration="30000" Margin="2" Visibility="Collapsed"/></Grid></DockPanel>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="1" Header="Group Tag" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Standard" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tTag" ToolTip="Group Tag, den die Geräte standardmäßig bekommen (z. B. SN-2026).&#x0a;Am Gerät: Enter oder 10 s warten = dieser Tag." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Auswahl (Komma)" VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="tTagChoices" ToolTip="Auswahl am Gerät (max. 9), durch Komma getrennt.&#x0a;Am Gerät mit Taste 1-9 wählbar - z. B. für Nachzügler aus anderen Jahrgängen." ToolTipService.ShowDuration="30000" Margin="2"/>
        <CheckBox Grid.Row="2" Grid.Column="1" x:Name="cAskUser" Margin="2,4,0,0" Content="Am Gerät nach Benutzer (UPN) fragen und vorab zuweisen" ToolTip="go.ps1 fragt nach dem Tag nach einem Anmeldenamen (Enter = keiner) und weist ihn in Autopilot zu.&#x0a;Sinnvoll für Einzelgeräte, nicht für ganze Klassen. Prüfung des Namens: optional User.Read.All." ToolTipService.ShowDuration="30000"/>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="2" Header="Konfigurations-WLAN (WPA2-Personal)" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="WLAN-Name" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tSsid" ToolTip="Name des Konfigurations-WLANs (WPA2-Personal).&#x0a;go.ps1 verbindet sich damit zum Hochladen; das WLAN-Paket bringt es nach dem Zurücksetzen wieder mit." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Kennwort" VerticalAlignment="Center"/>
        <DockPanel Grid.Row="1" Grid.Column="1"><CheckBox x:Name="cShowKey" ToolTip="WLAN-Kennwort im Klartext anzeigen." ToolTipService.ShowDuration="30000" Content="anzeigen" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="6,0,0,0"/><Grid><PasswordBox x:Name="pKey" ToolTip="Kennwort des Konfigurations-WLANs (mind. 8 Zeichen).&#x0a;Steht im Klartext in config.json und im WLAN-Paket - Stick nicht aus der Hand geben." ToolTipService.ShowDuration="30000" Margin="2"/><TextBox x:Name="tKey" ToolTip="WLAN-Kennwort im Klartext." ToolTipService.ShowDuration="30000" Margin="2" Visibility="Collapsed"/></Grid></DockPanel>
        <CheckBox Grid.Row="2" Grid.Column="1" x:Name="cRmPkg" IsChecked="False" Margin="2,4,0,0" Content="Fremde Bereitstellungspakete beim Zurücksetzen entfernen (Test)" ToolTip="Alte Pakete am Gerät (z. B. ein früheres Schul-MDM-Paket) würden das Zurücksetzen überleben und im Einrichtungsbildschirm erneut angewendet - das kann Autopilot stören.&#x0a;Bleibt nur HUPilot-WLAN.ppkg. Die entfernten Pakete werden vorher nach C:\Recovery\HUPilot-PPKG-Backup\&lt;Datum&gt; gesichert.&#x0a;Noch nicht an einem Gerät bestätigt - erst an einem Testgerät ausprobieren." ToolTipService.ShowDuration="30000"/>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="3" Header="Windows Home auf Pro umstellen - Intune braucht Pro oder Pro Education (optional - leer lassen = aus)" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="MAK (Pro)" VerticalAlignment="Center"/>
        <DockPanel Grid.Row="0" Grid.Column="1"><CheckBox x:Name="cShowEd" ToolTip="MAK im Klartext anzeigen." ToolTipService.ShowDuration="30000" Content="anzeigen" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="6,0,0,0"/><Grid><PasswordBox x:Name="pEdKey" ToolTip="Volumenlizenz-Schlüssel (MAK) für Windows Pro, Form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.&#x0a;Windows Home lässt keine Intune-Verwaltung zu, dafür braucht es Pro oder Pro Education (auch Education, Enterprise).&#x0a;Nur für Geräte mit Windows Home: go.ps1 fragt am Gerät nach, stellt auf Pro um (Neustart) und aktiviert danach mit diesem Schlüssel.&#x0a;Jede Aktivierung zählt beim MAK mit. Geräte mit Pro, Pro Education, Education oder Enterprise werden nicht angefasst.&#x0a;ACHTUNG: Der MAK steht im Klartext in config.json auf jedem Stick. Nur für Einzelfälle eintragen, nicht für Massen-Rollouts,&#x0a;Stick nicht aus der Hand geben und das Feld danach wieder leeren (3. Speichern, 5. Auf Stick kopieren). Leer = Funktion aus." ToolTipService.ShowDuration="60000" Margin="2"/><TextBox x:Name="tEdKey" ToolTip="MAK für Windows Pro im Klartext." ToolTipService.ShowDuration="30000" Margin="2" Visibility="Collapsed"/></Grid></DockPanel>
        <TextBlock Grid.Row="1" Grid.Column="1" Margin="2,2,0,0" Foreground="#FFC0392B" TextWrapping="Wrap" Text="Nur für Einzelfälle: Der MAK liegt im Klartext auf dem Stick. Nicht für Massen-Rollouts, danach wieder leeren." ToolTip="Der Schlüssel steht unverschlüsselt in HUPilot\config.json auf jedem bespielten Stick. Wer den Stick hat, kann ihn lesen." ToolTipService.ShowDuration="30000"/>
      </Grid>
    </GroupBox>
    <GroupBox Grid.Row="4" Header="Lokale Admins (optional - leer lassen = keiner)" Padding="6" Margin="0,6,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Admin-Name" VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="tAdmName" ToolTip="Lokales Administratorkonto für die Kustoden (max. 20 Zeichen, z. B. kustode).&#x0a;Kommt mit 4. WLAN-Paket bauen ins Paket und wird nach JEDEM Zurücksetzen neu angelegt.&#x0a;Kennwort und Konto laufen nie ab. Leer lassen = kein lokaler Admin.&#x0a;Änderung wirkt erst nach neuem Paket + Zurücksetzen mit dem Stick." ToolTipService.ShowDuration="30000" Margin="2"/>
        <TextBlock Grid.Row="1" Text="Admin-Kennwort" VerticalAlignment="Center"/>
        <DockPanel Grid.Row="1" Grid.Column="1"><CheckBox x:Name="cShowAdm" ToolTip="Admin-Kennwort im Klartext anzeigen." ToolTipService.ShowDuration="30000" Content="anzeigen" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="6,0,0,0"/><Grid><PasswordBox x:Name="pAdmPw" ToolTip="Kennwort des lokalen Admins (mind. 8 Zeichen, auf allen Geräten gleich).&#x0a;Steht im Klartext in config.json und im WLAN-Paket - Stick nicht aus der Hand geben." ToolTipService.ShowDuration="30000" Margin="2"/><TextBox x:Name="tAdmPw" ToolTip="Admin-Kennwort im Klartext." ToolTipService.ShowDuration="30000" Margin="2" Visibility="Collapsed"/></Grid></DockPanel>
        <TextBlock Grid.Row="2" Text="Admin 2 - Name" VerticalAlignment="Center" Margin="0,6,0,0"/><TextBox Grid.Row="2" Grid.Column="1" x:Name="tAdm2Name" ToolTip="Zweites lokales Administratorkonto, z. B. für den Elternverein (max. 20 Zeichen, z. B. elternadmin).&#x0a;Gleiche Regeln wie Admin 1: kommt ins WLAN-Paket, nach JEDEM Zurücksetzen neu angelegt, Kennwort und Konto laufen nie ab.&#x0a;Leer lassen = kein zweiter Admin." ToolTipService.ShowDuration="30000" Margin="2,8,2,2"/>
        <TextBlock Grid.Row="3" Text="Admin 2 - Kennwort" VerticalAlignment="Center"/>
        <DockPanel Grid.Row="3" Grid.Column="1"><CheckBox x:Name="cShowAdm2" ToolTip="Kennwort von Admin 2 im Klartext anzeigen." ToolTipService.ShowDuration="30000" Content="anzeigen" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="6,0,0,0"/><Grid><PasswordBox x:Name="pAdm2Pw" ToolTip="Kennwort des zweiten lokalen Admins (mind. 8 Zeichen, auf allen Geräten gleich).&#x0a;Steht im Klartext in config.json und im WLAN-Paket - Stick nicht aus der Hand geben." ToolTipService.ShowDuration="30000" Margin="2"/><TextBox x:Name="tAdm2Pw" ToolTip="Kennwort von Admin 2 im Klartext." ToolTipService.ShowDuration="30000" Margin="2" Visibility="Collapsed"/></Grid></DockPanel>
      </Grid>
    </GroupBox>
    <WrapPanel Grid.Row="5" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="Vorbereiten" Width="78" VerticalAlignment="Center" Foreground="Gray" Margin="0,0,0,4" ToolTip="Einzelschritte zum Vorbereiten der Quelle. Der Knopf &quot;Stick fertig machen&quot; unten erledigt sie in einem Durchgang." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bLoad" ToolTip="config.json aus der Quelle neu laden (der Ordner, aus dem dieses Setup läuft).&#x0a;Ungespeicherte Änderungen gehen dabei verloren (mit Rückfrage)." ToolTipService.ShowDuration="30000" Content="Neu laden" Padding="8,2" Margin="0,0,0,4"/>
      <Button x:Name="bTest" ToolTip="Holt mit App-ID und Secret ein Token und liest die Autopilot-Liste.&#x0a;Zeigt sofort, ob Secret abgelaufen/falsch ist oder die Berechtigung fehlt." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eTest" Style="{StaticResource HuLamp}"/><TextBlock Text="1. Verbindung testen"/></StackPanel></Button>
      <Button x:Name="bTags" ToolTip="Zeigt je Group Tag: Anzahl Geräte in Autopilot, passende dynamische Gruppe und zugewiesenes Autopilot-Profil.&#x0a;So sieht man VOR dem Einsatz, ob für einen Tag ein Profil fehlt. Gruppen lesen: optional Group.Read.All." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eTags" Style="{StaticResource HuLamp}"/><TextBlock Text="2. Tags prüfen"/></StackPanel></Button>
      <Button x:Name="bWrite" ToolTip="Speichert alle Felder als config.json in die Quelle.&#x0a;Zusätzliche Felder (TagPattern, Reset, ...) bleiben erhalten." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eWrite" Style="{StaticResource HuLamp}"/><TextBlock Text="3. Speichern"/></StackPanel></Button>
      <TextBlock x:Name="tDirty" Text="* ungespeichert" Foreground="#FFE65100" FontWeight="SemiBold" VerticalAlignment="Center" Margin="6,0,0,4" Visibility="Collapsed" ToolTip="Es gibt Änderungen, die noch nicht in config.json stehen.&#x0a;3. Speichern oder Stick fertig machen speichert sie." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bPkg" ToolTip="Speichert zuerst, dann baut HUPilot-WLAN.ppkg (WLAN + optional lokaler Admin, kein CleanPC) in die Quelle.&#x0a;VORAUSSETZUNG: Windows ADK mit &quot;Imaging and Configuration Designer&quot; (WCD) auf diesem PC:&#x0a;C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe&#x0a;Die WCD-App aus dem Microsoft Store reicht NICHT (keine Kommandozeile).&#x0a;Ohne ADK: Tools\New-WcdProjekt.ps1 + WCD-Oberfläche, siehe INSTALL.md." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="ePkg" Style="{StaticResource HuLamp}"/><TextBlock Text="4. WLAN-Paket bauen"/></StackPanel></Button>
      <TextBlock x:Name="tPkg" VerticalAlignment="Center" Margin="6,0,0,4" Foreground="Gray" ToolTip="Stand des WLAN-Pakets in der Quelle:&#x0a;aktuell = passt zu WLAN und lokalen Admins&#x0a;veraltet = WLAN oder Admins wurden seit dem Bau geändert, neu bauen&#x0a;fehlt = noch kein Paket gebaut" ToolTipService.ShowDuration="30000"/>
    </WrapPanel>
    <WrapPanel Grid.Row="6" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="Stick" Width="78" VerticalAlignment="Center" Foreground="Gray" Margin="0,0,0,4" ToolTip="Ziel-Stick für 5. Auf Stick kopieren und für Stick fertig machen." ToolTipService.ShowDuration="30000"/>
      <ComboBox x:Name="cDrive" ToolTip="Ziel-Stick für 5. Auf Stick kopieren und Stick fertig machen. Das Laufwerk der Quelle selbst wird nicht angeboten." ToolTipService.ShowDuration="30000" Width="180" Margin="0,0,0,4"/>
      <Button x:Name="bReload" ToolTip="USB-Laufwerke neu einlesen." ToolTipService.ShowDuration="30000" Content="Aktualisieren" Padding="8,2" Margin="6,0,0,4"/>
      <Button x:Name="bCopy" ToolTip="Speichert zuerst, dann kopiert die Quelle 1:1 auf den Ziel-Stick:&#x0a;go.cmd, HUPilot-Setup.cmd, HUPilot\ (go.ps1, config.json, WLAN-Paket, Setup).&#x0a;Nicht kopiert: logs und Ordner, die mit _ beginnen. Danach Kontrolle der kopierten Dateien." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eCopy" Style="{StaticResource HuLamp}"/><TextBlock Text="5. Auf Stick kopieren"/></StackPanel></Button>
      <Button x:Name="bPrep" ToolTip="Nur wenn das Setup vom PC läuft: mehrere USB-Sticks auf einmal oder hintereinander&#x0a;formatieren, benennen und mit HUPilot befüllen. ALLE Daten auf den gewählten Sticks gehen verloren." ToolTipService.ShowDuration="30000" Content="Sticks vorbereiten ..." Padding="8,2" Margin="8,0,0,4"/>
    </WrapPanel>
    <WrapPanel Grid.Row="7" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="Danach" Width="78" VerticalAlignment="Center" Foreground="Gray" Margin="0,0,0,4" ToolTip="Nach dem Einsatz der Sticks: Stand in Autopilot ansehen, offline gespeicherte Hashes hochladen." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bStatus" ToolTip="Zeigt alle Autopilot-Geräte des Tenants mit Tag, Profil und Intune-Registrierung.&#x0a;Filter nach Tag und nach Seriennummern aus protokoll.csv (Quelle und Ziel-Stick).&#x0a;Export als CSV oder Excel, Drucken (auch als PDF)." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="0,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eStatus" Style="{StaticResource HuLamp}"/><TextBlock Text="6. Status"/></StackPanel></Button>
      <Button x:Name="bHash" ToolTip="Hashes, die go.ps1 offline am Stick gespeichert hat (HUPilot\logs\hashes.csv), hochladen.&#x0a;Liest Quelle + Ziel-Stick, weitere CSV-Dateien können hinzugefügt werden. Erledigte Zeilen wandern nach hashes-erledigt.csv." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eHash" Style="{StaticResource HuLamp}"/><TextBlock Text="7. Hashes importieren"/></StackPanel></Button>
    </WrapPanel>
  </Grid>
  </ScrollViewer>
  </DockPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'iLogo','tSub','tTenant','tTenantId','tClientId','tSecret','pSecret','cShow','tEdKey','pEdKey','cShowEd','tTag','tTagChoices','tSsid','tKey','pKey','cShowKey','tAdmName','tAdmPw','pAdmPw','cShowAdm','tAdm2Name','tAdm2Pw','pAdm2Pw','cShowAdm2','cAskUser','cRmPkg','bTags','bHash','cDrive','bReload','bPrep','bLoad','bTest','bWrite','bPkg','bCopy','bStatus','bHelp','bUpd','bLnk','tLog','svMain','thLog','bLogRev','bLogClear','bReady','tReadyBtn','tReady','eReady','eTest','eTags','eWrite','ePkg','eCopy','eStatus','eHash','tDirty','tPkg') { $ui[$n] = $win.FindName($n) }

# Fenster an den Bildschirm anpassen: nie groesser als der Arbeitsbereich (ohne Taskleiste) und ganz sichtbar.
# Auf kleinen Notebooks (z. B. 1366x768 oder hohe Skalierung) ragte das Fenster sonst unter die Taskleiste.
# Unterfenster (mit Owner), die schon passen, bleiben mittig ueber dem Hauptfenster.
function Set-WinFit($w) {
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $fits = $true
        if ($w.Height -gt $wa.Height) { $w.Height = [math]::Max($w.MinHeight, $wa.Height); $fits = $false }
        if ($w.Width -gt $wa.Width) { $w.Width = [math]::Max($w.MinWidth, $wa.Width); $fits = $false }
        if ($w.Owner -and $fits) { return }
        $w.WindowStartupLocation = 'Manual'
        $w.Left = $wa.Left + [math]::Max(0, ($wa.Width - $w.Width) / 2)
        $w.Top = $wa.Top + [math]::Max(0, ($wa.Height - $w.Height) / 2)
    } catch { }
}
Set-WinFit $win
# Mausrad scrollt immer das ganze Formular (ausser im Protokoll und in einer offenen Auswahlliste)
$ui.svMain.Add_PreviewMouseWheel({
    param($s, $e)
    if ($ui.tLog.IsMouseOver -or $ui.cDrive.IsDropDownOpen) { return }
    $ui.svMain.ScrollToVerticalOffset($ui.svMain.VerticalOffset - ($e.Delta / 120.0 * 48))
    $e.Handled = $true
})

$win.Title = 'HUPilot-Setup v' + $SetupVer
# Icon (Titelleiste + Taskleiste) und Logo
try {
    $ico = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path $ico) { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($ico))) }
    $png = Join-Path $PSScriptRoot 'logo64.png'
    if (Test-Path $png) { $ui.iLogo.Source = New-Object System.Windows.Media.Imaging.BitmapImage((New-Object System.Uri($png))) }
} catch { }

# ---------- Oberflaechen-Einstellungen (HUPilot\Config\ui.json, lokal, uebersteht Updates) ----------
$script:UiJson = Join-Path $CfgDirHU 'ui.json'
function Get-UiSetting([string]$Name, $Default) {
    try {
        if (Test-Path -LiteralPath $script:UiJson) {
            $u = Get-Content -LiteralPath $script:UiJson -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($u -and ($u.PSObject.Properties.Name -contains $Name)) { return $u.$Name }
        }
    } catch { }
    return $Default
}
function Set-UiSetting([string]$Name, $Value) {
    try {
        $o = [ordered]@{}
        if (Test-Path -LiteralPath $script:UiJson) { try { $u = Get-Content -LiteralPath $script:UiJson -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $u.PSObject.Properties) { $o[$p.Name] = $p.Value } } catch { } }
        $o[$Name] = $Value
        if (-not (Test-Path -LiteralPath $CfgDirHU)) { New-Item -ItemType Directory -Path $CfgDirHU -Force | Out-Null }
        [System.IO.File]::WriteAllText($script:UiJson, ([pscustomobject]$o | ConvertTo-Json), $enc)
    } catch { }
}

# ---------- Protokoll: neueste Zeile oben (umkehrbar, gemerkt), Hoehe per Ziehgriff ----------
$script:LogTop = ([string](Get-UiSetting 'LogNewestTop' $true) -ne 'False')
function Out-Log([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $m
    if ($script:LogTop) {
        if ($ui.tLog.Text) { $ui.tLog.Text = $line + "`r`n" + $ui.tLog.Text } else { $ui.tLog.Text = $line }
        $ui.tLog.ScrollToHome()
    } else {
        if ($ui.tLog.Text) { $ui.tLog.AppendText("`r`n" + $line) } else { $ui.tLog.Text = $line }
        $ui.tLog.ScrollToEnd()
    }
}
try { $h = [double](Get-UiSetting 'LogHeight' 160); if ($h -ge 60 -and $h -le 800) { $ui.tLog.Height = $h } } catch { }
$ui.thLog.Add_DragDelta({
    param($s, $e)
    $max = [math]::Max(60, [math]::Min(800, $win.ActualHeight - 330))
    $ui.tLog.Height = [math]::Max(60, [math]::Min($max, $ui.tLog.Height - $e.VerticalChange))
})
$ui.thLog.Add_DragCompleted({ Set-UiSetting 'LogHeight' ([int]$ui.tLog.Height) })
$ui.bLogRev.Add_Click({
    $l = @($ui.tLog.Text -split "`r`n")
    [array]::Reverse($l)
    $ui.tLog.Text = ($l -join "`r`n")
    $script:LogTop = -not $script:LogTop
    Set-UiSetting 'LogNewestTop' $script:LogTop
    if ($script:LogTop) { $ui.tLog.ScrollToHome() } else { $ui.tLog.ScrollToEnd() }
})
$ui.bLogClear.Add_Click({ $ui.tLog.Clear() })

# ---------- Ampeln je Schritt (offen, laeuft, ok, Warnung, Fehler) ----------
$script:LampColor = @{ open = '#FF9E9E9E'; run = '#FF1976D2'; ok = '#FF2E7D32'; warn = '#FFF9A825'; err = '#FFC62828' }
$script:LampText  = @{ open = 'offen'; run = 'läuft ...'; ok = 'OK'; warn = 'Warnung'; err = 'Fehler' }
function Set-Step([string]$Step, [string]$State, [string]$Note = '') {
    $e = $ui['e' + $Step]
    if (-not $e -or -not $script:LampColor.ContainsKey($State)) { return }
    try {
        $e.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($script:LampColor[$State]))
        $e.ToolTip = 'Stand: ' + $script:LampText[$State] + $(if ($Note) { ' - ' + $Note } else { '' }) + '  (' + (Get-Date -Format 'HH:mm') + ')'
    } catch { }
}
function Get-Drive { if ($ui.cDrive.SelectedItem) { return ([string]$ui.cDrive.SelectedItem).Substring(0, 2) } return $null }
# Gewaehlter Stick nur, wenn er noch da ist. Prueft ueber .NET (nicht ueber PowerShell-Laufwerke): ein abgezogener oder
# neu eingehaengter Stick fehlt sonst als PS-Laufwerk, und Join-Path/Import-Csv brechen mit "Laufwerk D nicht vorhanden" ab.
function Get-ReadyDrive {
    $d = Get-Drive
    if (-not $d) { return $null }
    try { if ([System.IO.Directory]::Exists($d + '\')) { return $d } } catch { }
    Out-Log ('Stick ' + $d + ' nicht mehr vorhanden - Stick einstecken und "Aktualisieren" drücken')
    return $null
}
function Update-Drives {
    $ui.cDrive.Items.Clear()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try { if ($d.IsReady -and $d.DriveType -eq 'Removable' -and $d.Name.Substring(0, 2).ToUpper() -ne $srcDrive) { [void]$ui.cDrive.Items.Add(('{0} {1} ({2:N1} GB)' -f $d.Name.TrimEnd('\'), $d.VolumeLabel, ($d.TotalSize / 1GB))) } } catch { }
    }
    if ($ui.cDrive.Items.Count) {
        $ui.cDrive.SelectedIndex = 0
    } else { Out-Log 'Kein Ziel-Stick gefunden (nötig für 5. und Stick fertig machen).' }
    Update-ReadyLabel
}
# Hauptknopf zeigt den gewaehlten Stick
function Update-ReadyLabel {
    $d = Get-Drive
    $ui.tReadyBtn.Text = 'Stick fertig machen' + $(if ($d) { '  (' + $d + ')' } else { '' })
}
$ui.cDrive.Add_SelectionChanged({ Update-ReadyLabel })
function Get-Cfg {
    $choices = @($ui.tTagChoices.Text -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $o = [ordered]@{
        Tenant = $ui.tTenant.Text.Trim(); TenantId = $ui.tTenantId.Text.Trim(); ClientId = $ui.tClientId.Text.Trim()
        ClientSecret = (Get-Secret); GroupTag = $ui.tTag.Text.Trim(); TagChoices = $choices
        WlanSsid = $ui.tSsid.Text.Trim(); WlanKey = (Get-Masked 'Key'); WlanPackage = 'HUPilot-WLAN.ppkg'
        AdminName = $ui.tAdmName.Text.Trim(); AdminPassword = (Get-Masked 'AdmPw')
        Admin2Name = $ui.tAdm2Name.Text.Trim(); Admin2Password = (Get-Masked 'Adm2Pw'); AskUser = [bool]$ui.cAskUser.IsChecked; RemoveOtherPackages = [bool]$ui.cRmPkg.IsChecked
        EditionKey = (Get-EdKey)
    }
    foreach ($k in $script:Extra.Keys) { if (-not $o.Contains($k) -or $k -eq 'WlanPackage') { $o[$k] = $script:Extra[$k] } }
    return $o
}
# Muster fuer Group Tags: wie go.ps1 (TagPattern aus config.json, sonst Standard)
function Get-TagPattern($c) {
    $p = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    if ($c -and $c.TagPattern) { $p = [string]$c.TagPattern }
    return $p
}
# Feldfehler: ins Protokoll und fuer Meldungen merken (Stick fertig machen zeigt ihn im Klartext)
function Stop-Field([string]$m) { Out-Log $m; $script:FieldErr = $m; return $false }
# Pruefungen sind an den Aufrufer gebunden:
#   immer:        Pflichtfelder aus -Names, GUIDs, WLAN-Kennwort (wenn verlangt)
#   -Admin:       lokale Admins (nur Speichern und Paketbau) - sonst blockiert ein halb ausgefuellter Admin
#                 Verbindungstest, Tags, Status, Hashes und die Secret-Pruefung beim Start
#   GroupTag in -Names (nur beim Speichern): MAK, Group Tag und Auswahl (gleiches Muster wie go.ps1, hoechstens 9)
function Test-Fields([string[]]$Names, [switch]$Admin) {
    $script:FieldErr = ''
    $c = Get-Cfg
    $miss = @($Names | Where-Object { -not $c[$_] })
    if ($miss.Count) { return (Stop-Field ('FEHLT: ' + ($miss -join ', '))) }
    if ($Names -contains 'TenantId' -and $c.TenantId -notmatch '^[0-9a-fA-F-]{36}$') { return (Stop-Field 'Tenant-ID ist keine GUID') }
    if ($Names -contains 'ClientId' -and $c.ClientId -notmatch '^[0-9a-fA-F-]{36}$') { return (Stop-Field 'App-ID ist keine GUID') }
    if ($Names -contains 'WlanKey' -and $c.WlanKey.Length -lt 8) { return (Stop-Field 'WLAN-Kennwort kürzer als 8 Zeichen') }
    if ($Admin) {
        foreach ($a in @(@('Admin', $c.AdminName, $c.AdminPassword), @('Admin 2', $c.Admin2Name, $c.Admin2Password))) {
            if (-not $a[1]) { if ($a[2]) { return (Stop-Field ($a[0] + ': Kennwort ohne Name - Name eintragen oder Kennwort leeren')) }; continue }
            if ($a[1].Length -gt 20 -or $a[1] -match '["/\\\[\]:;|=,+*?<>@ ]') { return (Stop-Field ($a[0] + '-Name ungültig (max. 20 Zeichen, keine Leer- oder Sonderzeichen wie / \ [ ] : ; | = , + * ? < > @)')) }
            if ([string]$a[2] -eq '' -or $a[2].Length -lt 8) { return (Stop-Field ($a[0] + '-Kennwort kürzer als 8 Zeichen')) }
        }
        if ($c.AdminName -and $c.Admin2Name -and $c.AdminName -eq $c.Admin2Name) { return (Stop-Field 'Admin und Admin 2 haben denselben Namen') }
    }
    # MAK nur beim Speichern pruefen (dort ist GroupTag Pflicht): sonst scheitern Verbindungstest und Secret-Pruefung an einem falschen MAK
    $chkEd = $Names -contains 'GroupTag'
    if ($chkEd -and $c.EditionKey -and $c.EditionKey -notmatch '^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$') { return (Stop-Field 'MAK (Pro) ungültig - Form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, oder Feld leeren') }
    # Allgemeine Schluessel von Microsoft (Installation/KMS-Client) aktivieren nicht - gleiche Liste wie in go.ps1
    if ($chkEd -and $c.EditionKey -and @('VK7JG-NPHTM-C97JM-9MPGT-3V66T', '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT', 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7', 'W269N-WFGWX-YVC9B-4J6C9-T83GX', 'MH37W-N47XK-V7XM9-C7227-GCQG9') -contains $c.EditionKey) { return (Stop-Field 'MAK (Pro): das ist der allgemeine Schlüssel von Microsoft, der aktiviert nicht. Den MAK der Schule eintragen (Volumenlizenz), oder Feld leeren') }
    # Group Tag und Auswahl: go.ps1 bricht am Geraet sonst rot ab bzw. zeigt nur die ersten 9
    if ($chkEd) {
        $tp = Get-TagPattern $c
        $std = ($tp -eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
        $rule = $(if ($std) { 'erlaubt: Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich, am Anfang Buchstabe oder Ziffer, höchstens 64 Zeichen' } else { 'Muster aus config.json (TagPattern): ' + $tp })
        try { [void][regex]::new($tp) } catch { return (Stop-Field ('TagPattern in config.json ist kein gültiges Muster: ' + $tp)) }
        if ($c.GroupTag -notmatch $tp) { return (Stop-Field ('Group Tag "' + $c.GroupTag + '" ungültig - ' + $rule)) }
        $badC = @(@($c.TagChoices) | Where-Object { [string]$_ -notmatch $tp })
        if ($badC.Count) { return (Stop-Field ('Auswahl: ungültige(r) Eintrag/Einträge "' + ($badC -join '", "') + '" - ' + $rule)) }
        if (@($c.TagChoices).Count -gt 9) { return (Stop-Field ('Auswahl hat ' + @($c.TagChoices).Count + ' Einträge - am Gerät sind nur 9 wählbar (Taste 1 bis 9). Auf höchstens 9 kürzen.')) }
    }
    return $true
}

function Get-Secret { if ($ui.cShow.IsChecked) { return $ui.tSecret.Text.Trim() } return $ui.pSecret.Password.Trim() }
function Set-Secret([string]$v) { $ui.pSecret.Password = $v; $ui.tSecret.Text = $v }
$ui.cShow.Add_Checked({ $ui.tSecret.Text = $ui.pSecret.Password; $ui.pSecret.Visibility = 'Collapsed'; $ui.tSecret.Visibility = 'Visible' })
$ui.cShow.Add_Unchecked({ $ui.pSecret.Password = $ui.tSecret.Text; $ui.tSecret.Visibility = 'Collapsed'; $ui.pSecret.Visibility = 'Visible' })
function Get-EdKey { $v = $(if ($ui.cShowEd.IsChecked) { $ui.tEdKey.Text } else { $ui.pEdKey.Password }); return $v.Trim().ToUpper() }
function Set-EdKey([string]$v) { $ui.pEdKey.Password = $v; $ui.tEdKey.Text = $v }
$ui.cShowEd.Add_Checked({ $ui.tEdKey.Text = $ui.pEdKey.Password; $ui.pEdKey.Visibility = 'Collapsed'; $ui.tEdKey.Visibility = 'Visible' })
$ui.cShowEd.Add_Unchecked({ $ui.pEdKey.Password = $ui.tEdKey.Text; $ui.tEdKey.Visibility = 'Collapsed'; $ui.pEdKey.Visibility = 'Visible' })
# WLAN-Kennwort und Admin-Kennwoerter: gleiches Muster wie Secret und MAK (Kennwortfeld + Klartextfeld + "anzeigen"), Wert ungekuerzt
$script:Masked = @{ Key = 'cShowKey'; AdmPw = 'cShowAdm'; Adm2Pw = 'cShowAdm2' }
function Get-Masked([string]$Id) { if ($ui[$script:Masked[$Id]].IsChecked) { return [string]$ui['t' + $Id].Text } return [string]$ui['p' + $Id].Password }
function Set-Masked([string]$Id, [string]$v) { $ui['p' + $Id].Password = $v; $ui['t' + $Id].Text = $v }
foreach ($mk in @($script:Masked.Keys)) {
    $cb = $ui[$script:Masked[$mk]]; $cb.Tag = $mk
    $cb.Add_Checked({ $i = [string]$this.Tag; $ui['t' + $i].Text = $ui['p' + $i].Password; $ui['p' + $i].Visibility = 'Collapsed'; $ui['t' + $i].Visibility = 'Visible' })
    $cb.Add_Unchecked({ $i = [string]$this.Tag; $ui['p' + $i].Password = $ui['t' + $i].Text; $ui['t' + $i].Visibility = 'Collapsed'; $ui['p' + $i].Visibility = 'Visible' })
}
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
        Title="HUPilot - Sticks vorbereiten" Width="720" Height="560" WindowStartupLocation="CenterOwner" FontSize="13" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style x:Key="HuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="3" Background="#FF6A6A6A"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Border Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="1,0"/></Track.Thumb>
        </Track></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent"><Track x:Name="PART_Track">
              <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="0,1"/></Track.Thumb>
            </Track></Border>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="Firebrick" FontWeight="SemiBold" Margin="0,0,0,8"
      Text="ACHTUNG: Die gewählten USB-Sticks werden FORMATIERT - alle Daten darauf gehen verloren. Interne Laufwerke und der Quell-Datenträger werden nie angezeigt."/>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock Text="Name:" VerticalAlignment="Center"/>
      <TextBox x:Name="tLabel" Width="120" Margin="6,0,0,0" MaxLength="11" ToolTip="Laufwerksname (max. 11 Zeichen, keine Sonderzeichen)."/>
      <TextBlock Text="Dateisystem:" VerticalAlignment="Center" Margin="16,0,0,0"/>
      <ComboBox x:Name="cFs" Width="90" Margin="6,0,0,0" ToolTip="NTFS empfohlen. FAT32 nur bis 32 GB."/>
      <Button x:Name="bScan" Content="Neu einlesen" Padding="8,2" Margin="16,0,0,0" ToolTip="Sticks tauschen, dann neu einlesen."/>
      <Button x:Name="bAll" Content="Alle wählen" Padding="8,2" Margin="6,0,0,0" ToolTip="Alle angezeigten USB-Sticks auswählen."/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bGo" Content="Gewählte formatieren + befüllen" Padding="10,4" FontWeight="SemiBold" ToolTip="Speichert, fragt nach WLAN-Paket, Secret und MAK (einmal für alle), dann werden die gewählten Sticks nach einer Rückfrage formatiert, befüllt und kontrolliert."/>
      <Button x:Name="bClose" Content="Schließen" Padding="10,4" Margin="8,0,0,0" ToolTip="Fenster schließen."/>
    </StackPanel>
    <TextBox x:Name="tPLog" ToolTip="Protokoll dieses Fensters." DockPanel.Dock="Bottom" Height="150" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
    <ListBox x:Name="lSticks" SelectionMode="Multiple" FontFamily="Consolas" ToolTip="Gefundene USB-Sticks - anklicken zum Auswählen (mehrere möglich)."/>
  </DockPanel>
</Window>
'@
    $pw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $px))
    $pw.Owner = $win
    if ($win.Icon) { $pw.Icon = $win.Icon }
    Set-WinFit $pw
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
        if (-not $sel.Count) { & $plog 'Keinen Stick gewählt (anklicken).'; return }
        $label = $g.tLabel.Text.Trim(); $fs = [string]$g.cFs.SelectedItem
        if ($label -notmatch '^[A-Za-z0-9_-]{1,11}$') { & $plog 'Name ungültig (1-11 Zeichen: Buchstaben, Ziffern, - _)'; return }
        if (-not (Save-Cfg)) { & $plog ('Config nicht gespeichert: ' + $script:FieldErr); return }
        if (-not (Confirm-PkgForCopy $pw)) { & $plog 'Abgebrochen (WLAN-Paket)'; return }
        # Secret und MAK einmal fuer den ganzen Durchgang
        $pre = Confirm-CopyPrereqs ('die gewählten Sticks (' + $sel.Count + ')') $pw
        if (-not $pre) { & $plog 'Abgebrochen'; return }
        $list = ($sel | ForEach-Object { '   ' + $_.Text }) -join "`r`n"
        $q = [System.Windows.MessageBox]::Show($pw, ('Diese Sticks werden FORMATIERT (' + $fs + ', Name ' + $label + ') - alle Daten gehen verloren:' + "`r`n`r`n" + $list + "`r`n`r`nFortfahren?"), 'HUPilot - Sticks formatieren', 'YesNo', 'Warning')
        if ($q -ne 'Yes') { return }
        $ok = 0
        foreach ($st in $sel) {
            $dl = $st.Letter
            try {
                # Sicherheitscheck direkt vor dem Formatieren erneut
                $disk = Get-Partition -DriveLetter $dl -ErrorAction Stop | Get-Disk -ErrorAction Stop
                if ([string]$disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem -or [int]$disk.Number -eq $script:SrcDisk) { throw 'kein reiner USB-Stick mehr - übersprungen' }
                if ($fs -eq 'FAT32' -and (Get-Volume -DriveLetter $dl).Size -gt 32GB) { throw 'FAT32 nur bis 32 GB - NTFS wählen' }
                & $plog ($dl + ': formatiere ...')
                Format-Volume -DriveLetter $dl -FileSystem $fs -NewFileSystemLabel $label -Force -Confirm:$false -ErrorAction Stop | Out-Null
                & $plog ($dl + ': kopiere HUPilot ...')
                if (Copy-ToStick ($dl + ':') $pre.WithMak) { & $plog ($dl + ': OK - kopiert und kontrolliert, abziehen'); $ok++ } else { & $plog ($dl + ': FEHLER beim Kopieren: ' + $script:CopyErr) }
            } catch { & $plog ($dl + ': FEHLER ' + $_.Exception.Message) }
        }
        & $plog ('Fertig: ' + $ok + ' von ' + $sel.Count + ' Stick(s). Nächste Sticks anstecken -> Neu einlesen.')
        Out-Log ('Sticks vorbereitet: ' + $ok + ' von ' + $sel.Count)
        & $scan
    })
    & $scan
    [void]$pw.ShowDialog()
    Update-Drives
}
$ui.bPrep.Add_Click({ Show-PrepSticks })

# ---------- Update: GitHub-Releases, Kanal Stabil/Test, Pruefsumme + Signatur (gleicher Ablauf wie HU-MultiTenant / HUMig) ----------
#   Klick: bei neuer Version Pull.ps1 starten (laedt + prueft ALLE Dateien, ersetzt erst dann, startet das Setup neu), sonst pruefen
#   Rechtsklick: andere Version, Kanal, jetzt pruefen, GitHub-Token, Release signieren / freigeben (nur Herausgeber)
#   Einstellungen: HUPilot\Config\update.json (lokal). Installierte Version: HUPilot\Config\installed.json (schreibt Pull.ps1)
$script:UpdLib    = Join-Path $PSScriptRoot 'Core-Update.ps1'
$script:PullPs    = Join-Path $PSScriptRoot 'Pull.ps1'
$script:UpdRemote = ''
$script:UpdCfg    = $null
if (Test-Path -LiteralPath $script:UpdLib) { try { . $script:UpdLib } catch { Start-Log ('Core-Update.ps1 nicht ladbar: ' + $_.Exception.Message) } }

function Step-Ui { try { $win.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) } catch { } }
function Get-UpdCfg {
    if (-not (Get-Command Get-HMUpdateConfig -ErrorAction SilentlyContinue)) { return $null }
    $script:UpdCfg = Get-HMUpdateConfig $CfgDirHU
    return $script:UpdCfg
}
function Format-Channel([string]$c) { if ($c -eq 'Test') { 'Test' } else { 'Stabil' } }
function Get-GhTokenFile { return (Join-Path $CfgDirHU ('GitHubToken_{0}.xml' -f ("$($env:USERDOMAIN)_$($env:USERNAME)" -replace '[^\w\.\-]', '_'))) }
function Read-GhToken {
    if ("$env:HU_GITHUB_TOKEN".Trim()) { return "$env:HU_GITHUB_TOKEN".Trim() }
    $f = Get-GhTokenFile
    if (Test-Path -LiteralPath $f) { try { $c = Import-Clixml -Path $f -ErrorAction Stop; if ($c -is [System.Management.Automation.PSCredential]) { return $c.GetNetworkCredential().Password.Trim() } } catch { } }
    return ''
}
function Save-GhToken([string]$File, [string]$Message) {
    $c = $null
    try { $c = Get-Credential -UserName 'github' -Message $Message } catch { $c = $null }
    if (-not $c -or -not $c.GetNetworkCredential().Password.Trim()) { Out-Log 'Kein Token eingegeben'; return $false }
    try {
        $d = Split-Path $File -Parent
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $c | Export-Clixml -Path $File -Force -ErrorAction Stop
        return $true
    } catch { Out-Log ('Token nicht gespeichert: ' + $_.Exception.Message); return $false }
}
# update.json schreiben (vorhandene Einstellungen bleiben)
function Set-UpdSetting([string]$Name, $Value) {
    $f = Join-Path $CfgDirHU 'update.json'
    $o = [ordered]@{}
    if (Test-Path -LiteralPath $f) { try { $u = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $u.PSObject.Properties) { $o[$p.Name] = $p.Value } } catch { } }
    $o[$Name] = $Value
    if (-not (Test-Path -LiteralPath $CfgDirHU)) { New-Item -ItemType Directory -Path $CfgDirHU -Force | Out-Null }
    [pscustomobject]$o | ConvertTo-Json | Set-Content -LiteralPath $f -Encoding UTF8
}
function Set-UpdButton([string]$RemoteVer = '', [bool]$Pre = $false, [string]$Text = '') {
    if ($RemoteVer) {
        $ui.bUpd.Content = 'Update v' + $RemoteVer + $(if ($Pre) { ' (Test)' })
        $ui.bUpd.Background = [System.Windows.Media.Brushes]::Gold
        $ui.bUpd.FontWeight = 'Bold'
    } else {
        $ui.bUpd.Content = $(if ($Text) { $Text } else { 'Aktuell v' + $SetupVer })
        $ui.bUpd.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
        $ui.bUpd.ClearValue([System.Windows.Controls.Control]::FontWeightProperty)
    }
}
function Get-HttpCode($e) { $code = 0; try { $code = [int]$e.Exception.Response.StatusCode } catch { }; return $code }

function Invoke-UpdateCheck([switch]$Quiet) {
    $c = Get-UpdCfg
    if (-not $c) { Set-UpdButton -Text 'Update ...'; Out-Log 'Update-Prüfung: HUPilot\Setup\Core-Update.ps1 fehlt'; return }
    $ui.bUpd.Content = 'Prüfe ...'; Step-Ui
    $chan = $(if ($c.UseBranch) { 'Branch ' + $c.Branch } else { 'Kanal ' + (Format-Channel $c.Channel) })
    try {
        $tok = Read-GhToken
        if ($c.UseBranch) {
            $h = @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HUPilot-Setup' }
            if ($tok) { $h.Authorization = 'token ' + $tok }
            $r = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri ('https://api.github.com/repos/' + $c.Owner + '/' + $c.Repo + '/contents/Stick/HUPilot/Config/version.json?ref=' + $c.Branch) -Headers $h -UseBasicParsing -TimeoutSec 20
            $txt = $(if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content })
            $rv = [string]($txt | ConvertFrom-Json).version; $pre = $true
        } else {
            $rel = Select-HMRelease @(Get-HMReleases $c.Owner $c.Repo $tok) $c.Channel -SignedOnly:$c.RequireSignature
            if (-not $rel) {
                $script:UpdRemote = ''; Set-UpdButton
                if (-not $Quiet) { Out-Log ('Update-Prüfung: kein ' + $(if ($c.RequireSignature) { 'signiertes ' }) + 'Release im ' + $chan) }
                return
            }
            $rv = [string]$rel.Version; $pre = [bool]$rel.Prerelease
        }
        $cmp = 0; try { $cmp = ([version]$rv).CompareTo([version]$SetupVer) } catch { }
        if ($cmp -gt 0) {
            $script:UpdRemote = $rv
            Set-UpdButton $rv $pre
            Out-Log ('NEUE VERSION v' + $rv + ' verfügbar (installiert: v' + $SetupVer + ', ' + $chan + ') - Knopf "Update" klicken')
        } else {
            $script:UpdRemote = ''
            Set-UpdButton
            if (-not $Quiet) { Out-Log ('Version aktuell: v' + $SetupVer + ' (' + $chan + $(if ($c.RequireSignature) { ', nur signierte Updates' }) + ')') }
        }
    } catch {
        $code = Get-HttpCode $_
        Set-UpdButton -Text 'Update: offline'
        if ($code -in 401, 403, 404) { Out-Log ('Update-Prüfung: ' + $c.Owner + '/' + $c.Repo + ' nicht erreichbar (HTTP ' + $code + ')') }
        else { Out-Log ('Versionsprüfung nicht möglich: ' + $_.Exception.Message) }
    }
}

# Pull.ps1 starten (eigenes Fenster), Setup beenden - Pull wartet, bis das Setup zu ist, und startet es danach neu
function Start-Pull([string]$Version = '') {
    if (-not (Test-Path -LiteralPath $script:PullPs)) { Out-Log ('Pull.ps1 nicht gefunden: ' + $script:PullPs); return }
    $c = Get-UpdCfg
    $what = $(if ($Version) { 'Version ' + $Version } elseif ($script:UpdRemote) { 'v' + $script:UpdRemote } else { 'die neueste Version im Kanal ' + (Format-Channel $(if ($c) { $c.Channel } else { 'Stable' })) })
    $chk = $(if ($c -and $c.RequireSignature) { 'Prüfsumme + Signatur werden geprüft' } else { 'Prüfsumme wird geprüft' })
    $q = [System.Windows.MessageBox]::Show($win, ('HUPilot-Setup schließen, ' + $what + ' von GitHub laden und neu starten?' + "`r`n`r`n" + '  Ziel:         ' + $srcStick + "`r`n" + '  Installiert:  v' + $SetupVer + "`r`n" + '  ' + $chk + "`r`n`r`n" + 'config.json, WLAN-Paket und logs bleiben unverändert.'), 'HUPilot - Update', 'YesNo', 'Question')
    if ($q -ne 'Yes') { return }
    # Ungespeicherte Aenderungen vor dem Update sichern (Pull.ps1 laesst config.json unveraendert)
    if ($script:Dirty) {
        $q = [System.Windows.MessageBox]::Show($win, ('Es gibt ungespeicherte Änderungen. Vor dem Update speichern?' + "`r`n`r`n" + 'Ja = speichern, Nein = verwerfen, Abbrechen = kein Update'), 'HUPilot - Update', 'YesNoCancel', 'Question')
        if ($q -eq 'Cancel' -or $q -eq 'None') { return }
        if ($q -eq 'Yes' -and -not (Save-Cfg)) { Show-Msg ('Nicht gespeichert: ' + $script:FieldErr + "`r`n`r`n" + 'Update abgebrochen.') 'HUPilot - Update' 'Warning'; return }
    }
    try {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:PullPs + '" -Target "' + $srcStick.TrimEnd('\') + '" -WaitPid ' + $PID
        if ($Version) { $argLine += ' -Version ' + $Version }
        Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $env:TEMP | Out-Null
        Start-Log ('Pull gestartet: ' + $argLine)
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:NoClosePrompt = $true
        $win.Close()
    } catch { Out-Log ('Update-Start fehlgeschlagen: ' + $_.Exception.Message) }
}

# Liste zur Auswahl (Versionen). Rueckgabe: gewaehlte Zeile oder $null
function Show-Pick([string]$Title, [string]$Hint, [object[]]$Rows, [string]$OkText) {
    [xml]$vx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="860" Height="440" WindowStartupLocation="CenterOwner" FontSize="13" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style x:Key="HuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="3" Background="#FF6A6A6A"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Border Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="1,0"/></Track.Thumb>
        </Track></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent"><Track x:Name="PART_Track">
              <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="0,1"/></Track.Thumb>
            </Track></Border>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <TextBlock x:Name="tHint" DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bOk" Padding="10,4" FontWeight="SemiBold" ToolTip="Markierte Zeile übernehmen (auch Doppelklick)."/>
      <Button x:Name="bNo" Content="Abbrechen" Padding="10,4" Margin="8,0,0,0" IsCancel="True" ToolTip="Ohne Auswahl schließen (Esc)."/>
    </StackPanel>
    <DataGrid x:Name="gV" ToolTip="Zeile markieren, dann übernehmen - Doppelklick geht auch." AutoGenerateColumns="True" IsReadOnly="True" SelectionMode="Single" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $vw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $vx))
    $vw.Owner = $win; if ($win.Icon) { $vw.Icon = $win.Icon }
    $vw.Title = $Title
    Set-WinFit $vw
    $g = @{}; foreach ($n in 'tHint', 'bOk', 'bNo', 'gV') { $g[$n] = $vw.FindName($n) }
    $g.tHint.Text = $Hint; $g.bOk.Content = $OkText
    $g.gV.ItemsSource = @($Rows)
    $st = @{ Sel = $null }
    $g.bOk.Add_Click({ if ($g.gV.SelectedItem) { $st.Sel = $g.gV.SelectedItem; $vw.Close() } })
    $g.gV.Add_MouseDoubleClick({ if ($g.gV.SelectedItem) { $st.Sel = $g.gV.SelectedItem; $vw.Close() } })
    $g.bNo.Add_Click({ $vw.Close() })
    [void]$vw.ShowDialog()
    return $st.Sel
}
function Show-VersionPicker {
    $c = Get-UpdCfg
    if (-not $c) { Out-Log 'HUPilot\Setup\Core-Update.ps1 fehlt'; return }
    Out-Log 'Versionen werden von GitHub gelesen ...'; Step-Ui
    try { $list = @(Get-HMReleases $c.Owner $c.Repo (Read-GhToken)) }
    catch { Out-Log ('Versionen nicht lesbar: ' + $_.Exception.Message); return }
    if (-not $list.Count) { Out-Log 'Keine Releases gefunden.'; return }
    $rows = foreach ($x in $list) {
        $cmp = 0; try { $cmp = $x.Version.CompareTo([version]$SetupVer) } catch { }
        $first = @("$($x.Notes)" -split "`r?`n" | Where-Object { "$_".Trim() -and "$_" -notmatch '^\s*#' } | ForEach-Object { ("$_".Trim().TrimStart('-', ' ', '*') -replace '\*\*|`', '') })[0]
        [pscustomobject][ordered]@{
            Version = "$($x.Version)"; Kanal = $(if ($x.Prerelease) { 'Test' } else { 'Stabil' })
            Stand = $(if ($cmp -eq 0) { 'installiert' } elseif ($cmp -lt 0) { 'älter' } else { 'neuer' })
            Datum = "$($x.Date)"; Pruefsumme = $(if ($x.ManifestUrl) { 'ja' } else { 'nein' }); Signatur = $(if ($x.SignatureUrl) { 'ja' } else { 'nein' }); Aenderungen = "$first"
        }
    }
    $sel = Show-Pick 'HUPilot - Version wählen' ('Installiert: v' + $SetupVer + '. Version markieren, dann installieren. config.json, WLAN-Paket und logs bleiben erhalten.' + $(if ($c.RequireSignature) { ' Nur signierte Versionen sind installierbar.' })) @($rows) 'Diese Version installieren'
    if (-not $sel) { return }
    if ($c.RequireSignature -and $sel.Signatur -ne 'ja') { [void][System.Windows.MessageBox]::Show($win, ('Version ' + $sel.Version + ' ist nicht signiert und kann nicht installiert werden.'), 'HUPilot - Update', 'OK', 'Warning'); return }
    Start-Pull -Version $sel.Version
}

# --- Herausgeber: Release signieren / freigeben (Zertifikat mit privatem Schluessel nur auf dessen PC) ---
function Get-SignTokenFile { return (Join-Path $env:APPDATA 'HUPilot\GitHubSignToken.xml') }
function Read-SignToken {
    $f = Get-SignTokenFile
    if (Test-Path -LiteralPath $f) { try { $c = Import-Clixml -Path $f; if ($c -is [System.Management.Automation.PSCredential]) { return $c.GetNetworkCredential().Password.Trim() } } catch { } }
    return ''
}
function Get-SignToken($Cfg) {
    $t = Read-SignToken
    if ($t) { return $t }
    if (-not (Save-GhToken (Get-SignTokenFile) ('GitHub-Token mit Schreibrecht für ' + $Cfg.Owner + '/' + $Cfg.Repo + " (Fine-grained PAT, 'Contents: Read and write'). Wird verschlüsselt nur für deinen Windows-Benutzer gespeichert."))) { return '' }
    return (Read-SignToken)
}
function Test-CanSign {
    $c = Get-UpdCfg
    if (-not $c -or -not (Get-Command Get-HMSigningCert -ErrorAction SilentlyContinue)) { return $false }
    return [bool](Get-HMSigningCert $c.SignerThumbprint)
}
function Show-Msg([string]$Text, [string]$Title, [string]$Icon = 'Information', $Owner = $null) { if (-not $Owner) { $Owner = $win }; [void][System.Windows.MessageBox]::Show($Owner, $Text, $Title, 'OK', $Icon) }

function Start-ReleaseSigning {
    $c = Get-UpdCfg; if (-not $c) { return }
    Out-Log ('=== Release signieren (' + $c.Owner + '/' + $c.Repo + ') ===')
    $cert = Get-HMSigningCert $c.SignerThumbprint
    if (-not $cert) { $m = 'Signatur-Zertifikat ' + $c.SignerThumbprint + ' mit privatem Schlüssel ist auf diesem PC nicht vorhanden (oder abgelaufen).'; Out-Log $m; Show-Msg $m 'Release signieren' 'Error'; return }
    Out-Log ('Zertifikat: ' + $cert.Subject + ' - gültig bis ' + $cert.NotAfter.ToString('dd.MM.yyyy'))
    $tok = Get-SignToken $c
    if (-not $tok) { Out-Log 'Abgebrochen: kein GitHub-Token mit Schreibrecht.'; return }
    Step-Ui
    try { $all = @(Get-HMReleases $c.Owner $c.Repo $tok) } catch { $m = 'Releases nicht lesbar: ' + $_.Exception.Message; Out-Log $m; Show-Msg $m 'Release signieren' 'Error'; return }
    $tags = @($all | Where-Object { $_.ManifestUrl -and -not $_.SignatureUrl } | ForEach-Object { "$($_.Tag)" })
    $noMan = @($all | Where-Object { -not $_.ManifestUrl } | Select-Object -First 5 | ForEach-Object { "$($_.Tag)" })
    if ($noMan.Count) { Out-Log ('Ohne Prüfsummen-Datei (automatische Tests noch nicht fertig oder fehlgeschlagen): ' + ($noMan -join ', ')) }
    if (-not $tags.Count) { Out-Log 'Nichts zu signieren - alle Releases mit Prüfsumme sind bereits signiert.'; Show-Msg ('Nichts zu signieren - alle Releases mit Prüfsumme sind bereits signiert.' + "`r`n`r`n" + 'Eine neue Version entsteht erst mit dem Merge nach main (danach ein paar Minuten warten, bis die automatischen Tests die Prüfsummen-Datei angehängt haben).') 'Release signieren'; return }
    $q = [System.Windows.MessageBox]::Show($win, ('Diese Releases jetzt signieren?' + "`r`n`r`n" + ($tags -join ', ') + "`r`n`r`n" + 'Danach werden sie allen Installationen angeboten (je nach Kanal Stabil/Test).'), 'Release signieren', 'YesNo', 'Question')
    if ($q -ne 'Yes') { Out-Log 'Signieren abgebrochen.'; return }
    Out-Log ('Signiere ' + ($tags -join ', ') + ' ...'); Step-Ui
    try { $res = @(Invoke-HMReleaseSigning $c.Owner $c.Repo $c.SignerThumbprint $tok ([string[]]$tags)) }
    catch { $m = 'Signieren fehlgeschlagen: ' + $_.Exception.Message; Out-Log $m; Show-Msg $m 'Release signieren' 'Error'; return }
    foreach ($x in $res) { Out-Log ($x.Tag + ': ' + $x.Text) }
    $sum = ($res | ForEach-Object { $_.Tag + ': ' + $_.Text }) -join "`r`n"
    if (@($res | Where-Object { -not $_.Ok }).Count) {
        Show-Msg ('Signieren mit Fehlern:' + "`r`n`r`n" + $sum) 'Release signieren' 'Error'
        if (@($res | Where-Object { -not $_.Ok -and "$($_.Text)" -match 'Schreibrecht' }).Count) { Remove-Item -LiteralPath (Get-SignTokenFile) -Force -ErrorAction SilentlyContinue; Out-Log 'Gespeicherter Schreib-Token gelöscht - beim nächsten Signieren neu eingeben.' }
    } else { Show-Msg ('Signiert:' + "`r`n`r`n" + $sum + "`r`n`r`n" + 'Nächster Schritt: Rechtsklick auf Update > Release freigeben.') 'Release signieren' }
    Invoke-UpdateCheck -Quiet
}

function Start-ReleasePublish {
    $c = Get-UpdCfg; if (-not $c) { return }
    Out-Log ('=== Release freigeben (' + $c.Owner + '/' + $c.Repo + ') ===')
    $tok = Get-SignToken $c
    if (-not $tok) { Out-Log 'Abgebrochen: kein GitHub-Token mit Schreibrecht.'; return }
    Step-Ui
    try { $l = @(Get-HMReleases $c.Owner $c.Repo $tok) } catch { $m = 'Releases nicht lesbar: ' + $_.Exception.Message; Out-Log $m; Show-Msg $m 'Release freigeben' 'Error'; return }
    $stable = @($l | Where-Object { -not $_.Prerelease } | Select-Object -First 1)[0]
    $cand = @($l | Where-Object { $_.Prerelease -and $_.ManifestUrl -and $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | Select-Object -First 1)[0]
    $uns = @($l | Where-Object { $_.Prerelease -and -not $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | ForEach-Object { $_.Tag })
    $stTxt = $(if ($stable) { $stable.Tag } else { '-' })
    Out-Log ('Bisher freigegeben: ' + $stTxt)
    if (-not $cand) { $m = 'Kein signiertes Vorab-Release neuer als ' + $stTxt + '.' + $(if ($uns.Count) { ' Noch nicht signiert: ' + ($uns -join ', ') + " - zuerst 'Release signieren'." }); Out-Log $m; Show-Msg $m 'Release freigeben' 'Warning'; return }
    $q = [System.Windows.MessageBox]::Show($win, ($cand.Tag + ' jetzt freigeben?' + "`r`n`r`n" + 'Danach ist es im Kanal Stabil die neueste Version und wird ALLEN Installationen als Update angeboten.' + "`r`n" + 'Bisher freigegeben: ' + $stTxt), 'Release freigeben', 'YesNo', 'Question')
    if ($q -ne 'Yes') { Out-Log 'Freigabe abgebrochen.'; return }
    Out-Log ('Gebe ' + $cand.Tag + ' frei ... (Signatur wird vorher erneut geprüft)'); Step-Ui
    try {
        Publish-HMRelease $c.Owner $c.Repo $cand.Tag $c.SignerThumbprint $tok
        Out-Log ($cand.Tag + ': freigegeben (Kanal Stabil)')
        Show-Msg ($cand.Tag + ' ist freigegeben (Kanal Stabil) und wird allen Installationen als Update angeboten.') 'Release freigeben'
        Invoke-UpdateCheck -Quiet
    } catch {
        $code = Get-HttpCode $_
        if ($code -in 401, 403, 404) { Remove-Item -LiteralPath (Get-SignTokenFile) -Force -ErrorAction SilentlyContinue; $m = 'Freigabe fehlgeschlagen: kein Schreibrecht (HTTP ' + $code + ') - gespeicherter Token wurde gelöscht, beim nächsten Versuch neu eingeben.' }
        else { $m = 'Freigabe fehlgeschlagen: ' + $_.Exception.Message }
        Out-Log $m; Show-Msg $m 'Release freigeben' 'Error'
    }
}

$ui.bUpd.Add_Click({ if ($script:UpdRemote) { Start-Pull } else { Invoke-UpdateCheck } })
$cmU = New-Object System.Windows.Controls.ContextMenu
$addU = { param($h, $sb) $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $h; $mi.Add_Click($sb); [void]$cmU.Items.Add($mi); $mi }
[void](& $addU 'Andere Version / Vorversion installieren ...' { Show-VersionPicker })
[void](& $addU 'Jetzt nach Updates suchen' { Invoke-UpdateCheck })
[void]$cmU.Items.Add((New-Object System.Windows.Controls.Separator))
$script:miStable = & $addU 'Kanal Stabil (nur freigegebene Versionen)' { Set-UpdSetting 'Channel' 'Stable'; Out-Log 'Update-Kanal: Stabil'; Invoke-UpdateCheck }
$script:miTest   = & $addU 'Kanal Test (auch Vorab-Versionen)' { Set-UpdSetting 'Channel' 'Test'; Out-Log 'Update-Kanal: Test'; Invoke-UpdateCheck }
[void](& $addU 'GitHub-Token (nur privates Repo) ...' {
    $f = Get-GhTokenFile; $has = Test-Path -LiteralPath $f
    $a = [System.Windows.MessageBox]::Show($win, ('Gespeicherter GitHub-Token: ' + $(if ($has) { 'vorhanden' } else { 'keiner' }) + "`r`n`r`n" + "Nur für PRIVATE Repos nötig (Fine-grained PAT, nur 'Contents: Read')." + "`r`n`r`n" + 'Ja = Token eingeben/ersetzen' + "`r`n" + 'Nein = gespeicherten Token löschen'), 'GitHub-Token', 'YesNoCancel', 'Question')
    if ($a -eq 'Yes') { if (Save-GhToken $f 'GitHub-Token (Nur-Lese) als Kennwort eingeben (DPAPI, nur für deinen Benutzer lesbar)') { Out-Log 'GitHub-Token gespeichert'; Invoke-UpdateCheck } }
    elseif ($a -eq 'No' -and $has) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; Out-Log 'GitHub-Token gelöscht' }
})
$sepU = New-Object System.Windows.Controls.Separator
[void]$cmU.Items.Add($sepU)
$miSign = & $addU 'Release signieren (Herausgeber) ...' { Start-ReleaseSigning }
$miPub  = & $addU 'Release freigeben (Herausgeber) ...' { Start-ReleasePublish }
$script:UpdSignItems = @($sepU, $miSign, $miPub)
$cmU.Add_Opened({
    $c = Get-UpdCfg
    $script:miStable.IsChecked = ($c -and $c.Channel -ne 'Test'); $script:miTest.IsChecked = ($c -and $c.Channel -eq 'Test')
    $v = $(if (Test-CanSign) { 'Visible' } else { 'Collapsed' }); foreach ($m in $script:UpdSignItems) { $m.Visibility = $v }
})
$ui.bUpd.ContextMenu = $cmU
$win.Add_KeyDown({ if ($_.Key -eq 'F1') { & $ShowHelp } })
$ui.bReload.Add_Click({ Update-Drives })

$ui.bLoad.Add_Click({
    $p = $srcCfg
    if (-not (Test-Path $p)) { Out-Log ('Noch keine config.json in der Quelle: ' + $p + ' - Felder ausfüllen, dann 3. Speichern'); return }
    if ($script:Dirty) {
        $q = [System.Windows.MessageBox]::Show($win, ('Es gibt ungespeicherte Änderungen.' + "`r`n`r`n" + 'Verwerfen und config.json neu laden?'), 'HUPilot - Neu laden', 'YesNo', 'Warning')
        if ($q -ne 'Yes') { Out-Log 'Neu laden abgebrochen - Änderungen bleiben im Fenster'; return }
    }
    $script:Loading = $true
    try {
        $c = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $ui.tTenant.Text = [string]$c.Tenant; $ui.tTenantId.Text = [string]$c.TenantId; $ui.tClientId.Text = [string]$c.ClientId
        Set-Secret ([string]$c.ClientSecret); $ui.tTag.Text = [string]$c.GroupTag; $ui.tTagChoices.Text = (@($c.TagChoices) -join ', ')
        $ui.tSsid.Text = [string]$c.WlanSsid; Set-Masked 'Key' ([string]$c.WlanKey)
        $ui.tAdmName.Text = [string]$c.AdminName; Set-Masked 'AdmPw' ([string]$c.AdminPassword); $ui.cAskUser.IsChecked = ($c.AskUser -eq $true)
        $ui.tAdm2Name.Text = [string]$c.Admin2Name; Set-Masked 'Adm2Pw' ([string]$c.Admin2Password); $ui.cRmPkg.IsChecked = ($c.RemoveOtherPackages -eq $true)
        Set-EdKey ([string]$c.EditionKey)
        # Ablaufdatum des Secrets gilt nur fuer genau dieses Secret (bei geaendertem Secret: unbekannt)
        $script:SecretExpLoaded = [string]$c.SecretExpires; $script:SecretExpLoadedFor = Get-StrHash ([string]$c.ClientSecret).Trim()
        $script:Extra = @{}
        foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -notin 'Tenant','TenantId','ClientId','ClientSecret','GroupTag','TagChoices','WlanSsid','WlanKey','AdminName','AdminPassword','Admin2Name','Admin2Password','AskUser','RemoveOtherPackages','EditionKey','SecretExpires') { $script:Extra[$pr.Name] = $pr.Value } }
        Out-Log ('Geladen: ' + $p)
    } catch { Out-Log ('Fehler beim Laden: ' + $_.Exception.Message) }
    finally { $script:Loading = $false }
    $script:SavedSnap = Get-CfgSnap
    Update-Dirty
})

# ---------- Ungespeicherte Aenderungen: Vergleich mit dem zuletzt geladenen/gespeicherten Stand ----------
$script:Dirty = $false; $script:Loading = $false; $script:SavedSnap = $null
function Get-CfgSnap { return (Get-Cfg | ConvertTo-Json -Depth 3 -Compress) }
function Update-Dirty {
    if ($script:Loading -or $null -eq $script:SavedSnap) { return }
    $d = ((Get-CfgSnap) -cne $script:SavedSnap)
    $script:Dirty = $d
    $ui.tDirty.Visibility = $(if ($d) { 'Visible' } else { 'Collapsed' })
    $win.Title = 'HUPilot-Setup v' + $SetupVer + $(if ($d) { '  * (ungespeichert)' } else { '' })
    [void](Update-PkgState)
}
foreach ($n in 'tTenant','tTenantId','tClientId','tSecret','tEdKey','tTag','tTagChoices','tSsid','tKey','tAdmName','tAdmPw','tAdm2Name','tAdm2Pw') { $ui[$n].Add_TextChanged({ Update-Dirty }) }
foreach ($n in 'pSecret','pEdKey','pKey','pAdmPw','pAdm2Pw') { $ui[$n].Add_PasswordChanged({ Update-Dirty }) }
foreach ($n in 'cAskUser','cRmPkg') { $ui[$n].Add_Click({ Update-Dirty }) }

# ---------- Hilfen: SHA256, Datum in UTC ----------
function Get-BytesSha([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function Get-StrHash([string]$s) { return (Get-BytesSha ([System.Text.Encoding]::UTF8.GetBytes([string]$s))) }
function Get-FileSha([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}
# Graph-Datum (Text mit Z oder DateTime, je nach PowerShell-Version) sicher nach UTC
function ConvertTo-UtcDate($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }
        return $v.ToUniversalTime()
    }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$v, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal), [ref]$d)) { return [datetime]::SpecifyKind($d, [DateTimeKind]::Utc) }
    return $null
}
# Vertrag mit go.ps1: SecretExpires = UTC als yyyy-MM-ddTHH:mm:ssZ, leer = unbekannt
function Format-UtcText($d) { if (-not $d) { return '' } return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z' }
# Warnstufe fuer das Secret beim Kopieren: expired / soon (< 3 Tage) / ok / unknown
function Get-SecretWarnLevel($EndUtc, $NowUtc) {
    if (-not $EndUtc) { return 'unknown' }
    $span = $EndUtc - $NowUtc
    if ($span.TotalSeconds -le 0) { return 'expired' }
    if ($span.TotalDays -lt 3) { return 'soon' }
    return 'ok'
}
$script:SecretEnd = $null; $script:SecretEndFor = ''; $script:SecretExpLoaded = ''; $script:SecretExpLoadedFor = ''
# Ablaufdatum des gerade eingetragenen Secrets (aus der letzten Pruefung, sonst aus config.json, wenn es dasselbe Secret ist)
function Get-SecretExpiresValue([string]$Secret) {
    $hh = Get-StrHash $Secret
    if ($script:SecretEnd -and $script:SecretEndFor -eq $hh) { return (Format-UtcText $script:SecretEnd) }
    if ($script:SecretExpLoaded -and $script:SecretExpLoadedFor -eq $hh) { return $script:SecretExpLoaded }
    return ''
}

# ---------- Anmeldung: Fehlerart unterscheiden (kein Netz / Secret abgelaufen / Secret falsch / sonst) ----------
function Get-TokenErrorKind([string]$Message, [bool]$HasResponse) {
    if ($Message -match 'AADSTS7000222') { return 'expired' }
    if ($Message -match 'AADSTS7000215') { return 'wrong' }
    if ($Message -match 'AADSTS\d+') { return 'config' }
    if (-not $HasResponse) { return 'net' }
    if ($Message -match 'Remotename|remote name|No such host|nicht aufgel|timed out|Zeitüberschreitung|Zeitlimit|timeout|Unable to connect|Verbindung mit dem Remoteserver|actively refused') { return 'net' }
    return 'other'
}
$script:TokenErr = ''; $script:TokenMsg = ''
function Get-ApiToken {
    if (-not (Test-Fields @('TenantId', 'ClientId', 'ClientSecret'))) { $script:TokenErr = 'fields'; $script:TokenMsg = $script:FieldErr; return $null }
    $c = Get-Cfg
    $script:TokenErr = ''; $script:TokenMsg = ''
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{ grant_type = 'client_credentials'; client_id = $c.ClientId; client_secret = $c.ClientSecret; scope = 'https://graph.microsoft.com/.default' }
        return (Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $c.TenantId + '/oauth2/v2.0/token') -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30).access_token
    } catch {
        $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }
        $hasResp = $false; try { $hasResp = ($null -ne $_.Exception.Response) } catch { }
        $kind = Get-TokenErrorKind $m $hasResp
        $script:TokenErr = $kind
        $txt = $m
        if ($kind -eq 'expired') { $txt = 'Secret ABGELAUFEN - in Entra bei der App ein neues Geheimnis anlegen und den Wert eintragen' }
        elseif ($kind -eq 'wrong') { $txt = 'Secret FALSCH (Secret-ID statt Wert?)' }
        elseif ($kind -eq 'net') { $txt = 'keine Verbindung zu Microsoft (Internet, Proxy?) - Secret nicht geprüft: ' + $_.Exception.Message }
        $script:TokenMsg = $txt
        Out-Log ('FEHLER Anmeldung: ' + $txt)
        return $null
    }
}

function Format-Rest([TimeSpan]$Span) {
    if ($Span.TotalSeconds -le 0) { return 'abgelaufen' }
    $d = [int][Math]::Floor($Span.TotalDays)
    return ('noch ' + $(if ($d) { '' + $d + ' Tag' + $(if ($d -ne 1) { 'e' } else { '' }) + ' ' } else { '' }) + $Span.Hours + ' Std')
}
function Show-SecretExpiry([string]$Token) {
    # Secret-Ablauf (optional: braucht Application.Read.All fuer die App). Merkt das Ablaufdatum des verwendeten Secrets fuer SecretExpires.
    $h = @{ Authorization = 'Bearer ' + $Token }
    try {
        $c = Get-Cfg
        $app = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ("https://graph.microsoft.com/v1.0/applications(appId='" + $c.ClientId + "')?`$select=displayName,passwordCredentials") -Headers $h -TimeoutSec 30
        $hint = $c.ClientSecret.Substring(0, [Math]::Min(3, $c.ClientSecret.Length))
        $mine = @($app.passwordCredentials | Where-Object { $_.hint -ceq $hint })
        $list = $(if ($mine.Count) { $mine } else { @($app.passwordCredentials) })
        $minDays = $null; $minEnd = $null; $minUtc = $null
        foreach ($pc in $list) {
            $utc = ConvertTo-UtcDate $pc.endDateTime
            if (-not $utc) { continue }
            $end = $utc.ToLocalTime()
            $span = $end - (Get-Date)
            $days = $span.TotalDays
            if ($null -eq $minDays -or $days -lt $minDays) { $minDays = $days; $minEnd = $end; $minUtc = $utc }
            $txt = 'Secret "' + $pc.displayName + '" (' + $pc.hint + '...) gültig bis ' + $end.ToString('dd.MM.yyyy HH:mm') + '  -> ' + (Format-Rest $span)
            if ($days -lt 0) { $txt = 'ACHTUNG ABGELAUFEN: ' + $txt } elseif ($days -lt 1) { $txt = 'ACHTUNG BALD ABGELAUFEN: ' + $txt }
            Out-Log $txt
        }
        if (-not $mine.Count) { Out-Log '  (verwendetes Secret nicht eindeutig erkannt - alle Secrets der App angezeigt)' }
        if ($mine.Count -and $null -ne $minDays) {
            $script:SecretEnd = $minUtc; $script:SecretEndFor = Get-StrHash $c.ClientSecret
            Set-SubSecret ('Secret gültig bis ' + $minEnd.ToString('dd.MM.yyyy HH:mm') + ' (' + (Format-Rest ($minEnd - (Get-Date))) + ')') ($minDays -lt 1)
        }
    } catch {
        Out-Log 'Secret-Ablauf nicht lesbar (optional: Anwendungsberechtigung Application.Read.All für HUPilot-Upload)'
    }
}
function Set-SubSecret([string]$Text, [bool]$Warn) {
    $ui.tSub.Text = $Text
    $ui.tSub.Foreground = $(if ($Warn) { [System.Windows.Media.Brushes]::Firebrick } else { [System.Windows.Media.Brushes]::DimGray })
}
# Autopilot lesen (Berechtigung DeviceManagementServiceConfig.ReadWrite.All). Rueckgabe: Fehlertext oder '' = ok
function Test-ApAccess([string]$Token) {
    try {
        $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?$top=1' -Headers @{ Authorization = 'Bearer ' + $Token } -TimeoutSec 30
        Out-Log ('Autopilot-Zugriff OK (' + @($r.value).Count + ' Eintrag gelesen)')
        return ''
    } catch { Out-Log ('FEHLER Autopilot-Zugriff (Berechtigung DeviceManagementServiceConfig.ReadWrite.All?): ' + $_.Exception.Message); return $_.Exception.Message }
}

$ui.bTest.Add_Click({
    Set-Step 'Test' 'run'; Step-Ui
    $tok = Get-ApiToken
    if (-not $tok) { Set-Step 'Test' $(if ($script:TokenErr -eq 'net') { 'warn' } else { 'err' }) $script:TokenMsg; return }
    Out-Log 'Token OK'
    $apErr = Test-ApAccess $tok
    Show-SecretExpiry -Token $tok
    if ($apErr) { Set-Step 'Test' 'err' 'kein Zugriff auf Autopilot' } else { Set-Step 'Test' 'ok' }
})

function Save-Cfg {
    if (-not (Test-Fields @('Tenant', 'TenantId', 'ClientId', 'ClientSecret', 'GroupTag', 'WlanSsid', 'WlanKey') -Admin)) { Set-Step 'Write' 'err' $script:FieldErr; return $false }
    try {
        $o = Get-Cfg
        $o['SecretExpires'] = Get-SecretExpiresValue ([string]$o.ClientSecret)
        [System.IO.File]::WriteAllText($srcCfg, ($o | ConvertTo-Json -Depth 3), $enc)
        Out-Log ('Gespeichert: ' + $srcCfg + $(if ($o.SecretExpires) { '  (Secret gültig bis ' + (ConvertTo-UtcDate $o.SecretExpires).ToLocalTime().ToString('dd.MM.yyyy HH:mm') + ')' } else { '' }))
        $script:SecretExpLoaded = [string]$o.SecretExpires; $script:SecretExpLoadedFor = Get-StrHash ([string]$o.ClientSecret)
        $script:SavedSnap = Get-CfgSnap
        Update-Dirty
        Set-Step 'Write' 'ok'
        return $true
    } catch { $script:FieldErr = 'Speichern fehlgeschlagen: ' + $_.Exception.Message; Out-Log ('FEHLER Speichern: ' + $_.Exception.Message); Set-Step 'Write' 'err' $_.Exception.Message; return $false }
}

$ui.bWrite.Add_Click({ [void](Save-Cfg) })

# ---------- WLAN-Paket: Fingerabdruck (kein Klartext) neben dem Paket, Stand aktuell / veraltet / fehlt ----------
#   HUPilot-WLAN.fingerprint.json: SHA256 ueber SSID, WLAN-Kennwort, Admin-Namen und -Kennwoerter (mit Zufallswert) + SHA256 der ppkg.
#   Liegt neben dem Paket und uebersteht Updates (Pull.ps1 schont HUPilot\HUPilot-WLAN.*).
$srcPkgFp = Join-Path $srcHU 'HUPilot-WLAN.fingerprint.json'
function Get-PkgInputHash($c, [string]$Salt) {
    $s = (@('HUPilot-WLAN v1', $Salt, [string]$c.WlanSsid, [string]$c.WlanKey, [string]$c.AdminName, [string]$c.AdminPassword, [string]$c.Admin2Name, [string]$c.Admin2Password) -join "`n")
    return (Get-StrHash $s)
}
function Write-PkgFingerprint($c, [string]$PkgPath, [string]$FpPath) {
    $salt = [guid]::NewGuid().ToString('N')
    $o = [ordered]@{ Version = 1; Salt = $salt; Input = (Get-PkgInputHash $c $salt); Package = (Get-FileSha $PkgPath); Built = (Format-UtcText ([datetime]::UtcNow)) }
    [System.IO.File]::WriteAllText($FpPath, ([pscustomobject]$o | ConvertTo-Json), $enc)
}
# Rueckgabe: aus (kein Paket verwendet), fremd (anderer Paketname), fehlt, unbekannt (ohne Fingerabdruck), veraltet, aktuell
function Get-PkgState($c, [string]$PkgPath, [string]$FpPath) {
    $wp = [string]$c.WlanPackage
    if (-not $wp) { return 'aus' }
    if ($wp -ne (Split-Path $PkgPath -Leaf)) { return 'fremd' }
    if (-not [System.IO.File]::Exists($PkgPath)) { return 'fehlt' }
    if (-not [System.IO.File]::Exists($FpPath)) { return 'unbekannt' }
    try {
        $fp = Get-Content -LiteralPath $FpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$fp.Input -ne (Get-PkgInputHash $c ([string]$fp.Salt))) { return 'veraltet' }
        if ([string]$fp.Package -ne (Get-FileSha $PkgPath)) { return 'veraltet' }
        return 'aktuell'
    } catch { return 'unbekannt' }
}
$script:PkgStateText = @{
    aus = @('WLAN-Paket: nicht verwendet', 'Gray', 'open'); fremd = @('WLAN-Paket: eigenes (nicht geprüft)', 'Gray', 'open')
    fehlt = @('WLAN-Paket: fehlt', '#FFC62828', 'err'); unbekannt = @('WLAN-Paket: Stand unbekannt (neu bauen)', '#FFE65100', 'warn')
    veraltet = @('WLAN-Paket: veraltet (neu bauen)', '#FFE65100', 'warn'); aktuell = @('WLAN-Paket: aktuell', '#FF2E7D32', 'ok')
}
function Update-PkgState {
    $s = 'unbekannt'
    try { $s = Get-PkgState (Get-Cfg) $srcPkg $srcPkgFp } catch { }
    $t = $script:PkgStateText[$s]
    $ui.tPkg.Text = $t[0]
    try { $ui.tPkg.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($t[1])) } catch { }
    Set-Step 'Pkg' $t[2]
    return $s
}

# Kopierte Dateien kontrollieren: SHA256 von go.cmd, go.ps1, config.json, WLAN-Paket. Rueckgabe: Liste der Abweichungen
function Test-StickCopy([string]$dr, [byte[]]$CfgBytes, [string]$PkgName) {
    $bad = @()
    $chk = @(@('go.cmd', (Join-Path $srcStick 'go.cmd')), @('HUPilot\go.ps1', (Join-Path $srcHU 'go.ps1')))
    if ($PkgName -and [System.IO.File]::Exists((Join-Path $srcHU $PkgName))) { $chk += , @(('HUPilot\' + $PkgName), (Join-Path $srcHU $PkgName)) }
    foreach ($x in $chk) {
        $dst = Join-Path ($dr + '\') $x[0]
        try {
            if (-not [System.IO.File]::Exists($dst)) { $bad += ($x[0] + ' fehlt'); continue }
            if ((Get-FileSha $dst) -ne (Get-FileSha $x[1])) { $bad += ($x[0] + ' weicht ab') }
        } catch { $bad += ($x[0] + ': ' + $_.Exception.Message) }
    }
    $dc = Join-Path ($dr + '\') 'HUPilot\config.json'
    try {
        if (-not [System.IO.File]::Exists($dc)) { $bad += 'HUPilot\config.json fehlt' }
        elseif ((Get-FileSha $dc) -ne (Get-BytesSha $CfgBytes)) { $bad += 'HUPilot\config.json weicht ab' }
    } catch { $bad += ('HUPilot\config.json: ' + $_.Exception.Message) }
    return $bad
}
# config.json ohne MAK fuer einen einzelnen Stick (Quelle bleibt unveraendert)
function Get-CfgBytesNoMak([string]$Path) {
    $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($o.PSObject.Properties.Name -contains 'EditionKey') { $o.EditionKey = '' } else { $o | Add-Member -NotePropertyName EditionKey -NotePropertyValue '' }
    return $enc.GetBytes(($o | ConvertTo-Json -Depth 3))
}
$script:CopyErr = ''
function Copy-ToStick([string]$dr, [bool]$WithMak = $true) {
    $script:CopyErr = ''
    try {
        if (-not [System.IO.Directory]::Exists($dr + '\')) { throw ('Stick ' + $dr + ' nicht mehr vorhanden (abgezogen?)') }
        foreach ($f in 'go.cmd', 'diag.cmd', 'HUPilot-Setup.cmd') { $sf = Join-Path $srcStick $f; if (Test-Path $sf) { Copy-Item -Path $sf -Destination (Join-Path $dr $f) -Force -ErrorAction Stop } }
        $dst = Join-Path $dr 'HUPilot'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        foreach ($it in @(Get-ChildItem -Path $srcHU -Force | Where-Object { $_.Name -ne 'logs' -and -not $_.Name.StartsWith('_') })) {
            Copy-Item -Path $it.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
        }
        # persoenliche/zwischenzeitliche Dateien nicht auf den Stick (GitHub-Token, Update-Journal, Update-Reste)
        foreach ($x in @(Get-ChildItem -Path $dst -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'GitHubToken_*.xml' -or $_.Name -eq 'pull-journal.json' -or $_.Name -match '\.(pullold|pulltmp)$' })) { Remove-Item -LiteralPath $x.FullName -Force -ErrorAction SilentlyContinue }
        # Ohne MAK: nur die config.json dieses Sticks bekommt EditionKey leer
        $cfgBytes = [System.IO.File]::ReadAllBytes($srcCfg)
        if (-not $WithMak) {
            $cfgBytes = Get-CfgBytesNoMak $srcCfg
            [System.IO.File]::WriteAllBytes((Join-Path $dst 'config.json'), $cfgBytes)
            Out-Log ('Stick ' + $dr + ': ohne MAK (EditionKey leer)')
        }
        Out-Log ('Auf Stick kopiert: ' + $srcStick + ' -> ' + $dr + '\  (ohne logs und _Ordner)')
        $rootPkg = @(Get-ChildItem -Path ($dr + '\') -Filter *.ppkg -File -ErrorAction SilentlyContinue)
        if ($rootPkg.Count) { Out-Log ('ACHTUNG: .ppkg im Hauptverzeichnis entfernen (wird sonst im OOBE angewendet): ' + (($rootPkg | ForEach-Object { $_.Name }) -join ', ')) }
        # Schreibcache leeren, dann kontrollieren
        try { Write-VolumeCache -DriveLetter $dr.Substring(0, 1) -ErrorAction Stop } catch { }
        $bad = @(Test-StickCopy $dr $cfgBytes ([string](Get-Cfg).WlanPackage))
        if ($bad.Count) { $script:CopyErr = 'Kontrolle nicht bestanden: ' + ($bad -join ', '); Out-Log ('FEHLER ' + $dr + ': ' + $script:CopyErr); return $false }
        Out-Log ('Kontrolle ' + $dr + ' OK: go.cmd, go.ps1, config.json' + $(if ((Get-Cfg).WlanPackage -and (Test-Path $srcPkg)) { ', WLAN-Paket' } else { '' }) + ' stimmen mit der Quelle überein (SHA256)')
        return $true
    } catch { $script:CopyErr = $_.Exception.Message; Out-Log ('FEHLER kopieren ' + $dr + ': ' + $_.Exception.Message); return $false }
}

# Vor dem Kopieren: WLAN-Paket fehlt oder veraltet -> nicht still kopieren. Rueckgabe $false = abbrechen
function Confirm-PkgForCopy($Owner) {
    $st = Update-PkgState
    if ($st -in 'aktuell', 'aus', 'fremd') { return $true }
    $hasIcd = Test-Path $icd
    if ($st -eq 'fehlt') {
        Out-Log 'ACHTUNG: kein HUPilot-WLAN.ppkg in der Quelle - erst 4. WLAN-Paket bauen (oder "WlanPackage": "")'
        if ($hasIcd) {
            $q = [System.Windows.MessageBox]::Show($Owner, ('In der Quelle gibt es noch kein WLAN-Paket.' + "`r`n`r`n" + 'Ja = jetzt bauen und dann kopieren' + "`r`n" + 'Nein = ohne WLAN-Paket kopieren' + "`r`n" + 'Abbrechen = nichts kopieren'), 'HUPilot - WLAN-Paket fehlt', 'YesNoCancel', 'Warning')
            if ($q -eq 'Yes') { return (Build-Package -NoSave) }
            return ($q -eq 'No')
        }
        $q = [System.Windows.MessageBox]::Show($Owner, ('In der Quelle gibt es noch kein WLAN-Paket, und ICD.exe (Windows ADK) fehlt auf diesem PC.' + "`r`n`r`n" + 'Trotzdem ohne WLAN-Paket kopieren?'), 'HUPilot - WLAN-Paket fehlt', 'YesNo', 'Warning')
        return ($q -eq 'Yes')
    }
    $why = $(if ($st -eq 'veraltet') { 'WLAN oder lokale Admins wurden seit dem Bau des WLAN-Pakets geändert - das Paket ist veraltet.' } else { 'Ob das WLAN-Paket zu WLAN und lokalen Admins passt, ist unbekannt (gebaut mit einer älteren Version).' })
    Out-Log ('ACHTUNG: ' + $why)
    if ($hasIcd) {
        $q = [System.Windows.MessageBox]::Show($Owner, ($why + "`r`n`r`n" + 'Ja = Paket jetzt neu bauen und dann kopieren' + "`r`n" + 'Nein = altes Paket trotzdem kopieren' + "`r`n" + 'Abbrechen = nichts kopieren'), 'HUPilot - WLAN-Paket', 'YesNoCancel', 'Warning')
        if ($q -eq 'Yes') { return (Build-Package -NoSave) }
        if ($q -eq 'No') { Out-Log 'Altes WLAN-Paket wird trotzdem kopiert'; return $true }
        return $false
    }
    $q = [System.Windows.MessageBox]::Show($Owner, ($why + "`r`n`r`n" + 'ICD.exe (Windows ADK) fehlt auf diesem PC, neu bauen geht hier nicht.' + "`r`n" + 'Altes Paket trotzdem kopieren?'), 'HUPilot - WLAN-Paket', 'YesNo', 'Warning')
    if ($q -eq 'Yes') { Out-Log 'Altes WLAN-Paket wird trotzdem kopiert'; return $true }
    return $false
}
# Vor dem Kopieren: Secret abgelaufen (Rueckfrage) oder bald (Hinweis), MAK mit auf den Stick? Rueckgabe $null = abbrechen, sonst @{ WithMak }
function Confirm-CopyPrereqs([string]$Target, $Owner) {
    $c = Get-Cfg
    $endTxt = Get-SecretExpiresValue ([string]$c.ClientSecret)
    $end = ConvertTo-UtcDate $endTxt
    $lvl = Get-SecretWarnLevel $end ([datetime]::UtcNow)
    if ($lvl -eq 'expired') {
        $q = [System.Windows.MessageBox]::Show($Owner, ('Das Secret ist am ' + $end.ToLocalTime().ToString('dd.MM.yyyy HH:mm') + ' abgelaufen.' + "`r`n" + 'Mit diesem Stick kann go.ps1 keine Geräte hochladen.' + "`r`n`r`n" + 'Besser: in Entra ein neues Geheimnis anlegen, bei "Secret" eintragen, speichern.' + "`r`n`r`n" + 'Trotzdem kopieren?'), 'HUPilot - Secret abgelaufen', 'YesNo', 'Warning')
        if ($q -ne 'Yes') { Out-Log 'Kopieren abgebrochen: Secret abgelaufen'; return $null }
        Out-Log 'ACHTUNG: Secret abgelaufen - trotzdem kopiert'
    } elseif ($lvl -eq 'soon') {
        $t = 'Hinweis: Das Secret läuft am ' + $end.ToLocalTime().ToString('dd.MM.yyyy HH:mm') + ' ab (' + (Format-Rest ($end.ToLocalTime() - (Get-Date))) + '). Danach lädt dieser Stick keine Geräte mehr hoch - rechtzeitig erneuern.'
        Out-Log $t
        [void][System.Windows.MessageBox]::Show($Owner, $t, 'HUPilot - Secret läuft bald ab', 'OK', 'Information')
    }
    $withMak = $true
    if ($c.EditionKey) {
        $tail = $(if ($c.EditionKey.Length -ge 5) { $c.EditionKey.Substring($c.EditionKey.Length - 5) } else { '' })
        $q = [System.Windows.MessageBox]::Show($Owner, ('Im Feld "MAK (Pro)" steht ein Schlüssel (endet auf ' + $tail + ').' + "`r`n`r`n" + 'MAK mit auf ' + $Target + '?' + "`r`n`r`n" + 'Ja = mit MAK (nur für Geräte mit Windows Home nötig)' + "`r`n" + 'Nein = ohne MAK, die Quelle bleibt unverändert' + "`r`n" + 'Abbrechen = nichts kopieren'), 'HUPilot - MAK auf den Stick?', 'YesNoCancel', 'Question')
        if ($q -eq 'Cancel' -or $q -eq 'None') { Out-Log 'Kopieren abgebrochen'; return $null }
        $withMak = ($q -eq 'Yes')
        Out-Log ($Target + ': ' + $(if ($withMak) { 'mit MAK' } else { 'ohne MAK' }))
    }
    return @{ WithMak = $withMak }
}

$ui.bCopy.Add_Click({
    $dr = Get-ReadyDrive; if (-not $dr) { Out-Log 'Kein Ziel-Stick gewählt'; Set-Step 'Copy' 'err' 'kein Ziel-Stick'; return }
    if (-not (Save-Cfg)) { Set-Step 'Copy' 'err' 'nicht gespeichert'; return }
    if (-not (Confirm-PkgForCopy $win)) { Out-Log 'Kopieren abgebrochen'; Set-Step 'Copy' 'open'; return }
    $pre = Confirm-CopyPrereqs ('Stick ' + $dr) $win
    if (-not $pre) { Set-Step 'Copy' 'open'; return }
    Set-Step 'Copy' 'run'; Step-Ui
    if (Copy-ToStick $dr $pre.WithMak) { Set-Step 'Copy' 'ok' ('Stick ' + $dr) } else { Set-Step 'Copy' 'err' $script:CopyErr }
})

# ---------- 4. WLAN-Paket bauen (speichert vorher, schreibt den Fingerabdruck) ----------
function Build-Package([switch]$NoSave) {
    if (-not $NoSave) { if (-not (Save-Cfg)) { Set-Step 'Pkg' 'err' 'nicht gespeichert'; return $false } }
    if (-not (Test-Fields @('WlanSsid', 'WlanKey') -Admin)) { Set-Step 'Pkg' 'err' $script:FieldErr; return $false }
    if (-not (Test-Path $icd)) { Out-Log ('ICD.exe nicht gefunden: ' + $icd); Out-Log '  -> Windows ADK installieren, Feature "Imaging and Configuration Designer (ICD)". Die Store-App WCD hat keine Kommandozeile.'; Out-Log '  -> ohne ADK: Tools\New-WcdProjekt.ps1 + WCD-Oberfläche (INSTALL.md)'; Set-Step 'Pkg' 'err' 'ICD.exe fehlt'; return $false }
    Set-Step 'Pkg' 'run'; Step-Ui
    $c = Get-Cfg
    $okBuild = $false
    $work = Join-Path $env:TEMP ('HUPilot-WCD-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $x = [System.IO.File]::ReadAllText($tplXml)
        $x = $x.Replace('SSID="WLAN-NAME"', 'SSID="' + [System.Security.SecurityElement]::Escape($c.WlanSsid) + '"')
        $x = $x.Replace('<SecurityKey>WLAN-KENNWORT</SecurityKey>', '<SecurityKey>' + [System.Security.SecurityElement]::Escape($c.WlanKey) + '</SecurityKey>')
        $x = [regex]::Replace($x, '<ID>\{[0-9a-fA-F-]+\}</ID>', '<ID>{' + [guid]::NewGuid().ToString() + '}</ID>')
        $adm = @(@(@($c.AdminName, $c.AdminPassword), @($c.Admin2Name, $c.Admin2Password)) | Where-Object { $_[0] })
        if ($adm.Count) {
            # Optional: lokale Admins per ProvisioningCommands (Geraetekontext, laeuft als SYSTEM - auch nach jedem Zuruecksetzen)
            $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
            $body = @(
                '# HUPilot: lokale Admins (aus dem WLAN-Paket, läuft als SYSTEM)',
                ('$list = @(); ' + (($adm | ForEach-Object { '$list += ,@(' + (& $q $_[0]) + ', ' + (& $q $_[1]) + ')' }) -join '; ')),
                '$log = Join-Path $env:SystemRoot ''Temp\HUPilot-Admin.log''',
                'function L([string]$m) { try { Add-Content -Path $log -Value ((Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') + ''  '' + $m) -Encoding UTF8 } catch { } }',
                'foreach ($a in $list) {',
                '  $n = $a[0]; $pw = $a[1]',
                '  try {',
                '    $sec = ConvertTo-SecureString -String $pw -AsPlainText -Force',
                '    $u = Get-LocalUser -Name $n -ErrorAction SilentlyContinue',
                '    if ($u) { Set-LocalUser -Name $n -Password $sec -PasswordNeverExpires $true -AccountNeverExpires -ErrorAction Stop; Enable-LocalUser -Name $n -ErrorAction Stop; L (''Konto aktualisiert: '' + $n) }',
                '    else { New-LocalUser -Name $n -Password $sec -PasswordNeverExpires -AccountNeverExpires -Description ''HUPilot lokaler Admin'' -ErrorAction Stop | Out-Null; L (''Konto angelegt: '' + $n) }',
                '    $sid = (Get-LocalUser -Name $n).SID.Value',
                '    try { Add-LocalGroupMember -SID ''S-1-5-32-544'' -Member $sid -ErrorAction Stop; L (''zu Administratoren hinzugefügt: '' + $n) }',
                '    catch { if ($_.FullyQualifiedErrorId -like ''*MemberExists*'') { L (''bereits Administrator: '' + $n) } else { throw } }',
                '  } catch { L (''FEHLER '' + $n + '': '' + $_.Exception.Message) }',
                '}'
            ) -join "`r`n"
            # Ohne CommandFiles (ICD-Fehler beim Asset): Script als -EncodedCommand direkt in der CommandLine
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($body))
            $cl = 'cmd /c "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $b64
            $pc = '<ProvisioningCommands><DeviceContext><CommandLine>' + $cl + '</CommandLine></DeviceContext></ProvisioningCommands>'
            $x = $x.Replace('</Common>', $pc + '</Common>')
            $x = [regex]::Replace($x, '<Notes>.*?</Notes>', '<Notes>HUPilot: WLAN + lokale Admins. KEIN Zurücksetzen-Befehl im Paket.</Notes>')
            Out-Log ('Paket enthält lokale(n) Admin(s): ' + (($adm | ForEach-Object { $_[0] }) -join ', '))
        }
        $xmlPath = Join-Path $work 'customizations.xml'
        [System.IO.File]::WriteAllText($xmlPath, $x.TrimStart([char]0xFEFF), $enc)   # ohne BOM
        $ppkg = $srcPkg
        $cstore = Join-Path (Split-Path $icd -Parent) 'Microsoft-Common-Provisioning.dat'
        $stores = @($cstore)
        if ($adm.Count) {
            # ProvisioningCommands gibt es nur im Desktop-Speicher (Common kennt sie nicht)
            $dstore = Join-Path (Split-Path $icd -Parent) 'Microsoft-Desktop-Provisioning.dat'
            if (-not (Test-Path $dstore)) { Out-Log ('FEHLER: ' + $dstore + ' fehlt - ADK-Feature "Imaging and Configuration Designer" vollständig installieren'); Set-Step 'Pkg' 'err' 'ADK unvollständig'; return $false }
            $stores = @(($cstore + ',' + $dstore), $dstore)
        }
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
                foreach ($sec in @($c.WlanKey, $c.AdminPassword, $c.Admin2Password)) { if ($sec) { $ln = $ln.Replace($sec, '***') } }
                Out-Log ('  ' + $ln)
            }
            if (-not $lines.Count) { Out-Log '  (ICD.exe hat keine Ausgabe geliefert)' }
        }
        if ($okBuild) {
            try { Write-PkgFingerprint $c $srcPkg $srcPkgFp } catch { Out-Log ('Fingerabdruck des Pakets nicht schreibbar: ' + $_.Exception.Message) }
        } else { Out-Log 'WLAN-Paket NICHT gebaut - das bisherige Paket (falls vorhanden) bleibt unverändert.' }
    } catch { Out-Log ('FEHLER: ' + $_.Exception.Message); $okBuild = $false }
    finally { Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue }   # enthaelt das WLAN-Kennwort
    [void](Update-PkgState)
    if (-not $okBuild) { Set-Step 'Pkg' 'err' 'nicht gebaut' }
    return $okBuild
}
$ui.bPkg.Add_Click({ [void](Build-Package) })

function Read-Protokoll {
    $map = @{}
    $files = @(Join-Path $srcHU 'logs\protokoll.csv')
    $dr = Get-ReadyDrive; if ($dr) { $files += ($dr + '\HUPilot\logs\protokoll.csv') }
    foreach ($f in $files) {
        try {
            if (-not [System.IO.File]::Exists($f)) { continue }
            foreach ($row in @([System.IO.File]::ReadAllLines($f) | ConvertFrom-Csv -Delimiter ';')) {
                if (-not $row.Seriennr) { continue }
                if (-not $map.ContainsKey($row.Seriennr) -or [string]$row.Zeit -gt [string]$map[$row.Seriennr].Zeit) { $map[$row.Seriennr] = $row }
            }
            Out-Log ('Protokoll gelesen: ' + $f)
        } catch { Out-Log ('Protokoll ' + $f + ': ' + $_.Exception.Message) }
    }
    return $map
}

# Spalten der Status-Tabelle (Reihenfolge wie im Fenster), gilt fuer Excel und Druck
$script:StatusCols = @('Seriennr', 'Tag', 'Profil', 'Intune', 'RegDatum', 'LetzterKontakt', 'Benutzer', 'Name', 'LetzterSync', 'Modell', 'HUPilot')

# Excel-Datei (.xlsx) direkt schreiben, ohne installiertes Excel: Kopfzeile fett, fixiert, mit Filter,
# Spaltenbreite nach Inhalt, Datumsspalten als echtes Datum, Spalte Profil eingefaerbt wie im Fenster
function Export-StatusXlsx {
    param($Rows, [string[]]$Cols, [string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $esc = { param($s) [System.Security.SecurityElement]::Escape(([string]$s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')) }
    $colName = { param([int]$i) $n = ''; $i++; while ($i -gt 0) { $m = ($i - 1) % 26; $n = [char](65 + $m) + $n; $i = [int][math]::Floor(($i - 1) / 26) }; $n }
    $dateCols = @('RegDatum', 'LetzterKontakt', 'LetzterSync')
    $fmts = [string[]]@('dd.MM.yyyy HH:mm', 'yyyy-MM-dd HH:mm')
    $de = [Globalization.CultureInfo]::InvariantCulture
    $Rows = @($Rows)
    $width = @{}; foreach ($c in $Cols) { $width[$c] = $c.Length + 4 }
    $sb = New-Object System.Text.StringBuilder
    # Kopfzeile
    [void]$sb.Append('<row r="1">')
    for ($i = 0; $i -lt $Cols.Count; $i++) { [void]$sb.Append('<c r="' + (& $colName $i) + '1" s="1" t="inlineStr"><is><t>' + (& $esc $Cols[$i]) + '</t></is></c>') }
    [void]$sb.Append('</row>')
    $rn = 1
    foreach ($r in $Rows) {
        $rn++
        [void]$sb.Append('<row r="' + $rn + '">')
        for ($i = 0; $i -lt $Cols.Count; $i++) {
            $c = $Cols[$i]; $v = [string]$r.$c; $ref = (& $colName $i) + $rn
            if ($v.Length + 2 -gt $width[$c]) { $width[$c] = $v.Length + 2 }
            if (-not $v) { continue }
            $dt = [datetime]::MinValue
            if ($dateCols -contains $c -and [datetime]::TryParseExact($v, $fmts, $de, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
                [void]$sb.Append('<c r="' + $ref + '" s="2"><v>' + $dt.ToOADate().ToString($de) + '</v></c>')
                continue
            }
            $s = 0
            if ($c -eq 'Profil') { if ($v -eq 'zugewiesen') { $s = 3 } elseif ($v -in 'ausstehend', 'zugew., Datum fehlt', 'zugew., nicht synchron') { $s = 4 } }
            [void]$sb.Append('<c r="' + $ref + '"' + $(if ($s) { ' s="' + $s + '"' } else { '' }) + ' t="inlineStr"><is><t xml:space="preserve">' + (& $esc $v) + '</t></is></c>')
        }
        [void]$sb.Append('</row>')
    }
    $last = (& $colName ($Cols.Count - 1))
    $colsXml = ''
    for ($i = 0; $i -lt $Cols.Count; $i++) {
        $w = [math]::Min(60, [math]::Max($width[$Cols[$i]], $(if ($dateCols -contains $Cols[$i]) { 18 } else { 6 })))
        $colsXml += '<col min="' + ($i + 1) + '" max="' + ($i + 1) + '" width="' + $w + '" customWidth="1"/>'
    }
    $sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
        '<dimension ref="A1:' + $last + $rn + '"/>' +
        '<sheetViews><sheetView workbookViewId="0" tabSelected="1"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>' +
        '<sheetFormatPr defaultRowHeight="15"/><cols>' + $colsXml + '</cols>' +
        '<sheetData>' + $sb.ToString() + '</sheetData>' +
        '<autoFilter ref="A1:' + $last + $rn + '"/>' +
        '<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>' +
        '<pageSetup paperSize="9" orientation="landscape" fitToWidth="1" fitToHeight="0"/>' +
        '</worksheet>'
    $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
        '<numFmts count="1"><numFmt numFmtId="164" formatCode="dd.mm.yyyy hh:mm"/></numFmts>' +
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>' +
        '<fills count="5"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFDFF2E1"/><bgColor indexed="64"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFFFF4CE"/><bgColor indexed="64"/></patternFill></fill></fills>' +
        '<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FF808080"/></bottom><diagonal/></border></borders>' +
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/></cellXfs>' +
        '<cellStyles count="1"><cellStyle name="Standard" xfId="0" builtinId="0"/></cellStyles>' +
        '</styleSheet>'
    $parts = [ordered]@{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Status" sheetId="1" r:id="rId1"/></sheets><definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">Status!$A$1:$' + $last + '$' + $rn + '</definedName><definedName name="_xlnm.Print_Titles" localSheetId="0">Status!$1:$1</definedName></definedNames></workbook>'
        'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
        'xl/worksheets/sheet1.xml' = $sheet
        'xl/styles.xml' = $styles
    }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($k in $parts.Keys) {
            $st = $zip.CreateEntry($k).Open()
            try { $b = $utf8.GetBytes([string]$parts[$k]); $st.Write($b, 0, $b.Length) } finally { $st.Dispose() }
        }
    } finally { $zip.Dispose() }
}

# Druckansicht der Status-Tabelle: Querformat, Spaltenbreite nach Inhalt (gemessen), Zeilen abwechselnd hinterlegt,
# Profil eingefaerbt wie im Fenster. Passt die Tabelle nicht in die Breite, werden die Spalten anteilig verkleinert.
function New-StatusPrintDoc {
    param($Rows, [string[]]$Cols, [string]$Title, [string]$Sub, [double]$PageW, [double]$PageH)
    $brush = { param($hex) $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)); $b.Freeze(); $b }
    $bHead = & $brush '#D9E1F2'; $bAlt = & $brush '#F3F3F3'; $bLine = & $brush '#C8C8C8'; $bGreen = & $brush '#DFF2E1'; $bYellow = & $brush '#FFF4CE'
    $font = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $size = 8.0 * 96 / 72
    $pad = 36.0
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily = $font; $doc.FontSize = $size
    $doc.TextAlignment = [System.Windows.TextAlignment]::Left
    $doc.PagePadding = New-Object System.Windows.Thickness($pad)
    $doc.PageWidth = $PageW; $doc.PageHeight = $PageH
    $doc.ColumnWidth = $PageW; $doc.ColumnGap = 0
    $h1 = New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run($Title))
    $h1.FontSize = 11.0 * 96 / 72; $h1.FontWeight = [System.Windows.FontWeights]::Bold; $h1.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
    $doc.Blocks.Add($h1)
    $h2 = New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run($Sub))
    $h2.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $doc.Blocks.Add($h2)
    # Spaltenbreiten messen
    $Rows = @($Rows)
    $tfN = New-Object System.Windows.Media.Typeface($font, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
    $tfB = New-Object System.Windows.Media.Typeface($font, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Bold, [System.Windows.FontStretches]::Normal)
    $ci = [Globalization.CultureInfo]::CurrentCulture
    $measure = { param($t, $tf) (New-Object System.Windows.Media.FormattedText([string]$t, $ci, [System.Windows.FlowDirection]::LeftToRight, $tf, $size, [System.Windows.Media.Brushes]::Black)).WidthIncludingTrailingWhitespace }
    $cellPad = 10.0
    $wid = @()
    foreach ($c in $Cols) {
        $m = & $measure $c $tfB
        foreach ($r in $Rows) { $v = [string]$r.$c; if ($v) { $x = & $measure $v $tfN; if ($x -gt $m) { $m = $x } } }
        $wid += ($m + $cellPad + 2)
    }
    $avail = $PageW - 2 * $pad - 2
    $sum = ($wid | Measure-Object -Sum).Sum
    $f = $(if ($sum -gt $avail) { $avail / $sum } else { 1.0 })
    $mkCell = {
        param($t, $bold, $bg, $bottom)
        $p = New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run([string]$t))
        $p.Margin = New-Object System.Windows.Thickness(0)
        $cell = New-Object System.Windows.Documents.TableCell($p)
        $cell.Padding = New-Object System.Windows.Thickness(($cellPad / 2), 1.5, ($cellPad / 2), 1.5)
        if ($bold) { $cell.FontWeight = [System.Windows.FontWeights]::Bold }
        if ($bg) { $cell.Background = $bg }
        $cell.BorderBrush = $bLine; $cell.BorderThickness = New-Object System.Windows.Thickness(0, 0, 0, $bottom)
        $cell
    }
    # Kopfzeile auf jeder Seite: je Seite eine eigene Tabelle mit Kopf, Zeilen pro Seite aus der Zeilenhoehe berechnet
    # (1 Zeile Reserve). Seite 1 hat zusaetzlich Titel und Untertitel.
    $lineH = $font.LineSpacing * $size
    $rowH = $lineH + 3.5
    $bodyH = $PageH - 2 * $pad
    $titleH = $font.LineSpacing * $h1.FontSize + 2 + $lineH + 8
    $per1 = [math]::Max(5, [int][math]::Floor(($bodyH - $titleH - $rowH) / $rowH) - 1)
    $perN = [math]::Max(5, [int][math]::Floor(($bodyH - $rowH) / $rowH) - 1)
    $i = 0; $first = $true
    do {
        $n = $(if ($first) { $per1 } else { $perN })
        $tbl = New-Object System.Windows.Documents.Table
        $tbl.CellSpacing = 0
        $tbl.Margin = New-Object System.Windows.Thickness(0)
        foreach ($x in $wid) { $tc = New-Object System.Windows.Documents.TableColumn; $tc.Width = New-Object System.Windows.GridLength([math]::Floor($x * $f)); $tbl.Columns.Add($tc) }
        $rg = New-Object System.Windows.Documents.TableRowGroup
        $hr = New-Object System.Windows.Documents.TableRow
        foreach ($c in $Cols) { $hr.Cells.Add((& $mkCell $c $true $bHead 1.0)) }
        $rg.Rows.Add($hr)
        $end = [math]::Min($Rows.Count, $i + $n)
        for (; $i -lt $end; $i++) {
            $r = $Rows[$i]
            $tr = New-Object System.Windows.Documents.TableRow
            if ($i % 2 -eq 1) { $tr.Background = $bAlt }
            foreach ($c in $Cols) {
                $v = [string]$r.$c; $bg = $null
                if ($c -eq 'Profil') { if ($v -eq 'zugewiesen') { $bg = $bGreen } elseif ($v -in 'ausstehend', 'zugew., Datum fehlt', 'zugew., nicht synchron') { $bg = $bYellow } }
                $tr.Cells.Add((& $mkCell $v $false $bg 0.5))
            }
            $rg.Rows.Add($tr)
        }
        $tbl.RowGroups.Add($rg)
        # Seitenumbruch wirkt nur auf eine Section, nicht direkt auf die Tabelle
        $sec = New-Object System.Windows.Documents.Section
        if (-not $first) { $sec.BreakPageBefore = $true }
        $sec.Blocks.Add($tbl)
        $doc.Blocks.Add($sec)
        $first = $false
    } while ($i -lt $Rows.Count)
    return $doc
}

function Show-Status {
    param($Rows, [hashtable]$Proto, [string]$Tenant)
    [xml]$sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot - Status" Width="1260" Height="640" WindowStartupLocation="CenterOwner" FontSize="12" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style x:Key="HuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="3" Background="#FF6A6A6A"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Border Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="1,0"/></Track.Thumb>
        </Track></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent"><Track x:Name="PART_Track">
              <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="0,1"/></Track.Thumb>
            </Track></Border>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="10">
    <WrapPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,4">
      <TextBlock Text="Tag:" VerticalAlignment="Center" Margin="0,0,6,4"/>
      <ComboBox x:Name="cTag" Width="140" Margin="0,0,0,4" ToolTip="Nur Geräte mit diesem Group Tag"/>
      <CheckBox x:Name="cProto" Content="nur Geräte aus protokoll.csv" VerticalAlignment="Center" Margin="14,0,0,4" ToolTip="Nur Geräte, die mit dem Stick bearbeitet wurden (protokoll.csv von Quelle und Ziel-Stick)"/>
      <CheckBox x:Name="cZeit" Content="nur letzte" VerticalAlignment="Center" Margin="14,0,0,4" ToolTip="Zeitfilter: nur Geräte, die im gewählten Zeitraum registriert bzw. importiert wurden"/>
      <ComboBox x:Name="cZeitSpan" Width="60" Margin="6,0,0,4" ToolTip="Zeitraum bis jetzt"/>
      <ComboBox x:Name="cZeitBasis" Width="170" Margin="6,0,0,4" ToolTip="Registrierung = Zeit der Intune-Registrierung (Spalte RegDatum).&#x0a;Autopilot-Import = Zeit aus protokoll.csv (Hochladen per Stick);&#x0a;fehlt sie, gilt die Zeit der Profil-Zuweisung (meist wenige Minuten nach dem Import).&#x0a;Microsoft liefert keine eigene Importzeit."/>
      <TextBox x:Name="tFind" Width="160" Margin="14,0,0,4" VerticalAlignment="Center" ToolTip="Suche in Seriennummer / Gerätename / Benutzer"/>
      <TextBlock x:Name="tCount" VerticalAlignment="Center" Margin="14,0,0,4" FontWeight="SemiBold" ToolTip="Anzahl der angezeigten Geräte"/>
      <Button x:Name="bReload" Content="Aktualisieren" Padding="10,2" Margin="14,0,0,4" ToolTip="Alle Daten neu aus Autopilot/Intune laden"/>
    </WrapPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bCsv" Content="CSV speichern" Padding="10,4" ToolTip="Angezeigte Zeilen als CSV (Strichpunkt getrennt) speichern"/>
      <Button x:Name="bXlsx" Content="Excel speichern" Padding="10,4" Margin="8,0,0,0" ToolTip="Angezeigte Zeilen als Excel-Datei (.xlsx) speichern:&#x0a;Kopfzeile fixiert mit Filter, Datum als echtes Datum, Profil eingefärbt.&#x0a;Excel muss dafür nicht installiert sein."/>
      <Button x:Name="bPrint" Content="Drucken" Padding="10,4" Margin="8,0,0,0" ToolTip="Angezeigte Zeilen drucken (Querformat, auch als PDF über „Microsoft Print to PDF“)"/>
      <Button x:Name="bClose" Content="Schließen" Padding="10,4" Margin="8,0,0,0" ToolTip="Fenster schließen"/>
    </StackPanel>
    <DataGrid x:Name="dGrid" ToolTip="Doppelklick = Details (Profil live nachladen)" AutoGenerateColumns="True" IsReadOnly="True" CanUserSortColumns="True" AlternatingRowBackground="#F3F3F3" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
    $sw.Owner = $win
    if ($win.Icon) { $sw.Icon = $win.Icon }
    Set-WinFit $sw
    $g = @{}; foreach ($n in 'cTag','cProto','cZeit','cZeitSpan','cZeitBasis','tFind','tCount','bCsv','bXlsx','bPrint','bClose','dGrid','bReload') { $g[$n] = $sw.FindName($n) }
    # Spalte Profil dezent einfaerben: zugewiesen = hellgruen, in Arbeit (ausstehend, Datum fehlt, nicht synchron) = hellgelb.
    # Auswahl bleibt erkennbar (eigener Trigger fuer IsSelected mit den Systemfarben).
    $profStyle = $null
    try {
        $profStyle = [Windows.Markup.XamlReader]::Parse(@'
<Style TargetType="DataGridCell" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style.Triggers>
    <DataTrigger Binding="{Binding Profil}" Value="zugewiesen"><Setter Property="Background" Value="#DFF2E1"/></DataTrigger>
    <DataTrigger Binding="{Binding Profil}" Value="ausstehend"><Setter Property="Background" Value="#FFF4CE"/></DataTrigger>
    <DataTrigger Binding="{Binding Profil}" Value="zugew., Datum fehlt"><Setter Property="Background" Value="#FFF4CE"/></DataTrigger>
    <DataTrigger Binding="{Binding Profil}" Value="zugew., nicht synchron"><Setter Property="Background" Value="#FFF4CE"/></DataTrigger>
    <Trigger Property="IsSelected" Value="True">
      <Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.HighlightBrushKey}}"/>
      <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.HighlightTextBrushKey}}"/>
    </Trigger>
  </Style.Triggers>
</Style>
'@)
    } catch { Out-Log ('Status-Farben: ' + $_.Exception.Message) }
    if ($profStyle) { $g.dGrid.Add_AutoGeneratingColumn({ param($s, $e) if ([string]$e.PropertyName -eq 'Profil') { $e.Column.CellStyle = $profStyle } }) }
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
    # Zeitfilter: Zeitraum und Grundlage, Standard 24 h nach Registrierung (Haekchen aus)
    $script:ZeitStd = @(4, 24, 48)
    foreach ($h in $script:ZeitStd) { [void]$g.cZeitSpan.Items.Add(('' + $h + ' h')) }
    $g.cZeitSpan.SelectedIndex = 1
    [void]$g.cZeitBasis.Items.Add('nach Registrierung')
    [void]$g.cZeitBasis.Items.Add('nach Autopilot-Import')
    $g.cZeitBasis.SelectedIndex = 0
    $script:StatusView = @()
    $refresh = {
        $v = @($script:SRows)
        if ($g.cTag.SelectedItem -and [string]$g.cTag.SelectedItem -ne 'Alle') { $sel = [string]$g.cTag.SelectedItem; $v = @($v | Where-Object { $_.Tag -eq $sel }) }
        if ($g.cProto.IsChecked) { $v = @($v | Where-Object { $_.HUPilot }) }
        if ($g.cZeit.IsChecked) {
            $since = (Get-Date).AddHours(-1 * $script:ZeitStd[[math]::Max(0, $g.cZeitSpan.SelectedIndex)])
            $key = $(if ($g.cZeitBasis.SelectedIndex -eq 1) { 'Imp' } else { 'Reg' })
            $v = @($v | Where-Object { $t = $script:StatusTimes[[string]$_.Seriennr]; $t -and $t[$key] -and $t[$key] -ge $since })
        }
        if ($g.tFind.Text) { $q = $g.tFind.Text; $v = @($v | Where-Object { $_.Seriennr -like ('*' + $q + '*') -or $_.Name -like ('*' + $q + '*') -or $_.Benutzer -like ('*' + $q + '*') }) }
        $script:StatusView = $v
        $g.dGrid.ItemsSource = $v
        $ok = @($v | Where-Object { $_.Intune -eq 'registriert' }).Count
        $g.tCount.Text = ('' + $v.Count + ' Geräte  |  ' + $ok + ' in Intune registriert  |  ' + ($v.Count - $ok) + ' offen')
    }
    $g.cTag.Add_SelectionChanged($refresh)
    $g.cProto.Add_Click($refresh)
    $g.cZeit.Add_Click($refresh)
    $g.cZeitSpan.Add_SelectionChanged({ if ($g.cZeit.IsChecked) { & $refresh } })
    $g.cZeitBasis.Add_SelectionChanged({ if ($g.cZeit.IsChecked) { & $refresh } })
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
    $g.bXlsx.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'Excel (*.xlsx)|*.xlsx'
        $dlg.FileName = 'HUPilot-Status_' + ($Tenant -replace '[^A-Za-z0-9-]', '') + '_' + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '.xlsx'
        if ($dlg.ShowDialog()) {
            try {
                Export-StatusXlsx -Rows $script:StatusView -Cols $script:StatusCols -Path $dlg.FileName
                Out-Log ('Status gespeichert: ' + $dlg.FileName)
            } catch {
                Out-Log ('FEHLER Excel speichern: ' + $_.Exception.Message)
                [void][System.Windows.MessageBox]::Show($sw, ('Excel-Datei konnte nicht gespeichert werden (ist sie noch in Excel offen?)' + "`r`n`r`n" + $_.Exception.Message), 'HUPilot - Status', 'OK', 'Warning')
            }
        }
    })
    $g.bPrint.Add_Click({
        try {
            $pd = New-Object System.Windows.Controls.PrintDialog
            # Querformat vorschlagen, im Druckdialog weiter aenderbar
            try { Add-Type -AssemblyName System.Printing; $pd.PrintTicket.PageOrientation = [System.Printing.PageOrientation]::Landscape } catch { }
            if (-not $pd.ShowDialog()) { return }
            $flt = @()
            if ($g.cTag.SelectedItem -and [string]$g.cTag.SelectedItem -ne 'Alle') { $flt += ('Tag ' + [string]$g.cTag.SelectedItem) }
            if ($g.cProto.IsChecked) { $flt += 'nur Geräte aus protokoll.csv' }
            if ($g.cZeit.IsChecked) { $flt += ('letzte ' + [string]$g.cZeitSpan.SelectedItem + ' ' + [string]$g.cZeitBasis.SelectedItem) }
            if ($g.tFind.Text) { $flt += ('Suche „' + $g.tFind.Text + '“') }
            $sub = $g.tCount.Text + $(if ($flt.Count) { '   |   Filter: ' + ($flt -join ', ') } else { '' })
            $doc = New-StatusPrintDoc -Rows $script:StatusView -Cols $script:StatusCols -Title ('HUPilot - Status ' + $Tenant + '   ' + (Get-Date -Format 'dd.MM.yyyy HH:mm')) -Sub $sub -PageW $pd.PrintableAreaWidth -PageH $pd.PrintableAreaHeight
            $pd.PrintDocument(([System.Windows.Documents.IDocumentPaginatorSource]$doc).DocumentPaginator, 'HUPilot-Status')
            Out-Log 'Status gedruckt'
        } catch { Out-Log ('FEHLER Drucken: ' + $_.Exception.Message) }
    })
    & $refresh
    [void]$sw.ShowDialog()
}

function Get-StatusData {
    $tok = Get-ApiToken; if (-not $tok) { return $null }
    $h = @{ Authorization = 'Bearer ' + $tok }
    Out-Log 'Lade Autopilot-Geräte ...'
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
        Out-Log ('Intune-Geräte gelesen: ' + @($md.Keys | Where-Object { $_ -like 'SN:*' }).Count)
    } catch { Out-Log 'Primärer Benutzer nicht lesbar (optional: Anwendungsberechtigung DeviceManagementManagedDevices.Read.All für HUPilot-Upload)' }
    $proto = Read-Protokoll
    $mapE = @{ enrolled = 'registriert'; notContacted = 'noch nicht'; failed = 'Fehler'; pendingReset = 'Reset ausstehend'; blocked = 'blockiert'; unknown = 'unbekannt' }
    $script:ApIds = @{}
    foreach ($d in $all) { if ($d.serialNumber) { $script:ApIds[[string]$d.serialNumber] = [string]$d.id } }
    # Zeiten fuer den Zeitfilter (nicht als Spalte): Reg = Intune-Registrierung, Imp = Autopilot-Import.
    # Graph liefert keine Importzeit: genommen wird die HUPilot-Zeit aus protokoll.csv, sonst die Profil-Zuweisung
    # (kommt meist wenige Minuten nach dem Import).
    $script:StatusTimes = @{}
    $rows = foreach ($d in $all) {
        $ps = [string]$d.deploymentProfileAssignmentStatus
        $prof = $(if ($ps -in 'assignedInSync', 'assignedUnkownSyncState') { $(if ($(try { ([datetime]$d.deploymentProfileAssignedDateTime).Year -gt 2000 } catch { $false })) { 'zugewiesen' } else { 'zugew., Datum fehlt' }) } elseif ($ps -eq 'assignedOutOfSync') { 'zugew., nicht synchron' } elseif ($ps -eq 'pending') { 'ausstehend' } elseif ($ps -eq 'notAssigned') { 'keins' } else { $ps })
        $es = [string]$d.enrollmentState
        $lc = ''
        try { $dt = [datetime]$d.lastContactedDateTime; if ($dt.Year -gt 2000) { $lc = $dt.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } } catch { }
        $pr = $null; if ($proto.ContainsKey([string]$d.serialNumber)) { $pr = $proto[[string]$d.serialNumber] }
        $im = $null
        if ($d.managedDeviceId -and $md.ContainsKey([string]$d.managedDeviceId)) { $im = $md[[string]$d.managedDeviceId] }
        elseif ($md.ContainsKey('SN:' + [string]$d.serialNumber)) { $im = $md['SN:' + [string]$d.serialNumber] }
        $sync = ''; $reg = ''
        if ($im) { try { $sd = [datetime]$im.lastSyncDateTime; if ($sd.Year -gt 2000) { $sync = $sd.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } } catch { } }
        $tReg = $null; $tImp = $null
        if ($im) { try { $rd = [datetime]$im.enrolledDateTime; if ($rd.Year -gt 2000) { $tReg = $rd.ToLocalTime(); $reg = $tReg.ToString('yyyy-MM-dd HH:mm') } } catch { } }
        $pt = [datetime]::MinValue
        if ($pr -and [datetime]::TryParseExact([string]$pr.Zeit, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$pt)) { $tImp = $pt }
        if (-not $tImp) { try { $pa = [datetime]$d.deploymentProfileAssignedDateTime; if ($pa.Year -gt 2000) { $tImp = $pa.ToLocalTime() } } catch { } }
        if ($d.serialNumber) { $script:StatusTimes[[string]$d.serialNumber] = @{ Reg = $tReg; Imp = $tImp } }
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
    # noch nicht registrierte Geraete (gerade in Arbeit) OBEN, danach die registrierten, neueste zuerst
    $rows = @(@($rows | Where-Object { -not $_.RegDatum }) + @($rows | Where-Object { $_.RegDatum } | Sort-Object RegDatum -Descending))
    Out-Log ('' + @($rows).Count + ' Autopilot-Geräte, ' + $proto.Count + ' aus protokoll.csv')
    return @{ Rows = $rows; Proto = $proto }
}
$ui.bStatus.Add_Click({
    try {
        Set-Step 'Status' 'run'; Step-Ui
        $d = Get-StatusData; if (-not $d) { Set-Step 'Status' 'err' 'nicht geladen - siehe Protokoll'; return }
        Set-Step 'Status' 'ok' ('' + @($d.Rows).Count + ' Geräte')
        Show-Status -Rows @($d.Rows) -Proto $d.Proto -Tenant ((Get-Cfg).Tenant)
    } catch { Out-Log ('Status: ' + $_.Exception.Message); Set-Step 'Status' 'err' $_.Exception.Message }
})

# Desktop-Verknuepfung (nur wenn das Setup vom PC laeuft)
if ($script:SrcOnUsb) { $ui.bLnk.Visibility = 'Collapsed' }
$ui.bLnk.Add_Click({
    try {
        $c = Get-Cfg
        $nm = $(if ($c.Tenant) { [string]$c.Tenant } else { Split-Path $srcStick -Leaf })
        $nm = 'HUPilot ' + ($nm -replace '[\\/:*?"<>|]', '')
        $dsk = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $lnk = Join-Path $dsk ($nm + '.lnk')
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = Join-Path $srcStick 'HUPilot-Setup.cmd'
        $sc.WorkingDirectory = $srcStick
        $ico = Join-Path $PSScriptRoot 'icon.ico'
        if (Test-Path $ico) { $sc.IconLocation = $ico + ',0' }
        $sc.Description = 'HUPilot-Setup - ' + $srcStick
        $sc.WindowStyle = 7
        $sc.Save()
        Out-Log ('Desktop-Verknüpfung angelegt: ' + $lnk)
    } catch { Out-Log ('FEHLER Verknüpfung: ' + $_.Exception.Message) }
})

Update-Drives
Out-Log ('Quelle: '  + $srcStick)
$ui.tSub.ToolTip = 'Quelle: ' + $srcStick
if (Test-Path $srcCfg) { $ui.bLoad.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
# Ohne config.json: leeres Formular gilt als gespeicherter Stand (kein Hinweis "ungespeichert")
if ($null -eq $script:SavedSnap) { $script:SavedSnap = Get-CfgSnap; Update-Dirty }
Out-Log ('ICD.exe: ' + $(if (Test-Path $icd) { 'gefunden' } else { 'NICHT gefunden - für 4. WLAN-Paket: Windows ADK mit Imaging and Configuration Designer installieren (Store-WCD reicht nicht)' }))
Start-Log 'Fenster wird angezeigt'
# Beim Start automatisch Secret-Ablauf anzeigen (nur wenn echte Werte eingetragen sind)
$win.Add_ContentRendered({
    $c = Get-Cfg
    if ($c.TenantId -notmatch '^[0-9a-fA-F-]{36}$' -or $c.ClientId -notmatch '^[0-9a-fA-F-]{36}$' -or -not $c.ClientSecret -or $c.ClientSecret.StartsWith('<')) { return }
    Out-Log 'Prüfe Secret ...'
    $win.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    $tok = Get-ApiToken
    if (-not $tok) {
        # Kein Netz oder Zeitueberschreitung: neutral - das Secret ist dann nur nicht geprueft, nicht ungueltig
        if ($script:TokenErr -eq 'net') { Set-SubSecret 'Keine Verbindung - Secret nicht geprüft' $false; Set-Step 'Test' 'warn' 'keine Verbindung' }
        elseif ($script:TokenErr -in 'expired', 'wrong') { Set-SubSecret ('Secret UNGÜLTIG (' + $(if ($script:TokenErr -eq 'expired') { 'abgelaufen' } else { 'falsch' }) + ') - siehe Protokoll') $true; Set-Step 'Test' 'err' $script:TokenMsg }
        else { Set-SubSecret 'Anmeldung fehlgeschlagen - siehe Protokoll' $true; Set-Step 'Test' 'err' $script:TokenMsg }
        return
    }
    Show-SecretExpiry -Token $tok
    Set-Step 'Test' 'ok' 'Secret gültig (Start)'
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
        Width="1000" Height="520" WindowStartupLocation="CenterOwner" FontSize="12" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style x:Key="HuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="3" Background="#FF6A6A6A"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Border Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="1,0"/></Track.Thumb>
        </Track></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent"><Track x:Name="PART_Track">
              <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="0,1"/></Track.Thumb>
            </Track></Border>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="10">
    <TextBlock x:Name="tInfo" DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <Button x:Name="bClose" DockPanel.Dock="Bottom" HorizontalAlignment="Right" Content="Schließen" Padding="10,4" Margin="0,8,0,0" ToolTip="Fenster schließen."/>
    <DataGrid x:Name="dGrid" ToolTip="Je Tag: Geräte, passende Gruppe und Autopilot-Profil. Spaltenkopf anklicken = sortieren." AutoGenerateColumns="True" IsReadOnly="True" AlternatingRowBackground="#F3F3F3" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $gw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $gx))
    $gw.Owner = $win; $gw.Title = $Title
    if ($win.Icon) { $gw.Icon = $win.Icon }
    Set-WinFit $gw
    $gw.FindName('tInfo').Text = $Info
    $gw.FindName('dGrid').ItemsSource = @($Rows)
    $gw.FindName('bClose').Add_Click({ $gw.Close() })
    [void]$gw.ShowDialog()
}

# ---------- 2. Tags pruefen ----------
# Je Tag: Geraete, passende Gruppe, Profil. Rueckgabe @{ Rows; Bad (am Stick waehlbar, ohne Profil); GErr; Info; Error }
# Gemeinsam fuer "2. Tags pruefen" (Tabelle) und "Stick fertig machen" (nur Warnung)
function Get-TagReport($h) {
    Out-Log 'Lade Profile, Gruppen und Geräte ...'
    try { $profs = @((Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments' -Headers $h -TimeoutSec 60).value) }
    catch { Out-Log ('FEHLER Profile lesen: ' + $_.Exception.Message); return @{ Rows = @(); Bad = @(); GErr = $false; Info = ''; Error = ('Profile nicht lesbar: ' + $_.Exception.Message) } }
    $gcache = @{}; $gErr = $false; $targets = @()
    foreach ($p in $profs) {
        foreach ($a in @($p.assignments)) {
            $ty = [string]$a.target.'@odata.type'
            if ($ty -like '*allDevicesAssignmentTarget') { $targets += [pscustomobject]@{ Profil = [string]$p.displayName; Gruppe = 'Alle Geräte'; Rule = '*' }; continue }
            if ($ty -notlike '*.groupAssignmentTarget') { continue }
            $gid = [string]$a.target.groupId
            if (-not $gcache.ContainsKey($gid)) {
                try { $gcache[$gid] = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ('https://graph.microsoft.com/v1.0/groups/' + $gid + '?$select=displayName,membershipRule') -Headers $h }
                catch {
                    $em = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $em = $_.ErrorDetails.Message }
                    if ($em -match 'Authorization_RequestDenied|Forbidden|403|Insufficient privileges') { $gErr = $true; $gcache[$gid] = [pscustomobject]@{ displayName = $gid; membershipRule = '' } }
                    else { Out-Log ('Profil "' + $p.displayName + '" ist einer nicht mehr vorhandenen Gruppe zugewiesen: ' + $gid); $gcache[$gid] = [pscustomobject]@{ displayName = ('(gelöscht) ' + $gid); membershipRule = '' } }
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
    Out-Log ('Tags: ' + @($rows).Count + ', ohne Profil (am Stick wählbar): ' + $bad.Count + $(if ($gErr) { '  - Gruppen nicht lesbar: Group.Read.All für HUPilot-Upload ergänzen' } else { '' }))
    $info = 'Je Tag: Geräte in Autopilot, passende dynamische Gruppe ([OrderID]-Regel) und daran zugewiesenes Autopilot-Profil.'
    if ($bad.Count) { $info += '  ACHTUNG: ' + (($bad | ForEach-Object { $_.Tag }) -join ', ') + ' am Stick wählbar, aber ohne Profil.' }
    if ($gErr) { $info += '  Gruppen nicht lesbar - Anwendungsberechtigung Group.Read.All ergänzen.' }
    return @{ Rows = @($rows); Bad = $bad; GErr = $gErr; Info = $info; Error = '' }
}
$ui.bTags.Add_Click({
    Set-Step 'Tags' 'run'
    $tok = Get-ApiToken; if (-not $tok) { Set-Step 'Tags' 'err' $script:TokenMsg; return }
    $h = @{ Authorization = 'Bearer ' + $tok }
    $win.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    $r = Get-TagReport $h
    if ($r.Error) { Set-Step 'Tags' 'err' $r.Error; return }
    Set-Step 'Tags' $(if ($r.Bad.Count -or $r.GErr) { 'warn' } else { 'ok' }) $(if ($r.Bad.Count) { 'ohne Profil: ' + (($r.Bad | ForEach-Object { $_.Tag }) -join ', ') } elseif ($r.GErr) { 'Gruppen nicht lesbar' } else { '' })
    Show-Grid -Title ('HUPilot - Tags  (' + (Get-Cfg).Tenant + ')') -Rows $r.Rows -Info $r.Info
})

# ---------- 7. Offline-Hashes importieren ----------
function Read-HashCsv([string]$File) {
    $out = @()
    $lines = @(); try { $lines = @([System.IO.File]::ReadAllLines($File)) } catch { }
    foreach ($l in $lines) {
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
        Title="HUPilot - Hashes importieren" Width="1000" Height="560" WindowStartupLocation="CenterOwner" FontSize="12" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style x:Key="HuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="3" Background="#FF6A6A6A"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Border Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="1,0"/></Track.Thumb>
        </Track></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent"><Track x:Name="PART_Track">
              <Track.Thumb><Thumb Style="{StaticResource HuThumb}" Margin="0,1"/></Track.Thumb>
            </Track></Border>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="10">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8" Text="Offline gespeicherte Hashes (HUPilot\logs\hashes.csv aus Quelle und Ziel-Stick). Schon vorhandene Geräte bekommen nur den Tag. Erledigte Zeilen wandern nach hashes-erledigt.csv."/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bAdd" Content="CSV hinzufügen ..." Padding="10,4" ToolTip="Weitere hashes.csv-Dateien laden (z. B. von anderen Sticks)."/>
      <Button x:Name="bImp" Content="Importieren" FontWeight="SemiBold" Padding="10,4" Margin="8,0,0,0" ToolTip="Offene Zeilen nach Autopilot hochladen (dauert bis zu 15 Minuten). Schließen während des Imports bricht nach Rückfrage sauber ab."/>
      <Button x:Name="bClose" Content="Schließen" Padding="10,4" Margin="8,0,0,0" ToolTip="Fenster schließen. Während eines Imports: Abbrechen mit Rückfrage."/>
    </StackPanel>
    <TextBox x:Name="tHLog" ToolTip="Protokoll des Imports." DockPanel.Dock="Bottom" Height="110" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas"/>
    <DataGrid x:Name="dGrid" ToolTip="Gefundene Hashes mit Stand des Imports." AutoGenerateColumns="False" IsReadOnly="True" AlternatingRowBackground="#F3F3F3" HeadersVisibility="Column">
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
    Set-WinFit $hw
    $g = @{}; foreach ($n in 'bAdd','bImp','bClose','tHLog','dGrid') { $g[$n] = $hw.FindName($n) }
    $script:HRows = @()
    $hlog = { param($m) $g.tHLog.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $m + "`r`n"); $g.tHLog.ScrollToEnd(); $hw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
    $refresh = { $g.dGrid.ItemsSource = $null; $g.dGrid.ItemsSource = @($script:HRows); $hw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
    $addFile = {
        param($f)
        if (-not [System.IO.File]::Exists($f)) { return }
        $new = @(Read-HashCsv $f)
        foreach ($r in $new) { $script:HRows = @($script:HRows | Where-Object { $_.Seriennr -ne $r.Seriennr }) + $r }
        & $hlog ('' + $new.Count + ' Hash(es) aus ' + $f)
    }
    & $addFile (Join-Path $srcHU 'logs\hashes.csv')
    $dr = Get-ReadyDrive; if ($dr) { & $addFile ($dr + '\HUPilot\logs\hashes.csv') }
    & $refresh
    # Schliessen waehrend eines laufenden Imports: Rueckfrage, dann Abbruch-Merker (der Import endet sauber, erledigte Zeilen werden noch verschoben)
    $hst = @{ Busy = $false; Abort = $false; CloseAfter = $false }
    $hw.Add_Closing({
        param($s, $e)
        if (-not $hst.Busy) { return }
        $e.Cancel = $true
        if ($hst.Abort) { return }
        $q = [System.Windows.MessageBox]::Show($hw, ('Der Import läuft noch.' + "`r`n`r`n" + 'Abbrechen? Bereits importierte Geräte bleiben in Autopilot, erledigte Zeilen werden noch nach hashes-erledigt.csv verschoben. Das Fenster schließt danach von selbst.'), 'HUPilot - Import abbrechen', 'YesNo', 'Question')
        if ($q -eq 'Yes') { $hst.Abort = $true; $hst.CloseAfter = $true; & $hlog 'Abbruch angefordert - warte auf den laufenden Schritt ...' }
    })
    $g.bClose.Add_Click({ $hw.Close() })
    $g.bAdd.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'CSV (*.csv)|*.csv'; $dlg.Multiselect = $true
        if ($dlg.ShowDialog()) { foreach ($f in $dlg.FileNames) { & $addFile $f }; & $refresh }
    })
    $doImport = {
        $todo = @($script:HRows | Where-Object { -not $_.Done })
        if (-not $todo.Count) { & $hlog 'Nichts zu importieren.'; Set-Step 'Hash' 'ok' 'nichts offen'; return }
        $tok = Get-ApiToken; if (-not $tok) { & $hlog ('Anmeldung fehlgeschlagen: ' + $script:TokenMsg); Set-Step 'Hash' 'err' $script:TokenMsg; return }
        $h  = @{ Authorization = 'Bearer ' + $tok }
        $hj = @{ Authorization = 'Bearer ' + $tok; 'Content-Type' = 'application/json' }
        $GB = 'https://graph.microsoft.com/beta/deviceManagement'
        $c = Get-Cfg
        foreach ($r in $todo) {
            if ($hst.Abort) { & $hlog 'Abgebrochen - restliche Geräte nicht angefasst'; break }
            if (-not $r.Tag) { $r.Tag = $c.GroupTag }
            try {
                # OData: Hochkomma in der Seriennummer verdoppeln
                $f = [uri]::EscapeDataString("contains(serialNumber,'" + ([string]$r.Seriennr).Replace("'", "''") + "')")
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
                    $r.ImpId = [string]$imp.id; $r.Status = 'Import läuft ...'
                }
            } catch { $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }; $r.Status = 'FEHLER: ' + $m }
            & $hlog ($r.Seriennr + ': ' + $r.Status)
        }
        & $refresh
        $limit = (Get-Date).AddMinutes(15)
        while (-not $hst.Abort -and @($script:HRows | Where-Object { $_.ImpId -and -not $_.Done -and $_.Status -like 'Import*' }).Count -and (Get-Date) -lt $limit) {
            for ($i = 0; $i -lt 10 -and -not $hst.Abort; $i++) { Start-Sleep -Milliseconds 1000; $hw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
            if ($hst.Abort) { break }
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
        $late = $(if ($hst.Abort) { 'abgebrochen - Import läuft bei Microsoft evtl. weiter, später nochmal importieren' } else { 'Import nach 15 Min nicht fertig - später nochmal' })
        foreach ($r in @($script:HRows | Where-Object { -not $_.Done -and $_.Status -like 'Import*' })) { $r.Status = $late }
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
        Set-Step 'Hash' $(if ($ok -eq @($script:HRows).Count) { 'ok' } else { 'warn' }) ('' + $ok + ' von ' + @($script:HRows).Count + ' erledigt')
    }
    $g.bImp.Add_Click({
        if ($hst.Busy) { return }
        $hst.Busy = $true; $hst.Abort = $false; $hst.CloseAfter = $false
        $g.bImp.IsEnabled = $false; $g.bAdd.IsEnabled = $false; $g.bClose.Content = 'Abbrechen'
        Set-Step 'Hash' 'run'
        try { & $doImport }
        catch { & $hlog ('FEHLER: ' + $_.Exception.Message); Set-Step 'Hash' 'err' $_.Exception.Message }
        finally {
            $hst.Busy = $false
            $g.bImp.IsEnabled = $true; $g.bAdd.IsEnabled = $true; $g.bClose.Content = 'Schließen'
            if ($hst.CloseAfter) { [void]$hw.Dispatcher.BeginInvoke([action]{ $hw.Close() }) }
        }
    })
    [void]$hw.ShowDialog()
}
$ui.bHash.Add_Click({ Show-HashImport })

# ---------- Hauptknopf: Stick fertig machen (alle Schritte, Abbruch beim ersten echten Fehler mit Meldung in Klartext) ----------
$script:Busy = $false
function Stop-Ready([string]$Step, [string]$Msg, [switch]$Quiet) {
    if ($Step) { Set-Step $Step $(if ($Quiet) { 'open' } else { 'err' }) $Msg }
    Set-Step 'Ready' $(if ($Quiet) { 'open' } else { 'err' }) $Msg
    $first = @($Msg -split "`r?`n" | Where-Object { $_.Trim() })[0]
    $ui.tReady.Text = $(if ($Quiet) { 'Abgebrochen: ' } else { 'Nicht fertig: ' }) + $first + '  (' + (Get-Date -Format 'HH:mm') + ')'
    Out-Log ('ABBRUCH Stick fertig machen: ' + ($Msg -replace "`r?`n", ' '))
    if (-not $Quiet) { Show-Msg $Msg 'HUPilot - Stick nicht fertig' 'Warning' }
}
function Invoke-StickReadyCore {
    $nl = "`r`n"
    $warn = @()
    Set-Step 'Ready' 'run'; $ui.tReady.Text = 'läuft ...'; Out-Log '=== Stick fertig machen ==='; Step-Ui
    # 1. Ziel-Stick
    $dr = Get-ReadyDrive
    if (-not $dr) { Stop-Ready 'Copy' ('Kein Ziel-Stick gewählt.' + $nl + $nl + 'Stick anstecken, bei "Stick" auf "Aktualisieren" klicken, den Stick auswählen und nochmal "Stick fertig machen" klicken.'); return }
    # 2. Felder (wie beim Speichern, inklusive lokale Admins, MAK und Tags)
    if (-not (Test-Fields @('Tenant', 'TenantId', 'ClientId', 'ClientSecret', 'GroupTag', 'WlanSsid', 'WlanKey') -Admin)) { Stop-Ready 'Write' ('Eine Eingabe fehlt oder ist ungültig:' + $nl + $script:FieldErr + $nl + $nl + 'Feld korrigieren und nochmal "Stick fertig machen" klicken.'); return }
    # 3. Verbindung, Secret, Autopilot-Zugriff
    Set-Step 'Test' 'run'; Step-Ui
    $tok = Get-ApiToken
    if (-not $tok) {
        if ($script:TokenErr -eq 'net') {
            Set-Step 'Test' 'warn' 'keine Verbindung'
            $q = [System.Windows.MessageBox]::Show($win, ('Keine Verbindung zu Microsoft (Internet, Proxy?).' + $nl + 'Secret und Tags können deshalb nicht geprüft werden.' + $nl + $nl + 'Stick trotzdem fertig machen?'), 'HUPilot - keine Verbindung', 'YesNo', 'Warning')
            if ($q -ne 'Yes') { Stop-Ready '' 'keine Verbindung zu Microsoft' -Quiet; return }
            $warn += 'Secret und Tags nicht geprüft (keine Verbindung)'
        } elseif ($script:TokenErr -eq 'expired') { Stop-Ready 'Test' ('Das Secret ist abgelaufen.' + $nl + $nl + 'In Entra bei der App-Registrierung ein neues Geheimnis anlegen, den WERT bei "Secret" eintragen und nochmal "Stick fertig machen" klicken.'); return }
        elseif ($script:TokenErr -eq 'wrong') { Stop-Ready 'Test' ('Das Secret ist falsch.' + $nl + $nl + 'Häufiger Fehler: die Geheimnis-ID statt des WERTS kopiert. Den Wert bei "Secret" eintragen und nochmal versuchen.'); return }
        else { Stop-Ready 'Test' ('Anmeldung bei Microsoft fehlgeschlagen:' + $nl + $script:TokenMsg + $nl + $nl + 'Tenant-ID, App-ID und Secret prüfen.'); return }
    } else {
        $apErr = Test-ApAccess $tok
        if ($apErr) { Stop-Ready 'Test' ('Anmeldung OK, aber kein Zugriff auf Autopilot.' + $nl + $nl + 'Der App-Registrierung fehlt die Anwendungsberechtigung DeviceManagementServiceConfig.ReadWrite.All (mit Administratorzustimmung).' + $nl + 'Meldung: ' + $apErr); return }
        Show-SecretExpiry -Token $tok
        Set-Step 'Test' 'ok'
        # 4. Tags: nur warnen
        Set-Step 'Tags' 'run'; Step-Ui
        $tr = Get-TagReport @{ Authorization = 'Bearer ' + $tok }
        if ($tr.Error) { Set-Step 'Tags' 'warn' $tr.Error; $warn += ('Tags nicht geprüft: ' + $tr.Error) }
        elseif ($tr.Bad.Count) { $t = 'Tag(s) ohne Autopilot-Profil: ' + (($tr.Bad | ForEach-Object { $_.Tag }) -join ', '); Set-Step 'Tags' 'warn' $t; Out-Log ('WARNUNG: ' + $t); $warn += ($t + ' - Geräte mit diesem Tag bekommen kein Profil') }
        elseif ($tr.GErr) { Set-Step 'Tags' 'warn' 'Gruppen nicht lesbar'; $warn += 'Tags nur teilweise geprüft (Group.Read.All fehlt)' }
        else { Set-Step 'Tags' 'ok' }
    }
    # 5. Speichern
    if (-not (Save-Cfg)) { Stop-Ready 'Write' ('Speichern fehlgeschlagen:' + $nl + $script:FieldErr); return }
    # 6. WLAN-Paket nur bauen, wenn es fehlt oder veraltet ist
    $ps = Update-PkgState
    if ($ps -in 'fehlt', 'veraltet', 'unbekannt') {
        if (Test-Path $icd) {
            Out-Log ('WLAN-Paket ' + $ps + ' - wird gebaut')
            if (-not (Build-Package -NoSave)) { Stop-Ready 'Pkg' ('Das WLAN-Paket konnte nicht gebaut werden. Details stehen im Protokoll.' + $nl + $nl + 'Das bisherige Paket (falls vorhanden) ist unverändert, nichts wurde auf den Stick kopiert.'); return }
        } elseif ($ps -eq 'fehlt') { Stop-Ready 'Pkg' ('Es gibt noch kein WLAN-Paket, und ICD.exe fehlt auf diesem PC.' + $nl + $nl + 'Windows ADK mit "Imaging and Configuration Designer" installieren, oder das Paket auf einem PC mit ADK bauen (4. WLAN-Paket bauen).'); return }
        elseif ($ps -eq 'veraltet') { Stop-Ready 'Pkg' ('WLAN oder lokale Admins wurden geändert, das WLAN-Paket ist veraltet.' + $nl + 'ICD.exe fehlt auf diesem PC, deshalb kann es hier nicht neu gebaut werden.' + $nl + $nl + 'Auf einem PC mit Windows ADK "4. WLAN-Paket bauen" klicken, oder die alten Werte wieder eintragen.'); return }
        else {
            $q = [System.Windows.MessageBox]::Show($win, ('Ob das vorhandene WLAN-Paket zu WLAN und lokalen Admins passt, ist unbekannt (gebaut mit einer älteren Version).' + $nl + 'ICD.exe fehlt auf diesem PC, neu bauen geht hier nicht.' + $nl + $nl + 'Vorhandenes Paket verwenden?'), 'HUPilot - WLAN-Paket', 'YesNo', 'Warning')
            if ($q -ne 'Yes') { Stop-Ready 'Pkg' 'WLAN-Paket nicht bestätigt' -Quiet; return }
            $warn += 'WLAN-Paket ungeprüft (älter, ICD.exe fehlt)'
        }
    }
    # 7. Kopieren mit Kontrolle
    $pre = Confirm-CopyPrereqs ('Stick ' + $dr) $win
    if (-not $pre) { Stop-Ready 'Copy' 'vor dem Kopieren abgebrochen' -Quiet; return }
    Set-Step 'Copy' 'run'; Step-Ui
    if (-not (Copy-ToStick $dr $pre.WithMak)) { Stop-Ready 'Copy' ('Kopieren auf ' + $dr + ' fehlgeschlagen:' + $nl + $script:CopyErr + $nl + $nl + 'Stick neu anstecken, bei "Stick" auf "Aktualisieren" klicken und nochmal versuchen. Hilft das nicht: anderen Stick nehmen oder "Sticks vorbereiten" (formatiert).'); return }
    Set-Step 'Copy' 'ok' ('Stick ' + $dr)
    Set-Step 'Ready' $(if ($warn.Count) { 'warn' } else { 'ok' }) $(if ($warn.Count) { $warn -join '; ' } else { 'Stick ' + $dr + ' fertig' })
    $ui.tReady.Text = 'Stick ' + $dr + ' ist fertig und kontrolliert (' + (Get-Date -Format 'HH:mm') + ')' + $(if ($warn.Count) { ' - mit Hinweisen, siehe Protokoll' } else { '' })
    Out-Log ('=== Stick ' + $dr + ' fertig ===')
    Show-Msg ('Stick ' + $dr + ' ist fertig und kontrolliert.' + $(if ($warn.Count) { $nl + $nl + 'Hinweise:' + $nl + (($warn | ForEach-Object { '- ' + $_ }) -join $nl) } else { '' }) + $nl + $nl + 'Der Stick kann jetzt abgezogen werden.') 'HUPilot - Stick fertig' $(if ($warn.Count) { 'Warning' } else { 'Information' })
}
function Invoke-StickReady {
    if ($script:Busy) { return }
    $script:Busy = $true; $ui.bReady.IsEnabled = $false
    try { Invoke-StickReadyCore }
    catch { Stop-Ready '' ('Unerwarteter Fehler: ' + $_.Exception.Message) }
    finally { $script:Busy = $false; $ui.bReady.IsEnabled = $true }
}
$ui.bReady.Add_Click({ Invoke-StickReady })

# Schliessen: Rueckfrage bei ungespeicherten Aenderungen (nie im Starttest, nicht beim Update-Neustart)
$script:NoClosePrompt = $false
$win.Add_Closing({
    param($s, $e)
    if ($SmokeTest -or $script:NoClosePrompt) { return }
    if ($script:Busy) { $e.Cancel = $true; Show-Msg 'Stick fertig machen läuft noch - bitte warten, bis es fertig ist.' 'HUPilot-Setup'; return }
    Update-Dirty
    if (-not $script:Dirty) { return }
    $q = [System.Windows.MessageBox]::Show($win, ('Es gibt ungespeicherte Änderungen.' + "`r`n`r`n" + 'Ja = speichern und schließen' + "`r`n" + 'Nein = verwerfen und schließen' + "`r`n" + 'Abbrechen = weiterarbeiten'), 'HUPilot-Setup schließen', 'YesNoCancel', 'Question')
    if ($q -eq 'Cancel' -or $q -eq 'None') { $e.Cancel = $true; return }
    if ($q -eq 'Yes' -and -not (Save-Cfg)) { $e.Cancel = $true; Show-Msg ('Nicht gespeichert: ' + $script:FieldErr + "`r`n`r`n" + 'Feld korrigieren oder "Nein" wählen, um ohne Speichern zu schließen.') 'HUPilot-Setup' 'Warning' }
})
# Nach einem Update einmal erinnern: die USB-Sticks haben noch die alte Version -> "5. Auf Stick kopieren"
#   Merker Config\stickhint.json = Update-Stand (Programmversion aus version.json + Datum aus installed.json), fuer den der Hinweis schon kam.
#   Unabhaengig davon, welche Pull.ps1-Version das Update gemacht hat. Angezeigt wird die Version aus version.json (wie im Fenstertitel).
function Show-UpdateStickHint {
    $i = $null
    try { $i = Get-Content -LiteralPath (Join-Path $CfgDirHU 'installed.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { return }
    if (-not $i) { return }
    $key = $SetupVer + ' ' + [string]$i.Date
    $seen = Join-Path $CfgDirHU 'stickhint.json'
    try { if (Test-Path -LiteralPath $seen) { $s = Get-Content -LiteralPath $seen -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$s.Key -eq $key) { return } } } catch { }
    try { [pscustomobject]@{ Key = $key } | ConvertTo-Json | Set-Content -LiteralPath $seen -Encoding UTF8 -ErrorAction Stop } catch { Out-Log ('Hinweis-Merker nicht schreibbar: ' + $_.Exception.Message) }
    $ver = 'v' + $SetupVer
    $nl = [Environment]::NewLine
    $t = 'HUPilot ist jetzt auf ' + $ver + '.' + $nl + $nl
    if ($srcDrive) { $t += 'Dieser Stick (' + $srcDrive + ') ist schon aktualisiert. Alle ANDEREN Sticks haben noch die alte Version.' + $nl + $nl }
    else { $t += 'Die USB-Sticks haben noch die alte Version.' + $nl + $nl }
    $t += 'Jeden Stick neu bespielen:' + $nl + '   1. Stick anstecken' + $nl + '   2. bei "Stick" auswählen (ggf. "Aktualisieren")' + $nl + '   3. "Stick fertig machen" (oder "5. Auf Stick kopieren") klicken' + $nl + $nl + 'config.json und WLAN-Paket kommen dabei mit.'
    Out-Log ('Update auf ' + $ver + ' - Sticks jetzt mit "5. Auf Stick kopieren" neu bespielen')
    Show-Msg $t 'HUPilot - Update fertig: auf Stick kopieren'
}
if ($SmokeTest) {
    # Starttest (automatische Tests): Fenster oeffnen, 2 s laufen lassen, schliessen - kein Netzwerk
    $script:SmokeOk = $false
    $tm = New-Object System.Windows.Threading.DispatcherTimer
    $tm.Interval = [TimeSpan]::FromSeconds(2)
    $tm.Add_Tick({ $tm.Stop(); $script:SmokeOk = $win.IsLoaded; $win.Close() })
    $win.Add_ContentRendered({ $tm.Start() })
} else {
    $win.Add_ContentRendered({ Show-UpdateStickHint; Invoke-UpdateCheck -Quiet })
}
[void]$win.ShowDialog()
if ($SmokeTest) { try { Set-Content -LiteralPath $SmokeTest -Value $(if ($script:SmokeOk) { 'OK v' + $SetupVer } else { 'FEHLER: Fenster nicht geladen' }) -Encoding UTF8 } catch { } }
Start-Log 'Fenster geschlossen'
try { $script:Mutex.ReleaseMutex() } catch { }
