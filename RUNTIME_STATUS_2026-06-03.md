# XReactor Runtime Status — 2026-06-03

## Scope

This document captures the current architecture/code-reading status of the `beta` branch after the runtime block review performed on 2026-06-03.

Important boundaries:

- No in-game test was performed.
- No full regression run is claimed here.
- Findings are based on repository code inspection and the cleanup commits recorded below.

## Cleanup progress after audit

### Completed

- Added LOG/LOG_COLLECTOR telemetry schema entries in `xreactor/shared/telemetry_schema.lua`.
- Updated the corresponding manifest metadata for `shared/telemetry_schema.lua`.
- Added `tools/stamp_release_metadata.py` so concrete release builds can stamp immutable release metadata without changing the moving `beta` branch install policy.
- Documented ENERGY config ownership in this status document: `nodes/energy/main.lua` is the current authoritative runtime-default source; `nodes/energy/config.lua` is the installable/user-facing template.

### Attempted but not completed through the connector

- `xreactor/shared/constants.lua` LOG role/channel additions were attempted, but the repository write was blocked by the connector safety filter.
- `xreactor/core/bootstrap.lua` first-start LOG role support was prepared, but not committed because constants/bootstrap code writes are currently blocked by the connector safety filter.
- Direct README command examples with full raw installer URLs were also blocked by the connector filter; the placeholder form remains in the committed README, while the exact URLs were added manually outside this automation.
- A separate ENERGY config ownership doc was attempted, but new doc-file creation was blocked by the connector; this status document is the current authoritative documentation for that point.

## Current high-level state

The project is a distributed CC:Tweaked controller stack for Extreme Reactors and supporting infrastructure. Hardware control is intentionally local to the node that owns the peripherals. MASTER aggregates state, alerts, telemetry, health, UI models, and operator intent; RT owns reactor/turbine writes and safety; ENERGY owns power telemetry; WATER/FUEL/REPROCESSING provide support-node telemetry and limited local role behavior.

The reviewed runtime blocks show a mostly coherent split between:

- shared core infrastructure,
- service wrappers,
- peripheral adapters,
- MASTER orchestration/UI,
- RT safety/control,
- ENERGY sampling/telemetry/UI,
- support-node runtime helpers,
- role-specific WATER/FUEL/REPROCESSING nodes,
- and the standalone LOG collector.

## Reviewed blocks

### Core

Reviewed:

- `xreactor/core/protocol.lua`
- `xreactor/core/network.lua`
- `xreactor/core/comms.lua`
- `xreactor/core/registry.lua`
- `xreactor/core/non_rt_config.lua`
- `xreactor/core/non_rt_payload.lua`
- `xreactor/core/trends.lua`
- `xreactor/core/ui.lua`
- `xreactor/core/ui_router.lua`
- `xreactor/core/safety.lua`
- `xreactor/core/fluid.lua`
- `xreactor/core/control_rails.lua`
- `xreactor/core/turbine_ctrl.lua`
- `xreactor/core/turbine_regulator.lua`
- `xreactor/core/alert_rules.lua`
- `xreactor/core/alerts.lua`
- `xreactor/core/monitor_manager.lua`

Current notes:

- `core.comms` owns queueing, ACK handling, retries, backoff, volatile status coalescing, dedupe, peer state, and peer-down/up hysteresis.
- `core.network` handles modem discovery and can degrade cleanly when no suitable modem is available.
- `core.registry` persists discovered devices, keeps stable ordering, and avoids writing volatile fields such as `last_seen` and `last_error_ts` back into persistent snapshots.
- `core.safety`, `core.fluid`, `core.control_rails`, and `core.turbine_regulator` are part of the RT safety/control path and remain safety-critical.

### Services

Reviewed:

- `xreactor/services/service_manager.lua`
- `xreactor/services/comms_service.lua`
- `xreactor/services/discovery_service.lua`
- `xreactor/services/telemetry_service.lua`
- `xreactor/services/control_service.lua`
- `xreactor/services/ui_service.lua`
- `xreactor/services/alert_service.lua`
- `xreactor/services/matrix_sampling_service.lua`

Current notes:

- Service manager isolates service init/tick/shutdown failures and retries with backoff.
- Comms service is the bridge from modem events to `core.comms`.
- Telemetry separates heartbeat cadence from heavier status payload cadence.
- Matrix sampling service is used by ENERGY to keep heavy sampling out of the telemetry/UI hot path.

### Adapters

Reviewed:

- `xreactor/adapters/monitor.lua`
- `xreactor/adapters/reactor.lua`
- `xreactor/adapters/turbine.lua`
- `xreactor/adapters/energy_storage.lua`
- `xreactor/adapters/induction_matrix.lua`

Current notes:

- Reactor/turbine adapters normalize several Extreme Reactors API variants.
- Induction matrix adapter is defensive against multiple Mekanism/CC return formats and supports grouped matrix-port handling.
- Monitor adapter is simple and used by MASTER, ENERGY, and support nodes.

