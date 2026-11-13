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
$SetupVer = '2.7.18'
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

# ---------- Oberflaeche dunkel oder hell nach dem HU-GUI-Standard (Stile aus HU-MultiTenant, XAML\Theme.xaml) ----------
#   $script:HuThemeXaml: Stile. Farben stehen NUR in den beiden Farb-Woerterbuechern (gleiche Schluessel) und werden
#   ueberall mit DynamicResource bezogen, dadurch wechselt die Oberflaeche sofort und ohne Neustart (Set-HuTheme).
#   Beides wird beim Laden jedes Fensters als zusammengefuehrte Woerterbuecher eingesetzt (Add-HuTheme).
#   Eigene Stile eines Fensters (z. B. die 14-px-Bildlaufleiste des Hauptfensters) haben Vorrang.
$script:HuColorsDark = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="HuBg" Color="#FF1E1E1E"/>
  <SolidColorBrush x:Key="HuPanel" Color="#FF2D2D2D"/>
  <SolidColorBrush x:Key="HuPanel2" Color="#FF252526"/>
  <SolidColorBrush x:Key="HuText" Color="#FFCCCCCC"/>
  <SolidColorBrush x:Key="HuTitle" Color="#FFFFFFFF"/>
  <SolidColorBrush x:Key="HuMuted" Color="#FF858585"/>
  <SolidColorBrush x:Key="HuBorder" Color="#FF3E3E42"/>
  <SolidColorBrush x:Key="HuGroupLine" Color="#FF4A4A50"/>
  <SolidColorBrush x:Key="HuInputBg" Color="#FF1E1E1E"/>
  <SolidColorBrush x:Key="HuInputBorder" Color="#FF555555"/>
  <SolidColorBrush x:Key="HuControl" Color="#FF3E3E42"/>
  <SolidColorBrush x:Key="HuControlHover" Color="#FF505058"/>
  <SolidColorBrush x:Key="HuButtonText" Color="#FFFFFFFF"/>
  <SolidColorBrush x:Key="HuSel" Color="#FF094771"/>
  <SolidColorBrush x:Key="HuSelText" Color="#FFFFFFFF"/>
  <SolidColorBrush x:Key="HuTextSel" Color="#FF264F78"/>
  <SolidColorBrush x:Key="HuAccent" Color="#FF4CAF50"/>
  <SolidColorBrush x:Key="HuReadOnlyText" Color="#FFAAAAAA"/>
  <SolidColorBrush x:Key="HuListLine" Color="#FF2D2D30"/>
  <SolidColorBrush x:Key="HuListHover" Color="#FF2A2D2E"/>
  <SolidColorBrush x:Key="HuGridAlt" Color="#FF232323"/>
  <SolidColorBrush x:Key="HuHeaderBg" Color="#FF2D2D2D"/>
  <SolidColorBrush x:Key="HuHeaderText" Color="#FFAAAAAA"/>
  <SolidColorBrush x:Key="HuThumb" Color="#FF5A5A5A"/>
  <SolidColorBrush x:Key="HuThumbHover" Color="#FF787878"/>
  <SolidColorBrush x:Key="HuThumbDrag" Color="#FF9A9A9A"/>
  <SolidColorBrush x:Key="HuScrollBg" Color="#FF252526"/>
  <SolidColorBrush x:Key="HuDisabledText" Color="#FF6A6A6A"/>
  <SolidColorBrush x:Key="HuOk" Color="#FF4CAF50"/>
  <SolidColorBrush x:Key="HuWarn" Color="#FFFF9800"/>
  <SolidColorBrush x:Key="HuErr" Color="#FFE57373"/>
  <SolidColorBrush x:Key="HuRun" Color="#FF42A5F5"/>
  <SolidColorBrush x:Key="HuLampOpen" Color="#FF6A6A6A"/>
  <SolidColorBrush x:Key="HuMainBg" Color="#FF2E7D32"/>
  <SolidColorBrush x:Key="HuMainHover" Color="#FF388E3C"/>
  <SolidColorBrush x:Key="HuMainPressed" Color="#FF1B5E20"/>
  <SolidColorBrush x:Key="HuStandOkBg" Color="#FF2E7D32"/>
  <SolidColorBrush x:Key="HuStandWarnBg" Color="#FF8A6D00"/>
  <SolidColorBrush x:Key="HuStandErrBg" Color="#FFB23B3B"/>
  <SolidColorBrush x:Key="HuStandText" Color="#FFFFFFFF"/>
  <SolidColorBrush x:Key="HuRowOkBg" Color="#1A4CAF50"/>
  <SolidColorBrush x:Key="HuRowWarnBg" Color="#1AFF9800"/>
  <SolidColorBrush x:Key="HuRowErrBg" Color="#24E57373"/>
  <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#FF094771"/>
  <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#FFFFFFFF"/>
</ResourceDictionary>
'@
$script:HuColorsLight = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="HuBg" Color="#FFF3F3F3"/>
  <SolidColorBrush x:Key="HuPanel" Color="#FFFFFFFF"/>
  <SolidColorBrush x:Key="HuPanel2" Color="#FFE9E9EC"/>
  <SolidColorBrush x:Key="HuText" Color="#FF1E1E1E"/>
  <SolidColorBrush x:Key="HuTitle" Color="#FF1E1E1E"/>
  <SolidColorBrush x:Key="HuMuted" Color="#FF5F6368"/>
  <SolidColorBrush x:Key="HuBorder" Color="#FFC8C8CC"/>
  <SolidColorBrush x:Key="HuGroupLine" Color="#FFC0C0C6"/>
  <SolidColorBrush x:Key="HuInputBg" Color="#FFFFFFFF"/>
  <SolidColorBrush x:Key="HuInputBorder" Color="#FFAFAFB5"/>
  <SolidColorBrush x:Key="HuControl" Color="#FFE1E1E6"/>
  <SolidColorBrush x:Key="HuControlHover" Color="#FFD0D0D8"/>
  <SolidColorBrush x:Key="HuButtonText" Color="#FF1E1E1E"/>
  <SolidColorBrush x:Key="HuSel" Color="#FFCCE4F7"/>
  <SolidColorBrush x:Key="HuSelText" Color="#FF000000"/>
  <SolidColorBrush x:Key="HuTextSel" Color="#FFADD6FF"/>
  <SolidColorBrush x:Key="HuAccent" Color="#FF2E7D32"/>
  <SolidColorBrush x:Key="HuReadOnlyText" Color="#FF444444"/>
  <SolidColorBrush x:Key="HuListLine" Color="#FFE3E3E6"/>
  <SolidColorBrush x:Key="HuListHover" Color="#FFEAF2FB"/>
  <SolidColorBrush x:Key="HuGridAlt" Color="#FFF8F8F9"/>
  <SolidColorBrush x:Key="HuHeaderBg" Color="#FFE9E9EC"/>
  <SolidColorBrush x:Key="HuHeaderText" Color="#FF333333"/>
  <SolidColorBrush x:Key="HuThumb" Color="#FFB4B4BA"/>
  <SolidColorBrush x:Key="HuThumbHover" Color="#FF94949A"/>
  <SolidColorBrush x:Key="HuThumbDrag" Color="#FF74747A"/>
  <SolidColorBrush x:Key="HuScrollBg" Color="#FFE9E9EC"/>
  <SolidColorBrush x:Key="HuDisabledText" Color="#FF9A9A9A"/>
  <SolidColorBrush x:Key="HuOk" Color="#FF2E7D32"/>
  <SolidColorBrush x:Key="HuWarn" Color="#FFA85400"/>
  <SolidColorBrush x:Key="HuErr" Color="#FFC62828"/>
  <SolidColorBrush x:Key="HuRun" Color="#FF1565C0"/>
  <SolidColorBrush x:Key="HuLampOpen" Color="#FF9E9E9E"/>
  <SolidColorBrush x:Key="HuMainBg" Color="#FF2E7D32"/>
  <SolidColorBrush x:Key="HuMainHover" Color="#FF388E3C"/>
  <SolidColorBrush x:Key="HuMainPressed" Color="#FF1B5E20"/>
  <SolidColorBrush x:Key="HuStandOkBg" Color="#FF2E7D32"/>
  <SolidColorBrush x:Key="HuStandWarnBg" Color="#FFA85400"/>
  <SolidColorBrush x:Key="HuStandErrBg" Color="#FFC62828"/>
  <SolidColorBrush x:Key="HuStandText" Color="#FFFFFFFF"/>
  <SolidColorBrush x:Key="HuRowOkBg" Color="#FFF1F8F1"/>
  <SolidColorBrush x:Key="HuRowWarnBg" Color="#FFFFF8E6"/>
  <SolidColorBrush x:Key="HuRowErrBg" Color="#FFFDECEC"/>
  <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#FFCCE4F7"/>
  <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#FF000000"/>
</ResourceDictionary>
'@
$script:HuThemeXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="DarkButton" TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource HuButtonText}"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="14,6"/>
    <Setter Property="Cursor" Value="Hand"/><Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Opacity" Value="0.85"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="DarkCheckBox" TargetType="CheckBox"><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="Margin" Value="0,4"/></Style>
  <Style x:Key="DarkComboBoxItem" TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="Background" Value="{DynamicResource HuControl}"/><Setter Property="Padding" Value="6,3"/>
    <Style.Triggers>
      <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource HuControlHover}"/><Setter Property="Foreground" Value="{DynamicResource HuTitle}"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource HuControlHover}"/><Setter Property="Foreground" Value="{DynamicResource HuTitle}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="DarkComboBox" TargetType="ComboBox">
    <Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="Background" Value="{DynamicResource HuControl}"/><Setter Property="BorderBrush" Value="{DynamicResource HuInputBorder}"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="FontSize" Value="10"/><Setter Property="MinWidth" Value="150"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource DarkComboBoxItem}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
      <Grid>
        <ToggleButton x:Name="ToggleButton" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                      IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press">
          <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="2">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="18"/></Grid.ColumnDefinitions>
                <Path x:Name="Arrow" Grid.Column="1" Fill="{DynamicResource HuText}" HorizontalAlignment="Center" VerticalAlignment="Center" Data="M 0 0 L 4 4 L 8 0 Z"/></Grid>
            </Border>
          </ControlTemplate></ToggleButton.Template>
        </ToggleButton>
        <ContentPresenter x:Name="ContentSite" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                          Margin="6,2,20,2" VerticalAlignment="Center" HorizontalAlignment="Left" IsHitTestVisible="False"/>
        <TextBox x:Name="PART_EditableTextBox" Style="{x:Null}" Visibility="Hidden" Margin="4,1,20,1" Padding="1,0" VerticalAlignment="Center" HorizontalAlignment="Stretch"
                 Background="Transparent" BorderThickness="0" Foreground="{TemplateBinding Foreground}" CaretBrush="{DynamicResource HuText}"
                 SelectionBrush="{DynamicResource HuTextSel}" FontSize="{TemplateBinding FontSize}" IsReadOnly="{TemplateBinding IsReadOnly}"/>
        <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
          <Grid x:Name="DropDown" SnapsToDevicePixels="True" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
            <Border x:Name="DropDownBorder" Background="{DynamicResource HuControl}" BorderBrush="{DynamicResource HuInputBorder}" BorderThickness="1" CornerRadius="0,0,2,2"/>
            <ScrollViewer Margin="2" SnapsToDevicePixels="True"><StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
          </Grid>
        </Popup>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsEditable" Value="True">
          <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/><Setter TargetName="ContentSite" Property="Visibility" Value="Hidden"/><Setter Property="IsTabStop" Value="False"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="DarkTextBox" TargetType="TextBox">
    <Setter Property="Background" Value="{DynamicResource HuInputBg}"/><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="6,4"/><Setter Property="CaretBrush" Value="{DynamicResource HuText}"/><Setter Property="SelectionBrush" Value="{DynamicResource HuTextSel}"/>
    <Style.Triggers>
      <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource HuAccent}"/></Trigger>
      <Trigger Property="IsReadOnly" Value="True"><Setter Property="Foreground" Value="{DynamicResource HuReadOnlyText}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="DarkPasswordBox" TargetType="PasswordBox">
    <Setter Property="Background" Value="{DynamicResource HuInputBg}"/><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="6,4"/><Setter Property="CaretBrush" Value="{DynamicResource HuText}"/>
  </Style>
  <Style x:Key="DarkListBox" TargetType="ListBox">
    <Setter Property="Background" Value="{DynamicResource HuInputBg}"/><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
  </Style>
  <Style x:Key="DarkListBoxItem" TargetType="ListBoxItem">
    <Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="Padding" Value="6,4"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
      <Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}" BorderThickness="0,0,0,1" BorderBrush="{DynamicResource HuListLine}"><ContentPresenter/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource HuListHover}"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource HuSel}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ToolTip"><Setter Property="Background" Value="{DynamicResource HuPanel2}"/><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/></Style>
  <Style TargetType="ContextMenu">
    <Setter Property="Background" Value="{DynamicResource HuPanel2}"/><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContextMenu">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4" Padding="3"><StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/></Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="MenuItem">
    <Setter Property="Foreground" Value="{DynamicResource HuText}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
      <Border x:Name="bd" Background="Transparent" CornerRadius="3" Padding="12,5">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="chk" Text="&#x2713;" Foreground="{DynamicResource HuAccent}" Width="16" Visibility="Hidden" VerticalAlignment="Center"/>
          <ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center"/>
          <TextBlock Grid.Column="2" Text="{TemplateBinding InputGestureText}" Foreground="{DynamicResource HuMuted}" Margin="24,0,0,0" VerticalAlignment="Center"/></Grid>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="chk" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource HuSel}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource HuDisabledText}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="{x:Static MenuItem.SeparatorStyleKey}" TargetType="Separator">
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Separator"><Border Height="1" Background="{DynamicResource HuBorder}" Margin="6,3"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="DarkDataGrid" TargetType="DataGrid">
    <Setter Property="Background" Value="{DynamicResource HuInputBg}"/><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="RowBackground" Value="{DynamicResource HuInputBg}"/>
    <Setter Property="AlternatingRowBackground" Value="{DynamicResource HuGridAlt}"/><Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/><Setter Property="GridLinesVisibility" Value="Horizontal"/>
    <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource HuListLine}"/><Setter Property="HeadersVisibility" Value="Column"/><Setter Property="CanUserAddRows" Value="False"/>
    <Setter Property="IsReadOnly" Value="True"/><Setter Property="SelectionMode" Value="Single"/><Setter Property="ColumnWidth" Value="Auto"/>
    <Setter Property="MinRowHeight" Value="26"/>
    <Setter Property="CellStyle"><Setter.Value>
      <Style TargetType="DataGridCell">
        <Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="Transparent"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="8,3,8,3"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
            <ContentPresenter VerticalAlignment="Center" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
          </Border>
        </ControlTemplate></Setter.Value></Setter>
        <Style.Triggers>
          <Trigger Property="IsSelected" Value="True">
            <Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.HighlightBrushKey}}"/>
            <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.HighlightTextBrushKey}}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource {x:Static SystemColors.HighlightBrushKey}}"/>
          </Trigger>
          <MultiTrigger>
            <MultiTrigger.Conditions><Condition Property="IsSelected" Value="True"/><Condition Property="Selector.IsSelectionActive" Value="False"/></MultiTrigger.Conditions>
            <Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.InactiveSelectionHighlightBrushKey}}"/>
            <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource {x:Static SystemColors.InactiveSelectionHighlightBrushKey}}"/>
          </MultiTrigger>
          <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource {x:Static DataGrid.FocusBorderBrushKey}}"/></Trigger>
        </Style.Triggers>
      </Style>
    </Setter.Value></Setter>
    <Setter Property="ColumnHeaderStyle"><Setter.Value>
      <Style TargetType="DataGridColumnHeader">
        <Setter Property="Background" Value="{DynamicResource HuHeaderBg}"/><Setter Property="Foreground" Value="{DynamicResource HuHeaderText}"/><Setter Property="Padding" Value="8,5,8,5"/>
        <Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/><Setter Property="BorderThickness" Value="0,0,1,1"/>
      </Style>
    </Setter.Value></Setter>
  </Style>
  <Style x:Key="HUScrollThumb" TargetType="Thumb">
    <Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="IsTabStop" Value="False"/><Setter Property="Focusable" Value="False"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
      <Border x:Name="b" Background="{DynamicResource HuThumb}" CornerRadius="4" Margin="2"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource HuThumbHover}"/></Trigger>
        <Trigger Property="IsDragging" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource HuThumbDrag}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="HUScrollPage" TargetType="RepeatButton">
    <Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="IsTabStop" Value="False"/><Setter Property="Focusable" Value="False"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="SnapsToDevicePixels" Value="True"/><Setter Property="Background" Value="{DynamicResource HuScrollBg}"/>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Vertical">
        <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/><Setter Property="Height" Value="Auto"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
          <Border Background="{TemplateBinding Background}"><Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource HUScrollPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
            <Track.Thumb><Thumb Style="{StaticResource HUScrollThumb}" MinHeight="24"/></Track.Thumb>
            <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource HUScrollPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
          </Track></Border>
        </ControlTemplate></Setter.Value></Setter>
      </Trigger>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/><Setter Property="Width" Value="Auto"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
          <Border Background="{TemplateBinding Background}"><Track x:Name="PART_Track" IsDirectionReversed="False">
            <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource HUScrollPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
            <Track.Thumb><Thumb Style="{StaticResource HUScrollThumb}" MinWidth="24"/></Track.Thumb>
            <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource HUScrollPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
          </Track></Border>
        </ControlTemplate></Setter.Value></Setter>
      </Trigger>
    </Style.Triggers>
  </Style>
  <!-- Gruppenrahmen: eine duenne graue Linie, Ueberschrift sitzt in der Linie (statt des doppelten weissen Standardrahmens) -->
  <Style TargetType="GroupBox">
    <Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="BorderBrush" Value="{DynamicResource HuGroupLine}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="GroupBox">
      <Grid SnapsToDevicePixels="True">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Grid.RowSpan="2" Margin="0,9,0,0" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4"/>
        <Border Grid.Row="0" HorizontalAlignment="Left" Margin="10,0,0,0" Padding="5,0" Background="{DynamicResource HuBg}">
          <ContentPresenter ContentSource="Header" RecognizesAccessKey="True" TextElement.Foreground="{DynamicResource HuMuted}"/>
        </Border>
        <ContentPresenter Grid.Row="1" Margin="{TemplateBinding Padding}"/>
      </Grid>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <!-- Standard fuer alle Steuerelemente der HUPilot-Fenster (ohne eigenen Stil) -->
  <Style TargetType="Button" BasedOn="{StaticResource DarkButton}"><Setter Property="Background" Value="{DynamicResource HuControl}"/></Style>
  <Style TargetType="TextBox" BasedOn="{StaticResource DarkTextBox}"><Setter Property="Padding" Value="4,2"/></Style>
  <Style TargetType="PasswordBox" BasedOn="{StaticResource DarkPasswordBox}"><Setter Property="Padding" Value="4,2"/></Style>
  <Style TargetType="CheckBox" BasedOn="{StaticResource DarkCheckBox}"/>
  <Style TargetType="ComboBox" BasedOn="{StaticResource DarkComboBox}"><Setter Property="FontSize" Value="12"/><Setter Property="MinWidth" Value="0"/><Setter Property="Padding" Value="4,3"/></Style>
  <Style TargetType="ListBox" BasedOn="{StaticResource DarkListBox}"/>
  <Style TargetType="ListBoxItem" BasedOn="{StaticResource DarkListBoxItem}"/>
  <Style TargetType="DataGrid" BasedOn="{StaticResource DarkDataGrid}"/>
</ResourceDictionary>
'@
# Aktuelles Theme (hell oder dunkel), gemerkt in ui.json "Theme". Fehlt oder unlesbar = dunkel.
$script:HuTheme = 'dunkel'
$script:HuWindows = New-Object System.Collections.ArrayList
function Get-HuColorsXaml([string]$Name) { if ($Name -eq 'hell') { return $script:HuColorsLight } return $script:HuColorsDark }
function Add-HuTheme([xml]$Doc) {
    $ns = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
    $root = $Doc.DocumentElement
    foreach ($a in @(@('Background', '{DynamicResource HuBg}'), @('Foreground', '{DynamicResource HuText}'), @('UseLayoutRounding', 'True'), @('TextOptions.TextFormattingMode', 'Display'))) { if (-not $root.HasAttribute($a[0])) { $root.SetAttribute($a[0], $a[1]) } }
    $res = $null
    foreach ($ch in @($root.ChildNodes)) { if ($ch.LocalName -eq 'Window.Resources') { $res = $ch } }
    if (-not $res) { $res = $Doc.CreateElement('Window.Resources', $ns); [void]$root.PrependChild($res) }
    $rd = $Doc.CreateElement('ResourceDictionary', $ns)
    $md = $Doc.CreateElement('ResourceDictionary.MergedDictionaries', $ns)
    [void]$md.AppendChild($Doc.ImportNode(([xml](Get-HuColorsXaml $script:HuTheme)).DocumentElement, $true))
    [void]$md.AppendChild($Doc.ImportNode(([xml]$script:HuThemeXaml).DocumentElement, $true))
    [void]$rd.AppendChild($md)
    foreach ($ch in @($res.ChildNodes)) { [void]$rd.AppendChild($res.RemoveChild($ch)) }
    [void]$res.AppendChild($rd)
}
# Fenster fuer die Umschaltung merken (Hauptfenster und jedes Unterfenster), beim Schliessen wieder vergessen
function Register-HuWindow($w) {
    [void]$script:HuWindows.Add($w)
    $w.Add_Closed({ try { [void]$script:HuWindows.Remove($this) } catch { } })
}
# Theme wechseln: in jedem offenen Fenster das Farb-Woerterbuch tauschen (DynamicResource zieht sofort nach)
function Set-HuTheme([string]$Name) {
    if ($Name -ne 'hell') { $Name = 'dunkel' }
    $script:HuTheme = $Name
    foreach ($w in @($script:HuWindows)) {
        try {
            $md = $w.Resources.MergedDictionaries
            for ($i = 0; $i -lt $md.Count; $i++) {
                if ($md[$i].Contains('HuBg')) { $md[$i] = [Windows.Markup.XamlReader]::Parse((Get-HuColorsXaml $Name)); break }
            }
        } catch { }
    }
}

