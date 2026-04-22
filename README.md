# XReactor Controller V3

XReactor is a distributed controller stack for **CC:Tweaked** systems connected to **Extreme Reactors** and optional support infrastructure. It is built around one **MASTER** computer and several specialized role nodes that manage hardware locally and exchange state over wireless modem channels.

The current repository ships:

- a **single-file installer** (`installer`) for fresh installs and updates,
- a role-based runtime under `/xreactor`,
- a startup entrypoint that launches the selected role automatically,
- per-role configs, local registries, telemetry, alerts, and monitor UIs.

## System goals

- Keep hardware control **local to the node** that owns the peripherals.
- Let the **MASTER** aggregate telemetry, alerts, node health, and UI views.
- Allow the **RT** node to continue operating when the MASTER is unavailable.
- Keep installation/update simple with one installer and one runtime root.

## Roles

### MASTER
**Purpose:** Central coordinator and dashboard.

**Controls / responsibilities:**
- Receives node status, heartbeat, and alert traffic over wireless modem channels.
- Sends commands and setpoints to nodes using the command/ack protocol.
- Runs the startup sequencer for RT nodes.
- Renders the main UI, including overview, RT, energy, resources, alarms, alerts, and multi-monitor views.
- Tracks peer state, retries, queue metrics, and comms timeouts.

**Expected behavior:**
- Starts from `/xreactor/master/main.lua`.
- Uses wired monitors when present.
- Shows UTC wall-clock time in the MASTER UI (not CC:Tweaked in-game time).
- Does **not** directly control reactor, turbine, or storage peripherals; those stay on the role nodes.

### RT
**Purpose:** Reactor/turbine control node.

**Controls / responsibilities:**
- Detects and manages Extreme Reactors reactors and turbines.
- Fresh installs use auto-discovery by default: empty `reactors` / `turbines` config lists bind all compatible local RT devices automatically.
- Applies local control rails for rods, turbine flow, and coil engagement.
- Executes startup sequencing and startup watchdog logic.
- Accepts MASTER commands for mode changes and setpoints.
- Enforces local safety rules such as temperature/coolant-related limits.

**Expected behavior:**
- Supports local operating states such as `AUTONOM`, `MASTER`, and `SAFE`.
- If MASTER comms are lost, it can fall back to autonomous behavior instead of hard-stopping.
- Can drive an attached local monitor UI.
- If explicit device names are configured, RT binds only those names; clearing the lists switches back to auto-discovery.

### ENERGY
**Purpose:** Power telemetry node.

**Controls / responsibilities:**
- Discovers induction matrices and energy storage peripherals.
- Aggregates stored energy and storage-level telemetry.
- Can render a dedicated local monitor UI with overview, matrices, storages, and diagnostics pages.
- Reports registry/discovery state back to the MASTER.

**Expected behavior:**
- Mainly monitors and reports energy infrastructure.
- Uses peripheral discovery and filters from its role config.
- Normalizes induction component APIs (`getInstalledCells` / `getInstalledProviders` variants that return lists, maps, nested result tables, trailing payload tuples such as `nil, "warming up", {...}`, boolean+payload tuples, strings, or numbers) into stable numeric counts.
- Distinguishes matrix component issues between API-variant mismatches, temporary "not ready" nil payloads, unexpected value formats, and transient read/call errors, with deduplicated diagnostics to avoid repeated identical warning spam.
- Does not perform reactor/turbine control.

### WATER
**Purpose:** Water loop monitoring/balancing node.

**Controls / responsibilities:**
- Monitors configured loop tanks.
- Tracks a configured target volume.
- Reports health and balance state.
- Provides local monitor diagnostics when a monitor is attached.

**Expected behavior:**
- Operates on the configured tank list.
- Warns through health/telemetry when discovery or registry state is degraded.

### FUEL
**Purpose:** Fuel reserve monitoring node.

**Controls / responsibilities:**
- Reads a configured storage bus (default `meBridge_0`).
- Tracks configured target and minimum reserve values.
- Reports reserve state and health to the MASTER.
- Can show local status/diagnostics on an attached monitor.

**Expected behavior:**
- Monitors fuel availability only.
- Does not directly control reactor hardware.

