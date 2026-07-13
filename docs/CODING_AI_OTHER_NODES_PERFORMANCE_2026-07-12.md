# Coding-AI-Aufgaben: aktueller Gesamt-Audit aller Nodes

Stand: 2026-07-13  
Ziel-Branch: `beta`  
Geprüfter GitHub-Head: `cec5389de973b45302b324737920ffcb86f30520`  
Geprüfte Release: `beta-v397` / `manifest-v397`

Ergänzend zu:

- `docs/CODING_AI_FUEL_NODE_DEEP_AUDIT_2026-07-12.md`
- `docs/CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md`
- `docs/CODING_AI_PERFORMANCE_TASKS_2026-07-12.md`
- `docs/CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`
- `docs/CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md`

## Zweck dieser aktualisierten Datei

Der aktuelle `beta`-Stand wurde erneut direkt auf GitHub geprüft. Diese Datei ersetzt die ältere allgemeine Performance-Liste und enthält nur noch:

- offene Punkte,
- teilweise umgesetzte Punkte,
- neu gefundene Funktions- und Safetyfehler,
- nicht nachgewiesene Anforderungen,
- fehlende oder veraltete Tests.

Vollständig umgesetzte Punkte werden im Abschnitt „Nicht erneut umbauen“ festgehalten und ansonsten aus den Aufgaben entfernt.

Die Prüfung ist statisch. Aussagen über echte Laufzeit, Latenzen und Peripheral-Verhalten müssen zusätzlich mit reproduzierbaren Ingame-Tests bestätigt werden.

---

# 1. Statusübersicht

| Bereich | Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Konfiguration | **KRITISCH OFFEN** | Rollen-Konfigurationen werden beim Update gelöscht oder überschrieben |
| Gemeinsame Support-Runtime | **OFFEN** | Modem-/UI-Events ticken weiterhin alle periodischen Services |
| MASTER | **TEILWEISE** | Einstellungen nicht persistent, stale Fuel-Relay, UI-/Log-Last |
| RT | **KRITISCH OFFEN** | keine feste 10-Hz-Regelung, Eventabhängigkeit, SAFE-Recovery-Fehler |
| ENERGY | **TEILWEISE** | Matrix-Thread tickt weiterhin alle Services und kann sie gemeinsam blockieren |
| WATER | **KRITISCH OFFEN** | UI hält erstes Model fest, Touch doppelt, Cluster-Ausgänge ohne sicheren Read-Fail-Pfad |
| FUEL | **KRITISCH OFFEN** | siehe FUEL-Dokumente; Config-/Routing-/VALVE-Blocker bleiben |
| REPROCESSOR | **KRITISCH OFFEN** | Routing liest falschen Configblock, UI stale/doppelt, Transfer blockierend |
| VALVE | **KRITISCH OFFEN** | Standard-`modem_message` wird mit falschen Indizes gelesen |
| LOG Collector | **TEILWEISE** | synchroner Einzeldatei-I/O, O(n)-Dedupe, ACK über alle Modems |
| Tests / CI | **OFFEN** | Workflow parst Code, führt die vorhandenen Tests aber nicht aus |

---

# 2. Bereits umgesetzt – nicht ohne konkreten Regressionstest erneut umbauen

## MASTER

- Modemnachrichten werden im MASTER-Loop direkt an `comms:handle_event()` gegeben und lösen nicht automatisch den vollständigen Service-Manager-Tick aus.
- UI-Modelbau besitzt einen abgesicherten Default-Fallback.
- View-Rendering besitzt Modelvergleich und Rate-Limiting.

## ENERGY

- Ein eigener Heartbeat-Thread existiert.
- Matrixwerte werden über Snapshots veröffentlicht.
- Die ENERGY-UI baut ihr Model im `snapshot()`-Pfad und verwendet es beim Rendern wieder.
- Discovery besitzt Topologie-Gating und Cache-Invalidierung.

Diese Punkte sind nur Teilverbesserungen. Die noch offene Thread-/Service-Trennung steht weiter unten.

## FUEL-UI

- der doppelte FUEL-`router_touch`-Pfad wurde entfernt,
- ein FUEL-Model pro UI-Zyklus wurde eingeführt,
- die doppelte UI-Drossel wurde beseitigt,
- normale Inhaltsänderungen führen nicht mehr zwingend zu einem Full-Clear,
- Router-Redraw läuft zentral,
- Monitor-/Skalenwechsel und Page-Renderfehler besitzen Basisbehandlung.

Offene FUEL-Punkte bleiben in den beiden speziellen FUEL-Dokumenten.

## VALVE

- Boot-Grundzustand ist standardmäßig blockiert,
- ein offenes Ventil fällt nach 20 Sekunden ohne Kommando in den blockierten Fail-Safe-Zustand zurück.

## LOG Collector

- `LOG_ACK status=written` wird erst nach erfolgreichem Schreiben gesendet,
- Duplikate werden erkannt und als `duplicate` bestätigt,
- der Collector verwendet korrekte Standard-Indizes für `modem_message`,
- die lokale UI schreibt inkrementell,
- Crash-Loop-Historie und automatisches Wiederanlaufen sind vorhanden.

---

# 3. GLOBAL-P0 – Rollen-Konfigurationen updatesicher machen

## Status

**KRITISCH OFFEN**

## Bestätigtes Problem

Der Installer sichert vor dem Löschen von `/xreactor` nur:

```text
config/node_id.txt
config/capacity_cache.lua
config/role.lua
config/optional_features.lua
config/ampel_thresholds.lua
```

Danach wird `/xreactor` vollständig gelöscht.

Nicht gesichert werden unter anderem:

```text
config/rt.lua
config/fuel_routes.lua
config/reproc_routes.lua
config/remote_update.lua
rollenspezifische Registry-/Layoutdateien
weitere spätere Benutzerkonfigurationen
```

Zusätzlich verwenden mehrere Rollen ihre mitgelieferte Quelldatei direkt als Runtime-Konfiguration:

