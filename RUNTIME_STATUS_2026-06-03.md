# XReactor Runtime Status — 2026-06-03

## Scope

This document tracks the current code-reading and cleanup status of the `beta` branch after the 2026-06-03 runtime audit.

Boundaries:

- No in-game test was performed.
- No full regression run is claimed here.
- This file must stay current with every cleanup change.

## Completed during cleanup

- Added LOG/LOG_COLLECTOR telemetry schema entries in `xreactor/shared/telemetry_schema.lua`.
- Updated `xreactor/manifest.lua` metadata for `shared/telemetry_schema.lua`.
- Added `tools/stamp_release_metadata.py` for immutable release stamping.
- Documented ENERGY config ownership: `nodes/energy/main.lua` is the authoritative runtime-default source; `nodes/energy/config.lua` is the installable/user-facing template.
- Added LOG to `xreactor/core/bootstrap.lua` first-start role selection.
- Updated `xreactor/manifest.lua` metadata for `core/bootstrap.lua`.
- Added `ALERT_SUMMARY` to `xreactor/shared/constants.lua` to match the existing MASTER message-handler branch.
- Added `tests/message_type_reference_guard_test.py` to guard `constants.message_types.*` references.
- Updated `xreactor/manifest.lua` metadata for `shared/constants.lua`.

## Connector/write limits observed

The available GitHub write endpoint replaces complete files; there is no line-based patch endpoint in the currently available connector tool set. Some small intended runtime edits therefore still require sending the full target file, and a few full-file writes were blocked by the connector safety layer. When this happens, keep the manual follow-up listed here and apply it from a normal local checkout.

Known blocked or deferred write attempts:

- `xreactor/shared/constants.lua` full LOG/LOG_COLLECTOR role/channel additions.
- README update after manual full installer URL insertion.
- Separate ENERGY config ownership doc file.
- GitHub issue creation for follow-up tracking.

## Architecture status

The project is a distributed CC:Tweaked controller stack for Extreme Reactors and support infrastructure.

- MASTER aggregates telemetry, alerts, health, UI models, and operator intent.
- RT owns local reactor/turbine writes and safety.
- ENERGY owns power telemetry and uses cached sampling for matrix/storage state.
- WATER/FUEL/REPROCESSING provide support-node telemetry and limited local behavior.
- LOG collector listens for remote log events and writes them to disk/fallback storage.

The MASTER/RT separation remains the central safety boundary: MASTER sends intent/setpoints; RT performs local hardware writes and safety decisions.

## LOG role status

Completed:

- LOG/LOG_COLLECTOR exists in the manifest role list.
- LOG/LOG_COLLECTOR exists in `telemetry_schema.lua`.
- LOG is now available in bootstrap first-start role selection.

Still open:

- Add LOG/LOG_COLLECTOR constants to `xreactor/shared/constants.lua`.
- Add LOG channel constant to `xreactor/shared/constants.lua` if the channel table should expose log channel `6502` directly.
- Re-run manifest metadata generation after the constants change.

## Manifest metadata status

Still open:

- Run `python3 tools/regenerate_manifest_metadata.py` from a real repository checkout.
- Commit the resulting full `xreactor/manifest.lua` metadata refresh.
- Remove temporary metadata exceptions from `tests/manifest_entrypoint_require_coverage_test.py` when manifest metadata is complete.

Reason: several manifest entries still lack `size_bytes` and CRC32 `hash`, so installer storage preflight and integrity reporting remain less precise for those files.

## Release/build identity status

`xreactor/release.lua` intentionally remains branch-style for moving beta installs. Concrete immutable release/build identity is now handled by `tools/stamp_release_metadata.py`.

For release builds:

1. Run `tools/stamp_release_metadata.py` with a concrete commit SHA and release ID.
2. Commit the stamped `xreactor/release.lua` as part of release preparation.

## MASTER alert message type drift

Resolved:

- `xreactor/shared/constants.lua` now defines `ALERT_SUMMARY`.
- `tests/message_type_reference_guard_test.py` will catch future undefined `constants.message_types.*` references.

## ENERGY config defaults

Current documented ownership:

- `nodes/energy/main.lua` is the authoritative runtime-default source.
- `nodes/energy/config.lua` is the installable/user-facing template.
- User-facing ENERGY default changes must update both files until a shared defaults module exists.
- `nodes/energy/config_normalizer.lua` must be updated when validation, migration, clamping, or compatibility behavior is needed.

Recommended future cleanup:

- Introduce a shared ENERGY defaults module and have both runtime and template use it.

## Recommended next order

1. Finish `shared.constants.lua` LOG constants/channel update from a local checkout or via a connector-safe method.
2. Run full manifest metadata regeneration locally.
3. Remove manifest-metadata exceptions from the guard test.
4. Later: refactor ENERGY defaults into one shared module with tests.
