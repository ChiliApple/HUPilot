# Changelog

## v2.7.4 - 2026-10-30
- go.ps1: **„Nur hochladen“ im Einrichtungsbildschirm (OOBE) startet automatisch neu,** sobald das Profil zugewiesen ist. Laut Microsoft holt Windows das Autopilot-Profil bei jedem Neustart neu; ein Zurücksetzen ist im OOBE nicht nötig. Vorher wartet go, bis der Stick abgezogen ist (sonst bootet das Gerät evtl. vom Stick), dann 15 s Countdown, [A] bricht ab. Steckt der Stick nach 5 Min noch, kein automatischer Neustart. Im eingerichteten Windows bleibt der Hinweis aufs Zurücksetzen.
- go.ps1: Profilstatus wird auf Deutsch angezeigt (z. B. „kein Profil zugewiesen“, „Zuweisung läuft“, „zugewiesen“ statt `notAssigned`, `pending`, `assignedUnkownSyncState`); im Log steht zusätzlich der Graph-Wert.

## v2.7.3 - 2026-10-30
- go.ps1: **LAN wird abgewartet.** Schlägt der erste Internet-Test fehl und steckt ein LAN-Kabel (physischer Ethernet-Adapter verbunden), zeigt go „LAN verbunden – warte auf Internet“ und testet bis zu 60 s lang alle 10 s erneut, bevor das Konfigurations-WLAN versucht wird. Vorher ging go sofort zum WLAN, auch wenn das LAN nur noch keine Adresse hatte.
- go.ps1: Jeder fehlgeschlagene Internet-Test schreibt den Grund ins Log (`C:\Windows\Temp\HUPilot.log`); vorher wurde der Fehler verschluckt.

## v2.7.2 - 2026-10-26
- go.ps1: **Vorab importierte Geräte (Händler-CSV) behalten ihren Tag.** Ist das Gerät schon in Autopilot und weicht der am Stick gewählte Tag ab, fragt go jetzt: [Enter] vorhandenen Tag behalten (Standard, auch nach 10 s ohne Eingabe) oder [J] ändern. Vorher wurde der Tag ohne Rückfrage überschrieben, auch wenn nach 10 s nur der Standard-Tag gegriffen hatte. Beim Behalten wird das erwartete Profil für den vorhandenen Tag neu bestimmt.
- go.ps1: **Fehler behoben: Tag ohne Profil.** Gibt es für den Tag nachweislich kein Autopilot-Profil, hat `Wait-ApProfile` bisher jedes noch zugewiesene Altprofil akzeptiert und zurückgesetzt. Jetzt wartet go und fragt am Ende J/N. Behält go den vorhandenen Tag und hat dieser kein Profil (z. B. Tippfehler in der CSV), gibt es dieselbe Abbruchfrage [A] wie bei der ersten Tag-Prüfung.
- go.ps1: Registrierte Geräte ohne fertige Zuweisung (z. B. CSV-Import gerade erst verarbeitet) bekommen sofort einen Autopilot-Sync statt erst nach 5 Minuten.
- go.ps1: Scheitert die erste Autopilot-Abfrage (Netz, 429, 5xx), gilt das Gerät nicht mehr als „nicht registriert“: 3 Versuche, danach Abbruch. Vorher wurde dann ein vorab importiertes Gerät neu importiert und der Import scheiterte irreführend mit 806/808.
- go.ps1: Vor der Tag-Rückfrage werden alte Tastendrücke verworfen; `;` im Tag wird in `protokoll.csv` durch `,` ersetzt.
- Geprüft im KI-Briefkasten (Thema 052, Grok und Gemini).
- Setup › Status: Spalte Profil dezent eingefärbt – „zugewiesen“ hellgrün, „ausstehend“, „zugew., Datum fehlt“ und „zugew., nicht synchron“ hellgelb.
- go.ps1: Protokoll schreibt bei bereits registrierten Geräten „BEREITS REGISTRIERT“ statt „UPLOAD OK“ (Setup › Status, Spalte HUPilot).

## v2.7.1 - 2026-10-26
- go.ps1: **„Nur hochladen“ (ohne Zurücksetzen) prüft jetzt die Profilzuweisung.** Vorher endete go direkt nach dem Upload. Jetzt wartet go wie beim Zurücksetzen bis 20 Minuten auf die Zuweisung (gleiche Bedingungen: Status zugewiesen, Datum gesetzt, erwartetes Profil für den Tag) und zeigt am Ende grün „Autopilot-Profil zugewiesen“ mit Profilname oder gelb den letzten Status. Das Fenster darf jederzeit geschlossen werden, der Upload ist da schon fertig.
- go.ps1: Solange das Profil noch nicht zugewiesen ist, stößt go den Autopilot-Sync alle 5 Minuten erneut an. Der Sync direkt nach dem Import wird abgewiesen (429), wenn in den 10 Minuten davor schon einer lief, z. B. vom vorigen Gerät; dann musste man ihn bisher im Portal von Hand anstoßen.
- Setup: **Absturz „Laufwerk D nicht vorhanden“ behoben** (z. B. bei „6. Status“, nachdem der Stick neu eingehängt wurde). Stick-Zugriffe beim Lesen von `protokoll.csv` und `hashes.csv` prüfen den Stick jetzt direkt über Windows statt über PowerShell-Laufwerke; fehlt er, steht ein Hinweis im Log. Der Status-Knopf fängt Fehler ab, statt das Setup zu beenden.

