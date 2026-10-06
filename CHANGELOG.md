# Changelog

## v2.5 - 2026-10-06
- Setup: Online-Versionserkennung beim Start + Knopf **Update** (lädt nur geänderte Dateien, prüft Prüfsummen; `config.json`, WLAN-Paket, logs bleiben)
- go.ps1: erkennt die Intune-Sperre für Bereitstellungspakete (`AllowAddProvisioningPackage=0`) – vorhandenes WLAN-Paket bleibt, sonst Rückfrage; altes Paket wird nicht mehr entfernt
- go.ps1: SYSTEM-Aufgabe per XML – startet jetzt auch im Akkubetrieb (vorher „In Warteschlange“ → keine Rückmeldung)
- go.ps1: grünes „STICK ABZIEHEN“ bleibt mindestens 60 s stehen
- Setup: optionaler **lokaler Admin** (Name/Kennwort in `config.json`) – kommt per ProvisioningCommands ins WLAN-Paket und wird nach jedem Zurücksetzen angelegt; Kennwort und Konto laufen nie ab
- go.ps1: WLAN-Paket schon installiert (identisch) → provtool wird übersprungen; scheitert provtool, zweiter Versuch als SYSTEM (behebt 0x80070005 bei erneutem Lauf am eingerichteten Gerät)
- go.ps1: Log in UTF-8 (Umlaute in Profilnamen)
- Setup *Status*: Doppelklick auf ein Gerät lädt Details live (Profilname, Zuweisungsdatum, Profilstatus) – die Liste kann nach Tag-Wechsel kurz den alten Profilstand zeigen
- Setup: prüft beim Start automatisch das Secret und zeigt die Restlaufzeit oben unter dem Titel (rot ab 7 Tagen); Quelle steht im Protokoll

## v2.4 - 2026-10-06
- Setup: Anleitung (`HUPilot\Setup\Anleitung.html`), Knopf **?** und **F1**

## v2.3 - 2026-10-06
- Setup *Status*: Spalten **Benutzer** (primärer Benutzer), Gerätename und letzter Sync aus Intune – optional `DeviceManagementManagedDevices.Read.All`; Suche auch nach Benutzer

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