### REPROCESSING
**Purpose:** Reprocessing buffer telemetry node.

**Controls / responsibilities:**
- Monitors configured reprocessing buffers.
- Reports local state, registry data, and connection health.
- Supports local monitor pages similar to the other support nodes.

**Expected behavior:**
- Acts as a telemetry/visibility node for buffer state.
- Current implementation is named **REPROCESSING** in the installer/startup role flow, while the runtime folder is `nodes/reprocessor`.

## Runtime architecture

At runtime, the project is split into a small set of active areas:

- `xreactor/core/` - shared runtime internals such as bootstrap loading, network/comms, logging, registry handling, UI helpers, control rails, and safety helpers.
- `xreactor/services/` - reusable services for comms, discovery, telemetry, alerts, UI ticks, and service lifecycle management.
- `xreactor/master/` - MASTER-specific config, sequencer, and UI views.
- `xreactor/nodes/` - role-specific node implementations for `rt`, `energy`, `water`, `fuel`, and `reprocessor`.
- `xreactor/nodes/support/` - shared non-RT support-node runtime/discovery/ui/command helpers used by `water`, `fuel`, and `reprocessor`.
- `xreactor/adapters/` - peripheral adapters for reactors, turbines, monitors, energy storage, and induction matrices.
- `xreactor/shared/` - shared constants, colors, telemetry schema, build info, and health codes.
- `xreactor/manifest.lua` - installer manifest listing the files for the base runtime and each role.
- `xreactor/start.lua` - startup router that reads the installed role and launches the correct entrypoint.
- `installer` - single-file installer/update entrypoint for deployment.


### Roadmap-Status (Non-RT)

Der große Nicht-RT-Umbau ist auf dem aktuellen Stand abgeschlossen (Final-Audit 2026-04-22, siehe `NON_RT_CLOSEOUT_2026-04-22.md`):
- gemeinsame Nicht-RT-Bausteine sind aktiv,
- ENERGY/MASTER/Installer laufen modular,
- WATER/FUEL/REPROCESSOR nutzen die gemeinsame Support-Schicht.

RT bleibt bewusst getrennt und unverändert; RT-Audits/Refactors laufen separat.

Support-node architecture note:
- `water`, `fuel`, and `reprocessor` keep role-specific control logic local, but share common discovery classification/runtime wiring via `nodes/support/*`.
- RT (`xreactor/nodes/rt/*`) is intentionally separate and not part of these shared non-RT support abstractions.

## Repository structure

```text
installer                  Single-file installer/update program
xreactor/
  manifest.lua             Installer manifest with base + role file lists
  start.lua                Startup router for the installed role
  core/                    Shared runtime internals
  services/                Shared background/runtime services
  adapters/                Peripheral wrappers/adapters
  shared/                  Shared constants/schema/build metadata
  master/                  MASTER runtime and UI
  nodes/
    rt/                    Reactor/turbine node
    energy/                Energy telemetry node
    water/                 Water telemetry node
    fuel/                  Fuel telemetry node
    reprocessor/           Reprocessing telemetry node
tests/
  protocol_test.lua        Protocol validation test
```

## Installer behavior

The current installer is the root-level file `installer`. It is the only installer entrypoint in this repository.

### What the installer does

On launch it shows a simple menu:

1. `Neuinstallation`
2. `Update`
3. `Abbrechen`

### Fresh install flow

`Neuinstallation` currently does the following:

1. Prompts for one role (`MASTER`, `RT`, `ENERGY`, `WATER`, `FUEL`, `REPROCESSING`).
2. Downloads `xreactor/manifest.lua` from the `beta` branch raw GitHub URL.
3. Runs storage preflight checks (including stage/peak + buffer estimation and optional cleanup of stale stage/backup artifacts).
4. Downloads the expected base + selected role files into `/xreactor_stage` and validates staged files/hashes.
5. Writes the selected role config into the staged tree.
6. Commits stage activation by moving current `/xreactor` to `/xreactor_backup_prev`, moving stage to `/xreactor`, and removing backup after successful commit.
7. Writes `/startup` with `shell.run("/xreactor/start.lua")`, unless an existing `/startup` looks unrelated to XReactor.
8. Logs progress to `/xreactor_logs/installer.log`.

### Update flow

