# Session Handoff — XReactor Controller V3

> Letzte Aktualisierung: **beta-v134**  
> Branch: `beta` — Repo: `ItIsYe/ExtreamReactor-Controller-V3`  
> Dieses Dokument fasst den aktuellen Stand zusammen und dient als Einstiegspunkt für neue Chat-Sessions.

---

## Aktueller Stand

- **Manifest-Version:** v134
- **Dateien:** 131 Lua-Dateien
- **Working Tree:** letzte bekannte Änderungen committed
- **ATM10 / MC 1.21.1 / Extreme Reactors 2 / CC:Tweaked**
- **Wichtig:** User hat weiterhin keine dauerhafte Ingame-Installation/Freigabe für riskante Tests gegeben. Repo-/Log-/Diagnosearbeit ist okay; Ingame-Aktionen nur nach expliziter Freigabe.

---

## Letzte Änderung: RT Discovery Diagnostics (2026-06-23)

Aus hochgeladenen Logs (`rt/node-52.log`) ergab sich:

- Keine `ERROR`/`WARN`/Tracebacks.
- Sehr starker DEBUG-Spam durch zu häufigen Control-Tick.
- Discovery meldete dauerhaft: `visible reactors=0 turbines=0 | bound reactors=0 turbines=0`.

Wichtige Diagnose: Leere `reactors = {}` / `turbines = {}` sind **kein Fehler**, sondern aktivieren Auto-Discovery. Das Problem ist erst dann klar, wenn `visible=0`: Dann erkennt die RT-Node gar keine unterstützten Reactor/Turbine-Peripherals.

### Gepatchte Dateien

| Datei | Änderung |
|-------|----------|
| `xreactor/nodes/rt/discovery_runtime.lua` | Wenn 0 Reactor/Turbine sichtbar sind, wird einmal pro geänderter Peripheral-Signatur eine Diagnose geloggt: Anzahl `peripheral.getNames()`, Config-Pfad, sichtbare Peripheral-Namen, Typen und Methodensamples. Keine Änderung an Binding-/Steuerlogik. |
| `xreactor/nodes/rt/binding.lua` | Fehlermeldungen zeigen jetzt den echten RT-Config-Pfad `/xreactor/config/rt.lua` statt des alten/irreführenden Pfads `/xreactor/nodes/rt/config.lua`. |

### Worauf die nächste KI achten soll

Nach dem nächsten Log-Upload bitte nach diesen neuen Zeilen suchen:

```text
RT discovery found zero reactor/turbine peripherals; peripheral_count=...
RT discovery peripheral name=... type=... methods=...
```

Interpretation:

- `peripheral_count=0`: Der RT-Computer sieht gar keine Peripherals. Dann liegt es an Verkabelung/Wired-Modem/Computer-Position.
- `peripheral_count>0`, aber weiter `visible=0`: Peripherals sind sichtbar, aber `binding.detect_kind()` erkennt deren Typ/Methodensignatur nicht. Dann `binding.lua` um die echten Typen/Methoden erweitern.
- `visible>0`, aber `bound=0`: Dann ist Auto-Discovery/Explicit-Config/Binding-Policy zu prüfen.

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
- Aus Logs: Control-Tick spammt bei leerer RT-Node massiv DEBUG (`Reactor control tick`, `TurbineTick evaluated=0...`). Nächster kleiner Fix sollte ein Intervall-Guard für den Control-Service in `nodes/rt/main.lua` sein.
- Prüfen: `state_handlers.lua` nutzt `ctx.allowed_transitions`; sicherstellen, dass RT-State-Context entweder eine Tabelle setzt oder `set_state()` nil-safe ist.
- Prüfen/aufräumen: Falls noch ein doppelter Pfad `xreactor/xreactor/...` im Repo existiert, ist das vermutlich versehentlich und sollte nicht in Install-/Review-Pfade einfließen.

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
| RT Config | `/xreactor/config/rt.lua` | echte Laufzeit-Config der RT-Node |

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
    discovery_runtime.lua  Peripheral-Erkennung + neue zero-visible Diagnose
    binding.lua            Binding-Policy + Geräte-Erkennung
  master/
    rt_sync.lua            Proportionale Zuweisung + Setpoint-Bau
    runtime_ops_profile.lua  Leistungsschätzung (kein Fallback)
  core/
    remote_update.lua      Deferred Remote-Installer
  adapters/
    reactor.lua            ER2 Reaktor-Adapter (4-stufiger Rod-Fallback)
    turbine.lua            ER2 Turbinen-Adapter
  manifest.lua             v134, 131 Dateien
  release.lua              beta-v134
```

---

## Zugang / Arbeitsweise

- Keine Tokens in Chats speichern oder anfordern.
- Bei Connector-Schreibzugriff langsam und atomar arbeiten: Datei lesen, eine kleine Änderung, Commit prüfen.
- Möglichst nicht direkt große Umbauten auf `beta`; User kann aber explizit direkte kleine `beta`-Patches erlauben.
