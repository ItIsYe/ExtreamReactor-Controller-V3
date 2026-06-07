# XReactor Controller V3

XReactor is a distributed controller stack for **CC:Tweaked** systems connected to **Extreme Reactors** and optional support infrastructure. It is built around one **MASTER** computer and several specialized role nodes that manage hardware locally and exchange state over wireless modem channels.

The current repository ships:

- a **single-file installer** (`installer`) for fresh installs and updates,
- a role-based runtime under `/xreactor`,
- a startup entrypoint that launches the selected role automatically,
- per-role configs, local registries, telemetry, alerts, and monitor UIs.

## Schnellinstallation

Auf einem neuen CC:Tweaked-Computer mit aktivierter HTTP-API kann der Installer dauerhaft als `/installer` abgelegt und danach gestartet werden:

```sh
delete /installer
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
/installer
```

Damit bleibt der Installer fest auf dem Computer gespeichert. Nach dem Start zeigt er das Installationsmenü für `Neuinstallation`, `Update` und `Abbrechen`. Die Installation selbst legt die Runtime unter `/xreactor` ab und schreibt den XReactor-Startup-Eintrag nach `/startup`.

Wichtig: `wget run ...` lädt den Installer nur temporär und speichert ihn nicht dauerhaft. Für normale Installationen deshalb den obigen Befehl mit Zielpfad `/installer` verwenden.

## System goals

- Keep hardware control **local to the node** that owns the peripherals.
- Let the **MASTER** aggregate telemetry, alerts, node health, and UI views.
- Allow the **RT** node to continue operating when the MASTER is unavailable.
- Keep installation/update simple with one installer and one runtime root.
- Keep MASTER decisions and RT actuator writes separated: MASTER sends intent/setpoints, RT performs real peripheral control and safety enforcement locally.

## Roles

### MASTER
**Purpose:** Central coordinator and dashboard.

**Controls / responsibilities:**
- Receives node status, heartbeat, and alert traffic over wireless modem channels.
- Sends commands and setpoints to nodes using the command/ack protocol.
- Runs the startup sequencer for RT nodes.
- Computes RT assignment, startup, shed, standby, and shutdown plans from the current `power_target`, RT node health, node mode, and global RT hold state.
- Renders the main UI, including overview, RT, energy, resources, alarms, alerts, and multi-monitor views.
- Tracks peer state, retries, queue metrics, and comms timeouts.

**Expected behavior:**
- Starts from `/xreactor/master/main.lua`.
- Uses wired monitors when present.
- Shows UTC wall-clock time in the MASTER UI (not CC:Tweaked in-game time).
- Does **not** directly control reactor, turbine, or storage peripherals; those stay on the role nodes.
- Sends RT control intent through command payloads such as `SET_MODE`, `SET_SETPOINTS`, and `STARTUP_STAGE`.
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
- Accepts MASTER commands for mode changes and setpoints when the RT node is in local `MASTER` mode.
- Rejects or ignores remote setpoints in local `AUTONOM` or `SAFE` mode, so local safety and fallback behavior always win.
- Enforces local safety rules such as temperature/coolant-related limits.
- Performs the actual actuator writes to local peripherals: reactor activation, rod levels, turbine activation, turbine flow, and turbine inductor/coil state.

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

### LOG / LOG_COLLECTOR
**Purpose:** Central log collector node.

**Controls / responsibilities:**
- Receives remote log traffic from other XReactor nodes.
- Writes collected logs to attached disk storage.
- Maintains its own local/self log so the collector can be diagnosed.
- Provides the dedicated role-7 runtime entrypoint for log collection.

**Expected behavior:**
- Starts from `/xreactor/nodes/log_collector/main.lua`.
- Is selected in the installer as role `7 LOG`.
- May also be launched from role config value `LOG_COLLECTOR`.
- Should stay independent from the MASTER UI; MASTER UI behavior must not be changed for log-collector display work.

## Runtime architecture

At runtime, the project is split into a small set of active areas:

- `xreactor/core/` - shared runtime internals such as bootstrap loading, network/comms, logging, registry handling, UI helpers, control rails, turbine regulation, and safety helpers.
- `xreactor/services/` - reusable services for comms, discovery, telemetry, alerts, UI ticks, and service lifecycle management.
- `xreactor/master/` - MASTER-specific config, profile handling, RT sync planning, startup sequencing, UI views, monitor sessions, and UI diagnostics.
- `xreactor/nodes/` - role-specific node implementations for `rt`, `energy`, `water`, `fuel`, `reprocessor`, and `log_collector`.
- `xreactor/nodes/support/` - shared non-RT support-node runtime/discovery/ui/command helpers used by `water`, `fuel`, and `reprocessor`.
- `xreactor/adapters/` - peripheral adapters for reactors, turbines, monitors, energy storage, and induction matrices.
- `xreactor/shared/` - shared constants, colors, telemetry schema, build info, and health codes.
- `xreactor/manifest.lua` - installer manifest listing the files for the base runtime and each role. Current beta manifests use `hash_algo = "none"`; size/hash metadata is not mandatory in the active beta manifest.
- `xreactor/start.lua` - startup router that reads the installed role and launches the correct entrypoint.
- `installer` - single-file installer/update entrypoint for deployment.

### Control architecture

The control path is intentionally layered:

```text
Operator touch / AUTO / profile / RT-HOLD
        │
        ▼
MASTER ui_controller.lua
        │
        ▼
runtime_ops_profile.lua / runtime_ops_rt.lua
        │
        ▼
master.rt_sync.build_node_setpoint_plan()
        │
        ├─ SET_MODE
        ├─ SET_SETPOINTS
        └─ STARTUP_STAGE via startup_sequencer.lua
        │
        ▼
services.comms_service.lua -> core.comms.lua
        │
        ▼
RT nodes/rt/command_handler.lua
        │
        ├─ SET_MODE      -> state_handlers.apply_mode()
        ├─ SET_SETPOINTS -> local targets + optional desired node state
        ├─ STARTUP_STAGE -> module_lifecycle.start_module()
        └─ SCRAM         -> SAFE
        │
        ▼
RT node state-machine tick
        │
        ├─ Turbines: update_inductor_for_rpm(), update_turbine_flow_state(), setTurbineFlow()
        ├─ Reactors: controlReactor(), control_rails, reactor_steam_guard, applyReactorRods()
        └─ Safety: module_lifecycle.update_module_states() -> SAFE/EMERGENCY/SCRAM
```

The MASTER calculates desired intent and sends commands. The RT node owns all real hardware writes and safety-critical decisions. This means a MASTER UI/profile change never touches a reactor or turbine directly; it produces a command that the target node may accept, reject, acknowledge, or ignore depending on its local state.

### MASTER to RT sync

`xreactor/master/rt_sync.lua` evaluates every known RT node and builds a setpoint plan from:

- global `power_target`,
- `rt_global_off_hold`,
- RT node mode and node state,
- node health/offline/emergency state,
- configured per-node capacity and startup/shutdown margins.

The plan assigns nodes into states such as `active`, `startup`, `shed`, `standby`, `shutdown`, or `unavailable`. From that it produces RT setpoints containing `target_rpm`, `power_target`, `steam_target`, `enable_reactors`, `enable_turbines`, assignment metadata, and optional shutdown intent.

`xreactor/master/runtime_ops_rt.lua` wraps this in a controlled shutdown workflow. Shutdown is not a single blind command; it moves through rampdown, request, ack wait, state wait, completion, or failure states.

`xreactor/master/startup_sequencer.lua` handles staged startup and orders turbine modules before reactor modules. It waits for applied ACKs and stable module status before advancing to the next startup step.

### RT command and actuator layer

`xreactor/nodes/rt/command_handler.lua` is the remote command gate. It accepts setpoints only while the RT node is in local `MASTER` mode. It rejects unsafe or invalid requests and records command results for ACK_APPLIED responses.

