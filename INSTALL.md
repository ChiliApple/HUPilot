# Installation

## 1. App-Registrierung (je Tenant)
Entra > App-Registrierungen > **Neue Registrierung** > Name `HUPilot-Upload`, nur dieses Verzeichnis, keine Umleitungs-URI
- API-Berechtigungen > Microsoft Graph > **Anwendung** > `DeviceManagementServiceConfig.ReadWrite.All` > **Administratorzustimmung**. Reicht auch für *Tag ändern* und *Autopilot-Sync anstoßen* im Status-Fenster.
- optional (nur Lesen): `Application.Read.All` für den Ablauf des Secrets (Setup und Hinweis am Gerät); `DeviceManagementManagedDevices.Read.All` für primären Benutzer, Gerätename, letzten Sync bei *Status*; `Group.Read.All` für die Tag-Prüfung (Gerät und *Tags prüfen*); `User.Read.All` für die Prüfung des Benutzers bei Vorab-Zuweisung
- optional (Schreiben): `DeviceManagementManagedDevices.ReadWrite.All`: go kann Geräte nach einem **Mainboardtausch** neu registrieren (löscht den alten Intune-Eintrag, ersetzt `DeviceManagementManagedDevices.Read.All`)
- Zertifikate & Geheimnisse > neues Secret, kurz gültig > den **Wert** kopieren