```text
MASTER       /xreactor/master/config.lua
ENERGY       /xreactor/nodes/energy/config.lua
WATER        /xreactor/nodes/water/config.lua
FUEL         /xreactor/nodes/fuel/config.lua
REPROCESSING /xreactor/nodes/reprocessor/config.lua
VALVE        /xreactor/nodes/valve/config.lua
```

Diese Dateien werden bei jeder Installation neu heruntergeladen und überschrieben. Benutzeränderungen in diesen Dateien sind damit nicht updatesicher.

RT verwendet zwar bereits `/xreactor/config/rt.lua`, aber auch diese Datei steht nicht in `PRESERVE` und wird beim Reinstall gelöscht.

## Auswirkungen

Nach einem Auto-Update können verloren gehen:

- Reaktoren und Turbinen des RT-Nodes,
- Monitor-Skalierung,
- WATER-Tanks und Cluster,
- REPROCESSOR-Targets und Feed-Routing,
- VALVE-Seite und Node-spezifische Einstellungen,
- MASTER-Schwellwerte und Monitorkonfiguration,
- FUEL-/REPROCESSOR-Routen,
- Remote-Update-Einstellungen.

## Verbindliche Zielarchitektur

Die Dateien im Programmverzeichnis sind ausschließlich Default-Konfigurationen.

Kanonische Benutzerdateien:

```text
/xreactor/config/master.lua
/xreactor/config/rt.lua
/xreactor/config/energy.lua
/xreactor/config/water.lua
/xreactor/config/fuel.lua
/xreactor/config/reprocessor.lua
/xreactor/config/valve.lua
```

Ablauf:

1. Rollen-Default laden.
2. Benutzerdatei laden, falls vorhanden.
3. Default und Benutzerwerte migrationssicher zusammenführen.
4. Validieren und normalisieren.
5. Änderungen ausschließlich in die Benutzerdatei schreiben.
6. Installer sichert den vollständigen Configbereich oder eine explizit versionierte Config-Allowlist.
7. Neue Configfelder werden ergänzt, bestehende Benutzerwerte bleiben erhalten.

## Installer-Fix

Bevorzugt den gesamten Ordner `/xreactor/config` außerhalb von `/xreactor` temporär sichern und nach erfolgreicher Installation wiederherstellen.

Dabei müssen ausgeschlossen beziehungsweise bewusst behandelt werden:

- temporäre Dateien,
- `.tmp`-Dateien,
- defekte Recovery-Fragmente,
- versionsabhängige Cachedateien.

## Pflicht-Tests

1. Jede Rolle mit angepasster Config installieren.
2. Auto-Update ausführen.
3. Alle benutzerdefinierten Werte müssen erhalten bleiben.
4. Neue Defaultfelder müssen nach Migration vorhanden sein.
5. Alte oder ungültige Werte müssen mit sichtbarer Warnung normalisiert werden.
6. Abbruch während der Installation darf die letzte gültige Config nicht zerstören.
7. `fuel_routes.lua` und `reproc_routes.lua` müssen nach Reboot und Update weiter aktiv sein.

---

# 4. SHARED-P0 – Eventpfad und periodische Services trennen

## Status

**OFFEN**

## Bestätigtes Problem

Die gemeinsame Support-Runtime führt bei einer Modemnachricht aus:

```lua
comms:handle_event(event)
services:tick(nil, event)
```

Bei Touch und Taste wird ebenfalls der vollständige Service-Manager getickt.

`service_manager:tick()` iteriert immer über alle Services und ruft jede vorhandene `tick()`-Methode auf. Dadurch können Netzwerk- und UI-Events unbeabsichtigt auslösen:

- Control-Zyklen,
- Discovery-Prüfungen,
- Telemetrie-Maintenance,
- UI-Arbeit,
- Failsafe-Prüfungen,
- Reprocessor-Verarbeitung,
- Kommunikations-Maintenance.

## Zusätzliches Problem

`services/control_service.lua` ignoriert das übergebene `interval` vollständig. MASTER registriert beispielsweise HOUSEKEEPING mit `interval=0.5`; das Modul speichert diesen Wert aber nicht und führt `tick_fn()` bei jedem Service-Manager-Aufruf aus.

## Ziel

```lua
services:handle_event(event)
services:tick_due(now)
```

Ein Service deklariert explizit:

```lua
handle_event(event)
tick(now)
next_due_at
```

## Anforderungen

- Modemnachrichten werden sofort angenommen.
- Command-ACKs bleiben sofort möglich.
- Periodische Arbeit läuft ausschließlich nach echter Zeit.
- Ein Event kann einen Service einmalig als `due_now` markieren.
- Mehrere Events werden koalesziert.
- Kein Eventsturm erzeugt tausende vollständige Service-Zyklen.
- `char`, `peripheral` und `peripheral_detach` werden dort weitergeleitet, wo sie benötigt werden.

## Pflicht-Tests

- 1.000 Modemevents erzeugen keine 1.000 Control-, UI-, Discovery- oder Maintenance-Ausführungen.
- Touch und Tasten bleiben sofort bedienbar.
- Attach/Detach löst gezielt Discovery aus.
- HOUSEKEEPING respektiert sein konfiguriertes Intervall.
- Comms-Retries und Peer-Timeouts bleiben korrekt.

---

# 5. SHARED-P0.2 – Crashpfade ohne physischen Tastendruck selbst heilen

## Status

**OFFEN für MASTER, RT, ENERGY, WATER, FUEL, REPROCESSOR und VALVE**

## Problem

Die gemeinsame Node-Crashseite, die MASTER-Crashseite und die ENERGY-Crashseite warten unbegrenzt auf:

```lua
os.pullEvent("key")
```

Erst danach wird rebootet.

Das widerspricht dem unbeaufsichtigten Betrieb. `start.lua` besitzt bereits einen automatischen Rebootpfad für ungefangene Fehler, wird aber nicht erreicht, wenn der Rollenprozess den Fehler selbst fängt und anschließend auf eine Taste wartet.

## Ziel

