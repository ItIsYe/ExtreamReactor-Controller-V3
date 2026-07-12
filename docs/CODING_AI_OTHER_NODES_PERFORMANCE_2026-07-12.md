# Coding-AI-Aufgaben: Performance der übrigen Nodes

Stand: 2026-07-12  
Ziel-Branch: `beta`  
Gilt ergänzend zu:

- `docs/CODING_AI_PERFORMANCE_TASKS_2026-07-12.md`
- `docs/CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`

## Umfang

Diese Datei behandelt:

- FUEL
- WATER
- REPROCESSOR
- ENERGY
- VALVE
- LOG Collector
- gemeinsame Infrastruktur der Support-Nodes

Die Analyse ist statisch. Vor und nach jeder Änderung müssen Laufzeitmetriken erhoben werden. Funktionale Steuerung darf nicht nur zugunsten geringerer CPU-Last verlangsamt werden.

---

# Zusammenfassung nach Priorität

## Sehr hohe Priorität

1. FUEL/REPROCESSOR: blockierende `os.sleep()`-Phasen im Redstone-Router entfernen.
2. WATER: Tankwerte pro Messgeneration nur einmal lesen und gemeinsam für Regelung, UI und Telemetrie verwenden.
3. REPROCESSOR: `read_buffers()` nicht mehrfach pro Payload-/UI-Zyklus ausführen.
4. Support-Runtime: Modem-Events nicht als vollständigen periodischen Service-Tick behandeln.

## Hohe Priorität

5. LOG Collector: Einzeldatei-I/O pro Logevent bündeln, ohne ACK-Durability zu brechen.
6. FUEL: Waste-Fallback und mehrere gleichzeitige Lieferungen budgetieren und über mehrere Ticks fortsetzen.
7. ENERGY: langsame Matrix-Abfragen von UI, Storage, Discovery und Telemetrie vollständig trennen.
8. Gemeinsame Discovery: Methoden-Vollscans ereignisbasiert und deutlich seltener ausführen.

## Mittlere Priorität

9. FUEL-Ampel auf echte Zeit statt künstlichem `dt` umstellen.
10. VALVE: identische Redstone-Writes und Logs unterdrücken.
11. LOG Collector: Dedupe-Ring und UI-Rate-Limit verbessern.
12. Payload-/Diagnostics-Deep-Copies reduzieren.

---

# SHARED-P0 – Gemeinsame Support-Node-Infrastruktur

## SHARED-P0.1 Event-Verarbeitung von periodischen Service-Ticks trennen

### Betroffene Stelle

`xreactor/nodes/support/runtime.lua`

Aktuell wird bei jeder Modemnachricht ausgeführt:

```lua
comms:handle_event(event)
services:tick(nil, event)
```

Dadurch werden alle Services aufgerufen. Services mit eigener Zeitprüfung überspringen ihre Arbeit zwar häufig, aber:

- `comms.tick()` führt weiterhin Queue-, Retry-, Dedupe- und Peer-Maintenance aus.
- eigene Tabellen-Services ohne Intervall werden auf jedes Paket angesetzt.
- zukünftige Services können versehentlich eventabhängig beschleunigt werden.

### Ziel

Zwei ausdrücklich getrennte Pfade:

1. Event-Pfad für Modem/Touch/Key
2. Zeit-Pfad für fällige periodische Services

### Umsetzung

Beispielarchitektur:

```lua
services:handle_event(event)
services:tick_due(now)
```

- `comms:handle_event(event)` nimmt die Nachricht sofort an.
- Nur Services mit `handle_event()` erhalten das Event.
- Periodische `tick()`-Methoden laufen ausschließlich nach echter Zeit.
- Ein wichtiger Event darf einen Service als `due_now` markieren, aber nicht beliebig viele vollständige Ticks erzeugen.

### Tests

- 1.000 Modemevents lösen keine 1.000 UI-, Discovery-, Fail-Safe- oder Maintenance-Durchläufe aus.
- Commands bleiben sofort verarbeitbar.
- Touch und Tasten funktionieren weiter.
- Timerlose Services müssen explizit als Event-Service registriert werden.

