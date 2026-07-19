# Aktueller Gesamt-Audit – XReactor Controller V3

Stand: 2026-07-18  
Branch: `beta`  
Geprüfter ausführbarer Code-Head: `e21584e4c2d1c0e77b56e07a47943b9d98f62704`  
Geprüfte Release: `beta-v472` / `manifest-v472`  
Manifest-Dateien: `166`

## Zweck und Prüfumfang

Diese Datei ist die aktuelle, rollenübergreifende Aufgabenquelle für Coding-AI und manuelle Prüfungen. Sie ersetzt die vorherige `beta-v455`-Fassung vollständig.

Geprüft wurden statisch anhand des tatsächlichen Codes auf `beta`:

- Root-Installer, modularer Installer, Installationsjournal und Auto-Update,
- Manifest, Rollen-Scope und Entrypoint-Abhängigkeiten,
- Shared Runtime und Update-Quiesce,
- MASTER,
- RT,
- ENERGY,
- WATER,
- FUEL,
- REPROCESSOR,
- VALVE,
- LOG Collector,
- Tests und GitHub Actions.

Commitmeldungen und Kommentare wurden nicht als Beweis übernommen. Ein lokaler Checkout und Testlauf war in der Prüfumgebung wegen fehlender DNS-Verbindung nicht möglich. Peripheral-, Netzwerk-, Reboot-, Stromausfall-, Update- und Lastverhalten muss zusätzlich in CC:Tweaked/Ingame nachgewiesen werden.

---

# 1. Gesamtstatus

| Bereich | Tatsächlicher Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Auto-Update | **KRITISCH TEILWEISE** | Journal-Replace ist seit 2026-07-19 generationenbasiert/fail-closed (siehe Abschnitt 3+4); Configbackup kann Lesefehler weiterhin still überspringen |
| Manifest / Rollen-Scope | **WEITGEHEND UMGESETZT** | Release-Metadaten enthalten weiterhin keinen unveränderlichen Installations-SHA; statischer Kommentar im Manifest ist veraltet |
| Shared Runtime / Quiesce | **KRITISCH TEILWEISE** | FUEL/REPROCESSOR warten beim Quiesce nicht auf Wireless-VALVE-ACKs; RT beendet Safety/Regelung ohne sicheren Hardwarezustand |
| MASTER | **TEILWEISE OFFEN** | `persisted=false` wird weiterhin als vollständig `APPLIED` gewertet |
| RT | **WEITGEHEND UMGESETZT** | Startup-/Lifecycle-Fixes sind vorhanden; Update-Quiesce ohne SCRAM und Observability-/Persistenzrestpunkte bleiben offen |
| ENERGY | **WEITGEHEND UMGESETZT** | Heartbeatquelle und Schedulertrennung sind statisch korrigiert; echter Blockade-/Lastnachweis fehlt |
| WATER | **WEITGEHEND UMGESETZT** | lokale Persistenz wird ehrlich gemeldet, MASTER wertet sie aber noch falsch; Ingame-Nachweise fehlen |
| FUEL | **KRITISCH TEILWEISE** | Routing-ACKs sind command-ID-gebunden; Update-Quiesce bestätigt den physischen Blockzustand trotzdem nicht |
| REPROCESSOR | **KRITISCH TEILWEISE** | Wireless-VALVE-Verdrahtung und Standby-Cancel sind behoben; Update-Quiesce wartet nicht auf Block-ACKs |
| VALVE | **KRITISCH TEILWEISE** | Auto-Pairing erfolgt vor vollständiger Befehlsvalidierung und kann durch ein ungültiges Erstpaket vergiftet werden |
| LOG Collector | **WEITGEHEND UMGESETZT** | Probe-Wipe, Reclaim-Cache und `send_ack`-Crash sind behoben; Rotation und belastbarer Datenhaltungsnachweis bleiben offen |
| Tests / CI | **KRITISCH TEILWEISE** | 63 Lua- und 6 Python-Tests ausgeschlossen; für den geprüften Head kein grüner Workflowlauf nachgewiesen |
| Dokumentation | **AKTUELL** | diese Datei ist die aktuelle allgemeine Auditquelle für `beta-v472` |

## Produktionsurteil

`beta-v472` ist **noch nicht produktionsreif**.

Die größten aktuellen Risiken sind:

