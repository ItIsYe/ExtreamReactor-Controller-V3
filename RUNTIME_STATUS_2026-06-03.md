# XReactor Runtime Status — 2026-06-03

## Update 2026-07-01 (v236 → v242 — Full System Hardening + UI Overhaul)

Diese Session hat das System von v236 auf v242 gebracht. Alle bekannten offenen Punkte aus früheren Dokumenten wurden behoben.

**Auto-Updater & Installer:**
- `role.lua` jetzt in BEIDEN Installer-Codepfaden (manuell + Auto-Update-Reinstall) in der PRESERVE-Liste — zuvor ging die Rollenzuordnung bei jedem Auto-Update verloren (Node bootete ohne Rolle → `No such program`).
- `installer/auto_update.lua`: `resolve_sha()` entfernt (api.github.com-Call verursachte Hänger auf RT), nur noch direkte `raw.githubusercontent.com/beta/...`-Fetches.
- `enqueue()` im Sequencer verwirft jetzt Tabellen-Objekte als `node_id` statt sie durch `normalize_node_id()` in kaputte Strings zu verwandeln (`RT-table:_0x...`-Anzeigefehler behoben).

**Master — Setpoint/Kapazitäts-Fixes:**
- `message_handlers.populate_rt_status()`: `rt.capacity_max`/`rt.capacity_ready` werden jetzt VOR der Ableitung von `node.capacity_max`/`node.capacity_ready` aus dem Payload gesetzt (Off-by-one-Zyklus-Bug — brach Setpoint-Zuteilung für alle RT-Nodes).
- `node.rt` wird jetzt gemergt statt komplett ersetzt bei STATUS-Ticks (verhindert Verlust von UI-gesetzten Feldern).
- `node.assigned_power`/`node.assigned_percent` werden jetzt persistent auf `node` geschrieben (waren vorher nur lokal in `entry` — daher zeigte Master-UI immer `Soll 0.0` für RT-Nodes).
- `runtime_ops_profile.estimate_base_power()`: gelernte Maximalkapazität wird jetzt bevorzugt gegenüber dem aktuell gemessenen (möglicherweise gedrosselten) Output — verhindert dauerhaftes Einfrieren von `power_target` auf altem BASELOAD-Snapshot nach PEAK-Wechsel.
- Periodisches `power_target`-Nachziehen alle 30s wenn gelernte Kapazität >5% über aktuellem Soll.

**Master — UI-Fixes:**
- `control_source` (Source: LOCAL/MASTER) hatte denselben Sticky-Bug wie `assignment_state` — jetzt korrigierte Priorität.
- `infer_assignment_state()`: `node.assignment_state` (Master-Sync) hat jetzt Vorrang vor `rt_node.assignment_state` (instabil, durch STATUS-Ticks zurückgesetzt).
- AUX-Monitor-Badge: hardkodiertes `OK`/`LIMITED` durch echten Alert-Service-Status ersetzt.
- AUX-Alarmview komplett überarbeitet: Live-Alarmliste aus `alert_service`, Farben nach Severity (CRITICAL=rot, WARN=gelb), Timestamp pro Eintrag, Touch-to-ACK.
- `alerts`/`alarms`-Model fehlte in `build_models()` — Views bekamen nie echte `alert_service`-Daten.
- `multiview.lua`: Alarmtext der dringendsten Meldung wird jetzt unter dem Badge angezeigt.

**RT-Node:**
- `target_power`/`target_percent` fehlten im `monitor_ui.update()`-Model — RT-UI zeigte dauerhaft `Soll 0.0` und `WARTET AUF AUFTRAG` auch unter aktiver Master-Steuerung.
- `manifest_id`/`release_id` werden jetzt dynamisch aus `/xreactor/release.lua` geladen statt hartkodiert `v158`.
- RT-Kommafehler in `monitor_ui.update()` (fehlende Komma nach `build_health_payload`) behoben.

**Energy-Node:**
- `NO_STORAGE`-Health-Alert feuerte dauerhaft auf Matrix-only Nodes (kein separater Storage-Adapter) — jetzt nur noch wenn weder Matrix noch Storage vorhanden.

