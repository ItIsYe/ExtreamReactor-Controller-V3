# Coding-AI-Aufgaben: aktueller Gesamt-Audit aller Nodes

Stand: 2026-07-14  
Ziel-Branch: `beta`  
Geprüfter Code-Head vor dieser Aktualisierung: `b1b15e292b94a177b98b5e49845bb70a2e4e143d`  
Geprüfte Release: `beta-v427` / `manifest-v427`

## Zweck

Der aktuelle GitHub-Stand wurde erneut vollständig gegen den Auditstand vom 13. Juli geprüft. Seitdem wurden 30 Commits hinzugefügt. Diese Datei enthält deshalb nur noch:

- weiterhin offene oder nur teilweise umgesetzte Aufgaben,
- neu bestätigte Risiken,
- den aktuellen Bereinigungsstatus,
- die verbindliche Reihenfolge für die restliche Arbeit.

Vollständig erledigte Punkte werden nicht erneut als Aufgabe geführt.

---

# 1. Aktueller Gesamtstatus

| Bereich | Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Config | **KRITISCH OFFEN** | Installer erhält weiterhin nicht den vollständigen Benutzer-Configbestand |
| Shared Runtime | **KRITISCH OFFEN** | Modem- und UI-Events führen weiterhin den gesamten Service-Manager aus |
| MASTER | **WEITGEHEND ERLEDIGT** | mehrere Zielnodes und vollständige Config-/CI-Nachweise fehlen |
| RT | **KRITISCH OFFEN** | feste 10-Hz-Regelung weiterhin nicht umgesetzt |
| ENERGY | **TEILWEISE** | echte Schedulergruppen-Isolation fehlt |
| WATER | **WEITGEHEND ERLEDIGT** | Ingame-Regressionstest und Config-Update-Test fehlen |
| FUEL | **TEILWEISE** | blockierendes Routing und End-to-End-Ingame-Nachweis bleiben |
| REPROCESSOR | **TEILWEISE** | blockierendes Routing und End-to-End-Ingame-Nachweis bleiben |
| VALVE | **WEITGEHEND ERLEDIGT** | Protokoll unter Paketverlust und Reconnect ingame testen |
| LOG Collector | **WEITGEHEND ERLEDIGT** | Sourcecode-Patching des Renderers bleibt Wartbarkeitsrisiko |
| Tests / CI | **KRITISCH OFFEN** | Workflow führt weiterhin nur den Offline-Validator aus |
| Repository-Bereinigung | **TEILWEISE** | eindeutig obsolete v360-Workflowdatei entfernt; weitere Löschungen nur mit Referenznachweis |

---

# 2. Seit dem letzten Audit umgesetzt

## WATER

Umgesetzt wurden:

- gemeinsamer generationsbasierter Tank-Snapshot,
- Tankwerte pro Messgeneration nur einmal lesen,
- sichere BLOCK_ALL-Policy bei unbekanntem Tankstand,
- Redstone-State erst nach bestätigtem Write ändern,
- persistentes `SET_TARGET`,
- UI-Modell- und Touchpfade wurden in den nachfolgenden Änderungen überarbeitet.

Nicht erneut umbauen, bevor ein konkreter Regressionstest fehlschlägt.

## REPROCESSOR

Umgesetzt wurden:

- doppeltes `read_buffers()` im Payload entfernt,
- kurzer gemeinsamer Payloadcache,
- Round-Robin-/Budget-/Backoff-Verarbeitung für `process_buffers()`,
- Routing-/Configfehler aus dem vorherigen Audit wurden in den nachfolgenden Commits bearbeitet,
- VALVE-ACK-Verarbeitung wurde in FUEL und REPROCESSOR eingebunden.

Offen bleibt vor allem das blockierende Ventilfenster über `route_and_act()`.

## VALVE

Umgesetzt wurden:

- korrekte Standard-Indizes des CC:Tweaked-`modem_message`-Events,
- Stateänderung nur nach erfolgreichem Redstone-Write,
- ACK/Retry/Dedupe,
- Sender-/Zielprüfung,
- eindeutige `command_id`,
- bestätigter Zustand getrennt vom nur angeforderten Zustand,
- Schlüsselung pro Integrator und Seite,
- Fail-Safe bleibt erhalten.

## MASTER

Umgesetzt wurden:

- persistente PEAK-/IDLE-Schwellwerte,
- AUTO-UPDATE-Schalter schreibt nun die echte lokale Updaterconfig,
- Terminal-`mouse_click`,
- stale RT-Fuelwerte werden nicht mehr als frisch weitergereicht,
- wiederholte Modelserialisierung pro gleicher View wurde reduziert,
- erfolgreiches Rendern erzeugt nicht mehr pro Frame eine DEBUG-Zeile.

## RT

Umgesetzt wurden:

- SAFE-Recovery-Contextfehler,
- Startup-Report-Rollenvergleich,
- dynamisches Ziel-RPM im Monitor,
- Release-/Buildinformation aus dem Monitor-Hotpath entfernt,
- doppelte manuelle 60-Sekunden-Discovery entfernt,
- Peripheral-Wrapper aus Discovery werden im Controlpfad wiederverwendet,
- Capability-/Wrapperarbeit wurde teilweise reduziert.

Die feste Control-Cadence ist trotzdem weiterhin offen.

## ENERGY

Umgesetzt wurden:

- zusätzliche ungeregelte Heartbeats aus dem Matrixpfad beseitigt,
- Storage-Metriken zeitlich gestaffelt,
- Capacity wird seltener gelesen,
- Snapshots und last-good-Verhalten bleiben bestehen.

## LOG Collector

Umgesetzt wurden:

- persistente Batch-Writes,
- ACK weiterhin erst nach bestätigtem Write,
- sofortiger Flush für wichtige Fehlerlevel,
- O(1)-Dedupe-Ringbuffer,
- nur ein normaler ACK-Sendeweg statt Fan-out über alle Modems,
- UI-Redraw bei Burstverkehr rate-limitiert.

## FUEL / Routing

Umgesetzt wurden unter anderem:

- funktionsfähige FUEL- und REPROCESSOR-Configmodule mit korrektem `return`,
- VALVE-ACK-/Retrypfad,
- bestätigter und angeforderter Ventilzustand getrennt,
- mehrere frühere UI- und Routing-Persistenzprobleme.

---

# 3. GLOBAL-P0 – Benutzerkonfiguration updatesicher machen

## Status

**KRITISCH OFFEN**

Der aktuell aktive Installer sichert vor dem vollständigen Löschen von `/xreactor` weiterhin nur:

```text
config/node_id.txt
config/capacity_cache.lua
config/role.lua
config/optional_features.lua
config/ampel_thresholds.lua
```

Danach wird `/xreactor` vollständig gelöscht.

Damit sind weiterhin nicht generell geschützt:

```text
config/master.lua
config/rt.lua
config/energy.lua
config/water.lua
config/fuel.lua
config/reprocessor.lua
config/valve.lua
config/fuel_routes.lua
config/reproc_routes.lua
config/remote_update.lua
Registry-, Layout- und weitere Benutzerdateien
```

Einzelne Rollen schreiben inzwischen bewusst in geschützte Benutzerpfade. Der Installer schützt diese Pfade jedoch noch nicht vollständig. Dadurch kann ein Auto-Update genau die neuen persistenten Einstellungen wieder löschen.

## Verbindlicher Fix

1. Den vollständigen Ordner `/xreactor/config` vor dem Löschen außerhalb von `/xreactor` sichern.
2. Nach erfolgreicher Installation atomar wiederherstellen.
3. Temporäre und nachweislich regenerierbare Cachedateien über eine explizite Ausschlussliste behandeln.
4. Configschema versionieren und neue Defaults migrationssicher ergänzen.
5. Nie eine komplette Config aus Runtime-State blind überschreiben.
6. Bei fehlgeschlagener Installation letzte gültige Config wiederherstellen.

