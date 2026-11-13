# Changelog

## v2.7.16 - 2026-11-13
### 🎨 Oberfläche
- **Setup passt auf kleine Bildschirme:** Das Fenster ist nie größer als der Bildschirm ohne Taskleiste und liegt ganz im sichtbaren Bereich. Auf Notebooks mit kleiner Auflösung ragte es bisher unter die Taskleiste.
- **Scrollbalken bedienbar:** Der Balken ist breiter, lässt sich ziehen und ein Klick neben den Balken blättert seitenweise.
- **Mausrad scrollt das ganze Formular:** auch wenn der Mauszeiger über einem Eingabefeld steht. Im Protokoll scrollt es weiter das Protokoll.

### 🪟 Windows-Edition
- **Hinweis zum MAK:** Unter dem Feld "MAK (Pro)" steht jetzt, dass der Schlüssel im Klartext auf dem Stick liegt, nur für Einzelfälle gedacht ist und danach wieder geleert werden soll.

### 🚧 Grenzen
- Die anderen Fenster (Status, Hashes importieren, Sticks vorbereiten) sind noch nicht an kleine Bildschirme angepasst.

### ✅ Qualität
- 14 automatische Tests.

## v2.7.15 - 2026-11-13
### 🪟 Windows-Edition
- **Allgemeiner Schlüssel wird als MAK abgelehnt:** Steht im Feld "MAK (Pro)" einer der allgemeinen Schlüssel von Microsoft, speichert das Setup nicht und sagt warum. Diese Schlüssel stellen nur um, sie aktivieren nicht.
  - Am Gerät bricht go bei Windows Home mit Hinweis ab, bevor umgestellt wird.
  - Ist das Gerät schon umgestellt, läuft go weiter und zeigt eine gelbe Warnung statt eines Aktivierungsversuchs.
- **Am Gerät bestätigt:** Die Umstellung von Windows Home auf Pro im Einrichtungsbildschirm hat an einem Testgerät geklappt, mit Neustart und anschließendem Import in Autopilot.

### 🚧 Grenzen
- Die Aktivierung mit einem MAK im Einrichtungsbildschirm ist noch an keinem Gerät bestätigt.

### ✅ Qualität
- 14 automatische Tests.

## v2.7.14 - 2026-11-13
### 🪟 Windows-Edition
- **Klarere Texte zu Windows Home:** Setup, Meldungen am Gerät und Anleitung sagen jetzt, worum es geht: Windows Home lässt keine Intune-Verwaltung zu, nötig ist Pro oder Pro Education (auch Education, Enterprise).
  - Die Funktion ist unverändert: go stellt Home auf Pro um.

### ✅ Qualität
- 13 automatische Tests.

## v2.7.13 - 2026-11-13
### 🪟 Windows-Edition
- **Neu: Windows Home auf Pro umstellen (Test):** Geräte mit Windows Home bleiben nicht mehr nur rot stehen.
  - Im Setup neues Feld "MAK (Pro)" für den Volumenlizenz-Schlüssel, leer = aus.
  - Am Gerät fragt go nach (`J` = umstellen, sonst Abbruch), stellt auf Pro um und Windows startet neu. Danach `D:\go` erneut.
  - Nach dem Verbinden aktiviert go mit dem MAK. Klappt das nicht, gibt es nur eine Warnung.
  - Geräte mit Pro, Education oder Enterprise werden nicht angefasst.
- **Überwachte Umstellung:** go beobachtet die Umstellung 10 Minuten, versucht es dabei bis zu zweimal und startet selbst neu, falls Windows es nicht tut.
- **Kein neuer Versuch von selbst:** Scheitert die Umstellung, fragt go beim nächsten Start nach (`W` = nochmal versuchen, sonst Abbruch).
- **Schlüssel nie im Log:** Im Log und im Protokoll stehen nur die letzten 5 Zeichen.

### 🚧 Grenzen
- Noch an keinem Gerät bestätigt. Im Einrichtungsbildschirm hat die Umstellung mit dem MAK direkt nicht gewirkt, deshalb stellt go zuerst mit dem allgemeinen Pro-Schlüssel von Microsoft um und aktiviert erst danach.
- Windows Home N braucht einen Schlüssel für Pro N, go bricht dort mit Hinweis ab.
- Jede Aktivierung zählt beim MAK mit.

### ✅ Qualität
- 13 automatische Tests.

## v2.7.12 - 2026-11-05
### 📊 Status
- **Neu: Zeitfilter:** Häkchen „nur letzte“ mit 4 h, 24 h oder 48 h.
  - Wahlweise nach Registrierung in Intune oder nach Autopilot-Import.
  - Als Importzeit gilt die Zeit des Hochladens per Stick, sonst die Zeit der Profil-Zuweisung. Microsoft liefert keine eigene Importzeit.
  - Wirkt auch auf Excel, CSV und Ausdruck, der Ausdruck nennt den Filter.

