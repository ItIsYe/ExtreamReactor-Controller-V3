# Coding-AI-Aufgaben: Performance- und Skalierungs-Audit

Stand: 2026-07-12  
Ziel-Branch: `beta`  
Ergänzung zu: `docs/CODING_AI_IMPLEMENTATION_TASKS_2026-07-12.md`

## Zweck

Diese Datei beschreibt die bei einer statischen Laufzeitanalyse gefundenen Performance-Risiken. Die stärksten Kandidaten liegen aktuell im RT-Node, insbesondere bei vielen Turbinen/Reaktoren und bei viel Modemverkehr.

Die Analyse ist statisch. Deshalb sollen die Änderungen zuerst instrumentiert und anschließend mit reproduzierbaren Lasttests geprüft werden. Keine Sicherheitsfunktion darf allein zugunsten besserer Laufzeit verlangsamt oder entfernt werden.

## Verbindliche Regeln

1. Reaktor-, Turbinen-, Kühlmittel- und Overspeed-Schutz müssen funktional erhalten bleiben.
2. Regelzyklen müssen nach echter Zeit gesteuert werden, nicht nach der Anzahl eingehender Events.
3. UI und Telemetrie dürfen gecachte Messwerte verwenden. Sicherheits- und Regelungslogik muss ihre zulässige maximale Messwertalterung ausdrücklich definieren.
4. Keine vollständigen Stage-/Backup-Installationen anlegen. Die Speicherentscheidung aus der Hauptaufgabendatei bleibt bestehen.
5. Vor größeren Umbauten zuerst Messpunkte und Regressionstests ergänzen.

---

# PERF-P0 – Sehr wahrscheinliche Hauptursachen

## PERF-P0.1 Capability-Cache des RT-Nodes reparieren

### Betroffene Stelle

`xreactor/nodes/rt/turbine_control.lua`, Funktion `M.get_device_caps`.

Aktuell:

```lua
function M.get_device_caps(ctx, kind, name)
  ctx.capability_cache[kind] = ctx.capability_cache[kind] or {}
  if not ctx.capability_cache[kind][name] or peripheral.isPresent(name) then
    ctx.capability_cache[kind][name] = build_capabilities(name)
  end
  return ctx.capability_cache[kind][name]
end
```

### Problem

Bei einem vorhandenen Peripheral liefert `peripheral.isPresent(name)` normalerweise `true`. Damit wird `build_capabilities(name)` bei praktisch jedem Aufruf erneut ausgeführt.

`build_capabilities()` ruft `peripheral.getMethods(name)` auf und durchsucht die komplette Methodenliste. Diese Funktion liegt in mehreren heißen Pfaden:

- Turbinenregelung
- Reaktorprüfung
- lokaler RT-Monitor
- Status-/Telemetrieaufbau

Bei vielen Turbinen vervielfacht sich der Aufwand stark.

Zusätzlich werden uneinheitliche Cache-Schlüssel verwendet, zum Beispiel `turbine`/`turbines` und `reactor`/`reactors`. Dadurch können parallele Cache-Bereiche für dasselbe Gerät entstehen.

### Ziel

Capabilities genau einmal pro bekanntem Peripheral und Discovery-Generation ermitteln. Nur bei echtem Hotplug, Rebind oder expliziter Invalidierung neu aufbauen.

### Umsetzung

1. `kind` über eine kleine Normalisierungsfunktion vereinheitlichen:
   - `turbine` und `turbines` → `turbines`
   - `reactor` und `reactors` → `reactors`
2. Cache nur aufbauen, wenn für den Namen kein Eintrag existiert.
3. Bei Discovery/Rebind gezielt ungültige oder entfernte Einträge löschen.
4. Bei `peripheral`/`peripheral_detach` den betroffenen Namen invalidieren.
5. Keine `peripheral.getMethods()`-Abfrage im normalen Regel- oder Render-Hotpath.

Beispielrichtung:

```lua
function M.get_device_caps(ctx, kind, name)
  local bucket = normalize_capability_kind(kind)
  ctx.capability_cache[bucket] = ctx.capability_cache[bucket] or {}
  local cached = ctx.capability_cache[bucket][name]
  if cached then return cached end

  local caps = build_capabilities(name)
  ctx.capability_cache[bucket][name] = caps
  return caps
end
```