# Gemerktes Theme laden (ui.json liegt in HUPilot\Config, fehlend oder unlesbar = dunkel)
try { $tj = Get-Content -LiteralPath (Join-Path $CfgDirHU 'ui.json') -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$tj.Theme -eq 'hell') { $script:HuTheme = 'hell' } } catch { }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot-Setup" Width="890" Height="1060" MinWidth="640" MinHeight="420" WindowStartupLocation="CenterScreen" FontSize="13" ResizeMode="CanResizeWithGrip">
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
      <Setter Property="Background" Value="{DynamicResource HuMainBg}"/><Setter Property="Foreground" Value="White"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource HuMainHover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource HuMainPressed}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="HuLamp" TargetType="Ellipse">
      <Setter Property="Width" Value="10"/><Setter Property="Height" Value="10"/><Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Fill" Value="{DynamicResource HuLampOpen}"/><Setter Property="ToolTip" Value="Stand: offen"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="14">
  <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
      <Button VerticalAlignment="Center" x:Name="bLnk" FontFamily="Segoe MDL2 Assets" Content="&#xE718;" Width="32" Padding="0,5" Margin="0,0,8,0" ToolTip="Desktop-Verknüpfung zu diesem Ordner anlegen (öffentlicher Desktop, mit HUPilot-Symbol)." ToolTipService.ShowDuration="30000"/>
      <Button VerticalAlignment="Center" x:Name="bHelp" ToolTip="Anleitung öffnen (F1)" Content="?" FontWeight="Bold" Width="32" Padding="0,4" Margin="0,0,0,0"/>
      <Button VerticalAlignment="Center" x:Name="bTheme" FontFamily="Segoe MDL2 Assets" Content="&#xE793;" Width="32" Padding="0,5" Margin="8,0,0,0" ToolTip="Helle / dunkle Oberfläche umschalten (wirkt sofort in allen Fenstern und wird gemerkt)." ToolTipService.ShowDuration="30000"/>
      <Button VerticalAlignment="Center" x:Name="bUpd" ToolTip="Prüft auf GitHub, ob es eine neuere HUPilot-Version gibt.&#x0a;Gold = Update verfügbar - Klick aktualisiert die Programmdateien in der Quelle (Stick oder Ordner).&#x0a;config.json, WLAN-Paket und logs bleiben unverändert." ToolTipService.ShowDuration="30000" Content="Update ..." Padding="10,4" Margin="8,0,0,0"/>
    </StackPanel>
    <Image x:Name="iLogo" Width="44" Height="44"/>
    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="HUPilot" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource HuTitle}"/>
      <TextBlock x:Name="tSub" Text="Stick vorbereiten - Windows Autopilot per USB" Foreground="{DynamicResource HuMuted}"/>
    </StackPanel>
  </DockPanel>
  <!-- Protokoll fest unten (nicht im Scrollbereich), Hoehe per Ziehgriff, gemerkt in HUPilot\Config\ui.json -->
  <DockPanel x:Name="pLog" DockPanel.Dock="Bottom" Margin="0,4,0,0">
    <Thumb x:Name="thLog" DockPanel.Dock="Top" Height="10" Cursor="SizeNS" ToolTip="Höhe des Protokolls anpassen (ziehen) - wird gemerkt." ToolTipService.ShowDuration="30000">
      <Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="Transparent"><Border Background="{DynamicResource HuBorder}" Height="4" Width="80" CornerRadius="2" VerticalAlignment="Center"/></Border></ControlTemplate></Thumb.Template>
    </Thumb>
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
      <Button x:Name="bLogClear" DockPanel.Dock="Right" Content="Löschen" Padding="8,1" Margin="6,0,0,0" ToolTip="Protokoll im Fenster leeren (die Protokolldatei in HUPilot\logs bleibt unverändert)." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bLogRev" DockPanel.Dock="Right" Content="Umkehren" Padding="8,1" Margin="6,0,0,0" ToolTip="Reihenfolge umkehren: neueste Zeile oben oder unten (wird gemerkt)." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bLogCopy" DockPanel.Dock="Right" Content="Protokoll kopieren" Padding="8,1" ToolTip="Markierte Zeilen (sonst das ganze Protokoll) mit den technischen Details in die Zwischenablage kopieren.&#x0a;Markieren: Klick, Strg+Klick, Umschalt+Klick. Kopieren geht auch mit Strg+C." ToolTipService.ShowDuration="30000"/>
      <TextBlock x:Name="tLogFile" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="{DynamicResource HuMuted}" FontSize="11" ToolTip="Jede Sitzung wird zusätzlich als Datei gespeichert (ohne Kennwörter und Schlüssel). Die letzten 20 Dateien bleiben." ToolTipService.ShowDuration="30000"/>
      <TextBlock Text="Protokoll" FontWeight="SemiBold" VerticalAlignment="Center" ToolTip="Was das Setup in dieser Sitzung gemacht hat: OK (grün), Hinweis (gelb), Fehler (rot)." ToolTipService.ShowDuration="30000"/>
    </DockPanel>
    <ListBox x:Name="lLog" Height="120" SelectionMode="Extended" FontFamily="Consolas" FontSize="12" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ToolTip="Protokoll dieser Sitzung. Zeilen mit technischen Details: Maus darüber zeigt das Original, Doppelklick klappt es auf." ToolTipService.ShowDuration="30000"/>
  </DockPanel>
  <!-- Hauptknopf: alles in einem Durchgang -->
  <Border x:Name="bdReady" DockPanel.Dock="Bottom" Margin="0,8,0,0" Padding="8" CornerRadius="4" BorderThickness="1" BorderBrush="{DynamicResource HuAccent}" Background="{DynamicResource HuPanel2}">
    <DockPanel>
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,12,0">
        <TextBlock Text="Stick" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="{DynamicResource HuMuted}" ToolTip="Ziel-Stick für Stick fertig machen, 5. Auf Stick kopieren und die Stick-Protokolle in Status und Hashes importieren." ToolTipService.ShowDuration="30000"/>
        <ComboBox x:Name="cDrive" Width="190" VerticalAlignment="Center" ToolTip="Ziel-Stick für Stick fertig machen und 5. Auf Stick kopieren. Das Laufwerk der Quelle selbst wird nicht angeboten." ToolTipService.ShowDuration="30000"/>
        <Button x:Name="bReload" Content="Aktualisieren" Padding="8,3" Margin="6,0,0,0" VerticalAlignment="Center" ToolTip="USB-Laufwerke neu einlesen (nach dem Anstecken eines Sticks)." ToolTipService.ShowDuration="30000"/>
      </StackPanel>
      <Button x:Name="bReady" DockPanel.Dock="Left" Style="{StaticResource HuMain}" Padding="18,8" FontSize="15" FontWeight="Bold" ToolTip="Macht den gewählten Stick in einem Durchgang fertig:&#x0a;Felder prüfen, Verbindung und Secret prüfen, Tags prüfen (nur Warnung), speichern,&#x0a;WLAN-Paket bauen, wenn es fehlt oder veraltet ist, auf den Stick kopieren und die kopierten Dateien kontrollieren.&#x0a;Bricht beim ersten echten Fehler ab und sagt, was zu tun ist." ToolTipService.ShowDuration="60000">
        <StackPanel Orientation="Horizontal"><Ellipse x:Name="eReady" Style="{StaticResource HuLamp}" Width="13" Height="13" Margin="0,0,8,0" Stroke="White" StrokeThickness="1.5"/><TextBlock x:Name="tReadyBtn" Text="Stick fertig machen"/></StackPanel>
      </Button>
      <TextBlock x:Name="tReady" Margin="12,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap" Text="Stick anstecken, links auswählen (ggf. &quot;Aktualisieren&quot;), dann &quot;Stick fertig machen&quot; klicken." ToolTip="Ergebnis des letzten Durchgangs. Einzelschritte 1 bis 7 gibt es weiterhin, jeder mit eigener Ampel." ToolTipService.ShowDuration="30000"/>
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
        <TextBlock Grid.Row="1" Grid.Column="1" Margin="2,2,0,0" Foreground="{DynamicResource HuErr}" TextWrapping="Wrap" Text="Nur für Einzelfälle: Der MAK liegt im Klartext auf dem Stick. Nicht für Massen-Rollouts, danach wieder leeren." ToolTip="Der Schlüssel steht unverschlüsselt in HUPilot\config.json auf jedem bespielten Stick. Wer den Stick hat, kann ihn lesen." ToolTipService.ShowDuration="30000"/>
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
      <TextBlock Text="Vorbereiten" Width="78" VerticalAlignment="Center" Foreground="{DynamicResource HuMuted}" Margin="0,0,0,4" ToolTip="Einzelschritte zum Vorbereiten der Quelle. Der Knopf &quot;Stick fertig machen&quot; unten erledigt sie in einem Durchgang." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bLoad" ToolTip="config.json aus der Quelle neu laden (der Ordner, aus dem dieses Setup läuft).&#x0a;Ungespeicherte Änderungen gehen dabei verloren (mit Rückfrage)." ToolTipService.ShowDuration="30000" Content="Neu laden" Padding="8,2" Margin="0,0,0,4"/>
      <Button x:Name="bTest" ToolTip="Holt mit App-ID und Secret ein Token und liest die Autopilot-Liste.&#x0a;Zeigt sofort, ob Secret abgelaufen/falsch ist oder die Berechtigung fehlt." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eTest" Style="{StaticResource HuLamp}"/><TextBlock Text="1. Verbindung testen"/></StackPanel></Button>
      <Button x:Name="bTags" ToolTip="Zeigt je Group Tag: Anzahl Geräte in Autopilot, passende dynamische Gruppe und zugewiesenes Autopilot-Profil.&#x0a;So sieht man VOR dem Einsatz, ob für einen Tag ein Profil fehlt. Gruppen lesen: optional Group.Read.All." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eTags" Style="{StaticResource HuLamp}"/><TextBlock Text="2. Tags prüfen"/></StackPanel></Button>
      <Button x:Name="bWrite" ToolTip="Speichert alle Felder als config.json in die Quelle.&#x0a;Zusätzliche Felder (TagPattern, Reset, ...) bleiben erhalten." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eWrite" Style="{StaticResource HuLamp}"/><TextBlock Text="3. Speichern"/></StackPanel></Button>
      <TextBlock x:Name="tDirty" Text="* ungespeichert" Foreground="{DynamicResource HuWarn}" FontWeight="SemiBold" VerticalAlignment="Center" Margin="6,0,0,4" Visibility="Collapsed" ToolTip="Es gibt Änderungen, die noch nicht in config.json stehen.&#x0a;3. Speichern oder Stick fertig machen speichert sie." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bPkg" ToolTip="Speichert zuerst, dann baut HUPilot-WLAN.ppkg (WLAN + optional lokaler Admin, kein CleanPC) in die Quelle.&#x0a;VORAUSSETZUNG: Windows ADK mit &quot;Imaging and Configuration Designer&quot; (WCD) auf diesem PC:&#x0a;C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe&#x0a;Die WCD-App aus dem Microsoft Store reicht NICHT (keine Kommandozeile).&#x0a;Ohne ADK: Tools\New-WcdProjekt.ps1 + WCD-Oberfläche, siehe INSTALL.md." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="ePkg" Style="{StaticResource HuLamp}"/><TextBlock Text="4. WLAN-Paket bauen"/></StackPanel></Button>
      <TextBlock x:Name="tPkg" VerticalAlignment="Center" Margin="6,0,0,4" Foreground="{DynamicResource HuMuted}" ToolTip="Stand des WLAN-Pakets in der Quelle:&#x0a;aktuell = passt zu WLAN und lokalen Admins&#x0a;veraltet = WLAN oder Admins wurden seit dem Bau geändert, neu bauen&#x0a;fehlt = noch kein Paket gebaut&#x0a;unbekannt = gebaut mit einer älteren Version, neu bauen empfohlen" ToolTipService.ShowDuration="30000"/>
    </WrapPanel>
    <WrapPanel Grid.Row="6" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="Stick" Width="78" VerticalAlignment="Center" Foreground="{DynamicResource HuMuted}" Margin="0,0,0,4" ToolTip="Kopieren auf den Stick, der unten beim grünen Knopf ausgewählt ist." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bCopy" ToolTip="Speichert zuerst, dann kopiert die Quelle 1:1 auf den Ziel-Stick:&#x0a;go.cmd, HUPilot-Setup.cmd, HUPilot\ (go.ps1, config.json, WLAN-Paket, Setup).&#x0a;Nicht kopiert: logs und Ordner, die mit _ beginnen. Danach Kontrolle der kopierten Dateien." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eCopy" Style="{StaticResource HuLamp}"/><TextBlock Text="5. Auf Stick kopieren"/></StackPanel></Button>
      <Button x:Name="bPrep" ToolTip="Nur wenn das Setup vom PC läuft: mehrere USB-Sticks auf einmal oder hintereinander&#x0a;formatieren, benennen und mit HUPilot befüllen. ALLE Daten auf den gewählten Sticks gehen verloren." ToolTipService.ShowDuration="30000" Content="Sticks vorbereiten ..." Padding="8,2" Margin="8,0,0,4"/>
    </WrapPanel>
    <WrapPanel Grid.Row="7" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="Danach" Width="78" VerticalAlignment="Center" Foreground="{DynamicResource HuMuted}" Margin="0,0,0,4" ToolTip="Nach dem Einsatz der Sticks: Stand in Autopilot ansehen, offline gespeicherte Hashes hochladen." ToolTipService.ShowDuration="30000"/>
      <Button x:Name="bStatus" ToolTip="Zeigt alle Autopilot-Geräte des Tenants mit Tag, Profil und Intune-Registrierung.&#x0a;Filter nach Tag und nach Seriennummern aus protokoll.csv (Quelle und Ziel-Stick).&#x0a;Export als CSV oder Excel, Drucken (auch als PDF)." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="0,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eStatus" Style="{StaticResource HuLamp}"/><TextBlock Text="6. Status"/></StackPanel></Button>
      <Button x:Name="bHash" ToolTip="Hashes, die go.ps1 offline am Stick gespeichert hat (HUPilot\logs\hashes.csv), hochladen.&#x0a;Liest Quelle + Ziel-Stick, weitere CSV-Dateien können hinzugefügt werden. Erledigte Zeilen wandern nach hashes-erledigt.csv." ToolTipService.ShowDuration="30000" Padding="10,4" Margin="8,0,0,4"><StackPanel Orientation="Horizontal"><Ellipse x:Name="eHash" Style="{StaticResource HuLamp}"/><TextBlock Text="7. Hashes importieren"/></StackPanel></Button>
    </WrapPanel>
  </Grid>
  </ScrollViewer>
  </DockPanel>
</Window>
'@
Add-HuTheme $xaml
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
Register-HuWindow $win
$ui = @{}
foreach ($n in 'iLogo','tSub','tTenant','tTenantId','tClientId','tSecret','pSecret','cShow','tEdKey','pEdKey','cShowEd','tTag','tTagChoices','tSsid','tKey','pKey','cShowKey','tAdmName','tAdmPw','pAdmPw','cShowAdm','tAdm2Name','tAdm2Pw','pAdm2Pw','cShowAdm2','cAskUser','cRmPkg','bTags','bHash','cDrive','bReload','bPrep','bLoad','bTest','bWrite','bPkg','bCopy','bStatus','bHelp','bTheme','bUpd','bLnk','lLog','bLogCopy','tLogFile','svMain','thLog','bLogRev','bLogClear','bReady','tReadyBtn','tReady','eReady','eTest','eTags','eWrite','ePkg','eCopy','eStatus','eHash','tDirty','tPkg') { $ui[$n] = $win.FindName($n) }