- Crash sichtbar anzeigen.
- Fehler loggen.
- maximal konfigurierbare Wartezeit, beispielsweise 15–30 Sekunden.
- Taste darf den Reboot vorziehen.
- Crash-Loop-Erkennung wie beim LOG Collector.
- nach wiederholten Abstürzen längere Backoff-Zeit und klare Diagnose.

## Test

Ein absichtlich ausgelöster Rollenfehler muss ohne Eingriff automatisch rebooten. Drei schnelle Crashs müssen Crash-Loop-Backoff aktivieren.

---

# 6. WATER-P0 – UI-Eingabe und UI-Datenpfad reparieren

## Status

**KRITISCH OFFEN**

## WATER-P0.1 Erstes UI-Model wird dauerhaft festgehalten

`render_monitor()` baut ein lokales `model`. Beim ersten Render wird `monitor_router` angelegt. Die Seiten-Closures greifen direkt auf genau dieses erste lokale Model zu:

```lua
render = function(target)
  return water_ui.render_overview(target, model)
end
```

Bei späteren Zyklen wird zwar ein neues Model gebaut und an `monitor_router:render(mon, model)` übergeben, die Page-Closure ignoriert dieses Argument jedoch und rendert weiterhin das erste Model.

### Folge

Die WATER-UI kann dauerhaft alte Werte anzeigen:

- Tankstand,
- MASTER-Verbindung,
- Alerts,
- Clusterzustände,
- letzte Commands.

### Fix

```lua
render = function(target, current_model, should_clear)
  return water_ui.render_overview(target, current_model, should_clear)
end
```

Bevorzugt zusätzlich den `ui_service.build_model`-Pfad wie bei FUEL verwenden.

## WATER-P0.2 Touch wird über zwei Pfade verarbeitet

Der UI-Service ruft bereits `monitor_router:handle_input(event)` auf. Zusätzlich existiert nach `init()` ein eigener `router_touch`-Service, der denselben Touch nochmals direkt an den Handler der aktuellen Seite sendet.

### Besonders gefährlicher Ablauf

1. Footer-Touch wechselt die Seite.
2. Separater `router_touch` läuft danach.
3. Dieselben Koordinaten treffen den Handler der neu geöffneten Seite.

### Fix

- `router_touch` vollständig entfernen.
- Navigation und Page-Input ausschließlich zentral dispatchen.
- konsumierter Footer-Touch beendet die Eventverarbeitung.

---

# 7. WATER-P0.3 – Ein Tank-Snapshot pro Messgeneration

## Status

**OFFEN**

## Problem

Tankdaten werden mehrfach gelesen:

- `balance_loop()` → `total_water()`
- `manage_clusters()` → `read_tank_level()` pro Cluster
- `build_status_payload()` → `total_water()`
- `build_status_payload()` → erneut `read_tank_level()` pro Cluster
- UI-Snapshot baut Payload
- Monitor-Render baut Payload erneut
- Telemetrie baut eigenen Payload

## Ziel

```lua
water_snapshot = {
  generation = ...,
  ts = ...,
  total = ...,
  by_name = {
    [tank_name] = { level = ..., ok = ..., error = ... }
  }
}
```

Balance, Clustersteuerung, UI und Telemetrie verwenden dieselbe Generation innerhalb ihrer zulässigen Altersgrenze.

## Pflicht-Tests

- Ein physischer Tank wird pro Generation höchstens einmal gelesen.
- Zwei Cluster am selben Tank teilen denselben Messwert.
- UI und Regelung zeigen dieselbe Generation.
- stale/fehlgeschlagene Reads sind sichtbar.

---

# 8. WATER-P0.4 – Cluster-Ausgänge bei Mess- und Schreibfehlern sicher behandeln

## Status

**KRITISCH OFFEN**

## Bestätigtes Problem

Wenn ein Cluster-Tank nicht gelesen werden kann, wird nur gewarnt und zum nächsten Cluster gesprungen. Bereits aktive Fill-/Drain-Ausgänge bleiben unverändert eingeschaltet.

Zusätzlich:

- Cluster-State wird vor beziehungsweise unabhängig von bestätigtem Redstone-Erfolg geändert.
- `set_rs_output()` verwirft das Ergebnis von `redstone.setOutput()`/Integrator-Aufrufen.
- `config_normalizer` validiert Clusterstruktur, Seiten, `min_volume < max_volume` und Integratornamen nicht.

## Sicherheitsziel

Bei unbekanntem Tankstand gilt eine ausdrücklich konfigurierte Policy:

```text
BLOCK_ALL       beide Ausgänge aus
HOLD_LAST       nur mit Timeout und Warnung
FAIL_FILL       definierter anlagenspezifischer Notzustand
```

Standard muss der sichere Zustand sein.

## Fix

- Writes bestätigen und Fehler zurückgeben.
- State erst nach erfolgreichem Write aktualisieren.
- bei Teilfehler beide Ausgänge bestmöglich deaktivieren.
- Fehlerzustand in UI/Telemetrie anzeigen.
- Mindesthysterese und Mindestlaufzeit gegen Flattern ergänzen.
- Cluster vollständig validieren.

## Zusatz

`SET_TARGET` ändert `target_volume` aktuell nur im Speicher. Die Änderung muss in die kanonische WATER-Benutzerconfig geschrieben werden.

---

# 9. REPROC-P0 – UI-Fehler wie bei WATER beseitigen

## Status

**KRITISCH OFFEN**

REPROCESSOR besitzt dieselben beiden alten UI-Probleme:

1. Seiten-Closures halten das beim ersten Routeraufbau vorhandene Model fest.
2. UI-Service plus separater `router_touch` verarbeiten denselben Touch über zwei Pfade.

## Fix

- aktuelles Model als Page-Argument verwenden,
- `ui_service.build_model` verwenden,
- `router_touch` entfernen,
- konsumierte Navigation nicht an neue Seite weiterreichen,
- Routerseite mit rollenneutralem Titel rendern.

Aktuell ist der gemeinsame Router-Header fest als `FUEL NODE` beschriftet, auch wenn er im REPROCESSOR verwendet wird.

---

# 10. REPROC-P0.2 – Buffer nur einmal lesen und `process()` budgetieren