`Update` currently does the following:

1. Downloads the current manifest.
2. Reads the installed role from `/xreactor/config/role.lua`.
3. Runs storage preflight checks for update mode.
4. Downloads the expected base + installed role files into `/xreactor_stage`.
5. Copies existing `/xreactor/config` into stage and validates staged files/hashes.
6. Commits stage activation by moving active `/xreactor` to `/xreactor_backup_prev`, activating `/xreactor_stage` as `/xreactor`, and deleting backup after successful commit.
7. Rewrites/ensures the XReactor startup file at `/startup` if the existing startup belongs to XReactor.
8. Logs progress to `/xreactor_logs/installer.log`.

### Download validation

The installer validates downloaded files before keeping them:

- rejects missing or empty files,
- rejects HTML content,
- parses `.lua` files before accepting them.

That means blob/HTML downloads are explicitly treated as installation failures.

### Build/Release consistency (manifest + package)

To avoid stale ZIP artifacts and manifest drift, build release artifacts only via the repo scripts:

```bash
python scripts/manifest_sync.py --write
python scripts/package_release.py --sync --output dist/xreactor-release.zip
```

The packaging command validates and/or synchronizes:

- all manifest file hashes/sizes,
- installer hash/size in `xreactor/release.lua`,
- release manifest metadata in `xreactor/release.lua` (`manifest_id`, `manifest_version`, `manifest_file_count`, `hash_algo`, `manifest_path`),
- ZIP content directly from the current repository working tree (`installer` + `xreactor/**`).

`scripts/package_release.py` now performs a final strict manifest validation pass before writing the ZIP.
If manifest/release metadata is stale and `--sync` is not used, packaging fails instead of producing a broken artifact.

For publish/deploy sanity checks, verify the *published* files against the *published* manifest and fail release if any mismatch exists:

```bash
python scripts/verify_remote_manifest.py --base-url https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor --check-local --require-path shared/build_info.lua
```

You can also wire this into packaging via:

```bash
python scripts/package_release.py --sync --verify-url https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor
```

`package_release.py --verify-url` now enforces that `shared/build_info.lua` is present in the published manifest path in addition to full hash/size verification.

Deploy order must remain consistent: publish files first, then `manifest.lua` (or atomically), so installers never read a new manifest with old files.

### Current storage paths used by the installer

- Install root: `/xreactor`
- Stage root (temporary): `/xreactor_stage`
- Backup root during activation (temporary): `/xreactor_backup_prev`
- Installer log: `/xreactor_logs/installer.log`
- Role selection file: `/xreactor/config/role.lua`
- Startup file: `/startup`

## Installation

### Fresh install

In CC:Tweaked, download and run the raw installer:

```lua
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer installer
installer
```

Or run it directly:

```lua
wget run https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer
```

### Select a role

When the installer asks for a role, choose the computer’s actual purpose:

- `MASTER` for the central dashboard/orchestrator.
- `RT` for reactor/turbine control.
- `ENERGY` for matrix/storage telemetry.
- `WATER` for loop tank monitoring.
- `FUEL` for fuel reserve monitoring.
- `REPROCESSING` for reprocessing buffer monitoring.

### After install / reboot

The installer writes `/startup`, which runs `/xreactor/start.lua` on boot. `start.lua` reads `/xreactor/config/role.lua` and launches the matching runtime entrypoint automatically.

In practice:

- install once,
- reboot or let `/startup` run,
- the selected role starts automatically on that computer.

## Startup / autostart behavior

Current startup behavior is straightforward:

- `/startup` runs `/xreactor/start.lua`.
- `/xreactor/start.lua` reads `/xreactor/config/role.lua`.
- It dispatches to exactly one role entrypoint:
  - MASTER -> `/xreactor/master/main.lua`
  - RT -> `/xreactor/nodes/rt/main.lua`
  - ENERGY -> `/xreactor/nodes/energy/main.lua`
  - WATER -> `/xreactor/nodes/water/main.lua`
  - FUEL -> `/xreactor/nodes/fuel/main.lua`
  - REPROCESSING -> `/xreactor/nodes/reprocessor/main.lua`

Important current behavior:

- The installer **does** configure autostart by writing `/startup`.
- If `/startup` already exists and does **not** look like an XReactor startup file, the installer leaves it unchanged and logs a warning instead of overwriting it.

## Logging

### Installer logging

The installer always appends to:

- `/xreactor_logs/installer.log`

### Runtime logging

Runtime logs are written through the shared logger. The runtime can use disk-backed log paths when a usable disk mount exists, but this is separate from installer/update behavior (which stays local under `/xreactor*` paths).

Runtime log directory resolution:

- explicit runtime override (e.g. `xreactor.log_dir` setting or role-level `log_dir`) when valid,
- otherwise first usable disk mount like `/disk`, `/disk2`, ... as `/<disk>/xreactor_logs`,
- otherwise local fallback `/xreactor_logs`.

Typical runtime log names:

- `master_<node_id>.log`
- `loader_master.log` (optional bootstrap trace when enabled)
- `rt_<node_id>.log`
- `energy_<node_id>.log`
- `water_<node_id>.log`
- `fuel_<node_id>.log`
- `reprocessor_<node_id>.log`

Optional bootstrap loader logs can also be enabled in each role entry file (`BOOTSTRAP_LOG_ENABLED`).

For clean regression test cycles, the Master now truncates its runtime log on startup (`reset_log_on_start = true` in `xreactor/master/config.lua`).
You can also force a clean slate manually before an in-game test:

```lua
fs.delete("/xreactor_logs/master_<node_id>.log")
fs.delete("/disk/xreactor_logs/master_<node_id>.log") -- when a disk is attached
```


## Config and state files

Important current runtime files under `/xreactor/config`:

- `role.lua` - selected installed role, written by the installer.
- `node_id.txt` - optional/shared node id file used by runtime helpers when present.
- `alerts_state.lua` - persisted mute state for MASTER alerts.
- `master_ui_layout.json` - persisted MASTER monitor layout.
- `registry_<role>_<node_id>.json` - persisted device registry snapshots per role/node.
- `registry_master_monitors.json` - persisted MASTER monitor registry.

Notes:

- The installer preserves `/xreactor/config/` during updates.
- Config loaders can auto-fill missing defaults and write migrated configs back to disk.
- If a registry file is corrupt, the runtime renames it with a `.broken_<timestamp>` suffix and continues with a fresh registry state.

## Networking and runtime components

### Wireless comms

All roles use the shared comms/network stack built around the default channels:

- control: `6500`
- status: `6501`

Current runtime comms behavior includes:

- structured protocol validation,
- heartbeat/status traffic,
- command-only delivery and applied acknowledgements,
- retry/backoff handling,
- dedupe tracking,
- peer timeout/down detection with jitter tolerance (`peer_down_grace_s`) plus a minimum stale-observation gate (`peer_down_min_observations`), and up-recovery debounce (`peer_up_debounce_s`) with minimum recovery sightings (`peer_up_min_observations`) so one delayed/missed heartbeat does not instantly flap a peer down/up.
- peer timeout evaluation after ingesting newly received frames in the same tick, preventing transient DOWN→UP flaps when a heartbeat arrives near the timeout edge.
- telemetry heartbeat delay warnings when service ticks are late (helps diagnose event-loop blocking/jitter on nodes in field logs).

Modem selection is now centralized and robust:

- `wireless_modem` / `wired_modem` config entries stay supported as explicit overrides.
- If overrides are missing or invalid, runtime auto-detects modem roles from available peripherals (including `modem.isWireless()` when available).
- Selection is deterministic (stable name ordering), logs the selected wireless/wired modem, and warns clearly when falling back or when no compatible modem exists.

### Discovery and registries