### Tests

- 100 Aufrufe für dasselbe vorhandene Peripheral dürfen `peripheral.getMethods` nur einmal aufrufen.
- Nach expliziter Invalidierung muss genau ein neuer Aufbau erfolgen.
- Singular- und Pluralbezeichnung müssen denselben Cache-Eintrag liefern.
- Entferntes und erneut angeschlossenes Peripheral erhält frische Capabilities.

### Abnahmekriterien

- Kein wiederholtes Methoden-Scanning pro Turbine und Regelzyklus.
- Hotplug bleibt funktionsfähig.
- Bestehende Capability-Fallbacks bleiben erhalten.

---

## PERF-P0.2 RT-Regelung vollständig von Modem-Events entkoppeln

### Betroffene Stellen

- `xreactor/nodes/support/runtime.lua`
- `xreactor/nodes/rt/main.lua`
- optional `xreactor/services/control_service.lua`

### Problem

Der generische Node-Eventloop ruft bei jeder `modem_message` den kompletten Service-Manager auf:

```lua
comms:handle_event(event)
services:tick(nil, event)
```

Der RT-Node registriert den Control-Service ohne eigenes Intervall:

```lua
services:add({
  name = "control",
  tick = function() control_tick() end,
})
```

Dadurch kann jede eingehende Modemnachricht die vollständige Reaktor- und Turbinenregelung auslösen. Bei einem gemeinsamen Statuskanal und vielen Nodes kann die RT-Regelung wesentlich häufiger laufen als vorgesehen.

Die Reaktorregelung besitzt teilweise internes Rate-Limiting. Die Turbinenregelung durchläuft dagegen pro Aufruf alle konfigurierten Reaktoren und Turbinen und führt zahlreiche Peripheral-Reads/Writes aus.

### Ziel

Die Regelung läuft ausschließlich nach einem monotonic/wall-clock-basierten Intervall. Eingehende Nachrichten aktualisieren nur Zustände, Queue und Setpoints. Sie erzeugen keinen zusätzlichen vollständigen Regelzyklus.

### Umsetzung

Bevorzugte Lösung:

1. `control_service.lua` um echtes `interval`, `start_delay` und `next_due_at` erweitern.
2. `tick()` darf `tick_fn()` nur aufrufen, wenn das reale Zeitintervall abgelaufen ist.
3. RT verwendet einen konfigurierbaren Wert, zum Beispiel:

```lua
control_interval = 0.5
```

4. Kritische Sicherheitsprüfungen dürfen bei Bedarf einen eigenen, dokumentierten Safety-Sampler erhalten. Nicht stillschweigend dieselbe Drosselung auf alles anwenden.
5. Bei Setpoint- oder Mode-Commands darf optional ein einzelner vorgezogener Control-Tick angefordert werden, jedoch koalesziert und maximal einmal pro Mindestintervall.
6. Kein künstliches `dt = 0.5` bei fehlendem `dt` annehmen.

### Tests

- 100 `modem_message`-Events innerhalb einer Sekunde erzeugen höchstens die gemäß `control_interval` erlaubte Zahl vollständiger Control-Ticks.
- Ohne Netzwerkverkehr läuft der Control-Tick weiterhin periodisch.
- Ein Command aktualisiert Setpoints sofort, die Hardwareanwendung folgt spätestens im nächsten erlaubten Control-Tick.
- Overspeed-/SAFE-Tests bleiben grün.
- Event-Sturm darf Heartbeat und UI nicht verhungern lassen.

### Abnahmekriterien

- Control-Tick-Rate ist unabhängig von der Anzahl eingehender Nachrichten.
- Die gemessene Tick-Zahl entspricht dem konfigurierten Zeitintervall.
- Keine Regression der Sicherheitslogik.

---

## PERF-P0.3 Peripheral-Wrapping und unveränderte Actuator-Writes im RT-Hotpath reduzieren

### Problem

`turbine_control.updateControl()` führt aktuell bei jedem Durchlauf unter anderem aus:

- `peripheral.wrap(name)` für jeden Reaktor
- `peripheral.wrap(name)` für jede Turbine
- Aktivierung jedes Reaktors/Turbine
- RPM-/Flow-/Induktor-Reads
- Flow-Setter und Readback

