# Coding-AI-Vorgabe: RT-Regelung und feste Zykluszeiten

Stand: 2026-07-12  
Ziel-Branch: `beta`  
Status: verbindliche Ergänzung zu `CODING_AI_PERFORMANCE_TASKS_2026-07-12.md`

> Bei einem Konflikt zwischen dieser Datei und allgemeinen Performance-Empfehlungen hat diese Datei für den RT-Node Vorrang.

## Grundsatz

Die Performanceoptimierung darf die Reaktionsgeschwindigkeit der RT-Regelung **nicht** reduzieren.

Die Turbinen-Flowregelung und die Reaktor-Fuel-Rod-Regelung müssen häufig und mit einer festen, zeitbasierten Frequenz laufen. Optimiert werden sollen die unnötigen Nebenarbeiten innerhalb des schnellen Regelkreises:

- keine Discovery im Regelkreis
- keine erneute Methoden-Erkennung im Regelkreis
- kein vollständiger UI-/Telemetrie-Snapshot im Regelkreis
- keine Datei-I/O im Regelkreis
- keine identischen, unnötigen Actuator-Writes
- keine zusätzliche Ausführung allein wegen eingehender Modemnachrichten

Eine hohe feste Frequenz ist gewollt. Eine durch Netzwerk-Events zufällig schwankende oder unbegrenzt steigende Frequenz ist nicht gewollt.

---

# 1. Begriffe eindeutig trennen

## 1.1 Scheduler-Tick

Der Scheduler-Tick entscheidet, welche Teilregelungen jetzt fällig sind. Er darf selbst sehr häufig laufen und muss billig sein.

Standard:

```lua
scheduler_interval_s = 0.05
```

Das entspricht 20 Scheduler-Prüfungen pro Sekunde. Ein Scheduler-Tick bedeutet nicht automatisch, dass jedes Peripheral vollständig gelesen und beschrieben wird.

## 1.2 Control-Tick

Ein Control-Tick liest die für die jeweilige Regelung notwendigen schnellen Messwerte, berechnet das neue Soll und entscheidet über einen Write.

Standard für beide Hauptregler:

```lua
turbine_control_interval_s = 0.10
reactor_control_interval_s = 0.10
```

Damit laufen Flow- und Rod-Regler regulär mit 10 Hz.

## 1.3 Actuator-Write

Ein Actuator-Write ist ein tatsächlicher Hardwareaufruf wie:

- `setFluidFlowRate`
- `setFluidFlowRateMax`
- `setAllControlRodLevels`
- `setControlRodLevel`
- `setInductorEngaged`
- `setActive`

Der Control-Tick darf häufig berechnen. Ein Write erfolgt nur, wenn er fachlich notwendig ist.

## 1.4 Readback

Readback bestätigt, ob ein vorheriger Write tatsächlich am Gerät angekommen ist. Readback muss häufig genug sein, darf aber von langsamen Diagnosewerten getrennt werden.

---

# 2. Verbindliche Prioritäten

Die Reihenfolge innerhalb eines Scheduler-Zyklus lautet:

1. Safety- und Overspeed-Prüfung
2. Reaktor-Fuel-Rod-Regelung
3. Turbinen-Flow- und Coil-Regelung
4. Command-/Setpoint-Anwendung
5. Heartbeat und Kommunikationsqueue
6. Telemetrie
7. lokale UI
8. Discovery und Diagnose

Safety darf nie auf UI, Telemetrie oder Discovery warten.

---

# 3. Turbinenregelung

## 3.1 Zweck

Jede gebundene Turbine soll schnell auf RPM-Abweichungen reagieren. Der Flow-Regler muss deshalb häufig laufen.

## 3.2 Standardzeiten

```lua
turbine_control_interval_s = 0.10
turbine_flow_write_min_interval_s = 0.20
turbine_flow_readback_interval_s = 0.20
turbine_coil_readback_interval_s = 0.20
turbine_output_sample_interval_s = 0.50
turbine_active_readback_interval_s = 1.00
```

Bedeutung:

- RPM wird für jede Turbine alle 100 ms gelesen.
- Der Regler berechnet alle 100 ms den nächsten Flow.
- Ein geänderter Flow darf regulär spätestens alle 200 ms geschrieben werden.
- Flow- und Coil-Readback laufen alle 200 ms beziehungsweise sofort nach einem Write.
- Energieoutput ist für die schnelle RPM-Regelung nicht erforderlich und wird nur alle 500 ms gelesen.
- `getActive` ist kein 10-Hz-Messwert und wird nur periodisch oder nach Zustandswechsel geprüft.

## 3.3 Zulässige Reads im schnellen Turbinenpfad

Pro Turbine und Control-Tick grundsätzlich nur:

1. RPM
2. die minimal notwendigen Safety-Werte
3. optional fälliger Flow-/Coil-Readback

Nicht im schnellen Pfad:

- `peripheral.getMethods`
- vollständiges `adapter.inspect`
- Registry-Zusammenfassung
- Energy-/Output-Werte, wenn sie für die aktuelle Regelentscheidung nicht benötigt werden
- UI-Modellbau
- Telemetrie-Payloadbau

## 3.4 Writes

Ein Flow-Write erfolgt nur, wenn mindestens eine Bedingung zutrifft:

- der neue Sollwert unterscheidet sich vom letzten erfolgreich geschriebenen Wert
- ein Readback ist noch nicht bestätigt und ein Retry ist fällig
- Overspeed verlangt sofort Flow 0
- ein Mode-/Start-/Stop-Wechsel verlangt einen neuen Zustand
- das Peripheral wurde neu verbunden und muss synchronisiert werden

Ein stabiler Sollwert darf nicht bei jedem 100-ms-Tick erneut geschrieben werden.

## 3.5 Overspeed

Overspeed besitzt Vorrang vor normalen Cooldowns.

```lua
overspeed_bypass_write_cooldown = true
```

Bei erkanntem Overspeed:

- Flow sofort auf 0
- Coil gemäß Safety-Logik sofort schalten
- kein Warten auf normales `turbine_flow_write_min_interval_s`

## 3.6 Skalierung bei vielen Turbinen

Auch bei 25 Turbinen soll der Regler häufig reagieren. Dafür wird nicht die Frequenz reduziert, sondern die Arbeit pro Turbine minimiert:

- Wrapper cachen
- Capabilities cachen
- nur RPM im schnellen Pfad zwingend lesen
- Flow-/Coil-Readback nur wenn fällig
- Output langsamer sampeln
- unveränderte Writes überspringen
- keine Methodenlisten oder vollständigen Adapterinspektionen

Eine pauschale Reduktion auf 1–5 Sekunden ist nicht zulässig.

---

# 4. Reaktor-Fuel-Rod-Regelung

## 4.1 Zweck

Die Fuel Rods müssen schnell auf Dampf-Füllstand, Dampfbedarf und Safety-Grenzen reagieren. Die Berechnung darf deshalb nicht nur alle 1–5 Sekunden laufen.

## 4.2 Standardzeiten

```lua
reactor_control_interval_s = 0.10
reactor_rod_write_min_interval_s = 0.25
reactor_rod_readback_interval_s = 0.25
reactor_coolant_sample_interval_s = 0.10
reactor_steam_sample_interval_s = 0.10
reactor_temperature_sample_interval_s = 0.10
```

Bedeutung:

- Dampf-, Kühlmittel- und Safety-Werte werden mit 10 Hz geprüft.
- Der Rod-Regler berechnet mit 10 Hz.
- Ein normaler Rod-Write darf spätestens alle 250 ms erfolgen, sofern sich das Ziel tatsächlich geändert hat.
- Rod-Readback erfolgt alle 250 ms beziehungsweise direkt nach einem Write.

## 4.3 Bestehende langsame Begrenzungen ersetzen

Die derzeitigen äußeren Intervalle von ungefähr 1 Sekunde bei mehreren Reaktoren beziehungsweise 5 Sekunden bei einem Reaktor widersprechen dieser Vorgabe und müssen durch den festen 100-ms-Control-Tick ersetzt werden.

Die bisherige Stabilität soll nicht durch ein langsames äußeres Intervall erreicht werden, sondern durch:

- EMA
- Deadband
- Hysterese
- Ramp-Limits
- minimale Write-Abstände
- bestätigten Readback
- Safety-Grenzen

## 4.4 Rod-Writes

Ein Rod-Write erfolgt nur, wenn:

- das berechnete Ziel vom bestätigten beziehungsweise zuletzt geschriebenen Wert abweicht
- die minimale Änderungsschwelle erreicht ist
- der normale Write-Cooldown abgelaufen ist
- ein fälliger Retry erforderlich ist
- eine Safety-Aktion den normalen Cooldown überstimmt

Empfohlene minimale Änderung:

```lua
reactor_rod_min_change = 1
```

Dadurch kann der Regler mit 10 Hz rechnen, ohne identische Rod-Werte zehnmal pro Sekunde zu schreiben.

## 4.5 Safety-Ausnahmen

Folgende Aktionen dürfen den normalen Rod-Write-Cooldown umgehen:

- SAFE-Modus
- SCRAM
- kritische Temperatur
- kritischer Kühlmittelzustand
- kritischer interner Dampf-Füllstand, wenn die vorhandene Safety-Logik ein sofortiges Schließen verlangt

```lua
reactor_safety_bypass_write_cooldown = true
```

Safety bedeutet hierbei grundsätzlich Rods weiter schließen beziehungsweise auf den sicheren Grenzwert setzen. Safety darf niemals wegen einer Performance-Drosselung verzögert werden.

---

# 5. Netzwerk-Events

## 5.1 Gewolltes Verhalten

Eingehende Nachrichten dürfen sofort:

- neue Setpoints speichern
- einen Mode-Wechsel speichern
- Master-Zeitstempel aktualisieren
- Commands bestätigen
- einen priorisierten, vorgezogenen Control-Tick markieren

## 5.2 Nicht gewolltes Verhalten

Eine Modemnachricht darf nicht direkt einen zusätzlichen vollständigen Flow- und Rod-Regelzyklus außerhalb der festen Zeitplanung erzeugen.

Bei 100 Nachrichten innerhalb von 100 ms dürfen nicht 100 Hardware-Control-Ticks entstehen.

## 5.3 Vorgezogener Tick

Ein wichtiges Command darf den nächsten Control-Tick vorziehen. Mehrere Commands werden koalesziert.

Regel:

```lua
next_control_due = math.min(next_control_due, now)
```

Es wird höchstens ein zusätzlicher sofort fälliger Tick markiert. Es entsteht keine Event-Queue mit nachträglich abzuarbeitenden Control-Ticks.

---

# 6. Deadline- und Überlastverhalten

## 6.1 Kein Tick-Backlog

Wenn ein Control-Tick länger als sein Intervall dauert, dürfen keine verpassten Ticks nachträglich als Burst abgearbeitet werden.

Falsch:

```lua
while now >= next_due do
  run_control()
  next_due = next_due + interval
end
```

Richtig:

```lua
if now >= next_due then
  run_control()
  next_due = now + interval
end
```

## 6.2 Reaktionsziel

Normalbetrieb:

- Ziel: 100 ms pro Flow-/Rod-Control-Zyklus
- akzeptable kurzfristige Abweichung: bis 200 ms
- Warnung: länger als 250 ms zwischen zwei Control-Ticks
- kritisch zu untersuchen: länger als 500 ms

## 6.3 Degradation unter Last

Unter hoher Last werden zuerst langsamere Aufgaben verschoben:

1. Discovery
2. UI
3. Diagnose
4. vollständige Telemetrie
5. nicht notwendige Readbacks

Nicht verschieben:

- Safety
- Rod-Control
- Flow-Control
- Command-ACK
- Master-Verbindungsüberwachung

---

# 7. Empfohlene Konfiguration

Neue RT-Konfiguration beispielsweise:

```lua
control = {
  scheduler_interval_s = 0.05,

  turbine = {
    control_interval_s = 0.10,
    flow_write_min_interval_s = 0.20,
    flow_readback_interval_s = 0.20,
    coil_readback_interval_s = 0.20,
    output_sample_interval_s = 0.50,
    active_readback_interval_s = 1.00,
    overspeed_bypass_write_cooldown = true,
  },

  reactor = {
    control_interval_s = 0.10,
    rod_write_min_interval_s = 0.25,
    rod_readback_interval_s = 0.25,
    rod_min_change = 1,
    steam_sample_interval_s = 0.10,
    coolant_sample_interval_s = 0.10,
    temperature_sample_interval_s = 0.10,
    safety_bypass_write_cooldown = true,
  },
}
```

Die Coding-KI darf diese Werte nach reproduzierbaren Ingame-Messungen feinjustieren. Sie darf die Hauptregler jedoch nicht ohne dokumentierten Grund wesentlich langsamer als 10 Hz machen.

---

# 8. Architekturvorgabe

Empfohlene Aufteilung:

```text
RT Scheduler, 20 Hz
├── Safety Guard, 10–20 Hz
├── Reactor Controller, 10 Hz
├── Turbine Controller, 10 Hz
├── Comms fast path, event-driven
├── Flow/Rod readback, 4–5 Hz oder sofort nach Write
├── Telemetry snapshot, 1–2 Hz beziehungsweise Statusintervall
├── UI render, etwa 1 Hz
└── Discovery, ereignisbasiert plus langsamer Fallback
```

Flow- und Rod-Regelung gehören nicht in den UI-, Telemetrie- oder Discovery-Takt.

---

# 9. Verbindliche Tests

## 9.1 Frequenztests

- 10 Sekunden Laufzeit ergeben ungefähr 100 Turbinen-Control-Ticks.
- 10 Sekunden Laufzeit ergeben ungefähr 100 Reaktor-Control-Ticks.
- Toleranz für Offline-Test: ±10 %, sofern simulierte Uhr und Eventloop dies erfordern.

## 9.2 Event-Sturm

- 1.000 Modemnachrichten innerhalb von 10 Sekunden erhöhen die Control-Tick-Zahl nicht über die feste Zeitfrequenz hinaus.
- Ein Setpoint-Command wird spätestens im nächsten 100-ms-Control-Tick berücksichtigt.

## 9.3 Stabile Anlage

- Bei konstantem RPM-/Rod-Soll laufen weiterhin alle Berechnungen.
- Identische Flow- und Rod-Writes werden übersprungen.
- `peripheral.getMethods` wird im stabilen Control-Hotpath nicht aufgerufen.

## 9.4 Lasttest mit 25 Turbinen

Messen:

- durchschnittliche und maximale Control-Tick-Dauer
- maximale Zeit zwischen zwei Control-Ticks
- RPM-Reads pro Sekunde
- Flow-Writes pro Sekunde
- Capability-Cache-Hits/Misses
- Wrapper-Aufrufe

Abnahme:

- jede Turbine wird ungefähr alle 100 ms geregelt
- kein vollständiges `adapter.inspect` pro Turbine und Control-Tick
- keine identischen Writes
- keine Discovery im Control-Tick
- kein durch Netzwerkverkehr verursachter zusätzlicher Hardware-Tick

## 9.5 Safety

- Overspeed setzt Flow ohne normalen Write-Cooldown auf 0.
- SCRAM/SAFE setzt Rods ohne normalen Write-Cooldown auf sicheren Wert.
- Safety bleibt auch dann ausführbar, wenn UI oder Discovery gerade überfällig sind.

---

# 10. Definition of Done

- Turbinen-Flowregelung läuft standardmäßig mit 10 Hz.
- Reaktor-Fuel-Rod-Regelung läuft standardmäßig mit 10 Hz.
- Scheduler verwendet echte Zeit und nicht die Anzahl empfangener Events.
- Flow-/Rod-Berechnung und tatsächliche Writes sind getrennt.
- Unveränderte Writes werden übersprungen.
- Safety kann normale Write-Cooldowns umgehen.
- Discovery, UI und Telemetrie sind vom schnellen Regelkreis getrennt.
- Capability- und Peripheral-Caches werden im Hotpath verwendet.
- 25-Turbinen-Lasttest dokumentiert Vorher-/Nachher-Werte.
- Keine Sicherheits- oder Regelungsregression.