# Fenster an den Bildschirm anpassen: nie groesser als der Arbeitsbereich (ohne Taskleiste) und ganz sichtbar.
# Auf kleinen Notebooks (z. B. 1366x768 oder hohe Skalierung) ragte das Fenster sonst unter die Taskleiste.
# Unterfenster (mit Owner), die schon passen, bleiben mittig ueber dem Hauptfenster.
# Unterfenster stehen mittig ueber dem Hauptfenster, aber immer ganz im Arbeitsbereich (nie ueber den Rand hinaus).
function Set-WinFit($w) {
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($w.Height -gt $wa.Height) { $w.Height = [math]::Max($w.MinHeight, $wa.Height) }
        if ($w.Width -gt $wa.Width) { $w.Width = [math]::Max($w.MinWidth, $wa.Width) }
        $ww = $(if ($w.ActualWidth -gt 0 -and [double]::IsNaN($w.Width)) { $w.ActualWidth } else { $w.Width })
        $wh = $(if ($w.ActualHeight -gt 0 -and [double]::IsNaN($w.Height)) { $w.ActualHeight } else { $w.Height })
        $left = $wa.Left + ($wa.Width - $ww) / 2; $top = $wa.Top + ($wa.Height - $wh) / 2
        $o = $w.Owner
        if ($o -and $o.IsLoaded) { $left = $o.Left + ($o.ActualWidth - $ww) / 2; $top = $o.Top + ($o.ActualHeight - $wh) / 2 }
        $w.WindowStartupLocation = 'Manual'
        $w.Left = [math]::Max($wa.Left, [math]::Min($left, $wa.Right - $ww))
        $w.Top = [math]::Max($wa.Top, [math]::Min($top, $wa.Bottom - $wh))
    } catch { }
}
# ---------- Spaltenbreite = breitester Inhalt (Kopf eingeschlossen) plus ein festes Stueck Luft, nie mehr ----------
#   Gemessen wird der Text selbst ueber ALLE Zeilen (die Auto-Breite der Tabelle misst nur sichtbare Zeilen und wird nie kleiner).
#   Keine Stern-Breite, keine gemerkten Breiten. Obergrenze je Spalte, darueber Auslassung mit Tooltip auf den vollen Text.
# $Content/$Header: gemessene Breite in Pixeln. $Air: Zellabstand links und rechts plus Rahmen. Kopf mit Platz fuer den Sortierpfeil.
function Get-FitWidth([double]$Content, [double]$Header, [double]$Air = 18, [double]$Max = 320) {
    $w = [math]::Max($Content, $Header + 12) + $Air
    return [math]::Ceiling([math]::Min($w, $Max))
}
# Gemessen wird im selben Modus wie die Anzeige: Add-HuTheme stellt TextFormattingMode=Display ein (Zeichen auf ganze
# Pixel gerundet, breiter als die ideale Messung). Dazu 2 px Reserve fuer Rundung, sonst wird der letzte Buchstabe angeschnitten.
function Measure-TextWidth([string]$Text, $Typeface, [double]$Size) {
    if (-not $Text) { return 0.0 }
    $ft = $null
    try { $ft = New-Object System.Windows.Media.FormattedText($Text, [Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $Typeface, $Size, [System.Windows.Media.Brushes]::Black, $null, [System.Windows.Media.TextFormattingMode]::Display, 1.0) } catch { $ft = $null }
    if (-not $ft) { $ft = New-Object System.Windows.Media.FormattedText($Text, [Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $Typeface, $Size, [System.Windows.Media.Brushes]::Black); return [math]::Ceiling($ft.WidthIncludingTrailingWhitespace * 1.06) + 2 }
    return [math]::Ceiling($ft.WidthIncludingTrailingWhitespace) + 2
}
# Zellen kuerzen mit "..." und den vollen Text als Tooltip zeigen (nur sichtbar, wenn gekuerzt wurde, sonst ist er gleich)
$script:TrimStyles = @{}
function Get-TrimStyle([string]$Path) {
    if (-not $script:TrimStyles.ContainsKey($Path)) {
        $script:TrimStyles[$Path] = [Windows.Markup.XamlReader]::Parse('<Style TargetType="TextBlock" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Path=' + $Path + '}"/></Style>')
    }
    return $script:TrimStyles[$Path]
}
# Alle Spalten einer Tabelle setzen. $Max: Obergrenze je Bindungspfad (Standard 320), $Extra: Zusatz je Pfad (z. B. Schild),
# $Bold: Pfade, deren Inhalt halbfett steht. $Skip: Pfade, die unveraendert bleiben (von Hand gezogen).
# $rows: genau die ANGEZEIGTEN Zeilen (nach allen Filtern). Ist eine Spalte darin leer, ist sie so breit wie ihre Ueberschrift.
function Set-GridColumnsFit($grid, $rows, [hashtable]$Max = @{}, [hashtable]$Extra = @{}, [string[]]$Bold = @(), [string[]]$Skip = @()) {
    try {
        $ff = $grid.FontFamily; $fs = $grid.FontSize
        $tfN = New-Object System.Windows.Media.Typeface($ff, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
        $tfB = New-Object System.Windows.Media.Typeface($ff, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::SemiBold, [System.Windows.FontStretches]::Normal)
        $rows = @($rows)
        foreach ($c in @($grid.Columns)) {
            $path = ''; try { $path = [string]$c.Binding.Path.Path } catch { }
            if (-not $path -or $Skip -contains $path) { continue }
            $tf = $(if ($Bold -contains $path) { $tfB } else { $tfN })
            $m = 0.0; $seen = @{}
            foreach ($r in $rows) {
                $v = [string]$r.$path
                if (-not $v -or $seen.ContainsKey($v)) { continue }
                $seen[$v] = $true
                $x = Measure-TextWidth $v $tf $fs
                if ($x -gt $m) { $m = $x }
            }
            $h = Measure-TextWidth ([string]$c.Header) $tfN $fs
            $mx = $(if ($Max.ContainsKey($path)) { [double]$Max[$path] } else { 320 })
            $ex = $(if ($Extra.ContainsKey($path)) { [double]$Extra[$path] } else { 0 })
            # Luft: Zellabstand 8 + 8, Rahmen 1 + 1 und der feste Textrand der Textspalte 2 + 2 (gilt auch mit eigenem Stil)
            $c.Width = New-Object System.Windows.Controls.DataGridLength((Get-FitWidth ($m + $ex) $h 22 $mx))
            if ($c -is [System.Windows.Controls.DataGridTextColumn] -and $null -eq $c.ElementStyle) { $c.ElementStyle = Get-TrimStyle $path }
        }
    } catch { }
}
# Fenster so breit wie die Spalten der Tabelle (Inhalt plus Luft aus dem Zellabstand), mindestens $Min, hoechstens der
# Arbeitsbereich; danach wieder ganz in den Bildschirm. Nur wenn der Bildschirm zu schmal ist, bleibt der Querbalken.
function Set-GridWindowWidth($w, $grid, [double]$Min = 0) {
    try {
        $w.UpdateLayout()
        $cols = 0.0; foreach ($c in $grid.Columns) { if ([string]$c.Visibility -eq 'Visible') { $cols += $c.ActualWidth } }
        if ($cols -le 0) { return }
        $chrome = $w.ActualWidth - $grid.ActualWidth
        $need = [math]::Ceiling($cols + $chrome + 20)
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w.Width = [math]::Min($wa.Width, [math]::Max([math]::Max($Min, $w.MinWidth), $need))
        Set-WinFit $w
    } catch { }
}
Set-WinFit $win
# Mausrad scrollt immer das ganze Formular (ausser im Protokoll und in einer offenen Auswahlliste)
$ui.svMain.Add_PreviewMouseWheel({
    param($s, $e)
    if ($ui.lLog.IsMouseOver -or $ui.cDrive.IsDropDownOpen) { return }
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

# ---------- Protokoll: Liste mit drei Stufen (OK, Hinweis, Fehler), neueste Zeile oben (umkehrbar), Datei je Sitzung ----------
#   Sichtbar ist der Klartext, technische Details (rohe Graph- oder ICD-Meldung) im Tooltip der Zeile, per Doppelklick und immer in der Datei.
#   Datei: HUPilot\logs\setup_<yyyyMMdd_HHmm>.log (UTF-8), ohne Secret, Kennwoerter und Schluessel, die letzten 20 bleiben. logs kommt nie auf den Stick.
$script:LogTop = ([string](Get-UiSetting 'LogNewestTop' $true) -ne 'False')
$script:LogFile = $null; $script:LogFileFailed = $false
$script:LogColor = @{ OK = 'HuOk'; Hinweis = 'HuWarn'; Fehler = 'HuErr' }
# Stufe aus einem alten Zeilenanfang ableiten (FEHLER, FEHLT, ACHTUNG, WARNUNG, HINWEIS, ABBRUCH), Rest ohne Praefix
function Split-LogLevel([string]$m) {
    if ($m -cmatch '^\s*(FEHLER|FEHLT|ABBRUCH)\b\s*:?\s*(.*)$') { return @('Fehler', $Matches[2]) }
    if ($m -cmatch '^\s*(ACHTUNG|WARNUNG|HINWEIS)\b\s*:?\s*(.*)$') { return @('Hinweis', $Matches[2]) }
    return @('', $m)
}
# Geheimes ausblenden: bekannte Werte (Secret, Kennwoerter) durch ***, Produktschluessel bis auf die letzten 5 Zeichen
function Hide-LogSecrets([string]$Text, [string[]]$Values) {
    if (-not $Text) { return $Text }
    foreach ($v in @($Values | Where-Object { $_ -and $_.Length -ge 4 } | Sort-Object Length -Descending)) { $Text = $Text.Replace($v, '***') }
    return [regex]::Replace($Text, '\b[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-([A-Za-z0-9]{5})\b', '*****-*****-*****-*****-$1')
}
function Get-LogSecretValues {
    try { return @((Get-Secret), (Get-Masked 'Key'), (Get-Masked 'AdmPw'), (Get-Masked 'Adm2Pw'), (Get-EdKey)) } catch { return @() }
}
function Write-LogFile([string]$Line) {
    if ($SmokeTest -or $script:LogFileFailed) { return }
    try {
        if (-not $script:LogFile) {
            $d = Join-Path $srcHU 'logs'
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            foreach ($o in @(Get-ChildItem -LiteralPath $d -Filter 'setup_*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 19)) { Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue }
            $script:LogFile = Join-Path $d ('setup_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.log')
            try { $ui.tLogFile.Text = 'Datei: logs\' + (Split-Path $script:LogFile -Leaf) } catch { }
        }
        [System.IO.File]::AppendAllText($script:LogFile, $Line + "`r`n", $enc)
    } catch { $script:LogFileFailed = $true }
}
# Eine Zeile in eine Protokoll-Liste (Hauptfenster oder Unterfenster)
function Add-LogItem($List, [string]$Level, [string]$Text, [string]$Detail = '', [bool]$Top = $false) {
    $it = New-Object System.Windows.Controls.ListBoxItem
    $sp = New-Object System.Windows.Controls.StackPanel
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text + $(if ($Detail) { '   (Details: Doppelklick)' } else { '' }); $tb.TextWrapping = 'Wrap'
    if ($script:LogColor.ContainsKey($Level)) { try { $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $script:LogColor[$Level]) } catch { } }
    [void]$sp.Children.Add($tb)
    if ($Detail) {
        $dt = New-Object System.Windows.Controls.TextBlock
        $dt.Text = 'Details: ' + $Detail; $dt.TextWrapping = 'Wrap'; $dt.Visibility = 'Collapsed'; $dt.Margin = '70,0,0,2'
        $dt.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'HuMuted')
        [void]$sp.Children.Add($dt)
        $it.ToolTip = $Detail
        $it.Add_MouseDoubleClick({ $d = $this.Content.Children[1]; $d.Visibility = $(if ([string]$d.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }) })
    }
    $it.Content = $sp; $it.Padding = '4,1'
    $it.Tag = [pscustomobject]@{ Text = $Text; Detail = $Detail }
    if ($Top) { $List.Items.Insert(0, $it) } else { [void]$List.Items.Add($it) }
    try { $List.ScrollIntoView($it) } catch { }
}
# -FileText: abweichender Text fuer die Protokolldatei (z. B. ohne Secret-Kennung). $script:QuietDedupe: beim stillen
# Aktualisieren im Status jede gleiche Zeile nur einmal (Hashtabelle der schon geschriebenen Zeilen), sonst $null.
$script:QuietDedupe = $null
function Out-Log([string]$m, [string]$Level = '', [string]$Detail = '', [string]$FileText = '') {
    if (-not $Level) { $sl = Split-LogLevel $m; $Level = $sl[0]; $m = $sl[1] }
    if ($null -ne $script:QuietDedupe) { $qk = $Level + '|' + $m; if ($script:QuietDedupe.ContainsKey($qk)) { return }; $script:QuietDedupe[$qk] = $Level }
    $sec = Get-LogSecretValues
    $m = Hide-LogSecrets $m $sec; $Detail = Hide-LogSecrets $Detail $sec
    $time = Get-Date -Format 'HH:mm:ss'
    $text = $(if ($Level) { $Level + ': ' + $m } else { $m })
    $ftext = $(if ($FileText) { $(if ($Level) { $Level + ': ' } else { '' }) + (Hide-LogSecrets $FileText $sec) } else { $text })
    Write-LogFile ((Get-Date -Format 'yyyy-MM-dd ') + $time + '  ' + $ftext + $(if ($Detail) { "`r`n                     Details: " + ($Detail -replace "`r?`n", ' | ') } else { '' }))
    Add-LogItem $ui.lLog $Level ($time + '  ' + $text) $Detail $script:LogTop
}
# Protokoll eines Unterfensters: gleiche Stufen und Farben, auch in die Datei (mit Fensternamen)
function Out-SubLog($List, $Window, [string]$Source, [string]$m, [string]$Level = '', [string]$Detail = '') {
    if (-not $Level) { $sl = Split-LogLevel $m; $Level = $sl[0]; $m = $sl[1] }
    $sec = Get-LogSecretValues
    $m = Hide-LogSecrets $m $sec; $Detail = Hide-LogSecrets $Detail $sec
    $time = Get-Date -Format 'HH:mm:ss'
    $text = $(if ($Level) { $Level + ': ' + $m } else { $m })
    Write-LogFile ((Get-Date -Format 'yyyy-MM-dd ') + $time + '  [' + $Source + '] ' + $text + $(if ($Detail) { "`r`n                     Details: " + ($Detail -replace "`r?`n", ' | ') } else { '' }))
    Add-LogItem $List $Level ($time + '  ' + $text) $Detail $false
    try { $Window.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) } catch { }
}
# Markierte Zeilen (sonst alle) mit Details in die Zwischenablage, in der angezeigten Reihenfolge
function Copy-LogItems($List) {
    $items = @($List.Items | Where-Object { $_.IsSelected })
    if (-not $items.Count) { $items = @($List.Items) }
    $txt = ($items | ForEach-Object { $_.Tag.Text + $(if ($_.Tag.Detail) { "`r`n          Details: " + $_.Tag.Detail } else { '' }) }) -join "`r`n"
    try { if ($txt) { [System.Windows.Clipboard]::SetText($txt) }; return $items.Count } catch { return 0 }
}
# Protokollhoehe: gemerkter Wunsch in ui.json (LogHeight). Angezeigt wird hoechstens so viel, dass dem Formular etwa 200 px bleiben,
# mindestens etwa 3 Zeilen. Wird das Fenster kleiner, schrumpft das Protokoll mit, ohne den gemerkten Wert zu aendern.
$script:LogWanted = 120
try { $h = [double](Get-UiSetting 'LogHeight' 120); if ($h -ge 60 -and $h -le 800) { $script:LogWanted = $h } } catch { }
$ui.lLog.Height = $script:LogWanted
# Automatisch: das Formular bekommt so viel, wie es braucht; das Protokoll nimmt den Rest, mindestens etwa 4 Zeilen.
function Get-LogMax {
    $avail = $ui.svMain.ActualHeight + $ui.lLog.ActualHeight
    if ($avail -le 0) { return 800 }
    $form = $ui.svMain.ExtentHeight; if ($form -le 0) { $form = 200 }
    return [math]::Max(80, [math]::Min(800, $avail - $form))
}
# Von Hand (Ziehgriff): bis dem Formular noch etwa 200 px bleiben
function Get-LogDragMax {
    $avail = $ui.svMain.ActualHeight + $ui.lLog.ActualHeight
    if ($avail -le 0) { return 800 }
    return [math]::Max(80, [math]::Min(800, $avail - 200))
}
function Update-LogFit { try { $ui.lLog.Height = [math]::Max(80, [math]::Min($script:LogWanted, (Get-LogMax))) } catch { } }
$ui.thLog.Add_DragDelta({
    param($s, $e)
    $ui.lLog.Height = [math]::Max(80, [math]::Min((Get-LogDragMax), $ui.lLog.Height - $e.VerticalChange))
    $script:LogWanted = $ui.lLog.Height
})
$ui.thLog.Add_DragCompleted({ Set-UiSetting 'LogHeight' ([int]$script:LogWanted) })
$win.Add_SizeChanged({ Update-LogFit })
$win.Add_ContentRendered({ Update-LogFit })
$ui.bLogRev.Add_Click({
    $a = @($ui.lLog.Items); $ui.lLog.Items.Clear()
    [array]::Reverse($a)
    foreach ($it in $a) { [void]$ui.lLog.Items.Add($it) }
    $script:LogTop = -not $script:LogTop
    Set-UiSetting 'LogNewestTop' $script:LogTop
    if ($ui.lLog.Items.Count) { $ui.lLog.ScrollIntoView($ui.lLog.Items[$(if ($script:LogTop) { 0 } else { $ui.lLog.Items.Count - 1 })]) }
})
$ui.bLogClear.Add_Click({ $ui.lLog.Items.Clear() })
$ui.bLogCopy.Add_Click({ $n = Copy-LogItems $ui.lLog; $ui.bLogCopy.ToolTip = ('' + $n + ' Zeile(n) kopiert. ' + 'Markierte Zeilen (sonst das ganze Protokoll) mit den technischen Details in die Zwischenablage kopieren. Strg+C geht auch.') })
$ui.lLog.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'C' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { [void](Copy-LogItems $ui.lLog); $e.Handled = $true } })

# ---------- Ampeln je Schritt (offen, laeuft, ok, Warnung, Fehler) ----------
$script:LampColor = @{ open = 'HuLampOpen'; run = 'HuRun'; ok = 'HuOk'; warn = 'HuWarn'; err = 'HuErr' }
$script:LampText  = @{ open = 'offen'; run = 'läuft ...'; ok = 'OK'; warn = 'Warnung'; err = 'Fehler' }
$script:LampNote = @{}
function Set-Step([string]$Step, [string]$State, [string]$Note = '') {
    $e = $ui['e' + $Step]
    if (-not $e -or -not $script:LampColor.ContainsKey($State)) { return }
    $script:LampNote[$Step] = $Note
    try {
        $e.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $script:LampColor[$State])
        $e.ToolTip = 'Stand: ' + $script:LampText[$State] + $(if ($Note) { ' - ' + $Note } else { '' }) + '  (' + (Get-Date -Format 'HH:mm') + ')'
    } catch { }
}
# Waehrend Stick fertig machen, Kopieren und Paketbau: alle Knoepfe sperren, die verschachtelt mitlaufen koennten (zaehlt Ebenen)
$script:Busy = $false; $script:BusyDepth = 0
function Set-UiBusy([bool]$On) {
    if ($On) { $script:BusyDepth++ } else { $script:BusyDepth = [math]::Max(0, $script:BusyDepth - 1) }
    $script:Busy = ($script:BusyDepth -gt 0)
    foreach ($n in 'bReady', 'bTest', 'bTags', 'bWrite', 'bPkg', 'bCopy', 'bPrep', 'bLoad', 'bUpd', 'bStatus', 'bHash', 'bReload', 'cDrive', 'bLnk') { try { $ui[$n].IsEnabled = -not $script:Busy } catch { } }
}
function Get-Drive { if ($ui.cDrive.SelectedItem) { return ([string]$ui.cDrive.SelectedItem).Substring(0, 2) } return $null }
# Gewaehlter Stick nur, wenn er noch da ist. Prueft ueber .NET (nicht ueber PowerShell-Laufwerke): ein abgezogener oder
# neu eingehaengter Stick fehlt sonst als PS-Laufwerk, und Join-Path/Import-Csv brechen mit "Laufwerk D nicht vorhanden" ab.
function Get-ReadyDrive {
    $d = Get-Drive
    if (-not $d) { return $null }
    try { if ([System.IO.Directory]::Exists($d + '\')) { return $d } } catch { }
    Out-Log ('Stick ' + $d + ' ist nicht mehr da. Stick einstecken und bei "Stick" auf "Aktualisieren" klicken.') 'Fehler'
    return $null
}
function Update-Drives {
    $ui.cDrive.Items.Clear()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try { if ($d.IsReady -and $d.DriveType -eq 'Removable' -and $d.Name.Substring(0, 2).ToUpper() -ne $srcDrive) { [void]$ui.cDrive.Items.Add(('{0} {1} ({2:N1} GB)' -f $d.Name.TrimEnd('\'), $d.VolumeLabel, ($d.TotalSize / 1GB))) } } catch { }
    }
    if ($ui.cDrive.Items.Count) {
        $ui.cDrive.SelectedIndex = 0
    } else { Out-Log 'Kein Ziel-Stick gefunden. Für "Stick fertig machen" und "5. Auf Stick kopieren" einen Stick anstecken und "Aktualisieren" klicken.' 'Hinweis' }
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
function Stop-Field([string]$m) { Out-Log $m 'Fehler'; $script:FieldErr = $m; return $false }
# Pruefungen sind an den Aufrufer gebunden:
#   immer:        Pflichtfelder aus -Names, GUIDs, WLAN-Kennwort (wenn verlangt)
#   -Admin:       lokale Admins (nur Speichern und Paketbau) - sonst blockiert ein halb ausgefuellter Admin
#                 Verbindungstest, Tags, Status, Hashes und die Secret-Pruefung beim Start
#   GroupTag in -Names (nur beim Speichern): MAK, Group Tag und Auswahl (gleiches Muster wie go.ps1, hoechstens 9)
function Test-Fields([string[]]$Names, [switch]$Admin) {
    $script:FieldErr = ''
    $c = Get-Cfg
    # Namen der Felder wie im Fenster (nicht wie in config.json)
    $label = @{ Tenant = 'Anzeigename'; TenantId = 'Tenant-ID'; ClientId = 'App-ID (Client)'; ClientSecret = 'Secret (Wert)'; GroupTag = 'Group Tag (Standard)'; WlanSsid = 'WLAN-Name'; WlanKey = 'WLAN-Kennwort' }
    $miss = @($Names | Where-Object { -not $c[$_] } | ForEach-Object { $(if ($label.ContainsKey($_)) { $label[$_] } else { $_ }) })
    if ($miss.Count -eq 1) { return (Stop-Field ($miss[0] + ' fehlt. Bitte oben eintragen.')) }
    if ($miss.Count) { return (Stop-Field ('Es fehlen: ' + ($miss -join ', ') + '. Bitte oben eintragen.')) }
    if ($Names -contains 'TenantId' -and $c.TenantId -notmatch '^[0-9a-fA-F-]{36}$') { return (Stop-Field 'Tenant-ID hat nicht die Form xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx. Bitte die Mandanten-ID aus dem Entra Admin Center kopieren.') }
    if ($Names -contains 'ClientId' -and $c.ClientId -notmatch '^[0-9a-fA-F-]{36}$') { return (Stop-Field 'App-ID (Client) hat nicht die Form xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx. Bitte die Anwendungs-ID der App-Registrierung kopieren.') }
    if ($Names -contains 'WlanKey' -and $c.WlanKey.Length -lt 8) { return (Stop-Field 'WLAN-Kennwort ist kürzer als 8 Zeichen. Bitte das richtige Kennwort eintragen.') }
    if ($Admin) {
        foreach ($a in @(@('Admin-Name', 'Admin-Kennwort', $c.AdminName, $c.AdminPassword), @('Admin 2 - Name', 'Admin 2 - Kennwort', $c.Admin2Name, $c.Admin2Password))) {
            if (-not $a[2]) { if ($a[3]) { return (Stop-Field ($a[1] + ' ist eingetragen, aber ' + $a[0] + ' fehlt. Namen eintragen oder das Kennwort leeren.')) }; continue }
            if ($a[2].Length -gt 20 -or $a[2] -match '["/\\\[\]:;|=,+*?<>@ ]') { return (Stop-Field ($a[0] + ' ist ungültig: höchstens 20 Zeichen, keine Leer- oder Sonderzeichen wie / \ [ ] : ; | = , + * ? < > @. Bitte ändern.')) }
            if ([string]$a[3] -eq '' -or $a[3].Length -lt 8) { return (Stop-Field ($a[1] + ' ist kürzer als 8 Zeichen. Bitte ein längeres Kennwort eintragen.')) }
        }
        if ($c.AdminName -and $c.Admin2Name -and $c.AdminName -eq $c.Admin2Name) { return (Stop-Field 'Admin-Name und Admin 2 - Name sind gleich. Bitte zwei verschiedene Namen eintragen.') }
    }
    # MAK nur beim Speichern pruefen (dort ist GroupTag Pflicht): sonst scheitern Verbindungstest und Secret-Pruefung an einem falschen MAK
    $chkEd = $Names -contains 'GroupTag'
    if ($chkEd -and $c.EditionKey -and $c.EditionKey -notmatch '^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$') { return (Stop-Field 'MAK (Pro) hat nicht die Form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX. Bitte korrigieren oder das Feld leeren.') }
    # Allgemeine Schluessel von Microsoft (Installation/KMS-Client) aktivieren nicht - gleiche Liste wie in go.ps1
    if ($chkEd -and $c.EditionKey -and @('VK7JG-NPHTM-C97JM-9MPGT-3V66T', '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT', 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7', 'W269N-WFGWX-YVC9B-4J6C9-T83GX', 'MH37W-N47XK-V7XM9-C7227-GCQG9') -contains $c.EditionKey) { return (Stop-Field 'MAK (Pro): das ist der allgemeine Schlüssel von Microsoft, der aktiviert nicht. Bitte den MAK der Schule (Volumenlizenz) eintragen oder das Feld leeren.') }
    # Group Tag und Auswahl: go.ps1 bricht am Geraet sonst rot ab bzw. zeigt nur die ersten 9
    if ($chkEd) {
        $tp = Get-TagPattern $c
        $std = ($tp -eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
        $rule = $(if ($std) { 'erlaubt: Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich, am Anfang Buchstabe oder Ziffer, höchstens 64 Zeichen' } else { 'Muster aus config.json (TagPattern): ' + $tp })
        try { [void][regex]::new($tp) } catch { return (Stop-Field ('TagPattern in config.json ist kein gültiges Muster: ' + $tp + '. Bitte in config.json korrigieren oder die Zeile entfernen.')) }
        if ($c.GroupTag -notmatch $tp) { return (Stop-Field ('Group Tag (Standard) "' + $c.GroupTag + '" ist ungültig - ' + $rule + '. Bitte oben ändern.')) }
        $badC = @(@($c.TagChoices) | Where-Object { [string]$_ -notmatch $tp })
        if ($badC.Count) { return (Stop-Field ('Auswahl (Komma): ungültige(r) Eintrag/Einträge "' + ($badC -join '", "') + '" - ' + $rule + '. Bitte oben ändern.')) }
        if (@($c.TagChoices).Count -gt 9) { return (Stop-Field ('Auswahl (Komma) hat ' + @($c.TagChoices).Count + ' Einträge, am Gerät sind nur 9 wählbar (Taste 1 bis 9). Bitte auf höchstens 9 kürzen.')) }
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
    if (Test-Path $f) { Start-Process -FilePath $f } else { Out-Log 'Die Anleitung fehlt in HUPilot\Setup. Mit "Update" neu laden.' 'Hinweis' $f }
}
$ui.bHelp.Add_Click($ShowHelp)
$ui.bTheme.Add_Click({ Set-HuTheme $(if ($script:HuTheme -eq 'hell') { 'dunkel' } else { 'hell' }); Set-UiSetting 'Theme' $script:HuTheme })

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
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="{DynamicResource HuErr}" FontWeight="SemiBold" Margin="0,0,0,8"
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
    <ListBox x:Name="tPLog" ToolTip="Protokoll dieses Fensters: OK (grün), Hinweis (gelb), Fehler (rot). Steht auch in der Protokolldatei." DockPanel.Dock="Bottom" Height="150" Margin="0,8,0,0" SelectionMode="Extended" ScrollViewer.HorizontalScrollBarVisibility="Disabled" FontFamily="Consolas" FontSize="12"/>
    <ListBox x:Name="lSticks" SelectionMode="Multiple" FontFamily="Consolas" ToolTip="Gefundene USB-Sticks - anklicken zum Auswählen (mehrere möglich)."/>
  </DockPanel>
</Window>
'@
    Add-HuTheme $px
    $pw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $px))
    Register-HuWindow $pw
    $pw.Owner = $win
    if ($win.Icon) { $pw.Icon = $win.Icon }
    Set-WinFit $pw
    $g = @{}; foreach ($n in 'tLabel','cFs','bScan','bAll','bGo','bClose','tPLog','lSticks') { $g[$n] = $pw.FindName($n) }
    foreach ($f in 'NTFS', 'exFAT', 'FAT32') { [void]$g.cFs.Items.Add($f) }
    $g.cFs.SelectedIndex = 0
    $g.tLabel.Text = 'HUPILOT'
    $script:PrepList = @()
    $plog = { param($m, $lv = '', $dt = '') Out-SubLog $g.tPLog $pw 'Sticks vorbereiten' $m $lv $dt }
    $g.tPLog.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'C' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { [void](Copy-LogItems $g.tPLog); $e.Handled = $true } })
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
        if (-not $sel.Count) { & $plog 'Keinen Stick gewählt. Sticks in der Liste anklicken.' 'Hinweis'; return }
        $label = $g.tLabel.Text.Trim(); $fs = [string]$g.cFs.SelectedItem
        if ($label -notmatch '^[A-Za-z0-9_-]{1,11}$') { & $plog 'Name ungültig: 1 bis 11 Zeichen, nur Buchstaben, Ziffern, - und _. Bitte oben ändern.' 'Fehler'; return }
        if (-not (Save-Cfg)) { & $plog ('Nicht gespeichert: ' + $script:FieldErr + ' (im Hauptfenster)') 'Fehler'; return }
        if (-not (Confirm-PkgForCopy $pw)) { & $plog 'Abgebrochen (WLAN-Paket).'; return }
        # Secret und MAK einmal fuer den ganzen Durchgang
        $pre = Confirm-CopyPrereqs ('die gewählten Sticks (' + $sel.Count + ')') $pw
        if (-not $pre) { & $plog 'Abgebrochen.'; return }
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
                if (Copy-ToStick ($dl + ':') $pre.WithMak) { & $plog ($dl + ': fertig, kopiert und kontrolliert. Stick abziehen.') 'OK'; $ok++ } else { & $plog ($dl + ': Kopieren fehlgeschlagen. Stick neu anstecken und nochmal versuchen.') 'Fehler' $script:CopyErr }
            } catch { & $plog ($dl + ': nicht bearbeitet. ' + $(if ("$($_.Exception.Message)" -match 'FAT32|USB-Stick') { $_.Exception.Message } else { 'Stick neu anstecken und nochmal versuchen.' })) 'Fehler' $_.Exception.Message }
        }
        & $plog ('Fertig: ' + $ok + ' von ' + $sel.Count + ' Stick(s). Nächste Sticks anstecken, dann "Neu einlesen".') $(if ($ok -eq $sel.Count) { 'OK' } else { 'Hinweis' })
        Out-Log ('Sticks vorbereitet: ' + $ok + ' von ' + $sel.Count) $(if ($ok -eq $sel.Count) { 'OK' } else { 'Hinweis' })
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
    if (-not $c -or -not $c.GetNetworkCredential().Password.Trim()) { Out-Log 'Kein Token eingegeben.' 'Hinweis'; return $false }
    try {
        $d = Split-Path $File -Parent
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $c | Export-Clixml -Path $File -Force -ErrorAction Stop
        return $true
    } catch { Out-Log 'Token konnte nicht gespeichert werden.' 'Fehler' $_.Exception.Message; return $false }
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
        $ui.bUpd.Foreground = [System.Windows.Media.Brushes]::Black
        $ui.bUpd.FontWeight = 'Bold'
    } else {
        $ui.bUpd.Content = $(if ($Text) { $Text } else { 'Aktuell v' + $SetupVer })
        $ui.bUpd.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
        $ui.bUpd.ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
        $ui.bUpd.ClearValue([System.Windows.Controls.Control]::FontWeightProperty)
    }
}
function Get-HttpCode($e) { $code = 0; try { $code = [int]$e.Exception.Response.StatusCode } catch { }; return $code }

function Invoke-UpdateCheck([switch]$Quiet) {
    $c = Get-UpdCfg
    if (-not $c) { Set-UpdButton -Text 'Update ...'; Out-Log 'Update-Prüfung nicht möglich: HUPilot\Setup\Core-Update.ps1 fehlt. HUPilot neu installieren (Pull.ps1).' 'Fehler'; return }
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
            Out-Log ('Neue Version v' + $rv + ' verfügbar (installiert: v' + $SetupVer + ', ' + $chan + '). Oben rechts auf "Update" klicken.') 'Hinweis'
        } else {
            $script:UpdRemote = ''
            Set-UpdButton
            if (-not $Quiet) { Out-Log ('Version aktuell: v' + $SetupVer + ' (' + $chan + $(if ($c.RequireSignature) { ', nur signierte Updates' }) + ')') 'OK' }
        }
    } catch {
        $code = Get-HttpCode $_
        Set-UpdButton -Text 'Update: offline'
        if ($code -in 401, 403, 404) { Out-Log ('Update-Prüfung: ' + $c.Owner + '/' + $c.Repo + ' nicht erreichbar. Später nochmal versuchen.') 'Hinweis' ('HTTP ' + $code) }
        else { Out-Log 'Update-Prüfung nicht möglich (keine Verbindung zu GitHub?). Später nochmal versuchen.' 'Hinweis' $_.Exception.Message }
    }
}

# Pull.ps1 starten (eigenes Fenster), Setup beenden - Pull wartet, bis das Setup zu ist, und startet es danach neu
function Start-Pull([string]$Version = '') {
    if (-not (Test-Path -LiteralPath $script:PullPs)) { Out-Log 'Update nicht möglich: Pull.ps1 fehlt in HUPilot\Setup.' 'Fehler' $script:PullPs; return }
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
    } catch { Out-Log 'Update konnte nicht gestartet werden.' 'Fehler' $_.Exception.Message }
}

# Liste zur Auswahl (Versionen). Rueckgabe: gewaehlte Zeile oder $null
function Show-Pick([string]$Title, [string]$Hint, [object[]]$Rows, [string]$OkText, $Owner = $null) {
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
    Add-HuTheme $vx
    $vw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $vx))
    Register-HuWindow $vw
    $vw.Owner = $(if ($Owner) { $Owner } else { $win }); if ($win.Icon) { $vw.Icon = $win.Icon }
    $vw.Title = $Title
    Set-WinFit $vw
    $g = @{}; foreach ($n in 'tHint', 'bOk', 'bNo', 'gV') { $g[$n] = $vw.FindName($n) }
    $g.tHint.Text = $Hint; $g.bOk.Content = $OkText
    $g.gV.ItemsSource = @($Rows)
    $st = @{ Sel = $null }
    $g.bOk.Add_Click({ if ($g.gV.SelectedItem) { $st.Sel = $g.gV.SelectedItem; $vw.Close() } })
    $g.gV.Add_MouseDoubleClick({ if ($g.gV.SelectedItem) { $st.Sel = $g.gV.SelectedItem; $vw.Close() } })
    $g.bNo.Add_Click({ $vw.Close() })
    $vw.Add_ContentRendered({ Set-GridColumnsFit $g.gV @($Rows); Set-GridWindowWidth $vw $g.gV 600 })
    [void]$vw.ShowDialog()
    return $st.Sel
}
function Show-VersionPicker {
    $c = Get-UpdCfg
    if (-not $c) { Out-Log 'Versionsliste nicht möglich: HUPilot\Setup\Core-Update.ps1 fehlt.' 'Fehler'; return }
    Out-Log 'Versionen werden von GitHub gelesen ...'; Step-Ui
    try { $list = @(Get-HMReleases $c.Owner $c.Repo (Read-GhToken)) }
    catch { Out-Log 'Versionen konnten nicht von GitHub gelesen werden. Später nochmal versuchen.' 'Fehler' $_.Exception.Message; return }
    if (-not $list.Count) { Out-Log 'Keine Versionen auf GitHub gefunden.' 'Hinweis'; return }
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
    if (-not $cert) { $m = 'Signatur-Zertifikat ' + $c.SignerThumbprint + ' mit privatem Schlüssel ist auf diesem PC nicht vorhanden (oder abgelaufen).'; Out-Log $m 'Fehler'; Show-Msg $m 'Release signieren' 'Error'; return }
    Out-Log ('Zertifikat: ' + $cert.Subject + ' - gültig bis ' + $cert.NotAfter.ToString('dd.MM.yyyy'))
    $tok = Get-SignToken $c
    if (-not $tok) { Out-Log 'Abgebrochen: kein GitHub-Token mit Schreibrecht.'; return }
    Step-Ui
    try { $all = @(Get-HMReleases $c.Owner $c.Repo $tok) } catch { $m = 'Releases nicht lesbar: ' + $_.Exception.Message; Out-Log $m 'Fehler'; Show-Msg $m 'Release signieren' 'Error'; return }
    $tags = @($all | Where-Object { $_.ManifestUrl -and -not $_.SignatureUrl } | ForEach-Object { "$($_.Tag)" })
    $noMan = @($all | Where-Object { -not $_.ManifestUrl } | Select-Object -First 5 | ForEach-Object { "$($_.Tag)" })
    if ($noMan.Count) { Out-Log ('Ohne Prüfsummen-Datei (automatische Tests noch nicht fertig oder fehlgeschlagen): ' + ($noMan -join ', ')) }
    if (-not $tags.Count) { Out-Log 'Nichts zu signieren - alle Releases mit Prüfsumme sind bereits signiert.'; Show-Msg ('Nichts zu signieren - alle Releases mit Prüfsumme sind bereits signiert.' + "`r`n`r`n" + 'Eine neue Version entsteht erst mit dem Merge nach main (danach ein paar Minuten warten, bis die automatischen Tests die Prüfsummen-Datei angehängt haben).') 'Release signieren'; return }
    $q = [System.Windows.MessageBox]::Show($win, ('Diese Releases jetzt signieren?' + "`r`n`r`n" + ($tags -join ', ') + "`r`n`r`n" + 'Danach werden sie allen Installationen angeboten (je nach Kanal Stabil/Test).'), 'Release signieren', 'YesNo', 'Question')
    if ($q -ne 'Yes') { Out-Log 'Signieren abgebrochen.'; return }
    Out-Log ('Signiere ' + ($tags -join ', ') + ' ...'); Step-Ui
    try { $res = @(Invoke-HMReleaseSigning $c.Owner $c.Repo $c.SignerThumbprint $tok ([string[]]$tags)) }
    catch { $m = 'Signieren fehlgeschlagen: ' + $_.Exception.Message; Out-Log $m 'Fehler'; Show-Msg $m 'Release signieren' 'Error'; return }
    foreach ($x in $res) { Out-Log ($x.Tag + ': ' + $x.Text) $(if ($x.Ok) { 'OK' } else { 'Fehler' }) }
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
    try { $l = @(Get-HMReleases $c.Owner $c.Repo $tok) } catch { $m = 'Releases nicht lesbar: ' + $_.Exception.Message; Out-Log $m 'Fehler'; Show-Msg $m 'Release freigeben' 'Error'; return }
    $stable = @($l | Where-Object { -not $_.Prerelease } | Select-Object -First 1)[0]
    $cand = @($l | Where-Object { $_.Prerelease -and $_.ManifestUrl -and $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | Select-Object -First 1)[0]
    $uns = @($l | Where-Object { $_.Prerelease -and -not $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | ForEach-Object { $_.Tag })
    $stTxt = $(if ($stable) { $stable.Tag } else { '-' })
    Out-Log ('Bisher freigegeben: ' + $stTxt)
    if (-not $cand) { $m = 'Kein signiertes Vorab-Release neuer als ' + $stTxt + '.' + $(if ($uns.Count) { ' Noch nicht signiert: ' + ($uns -join ', ') + " - zuerst 'Release signieren'." }); Out-Log $m 'Hinweis'; Show-Msg $m 'Release freigeben' 'Warning'; return }
    $q = [System.Windows.MessageBox]::Show($win, ($cand.Tag + ' jetzt freigeben?' + "`r`n`r`n" + 'Danach ist es im Kanal Stabil die neueste Version und wird ALLEN Installationen als Update angeboten.' + "`r`n" + 'Bisher freigegeben: ' + $stTxt), 'Release freigeben', 'YesNo', 'Question')
    if ($q -ne 'Yes') { Out-Log 'Freigabe abgebrochen.'; return }
    Out-Log ('Gebe ' + $cand.Tag + ' frei ... (Signatur wird vorher erneut geprüft)'); Step-Ui
    try {
        Publish-HMRelease $c.Owner $c.Repo $cand.Tag $c.SignerThumbprint $tok
        Out-Log ($cand.Tag + ': freigegeben (Kanal Stabil)') 'OK'
        Show-Msg ($cand.Tag + ' ist freigegeben (Kanal Stabil) und wird allen Installationen als Update angeboten.') 'Release freigeben'
        Invoke-UpdateCheck -Quiet
    } catch {
        $code = Get-HttpCode $_
        if ($code -in 401, 403, 404) { Remove-Item -LiteralPath (Get-SignTokenFile) -Force -ErrorAction SilentlyContinue; $m = 'Freigabe fehlgeschlagen: kein Schreibrecht (HTTP ' + $code + ') - gespeicherter Token wurde gelöscht, beim nächsten Versuch neu eingeben.' }
        else { $m = 'Freigabe fehlgeschlagen: ' + $_.Exception.Message }
        Out-Log $m 'Fehler'; Show-Msg $m 'Release freigeben' 'Error'
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
    if ($a -eq 'Yes') { if (Save-GhToken $f 'GitHub-Token (Nur-Lese) als Kennwort eingeben (DPAPI, nur für deinen Benutzer lesbar)') { Out-Log 'GitHub-Token gespeichert' 'OK'; Invoke-UpdateCheck } }
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
    if (-not (Test-Path $p)) { Out-Log 'Noch keine Einstellungen gespeichert. Felder ausfüllen, dann "3. Speichern" oder "Stick fertig machen" klicken.' 'Hinweis' $p; return }
    if ($script:Dirty) {
        $q = [System.Windows.MessageBox]::Show($win, ('Es gibt ungespeicherte Änderungen.' + "`r`n`r`n" + 'Verwerfen und config.json neu laden?'), 'HUPilot - Neu laden', 'YesNo', 'Warning')
        if ($q -ne 'Yes') { Out-Log 'Neu laden abgebrochen, die Änderungen bleiben im Fenster.'; return }
    }
    $rc = Read-CfgFile $p
    if (-not $rc.Cfg) { Out-Log $rc.Error 'Fehler' $rc.Detail; return }
    $script:Loading = $true
    try {
        $c = $rc.Cfg
        $ui.tTenant.Text = [string]$c.Tenant; $ui.tTenantId.Text = [string]$c.TenantId; $ui.tClientId.Text = [string]$c.ClientId
        Set-Secret ([string]$c.ClientSecret); $ui.tTag.Text = [string]$c.GroupTag; $ui.tTagChoices.Text = (@($c.TagChoices) -join ', ')
        $ui.tSsid.Text = [string]$c.WlanSsid; Set-Masked 'Key' ([string]$c.WlanKey)
        $ui.tAdmName.Text = [string]$c.AdminName; Set-Masked 'AdmPw' ([string]$c.AdminPassword); $ui.cAskUser.IsChecked = ($c.AskUser -eq $true)
        $ui.tAdm2Name.Text = [string]$c.Admin2Name; Set-Masked 'Adm2Pw' ([string]$c.Admin2Password); $ui.cRmPkg.IsChecked = ($c.RemoveOtherPackages -eq $true)
        Set-EdKey ([string]$c.EditionKey)
        # Ablaufdatum des Secrets gilt nur fuer genau dieses Secret (bei geaendertem Secret: unbekannt).
        # Immer ins Vertragsformat bringen: PS 7 liefert aus ConvertFrom-Json ein DateTime, [string] davon waere ein anderes Format.
        $script:SecretExpLoaded = Format-UtcText (ConvertTo-UtcDate $c.SecretExpires); $script:SecretExpLoadedFor = Get-StrHash ([string]$c.ClientSecret).Trim()
        $script:Extra = @{}
        foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -notin 'Tenant','TenantId','ClientId','ClientSecret','GroupTag','TagChoices','WlanSsid','WlanKey','AdminName','AdminPassword','Admin2Name','Admin2Password','AskUser','RemoveOtherPackages','EditionKey','SecretExpires') { $script:Extra[$pr.Name] = $pr.Value } }
        Out-Log 'Einstellungen geladen (config.json)' 'OK' $p
    } catch { Out-Log 'Einstellungen konnten nicht übernommen werden. Felder prüfen, neu ausfüllen und speichern.' 'Fehler' ($p + ': ' + $_.Exception.GetType().Name) }
    finally { $script:Loading = $false }
    $script:SavedSnap = Get-CfgSnap
    Update-Dirty
})

# config.json lesen. Rueckgabe @{ Cfg; Error; Detail }. Bei kaputtem JSON nie die Meldung des Parsers weitergeben:
# Windows PowerShell 5.1 haengt dort den ganzen Dateiinhalt an (mit Secret und Kennwoertern).
function Read-CfgFile([string]$Path) {
    $raw = $null
    try { $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
    catch { return @{ Cfg = $null; Error = 'config.json konnte nicht geöffnet werden. Ist der Stick noch da oder die Datei in einem anderen Programm offen?'; Detail = ($Path + ': ' + $_.Exception.GetType().Name) } }
    try {
        $c = $raw | ConvertFrom-Json
        if ($null -eq $c -or $c -isnot [System.Management.Automation.PSCustomObject]) { throw 'kein Objekt' }
        return @{ Cfg = $c; Error = ''; Detail = '' }
    } catch {
        return @{ Cfg = $null; Error = 'config.json ist beschädigt (kein gültiges Format). Felder neu ausfüllen und "3. Speichern" klicken, das schreibt die Datei neu.'; Detail = $Path }
    }
}

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
# SHA256 mit Zwischenspeicher (gleicher Pfad, gleiche Groesse, gleiche Aenderungszeit = gleicher Wert)
$script:ShaCache = @{}
function Get-FileShaCached([string]$Path) {
    $fi = New-Object System.IO.FileInfo($Path)
    $k = $Path + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
    if ($null -eq $script:ShaCache) { $script:ShaCache = @{} }
    if ($script:ShaCache.ContainsKey($k)) { return $script:ShaCache[$k] }
    $h = Get-FileSha $Path
    $script:ShaCache = @{}; $script:ShaCache[$k] = $h
    return $h
}
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
        $tr = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://login.microsoftonline.com/' + $c.TenantId + '/oauth2/v2.0/token') -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
        # fuer Get-ApiTokenCached merken (5 Minuten Reserve vor dem Ablauf)
        $sec = 3600; try { $sec = [int]$tr.expires_in } catch { }
        $script:TokCache = @{ Token = [string]$tr.access_token; Until = (Get-Date).AddSeconds([math]::Max(0, $sec - 300)); For = (Get-StrHash ($c.TenantId + '|' + $c.ClientId + '|' + $c.ClientSecret)) }
        return $tr.access_token
    } catch {
        $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }
        $hasResp = $false; try { $hasResp = ($null -ne $_.Exception.Response) } catch { }
        $kind = Get-TokenErrorKind $m $hasResp
        $script:TokenErr = $kind
        $txt = 'Anmeldung bei Microsoft fehlgeschlagen. Später nochmal versuchen, Details im Protokoll.'
        if ($kind -eq 'expired') { $txt = 'Das Secret ist abgelaufen. In Entra bei der App-Registrierung ein neues Geheimnis anlegen und den Wert bei "Secret (Wert)" eintragen.' }
        elseif ($kind -eq 'wrong') { $txt = 'Das Secret ist falsch, oft ist die Geheimnis-ID statt des Werts kopiert. Den Wert bei "Secret (Wert)" eintragen.' }
        elseif ($kind -eq 'config') { $txt = 'Microsoft lehnt die Anmeldung ab. Tenant-ID und App-ID (Client) prüfen.' }
        elseif ($kind -eq 'net') { $txt = 'Keine Verbindung zu Microsoft. Internet prüfen. Das Secret wurde nicht geprüft.' }
        $script:TokenMsg = $txt
        Out-Log $txt $(if ($kind -eq 'net') { 'Hinweis' } else { 'Fehler' }) $m
        return $null
    }
}