`xreactor/nodes/rt/state_handlers.lua` owns the RT operating transitions and the node state-machine behavior. It is responsible for `AUTONOM`, `MASTER`, and `SAFE` behavior, startup transitions, fallback to autonomous mode on MASTER timeout, and emergency transitions.

`xreactor/nodes/rt/module_lifecycle.lua` owns module startup, stable/running/limited/error state transitions, safety limit checks, and SCRAM behavior.

The actual RT actuator writes are performed through:

- `setReactorActive(...)` -> reactor `setActive`, when available,
- `applyReactorRods(...)` -> reactor adapter rod write path,
- `setTurbineActive(...)` -> turbine `setActive`, when available,
- `setTurbineFlow(...)` -> `setFluidFlowRate` or `setFluidFlowRateMax`,
- `setInductor(...)` / `update_inductor_for_rpm(...)` -> turbine inductor/coil control.

### RT capacity learning

RT capacity learning is intentionally local to the RT node and does not depend on the MASTER completing a control cycle.

Current beta behavior:
- RT learns usable output from local turbine telemetry.
- RPM stability uses a 10% tolerance around target RPM because turbine RPM is regulated and will not be perfectly fixed.
- Three stable producing samples are enough to lock learned capacity.
- Until capacity is locked, MASTER `SET_SETPOINTS` commands are rejected with reason code `CAPACITY_LEARNING`.
- After `capacity_ready` is true, RT accepts MASTER setpoints again in the normal `MASTER` mode flow.
- This prevents the MASTER from forcing final setpoints before the RT node has learned its local capacity.

### RT regulation and safety

`xreactor/core/control_rails.lua` provides the generic regulator mechanics used by RT control:

- clamp with reason,
- EMA smoothing,
- deadband and hysteresis,
- cooldown,
- adaptive step sizing,
- ramp profiles,
- rod ramp limiting,
- coolant-sensitive limits when opening rods / increasing output.

`xreactor/core/turbine_regulator.lua` adds turbine-specific behavior:

- startup target detection,
- requested-vs-confirmed flow matching,
- readback-lag handling,
- learned effective minimum flow,
- target-band hold/trim behavior,
- overspeed brake behavior that can request zero flow and coil engagement,
- bottleneck classification for diagnostics.

`xreactor/core/safety.lua` and `xreactor/nodes/rt/module_lifecycle.lua` enforce safety locally. Temperature and coolant limits can transition the RT node into `SAFE`/`EMERGENCY` and trigger SCRAM behavior. `xreactor/nodes/rt/reactor_steam_guard.lua` prevents unsafe rod opening when reactor internal steam fill is high and can force extra rod insertion at critical fill levels.

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

### UI inspiration and attribution

The monitor UI in this repository is a custom CC:Tweaked terminal/monitor UI layer. It renders directly through the ComputerCraft terminal and monitor APIs (`term.redirect`, `term.write`, colors, monitor scale, and `monitor_touch` events) and does not embed or require an external UI library at runtime.

The design is conceptually inspired by general ComputerCraft UI frameworks and monitor-dashboard patterns, especially Basalt/Basalt2-style page/widget/event organization and older ComputerCraft GUI approaches such as Bedrock. These projects are noted as design inspiration only; the current runtime uses XReactor's own UI helpers, routing, models, and view files.

### Roadmap-Status (Non-RT)

Der große Nicht-RT-Umbau ist auf dem aktuellen Stand abgeschlossen (Final-Audit 2026-04-22, siehe `NON_RT_CLOSEOUT_2026-04-22.md`):
- gemeinsame Nicht-RT-Bausteine sind aktiv,
- ENERGY/MASTER/Installer laufen modular,
- WATER/FUEL/REPROCESSOR nutzen die gemeinsame Support-Schicht.

RT bleibt bewusst als separater Stabilisierungsbereich behandelt; Shutdown-/Standby-/Mehrknotenlogik wird dort weiterhin aktiv weiterentwickelt und separat auditiert.

Support-node architecture note:
- `water`, `fuel`, and `reprocessor` keep role-specific control logic local, but share common discovery classification/runtime wiring via `nodes/support/*`.
- RT (`xreactor/nodes/rt/*`) is intentionally separate and not part of these shared non-RT support abstractions.

