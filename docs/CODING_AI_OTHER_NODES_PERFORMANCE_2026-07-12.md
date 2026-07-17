# Aktueller Gesamt-Audit – XReactor Controller V3

Stand: 2026-07-16  
Branch: `beta`  
Geprüfter ausführbarer Code-Head: `423a2f0b5198de61aaaf71c8fa28413d151b63bd`  
Geprüfte Release: `beta-v455` / `manifest-v455`  
Manifest-Dateien: `166`

## Zweck und Prüfumfang

Diese Datei ist die aktuelle, rollenübergreifende Aufgabenquelle für Coding-AI und manuelle Prüfungen. Sie ersetzt die vorherige Fassung vollständig. Alte Fehlerbeschreibungen werden nicht mehr unter bereits behobenen Überschriften weitergeführt.

Geprüft wurden:

- Root-Installer, modularer Installer und Auto-Update,
- Manifest, Rollen-Scope und Entrypoint-Abhängigkeiten,
- Shared Runtime, Service-Manager und Crashpfade,
- MASTER,
- RT,
- ENERGY,
- WATER,
- FUEL,
- REPROCESSOR,
- VALVE,
- LOG Collector,
- Tests und GitHub Actions.

Commitmeldungen und vorhandene Kommentare wurden nicht als Beweis übernommen. Bewertet wurde der tatsächliche Code auf `beta`. Peripheral-, Netzwerk-, Reboot-, Stromausfall-, Update- und Lastverhalten muss zusätzlich in CC:Tweaked/Ingame nachgewiesen werden.

---

# 1. Gesamtstatus

| Bereich | Tatsächlicher Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Auto-Update | **KRITISCH TEILWEISE** | kein transaktionaler Completion-Marker, Runtime läuft beim Reinstall weiter, kritische FS-Fehler werden teilweise ignoriert |
| Manifest / Rollen-Scope | **WEITGEHEND BEHOBEN** | strukturelle Manifestvalidierung und doppelte Installer-Implementierung bleiben offen |
| Shared Runtime | **WEITGEHEND UMGESETZT** | Update-Quiesce fehlt rollenübergreifend |
| MASTER | **TEILWEISE OFFEN** | Config-Editor meldet Werte optimistisch als übernommen; kein Applied-ACK je Zielnode und keine Einzelnode-Auswahl |
| RT | **WEITGEHEND UMGESETZT** | `TURBINE_MODE`-Context-Typfehler (Abschnitt 11), Rampendauer-Einheitenfehler (Abschnitt 12) und fehlende `update_module_states()`-Verdrahtung (Abschnitt 13) behoben; Persistenz-/Observability-Restpunkte (Abschnitt 14) weiterhin offen |
| ENERGY | **TEILWEISE BEHOBEN** | Schedulergruppen getrennt, Heartbeat besitzt aber weiterhin zwei Zeitquellen |
| WATER | **WEITGEHEND UMGESETZT** | Persistenzfehler werden geloggt, Command kann trotzdem als angewendet bestätigt werden |
| FUEL | **TEILWEISE OFFEN** | Config/Async-Lifecycle und Router-ACK-Command-ID-Bindung behoben (Abschnitt 17); Async-Ergebnis noch nicht sauber an seinen Lieferzyklus gebunden (Abschnitt 19) |
| REPROCESSOR | **WEITGEHEND UMGESETZT** | Standby-Cancel und Wireless-VALVE-Discovery behoben (Abschnitt 20) |
| VALVE | **TEILWEISE BEHOBEN** | Retry behoben; Senderbindung standardmäßig aus und Sorter-Reconnect unvollständig |
| LOG Collector | **WEITGEHEND UMGESETZT** | Probe-Wipe (Abschnitt 16) und stale Free-Space-Cache im Reclaim (Abschnitt 22) behoben; Rotation/Datenhaltungsregeln (Abschnitt 23) weiterhin offen |
| Tests / CI | **KRITISCH TEILWEISE** | 66 Lua- und 6 Python-Tests ausgeschlossen; aktueller Head ohne nachgewiesenen grünen Lauf |
| Dokumentation | **AKTUELL** | diese Datei ist die einzige aktuelle allgemeine Auditquelle |

## Produktionsurteil

`beta-v455` ist **noch nicht produktionsreif**.

Die kritischsten aktuellen Risiken sind:

1. Ein Update kann als neue Release erscheinen, obwohl die Installation nur teilweise abgeschlossen wurde.
2. Der Installer kann Dateien ersetzen, während die laufende Node dieselben Dateien und Hardwarepfade weiter benutzt.
3. ~~RT-Startup verwendet im echten Context einen falschen `TURBINE_MODE`-Typ und behandelt `30` als 30 Millisekunden.~~ BEHOBEN (2026-07-17, siehe Abschnitt 11 und Abschnitt 12).
4. ~~`module_lifecycle.update_module_states()` ist im Produktionspfad nicht aufgerufen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 13).
5. ~~Der Ventilrouter kann einen fehlenden aktuellen ACK durch einen alten passenden Bestätigungszustand ersetzen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 17).
6. ~~REPROCESSOR übergibt dem Router keine COMMS-Peerquelle und erkennt Wireless-VALVE-Nodes dadurch nicht.~~ BEHOBEN (2026-07-17, siehe Abschnitt 20).
7. ~~LOG-Reclaim prüft nach Löschungen einen gecachten Free-Space-Wert und kann unnötig viele Dateien entfernen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 22).
8. 72 Tests bleiben ausgeschlossen; ein grüner Lauf des geprüften Heads ist nicht nachgewiesen.

---

# 2. Seit `beta-v438` tatsächlich behoben

Die folgenden Punkte sind im aktuellen Code nachvollziehbar umgesetzt. Sie dürfen nur mit einem konkreten Regressionstest erneut umgebaut werden.

## Installer / Manifest

- Manifest und heruntergeladene Dateien verwenden im modularen Installer denselben aufgelösten Source-Ref.
- `installer/stage.lua` prüft nach jedem Write Größe und CRC32.
- automatische Speicherbereinigung löscht nicht mehr pauschal `/xreactor_logs`.
- REPROCESSOR-`feed_router.lua` besitzt jetzt den Rollen-Scope `REPROCESSING`.
- `optional/speaker_alarm.lua` besitzt einen Rollen-Scope.
- VALVE-Rollen- und Shared-Support-Dateien sind im aktuellen Manifest enthalten.
- der frühere doppelte Manifestpfad für `core/bootstrap.lua` ist nicht mehr vorhanden.

## MASTER / RT