# Token wiederverwenden, solange es gilt und Tenant, App und Secret gleich sind (Status-Aktualisierung alle 60 s)
$script:TokCache = $null
function Get-ApiTokenCached {
    $c = Get-Cfg
    $tc = $script:TokCache
    if ($tc -and $tc.Token -and (Get-Date) -lt $tc.Until -and $tc.For -eq (Get-StrHash ($c.TenantId + '|' + $c.ClientId + '|' + $c.ClientSecret))) { $script:TokenErr = ''; return $tc.Token }
    return (Get-ApiToken)
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
            # Die ersten Zeichen des Secrets (hint) nur im Fenster, nicht in der Protokolldatei
            $txt = 'Secret "' + $pc.displayName + '" (' + $pc.hint + '...) gültig bis ' + $end.ToString('dd.MM.yyyy HH:mm') + ', ' + (Format-Rest $span)
            $ftx = 'Secret "' + $pc.displayName + '" gültig bis ' + $end.ToString('dd.MM.yyyy HH:mm') + ', ' + (Format-Rest $span)
            if ($days -lt 0) { $sfx = '. Abgelaufen: in Entra ein neues Geheimnis anlegen und eintragen.'; Out-Log ($txt + $sfx) 'Fehler' '' ($ftx + $sfx) }
            elseif ($days -lt 3) { $sfx = '. Läuft bald ab: rechtzeitig ein neues Geheimnis anlegen.'; Out-Log ($txt + $sfx) 'Hinweis' '' ($ftx + $sfx) }
            else { Out-Log $txt 'OK' '' $ftx }
        }
        if (-not $mine.Count) { Out-Log 'Das verwendete Secret ist nicht eindeutig erkannt, deshalb stehen alle Secrets der App oben.' }
        if ($mine.Count -and $null -ne $minDays) {
            $script:SecretEnd = $minUtc; $script:SecretEndFor = Get-StrHash $c.ClientSecret
            Set-SubSecret ('Secret gültig bis ' + $minEnd.ToString('dd.MM.yyyy HH:mm') + ' (' + (Format-Rest ($minEnd - (Get-Date))) + ')') ($minDays -lt 1)
        }
    } catch {
        Out-Log 'Ablaufdatum des Secrets nicht lesbar. Optional: der App die Berechtigung Application.Read.All geben.' 'Hinweis' $_.Exception.Message
    }
}
function Set-SubSecret([string]$Text, [bool]$Warn) {
    $ui.tSub.Text = $Text
    $ui.tSub.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($Warn) { 'HuErr' } else { 'HuMuted' }))
}
# Autopilot lesen (Berechtigung DeviceManagementServiceConfig.ReadWrite.All). Rueckgabe: Fehlertext oder '' = ok
function Test-ApAccess([string]$Token) {
    try {
        $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?$top=1' -Headers @{ Authorization = 'Bearer ' + $Token } -TimeoutSec 30
        Out-Log 'Zugriff auf Autopilot OK' 'OK' ('' + @($r.value).Count + ' Eintrag gelesen')
        return ''
    } catch { Out-Log 'Kein Zugriff auf Autopilot. Der App fehlt die Berechtigung DeviceManagementServiceConfig.ReadWrite.All (mit Administratorzustimmung).' 'Fehler' $_.Exception.Message; return $_.Exception.Message }
}

$ui.bTest.Add_Click({
    Set-Step 'Test' 'run'; Step-Ui
    $tok = Get-ApiToken
    if (-not $tok) { Set-Step 'Test' $(if ($script:TokenErr -eq 'net') { 'warn' } else { 'err' }) $script:TokenMsg; return }
    Out-Log 'Anmeldung bei Microsoft OK' 'OK'
    $apErr = Test-ApAccess $tok
    Show-SecretExpiry -Token $tok
    if ($apErr) { Set-Step 'Test' 'err' 'kein Zugriff auf Autopilot' } else { Set-Step 'Test' 'ok' }
})

