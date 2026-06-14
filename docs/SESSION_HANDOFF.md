# Session Handoff — XReactor Controller V3

> Letzte Aktualisierung: **beta-v45**  
> Branch: `beta` — Repo: `ItIsYe/ExtreamReactor-Controller-V3`  
> Dieses Dokument fasst den aktuellen Stand zusammen und dient als Einstiegspunkt für neue Chat-Sessions oder andere KI-Assistenten.

---

## Aktueller Stand

- **Manifest-Version:** v45
- **Alle Tests grün:** 18/18 pytest + alle Skript-Guards
- **126 Lua-Dateien:** syntaktisch korrekt (lua5.2)
- **Working Tree:** sauber, alles committed und gepusht

---

## Was zuletzt gemacht wurde (diese Session)

### Turbinen-Regelung — kompletter Umbau

Das gesamte Turbinen-Regelungsmodell wurde von Grund auf neu gestaltet:

**Kernprinzip:** 900 RPM ist das Effizienzoptimum für ER2-Turbinen. Der Coil (Generator) engagiert sich erst bei ≥ 900 RPM — darunter kein Strom. Daher:
- Jede laufende Turbine läuft **immer bei 900 RPM**
- Leistungsreduzierung = **weniger Turbinen**, nicht langsamere Turbinen
- Der Regelkreis ist für **jede Turbine immer aktiv**, ohne State-Ausnahmen

**Coil-Schwellwerte:** Einschalten bei ≥ 900 RPM, Ausschalten bei < 850 RPM, Hysterese 850–900.

**Automatische Turbinen-Anzahl-Steuerung (`get_turbine_target_rpm`):**
```
active_count = round(Anzahl_Turbinen × power_percent / 100)
Turbine index ≤ active_count → Ziel 900 RPM (Coil engagiert)
Turbine index >  active_count → Ziel 0 RPM   (Coil trennt sich bei < 850)
```

### Kritische Bugfixes (aus Log-Analyse)

| Fix | Commit | Problem |
|-----|--------|---------|
| RT CONTROL crash bei SET_MODE MASTER | `5d598ad` (v37) | `runtime_ctx` als Global (nil) — forward-declaration bei Zeile 49 fehlte |
| Learning nie abgeschlossen — Deadlock | `de260f3` (v38) | 20/25 Turbinen übersprungen (STATE_OFF) da MASTER keine Setpoints schickte |
| STARTING-Turbinen unkontrolliert | `8ca03c6` (v39) | `should_regulate_module_state` blockierte STARTING → 23 Turbinen ohne Flow |
| Overspeed-Brake Deadlock | `406964e` (v45) | target=0 → threshold=20 RPM → alle Turbinen permanent in OVERSPEED_BRAKE, repeat_count=1490 |
| Logger schreibt nie auf Disk | `dd978fe` (v35) | `disk_write_test` nutzte `pcall(fn())` — Lua ignoriert innere Return-Werte |
| RT crasht beim Registry-Save | `eaac123` (v36) | `utils.write_config` warf `error()` → Crash |
| MASTER startet nicht | `0c1fd20` | `colors.black` als Global in Bootstrap-Kontext nicht verfügbar |
| ENERGY/RT/MASTER: ui_pages fehlt | `cf5170c` (v34) | `nodes/support/ui_pages.lua` nicht im Manifest für diese Rollen |
| Router-Dateien nie installiert | `1257066` (v32) | 3 Router-Dateien fehlten im Manifest → Installer lud sie nie |
| node-54 ständig offline | `7ff36ae` (v33) | node_id vom Computer-Label abgeleitet → Netzwerk-ID-Kollision |
| turbine_index nie initialisiert | `28b1d07` (v44) | `get_turbine_target_rpm(nil)` → Turbinen-Anzahl-Steuerung hatte keinen Effekt |

### Features (diese Session)