1. ~~Ein Stromausfall beim Aktualisieren des Installationsjournals kann das einzige unvollständige Installationssignal entfernen.~~ BEHOBEN 2026-07-19, siehe Abschnitt 3.
2. ~~Ein beschädigtes oder nicht lesbares Journal wird beim Boot wie „kein Journal vorhanden“ behandelt.~~ BEHOBEN 2026-07-19, siehe Abschnitt 4.
3. FUEL und REPROCESSOR melden `RUNTIME_STOPPED`, bevor drahtlose Ventile ihren sicheren BLOCKED-Zustand bestätigt haben.
4. RT beendet seine Regel- und Safety-Schleife für ein Update ohne vorherigen SCRAM oder bestätigten sicheren Reaktor-/Turbinenzustand.
5. VALVE kann durch ein ungültiges erstes Paket dauerhaft an den falschen Sender gekoppelt werden.
6. MASTER übernimmt `persisted=false` als vollständig bestätigten Sollwert.
7. Configdateien können beim Backup still fehlen, wenn Verzeichnislisting oder `fs.open()` scheitert.
8. 69 Tests bleiben ausgeschlossen; ein grüner Lauf des aktuellen Heads ist nicht nachgewiesen.

---

# 2. Seit `beta-v455` tatsächlich behoben

Die folgenden Punkte sind im aktuellen Code nachvollziehbar umgesetzt. Sie dürfen nur mit konkretem Regressionstest erneut verändert werden.

## Installer und Manifest

- `/installer` ist ein dünner Bootstrap; die eigentliche Installationslogik liegt nur noch in `xreactor/installer/init.lua`.
- Bootstrap, Installermodule, Manifest und Installationsdateien verwenden denselben einmal aufgelösten Ref.
- `installer/plan_validator.lua` validiert Rolle, Entrypoint, Pfade, Größen, CRC32-Felder und Plangrößen vor dem Löschen der alten Installation.
- transitive `require()`-/`dofile()`-Manifestabdeckung besitzt einen eigenen Test.
- kritische Dateisystemoperationen und Config-/Rollenwrites werden weitgehend auf Erfolg geprüft.
- der unsichere `stage.write()`-Fallback, der bei fehlgeschlagenem Backupmove die alte Datei löschte, wurde entfernt.
- jede installierte Datei wird gegen Größe und CRC32 geprüft.
- `release.lua` wird erst nach den übrigen Dateien installiert.
- ein Installationsjournal mit `PREPARED -> INSTALLING -> VERIFYING -> COMMITTED` ist vorhanden.
- der Bootpfad verhindert den Rollenstart, wenn ein lesbares Journal einen unvollständigen Zustand meldet.
- Manifest-Scope-Lücken für REPROCESSOR, VALVE, Speaker, Alert-Service und Shared Colors wurden behoben.
- der frühere doppelte Manifestpfad für `core/bootstrap.lua` wurde entfernt.
- das Installationsjournal ist generationenbasiert (zwei alternierende Slots) und stromausfallsicher: kein Schreibvorgang kann die zuletzt bestätigte Generation zerstören (INSTALL-P0.1).
- Journalklassifikation unterscheidet fail-closed `ABSENT`/`VALID_COMMITTED`/`VALID_INCOMPLETE`/`CORRUPT`/`UNREADABLE`; nur `ABSENT`/`VALID_COMMITTED` erlauben normalen Rollenstart (INSTALL-P0.2).

## Shared Runtime und Rollen

- ein rollenübergreifender Update-Handshake existiert.
- Rollen können ihre Eventloops kontrolliert verlassen.
- ENERGY besitzt getrennte schnelle und langsame Schedulergruppen.
- ENERGY verwendet eine gemeinsame Heartbeat-Fälligkeitsquelle.
- MASTER unterstützt Einzelnode-/Alle-Auswahl und verfolgt `ACK_DELIVERED`/`ACK_APPLIED` je Ziel.
- RT besitzt echte Startup-Statevariablen und echte MASTER-Startup-Verdrahtung.
- RT verwendet den korrekten Stringwert `TURBINE_MODE_RAMP`.
- RT behandelt die Startup-Rampendauer explizit in Millisekunden.
- `module_lifecycle.update_module_states()` ist im Produktions-Controltick verdrahtet.
- historische RT-Defaultintervalle werden migrationsgesteuert auf 0,10 Sekunden aktualisiert.
- WATER und RT liefern bei Configwrite-Fehlern ein ehrliches `persisted`-Feld im Commandresultat.
- FUEL-Confignormalisierung und asynchroner Request-Lifecycle wurden korrigiert.
- Router-Batches binden bestätigte Ventilzustände an die aktuelle `command_id`.
- REPROCESSOR übergibt COMMS an den Wireless-VALVE-Router.
- REPROCESSOR bricht laufende Feedtransaktionen beim Eintritt in Standby ab.
- VALVE wiederholt fehlgeschlagene Writes bei derselben Command-ID tatsächlich.
- VALVE verwirft den Sorterwrapper nach Fehlern und kann ihn neu binden.
- LOG Collector invalidiert den Free-Space-Cache nach Reclaim-Löschungen.
- der nicht deklarierte `send_ack`-Aufruf im LOG-Flushpfad wurde korrigiert.
- COMMS-Hysterese initialisiert `peer.down` korrekt.