function Save-Cfg {
    if (-not (Test-Fields @('Tenant', 'TenantId', 'ClientId', 'ClientSecret', 'GroupTag', 'WlanSsid', 'WlanKey') -Admin)) { Set-Step 'Write' 'err' $script:FieldErr; return $false }
    try {
        $o = Get-Cfg
        $expUtc = ConvertTo-UtcDate (Get-SecretExpiresValue ([string]$o.ClientSecret))
        $o['SecretExpires'] = Format-UtcText $expUtc
        [System.IO.File]::WriteAllText($srcCfg, ($o | ConvertTo-Json -Depth 3), $enc)
        Out-Log ('Gespeichert' + $(if ($expUtc) { ' (Secret gültig bis ' + $expUtc.ToLocalTime().ToString('dd.MM.yyyy HH:mm') + ')' } else { '' })) 'OK' $srcCfg
        $script:SecretExpLoaded = [string]$o.SecretExpires; $script:SecretExpLoadedFor = Get-StrHash ([string]$o.ClientSecret)
        $script:SavedSnap = Get-CfgSnap
        Update-Dirty
        Set-Step 'Write' 'ok'
        return $true
    } catch { $script:FieldErr = 'Speichern fehlgeschlagen. Ist die Quelle schreibgeschützt oder der Stick voll?'; Out-Log $script:FieldErr 'Fehler' ($srcCfg + ': ' + $_.Exception.Message); Set-Step 'Write' 'err' $_.Exception.Message; return $false }
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
        if ([string]$fp.Package -ne (Get-FileShaCached $PkgPath)) { return 'veraltet' }
        return 'aktuell'
    } catch { return 'unbekannt' }
}
$script:PkgStateText = @{
    aus = @('Paket: nicht verwendet', 'HuMuted', 'open'); fremd = @('Paket: eigenes (nicht geprüft)', 'HuMuted', 'open')
    fehlt = @('Paket: fehlt', 'HuErr', 'err'); unbekannt = @('Paket: unbekannt', 'HuWarn', 'warn')
    veraltet = @('Paket: veraltet', 'HuWarn', 'warn'); aktuell = @('Paket: aktuell', 'HuOk', 'ok')
}
function Update-PkgState {
    $s = 'unbekannt'
    try { $s = Get-PkgState (Get-Cfg) $srcPkg $srcPkgFp } catch { }
    $t = $script:PkgStateText[$s]
    $ui.tPkg.Text = $t[0]
    try { $ui.tPkg.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $t[1]) } catch { }
    # Ist der letzte Bau gescheitert, bleibt die Ampel rot mit dem Grund, bis wieder gebaut wird
    if ($script:PkgBuildErr) { Set-Step 'Pkg' 'err' $script:PkgBuildErr } else { Set-Step 'Pkg' $t[2] }
    return $s
}
$script:PkgBuildErr = ''

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
    # WLAN-Paket, Katalog oder Pruefmerkmal am Stick, die es in der Quelle nicht gibt (z. B. von einem frueheren Kopieren)
    foreach ($x in @(Get-StaleStickPkg $dr)) { $bad += ('HUPilot\' + $x + ' liegt am Stick, gehört aber nicht zur Quelle') }
    $dc = Join-Path ($dr + '\') 'HUPilot\config.json'
    try {
        if (-not [System.IO.File]::Exists($dc)) { $bad += 'HUPilot\config.json fehlt' }
        elseif ((Get-FileSha $dc) -ne (Get-BytesSha $CfgBytes)) { $bad += 'HUPilot\config.json weicht ab' }
    } catch { $bad += ('HUPilot\config.json: ' + $_.Exception.Message) }
    return $bad
}
# Dateien HUPilot\HUPilot-WLAN.* am Stick, die in der Quelle fehlen (altes Paket, Katalog, Pruefmerkmal). Rueckgabe: Dateinamen
function Get-StaleStickPkg([string]$dr) {
    $d = Join-Path ($dr + '\') 'HUPilot'
    if (-not [System.IO.Directory]::Exists($d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -Filter 'HUPilot-WLAN.*' -File -Force -ErrorAction SilentlyContinue | Where-Object { -not [System.IO.File]::Exists((Join-Path $srcHU $_.Name)) } | ForEach-Object { $_.Name })
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
        # config.json zuerst und direkt in der Zielfassung: bei "ohne MAK" steht der MAK nie auf diesem Stick,
        # auch nicht kurz und auch nicht, wenn das Kopieren danach abbricht (eine alte config.json wird sofort ersetzt)
        $cfgBytes = $(if ($WithMak) { [System.IO.File]::ReadAllBytes($srcCfg) } else { Get-CfgBytesNoMak $srcCfg })
        [System.IO.File]::WriteAllBytes((Join-Path $dst 'config.json'), $cfgBytes)
        if (-not $WithMak) { Out-Log ('Stick ' + $dr + ': ohne MAK') }
        foreach ($it in @(Get-ChildItem -Path $srcHU -Force | Where-Object { $_.Name -ne 'logs' -and $_.Name -ne 'config.json' -and -not $_.Name.StartsWith('_') })) {
            Copy-Item -Path $it.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
        }
        # persoenliche/zwischenzeitliche Dateien nicht auf den Stick (GitHub-Token, Update-Journal, Update-Reste)
        foreach ($x in @(Get-ChildItem -Path $dst -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'GitHubToken_*.xml' -or $_.Name -eq 'pull-journal.json' -or $_.Name -match '\.(pullold|pulltmp)$' })) { Remove-Item -LiteralPath $x.FullName -Force -ErrorAction SilentlyContinue }
        # Altes WLAN-Paket, Katalog oder Pruefmerkmal, die nicht aus der Quelle stammen, entfernen (sonst nimmt go ein falsches Paket)
        foreach ($x in @(Get-StaleStickPkg $dr)) {
            try { Remove-Item -LiteralPath (Join-Path $dst $x) -Force -ErrorAction Stop; Out-Log ('Stick ' + $dr + ': altes ' + $x + ' entfernt, es gehörte nicht zur Quelle') 'Hinweis' }
            catch { Out-Log ('Stick ' + $dr + ': altes ' + $x + ' konnte nicht entfernt werden. Bitte von Hand löschen.') 'Fehler' $_.Exception.Message }
        }
        Out-Log ('Auf Stick ' + $dr + ' kopiert') '' ($srcStick + ' nach ' + $dr + '\, ohne logs und Ordner mit _')
        $rootPkg = @(Get-ChildItem -Path ($dr + '\') -Filter *.ppkg -File -ErrorAction SilentlyContinue)
        if ($rootPkg.Count) { Out-Log ('Auf Stick ' + $dr + ' liegt ein Paket direkt im Hauptordner (' + (($rootPkg | ForEach-Object { $_.Name }) -join ', ') + '). Bitte löschen, Windows würde es sonst im Einrichtungsbildschirm anwenden.') 'Hinweis' }
        # Schreibcache leeren, dann kontrollieren
        try { Write-VolumeCache -DriveLetter $dr.Substring(0, 1) -ErrorAction Stop } catch { }
        $bad = @(Test-StickCopy $dr $cfgBytes ([string](Get-Cfg).WlanPackage))
        if ($bad.Count) { $script:CopyErr = 'Kontrolle nicht bestanden: ' + ($bad -join ', '); Out-Log ('Stick ' + $dr + ': ' + $script:CopyErr + '. Stick neu anstecken und nochmal kopieren.') 'Fehler'; return $false }
        Out-Log ('Stick ' + $dr + ' kontrolliert: alle Dateien stimmen mit der Quelle überein') 'OK' ('SHA256: go.cmd, go.ps1, config.json' + $(if ((Get-Cfg).WlanPackage -and (Test-Path $srcPkg)) { ', WLAN-Paket' } else { '' }))
        return $true
    } catch { $script:CopyErr = $_.Exception.Message; Out-Log ('Kopieren auf ' + $dr + ' fehlgeschlagen. Stick neu anstecken, "Aktualisieren" klicken und nochmal versuchen.') 'Fehler' $_.Exception.Message; return $false }
}

# Vor dem Kopieren: WLAN-Paket fehlt oder veraltet -> nicht still kopieren. Rueckgabe $false = abbrechen
function Confirm-PkgForCopy($Owner) {
    $st = Update-PkgState
    if ($st -in 'aktuell', 'aus', 'fremd') { return $true }
    $hasIcd = Test-Path $icd
    if ($st -eq 'fehlt') {
        Out-Log 'In der Quelle gibt es noch kein WLAN-Paket. Erst "4. WLAN-Paket bauen".' 'Hinweis'
        if ($hasIcd) {
            $q = [System.Windows.MessageBox]::Show($Owner, ('In der Quelle gibt es noch kein WLAN-Paket.' + "`r`n`r`n" + 'Ja = jetzt bauen und dann kopieren' + "`r`n" + 'Nein = ohne WLAN-Paket kopieren (ein altes WLAN-Paket auf dem Stick wird dabei entfernt)' + "`r`n" + 'Abbrechen = nichts kopieren'), 'HUPilot - WLAN-Paket fehlt', 'YesNoCancel', 'Warning')
            if ($q -eq 'Yes') { return (Build-Package -NoSave) }
            return ($q -eq 'No')
        }
        $q = [System.Windows.MessageBox]::Show($Owner, ('In der Quelle gibt es noch kein WLAN-Paket, und ICD.exe (Windows ADK) fehlt auf diesem PC.' + "`r`n`r`n" + 'Trotzdem ohne WLAN-Paket kopieren? Ein altes WLAN-Paket auf dem Stick wird dabei entfernt.'), 'HUPilot - WLAN-Paket fehlt', 'YesNo', 'Warning')
        return ($q -eq 'Yes')
    }
    $why = $(if ($st -eq 'veraltet') { 'WLAN oder lokale Admins wurden seit dem Bau des WLAN-Pakets geändert - das Paket ist veraltet.' } else { 'Ob das WLAN-Paket zu WLAN und lokalen Admins passt, ist unbekannt (gebaut mit einer älteren Version).' })
    Out-Log $why 'Hinweis'
    if ($hasIcd) {
        $q = [System.Windows.MessageBox]::Show($Owner, ($why + "`r`n`r`n" + 'Ja = Paket jetzt neu bauen und dann kopieren' + "`r`n" + 'Nein = altes Paket trotzdem kopieren' + "`r`n" + 'Abbrechen = nichts kopieren'), 'HUPilot - WLAN-Paket', 'YesNoCancel', 'Warning')
        if ($q -eq 'Yes') { return (Build-Package -NoSave) }
        if ($q -eq 'No') { Out-Log 'Altes WLAN-Paket wird trotzdem kopiert.' 'Hinweis'; return $true }
        return $false
    }
    $q = [System.Windows.MessageBox]::Show($Owner, ($why + "`r`n`r`n" + 'ICD.exe (Windows ADK) fehlt auf diesem PC, neu bauen geht hier nicht.' + "`r`n" + 'Altes Paket trotzdem kopieren?'), 'HUPilot - WLAN-Paket', 'YesNo', 'Warning')
    if ($q -eq 'Yes') { Out-Log 'Altes WLAN-Paket wird trotzdem kopiert.' 'Hinweis'; return $true }
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
        if ($q -ne 'Yes') { Out-Log 'Kopieren abgebrochen, das Secret ist abgelaufen.'; return $null }
        Out-Log 'Secret abgelaufen, trotzdem kopiert. Mit diesem Stick lädt go.ps1 keine Geräte hoch.' 'Hinweis'
    } elseif ($lvl -eq 'soon') {
        $t = 'Das Secret läuft am ' + $end.ToLocalTime().ToString('dd.MM.yyyy HH:mm') + ' ab (' + (Format-Rest ($end.ToLocalTime() - (Get-Date))) + '). Danach lädt dieser Stick keine Geräte mehr hoch - rechtzeitig erneuern.'
        Out-Log $t 'Hinweis'
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
    if ($script:Busy) { return }
    Set-UiBusy $true
    try {
        $dr = Get-ReadyDrive; if (-not $dr) { Out-Log 'Kein Ziel-Stick gewählt. Stick anstecken, "Aktualisieren" klicken und bei "Stick" auswählen.' 'Fehler'; Set-Step 'Copy' 'err' 'kein Ziel-Stick'; return }
        if (-not (Save-Cfg)) { Set-Step 'Copy' 'err' 'nicht gespeichert'; return }
        if (-not (Confirm-PkgForCopy $win)) { Out-Log 'Kopieren abgebrochen.'; Set-Step 'Copy' 'open'; return }
        $pre = Confirm-CopyPrereqs ('Stick ' + $dr) $win
        if (-not $pre) { Set-Step 'Copy' 'open'; return }
        Set-Step 'Copy' 'run'; Step-Ui
        if (Copy-ToStick $dr $pre.WithMak) { Set-Step 'Copy' 'ok' ('Stick ' + $dr) } else { Set-Step 'Copy' 'err' $script:CopyErr }
    } finally { Set-UiBusy $false }
})

# ICD-Ausgabe fuer Protokoll und Datei: Kennwoerter (roh und XML-escapt) und den Base64-Block der -EncodedCommand-Zeile ausblenden
function Hide-IcdText([string]$Line, $c, [string]$B64 = '') {
    $vals = @()
    foreach ($s in @($c.WlanKey, $c.AdminPassword, $c.Admin2Password)) { if ($s) { $vals += [string]$s; $vals += [System.Security.SecurityElement]::Escape([string]$s) } }
    if ($B64) { $vals += $B64 }
    foreach ($v in @($vals | Where-Object { $_ } | Sort-Object Length -Descending)) { $Line = $Line.Replace($v, '***') }
    $Line = [regex]::Replace($Line, '(?i)(-EncodedCommand\s+)[A-Za-z0-9+/=]{16,}', '$1***')
    return $Line.Trim()
}
# ---------- 4. WLAN-Paket bauen (speichert vorher, schreibt den Fingerabdruck) ----------
function Build-Package([switch]$NoSave) {
    $script:PkgBuildErr = ''
    Set-UiBusy $true
    try {
        $ok = [bool](Build-PackageCore -NoSave:$NoSave)
        if (-not $ok) { $n = [string]$script:LampNote['Pkg']; $script:PkgBuildErr = $(if ($n) { $n } else { 'nicht gebaut' }); Set-Step 'Pkg' 'err' $script:PkgBuildErr }
        return $ok
    } finally { Set-UiBusy $false }
}
function Build-PackageCore([switch]$NoSave) {
    if (-not $NoSave) { if (-not (Save-Cfg)) { Set-Step 'Pkg' 'err' 'nicht gespeichert'; return $false } }
    if (-not (Test-Fields @('WlanSsid', 'WlanKey') -Admin)) { Set-Step 'Pkg' 'err' $script:FieldErr; return $false }
    if (-not (Test-Path $icd)) { Out-Log 'WLAN-Paket kann hier nicht gebaut werden: ICD.exe fehlt. Windows ADK mit "Imaging and Configuration Designer" installieren (die Store-App reicht nicht) oder ohne ADK Tools\New-WcdProjekt.ps1 laut INSTALL.md nehmen.' 'Fehler' $icd; Set-Step 'Pkg' 'err' 'ICD.exe fehlt'; return $false }
    Set-Step 'Pkg' 'run'; Step-Ui
    $c = Get-Cfg
    $okBuild = $false
    $b64 = ''
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
            if (-not (Test-Path $dstore)) { Out-Log 'Das Windows ADK ist unvollständig. "Imaging and Configuration Designer" vollständig installieren.' 'Fehler' ($dstore + ' fehlt'); Set-Step 'Pkg' 'err' 'ADK unvollständig'; return $false }
            $stores = @(($cstore + ',' + $dstore), $dstore)
        }
        foreach ($store in $stores) {
            $icdArgs = @('/Build-ProvisioningPackage', ('/CustomizationXML:"' + $xmlPath + '"'), ('/PackagePath:"' + $ppkg + '"'), ('/StoreFile:"' + $store + '"'), '+Overwrite')
            Out-Log ('ICD.exe baut das Paket (' + ((@($store -split ',') | ForEach-Object { (Split-Path $_ -Leaf) -replace '-Provisioning\.dat$', '' }) -join ' + ') + ') ...')
            $outF = Join-Path $work 'icd-out.txt'; $errF = Join-Path $work 'icd-err.txt'
            $p = Start-Process -FilePath $icd -ArgumentList $icdArgs -Wait -PassThru -NoNewWindow -WorkingDirectory $work -RedirectStandardOutput $outF -RedirectStandardError $errF
            if ($p.ExitCode -eq 0 -and (Test-Path $ppkg)) { Out-Log 'WLAN-Paket gebaut' 'OK' ($ppkg + ' (' + (Get-Item $ppkg).Length + ' Bytes)'); $okBuild = $true; break }
            $lines = @()
            foreach ($f in @($outF, $errF)) { if (Test-Path $f) { $lines += @(Get-Content -Path $f -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) } }
            $det = @($lines | Select-Object -Last 30 | ForEach-Object { Hide-IcdText ([string]$_) $c $b64 }) -join ' | '
            if (-not $det) { $det = 'ICD.exe hat keine Ausgabe geliefert' }
            Out-Log ('ICD.exe konnte das Paket so nicht bauen (Exitcode ' + $p.ExitCode + ').' + $(if ($stores.Count -gt 1 -and $store -ne $stores[-1]) { ' Zweiter Versuch folgt.' } else { '' })) 'Hinweis' $det
        }
        if ($okBuild) {
            try { Write-PkgFingerprint $c $srcPkg $srcPkgFp } catch { Out-Log 'Prüfmerkmal des Pakets konnte nicht gespeichert werden, der Stand wird als unbekannt angezeigt.' 'Hinweis' $_.Exception.Message }
        } else { Out-Log 'WLAN-Paket wurde nicht gebaut, das bisherige Paket bleibt unverändert. Details stehen in den Zeilen davor.' 'Fehler' }
    } catch { Out-Log 'Paketbau abgebrochen. Das bisherige Paket bleibt unverändert.' 'Fehler' $_.Exception.Message; $okBuild = $false }
    finally { Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue }   # enthaelt das WLAN-Kennwort
    [void](Update-PkgState)
    if (-not $okBuild) { Set-Step 'Pkg' 'err' 'nicht gebaut' }
    return $okBuild
}
$ui.bPkg.Add_Click({ if (-not $script:Busy) { [void](Build-Package) } })

# protokoll.csv von Quelle und Ziel-Stick: je Seriennummer die neueste Zeile ($map) und alle Zeilen ($script:ProtoAll, fuer Details)
function Read-Protokoll {
    $map = @{}
    $script:ProtoAll = @{}
    $files = @(Join-Path $srcHU 'logs\protokoll.csv')
    $dr = Get-ReadyDrive; if ($dr) { $files += ($dr + '\HUPilot\logs\protokoll.csv') }
    foreach ($f in $files) {
        try {
            if (-not [System.IO.File]::Exists($f)) { continue }
            foreach ($row in @([System.IO.File]::ReadAllLines($f) | ConvertFrom-Csv -Delimiter ';')) {
                if (-not $row.Seriennr) { continue }
                if (-not $script:ProtoAll.ContainsKey($row.Seriennr)) { $script:ProtoAll[$row.Seriennr] = New-Object System.Collections.ArrayList }
                [void]$script:ProtoAll[$row.Seriennr].Add([pscustomobject]@{ Zeit = [string]$row.Zeit; Ergebnis = [string]$row.Ergebnis; Tag = [string]$row.Tag; Datei = $f })
                if (-not $map.ContainsKey($row.Seriennr) -or [string]$row.Zeit -gt [string]$map[$row.Seriennr].Zeit) { $map[$row.Seriennr] = $row }
            }
        } catch { Out-Log 'Ein Stick-Protokoll (protokoll.csv) konnte nicht gelesen werden.' 'Hinweis' ($f + ': ' + $_.Exception.Message) }
    }
    return $map
}

# ---------- Status: Stand und naechster Schritt in Klartext (aus Profilstatus und Intune-Status) ----------
#   ProfileStatus = deploymentProfileAssignmentStatus, EnrollState = enrollmentState (Graph, Autopilot-Geraet)
function Get-DeviceStand([string]$ProfileStatus, [string]$EnrollState, [bool]$HasAssignedDate) {
    if ($EnrollState -eq 'enrolled') { return 'Fertig' }
    if ($EnrollState -in 'failed', 'blocked' -or $ProfileStatus -eq 'failed') { return 'Fehler' }
    if ($ProfileStatus -eq 'notAssigned') { return 'Kein Profil für diesen Tag' }
    if ($ProfileStatus -in 'assignedInSync', 'assignedUnkownSyncState', 'assignedUnknownSyncState', 'assignedOutOfSync' -and $HasAssignedDate) { return 'Profil da, Gerät noch nicht angemeldet' }
    return 'Wartet auf Profil'
}
function Get-DeviceTodo([string]$Stand, [string]$ProfileStatus, [string]$EnrollState) {
    switch ($Stand) {
        'Fertig' { return 'Nichts, das Gerät ist fertig.' }
        'Wartet auf Profil' { if ($ProfileStatus -eq 'assignedOutOfSync') { return 'Autopilot-Sync anstoßen und ein paar Minuten warten.' } return 'Nichts, läuft. Das Profil kommt meist in 5 bis 15 Minuten.' }
        'Profil da, Gerät noch nicht angemeldet' { return 'Gerät einschalten, mit dem WLAN verbinden und neu starten, dann meldet es sich an.' }
        'Kein Profil für diesen Tag' { return 'Tag prüfen: kein Profil zugewiesen ("2. Tags prüfen"), oder mit "Tag ändern" einen Tag mit Profil wählen.' }
        'Fehler' { if ($EnrollState -eq 'blocked') { return 'Gerät ist in Intune blockiert. Admin fragen.' } return 'Gerät in Intune prüfen, dann mit dem Stick neu zurücksetzen.' }
    }
    return ''
}
# Farbe und Kachel je Stand: ok (gruen) / warn (gelb) / err (rot)
$script:StandClass = @{ 'Fertig' = 'ok'; 'Wartet auf Profil' = 'warn'; 'Profil da, Gerät noch nicht angemeldet' = 'warn'; 'Kein Profil für diesen Tag' = 'err'; 'Fehler' = 'err' }
$script:StandTile = @{ 'Fertig' = 'ok'; 'Wartet auf Profil' = 'wait'; 'Profil da, Gerät noch nicht angemeldet' = 'ready'; 'Kein Profil für diesen Tag' = 'prob'; 'Fehler' = 'prob' }

# Spalten der Status-Tabelle (Reihenfolge wie im Fenster), gilt fuer Fenster, CSV, Excel und Druck
$script:StatusCols = @(
    @{ Key = 'Stand'; Header = 'Stand' }, @{ Key = 'WasTun'; Header = 'Was tun' }, @{ Key = 'Seriennr'; Header = 'Seriennummer' }, @{ Key = 'Tag'; Header = 'Tag' },
    @{ Key = 'Name'; Header = 'Gerätename' }, @{ Key = 'Benutzer'; Header = 'Benutzer' }, @{ Key = 'RegDatum'; Header = 'Registriert'; Sort = 'RegSort' },
    @{ Key = 'LetzterKontakt'; Header = 'Letzter Kontakt'; Sort = 'KontaktSort' }, @{ Key = 'LetzterSync'; Header = 'Letzter Sync'; Sort = 'SyncSort' }, @{ Key = 'Modell'; Header = 'Modell' },
    @{ Key = 'Profil'; Header = 'Profil' }, @{ Key = 'Intune'; Header = 'Intune' }, @{ Key = 'HUPilot'; Header = 'Stick-Protokoll'; Sort = 'HUPilotSort' }
)

# Excel-Datei (.xlsx) direkt schreiben, ohne installiertes Excel: Kopfzeile fett, fixiert, mit Filter,
# Spaltenbreite nach Inhalt, Datumsspalten als echtes Datum, Spalte Stand eingefaerbt wie im Fenster
function Export-StatusXlsx {
    param($Rows, [string[]]$Cols, [string[]]$Headers, [string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not $Headers -or $Headers.Count -ne $Cols.Count) { $Headers = $Cols }
    $esc = { param($s) [System.Security.SecurityElement]::Escape(([string]$s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')) }
    $colName = { param([int]$i) $n = ''; $i++; while ($i -gt 0) { $m = ($i - 1) % 26; $n = [char](65 + $m) + $n; $i = [int][math]::Floor(($i - 1) / 26) }; $n }
    $dateCols = @('RegDatum', 'LetzterKontakt', 'LetzterSync')
    $fmts = [string[]]@('dd.MM.yyyy HH:mm', 'yyyy-MM-dd HH:mm')
    $de = [Globalization.CultureInfo]::InvariantCulture
    $standStyle = @{ ok = 3; warn = 4; err = 5 }
    $Rows = @($Rows)
    $width = @{}; for ($i = 0; $i -lt $Cols.Count; $i++) { $width[$Cols[$i]] = $Headers[$i].Length + 4 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<row r="1">')
    for ($i = 0; $i -lt $Cols.Count; $i++) { [void]$sb.Append('<c r="' + (& $colName $i) + '1" s="1" t="inlineStr"><is><t>' + (& $esc $Headers[$i]) + '</t></is></c>') }
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
            if ($c -eq 'Stand' -and $script:StandClass.ContainsKey($v)) { $s = $standStyle[$script:StandClass[$v]] }
            [void]$sb.Append('<c r="' + $ref + '"' + $(if ($s) { ' s="' + $s + '"' } else { '' }) + ' t="inlineStr"><is><t xml:space="preserve">' + (& $esc $v) + '</t></is></c>')
        }
        [void]$sb.Append('</row>')
    }
    $last = (& $colName ($Cols.Count - 1))
    $colsXml = ''
    for ($i = 0; $i -lt $Cols.Count; $i++) {
        $w = [math]::Min(70, [math]::Max($width[$Cols[$i]], $(if ($dateCols -contains $Cols[$i]) { 18 } else { 6 })))
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
        '<fills count="6"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFDFF2E1"/><bgColor indexed="64"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFFFF4CE"/><bgColor indexed="64"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFF8D7DA"/><bgColor indexed="64"/></patternFill></fill></fills>' +
        '<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FF808080"/></bottom><diagonal/></border></borders>' +
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="5" borderId="0" xfId="0" applyFill="1"/></cellXfs>' +
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
# Spalte Stand eingefaerbt wie im Fenster. Passt die Tabelle nicht in die Breite, werden die Spalten anteilig verkleinert.
function New-StatusPrintDoc {
    param($Rows, [string[]]$Cols, [string[]]$Headers, [string]$Title, [string]$Sub, [double]$PageW, [double]$PageH)
    if (-not $Headers -or $Headers.Count -ne $Cols.Count) { $Headers = $Cols }
    $brush = { param($hex) $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)); $b.Freeze(); $b }
    $bHead = & $brush '#D9E1F2'; $bAlt = & $brush '#F3F3F3'; $bLine = & $brush '#C8C8C8'
    $bStand = @{ ok = (& $brush '#DFF2E1'); warn = (& $brush '#FFF4CE'); err = (& $brush '#F8D7DA') }
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
    $Rows = @($Rows)
    $tfN = New-Object System.Windows.Media.Typeface($font, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
    $tfB = New-Object System.Windows.Media.Typeface($font, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Bold, [System.Windows.FontStretches]::Normal)
    $ci = [Globalization.CultureInfo]::CurrentCulture
    $measure = { param($t, $tf) (New-Object System.Windows.Media.FormattedText([string]$t, $ci, [System.Windows.FlowDirection]::LeftToRight, $tf, $size, [System.Windows.Media.Brushes]::Black)).WidthIncludingTrailingWhitespace }
    $cellPad = 10.0
    $wid = @()
    for ($ix = 0; $ix -lt $Cols.Count; $ix++) {
        $c = $Cols[$ix]
        $m = & $measure $Headers[$ix] $tfB
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
        foreach ($hd in $Headers) { $hr.Cells.Add((& $mkCell $hd $true $bHead 1.0)) }
        $rg.Rows.Add($hr)
        $end = [math]::Min($Rows.Count, $i + $n)
        for (; $i -lt $end; $i++) {
            $r = $Rows[$i]
            $tr = New-Object System.Windows.Documents.TableRow
            if ($i % 2 -eq 1) { $tr.Background = $bAlt }
            foreach ($c in $Cols) {
                $v = [string]$r.$c; $bg = $null
                if ($c -eq 'Stand' -and $script:StandClass.ContainsKey($v)) { $bg = $bStand[$script:StandClass[$v]] }
                $tr.Cells.Add((& $mkCell $v $false $bg 0.5))
            }
            $rg.Rows.Add($tr)
        }
        $tbl.RowGroups.Add($rg)
        $sec = New-Object System.Windows.Documents.Section
        if (-not $first) { $sec.BreakPageBefore = $true }
        $sec.Blocks.Add($tbl)
        $doc.Blocks.Add($sec)
        $first = $false
    } while ($i -lt $Rows.Count)
    return $doc
}

# Details eines Geraets als eigenes Fenster: Felder in Klartext, Verlauf aus protokoll.csv, Kopieren, Schliessen
function Show-DeviceDetail($Row, $Owner) {
    [xml]$dx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot - Gerät" Width="720" Height="560" WindowStartupLocation="CenterOwner" FontSize="12" ResizeMode="CanResizeWithGrip" ShowInTaskbar="False">
  <DockPanel Margin="10">
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="bCopy" Content="Kopieren" Padding="10,4" ToolTip="Alle Angaben in die Zwischenablage kopieren (z. B. für eine E-Mail an den Admin)."/>
      <Button x:Name="bClose" Content="Schließen" Padding="10,4" Margin="8,0,0,0" IsCancel="True" ToolTip="Fenster schließen (Esc)."/>
    </StackPanel>
    <TextBox x:Name="tDet" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" ToolTip="Angaben zum Gerät aus Autopilot, Intune und dem Stick-Protokoll. Text lässt sich markieren und kopieren."/>
  </DockPanel>
</Window>
'@
    Add-HuTheme $dx
    $dw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    Register-HuWindow $dw
    $dw.Owner = $Owner; if ($win.Icon) { $dw.Icon = $win.Icon }
    Set-WinFit $dw
    $dw.Title = 'HUPilot - Gerät ' + $Row.Seriennr
    # Profil live nachladen (optional)
    $prof = ''; $profAt = ''
    $id = $script:ApIds[[string]$Row.Seriennr]
    if ($id) {
        $tok = Get-ApiToken
        if ($tok) {
            try {
                $d = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri ('https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/' + $id + '?$expand=deploymentProfile') -Headers @{ Authorization = 'Bearer ' + $tok } -TimeoutSec 30
                if ($d.deploymentProfile) { $prof = [string]$d.deploymentProfile.displayName }
                try { $t = [datetime]$d.deploymentProfileAssignedDateTime; if ($t.Year -gt 2000) { $profAt = $t.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } } catch { }
            } catch { Out-Log ('Profil von ' + $Row.Seriennr + ' nicht nachladbar, die Angaben stammen aus der Liste.') 'Hinweis' $_.Exception.Message }
        }
    }
    $nl = "`r`n"
    $lines = @(
        ('Seriennummer:      ' + $Row.Seriennr),
        ('Stand:             ' + $Row.Stand),
        ('Was tun:           ' + $Row.WasTun),
        '',
        ('Tag:               ' + $Row.Tag),
        ('Autopilot-Profil:  ' + $(if ($prof) { $prof } else { '-' }) + $(if ($profAt) { ' (zugewiesen am ' + $profAt + ')' } else { '' })),
        ('Profilstatus:      ' + $Row.Profil),
        ('Intune:            ' + $Row.Intune),
        ('Registriert:       ' + $(if ($Row.RegDatum) { $Row.RegDatum } else { '-' })),
        ('Letzter Kontakt:   ' + $(if ($Row.LetzterKontakt) { $Row.LetzterKontakt } else { '-' })),
        ('Letzter Sync:      ' + $(if ($Row.LetzterSync) { $Row.LetzterSync } else { '-' })),
        ('Benutzer:          ' + $(if ($Row.Benutzer) { $Row.Benutzer } else { '-' })),
        ('Gerätename:        ' + $(if ($Row.Name) { $Row.Name } else { '-' })),
        ('Modell:            ' + $Row.Modell),
        '',
        'Verlauf am Stick (protokoll.csv):'
    )
    $hist = @()
    if ($script:ProtoAll -and $script:ProtoAll.ContainsKey([string]$Row.Seriennr)) { $hist = @($script:ProtoAll[[string]$Row.Seriennr] | Sort-Object Zeit) }
    if ($hist.Count) { foreach ($h in $hist) { $lines += ('  ' + $h.Zeit + '   ' + $h.Ergebnis + $(if ($h.Tag) { '   (Tag ' + $h.Tag + ')' } else { '' })) } }
    else { $lines += '  keine Einträge (Gerät wurde nicht mit diesem Stick bearbeitet oder das Protokoll ist nicht da)' }
    $txt = $lines -join $nl
    $c = @{ tDet = $dw.FindName('tDet'); bCopy = $dw.FindName('bCopy'); bClose = $dw.FindName('bClose') }
    $c.tDet.Text = $txt
    $c.bCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText($c.tDet.Text); $c.bCopy.Content = 'Kopiert' } catch { $c.bCopy.Content = 'Kopieren fehlgeschlagen' } })
    $c.bClose.Add_Click({ $dw.Close() })
    [void]$dw.ShowDialog()
}

function Show-Status {
    [xml]$sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUPilot - Status" Width="1280" Height="720" WindowStartupLocation="CenterOwner" FontSize="12" ResizeMode="CanResizeWithGrip">
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
    <Style x:Key="HuTile" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource HuPanel}"/><Setter Property="Foreground" Value="{DynamicResource HuText}"/><Setter Property="BorderBrush" Value="{DynamicResource HuBorder}"/>
      <Setter Property="BorderThickness" Value="2"/><Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="0,0,8,6"/><Setter Property="MinWidth" Value="150"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Left"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <DockPanel Margin="10">
    <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,6">
      <Button x:Name="kAll" Style="{StaticResource HuTile}" Tag="" ToolTip="Alle Geräte (mit den Filtern unten). Klick hebt den Kachel-Filter auf."><StackPanel><TextBlock x:Name="nAll" Text="-" FontSize="22" FontWeight="Bold"/><TextBlock Text="Geräte gesamt"/></StackPanel></Button>
      <Button x:Name="kOk" Style="{StaticResource HuTile}" Tag="ok" ToolTip="Fertig: in Intune angemeldet. Klick zeigt nur diese, zweiter Klick wieder alle."><StackPanel><TextBlock x:Name="nOk" Text="-" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource HuOk}"/><TextBlock Text="Fertig"/></StackPanel></Button>
      <Button x:Name="kWait" Style="{StaticResource HuTile}" Tag="wait" ToolTip="Hochgeladen, Microsoft weist das Profil noch zu (meist 5 bis 15 Minuten). Klick filtert."><StackPanel><TextBlock x:Name="nWait" Text="-" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource HuWarn}"/><TextBlock Text="Wartet auf Profil"/></StackPanel></Button>
      <Button x:Name="kReady" Style="{StaticResource HuTile}" Tag="ready" ToolTip="Profil ist da, das Gerät hat sich aber noch nicht angemeldet. Klick filtert."><StackPanel><TextBlock x:Name="nReady" Text="-" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource HuWarn}"/><TextBlock Text="Profil da, noch nicht angemeldet"/></StackPanel></Button>
      <Button x:Name="kProb" Style="{StaticResource HuTile}" Tag="prob" ToolTip="Kein Profil für den Tag oder Fehler in Intune - hier ist etwas zu tun. Klick filtert."><StackPanel><TextBlock x:Name="nProb" Text="-" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource HuErr}"/><TextBlock Text="Problem"/></StackPanel></Button>
    </WrapPanel>
    <WrapPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock Text="Tag:" VerticalAlignment="Center" Margin="0,0,6,4"/>
      <ComboBox x:Name="cTag" Width="140" Margin="0,0,0,4" ToolTip="Nur Geräte mit diesem Group Tag"/>
      <CheckBox x:Name="cProto" Content="nur Geräte aus dem Stick-Protokoll" VerticalAlignment="Center" Margin="14,0,0,4" ToolTip="Nur Geräte, die mit dem Stick bearbeitet wurden (protokoll.csv von Quelle und Ziel-Stick)"/>
      <CheckBox x:Name="cToday" Content="heute" VerticalAlignment="Center" Margin="14,0,0,4" ToolTip="Nur Geräte, die heute hochgeladen oder registriert wurden"/>
      <CheckBox x:Name="cProblem" Content="nur Probleme" VerticalAlignment="Center" Margin="14,0,0,4" ToolTip="Nur Geräte mit Stand &quot;Kein Profil für diesen Tag&quot; oder &quot;Fehler&quot;"/>
      <CheckBox x:Name="cZeit" Content="nur letzte" VerticalAlignment="Center" Margin="14,0,0,4" ToolTip="Zeitfilter: nur Geräte, die im gewählten Zeitraum registriert bzw. importiert wurden"/>
      <ComboBox x:Name="cZeitSpan" Width="70" Margin="6,0,0,4" ToolTip="Zeitraum bis jetzt"/>
      <ComboBox x:Name="cZeitBasis" Width="170" Margin="6,0,0,4" ToolTip="Registrierung = Zeit der Intune-Registrierung (Spalte Registriert).&#x0a;Autopilot-Import = Zeit aus protokoll.csv (Hochladen per Stick);&#x0a;fehlt sie, gilt die Zeit der Profil-Zuweisung (meist wenige Minuten nach dem Import).&#x0a;Microsoft liefert keine eigene Importzeit."/>
      <TextBox x:Name="tFind" Width="160" Margin="14,0,0,4" VerticalAlignment="Center" ToolTip="Suche in Seriennummer, Gerätename und Benutzer"/>
    </WrapPanel>
    <Grid DockPanel.Dock="Top" Margin="0,0,4,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <DockPanel Grid.Column="0" VerticalAlignment="Center">
        <Ellipse x:Name="ePulse" DockPanel.Dock="Left" Width="10" Height="10" Fill="{DynamicResource HuOk}" Margin="0,0,6,0" VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Daten werden geladen"/>
        <TextBlock x:Name="tLoad" VerticalAlignment="Center" TextWrapping="Wrap" Foreground="{DynamicResource HuMuted}" ToolTip="Fortschritt beim Laden"/>
      </DockPanel>
      <StackPanel x:Name="spTopR" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="tStamp" VerticalAlignment="Center" Margin="12,0,16,0" Foreground="{DynamicResource HuMuted}" ToolTip="Zeitpunkt der letzten erfolgreichen Abfrage"/>
        <CheckBox x:Name="cAuto" Content="alle 60 s aktualisieren" VerticalAlignment="Center" Margin="0,0,12,0" ToolTip="Liste jede Minute neu laden (nicht, während ein Dialog offen ist). Auswahl, Sortierung und Filter bleiben."/>
        <Button x:Name="bReload" Content="Aktualisieren" Padding="10,2" ToolTip="Alle Daten jetzt neu aus Autopilot und Intune laden"/>
      </StackPanel>
    </Grid>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <StackPanel x:Name="spBotR" DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="bCsv" Content="CSV speichern" Padding="10,4" ToolTip="Angezeigte Zeilen als CSV (Strichpunkt getrennt) speichern, mit denselben Spalten wie im Fenster"/>
        <Button x:Name="bXlsx" Content="Excel speichern" Padding="10,4" Margin="8,0,0,0" ToolTip="Angezeigte Zeilen als Excel-Datei (.xlsx) speichern:&#x0a;Kopfzeile fixiert mit Filter, Datum als echtes Datum, Stand eingefärbt.&#x0a;Excel muss dafür nicht installiert sein."/>
        <Button x:Name="bPrint" Content="Drucken" Padding="10,4" Margin="8,0,0,0" ToolTip="Angezeigte Zeilen drucken (Querformat, auch als PDF über Microsoft Print to PDF)"/>
        <Button x:Name="bClose" Content="Schließen" Padding="10,4" Margin="8,0,0,0" ToolTip="Fenster schließen"/>
      </StackPanel>
      <StackPanel x:Name="spBotL" Orientation="Horizontal">
        <Button x:Name="bDetail" Content="Details ..." Padding="10,4" ToolTip="Angaben zur markierten Zeile mit Verlauf aus dem Stick-Protokoll (auch Doppelklick auf die Zeile)"/>
        <Button x:Name="bTagSet" Content="Tag ändern ..." Padding="10,4" Margin="8,0,0,0" ToolTip="Den markierten Geräten einen anderen Group Tag geben (Standard- oder Auswahl-Tag aus den Einstellungen). Mit Rückfrage."/>
        <Button x:Name="bSync" Content="Autopilot-Sync anstoßen" Padding="10,4" Margin="8,0,0,0" ToolTip="Microsoft gleicht Autopilot neu ab (immer für den ganzen Tenant). Hilft, wenn ein Profil nicht kommt. Höchstens alle 10 Minuten."/>
        <TextBlock x:Name="tCount" VerticalAlignment="Center" Margin="14,0,0,0" FontWeight="SemiBold" ToolTip="Anzahl der angezeigten und markierten Geräte"/>
      </StackPanel>
    </DockPanel>
    <DataGrid x:Name="dGrid" ToolTip="Doppelklick = Details. Mehrere Zeilen markieren: Strg+Klick oder Umschalt+Klick.&#x0a;Spalten lassen sich verschieben (die Reihenfolge wird gemerkt) und breiter ziehen (gilt bis zum Schließen).&#x0a;Gekürzte Texte zeigen den vollen Inhalt, wenn die Maus darüber steht." AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True" CanUserReorderColumns="True" CanUserResizeColumns="True" SelectionMode="Extended" SelectionUnit="FullRow" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    Add-HuTheme $sx
    $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
    Register-HuWindow $sw
    $sw.Owner = $win
    if ($win.Icon) { $sw.Icon = $win.Icon }
    Set-WinFit $sw
    $g = @{}; foreach ($n in 'kAll','kOk','kWait','kReady','kProb','nAll','nOk','nWait','nReady','nProb','cTag','cProto','cToday','cProblem','cZeit','cZeitSpan','cZeitBasis','tFind','bReload','cAuto','tStamp','ePulse','tLoad','bCsv','bXlsx','bPrint','bClose','bDetail','bTagSet','bSync','tCount','dGrid','spTopR','spBotL','spBotR') { $g[$n] = $sw.FindName($n) }
    $sst = @{ Loading = $false; Dialog = $false; Tile = ''; First = $true; Fitted = $false; FitW = @{}; ManualCols = @{}; UserSized = $false; SizingByCode = $false; FromSearch = $false }
    $script:SRows = @(); $script:StatusView = @()
    # Spalten fest (deutsche Ueberschriften), Breite nach Inhalt (Set-GridColumnsFit), Reihenfolge aus ui.json
    $standStyle = $null
    try {
        $standXaml = '<Style TargetType="TextBlock" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">' +
            '<Setter Property="Padding" Value="8,2"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="FontWeight" Value="SemiBold"/><Style.Triggers>'
        foreach ($k in @(@('ok', 'HuStandOkBg'), @('warn', 'HuStandWarnBg'), @('err', 'HuStandErrBg'))) { $standXaml += '<DataTrigger Binding="{Binding Klasse}" Value="' + $k[0] + '"><Setter Property="Background" Value="{DynamicResource ' + $k[1] + '}"/><Setter Property="Foreground" Value="{DynamicResource HuStandText}"/></DataTrigger>' }
        $standStyle = [Windows.Markup.XamlReader]::Parse($standXaml + '</Style.Triggers></Style>')
    } catch { }
    foreach ($col in $script:StatusCols) {
        $dc = New-Object System.Windows.Controls.DataGridTextColumn
        $dc.Header = $col.Header; $dc.Binding = New-Object System.Windows.Data.Binding($col.Key)
        # Datumsspalten zeigen dd.MM.yyyy HH:mm, sortiert wird nach einer versteckten Fassung yyyy-MM-dd HH:mm
        $dc.SortMemberPath = $(if ($col.Sort) { $col.Sort } else { $col.Key })
        # Stand: nur diese Zelle deutlich eingefaerbt (Schild), die Zeile bleibt neutral bzw. leicht getoent
        if ($col.Key -eq 'Stand') { try { $dc.ElementStyle = $standStyle } catch { } }
        $g.dGrid.Columns.Add($dc)
    }
    # Spaltenbreite von Hand gezogen (Griff im Spaltenkopf): diese Spalte bis zum Schliessen nicht mehr anpassen.
    # Verglichen wird mit der zuletzt berechneten Breite, Scrollbalken zaehlen nicht (kein Spaltenkopf darueber).
    $g.dGrid.AddHandler([System.Windows.Controls.Primitives.Thumb]::DragCompletedEvent, [System.Windows.Controls.Primitives.DragCompletedEventHandler]{
        param($s, $e)
        try {
            $o = $e.OriginalSource; $inHead = $false
            while ($o -and $o -ne $g.dGrid) {
                if ($o -is [System.Windows.Controls.Primitives.DataGridColumnHeader]) { $inHead = $true; break }
                $o = [System.Windows.Media.VisualTreeHelper]::GetParent($o)
            }
            if (-not $inHead) { return }
            foreach ($dc in $g.dGrid.Columns) {
                $p = [string]$dc.Binding.Path.Path
                if ($sst.FitW.ContainsKey($p) -and [math]::Abs($dc.Width.Value - $sst.FitW[$p]) -gt 0.5) { $sst.ManualCols[$p] = $true }
            }
        } catch { }
    }, $true)
    try {
        $saved = @(Get-UiSetting 'StatusCols' @())
        $byKey = @{}; foreach ($dc in $g.dGrid.Columns) { $byKey[[string]$dc.Binding.Path.Path] = $dc }
        # Nur die Reihenfolge wird uebernommen ("Spalte|Position"). Alte Eintraege mit Breite ("Spalte|Position|Breite")
        # zaehlen nur mit ihrer Position, die Breite wird ignoriert und sofort aus ui.json entfernt.
        $order = @($saved | ForEach-Object { $p = ([string]$_) -split '\|'; if ($p.Count -ge 2 -and $byKey.ContainsKey($p[0])) { [pscustomobject]@{ Key = $p[0]; Ix = [int]$p[1] } } } | Sort-Object Ix)
        if ($order.Count -eq $g.dGrid.Columns.Count) { for ($i = 0; $i -lt $order.Count; $i++) { $byKey[$order[$i].Key].DisplayIndex = $i } }
        if (@($saved | Where-Object { ([string]$_ -split '\|').Count -gt 2 }).Count) { Set-UiSetting 'StatusCols' @($order | ForEach-Object { $_.Key + '|' + $_.Ix }) }
    } catch { }
    # Zeile nach Stand einfaerben (gruen / gelb / rot), Auswahl bleibt erkennbar (Zellen markiert in der Auswahlfarbe)
    try {
        $g.dGrid.RowStyle = [Windows.Markup.XamlReader]::Parse(@'
<Style TargetType="DataGridRow" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Style.Triggers>
    <DataTrigger Binding="{Binding Klasse}" Value="ok"><Setter Property="Background" Value="{DynamicResource HuRowOkBg}"/></DataTrigger>
    <DataTrigger Binding="{Binding Klasse}" Value="warn"><Setter Property="Background" Value="{DynamicResource HuRowWarnBg}"/></DataTrigger>
    <DataTrigger Binding="{Binding Klasse}" Value="err"><Setter Property="Background" Value="{DynamicResource HuRowErrBg}"/></DataTrigger>
  </Style.Triggers>
</Style>
'@)
    } catch { Out-Log 'Farben der Status-Tabelle nicht verfügbar.' 'Hinweis' $_.Exception.Message }
    $fillTags = {
        $keep = [string]$g.cTag.SelectedItem
        $g.cTag.Items.Clear(); [void]$g.cTag.Items.Add('Alle')
        foreach ($t in @($script:SRows | ForEach-Object { $_.Tag } | Where-Object { $_ } | Sort-Object -Unique)) { [void]$g.cTag.Items.Add($t) }
        if ($keep -and $g.cTag.Items.Contains($keep)) { $g.cTag.SelectedItem = $keep } else { $g.cTag.SelectedIndex = 0 }
    }
    $script:ZeitStd = @(4, 24, 48)
    foreach ($h in $script:ZeitStd) { [void]$g.cZeitSpan.Items.Add(('' + $h + ' h')) }
    [void]$g.cZeitSpan.Items.Add('heute')
    $g.cZeitSpan.SelectedIndex = 1
    [void]$g.cZeitBasis.Items.Add('nach Registrierung')
    [void]$g.cZeitBasis.Items.Add('nach Autopilot-Import')
    $g.cZeitBasis.SelectedIndex = 0
    $g.cAuto.IsChecked = ([string](Get-UiSetting 'StatusAuto' $true) -ne 'False')
    $tiles = @{ '' = $g.kAll; ok = $g.kOk; wait = $g.kWait; ready = $g.kReady; prob = $g.kProb }
    $refresh = {
        # Auswahl und Sortierung merken
        $selSn = @($g.dGrid.SelectedItems | ForEach-Object { [string]$_.Seriennr })
        $sorts = @($g.dGrid.Items.SortDescriptions | ForEach-Object { $_ })
        $v = @($script:SRows)
        if ($g.cTag.SelectedItem -and [string]$g.cTag.SelectedItem -ne 'Alle') { $sel = [string]$g.cTag.SelectedItem; $v = @($v | Where-Object { $_.Tag -eq $sel }) }
        if ($g.cProto.IsChecked) { $v = @($v | Where-Object { $_.HUPilot }) }
        if ($g.cToday.IsChecked) { $d0 = (Get-Date).Date; $v = @($v | Where-Object { $t = $script:StatusTimes[[string]$_.Seriennr]; $t -and (($t.Reg -and $t.Reg -ge $d0) -or ($t.Imp -and $t.Imp -ge $d0)) }) }
        if ($g.cProblem.IsChecked) { $v = @($v | Where-Object { $_.Klasse -eq 'err' }) }
        if ($g.cZeit.IsChecked) {
            $since = $(if ($g.cZeitSpan.SelectedIndex -eq 3) { (Get-Date).Date } else { (Get-Date).AddHours(-1 * $script:ZeitStd[[math]::Max(0, [math]::Min(2, $g.cZeitSpan.SelectedIndex))]) })
            $key = $(if ($g.cZeitBasis.SelectedIndex -eq 1) { 'Imp' } else { 'Reg' })
            $v = @($v | Where-Object { $t = $script:StatusTimes[[string]$_.Seriennr]; $t -and $t[$key] -and $t[$key] -ge $since })
        }
        if ($g.tFind.Text) { $q = $g.tFind.Text; $v = @($v | Where-Object { $_.Seriennr -like ('*' + $q + '*') -or $_.Name -like ('*' + $q + '*') -or $_.Benutzer -like ('*' + $q + '*') }) }
        # Kacheln zaehlen ueber die gefilterte Liste (ohne Kachel-Filter)
        $cnt = @{ ok = 0; wait = 0; ready = 0; prob = 0 }
        foreach ($r in $v) { $k = $script:StandTile[[string]$r.Stand]; if ($k) { $cnt[$k]++ } }
        $g.nAll.Text = '' + $v.Count; $g.nOk.Text = '' + $cnt.ok; $g.nWait.Text = '' + $cnt.wait; $g.nReady.Text = '' + $cnt.ready; $g.nProb.Text = '' + $cnt.prob
        if ($sst.Tile) { $tk = $sst.Tile; $v = @($v | Where-Object { $script:StandTile[[string]$_.Stand] -eq $tk }) }
        foreach ($k in @($tiles.Keys)) { if ($k -eq $sst.Tile -and $k) { $tiles[$k].SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'HuAccent') } else { $tiles[$k].ClearValue([System.Windows.Controls.Control]::BorderBrushProperty) } }
        $script:StatusView = $v
        $g.dGrid.ItemsSource = $v
        # Sortierung und Auswahl wiederherstellen
        foreach ($sd in $sorts) { $g.dGrid.Items.SortDescriptions.Add($sd); foreach ($dc in $g.dGrid.Columns) { if ($dc.SortMemberPath -eq $sd.PropertyName) { $dc.SortDirection = $sd.Direction } } }
        if ($selSn.Count) { foreach ($it in @($g.dGrid.Items)) { if ($selSn -contains [string]$it.Seriennr) { [void]$g.dGrid.SelectedItems.Add($it) } } }
        $g.tCount.Text = ('' + $v.Count + ' angezeigt' + $(if ($g.dGrid.SelectedItems.Count) { ', ' + $g.dGrid.SelectedItems.Count + ' markiert' } else { '' }))
        # Spaltenbreiten nach der ANGEZEIGTEN Liste, bei jeder Aenderung (Filter, Suche, Kachel, Aktualisieren)
        try { & $fitCols } catch { }
        # Fensterbreite: bei der Suche erst nach einer kurzen Pause, sonst sofort
        if ($sst.FromSearch) { $wtm.Stop(); $wtm.Start() } else { try { & $fitWin } catch { } }
    }
    $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.2, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(600))))
    $pulse.AutoReverse = $true; $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    # -Auto: Aufruf vom Timer. Dann gleiche Protokollzeilen nur einmal (bis sich etwas aendert) und nach zwei
    # Fehlschlaegen ohne Verbindung pausieren. Ein Klick auf Aktualisieren laeuft immer laut und startet den Timer wieder.
    $sst.Seen = @{}; $sst.Fails = 0; $sst.Paused = $false
    $load = {
        param([bool]$Auto = $false)
        if ($sst.Loading) { return }
        $sst.Loading = $true; $g.bReload.IsEnabled = $false
        $g.ePulse.Visibility = 'Visible'; $g.ePulse.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
        Set-Step 'Status' 'run'
        if ($Auto) { $script:QuietDedupe = $sst.Seen } else { $script:QuietDedupe = $null; $sst.Seen.Clear() }
        try {
            $d = Get-StatusData -Progress { param($t) $g.tLoad.Text = $t; $sw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
            if ($d) {
                $sst.Fails = 0
                # Fehler und Hinweise duerfen nach einem erfolgreichen Durchgang wieder einmal erscheinen
                foreach ($k in @($sst.Seen.Keys)) { if ($sst.Seen[$k] -in 'Fehler', 'Hinweis') { $sst.Seen.Remove($k) } }
                if ($sst.Paused -and $g.cAuto.IsChecked) { $sst.Paused = $false; $tm.Start() }
                $script:SRows = @($d.Rows); & $fillTags
                if ($sst.First) { $g.cProto.IsChecked = ($d.Proto.Count -gt 0); $g.cProto.IsEnabled = ($d.Proto.Count -gt 0); $sst.First = $false }
                $g.tStamp.Text = 'Stand: ' + (Get-Date -Format 'HH:mm')
                $g.tLoad.Text = ''
                Set-Step 'Status' 'ok' ('' + @($d.Rows).Count + ' Geräte')
            } else {
                $g.tLoad.Text = 'Nicht geladen, Details im Protokoll des Hauptfensters.'; Set-Step 'Status' 'err' 'nicht geladen'
                if ($Auto) {
                    $sst.Fails++
                    if ($sst.Fails -ge 2 -and $script:TokenErr -eq 'net') { $tm.Stop(); $sst.Paused = $true; $g.tLoad.Text = 'Automatisches Aktualisieren pausiert: keine Verbindung. "Aktualisieren" klicken, um es wieder zu starten.' }
                }
            }
        } catch { $g.tLoad.Text = 'Nicht geladen, Details im Protokoll des Hauptfensters.'; Out-Log 'Status konnte nicht geladen werden.' 'Fehler' $_.Exception.Message; Set-Step 'Status' 'err' $_.Exception.Message }
        finally {
            $script:QuietDedupe = $null
            $sst.Loading = $false; $g.bReload.IsEnabled = $true
            $g.ePulse.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $g.ePulse.Visibility = 'Collapsed'
        }
        # Auffrischen der Liste abgesichert (passt auch Spalten und Fenster an): ein Fehler darf das Fenster nicht abstuerzen lassen
        try { & $refresh } catch { Out-Log 'Die Liste im Status-Fenster konnte nicht aufgefrischt werden.' 'Fehler' $_.Exception.Message }
    }
    # Breite je Spalte = breitester Text der angezeigten Zeilen plus Luft; von Hand gezogene Spalten bleiben bis zum Schliessen
    $fitCols = {
        Set-GridColumnsFit $g.dGrid @($script:StatusView) @{ WasTun = 420 } @{ Stand = 16 } @('Stand') @($sst.ManualCols.Keys)
        foreach ($dc in $g.dGrid.Columns) { $sst.FitW[[string]$dc.Binding.Path.Path] = $dc.Width.Value }
    }
    # Fensterbreite an die Spalten anpassen (breiter und schmaler), solange der Anwender das Fenster nicht selbst veraendert hat
    $fitWin = {
        if ($sst.UserSized -or [string]$sw.WindowState -ne 'Normal') { return }
        $sw.UpdateLayout()
        # Fensterbreite = Spalten plus Raender und Scrollbalken, mindestens so breit, dass Kopfzeile und Knopfleiste ganz sichtbar sind
        $cols = 0.0; foreach ($dc in $g.dGrid.Columns) { $cols += $dc.Width.Value }
        $chrome = $sw.ActualWidth - $g.dGrid.ActualWidth
        $g.spBotL.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)); $g.spBotR.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)); $g.spTopR.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $minW = [math]::Max($g.spBotL.DesiredSize.Width + $g.spBotR.DesiredSize.Width + 24, $g.spTopR.DesiredSize.Width + 260) + $chrome
        $wa = [System.Windows.SystemParameters]::WorkArea
        $target = [math]::Ceiling([math]::Min($wa.Width, [math]::Max($cols + $chrome + 20, $minW)))
        if (-not $sst.Fitted -or [math]::Abs($target - $sw.ActualWidth) -gt 1) {
            $sst.Fitted = $true; $sst.SizingByCode = $true
            $sw.Width = $target; Set-WinFit $sw
            [void]$sw.Dispatcher.BeginInvoke([action]{ $sst.SizingByCode = $false }, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
        }
    }
    # Pause nach dem Tippen in der Suche, bevor das Fenster seine Breite aendert
    $wtm = New-Object System.Windows.Threading.DispatcherTimer
    $wtm.Interval = [TimeSpan]::FromMilliseconds(400)
    $wtm.Add_Tick({ $wtm.Stop(); try { & $fitWin } catch { } })
    # Der Anwender hat das Fenster selbst in der Groesse geaendert oder maximiert: Breite nicht mehr anfassen
    $sw.Add_SizeChanged({ param($s, $e) if ($sst.Fitted -and -not $sst.SizingByCode -and $e.PreviousSize.Width -gt 0) { $sst.UserSized = $true } })
    $sw.Add_StateChanged({ if ([string]$sw.WindowState -ne 'Normal') { $sst.UserSized = $true } })
    foreach ($k in @($tiles.Keys)) { $tiles[$k].Add_Click({ $t = [string]$this.Tag; if (-not $t -or $sst.Tile -eq $t) { $sst.Tile = '' } else { $sst.Tile = $t }; & $refresh }) }
    $g.cTag.Add_SelectionChanged({ if (-not $sst.Loading) { & $refresh } })
    foreach ($cb in 'cProto', 'cToday', 'cProblem', 'cZeit') { $g[$cb].Add_Click({ & $refresh }) }
    $g.cZeitSpan.Add_SelectionChanged({ if ($g.cZeit.IsChecked) { & $refresh } })
    $g.cZeitBasis.Add_SelectionChanged({ if ($g.cZeit.IsChecked) { & $refresh } })
    $g.tFind.Add_TextChanged({ $sst.FromSearch = $true; try { & $refresh } finally { $sst.FromSearch = $false } })
    $g.dGrid.Add_SelectionChanged({ $g.tCount.Text = ('' + @($script:StatusView).Count + ' angezeigt' + $(if ($g.dGrid.SelectedItems.Count) { ', ' + $g.dGrid.SelectedItems.Count + ' markiert' } else { '' })) })
    $g.bReload.Add_Click({ & $load $false; if ($g.cAuto.IsChecked -and -not $sst.Paused) { $tm.Start() } })
    $g.bClose.Add_Click({ $sw.Close() })
    $g.cAuto.Add_Click({ Set-UiSetting 'StatusAuto' ([bool]$g.cAuto.IsChecked) })
    # Automatisch aktualisieren: nicht waehrend Laden oder offenem Dialog
    $tm = New-Object System.Windows.Threading.DispatcherTimer
    $tm.Interval = [TimeSpan]::FromSeconds(60)
    $tm.Add_Tick({ if ($g.cAuto.IsChecked -and -not $sst.Loading -and -not $sst.Dialog) { & $load $true } })
    $sw.Add_Closing({
        $tm.Stop()
        # nur die Reihenfolge merken, keine Breiten
        try { Set-UiSetting 'StatusCols' @($g.dGrid.Columns | ForEach-Object { [string]$_.Binding.Path.Path + '|' + $_.DisplayIndex }) } catch { }
    })
    $detail = {
        $it = $g.dGrid.SelectedItem; if (-not $it) { $g.tCount.Text = 'Bitte zuerst eine Zeile markieren.'; return }
        $sst.Dialog = $true
        try { Show-DeviceDetail $it $sw } catch { Out-Log ('Details zu ' + $it.Seriennr + ' nicht verfügbar.') 'Fehler' $_.Exception.Message } finally { $sst.Dialog = $false }
    }
    $g.dGrid.Add_MouseDoubleClick($detail)
    $g.bDetail.Add_Click($detail)
    # Tag aendern fuer markierte Geraete (Auswahl aus Standard- und Auswahl-Tags der Einstellungen)
    $g.bTagSet.Add_Click({
        $sel = @($g.dGrid.SelectedItems); if (-not $sel.Count) { $g.tCount.Text = 'Bitte zuerst Geräte markieren.'; return }
        $c = Get-Cfg
        $tags = @(@($c.GroupTag) + @($c.TagChoices) | Where-Object { $_ } | Select-Object -Unique)
        if (-not $tags.Count) { Show-Msg 'In den Einstellungen ist kein Group Tag eingetragen (Hauptfenster: Group Tag).' 'HUPilot - Tag ändern' 'Warning' $sw; return }
        $sst.Dialog = $true
        try {
            $rows = @($tags | ForEach-Object { [pscustomobject]@{ Tag = $_; Art = $(if ($_ -eq $c.GroupTag) { 'Standard' } else { 'Auswahl' }) } })
            $pick = Show-Pick 'HUPilot - Tag ändern' ('Neuen Group Tag für ' + $sel.Count + ' Gerät(e) wählen.') $rows 'Diesen Tag setzen' $sw
            if (-not $pick) { return }
            $sns = @($sel | ForEach-Object { [string]$_.Seriennr })
            $list = (@($sns | Select-Object -First 15) -join "`r`n") + $(if ($sns.Count -gt 15) { "`r`n... und " + ($sns.Count - 15) + ' weitere' } else { '' })
            $q = [System.Windows.MessageBox]::Show($sw, ('Tag "' + $pick.Tag + '" setzen für ' + $sns.Count + ' Gerät(e):' + "`r`n`r`n" + $list + "`r`n`r`n" + 'Wirkung: Die Geräte wechseln in die Gruppe dieses Tags und bekommen dessen Autopilot-Profil. Das dauert einige Minuten. Bereits eingerichtete Geräte ändern sich erst beim nächsten Zurücksetzen.' + "`r`n`r`n" + 'Fortfahren?'), 'HUPilot - Tag ändern', 'YesNo', 'Question')
            if ($q -ne 'Yes') { return }
            $tok = Get-ApiToken; if (-not $tok) { Show-Msg $script:TokenMsg 'HUPilot - Tag ändern' 'Warning' $sw; return }
            $hj = @{ Authorization = 'Bearer ' + $tok; 'Content-Type' = 'application/json' }
            $ok = 0
            foreach ($r in $sel) {
                $id = $script:ApIds[[string]$r.Seriennr]
                if (-not $id) { Out-Log ($r.Seriennr + ': nicht in Autopilot gefunden, Tag nicht geändert.') 'Fehler'; continue }
                try {
                    Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri ('https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/' + $id + '/updateDeviceProperties') -Headers $hj -Body (@{ groupTag = [string]$pick.Tag } | ConvertTo-Json) -TimeoutSec 30 | Out-Null
                    Out-Log ($r.Seriennr + ': Tag auf "' + $pick.Tag + '" gesetzt') 'OK'; $ok++
                } catch { $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }; Out-Log ($r.Seriennr + ': Tag konnte nicht geändert werden. Später nochmal versuchen.') 'Fehler' $m }
                $sw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
            }
            Show-Msg ('Tag "' + $pick.Tag + '" gesetzt: ' + $ok + ' von ' + $sel.Count + ' Gerät(en). Einzelheiten im Protokoll des Hauptfensters.') 'HUPilot - Tag ändern' $(if ($ok -eq $sel.Count) { 'Information' } else { 'Warning' }) $sw
        } finally { $sst.Dialog = $false }
        & $load
    })
    # Autopilot-Sync: wirkt fuer den ganzen Tenant; 409/429 = laeuft bereits oder vor weniger als 10 Minuten
    $g.bSync.Add_Click({
        $sns = @($g.dGrid.SelectedItems | ForEach-Object { [string]$_.Seriennr })
        $sst.Dialog = $true
        try {
            $q = [System.Windows.MessageBox]::Show($sw, ('Autopilot-Sync anstoßen?' + "`r`n`r`n" + 'Microsoft gleicht dabei alle Autopilot-Geräte des Tenants ab, nicht nur einzelne.' + $(if ($sns.Count) { ' Markiert: ' + (@($sns | Select-Object -First 10) -join ', ') + $(if ($sns.Count -gt 10) { ' ...' } else { '' }) + '.' } else { '' }) + "`r`n" + 'Wirkung: neue Geräte und geänderte Tags werden schneller sichtbar. Geht höchstens alle 10 Minuten.' + "`r`n`r`n" + 'Fortfahren?'), 'HUPilot - Autopilot-Sync', 'YesNo', 'Question')
            if ($q -ne 'Yes') { return }
            $tok = Get-ApiToken; if (-not $tok) { Show-Msg $script:TokenMsg 'HUPilot - Autopilot-Sync' 'Warning' $sw; return }
            try {
                Microsoft.PowerShell.Utility\Invoke-RestMethod -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync' -Headers @{ Authorization = 'Bearer ' + $tok } -TimeoutSec 30 | Out-Null
                Out-Log ('Autopilot-Sync angestoßen' + $(if ($sns.Count) { ' (markiert: ' + ($sns -join ', ') + ')' } else { '' })) 'OK'
                Show-Msg 'Autopilot-Sync angestoßen. In ein paar Minuten "Aktualisieren" klicken.' 'HUPilot - Autopilot-Sync' 'Information' $sw
            } catch {
                $code = Get-HttpCode $_
                if ($code -in 409, 429) { Out-Log 'Autopilot-Sync läuft bereits oder wurde vor weniger als 10 Minuten angestoßen. Einfach etwas warten.' 'Hinweis' ('HTTP ' + $code); Show-Msg 'Der Sync läuft bereits oder wurde vor weniger als 10 Minuten angestoßen. Einfach etwas warten.' 'HUPilot - Autopilot-Sync' 'Information' $sw }
                else { Out-Log 'Autopilot-Sync konnte nicht angestoßen werden. Später nochmal versuchen.' 'Fehler' $_.Exception.Message; Show-Msg 'Autopilot-Sync konnte nicht angestoßen werden. Details im Protokoll des Hauptfensters.' 'HUPilot - Autopilot-Sync' 'Warning' $sw }
            }
        } finally { $sst.Dialog = $false }
    })
    $exportRows = { @($g.dGrid.Items) }
    $fileBase = { 'HUPilot-Status_' + ((Get-Cfg).Tenant -replace '[^A-Za-z0-9-]', '') + '_' + (Get-Date -Format 'yyyy-MM-dd_HHmm') }
    $g.bCsv.Add_Click({
        $sst.Dialog = $true
        try {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter = 'CSV (*.csv)|*.csv'; $dlg.FileName = (& $fileBase) + '.csv'
            if ($dlg.ShowDialog()) {
                $props = @($script:StatusCols | ForEach-Object { $k = $_.Key; @{ Name = $_.Header; Expression = [scriptblock]::Create('$_.' + $k) } })
                @(& $exportRows) | Select-Object -Property $props | Export-Csv -Path $dlg.FileName -Delimiter ';' -NoTypeInformation -Encoding UTF8
                Out-Log 'Status als CSV gespeichert' 'OK' $dlg.FileName
            }
        } catch { Out-Log 'CSV-Datei konnte nicht gespeichert werden. Ist sie noch in Excel offen?' 'Fehler' $_.Exception.Message }
        finally { $sst.Dialog = $false }
    })
    $g.bXlsx.Add_Click({
        $sst.Dialog = $true
        try {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter = 'Excel (*.xlsx)|*.xlsx'; $dlg.FileName = (& $fileBase) + '.xlsx'
            if ($dlg.ShowDialog()) {
                try {
                    Export-StatusXlsx -Rows @(& $exportRows) -Cols @($script:StatusCols | ForEach-Object { $_.Key }) -Headers @($script:StatusCols | ForEach-Object { $_.Header }) -Path $dlg.FileName
                    Out-Log 'Status als Excel-Datei gespeichert' 'OK' $dlg.FileName
                } catch {
                    Out-Log 'Excel-Datei konnte nicht gespeichert werden. Ist sie noch in Excel offen?' 'Fehler' $_.Exception.Message
                    [void][System.Windows.MessageBox]::Show($sw, ('Excel-Datei konnte nicht gespeichert werden (ist sie noch in Excel offen?)' + "`r`n`r`n" + $_.Exception.Message), 'HUPilot - Status', 'OK', 'Warning')
                }
            }
        } finally { $sst.Dialog = $false }
    })
    $g.bPrint.Add_Click({
        $sst.Dialog = $true
        try {
            $pd = New-Object System.Windows.Controls.PrintDialog
            try { Add-Type -AssemblyName System.Printing; $pd.PrintTicket.PageOrientation = [System.Printing.PageOrientation]::Landscape } catch { }
            if (-not $pd.ShowDialog()) { return }
            $flt = @()
            if ($g.cTag.SelectedItem -and [string]$g.cTag.SelectedItem -ne 'Alle') { $flt += ('Tag ' + [string]$g.cTag.SelectedItem) }
            if ($g.cProto.IsChecked) { $flt += 'nur Geräte aus dem Stick-Protokoll' }
            if ($g.cToday.IsChecked) { $flt += 'heute' }
            if ($g.cProblem.IsChecked) { $flt += 'nur Probleme' }
            if ($sst.Tile) { $flt += ('Kachel ' + @{ ok = 'Fertig'; wait = 'Wartet auf Profil'; ready = 'Profil da'; prob = 'Problem' }[$sst.Tile]) }
            if ($g.cZeit.IsChecked) { $flt += ('letzte ' + [string]$g.cZeitSpan.SelectedItem + ' ' + [string]$g.cZeitBasis.SelectedItem) }
            if ($g.tFind.Text) { $flt += ('Suche "' + $g.tFind.Text + '"') }
            $sub = ('' + @(& $exportRows).Count + ' Geräte: ' + $g.nOk.Text + ' fertig, ' + $g.nWait.Text + ' warten auf Profil, ' + $g.nReady.Text + ' noch nicht angemeldet, ' + $g.nProb.Text + ' Problem') + $(if ($flt.Count) { '   |   Filter: ' + ($flt -join ', ') } else { '' })
            $doc = New-StatusPrintDoc -Rows @(& $exportRows) -Cols @($script:StatusCols | ForEach-Object { $_.Key }) -Headers @($script:StatusCols | ForEach-Object { $_.Header }) -Title ('HUPilot - Status ' + (Get-Cfg).Tenant + '   ' + (Get-Date -Format 'dd.MM.yyyy HH:mm')) -Sub $sub -PageW $pd.PrintableAreaWidth -PageH $pd.PrintableAreaHeight
            $pd.PrintDocument(([System.Windows.Documents.IDocumentPaginatorSource]$doc).DocumentPaginator, 'HUPilot-Status')
            Out-Log 'Status gedruckt' 'OK'
        } catch { Out-Log 'Drucken fehlgeschlagen. Drucker prüfen und nochmal versuchen.' 'Fehler' $_.Exception.Message }
        finally { $sst.Dialog = $false }
    })
    $sw.Add_ContentRendered({ & $load $false; $tm.Start() })
    [void]$sw.ShowDialog()
    $tm.Stop(); $wtm.Stop()
}