- Colon-/Dot-Aufrufproblem im MASTER-Startup-Sequencer ist behoben.
- RT besitzt jetzt echte Startup-Statevariablen und echte `start_module`-/`process_startup`-Verdrahtung.
- RT-Telemetrie enthält Modul- und Startupzustände.
- RT-Discovery verwendet eine echte Wanduhrdeadline statt Scheduler-Ticks als Slowdown-Zähler.
- historische RT-Defaultintervalle `5.0` und `1.0` werden versionsgesteuert auf `0.10` migriert.
- Capability-Cache normalisiert Singular-/Plural-Kindnamen und entfernt nicht mehr gebundene Einträge.

## ENERGY

- schnelle Services und Matrix-/Storage-Sampling verwenden getrennte Service-Manager.
- der Matrix-Thread tickt nicht mehr COMMS, Discovery, Telemetrie und UI gemeinsam mit blockierenden Matrixcalls.
- Matrixcode verwendet eine `send_heartbeat_if_due`-Funktion statt eines vollständig ungefilterten Sends.

## WATER

- gemeinsamer Tank-Snapshot,
- BLOCK_ALL bei unbekanntem Tankstand,
- Stateänderung erst nach erfolgreichen Redstone-Writes,
- persistentes `SET_TARGET`,
- aktuelles UI-Model,
- zentraler Touchpfad.

## FUEL / Router

- `logistics.destinations`, `sources` und `routes` werden normalisiert; frische Teilconfigs stürzen dort nicht mehr mit `ipairs(nil)` ab.
- asynchroner FUEL-Request bleibt bis Erfolgs- oder Fehlercallback erhalten.
- Exportstatistik wird im asynchronen Callback aktualisiert.
- ungültiges oder erforderliches, aber leeres Routing fällt nicht mehr direkt in den ungeschützten Exportpfad.
- Router blockiert zuerst alle Ventile, bestätigt den Zustand, öffnet danach den Zielpfad und bestätigt diesen ebenfalls.
- REPROCESSOR bricht eine aktive Transaktion beim Eintritt in Standby ab.

## VALVE

- eine Command-ID wird erst nach erfolgreichem Apply dedupliziert.
- ein fehlgeschlagener Write wird bei Retry derselben ID erneut versucht.
- ein fehlgeschlagener Write verlängert den Fail-Safe-Timer nicht mehr.
- Logistical Sorter wird als alternativer Aktor unterstützt.

## LOG Collector

- ein fehlgeschlagener Probe-Write löscht nur noch die eigene `.probe`-Datei.
- ACK bleibt an tatsächliche Persistierung gekoppelt.
- Batch-Writes und Dedupe-Ringstruktur bleiben erhalten.

---

# 3. INSTALL-P0.1 – Kein transaktionaler Installationsabschluss

## Status

**KRITISCH OFFEN**

## Bestätigtes Problem

`release.lua` wird wie eine normale Datei innerhalb der Installationsliste geschrieben. Danach folgen weitere Rollen-, Shared- und Startdateien. Bricht der Lauf nach dem Schreiben von `release.lua`, aber vor dem vollständigen Ende ab, kann der Rechner bereits die neue Release-/Manifestnummer melden, obwohl Teile der Installation fehlen oder alt geblieben sind.

Es existiert kein persistenter Zustand wie:

```text
PREPARED
INSTALLING
VERIFYING
COMMITTED
FAILED
```

und kein Completion-Marker, der erst nach vollständiger Verifikation gesetzt wird.

## Folge

- Teilinstallation kann als aktuell erscheinen.
- Auto-Update kann denselben Stand anschließend überspringen.
- Diagnose und UI können eine falsche Versionskonsistenz anzeigen.
- ein Neustart mitten im Update besitzt keine eindeutige Recoveryentscheidung.

## Verbindlicher Fix

1. Installationsjournal außerhalb des ersetzten Baums anlegen.
2. Ziel-Ref, Manifest-ID, Rolle und erwartete Dateiliste speichern.
3. alle Dateien schreiben und verifizieren.
4. Entrypoint und Rollenabhängigkeiten prüfen.
5. `release.lua` und Completion-Marker **zuletzt** atomar committen.
6. beim Boot unvollständigen Zustand erkennen und entweder Rollback oder kontrollierten Resume ausführen.

## Pflicht-Test

Stromausfall/Fehler nach jedem einzelnen Dateischritt injizieren. Nach jedem Reboot muss genau einer der Zustände gelten:

- vollständig alter Stand,
- vollständig neuer Stand,
- klarer Recoverymodus ohne Start der normalen Rolle.

---

# 4. INSTALL-P0.2 – Runtime und Installer laufen parallel

## Status

**KRITISCH OFFEN**

`start.lua` startet Rollenruntime und Auto-Updater mit `parallel.waitForAny`. Der Updater führt den Installer direkt aus, während die Rollenruntime weiterhin:

- Hardware regeln,
- Ventile schalten,
- Logs schreiben,
- Configs persistieren,
- Module laden,
- Netzwerkcommands verarbeiten

kann.

## Folge

- Dateien werden ersetzt, während alter Code weiterläuft.
- Rollenlogik kann Configrestore oder Installerwrites überschreiben.
- Safety-Aktoren besitzen keinen definierten Quiesce-Zustand.
- ein Updatefehler kann Runtime und Installationsbaum gleichzeitig inkonsistent hinterlassen.

## Verbindlicher Fix

Ein rollenübergreifender Update-Handshake:

```text
UPDATE_REQUESTED
QUIESCE_REQUESTED
SAFE_OUTPUTS_APPLIED
RUNTIME_STOPPED
INSTALLING
VERIFIED
COMMITTED
REBOOT
```

Jede Rolle benötigt einen expliziten Quiesce-Handler. Für FUEL/REPROCESSOR/VALVE/WATER muss der sichere physische Ausgangszustand bestätigt sein, bevor der Installer Dateien ersetzt.

---

# 5. INSTALL-P0.3 – Kritische Dateisystemfehler werden ignoriert

## Status

**KRITISCH OFFEN**

Mehrere kritische Operationen sind weiterhin als `pcall(...)` ohne anschließende Ergebnisprüfung ausgeführt, unter anderem:

- Löschen beziehungsweise Erzeugen des Installationsroots,
- Teile des Minimal-Restores,
- Schreiben von Rollen-/Feature-/Updaterconfig,
- Schreiben des Startupwrappers.

Zusätzlich besitzt `stage.write()` noch einen unsicheren Fallback: Schlägt das Verschieben der alten Datei nach `.xr_prev` fehl, wird die alte Zieldatei gelöscht und der Lauf versucht trotzdem weiterzumachen.

## Folge

Der Installer kann nach einem fehlgeschlagenen Lösch-, Move-, Mkdir- oder Restore-Schritt fortfahren und später einen scheinbar erfolgreichen, aber unvollständigen Stand hinterlassen.

## Verbindlicher Fix