---

# 3. INSTALL-P0.1 – Journal-Replace ist nicht stromausfallsicher

## Status

**BEHOBEN (2026-07-19)**

`installer/journal.lua` verwendet jetzt zwei fest benannte Generationsslots (`SLOT_A`/`SLOT_B`) mit einer im Journalinhalt selbst monoton steigenden `generation`-Zahl statt eines einzelnen Delete-vor-Move-Pfads. Jeder `M.write()`-Aufruf schreibt ausschließlich in den Slot mit der niedrigeren Generation ("stale" Slot); der jeweils andere Slot (aktuell höchste gültige Generation) bleibt dabei unangetastet. Nach dem Schreiben liest `M.write()` den Zielslot zurück und vergleicht Zustand/Generation, bevor der Write als erfolgreich gilt. `xreactor/start.lua` enthält dieselbe Klassifikationslogik dupliziert (bewusst kein `dofile()` von `installer/journal.lua`, siehe dortiger Kommentar) und wählt beim Booten den Slot mit der höchsten gültigen Generation. Ein Crash an jedem Punkt eines Schreibvorgangs lässt damit den zuvor bestätigten Generationsstand im jeweils anderen Slot unverändert und lesbar zurück.

Regressionstests: `tests/installer_journal_state_machine_test.lua` (Crashsimulation nach dem tmp-Write, nach dem Move und bei fehlgeschlagener Rückverifikation; Rundlauf über PREPARED→INSTALLING→VERIFYING→COMMITTED mit alternierenden Slots) und `tests/start_lua_incomplete_install_blocks_role_test.lua` (Bootguard folgt der höheren Generation unabhängig davon, welcher Slot sie trägt).

## Ursprünglicher, jetzt behobener Fehler

(Nachfolgend unverändert als Regressionsreferenz erhalten – bei erneuter Änderung an `installer/journal.lua`/`xreactor/start.lua` MUSS mindestens obiger Testsatz weiterhin grün bleiben.)

## Bestätigter Fehler

`installer/journal.lua` schreibt zunächst `<journal>.tmp`. Existiert das Zieljournal bereits, wird dieses gelöscht. Erst danach wird die Tempdatei zum Ziel verschoben.

Vereinfachter Ablauf:

```text
write journal.tmp
close journal.tmp
delete journal
move journal.tmp -> journal
```

Zwischen `delete journal` und dem erfolgreichen `move` existiert ein Zustand ohne gültiges Hauptjournal.

## Folge

Ein Stromausfall, Chunk-Unload, Move-Fehler oder Neustart in diesem Fenster kann:

- das alte Journal entfernen,
- die Tempdatei zurücklassen,
- beim nächsten Boot kein lesbares Hauptjournal liefern.

`start.lua` behandelt „kein Journal“ aktuell als Normalfall und kann dann versuchen, eine teilweise installierte Rolle zu starten.

## Verbindlicher Fix

Das Journal benötigt eine generationenbasierte, fail-closed Strategie, zum Beispiel:

```text
journal.a
journal.b
journal.pointer
```

oder:

```text
journal
journal.prev
journal.tmp
```

mit folgenden Regeln:

1. neue Generation vollständig schreiben und zurücklesen,
2. Inhalt/State validieren,
3. erst danach aktive Generation umschalten,
4. niemals die letzte gültige Generation löschen, bevor die neue bestätigt ist,
5. Boot prüft Haupt-, Previous- und Tempgeneration,
6. bei Widerspruch gilt die Installation als unvollständig.

## Pflicht-Tests

Crashsimulation nach jedem einzelnen FS-Schritt von `PREPARED`, `INSTALLING`, `VERIFYING` und `COMMITTED`. Kein Zwischenzustand darf einen normalen Rollenstart erlauben, solange nicht eine verifizierte COMMITTED-Generation existiert.

---

# 4. INSTALL-P0.2 – Beschädigtes Journal führt zu Fail-Open

## Status

**BEHOBEN (2026-07-19)**

`installer/journal.lua` (Funktion `slot_read()`/`classify()`) und die dazu bewusst duplizierte, eigenständige Klassifikationslogik in `xreactor/start.lua` unterscheiden jetzt explizit `ABSENT` / `VALID_COMMITTED` / `VALID_INCOMPLETE` / `CORRUPT` / `UNREADABLE`. Nur `ABSENT` (beide Slots existieren nicht – echter Erststart) oder `VALID_COMMITTED` (höchste gültige Generation ist COMMITTED) erlauben einen normalen Rollenstart; `CORRUPT`, `UNREADABLE` und `VALID_INCOMPLETE` lösen alle denselben Recovery-Resume-Pfad aus. Ein Slot, der existiert, sich aber nicht öffnen/lesen/parsen lässt oder kein gültiges Journaltable mit bekanntem `state` und numerischer `generation` liefert, zählt NICHT als „kein Journal vorhanden“.

