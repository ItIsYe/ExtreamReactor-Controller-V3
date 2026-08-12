# CI-Wartungshandbuch

## Monatliche Aufgaben

### Skip-Liste prüfen
```bash
# Aktuellen Stand anzeigen
cat tests/known_failing_lua_tests.txt | grep -c STALE_STRUCTURE
cat tests/known_failing_lua_tests.txt | grep -c STALE_API
cat tests/known_failing_lua_tests.txt | grep -c NEEDS_MOCK
# Budget prüfen
cat tests/skip_budget.txt
```

STALE_STRUCTURE: Gegen aktuellen Code testen, ggf. reaktivieren.
STALE_API: Bei Modpack-Update (Extreme Reactors 2 API) prüfen.
NEEDS_MOCK: Wenn Hardware-Mocks hinzugefügt werden, reaktivieren.

### Externe API-Fixtures erneuern
Bei Modpack-Update die STALE_API Tests mit neuer API testen:
```
tests/*_regression_test.lua  →  gegen neue ER2-API prüfen
```

### Simulator gegen neue In-game-Traces vergleichen
1. `xreactor/trace/recorder.lua` im laufenden CC:Tweaked-Node aktivieren
2. Trace speichern als `tests/sim/fixtures/<node>_<datum>.lua`
3. `tests/sim_fixture_replay_test.lua` mit neuer Fixture ausführen

## Action-SHA-Aktualisierung
Alle `uses:` Einträge in `.github/workflows/` auf aktuelle Commit-SHAs prüfen:
- `actions/checkout`
- `actions/setup-python`

## Skip-Budget Grenzwerte

| Kategorie     | Aktuell | Ziel |
|---------------|---------|------|
| STALE_STRUCTURE | 0     | 0    |
| STALE_API       | 13    | ≤10  |
| NEEDS_MOCK      | 12    | ≤10  |
| Budget gesamt   | /48   | /40  |

## Workflow-Übersicht

| Workflow              | Trigger        | Jobs                              |
|-----------------------|----------------|-----------------------------------|
| offline-tests.yml     | push/PR beta   | syntax, manifest, skip, unit, sim |
| deployment-gate.yml   | push main/rel  | manifest-gate, promotion, rollback|
| nightly.yml           | 02:00 UTC tägl | full-sim, manifest-check          |

---

## Session August 2026 — Monitor-Flackern & CI-Bereinigung

### Deployments
- **beta-v499/v500** (PR #499, gemergt): zwei Fixes
  - `core/ui_router.lua`: `setVisible(false/true)` Double-Buffering vor/nach Render — verhindert Monitor-Flackern beim Neuzeichnen
  - `core/monitor_manager.lua`: zu-kleiner Monitor nur einmal als ERROR loggen statt bei jedem Scan-Zyklus

### Root Cause Monitor-Flackern (FUEL-Node Computer 64)
`node-57` (ENERGY-Node) geht alle ~30s kurz als `Peer down` (Wireless Modem sendet auf 4 Kanälen → kurze Lücken). Snapshot ändert sich → `ui_service` triggert Render → Pixel werden nacheinander geschrieben → sichtbar schwarz. Fix: `setVisible(false)` puffert alle Änderungen, `setVisible(true)` macht sie atomar sichtbar.

### CI-Bugs behoben
| Problem | Fix |
|---|---|
| `manifest_sync.py --check` unbekannt | `--check` Argument hinzugefügt |
| `verify_remote_manifest.py --base-url` required | optional gemacht; `--ref`/`--repo`/`--report` registriert |
| Python-Tests: `real parse unavailable` | `lua5.2` im Python-Tests CI-Job installiert |
| `upload-artifact` veralteter Commit-Hash | auf `@v4` (stabiler Alias) aktualisiert |
| `always=true` Duplikate im Manifest | normalisiert auf `always = true`, Hashes neu berechnet |

### Offene Punkte (nicht codeseitig lösbar)
- `monitor_45` am MASTER zu klein → im Spiel größer bauen oder entfernen
- node-57 Peer-down-Ursache: Wireless Modem auf 4 Kanälen → strukturelles Netzwerkproblem
- node-56 Heartbeat-Delay → Server-Lag
- VALVE-Nodes node-70/74 gelegentliche Aussetzer → Verbindungsinstabilität
