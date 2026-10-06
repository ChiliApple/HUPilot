# Changelog

## v2.2 - 2026-10-06
- go.ps1: Schutz – hat das Gerät Benutzerprofile oder läuft nicht im Einrichtungsbildschirm, rote Rückfrage (`LOESCHEN` eintippen)
- go.ps1: Strom – ohne Netzteil und unter `MinBattery` % (Standard 50) wartet es vor dem Zurücksetzen auf das Netzteil
- Setup: *5. Status* – alle Autopilot-Geräte mit Tag, Profil, Intune-Registrierung, letztem Kontakt und Eintrag aus `protokoll.csv`; Filter, CSV, Drucken
- Setup: *Verbindung testen* zeigt den Ablauf des Secrets (optional `Application.Read.All`)
- Setup: Version in der Titelleiste, Startprotokoll, nur eine Instanz, sichtbarer Start
- Doku gekürzt

## v2.1 - 2026-10-05
### Neu
- Setup arbeitet immer mit seiner **Quelle** (Ordner, aus dem es läuft – Stick oder Vorbereitungsordner am PC): *Neu laden*, *Speichern*, *WLAN-Paket bauen* dort; *Auf Stick kopieren* kopiert die Quelle 1:1 (ohne logs)
- Setup reist mit dem Stick: `HUPilot-Setup.cmd` im Stick-Hauptverzeichnis, Oberfläche + WCD-Vorlage in `HUPilot\Setup\`; vom Stick gestartet ist der Stick vorausgewählt und die `config.json` geladen; *Stick schreiben* auf einen anderen Stick klont alles
- Beim Start: *Nach dem Upload zurücksetzen?* – Enter = Standard aus `config.json` (`Reset`, Standard ja), `N` = nur hochladen, `J` = zurücksetzen. Nur Upload: grün „HOCHGELADEN“, Gerät bleibt unverändert, Eintrag im Protokoll
- `HUPilot-Setup`: Secret verdeckt (anzeigen per Haken), zusätzliche Felder der `config.json` bleiben beim Schreiben erhalten

## v2.0 - 2026-10-05
### Erste öffentliche Version
- `go.ps1`: Autopilot-Import mit Group Tag aus dem OOBE (Graph API), WLAN-Verbindung, Tag-Auswahl beim Start, grün „STICK ABZIEHEN“, Warten auf Profilzuweisung
- Ist das Gerät schon in Autopilot: kein Import, nur Tag prüfen/setzen; nach einer Tag-Änderung wird auf das Profil der neuen Gruppe gewartet
- Zurücksetzen ohne Hersteller-Programme: `C:\Recovery\Customizations` wird nach `C:\Recovery\HUPilot-OEM-Backup` verschoben, dann RemoteWipe `doWipePersistProvisionedData` als SYSTEM (geplante Aufgabe)
- Nur ein WLAN-Paket (kein CleanPC): bleibt beim Zurücksetzen erhalten, Einrichtungsbildschirm verbindet danach selbst
- Schutz: gespeicherte Pakete mit CleanPC werden vor dem Zurücksetzen entfernt
- `Tools\HUPilot-Setup.cmd`: Oberfläche – Verbindung testen, Stick schreiben, WLAN-Paket per ICD-Kommandozeile bauen
- `Tools\New-WcdProjekt.ps1`: WCD-Projekt aus der Vorlage mit eigenem WLAN
- `Tools\Diagnose.cmd`: Diagnose im OOBE (ändert nichts)
### Warum kein CleanPC
- Ein Paket mit CleanPC wird in `ProgramData\Microsoft\Provisioning` gespeichert und nach jedem Zurücksetzen erneut angewendet – das Gerät setzt sich endlos zurück (getestet)
