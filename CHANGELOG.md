# Changelog

## v2.1 - 2026-10-05
### Getestet (05.10.2026, Lenovo 82TS, Windows 11 Pro Education 22H2)
- Upload + Tag, grün „STICK ABZIEHEN“, WLAN-Paket, Zurücksetzen per `doWipePersistProvisionedData` als SYSTEM: **ok** – ein Neustart, WLAN im Einrichtungsbildschirm von selbst, Autopilot-Profil geladen, Intune-Registrierung ok
- Offen: ob die Hersteller-Programme auf einem **unberührten** Gerät wirklich wegbleiben (Testgerät war durch frühere CleanPC-Tests schon bereinigt)
### Neu
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
