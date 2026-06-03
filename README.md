# XReactor Controller V3

XReactor is a distributed controller stack for **CC:Tweaked** systems connected to **Extreme Reactors** and optional support infrastructure. It is built around one **MASTER** computer and multiple role nodes. Hardware control stays local to the node that owns the peripherals; MASTER aggregates state and sends control intent.

## Aktueller Dokumentationsstand

Stand: **2026-06-03**.

The current architecture/status audit is tracked in:

- [`RUNTIME_STATUS_2026-06-03.md`](RUNTIME_STATUS_2026-06-03.md)

Important status boundaries:

- No in-game test is claimed for the current audit.
- Runtime code was not changed during the documentation refresh.
- The remaining open work is mostly packaging/integration consistency, not a new architecture rewrite.

Current next cleanup order:

1. Manifest metadata consistency.
2. LOG role integration decision and cleanup.
3. Release/build identity cleanup.
4. MASTER alert-message-type cleanup.
5. ENERGY config-default consolidation.

## Schnellinstallation

On a new CC:Tweaked computer with HTTP enabled, download the root `installer` from the `beta` branch, save it as `/installer`, then run `/installer`.

The installer shows `Neuinstallation`, `Update`, and `Abbrechen`. It installs the runtime under `/xreactor` and writes the XReactor startup entry when safe to do so.

Note: `wget run` only runs a temporary copy. For normal installs, save the installer permanently as `/installer` first.

## System goals

- Keep hardware control **local to the node** that owns the peripherals.
- Let the **MASTER** aggregate telemetry, alerts, node health, and UI views.
- Allow the **RT** node to continue operating when the MASTER is unavailable.
- Keep installation/update simple with one installer and one runtime root.
- Keep MASTER decisions and RT actuator writes separated: MASTER sends intent/setpoints, RT performs real peripheral control and safety enforcement locally.

## Roles

### MASTER

**Purpose:** Central coordinator and dashboard.

MASTER receives node status, heartbeat, and alert traffic, tracks peer/comms health, renders the operator UI, and sends commands/setpoints through the command/ACK protocol. It does **not** directly control reactor, turbine, or storage peripherals.

Key runtime areas:

- `xreactor/master/runtime_context.lua`
- `xreactor/master/message_handlers.lua`
- `xreactor/master/runtime_ops_rt.lua`
- `xreactor/master/startup_sequencer.lua`
- `xreactor/master/ui_controller.lua`
- `xreactor/master/monitor_sessions.lua`
- `xreactor/master/ui/*`

### RT

**Purpose:** Reactor/turbine control node.

RT owns all local reactor/turbine hardware writes and safety enforcement. Fresh installs use auto-discovery by default when `reactors` / `turbines` config lists are empty. Explicit lists restrict binding to those names.

RT local operating modes include `AUTONOM`, `MASTER`, and `SAFE`. Remote setpoints are accepted only when the RT node is in local `MASTER` mode. Safety conditions can transition the node into `SAFE`/`EMERGENCY` and apply SCRAM locally.

Key runtime areas:

- `xreactor/nodes/rt/main.lua`
- `xreactor/nodes/rt/command_handler.lua`
- `xreactor/nodes/rt/state_handlers.lua`
- `xreactor/nodes/rt/module_lifecycle.lua`
- `xreactor/nodes/rt/flow_apply_helpers.lua`
- `xreactor/nodes/rt/reactor_steam_guard.lua`
- `xreactor/core/control_rails.lua`
- `xreactor/core/turbine_regulator.lua`
- `xreactor/core/safety.lua`

### ENERGY

**Purpose:** Power telemetry node.

ENERGY discovers energy storage and induction matrix peripherals, samples them through cached snapshot runtimes, and reports aggregate power/storage state to MASTER. ENERGY does not control reactor/turbine hardware.

Heavy storage/matrix sampling is intentionally detached from telemetry/UI paths. Heartbeats remain lightweight so MASTER liveness is not blocked by slow matrix or storage API calls.

Key runtime areas:

- `xreactor/nodes/energy/main.lua`
- `xreactor/nodes/energy/discovery_runtime.lua`
- `xreactor/nodes/energy/matrix_snapshot_runtime.lua`
- `xreactor/nodes/energy/storage_snapshot_runtime.lua`
- `xreactor/nodes/energy/status_payload.lua`
- `xreactor/nodes/energy/ui_model.lua`
- `xreactor/nodes/energy/ui_pages.lua`