Discovery hält bereits gewrappte Peripherals in `ctx.peripherals.reactors` und `ctx.peripherals.turbines`. Diese Objekte werden im Regel-Hotpath trotzdem häufig neu gewrappt.

`setTurbineFlow()` schreibt den Flow auch dann erneut, wenn der angeforderte Wert unverändert ist. `setTurbineActive(..., true)` wird ebenfalls wiederholt aufgerufen.

### Ziel

Im normalen Regelzyklus nur die Messwerte lesen und Writes durchführen, die für eine echte Zustandsänderung notwendig sind.

### Umsetzung

1. Gewrappte Objekte aus `ctx.peripherals` verwenden.
2. Nur bei fehlendem Cache oder nach Discovery/Hotplug neu wrappen.
3. Pro Turbine letzten erfolgreich geschriebenen Flow und Active-Zustand speichern.
4. Flow nur schreiben, wenn:
   - Sollwert sich außerhalb der konfigurierten Toleranz geändert hat,
   - Readback nicht bestätigt ist,
   - Retry fällig ist,
   - Safety/Overspeed eine erzwungene Aktion verlangt.
5. `setActive(true)` nur beim Übergang von inaktiv/unbekannt zu aktiv oder nach bestätigtem Reconnect ausführen.
6. Coil-Writes bleiben zustandsbasiert; bestehende Skip-Logik erhalten.

### Tests

- Stabiler Zielzustand über 20 Ticks erzeugt keine 20 identischen Flow-Writes.
- Flow-Änderung erzeugt genau den erforderlichen Write plus dokumentierte Readback-Retries.
- Overspeed erzwingt weiterhin sofort Flow 0 und Coil-Verhalten.
- Reconnect invalidiert den Write-State und synchronisiert das Peripheral erneut.

### Abnahmekriterien

- `peripheral.wrap` ist im stabilen RT-Control-Hotpath nicht mehr pro Gerät und Tick sichtbar.
- Identische Actuator-Writes werden unterdrückt.
- Readback- und Safety-Verhalten bleiben korrekt.

---

## PERF-P0.4 Doppelte RT-Discovery entfernen und Scanstrategie entschärfen

### Problem

Der RT-Node registriert bereits einen `discovery_service` mit `config.scan_interval`. Der Default in `nodes/rt/config.lua` beträgt 10 Sekunden.

Zusätzlich führt `nodes/rt/main.lua` im `after_cycle` noch einen manuellen Vollscan alle 60 Sekunden aus. Der Kommentar dazu behauptet, Discovery sei vorher nur beim Boot gelaufen, obwohl gleichzeitig der Discovery-Service aktiv ist.

Ein Vollscan ruft für viele Peripherals unter anderem auf:

- `peripheral.getNames`
- `peripheral.getType`
- `peripheral.getMethods`
- Reactor-/Turbine-Adapter-Inspektion
- Registry-Synchronisierung

Bei großen Anlagen kann dies regelmäßige Lastspitzen verursachen.

### Ziel

Nur eine Discovery-Instanz. Normale Änderungen primär ereignisbasiert, vollständiger Rescan deutlich seltener und konfigurierbar.

### Umsetzung

1. Manuellen 60-Sekunden-Scan entfernen oder ausschließlich als Fallback durch denselben Discovery-Service abbilden.
2. `peripheral` und `peripheral_detach` als sofortige Discovery-Trigger unterstützen.
3. Regulären Full-Scan-Default für stabile Anlagen erhöhen, zum Beispiel 60 bis 300 Sekunden.
4. Nach Boot darf ein kurzer Retry-Zyklus bestehen:
   - schneller Retry bei leerer/unvollständiger Discovery,
   - nach erfolgreicher Bindung in langsamen Normalmodus wechseln.
5. Unveränderte Topologie darf keine erneute Adapter-Vollinspektion erzwingen, wenn eine schnelle Signaturprüfung reicht.

### Tests

- Kein zweiter unabhängiger RT-Discovery-Timer.
- Stabile Anlage wird nicht alle 10 Sekunden vollständig inspiziert.
- `peripheral`-Event bindet neues Gerät zeitnah.
- `peripheral_detach` entfernt beziehungsweise markiert Gerät zuverlässig.
- Fehlgeschlagener Boot-Scan wird weiterhin wiederholt.