## Status

**OFFEN**

## Doppelte Reads

Innerhalb eines einzigen Payloadaufbaus wird `read_buffers()` zweimal ausgeführt:

```lua
reproc_health.bindings = { buffers = #read_buffers() }
payload.buffers = read_buffers()
```

Danach entstehen weitere Aufrufe durch UI-Snapshot, Render und Telemetrie.

## Unbudgetierte Verarbeitung

`process_buffers()` ruft in jedem 0,5-Sekunden-Hauptzyklus für alle Buffer nacheinander `process()` auf.

## Ziel

- ein Buffer-Snapshot pro Generation,
- explizites `process_interval_s`,
- Round-Robin-Cursor,
- Call- und Zeitbudget,
- Backoff für langsame oder fehlerhafte Ports,
- keine Beschleunigung durch Modemevents.

---

# 11. REPROC-P0.3 – Routing verwendet den falschen Configblock

## Status

**KRITISCH OFFEN**

## Bestätigter Strukturfehler

Die REPROCESSOR-Config definiert:

```lua
config.feed.redstone_tree
```

Der gemeinsame `redstone_router` sucht jedoch nur:

```lua
config.logistics.redstone_tree
```

oder:

```lua
config.redstone_tree
```

Der REPROCESSOR erzeugt den Router mit der gesamten Root-Config. Damit wird `config.feed.redstone_tree` im normalen Startpfad nicht gefunden.

## Weitere Folgefehler

- Router-UI arbeitet ebenfalls mit `config.logistics or config`.
- Ein UI-Speichern schreibt `config.redstone_tree`, nicht `config.feed.redstone_tree`.
- `/xreactor/config/reproc_routes.lua` wird beim Neustart nicht vor Routererzeugung geladen.
- Eine in der REPROCESSOR-Config dokumentierte Route kann damit wirkungslos sein.
- Wenn der Router null Ventile kennt, führt `route_and_act()` die Exportaktion direkt ohne Routing aus.

## Verbindlicher Fix

Der Router erhält den tatsächlichen Feedblock:

```lua
redstone_router.new({ config = config.feed, ... })
```

oder eine explizite Config-Accessor-API.

Kanonischer Ablauf analog zum FUEL-Router:

1. persistente `reproc_routes.lua` laden,
2. validieren,
3. vor Routererzeugung in `config.feed.redstone_tree` übernehmen,
4. bei ungültigem Routing Feed hart sperren,
5. atomar speichern,
6. Reload und operative Aktivierung bestätigen.

## Sicherheitsregel

Wenn Routing konfiguriert beziehungsweise erforderlich ist, darf `route_count()==0` niemals still in direkten Export fallen.

---

# 12. REPROC-P0.4 – Feed-Routing nicht blockierend machen

## Status

**OFFEN**

`feed_router` verwendet weiterhin `redstone_router:route_and_act()`.

Dieser Pfad blockiert mit:

```lua
os.sleep(0.4 oder 0.05)
os.sleep(valve_open_ms / 1000)
```

Währenddessen bleiben normale Eventloop-Aufgaben liegen.

## Ziel

Nicht blockierende State-Machine:

```text
IDLE
OPEN_PATH
WAIT_SETTLE
EXPORT
HOLD_OPEN
BLOCK_ALL
COMPLETE / ERROR
```

Heartbeats, Commands, UI und MASTER-Failsafe müssen während des Ventilfensters weiterlaufen.

## Zusätzlicher Standby-Fehler

Jede beliebige `HELLO`-Nachricht setzt aktuell `standby=false`. Beim nächsten Hauptzyklus kann dadurch einmal `process_buffers()` und Feed ausgeführt werden, bevor der stale MASTER-Check den Standby wieder aktiviert.

### Fix

- nur bestätigte MASTER-Kommunikation darf Standby aufheben,
- MASTER-Stale-Prüfung vor Prozess-/Feedarbeit ausführen,
- Zustand explizit als `MASTER_OK`, `MASTER_STALE`, `MANUAL_STANDBY` modellieren.

---

# 13. VALVE-P0 – Modemevent korrekt lesen

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

Aktuell:

```lua
local channel, _, message = event[2], event[3], event[4]
```

Standard-CC:Tweaked liefert:

```text
event[2] = side
event[3] = channel
event[4] = replyChannel
event[5] = message
event[6] = distance
```

Damit vergleicht die VALVE-Node die Modemseite mit der Kanalnummer und interpretiert den Reply-Channel als Nachricht.

## Fix

```lua
local channel = event[3]
local message = event[5]
```

## Pflicht-Test

Ein realistisches Event:

```lua
{
  "modem_message",
  "left",
  6504,
  6504,
  { type="SET_VALVE", dst="VALVE-1", high=false },
  12
}
```

muss genau einen Ventilwechsel auslösen.

---

# 14. VALVE-P0.2 – Ventilzustand nur nach erfolgreichem Write ändern

## Status

**OFFEN**

`apply_valve(high)` setzt zuerst:

```lua
current_high = high
```

und ignoriert danach das Ergebnis von `redstone.setOutput()`.

## Folge

Heartbeat und Status können `blocked=false/true` melden, obwohl der physische Write fehlgeschlagen ist.

## Fix

- Write mit `pcall` ausführen.
- State erst bei Erfolg ändern.
- Fehlerstatus und letzter Writefehler in Telemetrie aufnehmen.
- optional Readback über `redstone.getOutput()`.
- identische Writes unterdrücken, aber `last_command_ts` aktualisieren.

---

# 15. VALVE-P1 – Bestätigung, Retry, Dedupe und Authentisierung

## Status

**OFFEN**

Der dedizierte Ventilkanal ist bewusst Fire-and-forget:

- kein ACK,
- kein Retry,
- keine Sequenznummer,
- kein Dedupe,
- kein vertrauenswürdiger Sender,
- kein bestätigter Ist-Zustand.

## Risiken

