# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development. Current release: **beta-v40** (manifest v40).

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

**Key design rule:** MASTER sends only setpoints and intents. Each RT node makes local hardware decisions and writes directly to its own peripherals. No other node has hardware write access.

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

### Turbine Flow Regulation

Every tick, **all turbines** receive individual closed-loop flow control regardless of their module state:

| Module State | Effective Target RPM | Behaviour |
|---|---|---|
| `ON` | 900 RPM (or MASTER setpoint) | Hold at target |
| `STARTING` | 900 RPM | Ramp up in parallel with all others |
| `OFF` | 0 RPM | Controlled deceleration, coil disengages |
| `ERROR` | 0 RPM | Safe deceleration |
| `nil` (learning) | 900 RPM | All turbines regulated freely |

Turbines are **never** left without flow control — state only changes the target, not whether regulation runs.

### Capacity Cache

- Saved to `/xreactor/config/capacity_cache.lua` after first successful learning
- Loaded on boot — no re-learning needed after restart
- Automatically invalidated if turbine count changes (different hardware detected)
- Delete the file manually to force re-learning

### Safety Defaults

| Parameter | Default |
|-----------|---------|
| Turbine RPM target | 900 RPM |
| Coil engage | 855 RPM |
| Coil disengage | 750 RPM |
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

### Reliable Transport

- Each event has a reboot-safe `event_id` (`boot_id:seq`)
- Sender retries unacknowledged events up to 3 times (30s intervals)
- Collector deduplicates by `event_id` and sends `LOG_ACK`
- Pause/resume via button — paused events are not written but still acknowledged on resume

---

## Startup Delay

All nodes except `LOG` and `MASTER` wait **5 seconds** on boot before starting their role. This ensures the LOG collector is ready to receive log events before other nodes start producing them.

---

## node_id System

Each computer's network identity is derived from its **CC computer ID** (`node-<id>`), not from its label. This is stable and unique.

- Written to `/xreactor/config/node_id.txt` on first boot
- Never derived from the computer label (`XR-RT-54` etc.) — labels are human-facing only
- If a node appears constantly offline despite running: delete `/xreactor/config/node_id.txt` and reboot to regenerate

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
| `release_id` | `beta-v40` |
| `manifest_version` | 40 |
| `manifest_file_count` | 125 |
| `hash_algo` | `crc32` |

---

## Development

### Running Tests

```sh
python3 -m pytest tests/ -q
```

All 18 tests plus script-style guard tests should pass.

### After Changing Files

```sh
python3 tools/regenerate_manifest_metadata.py
```

Updates `size_bytes` and CRC32 `hash` in `manifest.lua`.

### Branching

- `beta` — all active development
- `main` — frozen reference snapshot