## v2.7.11 - 2026-11-05
### ⏱️ Wartezeiten am Gerät
- **Kein stundenlanges Warten mehr, wenn Windows die Uhr umstellt:** Im Einrichtungsbildschirm stellt Windows die Uhr oder Zeitzone teils mitten im Lauf um. Bisher konnte go dann stundenlang warten (z. B. „nächster Test in 21642 s“ beim WLAN-Verbinden).
  - Alle Wartezeiten laufen jetzt über eine Stoppuhr, unabhängig von Uhrzeit und Zeitzone: WLAN, LAN, Anmeldung, Import, Profil, Stick abziehen, Auswahlen mit Zeitlimit, Zurücksetzen.
  - Die Anzeige der gelaufenen Zeit springt nicht mehr.
- **Uhrsprung im Log:** Stellt Windows die Uhr um mehr als 60 s um, steht das mit der Größe des Sprungs im Log.

### 📊 Status
- **Neu: Excel speichern:** Die angezeigten Zeilen als Excel-Datei, ohne dass Excel installiert sein muss.
  - Kopfzeile fixiert und mit Filter, Spaltenbreite nach Inhalt.
  - Datumsspalten als echtes Datum (sortier- und filterbar), Profil eingefärbt wie im Fenster.
  - Druckt aus Excel im Querformat auf Seitenbreite, Kopfzeile auf jeder Seite.
- **Drucken neu gestaltet:** Ausdruck und PDF sehen jetzt aus wie die Tabelle im Fenster.
  - Querformat vorgeschlagen, alle Spalten wie im Fenster, Breite nach Inhalt statt gleich breit.
  - Kopfzeile auf jeder Seite, Zeilen abwechselnd hinterlegt, Profil eingefärbt.
  - Unter dem Titel stehen Anzahl und aktive Filter.

### ✅ Qualität
- 11 automatische Tests.

## v2.7.10 - 2026-11-02
- Anleitung: **„Nur hochladen“** beschrieben (WLAN-Paket, Neustart im Einrichtungsbildschirm, 11-Min-Regel), **Rückfrage bei anderem Tag**, empfohlenes Recht **Group.Read.All** und optional **User.Read.All**, Häkchen „Fremde Bereitstellungspakete entfernen“, Entfernen von Hersteller-Apps (`RemoveApps`), Profile nur über Tag-Gruppen zuweisen.
- Anleitung: Farben und Fehlersuche ergänzt (Windows Home, „Profil kann nicht geprüft werden“, „ZURÜCKSETZEN NICHT GESTARTET“); Bildschirmtexte mit Umlaut (`LÖSCHEN`, „HARDWARE-ÄNDERUNG“).

## v2.7.9 - 2026-11-02
- go.ps1: **Kein rotes Banner mehr, während das Zurücksetzen im Hintergrund weiterläuft.** Kommt vom SYSTEM-Script keine Rückmeldung, wird die geplante Aufgabe jetzt gestoppt, bevor „FEHLER beim Zurücksetzen“ erscheint. War der Aufruf zum Zurücksetzen schon abgesetzt, meldet go „angenommen“ statt Rot. Wartezeit 5 statt 3 Min (Entfernen der Hersteller-Apps kann dauern).
- Setup: **Nach einem Update kommt einmal der Hinweis „Sticks neu bespielen: 5. Auf Stick kopieren“.** Läuft das Setup selbst vom Stick, steht dabei, dass dieser Stick schon aktuell ist und nur die anderen fehlen.
- Update: **Abgebrochenes Update wird auch mit anderem Laufwerksbuchstaben wiederhergestellt.** Das Journal speichert die Pfade relativ zum Stick; alte Journale mit festem Buchstaben werden umgesetzt.
- Tools: `New-WcdProjekt.ps1` liest config.json als UTF-8 (Umlaute in SSID/WLAN-Kennwort).