Regressionstests: `tests/installer_journal_state_machine_test.lua` (ungültige Lua-Syntax, leere Datei, unbekannter `state`-Wert, fehlende `generation` → jeweils CORRUPT/UNREADABLE statt ABSENT; ein korrupter stale Slot darf einen gültigen, höher-generierten COMMITTED-Slot nicht verdrängen) und `tests/start_lua_incomplete_install_blocks_role_test.lua` (Fälle 7+8: kaputte Syntax bzw. leere Datei blockieren den Bootguard).

## Ursprünglicher, jetzt behobener Fehler

(Nachfolgend unverändert als Regressionsreferenz erhalten.)

## Bestätigter Fehler

Sowohl `installer/journal.lua` als auch der unabhängige Parser in `start.lua` liefern bei folgenden Fällen einfach `nil`:

- Datei kann nicht geöffnet werden,
- Datei ist leer oder abgeschnitten,
- Lua-Syntax ist ungültig,
- Ausführung schlägt fehl,
- Ergebnis ist kein gültiges Journaltable.

`nil` bedeutet im Bootpfad zugleich „kein unvollständiges Journal vorhanden“.

## Folge

Ein beschädigtes Journal ist gerade während eines abgebrochenen Updates wahrscheinlich, wird aber nicht als Safetyfehler behandelt. Die Rolle kann auf einem unvollständigen Dateibaum starten.

## Verbindlicher Fix

Journalparser muss unterscheiden:

```text
ABSENT
VALID_COMMITTED
VALID_INCOMPLETE
CORRUPT
UNREADABLE
```

Nur `ABSENT` ohne weitere Installationsreste oder `VALID_COMMITTED` darf normalen Rollenstart erlauben. `CORRUPT` und `UNREADABLE` müssen Recovery erzwingen.

Zusätzlich `.tmp`/`.prev`, erwartete Dateien und Release-/Manifestzustand prüfen.

---

# 5. INSTALL-P0.3 – Configbackup kann Dateien still überspringen

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

`list_files_recursive()` gibt bei fehlgeschlagenem `fs.list()` einfach die bisherige Ergebnisliste zurück. `backup_config_dir()` überspringt jede Datei still, wenn `fs.open()` keinen Handle liefert.

Damit kann ein Backup als erfolgreich gelten, obwohl:

- ein Unterverzeichnis nicht aufgelistet werden konnte,
- einzelne Configdateien nicht gelesen wurden,
- die Sicherung unvollständig ist.

Ein leeres Backup ist nicht von „Configordner war wirklich leer“ unterscheidbar.

## Folge

Der Installer kann anschließend `/xreactor` löschen und Config-/Routing-/Pairingdaten verlieren, obwohl die Vorabverifikation nur die erfolgreich gelesene Teilmenge geprüft hat.

## Verbindlicher Fix

Backupfunktion liefert:

```lua
files, errors
```

Jeder Listing-, Open-, Read- oder Closefehler muss vor dem ersten destruktiven Schritt zum Abbruch führen. Zusätzlich:

- erwartete Dateianzahl und Pfadliste speichern,
- Restore auf exakt dieselbe Menge prüfen,
- existierendes Recoverybackup nicht durch eine unvollständige Folgesicherung überschreiben.

---

# 6. INSTALL-P0.4 – Generische `.xr_prev`-/`.xr_tmp`-Recovery fehlt

## Status

**OFFEN**

`stage.write()` kann zwischen Backupmove und finalem Move einen Zustand hinterlassen, in dem eine beliebige benötigte Datei nur als `.xr_prev` existiert. Für `/xreactor/start.lua` gibt es eine Sonderbehandlung, nicht aber für alle erwarteten Module.

## Verbindlicher Fix

Der frühe Boot-Recoverypfad muss anhand des Journals:

1. erwartete Pfade durchgehen,
2. fehlende Hauptdatei aus gültiger `.xr_prev`-Datei wiederherstellen,
3. `.xr_tmp` nur nach Größe/CRC32 übernehmen,
4. anschließend die vollständige erwartete Dateiliste verifizieren,
5. erst danach Resume oder Rollenstart zulassen.

---

# 7. UPDATE-P0.1 – FUEL/REPROCESSOR bestätigen Wireless-Ventile nicht