## v2.7 - 2026-10-24
- go.ps1: **Zurücksetzen ohne fertiges Autopilot-Profil behoben.** v2.6 hat schon beim ersten Profilstatus `assigned…` zurückgesetzt. Ein Gerät wurde so zurückgesetzt, bevor die Zuweisung fertig war, und landete im normalen Windows-Setup. Jetzt gelten die drei Bedingungen aus der Microsoft-Doku (Autopilot › Profile › „Assignment of Windows Autopilot deployment profiles to devices“):
  1. Profilstatus „Zugewiesen“ (`assignedInSync` oder `assignedUnkownSyncState`; in den Schul-Tenants stehen **alle** registrierten Geräte dauerhaft auf `assignedUnkownSyncState`)
  2. Zuweisungsdatum gesetzt (`deploymentProfileAssignedDateTime`)
  3. Zugewiesenes Profil = erwartetes Profil. Erwartet ist das Profil, das laut Microsoft-Prioritätsregel gewinnt: unter mehreren passenden Gruppen-Profilen das älteste, ein Profil für „Alle Geräte“ nur, wenn kein Gruppen-Profil passt; Profile, die die Tag-Gruppe ausschließen, zählen nicht (braucht `Group.Read.All`)
  4. Detailstatus der Zuweisung leer oder `none`
  
  Alles muss zwei Abfragen hintereinander (30 s) erfüllt sein. Kommt der erste Treffer kurz vor Ablauf der Wartezeit, gibt es genau eine Kontrollrunde zusätzlich.
- go.ps1: **Tag-Änderung:** Freigabe nur noch mit dem Profil des neuen Tags. Die alte 10-Minuten-Regel und der Vergleich mit dem bisherigen Profil entfallen; beide konnten mit dem **alten** Profil zurücksetzen (z. B. wenn das bisherige Profil nicht lesbar war). Ohne Tag-Prüfung (kein `Group.Read.All`) gibt es nach einer Tag-Änderung keine automatische Freigabe, sondern die J/N-Abfrage am Ende.
- go.ps1: **Token wird nach 45 Minuten erneuert.** Microsoft gibt 60–90 Minuten Gültigkeit an; Hardwaretausch, Import und Profil-Warten zusammen können länger dauern.
- go.ps1: Autopilot-Sync einmal **nach** Import, Tag-Änderung und Benutzerzuweisung (vorher vor der Benutzerzuweisung, nach Tag-Änderung gar nicht). 409/429 (Sync läuft bzw. letzter Sync vor < 10 Min, laut Doku) gelten nicht mehr als Fehler.
- go.ps1: Import-Statuswechsel werden geloggt (auch `partial`). Meldung bei Fehler 806/808 nennt jetzt auch einen alten Datensatz im eigenen Tenant als Ursache (laut Doku möglich).
- go.ps1: Seriennummer im Filter abgesichert (Hochkomma), bei mehreren Autopilot-Einträgen mit derselben Seriennummer Hinweis im Log und Verwendung des jüngsten.
- go.ps1: Läuft die Wartezeit ab, zeigt die gelbe Meldung den letzten Status und empfiehlt N.
- Setup › Status: Spalte Profil zeigt „zugew., Datum fehlt“ bzw. „zugew., nicht synchron“ (`assignedOutOfSync`).
- Setup › Status: Datum wird über das Jahr geprüft (robust, egal ob Text oder Datumswert).
- Geprüft im KI-Briefkasten (Thema 051, Gemini, 2 Runden).
- **Noch nicht an einem Gerät getestet.**

## v2.6 - 2026-10-20
- Zurücksetzen: **McAfee und andere Hersteller-Apps kamen zurück.** Laut Microsoft-Doku (Push-button reset) stellt das Zurücksetzen zusätzlich wieder her: vorinstallierte Store-Apps aus einer eigenen Sicherung und Herstellerskripte aus `C:\Recovery\OEM` (`ResetConfig.xml`). Neu vor dem Zurücksetzen (als SYSTEM):
  - vorinstallierte und installierte Store-Apps, deren Name auf `RemoveApps` passt, werden entfernt (Standard `McAfee`; `"RemoveApps": ""` schaltet es aus)
  - `C:\Recovery\OEM` wird wie `Customizations` und `AutoApply` nach `C:\Recovery\HUPilot-OEM-Backup` verschoben
  - **Noch nicht an einem Gerät bestätigt**, ob damit alle Wege abgedeckt sind. Falls McAfee trotzdem zurückkommt: `D:\diag` › 6 zeigt jetzt, in welcher Form McAfee vorhanden ist (vorinstallierte App, App, Programm) und was in `C:\Recovery\OEM` liegt.