- verlorenes OPEN-/BLOCK-Kommando,
- UI zeigt nur angeforderten Zustand,
- fremder Sender auf Kanal 6504 kann passende Kommandos senden,
- wiederholte Pakete erzeugen unnötige Writes und Logs.

## Zielprotokoll

```lua
SET_VALVE = {
  type = "SET_VALVE",
  src = "FUEL-1",
  dst = "VALVE-1",
  command_id = "...",
  side = "front",
  high = true,
  ts = ...,
}

VALVE_ACK = {
  type = "VALVE_ACK",
  command_id = "...",
  applied = true,
  high = true,
  error = nil,
}
```

## Mehrere Ausgänge

Der gewünschte Zustand wird aktuell nur pro Integrator-ID gespeichert. Für Nodes mit mehreren Seiten muss der Schlüssel mindestens `(integrator, side)` enthalten.

---

# 16. RT-P0 – Feste 10-Hz-Regelung tatsächlich umsetzen

## Status

**KRITISCH OFFEN**

## Bestätigter aktueller Ablauf

Der RT-Control-Service besitzt kein eigenes Intervall:

```lua
services:add({
  name = "control",
  tick = function() control_tick() end,
})
```

Die gemeinsame Runtime ruft den Service-Manager:

- bei jedem 0,5-Sekunden-Grundzyklus,
- bei jeder Modemnachricht,
- bei Touch-/Key-Events

auf.

Damit gilt:

- Turbinenregelung läuft normalerweise nur ungefähr mit 2 Hz,
- zusätzlicher Netzwerkverkehr erzeugt zufällige zusätzliche vollständige Turbinenzyklen,
- die Frequenz ist nicht deterministisch,
- die geforderten 10 Hz sind nicht umgesetzt.

Die Reaktorregelung drosselt zusätzlich intern:

```text
mehrere Reaktoren: standardmäßig 1 Sekunde
Einzelreaktor: config.autonom.reactor_adjust_interval, standardmäßig 5 Sekunden
```

## Verbindliche Vorgabe

Aus `CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`:

```lua
scheduler_interval_s = 0.05
turbine_control_interval_s = 0.10
reactor_control_interval_s = 0.10
```

Writes bleiben separat rate-limited:

```lua
turbine_flow_write_min_interval_s = 0.20
reactor_rod_write_min_interval_s = 0.25
```

## Zielarchitektur

- eigener RT-Scheduler mit monotonic Deadline,
- Safety zuerst,
- Rod-Control und Flow-Control getrennte Deadlines,
- Commands markieren höchstens einen koaleszierten vorgezogenen Tick,
- kein Backlog-Burst verpasster Ticks,
- UI/Telemetry/Discovery außerhalb des schnellen Controlpfads.

## Pflicht-Metriken

- Scheduler-Ticks/s,
- Rod-Control-Ticks/s,
- Flow-Control-Ticks/s,
- maximale Ticklücke,
- Peripheral-Reads/Writes pro Tick,
- Skips durch unveränderten Sollwert,
- Deadlineüberschreitungen.

---

# 17. RT-P0.2 – SAFE-Recovery-Context reparieren

## Status

**KRITISCH OFFEN**

In `updateReactorControl()` wird beim Abkühlen aus SAFE aufgerufen:

```lua
ctx.setState(ctx.STATE.MASTER, "SAFETY_TEMPERATURE_RECOVERED")
```

Der von `main.lua` gebaute normale Reaktor-Control-Context enthält jedoch kein `setState`.

## Folge

Sobald alle Reaktoren im SAFE-Modus ausreichend abgekühlt sind, kann der Control-Service mit `attempt to call a nil value` fehlschlagen und in Service-Backoff gehen.

## Fix

Entweder:

```lua
ctx.setState = function(next_state, reason)
  ...
end
```

sauber verdrahten, oder Recovery ausschließlich über die vorhandene State-Machine-API ausführen.

## Pflicht-Test

- Temperatur über Limit → SAFE.
- Temperatur unter Recovery-Schwelle → definierter Übergang.
- kein Nil-Call.
- Grund wird geloggt.
- Reaktoren verlassen SAFE nur bei vollständig bestätigter Erholung.

---

# 18. RT-P0.3 – Capability-Cache reparieren

## Status

**KRITISCH OFFEN**

Aktuell wird der Cache bei vorhandenem Peripheral bei praktisch jedem Aufruf neu aufgebaut:

```lua
if not cache[name] or peripheral.isPresent(name) then
  cache[name] = build_capabilities(name)
end
```

Da `peripheral.isPresent(name)` im Normalbetrieb `true` liefert, läuft `peripheral.getMethods()` wiederholt im Control-, UI- und Statuspfad.

## Fix

- Kind-Namen normalisieren (`turbine/turbines`, `reactor/reactors`).
- Capability nur bei fehlendem Cache aufbauen.
- bei Attach/Detach/Rebind gezielt invalidieren.
- keine Methodenscans im Controlpfad.

---

# 19. RT-P0.4 – Wrapping und identische Actuator-Writes aus Hotpath entfernen

## Status

**OFFEN**

`turbine_control.updateControl()` wrappt weiterhin in jedem Zyklus jeden Reaktor und jede Turbine neu und versucht wiederholt, alle Geräte aktiv zu setzen.

## Ziel

- Discovery-Wrapper verwenden.
- nur nach Hotplug neu wrappen.
- Active-State cachen/readbacken.
- `setActive(true)` nur bei Zustandswechsel oder Reconnect.
- Flow/Coil/Rods nur bei echter Änderung, Retry oder Safety schreiben.
- Overspeed darf normale Cooldowns umgehen.

---

# 20. RT-P1 – Weitere bestätigte Fehler und Lastquellen

## RT-P1.1 Doppelte Discovery

Aktiv sind gleichzeitig:

- `discovery_service` mit `config.scan_interval` (Default 10 Sekunden),
- manueller `discover()`-Vollscan alle 60 Sekunden im `after_cycle`.

Nur eine zentrale Discovery-Policy verwenden: schneller Boot-Retry, Attach/Detach sofort, stabiler Full-Scan deutlich seltener.

## RT-P1.2 Startup-Report prüft falschen Rollenstring

