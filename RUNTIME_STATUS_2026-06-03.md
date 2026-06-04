# XReactor Runtime Status — 2026-06-03

## Scope

This document tracks the current code-reading and cleanup status of the `beta` branch after the 2026-06-03 runtime audit.

Boundaries:

- No full regression run is claimed here.
- This file must stay current with every cleanup change.
- MASTER UI code is currently considered working and must not be changed for the logging issue.

## Latest uploaded logs

The uploaded `xreactor_logs.zip` contained only:

- `master/pc-53.log`
- `rt/pc-52.log`

Missing from that archive:

- ENERGY node logs.
- LOG collector self-log.

Interpretation:

- MASTER and RT are sending/being collected.
- ENERGY either was not running, did not have a usable modem path to the collector, did not reach logger init, or its remote log traffic did not arrive at the LOG collector.
- LOG collector did not previously write its own startup/status events into the collected log tree.

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
- Added `tests/log_role_manifest_minimal_test.py` to guard minimal LOG role manifest selection.
- Reverted the temporary MASTER monitor-manager remote-monitor change; MASTER UI is left unchanged.
- Updated `core/utils.lua` remote logging so nodes transmit log events on all available modems instead of only one preferred modem.
- Updated LOG collector to write startup/status self-log events under role `LOG_COLLECTOR`.
- Updated LOG collector to open the log channel on all available modems instead of only one preferred modem.
- Hardened LOG collector-only monitor UI: supports configured monitor selection, modem-attached remote monitors, and terminal fallback inside `nodes/log_collector/main.lua` only.
- Added `tests/log_collector_remote_monitor_scope_test.py` to guard that remote-monitor support remains scoped to LOG collector and does not modify MASTER monitor manager.
- Updated LOG collector UI to always show the last written disk ID/index, mount/root/path, and mark that disk in the disk ring with `*`.
- Added LOG collector disk-write pause/resume control via monitor touch, terminal mouse click, `p`, or space.
- Added `tests/log_collector_ui_disk_pause_test.py` to guard the active-disk display and pause control.
- Added reliable log transport fields in `core/utils.lua`: `event_id`, sequence number, pending retry buffer, ACK handling, retry flushing, and remote status counters.
- Routed `LOG_ACK` messages through `services/comms_service.lua` before normal protocol receive so shared-service nodes can clear pending remote log events.
- Added LOG collector dedupe and ACK handling in `nodes/log_collector/main.lua`; duplicate events are acknowledged but not written again.
- Added `tests/log_reliable_transport_guard_test.py` to guard event IDs, retries, ACK routing, collector dedupe, and multi-modem send/ACK behavior.
- Verification fix: sender `event_id` now includes a boot/session component (`boot_id`) so node restarts cannot collide with earlier sequence numbers.
- Verification fix: `utils.flush_remote_logs()` no longer forces retries on every service tick; retry cadence is throttled unless explicitly called with `true`.
- Updated `tests/log_reliable_transport_guard_test.py` to guard reboot-safe log IDs and throttled retry flushing.

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

## Logging status

ENERGY/logging issue scope:

- No MASTER UI code should be changed for this issue.
- Sender-side remote logging discovers all local modems and transmits every log event on every available modem, including multiple wireless modems and wired modems.
- Sender-side log events now carry reboot-safe `event_id = boot_id:seq`, `boot_id`, `seq`, and `ack=true`.
- Sender-side remote logging keeps a bounded pending buffer and retries unacknowledged events a limited number of times.
- Retry flushing is cadence-limited; shared service ticks no longer force a retransmit every tick.
- `services/comms_service.lua` routes `LOG_ACK` messages to `core.utils` before normal protocol receive, so ACK packets do not disturb the main control/status protocol.
- Collector-side logging opens the log channel on every available modem.
- Collector-side logging deduplicates by `event_id` and sends `LOG_ACK` back through every available modem after a successful write.
- Duplicate events are acknowledged again but not written again.
- During pause, the collector does not write and does not ACK, so senders can retry after resume.
- Collector writes its own startup/listening/status entries as `LOG_COLLECTOR`.
- Collector UI may use a local or modem-attached monitor, but that change is limited to `nodes/log_collector/main.lua`.

