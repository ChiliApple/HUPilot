# Changelog

## Unveröffentlicht
- **`diag.cmd`** am Stick: Diagnose-Menü (Log, Fehler, Zurücksetzen, Gerät, Netzwerk, WLAN-Paket/Intune-Sperre, alles speichern) – ersetzt `Tools\Diagnose.cmd`
- go.ps1/go.cmd: Konsolenfarben werden beim Start und am Ende zurückgesetzt (erneutes `go` im selben Fenster blieb grün/gelb/rot)
- go.ps1: **Offline-Modus** – ohne Internet oder bei abgelaufenem/falschem Secret wird der Hash am Stick gespeichert (`logs\hashes.csv`, Microsoft-CSV-Format), gelbe Meldung, kein Zurücksetzen
- go.ps1: Uhrzeit per HTTP-Date stellen (falsche Uhr → Token/TLS scheitern)
- go.ps1: **Tag-Prüfung** – Warnung, wenn für den Tag kein Autopilot-Profil zugewiesen ist (optional `Group.Read.All`)
- go.ps1: optional **Benutzer vorab zuweisen** (`AskUser`, Prüfung optional `User.Read.All`)
- Setup: **6. Tags prüfen**, **7. Hashes importieren**, Schalter „nach Benutzer fragen“
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