Die RT-Config verwendet:

```lua
role = "RT-NODE"
```

Der Startup-Report prüft:

```lua
config.role == "RT"
```

Dadurch kann „Rolle konfiguriert“ fälschlich fehlschlagen.

## RT-P1.3 Monitor zeigt statisches Ziel-RPM

Der Callback prüft irrtümlich `reactor_control.get_target_rpm`, obwohl die Funktion in `turbine_control` liegt. Dadurch fällt der Ausdruck praktisch immer auf den statischen Default `900` zurück, statt den aktuellen MASTER-Setpoint anzuzeigen.

## RT-P1.4 Release-Datei im Monitor-Hotpath

Für `manifest_id` und `release_id` wird bei jedem Monitorupdate jeweils erneut `require`/`dofile` versucht.

Buildinfo einmal beim Start laden.

## RT-P1.5 Gemeinsamer Hardware-Snapshot fehlt

UI, Telemetrie, Capacity-Learning und teilweise Control lesen Reaktor-/Turbinenwerte weiterhin in getrennten Durchläufen. Ein generationsbasierter Snapshot muss redundante nicht-sicherheitskritische Reads zusammenführen.

---

# 21. ENERGY-P0 – Services wirklich in getrennte Schedulergruppen aufteilen

## Status

**TEILWEISE UMGESETZT**

## Bereits vorhanden

- eigener Heartbeat-Thread,
- eigener als Matrix-Thread bezeichneter Coroutine-Pfad,
- Matrix- und Storage-Snapshotmodule.

## Noch fehlerhaft

Der Matrix-Thread ruft weiterhin aus:

```lua
ctx.services:tick()
```

Damit liegen im gleichen potenziell blockierenden Pfad:

- Discovery,
- Storage-Sampling,
- Matrix-Sampling,
- Telemetrie,
- UI,
- Comms-Maintenance.

Ein langsamer Matrixcall blockiert damit weiterhin alle diese Services gemeinsam. Nur der separate Heartbeat-Coroutine-Pfad ist grundsätzlich unabhängig.

## Zusätzliche Regression

Der Heartbeat-Thread ruft bei Touch/Key ebenfalls `services:tick(nil, event)` auf. Ist ein Matrix-Sample gerade fällig, kann ein UI-Event den langsamen Matrixcall im Heartbeat-Thread ausführen und damit genau den eigentlich geschützten Heartbeat-/Comms-Pfad blockieren.

## Zielgruppen

```text
1. Comms + Heartbeat + Command-Events
2. Matrix-Sampling
3. Storage-Sampling
4. UI + Telemetrie
5. Discovery
```

Jede Gruppe braucht eigene Deadline und Fehlerisolierung.

## Heartbeat-Frequenz

Der Matrix-Thread sendet nach jedem etwa 0,5-Sekunden-Zyklus zusätzlich einen Heartbeat, obwohl die Config standardmäßig 2 Sekunden vorgibt. Heartbeats müssen von einer einzigen zentralen Zeitquelle erzeugt werden; ein langer Matrixcall darf nur eine fällige Sendung anstoßen, nicht dauerhaft zusätzliche Heartbeats erzeugen.

---

# 22. ENERGY-P1 – Storage-Sampling staffeln

## Status

**OFFEN**

Alle 0,5 Sekunden werden für jedes Storage gelesen:

- stored,
- capacity,
- input,
- output.

`capacity` ist meistens statisch und muss nicht mit 2 Hz gelesen werden.

## Ziel

```lua
stored_interval_s = 0.5
rate_interval_s = 0.5
capacity_interval_s = 5.0
```

Zusätzlich:

- Call-/Zeitbudget,
- Backoff pro langsamem Gerät,
- last-good Snapshot,
- klare stale-Diagnose.

---

# 23. MASTER-P1 – Einstellungen persistent und zielgenau machen

## Status

**TEILWEISE / OFFEN**

## MASTER-P1.1 Config-Editor ändert mehrere Werte nur im Speicher

Nicht dauerhaft gespeichert werden unter anderem:

- PEAK-Schwellwert,
- IDLE-Schwellwert,
- lokaler AUTO-UPDATE-Schalter,
- lokale UI-Zustände.

Der AUTO-UPDATE-Schalter ändert nur `runtime.state.auto_update_enabled`. Der tatsächliche Auto-Updater liest seine eigene Config und wird dadurch nicht dauerhaft beziehungsweise nicht nodeübergreifend umgestellt.

## MASTER-P1.2 FUEL/WATER-Auswahl

Der Config-Editor sendet FUEL-Reserve und WATER-Ziel nur an den ersten gefundenen Node der Rolle.

Bei mehreren Nodes muss die UI anbieten:

- konkreten Node auswählen,
- alle Nodes der Rolle,
- sichtbare ACK-/Fehlerauswertung.

## MASTER-P1.3 Terminal-Maus

Der MASTER-Loop leitet `monitor_touch`, `key` und `char` weiter, aber kein `mouse_click`. Terminal-Fallbacks sind damit nicht vollständig bedienbar.

---

# 24. MASTER-P1.2 – Fuel-Relay darf stale RT-Werte nicht verjüngen

## Status

**KRITISCH OFFEN für die Fuel-Versorgung**

Der MASTER sammelt gespeicherte RT-Reaktorwerte und setzt beim Relay für jeden Eintrag einen neuen Zeitstempel:

```lua
ts = os.epoch("utc")
```

Es wird nicht geprüft, wie alt der RT-Node oder dessen ursprünglicher Snapshot ist.

## Folge

Ein längst ausgefallener RT-Node kann indirekt weiterhin scheinbar frische Fuelwerte liefern, solange sein letzter Nodezustand im MASTER gespeichert ist.

## Fix

- ursprünglichen Sample-Zeitstempel erhalten,
- Node-Stale-/Down-Status prüfen,
- nur Werte unter einer definierten Altersgrenze relayn,
- Quellalter explizit mitsenden,
- FUEL darf Empfangszeit nicht als Messzeit interpretieren.

---

