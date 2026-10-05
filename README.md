<h1 align="center">HUPilot</h1>

<p align="center"><b>Windows Autopilot per USB-Stick – Hash hochladen, Group Tag setzen, ohne Hersteller-Programme zurücksetzen</b><br>
Neues Gerät einschalten, Stick anstecken, <code>D:\go</code> – nach einer Minute Stick abziehen, nächstes Gerät.<br>
Gedacht für ganze Klassensätze: 20–30 Notebooks in einer Schulstunde, ohne CSV und ohne Admin am Gerät.</p>

<p align="center">
  <a href="https://github.com/ChiliApple/HUPilot/releases/latest"><img src="https://img.shields.io/github/v/release/ChiliApple/HUPilot?label=Version&color=b9a88a" alt="Version"></a>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011%20Pro%20%7C%20Education%20%7C%20Enterprise-0078D6" alt="Windows 10 | 11 Pro | Education | Enterprise">
  <img src="https://img.shields.io/badge/Intune-Autopilot-2E7D32" alt="Intune Autopilot">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Lizenz-Nutzung%20frei-orange" alt="Lizenz"></a>
</p>

<p align="center">
  <a href="INSTALL.md"><b>Installation</b></a> ·
  <a href="CHANGELOG.md">Änderungen</a> ·
  <a href="LICENSE">Lizenz</a>
</p>

---

| | |
|---|---|
| **Autopilot-Import** | Hardware-Hash direkt aus dem OOBE in den Tenant (Graph API) – mit **Group Tag**, ohne CSV. Ist das Gerät schon registriert, wird nur der Tag geprüft und gesetzt |
| **Group Tag wählbar** | Standard aus `config.json`, beim Start 10 s Auswahl (z. B. Jahrgänge) – ohne Eingabe läuft es von selbst weiter |
| **WLAN** | verbindet selbst mit dem Konfigurations-WLAN, falls noch kein Internet |
| **Stick abziehbar** | sobald der Upload fertig ist: **grün „STICK ABZIEHEN“** – der Rest läuft ohne Stick |
| **Profil abwarten** | setzt erst zurück, wenn das Autopilot-Profil zugewiesen ist (nach einer Tag-Änderung: das Profil der neuen Gruppe) |
| **Ohne Hersteller-Programme** | vor dem Zurücksetzen werden die Hersteller-Anpassungen (`C:\Recovery\Customizations`) weggeschoben, dann *Alles entfernen* über den RemoteWipe-Befehl `doWipePersistProvisionedData` – das WLAN-Paket bleibt dabei erhalten |
| **Sicher** | jeder Fehler vor dem Zurücksetzen → **rot**, Gerät bleibt unverändert im OOBE; Logs am Gerät und am Stick, `protokoll.csv` je Stick |

## Schnellstart

1. **App-Registrierung** im Tenant mit `DeviceManagementServiceConfig.ReadWrite.All` (Anwendung) und kurz gültigem Secret – [INSTALL.md](INSTALL.md#1-app-registrierung)
2. **Stick + WLAN-Paket:** `Tools\HUPilot-Setup.cmd` (Oberfläche) – Daten eintragen → *Verbindung testen* → *Stick schreiben* → *WLAN-Paket bauen* (braucht Windows ADK)
   – oder von Hand: [INSTALL.md](INSTALL.md#2-stick-vorbereiten)
4. Am Gerät im ersten Einrichtungsbildschirm: **Shift+F10** → `D:\go`

## Ablauf am Gerät

| Farbe | Bedeutung |
|---|---|
| **Cyan** | Group Tag wählen (Enter / Ziffer) und *zurücksetzen ja/nein* (Enter / N) – je 10 s, dann Standard |
| **Grün** | Upload fertig – **Stick abziehen**, Gerät wartet auf das Profil und setzt sich dann selbst zurück |
| **Gelb** | Profil nach 20 Min noch nicht zugewiesen – `J` trotzdem zurücksetzen, `N` abbrechen |
| **Blau** | Zurücksetzen startet |
| **Rot** | Fehler – **nichts** zurückgesetzt, Grund steht am Bildschirm und im Log. Nochmal: `D:\go` |

Danach: Windows setzt sich ohne die Hersteller-Programme zurück, wendet das WLAN-Paket wieder an und zeigt die Autopilot-Anmeldung.

## Aufbau

```
Stick:\
├── go.cmd
└── HUPilot\
    ├── go.ps1
    ├── config.json            (aus config.example.json – Secret, nie ins Repo)
    ├── HUPilot-WLAN.ppkg      (selbst gebaut – enthält das WLAN-Kennwort)
    └── logs\                  (automatisch: <Seriennr>_<Zeit>.log, protokoll.csv)
```

| Ordner im Repo | Inhalt |
|---|---|
| `Stick\` | Dateien für den Stick |
| `WCD-Vorlage\` | WCD-Projekt *nur WLAN* mit Platzhaltern |
| `Tools\HUPilot-Setup.cmd` | Oberfläche: Verbindung testen, Stick schreiben, WLAN-Paket per `ICD.exe` bauen |
| `Tools\New-WcdProjekt.ps1` | setzt WLAN-Name/-Kennwort aus `config.json` in die Vorlage ein |
| `Tools\Diagnose.cmd` | Diagnose im OOBE (ändert nichts) |

## Voraussetzungen und Grenzen

- **Windows Pro, Education oder Enterprise** (RemoteWipe-CSP), Home → rot, kein Zurücksetzen
- Vom Hersteller vorinstallierte **Store-Apps** stellt Windows beim Zurücksetzen trotzdem wieder her (Microsoft: *Push-button reset*) – bei Bedarf per Intune entfernen
- Die Hersteller-Anpassungen bleiben in `C:\Recovery\HUPilot-OEM-Backup` (Platz, z. B. ~4 GB) – zurück verschieben stellt den Werkszustand wieder her
- **Kein CleanPC-Paket verwenden:** Windows speichert angewendete Pakete und wendet sie nach jedem Zurücksetzen erneut an – CleanPC setzt dann endlos zurück
- Microsoft Intune mit Windows Autopilot, dynamische Gruppen nach Group Tag (`[OrderID]:<Tag>`), Profil je Gruppe zugewiesen
- Das Gerät darf in keinem anderen Tenant registriert sein (sonst rot: *anderer Tenant*)
- Import dauert erfahrungsgemäß 2–5 Min, die Profilzuweisung 5–15 Min – mehrere Geräte laufen parallel, ein Stick reicht
- Das Konfigurations-WLAN bleibt nach dem Zurücksetzen am Gerät – später per Intune entfernen

## Sicherheit

Die App-Berechtigung `DeviceManagementServiceConfig.ReadWrite.All` gibt es nur als Lesen **und** Schreiben – wer das Secret hat, kann Intune-Registrierungseinstellungen ändern (Autopilot-Geräte, Profile, Registrierungsbeschränkungen). Deshalb:

- Secret **kurz gültig** (z. B. 7–14 Tage), vor jedem Einsatz neu erstellen, alte löschen
- App nur mit dieser einen Berechtigung, Stick nicht aus der Hand geben
- Anmeldungen der App prüfen: Entra ID › Anmeldeprotokolle › Dienstprinzipal-Anmeldungen

---

**Lizenz:** kostenlose Nutzung erlaubt, Veränderung und Weitergabe veränderter Fassungen nicht – Details in [LICENSE](LICENSE) (deutsch und englisch).
*License: free to use, modification and redistribution of modified versions not permitted – see [LICENSE](LICENSE) (German and English).*