- jede kritische FS-Operation muss explizit geprüft werden,
- bei Fehler sofort abbrechen,
- alte Datei niemals löschen, wenn das Backup nicht bestätigt vorhanden ist,
- Restorewrites einzeln verifizieren,
- Fehlerpfad muss Journal/Recoverymarker aktualisieren.

---

# 6. INSTALL-P0.4 – Generische `.xr_prev`-Recovery fehlt

## Status

**OFFEN**

`stage.write()` kann temporär einen Zustand erzeugen, in dem nur `<datei>.xr_prev` vorhanden ist. Für `/xreactor/start.lua` existiert ein spezieller Recoverypfad, nicht aber für beliebige benötigte Module.

## Folge

Stromausfall zwischen Backup-Move und finalem Move kann eine Rollen- oder Shared-Datei fehlen lassen. Der nächste Boot kann bereits beim `require()` abbrechen, bevor der Installer selbst wieder erreichbar ist.

## Fix

- Boot-Recovery scannt `.xr_prev` und `.xr_tmp` anhand des Installationsjournals.
- Wiederherstellung nur für den dokumentierten aktiven Updatevorgang.
- anschließend CRC/Größe prüfen.

---

# 7. INSTALL/MANIFEST-P1 – Vorabvalidierung ist zu schwach

## Status

**OFFEN**

Vor dem Löschen des alten Baums fehlen vollständige Guards für:

- erlaubte Rollenwerte,
- erwarteten Entrypoint der gewählten Rolle,
- doppelte Pfade,
- absolute Pfade und `..`-Traversal,
- gültige Hash-/Größenfelder,
- Manifest-/Releasekonsistenz,
- maximale Manifest- und Dateigröße,
- transitive `require()`-/`dofile()`-Abdeckung.

`ROLE_EXTRAS` kann außerdem Dateien ergänzen, deren Manifestmetadaten fehlen.

## Fix

Ein einziges `validate_install_plan()` muss vor dem Backup-/Delete-Schritt die gesamte Installationsmenge ablehnen, sobald irgendeine strukturelle Bedingung nicht erfüllt ist.

---

# 8. INSTALL-P1 – Zwei unabhängige Installerimplementierungen

## Status

**OFFEN**

Der Root-`/installer` enthält weiterhin eingebettete Kopien von HTTP-, Manifest-, Stage-, UI- und Initlogik. Parallel existieren dieselben Module unter `xreactor/installer/`.

## Folge

Jeder Fix muss mehrfach synchron gehalten werden. Ein bestandener Test des modularen Pfads beweist nicht automatisch den Root-Bootstrap-Pfad.

## Fix

Der Root-Installer darf nur noch:

1. einen kleinen, versionsfesten Bootstrap laden,
2. genau einen Source-Ref auflösen,
3. die kanonischen Installermodule dieses Refs herunterladen,
4. anschließend ausschließlich den modularen Installer ausführen.

---

# 9. INSTALL-P1 – Fleet-Jitter und persistenter Circuit Breaker fehlen

## Status

**OFFEN**

Nodes prüfen nach ähnlichem Startdelay und danach in festen Intervallen. Ein dauerhaft fehlerhafter neuer Stand kann von vielen Nodes nahezu gleichzeitig wiederholt geladen werden.

## Fix

- deterministischer Jitter pro Computer-ID,
- persistente Fehleranzahl pro Zielmanifest,
- exponentieller Backoff,
- Circuit Breaker nach N Fehlschlägen,
- manuelle Freigabe oder neueres Manifest zum Entsperren.

---

# 10. MASTER-P1 – Config-Editor behauptet Übernahme vor `ACK_APPLIED`

## Status

**OFFEN**

Der Config-Editor ändert die lokal angezeigten Werte sofort nach dem Senden. Die Broadcastfunktionen senden FUEL-/WATER-/RT-Commands an alle Nodes, fordern aber kein `require_applied` an und warten nicht auf ein Ergebnis pro Zielnode.

MASTER speichert zwar eingehende `ACK_APPLIED`-Ergebnisse je Node, der Config-Editor verknüpft sie aber nicht mit dem gerade ausgelösten Edit.

## Folge

- UI zeigt einen neuen Wert, obwohl ein Ziel ihn abgelehnt hat.
- Teilfehler bei mehreren Nodes erscheinen als Gesamterfolg.
- Offline-/stale Nodes werden nicht separat ausgewiesen.
- keine eindeutige Command-ID-/Zielzuordnung im Editor.

## Verbindlicher Fix

- Auswahl `ALLE` oder konkrete Node-ID,
- Command mit `requires_applied=true`,
- ausgehende Message-/Command-ID speichern,
- Status pro Ziel: `QUEUED`, `DELIVERED`, `APPLIED`, `REJECTED`, `TIMEOUT`,
- lokalen angezeigten Sollwert erst nach Applied-ACK übernehmen oder klar als `PENDING` markieren,
- Auswahl und letzter bestätigter Wert persistent speichern.

---

# 11. RT-P0.1 – Produktions-Context liefert falschen `TURBINE_MODE`-Typ

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: `module_lifecycle.lua` indizierte `ctx.TURBINE_MODE.RAMP` (zwei Stellen: `start_module()` und `apply_safe_controls()`), während `nodes/rt/main.lua`s echter `make_lifecycle_ctx()` nur `TURBINE_MODE = CONFIG.TURBINE_MODE_RAMP or "RAMP"` lieferte — einen String, keine Tabelle. `turbine_control.lua`s eigene, an vielen Stellen verwendete Konvention (`ctx.CONFIG.TURBINE_MODE_RAMP`, immer ein reiner String, z.B. `"RAMP"`, `"OVERSPEED_BRAKE"`, `"UP"`, `"DOWN"`) bestätigt: `ctrl.mode` ist im gesamten Produktionscode konsequent ein Skalar, niemals eine Tabelle — die Tabellenform in `module_lifecycle.lua` war der eigentliche Fehler, nicht der String in `main.lua`.

Fix: `main.lua`s Feld wurde konsistent zu `TURBINE_MODE_RAMP` (weiterhin ein String) umbenannt — passend zur bereits etablierten Namenskonvention der übrigen flachen `make_lifecycle_ctx()`-Felder (`START_FLOW`, `RPM_TOL`). `module_lifecycle.lua` liest jetzt an beiden Stellen direkt `ctx.TURBINE_MODE_RAMP` statt `ctx.TURBINE_MODE.RAMP`. Die drei betroffenen Tests (`tests/rt_master_startup_end_to_end_test.lua`, `tests/rt_module_lifecycle_control_rod_caps_test.lua`, `tests/rt_module_lifecycle_safe_controls_test.lua`), die bisher jeweils einen eigenen, künstlichen Mock-Context mit der falschen Tabellenform (`TURBINE_MODE = { RAMP = 'RAMP' }`) bauten und die reale Produktionsabweichung dadurch nicht aufdeckten, wurden auf die korrekte Skalarform angepasst.