Support nodes maintain a local peripheral registry and periodically rescan hardware. Discovery runs on the node-specific `discovery_interval`, independently from heartbeat timing. The registry stores bound/missing state, signatures, aliases, and scan metadata in `/xreactor/config/registry_<role>_<node_id>.json`, and only rewrites the file when the serialized registry state actually changes. Fluid-capable nodes prefer CC:Tweaked's generic `fluid_storage` API (`tanks()`) and keep older mod-specific methods only as compatibility fallbacks.
ENERGY discovery diagnostics now emit full peripheral/method dumps on startup and on real discovery signature changes, while suppressing unchanged repeated snapshots in steady state.
ENERGY now models induction data matrix-zentriert (logical matrix objects) and only groups multiple `inductionPort_*` access points when a stable topology/identity signal is available (e.g. matrix id/bounds). A plain `inductionPort_*` name prefix is intentionally not used as a grouping key, so physically separate matrices are not collapsed into one logical matrix.
ENERGY matrix polling now runs in a dedicated sampler service (`MATRIX_SAMPLE`) instead of the status-build path, so expensive peripheral reads are time-sliced independently from telemetry publishing and UI rendering.
ENERGY matrix polling keeps per-matrix/per-metric timing history and applies adaptive cadence/backoff for outlier calls, while also enforcing per-matrix call budgets plus a cumulative time budget (`matrix_metric_time_budget_ms`) so one slow reader cannot monopolize a service tick.
ENERGY keeps split matrix snapshots (dynamic: `stored/capacity/input/output`; static: `cells/providers/ports`) with freshness metadata; TELEMETRY and UI read snapshot state only, never direct heavy matrix reads.
ENERGY now keeps a persistent matrix topology cache: discovery only executes on peripheral/topology changes (or a large defensive forced-rescan interval), while matrix identity/group objects are reconciled in-place so 4 physically separate matrices stay stable without hot-path regroup churn.
ENERGY monitor discovery preserves the active wrapped monitor instance when the selected monitor name stays unchanged, preventing periodic dirty-cache invalidation and UI flicker on each discovery cycle.
ENERGY heartbeats/presence run on a hard-separated lightweight path (timer + inter-service heartbeat pump + immediate comms flush via `comms:send_heartbeat(minimal_presence_state)` and `comms:tick(ts)`), so slow UI/matrix/status ticks no longer defer heartbeat publication across multi-second manager cycles.

### Monitor behavior

- MASTER supports wired monitor management and persistent layout assignment.
- ENERGY, WATER, FUEL, RT, and REPROCESSING can render local monitor pages when a monitor is available.
- ENERGY can choose monitors using a preferred name or selection strategy.

## RT safety and turbine control notes (current behavior)

- Low coolant is handled with a confirmation window, not as immediate kill: runtime emits `COOLANT_LOW_PENDING`, waits ~4 seconds, then either enters SAFE with `SAFETY_COOLANT_LOW` or aborts the pending condition on recovery.
- Turbine control includes explicit target-band trim and readback diagnostics states such as `TARGET_TRIM_UP`, `TARGET_TRIM_DOWN`, `ACTIVE_TRIM_WITH_READBACK_LAG`, `TRIM_PENDING_CONFIRMATION`, `READBACK_SETTLING_HOLD`, and `HOLD_CONFIRMED`.
- `FLOW_READBACK_LAG` diagnostics now separate accepted-write/readback-pending (`WRITE_ACCEPTED_READBACK_PENDING`) from generic mismatch states, and pending retry escalation advances per `settle_timeout_s` window instead of every fast control tick to avoid premature retry-cap trips during delayed API readback.
- Overspeed handling uses explicit brake mode (`OVERSPEED_BRAKE`) and forces requested turbine flow to `0` while enforcing coil engagement for active braking.
- The automatic reactor rod regulator now supports explicit config clamps:
  - `autonom.regulator_min_rods` (default `80`; this equals the default `rails.reactor_rods.min` and enforces max 20% automatic power with inverted rod semantics: `100% rods = 0% power`, `0% rods = 100% power`)
  - `autonom.regulator_max_rods` (default `98`; this equals the default `rails.reactor_rods.max`)
  - valid range is `0..100`; invalid values are normalized, and if min > max the values are swapped during normalization.
  - legacy aliases `autonom.min_rods` / `autonom.max_rods` are only migration fallbacks when regulator fields are missing; if both are present, regulator fields are authoritative and legacy values are ignored with warnings.
  - clamps apply to the automatic regulator target path (with diagnostics `ROD_TARGET_CLAMPED_BY_CONFIG_MIN/MAX`), while SAFE/SCRAM still keeps authority to force rods to `100%`.
