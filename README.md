# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development.  
> **Manifest / Release:** `manifest-v156` / `beta-v156` · 131 files · ATM10 (MC 1.21.1)  
> **Beta status:** known node start blockers are documented in [docs/NODE_START_BLOCKERS_2026-06-25.md](docs/NODE_START_BLOCKERS_2026-06-25.md). Do not treat this branch as ready for ingame rollout until those blockers are fixed and statically checked.  
> See [docs/PROJECT_DOCUMENTATION.md](docs/PROJECT_DOCUMENTATION.md) for the full technical reference.

---

## Current Handoff / Cleanup Docs

- [docs/README.md](docs/README.md) — documentation index.
- [docs/NODE_START_BLOCKERS_2026-06-25.md](docs/NODE_START_BLOCKERS_2026-06-25.md) — current RT/FUEL/WATER/REPROCESSING/ENERGY blockers and fix notes.
- [RUNTIME_STATUS_2026-06-03.md](RUNTIME_STATUS_2026-06-03.md) — runtime audit / cleanup handoff history.

Important beta note: `xreactor/manifest.lua` currently uses `hash_algo = "none"` intentionally for the moving beta branch. Do not revert that as part of normal cleanup; regenerate manifest metadata from a real checkout first if CRC32 checks should be restored.

---

## Quick Install

On any new CC:Tweaked computer with HTTP enabled:

```sh
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
shell.run("/installer")
```

The installer downloads the manifest, lets you pick a role, stages all required files, writes `/startup`, and reboots automatically.

**Update / reinstall:** Run `/installer` again — detects existing role and asks whether to keep or change it.

**Remote Update:** Trigger a Redstone signal on the `top` side of the MASTER computer. The Master broadcasts a `REMOTE_UPDATE` command to all connected nodes and updates itself. Each node downloads the installer and reboots automatically (non-interactive).

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                       MASTER                         │
│  UI · Alerts · Telemetry · Setpoints · Profiles      │
└──────┬───────────────────────────┬───────────────────┘
       │ Ender Modem (ch 6500/6501)│
  ┌────▼────┐  ┌────────┐  ┌──────▼──────┐  ┌─────┐
  │   RT    │  │ ENERGY │  │ WATER/FUEL/ │  │ LOG │
  │Reactor  │  │Matrix  │  │REPROCESSING │  │     │
  │Turbines │  │Storage │  │ Support     │  │     │
  └─────────┘  └────────┘  └─────────────┘  └─────┘