Pflicht-Test: `tests/rt_turbine_mode_context_shape_test.lua` — anders als die drei oben genannten (handgeschriebene Mock-Contexts, könnten erneut driften) prüft dieser neue Test strukturell direkt am echten Quelltext beider Dateien, dass `main.lua`s `make_lifecycle_ctx()` ein skalares `TURBINE_MODE_RAMP`-Feld definiert (und **kein** `TURBINE_MODE`-Tabellenfeld mehr reintroduziert) und dass `module_lifecycle.lua` an beiden Stellen exakt `ctx.TURBINE_MODE_RAMP` liest, nie `ctx.TURBINE_MODE.RAMP`. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Folge (vor dem Fix)

Beim echten Turbinenstart wurde `ctrl.mode` nicht zuverlässig auf den vorgesehenen Rampenmodus gesetzt.

## Fix (umgesetzt)

```lua
-- main.lua
TURBINE_MODE_RAMP = CONFIG.TURBINE_MODE_RAMP or "RAMP",
-- module_lifecycle.lua
ctrl.mode = ctx.TURBINE_MODE_RAMP
```

---

# 12. RT-P0.2 – Rampendauer wird als Millisekunden behandelt

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: Produktionscode lieferte `ramp_duration = function() return 30 end`, während `module_lifecycle.process_startup()` mit `os.epoch("utc")` in Millisekunden rechnet (`progress = (now - module.start_time) / duration`) — die Reaktorrampe erreichte dadurch bereits nach ungefähr 30 Millisekunden 100 Prozent statt der beabsichtigten 30 Sekunden, ein deutlicher Widerspruch zum 60-s-Startup-Stage-Timeout und zur fachlichen Bedeutung einer Rampe. Der bisherige End-to-End-Test bestätigte dieses (falsche) Verhalten sogar ausdrücklich, indem er die Fake-Clock nur um 100 ms erhöhte.

Fix: die Einheit ist jetzt explizit im Namen — `ramp_duration_ms(profile)` liefert garantiert Millisekunden (`STARTUP_RAMP_DURATION_S * 1000`, kein unbenannter Zahlenkonstante mehr). `module_lifecycle.lua` liest den Wert als `duration_ms` und dividiert korrekt Millisekunden durch Millisekunden. Der bisherige End-to-End-Test wurde auf die reale Dauer (30000 statt 100 ms Fake-Clock-Vorlauf) korrigiert.

Pflicht-Test: `tests/rt_ramp_duration_units_test.lua` — treibt die echte `process_startup()`-Funktion mit einer Fake-Clock über die tatsächlichen Produktionswerte (30000 ms): (1) nach 100 ms ist die Rampe nachweislich NICHT fertig (`progress < 1`, Modul bleibt `STARTING`); (2) Fortschritt steigt monoton (100 ms → 15 s); (3) bei Erreichen der konfigurierten Dauer wird das Modul `STABLE`; (4) weit nach der Deadline bleibt `progress` bei exakt `1` geklammert (kein Überschreiten), demonstriert an einem zweiten Modul, dessen Temperatur-Gate absichtlich nie erfüllt ist, damit die Rampen-Fortschrittsberechnung isoliert von der `STABLE`-Transition wiederholt geprüft werden kann. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt (die alte `module_lifecycle.lua` erwartet noch das alte `ramp_duration`-Feld, nicht `ramp_duration_ms` — ein direkter Beweis für die inkompatible Schnittstelle).

Beim Schreiben dieses Tests wurde zusätzlich ein separater, vorbestehender Bug in `update_module_limits()`s Coolant-Check entdeckt (`skip_coolant and nil or ctx.evaluate_reactor_coolant(...)` — der klassische Lua-`and/or`-Fallstrick: die `or`-Seite läuft immer, wenn die `and`-Seite `nil` ist, unabhängig von `skip_coolant`). Dieser Bug ist NICHT Teil dieses Fixes (eigenständiges Problem, bereits durch die vorbestehende Testausschlussliste als `NEEDS_MOCK` markiert) und wurde hier nur umgangen (echter `evaluate_reactor_coolant`-Stub im neuen Test), nicht behoben.

## Fix (umgesetzt)

```lua
-- main.lua
ramp_duration_ms = function(_ramp_profile)
  local STARTUP_RAMP_DURATION_S = 30
  return STARTUP_RAMP_DURATION_S * 1000
end,
-- module_lifecycle.lua
local duration_ms = ctx.ramp_duration_ms(module.ramp_profile)
local progress = safety.clamp((now - module.start_time) / duration_ms, 0, 1)
```

---

# 13. RT-P0.3 – `update_module_states()` ist im Produktionspfad nicht verdrahtet

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: `update_module_states()` existierte bereits in `nodes/rt/module_lifecycle.lua` und war bereits funktional getestet (`tests/rt_coolant_low_confirm_delay_test.lua`), wurde aber im Produktivcode nirgends aufgerufen — die einzige weitere Fundstelle war ein Test. `control_tick()` rief bisher nur `process_startup()`, Reactor-Control und Turbine-Control auf. Ohne `update_module_states()` waren unter anderem nicht regelmäßig aktiv: `STABLE -> RUNNING`, laufende Modul-Limitbewertung, Modulstate `LIMITED`, modulbezogene Temperatur-/Coolant-Transitionen außerhalb eines aktiven Startups.

Fix: `module_lifecycle.update_module_states(make_lifecycle_ctx())` wird jetzt in `control_tick()` aufgerufen — dieselbe `make_lifecycle_ctx()`, die `process_startup()` bereits erfolgreich verwendet, liefert bereits alle von `update_module_states()` benötigten Felder (`log`, `current_state`, `STATE`, `setState`, `node_state_machine`, `constants`, `evaluate_reactor_coolant`, `get_effective_regulator_rod_caps`, `read_current_rods`, `config.safety.*`, `get_target_rpm`) — keine neuen Ctx-Felder nötig. Reihenfolge bewusst sicherheitserst dokumentiert und getestet: `update_module_states()` (erkennt/reagiert auf neue Gefahrenzustände über alle Module) läuft VOR `process_startup()` (treibt nur das aktuell startende Modul voran) und VOR `reactor_control`/`turbine_control` (die Regelung darf nicht auf einem in diesem Tick bereits veralteten Sicherheitszustand aufbauen).

Pflicht-Test: `tests/rt_control_tick_wires_update_module_states_test.lua` — prüft strukturell an `control_tick()`s echtem Quelltext, dass `update_module_states()` tatsächlich aufgerufen wird UND in der dokumentierten Reihenfolge vor `process_startup()`, `reactor_control.updateReactorControl()` und `turbine_control.updateControl()` steht. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Fix (umgesetzt)

