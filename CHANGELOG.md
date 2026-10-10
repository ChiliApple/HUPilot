# Changelog

## v2.2 - 2026-10-10
Update-Weg wie bei den anderen HU-Tools: **Release + Prüfsumme + Signatur + Freigabe**.
- Neu: `HUPilot\Setup\Pull.ps1` – lädt eine Version als GitHub-Release, prüft **jede Datei** gegen `HUPilot-files.sha256` und die Signatur (`HUPilot-files.sha256.p7s`, Zertifikat des Herausgebers), ersetzt erst dann alles auf einmal (Journal, bei Abbruch wird der alte Stand zurückgestellt) und entfernt Dateien, die es nicht mehr gibt
- `config.json`, WLAN-Paket, `logs\`, `HUPilot\Config\update.json` und eigene Dateien am Stick bleiben immer unberührt
- Setup, Knopf **Update**: gold bei neuer freigegebener Version, Klick startet Pull. Rechtsklick: andere Version/Vorversion, Kanal **Stabil**/**Test**, jetzt prüfen, GitHub-Token; für den Herausgeber zusätzlich *Release signieren* und *Release freigeben*
- Versionsnummer nur noch in `HUPilot\Config\version.json` (Setup, `go.ps1`, `diag` lesen sie dort)
- Setup und `go.ps1` starten nicht, solange ein abgebrochenes Update offen ist (`pull-journal.json`); das Setup bietet dann Pull zum Wiederherstellen an
- Eine Setup-Instanz je Stick/Ordner (vorher eine je PC)
- *Auf Stick kopieren* / *Sticks vorbereiten* nehmen keinen GitHub-Token und keine Update-Reste mit
- Automatische Tests auf GitHub wieder aktiv: Syntax, Steuerelemente, Version, Bibliothek, PSScriptAnalyzer, Pester, Starttest des Setups; bei neuer Version Vorab-Release mit Prüfsummen-Datei und Test des Update-Wegs

**Übergang:** Von v2.1 auf v2.2 aktualisiert noch der alte Update-Knopf (ohne Signatur). Ab v2.2 gilt der neue Weg. Änderungen an `Pull.ps1` wirken immer erst beim übernächsten Update, weil ein Update mit dem bisher vorhandenen Pull läuft.

## v2.1 - 2026-10-07
- **`diag.cmd`** am Stick: Diagnose-Menü (Log, Fehler, Zurücksetzen, Gerät, Netzwerk, WLAN-Paket/Intune-Sperre, alles speichern) – ersetzt `Tools\Diagnose.cmd`
- go.ps1/go.cmd: Konsolenfarben werden beim Start und am Ende zurückgesetzt (erneutes `go` im selben Fenster blieb grün/gelb/rot)
- go.ps1: **Offline-Modus** – ohne Internet oder bei abgelaufenem/falschem Secret wird der Hash am Stick gespeichert (`logs\hashes.csv`, Microsoft-CSV-Format), gelbe Meldung, kein Zurücksetzen
- go.ps1: Uhrzeit per HTTP-Date stellen (falsche Uhr → Token/TLS scheitern)
- go.ps1: **Tag-Prüfung** – Warnung, wenn für den Tag kein Autopilot-Profil zugewiesen ist (optional `Group.Read.All`)
- go.ps1: optional **Benutzer vorab zuweisen** (`AskUser`, Prüfung optional `User.Read.All`)
- Setup: Knöpfe nach Ablauf geordnet (*Vorbereiten* 1–4 · *Stick* 5 · *Danach* 6–7), Anleitung/Update oben rechts
- Setup: **2. Tags prüfen**, **7. Hashes importieren**, Schalter „nach Benutzer fragen“
- Setup: Secret-Restlaufzeit in Tagen + Stunden, rot erst unter 24 Std
- Setup *Status*: Spalte **RegDatum** (Intune-Registrierung, neueste oben) und Knopf **Aktualisieren**
- Setup: Knopf oben rechts legt eine Desktop-Verknüpfung (mit Symbol) zum Vorbereitungsordner an
- Setup: **Sticks vorbereiten** (nur vom PC) – mehrere USB-Sticks formatieren, benennen und mit HUPilot befüllen

## v2.0 - 2026-10-06
Erste Veröffentlichung.
- **go.ps1** (USB, `Shift+F10` → `D:\go`): WLAN verbinden, Hash mit Group Tag hochladen (Tag-Auswahl, Tag-Wechsel bei vorhandenen Geräten), auf Autopilot-Profil warten, Zurücksetzen ohne Hersteller-Anpassungen (RemoteWipe `doWipePersistProvisionedData`) – auch im Akkubetrieb
- Schutz: Rückfrage bei eingerichteten Geräten, Akku-/Netzteil-Prüfung, Erkennung der Intune-Sperre für Bereitstellungspakete
- WLAN-Paket bleibt beim Zurücksetzen erhalten; optional mit lokalem Admin (Kennwort/Konto laufen nie ab)
- **Setup-Oberfläche**: Verbindung testen, Secret-Ablauf beim Start, WLAN-Paket bauen (ADK), auf Stick kopieren, Status aller Autopilot-Geräte (Filter, CSV, Drucken, Details), Anleitung (F1), Online-Update

**Noch nicht auf einem unberührten Neugerät bestätigt:** dass nach dem Zurücksetzen keine Hersteller-Programme zurückkommen.
