# Session Handoff — XReactor Controller V3

> Letzte Aktualisierung: **beta-v133**  
> Branch: `beta` — Repo: `ItIsYe/ExtreamReactor-Controller-V3`  
> Dieses Dokument fasst den aktuellen Stand zusammen und dient als Einstiegspunkt für neue Chat-Sessions.

---

## Aktueller Stand

- **Manifest-Version:** v133
- **Dateien:** 131 Lua-Dateien
- **Working Tree:** sauber, alles committed
- **ATM10 / MC 1.21.1 / Extreme Reactors 2 / CC:Tweaked**

---

## Was in dieser Entwicklungsphase passiert ist

### RT-Node Komplett-Rewrite (SCADA-Architektur)
Die `nodes/rt/main.lua` wurde von 2350 Zeilen auf ~750 Zeilen reduziert. Fachlogik lebt jetzt in separaten Modulen mit expliziten `ctx`-Parametern statt versteckter Closures:

| Modul | Verantwortlichkeit |
|-------|-------------------|
| `reactor_control.lua` | Rod-Steuerung, Steam-Margin-Regler |
| `turbine_control.lua` | Flow, Induktor, Overspeed, Rotation |
| `capacity_learning.lua` | Eigenständiges Learning-Modul |
| `status_snapshot.lua` | Status-Payload für Master |

### Setpoint-Schema (vereinfacht)
Master sendet jetzt nur noch 4 Felder statt 12:
- `power_target_percent` — der einzige steuerungsrelevante Wert
- `assignment_state` — active/shed/shutdown/standby
- `shutdown_stage` — REQUEST_OFF / RAMPDOWN
- `desired_node_state` — RUNNING / LIMITED / OFF

Entfernt: `target_rpm`, `steam_target`, `power_target`, `enable_reactors`, `enable_turbines`, `assignment_reason`, `assignment_source`, `assignment_rank`, `controllable`

### 3-Zustands-Teillast-Modell
Turbinen kennen drei Zustände: Vollast (900 RPM), Puffer (fraction × 900 RPM), AUS (0). Bei 50 % mit 25 Turbinen: 12 × 900 RPM + 1 × 450 RPM + 12 × 0 RPM = exakt 50 %.

### Proportionale Multi-Node-Zuweisung
Statt Greedy (erste Node voll, zweite bekommt Rest) verteilt der Master gleichmäßig: alle aktiven Nodes bekommen denselben Prozentsatz. Kein capacity-Fallback mehr.

### Remote-Update Fix (Deferred)
`REMOTE_UPDATE` Command setzt jetzt nur ein Flag und gibt sofort zurück. Der eigentliche `http.get()` läuft im Hauptthread nach dem aktuellen Event-Zyklus. Das behebt den Blocking-Bug: CC:Tweaked kann `http_success` Events nicht empfangen wenn bereits in einem `modem_message`-Handler.

### Startsequenz
LOG → 0s, MASTER → 2s, NODES → 8s. War vorher flach (alle 5s Delay).

---

## Bekannte offene Punkte

- `enable_reactors` / `enable_turbines` in `ctx.targets`: werden empfangen und gespeichert, aber nicht ausgewertet. State-Machine übernimmt das. Kein Bug, bewusst.
- Keine automatischen Tests mehr (pytest entfernt — Lua in Python nicht vollständig simulierbar für CC:Tweaked-Code).

---

## Wichtige Konfigurationswerte

| Wert | Default | Beschreibung |
|------|---------|-------------|
| `TARGET_RPM` | 900 | Ziel-RPM für alle Turbinen |
| `RECEIVE_TIMEOUT` | 0.5s | Event-Loop Timeout |
| `INITIAL_ROD_LEVEL` | 100 % | Stäbe beim Boot vollständig eingefahren |
| Capacity-Learning Min-Fraction | 80 % | Mindestanteil Turbinen am Ziel |
| Modem Control | 6500 | Master → Nodes |
| Modem Status | 6501 | Nodes → Master |
| Modem Log | 6502 | alle → LOG |

---

## Repo-Struktur (relevante Pfade)

```
xreactor/
  nodes/rt/
    main.lua               Boot + Service-Wiring (~750Z)
    reactor_control.lua    Rod-Steuerung (~540Z)
    turbine_control.lua    Turbinen-Regelung (~930Z)
    capacity_learning.lua  Eigenständiges Learning (~110Z)
    status_snapshot.lua    Status-Payload (~160Z)
    state_handlers.lua     State-Machine (~270Z)
    command_handler.lua    SET_SETPOINTS, REMOTE_UPDATE (~285Z)
    module_lifecycle.lua   SCRAM, Safe-Controls (~625Z)
    monitor_ui.lua         Lokales Display (~610Z)
  master/
    rt_sync.lua            Proportionale Zuweisung + Setpoint-Bau
    runtime_ops_profile.lua  Leistungsschätzung (kein Fallback)
  core/
    remote_update.lua      Deferred Remote-Installer
  adapters/
    reactor.lua            ER2 Reaktor-Adapter (4-stufiger Rod-Fallback)
    turbine.lua            ER2 Turbinen-Adapter
  manifest.lua             v133, 131 Dateien
  release.lua              beta-v133
```

---

## Zugang

GitHub-Token für beta branch (write access) — wird nicht in der Doku gespeichert.
