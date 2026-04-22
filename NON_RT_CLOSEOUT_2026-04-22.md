# Non-RT Closeout Audit — 2026-04-22

## Scope and hard boundaries
- Audit scope is **non-RT only** (MASTER, ENERGY, WATER/FUEL/REPROCESSOR, installer, shared non-RT services).
- `xreactor/nodes/rt/**` was intentionally not modified.
- No new architecture wave/refactor was performed; only closeout validation and documentation.

## Architecture audit (non-RT)

### 1) Payload -> UI model -> rendering path
- ENERGY keeps the intended layering:
  - payload builder runtime (`nodes/energy/status_payload.lua`),
  - UI model runtime (`nodes/energy/ui_model.lua`),
  - rendering pages (`nodes/energy/ui_pages.lua`),
  - integrated by `nodes/energy/main.lua`.
- This preserves rendering decoupled from direct heavy discovery reads.

### 2) Direct registry/comms/peripheral access in render path
- ENERGY render path uses prebuilt model snapshots via `build_ui_model(...)` and delegates painting to `ui_pages`.
- Heavy discovery / peripheral sampling remains in runtime/service paths and cached payload/model builders.

### 3) Modular main-flow ownership (MASTER/ENERGY/installer)
- MASTER main flow remains modularized through `runtime_context`, `startup_sequencer`, `message_handlers`, and `ui_controller`.
- Installer external entry remains compatible (`installer` -> `xreactor/installer_main.lua`) while internals stay modularized.

### 4) Shared support runtime usage (WATER/FUEL/REPROCESSOR)
- All three support nodes use shared support discovery/runtime helpers (`nodes/support/*`) and keep role-specific domain logic local.
- Shared discovery classification (`collect_devices_by_methods`) is actively used in water/fuel/reprocessor.

### 5) Dead/duplicate/intermediate structures
- No mandatory cleanup blocker found in non-RT paths during this closeout pass.
- Remaining optional cleanups are cosmetic and do not block roadmap completion.

## Integration and regression run

### Acceptance target suite (executed)
- `python3 tests/support_nodes_shared_runtime_regression_test.py` ✅
- `python3 tests/energy_scope_regression_test.py` ✅
- `python3 tests/energy_heartbeat_decoupling_regression_test.py` ✅
- `python3 tests/energy_persistent_topology_regression_test.py` ✅
- `python3 tests/cc_parse_guard_test.py` ✅
- `python3 tests/rt_main_parse_guard_test.py` ✅

### Additional formal signoff checks (executed)
- Full Python guard sweep (excluding RT-size-track guard):
  - `python3 tests/cc_parse_guard_test.py` ✅
  - `python3 tests/energy_heartbeat_decoupling_regression_test.py` ✅
  - `python3 tests/energy_persistent_topology_regression_test.py` ✅
  - `python3 tests/energy_scope_regression_test.py` ✅
  - `python3 tests/rt_main_parse_guard_test.py` ✅
  - `python3 tests/support_nodes_shared_runtime_regression_test.py` ✅
  - `tests/rt_main_structure_guard_test.py` intentionally skipped (separate RT-audit track).
- `pytest -q tests/*.py` executed for transparency and aborts during collection because `tests/rt_main_structure_guard_test.py` raises `SystemExit` by design on RT-size policy.
- Lua runtime availability check executed; no `lua`/`luajit` binary in this environment, so `.lua` suites could not be executed in this signoff run.

### Architecture consistency spot checks (executed)
- Non-RT `main.lua` footprint check executed (`xreactor/master/main.lua`, `xreactor/nodes/energy/main.lua`, `xreactor/nodes/water/main.lua`, `xreactor/nodes/fuel/main.lua`, `xreactor/nodes/reprocessor/main.lua`) to ensure there is no forced/artificial split wave.
- Support-layer usage check re-verified in `water`/`fuel`/`reprocessor` (`nodes/support/runtime.lua`, `nodes/support/discovery.lua`, `collect_devices_by_methods` path present in all three role mains).

## Excluded from this closeout (intentional)
- RT refactor, RT state-machine behavior changes, RT safety behavior changes, or any file changes under `xreactor/nodes/rt/**`.
- `tests/rt_main_structure_guard_test.py` as non-RT acceptance criterion (kept in separate RT audit track).

## Final decision

**Non-RT roadmap status: JA (abgeschlossen).**

The non-RT architecture goals are met on this repo state, with acceptance gates passing for support-runtime, ENERGY decoupling/heartbeat/topology stability, and parse/load guards. Remaining work is optional polish or RT-track backlog, not a non-RT completion blocker.