---

## SHARED-P0.2 Support-Discovery ereignisbasiert machen

### Betroffene Stellen

- `xreactor/nodes/support/discovery.lua`
- `xreactor/services/discovery_service.lua`
- FUEL/WATER/REPROCESSOR Discovery-Wiring

### Problem

Die Support-Discovery liest periodisch:

- `peripheral.getNames()`
- Typen
- Methodenlisten über `peripheral.getMethods()`
- Monitorinformationen

Defaults liegen häufig bei 15 Sekunden. Bei stabiler Hardware ist ein kompletter Methoden-Vollscan so häufig nicht nötig.

### Ziel

- schneller Scan beim Boot
- sofortiger Scan bei `peripheral`/`peripheral_detach`
- langsamer Sicherheits-Fallback bei stabiler Topologie

### Umsetzung

Empfohlene Phasen:

```lua
boot_retry_interval_s = 2
stable_full_scan_interval_s = 120
```

- Solange erwartete Geräte fehlen: kurzer Retry.
- Sobald Bindings vollständig/stabil sind: langer Fallback.
- Attach/Detach setzt Discovery sofort auf fällig.
- Methodenlisten und Wrapper zwischen Scans cachen.
- Unveränderte Topologiesignatur darf teure Registry-/Adapterarbeit überspringen.

### Tests

- Neue Hardware wird durch Event sofort erkannt.
- Stabile Hardware wird nicht alle 15 Sekunden vollständig inspiziert.
- Fehlende Hardware wird beim Boot weiterhin zeitnah gesucht.

---

## SHARED-P0.3 Gemeinsamer Snapshot zwischen UI und Render

### Problem

`ui_service.snapshot()` erstellt ein Model, aber mehrere Node-Implementierungen rufen in ihrem `render_monitor()` den Payload-Builder erneut auf. Dadurch entsteht innerhalb desselben UI-Zyklus doppelte Hardware- und Registryarbeit.

### Ziel

`snapshot()` erzeugt die vollständige Datenbasis. `render()` verwendet ausschließlich dieses Ergebnis.

### Umsetzung

- `ui_service` soll das Snapshot-Ergebnis an `render(snapshot)` übergeben oder im UI-State speichern.
- Render-Funktionen dürfen nur bei fehlendem/zu altem Snapshot neu lesen.
- Touch-Navigation verwendet den aktuellen Snapshot und erzwingt nur einen Draw, nicht automatisch einen neuen Hardware-Read.

---

# FUEL-P0 – FUEL-Node

## FUEL-P0.1 Blockierenden Redstone-Router in eine Zustandsmaschine umbauen

### Betroffene Stelle

`xreactor/nodes/fuel/redstone_router.lua`, `route_and_act()`

Aktuell:

```lua
os.sleep(uses_network and 0.4 or 0.05)
if action_fn then action_fn() end
os.sleep((tonumber(valve_open_ms) or 2000) / 1000)
self:block_all()
```

### Problem

Diese Sleeps laufen innerhalb des FUEL-/REPROCESSOR-Hauptloops. Währenddessen werden keine normalen Events verarbeitet:

- Heartbeats verzögern sich.
- Commands und ACKs bleiben liegen.
- UI friert ein.
- weitere Logistikaufgaben blockieren.
- bei mehreren Kandidaten werden mehrere 2,4-Sekunden-Fenster nacheinander ausgeführt.

### Ziel

Nicht blockierende Route-State-Machine.

### Zustände

```text
IDLE
OPEN_PATH
WAIT_PATH_SETTLE
ACT
HOLD_OPEN
BLOCK_ALL
COMPLETE / ERROR
```

### Umsetzung

- `start_route(target, action_descriptor, valve_open_ms)` startet nur einen Job.
- `tick(now)` wechselt anhand von Deadlines die Zustände.
- Kein `os.sleep()`.
- Hauptloop bleibt zwischen allen Phasen ereignisfähig.
- Nur ein aktiver Pfad gleichzeitig.
- Weitere Jobs in priorisierter Queue.
- Nach Fehler/Timeout immer `block_all()`.
- Reboot-/Crash-Fail-Safe bleibt bestehen.