`module_lifecycle.update_module_states(make_lifecycle_ctx())` in `control_tick()` aufgenommen, sicherheitserst vor `process_startup()`, Reactor-Control und Turbine-Control.

---

# 14. RT-P1 – Persistenz- und Observability-Restpunkte

## Status

**OFFEN**

- Schema-Migration schreibt per ignoriertem `pcall`; Fehlschlag wird nicht sichtbar behandelt.
- `SET_REACTOR_FILL_TARGET` loggt Erfolg, obwohl `utils.write_config()` in einem ignorierten `pcall` scheitern kann.
- `build_discovery_context().build_capabilities()` verwendet unabhängig vom tatsächlichen Gerät zunächst den Turbinen-Key.
- UI und Telemetrie bauen weiterhin getrennte vollständige Gerätesnapshots.
- es fehlen echte Control-Tick-/Jitter-/Deadline-Metriken.

## Pflicht-Metriken

- Control-Ticks/s,
- maximale Ticklücke,
- Reactor-/Turbine-Reglerticks,
- Startup-Lifecycle-Ticks,
- übersprungene Writes,
- Discovery-Calls/min,
- Peripheral-Inspect-Calls/min,
- Deadlineüberschreitungen.

---

# 15. ENERGY-P1 – Heartbeat besitzt weiterhin zwei Zeitquellen

## Status

**OFFEN**

Die Schedulertrennung ist real umgesetzt. Die Heartbeatlogik ist aber nicht vollständig zentral:

- `main.lua` besitzt `hb_state.last_ts` und `send_heartbeat_if_due()`.
- der Matrix-Thread verwendet diese Quelle.
- `heartbeat.lua` besitzt zusätzlich `ctx.last_heartbeat_ts`, aktualisiert diesen separat und sendet auf seinem Heartbeat-Timer unbedingt über `ctx.send_heartbeat()`.

Ein Matrixabschluss und der Heartbeat-Timer können dadurch zeitlich nah nacheinander senden. Direkt nach dem initialen Heartbeat kann ein frühes Modemevent wegen des privaten `last_heartbeat_ts=0` ebenfalls einen zusätzlichen Send auslösen.

## Fix

Alle Threads verwenden ausschließlich:

```lua
heartbeat:send_if_due(now)
```

mit genau einer geteilten `last_sent_ts`-Quelle. Der Heartbeat-Timer darf keinen ungeprüften Send ausführen.

## Pflicht-Test

Fake-Scheduler mit gleichzeitigem Matrixabschluss, Modemevent und Heartbeat-Timer. In jedem konfigurierten Intervall maximal ein Präsenzheartbeat, abgesehen von explizit dokumentierter Startmeldung.

---

# 16. WATER-P1 – Persistenzfehler kann trotzdem als angewendet bestätigt werden

## Status

**OFFEN**

`SET_TARGET` ändert den RAM-Wert, versucht die Config zu schreiben und loggt einen Persistenzfehler. Anschließend wird der Command trotzdem mit Erfolg abgeschlossen.

## Folge

MASTER kann `ACK_APPLIED` erhalten, obwohl der Wert nach einem Neustart verloren geht.

## Fix

Commandresultat muss unterscheiden:

```text
APPLIED_VOLATILE
APPLIED_PERSISTED
REJECTED_PERSISTENCE
```

Für dauerhaft konfigurierte Sollwerte gilt `ok=true` erst nach erfolgreicher Persistierung oder der ACK muss explizit `persisted=false` tragen.

## Weiterer Nachweis

WATER bleibt statisch ansonsten weitgehend sauber. Notwendig sind Ingame-Tests für Tanklesefehler, Teil-Writefehler, Reboot, Update und Touchverarbeitung.

---

# 17. ROUTER-P0 – Alter bestätigter Zustand kann aktuellen ACK ersetzen

## Status

**BEHOBEN (2026-07-17)**

Bestätigt in `xreactor/nodes/fuel/redstone_router.lua`: die Batchlogik speicherte pro Ventil angefordertes `high`, ob ein ACK benötigt wird und das synchrone Ergebnis, aber NICHT die `command_id` des aktuellen Ventilkommandos. `handle_valve_ack()` legte im bestätigten Zustand (`confirmed_valve_state[key]`) ebenfalls keine Command-ID ab — dieser Zustand wird pro Ventilschlüssel nie gelöscht und überlebt beliebig viele nachfolgende Transaktionen. Wurde ein aktuelles Kommando nach allen Retries aus `pending_valve_acks` entfernt (verlorene ACKs), prüfte `_check_valve_batch()` nur noch, ob irgendein FRÜHER bestätigter Zustand für denselben Ventilschlüssel `applied=true` und denselben `high`-Wert besitzt — exakt der Fall bei der WAIT_FINAL_ACKS-Phase einer Transaktion, deren nächster Delivery-Zyklus in WAIT_BLOCK_ACKS erneut denselben `high=true`-Wert für dieselben Ventile anfordert.

Fix: `_set_valve()` gibt die erzeugte `command_id` als zweiten Rückgabewert zurück; `_request_valve_batch()` speichert sie in jedem Batcheintrag; `handle_valve_ack()` speichert `command_id` zusätzlich im Confirmed-State; `_check_valve_batch()` akzeptiert einen Confirmed-State nur noch, wenn dessen `command_id` exakt mit der `command_id` des AKTUELL angeforderten Kommandos übereinstimmt (zusätzlich zu `applied==true` und passendem `high`). Ein alter, zufällig passender Confirmed-State (andere oder fehlende `command_id`) zählt damit nicht mehr als Beweis für ein neues Kommando — das schließt automatisch auch den letzten Fix-Punkt ("vor einem neuen Command alten Confirmed-State nicht als aktuellen Beweis verwenden") mit ein, da jedes Kommando eine neue, aus Zeitstempel+Sequenznummer gebildete `command_id` erhält. Die zusätzlich vorgeschlagene Prüfung von "Bestätigungsalter und Peerstatus" wurde als durch die Command-ID-Bindung bereits abgedeckt bewertet: eine Bestätigung mit korrekter `command_id` kann per Konstruktion nicht älter sein als die aktuelle Anfrage (eindeutige ID pro Anfrage), und `VALVE_PHASE_TIMEOUT_MS` begrenzt ohnehin, wie lange eine Phase auf eine Bestätigung wartet.

