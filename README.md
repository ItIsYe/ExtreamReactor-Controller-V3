# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development.
>
> See [docs/PROJECT_DOCUMENTATION.md](docs/PROJECT_DOCUMENTATION.md) for the full technical reference.

---

## Quick Install

On any new CC:Tweaked computer with HTTP enabled:

```sh
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
shell.run("/installer")
```

The installer downloads the manifest, lets you pick a role, stages all required files, writes `/startup`, and reboots automatically.

**Update / reinstall:** Run `/installer` again — detects existing role and asks whether to keep or change it.

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

**Key design rule:** MASTER sends only setpoints and intents. Each RT node makes local hardware decisions and writes directly to its own peripherals.

### Modem Channels

| Channel | Purpose |
|---------|---------|
| 6500 | Control — MASTER → nodes |
| 6501 | Status — nodes → MASTER |
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

## RT Node — Turbine & Reactor Control

### Why 900 RPM?

**900 RPM is the efficiency optimum for ER2 turbines.** The coil (generator) only produces power at ≥ 900 RPM. Below that, the turbine consumes steam but generates no electricity.

### Power Control — Turbine Count + Partial Load Rotation

The RT node receives a `power_percent` setpoint (0–100%) from the MASTER. It converts this to a turbine plan:

```
demand = total_turbines × power_percent / 100

full_count  = floor(demand)          → these run at 900 RPM (coil ON)
remainder   = demand − full_count    → one turbine runs at partial RPM
rest                                 → coast to 0 (coil OFF)

Example: 25 turbines, 54% → demand = 13.5
  13 turbines at 900 RPM
   1 turbine  at 450 RPM  (partial, coil thresholds scaled proportionally)
  11 turbines coast to 0
```

**Rotation:** Every 5 minutes a `rotation_offset` shifts which physical turbines carry full load, partial load, or coast. All turbines share operating hours equally over time. Works for any number of turbines per node (e.g. 15 or 25).

### Coil Thresholds

Coil engage/disengage thresholds scale proportionally with the target RPM:

| Condition | Full load (900 RPM) | Partial (e.g. 450 RPM) |
|-----------|--------------------|-----------------------|
| Engage coil | ≥ 900 RPM | ≥ 450 RPM |
| Hold state | 850–899 RPM | 425–449 RPM |
| Disengage | < 850 RPM | < 425 RPM |
| Overspeed brake | > target + 20 RPM | > target + 20 RPM → coil forced ON |

### Capacity Learning

On first boot (or after deleting the cache), the node learns its maximum output:

```
1. All turbines regulated to 900 RPM
2. Reactor rods controlled by the normal rod regulator (same rules as production)
3. Wait until ALL turbines are stable at target RPM with coil engaged and energy > 0
4. Collect 3 consecutive stable samples
5. Lock: max_output = peak of 3 samples
6. Cache saved to /xreactor/config/capacity_cache.lua
```

While learning, the MASTER receives `capacity_ready=false` and sends 0% setpoints. The Master UI shows `LEARNING X/N turbines stable (Y samples)` per node.

After lock, `SET_SETPOINTS` commands are accepted and the MASTER begins normal power distribution.

**Force re-learning:**
```sh
delete /xreactor/config/capacity_cache.lua
reboot
```

### Reactor Rod Control

The rod regulator has two phases:

**Rod regulator runs identically during Learning and normal operation:**
```
steam_margin = available_steam − total_turbine_steam_demand
Positive margin → insert rods (less steam produced)
Negative margin → retract rods (more steam produced)

Deadband:  ±5000 mB  (no action in this range)
Step:      max ±5% per application
Cooldown:  1.5s between adjustments
Rod range: min=80% .. max=100% insertion (configurable in rails.reactor_rods)

Safety overrides (bypass rod caps):
  SCRAM / EMERGENCY → 100% insertion (immediate)
```

Coolant protection reduces or blocks rod retraction when coolant ratio is low (soft limit 0.28, hard limit 0.22).

**Log indicator for active rod control:**
```
ReactorCtrl margin=<N> rods_current=<X> rods_target=<Y> source=AUTO_REGULATOR
```

---

## FUEL & REPROCESSING — Routing

Mekanism pipe valves must be set to **High Redstone = Interrupt**. Configure via the **Router tab** on the Monitor (or PC terminal). Routes save to `/xreactor/config/fuel_routes.lua` / `reproc_routes.lua`.

---

## LOG Collector

Disk ring-buffer: fills one disk, then switches to next, wipes first when all full. Log mode buttons on all nodes: `[All][Disk][Rmt][Term][Off]`.

---

## node_id System

Identity = `node-<computerID>`. Stored in `/xreactor/config/node_id.txt`. Never derived from the computer label. If a node appears offline but is running: delete `node_id.txt` and reboot.

---

## PC Console Fallback

No Monitor attached? All nodes render their UI directly on the terminal. Buttons are clickable via mouse on Advanced Computers.

---

## Development

```sh
python3 -m pytest tests/ -q                        # run all tests
python3 tools/regenerate_manifest_metadata.py      # after changing any xreactor/ file
```