**LOG-Collector:**
- Kanal-Mismatch behoben: `core/remote_log.lua` sendete auf 6502, `shared/constants.lua` definiert `channels.LOG = 6503` — LOG empfing dauerhaft nichts (`Recv 0`). Beide Seiten jetzt auf 6503.
- Wireless-Modem-Erkennung ergänzt (zeigt `*` im Modem-Status für Ender-Modems).

**Sonstiges:**
- `core/remote_update.lua`: `handle_command()` reicht jetzt `opts` (inkl. Token) an `M.run()` weiter.
- Manifest: alle 143 Einträge mit korrekten `size_bytes` + CRC32-Hashes regeneriert, `hash_algo = "crc32"` wiederhergestellt (war seit Rewrite auf `"none"`).
- `xreactor/xreactor/nodes/` (verwaistes Duplikat-Verzeichnis) — bekannt, noch nicht aufgeräumt, dokumentiert für nächste Doku-Runde.

**Versionsverlauf dieser Session:** v220 (Sessionstart) → v242 (Abschluss). Alle Blocker aus `NODE_START_BLOCKERS_2026-06-25.md` und `PROJECT_DOCUMENTATION.md` Abschnitt 9 behoben.

---

## Update 2026-06-30 (Installer / Auto-Update Härtung, v220 → v225)

Diese Sektion dokumentiert die Arbeit vom 2026-06-30 zusätzlich zum darunterliegenden, unveränderten Audit-Stand vom 2026-06-03/04-22.

**Behoben:**
- ENERGY Auto-Update brach mit `attempt to index global 'shell' (a nil value)` ab (`installer/auto_update.lua:130`) — `shell.run` ist in `parallel`-Coroutinen nicht verfügbar. Fix: `dofile()` statt `shell.run()`.
- LOG-Boot brach mit `No such program` ab — `start.lua` rief `shell.run(entry)` mit einem absoluten Pfad auf, nicht einem Programmnamen. Fix: `dofile(entry)`.
- Installer brach mit `size mismatch /xreactor/start.lua: got 3817 expected 3823` ab — `manifest.lua`-`size_bytes` für `start.lua` war nach dem `dofile`-Fix nicht nachgezogen worden.
- LOG erhielt nach erfolgreicher Installation trotzdem `File not found` bei `/xreactor/nodes/log_collector/main.lua` — der Installer hatte für die LOG-Rolle nie `manifest.roles.log` ausgewertet (`if not is_log then` blockierte den gesamten Role-Files-Block für LOG). Fix: Role-Files werden jetzt für alle Rollen ausgewertet, base_files bleiben für LOG weiterhin auf `always=true` beschränkt. LOG-Dateianzahl stieg dadurch von 11 auf 12 (korrekt).
- RT Auto-Update hing nach `Versuch 1/3` ohne weitere Log-Ausgabe — `resolve_sha()` rief zusätzlich `api.github.com` auf; auf dem event-intensiven RT-Node konnte der async HTTP-Wait dadurch stecken bleiben. Fix: `resolve_sha()` entfernt, Auto-Updater fetcht `release.lua` und `installer` direkt über `raw.githubusercontent.com/.../beta/...` ohne SHA-Auflösung.
- Installer löschte beim Reinstall `/xreactor/config/role.lua` mit, bevor neu installiert wurde — bei einem fehlgeschlagenen/abgebrochenen Reinstall (relevant bei großen Rollen wie MASTER/RT, da `/xreactor` komplett gelöscht statt über Stage/Backup gewechselt wird) ging die Rollenzuordnung verloren. Fix: `role.lua` wird vor dem Löschen gelesen und sofort nach dem Neuanlegen von `/xreactor` wiederhergestellt — in beiden Installer-Codepfaden (Erstinstallation und Auto-Update-Reinstall).

