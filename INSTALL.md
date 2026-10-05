# Installation

## 1. App-Registrierung
Entra Admin Center › App-Registrierungen › **Neue Registrierung**
1. Name z. B. `HUPilot-Upload`, *Nur Konten in diesem Organisationsverzeichnis*, keine Umleitungs-URI
2. **API-Berechtigungen** › Microsoft Graph › **Anwendungsberechtigungen** › `DeviceManagementServiceConfig.ReadWrite.All` › **Administratorzustimmung erteilen** – keine weiteren Berechtigungen
3. **Zertifikate & Geheimnisse** › Neuer geheimer Clientschlüssel › Ablauf kurz wählen › den **Wert** kopieren (nicht die Geheimnis-ID)
4. Anwendungs-(Client-)ID und Verzeichnis-(Mandanten-)ID notieren

## 2. Stick vorbereiten
**Am einfachsten:** `Tools\HUPilot-Setup.cmd` starten (fragt nach Adminrechten) – Felder ausfüllen, *Verbindung testen*, *Stick schreiben*, *WLAN-Paket bauen*. Das Paket wird mit `ICD.exe` aus dem **Windows ADK** gebaut; ohne ADK: Schritt 3 von Hand.

Von Hand:
1. Inhalt von `Stick\` ins Hauptverzeichnis des Sticks kopieren (`go.cmd` und Ordner `HUPilot\`)
2. `HUPilot\config.example.json` nach `HUPilot\config.json` kopieren und ausfüllen:

| Feld | Inhalt |
|---|---|
| `Tenant` | Anzeigename (nur für Log/Protokoll) |
| `TenantId`, `ClientId`, `ClientSecret` | aus Schritt 1 |
| `GroupTag` | Standard-Tag (Enter / nach 10 s) |
| `TagChoices` | Auswahl beim Start, max. 9 Einträge |
| `TagPattern` | erlaubte Tags (Regex), optional |
| `WlanSsid`, `WlanKey` | Konfigurations-WLAN (WPA2-Personal) – zum Hochladen |
| `WlanPackage` | Name des WLAN-Pakets im Ordner `HUPilot\` (Standard `HUPilot-WLAN.ppkg`, leer = ohne) |

3. **Keine** `.ppkg`-Datei ins Hauptverzeichnis des Sticks legen – Windows kann ein Paket dort im OOBE von selbst anwenden.

## 3. WLAN-Paket bauen (Windows Configuration Designer)
Das Paket enthält **nur** das Konfigurations-WLAN. go.ps1 wendet es vor dem Zurücksetzen an; Windows behält es beim Zurücksetzen (*doWipePersistProvisionedData*) und verbindet danach im Einrichtungsbildschirm von selbst.
1. WCD installieren (Microsoft Store oder Windows ADK)
2. `powershell -ExecutionPolicy Bypass -File Tools\New-WcdProjekt.ps1` – liest WLAN-Name und -Kennwort aus `config.json` am Stick (oder fragt nach) und erzeugt `WCD-Projekt\HUPilot-WLAN\`
   (ohne Script: in `WCD-Vorlage\HUPilot-WLAN\customizations.xml` die Platzhalter `WLAN-NAME` und `WLAN-KENNWORT` mit einem Editor ersetzen)
3. WCD › **Projekt öffnen** › `HUPilot-WLAN.icdproj.xml` › **Exportieren › Bereitstellungspaket** › ohne Verschlüsselung und Signatur
4. Paket als `HUPilot-WLAN.ppkg` nach `Stick:\HUPilot\` speichern

**Nicht** hinzufügen: **CleanPC** (Endlosschleife – das Paket wird nach jedem Zurücksetzen erneut angewendet), Bulk-Token (BPRT), *HideOobe*, Gerätename, lokale Konten, ProvisioningCommands.
Nur LAN, kein WLAN: in `config.json` `"WlanPackage": ""` setzen.

## 4. Intune
- Dynamische Gerätegruppe je Tag: `(device.devicePhysicalIds -any (_ -eq "[OrderID]:SN-2026"))`
- Autopilot-Bereitstellungsprofil der Gruppe zuweisen
- Registrierungsbeschränkung: private Windows-Geräte blockieren – Autopilot-Geräte gelten als Unternehmensgeräte

## 5. Secret erneuern
App-Registrierung › Zertifikate & Geheimnisse › neues Secret › in `config.json` aller Sticks eintragen › altes Secret löschen.

## Fehlersuche
- Log am Gerät: `C:\Windows\Temp\HUPilot.log`, am Stick: `HUPilot\logs\`
- `Tools\Diagnose.cmd` aufs Stick-Hauptverzeichnis kopieren und im OOBE starten
- *Secret ABGELAUFEN / FALSCH* → neues Secret (Wert, nicht ID)
- *anderer Tenant* → Gerät beim anderen Tenant/Händler aus Autopilot entfernen lassen
- Zurücksetzen startet nicht → `C:\Windows\Temp\HUPilot-Wipe.log` (läuft als SYSTEM über die geplante Aufgabe `HUPilot-Wipe`)
- Werkszustand mit Hersteller-Programmen zurück: Inhalt von `C:\Recovery\HUPilot-OEM-Backup\Customizations` nach `C:\Recovery\Customizations` verschieben
- Shift+F10 öffnet kein Fenster → Fn+Shift+F10 versuchen