# 25. MASTER-P2 – UI- und Debuglast reduzieren

## Status

**TEILWEISE**

Der MASTER baut bei einem Draw weiterhin alle View-Modelle gemeinsam auf. `multiview.lua` serialisiert anschließend das jeweilige Model pro Monitor/View für den Vergleich.

Bei mehreren Monitoren derselben View entstehen unnötige wiederholte Serialisierungen.

Zusätzlich ist Debug-Logging standardmäßig aktiv und jeder erfolgreiche Monitor-Render kann eine DEBUG-Zeile erzeugen.

## Ziel

- Modelgeneration pro View/Datenbereich,
- Signatur einmal pro Viewgeneration,
- mehrere Monitore teilen dieselbe Signatur,
- nur sichtbare Views vollständig bauen,
- Debug-Strings nur erzeugen, wenn DEBUG wirklich aktiv ist,
- Rendererfolg aggregieren statt pro Frame loggen.

---

# 26. LOG-P1 – Persistente Writes bündeln

## Status

**OFFEN**

Für jedes einzelne Logevent wird:

1. Dateigröße geprüft,
2. Datei geöffnet,
3. eine Zeile geschrieben,
4. Datei geschlossen.

## Sicherheitsanforderung

`LOG_ACK written` darf weiterhin erst nach erfolgreicher Persistierung gesendet werden.

## Ziel

Kleine per-path Batches:

```lua
flush_lines = 8
flush_interval_ms = 200
max_pending_lines = 128
```

- ACKs erst nach erfolgreichem Batch-Write.
- ERROR/CRITICAL optional sofort flushen.
- Disk-Eject und Out-of-Space sauber behandeln.
- Backpressure und Speicherlimit definieren.

---

# 27. LOG-P1.2 – Dedupe, ACK-Fanout und UI-Rate-Limit

## Status

**OFFEN**

## Dedupe

Nach Überschreiten von 512 Einträgen wird `table.remove(seen_order, 1)` verwendet. Das verschiebt das gesamte Array.

Ziel: Ringbuffer oder Head-Index mit O(1).

## ACK

Ein ACK wird über jedes gefundene Modem gesendet. Bei Wireless + Wired entstehen mehrere identische Übertragungen.

Ziel: empfangendes beziehungsweise bevorzugtes Wireless-Modem einmal verwenden; Fallback nur bei Sendefehler.

## UI

Zusätzlich zum Timer wird nach jeweils 20 empfangenen Events sofort gezeichnet. Unter hoher Last kann das häufige UI-Arbeit erzeugen.

Ziel:

```lua
active_draw_min_interval_s = 1
idle_draw_interval_s = 5
```

## Wartbarkeitsrisiko

`mockup_main.lua` liest `main.lua` als Text, sucht feste Marker und ersetzt die lokale `draw()`-Funktion zur Laufzeit. Schon eine harmlose Umbenennung oder Kommentarverschiebung kann den LOG-Start brechen.

Langfristig den Renderer über eine normale Modul-/Dependency-Schnittstelle anbinden statt Sourcecode-Textpatching.

---

# 28. FUEL – nur cross-node Blocker in dieser Datei

Die vollständigen FUEL-Aufgaben bleiben in den dedizierten Dokumenten. Beim Gesamt-Audit weiterhin bestätigt:

1. `nodes/fuel/config.lua` gibt seine `CONFIG`-Tabelle nicht zurück.
2. Ein ungültiger beziehungsweise leerer Routingbaum kann über `route_count()==0` in direkten Export fallen.
3. `route_and_act()` blockiert weiterhin mit `os.sleep()`.
4. VALVE-Kommandos besitzen kein ACK/Retry.
5. MASTER kann stale RT-Fuelwerte neu timestampen.
6. FUEL-/REPROCESSOR-Routen sind durch die Installer-Config-Persistenz gefährdet.

Diese Punkte dürfen nicht als erledigt markiert werden, nur weil die FUEL-UI sichtbar verbessert wurde.

---

# 29. TEST-P0 – Vorhandene Tests werden in CI nicht ausgeführt

## Status

**OFFEN**

## Aktueller Workflow

`.github/workflows/offline-tests.yml` führt nur aus:

```text
lua5.2 tools/offline_validate.lua
```

Der Offline-Validator:

- parst die Lua-Dateien,
- prüft Manifestpfade,
- prüft Release-/Manifest-Metadaten.

Er führt die zahlreichen Dateien unter `tests/` nicht aus.

## Zusätzlich bestätigte veraltete Tests

### `tests/rt_control_tick_wiring_regression_test.lua`

Der Test sucht alte Funktionen und Verdrahtungen:

```text
local function adjust_turbines(...)
local function adjust_reactors(...)
adjust_turbines = adjust_turbines
adjust_reactors = adjust_reactors
```

Diese Architektur existiert im aktuellen RT-Rewrite nicht mehr. Der Test würde damit fehlschlagen, wird aber vom Workflow nicht ausgeführt.

### `tests/rt_schema_ctx_guard_test.lua`

Der Test erwartet unter anderem eine ältere `monitor_ui.init(...)`-Signatur und alte Contextformen. Auch dieser Guard ist nicht auf den aktuellen Rewrite abgestimmt.

### `TESTPLAN.md`

Der Kopf bezeichnet weiterhin `v358`, während der geprüfte Stand `beta-v397` ist.

## Verbindlicher CI-Umbau

Mindestens:

```text
1. Lua-Parse/Manifest-Validator
2. alle kompatiblen tests/*.lua
3. alle tests/*.py
4. explizite Ausschlussliste nur mit Begründung
5. Ergebnis als verpflichtender Statuscheck
```

Tests müssen nach Rolle und Funktionsbereich gruppiert werden, damit ein Fehler schnell zugeordnet werden kann.

## Neue Pflicht-Testgruppen

