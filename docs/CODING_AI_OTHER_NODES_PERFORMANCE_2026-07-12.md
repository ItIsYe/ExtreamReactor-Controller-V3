# Aktueller Gesamt-Audit – XReactor Controller V3

Stand: 2026-07-16  
Branch: `beta`  
Geprüfter ausführbarer Code-Head: `12012b58161ea4b5aef8b0baae31949dfc85362f`  
Geprüfte Release: `beta-v438` / `manifest-v438`  
Manifest-Dateien: `166`

## Zweck

Diese Datei ist die aktuelle, rollenübergreifende Aufgabenquelle für Coding-AI und manuelle Prüfungen. Sie ersetzt die vorherige widersprüchliche Fassung vollständig.

Geprüft wurden nicht nur einzelne Nodes, sondern:

- Installer und Auto-Update,
- Manifest und Rollen-Scope,
- Shared Runtime und Service-Manager,
- MASTER,
- RT,
- ENERGY,
- WATER,
- FUEL,
- REPROCESSOR,
- VALVE,
- LOG Collector,
- Tests und CI.

Commitmeldungen und bestehende Audit-Aussagen wurden nicht als Beweis übernommen. Bewertet wurde der tatsächliche Code auf `beta`. Peripheral-, Netzwerk-, Neustart-, Update- und Lastverhalten muss zusätzlich in CC:Tweaked/Ingame nachgewiesen werden.

---

# 1. Gesamtstatus

| Bereich | Tatsächlicher Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Benutzerconfig | **TEILWEISE UMGESETZT** | einheitlicher SHA für Manifest und Dateien, CRC beim Write, keine pauschale Log-Löschung |
| Manifest / Rollen-Scope | **TEILWEISE UMGESETZT** | `feed_router.lua`/`redstone_router.lua`/`ui_pages.lua`-Scopes behoben (Abschnitt 10/17); `optional/speaker_alarm.lua` weiterhin ohne `required_for` |
| Shared Runtime | **WEITGEHEND UMGESETZT** | ENERGY umgeht die Trennung mit einem Volltick im Matrix-Thread |
| MASTER | **TEILWEISE UMGESETZT** | Sequencer-Aufrufsyntax und echter MASTER→RT-Modulstart behoben (Abschnitt 3); Einzelnode-/ACK-UI (Abschnitt 15) weiterhin offen |
| RT | **WEITGEHEND UMGESETZT** | Discovery-Deadline und Altconfig-Migration behoben (Abschnitt 4/5); Controlmetriken (Jitter/Ticklücke, siehe Abschnitt 5 „Zusätzlich offen“) weiterhin offen |
| ENERGY | **WEITGEHEND UMGESETZT** | Scheduler-/Heartbeat-Trennung behoben (Abschnitt 13) |
| WATER | **WEITGEHEND UMGESETZT** | Ingame-, Neustart- und Update-Regressionsnachweis |
| FUEL | **WEITGEHEND UMGESETZT** | Startabsturz, Export-vor-Ventilbestätigung, Async-Lifecycle und ungültiges Routing→Direktexport behoben (Abschnitt 6/7/8/9); gemeinsamer Ventilkanal (VALVE, Abschnitt 12) ebenfalls behoben |
| REPROCESSOR | **WEITGEHEND UMGESETZT** | unvollständige Installation, Export-vor-Ventilbestätigung und Export trotz Standby behoben (Abschnitt 8/10/11) |
| VALVE | **WEITGEHEND UMGESETZT** | Failed-Write-Retry und Fail-Safe-Zeitstempel behoben (Abschnitt 12) |
| LOG Collector | **KRITISCH TEILWEISE** | Probe-Fehler kann komplettes Logarchiv löschen |
| Tests / CI | **TEILWEISE UMGESETZT** | 66 Lua- und 6 Python-Tests bleiben ausgeschlossen; kein grüner Head-Check nachgewiesen |
| Dokumentation | **AKTUELL** | diese Datei ist die einzige aktuelle allgemeine Auditquelle |

## Produktionsurteil

`beta-v438` ist **nicht produktionsreif**. Die kritischsten Risiken sind:

1. FUEL kann beim Start mit Default-/Teilconfig abbrechen.
2. REPROCESSOR kann ohne zwingend benötigte Datei installiert werden.
3. Ventile sind vor einem Export nicht vollständig bestätigt.
4. MASTER-Startup sendet Befehle, die RT wegen eines Stub-Callbacks ablehnt.
5. ENERGY verletzt seine eigene Schedulertrennung.
6. LOG- und Installerpfade können vorhandene Logs pauschal löschen.

---

# 2. Seit `beta-v434` tatsächlich geändert

Zwischen dem vorherigen Audit-Commit und `beta-v438` wurden fünf Commits zusammengeführt. Produktivcode wurde nur in folgenden Bereichen geändert:

- MASTER `startup_sequencer.lua`,
- RT `discovery_runtime.lua`, `main.lua`, `turbine_control.lua`,
- Manifest und Release,
- Tests und Ausschlusslisten.

FUEL, REPROCESSOR, VALVE, ENERGY, WATER, LOG und der Installer wurden in dieser Runde nicht funktional geändert. Deren zuvor bestätigte Fehler bestehen deshalb weiter, sofern sie unten nicht ausdrücklich anders bewertet werden.

## Tatsächlich verbessert

### MASTER

- `enqueue`, `tick`, `notify_ack`, `notify_stable` und `handle_timeout` verwenden jetzt Doppelpunkt-Definitionen passend zu den realen Aufrufen.
- Der bisherige Argumentverschiebungsfehler ist damit behoben.
- Ein Regressionstest prüft den Sequencer-internen Lebenszyklus.

### RT

- Capability-Cache normalisiert Singular-/Plural-Kindnamen.
- Neue Geräte werden gezielter gecacht.
- Nicht mehr gebundene Geräte werden aus dem jeweiligen Cache entfernt.
- zusätzliche Tests für Cache-Invalidierung und Kindnormalisierung wurden ergänzt.

### Tests

- sechs zuvor ausgeschlossene Tests wurden repariert beziehungsweise aktualisiert.
- aktuell ausgeschlossen: 66 Lua-Tests und 8 Python-Tests, insgesamt 74.

### Manifest

- der frühere doppelte `core/bootstrap.lua`-Eintrag ist im aktuellen Manifest nicht mehr vorhanden.
- Release wurde auf `beta-v438` / `manifest-v438` angehoben.

---

# 3. MASTER-P0 – Startup-Sequenz bleibt end-to-end funktionslos

## Status

**BEHOBEN (2026-07-16)**

`nodes/rt/main.lua` verdrahtete `request_startup_if_needed`/`start_module` (in
`build_command_ctx()`) sowie `build_modules`/`refresh_module_peripherals` (in
`build_discovery_context()`) bisher als reine No-Op-Stubs, und sowohl
`make_lifecycle_ctx()` als auch `state_ctx` hatten `modules = {}` (immer neu
bzw. dauerhaft leer) und Startup-State (`get_active_startup` etc.) als
No-Op-Closures ("RT-Node hat keine Modul-Startup-Sequenz"). Dadurch blieb das
Modul-Register für die gesamte RT-Node-Laufzeit leer — `module_lifecycle.
start_module()`/`process_startup()` liefen ins Leere, RT's eigene lokale
STARTUP-Sequenz (`state_handlers.lua` `startup_on_tick`) kam nie über OFF
hinaus, und MASTER-gesteuerte `STARTUP_STAGE`-Kommandos wurden immer mit
`STARTUP_REJECTED` beantwortet.

Fix:

- Modul-globaler, persistenter Startup-State (`modules_registry`,
  `active_startup_id`, `startup_queue_list`, `startup_started_ms_value`,
  `startup_watchdog_tripped_value`) statt lokaler No-Op-Stubs; `make_
  lifecycle_ctx` per Vorwärtsdeklaration auch für `build_command_ctx()`
  (welches vor `init()` läuft) erreichbar gemacht.
- `build_discovery_context()`'s `build_modules`/`refresh_module_peripherals`
  mutieren jetzt tatsächlich die geteilte `modules_registry`-Tabelle in
  place (Neuzugänge ergänzt, verschwundene Geräte entfernt, bestehender
  Fortschritt bleibt über Re-Discovery-Scans erhalten).
- `build_command_ctx()`'s `start_module`/`request_startup_if_needed`
  delegieren jetzt an die echte `module_lifecycle`-/`state_handlers`-Logik
  mit vollem Kontext, statt nichts zu tun.