## 2. Stick / Quelle
`Stick\` auf den Stick oder in einen Vorbereitungsordner kopieren (z. B. je Schule einer), `HUPilot-Setup.cmd` starten.
Das Setup arbeitet immer mit dem Ordner, aus dem es läuft: laden, speichern, WLAN-Paket bauen. *Stick fertig machen* und *Auf Stick kopieren* kopieren ihn 1:1 auf den gewählten Stick (ohne `logs` und `_`-Ordner) und kontrollieren die Dateien.
Vom PC aus: *Sticks vorbereiten* formatiert und befüllt mehrere USB-Sticks, der Pin-Knopf oben rechts legt eine Desktop-Verknüpfung an.

| config.json | |
|---|---|
| `Tenant`, `TenantId`, `ClientId`, `ClientSecret` | Tenant und App |
| `SecretExpires` | Ablauf des Secrets (UTC), schreibt das Setup selbst, nicht von Hand ändern |
| `GroupTag`, `TagChoices`, `TagPattern` | Standard-Tag, Auswahl (max. 9, leer = keine Tag-Frage am Gerät), erlaubtes Muster |
| `WlanSsid`, `WlanKey`, `WlanPackage` | Konfigurations-WLAN; Paketname (leer = ohne, z. B. nur LAN) |
| `Reset`, `MinBattery` | Standard "zurücksetzen", Mindest-Akku ohne Netzteil (50) |
| `AskUser` | am Gerät nach Benutzer (UPN) fragen und vorab zuweisen (true/false) |
| `RemoveApps` | Regex auf App-Namen, die vor dem Zurücksetzen entfernt werden (Standard `McAfee`, leer = aus) |
| `RemoveOtherPackages` | fremde Bereitstellungspakete beim Zurücksetzen entfernen (Standard false, noch im Test); sie werden vorher nach `C:\Recovery\HUPilot-PPKG-Backup\<Datum>` gesichert |
| `AdminName`, `AdminPassword` | optional lokaler Admin (leer = keiner), kommt mit dem WLAN-Paket |
| `Admin2Name`, `Admin2Password` | optional zweiter lokaler Admin, z. B. Elternverein (leer = keiner) |
| `EditionKey` | optional MAK für Windows Pro (Home auf Pro umstellen, leer = aus). Das Setup fragt beim Kopieren, ob er auf den Stick soll |

**Kein** `.ppkg` ins Hauptverzeichnis des Sticks legen.

## 3. WLAN-Paket
*WLAN-Paket bauen* braucht das **Windows ADK** mit *Imaging and Configuration Designer* (`ICD.exe`). Das Setup merkt sich, für welches WLAN und welche Admins das Paket gebaut ist, und zeigt "aktuell" oder "veraltet".
Ohne ADK: `Tools\New-WcdProjekt.ps1`, in WCD öffnen, als `HUPilot-WLAN.ppkg` exportieren (das Setup zeigt dann "unbekannt").

### Paketbau mit auf den Stick (Test)
Damit auch ein PC ohne ADK Pakete bauen kann, nimmt das Setup an einem PC mit ADK den Paketbau mit auf den Stick (rund 78 MB):
1. Setup am PC mit ADK starten und in der Zeile *Stick* das Häkchen *Paketbau mit auf den Stick* setzen (wird gemerkt).
2. *Stick fertig machen*, *5. Auf Stick kopieren* oder *Sticks vorbereiten* klicken. Das Setup sieht nach, was am Stick schon liegt, und kopiert nur, was fehlt oder veraltet ist. Läuft das Setup direkt vom Stick, holt das Häkchen den Paketbau sofort auf diesen Stick.
3. Am PC ohne ADK das Setup vom Stick starten und *4. WLAN-Paket bauen* klicken. Das Protokoll nennt, welche `ICD.exe` benutzt wird.

Die Kopie liegt in `HUPilot\ADK-ICD`, daneben die Prüfliste `HUPilot-ICD.json`. Vor jedem Bau prüft das Setup Prüfsummen, fremde Dateien und die Signaturen, sonst baut es nicht: Jede Programmdatei braucht eine gültige Signatur von Microsoft, nur die schon im Original unsignierten Dateien sind über ihre im Setup hinterlegte Prüfsumme erlaubt. Das schützt vor beschädigten oder zufällig veränderten Dateien und vor fremden Programmdateien. Wer den Stick gezielt verändern kann, kann auch das Setup selbst ändern, deshalb den Stick nicht aus der Hand geben. Das Setup kennt derzeit ICD 10.0.28000.1, andere Versionen werden abgelehnt. Updates und das Repo lassen den Ordner unberührt. Ohne Häkchen bleibt eine Kopie am Stick, entfernt wird sie nur über den Rechtsklick auf das Häkchen (*Kopie entfernen ...*).

Das Windows ADK gehört Microsoft und wird **nicht** mit HUPilot ausgeliefert. Die Kopie ist immer die eigene des Anwenders und nur für den eigenen Gebrauch. Geprüft mit ICD 10.0.28000.1 unter Windows 11 ohne ADK. Mit einem echten Stick an einem fremden PC, mit lokalen Admins im Paket und mit älteren ADK-Versionen noch nicht.
Das Paket enthält nur das WLAN und optional die lokalen Admins, kein CleanPC, kein BPRT, kein HideOobe.
Sperrt Intune Bereitstellungspakete (`AllowAddProvisioningPackage = 0`), kann go.ps1 an bereits eingerichteten Geräten kein neues Paket installieren, das vorhandene bleibt.

## 4. Intune
- Dynamische Gerätegruppe je Tag: `(device.devicePhysicalIds -any (_ -eq "[OrderID]:SN-2026"))` und Autopilot-Profil
- Empfohlen: Kontoeinrichtung überspringen, benutzerdefiniertes Profil an die Gerätegruppen,
  OMA-URI `./Vendor/MSFT/DMClient/Provider/MS DM Server/FirstSyncStatus/SkipUserStatusPage`, Boolesch, `True`
- Später per Wartung: Config-WLAN, WLAN-Paket und `C:\Recovery\HUPilot-OEM-Backup` entfernen

## Fehlersuche
- Updates: Knopf *Update* im Setup (prüft beim Start online). Klick startet `HUPilot\Setup\Pull.ps1`: lädt das Release, prüft Prüfsumme und Signatur, ersetzt erst dann. Rechtsklick: Vorversion, Kanal Stabil/Test.
- Erstinstallation ohne Stick: `Pull.ps1` aus dem Repo laden und ausführen (`powershell -ExecutionPolicy Bypass -File Pull.ps1`), legt `Desktop\HUPilot` an
- Logs: Gerät `C:\Windows\Temp\HUPilot.log` und `HUPilot-Wipe.log`, Stick `HUPilot\logs\`, Setup `HUPilot\logs\setup_<Datum>.log` (die letzten 20)
- Am Gerät: `D:\diag`, Diagnose-Menü zum Abfotografieren (ändert nichts), *7* speichert alles am Stick
- Setup startet nicht: `C:\Users\Public\HUPilot-Setup-Start.log`