Pflicht-Test: `tests/redstone_router_stale_confirmed_state_test.lua` — treibt die echte `begin_transaction()`/`tick()`-Zustandsmaschine über zwei aufeinanderfolgende Transaktionen: die erste läuft vollständig durch und hinterlässt in `confirmed_valve_state` für beide Ventile einen bestätigten `BLOCKED`-Zustand (`high=true`) aus ihrer WAIT_FINAL_ACKS-Phase; die zweite Transaktion sendet in ihrer eigenen WAIT_BLOCK_ACKS-Phase erneut `BLOCKED` (`high=true`) für dieselben Ventile — mit neuen, nachweislich anderen `command_id`s —, aber alle ihre ACKs gehen verloren (`check_pending_acks()` gibt nach `VALVE_ACK_MAX_RETRIES` auf). Beweist: die zweite Transaktion bricht sicherheitshalber ab (`transaction == nil`), ihr `action_fn` (Export) läuft niemals. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt (der beschriebene Bug reproduziert sich exakt wie im Audit beschrieben).

## Beispiel (ursprünglich beobachtet)

1. Ventil wurde früher bestätigt `BLOCKED`.
2. neuer `BLOCKED`-Befehl wird gesendet.
3. alle aktuellen ACKs gehen verloren.
4. Retrylogik gibt den aktuellen Befehl auf und entfernt ihn aus `pending`.
5. alter bestätigter `BLOCKED`-Eintrag passt weiterhin.
6. aktueller Batch kann fälschlich als bestätigt gelten.

## Verbindlicher Fix (umgesetzt)

- `_set_valve()` gibt die erzeugte `command_id` zurück.
- Batchentry speichert diese ID.
- `handle_valve_ack()` speichert `command_id` im Confirmed-State.
- `_check_valve_batch()` akzeptiert ausschließlich exakt dieselbe ID.
- vor einem neuen Command alten Confirmed-State für denselben Schlüssel nicht als aktuellen Beweis verwenden — durch die Command-ID-Bindung automatisch erfüllt.

---

# 18. ROUTER-P1 – Abschluss- und Fehlerzustände nach Export

## Status

**OFFEN**

- Wirft `action_fn` selbst einen Fehler, wird nur gewarnt; die Transaktion geht trotzdem nach `HOLD_OPEN` und erhält keinen normalen `on_error`-Abschluss.
- finale Blockbestätigung kann fehlschlagen; danach wird `block_all()` erneut gesendet, aber die Transaktion wird ohne bestätigten sicheren Istzustand gelöscht.
- ein solcher Zustand muss als latched Safetyfehler in Telemetrie/UI erhalten bleiben.

## Fix

Eigene Abschlusszustände:

```text
COMPLETE_SAFE
EXPORT_FAILED
FINAL_BLOCK_UNCONFIRMED
CANCELLED
```

Ein unbestätigt offenes Ventil darf nicht durch Löschen des Transaktionsobjekts diagnostisch verschwinden.

---

# 19. FUEL-P1 – Async-Ergebnis ist nicht sauber an seinen Zyklus gebunden

## Status

**OFFEN**

Der spätere Exportcallback schreibt in `self._state.last_cycle`. Dauert eine Ventiltransaktion länger als das normale Logistikintervall, kann zwischen Start und Callback bereits ein neuer Zyklus `last_cycle` ersetzt haben.

Zusätzlich wird `current_request.state` direkt nach `begin_transaction()` auf `delivering` gesetzt, obwohl die Transaktion zu diesem Zeitpunkt erst Ventile blockiert beziehungsweise ACKs abwartet.

## Folge

- Exportmenge kann dem falschen Zyklus zugerechnet werden.
- UI meldet „delivering“, bevor ein Export überhaupt zulässig ist.

## Fix

Eigener Transaction-Record mit stabiler ID:

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

Zyklusstatistik referenziert diese ID und wird nicht über ein global austauschbares `last_cycle` aktualisiert.

---

# 20. REPROCESSOR-P0 – Wireless-VALVE-Peers werden nicht verdrahtet

## Status

**BEHOBEN (2026-07-17)**

Bestätigt in `xreactor/nodes/reprocessor/main.lua`: FUEL erzeugt den Redstone-Router mit `comms = comms`, REPROCESSORs `get_rs_router()` erzeugte denselben Router dagegen komplett ohne `comms`. `redstone_router:refresh()` verwendet `self.comms:get_peers()`, um einen konfigurierten Integrator als erreichbaren Wireless-VALVE-Node zu erkennen — ohne COMMS-Referenz bleibt die Peer-Liste leer, danach wird nur noch nach einem lokalen Peripheral gleichen Namens gesucht.

Fix: `comms = comms` wird jetzt auch in REPROCESSORs `get_rs_router()` an `redstone_router_lib.new()` übergeben — identisch zu FUEL. `get_rs_router()` ist ein Lazy-Singleton, der erst zur Laufzeit (aus Event-Handlern/Tick-Loop) aufgerufen wird, zu diesem Zeitpunkt ist die vorwärtsdeklarierte `comms`-Upvalue bereits per `comms_service.new(...)` zugewiesen — keine zusätzliche nachträgliche Injektion nötig, die bestehende Konstruktionsreihenfolge reicht bereits aus.

Pflicht-Test: `tests/reprocessor_wireless_valve_comms_wiring_test.lua` — prüft strukturell, dass `get_rs_router()`s Konstruktoraufruf tatsächlich `comms = comms` enthält, und demonstriert zusätzlich funktional mit dem echten `redstone_router.lua`-Modul den beobachtbaren Unterschied: ohne `comms` wird ein konfigurierter Wireless-Integrator gar nicht erkannt (`self._state.integrators[name] == nil`), mit `comms` wird er korrekt als `network=true` erkannt. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Fix (umgesetzt)

- `comms = comms` an `redstone_router_lib.new()` übergeben.
- Reconnect-/Peer-Down-/Peer-Up-Test bleibt als weiterführender Ingame-Nachweis offen (kein neuer statischer Fund).

---

# 21. VALVE-P1 – Senderbindung und Sorter-Reconnect

## Status

**OFFEN**

## Senderbindung

`trusted_source` ist optional. Ohne dieses Feld akzeptiert die VALVE-Node jedes korrekt adressierte `SET_VALVE` auf dem dedizierten Kanal. ACKs besitzen ebenfalls keine authentisierte Senderidentität.

Für einen Safety-Aktor sollte die erlaubte Steuerquelle verpflichtend oder über einen installierten Pairingzustand gebunden sein.

## Sorter-Reconnect

`get_sorter()` cached den einmal gewrappten Sorter dauerhaft. Schlägt ein späterer Call wegen Detach/Reattach oder ersetztetem Peripheral fehl, wird `sorter_device` nicht verworfen und neu gebunden.

## Fix

- verpflichtendes Pairing beziehungsweise `trusted_source`,
- ACK mit `src`, `dst` und aktuellem Commandbezug,
- bei Sorter-Callfehler Cache leeren,
- beim nächsten Retry neu wrappen,
- Statusfelder für `actuator_online`, `last_apply_ts`, `last_error_ts`.

---