### Fuel logistics roadmap

Fuel logistics is planned as a later extension of the existing **FUEL** node, not as a new standalone node.

Planned direction:
- use wired-modem `inventory` peripherals for targeted item routing,
- keep the existing FUEL node as the owner of fuel distribution logic,
- route input sources to specific reactor or reprocessing targets by explicit rules,
- log each transfer and expose diagnostics through the normal node status/logging path.

This is intentionally deferred. First priority is to stabilize the current MASTER ↔ RT ↔ ENERGY integration, including RT capacity learning, ENERGY telemetry, and LOG collector reliability.

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
    log_collector/         Central log collector node
tests/
  protocol_test.lua        Protocol validation test
  manifest_entrypoint_require_coverage_test.py
                            Manifest/entrypoint coverage and critical shipment metadata test
```

## Installer behavior

The current installer is the root-level file `installer`. It is the only installer entrypoint in this repository.

### Persistent installer command

Use this command on the target CC:Tweaked computer to install the installer itself permanently at `/installer`:

```sh
delete /installer
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
/installer
```

The installer source is fixed to the repository `beta` branch during normal install/update. The root installer bootstraps the modular installer runtime into `/xreactor` before the normal installation flow continues.

### What the installer does

On launch it shows a simple menu:

1. `Neuinstallation`
2. `Update`
3. `Abbrechen`

### Fresh install flow

`Neuinstallation` currently does the following:

1. Prompts for one role (`MASTER`, `RT`, `ENERGY`, `WATER`, `FUEL`, `REPROCESSING`, `LOG`).
2. Downloads `xreactor/manifest.lua` from the `beta` branch raw GitHub URL.
3. Runs storage preflight checks (including stage/peak + buffer estimation and optional cleanup of stale stage/backup artifacts).
4. Downloads the expected base + selected role files into `/xreactor_stage` and validates staged files.
5. Writes the selected role config into the staged tree and ensures `/xreactor/config/role.lua` exists after activation.
6. Commits stage activation by moving current `/xreactor` to `/xreactor_backup_prev`, moving stage to `/xreactor`, and removing backup after successful commit.
7. Writes `/startup` with `shell.run("/xreactor/start.lua")`, unless an existing `/startup` looks unrelated to XReactor.
8. Logs progress to `/xreactor_logs/installer_<role>.log` (bootstrap: `/xreactor_logs/installer_bootstrap.log`).
9. Reboots automatically after a successful fresh installation.

### Standalone bootstrap guarantee

The root `installer` is a real standalone entrypoint for fresh systems:

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
5. Copies existing `/xreactor/config` into stage and validates staged files.
6. Commits stage activation by moving active `/xreactor` to `/xreactor_backup_prev`, activating `/xreactor_stage` as `/xreactor`, and deleting backup after successful activation.
7. Rewrites/ensures the XReactor startup file at `/startup` if the existing startup belongs to XReactor.
8. Logs progress to `/xreactor_logs/installer_<role>.log` (bootstrap: `/xreactor_logs/installer_bootstrap.log`).
9. Reboots automatically after a successful fresh installation.

### Download validation

The installer validates downloaded files before keeping them:

- rejects missing or empty files,
- rejects HTML content,
- parses `.lua` files before accepting them,
- uses manifest metadata when present.

Current beta manifests use `hash_algo = "none"`. That means `size_bytes` and CRC32 `hash` metadata are not mandatory for the active beta install path. The installer must not fail a beta install solely because old size/hash metadata is stale; it should still fail for missing files, invalid Lua, or invalid downloaded content.

To reduce GitHub raw cache races between a fresh `manifest.lua` and staged file downloads, the installer appends a cache-busting `xr_cb=...` query token to manifest, release, and staged file download URLs while still staying on the `beta` branch strategy.

Storage preflight also handles CC:Tweaked `fs.getFreeSpace()` special values: `number`, negative-as-unbounded, and `"unlimited"`.
