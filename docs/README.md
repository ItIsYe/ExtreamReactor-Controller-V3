# XReactor Documentation Index

Stand: `beta` / `manifest-v262` / `beta-v262`.

## Current status first

Read these before changing runtime code or attempting an ingame rollout:

1. [`../README.md`](../README.md) — main technical reference: architecture, roles, boot sequence, RT-node details (multi-node assignment, setpoint fields, capacity learning, Ampel monitor), Master UI.
2. [`NODE_OVERVIEW.md`](NODE_OVERVIEW.md) — per-node functional breakdown with concrete config examples (FUEL/WATER/REPROCESSOR/ENERGY/LOG details not covered in the main README).
3. [`../RUNTIME_STATUS_2026-06-03.md`](../RUNTIME_STATUS_2026-06-03.md) — full, dated session-by-session change history.
4. [`SESSION_HANDOFF.md`](SESSION_HANDOFF.md) — compact entry point for new chat sessions.
5. [`NODE_START_BLOCKERS_2026-06-25.md`](NODE_START_BLOCKERS_2026-06-25.md) — historical blockers, all resolved as of `beta-v262`.
6. [`PROJECT_DOCUMENTATION.md`](PROJECT_DOCUMENTATION.md) — now just a pointer to the above (was a parallel, independently-maintained copy that drifted out of sync with the actual code; consolidated 2026-07-01 to avoid that recurring).

## Current status

No known open blockers as of `beta-v262` (2026-07-01). Manifest and release metadata are consistent (`manifest_version`/`manifest_id`/`release_id` all `262`, `manifest_file_count = 139`, `hash_algo = "crc32"` in both `manifest.lua` and `release.lua`). A hygiene pass removed two long-standing dead-code artifacts (orphaned `installer_*.lua` files, duplicate `xreactor/xreactor/` path) and 9 tests for the since-replaced stage-based installer mechanism.

## Ingame boundary

This documentation update itself performed no ingame tests, ingame installs, or remote rollout execution — it reflects the state of the `beta` branch source code and the manifest/release metadata at the time of writing. Always verify against a fresh `installer` run before relying on documentation alone for an ingame rollout decision.