# 22. LOG-P0 – Reclaim verwendet stale Free-Space-Cache

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: `free_space()` cached Werte für `FREE_SPACE_CACHE_TTL` (2 echte Sekunden, per `os.clock()`) pro Mount. `reclaim_oldest()` prüfte vor jeder Löschung denselben gecachten Wert, löschte eine Datei, invalidierte den Cache aber nicht. Da mehrere aufeinanderfolgende Löschungen innerhalb eines einzigen, synchronen Reclaim-Laufs praktisch keine messbare Zeit verbrauchen, blieb der Cache-Eintrag über den gesamten Lauf "frisch" — die Schleife sah bei jeder Iteration weiterhin den alten, niedrigen Free-Space-Wert und entfernte munter weiter, obwohl bereits nach der ersten Löschung genug Platz frei sein konnte. Die frühere pauschale Komplettlöschung war zwar bereits entfernt (siehe Abschnitt 16), aber diese Schleife konnte im Extremfall trotzdem alle aufgelisteten Dateien löschen.

Fix: `free_space_cache[mount] = nil` direkt nach jeder erfolgreichen Löschung, damit die nächste `free_space()`-Abfrage tatsächlich neu misst. Zusätzlich umgesetzt: `reclaim_oldest()` erhält einen `exclude_path`-Parameter, der die gerade tatsächlich offene Zieldatei (die der LOG Collector im selben Schreibversuch befüllen will) niemals löscht — beide Aufrufstellen (`write_log()`s Vorab-Check, `flush_bucket()`s Out-of-Space-Retry) übergeben jetzt den betroffenen Zielpfad. Ein hartes `RECLAIM_MAX_FILES_PER_RUN`-Limit (64) begrenzt zusätzlich den maximalen Schaden pro Lauf, selbst falls die Free-Space-Messung aus einem anderen Grund weiterhin falsch wäre. Die Punkte "Mindestanzahl/Mindestalter geschützter Dateien" und "UI zeigt Retention-/Reclaimereignisse" aus dem ursprünglichen Fix-Vorschlag bleiben als LOG-P1-Weiterentwicklung offen (siehe Abschnitt 23) — kein Datenverlustrisiko mehr durch DIESEN Bug, da die Kernursache (stale Cache) behoben ist.

Pflicht-Test: `tests/log_collector_reclaim_cache_invalidation_test.lua` — treibt die echte `reclaim_oldest()`-Funktion mit einer Fake-Disk aus drei gleich großen Dateien und einem `os.clock()`, der über den GESAMTEN Testlauf einen konstanten Wert liefert (simuliert exakt die reale Bedingung: synchrone Löschungen verbrauchen keine messbare Zeit). Fake-Free-Space steigt nach der ersten Löschung über das angeforderte Ziel — beweist, dass exakt eine Datei entfernt wird (nicht alle drei) und dass `fs.getFreeSpace()` nach der Löschung tatsächlich erneut aufgerufen wird. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt (entfernt dort nachweislich alle drei Dateien statt einer).

## Fix (umgesetzt)

```lua
-- nach jeder erfolgreichen Loeschung:
free_space_cache[mount] = nil
```

plus `exclude_path`-Schutz der offenen Zieldatei und `RECLAIM_MAX_FILES_PER_RUN`-Obergrenze.

---

# 23. LOG-P1 – Rotation und Datenhaltungsregeln explizit machen

## Status

**OFFEN**

Eine einzelne Node-Logdatei wird bei Überschreiten von `MAX_LOG_BYTES` gelöscht statt archiviert oder atomar rotiert. Das kann beabsichtigt sein, ist aber keine nachvollziehbare Retentionpolicy.

## Fix

- nummerierte oder datierte Rotation,
- Maximalalter und Maximalgröße pro Rolle,
- Mindestanzahl erhaltener Dateien,
- UI zeigt Retention-/Reclaimereignisse,
- Tests für Full-Disk, Mountverlust und Reattach.

---

# 24. TEST-P0 – 72 Tests sind ausgeschlossen

## Status

**KRITISCH TEILWEISE**

Aktuelle Ausschlusslisten:

```text
66 Lua-Tests
6 Python-Tests
72 insgesamt
```

Darunter befinden sich weiterhin echte Verhaltenskategorien wie:

- ENERGY-Architektur und Payloadcache,
- MASTER-ACK-/Shutdown-Semantik,
- RT-Control, Safety, Startup und Sync,
- Logger-/Registry-Runtime,
- Comms-Hysterese.

Der neue RT-Startup-Test zeigt außerdem ein strukturelles Problem des Testansatzes: Er behauptet, den Produktions-Context zu spiegeln, liefert aber einen anderen `TURBINE_MODE`-Typ und kodiert die 30-ms-Rampensemantik als erwartet.

## Regel

Ein Test darf nur entfernt werden, wenn:

1. die Anforderung nachweislich nicht mehr existiert, oder
2. ein aktueller, gleichwertiger Test dieselbe Anforderung vollständig schützt.

`CONTENT_DRIFT` ist keine Freigabe zum Überspringen, sondern muss einzeln als echter Produktionsfehler oder veraltete Erwartung entschieden werden.

## Sofortige neue Tests

1. Installer-Powerloss-Matrix und Completion-Marker.
2. Update-Quiesce je Rolle.
3. ~~RT-Produktions-Context-Shape.~~ BEHOBEN (2026-07-17, siehe Abschnitt 11): `tests/rt_turbine_mode_context_shape_test.lua`.
4. ~~RT-Rampeneinheit mit Fake-Clock.~~ BEHOBEN (2026-07-17, siehe Abschnitt 12): `tests/rt_ramp_duration_units_test.lua`.
5. ~~produktive Verdrahtung von `update_module_states()`.~~ BEHOBEN (2026-07-17, siehe Abschnitt 13): `tests/rt_control_tick_wires_update_module_states_test.lua`.
6. ~~Router-ACK muss aktuelle Command-ID matchen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 17): `tests/redstone_router_stale_confirmed_state_test.lua`.
7. ~~REPROCESSOR Wireless-VALVE-Discovery.~~ BEHOBEN (2026-07-17, siehe Abschnitt 20): `tests/reprocessor_wireless_valve_comms_wiring_test.lua`.
8. ENERGY exakt eine Heartbeat-Zeitquelle.
9. ~~LOG-Reclaim mit Cacheinvalidierung.~~ BEHOBEN (2026-07-17, siehe Abschnitt 22): `tests/log_collector_reclaim_cache_invalidation_test.lua`.
10. MASTER Config-Editor Applied-ACK je Zielnode.

---

# 25. CI-Status

Der Workflow führt aus:

- Offline-Validator,
- funktionale Lua-Tests,
- funktionale Python-Tests.