Die Aktion sollte möglichst als deklarativer Job statt beliebiger Closure gespeichert werden, damit Zustand und Diagnose sichtbar bleiben.

### Abnahmekriterien

- Während eines 2-Sekunden-Ventilfensters laufen Heartbeats und Commands weiter.
- UI bleibt bedienbar.
- Kein zweiter Pfad wird gleichzeitig geöffnet.
- Fehler blockiert alle Ventile sicher.

---

## FUEL-P0.2 Lieferungen nicht vollständig in einem Tick abarbeiten

### Problem

`_run_supply()` sortiert alle anfordernden Reaktoren und bearbeitet anschließend alle Kandidaten im selben Zyklus. Mit Ventilrouting kann jeder Kandidat mehrere Sekunden belegen.

### Ziel

Ein begrenzter, fairer Job-Scheduler.

### Umsetzung

- Kandidaten erfassen und priorisieren.
- Höchstens einen aktiven Transferjob gleichzeitig.
- Nach Abschluss nächsten Kandidaten auswählen.
- Fairness/Aging verwenden, damit ein Reaktor nicht verhungert.
- ME-Verfügbarkeit kurz vor dem tatsächlichen Export erneut prüfen.
- Zyklusstatistik über mehrere Jobs aggregieren.

### Tests

- Fünf gleichzeitige Requests blockieren den Node nicht.
- niedrigster Füllstand bleibt bevorzugt.
- länger wartende Requests erhalten Aging-Priorität.

---

## FUEL-P0.3 Waste-Fallback budgetieren

### Problem

Wenn `importItemFromPeripheral({}, outlet)` fehlschlägt, wird das komplette Outlet per `list()` gelesen. Danach wird für jeden Stack einzeln ein Import versucht. Große Inventare können viele Peripheral-Aufrufe in einem Tick erzeugen.

### Ziel

Fortsetzbarer, budgetierter Waste-Import.

### Umsetzung

Konfigurierbare Limits:

```lua
waste_calls_per_tick = 4
waste_time_budget_ms = 100
```

- Cursor pro Outlet/Slot speichern.
- Nach Erreichen des Call- oder Zeitbudgets im nächsten Tick fortsetzen.
- Inventarliste nur bei Bedarf neu laden.
- Leere/unveränderte Outlets mit Backoff versehen.

---

## FUEL-P1.1 Payload-Cache generationsbasiert statt nur 300 ms

### Status

FUEL besitzt bereits einen 300-ms-Cache. Das ist eine gute Zwischenlösung.

### Verbesserung

- UI, Ampel und Telemetrie sollen einen gemeinsamen Fuel-Snapshot verwenden.
- Cache über `sample_generation` und maximales Alter steuern.
- Änderung von Reserve, Command, Routingzustand oder Discovery invalidiert gezielt.
- `read_fuel()` nicht mehrfach innerhalb derselben Generation ausführen.

Empfohlene Werte:

```lua
fuel_sample_interval_s = 0.5
ui_max_age_s = 1.0
telemetry_max_age_s = 1.0
```

---

## FUEL-P1.2 Ampel-Timer mit echter Zeit steuern

### Problem

Der Ampel-Service addiert bei fehlendem `dt` künstlich 0,5 Sekunden. Modemevents können dadurch die Ampel schneller takten.

### Umsetzung

`next_due_at` plus `os.epoch("utc")` verwenden. Netzwerkverkehr darf die Renderfrequenz nicht verändern.

---

# WATER-P0 – WATER-Node

## WATER-P0.1 Einen gemeinsamen Tank-Snapshot verwenden

### Problem

Im normalen 0,5-Sekunden-Zyklus passiert aktuell:

1. `balance_loop()` ruft `total_water()` auf und liest alle Tanks.
2. `manage_clusters()` liest jeden Cluster-Tank erneut.
3. UI-Snapshot baut Status auf und liest Tanks.
4. `render_monitor()` baut Status erneut auf.
5. Telemetrie liest dieselben Werte in ihrem eigenen Zyklus erneut.