### Abnahmekriterien

- Genau eine zentrale Discovery-Policy.
- Keine doppelten 60-Sekunden-Scans.
- Keine periodischen starken Full-Scan-Spitzen im stabilen Betrieb.

---

# PERF-P1 – Hohe Auswirkungen bei großen Anlagen

## PERF-P1.1 Gemeinsamen RT-Hardware-Snapshot für UI und Telemetrie einführen

### Problem

Der RT-Node liest dieselben Geräte in kurzen Abständen mehrfach:

- Telemetrie baut Turbinen- und Reaktor-Snapshots auf.
- Der lokale Monitor baut einen eigenen Snapshot auf.
- Der Monitor durchläuft Turbinen teilweise zweimal:
  - RPM-Min/Max/Avg
  - Detaildaten und Output
- Reaktoren werden ebenfalls mehrfach inspiziert:
  - Temperaturstatistik
  - Detaildaten
- `adapter.inspect()` ermittelt zusätzlich wieder Methodentabellen und mehrere Messwerte.

Bei 20 bis 30 Turbinen führt ein einzelner sichtbarer Monitor-Refresh dadurch zu vielen redundanten Remote-Peripheral-Aufrufen.

### Ziel

Ein Hardware-Sampling-Pass erzeugt einen unveränderlichen Snapshot. UI, Telemetrie, Statistiken und Capacity-Learning verwenden diesen Snapshot innerhalb eines definierten Maximalalters gemeinsam.

### Umsetzung

1. Neues Modul, zum Beispiel `nodes/rt/hardware_snapshot.lua`.
2. Snapshot enthält je Gerät mindestens:
   - Messzeit
   - RPM
   - Flow
   - Output
   - Active
   - Coil
   - Reaktorwerte, Rods, Temperatur, Kühlmittel, Dampf, Fuel
3. Aus der bereits gesammelten Geräteliste Min/Max/Avg berechnen; keine zweite Peripheral-Leserunde.
4. UI- und Telemetrie-Cache mit `max_age_ms` verwenden.
5. Sicherheits-/Control-Reads dürfen bei notwendiger Frische separat bleiben; klar dokumentieren, welche Werte geteilt werden dürfen.
6. Capabilities und Peripheral-Wrapper aus dem Discovery-Cache übernehmen.

### Empfohlene Altersgrenzen

- UI: etwa 500–1000 ms
- Status-Telemetrie: etwa 500–1000 ms
- Regelung/Safety: eigene fachlich begründete Grenzen

Diese Werte sind Startpunkte und müssen anhand realer Hardware getestet werden.

### Tests

- Ein UI-Refresh liest jede Turbine höchstens einmal pro Messwertart.
- UI und Telemetrie innerhalb desselben Cachefensters teilen denselben Snapshot.
- Nach Ablauf des Maximalalters erfolgt ein neuer Sampling-Pass.
- Statistiken entsprechen den Details desselben Snapshots.

### Abnahmekriterien

- Keine doppelte Turbinen-/Reaktorinspektion innerhalb eines UI-/Statuszyklus.
- Messwerte eines dargestellten Frames stammen aus derselben Generation.

---

## PERF-P1.2 Kommunikations-Maintenance rate-limiten

### Problem

Jeder Aufruf von `core.comms.tick()` führt aktuell unter anderem aus:

- Dedupe-Listen komplett bereinigen und neu aufbauen
- Send-Queue durchlaufen
- Inflight-Retries durchlaufen
- Incoming-Nachrichten verarbeiten
- alle Peers auf Timeout prüfen

Da `comms.tick()` durch den Service-Manager auch auf Modem-Events ausgelöst wird, laufen Dedupe- und Peer-Maintenance bei hohem Traffic unnötig häufig.

### Ziel

Incoming-Verarbeitung und dringende Send-Queue bleiben reaktionsschnell. Teure periodische Wartungsarbeiten laufen nur in sinnvollen Zeitabständen.

### Umsetzung

`comms.tick()` logisch aufteilen:

1. `process_incoming()` – bei neuen Nachrichten sofort
2. `flush_queue()` – bei neuer Queue beziehungsweise kleinem Mindestintervall
3. `retry_inflight()` – nach nächstem fälligen Retry-Zeitpunkt
4. `prune_dedupe()` – zum Beispiel einmal pro Sekunde oder abhängig von nächstem Ablauf
5. `update_peer_timeouts()` – zum Beispiel alle 500–1000 ms