- RT now includes an internal reactor steam/hot-fluid **secondary guard** (`rails.reactor_steam_guard`), which keeps turbine-demand regulation as primary and only adds stabilizing corrections:
  - uses internal reactor steam fill ratio when available (`getHotFluidAmount*`, `getSteamAmount*`, `get*Capacity`, or `tanks()` fallback data),
  - smooths with EMA (`ema_alpha`) and applies hysteresis (`high_ratio`/`high_release_ratio`, `critical_ratio`/`critical_release_ratio`),
  - high zone: blocks further rod withdraw (`steam_guard_block_open=true`),
  - critical zone: additionally forces a small controlled close step (`force_close_step`),
  - designed to avoid oscillation by latching until release thresholds are crossed.
- Temperatur-Safety-Logs enthalten zusätzlich Regler-Kontext (`Safety temperature context: rods_current=... regulator_min_rods=... regulator_max_rods=... auto_power_cap_pct=...`), damit Übertemperatur-Fälle mit aktiven Rod-Caps im Feld klar korreliert werden können.

## Update instructions

To update an installed node/computer:

1. Run the local installer again, or download the latest `installer` from the repo.
2. Choose `Update`.
3. The installer reads the already-installed role from `/xreactor/config/role.lua`.
4. It performs storage preflight, stages expected files into `/xreactor_stage`, copies existing `/xreactor/config` into stage, validates hashes, then commits by backup+activate.
5. Commit sequence is: active `/xreactor` -> `/xreactor_backup_prev`, stage `/xreactor_stage` -> live `/xreactor`, then backup removal after successful activation.
6. Config files under `/xreactor/config/` are preserved via stage copy.

Practical update command:

```lua
installer
```

If `installer` is missing locally, re-download it first.

## If installation fails

Work from the current implementation, not older installer docs:

1. Open `/xreactor_logs/installer.log` and read the last error.
2. Make sure HTTP access is enabled in CC:Tweaked, because the installer uses `http.get`.
3. Make sure you used the **raw** GitHub URL, not a blob page.
4. Re-run the installer after fixing the issue.
5. If `/startup` was not updated, check whether an unrelated existing `/startup` file was intentionally preserved.

## Current limitations and practical notes

These are the constraints that are visible in the current codebase:

- **HTTP is required for installation and update.** The installer cannot work without the CC:Tweaked HTTP API.
- **The installer uses an active staged commit flow** for both install and update (`/xreactor_stage` + `/xreactor_backup_prev` + activation/rollback attempt on stage move failure).
- **Fresh install replaces the active install tree.** `Neuinstallation` stages a full install and then swaps it into `/xreactor` (existing runtime is moved to backup during activation and removed after successful commit).
- **Update is local-only.** The installer always stages/activates local filesystem paths; optional disk usage applies to runtime logging only.
- **Autostart only works automatically if `/startup` is writable and not protected by an unrelated script.**
- **Role changes are install-time decisions.** The updater does not re-prompt for a different role; it uses the installed role from `role.lua`.
- **Hardware availability is role-dependent.** Missing modems, monitors, tanks, matrices, storages, reactors, or turbines lead to degraded behavior, warnings, or disabled subsystems rather than magically emulated hardware.
- **Wireless modem connectivity is assumed for distributed operation.** Without a wireless modem, comms are disabled for that runtime.
- **Optional monitors remain optional.** Most roles still run without a monitor; the monitor mainly affects local UI visibility.
- **Node identity is not fully installer-driven.** The installer writes `role.lua`, but role/node-specific identity and hardware binding still come from runtime config and runtime node-id handling.
- **REPROCESSING is exposed under two names in code paths.** The user-facing role is `REPROCESSING`, while the runtime folder name is `reprocessor`.

## Development notes

- The installer manifest (`xreactor/manifest.lua`) defines which files are installed for each role.
- `tests/protocol_test.lua` covers protocol validation basics.
- `xreactor/release.lua` contains release metadata used by the current build.
- The runtime bootstrap layer is designed to load modules reliably from `/xreactor` regardless of the shell working directory.

## Quick setup checklist

1. Install the correct role on each CC computer.
2. Ensure the expected peripherals are attached to the node that owns them.
3. Verify wireless modem connectivity between MASTER and nodes.
4. Reboot once to confirm `/startup` launches the selected role.
5. Check logs if a node comes up degraded or fails discovery.
