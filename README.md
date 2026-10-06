<h1 align="center"><img src="Assets/logo64.png" width="44" alt="" align="absmiddle"/> HUPilot</h1>

<p align="center"><b>Windows Autopilot per USB-Stick</b><br>
Hash mit Group Tag hochladen, Gerät ohne Hersteller-Programme zurücksetzen – <code>Shift+F10</code> → <code>D:\go</code>.</p>

<p align="center">
  <a href="https://github.com/ChiliApple/HUPilot/releases/latest"><img src="https://img.shields.io/github/v/release/ChiliApple/HUPilot?label=Version&color=b9a88a" alt="Version"></a>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/Windows-Pro%20%7C%20Education%20%7C%20Enterprise-0078D6" alt="Windows">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Lizenz-Nutzung%20frei-orange" alt="Lizenz"></a>
</p>

<p align="center"><a href="INSTALL.md"><b>Installation</b></a> · <a href="CHANGELOG.md">Änderungen</a> · <a href="LICENSE">Lizenz</a></p>

---

## Ablauf am Gerät

1. Neues Gerät im ersten Einrichtungsbildschirm, Stick anstecken, **Shift+F10** → `D:\go`
2. Tag wählen und „zurücksetzen ja/nein“ (je 10 s, sonst Standard)
3. Upload → **grün „STICK ABZIEHEN“** → nächstes Gerät
4. Gerät wartet auf das Autopilot-Profil und setzt sich selbst zurück → Autopilot-Anmeldung

| Farbe | Bedeutung |
|---|---|
| Grün | Upload fertig, Stick abziehen |
| Gelb | Netzteil fehlt / Profil noch nicht zugewiesen |
| Blau | Zurücksetzen startet |
| Rot | Fehler – **nichts** zurückgesetzt. Nochmal: `D:\go` |

## Vorbereitung

1. App-Registrierung `HUPilot-Upload` – [INSTALL.md](INSTALL.md)
2. `Stick\` auf Stick oder in einen Ordner kopieren, **`HUPilot-Setup.cmd`** starten:
   *Verbindung testen* → *Speichern* → *WLAN-Paket bauen* → *Auf Stick kopieren* · *Status* zeigt danach, welche Geräte fertig sind

## Gut zu wissen

- Zurücksetzen ohne Hersteller-Programme: `C:\Recovery\Customizations` wird weggeschoben, dann *Alles entfernen* (RemoteWipe `doWipePersistProvisionedData`). Hersteller-Store-Apps kann Windows trotzdem wiederherstellen.
- **Kein CleanPC-Paket verwenden** – Windows wendet gespeicherte Pakete nach jedem Zurücksetzen erneut an (Endlosschleife).
- Schutz: Gerät mit Benutzerprofil → rote Rückfrage; ohne Netzteil und unter 50 % Akku → wartet.
- Secret kurz gültig halten, Stick nicht aus der Hand geben (`DeviceManagementServiceConfig.ReadWrite.All` gibt es nur mit Schreibrecht).

---

**Lizenz:** kostenlose Nutzung erlaubt, Veränderung und Weitergabe veränderter Fassungen nicht – [LICENSE](LICENSE).