Bei `tanks()` werden außerdem komplette Fluid-Tabellen durchlaufen.

### Ziel

Jeder physische Tank wird pro Messgeneration genau einmal gelesen.

### Umsetzung

Neues Modul, zum Beispiel `nodes/water/tank_snapshot.lua`:

```lua
{
  ts = ...,
  total = ...,
  by_name = {
    [name] = { level = ..., fluids = ... }
  },
  buffers = {...}
}
```

- schneller Water-Sampler liest alle Tanks einmal.
- Balance und Clustersteuerung verwenden `by_name`.
- UI und Telemetrie verwenden denselben Snapshot.
- alter Snapshot wird eindeutig als stale markiert.

### Frequenz

Die Wasser-/Clustersteuerung darf reaktionsfähig bleiben:

```lua
tank_control_sample_interval_s = 0.25
ui_interval_s = 1.0
status_interval_s = 5.0
```

Diese Werte sind Startwerte. Die Coding-KI darf sie anhand realer Hardware messen, aber nicht durch doppelte Reads ersetzen.

### Tests

- Zwei Cluster am selben Tank erzeugen nur einen Tank-Read pro Generation.
- UI und Balance zeigen denselben Messstand.
- Cluster-Ausgänge reagieren weiter innerhalb der festgelegten Zeit.

---

## WATER-P0.2 UI-/Payload-Doppelaufbau entfernen

### Problem

`ui_service.snapshot()` ruft `build_status_payload()` auf. `render_monitor()` ruft es unmittelbar erneut auf.

### Ziel

Render verwendet das Snapshot-Model ohne zweiten Tank-/Registry-Lauf.

---

## WATER-P1.1 Integrator-Wrapper cachen

### Problem

Bei Cluster-Zustandswechseln wird ein konfigurierter Integrator erneut mit `peripheral.wrap()` geladen.

### Ziel

- Integratoren bei Discovery/Configänderung cachen.
- bei Attach/Detach invalidieren.
- Redstone nur bei echtem Zustandswechsel schreiben.

Der zweite Punkt ist im Cluster-State bereits weitgehend vorhanden und muss erhalten bleiben.

---

# REPROC-P0 – REPROCESSOR-Node

## REPROC-P0.1 Redstone-Routing nicht blockierend machen

REPROCESSOR verwendet denselben `redstone_router.route_and_act()` wie FUEL. Deshalb gilt FUEL-P0.1 vollständig auch hier.

Der Feed-Router darf sein zufälliges 20–60-Sekunden-Intervall behalten. Nur das Ventilfenster selbst muss nicht blockierend werden.

---

## REPROC-P0.2 `read_buffers()` pro Generation nur einmal

### Problem

Innerhalb eines einzelnen `build_status_payload()` wird `read_buffers()` derzeit zweimal aufgerufen:

```lua
reproc_health.bindings = { buffers = #read_buffers() }
...
payload.buffers = read_buffers()
```

Danach wird der Payload im UI-Snapshot und erneut in `render_monitor()` gebaut.

Bei Inventar-Backends führt `read_buffers()` ein komplettes `list()` aus und summiert alle Stacks.

### Ziel

```lua
local buffer_snapshot = read_buffers()
reproc_health.bindings = { buffers = #buffer_snapshot }
payload.buffers = buffer_snapshot
```

Zusätzlich UI/Telemetrie über einen gemeinsamen, zeitlich begrenzten Snapshot versorgen.

### Empfohlene Frequenz

```lua
buffer_sample_interval_s = 0.5
```

Der Prozess-Tick und Status-Read sollen getrennt sein.

---

## REPROC-P0.3 `process()` explizit takten und budgetieren

### Problem

Alle erkannten Buffer mit `process()` werden aktuell alle 0,5 Sekunden nacheinander aufgerufen.

### Ziel

Hohe gewünschte Prozessfrequenz beibehalten, aber explizit und messbar machen:

```lua
process_interval_s = 0.5
process_calls_per_tick = 4
```

