# XReactor Documentation Index

Stand: `beta` / `manifest-v236` / `beta-v236`.

## Current status first

Read these before changing runtime code or attempting an ingame rollout:

1. [`NODE_START_BLOCKERS_2026-06-25.md`](NODE_START_BLOCKERS_2026-06-25.md) — current known blockers and open checks for `beta-v236`.
2. [`PROJECT_DOCUMENTATION.md`](PROJECT_DOCUMENTATION.md) — broader technical project documentation.
3. [`../RUNTIME_STATUS_2026-06-03.md`](../RUNTIME_STATUS_2026-06-03.md) — older running handoff/status document.

## Current critical notes

### RT parse blocker remains open

`xreactor/nodes/rt/main.lua` still contains the known missing comma after the `build_health_payload` function field in the `monitor_ui.update(...)` table.

This was intentionally **not changed** in the latest documentation-only update. Until it is fixed, RT should not be treated as cleanly startable.

### Manifest / Release consistency

Current visible state:

- `xreactor/manifest.lua`: `manifest-v236`, `hash_algo = "none"`
- `xreactor/release.lua`: `beta-v236`, `hash_algo = "crc32"`

This is inconsistent and must be resolved before relying on strict manifest verification.

## Ingame boundary

The latest documentation update did not perform:

- ingame tests
- ingame installs
- remote rollout execution
- RT source-code fix

Run static Lua/require checks after the documented blockers are fixed and before considering an ingame test.
