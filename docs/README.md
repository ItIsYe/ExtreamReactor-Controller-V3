# XReactor Documentation Index

Stand: `beta` / `manifest-v261` / `beta-v261`.

## Current status first

Read these before changing runtime code or attempting an ingame rollout:

1. [`NODE_START_BLOCKERS_2026-06-25.md`](NODE_START_BLOCKERS_2026-06-25.md) — historical blockers, all resolved as of `beta-v261`.
2. [`PROJECT_DOCUMENTATION.md`](PROJECT_DOCUMENTATION.md) — broader technical project documentation.
3. [`NODE_OVERVIEW.md`](NODE_OVERVIEW.md) — per-node functional breakdown (what each of the 8 node types actually does).
4. [`../RUNTIME_STATUS_2026-06-03.md`](../RUNTIME_STATUS_2026-06-03.md) — full, dated session-by-session change history.
5. [`../README.md`](../README.md) — top-level project README (install instructions, architecture overview).

## Current status

No known open blockers as of `beta-v261` (2026-07-01). Manifest and release metadata are consistent (`manifest_version`/`manifest_id`/`release_id` all `261`, `manifest_file_count = 145`, `hash_algo = "crc32"` in both `manifest.lua` and `release.lua`).

## Ingame boundary

This documentation update itself performed no ingame tests, ingame installs, or remote rollout execution — it reflects the state of the `beta` branch source code and the manifest/release metadata at the time of writing. Always verify against a fresh `installer` run before relying on documentation alone for an ingame rollout decision.