Expected result after reinstall/update:

- A LOG collector self-log appears under `log_collector/<collector-node>.log`.
- ENERGY logs should appear under `energy/<energy-node>.log` once the ENERGY node starts and calls its normal logger path.
- On nodes using `services/comms_service.lua`, ACKs should reduce the sender pending count.

Reliability boundary:

- This is now retry/dedupe/ACK based, but still not a fully persistent store-and-forward queue. If a sender reboots before ACK, only logs still held in memory are retried. Reboot-safe IDs avoid false dedupe collisions after restart, but they do not persist unsent events across restart.

## UI / monitor status

MASTER UI:

- MASTER UI code was restored to the previous behavior and is not part of the current logging fix.
- `core/monitor_manager.lua` must not contain LOG-only remote-monitor behavior.

LOG collector UI:

- The collector now prefers a configured display if set.
- Supported config inputs are `settings.set("xreactor.log_monitor", "<monitor>")`, `settings.set("xreactor.log_monitor", "<remote>@<modem>")`, or `/xreactor/config/log_monitor.txt`.
- If no configured display is found, it tries a local monitor.
- If no local monitor is present, it searches modem remote peripherals for monitors.
- If a remote monitor is found, the collector redirects `term` to that monitor and renders the LOG dashboard there.
- If no monitor exists, it falls back to the local terminal.
- The disk ring uses `*` to mark the last successful write target.
- `Writing Disk #...` shows the last written disk ID/index and mount.
- `Path ...` shows the exact log file path last written.
- `Next Disk #...` shows the current next-attempt disk index.
- A pause/resume button is shown on the LOG UI. While paused, incoming log events are not written to disk and are counted as paused drops so disks can be safely copied/downloaded.
- Pause/resume input works through monitor touch, terminal mouse click, `p`, or space.
- The LOG UI now shows duplicate and ACK counters.

## Connector/write limits observed

The available GitHub write endpoint replaces complete files; there is no line-based patch endpoint in the currently available connector tool set. Some small intended runtime edits therefore still require sending the full target file, and a few full-file writes were blocked by the connector safety layer. Splitting changes into smaller semantic commits worked for the constants/bootstrap cleanup.

Known blocked or deferred write attempts:

- README update after manual full installer URL insertion.
- Separate ENERGY config ownership doc file.
- GitHub issue creation for follow-up tracking.
- General `adapters/monitor.lua` remote-monitor support.

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
- LOG collector now writes its own `LOG_COLLECTOR` startup/status log entries.
- LOG collector listens on all detected modems.
- LOG collector UI supports modem-attached monitors without touching MASTER UI code.
- LOG collector UI always shows the active/last-written disk and supports disk-write pause/resume.
- LOG transport now includes reboot-safe event IDs, dedupe, ACKs, cadence-limited retries, and multiple-wireless-modem support.

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

1. Reinstall/update LOG collector and all nodes that should use reliable remote logging, especially ENERGY.
2. Optional: set `xreactor.log_monitor` to the desired monitor name or `<remote>@<modem>` before starting LOG collector.
3. Start LOG collector and verify the dashboard appears on the modem-attached monitor.
4. Verify the UI shows `Writing Disk #...`, the `*` marker in the disk ring, duplicate count, ACK count, and that the pause/resume button works.
5. Then start/update ENERGY and verify `energy/...log` appears.
6. Check sender `utils.remote_log_status()` locally if needed: pending should decrease as ACKs arrive.
7. Run full manifest metadata regeneration locally.
8. Remove manifest-metadata exceptions from the guard test.
9. Later: refactor ENERGY defaults into one shared module with tests.