```text
tests/shared_event_timer_separation_test.lua
tests/config_persistence_all_roles_test.lua
tests/water_ui_model_and_touch_test.lua
tests/water_cluster_failsafe_test.lua
tests/reprocessor_ui_and_buffer_snapshot_test.lua
tests/reprocessor_routing_persistence_test.lua
tests/valve_modem_event_test.lua
tests/valve_write_confirmation_test.lua
tests/rt_fixed_cadence_test.lua
tests/rt_safe_recovery_test.lua
tests/rt_capability_cache_test.lua
tests/energy_scheduler_isolation_test.lua
tests/master_config_persistence_test.lua
tests/master_fuel_relay_freshness_test.lua
tests/log_batch_ack_durability_test.lua
```

Für den geprüften Head wurden über die GitHub-Schnittstelle keine zugeordneten Statuschecks beziehungsweise Workflow-Runs zurückgegeben. Deshalb darf aus der vorhandenen Workflowdatei nicht auf einen erfolgreichen Lauf des aktuellen Commits geschlossen werden.

---

# 30. Verbindliche Bearbeitungsreihenfolge

1. **VALVE-P0** – Modemevent-Indizes sofort korrigieren.
2. **GLOBAL-P0** – kanonische, updatesichere Benutzerconfigs für alle Rollen.
3. **REPROC-P0.3** – richtigen Routingblock verwenden und direkten Export bei Routingfehler sperren.
4. **WATER-P0.4** – Cluster-Failsafe bei unbekanntem Tankstand und Writefehler.
5. **RT-P0.2** – SAFE-Recovery-Context reparieren.
6. **SHARED-P0** – Event- und Timerpfad trennen; `control_service.interval` implementieren.
7. **RT-P0** – feste 10-Hz-Control-Cadence mit separaten Write-Cooldowns.
8. **WATER/REPROC UI** – stale Closures und doppelte Touchpfade entfernen.
9. **REPROC-P0.4 / FUEL** – Redstone-Routing als nicht blockierende State-Machine.
10. **RT-P0.3/P0.4** – Capability-Cache, Wrapper und identische Writes optimieren.
11. **ENERGY-P0** – echte Scheduler-/Threadtrennung.
12. **WATER-/REPROC-Snapshots** – physische Reads pro Generation einmal.
13. **MASTER-Fuel-Relay** – Quellfrische erhalten.
14. **LOG-P1** – Batch-I/O, Ringbuffer, einzelner ACK-Weg.
15. **TEST-P0** – vollständige Testsuite in CI verpflichtend ausführen.
16. Danach P1/P2-Last- und UI-Optimierungen.

---

# 31. Definition of Done

## Allgemein

- alle Rollen laden eine kanonische Benutzerconfig außerhalb der heruntergeladenen Programmdateien,
- Auto-Updates erhalten alle Benutzerwerte,
- keine Rollen-Crashseite benötigt unbegrenzt einen physischen Tastendruck,
- Modemverkehr beschleunigt keine periodischen Services,
- Attach/Detach wird gezielt behandelt,
- alle kritischen Writes besitzen klare Erfolgs-/Fehlersemantik.

## WATER

- aktuelles UI-Model wird tatsächlich gerendert,
- ein Touch erzeugt genau eine Aktion,
- jeder Tank wird pro Generation höchstens einmal gelesen,
- unbekannter Tankstand lässt keine unkontrolliert aktiven Cluster-Ausgänge zurück,
- Zieländerungen sind persistent.

## REPROCESSOR

- aktuelles UI-Model und ein zentraler Touchpfad,
- Buffer pro Generation einmal gelesen,
- `process()` budgetiert,
- `config.feed.redstone_tree` ist der operative Baum,
- Routen überleben Reboot und Update,
- kein direkter Export bei erforderlichem, aber ungültigem Routing,
- Ventilfenster blockiert den Eventloop nicht,
- fremde HELLO-Nachrichten heben MASTER-Standby nicht auf.

## VALVE

- realistisches Standard-Modemevent wird korrekt verarbeitet,
- State ändert sich nur nach erfolgreichem Redstone-Write,
- identische Writes werden unterdrückt,
- ACK/Retry/Dedupe/Auth vorhanden,
- Status wird pro Integrator und Seite geführt,
- Fail-Safe bleibt aktiv.

## RT

- Flow- und Rod-Regler laufen zeitbasiert mit der dokumentierten Frequenz,
- keine zusätzlichen vollständigen Control-Ticks durch Eventstürme,
- SAFE-Recovery funktioniert ohne Nil-Call,
- Capabilities werden pro Discoverygeneration einmal gebaut,
- stabile Geräte werden nicht pro Tick neu gewrappt/aktiviert,
- nur eine Discovery-Policy,
- UI/Telemetrie teilen geeignete Snapshotwerte,
- Safety besitzt weiterhin höchste Priorität.

## ENERGY

- langsame Matrixcalls blockieren weder Comms/Heartbeat noch Storage/UI/Telemetrie/Discovery,
- Heartbeat besitzt eine einzige Zeitquelle,
- Storage-Metriken besitzen fachlich getrennte Intervalle,
- last-good Snapshots und stale-Diagnose bleiben korrekt.

## MASTER

- Config-Editor-Werte sind persistent,
- mehrere FUEL-/WATER-Nodes sind zielgenau auswählbar,
- Auto-Update-Schalter steuert die echte persistente Updaterconfig,
- stale RT-Fuelwerte werden nicht verjüngt,
- Terminal-Maus funktioniert,
- UI-/Debugarbeit ist generations- und levelbasiert.

## LOG

- ACK nur nach tatsächlicher Persistierung,
- Writes sind gebündelt und speicherbegrenzt,
- Dedupe O(1),
- pro erfolgreichem Event höchstens ein normaler ACK-Sendeweg,
- UI ist zeitbasiert begrenzt,
- kein fragiler Sourcecode-Textpatch als langfristige Rendererarchitektur.

## Tests

- aktuelle Tests entsprechen der aktuellen Architektur,
- alle Lua-/Python-Tests laufen automatisiert,
- kritische Testgruppen sind verpflichtende Statuschecks,
- Lasttests dokumentieren vorher/nachher gemessene Werte,
- der aktuelle Commit besitzt einen nachweislich grünen CI-Lauf.
