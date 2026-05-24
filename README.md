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
- Uses a fixed 3-primary-monitor mapping when at least three MASTER monitors are bound:
  - monitor 1 -> `overview`
  - monitor 2 -> `rt`
  - monitor 3 -> `energy`
- Keeps MASTER monitor text scale explicitly fixed at `1.0` (`monitor_scale` and `ui_scale_default` in `xreactor/master/config.lua`).
- Uses a session-based monitor UI pipeline built from:
  - `xreactor/master/monitor_sessions.lua` for monitor/session state and binding,
  - `xreactor/master/ui/multiview.lua` for per-session render/input orchestration,
  - `xreactor/master/ui_diagnostics.lua` for compact UI shape diagnostics.
- Keeps touch controls on the Overview view only; Overview is the place for primary operator actions such as profile selection, AUTO toggle, and RT hold toggle.

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
- `xreactor/master/` - MASTER-specific config, sequencer, UI views, monitor sessions, and UI diagnostics.
- `xreactor/nodes/` - role-specific node implementations for `rt`, `energy`, `water`, `fuel`, and `reprocessor`.
- `xreactor/nodes/support/` - shared non-RT support-node runtime/discovery/ui/command helpers used by `water`, `fuel`, and `reprocessor`.
- `xreactor/adapters/` - peripheral adapters for reactors, turbines, monitors, energy storage, and induction matrices.
- `xreactor/shared/` - shared constants, colors, telemetry schema, build info, and health codes.
- `xreactor/manifest.lua` - installer manifest listing the files for the base runtime and each role.
- `xreactor/start.lua` - startup router that reads the installed role and launches the correct entrypoint.
- `installer` - single-file installer/update entrypoint for deployment.

### MASTER monitor UI architecture (current)

The current MASTER monitor UI is organized in four layers:

1. `xreactor/core/monitor_manager.lua`
   - discovers and wraps bound MASTER monitors,
   - caches wrapped monitor objects per peripheral name across scans to avoid false monitor rebinds from wrapper churn,
   - applies monitor text scale only when needed,
   - persists and restores the MASTER monitor registry.

2. `xreactor/master/monitor_sessions.lua`
   - keeps stable session state per physical monitor,
   - owns primary/aux binding decisions,
   - tracks render/input lifecycle state such as dirty/full-clear/rebind/input metadata.

3. `xreactor/master/ui/multiview.lua`
   - acts as the render/input orchestrator,
   - asks the session layer which view a monitor should render,
   - dispatches touches into the active view hit-test/action path.

4. `xreactor/master/ui_controller.lua` plus the view files in `xreactor/master/ui/`
   - builds per-view UI models,
   - renders the `overview`, `rt`, and `energy` primary dashboard views.

Current MASTER monitor policy:
- exactly one active primary view per primary monitor,
- no standby/fallback secondary UI mode,
- no full clear on every frame,
- no repeated `setTextScale(...)` on every monitor refresh,
- initial MASTER UI bootstrap now runs through the regular UI service tick path instead of a separate one-off draw path,
- current primary dashboard finish work is focused on the three view files:
  - `xreactor/master/ui/overview.lua`
  - `xreactor/master/ui/rt_dashboard.lua`
  - `xreactor/master/ui/energy.lua`


### Roadmap-Status (Non-RT)

Der große Nicht-RT-Umbau ist auf dem aktuellen Stand abgeschlossen (Final-Audit 2026-04-22, siehe `NON_RT_CLOSEOUT_2026-04-22.md`):
- gemeinsame Nicht-RT-Bausteine sind aktiv,
- ENERGY/MASTER/Installer laufen modular,
- WATER/FUEL/REPROCESSOR nutzen die gemeinsame Support-Schicht.

RT bleibt bewusst als separater Stabilisierungsbereich behandelt; Shutdown-/Standby-/Mehrknotenlogik wird dort weiterhin aktiv weiterentwickelt und separat auditiert.

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
8. Logs progress to `/xreactor_logs/installer_<role>.log (bootstrap: /xreactor_logs/installer_bootstrap.log)`.

### Standalone bootstrap guarantee

The root `installer` is now a real standalone entrypoint for fresh systems:

- if `/xreactor/installer_main.lua` and the modular installer runtime files are missing, the root installer downloads
  `installer_main.lua`, `installer_http.lua`, `installer_manifest.lua`, `installer_stage.lua`, `installer_startup.lua`, and `installer_storage.lua` first,
- downloaded bootstrap files are validated (reject HTML, parse Lua before writing),
- then normal install/update flow continues.

This means a fresh machine only needs the single root `installer` file to begin installation.

### Update flow

`Update` currently does the following:

1. Downloads the current manifest.
2. Reads the installed role from `/xreactor/config/role.lua`.
3. Runs storage preflight checks for update mode.
4. Downloads the expected base + installed role files into `/xreactor_stage`.
5. Copies existing `/xreactor/config` into stage and validates staged files/hashes.
6. Commits stage activation by moving active `/xreactor` to `/xreactor_backup_prev`, activating `/xreactor_stage` as `/xreactor`, and deleting backup after successful activation.
7. Rewrites/ensures the XReactor startup file at `/startup` if the existing startup belongs to XReactor.
8. Logs progress to `/xreactor_logs/installer_<role>.log (bootstrap: /xreactor_logs/installer_bootstrap.log)`.

### Download validation

The installer validates downloaded files before keeping them:

- rejects missing or empty files,
- rejects HTML content,
- parses `.lua` files before accepting them.

To reduce GitHub raw cache races between a fresh `manifest.lua` and staged file downloads, the installer appends a cache-busting `xr_cb=...` query token to manifest, release, and staged file download URLs while still staying on the `beta` branch strategy.

Storage preflight also handles CC:Tweaked `fs.getFreeSpace()` special values: `number`, negative-as-unbounded, and `"unlimited"`.