Zusätzlich:

- Dedupe-Strukturen nicht bei jedem Prune vollständig neu allokieren, wenn ein Index/Ringbuffer genügt.
- `next_maintenance_due` berechnen statt alle Tabellen blind zu scannen.

### Tests

- 100 eingehende Nachrichten verursachen nicht 100 vollständige Peer- und Dedupe-Scans.
- ACK, Commands und Heartbeats bleiben funktional.
- Timeout-/Retry-Zeitpunkte bleiben innerhalb dokumentierter Toleranz.
- Dedupe-Schutz bleibt erhalten.

### Abnahmekriterien

- Maintenance-Zähler zeigen feste, zeitbasierte Frequenzen.
- Nachrichtendurchsatz verbessert sich ohne Protokollregression.

---

## PERF-P1.3 Broadcast-Fan-out des gemeinsamen Statuskanals reduzieren

### Problem

Alle Nodes öffnen dieselben Control- und Statuskanäle. STATUS und HEARTBEAT werden ohne Ziel als Broadcast gesendet. Deshalb empfängt grundsätzlich jeder Node den Status jedes anderen Nodes, obwohl meist nur MASTER diese Daten benötigt.

Mit `N` Nodes entsteht dadurch näherungsweise quadratische Empfangsarbeit: Jeder sendende Node erzeugt Events auf allen anderen Nodes. Das ist besonders problematisch, solange Service- und Control-Ticks an Modem-Events gekoppelt sind.

### Ziel

Unnötige Node-zu-Node-Telemetrie vermeiden, ohne notwendige Relays und Discovery-Funktionen zu brechen.

### Umsetzungsmöglichkeiten

Bevorzugt nach PERF-P0.2 umsetzen, damit zuerst der größte Verstärker entfernt ist.

Mögliche Architektur:

- separater `node_to_master_status`-Kanal
- separater `master_to_node_control`-Kanal
- optionale kleine Broadcast-/Discovery-Schiene
- gezielte Relays für Funktionen, die tatsächlich Node-zu-Node-Daten benötigen

Alternativ:

- Nodes filtern Modemnachrichten vor dem kompletten Service-Tick sehr früh nach relevantem Typ/Ziel/Rolle.
- STATUS fremder Support-Nodes wird auf RT/FUEL/WATER nicht weiterverarbeitet, wenn kein Verbraucher existiert.

### Tests

- MASTER erhält weiterhin alle Statusdaten.
- Commands und ACKs funktionieren.
- Fuel-/RT-Relay-Funktionen bleiben erhalten.
- Ein Node-Sturm erzeugt auf einem unbeteiligten Node deutlich weniger Events/Verarbeitung.

### Abnahmekriterien

- Netzwerklast skaliert nicht mehr unnötig mit jedem Sender×Empfänger-Paar.
- Keine stille Funktionsregression bei Relays.

---

## PERF-P1.4 Nicht-RT-UI-Payloads nur einmal pro Zyklus bauen

### Problem

Einige Nodes bauen denselben Status-Payload sowohl im `ui_service.snapshot` als auch erneut in `render_monitor()` auf. WATER ist ein klarer Fall. Der Payload liest Tanks, Cluster, Registry und Kommunikationsdiagnostik.

FUEL verwendet bereits einen kurzlebigen 300-ms-Cache, um genau diese doppelte Arbeit zwischen Hauptmonitor und Ampel zu vermeiden. Dieses Muster sollte vereinheitlicht werden.

### Ziel

Snapshot und Render verwenden dieselbe Payload-Generation.

### Umsetzung

1. Gemeinsamen `payload_cache` mit Zeitstempel und optionaler Dirty-Generation einführen.
2. `snapshot()` speichert das erzeugte Model/Payload im UI-State.
3. `render()` verwendet den bereits erzeugten Wert statt erneut Hardware zu lesen.
4. Zeitstempel, die sich immer ändern, nicht als alleinigen UI-Dirty-Grund verwenden. Visuelle Snapshot-Signatur getrennt von Telemetrie-Zeitstempel halten.
5. WATER, REPROCESSOR, VALVE und weitere Support-Nodes prüfen.

