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
- Does **not** directly control reactor, turbine, or storage peripherals; those stay on the role nodes.

### RT
**Purpose:** Reactor/turbine control node.

**Controls / responsibilities:**
- Detects and manages Extreme Reactors reactors and turbines.
- Applies local control rails for rods, turbine flow, and coil engagement.
- Executes startup sequencing and startup watchdog logic.
- Accepts MASTER commands for mode changes and setpoints.
- Enforces local safety rules such as temperature/coolant-related limits.

**Expected behavior:**
- Supports local operating states such as `AUTONOM`, `MASTER`, and `SAFE`.
- If MASTER comms are lost, it can fall back to autonomous behavior instead of hard-stopping.
- Can drive an attached local monitor UI.

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
- `xreactor/adapters/` - peripheral adapters for reactors, turbines, monitors, energy storage, and induction matrices.
- `xreactor/shared/` - shared constants, colors, telemetry schema, build info, and health codes.
- `xreactor/manifest.lua` - installer manifest listing the files for the base runtime and each role.
- `xreactor/start.lua` - startup router that reads the installed role and launches the correct entrypoint.
- `installer` - single-file installer/update entrypoint for deployment.

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

1. Deletes the existing `/xreactor` install root if it exists.
2. Prompts for one role:
   - `MASTER`
   - `RT`
   - `ENERGY`
   - `WATER`
   - `FUEL`
   - `REPROCESSING`
3. Downloads `xreactor/manifest.lua` from the `beta` branch raw GitHub URL.
4. Downloads the shared base files plus only the selected role files into `/xreactor`.
5. Writes `/xreactor/config/role.lua` with the selected role.
6. Writes `/startup` with `shell.run("/xreactor/start.lua")`, unless an existing `/startup` looks unrelated to XReactor.
7. Logs progress to `/xreactor_logs/installer.log`.

### Update flow

`Update` currently does the following:

1. Downloads the current manifest.
2. Reads the installed role from `/xreactor/config/role.lua`.
3. Updates only missing or changed files for that role based on manifest CRC32 hashes.
4. Removes obsolete files under `/xreactor`, except anything under `/xreactor/config/`.
5. Rewrites/ensures the XReactor startup file at `/startup` if the existing startup belongs to XReactor.
6. Logs progress to `/xreactor_logs/installer.log`.

### Download validation

The installer validates downloaded files before keeping them:

- rejects missing or empty files,
- rejects HTML content,
- parses `.lua` files before accepting them.

That means blob/HTML downloads are explicitly treated as installation failures.

### Current storage paths used by the installer

- Install root: `/xreactor`
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

Runtime logs are written through the shared logger. If `/disk` exists, the runtime log directory moves there automatically; otherwise it stays under the root filesystem.

Runtime log directory resolution:

- `/disk/xreactor_logs` if `/disk` exists
- otherwise `/xreactor_logs`

Typical runtime log names:

- `master_<node_id>.log`
- `rt_<node_id>.log`
- `energy_<node_id>.log`
- `water_<node_id>.log`
- `fuel_<node_id>.log`
- `reprocessor_<node_id>.log`

Optional bootstrap loader logs can also be enabled in each role entry file (`BOOTSTRAP_LOG_ENABLED`).

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
- peer timeout/down detection.

### Discovery and registries

Support nodes maintain a local peripheral registry and periodically rescan hardware. Discovery runs on the node-specific `discovery_interval`, independently from heartbeat timing. The registry stores bound/missing state, signatures, aliases, and scan metadata in `/xreactor/config/registry_<role>_<node_id>.json`, and only rewrites the file when the serialized registry state actually changes. Fluid-capable nodes prefer CC:Tweaked's generic `fluid_storage` API (`tanks()`) and keep older mod-specific methods only as compatibility fallbacks.

### Monitor behavior

- MASTER supports wired monitor management and persistent layout assignment.
- ENERGY, WATER, FUEL, RT, and REPROCESSING can render local monitor pages when a monitor is available.
- ENERGY can choose monitors using a preferred name or selection strategy.

## Update instructions

To update an installed node/computer:

1. Run the local installer again, or download the latest `installer` from the repo.
2. Choose `Update`.
3. The installer reads the already-installed role from `/xreactor/config/role.lua`.
4. It refreshes only files for that role and the shared base runtime.
5. Config files under `/xreactor/config/` are left in place.

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
- **The installer only supports two active operations:** fresh install and update. There is no active stage/backup/rollback flow in the current installer.
- **Fresh install is destructive for `/xreactor`.** `Neuinstallation` deletes the existing install root before downloading the selected role runtime.
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