### WATER

**Purpose:** Water loop monitoring/balancing node.

WATER monitors configured loop tanks, tracks a target volume, reports total water/health, and logs refill/bleed suggestions around the configured target. It can render local monitor diagnostics.

### FUEL

**Purpose:** Fuel reserve monitoring node.

FUEL reads a configured storage bus, reports reserve state, and supports the `SET_RESERVE` command. It does not directly control reactor hardware.

### REPROCESSING

**Purpose:** Reprocessing buffer telemetry/utility node.

REPROCESSING monitors configured buffers, reports local state and health, supports `MODE OFF` / `MODE RUNNING` standby behavior, and can call a local buffer `process()` method when present and not in standby. The installer/startup role label is **REPROCESSING** while the runtime folder is `xreactor/nodes/reprocessor`.

### LOG collector

**Purpose:** Optional log collection utility.

The LOG collector listens for `LOG_EVENT` payloads on the log channel and writes per-role/per-node logs to a disk ring or fallback directory. It supports disk discovery, write probing, rotation, and pruning.

Current status note: the manifest contains a LOG/LOG_COLLECTOR role entry, but LOG integration is not yet fully aligned across all shared role constants/schema/bootstrap paths. This is listed as an open cleanup item in the runtime status document.

## Runtime architecture

At runtime, the project is split into these active areas:

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
    reprocessor/           Reprocessing node
    log_collector/         Optional LOG collector utility
    support/               Shared WATER/FUEL/REPROCESSING helpers
tests/                     Regression and guard tests
scripts/                   Development/CI helper scripts
```

## Control architecture

The MASTER calculates desired intent and sends commands. The RT node owns all real hardware writes and safety-critical decisions. A MASTER UI/profile change never touches a reactor or turbine directly; it produces a command that the target node may accept, reject, acknowledge, or ignore depending on its local state.

Control flow summary:

1. Operator input changes MASTER UI/profile/AUTO/RT-HOLD state.
2. MASTER builds RT intent and setpoint plans.
3. `services.comms_service.lua` sends commands through `core.comms.lua`.
4. RT `command_handler.lua` validates the command and local mode.
5. RT state-machine ticks apply local reactor/turbine control and safety.

## Installer behavior

The current installer is the root-level file `installer`. It is the only installer entrypoint in this repository.

On launch it shows:

1. `Neuinstallation`
2. `Update`
3. `Abbrechen`

Fresh install currently:

1. Prompts for one role.
2. Downloads `xreactor/manifest.lua` from the `beta` branch raw GitHub URL.
3. Runs storage preflight checks.
4. Downloads expected base + selected role files into `/xreactor_stage`.
5. Validates staged files/hashes when manifest metadata is available.
6. Writes the selected role config into the staged tree.
7. Activates the stage by moving it to `/xreactor`.
8. Writes the XReactor startup entry when safe.
9. Logs progress to `/xreactor_logs/installer_<role>.log`.

Update currently:

1. Downloads the current manifest.
2. Reads the installed role from `/xreactor/config/role.lua`.
3. Runs storage preflight checks.
4. Downloads expected base + installed role files into `/xreactor_stage`.
5. Copies existing `/xreactor/config` into stage.
6. Validates staged files/hashes when manifest metadata is available.
7. Activates the stage and preserves/recreates XReactor startup wiring.
8. Logs progress to `/xreactor_logs/installer_<role>.log`.

The root `installer` is a standalone bootstrap entrypoint: if the modular installer runtime files are missing, it downloads the required installer modules first and then continues the normal install/update flow.

## Download validation

The installer rejects missing/empty files, rejects HTML content, parses `.lua` files before accepting them, and checks `size_bytes` / CRC32 `hash` when that metadata is present in `xreactor/manifest.lua`.

Current status note: not every manifest entry has complete metadata yet. Completing that metadata is the next planned cleanup item.

## Tests and guards

The repository includes Lua and Python tests plus guard scripts. Important current guard areas include:

- protocol validation,
- manifest/entrypoint coverage,
- CC/Lua parser pressure checks,
- RT main structure/bloat guards,
- ENERGY sampling/heartbeat/topology regressions,
- support-node shared-runtime regressions.

No new green test-run claim is made by this README update. See `RUNTIME_STATUS_2026-06-03.md` for the current code-reading status and open work list.