### Tests

- Ein UI-Zyklus ruft den Hardware-Payload-Builder höchstens einmal auf.
- Inhalt ändert sich weiterhin nach echtem Gerätewertwechsel.
- Touch-Navigation zeichnet sofort neu, ohne neue Hardware-Leserunde zu erzwingen, falls Daten noch frisch sind.

---

# PERF-P2 – Mittlere und kleinere Optimierungen

## PERF-P2.1 FUEL-Ampel nicht mit künstlichem `dt` beschleunigen

### Problem

Der FUEL-Ampel-Service addiert bei fehlendem `dt` pauschal `0.5`. Da Modem-Event-Ticks mit `dt=nil` eintreffen, können bereits zwei Netzwerkpakete einen vermeintlichen Zeitablauf von einer Sekunde erzeugen und die Ampel erneut rendern.

### Ziel

Ausschließlich echte Uhrzeit verwenden.

### Umsetzung

Das Muster aus `services/matrix_sampling_service.lua` verwenden:

- `next_due_at`
- `os.epoch("utc")`
- Render nur, wenn `ts >= next_due_at`

### Tests

- 100 Modem-Events innerhalb von 100 ms lösen keinen zusätzlichen Ampel-Render aus.
- Nach einer echten Sekunde erfolgt ein Render.

---

## PERF-P2.2 Release-/Buildinformationen einmal beim RT-Start laden

### Problem

Der lokale RT-Monitor versucht bei jedem Update getrennt für `manifest_id` und `release_id`, das Release-Modul zu laden beziehungsweise per `dofile` einzulesen.

### Ziel

Release-Metadaten einmal beim Start auflösen und im Context halten.

### Umsetzung

- `build_info.get()` oder `release.lua` einmal in `init()` laden.
- Monitor erhält ein kleines unveränderliches `build_info`-Objekt.
- Kein Datei-I/O im Monitor-Hotpath.

---

## PERF-P2.3 Master-UI-Modell- und Serialisierungsarbeit reduzieren

### Problem

Bei jedem tatsächlichen Master-UI-Draw werden alle View-Modelle gemeinsam aufgebaut. Anschließend serialisiert `multiview.lua` das Modell je Monitor/View erneut für den Änderungsvergleich.

Bei vielen Nodes und mehreren Monitoren kann dies sichtbar werden, auch wenn die aktuell stärkeren RT-Probleme zuerst behoben werden sollten.

### Ziel

Modellgeneration und Snapshot-Signatur pro View-Generation berechnen und über mehrere Monitore wiederverwenden.

### Umsetzung

- Dirty-/Generation-Counter pro Datenbereich statt vollständiger Tabellenserialisierung bevorzugen.
- Serialisierte Signatur pro View nur einmal pro Modellgeneration erzeugen.
- Mehrere Monitore derselben View teilen diese Signatur.
- Nur tatsächlich sichtbare View-Modelle vollständig aufbauen; globale Badge-/Alarmdaten separat klein halten.

### Tests

- Drei Monitore mit derselben View führen nicht zu drei vollständigen Modellserialisierungen.
- View-Wechsel und Touch-Dirty-Redraw bleiben sofort sichtbar.

---

## PERF-P2.4 Logger- und Debug-Defaults für Produktionsbetrieb prüfen

### Problem

MASTER, RT und ENERGY aktivieren Debug-Logging standardmäßig. Der Logger puffert zwar, aber bei vielen Control-/UI-/Comms-Ereignissen entstehen Stringformatierung, Speicherallokationen und periodische Datei-I/O.

### Ziel

Produktion arbeitet standardmäßig mit INFO/WARN/ERROR beziehungsweise ausgeschaltetem Debug-Trace. Diagnose kann gezielt aktiviert werden.

### Umsetzung

- Log-Level statt nur booleschem Debug-Schalter unterstützen.
- Teure Debug-Strings nur erzeugen, wenn der Level aktiv ist.
- Performance-Metriken aggregieren, nicht jeden Tick loggen.
- Bestehende Notfall- und Fehlerlogs nicht entfernen.

### Tests

- Deaktiviertes DEBUG erzeugt keine Debug-Stringformatierung und keine Debug-Dateizeilen.
- WARN/ERROR bleiben sichtbar.
- Laufzeitumschaltung bleibt möglich.

