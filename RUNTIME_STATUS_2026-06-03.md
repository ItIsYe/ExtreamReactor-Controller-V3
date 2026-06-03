# XReactor Runtime Status — 2026-06-03

## Scope

This document tracks the current code-reading and cleanup status of the `beta` branch after the 2026-06-03 runtime audit.

Boundaries:

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
- Added LOG/LOG_COLLECTOR role constants and LOG channel constant to `xreactor/shared/constants.lua`.
- Updated `xreactor/manifest.lua` metadata for `shared/constants.lua`.
- Fixed installer low-space cleanup so active `/xreactor_stage` is not deleted while writing staged files.
- Changed installer staging order so files with known larger `size_bytes` are downloaded/written first.
- Changed installer manifest selection so LOG/LOG_COLLECTOR no longer receives all base files automatically.
- Marked `shared/constants.lua` explicit `always=true`, because the LOG collector reads it.
- Changed virtual role-file injection so `core/utils.lua` is not added for LOG/LOG_COLLECTOR.

## Ingame test finding

During ingame installer attempts, two low-space staging problems were observed.

First, low-space write cleanup removed the active stage directory while files were still being downloaded. That caused staged validation to fail with missing earlier-stage files such as `core/bootstrap.lua`.

Second, after preserving the active stage, the install could still fail when a large file such as `core/comms.lua` was attempted late in the stage after smaller files had already consumed most of the remaining free space.

Fix status:

- `xreactor/installer_storage.lua` now supports `keep_stage = true` and preserves the active stage during cleanup.
- `xreactor/installer_main.lua` now passes `keep_stage = true` when the target path is inside `/xreactor_stage/`.
- `xreactor/installer_stage.lua` now stages files ordered by known size descending, with path name as a stable tie-breaker.
- `xreactor/installer_manifest.lua` now treats base files as implicit for normal roles, but not for LOG/LOG_COLLECTOR.
- LOG/LOG_COLLECTOR install should now include only explicit always files plus LOG-specific files, rather than large MASTER/RT/ENERGY runtime base files.

## Connector/write limits observed

The available GitHub write endpoint replaces complete files; there is no line-based patch endpoint in the currently available connector tool set. Some small intended runtime edits therefore still require sending the full target file, and a few full-file writes were blocked by the connector safety layer. Splitting changes into smaller semantic commits worked for the constants/bootstrap cleanup.

Known blocked or deferred write attempts:

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
- LOG/LOG_COLLECTOR exists in `shared.constants.lua`.
- LOG channel `6502` exists in `shared.constants.lua`.
- LOG is available in bootstrap first-start role selection.
- Installer role 7 now has minimal LOG-specific manifest selection instead of inheriting all base files.

Expected LOG role installed files:

- `installer_http.lua`
- `installer_main.lua`
- `installer_manifest.lua`
- `installer_stage.lua`
- `installer_startup.lua`
- `installer_storage.lua`
- `release.lua`
- `start.lua`
- `shared/build_info.lua`
- `shared/constants.lua`
- `nodes/log_collector/main.lua`

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

1. Re-run the LOG-role installer ingame after deleting the failed partial `/xreactor_stage` if it still exists.
2. Run full manifest metadata regeneration locally.
3. Remove manifest-metadata exceptions from the guard test.
4. Later: refactor ENERGY defaults into one shared module with tests.