## Status

**KRITISCHER SAFETYFEHLER**

## Bestätigter Fehler

FUEL-Quiesce ruft:

```lua
rs_router:shutdown_now("UPDATE_QUIESCE")
return rs_router:get_active_transaction() == nil
```

REPROCESSOR ruft `enter_standby()`, das intern ebenfalls `shutdown_now()` ausführt, und bestätigt anschließend allein über `standby == true`.

`shutdown_now()` löscht die aktive Transaktion sofort und ruft `block_all()`. Bei Wireless-VALVEs sendet `block_all()` jedoch nur neue `SET_VALVE`-Kommandos und erzeugt Pending-ACKs. Es wartet nicht auf deren Bestätigung.

## Folge

Die Rolle meldet `RUNTIME_STOPPED`, obwohl ein drahtloses Ventil:

- das BLOCKED-Kommando noch nicht erhalten hat,
- das Kommando verloren hat,
- den Write abgelehnt hat,
- weiterhin offen ist.

Danach darf der Installer beginnen und die ACK-/Retry-Verarbeitung stoppt zusammen mit der Rollenloop.

## Verbindlicher Fix

Eigener Quiesce-State:

```text
QUIESCE_REQUESTED
CANCEL_TRANSACTION
REQUEST_BLOCK_ALL
WAIT_BLOCK_ACKS
SAFE_OUTPUTS_APPLIED
RUNTIME_STOPPED
```

`RUNTIME_STOPPED` erst, wenn für jedes bekannte Ventil gilt:

```text
aktueller Quiesce-Command bestätigt
applied == true
high == true
command_id stimmt überein
ACK nicht stale
```

Bei Timeout kein Installerstart. Der Knoten bleibt in einer kleinen Quiesce-Safetyloop, die ACKs/Retry weiterverarbeitet.

---

# 8. UPDATE-P0.2 – RT beendet Safety und Regelung ohne SCRAM

## Status

**KRITISCHER SAFETYFEHLER**

## Bestätigter Fehler

RT verwendet den gemeinsamen Eventloop ohne rollenspezifischen `on_quiesce`-Handler. Bei einer Updateanforderung wird daher direkt:

```text
SAFE_OUTPUTS_APPLIED
RUNTIME_STOPPED
```

markiert und die Control-/Safety-Schleife verlassen.

Es gibt in diesem Pfad keinen verpflichtenden:

- Reactor SCRAM,
- Turbine-Safe-State,
- Rod-Safe-Write mit Readback,
- bestätigten Stopp aller Startup-/Controlaktionen.

Der Installer wird erst nach der Quiesce-Bestätigung heruntergeladen und ausgeführt. Netzwerk- und Retryzeiten können erheblich sein.

## Folge

Reaktoren und Turbinen können während Download, Installationsversuchen oder Netzwerkausfällen mit den letzten Stellwerten weiterlaufen, während keine aktive RT-Safetylogik mehr arbeitet.

## Verbindlicher Fix

RT-Quiesce muss einen expliziten Update-Safe-State anwenden und bestätigen:

1. Startupsequenz abbrechen,
2. Reaktoren scrammen beziehungsweise sichere Rodstellung anwenden,
3. Turbinen in dokumentierten sicheren Zustand setzen,
4. Writes/Readback prüfen,
5. erst danach `SAFE_OUTPUTS_APPLIED`,
6. bis zum tatsächlichen Installerstart minimalen Safety-Watchdog aktiv halten.

Alternativ Installer vollständig herunterladen und vorvalidieren, **bevor** die Rolle quiesced wird; die physische Safetybestätigung bleibt trotzdem erforderlich.

---

# 9. UPDATE-P1 – Recovery ist nicht an den Journal-Ref gebunden

## Status

**OFFEN**

Das Journal speichert den Ziel-Ref. `start.lua` lädt beim Recovery jedoch immer den aktuellen `beta/installer`.

## Risiko

Ein Resume kann dadurch einen anderen Commit installieren als den, dessen Installation abgebrochen wurde. Das kann sinnvoll sein, ist aber keine Wiederaufnahme derselben Transaktion und erschwert Diagnose sowie reproduzierbare Recovery.

## Fix

Recoverypolicy explizit festlegen:

- zuerst exakt `journal.ref` versuchen,
- nur nach dokumentierter Prüfung auf aktuellen `beta`-Head wechseln,
- gewählten Recoveryref sichtbar protokollieren,
- Journalgeneration und ursprünglichen/refinalen Zielstand erhalten.

---

# 10. VALVE-P0 – Auto-Pairing vor vollständiger Validierung

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