## Pflicht-Test

Für jede Rolle:

1. Benutzerwerte verändern.
2. Auto-Update/Reinstall ausführen.
3. Neustarten.
4. Alle Werte und Routen müssen erhalten bleiben.
5. Neue Defaultfelder müssen ergänzt sein.

---

# 4. SHARED-P0 – Event- und Timerpfad trennen

## Status

**KRITISCH OFFEN**

Die gemeinsame Support-Runtime führt bei einer Modemnachricht weiterhin aus:

```lua
comms:handle_event(event)
services:tick(nil, event)
```

Auch Monitor-/Maus-/Key-Ereignisse werden an den gesamten Service-Manager gegeben.

Folge: Ein Event kann weiterhin alle Services aufrufen, darunter Control, Discovery, Telemetrie, UI, Failsafe und Maintenance. Damit bleibt die Laufzeit abhängig vom Netzwerk- und Eingabeverkehr.

## Ziel

```lua
services:handle_event(event)
services:tick_due(now_ms)
```

Jeder Service besitzt getrennt:

```lua
handle_event(event)
tick(now_ms)
next_due_at
```

## Anforderungen

- Modemempfang und ACK sofort.
- Periodische Arbeit ausschließlich nach echter Zeit.
- Eventstürme werden koalesziert.
- Attach/Detach wird gezielt an Discovery gesendet.
- UI-Events erreichen ausschließlich UI-relevante Services.
- kein Event erzeugt zusätzliche vollständige Controlzyklen.

---

# 5. RT-P0 – feste 10-Hz-Control-Cadence

## Status

**KRITISCH OFFEN**

Der RT-Control-Service ist weiterhin ohne eigene Deadline registriert:

```lua
services:add({
  name = "control",
  tick = function() control_tick() end,
})
```

Damit läuft er weiterhin über den gemeinsamen Support-Eventloop:

- regulär ungefähr alle 0,5 Sekunden,
- zusätzlich bei Modem- und UI-Events.

Die Dokumentvorgabe ist nicht umgesetzt:

```lua
scheduler_interval_s = 0.05
reactor_control_interval_s = 0.10
turbine_control_interval_s = 0.10
```

## Verbindlicher Fix

- eigener monotonic Scheduler,
- Safety zuerst,
- Rod- und Flow-Regler mit separaten Deadlines,
- keine Nachhol-Bursts,
- Commands dürfen nur einen koaleszierten vorgezogenen Tick markieren,
- Hardware-Writes bleiben zusätzlich cooldown-/change-basiert,
- Overspeed/SCRAM umgehen normale Cooldowns.

## Abnahme

- 10 Hz unter ruhigem Betrieb,
- 10 Hz auch bei Eventsturm,
- keine zusätzlichen Controlticks durch 1.000 Modemevents,
- Safety reagiert weiterhin rechtzeitig,
- Ticklücke und Laufzeit werden gemessen.

---

# 6. RT-P1 – verbleibende Hotpath-Arbeit

## Teilweise offen

Die Wrapper-Wiederverwendung wurde verbessert. Noch zu prüfen beziehungsweise abzuschließen:

- identische `setActive`, Flow-, Coil- und Rod-Writes vollständig unterdrücken,
- Capability-Cache exakt einmal pro Discoverygeneration,
- Singular-/Plural-Kind-Namen normalisieren,
- gezielte Invalidierung bei Attach/Detach,
- gemeinsamer nicht-sicherheitskritischer Hardware-Snapshot für UI und Telemetrie,
- Discovery-Default nach erfolgreichem Boot deutlich langsamer als 10 Sekunden.

Diese Punkte müssen anhand echter Metriken beurteilt werden, nicht nur statisch.

---

# 7. ENERGY-P0 – Schedulergruppen wirklich isolieren

## Status

**TEILWEISE OFFEN**

Heartbeatfrequenz und Storage-Sampling wurden verbessert. Die Architektur trennt langsame Arbeit jedoch noch nicht vollständig in unabhängige Gruppen.