- `module_lifecycle.process_startup(ctx)` läuft jetzt jeden Control-Tick
  (vorher im gesamten Projekt nirgends aufgerufen — toter Code).
- `state_ctx`'s Startup-State-Getter/Setter, `start_module` und `handle_
  startup_timeout` sind jetzt echte Closures statt Stubs; `handle_startup_
  timeout` verdrahtet `startup_diagnostics.lua` (vorher komplett unbenutzt)
  über einen neuen `update_status_snapshot()`-Helper (Max-Temperatur/
  Durchschnitts-RPM direkt aus den gebundenen Peripheriegeräten) und einen
  neuen `broadcast_status(level)`-Helper (`comms:publish_status(build_
  status_payload(level))`).
- `build_status_payload()` reicht `modules`/`active_startup`/`startup_queue`
  und `startup_watchdog_tripped` jetzt echt durch (waren hart auf
  `{}`/`nil`/`{}`/`false` verdrahtet) — MASTER erhält damit über die normale
  Status-Telemetrie sowohl den Modul-Fortschritt (`message_handlers.lua`
  prüft `payload.modules[id].state == "STABLE"` für `notify_stable`) als
  auch den degradierten Health-Zustand nach einem Watchdog-Timeout.

Pflicht-Test: `tests/rt_master_startup_end_to_end_test.lua` (neu) — treibt
den echten `command_handler.lua`-Pfad (`STARTUP_STAGE` → `ctx.start_module`
→ `module_lifecycle`) mit Mock-Peripherals: Turbine startet zuerst, Reactor
wird per `module_lifecycle`-eigenem "Startup busy"-Guard blockiert bis die
Turbine bestätigt stabil ist, unbekannte Modul-ID wird abgelehnt, SAFE lehnt
jeden Startup-Befehl ab, und ein Watchdog-Timeout versetzt den Node in
LIMITED/EMERGENCY inklusive durchschlagender `CONTROL_DEGRADED`-Health.
Verifiziert per `git stash`, dass der Test mit dem alten No-Op-Stub exakt am
ersten Schritt (`start_module should be accepted`) fehlschlägt.

## Status (vor dem Fix)

**KRITISCH OFFEN**

## Behobener Teil

Der Colon/Dot-Aufrufbug in `master/startup_sequencer.lua` wurde korrekt behoben. Der Sequencer kann nun:

- Nodes einreihen,
- Schritte planen,
- `STARTUP_STAGE` senden,
- auf ACK/Stable/Timeout reagieren.

## Weiterhin bestätigter Blocker

Der RT-Command-Handler verarbeitet `STARTUP_STAGE` über:

```lua
local module, detail = ctx.start_module(...)
```

Der echte RT-Command-Context in `nodes/rt/main.lua` verdrahtet jedoch weiterhin:

```lua
request_startup_if_needed = function() end,
start_module = function() end,
```

`start_module()` gibt damit immer `nil` zurück. Der RT-Handler beantwortet jeden echten Startup-Schritt mit `STARTUP_REJECTED`.

## Folge

Der neue MASTER-Test beweist nur den internen Sequencerablauf mit einem Mock-COMMS-Objekt. Er prüft nicht:

```text
MASTER Sequencer
→ COMMS Command
→ RT Command Handler
→ echtes Modul
→ ACK_APPLIED
→ Stable-Telemetrie
→ nächster Schritt
```

Die MASTER-gesteuerte Modulstartsequenz ist daher trotz Methodensyntax-Fix weiterhin nicht nutzbar.

## Verbindlicher Fix

- RT benötigt einen echten `start_module(module_id, module_type, ramp_profile)`-Callback.
- Callback muss die existierende Modul-/Lifecycle-Logik verwenden, nicht einen zweiten Parallelpfad schaffen.
- ACK darf erst `ok=true` melden, wenn der Startauftrag wirklich angenommen wurde.
- MASTER darf erst nach passender Stable-Telemetrie zum nächsten Modul wechseln.
- Fehler, unbekannte Module, SAFE und Timeout müssen sichtbar und sicher behandelt werden.

## Pflicht-Test

Ein End-to-End-Test mit echten Produktionsmodulen muss mindestens prüfen:

1. Turbine wird zuerst gestartet.
2. Reactor folgt erst nach bestätigter Turbinenstabilität.
3. unbekannte Modul-ID wird abgelehnt.
4. SAFE lehnt Startup ab.
5. Timeout versetzt den Zielnode in den vorgesehenen degradierten Zustand.

---

# 4. RT-P0 – Discovery-Slowdown funktioniert nicht wie dokumentiert

## Status

**BEHOBEN (2026-07-16)**

`services/discovery_service.lua`s `tick()` aktualisiert `self.last_scan` nur bei einem tatsächlich ausgeführten Scan — ein übersprungener fälliger Scan lässt `last_scan` unverändert, wodurch `due` (`ts - last_scan >= interval*1000`) ab diesem Zeitpunkt bei **jedem** folgenden RT-Schedulertick (~alle 0,1s) wahr blieb. `nodes/rt/main.lua`s alter Zähler (`discovery_slow_skip_count += 1` pro `should_discover()`-Aufruf) zählte dadurch Scheduler-Ticks statt echter 10s-Scanintervalle — erreichte `DISCOVERY_SLOW_MULTIPLIER=6` bereits nach ~0,6s statt der beabsichtigten ~60s. Empirisch am tatsächlichen Verhalten bestätigt (kein Konstrukt).

Fix: `should_discover()` verwendet jetzt eine echte Wanduhr-Deadline (`discovery_next_slow_scan_at`, in ms) statt eines Aufruf-Zählers — bekommt den Discovery-Service selbst als ersten Parameter (`service.interval` für die tatsächlich konfigurierte Basisrate) und vergleicht direkt gegen die aktuelle Zeit. Eine weit in der Zukunft liegende Deadline wird bei Erreichen genau einmal ausgeführt und von diesem Zeitpunkt aus neu gesetzt — kein Scanburst durch mehrere „verpasste“ Zwischenschritte. Die zuvor zu stark formulierte Attach-/Detach-Aussage („setzt den Zähler sofort zurück“) wurde auf die ehrliche Beschreibung korrigiert (Erkennung erst beim nächsten fälligen Scan, danach sofortige Rücksetzung auf normale Kadenz) — kein eventgetriebener Discovery-Trigger eingeführt, da RT-Discovery bewusst nicht `wants_events` nutzt (Performance).

Pflicht-Test: `tests/rt_discovery_stable_slowdown_test.lua` (komplett neu geschrieben, ersetzt den vom Audit als Testlücke identifizierten alten Test) — treibt die echten `should_discover()`/`discover_with_stability_tracking()`-Funktionen über eine Fake-Clock mit 100ms-Scheduler-Tick und einer `discovery_service.lua`-äquivalenten `due`/`last_scan`-Simulation (nicht nur direkte `should_discover(..., due=true)`-Aufrufe): 190 Sekunden stabile Hardware zeigen tatsächliche ~60s-Scanabstände ohne Burst; eine Bindungsänderung kurz nach einem Scan wird innerhalb der dokumentierten maximalen Erkennungszeit (~60s im Slow-Modus) erkannt und setzt sofort auf die normale ~10s-Kadenz zurück. Verifiziert per `git stash`, dass der Test (durch die Extraktion der jetzt geänderten Quelltext-Marker) mit dem alten Code fehlschlägt.

## Status (vor dem Fix)

**KRITISCHER PERFORMANCE-/VERHALTENSFEHLER**

## Bestätigter Fehler

Die neue Logik soll nach drei stabilen Scans nur noch jeden sechsten **fälligen 10-s-Scan** ausführen und so ungefähr 60 Sekunden erreichen.

Tatsächlich gilt:

- `discovery_service` setzt `last_scan` nur bei einem wirklich ausgeführten Scan.
- ein übersprungener fälliger Scan verändert `last_scan` nicht.
- ab diesem Zeitpunkt bleibt `due == true` bei jedem nachfolgenden RT-Schedulertick.
- RT läuft mit ungefähr 0,1 Sekunden Schedulerintervall.
- `discovery_slow_skip_count` erhöht sich daher alle 0,1 Sekunden.
- der sechste Tick führt den Scan nach ungefähr 0,5 Sekunden Zusatzwartezeit aus.

Effektiver Abstand ist damit ungefähr:

```text
10,0 s + 0,5 s
```

und nicht:

```text
60 s
```

## Attach-/Detach-Aussage ebenfalls zu stark

Der Discovery-Service besitzt kein `wants_events=true` und wird daher nicht direkt durch Peripheral-Events getickt. Eine echte Änderung setzt den Zähler erst zurück, wenn der nächste Scan sie entdeckt. Sie setzt nicht „sofort“ nach einem Attach-/Detach-Event zurück.

## Testlücke

`rt_discovery_stable_slowdown_test.lua` ruft `should_discover(..., due=true)` sechsmal direkt hintereinander auf. Der Test modelliert weder:

- `last_scan`,
- reale Zeit,
- 0,1-s-Scheduler-Ticks,
- Peripheral-Events.

Der Test bestätigt daher nur den Zähler, nicht das versprochene Zeitverhalten.

## Verbindlicher Fix

Eine echte Deadline verwenden:

```lua
next_discovery_at = now + interval_ms
```

oder bei einem Skip den nächsten zulässigen Scan explizit verschieben. Attach/Detach entweder:

- als Event an einen gezielt eventfähigen Discovery-Trigger weiterleiten, oder
- ehrlich als „wird beim nächsten Poll erkannt“ dokumentieren.

## Pflicht-Test

- Fake-Clock über mindestens 180 Sekunden.
- Scheduler-Tick alle 100 ms.
- stabile Hardware: Scanabstände tatsächlich ungefähr 60 Sekunden.
- Änderung kurz nach einem Scan: dokumentierte maximale Erkennungszeit einhalten.
- kein Scanburst nach übersprungener Deadline.

---

# 5. RT-P1 – Altconfig-Migration und Schedulernachweis

## Status

**BEHOBEN (Altconfig-Migration, 2026-07-16) — Schedulernachweis (siehe „Zusätzlich offen“ unten) weiterhin offen**

`nodes/rt/config.lua` hatte bereits ein `version`/`CURRENT_VERSION`-Feld, das aber im gesamten Projekt nirgends gelesen/verglichen wurde — ein reines Deklarations-Feld ohne Wirkung. Eine bestehende, persistierte `config/rt.lua` mit den historischen Defaults `autonom.reactor_adjust_interval=5.0`/`reactor_adjust_interval_individual=1.0` (vor dem 10-Hz-Fix) blieb dadurch dauerhaft auf der alten, viel zu langsamen Regelkadenz — beide sind gültige Zahlen, die generische `type(...) ~= "number"`-Normalisierung fasst sie nie an.

Fix:

- `config.lua`s `CURRENT_VERSION` auf `5` erhöht (das erste Mal, dass dieses Feld tatsächlich benutzt wird).
- Neue `config_normalizer.migrate_schema_version()`: migriert **gezielt nur die historischen Default-WERTE** (5.0/1.0) auf die neuen 0.10-Defaults, gesteuert über `config.version` — ein bewusst vom Nutzer auf einen anderen Wert gesetztes Intervall (z. B. 2.5) bleibt unangetastet. `main.lua` persistiert das Ergebnis sofort nach der Migration (`utils.write_config`), damit sie garantiert nur einmal läuft.
- `reactor_adjust_interval_individual` bekommt zusätzlich eine reguläre `type(...) ~= "number"`-Normalisierung in `validate_config()` (fehlte bisher komplett — wurde nur über einen impliziten `or 0.10`-Fallback an der Nutzungsstelle in `reactor_control.lua` abgesichert).

Pflicht-Test: `tests/rt_config_interval_schema_migration_test.lua` (neu) — treibt die echte `config_normalizer.lua` direkt: historische Defaults werden migriert; bewusst benutzerdefinierte Werte bleiben unangetastet (nur der Versionsstand wird trotzdem angehoben); ein bereits migrierter Stand wird nicht erneut verändert (auch wenn zufällig wieder 5.0/1.0 vorliegt); ein Config-Stand ganz ohne `version`-Feld wird ebenfalls migriert. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

Neue Defaults stehen auf:

```lua
reactor_adjust_interval = 0.10
reactor_adjust_interval_individual = 0.10
```

Bestehende persistierte Werte wie `5.0` und `1.0` bleiben jedoch gültige Zahlen. Der Normalizer ersetzt nur fehlende beziehungsweise nichtnumerische Werte und migriert den Individualwert nicht gezielt.

## Folge

- neue Installation: neue Defaults,
- bestehender aktualisierter Node: möglicherweise weiterhin 1- beziehungsweise 5-s-Regelintervall.

## Verbindlicher Fix

- Configschema erhöhen.
- bekannte historische Defaultwerte gezielt migrieren.
- bewusst benutzerdefinierte Werte nicht blind überschreiben.
- Migration nur einmal ausführen und persistieren.

## Zusätzlich offen

- Control-Tick besitzt weiterhin keine eigene explizite Deadline-/Jittermetrik.
- UI und Telemetrie bauen weiterhin getrennte vollständige Gerätesnapshots.
- `build_discovery_context().build_capabilities()` ruft intern immer den Turbinen-Key auf; das Ergebnis wird später zwar in den Reaktorcache kopiert und der temporäre Eintrag bereinigt, die Verdrahtung ist dennoch unnötig indirekt und fehleranfällig.

## Pflicht-Metriken

- Control-Ticks/s,
- maximale Ticklücke,
- Reactor-/Turbine-Reglerticks,
- übersprungene Writes,
- Discovery-Calls/min,
- Peripheral-Inspect-Calls/min,
- Deadlineüberschreitungen.

---

# 6. FUEL-P0 – Frische FUEL-Config kann den Start abbrechen

## Status

**BEHOBEN (2026-07-16)**

`nodes/fuel/config_normalizer.lua` initialisiert:

```lua
lg.reactors
lg.waste
```

aber nicht:

```lua
lg.destinations
```

Anschließend wird ausgeführt:

```lua
for i, dest in ipairs(lg.destinations) do
```

Die aktuelle FUEL-Defaultconfig enthält ebenfalls kein `destinations`-Feld.

## Folge

Eine frische oder teilweise Config kann mit `ipairs(nil)` abbrechen, bevor die Node betriebsbereit ist.

## Fix

Alle später iterierten Logistikfelder vorab normalisieren:

```lua
lg.reactors = type(lg.reactors) == "table" and lg.reactors or {}
lg.waste = type(lg.waste) == "table" and lg.waste or {}
lg.sources = type(lg.sources) == "table" and lg.sources or {}
lg.destinations = type(lg.destinations) == "table" and lg.destinations or {}
lg.routes = type(lg.routes) == "table" and lg.routes or {}
```

## Umsetzung

`nodes/fuel/config_normalizer.lua` normalisiert jetzt auch `lg.destinations`, `lg.sources` und `lg.routes` auf Tabellen (analog zum bereits vorhandenen Muster für `lg.reactors`/`lg.waste`), bevor der Destination-Validierungsloop `ipairs(lg.destinations)` läuft.

## Pflicht-Test

Funktionaler Test `tests/fuel_config_normalizer_logistics_fields_test.lua` (lädt das echte Modul und die echte FUEL-Defaultconfig, kein Mock der Normalisierungslogik selbst):

- leere Config — vorher: Crash bei `ipairs(nil)`, jetzt: ok,
- aktuelle Defaultconfig (`nodes/fuel/config.lua`) als Benutzerconfig — vorher: Crash, jetzt: ok,
- `logistics={}` — vorher: Crash, jetzt: ok, alle drei Felder leere Tabellen,
- ungültige Typen (`destinations="not-a-table"`, `sources=42`, `routes=false`) — vorher: Crash mit anderem `ipairs`-Fehlertext, jetzt: alle drei werden durch leere Tabellen ersetzt,
- Regressionstest verifiziert zusätzlich per `git stash`, dass der Test ohne den Fix tatsächlich mit exakt dem im Audit beschriebenen Fehler fehlschlägt.

`Start bis Node ready` (voller RT-Boot mit Mock-Peripherals) ist nicht Teil dieses Tests — das ist ein Ingame-/Integrationstest, kein isolierter Modultest.

---

# 7. FUEL-P0 – Async-Lieferung verliert Request und Ergebnis

## Status

**BEHOBEN (2026-07-16)**

`nodes/fuel/logistics_router.lua`'s `_run_supply()` setzte `current_request` direkt nach `rs:begin_transaction()` wieder auf `nil`, während der spätere, asynchrone `do_export()`-Callback (läuft erst, sobald `redstone_router.lua`'s Zustandsmaschine `WAIT_SETTLE` verlässt) `current_request.state` schrieb — Nil-Zugriff im Callback. Zusätzlich wurden `exported`/`errors`/`cycle_log` sofort nach dem *Start* der Transaktion ausgewertet, nicht nach ihrem tatsächlichen Abschluss.

Fix:

- `redstone_router.lua`'s `begin_transaction()` akzeptiert jetzt einen optionalen vierten Parameter `opts.on_error(reason)`, den `_fail_transaction()` immer aufruft, wenn eine Transaktion abbricht, BEVOR `action_fn` je lief (Ventil-ACK-Fehler, Phasen-Timeout) — der Aufrufer hat damit garantiert genau einen von zwei Abschluss-Pfaden.
- `current_request` bleibt jetzt bis zum echten Abschluss bestehen (`do_export()` erfolgreich/fehlgeschlagen ODER `on_error()`), nicht mehr bis zum bloßen *Start* der Transaktion.
- `total_exported`/`total_errors` und der Zykluslog-Eintrag (`last_cycle.moves`) werden jetzt ausschließlich im jeweiligen Abschluss-Callback geschrieben, direkt in `self._state` (nicht in den lokalen `exported`/`cycle_log`-Variablen des Start-Zyklus, da der Export ggf. erst in einem späteren Zyklus tatsächlich passiert).
- Dieselbe `on_error`-Anbindung wurde auch in `nodes/reprocessor/feed_router.lua` ergänzt (setzt `last_error` bei einem vor dem Export abgebrochenen Transfer, statt ihn stumm zu verlieren).

Pflicht-Test: `tests/fuel_logistics_async_delivery_lifecycle_test.lua` (neu) — treibt `logistics_router.lua` mit einem kontrollierbaren Mock-`rs_router` (isoliert von der in Abschnitt 8 separat getesteten `redstone_router.lua`-Zustandsmaschine) und beweist: erfolgreicher Async-Export, Callback-Fehler, Abbruch vor dem Export (ACK-Timeout-Äquivalent über `on_error`), Busy/Skip-Fall, korrekte Exportmenge, `current_request` bleibt bis zum Abschluss sichtbar. Verifiziert per `git stash`, dass der Test mit dem alten Verhalten fehlschlägt.

## Status (vor dem Fix)

**KRITISCH OFFEN**

FUEL setzt `current_request`, startet eine asynchrone Redstone-Transaktion und setzt `current_request` direkt danach wieder auf `nil`.

Der spätere Exportcallback greift jedoch auf:

```lua
self._state.current_request.state
```

zu.

## Folgen

- Nil-Zugriff im späteren Callback möglich.
- `moved`, `exp_ok`, `exported` und `cycle_log` werden im Starttick ausgewertet, bevor der spätere Export erfolgt.
- Statistik und UI können `0 exportiert` melden, obwohl später exportiert wurde.
- Requestzustand verschwindet, während die Transaktion noch aktiv ist.

## Verbindlicher Fix

Ein langlebiger Transaktionskontext muss bis `COMPLETE` oder `ERROR` bestehen bleiben. Exportstatistik, Zykluslog und Requestabschluss werden ausschließlich im Abschlusscallback geschrieben.

## Pflicht-Test

- erfolgreicher Async-Export,
- Callback-Fehler,
- ACK-Timeout,
- Shutdown während Routing,
- korrekte Exportmenge,
- Request bleibt bis Abschluss sichtbar.

---

# 8. ROUTER-P0 – Export vor vollständiger Ventilbestätigung

## Status

**BEHOBEN (2026-07-16)**

`nodes/fuel/redstone_router.lua`'s Transaktions-Zustandsmaschine (`begin_transaction`/`tick`) gate'te den Export über eine feste Settle-Zeit (`settle_until`) statt über echte Ventil-Bestätigung — ein noch `pending` ACK löste keinen Fehler aus, der Export lief nach Ablauf der Settle-Zeit trotzdem los. Zusätzlich enthielt `watched_keys` nur die Zielpfad-Ventile; ein fehlgeschlagenes Blockieren eines Nebenpfads (`open_path_to()`'s Rückgabewert dafür wurde nicht ausgewertet) verhinderte den Export nicht.

Fix: `begin_transaction()`/`tick()` durch eine zweiphasige Zustandsmaschine ersetzt (`WAIT_BLOCK_ACKS` → `WAIT_OPEN_ACKS` → `WAIT_SETTLE` → `EXPORT` → `HOLD_OPEN` → `WAIT_FINAL_ACKS` → Abschluss), entlang der im Audit vorgegebenen Ziel-State-Machine:

- Phase 1 blockiert und bestätigt **alle** bekannten Ventile (nicht nur Nebenpfade) als deterministischen Ausgangszustand.
- Phase 2 öffnet erst danach den Zielpfad und wartet ebenfalls auf dessen vollständige Bestätigung.
- Bestätigung heißt für Netzwerk-Ventile: ACK vorhanden, `applied == true`, bestätigtes `high` entspricht dem angeforderten Wert (neue Hilfsfunktionen `_request_valve_batch`/`_check_valve_batch`, wiederverwenden die bestehende `pending_valve_acks`/`confirmed_valve_state`-Nachverfolgung aus VALVE-P1). Für lokale/eingebaute Ventile ist der synchrone `_set_valve()`-Rückgabewert die Bestätigung.
- `WAIT_SETTLE` ist jetzt nur noch eine zusätzliche physische Pufferzeit NACH bestätigtem Zustand, kein Ersatz mehr für die Bestätigung.
- Jeder Fehlschlag oder ein Phasen-Timeout (`VALVE_PHASE_TIMEOUT_MS`, zusätzliches Sicherheitsnetz über das einzelne ACK-Timeout hinaus) bricht sofort über `_fail_transaction()` mit `block_all()` ab.
- Nach dem Export wird zusätzlich versucht, das finale Blockieren zu bestätigen (`WAIT_FINAL_ACKS`), bevor die Transaktion als abgeschlossen gilt.
- `open_path_to()` (Teil des ursprünglichen Bugs — wertete Nebenpfad-Blockierfehler gar nicht aus) wurde entfernt, da vollständig durch die neue Zustandsmaschine ersetzt.

Pflicht-Test: `tests/redstone_router_valve_confirmation_gate_test.lua` (neu) — treibt die echte Zustandsmaschine mit einem Mock-Funkmodem: Export läuft nicht, solange irgendein Ventil (Zielpfad oder Nebenpfad) unbestätigt ist, egal wie viele Ticks/wie viel Zeit vergeht; ein fehlgeschlagenes Blockieren eines Nebenpfads bricht die Transaktion ab, bevor Export je läuft; ein dauerhaft unbeantwortetes Ventil löst den Phasen-Timeout aus statt endlos zu warten; vollständiger Zyklus inklusive `HOLD_OPEN`/`WAIT_FINAL_ACKS`. Verifiziert per `git stash`, dass der Test mit der alten Zustandsmaschine (direkter Sprung nach `WAIT_SETTLE` ohne Blockier-Bestätigungsphase) fehlschlägt.

## Status (vor dem Fix)

**KRITISCHER SAFETYFEHLER**

## Zielpfad

Die State-Machine wartet nur bis `settle_until`. Ein ACK darf zu diesem Zeitpunkt noch `pending` sein. Solange es noch pending ist, wird kein Fehler ausgelöst. Nach der kurzen Settle-Zeit startet trotzdem der Export.

Das ACK-Timeout liegt deutlich später.

## Nebenpfade

`open_path_to()` behandelt primär das Nichtöffnen eines Zielpfadventils als Fehler. Das fehlgeschlagene Blockieren eines Nebenpfads verhindert den Export nicht zuverlässig.

`watched_keys` enthält nur Netzwerkventile des Zielpfads, nicht alle Ventile, die für eine eindeutige Route bestätigt blockiert sein müssen.

## Verbindliche Sicherheitsregel

Export nur, wenn für **jedes betroffene Ventil** gilt:

```text
ACK vorhanden
applied == true
confirmed high entspricht requested high
Zielpfad offen
alle Nebenpfade blockiert
Bestätigung nicht stale
```

## Ziel-State-Machine

```text
IDLE
REQUEST_BLOCK_ALL
WAIT_BLOCK_ACKS
REQUEST_OPEN_TARGET
WAIT_OPEN_ACKS
WAIT_SETTLE
EXPORT
HOLD_OPEN
REQUEST_BLOCK_FINAL
WAIT_FINAL_ACKS
COMPLETE / ERROR
```

Jeder NACK, Timeout, Offlinezustand, State-Mismatch oder Cancel muss vor Export abbrechen und bestmöglich `block_all` ausführen.

---

# 9. ROUTER-P0 – Ungültiges Routing kann weiterhin direkten Export auslösen

## Status

**BEHOBEN (2026-07-16)**

`nodes/fuel/logistics_router.lua` entschied über `local routed = rs and rs:route_count() > 0` — ein struktureller Walk über das **rohe** `cfg.redstone_tree`, unabhängig vom in `rs:refresh()` ermittelten Validierungszustand (`tree_configured`/`tree_valid`/`all_valves`). Ein Baum, der konfiguriert, aber strukturell ungültig war (z. B. ein Ventil-Knoten ohne `reactor`-Ziel und ohne `children`, ein „dead_end“), fand beim strukturellen Walk KEINEN Reaktor-Endpunkt und lieferte deshalb ebenfalls `route_count() == 0` — identisch zum Fall „nie konfiguriert“. `begin_transaction()` (mit seiner eigenen `invalid_tree`-Absicherung, siehe Abschnitt 8) wurde dadurch NIE aufgerufen; FUEL fiel direkt in den ungeschützten Direkt-Export-Pfad, obwohl `refresh()` den Baum bereits als ungültig erkannt und `block_all()` ausgeführt hatte. Empirisch am echten Vor-Fix-Code bestätigt: `tree_configured=true`, `tree_valid=false`, aber `route_count()==0` → alte `routed`-Entscheidung `false`.

Fix: `redstone_router.lua` bekommt eine neue, einzige Autorität für diese Entscheidung, `get_routing_state()`, mit den im Audit vorgegebenen vier Zuständen (`ROUTING_NOT_CONFIGURED`/`ROUTING_VALID`/`ROUTING_INVALID`/`ROUTING_REQUIRED_BUT_EMPTY`), basierend auf dem echten Validierungszustand statt auf einem erneuten rohen Baum-Walk. `logistics_router.lua` nutzt jetzt ausschließlich diesen Zustand: bei `ROUTING_INVALID`/`ROUTING_REQUIRED_BUT_EMPTY` wird die Belieferung diesen Zyklus komplett blockiert (kein Routing-Versuch, aber auch kein Direktexport-Fallback); nur bei `ROUTING_NOT_CONFIGURED` bleibt der bisherige, sichere Direkt-Export-Pfad aktiv. `nodes/reprocessor/feed_router.lua` hatte diesen Bug nicht (kein separater `route_count()`-Vorab-Check — ruft `begin_transaction()` immer direkt auf, dessen eigene interne Prüfung beide Fälle bereits korrekt abfing), keine Änderung dort nötig.

Pflicht-Test: `tests/fuel_routing_invalid_tree_blocks_direct_export_test.lua` (neu) — treibt den echten `redstone_router.lua` mit einem konfigurierten-aber-kaputten Baum (`dead_end`) und beweist: `get_routing_state()` klassifiziert korrekt als `ROUTING_INVALID`, `logistics_router.lua` exportiert dabei NIE ungeschützt; ebenso für `ROUTING_REQUIRED_BUT_EMPTY` (gültiger Baum ohne jedes Ventil); Regressionsschutz für den legitimen `ROUTING_NOT_CONFIGURED`-Fall (Direktexport funktioniert weiterhin). Verifiziert per `git stash`, dass der Test ohne den Fix fehlschlägt, sowie per direktem Vergleich gegen den alten Code, dass die alte `routed`-Entscheidung tatsächlich `false` für den Exploit-Baum liefert.

## Status (vor dem Fix)

**KRITISCH OFFEN**

Der Redstone-Router selbst verweigert `begin_transaction()` bei einem konfigurierten, aber ungültigen Baum.

FUEL entscheidet jedoch vorher anhand von:

```lua
local routed = rs and rs:route_count() > 0
```

Bei ungültigem Baum ist `route_count()==0`. Dadurch wird `begin_transaction()` gar nicht aufgerufen und FUEL fällt in den direkten Exportpfad.

Beim REPROCESSOR kann eine vorhandene, aber ungültige Routendatei ebenfalls auf einen leeren Defaultbaum zurückfallen, der wie „nie konfiguriert“ behandelt wird.

## Verbindliche Zustände

```text
ROUTING_NOT_CONFIGURED
ROUTING_VALID
ROUTING_INVALID
ROUTING_REQUIRED_BUT_EMPTY
```

Direkter Export nur bei ausdrücklich erlaubter ungerouteter Installation. Sobald Routingdatei/-pflicht existiert, muss ungültig oder leer hart blockieren.

---

# 10. REPROCESSOR-P0 – `feed_router.lua` fehlt weiterhin im Rollen-Scope

## Status

**BEHOBEN (2026-07-16)**

`nodes/reprocessor/main.lua` benötigt:

```lua
require("nodes.reprocessor.feed_router")
```

Der aktuelle Manifest-Eintrag lautet weiterhin ohne `required_for`:

```lua
{ path = "nodes/reprocessor/feed_router.lua", ... }
```

`installer/manifest.lua` nimmt Rollen-Dateien nur bei `always=true` oder passendem `required_for` auf.

## Folge

Eine frische REPROCESSING-Installation oder ein Reinstall kann `main.lua`, aber nicht `feed_router.lua` installieren. Der Start endet am fehlenden Modul.

## Umsetzung

`xreactor/manifest.lua`s `feed_router.lua`-Eintrag hat jetzt `required_for={"REPROCESSING"}`. Der monolithische `/installer` lädt `manifest.lua` bei jeder Installation frisch von GitHub (kein eingebetteter Datenkopie-Pfad, nur generische, manifest-getriebene `files_for_role()`-Logik) — der einzelne Fix in `xreactor/manifest.lua` deckt daher beide Installationswege ab.

Bei derselben Untersuchung zwei weitere, verwandte Manifest-Scope-Bugs gefunden und behoben (siehe Abschnitt 17):

- `nodes/fuel/redstone_router.lua` fehlte `"WATER"` in `required_for`, obwohl `nodes/water/main.lua` es direkt per `require("nodes.fuel.redstone_router")` benötigt — derselbe Fehlerklasse wie `feed_router.lua`, nur unentdeckt weil die betroffene Rolle (WATER) nicht die Rolle war, die die Datei "besitzt" (FUEL).
- `nodes/support/ui_pages.lua` hatte umgekehrt `"MASTER"` zu Unrecht in `required_for`, obwohl kein Pfad von `master/main.lua` (auch nicht transitiv über `dofile()`) dorthin führt — ein zu breiter, nicht zu enger Scope, aber dieselbe Bug-Familie.

## Pflicht-Test

`tests/manifest_role_scope_guard_test.py` und `tests/manifest_entrypoint_require_coverage_test.py` (beide zuvor als `CONTENT_DRIFT` ausgeschlossen) erkannten diese Fehler bereits korrekt, verglichen aber nur direkte, nicht-transitive `require()`-Aufrufe und kannten `dofile()` überhaupt nicht — dadurch lieferten sie für einige Dateien (z. B. `nodes/support/runtime.lua`, das MASTER nur über `master/runtime_loop.lua`s `dofile("/xreactor/nodes/support/runtime.lua")` erreicht) falsch-positive Abweichungen. Beide Tests wurden auf transitive BFS mit `dofile()`-Erkennung umgestellt (identische Methodik in beiden Dateien); `manifest_entrypoint_require_coverage_test.py`s zusätzliche, nie implementierte „Master-Runtime-Fingerprint“-Markerprüfung (vier wörtliche Log-Strings ohne jede Spur einer echten Implementierung, siehe `git log -S`) wurde entfernt. Beide Tests laufen jetzt grün und aus der Ausschlussliste entfernt.

---

# 11. REPROCESSOR-P0 – Standby lässt aktive Transaktion weiterlaufen

## Status

**BEHOBEN (2026-07-16)**

`nodes/reprocessor/main.lua` liess `get_rs_router():tick()` bewusst unbedingt weiterlaufen, auch nach Eintritt in den Standby, mit der ausdrücklichen Absicht, eine laufende Transaktion „sauber“ zu Ende zu führen. Eine Transaktion in `WAIT_SETTLE`/`WAIT_OPEN_ACKS` konnte dadurch trotz frisch eingetretenem Standby (z. B. MASTER-Timeout mitten in einer Befüllung) noch den Exportcallback ausführen. `redstone_router.lua`s `shutdown_now()` existierte zwar bereits, war aber toter Code (nirgends aufgerufen) und rief zusätzlich keinerlei Abschluss-Callback auf.

Fix:

- `redstone_router.lua`s `shutdown_now(reason)` ruft jetzt, falls eine Transaktion aktiv war, deren `on_error(reason)` auf (derselbe Mechanismus wie beim FUEL-P0-Fix) — der Abbruch wird dadurch für den Aufrufer sichtbar, statt stillschweigend zu verschwinden.
- `feed_router.lua` bekommt eine neue `cancel(reason)`-Methode, die direkt an `rs_router:shutdown_now(reason)` delegiert.
- `nodes/reprocessor/main.lua` bekommt eine neue `enter_standby(reason)`-Funktion, die beim tatsächlichen Übergang `false→true` (nicht bei jedem Tick, solange schon im Standby) `feed_router:cancel(reason)` aufruft — verdrahtet an beiden bisherigen `standby = true`-Stellen (`MODE_OFF`-Kommando, `MASTER_STALE`-Timeout). `get_rs_router():tick()` bleibt unbedingt bestehen (treibt im Normalbetrieb weiterhin laufende Transaktionen voran), ist nach einem Standby-Übergang aber nur noch ein billiger No-Op, da die Transaktion bereits geleert wurde.

Pflicht-Test: `tests/reprocessor_standby_cancels_transaction_test.lua` (neu) — treibt den echten `redstone_router.lua` und `feed_router.lua`: `shutdown_now()` bricht eine laufende Transaktion sofort ab, ruft den Export-Callback nie auf, meldet den Abbruch über `on_error(reason)`, und blockiert alle Ventile; `feed_router:cancel()` delegiert korrekt und macht den Abbruch über `last_error` sichtbar; `cancel()` ohne aktive Transaktion stürzt nicht ab. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Status (vor dem Fix)

**KRITISCH OFFEN**

Bei MASTER-Timeout setzt REPROCESSOR zuerst `standby=true`. Danach gilt:

```lua
if not standby then get_feed_router():tick() end
get_rs_router():tick()
```

Der Redstone-Router wird bewusst auch im Standby weitergetickt. Eine Transaktion in `WAIT_SETTLE` kann dadurch trotz neuem Standby noch den Exportcallback ausführen.

## Fix

Bei Übergang nach Standby, MASTER_STALE, SAFE oder Shutdown:

```lua
feed_router:cancel(reason)
redstone_router:shutdown_now(reason)
```

Danach kein Exportcallback mehr, Ventile bestmöglich blockieren und Transaktion sichtbar als abgebrochen markieren.

---

# 12. VALVE-P0 – Fehlgeschlagener Write wird nicht erneut versucht

## Status

**BEHOBEN (2026-07-16)**

`nodes/valve/main.lua`'s `handle_valve_channel_event()` rief `remember_command(id)` VOR dem Ergebnis von `apply_valve()` auf — schlug der physische `redstone.setOutput()`-Write fehl, war die `command_id` trotzdem bereits als „gesehen“ markiert. Ein Retry mit derselben ID (genau das, was `redstone_router.lua`s `check_pending_acks()` bei ausbleibender Bestätigung tut) traf dadurch nur noch den Dedupe-Zweig (`applied = current_high == high`, ohne zweiten Schreibversuch) — Retry war beim eigentlichen Anwendungsfall (Schreibfehler) wirkungslos. Zusätzlich setzte `apply_valve()` `last_command_ts` unbedingt als allererste Anweisung, auch bei fehlgeschlagenem Write — ein fehlgeschlagenes BLOCK-Kommando (Ventil bleibt unsicher offen) verlängerte dadurch die Gnadenfrist des Fail-Safe-Watchdogs, statt sie zu verkürzen.

Fix:

- `remember_command(id)` wird nur noch nach einem **erfolgreichen** `apply_valve()` aufgerufen. Eine fehlgeschlagene ID bleibt „ungesehen“ und wird bei identischem Retry erneut wirklich geschrieben, solange bis sie tatsächlich übernommen wurde.
- `last_command_ts` wird nur noch bei erfolgreichem Write (oder wenn ohnehin kein Write nötig war) aktualisiert — ein Fehlschlag lässt den Watchdog auf dem älteren Zeitstempel stehen, wodurch er eher, nicht später, erneut eingreift.
- `last_command_ts` wird jetzt bereits bei der Deklaration mit einem echten Zeitstempel initialisiert (statt `nil`), damit der Fail-Safe-Watchdog auch dann irgendwann auslöst, wenn schon der allererste Boot-Write fehlschlägt und danach nie ein gültiges Kommando eintrifft.

Pflicht-Test: `tests/valve_failed_write_retry_test.lua` (neu) — extrahiert den echten Quelltext von `apply_valve()`/`handle_valve_channel_event()` per String-Marker direkt aus `main.lua` und führt ihn per `load()` in einer isolierten, gemockten Umgebung aus (kein Nachbau der Logik). Beweist: ein fehlgeschlagener Write markiert die `command_id` nicht als gesehen und ein identischer Retry löst einen echten zweiten Schreibversuch aus; ein erfolgreicher Write wird weiterhin korrekt dedupliziert; `last_command_ts` wird durch einen fehlgeschlagenen sicherheitskritischen Write nicht verlängert. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Status (vor dem Fix)

**KRITISCH OFFEN**

Die VALVE-Node speichert eine `command_id` vor dem Ergebnis von `apply_valve()`.

Schlägt der physische Redstone-Write fehl:

- ACK meldet `applied=false`,
- Router sendet Retry mit derselben ID,
- VALVE erkennt die ID als gesehen,
- kein zweiter Write wird ausgeführt,
- `applied` wird nur aus `current_high == requested_high` abgeleitet.

Retry ist damit genau beim Writefehler wirkungslos.

Zusätzlich setzt `apply_valve()` `last_command_ts` vor dem Write. Ein fehlgeschlagenes BLOCK-Kommando kann dadurch den Fail-Safe eines noch offenen Ventils verlängern.

## Fix

Command-ID erst nach erfolgreichem Apply als abgeschlossen markieren. Fehlgeschlagene IDs mit Fehlerzustand speichern und bei gleicher ID erneut schreiben, solange `applied~=true`.

`last_command_ts` nur so aktualisieren, dass ein fehlgeschlagenes Sicherheitskommando keinen unsicheren Zustand verlängert.

---

# 13. ENERGY-P0 – Schedulergruppen sind nicht vollständig getrennt

## Status

**BEHOBEN (2026-07-16)**

`nodes/energy/matrix.lua` (der explizit blockieren darf, Peripherie-Calls dokumentiert 1-4s) tickte über `ctx.services:tick()` die VOLLSTÄNDIGE Service-Liste (COMMS/DISCOVERY/STORAGE_SAMPLE/MATRIX_SAMPLE/TELEMETRY/UI) — ein langsamer Matrix-Peripherie-Call verzögerte dadurch im selben sequentiellen Aufruf auch COMMS/Discovery/Telemetry/UI, obwohl der eigentliche Sinn der zwei getrennten Coroutinen (`heartbeat.lua` + `matrix.lua` via `parallel.waitForAny`) genau das verhindern sollte. Zusätzlich rief `matrix.lua` nach jedem Loop-Durchlauf (~alle 0,5s) `ctx.send_heartbeat(ctx.now_ms())` komplett ungegatet auf — deutlich mehr Heartbeats als das konfigurierte Intervall.

Fix:

- Neue, zweite `service_manager`-Instanz `matrix_services` in `nodes/energy/main.lua`, ausschließlich für `STORAGE_SAMPLE`/`MATRIX_SAMPLE` — nur diese wird aus dem Matrix-Thread geticked (`ctx.services` in `matrix.lua`s Kontext zeigt jetzt darauf).
- `services` (COMMS/DISCOVERY/TELEMETRY/UI) wird jetzt periodisch aus dem (garantiert nie blockierenden) Heartbeat-Thread geticked — `heartbeat.lua` unterhält dafür einen eigenen, unabhängigen Timer (`tick_interval_s`, Standard `CONFIG.RECEIVE_TIMEOUT`) neben dem bestehenden Heartbeat-Intervall-Timer, statt die Nicht-Matrix-Services ausschließlich vom Matrix-Thread abhängig zu machen.
- `send_heartbeat_if_due(now)` als einzige zentrale „sende Heartbeat, falls fällig“-Quelle in `main.lua` — ersetzt drei zuvor unabhängig voneinander duplizierte Intervallprüfungen (`inter_service_hook`, `matrix_runtime`s `heartbeat_pump`-Option, und den ungegateten Aufruf in `matrix.lua`). Der `inter_service_hook` selbst wurde komplett entfernt (redundant geworden).
- `matrix.lua` ruft jetzt `ctx.send_heartbeat_if_due(ctx.now_ms())` statt eines rohen `send_heartbeat`.

Pflicht-Test: `tests/energy_matrix_thread_scheduler_isolation_test.lua` (neu) — treibt die echten, jetzt seiteneffektfreien Module `nodes/energy/matrix.lua` und `nodes/energy/heartbeat.lua` direkt: ein künstlich fehlschlagender/„langsamer“ Matrix-Tick verhindert die Heartbeat-Nachholprüfung nicht; `matrix.lua` ruft ausschließlich die gegatete `send_heartbeat_if_due`-Variante auf; `heartbeat.lua` tickt `ctx.services` über einen eigenen Timer, unabhängig vom Heartbeat-Sendeintervall; ergänzt um eine strukturelle Prüfung von `main.lua`s Verdrahtung (Boot-Skript mit Seiteneffekten, nicht direkt instanziierbar). Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Status (vor dem Fix)

**KRITISCH OFFEN**

`nodes/energy/matrix.lua` ruft weiterhin:

```lua
ctx.services:tick()
```

Damit läuft im Matrix-Thread nicht nur Matrix-Sampling, sondern potenziell:

- COMMS-Maintenance,
- Discovery,
- Storage-Sampling,
- Matrix-Sampling,
- Telemetrie,
- UI.

Langsame Matrixcalls können diese Services im selben Thread gemeinsam verzögern.

## Heartbeatfehler

Nach jedem Matrixdurchlauf wird direkt:

```lua
ctx.send_heartbeat(ctx.now_ms())
```

aufgerufen. Die zentrale `send_heartbeat()`-Funktion besitzt selbst keine Intervallprüfung. Bei 0,5-s-Schleife können dadurch wesentlich mehr Heartbeats als konfiguriert gesendet werden; der separate Heartbeat-Thread existiert zusätzlich.

## Fix

- Matrix-Thread tickt ausschließlich einen dedizierten Matrixservice.
- COMMS/UI/Telemetry/Discovery bleiben in getrennten Schedulergruppen.
- genau eine zentrale `send_if_due()`-Heartbeatquelle.
- keine vollständige `services:tick()` aus dem Matrix-Thread.

## Pflicht-Test

Künstlicher 4-s-Matrixcall darf COMMS, Heartbeat, UI und andere Deadlines nicht blockieren oder zusätzliche Heartbeats erzeugen.

---

# 14. INSTALL-P0 – Manifest und Dateien stammen nicht garantiert aus demselben Commit

## Status

**KRITISCH OFFEN**

Der Installer:

- löst einen SHA für Datei-Downloads auf,
- lädt das Manifest aber immer vom bewegten `beta`-Branch,
- einzelne Dateien können zusätzlich auf den Branch-Fallback wechseln.

Damit können Manifestmetadaten und Dateiinhalte aus unterschiedlichen Commits stammen.

## Fix

1. Branch-SHA einmal auflösen.
2. Manifest exakt von diesem SHA laden.
3. alle Dateien exakt von diesem SHA laden.
4. bei vollständigem Fallback einen komplett neuen, konsistenten Versuch mit neu aufgelöstem SHA starten.
5. niemals Manifest und Dateien innerhalb eines Laufs mischen.

---

# 15. INSTALL-P0 – CRC wird beim tatsächlichen Write nicht geprüft

## Status

**OFFEN**

`manifest.lua` enthält CRC32-Hashes. `installer/stage.lua` prüft nach dem Schreiben jedoch nur:

- Existenz,
- Lesbarkeit,
- Größe,
- Lua-Syntax.

Eine Datei mit korrekter Größe und gültiger Syntax, aber verändertem Inhalt kann akzeptiert werden.

## Fix

`stage.verify()` muss `entry.hash` gegen CRC32 des geschriebenen Inhalts prüfen. Modularer und monolithischer Installer müssen dieselbe Implementierung verwenden.

---

# 16. INSTALL/LOG-P0 – Pauschale Löschung vorhandener Logs

## Status

**KRITISCH OFFEN**

## Installer

`installer/stage.lua` löscht bei zu wenig freiem Speicher pauschal:

```text
/xreactor_logs
```

bevor erneut geprüft wird.

## LOG Collector

Schlägt `probe_disk()` einmal fehl, wird der gesamte Rollen-Logordner rekursiv geleert und danach erneut probiert.

## Folgen

Temporäre Mount-, Full-, I/O- oder Race-Fehler können vorhandene Logs vollständig vernichten.

## Fix

- niemals komplette Logs als automatische Fehlerbehandlung löschen,
- nur eigene Temp-/Probe-Dateien entfernen,
- klare Zustände `FULL`, `READ_ONLY`, `UNAVAILABLE`, `IO_ERROR`,
- Retention ausschließlich explizit alters-/größenbasiert,
- bei Platzmangel Installation kontrolliert abbrechen oder Nutzerentscheidung verlangen.

---

# 17. MANIFEST-P1 – Rollen- und optionale Scopes

## Status

**OFFEN**

Bestätigt:

- `core/bootstrap.lua` ist nicht mehr doppelt enthalten.
- `nodes/reprocessor/feed_router.lua` hat jetzt `required_for={"REPROCESSING"}` (BEHOBEN, siehe Abschnitt 10).
- `nodes/fuel/redstone_router.lua` hat jetzt zusätzlich `"WATER"` (BEHOBEN — `nodes/water/main.lua` benötigt es direkt).
- `nodes/support/ui_pages.lua` hat `"MASTER"` nicht mehr zu Unrecht in `required_for` (BEHOBEN — kein Pfad von MASTER dorthin).
- `tests/manifest_role_scope_guard_test.py` und `tests/manifest_entrypoint_require_coverage_test.py` laufen jetzt grün (BEHOBEN, transitive `dofile()`-fähige Neufassung, siehe Abschnitt 10) und wurden aus der Ausschlussliste entfernt.
- `optional/speaker_alarm.lua` hat weiterhin kein `required_for` und kann trotz auswählbarem Feature aus der tatsächlichen Rollen-Dateiliste fallen.
- Manifestkopf kommentiert weiterhin eine alte Versionsbezeichnung, obwohl die tatsächlichen Felder v439 sind; funktional gering, aber verwirrend.

## Pflicht-Test

Für jede installierbare Rolle:

- transitive `require()`-/`dofile()`-Abdeckung,
- kein fehlender Pflichtpfad,
- keine Duplikate,
- optionale Auswahl verändert Dateiliste tatsächlich,
- nicht ausgewählte Features werden nicht installiert.

---

# 18. SHARED Runtime – aktueller Stand

## Status

**WEITGEHEND UMGESETZT**

Positiv bestätigt:

- Eventticks laufen nur für `wants_events=true`-Services.
- COMMS/UI und dedizierte Ventillistener melden sich explizit an.
- normale Eventbursts starten nicht mehr automatisch jeden periodischen Service.
- Servicefehler erhalten Backoff und Slow-Tick-Diagnose.

Offen:

- ENERGY verwendet weiterhin einen vollständigen periodischen Service-Manager-Tick in seinem Matrix-Thread.
- Service-Manager besitzt keine Schedulergruppen-/`tick_only(name)`-API, wodurch ENERGY zu diesem Workaround greift.

---

# 19. WATER – aktueller Stand

## Status

**WEITGEHEND UMGESETZT**

Positiv bestätigt:

- gemeinsamer Tank-Snapshot,
- `BLOCK_ALL` bei unbekanntem Tankstand,
- Statusänderung erst nach bestätigtem Write,
- sichere Behandlung von Teilfehlern,
- persistentes `SET_TARGET`,
- aktuelles UI-Model,
- zentraler Touchpfad.

Noch erforderlich:

- Ingame-Test für Lesefehler und Writefehler,
- Reboot-/Update-Erhalt von Config und Zielwert,
- mehrere Cluster gleichzeitig,
- Integratorverlust während Fill/Drain,
- UI-/Telemetrie-Konsistenz unter Last.

Es wurde in dieser Runde kein neuer statischer WATER-P0-Blocker gefunden.

---

# 20. MASTER-P1 – Zielnode und echte Applied-Bestätigung

## Status

**OFFEN**

Das Senden an alle FUEL-/WATER-Nodes einer Rolle ist umgesetzt. Weiter offen:

- konkreten Einzelnode auswählen,
- „alle Nodes“ explizit anzeigen,
- Command-ID und ACK je Zielnode verfolgen,
- Teilfehler darstellen,
- persistente Zielauswahl.

„gesendet“ darf nicht als „angewendet“ dargestellt werden.

---

# 21. TEST/CI-P0 – 72 Tests weiterhin ausgeschlossen

## Status

**KRITISCH TEILWEISE**

Aktueller Stand (nach Behebung von `manifest_role_scope_guard_test.py`/`manifest_entrypoint_require_coverage_test.py`, siehe Abschnitt 10):

```text
66 ausgeschlossene Lua-Tests
6 ausgeschlossene Python-Tests
72 insgesamt
```

Die Liste enthält weiterhin:

- `CONTENT_DRIFT`,
- echte Manifest-Scope-Abweichungen,
- ENERGY-Architekturtests,
- RT-Control-/Safety-/Comms-Tests,
- MASTER-Shutdown-/ACK-Semantik,
- fehlende CC:Tweaked-Mocks.

Für den aktuellen Merge-Head wurden über die GitHub-Schnittstelle keine zugeordneten Workflow-Runs und keine kombinierten Statuschecks zurückgegeben. Ein grüner aktueller Head ist daher nicht nachgewiesen.

## Testregel

Ein Test darf nur entfernt werden, wenn die Anforderung nicht mehr gilt oder gleichwertig durch einen aktuellen Test geschützt ist. Andernfalls Produktionscode, Test oder Mock reparieren und aus der Ausschlussliste entfernen.

## Fehlende Pflicht-Regressionstests

1. FUEL Defaultconfig-Start.
2. REPROCESSOR vollständige Installationsdateiliste.
3. ~~MASTER→RT echter Startup-End-to-End-Pfad.~~ BEHOBEN (2026-07-16, siehe Abschnitt 3): `tests/rt_master_startup_end_to_end_test.lua`.
4. Router wartet auf Ziel- und Nebenventil-ACKs.
5. ~~FUEL Async-Lifecycle und Statistik.~~ BEHOBEN (2026-07-16, siehe Abschnitt 7): `tests/fuel_logistics_async_delivery_lifecycle_test.lua`.
6. ~~VALVE Failed-Write-Retry.~~ BEHOBEN (2026-07-16, siehe Abschnitt 12): `tests/valve_failed_write_retry_test.lua`.
7. ~~REPROCESSOR Standby-Cancel.~~ BEHOBEN (2026-07-16, siehe Abschnitt 11): `tests/reprocessor_standby_cancels_transaction_test.lua`.
8. ~~ENERGY 4-s-Matrixcall bei laufendem COMMS/Heartbeat/UI.~~ BEHOBEN (2026-07-16, siehe Abschnitt 13): `tests/energy_matrix_thread_scheduler_isolation_test.lua`.
9. ~~RT Discovery mit Fake-Clock und realem Schedulerintervall.~~ BEHOBEN (2026-07-16, siehe Abschnitt 4): `tests/rt_discovery_stable_slowdown_test.lua`.
10. ~~RT Altconfig-Migration.~~ BEHOBEN (2026-07-16, siehe Abschnitt 5): `tests/rt_config_interval_schema_migration_test.lua`. Controlmetriken (Abschnitt 5, „Pflicht-Metriken“) weiterhin offen.
11. Installer ein SHA + CRC.
12. LOG-/Installer-Datenerhalt bei Full-/Probe-Fehlern.

---

# 22. Verbindliche Bearbeitungsreihenfolge

1. **FUEL Config-Normalizer** – Startabsturz verhindern.
2. **REPROCESSOR Manifest-Scope** – `feed_router.lua` sicher installieren.
3. ~~**MASTER→RT Startup-End-to-End** – echten `start_module`-Pfad verdrahten.~~ BEHOBEN (2026-07-16, siehe Abschnitt 3).
4. ~~**Router Safety** – alle Ziel- und Nebenventile vor Export bestätigen.~~ BEHOBEN (2026-07-16, siehe Abschnitt 8).
5. ~~**FUEL Async-Lifecycle** – Request, Statistik und Abschluss korrigieren.~~ BEHOBEN (2026-07-16, siehe Abschnitt 7).
6. ~~**Invalid-Routing-Hardblock** für FUEL und REPROCESSOR.~~ BEHOBEN (2026-07-16, siehe Abschnitt 9). REPROCESSOR (`feed_router.lua`) hatte den Bug nicht (kein separater `route_count()`-Vorab-Check).
7. ~~**VALVE Failed-Write-Retry** und Fail-Safe-Zeitstempel.~~ BEHOBEN (2026-07-16, siehe Abschnitt 12).
8. ~~**REPROCESSOR Standby-Cancel**.~~ BEHOBEN (2026-07-16, siehe Abschnitt 11).
9. ~~**ENERGY Scheduler-/Heartbeat-Trennung**.~~ BEHOBEN (2026-07-16, siehe Abschnitt 13).
10. ~~**RT Discovery-Deadline korrekt umsetzen**.~~ BEHOBEN (2026-07-16, siehe Abschnitt 4).
11. **RT Altconfig-Migration und Controlmetriken**. Altconfig-Migration BEHOBEN (2026-07-16, siehe Abschnitt 5); Controlmetriken weiterhin offen.
12. **Installer ein SHA + CRC-Verifikation**.
13. **keine automatische Log-Löschung** in Installer und LOG Collector.
14. **Manifest optionale Features/Rollenscope**.
15. **MASTER Einzelnode-/ACK-UI**.
16. **Ausschlusslisten Test für Test abbauen**.
17. danach vollständige Ingame-Last-, Reconnect-, Reboot- und Update-Tests.

---

# 23. Definition of Done

## Installer / Manifest

- Manifest und Dateien stammen aus exakt demselben Commit.
- Größe und CRC32 werden nach jedem Write geprüft.
- jede Rolle erhält alle transitiven Abhängigkeiten.
- optionale Features verändern die Dateiliste korrekt.
- keine vorhandenen Logs werden als automatische Platz-/Probe-Reaktion gelöscht.
- Benutzerconfig und Routen überleben Update, Reinstall und Neustart.

## MASTER

- Colon/Dot-Fix bleibt getestet.
- echter STARTUP_STAGE-Pfad startet reale RT-Module.
- Turbine vor Reactor.
- ACK und Stable-Telemetrie steuern die Sequenz.
- Einzelnode oder alle Nodes auswählbar.
- Applied-Ergebnis je Ziel sichtbar.

## RT

- alte historische Defaultintervalle werden migrationssicher aktualisiert.
- Discovery-Abstände entsprechen real den dokumentierten Deadlines.
- Attach/Detach-Erkennungszeit ist definiert und getestet.
- Controlfrequenz, Jitter und Write-Skips sind messbar.
- SAFE und Startup sind end-to-end getestet.

## ENERGY

- Matrix-Thread tickt ausschließlich Matrixarbeit.
- COMMS/Heartbeat/UI bleiben bei langsamen Matrixcalls reaktionsfähig.
- genau eine zentrale Heartbeat-Zeitquelle.
- Heartbeatfrequenz entspricht der Config.

## WATER

- Snapshot, Block-All, Writebestätigung und Persistenz funktionieren ingame.
- Reboot/Update erhalten Config und Ziel.
- jeder Touch erzeugt genau eine Aktion.

## FUEL

- frische Defaultconfig startet fehlerfrei.
- kein Export bei ungültigem/erforderlichem leerem Routing.
- Export erst nach vollständiger Bestätigung aller Ventile.
- Async-Request bleibt bis COMPLETE/ERROR erhalten.
- Statistik entspricht tatsächlicher Exportmenge.
- Shutdown/Timeout führen zu `block_all` und keinem Export.

## REPROCESSOR

- `feed_router.lua` wird immer installiert.
- ungültiges Routing blockiert Feed.
- Standby/MASTER_STALE bricht laufende Transaktion ab.
- keine Exportaktion nach Standby-Eintritt.

## VALVE

- fehlgeschlagene Writes werden bei Retry erneut ausgeführt.
- Command-ID gilt erst nach erfolgreichem Apply als abgeschlossen.
- fehlgeschlagenes BLOCK-Kommando verlängert keinen unsicheren Offen-Zustand.

## LOG Collector

- Probe-, Mount- und Full-Fehler löschen keine vorhandenen Logs.
- Retention ist explizit und nachvollziehbar.
- ACK erfolgt weiterhin erst nach Persistierung.

## Tests / CI

- keine kritischen Produktionsfehler stehen auf einer Ausschlussliste.
- alle oben genannten Pflicht-Regressionstests laufen im Workflow.
- aktueller `beta`-Head besitzt einen nachweislich grünen Statuscheck.