Beim ersten korrekt adressierten `SET_VALVE` ohne vorhandenes `trusted_source` wird der Absender sofort in Config und RAM übernommen. Erst danach prüft der Handler, ob `message.high` überhaupt ein Boolean ist.

Weitere notwendige Felder wie eine gültige `command_id` werden vor dem Pairing ebenfalls nicht vollständig als Pairingvoraussetzung validiert.

## Folge

Ein erstes ungültiges oder böswilliges Paket kann:

- `trusted_source` dauerhaft auf einen fremden Sender setzen,
- selbst keine Ventilaktion ausführen,
- den echten FUEL-/REPROCESSOR-Sender anschließend aussperren.

## Verbindlicher Fix

Pairing nur nach vollständiger Befehlsvalidierung und erfolgreichem sicheren Apply:

```text
richtiger Kanal
gültiges dst
gültiges src
gültige command_id
high ist Boolean
optional Pairingnonce/Installer-Pairingzustand
Apply erfolgreich
```

Für Safety-Aktoren vorzugsweise explizites Pairingfenster oder Installer-erzeugtes Trustmaterial statt „erstes Funkpaket gewinnt“.

## Pflicht-Tests

- ungültiges Erstpaket verändert `trusted_source` nicht,
- falscher Sender mit gültiger Form während geschlossenem Pairingfenster wird abgelehnt,
- legitimes Pairing überlebt Neustart,
- Persistenzfehler wird sichtbar und führt nicht zu falscher dauerhafter Sicherheitsannahme.

---

# 11. MASTER-P0 – `persisted=false` wird als APPLIED bestätigt

## Status

**KRITISCH OFFEN FÜR DAUERHAFTE SOLLWERTE**

## Bestätigter Fehler

WATER und RT melden bei einem Configwrite-Fehler korrekt:

```lua
{ ok = true, persisted = false }
```

Der RAM-Wert wurde angewendet, überlebt aber keinen Neustart.

`master/config_edits.lua` wertet in `handle_ack_applied()` nur `result.ok` aus. Jeder Wert mit `ok ~= false` wird als `APPLIED` markiert. Sind alle Ziele so markiert, wird der neue Wert als `confirmed_value` übernommen.

## Folge

Die MASTER-UI kann einen Sollwert als vollständig bestätigt anzeigen, obwohl er auf einem oder mehreren Zielnodes nach dem nächsten Reboot verloren geht.

## Verbindlicher Fix

Für persistente Einstellungen Zielstatus unterscheiden:

```text
APPLIED_PERSISTED
APPLIED_VOLATILE
REJECTED
TIMEOUT
```

`confirmed_value` für dauerhaft konfigurierte Werte nur übernehmen, wenn alle Zielnodes `persisted == true` melden. `APPLIED_VOLATILE` muss sichtbar bleiben und darf nicht als dauerhafter Gesamterfolg gelten.

FUEL `SET_RESERVE` ebenfalls auf ehrliche Persistenzsemantik prüfen.

---

# 12. ROUTER-P1 – Abschlussfehler werden nicht vollständig gelatcht

## Status

**OFFEN**

Die pre-export Safety ist deutlich verbessert und an aktuelle Command-IDs gebunden. Nach dem Export bleiben aber Restpunkte:

- wirft `action_fn` einen Fehler, wird gewarnt, die Transaktion läuft trotzdem in `HOLD_OPEN`,
- ein fehlgeschlagenes finales Blockieren führt zu erneutem `block_all()`, danach wird die Transaktion gelöscht,
- der unbestätigte physische Endzustand bleibt nicht als gelatchter Safetyfehler erhalten,
- `block_all()` nach finalem Fehler wartet ebenfalls nicht auf Wireless-ACKs.

## Verbindlicher Fix

Explizite Endzustände:

```text
COMPLETE_SAFE
EXPORT_FAILED
FINAL_BLOCK_PENDING
FINAL_BLOCK_UNCONFIRMED
CANCELLED
```

Ein unbestätigt offenes Ventil muss in Telemetrie/UI/Log erhalten bleiben und eine neue Lieferung blockieren, bis ein aktueller BLOCKED-Zustand bestätigt wurde.

---

# 13. FUEL-P1 – Async-Ergebnis nicht eindeutig an Lieferzyklus gebunden

## Status

**OFFEN**

Der asynchrone Callback aktualisiert weiterhin geteilte Zyklusdaten. Dauert eine Ventiltransaktion länger als das normale Logistikintervall, kann ein neuer Zyklus die globale `last_cycle`-Struktur ersetzen, bevor der alte Callback endet.

Zusätzlich wird der Requeststatus früh als `delivering` bezeichnet, obwohl die Transaktion noch Ventile blockiert oder ACKs abwartet.

## Fix