Zielgruppen:

```text
1. Comms + Heartbeat + Commands
2. Matrix-Sampling
3. Storage-Sampling
4. UI + Telemetrie
5. Discovery
```

Ein langsamer Matrixcall darf keine der anderen Gruppen blockieren oder über UI-/Eventpfade in den Comms-Thread gelangen.

## Pflicht-Test

Einen Matrixadapter künstlich mehrere Sekunden blockieren lassen:

- Heartbeat bleibt im erlaubten Intervall,
- Commands werden verarbeitet,
- Storage-last-good bleibt sichtbar,
- UI zeigt stale statt einzufrieren,
- Discovery läuft später weiter.

---

# 8. FUEL / REPROCESSOR – Routing nicht blockierend machen

## Status

**OFFEN**

Der gemeinsame Redstone-Router verwendet weiterhin einen blockierenden Ablauf mit `os.sleep()` für Settle- und Valve-open-Zeiten.

Während dieses Fensters können Eventloop-Aufgaben verzögert werden.

## Ziel-State-Machine

```text
IDLE
OPEN_PATH
WAIT_ACK
WAIT_SETTLE
EXPORT
HOLD_OPEN
BLOCK_ALL
COMPLETE
ERROR
```

## Anforderungen

- kein `os.sleep()` im normalen Routingpfad,
- Heartbeat, Commands, UI und Failsafe bleiben aktiv,
- ACK-Timeout führt zu BLOCK_ALL,
- Abbruch/Shutdown blockiert sofort alle Ventile,
- parallele Lieferungen werden serialisiert oder klar budgetiert,
- aktive Transaktion und Fehler sind in UI/Telemetrie sichtbar.

---

# 9. MASTER-P1 – Mehrere Zielnodes

## Status

**OFFEN**

FUEL-Reserve und WATER-Ziel werden weiterhin typischerweise an den ersten gefundenen Node der Rolle gesendet.

Bei mehreren Nodes muss die UI anbieten:

- konkreten Node,
- alle Nodes der Rolle,
- sichtbare ACK-/Fehlerauswertung,
- keine von Tabellenreihenfolge abhängige Auswahl.

---

# 10. LOG-P2 – Renderer ohne Sourcecode-Textpatch

## Status

**OFFEN, Wartbarkeit**

`nodes/log_collector/mockup_main.lua` liest `main.lua` als Text und ersetzt die lokale `draw()`-Funktion anhand fester Marker.

Das funktioniert aktuell, ist aber fragil. Eine harmlose Umbenennung oder Markeränderung kann den Start brechen.

## Ziel

- Renderer als normales Modul injizieren,
- keine Quelltextmanipulation zur Laufzeit,
- `main.lua` enthält Runtime und ruft eine Renderer-Schnittstelle auf,
- Fallback-Renderer bei Modulfehler.

`main.lua` und `mockup_main.lua` dürfen bis zu diesem Umbau nicht als „doppelt“ gelöscht werden: Der aktive Startpfad benötigt beide.

---

# 11. TEST-P0 – CI führt die Testsuite nicht aus

## Status

**KRITISCH OFFEN**

`.github/workflows/offline-tests.yml` führt weiterhin nur aus:

```text
lua5.2 tools/offline_validate.lua
```

Damit werden zwar Lua-Dateien geparst und Manifestreferenzen geprüft, aber die zahlreichen funktionalen Lua- und Python-Tests unter `tests/` nicht automatisch ausgeführt.

## Verbindlicher CI-Umbau

1. Offline-Validator.
2. Alle kompatiblen `tests/*.lua`.
3. Alle `tests/*.py`.
4. Explizite Ausschlussliste nur mit Begründung.
5. Rollenweise Jobgruppen.
6. Pflichtstatuscheck für `beta` und Pull Requests.
7. Testdateien, die noch alte Architekturen erwarten, aktualisieren oder löschen, falls ihr Schutz vollständig durch einen neuen Test ersetzt wurde.