## v2.7.8 - 2026-10-30
- go.ps1: Graph-Abfragen wiederholen bei Überlast (429/503/504) mit Retry-After bzw. 5/15/45 s + Zufall; Profil-Abfrage im Takt 26–35 s statt fix 30 s (viele Geräte gleichzeitig). Hinweis am Bildschirm, wenn das Profil mangels Recht Group.Read.All nicht geprüft werden kann. Live-Zeile wird bei schmalem Fenster gekürzt, Zeit und Countdown bleiben sichtbar.
- diag.ps1: Hersteller-Apps nach `RemoveApps` aus config.json statt fest McAfee; ungültige Menüauswahl wird gemeldet.
- Update: verständliche Meldung, wenn die GitHub-Abfragegrenze (60/Stunde ohne Token) erreicht ist.
- CI: neue Prüfungen „Funktionen vor Verwendung definiert“ (go/diag) und „config.json nur mit -Encoding lesen“.
- Prüfung Grok (Briefkasten 076): Fehler bei kaputter config.json zeigte kein rotes Banner (Live-Anzeige war zu spät definiert) – behoben. config.json wird überall als UTF-8 gelesen (Umlaute in WLAN-Kennwort/Tenant). WLAN-Paket ohne Zurücksetzen mit 2-Min-Zeitlimit und Anzeige. Im OOBE verlängert sich die Wartezeit, damit der Neustart nach 11 Min ohne Datum auch bei spätem Profil greift. Verlauf zeigt bei Statuswechsel den alten Status statt „frage ab“. Startet das Zurücksetzen nach 15 Min nicht, kommt ein rotes Banner. CI-Update-Test auf Umlaut angepasst.
- Setup Status: Geräte, die noch nicht in Intune registriert sind (gerade in Arbeit), stehen jetzt **oben** statt ganz unten.
- go.ps1: **Neustart im Einrichtungsbildschirm erzwungen** (`shutdown /r /f /t 0`). Vorher konnte „Program Manager – diese App verhindert den Neustart“ den automatischen Neustart blockieren.
- Alle Anzeigen (go, diag, Setup, Update) einheitlich mit echten Umlauten und ß statt ae/oe/ue/ss. `protokoll.csv` und `hashes.csv` bleiben ASCII (Umlaute werden dort umgeschrieben). Bei der Warnung „Gerät ist schon eingerichtet“ wird `LÖSCHEN` und `LOESCHEN` akzeptiert (Tastatur im OOBE evtl. englisch).
- Setup: Hauptfenster scrollt, wenn es kleiner gezogen wird; schmale dunkle Scrollbalken in allen Fenstern; Anfasser rechts unten zum Größerziehen.

## v2.7.7 - 2026-10-30
- go.ps1: **Live-Anzeige bei allen Wartestellen.** Statt alle 30 s eine neue Zeile gibt es eine Zeile, die sich jede Sekunde aktualisiert: Status, gelaufene Zeit / Höchstzeit, Countdown bis zur nächsten Abfrage und ein drehendes Zeichen (`| / - \`). Ändert sich der Status, bleibt die alte Zeile als Verlauf stehen. Gilt für Profil, Import, Löschen, LAN, WLAN, Anmeldung, Netzteil, Stick abziehen, Neustart-Countdown, Zurücksetzen. Auch alle Auswahlen mit Zeitlimit zeigen den Countdown live. Ins Log kommt weiter jede Abfrage.
- go.ps1: **Im Einrichtungsbildschirm (nur hochladen) nach 11 Min auch ohne Zuweisungsdatum neu starten,** wenn Status, Profil und „kein Fehler“ stabil passen (Test 30.10.: Profil kam ohne Datum an; ein Irrtum kostet nur einen Neustart). Beim Zurücksetzen wird das Datum weiter abgewartet.
- go.ps1: Schrift im Fenster größer (mind. 20 statt meist 16).
- go.ps1: **WLAN-Paket auch bei „nur hochladen“ (ohne Zurücksetzen).** Bisher wurde das Paket (WLAN + ggf. lokaler Admin) nur beim Zurücksetzen installiert. Jetzt installiert go es auch ohne Zurücksetzen per provtool, bevor auf das Profil gewartet wird; ist es schon identisch installiert, wird es übersprungen. Schlägt es fehl, gelbe Meldung, go macht weiter.

## v2.7.6 - 2026-10-30
- go.ps1: Ist das Profil zugewiesen, aber das Zuweisungsdatum noch leer, zeigt go „Profil: zugewiesen – Datum fehlt noch“ statt „Zuweisung fehlt – warten“ (passt zum Portal, das dann schon „Zugewiesen“ zeigt). Entscheidung unverändert: laut Microsoft erst ausrollen, wenn das Datum gesetzt ist.

## v2.7.5 - 2026-10-30
- go.ps1: **Anzeige beim Warten auf das Profil vereinfacht** – eine kurze Zeile pro Abfrage: „noch nicht sichtbar – warten“, „Zuweisung fehlt – warten“, „falsches Profil – warten“, „zugewiesen (Profil) – Kontrolle in 30 s“, „zugewiesen (Profil)“. Keine zweite Erklärungszeile mehr. Die Entscheidung, wann zurückgesetzt bzw. neu gestartet wird, ist unverändert; der genaue Grund steht weiter im Log.

## v2.7.4 - 2026-10-30
- go.ps1: **„Nur hochladen“ im Einrichtungsbildschirm (OOBE) startet automatisch neu,** sobald das Profil zugewiesen ist. Laut Microsoft holt Windows das Autopilot-Profil bei jedem Neustart neu; ein Zurücksetzen ist im OOBE nicht nötig. Der Stick ist da normalerweise schon abgezogen (nach „STICK ABZIEHEN“ beim Upload); steckt er noch, erscheint ein gelber Hinweis und go wartet, bis er weg ist (sonst bootet das Gerät evtl. vom Stick). Dann 15 s Countdown, [A] bricht ab. Steckt der Stick nach 5 Min noch, kein automatischer Neustart. Im eingerichteten Windows bleibt der Hinweis aufs Zurücksetzen.
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