Für den geprüften Code-Head `423a2f0b5198de61aaaf71c8fa28413d151b63bd` wurden über die GitHub-Schnittstelle jedoch weder kombinierte Statuschecks noch zugeordnete Pull-Request-Workflow-Runs zurückgegeben.

Daher gilt:

```text
Workflow vorhanden != dieser konkrete Head nachweislich grün
```

## Definition of Done für CI

- aktueller `beta`-Head besitzt einen sichtbaren grünen Check,
- keine kritische Safety-/Installeranforderung steht auf einer Ausschlussliste,
- Testergebnis enthält Anzahl ausgeführt/übersprungen/fehlgeschlagen,
- Ingame-/Hardwaretests werden als separate dokumentierte Abnahme geführt.

---

# 26. Rollen ohne neuen statischen P0-Fund

## Shared Runtime

Das Event-Gating über `wants_events` ist weiterhin sinnvoll umgesetzt. Rein periodische Services laufen nicht zusätzlich bei jedem Event. Offener Querschnittspunkt bleibt das fehlende Update-Quiesce.

## WATER

Neben der Persistenz-/ACK-Semantik wurde kein neuer statischer P0-Blocker bestätigt. Ingame-Nachweise bleiben erforderlich.

## Manifest-Rollen-Scope

Die zuletzt bekannten konkreten Scopefehler für REPROCESSOR, Speaker und VALVE-Support sind im aktuellen Manifest behoben. Offen bleibt die generische Vorabvalidierung des Installationsplans.

---

# 27. Verbindliche Bearbeitungsreihenfolge

1. ~~**ROUTER-P0:** aktuellen ACK über Command-ID statt alten Confirmed-State beweisen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 17): `tests/redstone_router_stale_confirmed_state_test.lua`.
2. ~~**REPROCESSOR-P0:** COMMS-Peers an Wireless-Router verdrahten.~~ BEHOBEN (2026-07-17, siehe Abschnitt 20): `tests/reprocessor_wireless_valve_comms_wiring_test.lua`.
3. ~~**RT-P0:** `TURBINE_MODE`-Context-Typ korrigieren.~~ BEHOBEN (2026-07-17, siehe Abschnitt 11): `tests/rt_turbine_mode_context_shape_test.lua`.
4. ~~**RT-P0:** Rampendauer in eindeutigen Millisekunden konfigurieren.~~ BEHOBEN (2026-07-17, siehe Abschnitt 12): `tests/rt_ramp_duration_units_test.lua`.
5. ~~**RT-P0:** `update_module_states()` in den Produktions-Controlpfad aufnehmen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 13): `tests/rt_control_tick_wires_update_module_states_test.lua`.
6. **INSTALL-P0:** Installationsjournal, Completion-Marker und Release-last-Commit.
7. **INSTALL-P0:** Runtime-Quiesce und sichere Aktorzustände vor Reinstall.
8. **INSTALL-P0:** alle kritischen FS-Ergebnisse prüfen und unsicheren Backup-Fallback entfernen.
9. ~~**LOG-P0:** Free-Space-Cache im Reclaimpfad korrigieren.~~ BEHOBEN (2026-07-17, siehe Abschnitt 22): `tests/log_collector_reclaim_cache_invalidation_test.lua`.
10. **MASTER-P1:** Einzelnode-/Alle-Auswahl und Applied-ACK je Ziel.
11. **ENERGY-P1:** genau eine Heartbeat-Zeitquelle.
12. **WATER/RT-P1:** Persistenzresultat ehrlich im Command-ACK abbilden.
13. **VALVE-P1:** verpflichtende Senderbindung und Sorter-Reconnect.
14. **INSTALL/MANIFEST-P1:** vollständige Planvalidierung und nur eine Installerimplementierung.
15. **TEST-P0:** Ausschlusslisten Test für Test abbauen.
16. Danach Ingame-Last-, Funkverlust-, Reconnect-, Reboot-, Stromausfall- und Updateabnahme.

---

# 28. Definition of Done

## Installer / Auto-Update

- alter oder neuer Stand ist nach jedem Fehler vollständig und eindeutig,
- Release wird erst beim Commit geschrieben,
- Runtime ist vor Dateiersatz beendet und Aktoren sind sicher,
- jeder FS-Schritt wird geprüft,
- generische `.xr_prev`-Recovery vorhanden,
- ein kanonischer Installerpfad,
- Jitter und persistenter Circuit Breaker.

## MASTER

- `ALLE` oder konkrete Zielnode auswählbar,
- Applied-ACK/Reject/Timeout je Node sichtbar,
- keine optimistische Erfolgsmeldung,
- Teilfehler bleiben sichtbar und persistent nachvollziehbar.

## RT

- echter Produktions-Context wird im Test verwendet,
- Turbinenmodus korrekt gesetzt,
- Rampenzeit in eindeutiger Einheit,
- `update_module_states()` läuft regelmäßig,
- Migration und Sollwertpersistenz melden echte Resultate,
- Control-/Jittermetriken belegen den Takt.

## ENERGY

- getrennte Schedulergruppen,
- genau eine Heartbeat-Zeitquelle,
- keine Doppel-Sends bei gleichzeitigem Timer/Matrixabschluss,
- langsame Matrixcalls blockieren COMMS/UI nicht.

## WATER

- Tank-Snapshot und BLOCK_ALL ingame bestätigt,
- Writefehler sichtbar,
- `SET_TARGET`-ACK unterscheidet volatile und persistierte Übernahme,
- Reboot und Update erhalten Config.

## FUEL / Router

- Export nur mit ACK der **aktuellen** Command-ID für jedes betroffene Ventil,
- alte Bestätigungen sind kein aktueller Beweis,
- Async-Transaktion besitzt stabile ID und korrekte Zykluszuordnung,
- finaler Blockfehler bleibt als Safetyalarm sichtbar,
- kein Export bei invalidem Routing.

## REPROCESSOR

- Wireless-VALVE-Nodes werden über COMMS-Peers gefunden,
- Standby/MASTER_STALE bricht Transaktion sofort ab,
- kein Export nach Standby,
- vollständige Rolleninstallation.

## VALVE

- Failed-Write-Retry führt echten neuen Write aus,
- Sender ist gebunden/authentisiert,
- Sorter kann nach Detach/Reattach neu gebunden werden,
- ACK enthält eindeutigen aktuellen Commandbezug.

## LOG Collector

- Probe-Fehler löscht keine Logs,
- Reclaim misst nach jeder Löschung frisch,
- maximale Löschgrenzen und Retentionpolicy,
- ACK erst nach Persistierung,
- Full-/Mount-/Reconnecttests grün.

## Tests / CI

- keine kritischen Produktionsanforderungen ausgeschlossen,
- aktueller Head sichtbar grün,
- echte Produktionscontexts statt vereinfachter, abweichender Mocks,
- Hardware-/Ingame-Abnahme separat dokumentiert.