Stabiler Transaction-Record mit eindeutiger ID und Phasen:

```text
REQUESTING
BLOCKING
OPENING
SETTLING
EXPORTING
HOLDING
FINAL_BLOCK
COMPLETE / ERROR
```

Statistik, UI und Zykluslog referenzieren dieselbe Transaktions-ID.

---

# 14. RT-P1 – Observability und Persistenzrestpunkte

## Status

**OFFEN**

Die großen Startup- und Lifecyclefehler sind behoben. Weiter fehlen beziehungsweise sind nicht ausreichend nachgewiesen:

- Control-Ticks/s,
- maximale Ticklücke/Jitter,
- Reactor-/Turbine-Reglerticks,
- Startup-Lifecycle-Ticks,
- übersprungene/deduplizierte Writes,
- Discovery- und Peripheral-Inspect-Calls/min,
- Deadlineüberschreitungen,
- sicherer Update-Quiesce,
- vollständige Behandlung aller Configwrite-Fehler.

`rt/main.lua` bleibt sehr groß; der ausgeschlossene Strukturtest meldet eine Funktion mit ungefähr 347 Zeilen. Das ist kein unmittelbarer Laufzeitfehler, erhöht aber das Regressionsrisiko.

---

# 15. ENERGY-P1 – Ingame-Isolationsnachweis fehlt

## Status

**STATISCH WEITGEHEND BEHOBEN, INGAME OFFEN**

Heartbeat-Fälligkeitsquelle und Schedulergruppen sind im Code konsolidiert. Cooperative Lua kann jedoch einen wirklich blockierenden Peripheralcall nicht präemptieren.

## Pflicht-Test

Künstlich langsame beziehungsweise fehlerhafte Matrix-/Storageadapter:

- Heartbeatabstand messen,
- Commands und UI-Eingaben prüfen,
- Discoverydeadline prüfen,
- keine Doppelheartbeats,
- kontrolliertes Quiesce während langsamer Calls,
- dokumentieren, welche Blockaden durch CC:Tweaked technisch nicht präemptierbar sind.

---

# 16. WATER-P1 – Ingame- und Rebootnachweis

## Status

**STATISCH WEITGEHEND UMGESETZT**

Offene Abnahme:

- Tanklesefehler führt zuverlässig zu BLOCK_ALL,
- Teilfehler beim Fill-/Drain-Write erzeugt keinen falschen Clusterstate,
- Update-Quiesce bestätigt alle konfigurierten lokalen Ausgänge,
- Target bleibt nach Reboot erhalten,
- `persisted=false` wird von MASTER korrekt dargestellt,
- jeder Touch erzeugt genau eine Aktion.

---

# 17. LOG-P1 – Datenhaltung und Rotation

## Status

**OFFEN**

Behoben sind:

- pauschales Löschen bei Probe-Fehler,
- stale Free-Space-Cache während Reclaim,
- `send_ack`-Nil-Crash.

Weiter verbindlich zu definieren und zu testen:

- maximale Gesamtgröße,
- Mindestaufbewahrungszeit,
- älteste Datei zuerst,
- niemals aktive Datei löschen,
- nie alle Kopien eines noch nicht bestätigten Batches verlieren,
- Verhalten bei voller/read-only/detachter Disk,
- Reboot mitten im Batchflush,
- ACK weiterhin erst nach echter Persistierung.

---

# 18. RELEASE/MANIFEST-P1 – Installierter Commit ist nicht eindeutig sichtbar

## Status

**OFFEN**

`release.lua` enthält weiterhin:

```lua
commit_sha = "beta"
source_ref = "beta"
```

Der Installer arbeitet zwar intern mit einem aufgelösten Ref, die installierte Release-Metadatei dokumentiert diesen konkreten SHA aber nicht.

## Folge

Diagnose und Support können aus der laufenden Installation nicht zweifelsfrei ermitteln, welcher unveränderliche Commit tatsächlich installiert wurde.

## Fix

Installer schreibt zusätzlich eine lokal generierte Installationsmetadatei oder stempelt:

```text
resolved_commit_sha
installed_at
manifest_id
installer_ref
recovery_origin_ref
```

Der statische Kommentar `manifest-v287` am Kopf von `xreactor/manifest.lua` muss ebenfalls mitgeneriert oder entfernt werden.

---

# 19. TEST-P0 – Ausschlusslisten weiter kritisch groß

## Status

**KRITISCH TEILWEISE**

Aktuell ausgeschlossen:

```text
63 Lua-Tests
6 Python-Tests
69 Tests insgesamt
```

Darunter befinden sich zahlreiche `CONTENT_DRIFT`-Einträge in MASTER-, RT- und ENERGY-Pfaden. `CONTENT_DRIFT` ist keine Entwarnung; jeder Eintrag kann entweder einen veralteten Test oder einen echten Produktfehler darstellen.