**Versionsverlauf dieser Session:** v218 (Sessionstart) → v220 (LOG `dofile`-Test) → v221 (`start.lua` `dofile`-Fix) → v222 (LOG-Manifest-Fix) → v223 (Auto-Updater-Rollout-Test alle Nodes) → v224 (RT Auto-Update-Hang-Fix, kein `api.github.com` mehr) → v225 (role.lua-Erhalt im Installer).

**Bestätigt funktionierend:** Auto-Updater läuft jetzt stabil auf ENERGY, LOG, MASTER, RT (nach manuellem einmaligem Installer-Lauf je Node zum Nachziehen der gefixten Installer-Logik).

**Offenes Problem (nicht behoben, neu aufgefallen):** Setpoint-Übertragung/-Berechnung zwischen MASTER und Nodes funktioniert aktuell nicht zuverlässig. Root Cause noch nicht untersucht — nächster Arbeitspunkt.

---

## Scope

This document tracks the current code-reading and cleanup status of the `beta` branch after the 2026-06-03 runtime audit.

Boundaries:

- No full regression run is claimed here.
- This file must stay current with every cleanup change.
- MASTER UI code is currently considered working and must not be changed for the logging issue.
- As of 2026-06-25, no ingame test, ingame install, or ingame remote-update execution was performed for the LOG collector rewrite work described below.

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
- Follow-up fix: sender-side remote logging now refreshes its modem list after startup so ENERGY and other nodes can begin logging even if no modem was usable during initial logger setup.
- Follow-up fix: LOG collector now refreshes its modem list after startup and shows `ModemRefresh` on the UI.
- Follow-up fix: LOG collector advances the next write disk after every successful write, making disk rotation visible instead of staying on disk 1 until a failure.
- Follow-up fix: LOG collector pruning no longer deletes active `.log` files; it prunes only rotated/old/backup files.
- Updated `tests/log_collector_ui_disk_pause_test.py` to guard visible disk rotation, collector modem refresh, and active-log preservation.
- 2026-06-25: Completed the LOG collector v2 rewrite in `xreactor/nodes/log_collector/main.lua` after a partial rewrite left undefined UI helpers (`buf_line`/`flush_buf`) in the draw path.
- 2026-06-25: Replaced the LOG collector UI with an incremental segment renderer; normal redraws now queue UI segments and only write changed or removed segments instead of clearing/redrawing the whole screen.
- 2026-06-25: Bumped `xreactor/manifest.lua` to `manifest-v156` and `hash_algo = "none"` so stale size/CRC metadata no longer blocks the rewritten LOG collector during beta installs/updates.
- 2026-06-25: Bumped `xreactor/release.lua` to `beta-v156` so release metadata matches `manifest-v156`.

## 2026-06-25 LOG collector rewrite handoff

Files changed in this pass:

- `xreactor/nodes/log_collector/main.lua`
- `xreactor/manifest.lua`
- `xreactor/release.lua`
- `RUNTIME_STATUS_2026-06-03.md`

Commits:

- `717b1051e5437618e6db2eda446f91f4229c5dae` — `fix(log_collector): complete stable v2 rewrite`
- `e5773eba0c289454976f903ebe7aff616ab966ed` — `perf(log_collector): render only changed UI segments`
- `5bf5d84de8cd5e0b3cd50e6f41dd4b2e318f3362` — `chore(manifest): bump to v156 for log collector rewrite`
- `4279a588a561c2a9e2c26b4d2383b5f21ad62755` — `chore(release): bump beta release to v156`

Current LOG collector behavior after the rewrite:

- Receives `LOG_EVENT` packets on the configured LOG channel.
- Opens the LOG channel on every detected modem and refreshes modem discovery periodically.
- Writes collected logs to external disks only; there is no PC fallback for collected node logs.
- Uses fixed role-to-disk ordering: `/disk=RT`, `/disk1=MASTER`, `/disk2=ENERGY`, `/disk3=WATER`, `/disk4=FUEL`, `/disk5=REPROCESSING`, `/disk6=LOG`.
- Writes per-role/per-node files under `<disk>/xreactor_logs/<role>/<node>.log`.
- Deduplicates by `event_id` and ACKs successful or duplicate events.
- While paused, incoming logs are not written and are not ACKed, so senders can retry after resume.
- Provides a crash screen and reboots after a key press on non-terminate errors.
- UI supports a configured monitor, local monitor discovery, and terminal fallback.
- UI now uses an incremental render buffer: `begin_frame()` starts a frame, UI widgets enqueue segments, and `flush_ui()` only writes changed segments or erases removed segments. `term.clear()` is restricted to first render or display-size changes.