- Round-Robin über viele Ports.
- bei wenigen Ports weiterhin jeder Port alle 0,5 Sekunden.
- langsame/fehlerhafte Ports mit begrenztem Backoff.
- keine Beschleunigung durch Modemevents.

---

## REPROC-P1.1 Router-UI-Discovery nicht im Render-Hotpath

Der Router-UI-Fallback durchsucht `peripheral.getNames()` nach Reprocessor-Namen, wenn keine Targets konfiguriert sind. Ergebnis cachen und nur bei Discovery-/Configänderung neu aufbauen.

---

# ENERGY-P0 – ENERGY-Node

## ENERGY-P0.1 Langsame Matrixarbeit von allen übrigen Services trennen

### Positiver aktueller Stand

ENERGY besitzt bereits einen separaten Heartbeat-Thread. Dadurch bleiben Heartbeats grundsätzlich möglich, wenn Matrix-Calls lange dauern.

### Verbleibendes Problem

Der Matrix-Thread führt dennoch aus:

```lua
ctx.services:tick()
```

Damit liegen im selben möglicherweise blockierenden Thread:

- Comms-Maintenance
- Discovery
- Storage-Sampling
- Matrix-Sampling
- Telemetrie
- UI

Ein 1–4 Sekunden dauernder Matrix-Peripheral-Call verzögert damit alle diese Aufgaben gemeinsam.

### Ziel

Mindestens drei getrennte Scheduler-/Coroutine-Gruppen:

```text
1. Comms + Heartbeat + Command Events
2. Matrix Polling
3. UI + Telemetrie + Storage + Discovery
```

Alternativ noch feiner:

- Storage-Sampling eigener Thread
- UI/Telemetrie gemeinsamer schneller Thread
- Discovery langsamer Thread

### Anforderungen

- Matrixresultate atomar als Snapshot veröffentlichen.
- UI/Telemetrie lesen nur den zuletzt vollständigen Snapshot.
- kein halbfertiger Matrixzustand sichtbar.
- ein Matrixfehler beendet nicht die übrigen Threads.

---

## ENERGY-P0.2 Storage-Sampling konfigurierbar machen

### Problem

Alle 0,5 Sekunden werden für jedes Storage vier Metriken gelesen:

- stored
- capacity
- input
- output

Bei vielen Storages oder langsamen APIs können diese Aufrufe den Nicht-Matrix-Teil unnötig belasten.

### Ziel

Metriken nach Änderungsrate trennen:

```lua
storage_energy_interval_s = 0.5
storage_rate_interval_s = 0.5
storage_capacity_interval_s = 5.0
```

- Capacity deutlich seltener, da normalerweise statisch.
- Stored/Input/Output häufiger.
- langsame Geräte erhalten dynamisches Backoff.
- pro Tick Call-/Zeitbudget.

---

## ENERGY-P1.1 Matrix-Jobqueue nicht bei jedem Sample vollständig neu sortieren

### Problem

`poll_due_metrics()` baut für alle Gruppen und Metriken eine neue Jobliste auf und sortiert sie bei jedem Poll.

### Ziel

Bei großen Matrixmengen:

- `next_due` pro Metrik speichern.
- kleine Prioritätsqueue oder Round-Robin-Cursor verwenden.
- nur wirklich fällige Jobs einplanen.

Für kleine Anlagen ist dies niedriger priorisiert als die Threadtrennung.

---

## ENERGY-P1.2 Zeitbudget als Beobachtung, nicht als harte Unterbrechung dokumentieren

Ein einzelner Peripheral-Aufruf kann länger als das konfigurierte Gesamtbudget dauern. Das Budget kann erst nach Rückkehr des Calls geprüft werden. Diagnose muss deshalb unterscheiden:

- geplantes Budget
- tatsächliche Call-Dauer
- Budgetüberschreitung durch einen einzelnen nicht unterbrechbaren Call

Keine falsche Garantie geben, dass ein 2.000-ms-Budget einen 4-Sekunden-Call abbrechen kann.

---

# VALVE-P1 – VALVE-Node

## VALVE-P1.1 Identische Writes unterdrücken

### Aktueller Stand