---

# PERF-P3 – Messbarkeit und Lasttests

## PERF-P3.1 Leichtgewichtige Laufzeitmetriken ergänzen

### Ziel

Die Coding-KI soll nicht nur vermutete Optimierungen durchführen, sondern die Wirkung messbar machen.

### Metriken pro Service

- Aufrufzahl
- tatsächliche Arbeitsausführungen versus rate-limited Skips
- letzte Dauer
- Maximum
- gleitender Durchschnitt oder EMA
- Anzahl Ticks über 50/100/250/500 ms

### Zusätzliche RT-Metriken

- Control-Ticks pro Sekunde
- Peripheral-Reads pro Zyklus
- Peripheral-Writes pro Zyklus
- `peripheral.wrap`-Aufrufe
- `peripheral.getMethods`-Aufrufe
- Discovery-Dauer und Anzahl inspizierter Geräte
- Snapshot-Cache-Hits/Misses

### Anforderungen

- Instrumentierung selbst muss billig sein.
- Keine Logzeile pro Tick.
- Aggregierte Ausgabe zum Beispiel alle 30–60 Sekunden oder auf Diagnostics-Seite.
- Metriken abschaltbar beziehungsweise mit sehr geringem Overhead.

---

## PERF-P3.2 Reproduzierbare Offline-Lasttests

### Szenarien

1. **RT klein**: 1 Reaktor, 2 Turbinen
2. **RT groß**: 2 Reaktoren, 25 Turbinen
3. **Netzwerk normal**: 10 Nodes mit regulären Heartbeats/Status
4. **Netzwerk-Sturm**: 100 Modemnachrichten pro Sekunde
5. **Mehrere Monitore**: MASTER mit 3 Primär- und mehreren AUX-Monitoren
6. **Discovery stabil**: unveränderte Topologie über 10 Minuten
7. **Hotplug**: Peripheral attach/detach während Betrieb

### Zu prüfende Grenzwerte

Grenzwerte zunächst messen und anschließend im Testplan festlegen. Als relative Mindestziele:

- Modem-Sturm erhöht RT-Control-Tick-Rate nicht.
- Capability-Methodenabfrage sinkt im stabilen Betrieb von pro Hotpath-Aufruf auf einmal pro Discovery-Generation.
- UI-/Telemetrie-Sampling liest jedes Gerät pro Snapshot-Generation höchstens einmal je Messwertart.
- Unveränderte Discovery erzeugt keine häufigen Vollinspektionen.
- Heartbeat-Verzögerungen bleiben auch bei UI/Discovery-Last innerhalb der vorhandenen Sicherheitsmargen.

---

# Empfohlene Bearbeitungsreihenfolge

1. PERF-P3.1 Messpunkte einbauen
2. PERF-P0.1 Capability-Cache reparieren
3. PERF-P0.2 RT-Control-Tick zeitbasiert machen
4. PERF-P0.3 Wrapper und redundante Writes reduzieren
5. PERF-P0.4 doppelte/zu häufige Discovery bereinigen
6. PERF-P1.1 gemeinsamer RT-Hardware-Snapshot
7. PERF-P1.2 Comms-Maintenance rate-limiten
8. PERF-P2.1 FUEL-Ampel-Timer reparieren
9. PERF-P1.4 Support-UI-Payload-Caches vereinheitlichen
10. PERF-P1.3 Netzwerk-Fan-out reduzieren
11. PERF-P2.2/P2.3/P2.4 kleinere Hotpath-Optimierungen
12. PERF-P3.2 vollständige Lasttest-Matrix

# Definition of Done für Performance-Änderungen

- Vorher-/Nachher-Messwerte dokumentiert
- neue Regressionstests vorhanden
- Sicherheits- und Regelungstests bleiben grün
- keine Event-abhängige Beschleunigung periodischer Services
- keine wiederholten Methoden-Scans im stabilen Hotpath
- keine identischen unnötigen Actuator-Writes
- keine doppelte RT-Discovery
- UI und Telemetrie teilen frische Snapshots, wo fachlich zulässig
- Heartbeat und Command-Verarbeitung bleiben reaktionsfähig
- Manifest-/Release-Guards werden bei Änderungen an manifestierten Dateien korrekt aktualisiert
