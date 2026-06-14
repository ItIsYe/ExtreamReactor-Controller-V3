# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development. Current release: **beta-v43** (manifest v43).

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

**Key design rule:** MASTER sends only setpoints and intents. Each RT node makes local hardware decisions and writes directly to its own peripherals. No other node has hardware write access on reactors or turbines.

### Modem Channels

| Channel | Purpose |
|---------|---------|
| 6500 | Control — MASTER → nodes (commands, setpoints) |
| 6501 | Status — nodes → MASTER (telemetry, health) |
| 6502 | Log transport — all nodes → LOG collector |

---

## Roles

| Role | Entrypoint | Required Peripherals |
|------|-----------|---------------------|
| `MASTER` | `master/main.lua` | Monitor(s), Ender Modem |
| `RT` | `nodes/rt/main.lua` | ER2 Reactor, ER2 Turbines, Ender Modem |
| `ENERGY` | `nodes/energy/main.lua` | Mekanism Induction Matrix, Ender Modem |
| `WATER` | `nodes/water/main.lua` | Ender Modem |
| `FUEL` | `nodes/fuel/main.lua` | Ender Modem, Wired Modem (logistics) |
| `REPROCESSING` | `nodes/reprocessor/main.lua` | Ender Modem, Wired Modem (logistics) |
| `LOG` | `nodes/log_collector/main.lua` | Disk Drive(s), Ender Modem |

---

## RT Node — Safety & Control

RT runs a fully local safety loop. MASTER setpoints are accepted only after RT completes its capacity-learning phase. The RT ↔ MASTER boundary is the central safety boundary of the system.

### Why 900 RPM?

**900 RPM is the efficiency optimum for Extreme Reactors 2 turbines.** At this speed the turbine converts steam to RF at maximum efficiency. Running below 900 RPM wastes steam per RF produced; there is no meaningful benefit to partial-speed operation. The system is therefore designed to always run active turbines at exactly 900 RPM and control power output exclusively by choosing how many turbines run.

### Startup Sequence

```
Boot
 └─ Discover peripherals (reactor + turbines)
     └─ CAPACITY LEARNING
         ├─ Rods set to 50% (bypasses regulator_min_rods config cap)
         ├─ All turbines regulated to 900 RPM simultaneously
         ├─ 3 stable samples with output > 0 required to lock
         └─ Cache saved to /xreactor/config/capacity_cache.lua
             └─ MASTER mode: accept SET_SETPOINTS, regulate normally
```

### Power Control — Turbine Count Mode

**Power output is controlled exclusively by the number of active turbines.** Every running turbine is always regulated to exactly 900 RPM. Reducing power means stopping turbines, not slowing them down.

```
power_percent = 80%  →  20 of 25 turbines at 900 RPM (coil ON)
                          5 of 25 turbines decelerating to 0 (coil OFF)

power_percent = 50%  →  13 of 25 turbines at 900 RPM (coil ON)
                         12 of 25 turbines decelerating to 0 (coil OFF)

power_percent = 100% →  all 25 at 900 RPM
power_percent =   0% →  all 25 decelerating to 0
```

`active_count = round(total_turbines × power_percent / 100)`

Turbine priority is stable (by index order in config). No oscillation.

### Why Not RPM Scaling?

Coil engagement (electricity generation) requires **≥ 900 RPM** to engage, and disengages below 850 RPM. A turbine running at 450 RPM has no coil engagement and generates zero electricity. RPM reduction would spin turbines without producing power — worse efficiency than simply stopping the turbine. Therefore all power reductions use turbine count, not RPM.

### Turbine Flow Regulation — Always Active

Every turbine receives individual closed-loop flow control every tick, with no state-based exceptions:

| Turbine Status | Effective Target RPM | Result |
|---|---|---|
| Active (in power budget) | 900 RPM | Coil engages at 900 → electricity |
| Inactive (over budget) | 0 RPM | Coil disengages below 850 → no electricity |
| Learning phase (any) | 900 RPM | All turbines measure capacity together |

The regulation loop (flow → RPM → coil) runs identically for all turbines. Only the target value differs.