Die Node ist bewusst sehr klein und hat keine Discovery oder UI. Es gibt keinen größeren allgemeinen Performancefehler.

### Verbesserung

`apply_valve(high)` schreibt und loggt auch dann erneut, wenn `high == current_high`.

Bei identischem Command:

- `last_command_ts` aktualisieren
- keinen erneuten `redstone.setOutput` ausführen
- keine neue INFO-Zeile schreiben

Ausnahme: nach Boot/Reconnect oder explizitem Force-Command.

---

## VALVE-FUNCTIONAL-1 – Nebenfund: Modemevent-Indizes prüfen

Dies ist kein Performancepunkt, aber bei der Analyse wurde ein wahrscheinlicher Funktionsfehler gefunden.

Aktuell:

```lua
local channel, _, message = event[2], event[3], event[4]
```

Beim normalen CC:Tweaked-Event `modem_message` ist üblicherweise:

```text
event[2] = side
 event[3] = channel
 event[4] = replyChannel
 event[5] = message
```

Die Coding-KI muss dies gegen die tatsächlich verwendete CC:Tweaked-Version/Testumgebung prüfen. Falls Standardformat gilt, muss es lauten:

```lua
local channel = event[3]
local message = event[5]
```

Regressionstest mit einem realistischen `modem_message`-Event ergänzen.

---

# LOG-P0 – LOG Collector

## LOG-P0.1 Disk-Writes kontrolliert bündeln

### Problem

Für jedes Logevent wird derzeit:

- Zielpfad bestimmt
- `fs.exists()`/`fs.getSize()` geprüft
- Datei mit `fs.open(path, "a")` geöffnet
- eine Zeile geschrieben
- Datei geschlossen

Bei starkem Debug-Logging dominiert diese synchrone Datei-I/O.

### Sicherheitsanforderung

Ein `LOG_ACK` mit Status `written` darf erst gesendet werden, nachdem die Zeile tatsächlich persistent geschrieben wurde. Performanceoptimierung darf keine falschen ACKs erzeugen.

### Umsetzungsmöglichkeiten

Bevorzugt: kleine per-path Batches.

```lua
flush_lines = 8
flush_interval_ms = 200
max_pending_lines = 128
```

- Events pro Zielpfad puffern.
- Batch mit einem Open/Write/Close schreiben.
- ACKs erst nach erfolgreichem Batch-Write senden.
- bei Disk-Eject/Fehler alle betroffenen Events als nicht bestätigt behandeln.
- Speicherlimit und Backpressure definieren.
- CRITICAL/ERROR optional sofort flushen.

Alternative: sicher verwaltete offene Handles mit sauberem Eject-/Rotate-Verhalten. Batch ist meist robuster.

### Tests

- Acht Events für denselben Pfad erzeugen einen Datei-Open-Vorgang.
- ACK erst nach erfolgreichem Schreiben.
- Crash vor Flush führt zu keinem falschen ACK.
- Disk-Eject beschädigt andere Rollenpuffer nicht.

---

## LOG-P0.2 Dateigröße cachen

### Problem

`fs.getSize(path)` läuft für jedes Event.

### Ziel

- geschätzte/geschriebene Bytezahl pro Pfad im Speicher halten.
- beim ersten Zugriff oder nach Refresh/Eject mit `fs.getSize()` synchronisieren.
- nach erfolgreichem Batch um geschriebene Bytes erhöhen.
- vor Rotation optional final nachprüfen.

---

## LOG-P1.1 Dedupe-Queue als Ringbuffer

### Problem

Nach Erreichen von 512 Einträgen führt jedes neue Event `table.remove(seen_order, 1)` aus. Das verschiebt den gesamten Arrayinhalt.

### Ziel

O(1)-Ringbuffer oder Queue mit Head-Index.

- Map `seen[event_id]` bleibt für schnelle Suche.
- Ringposition überschreibt ältesten Eintrag.
- alter Map-Key wird entfernt.

---

## LOG-P1.2 UI-Redraw zeitbasiert begrenzen

### Problem

Zusätzlich zum 5-Sekunden-Timer wird nach jeweils 20 empfangenen Events gezeichnet. Bei hohem Durchsatz kann dies häufige UI-Arbeit erzeugen.