# Autopilot- und Intune-Geraete laden. -Progress: Skriptblock mit einem Text (Fortschritt), haelt das Fenster zwischen den Seiten bedienbar
function Get-StatusData([scriptblock]$Progress = $null) {
    $say = { param($t) if ($Progress) { & $Progress $t } }
    & $say 'Anmeldung bei Microsoft ...'
    $tok = Get-ApiTokenCached; if (-not $tok) { return $null }
    $h = @{ Authorization = 'Bearer ' + $tok }
    $all = @()
    try {
        $uri = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?$top=500'
        $page = 0
        while ($uri) {
            $page++; & $say ('lade Autopilot-Geräte, Seite ' + $page + ' ...')
            $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri $uri -Headers $h -TimeoutSec 60
            $all += @($r.value)
            $uri = $r.'@odata.nextLink'
        }
    } catch { Out-Log 'Autopilot-Geräte nicht lesbar. 1. Verbindung testen.' 'Fehler' $_.Exception.Message; return $null }
    # Optional: Intune-Geraete (Primaerer Benutzer, Geraetename, letzter Sync) - braucht DeviceManagementManagedDevices.Read.All
    $md = @{}
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,serialNumber,deviceName,userPrincipalName,lastSyncDateTime,enrolledDateTime&`$top=999"
        $page = 0
        while ($uri) {
            $page++; & $say ('lade Intune-Geräte, Seite ' + $page + ' ...')
            $r = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri $uri -Headers $h -TimeoutSec 60
            foreach ($m in @($r.value)) { if ($m.serialNumber) { $md[[string]$m.id] = $m; $md['SN:' + [string]$m.serialNumber] = $m } }
            $uri = $r.'@odata.nextLink'
        }
    } catch { Out-Log 'Benutzer, Gerätename und letzter Sync nicht lesbar. Optional: der App die Berechtigung DeviceManagementManagedDevices.Read.All geben.' 'Hinweis' $_.Exception.Message }
    & $say 'lese Stick-Protokoll ...'
    $proto = Read-Protokoll
    $mapE = @{ enrolled = 'registriert'; notContacted = 'noch nicht'; failed = 'Fehler'; pendingReset = 'Reset ausstehend'; blocked = 'blockiert'; unknown = 'unbekannt' }
    $script:ApIds = @{}
    foreach ($d in $all) { if ($d.serialNumber) { $script:ApIds[[string]$d.serialNumber] = [string]$d.id } }
    # Zeiten fuer die Zeitfilter (nicht als Spalte): Reg = Intune-Registrierung, Imp = Autopilot-Import.
    # Graph liefert keine Importzeit: genommen wird die HUPilot-Zeit aus protokoll.csv, sonst die Profil-Zuweisung.
    $script:StatusTimes = @{}
    $rows = foreach ($d in $all) {
        $ps = [string]$d.deploymentProfileAssignmentStatus
        $hasDate = $false; try { $hasDate = ([datetime]$d.deploymentProfileAssignedDateTime).Year -gt 2000 } catch { }
        $prof = $(if ($ps -in 'assignedInSync', 'assignedUnkownSyncState') { $(if ($hasDate) { 'zugewiesen' } else { 'zugew., Datum fehlt' }) } elseif ($ps -eq 'assignedOutOfSync') { 'zugew., nicht synchron' } elseif ($ps -eq 'pending') { 'ausstehend' } elseif ($ps -eq 'notAssigned') { 'keins' } else { $ps })
        $es = [string]$d.enrollmentState
        $stand = Get-DeviceStand $ps $es $hasDate
        $lc = ''; $lcS = ''
        try { $dt = [datetime]$d.lastContactedDateTime; if ($dt.Year -gt 2000) { $lc = $dt.ToLocalTime().ToString('dd.MM.yyyy HH:mm'); $lcS = $dt.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } catch { }
        $pr = $null; if ($proto.ContainsKey([string]$d.serialNumber)) { $pr = $proto[[string]$d.serialNumber] }
        $im = $null
        if ($d.managedDeviceId -and $md.ContainsKey([string]$d.managedDeviceId)) { $im = $md[[string]$d.managedDeviceId] }
        elseif ($md.ContainsKey('SN:' + [string]$d.serialNumber)) { $im = $md['SN:' + [string]$d.serialNumber] }
        $sync = ''; $syncS = ''; $reg = ''; $regS = ''
        if ($im) { try { $sd = [datetime]$im.lastSyncDateTime; if ($sd.Year -gt 2000) { $sync = $sd.ToLocalTime().ToString('dd.MM.yyyy HH:mm'); $syncS = $sd.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } catch { } }
        $tReg = $null; $tImp = $null
        if ($im) { try { $rd = [datetime]$im.enrolledDateTime; if ($rd.Year -gt 2000) { $tReg = $rd.ToLocalTime(); $reg = $tReg.ToString('dd.MM.yyyy HH:mm'); $regS = $tReg.ToString('yyyy-MM-dd HH:mm') } } catch { } }
        $pt = [datetime]::MinValue
        if ($pr -and [datetime]::TryParseExact([string]$pr.Zeit, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$pt)) { $tImp = $pt }
        if (-not $tImp) { try { $pa = [datetime]$d.deploymentProfileAssignedDateTime; if ($pa.Year -gt 2000) { $tImp = $pa.ToLocalTime() } } catch { } }
        if ($d.serialNumber) { $script:StatusTimes[[string]$d.serialNumber] = @{ Reg = $tReg; Imp = $tImp } }
        [pscustomobject]@{
            Stand          = $stand
            WasTun         = (Get-DeviceTodo $stand $ps $es)
            Seriennr       = [string]$d.serialNumber
            Tag            = [string]$d.groupTag
            Name           = $(if ($im) { [string]$im.deviceName } else { [string]$d.displayName })
            Benutzer       = $(if ($im -and $im.userPrincipalName) { [string]$im.userPrincipalName } else { [string]$d.userPrincipalName })
            RegDatum       = $reg
            LetzterKontakt = $lc
            LetzterSync    = $sync
            RegSort        = $regS
            KontaktSort    = $lcS
            SyncSort       = $syncS
            HUPilotSort    = $(if ($pr) { [string]$pr.Zeit } else { '' })
            Modell         = [string]$d.model
            Profil         = $prof
            Intune         = $(if ($mapE.ContainsKey($es)) { $mapE[$es] } else { $es })
            HUPilot        = $(if ($pr) { $(if ($pt -ne [datetime]::MinValue) { $pt.ToString('dd.MM.yyyy HH:mm') } else { [string]$pr.Zeit }) + ' ' + [string]$pr.Ergebnis } else { '' })
            Klasse         = $script:StandClass[$stand]
        }
    }
    # noch nicht registrierte Geraete (gerade in Arbeit) OBEN, danach die registrierten, neueste zuerst
    $rows = @(@($rows | Where-Object { -not $_.RegSort }) + @($rows | Where-Object { $_.RegSort } | Sort-Object RegSort -Descending))
    Out-Log ('Status geladen: ' + @($rows).Count + ' Autopilot-Geräte, ' + $proto.Count + ' aus dem Stick-Protokoll') 'OK'
    return @{ Rows = $rows; Proto = $proto }
}
$ui.bStatus.Add_Click({
    try { Show-Status } catch { Out-Log 'Das Status-Fenster konnte nicht geöffnet werden.' 'Fehler' $_.Exception.Message; Set-Step 'Status' 'err' $_.Exception.Message }
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
        Out-Log 'Desktop-Verknüpfung angelegt' 'OK' $lnk
    } catch { Out-Log 'Desktop-Verknüpfung konnte nicht angelegt werden.' 'Fehler' $_.Exception.Message }
})

Update-Drives
Out-Log ('Quelle: '  + $srcStick)
$ui.tSub.ToolTip = 'Quelle: ' + $srcStick
if (Test-Path $srcCfg) { $ui.bLoad.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
# Ohne config.json: leeres Formular gilt als gespeicherter Stand (kein Hinweis "ungespeichert")
if ($null -eq $script:SavedSnap) { $script:SavedSnap = Get-CfgSnap; Update-Dirty }
if (Test-Path $icd) { Out-Log 'ICD.exe gefunden, WLAN-Pakete können gebaut werden' 'OK' $icd }
else { Out-Log 'ICD.exe fehlt: WLAN-Pakete können hier nicht gebaut werden. Für "4. WLAN-Paket bauen" Windows ADK mit "Imaging and Configuration Designer" installieren (die Store-App reicht nicht).' 'Hinweis' $icd }
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
    <DataGrid x:Name="dGrid" ToolTip="Je Tag: Geräte, passende Gruppe und Autopilot-Profil. Spaltenkopf anklicken = sortieren." AutoGenerateColumns="True" IsReadOnly="True" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    Add-HuTheme $gx
    $gw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $gx))
    Register-HuWindow $gw
    $gw.Owner = $win; $gw.Title = $Title
    if ($win.Icon) { $gw.Icon = $win.Icon }
    Set-WinFit $gw
    $gw.FindName('tInfo').Text = $Info
    $gw.FindName('dGrid').ItemsSource = @($Rows)
    $gw.FindName('bClose').Add_Click({ $gw.Close() })
    $gw.Add_ContentRendered({ $dg = $gw.FindName('dGrid'); Set-GridColumnsFit $dg @($dg.ItemsSource); Set-GridWindowWidth $gw $dg 640 })
    [void]$gw.ShowDialog()
}

# ---------- 2. Tags pruefen ----------
# Je Tag: Geraete, passende Gruppe, Profil. Rueckgabe @{ Rows; Bad (am Stick waehlbar, ohne Profil); GErr; Info; Error }
# Gemeinsam fuer "2. Tags pruefen" (Tabelle) und "Stick fertig machen" (nur Warnung)
function Get-TagReport($h) {
    Out-Log 'Lade Profile, Gruppen und Geräte ...'
    try { $profs = @((Microsoft.PowerShell.Utility\Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments' -Headers $h -TimeoutSec 60).value) }
    catch { Out-Log 'Autopilot-Profile nicht lesbar. 1. Verbindung testen.' 'Fehler' $_.Exception.Message; return @{ Rows = @(); Bad = @(); GErr = $false; Info = ''; Error = ('Profile nicht lesbar: ' + $_.Exception.Message) } }
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
                    else { Out-Log ('Profil "' + $p.displayName + '" ist einer Gruppe zugewiesen, die es nicht mehr gibt. In Intune die Zuweisung prüfen.') 'Hinweis' $gid; $gcache[$gid] = [pscustomobject]@{ displayName = ('(gelöscht) ' + $gid); membershipRule = '' } }
                }
            }
            $targets += [pscustomobject]@{ Profil = [string]$p.displayName; Gruppe = [string]$gcache[$gid].displayName; Rule = [string]$gcache[$gid].membershipRule }
        }
    }
    $devs = @(); try { $devs = @(Get-ApAll $h) } catch { Out-Log 'Autopilot-Geräte nicht lesbar, die Spalte Geräte bleibt leer.' 'Hinweis' $_.Exception.Message }
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
    if ($bad.Count) { Out-Log ('Tags ohne Autopilot-Profil, aber am Stick wählbar: ' + (($bad | ForEach-Object { $_.Tag }) -join ', ') + '. In Intune eine dynamische Gruppe mit Profil für diesen Tag anlegen oder den Tag am Stick ändern.') 'Hinweis' }
    elseif ($gErr) { Out-Log 'Tags nur teilweise geprüft: Gruppen nicht lesbar. Optional: der App die Berechtigung Group.Read.All geben.' 'Hinweis' }
    else { Out-Log ('Tags geprüft: alle ' + @($rows).Count + ' Tags haben ein Profil') 'OK' }
    $info = 'Je Tag: Geräte in Autopilot, passende dynamische Gruppe ([OrderID]-Regel) und daran zugewiesenes Autopilot-Profil.'
    if ($bad.Count) { $info += '  Achtung: ' + (($bad | ForEach-Object { $_.Tag }) -join ', ') + ' am Stick wählbar, aber ohne Profil.' }
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
        $out += [pscustomobject]@{ Seriennr = $p[0].Trim(); Tag = $(if ($p.Count -gt 3) { $p[3].Trim() } else { '' }); Benutzer = $(if ($p.Count -gt 4) { $p[4].Trim() } else { '' }); Status = 'offen'; Datei = $File; Hash = $p[2].Trim(); ImpId = ''; Done = $false; Detail = '' }
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
    <ListBox x:Name="tHLog" ToolTip="Protokoll des Imports: OK (grün), Hinweis (gelb), Fehler (rot). Technische Details per Doppelklick, steht auch in der Protokolldatei." DockPanel.Dock="Bottom" Height="110" Margin="0,8,0,0" SelectionMode="Extended" ScrollViewer.HorizontalScrollBarVisibility="Disabled" FontFamily="Consolas"/>
    <DataGrid x:Name="dGrid" ToolTip="Gefundene Hashes mit Stand des Imports." AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Seriennr" Binding="{Binding Seriennr}"/>
        <DataGridTextColumn Header="Tag" Binding="{Binding Tag}"/>
        <DataGridTextColumn Header="Benutzer" Binding="{Binding Benutzer}"/>
        <DataGridTextColumn Header="Status" Binding="{Binding Status}"/>
        <DataGridTextColumn Header="Datei" Binding="{Binding Datei}"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@
    Add-HuTheme $hx
    $hw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $hx))
    Register-HuWindow $hw
    $hw.Owner = $win
    if ($win.Icon) { $hw.Icon = $win.Icon }
    Set-WinFit $hw
    $g = @{}; foreach ($n in 'bAdd','bImp','bClose','tHLog','dGrid') { $g[$n] = $hw.FindName($n) }
    $script:HRows = @()
    $hlog = { param($m, $lv = '', $dt = '') Out-SubLog $g.tHLog $hw 'Hashes importieren' $m $lv $dt }
    $g.tHLog.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'C' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { [void](Copy-LogItems $g.tHLog); $e.Handled = $true } })
    # Zeile eines Geraets: Stufe aus dem Stand, rohe Graph-Meldung als Detail
    $hrow = { param($r) & $hlog ($r.Seriennr + ': ' + $r.Status) $(if ($r.Status -like 'Fehler*') { 'Fehler' } elseif ($r.Done) { 'OK' } elseif ($r.Status -like 'Import nach*' -or $r.Status -like 'abgebrochen*') { 'Hinweis' } else { '' }) ([string]$r.Detail) }
    $refresh = { $g.dGrid.ItemsSource = $null; $g.dGrid.ItemsSource = @($script:HRows); Set-GridColumnsFit $g.dGrid $script:HRows; $hw.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background) }
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
        if ($q -eq 'Yes') { $hst.Abort = $true; $hst.CloseAfter = $true; & $hlog 'Abbruch angefordert, warte auf den laufenden Schritt ...' 'Hinweis' }
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
        $tok = Get-ApiToken; if (-not $tok) { & $hlog $script:TokenMsg 'Fehler'; Set-Step 'Hash' 'err' $script:TokenMsg; return }
        $h  = @{ Authorization = 'Bearer ' + $tok }
        $hj = @{ Authorization = 'Bearer ' + $tok; 'Content-Type' = 'application/json' }
        $GB = 'https://graph.microsoft.com/beta/deviceManagement'
        $c = Get-Cfg
        foreach ($r in $todo) {
            if ($hst.Abort) { & $hlog 'Abgebrochen, die restlichen Geräte wurden nicht angefasst.' 'Hinweis'; break }
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
            } catch { $m = $_.Exception.Message; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }; $r.Detail = $m; $r.Status = 'Fehler: von Microsoft abgelehnt, später nochmal versuchen (Details im Protokoll)' }
            & $hrow $r
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
                    elseif ($s2 -eq 'error') { $r.Status = 'Fehler: Import abgelehnt (' + [string]$st.state.deviceErrorName + ')'; $r.Detail = [string]$st.state.deviceErrorName + ' (' + [string]$st.state.deviceErrorCode + ')' }
                    if ($s2 -in 'complete', 'error') {
                        try { Microsoft.PowerShell.Utility\Invoke-RestMethod -Method DELETE -Uri ($GB + '/importedWindowsAutopilotDeviceIdentities/' + $r.ImpId) -Headers $h | Out-Null } catch { }
                        & $hrow $r
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
                & $hlog ('' + $moved.Count + ' erledigte Zeile(n) nach hashes-erledigt.csv verschoben') 'OK' $erl
            } catch { & $hlog ('Datei ' + $f + ' konnte nicht aktualisiert werden. Ist sie in Excel offen?') 'Fehler' $_.Exception.Message }
        }
        & $refresh
        $ok = @($script:HRows | Where-Object { $_.Done }).Count
        & $hlog ('Fertig: ' + $ok + ' von ' + @($script:HRows).Count + ' erledigt.') $(if ($ok -eq @($script:HRows).Count) { 'OK' } else { 'Hinweis' })
        Out-Log ('Hashes importiert: ' + $ok + ' von ' + @($script:HRows).Count) $(if ($ok -eq @($script:HRows).Count) { 'OK' } else { 'Hinweis' })
        Set-Step 'Hash' $(if ($ok -eq @($script:HRows).Count) { 'ok' } else { 'warn' }) ('' + $ok + ' von ' + @($script:HRows).Count + ' erledigt')
    }
    $g.bImp.Add_Click({
        if ($hst.Busy) { return }
        $hst.Busy = $true; $hst.Abort = $false; $hst.CloseAfter = $false
        $g.bImp.IsEnabled = $false; $g.bAdd.IsEnabled = $false; $g.bClose.Content = 'Abbrechen'
        Set-Step 'Hash' 'run'
        try { & $doImport }
        catch { & $hlog 'Import unerwartet abgebrochen.' 'Fehler' $_.Exception.Message; Set-Step 'Hash' 'err' $_.Exception.Message }
        finally {
            $hst.Busy = $false
            $g.bImp.IsEnabled = $true; $g.bAdd.IsEnabled = $true; $g.bClose.Content = 'Schließen'
            if ($hst.CloseAfter) { [void]$hw.Dispatcher.BeginInvoke([action]{ $hw.Close() }) }
        }
    })
    $hw.Add_ContentRendered({ Set-GridWindowWidth $hw $g.dGrid 760 })
    [void]$hw.ShowDialog()
}
$ui.bHash.Add_Click({ Show-HashImport })

# ---------- Hauptknopf: Stick fertig machen (alle Schritte, Abbruch beim ersten echten Fehler mit Meldung in Klartext) ----------
function Stop-Ready([string]$Step, [string]$Msg, [switch]$Quiet) {
    if ($Step) { Set-Step $Step $(if ($Quiet) { 'open' } else { 'err' }) $Msg }
    Set-Step 'Ready' $(if ($Quiet) { 'open' } else { 'err' }) $Msg
    $first = @($Msg -split "`r?`n" | Where-Object { $_.Trim() })[0]
    $ui.tReady.Text = $(if ($Quiet) { 'Abgebrochen: ' } else { 'Nicht fertig: ' }) + $first + '  (' + (Get-Date -Format 'HH:mm') + ')'
    Out-Log ('Stick nicht fertig: ' + ($Msg -replace "`r?`n", ' ')) $(if ($Quiet) { '' } else { 'Fehler' })
    if (-not $Quiet) { Show-Msg $Msg 'HUPilot - Stick nicht fertig' 'Warning' }
}
function Invoke-StickReadyCore {
    $nl = "`r`n"
    $warn = @()
    foreach ($s in 'Test', 'Tags', 'Write', 'Copy') { Set-Step $s 'open' }
    if (-not $script:PkgBuildErr) { Set-Step 'Pkg' 'open' }
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
        try { $tr = Get-TagReport @{ Authorization = 'Bearer ' + $tok } }
        catch { $tr = @{ Rows = @(); Bad = @(); GErr = $false; Info = ''; Error = ('Tags nicht prüfbar: ' + $_.Exception.Message) } }
        if ($tr.Error) { Set-Step 'Tags' 'warn' $tr.Error; $warn += ('Tags nicht geprüft: ' + $tr.Error) }
        elseif ($tr.Bad.Count) { $t = 'Tag(s) ohne Autopilot-Profil: ' + (($tr.Bad | ForEach-Object { $_.Tag }) -join ', '); Set-Step 'Tags' 'warn' $t; $warn += ($t + ' - Geräte mit diesem Tag bekommen kein Profil') }
        elseif ($tr.GErr) { Set-Step 'Tags' 'warn' 'Gruppen nicht lesbar'; $warn += 'Tags nur teilweise geprüft (Group.Read.All fehlt)' }
        else { Set-Step 'Tags' 'ok' }
    }
    # 5. Speichern
    if (-not (Save-Cfg)) { Stop-Ready 'Write' ('Speichern fehlgeschlagen:' + $nl + $script:FieldErr); return }
    # 6. WLAN-Paket nur bauen, wenn es fehlt oder veraltet ist
    $ps = Update-PkgState
    if ($ps -in 'fehlt', 'veraltet', 'unbekannt') {
        if (Test-Path $icd) {
            Out-Log ('WLAN-Paket ' + $ps + ', wird jetzt gebaut')
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
    Out-Log ('Stick ' + $dr + ' ist fertig und kontrolliert' + $(if ($warn.Count) { ', mit Hinweisen' } else { '' })) $(if ($warn.Count) { 'Hinweis' } else { 'OK' })
    Show-Msg ('Stick ' + $dr + ' ist fertig und kontrolliert.' + $(if ($warn.Count) { $nl + $nl + 'Hinweise:' + $nl + (($warn | ForEach-Object { '- ' + $_ }) -join $nl) } else { '' }) + $nl + $nl + 'Der Stick kann jetzt abgezogen werden.') 'HUPilot - Stick fertig' $(if ($warn.Count) { 'Warning' } else { 'Information' })
}
function Invoke-StickReady {
    if ($script:Busy) { return }
    Set-UiBusy $true
    try { Invoke-StickReadyCore }
    catch { Stop-Ready '' ('Unerwarteter Fehler: ' + $_.Exception.Message) }
    finally { Set-UiBusy $false }
}
$ui.bReady.Add_Click({ Invoke-StickReady })

# Schliessen: Rueckfrage bei ungespeicherten Aenderungen (nie im Starttest, nicht beim Update-Neustart)
$script:NoClosePrompt = $false
$win.Add_Closing({
    param($s, $e)
    if ($SmokeTest) { return }
    # Laufender Vorgang geht vor allem anderen (auch vor dem Update-Neustart)
    if ($script:Busy) { $e.Cancel = $true; Show-Msg 'Ein Vorgang läuft noch (Stick fertig machen, Kopieren oder Paketbau). Bitte warten, bis er fertig ist.' 'HUPilot-Setup'; return }
    if ($script:NoClosePrompt) { return }
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
    try { [pscustomobject]@{ Key = $key } | ConvertTo-Json | Set-Content -LiteralPath $seen -Encoding UTF8 -ErrorAction Stop } catch { Out-Log 'Merker für den Update-Hinweis nicht schreibbar, der Hinweis kommt beim nächsten Start nochmal.' 'Hinweis' $_.Exception.Message }
    $ver = 'v' + $SetupVer
    $nl = [Environment]::NewLine
    $t = 'HUPilot ist jetzt auf ' + $ver + '.' + $nl + $nl
    if ($srcDrive) { $t += 'Dieser Stick (' + $srcDrive + ') ist schon aktualisiert. Alle ANDEREN Sticks haben noch die alte Version.' + $nl + $nl }
    else { $t += 'Die USB-Sticks haben noch die alte Version.' + $nl + $nl }
    $t += 'Jeden Stick neu bespielen:' + $nl + '   1. Stick anstecken' + $nl + '   2. bei "Stick" auswählen (ggf. "Aktualisieren")' + $nl + '   3. "Stick fertig machen" (oder "5. Auf Stick kopieren") klicken' + $nl + $nl + 'config.json und WLAN-Paket kommen dabei mit.'
    Out-Log ('Update auf ' + $ver + ' fertig. Jetzt jeden Stick mit "Stick fertig machen" neu bespielen.') 'Hinweis'
    Show-Msg $t 'HUPilot - Update fertig: auf Stick kopieren'
}
if ($SmokeTest) {
    # Starttest (automatische Tests): Fenster oeffnen, 2 s laufen lassen, schliessen - kein Netzwerk
    $script:SmokeOk = $false
    $tm = New-Object System.Windows.Threading.DispatcherTimer
    $tm.Interval = [TimeSpan]::FromSeconds(2)
    $tm.Add_Tick({
        $tm.Stop()
        # beide Themes einmal anzeigen, dann zurueck
        $t0 = $script:HuTheme
        foreach ($th in @($(if ($t0 -eq 'hell') { 'dunkel' } else { 'hell' }), $t0)) { Set-HuTheme $th; $win.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Render) }
        $script:SmokeOk = $win.IsLoaded
        $win.Close()
    })
    $win.Add_ContentRendered({ $tm.Start() })
} else {
    $win.Add_ContentRendered({ Show-UpdateStickHint; Invoke-UpdateCheck -Quiet })
}
[void]$win.ShowDialog()
if ($SmokeTest) { try { Set-Content -LiteralPath $SmokeTest -Value $(if ($script:SmokeOk) { 'OK v' + $SetupVer } else { 'FEHLER: Fenster nicht geladen' }) -Encoding UTF8 } catch { } }
Start-Log 'Fenster geschlossen'
try { $script:Mutex.ReleaseMutex() } catch { }
