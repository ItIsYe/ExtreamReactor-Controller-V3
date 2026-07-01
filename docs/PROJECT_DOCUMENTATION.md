# XReactor Controller V3 — Projektdokumentation

> Letzte Aktualisierung: beta-v236  
> Stack: CC:Tweaked · Extreme Reactors 2 · Mekanism · ATM10 (MC 1.21.1)

---

## Aktueller Status

Stand: `beta` / `manifest-v236` / `beta-v236`.

Diese Dokumentation beschreibt den aktuellen Architekturstand und die offenen Prüfpunkte. Es wurde bei dieser Doku-Aktualisierung kein Ingame-Test durchgeführt und nichts ingame installiert.

Wichtigster offener Punkt:

```text
xreactor/nodes/rt/main.lua
```

In der Tabelle für `monitor_ui.update(...)` fehlt weiterhin ein Komma nach dem `build_health_payload` Funktionsfeld. Dieser Codefehler wurde auf Wunsch nicht behoben, sondern nur dokumentiert. Solange dieser Punkt offen ist, gilt RT nicht als sauber startfähig.

Weitere offene Prüfpunkte:

- RT-Monitorwerte sind noch auf `manifest-v158` / `beta-v158` hart codiert.
- `xreactor/manifest.lua` und `xreactor/release.lua` verwenden aktuell unterschiedliche `hash_algo` Werte.
- `xreactor/manifest.lua` hat einen älteren Header-Kommentar als seine eigentlichen Manifestwerte.
- Remote-Update ist geschützt und robuster, aber die Optionsweitergabe im Command-Pfad sollte später geprüft werden.

Details stehen in:

```text
docs/NODE_START_BLOCKERS_2026-06-25.md
```

---

## Inhaltsverzeichnis