## Verbindliche Reihenfolge

1. ~~Update-Journal-Crashmatrix~~ BEHOBEN 2026-07-19 (`tests/installer_journal_state_machine_test.lua`),
2. ~~corrupt-journal Boot-Fail-Closed~~ BEHOBEN 2026-07-19 (`tests/installer_journal_state_machine_test.lua`, `tests/start_lua_incomplete_install_blocks_role_test.lua`),
3. Configbackup-Lesefehler,
4. FUEL/REPROCESSOR Quiesce-ACK-Safety,
5. RT-Quiesce-SCRAM,
6. VALVE-Pairing vor/nach Validierung,
7. MASTER `persisted=false`,
8. Router-Finalblock-Latch,
9. FUEL Transaction-ID/Zyklusbindung,
10. ausgeschlossene MASTER-/RT-Semantiktests,
11. ENERGY-Lasttests,
12. LOG-Reboot-/Full-Disk-Tests.

## CI-Status

Für den geprüften ausführbaren Head wurde über die verfügbare GitHub-Schnittstelle weder ein kombinierter Statuscheck noch ein zugeordneter Pull-Request-Workflowlauf zurückgegeben. Ein grüner Lauf ist damit nicht nachgewiesen.

---

# 20. Verbindliche Bearbeitungsreihenfolge

1. ~~Journal fail-closed und generationensicher machen.~~ BEHOBEN 2026-07-19.
2. ~~Beschädigtes/unlesbares Journal als Recoveryzustand behandeln.~~ BEHOBEN 2026-07-19.
3. Configbackup bei jedem Listing-/Readfehler abbrechen.
4. FUEL/REPROCESSOR Quiesce bis zu bestätigten Wireless-BLOCK-ACKs weiterlaufen lassen.
5. RT vor Runtime-Stopp in einen bestätigten sicheren Hardwarezustand fahren.
6. VALVE-Pairing erst nach vollständiger Validierung und sicherem Apply durchführen.
7. MASTER-Persistenzstatus korrekt auswerten.
8. generische `.xr_prev`-/`.xr_tmp`-Recovery implementieren.
9. Router-Abschlusszustände und Finalblockfehler latchen.
10. FUEL Async-Resultat an stabile Transaktions-ID binden.
11. Release-Metadaten mit aufgelöstem Installations-SHA ergänzen.
12. Testausschlusslisten systematisch abbauen.
13. danach vollständige Ingame-Update-, Stromausfall-, Funkverlust-, Reconnect- und Lasttests.

---

# 21. Definition of Done

## Installer und Update

- Jeder Stromausfallpunkt führt entweder zu einer verifizierten alten oder verifizierten neuen Installation, niemals zu ungeschütztem Rollenstart.
- Fehlendes, beschädigtes oder unlesbares Journal wird fail-closed behandelt.
- Configbackup ist vollständig oder der Installer bricht vor dem Löschen ab.
- `.xr_prev`/`.xr_tmp` werden anhand von Journal und CRC sicher wiederhergestellt.
- installierter Commit-SHA ist lokal eindeutig sichtbar.

## Quiesce

- FUEL/REPROCESSOR: alle Wireless-VALVEs aktuell als BLOCKED bestätigt.
- VALVE: physischer sichere Zustand bestätigt.
- WATER: alle Fill-/Drain-Ausgänge erfolgreich deaktiviert.
- RT: Reaktoren/Turbinen in dokumentiertem, bestätigtem Safe-State.
- erst danach `RUNTIME_STOPPED` und Installerstart.

## MASTER

- `APPLIED_PERSISTED`, `APPLIED_VOLATILE`, `REJECTED` und `TIMEOUT` sind unterscheidbar.
- dauerhafter bestätigter Wert wird nur nach `persisted=true` auf allen Zielen übernommen.
- Einzelnode- und Alle-Zielstatus bleiben sichtbar.

## Routing

- kein Export ohne aktuelle Command-ID-gebundene Block-/Open-Bestätigung,
- Actionfehler sichtbar und sauber abgeschlossen,
- finales Blockieren bestätigt oder als gelatchter Safetyfehler erhalten,
- neue Lieferung bei unbestätigtem Endzustand blockiert.

## Tests / CI

- keine kritischen Safety-, Update-, Persistenz- oder Routingtests auf Ausschlussliste,
- aktueller `beta`-Head besitzt einen nachgewiesenen grünen Workflowlauf,
- Stromausfallmatrix, Funkverlust, Reconnect, Reboot und Update werden automatisiert beziehungsweise ingame reproduzierbar dokumentiert.