```

**Key design rule (SCADA principle):** MASTER sends only a percentage setpoint (`power_target_percent`) and a state intent (`assignment_state`). Each RT node autonomously decides how many turbines run, which are at partial load, and how to position reactor rods — the Master has no knowledge of individual turbine RPM or flow rates.

### Modem Channels

| Channel | Purpose |
|---------|---------|
| 6500 | Control — MASTER → nodes (commands, setpoints) |
| 6501 | Status — nodes → MASTER (heartbeat, status payloads) |
| 6502 | Log transport — all nodes → LOG collector |

---

## Roles

| Role | Entrypoint | Required Peripherals |
|------|-----------|---------------------|
| `MASTER` | `master/main.lua` | Monitor(s), Ender Modem |
| `RT` | `nodes/rt/main.lua` | ER2 Reactor, ER2 Turbines, Ender Modem |
| `ENERGY` | `nodes/energy/main.lua` | Mekanism Induction Matrix, Ender Modem |
| `WATER` | `nodes/water/main.lua` | Ender Modem |
| `FUEL` | `nodes/fuel/main.lua` | Ender Modem, Wired Modem |
| `REPROCESSING` | `nodes/reprocessor/main.lua` | Ender Modem, Wired Modem |
| `LOG` | `nodes/log_collector/main.lua` | Disk Drive(s), Ender Modem |

---

## Boot Sequence

Nodes start in a fixed order to ensure the Master is ready before nodes announce themselves:

| Role | Delay | Waits for |
|------|-------|-----------|
| LOG / LOG_COLLECTOR | 0s | — starts immediately |
| MASTER | 2s | LOG_COLLECTOR |
| RT, FUEL, WATER, all others | 8s | LOG_COLLECTOR + MASTER |

---

## RT Node — Reactor & Turbine Control

### Module Structure (SCADA Rewrite)

The RT node was fully rewritten following SCADA principles. Instead of one 2350-line `main.lua`, logic is split into focused modules:

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `nodes/rt/main.lua` | ~750 | Boot, service wiring, ctx assembly |
| `nodes/rt/reactor_control.lua` | ~540 | Rod control, steam-margin regulator |
| `nodes/rt/turbine_control.lua` | ~930 | Flow, inductor, overspeed, rotation |
| `nodes/rt/capacity_learning.lua` | ~110 | Continuous capacity measurement |
| `nodes/rt/status_snapshot.lua` | ~160 | Status payload for Master |
| `nodes/rt/state_handlers.lua` | ~270 | State machine (AUTONOM/MASTER/SAFE) |

### Why 900 RPM?

**900 RPM is the efficiency optimum for ER2 turbines.** The coil (generator) only produces power at ≥ 900 RPM. Below that, the turbine consumes steam but generates no electricity. The RT node always targets 900 RPM as the base operating point.

### Power Control — 3-State Turbine Model

The RT node receives a single `power_target_percent` (0–100 %) from the Master and converts it into a turbine plan autonomously:

```
exact       = n_turbines × power_percent / 100
full_count  = floor(exact)            → run at 900 RPM (coil ON)
remainder   = exact − full_count      → one buffer turbine at remainder × 900 RPM
off_count   = n − full_count − 1      → flow = 0, coil OFF (rotate periodically)
```

Example at 50 %, 25 turbines:
- **12 turbines** → 900 RPM, full power
- **1 buffer turbine** → 450 RPM, coil scales with target RPM
- **12 turbines** → 0 RPM (rotating — no turbine stays cold permanently)

The coil engage/disengage thresholds scale proportionally with the target RPM, so the buffer turbine produces the correct fractional power.

### Setpoints (Master → RT)

The Master sends only four fields:

| Field | Type | Meaning |
|-------|------|---------|
| `power_target_percent` | number 0–100 | How much of RT capacity to deliver |
| `assignment_state` | string | `"active"` / `"shed"` / `"shutdown"` / `"standby"` |
| `shutdown_stage` | string\|nil | `"REQUEST_OFF"` / `"RAMPDOWN"` |
| `desired_node_state` | string | `"RUNNING"` / `"LIMITED"` / `"OFF"` |

The RT node calculates everything else itself (turbine count, flow rates, rod positions).

### Capacity Learning

Before the Master can send useful setpoints, the RT node must measure its own maximum output. Learning runs continuously and independently:

- Target: always 900 RPM (regardless of current setpoints)
- Minimum fraction: 80 % of turbines must be at target RPM for a reading to count
- Once `capacity_ready = true`, the Master can assign proportional load
- Result is cached to disk (`/xreactor/config/capacity_cache.lua`) and survives reboots

### Multi-Node Assignment (proportional)

When multiple RT nodes are available, the Master assigns load proportionally:

1. Sort nodes by capacity (largest first)
2. Determine how many nodes are needed (greedy fill)
3. Assign `global_target / sum(needed_capacities) × 100 %` to each needed node equally

No node runs at 100 % while another idles — all active nodes share the same percentage.

---

## Peripheral Detection

The system uses `peripheral.getType()` and string matching to detect ER2 devices:

- Type contains `"reactor"` → bound as reactor
- Type contains `"turbine"` → bound as turbine

Compatible type names: `BigReactors-Reactor`, `BigReactors-Turbine`, `extremereactors:turbine_part`, and variants.

Rod-level writes use a 4-step fallback: `setAllControlRodLevels` → `setControlRodsLevels` → `setControlRodLevel` → `getControlRods.setLevel`.

---

## Remote Update

Trigger: Redstone signal on **top** of the MASTER computer.

Flow:
1. Master broadcasts `REMOTE_UPDATE` to all nodes and updates itself
2. Each node sets a deferred flag (does not block the event loop)
3. After the current event cycle, the node downloads the installer from GitHub
4. Installer runs non-interactively (existing role kept), then `os.reboot()`

The deferred mechanism is required because CC:Tweaked's `http.get()` is asynchronous — it cannot receive the `http_success` event while already inside a `modem_message` handler.
