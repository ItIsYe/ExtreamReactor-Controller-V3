# Non-RT Closeout Audit — 2026-04-22 (Formal Signoff Run)

## Scope and hard boundaries
- Audit scope is **non-RT only** (MASTER, ENERGY, WATER/FUEL/REPROCESSOR, installer, shared non-RT services).
- `xreactor/nodes/rt/**` was intentionally not modified.
- No new architecture wave/refactor was performed; this run is a formal audit + validation pass only.

## Architecture audit (non-RT)

### 1) Payload -> UI model -> rendering path
- ENERGY keeps the intended layering and explicit separation:
  - payload runtime: `xreactor/nodes/energy/status_payload.lua`
  - UI model runtime: `xreactor/nodes/energy/ui_model.lua`
  - rendering pages: `xreactor/nodes/energy/ui_pages.lua`
  - orchestrated by `xreactor/nodes/energy/main.lua`
- Render pages consume model snapshots; heavy sampling/discovery stays in runtime/services.

### 2) Main-flow modular ownership
- MASTER entry flow remains routed through modular components (`runtime_context`, `startup_sequencer`, `message_handlers`, `housekeeping`, `ui_controller`, `rt_sync`) via `xreactor/master/main.lua`.
- Installer remains externally compatible (`installer` -> `xreactor/installer_main.lua`) while using modular installer layers (`installer_manifest`, `installer_stage`, `installer_storage`, `installer_startup`, `installer_http`).

### 3) Shared support-node runtime usage
- `xreactor/nodes/water/main.lua`, `xreactor/nodes/fuel/main.lua`, and `xreactor/nodes/reprocessor/main.lua` all use shared discovery helper `collect_devices_by_methods(...)` from support runtime/discovery stack.
- This confirms active reuse of the shared non-RT support infrastructure.

### 4) Direct registry/comms/peripheral access in render path
- No direct peripheral/discovery sampling calls were found in ENERGY rendering pages.
- Registry/comms diagnostics are passed through payload/model layers before render output.

### 5) Parallel old/new architecture paths
- No mandatory non-RT blocker from parallel architecture paths was identified in this audit pass.
- Remaining potential cleanups are optional and not required for formal signoff.

## Integration and regression run (formal)

### Environment note
- `lua5.4` was installed in this run to execute `.lua` test suites.

### Python guard/regression sweep (`tests/*.py`)
- ✅ `tests/cc_parse_guard_test.py`
- ✅ `tests/energy_heartbeat_decoupling_regression_test.py`
- ✅ `tests/energy_persistent_topology_regression_test.py`
- ✅ `tests/energy_scope_regression_test.py`
- ✅ `tests/rt_main_parse_guard_test.py`
- ✅ `tests/support_nodes_shared_runtime_regression_test.py`
- ❌ `tests/rt_main_structure_guard_test.py` (`rt main too large: 2606 lines > 2400`)

### Lua regression sweep (`tests/*.lua` with `lua`)
- **54 passed / 25 failed**.
- Failures observed in both non-RT/shared and RT-track tests.

#### Non-RT/shared-track failures observed
- `tests/alert_rules_numeric_normalization_test.lua`
- `tests/comms_peer_down_observation_debounce_test.lua`
- `tests/comms_peer_state_hysteresis_test.lua`
- `tests/energy_architecture_stability_regression_test.lua`
- `tests/energy_discovery_hot_path_gating_test.lua`
- `tests/energy_matrix_component_logging_regression_test.lua`
- `tests/energy_matrix_payload_cache_regression_test.lua`
- `tests/induction_matrix_component_counts_test.lua`
- `tests/logger_startup_policy_test.lua`
- `tests/manifest_integrity_consistency_test.lua`
- `tests/manifest_role_filter_metadata_test.lua`
- `tests/master_regression_guards_test.lua`
- `tests/network_modem_detection_test.lua`
- `tests/release_metadata_consistency_test.lua`
- `tests/runtime_identity_logging_test.lua`
- `tests/ui_redirect_guard_test.lua`
- `tests/wrapped_peripheral_guard_test.lua`

#### RT-track failures observed (not changed in this run)
- `tests/rt_config_normalizer_steam_guard_test.lua`
- `tests/rt_flow_apply_helpers_readback_lag_regression_test.lua`
- `tests/rt_master_startup_off_state_regression_test.lua`
- `tests/rt_module_lifecycle_control_rod_caps_test.lua`
- `tests/rt_monitor_ui_adapter_snapshot_test.lua`
- `tests/rt_safety_causality_logging_test.lua`
- `tests/rt_turbine_api_warning_regression_test.lua`
- `tests/rt_turbine_flow_range_config_regression_test.lua`

## Minimal changes made in this formal run
- No runtime/logic/module changes were made.
- Only this closeout document was updated to reflect the current formal audit + test evidence.

## Exclusions (intentional)
- No RT code changes.
- No new architecture/refactor wave.
- No cosmetic-only restructuring.

## Final decision

**NICHT-RT-ROADMAP ABGESCHLOSSEN: NEIN**

Reason: formal signoff requires a fully green relevant test/integration state. This run still shows multiple non-RT/shared-stack failing regressions, therefore a hard closeout signoff cannot be issued yet.