- **Log-Modus-Buttons** auf allen Nodes: `[All][Disk][Rmt][Term][Off]` — Monitor + PC-Terminal
- **PC-Console-Fallback** für alle Nodes ohne externen Monitor
- **Redstone-Router** für REPROCESSING Node (identisch zu FUEL)
- **Automatische Turbinen-Anzahl-Steuerung** via `power_percent` (v43–v45)
- **RT UI-Timer** unabhängig vom Control-Tick (kein Einfrieren mehr)
- **LOG_COLLECTOR** Disk-Ring mit Wipe-on-Wraparound
- **Startup-Delay** 5s für alle Nodes außer LOG/MASTER
- **Retry-Intervall** 4s→30s, MAX_SENDS 6→3 (Log-Duplikate reduziert)
- **Matrix-Budget** 800ms→2000ms (ENERGY)
- Komplette **Projektdokumentation** unter `docs/PROJECT_DOCUMENTATION.md`

---

## Architektur-Überblick

```
Nodes kommunizieren über Ender-Modeme:
  Kanal 6500: MASTER → Nodes (Commands, Setpoints)
  Kanal 6501: Nodes → MASTER (Telemetrie, Heartbeat)
  Kanal 6502: Alle → LOG (Log-Events, ACK)

Sicherheitsprinzip: MASTER schickt nur Sollwerte.
Jeder RT-Node trifft lokale Entscheidungen und schreibt direkt auf seine Hardware.
```

### Wichtige Dateien

| Datei | Zweck |
|-------|-------|
| `xreactor/nodes/rt/main.lua` | RT-Node Hauptschleife, Turbinen-Regelkreis, Capacity-Learning |
| `xreactor/nodes/rt/config.lua` | RT-Defaults (TARGET_RPM=900, COIL_ENGAGE=900, COIL_DISENGAGE=850) |
| `xreactor/core/turbine_regulator.lua` | Turbinen-Regellogik, Overspeed-Brake |
| `xreactor/core/utils.lua` | Log-Modi, node_id, write_config, Retry-Konfiguration |
| `xreactor/core/logger.lua` | Disk-Logger (kein error() mehr, disk_write_test gefixt) |
| `xreactor/core/network.lua` | node_id-Auflösung (niemals vom Label) |
| `xreactor/manifest.lua` | Dateiliste v45, 125 Einträge, CRC32-Hashes |
| `xreactor/nodes/support/ui_pages.lua` | Log-Modus-Buttons (CC-Farb-Zahlen, kein colors-Global) |
| `docs/PROJECT_DOCUMENTATION.md` | Vollständige deutsche Projektdokumentation |

---

## Offene Punkte / nächste Schritte

### Ingame-Aktionen nötig

- **Alle Nodes `installer` ausführen** → v45 installieren
- Besonders **node-55** hat noch alten Code (vor v41) → STATE_OFF/STATE_STARTING Skip-Bug aktiv
- **node-54:** `/xreactor/config/node_id.txt` löschen + reboot (falls noch `XR-RT-54` drin)

### Noch nicht implementiert / offen

- **MASTER → RT Turbinen-Assignment:** MASTER kann aktuell über `power_percent` die Anzahl aktiver Turbinen steuern (automatisch nach Index). Eine explizite Zuweisung (welche spezifischen Turbinen laufen) ist über `assignment_state` / STARTUP_STAGE-Commands möglich aber noch nicht vollständig verdrahtet.
- **Feiner Leistungsbereich:** Bei 25 Turbinen gibt es nur 26 diskrete Stufen (0%, 4%, 8%, ..., 100%). Zwischen-Stufen nicht möglich ohne RPM-Skalierung (die aber bei < 900 RPM keinen Strom erzeugt).
- **node-54 Status** nach node_id-Fix im ingame-Test verifizieren.

---

## Entwicklungsumgebung