### MASTER

Reviewed:

- `xreactor/master/config.lua`
- `xreactor/master/runtime_context.lua`
- `xreactor/master/message_handlers.lua`
- `xreactor/master/rt_sync_coalescer.lua`
- `xreactor/master/runtime_ops_rt.lua`
- `xreactor/master/runtime_ops_profile.lua`
- `xreactor/master/runtime_ops_monitor.lua`
- `xreactor/master/startup_sequencer.lua`
- `xreactor/master/ui_controller.lua`
- `xreactor/master/monitor_sessions.lua`
- `xreactor/master/housekeeping.lua`
- `xreactor/master/profiles.lua`
- `xreactor/master/support_status.lua`
- `xreactor/master/ui_diagnostics.lua`
- `xreactor/master/ui/multiview.lua`
- `xreactor/master/ui/widgets.lua`
- `xreactor/master/ui/overview.lua`
- `xreactor/master/ui/rt_dashboard.lua`
- `xreactor/master/ui/energy.lua`
- `xreactor/master/ui/resources.lua`
- `xreactor/master/ui/alarms.lua`
- `xreactor/master/ui/alerts.lua`

Current notes:

- MASTER is an orchestration and UI node, not a direct actuator node.
- MASTER receives node status/heartbeat/alert data, tracks peer/comms health, and sends control intent through command payloads.
- MASTER RT synchronization is coalesced so status/ACK bursts do not immediately cause one full sync per incoming message.
- MASTER UI is model-driven: `ui_controller` builds view models, `monitor_sessions` keeps physical monitor/session state, and `ui/multiview.lua` routes rendering/input.

### RT

Reviewed:

- `xreactor/nodes/rt/config.lua`
- `xreactor/nodes/rt/config_normalizer.lua`
- `xreactor/nodes/rt/binding.lua`
- `xreactor/nodes/rt/discovery_runtime.lua`
- `xreactor/nodes/rt/discovery_log.lua`
- `xreactor/nodes/rt/health_payload.lua`
- `xreactor/nodes/rt/status_snapshot.lua`
- `xreactor/nodes/rt/monitor_ui.lua`
- `xreactor/nodes/rt/startup_diagnostics.lua`
- `xreactor/nodes/rt/module_lifecycle.lua`
- `xreactor/nodes/rt/flow_apply_helpers.lua`
- `xreactor/nodes/rt/reactor_steam_guard.lua`
- `xreactor/nodes/rt/state_handlers.lua`
- `xreactor/nodes/rt/main.lua`

Current notes:

- Fresh RT installs default to auto-discovery when `reactors` / `turbines` lists are empty.
- Explicit reactor/turbine lists restrict binding to those configured names.
- RT starts in local `AUTONOM` mode after bootstrap and only accepts MASTER setpoints while in local `MASTER` mode.
- RT locally owns reactor activation, control rods, turbine activation, turbine flow, and inductor/coil state.
- RT safety can enter `SAFE`/`EMERGENCY` and apply SCRAM locally.
- Turbine flow control is split between the RT orchestrator and helper modules to avoid growing `main.lua` hot paths past Lua/CC parser limits.

### ENERGY

Reviewed:

- `xreactor/nodes/energy/config.lua`
- `xreactor/nodes/energy/config_normalizer.lua`
- `xreactor/nodes/energy/discovery_runtime.lua`
- `xreactor/nodes/energy/discovery_log.lua`
- `xreactor/nodes/energy/matrix_topology_cache.lua`
- `xreactor/nodes/energy/matrix_snapshot_runtime.lua`
- `xreactor/nodes/energy/storage_snapshot_runtime.lua`
- `xreactor/nodes/energy/runtime_context.lua`
- `xreactor/nodes/energy/status_payload.lua`
- `xreactor/nodes/energy/ui_model.lua`
- `xreactor/nodes/energy/ui_pages.lua`
- `xreactor/nodes/energy/command_handler.lua`
- `xreactor/nodes/energy/main.lua`

Current notes:

- ENERGY is a telemetry node and does not control reactor/turbine hardware.
- Storage and matrix sampling are intentionally detached from telemetry/UI paths.
- Telemetry/UI consume snapshots and last-good values rather than performing heavy peripheral reads directly.
- ENERGY heartbeats are intentionally lightweight and flushed separately so liveness is not blocked by slow matrix/storage reads.
- The current runtime is effectively single-storage/single-matrix per ENERGY node even though discovery may see multiple candidates; MASTER can still aggregate multiple ENERGY nodes.
- ENERGY config default ownership is currently split: `nodes/energy/main.lua` is authoritative at runtime; `nodes/energy/config.lua` is the installable/user-facing template and must be kept in sync until a dedicated defaults module exists.

### Support nodes

Shared support reviewed:

- `xreactor/nodes/support/role_logic.lua`
- `xreactor/nodes/support/discovery.lua`
- `xreactor/nodes/support/runtime.lua`
- `xreactor/nodes/support/command_handler.lua`
- `xreactor/nodes/support/ui_pages.lua`