## Wichtige neue/aktualisierte Tests

```text
config_persistence_all_roles_test
shared_event_timer_separation_test
rt_fixed_cadence_test
rt_control_event_storm_test
energy_scheduler_isolation_test
fuel_reprocessor_nonblocking_routing_test
valve_packet_loss_retry_test
master_multi_target_selection_test
log_renderer_entrypoint_test
```

---

# 12. Repository-Bereinigung

## Gelöscht

### `.github/workflows/publish-beta-v360.yml`

Die Datei war eindeutig obsolet und gefährlich:

- Name und Inhalt waren fest auf `v360` verdrahtet.
- Aktuelle Release ist `v427`.
- Bei Ausführung hätte sie `release.lua` und `manifest.lua` auf v360 zurückgesetzt.
- Sie war weder allgemeiner Releaseworkflow noch Bestandteil des normalen Buildpfads.

Entfernt im Commit:

```text
54dbae7799ffe20304da4820e6e58ba81df19e9e
```

## Bewusst nicht gelöscht

Folgende Kategorien sind weiterhin nötig und dürfen nicht pauschal als „alt“ entfernt werden:

- Audit-Dokumente, solange aktuelle Aufgaben darauf verweisen,
- Tests, solange sie Schutz liefern oder erst noch in CI aufgenommen werden,
- `nodes/log_collector/main.lua` und `mockup_main.lua`, weil der aktive LOG-Start beide verwendet,
- Default-Configdateien, weil sie für Fresh Install und Migration benötigt werden,
- Installer-Module, auch wenn der Root-Installer Teile einbettet,
- optionale Module, die über Manifestfeatures installiert werden.

## Regel für weitere Löschungen

Eine Datei wird erst gelöscht, wenn alle Punkte erfüllt sind:

1. nicht in `manifest.lua`,
2. nicht von `require`, `dofile`, `shell.run`, Startup oder Workflow referenziert,
3. nicht von Tests, Scripts oder Installer benötigt,
4. kein dokumentierter manueller Entry-Point,
5. kein Migrations-/Recoveryzweck,
6. Ersatzfunktion besitzt Regressionstest.

Dateien mit nur vermuteter Redundanz werden nicht gelöscht.

---

# 13. Verbindliche Reihenfolge

1. **GLOBAL-P0:** vollständige Config-Persistenz des Installers.
2. **SHARED-P0:** Event- und Timerpfad trennen.
3. **RT-P0:** echte 10-Hz-Cadence.
4. **TEST-P0:** vollständige Testsuite in CI.
5. **ENERGY-P0:** echte Schedulergruppen-Isolation.
6. **FUEL/REPROCESSOR:** nicht blockierende Routing-State-Machine.
7. **RT-P1:** restliche Hotpath-Writes, Capabilities und Snapshotarbeit.
8. **MASTER-P1:** Multi-Node-Zielauswahl.
9. **LOG-P2:** Sourcecode-Patching durch normale Renderer-Schnittstelle ersetzen.
10. Danach erneuter Referenzscan und weitere sichere Dateibereinigung.

---

# 14. Definition of Done

- Updates erhalten alle Benutzerconfigs und Routen.
- Modem-/UI-Events erzeugen keine periodischen Vollticks.
- RT-Regelung läuft gemessen und deterministisch mit 10 Hz.
- langsame ENERGY-Peripherals blockieren Comms/Heartbeat nicht.
- FUEL-/REPROCESSOR-Routing enthält keine blockierenden Sleeps.
- alle VALVE-Kommandos besitzen bestätigten Endzustand oder sichtbaren Fehler.
- MASTER kann bei mehreren Supportnodes zielgenau arbeiten.
- LOG-Renderer benötigt keine Quelltextmanipulation.
- alle relevanten Lua-/Python-Tests laufen in GitHub Actions.
- jede gelöschte Datei ist durch Referenzscan und Tests als unbenötigt nachgewiesen.
- aktueller `beta`-Head besitzt einen nachweislich grünen CI-Lauf.