### Coil Engagement

| RPM | Coil action |
|-----|------------|
| ≥ 900 | Engage (start generating) |
| 850–899 | Hold current state (hysteresis) |
| < 850 | Disengage (stop generating) |

### Capacity Cache

- Saved to `/xreactor/config/capacity_cache.lua` after first successful learning
- Loaded on boot — no re-learning needed after restart
- Automatically invalidated if turbine count changes (different hardware detected)
- Delete the file manually to force re-learning

### Safety Defaults

| Parameter | Default |
|-----------|---------|
| Turbine RPM target | 900 RPM (efficiency optimum) |
| Coil engage | ≥ 900 RPM |
| Coil disengage | < 850 RPM |
| Rod range (normal) | 80–98 % insertion |
| Rod override (SCRAM) | 100 % (bypasses all limits) |
| Steam guard high | 0.82 ratio |
| Steam guard critical | 0.92 ratio |
| Temperature limit | 2000 °C |

### Node States

`INIT` → `AUTONOM` → `MASTER` / `LIMITED` / `EMERGENCY`

A SCRAM or temperature trip forces `EMERGENCY` and inserts all rods to 100% regardless of normal limits.

---

## FUEL & REPROCESSING — Logistics & Routing

Both nodes support **Mekanism pipe valve routing** via a Redstone Router:

- Pipe valves must be set to **High Redstone = Interrupt**
- Routing config via the **Router tab** on the node's Monitor (or PC terminal)
- Touch a pipe side → touch a reactor/reprocessor → Save
- Config saved to disk: `FUEL` → `/xreactor/config/fuel_routes.lua`, `REPROCESSING` → `/xreactor/config/reproc_routes.lua`
- Routes take effect immediately after saving (shared rs_router instance)

Wiring requirements:
- **Wired Modem** for peripheral access (transporter, reactor ports)
- **Ender Modem** for MASTER communication

---

## LOG Collector

Receives structured log events from all nodes on channel 6502. Writes to attached disk drives with rotation, deduplication, and ACK-based reliability.

### Disk Strategy

- Writes to one disk until full, then switches to the next
- When all disks are full: wipes disk 1 and starts over (ring buffer)
- Minimum free space before switching: 8 KB

### Log Modes (all nodes)

Every node has a log mode button on its Diagnostics page (or PC terminal):

| Mode | Behaviour |
|------|-----------|
| `All` | Disk + remote LOG collector (default) |
| `Disk` | Local disk only |
| `Rmt` | Remote LOG collector only |
| `Term` | Terminal print only |
| `Off` | No logging |

Setting persists across reboots via CC settings (`xreactor.log_mode`).

---

## Startup Delay

All nodes except `LOG` and `MASTER` wait **5 seconds** on boot before starting. This ensures the LOG collector is ready to receive log events before other nodes start producing them.

---

## node_id System

Each computer's network identity is `node-<computerID>` — stable and unique, never derived from the computer label. Written to `/xreactor/config/node_id.txt` on first boot.

If a node appears constantly offline despite running: delete `/xreactor/config/node_id.txt` and reboot to regenerate.

---

## PC Console Fallback

If no external Monitor peripheral is attached, all nodes render their UI directly on the computer's own terminal. Log mode buttons and the Router tab are fully interactive via mouse clicks on Advanced Computers.

---

## File Layout After Install

```
/xreactor/              Runtime files for the selected role
/xreactor/config/       role.lua, node_id.txt, capacity_cache.lua, routes
/xreactor_logs/         Installer log
/startup                Boots /xreactor/start.lua on every reboot
```

---

## Release & Manifest

| Field | Value |
|-------|-------|
| `release_id` | `beta-v43` |
| `manifest_version` | 43 |
| `manifest_file_count` | 125 |
| `hash_algo` | `crc32` |

---

## Development

```sh
# Run all tests
python3 -m pytest tests/ -q

# After changing any xreactor/ file
python3 tools/regenerate_manifest_metadata.py
```

- `beta` — all active development
- `main` — frozen reference snapshot
