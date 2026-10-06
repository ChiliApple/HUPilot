# Installation

## 1. App-Registrierung (je Tenant)
Entra › App-Registrierungen › **Neue Registrierung** › Name `HUPilot-Upload`, nur dieses Verzeichnis, keine Umleitungs-URI
- API-Berechtigungen › Microsoft Graph › **Anwendung** › `DeviceManagementServiceConfig.ReadWrite.All` › **Administratorzustimmung**
- optional (nur Lesen): `Application.Read.All` → Secret-Ablauf; `DeviceManagementManagedDevices.Read.All` → primärer Benutzer, Gerätename, letzter Sync bei *Status*; `Group.Read.All` → Tag-Prüfung (Gerät + *Tags prüfen*); `User.Read.All` → Benutzer prüfen bei Vorab-Zuweisung
- Zertifikate & Geheimnisse › neues Secret, kurz gültig › den **Wert** kopieren

## 2. Stick / Quelle
`Stick\` auf den Stick oder in einen Vorbereitungsordner kopieren (z. B. je Schule einer), `HUPilot-Setup.cmd` starten.
Das Setup arbeitet immer mit dem Ordner, aus dem es läuft: laden, speichern, WLAN-Paket bauen; *Auf Stick kopieren* kopiert ihn 1:1 (ohne `logs` und `_`-Ordner).

| config.json | |
|---|---|
| `Tenant`, `TenantId`, `ClientId`, `ClientSecret` | Tenant und App |
| `GroupTag`, `TagChoices`, `TagPattern` | Standard-Tag, Auswahl (max. 9), erlaubtes Muster |
| `WlanSsid`, `WlanKey`, `WlanPackage` | Konfigurations-WLAN; Paketname (leer = ohne, z. B. nur LAN) |
| `Reset`, `MinBattery` | Standard „zurücksetzen“, Mindest-Akku ohne Netzteil (50) |
| `AskUser` | am Gerät nach Benutzer (UPN) fragen und vorab zuweisen (true/false) |
| `AdminName`, `AdminPassword` | optional lokaler Admin (leer = keiner), kommt mit dem WLAN-Paket |

**Kein** `.ppkg` ins Hauptverzeichnis des Sticks legen.

## 3. WLAN-Paket
*WLAN-Paket bauen* braucht das **Windows ADK** mit *Imaging and Configuration Designer* (`ICD.exe`).
Ohne ADK: `Tools\New-WcdProjekt.ps1` → in WCD öffnen → als `HUPilot-WLAN.ppkg` exportieren.
Das Paket enthält nur das WLAN und optional den lokalen Admin – kein CleanPC, kein BPRT, kein HideOobe.
Sperrt Intune Bereitstellungspakete (`AllowAddProvisioningPackage = 0`), kann go.ps1 an bereits eingerichteten Geräten kein neues Paket installieren – das vorhandene bleibt.

## 4. Intune
- Dynamische Gerätegruppe je Tag: `(device.devicePhysicalIds -any (_ -eq "[OrderID]:SN-2026"))` + Autopilot-Profil
- Empfohlen: Kontoeinrichtung überspringen – benutzerdefiniertes Profil an die Gerätegruppen,
  OMA-URI `./Vendor/MSFT/DMClient/Provider/MS DM Server/FirstSyncStatus/SkipUserStatusPage`, Boolesch, `True`
- Später per Wartung: Config-WLAN + WLAN-Paket und `C:\Recovery\HUPilot-OEM-Backup` entfernen

## Fehlersuche
- Updates: Knopf *Update* im Setup (prüft beim Start online)
- Logs: Gerät `C:\Windows\Temp\HUPilot.log` und `HUPilot-Wipe.log`, Stick `HUPilot\logs\`
- `Tools\Diagnose.cmd` im OOBE (ändert nichts)
- Setup startet nicht: `C:\Users\Public\HUPilot-Setup-Start.log`