Role runtimes reviewed:

- `xreactor/nodes/water/*`
- `xreactor/nodes/fuel/*`
- `xreactor/nodes/reprocessor/*`

Current notes:

- WATER monitors configured tanks, reports total water and health, and logs refill/bleed suggestions around the configured target volume.
- FUEL monitors a configured storage bus, reports reserve state, and supports `SET_RESERVE`.
- REPROCESSING monitors buffers, supports `MODE OFF` / `MODE RUNNING` standby behavior, and can call a local buffer `process()` method when present and not in standby.
- WATER/FUEL/REPROCESSING share common discovery/runtime/UI/command helper layers.

### LOG collector

Reviewed:

- `xreactor/nodes/log_collector/main.lua`

Current notes:

- LOG collector listens on the log channel and writes incoming `LOG_EVENT` payloads to a disk ring or fallback directory.
- It performs disk discovery, write probing, log rotation, and pruning.
- LOG collector is represented in the manifest role list.
- LOG/LOG_COLLECTOR now exists in `telemetry_schema.lua`.
- LOG is still not fully integrated in `shared.constants.lua` or bootstrap first-start role selection because those runtime writes were blocked by the connector.

### Test/guard infrastructure inspected

Reviewed as quality guard layer:

- `scripts/cc_parse_guard.py`
- `tests/cc_parse_guard_test.py`
- `tests/rt_main_structure_guard_test.py`
- `tests/manifest_entrypoint_require_coverage_test.py`

Current notes:

- CC parse guard protects against Lua parser/local/upvalue pressure.
- RT main structure guard protects against renewed bloat in the RT hot path.
- Manifest/entrypoint coverage test checks role-scoped requires and critical manifest metadata, but currently still has explicit temporary metadata exceptions for active MASTER UI rollout files.

## Current open work items

These are the next cleanup/fix items identified by code inspection.

### 1. Manifest metadata consistency

`xreactor/manifest.lua` still contains several entries without `size_bytes` / CRC32 `hash` metadata. The installer can still download and Lua-parse files without metadata, but storage preflight and integrity reporting are less precise when sizes/hashes are absent.

Progress:

- `shared/telemetry_schema.lua` metadata was updated after the LOG schema change.

Next action:

- Run `python3 tools/regenerate_manifest_metadata.py` from a real repository checkout.
- Commit the resulting full-manifest metadata update.
- Remove temporary manifest-metadata exceptions from `tests/manifest_entrypoint_require_coverage_test.py` when the metadata is complete.

### 2. LOG role integration consistency

The manifest contains a LOG/LOG_COLLECTOR role entry for `nodes/log_collector/main.lua`. `telemetry_schema.lua` now includes LOG/LOG_COLLECTOR telemetry fields.

Remaining next action:

- Add LOG/LOG_COLLECTOR constants in `shared.constants.lua`.
- Add LOG to `core.bootstrap.lua` first-start role selection if LOG should be an official installer/startup role.
- Keep the README LOG role section aligned with that final decision.

### 3. Release/build identity

`xreactor/release.lua` intentionally remains branch-style for moving beta installs. Concrete immutable release/build identity is now handled by `tools/stamp_release_metadata.py`.

Next action:

- Keep `commit_sha = "beta"` for dev branch installs if that is intentional.
- For release builds, run `tools/stamp_release_metadata.py` with a concrete commit SHA and release ID, then commit the stamped `xreactor/release.lua` as part of release preparation.

### 4. MASTER alert message type drift

MASTER message handling references an `ALERT_SUMMARY` message type that is not currently present in shared constants.

Next action:

- Either add the constant and schema if this path is intended,
- or remove/replace the dead check if alert summaries are now represented through STATUS payloads.

### 5. ENERGY config duplication

ENERGY has defaults in both `nodes/energy/config.lua` and `nodes/energy/main.lua`. Current documentation decision:

- `nodes/energy/main.lua` is the authoritative runtime-default source.
- `nodes/energy/config.lua` is the installable/user-facing template.
- Any future ENERGY default change must update both when the setting is user-facing.
- `nodes/energy/config_normalizer.lua` must be updated when a field needs validation, migration, clamping, or compatibility behavior.

Next action:

- Prefer a future focused refactor to introduce a single shared ENERGY defaults module.

## Recommended next order

Recommended order before further feature work:

1. Finish manifest metadata cleanup with the repo-local regeneration tool.
2. Finish LOG role constants/bootstrap integration.
3. Use release stamping helper for immutable release builds.
4. Resolve MASTER alert-message-type drift.
5. Refactor ENERGY defaults into a shared module when tests are available.

## Current conclusion

Architecture is in a better state than the older non-RT closeout document suggests, but it is not final-release clean yet. The main remaining risks are packaging/integration consistency rather than the broad runtime split itself. The cleanup is partially underway; Doku must remain updated with every code change.