1. [Systemüberblick](#1-systemüberblick)
2. [SCADA-Designprinzip](#2-scada-designprinzip)
3. [Netzwerk & Protokoll](#3-netzwerk--protokoll)
4. [MASTER Node](#4-master-node)
5. [RT Node — Reaktor & Turbinen](#5-rt-node--reaktor--turbinen)
6. [Startsequenz](#6-startsequenz)
7. [Update-System](#7-update-system)
8. [Peripheral-Erkennung](#8-peripheral-erkennung)
9. [Offene technische Prüfpunkte](#9-offene-technische-prüfpunkte)

---

## 1. Systemüberblick

Ein MASTER-Computer koordiniert alle Nodes. Nodes melden ihren Status, der Master berechnet Sollwerte und sendet sie zurück. Hardware-Steuerung bleibt strikt lokal auf der Node, die die Peripherie besitzt.

```text
┌──────────────────────────────────────────────────────┐
│                       MASTER                         │
│  UI · Alerts · Telemetry · Setpoints · Profiles      │
└──────┬───────────────────────────┬───────────────────┘
       │ Ender Modem ch 6500/6501 │
  ┌────▼────┐  ┌────────┐  ┌──────▼──────┐  ┌─────┐
  │   RT    │  │ ENERGY │  │ WATER/FUEL/ │  │ LOG │
  │Reactor  │  │Matrix  │  │REPROCESSING │  │     │
  │Turbines │  │Storage │  │ Support     │  │     │
  └─────────┘  └────────┘  └─────────────┘  └─────┘
```

---

## 2. SCADA-Designprinzip

**Master kennt das Ziel. Nodes kennen den Weg.**

- Master sendet nur `power_target_percent` und einen Zustandsintent.
- RT-Node berechnet autonom: Turbinenzustände, Flow, Induktor-Timing und Reaktor-Stab-Position.
- Master muss keine individuellen Turbinen-RPM oder Flow-Werte steuern.

Dies entspricht dem SCADA-Prinzip: zentrales Monitoring und Sollwertvorgabe, dezentrale Ausführung.

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
| `STATUS` | periodischer Status-Payload |
| `HEARTBEAT` | kurzer Lebens-/State-Puls |
| `SET_SETPOINTS` | Master sendet Sollwerte an RT-Node |
| `SET_MODE` | Master sendet State-Transition |
| `REMOTE_UPDATE` | Update-Befehl über das Netzwerk |
| `ACK` / `ACK_APPLIED` | Node bestätigt empfangenes oder angewendetes Command |

---

## 4. MASTER Node

### Leistungsschätzung

Priorität für `power_target`:

1. `measured_total` — Summe der tatsächlichen RT-Outputs.
2. `learned_capacity_total` — Summe gelernter RT-Kapazitäten.
3. `power_target` vom letzten Tick als Kontinuität.
4. Kein generischer 3000-RF/t-Fallback mehr.

### Multi-Node-Zuweisung

Aktueller `rt_sync.lua`-Ansatz:

```text
1. Nodes nach Kapazität sortieren.
2. Zählen, wie viele Nodes für global_target benötigt werden.
3. uniform_pct = global_target / Summe(benötigte Kapazitäten) × 100.
4. Nur benötigte Nodes werden aktiv zugeteilt.
```

### Setpoint-Paket Master → RT

Gesendet werden nur funktionale Felder:

| Feld | Typ | Bedeutung |
|------|-----|-----------|
| `power_target_percent` | number 0–100 | Prozent der gelernten Node-Kapazität |
| `assignment_state` | string | `active`, `shed`, `shutdown`, `standby` |
| `shutdown_stage` | string/nil | Shutdown-/Rampdown-Intent |
| `desired_node_state` | string/nil | gewünschter Node-State |

Der aktuelle Code sendet Setpoints sichtbar wieder über `M.send_rt_setpoints(...)`. Das alte Log-Problem `RT setpoints deduped ... ACK_MATCH` ist im aktuellen `rt_sync.lua` nicht mehr sichtbar, muss aber später ingame/logbasiert erneut geprüft werden.

---

## 5. RT Node — Reaktor & Turbinen

### Modulstruktur

| Datei | Verantwortlichkeit |
|-------|-------------------|
| `nodes/rt/main.lua` | Boot, Service-Wiring, ctx-Assembly |
| `nodes/rt/reactor_control.lua` | Rod-Steuerung, Steam-Margin-Regler |
| `nodes/rt/turbine_control.lua` | Flow, Induktor, Overspeed, Rotation |
| `nodes/rt/capacity_learning.lua` | kontinuierliche Kapazitätsmessung |
| `nodes/rt/status_snapshot.lua` | Status-Payload für Master |
| `nodes/rt/state_handlers.lua` | State-Machine |
| `nodes/rt/command_handler.lua` | Commands, Setpoints, Update-Command |
| `nodes/rt/module_lifecycle.lua` | SCRAM, Safe-Controls, Startup |
| `nodes/rt/monitor_ui.lua` | lokales Display |

### Offener RT-Codeblocker

In `nodes/rt/main.lua` fehlt ein Komma in der `monitor_ui.update(...)` Parameter-Tabelle:

```lua
build_health_payload = function() return build_status_payload() end
read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
```

Korrekt wäre:

```lua
build_health_payload = function() return build_status_payload() end,
read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
```

Dieser Punkt wurde bewusst nicht gepatcht und bleibt offen.

### Capacity Learning

```text
ready = false  → Master weist 0 Prozent zu
ready = true   → Master kann proportionalen Load zuweisen
```

- Misst kontinuierlich bei 900 RPM.
- Mindestens 80 Prozent der Turbinen müssen am Ziel sein.
- Höhere Werte werden übernommen, niedrigere ignoriert.
- Ergebnis wird über `capacity_cache.lua` persistiert.

---

## 6. Startsequenz

Aktuelle `xreactor/start.lua`:

- liest `/xreactor/config/role.lua`
- ermittelt den Entrypoint je Rolle
- startet optional parallel einen Auto-Update-Loop über `installer/auto_update.lua`
- startet dann die Rollen-Datei per `dofile(entry)`

Startverzögerungen:

```text
LOG/LOG_COLLECTOR  → 0s
MASTER             → 2s
Alle anderen Nodes → 8s
```

Wichtig: Der frühere Startup-Self-Heal für den RT-Kommafehler ist aktuell nicht sichtbar vorhanden.

---

## 7. Update-System

Der Stand enthält ein Update-/Auto-Update-System mit:

- Auto-Update-Loop aus `installer/auto_update.lua`
- Versionsvergleich gegen den aktuellen Branch-Stand
- Installer-Neulauf mit Rollenerhalt
- Remote-Update-Schutz über lokale Freigabe
- robustere Downloads mit SHA-Pin/Fallback/Retry/HTML-Prüfung

Offener Prüfpunkt: Im Command-Pfad sollte geprüft werden, ob Optionen aus `handle_command(opts)` auch an `M.run(...)` weitergereicht werden müssen, besonders wenn Token-basierte Freigabe genutzt wird.

---

## 8. Peripheral-Erkennung

Erkennung erfolgt über `peripheral.getType()` und Adapter:

```lua
type:find("turbine") → turbine
type:find("reactor") → reactor
```

Genutzte ER2 Turbine API:

- `getRotorSpeed()`
- `setFluidFlowRateMax(rate)`
- `setInductorEngaged(bool)`
- `getFluidFlowRateMaxMax()`
- `getEnergyProducedLastTick()`

Genutzte ER2 Reaktor API:

- `setActive(bool)`
- `setAllControlRodLevels(level)`
- `setControlRodLevel(...)` Fallbacks
- `getHotFluidAmount()`
- `getHotFluidAmountMax()`
- `getFuelTemperature()`

---

## 9. Offene technische Prüfpunkte

**Stand 2026-07-01: Alle Punkte behoben (v240-v242).**

1. ✓ RT-Kommafehler in `nodes/rt/main.lua` — behoben in v237/v241.
2. ✓ RT-Monitor-Buildwerte — jetzt dynamisch aus `release.lua` geladen (v241).
3. ✓ `hash_algo` vereinheitlicht — CRC32 wiederhergestellt, alle 143 Einträge regeneriert (v240).
4. ✓ Manifest-Metadaten aktuell — vollständig regeneriert via `tools/regenerate_manifest_metadata.py` (v240).
5. ✓ Remote-Update-Optionsweitergabe — `handle_command()` reicht jetzt `opts` (inkl. Token) an `M.run()` weiter (v242).
6. ✓ Statische Lua-Prüfung — 147 Dateien geprüft, keine offensichtlichen Parse-Fehler gefunden (v241).