- diag › 6: Abschnitt „McAfee / Hersteller-Apps“, dazu `C:\Recovery\OEM` und `HUPilot-PPKG-Backup` in der Recovery-Übersicht.

## v2.5 - 2026-10-19
- go.ps1: **Abbruch nach „STICK ABZIEHEN“ behoben.** go lief mit dem Stick als Arbeitsverzeichnis. Wurde der Stick wie angezeigt abgezogen, scheiterte danach jeder Programmaufruf (`schtasks`, `cmd`) mit „Der Verzeichnisname ist ungültig“, und das Zurücksetzen startete nicht. go wechselt jetzt gleich zu Beginn nach `C:\Windows\System32`. Das erklärt vermutlich auch den Fehler aus v2.3 („schtasks ohne Ausgabe“).
- go.ps1: alte Aufgabe wird mit `Unregister-ScheduledTask` entfernt; ein Fehler dabei bricht nicht mehr ab.

## v2.4 - 2026-10-14
- go.ps1 und diag: Ohne Administratorrechte (z. B. `go.cmd` per Doppelklick im Explorer) starten sie sich selbst mit Adminrechten in einem neuen Fenster neu (Windows fragt nach einem Admin-Konto). Vorher brach go mit „Hardware-Hash nicht lesbar“ ab – erst nachdem die LOESCHEN-Rückfrage schon bestätigt war.
- go.ps1: **Mainboardtausch erkennen** – meldet Autopilot eine Hardware-Änderung („Fix ausstehend“ / „Achtung erforderlich“, `remediationState`), bietet go an, das Gerät neu zu registrieren: Intune-Eintrag löschen, Autopilot-Eintrag löschen (Reihenfolge laut MS Doku), warten bis er weg ist, neuen Hash mit Tag hochladen. Vorher wurde bei bekannter Seriennummer nur der Tag geändert und der alte Hash blieb. Braucht optional `DeviceManagementManagedDevices.ReadWrite.All`.
- **Fremde Bereitstellungspakete entfernen** (neuer Setup-Schalter, `RemoveOtherPackages`, **Standard aus**, noch im Test): Das Zurücksetzen stellt alle Pakete aus `ProgramData\Microsoft\Provisioning` wieder her (MS Doku RemoteWipe CSP), also auch alte Schul-/MDM-Pakete. Verdacht: Diese können Autopilot stören (nicht bestätigt). Eingeschaltet bleibt nur das HUPilot-WLAN-Paket (erkannt an Name und Prüfsumme); alle anderen werden zuerst nach `C:\Recovery\HUPilot-PPKG-Backup\<Datum>` kopiert und geprüft, erst dann entfernt. Schlägt die Sicherung fehl, wird nichts entfernt und nicht zurückgesetzt. go zeigt vorher an, welche Pakete betroffen sind.

## v2.3 - 2026-10-13
- go.ps1: Die geplante Aufgabe fürs Zurücksetzen wird jetzt mit `Get-ScheduledTask` geprüft und mit `Start-ScheduledTask` gestartet. Vorher lieferte `schtasks /Query` auf manchen Geräten keine Ausgabe, und go brach mit „Geplante Aufgabe nicht angelegt“ ab, obwohl die Aufgabe da war. `schtasks` bleibt als Ausweichweg.

## v2.2 - 2026-10-10
Update-Weg wie bei den anderen HU-Tools: **Release + Prüfsumme + Signatur + Freigabe**.
- Neu: `HUPilot\Setup\Pull.ps1` – lädt eine Version als GitHub-Release, prüft **jede Datei** gegen `HUPilot-files.sha256` und die Signatur (`HUPilot-files.sha256.p7s`, Zertifikat des Herausgebers), ersetzt erst dann alles auf einmal (Journal, bei Abbruch wird der alte Stand zurückgestellt) und entfernt Dateien, die es nicht mehr gibt
- `config.json`, WLAN-Paket, `logs\`, `HUPilot\Config\update.json` und eigene Dateien am Stick bleiben immer unberührt
- Setup, Knopf **Update**: gold bei neuer freigegebener Version, Klick startet Pull. Rechtsklick: andere Version/Vorversion, Kanal **Stabil**/**Test**, jetzt prüfen, GitHub-Token; für den Herausgeber zusätzlich *Release signieren* und *Release freigeben*
- Versionsnummer nur noch in `HUPilot\Config\version.json` (Setup, `go.ps1`, `diag` lesen sie dort)
- Setup und `go.ps1` starten nicht, solange ein abgebrochenes Update offen ist (`pull-journal.json`); das Setup bietet dann Pull zum Wiederherstellen an
- Setup: **zweiter lokaler Admin** (Admin 2, z. B. Elternverein) – kommt wie Admin 1 mit dem WLAN-Paket, Kennwort/Konto laufen nie ab
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