```
Arbeitsverzeichnis: /home/claude/xreactor_review (in dieser Sandbox)
Tests ausführen:    python3 -m pytest tests/ -q
Manifest-Update:    python3 tools/regenerate_manifest_metadata.py
CI-Validator:       lua5.2 tools/offline_validate.lua
```

### Commit-Workflow

```sh
# 1. Änderungen machen
# 2. Manifest aktualisieren
python3 tools/regenerate_manifest_metadata.py
# 3. Version bumpen (in manifest.lua und release.lua)
# 4. Manifest nochmal regenerieren
# 5. Tests
python3 -m pytest tests/ -q
# 6. Commit + Push
```

---

## Turbinen-Regelkreis im Detail (für neue Sessions)

Das ist der kritischste und komplexeste Teil des Systems.

### Datenfluss

```
MASTER → SET_SETPOINTS (power_percent, target_rpm)
  ↓
RT command_handler.lua → runtime_ctx.targets.power_percent setzen
  ↓
updateControl() [jeder Tick, für jede Turbine]:
  get_turbine_target_rpm(turbine_index):
    - cap_locked=false (Learning) → immer 900
    - state != MASTER → immer 900
    - active_count = round(25 * pct/100)
    - index <= active_count → 900
    - index >  active_count → 0
  apply_turbine_flow(name, turbine, caps, rpm, effective_target)
    ↓
    overspeed_brake_state():
      target=0 → return false (kein Brake) ← v45-Fix
      rpm > target+20 → Brake aktiv → flow=0
    update_turbine_flow_state(rpm, target_rpm, ctrl)
      → PID-ähnliche Regelung → requested_flow
    setTurbineFlow(turbine, caps, requested_flow)
  ↓
  update_inductor_for_rpm(rpm, coil_config, ctrl):
    rpm >= 900 → Coil AN
    rpm <  850 → Coil AUS
    850–899    → Zustand halten
```

### Capacity Learning

```
Boot → load_capacity_cache() → wenn vorhanden: LOCKED (kein Re-Learning)
     → sonst: LEARNING_PHASE
  Reaktor: applyReactorRods(50, allow_overmax=true)  ← bypassed regulator_min_rods!
  Steam_Margin-Regler: pausiert während Learning
  Alle Turbinen: Ziel 900 RPM (cap_locked=false Guard in get_turbine_target_rpm)
  3 stable samples mit sample_output > 0 → LOCKED
  save_capacity_cache() → /xreactor/config/capacity_cache.lua
  Turbinen-Anzahl-Check: wenn turbine_count sich ändert → Cache invalidiert
```

### Was getan werden muss wenn etwas mit Turbinen nicht stimmt

1. `TurbineTick decisions=0 skipped=N`: Turbinen werden übersprungen
   - Prüfe `skip_reasons` — STATE_OFF/STATE_STARTING: **alter Code, installer ausführen**
   - WRAP_FAILED: Peripherals nicht gefunden
   - FLOW_SET_SKIPPED: Turbine braucht keine Änderung (normal)

2. `OVERSPEED_BRAKE repeat_count=high` bei niedrigem RPM:
   - target_rpm=0 mit Overspeed-Brake = v45-Bug (behoben)
   - Falls noch aktiv: installer ausführen

3. Learning schlägt fehl / `CapacityLearning WAITING`:
   - Prüfe ob Reaktor läuft (Stäbe auf 50% → Dampf vorhanden?)
   - Prüfe ob Turbinen überhaupt Energie produzieren (`sample_output > 0`)
   - capacity_cache.lua löschen und reboot

---

## Bekannte Einschränkungen

- **Log-Duplikate ~30–40%** trotz Retry=30s. Bei 2×25 Turbinen auf einem Kanal unvermeidlich. Duplikate sind harmlos (Deduplizierung aktiv).
- **Integer-Leistungsstufen** bei 25 Turbinen: 26 diskrete Stufen (0, 4, 8, ..., 100%).
- **node-55** läuft noch alten Code (vor v41) → `installer` nötig.