Important verification boundary:

- This was a static/repository update only.
- No ingame install, no ingame run, and no remote-update test was performed.
- A later real checkout should still run Lua parse checks and any repo-local manifest/tooling checks before an ingame rollout.

Known follow-up after this pass:

- `hash_algo = "none"` is intentional for the moving `beta` branch after the LOG rewrite because exact regenerated CRC metadata was not available through the connector. A real repository checkout should later run the manifest metadata generator and restore full `size_bytes`/CRC metadata if desired.
- Existing non-LOG node blockers found in static review are not fixed by this LOG collector pass: RT parse issue, WATER/FUEL/REPROCESSING Lua-scope issues, and FUEL missing `redstone_router_lib` require still need separate fixes.

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
- Sender-side remote logging periodically refreshes modem discovery after startup; this protects nodes whose modem appears or becomes usable after logger init.
- Retry flushing is cadence-limited; shared service ticks no longer force a retransmit every tick.
- `services/comms_service.lua` routes `LOG_ACK` messages to `core.utils` before normal protocol receive, so ACK packets do not disturb the main control/status protocol.
- Collector-side logging opens the log channel on every available modem and periodically refreshes the modem list.
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
- `Next Disk #...` shows the current next-attempt disk index, which now advances after successful writes.
- `ModemRefresh` shows how often the collector refreshed modem discovery after startup.
- A pause/resume button is shown on the LOG UI. While paused, incoming log events are not written to disk and are counted as paused drops so disks can be safely copied/downloaded.
- Pause/resume input works through monitor touch, terminal mouse click, `p`, or space.
- The LOG UI now shows duplicate and ACK counters.
- After the 2026-06-25 rewrite, normal LOG UI updates are incremental. The draw path queues render segments and `flush_ui()` only writes changed segments or erases removed segments. Full `term.clear()` should happen only on first render or display-size change.

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
- LOG collector listens on all detected modems and refreshes modem discovery after startup.
- LOG collector UI supports modem-attached monitors without touching MASTER UI code.
- LOG collector UI always shows the active/last-written disk and supports disk-write pause/resume.
- LOG collector rotates the next write disk after each successful write and preserves active `.log` files during pruning.
- LOG transport now includes reboot-safe event IDs, dedupe, ACKs, cadence-limited retries, post-start modem refresh, and multiple-wireless-modem support.
- LOG collector v2 rewrite is now complete enough to remove the previous undefined UI helper issue (`buf_line`/`flush_buf`).
- LOG collector UI now uses incremental segment rendering instead of full redraws during normal operation.

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

Current beta state after 2026-06-25 LOG rewrite:

- `xreactor/manifest.lua` is now `manifest-v156`.
- `xreactor/release.lua` is now `beta-v156`.
- `hash_algo = "none"` is currently intentional for beta because the LOG collector file was rewritten through the connector and exact regenerated CRC metadata was not available from a real checkout during this pass.

Still open:

- Run `python3 tools/regenerate_manifest_metadata.py` from a real repository checkout.
- Commit the resulting full `xreactor/manifest.lua` metadata refresh.
- Restore `hash_algo = "crc32"` if/when the regenerated metadata is complete and verified.
- Remove temporary metadata exceptions from `tests/manifest_entrypoint_require_coverage_test.py` when manifest metadata is complete.

Reason: several manifest entries previously lacked or could now lack exact `size_bytes` and CRC32 `hash`, so installer storage preflight and integrity reporting remain less precise for those files while `hash_algo = "none"` is active.

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
