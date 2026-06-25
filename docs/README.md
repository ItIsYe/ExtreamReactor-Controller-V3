# XReactor Documentation Index

Stand: `beta` / `manifest-v156` / `beta-v156`.

## Current status first

Read these before changing runtime code or attempting an ingame rollout:

1. [`NODE_START_BLOCKERS_2026-06-25.md`](NODE_START_BLOCKERS_2026-06-25.md) — current known node start/runtime blockers and exact fix notes for RT, FUEL, WATER, REPROCESSING and ENERGY.
2. [`../RUNTIME_STATUS_2026-06-03.md`](../RUNTIME_STATUS_2026-06-03.md) — running handoff/status document for cleanup history and LOG collector rewrite notes.
3. [`PROJECT_DOCUMENTATION.md`](PROJECT_DOCUMENTATION.md) — broader technical project documentation.

## Important beta rule

`xreactor/manifest.lua` currently uses:

```lua
hash_algo = "none"
```

That is intentional for the moving `beta` branch after the LOG collector rewrite. Do not revert it during normal cleanup. If CRC32 metadata should be restored, regenerate the manifest from a real checkout first and verify it before switching back to `crc32`.

## Ingame boundary

The latest cleanup/documentation work did not perform:

- ingame tests
- ingame installs
- ingame remote-update execution

Fix the documented start blockers and run static Lua/require checks before considering an ingame test.
