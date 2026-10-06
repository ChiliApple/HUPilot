# Changelog

## Unveröffentlicht
- Setup: **Sticks vorbereiten** (nur vom PC) – mehrere USB-Sticks formatieren, benennen und mit HUPilot befüllen

## v2.0 - 2026-10-06
Erste Veröffentlichung.
- **go.ps1** (USB, `Shift+F10` → `D:\go`): WLAN verbinden, Hash mit Group Tag hochladen (Tag-Auswahl, Tag-Wechsel bei vorhandenen Geräten), auf Autopilot-Profil warten, Zurücksetzen ohne Hersteller-Anpassungen (RemoteWipe `doWipePersistProvisionedData`) – auch im Akkubetrieb
- Schutz: Rückfrage bei eingerichteten Geräten, Akku-/Netzteil-Prüfung, Erkennung der Intune-Sperre für Bereitstellungspakete
- WLAN-Paket bleibt beim Zurücksetzen erhalten; optional mit lokalem Admin (Kennwort/Konto laufen nie ab)
- **Setup-Oberfläche**: Verbindung testen, Secret-Ablauf beim Start, WLAN-Paket bauen (ADK), auf Stick kopieren, Status aller Autopilot-Geräte (Filter, CSV, Drucken, Details), Anleitung (F1), Online-Update

**Noch nicht auf einem unberührten Neugerät bestätigt:** dass nach dem Zurücksetzen keine Hersteller-Programme zurückkommen.