### Ziel

```lua
active_draw_min_interval_s = 1
idle_draw_interval_s = 5
```

- Zähleränderungen markieren UI als dirty.
- höchstens einmal pro Sekunde während hoher Last zeichnen.
- Fehler/Touch dürfen sofort zeichnen.

---

## LOG-P1.3 ACK nur über notwendigen Modemweg senden

### Problem

ACK wird über alle gefundenen Modems gesendet. Bei mehreren Modems entstehen mehrere identische ACK-Übertragungen.

### Ziel

- bevorzugtes Wireless-Modem einmal bestimmen.
- ACK normalerweise genau einmal senden.
- optional das empfangende Modem/Side verwenden, wenn zuverlässig verfügbar.
- Fallback auf weiteres Modem nur nach Sendefehler.

### Test

Ein Logevent mit zwei angeschlossenen Modems erzeugt im Erfolgsfall genau eine ACK-Übertragung.

---

# Node-spezifische Lasttests

## FUEL

- 10 gleichzeitige Fuel-Requests
- 5 Waste-Outlets mit großen Inventaren
- Netzwerk-Valves mit 2-Sekunden-Öffnungszeit
- während Transfer jede Sekunde Command und Heartbeat prüfen

## WATER

- 10 Tanks
- mehrere Cluster teilen denselben Tank
- Zähler für `tanks()`/`getFluidAmount()`
- Abnahme: pro Tank nur ein Read je Samplegeneration

## REPROCESSOR

- 8 Buffer/Ports
- große Inventarlisten
- Feed-Routing aktiv
- `process()`-Dauer und maximale Eventloop-Lücke messen

## ENERGY

- mehrere Matrices mit simulierten 1–4-Sekunden-Calls
- UI/Storage/Telemetrie müssen trotz Matrixblockade ihre dokumentierte Frequenz halten
- Heartbeat bleibt innerhalb seiner Warnschwelle

## VALVE

- 1.000 identische SET_VALVE-Commands
- nur erster tatsächlicher Zustandswechsel schreibt Redstone
- Zeitstempel bleibt frisch

## LOG

- 10, 50 und 100 Logevents pro Sekunde
- verschiedene Rollen und Zielpfade
- Disk-Eject während Batch
- keine falschen ACKs
- UI bleibt reaktionsfähig

---

# Empfohlene Bearbeitungsreihenfolge

1. FUEL-P0.1 / REPROC-P0.1 nicht blockierender Router
2. WATER-P0.1 gemeinsamer Tank-Snapshot
3. REPROC-P0.2 Buffer-Snapshot
4. SHARED-P0.1 Event-/Timer-Trennung
5. LOG-P0.1 gebündelte persistente Writes
6. FUEL-P0.2 Jobqueue und FUEL-P0.3 Waste-Budget
7. ENERGY-P0.1 getrennte Servicegruppen
8. SHARED-P0.2 Discovery-Policy
9. WATER-P0.2 und SHARED-P0.3 UI-Snapshot-Wiederverwendung
10. ENERGY-P0.2 Storage-Cadence
11. LOG-P0.2/P1.1/P1.2/P1.3
12. FUEL-P1.1/P1.2 und VALVE-P1.1
13. VALVE-FUNCTIONAL-1 separat verifizieren und beheben

# Definition of Done

- keine `os.sleep()`-Wartephase blockiert FUEL-/REPROCESSOR-Kommunikation
- WATER liest jeden Tank pro Generation höchstens einmal
- REPROCESSOR liest Buffer pro Generation höchstens einmal
- ENERGY-Matrixcalls blockieren nicht UI/Storage/Telemetrie/Discovery
- LOG bestätigt nur tatsächlich persistierte Events
- LOG-Datei-I/O ist gebündelt und speicherbegrenzt
- Modemverkehr beschleunigt keine periodischen Dienste
- Discovery ist eventbasiert plus langsamer Fallback
- alle Änderungen besitzen Last- und Regressionstests
- Vorher-/Nachher-Metriken sind dokumentiert
