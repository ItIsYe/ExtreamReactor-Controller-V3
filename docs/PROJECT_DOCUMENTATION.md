# XReactor Controller V3 — Vollständige Projektdokumentation

> Letzte Aktualisierung: beta-v133  
> Stack: CC:Tweaked · Extreme Reactors 2 · Mekanism · ATM10 (MC 1.21.1)

---

## Inhaltsverzeichnis

1. [Systemüberblick](#1-systemüberblick)
2. [SCADA-Designprinzip](#2-scada-designprinzip)
3. [Netzwerk & Protokoll](#3-netzwerk--protokoll)
4. [MASTER Node](#4-master-node)
5. [RT Node — Reaktor & Turbinen](#5-rt-node--reaktor--turbinen)
6. [Startsequenz](#6-startsequenz)
7. [Remote Update](#7-remote-update)
8. [Peripheral-Erkennung](#8-peripheral-erkennung)

---

## 1. Systemüberblick

Ein MASTER-Computer koordiniert alle Nodes. Nodes melden ihren Status, der Master berechnet Sollwerte und sendet sie zurück. Hardware-Steuerung bleibt strikt lokal auf der Node die die Peripherie besitzt.

```
┌──────────────────────────────────────────────────────┐
│                       MASTER                         │
│  UI · Alerts · Telemetry · Setpoints · Profiles      │
└──────┬───────────────────────────┬───────────────────┘
       │ Ender Modem (ch 6500/6501)│
  ┌────▼────┐  ┌────────┐  ┌──────▼──────┐  ┌─────┐
  │   RT    │  │ ENERGY │  │ WATER/FUEL/ │  │ LOG │
  │Reactor  │  │Matrix  │  │REPROCESSING │  │     │
  │Turbines │  │Storage │  │ Support     │  │     │
  └─────────┘  └────────┘  └─────────────┘  └─────┘
```

---

## 2. SCADA-Designprinzip

**Master kennt das Ziel. Nodes kennen den Weg.**

- Master sendet nur `power_target_percent` (0–100 %) und einen Zustandsintent
- RT-Node berechnet autonom: Anzahl aktiver Turbinen, Flow pro Turbine, Induktor-Timing, Reaktor-Stab-Position
- Master hat keine Kenntnis über individuelle Turbinen-RPM oder Flow-Werte

Dies entspricht dem SCADA-Prinzip (Supervisory Control and Data Acquisition): zentrales Monitoring und Sollwertvorgabe, dezentrale Ausführung.

---

## 3. Netzwerk & Protokoll

### Kanäle

| Kanal | Richtung | Inhalt |
|-------|----------|--------|
| 6500 | MASTER → Nodes | Commands, Setpoints |
| 6501 | Nodes → MASTER | Status-Payloads, Heartbeats |
| 6502 | alle → LOG | Log-Zeilen |

### Message-Typen

| Typ | Beschreibung |
|-----|-------------|
| `HELLO` | Node meldet sich beim Start beim Master an |
| `STATUS` | periodischer Status-Payload (Heartbeat + Daten) |
| `SET_SETPOINTS` | Master sendet Sollwerte an RT-Node |
| `SET_MODE` | Master sendet State-Transition |
| `REMOTE_UPDATE` | Master triggert Installer-Update |
| `ACK` | Node bestätigt empfangenes Command |

---

## 4. MASTER Node

### Leistungsschätzung (`runtime_ops_profile.lua`)

Priorität für `power_target`:
1. `measured_total` — Summe der tatsächlichen RT-Outputs (beste Schätzung)
2. `learned_capacity_total` — Summe der gelernten Kapazitäten (bei SHED/Reboot)
3. `power_target` vom letzten Tick (Kontinuität)
4. Kein generischer Fallback mehr (wurde entfernt — 3000 RF/t war um Größenordnungen falsch)

### Multi-Node-Zuweisung (`rt_sync.lua`)

Proportionale Verteilung statt Greedy:

```
1. Nodes nach Kapazität sortieren (größte zuerst)
2. Greedy: zählen wie viele Nodes für global_target benötigt werden
3. uniform_pct = global_target / Summe(benötigte Kapazitäten) × 100
4. Alle benötigten Nodes bekommen denselben Prozentsatz
```

Vorteil: gleichmäßige Auslastung, kein Yo-Yo-Effekt, korrekte Skalierung auf N Nodes.

### Setpoint-Paket (Master → RT)

Nur 4 Felder werden gesendet:

| Feld | Typ | Bedeutung |
|------|-----|-----------|
| `power_target_percent` | number 0–100 | Prozent der Gesamtkapazität |
| `assignment_state` | string | `active` / `shed` / `shutdown` / `standby` |
| `shutdown_stage` | string\|nil | `REQUEST_OFF` / `RAMPDOWN` |
| `desired_node_state` | string | `RUNNING` / `LIMITED` / `OFF` |

Entfernt: `target_rpm`, `steam_target`, `power_target` (absolut), `enable_reactors`, `enable_turbines`, `assignment_reason/source/rank`, `controllable`.

---

## 5. RT Node — Reaktor & Turbinen

### Modulstruktur

| Datei | Zeilen | Verantwortlichkeit |
|-------|--------|-------------------|
| `nodes/rt/main.lua` | ~750 | Boot, Service-Wiring, ctx-Assembly |
| `nodes/rt/reactor_control.lua` | ~540 | Rod-Steuerung, Steam-Margin-Regler |
| `nodes/rt/turbine_control.lua` | ~930 | Flow, Induktor, Overspeed, Rotation |
| `nodes/rt/capacity_learning.lua` | ~110 | Kontinuierliche Kapazitätsmessung |
| `nodes/rt/status_snapshot.lua` | ~160 | Status-Payload für Master |
| `nodes/rt/state_handlers.lua` | ~270 | State-Machine (AUTONOM/MASTER/SAFE) |
| `nodes/rt/command_handler.lua` | ~285 | SET_SETPOINTS, REMOTE_UPDATE |
| `nodes/rt/module_lifecycle.lua` | ~625 | SCRAM, Safe-Controls, Startup |
| `nodes/rt/monitor_ui.lua` | ~610 | Lokales Display |

### ctx-Architektur

Alle Fachmodule erhalten einen expliziten `ctx`-Parameter mit ihren Abhängigkeiten. Keine globalen Closures. Vorteile:
- Fehler in `reactor_control` betreffen nur die Reaktor-Regelung
- Fehler in `turbine_control` betreffen nur die Turbinen-Regelung
- Jede Abhängigkeit ist am Funktionskopf sichtbar

### Reaktor-Steuerung

**Steam-Margin-Regler:** Der Reaktor wird ausschließlich über Stab-Level geregelt. Der Regler misst die Steam-Tank-Füllstand und passt die Stäbe so an, dass die Turbinen immer genug Dampf haben ohne den Tank zu überfluten.

**Rod-Write-Fallback** (4 Stufen, alle ER2-Varianten abgedeckt):
1. `setAllControlRodLevels` (primär, ER2 2.x)
2. `setControlRodsLevels` (Tabellenform)
3. `setControlRodLevel` (pro Stab, 0-indiziert mit 1-Fallback)
4. `getControlRods().setLevel` (Objekt-Methode)

### Turbinen-Steuerung

**Ziel-RPM: 900** (fix, aus `CONFIG.TARGET_RPM`). Coil rastet bei ≥ 900 RPM ein.

**3-Zustands-Teillast-Modell:**

```
exact      = n × power_percent / 100
full       = floor(exact)          → 900 RPM, Coil ON
remainder  = exact − full          → 1 Puffer-Turbine: remainder × 900 RPM
off        = n − full − 1          → 0 RPM (rotiert, damit keine Turbine dauerhaft kalt)
```

Der Coil der Puffer-Turbine skaliert: `engage_rpm = 900 × scale` → korrekte Leistung.

Rotation über `partial_turbine_index` — alle N Sekunden wechseln Puffer- und AUS-Turbinen.

### Capacity Learning

```
ready = false  →  Node wartet, Master weist 0 % zu
ready = true   →  Master kann proportionalen Load zuweisen
```

- Misst kontinuierlich bei 900 RPM (unabhängig vom Master)
- Min. 80 % der Turbinen müssen am Ziel sein für gültige Messung
- Höhere Werte werden sofort übernommen, niedrigere ignoriert (kein Reset bei kurzem Einbruch)
- Ergebnis wird in `capacity_cache.lua` persistiert

### State-Machine

| Zustand | Beschreibung |
|---------|-------------|
| `AUTONOM` | Kein Master erreichbar — Node regelt selbstständig auf Vollast |
| `MASTER` | Master aktiv, folgt Setpoints |
| `SAFE` | Notabschaltung — alle Turbinen/Reaktoren deaktiviert |

---

## 6. Startsequenz

```
LOG/LOG_COLLECTOR  → 0s  (sofort)
MASTER             → 2s  (wartet auf LOG)
Alle anderen Nodes → 8s  (warten auf LOG + MASTER)
```

Nodes senden beim Start `HELLO`. Wenn Master noch nicht bereit ist, wird das nächste Heartbeat-Interval (2–5s) abgewartet. Die Startsequenz minimiert verlorene HELLOs.

---

## 7. Remote Update

**Trigger:** Redstone-Signal auf Seite `top` des MASTER-Computers.

**Flow:**
```
Master:  Redstone-Event → broadcast REMOTE_UPDATE → alle Nodes
Master:  remote_update.run() für sich selbst

RT-Node: REMOTE_UPDATE empfangen → pending_remote_update = true (kein Block!)
RT-Node: nach aktuellem Event-Zyklus (max. 0.5s) → after_cycle()
RT-Node: http.get(GitHub) → Installer auf Disk schreiben
RT-Node: dofile(installer) → non-interaktiv (__xreactor_remote_update = true)
RT-Node: os.reboot()
```

**Warum deferred?** CC:Tweaked's `http.get()` ist asynchron und wartet auf `http_success`-Events über `os.pullEvent()`. Innerhalb eines `modem_message`-Handlers kann dieses Event nicht ankommen → ewiges Warten. Der Deferred-Mechanismus (v117) löst das.

---

## 8. Peripheral-Erkennung

**Erkennung über `peripheral.getType()`:**

```lua
type:find("turbine") → turbine
type:find("reactor") → reactor
```

Unterstützte Typ-Namen: `BigReactors-Reactor`, `BigReactors-Turbine`, `extremereactors:turbine_part` und weitere.

**ER2 Turbine API (genutzte Methoden):**
- `getRotorSpeed()` → aktuelles RPM
- `setFluidFlowRateMax(rate)` → Flow in mB/t setzen
- `setInductorEngaged(bool)` → Coil ein/aus
- `getFluidFlowRateMaxMax()` → maximaler Flow
- `getEnergyProducedLastTick()` → RF/t

**ER2 Reaktor API (genutzte Methoden):**
- `setActive(bool)` → Reaktor ein/aus
- `setAllControlRodLevels(level)` → alle Stäbe (primäre Methode)
- `getHotFluidAmount()` → Steam-Füllstand
- `getHotFluidAmountMax()` → Steam-Kapazität
- `getFuelTemperature()` → Brennstoff-Temperatur
