# XReactor Controller V3 — Projektdokumentation

> Letzte Aktualisierung: beta-v261
> Stack: CC:Tweaked · Extreme Reactors 2 · Mekanism · ATM10 (MC 1.21.1)

---

## Aktueller Status

Stand: `beta` / `manifest-v261` / `beta-v261`.

Keine bekannten offenen Blocker zum Zeitpunkt dieser Aktualisierung. Details zur vollständigen Fix-Historie stehen in `docs/NODE_START_BLOCKERS_2026-06-25.md` und `RUNTIME_STATUS_2026-06-03.md` (Repo-Root).

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
| 6503 | alle → LOG | Log-Zeilen |

> War lange Zeit `6502` im Sendercode (`core/remote_log.lua`), während `shared/constants.lua` bereits `6503` definierte — ein realer Kanal-Mismatch, der den LOG-Collector nichts empfangen ließ. Fixed 2026-06-30.

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

Priorität für `power_target` (`estimate_base_power()` in `runtime_ops_profile.lua`):

1. `learned_capacity_total` — Summe gelernter RT-Maximalkapazitäten. **Hat Vorrang**, seit 2026-06-30/07-01 gefixt.
2. `measured_total` — Summe der tatsächlichen, aktuell gemessenen RT-Outputs. Nur Fallback, wenn noch keine Node `capacity_ready` meldet.
3. `power_target` vom letzten Tick als Kontinuität.
4. Kein generischer 3000-RF/t-Fallback.

> Vorher war die Reihenfolge umgekehrt (`measured_total` zuerst) — das führte dazu, dass `power_target` beim Wechsel auf das PEAK-Profil auf dem aktuell gemessenen (ggf. durch das vorherige, niedrigere Profil gedrosselten) Output einfror, statt zur echten gelernten Maximalkapazität zu wachsen. Zusätzlich zieht `sample_trends()` alle ~30s nach, falls die gelernte Kapazität deutlich (>5%) über dem aktuellen `power_target` liegt — verhindert dauerhaftes Einfrieren auch ohne erneuten Profilwechsel.

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

Der Master persistiert jetzt zusätzlich `assigned_power`/`assigned_percent` direkt auf das Node-Objekt (`rt_sync.lua`) — vorher blieben diese berechneten Werte nur lokal in einer temporären Struktur und wurden verworfen, was dazu führte, dass die Master-UI dauerhaft `Soll 0.0` für jeden RT-Node zeigte, obwohl der globale Sollwert korrekt war. Fixed 2026-07-01.

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

### RT-Monitor: Ampel-Statusmonitor (neu, 2026-07-01)

Ein optionaler zweiter Monitor, exakt 1×3 groß (Wired Modem), wird automatisch erkannt und zeigt eine reine Statusfarbe ohne Text (grün/gelb/orange/rot/grau je nach Betriebszustand). Vollständig `pcall`-isoliert — kann den Hauptmonitor bei einem internen Fehler nicht mehr beeinflussen.

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

## 9. Historie behobener technischer Punkte

Chronologisch, älteste zuerst. Vollständige Details in `RUNTIME_STATUS_2026-06-03.md` (Repo-Root).

**Stand v240–v242 (2026-07-01):**
1. RT-Kommafehler in `nodes/rt/main.lua` — behoben.
2. RT-Monitor-Buildwerte — dynamisch aus `release.lua` geladen statt hartkodiert.
3. `hash_algo` vereinheitlicht (CRC32), Manifest-Metadaten regeneriert.
4. Remote-Update-Optionsweitergabe (`handle_command()` reicht `opts` inkl. Token an `M.run()` weiter).
5. Statische Lua-Prüfung über alle Dateien.

**Stand v220–v235 (2026-06-30):**
6. Installer/Auto-Updater: `shell.run()` → `dofile()` in `auto_update.lua`/`start.lua` (nicht verfügbar in `parallel`-Coroutinen).
7. `resolve_sha()` (api.github.com-Call) aus dem Auto-Update-Check-Pfad entfernt — verursachte Hänger auf RT.
8. `role.lua`-Erhalt bei Reinstall vereinheitlicht auf beide Installer-Codepfade (manuell + Auto-Update).
9. LOG-Manifest-Vollständigkeit (`files_for_role()`) gefixt — LOG erhielt zuvor nicht alle nötigen Dateien.
10. Log-Transport-Kanal-Mismatch (6502 vs. 6503) gefixt.

**Stand v229–v236 (2026-06-30/07-01):**
11. Setpoint-Fluss (Master → RT): Feld-Reihenfolge-Bug in `populate_rt_status()` behoben (capacity_max/capacity_ready waren immer einen Zyklus veraltet).
12. PEAK-Profil-Berechnung: gelernte Maximalkapazität hat jetzt Vorrang vor aktuell gemessenem Output (siehe Abschnitt 4 oben).
13. `assigned_power`/`assigned_percent` werden jetzt persistent auf das Node-Objekt geschrieben (vorher nur lokal, verworfen — UI zeigte `Soll 0.0`).

**Stand v243–v261 (2026-07-01, UI-Redesign):**
14. `node.rt` wird bei STATUS-Ticks gemergt statt komplett ersetzt (verhinderte Sticky-Bugs bei `assignment_state`/`control_source`).
15. Neues zentrales Badge-Layout-System (`master/ui/layout.lua`) — garantiert keine Badge-Überlappung mehr auf beliebig schmalen Monitoren.
16. Overview-Seite um RT-Fleet-Kurzzusammenfassung erweitert.
17. Doppelte Turbinen-Zeile im RT-Monitor während Capacity-Learning behoben.
18. Neuer optionaler 1×3-Ampel-Statusmonitor (siehe Abschnitt 5).
19. "Overspeed brake pending"-Log-Spam auf 1x/5s pro Turbine begrenzt.
20. Vollständige Manifest-Integritätsprüfung: zwei reale `size_bytes`-Mismatches gefunden und behoben, `manifest_file_count` korrigiert.

Keine bekannten offenen Punkte zum Zeitpunkt dieser Aktualisierung.
