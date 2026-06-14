# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development. Current release: **beta-v45** (manifest v45).
>
> See [docs/SESSION_HANDOFF.md](docs/SESSION_HANDOFF.md) for a full summary of recent work — useful for continuing in a new chat or with a different AI.

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

## RT Node — Turbine Regulation

### Why 900 RPM?

**900 RPM is the efficiency optimum for ER2 turbines.** The coil (generator) only engages at ≥ 900 RPM, so any RPM below 900 produces no electricity. Power control therefore works exclusively by varying the **number of running turbines**, not their speed.

### Power Control — Automatic Turbine Count

```
active_count = round(total_turbines × power_percent / 100)

Example (25 turbines):
  100% → 25 at 900 RPM  (all coils on)
   80% → 20 at 900 RPM + 5 decelerating
   50% → 13 at 900 RPM + 12 decelerating
    0% → all decelerating to 0
```

The flow regulation loop is **always closed** for every turbine — state only controls the target RPM (900 for active, 0 for stopped).

### Coil Thresholds

| RPM | Action |
|-----|--------|
| ≥ 900 | Engage (start generating) |
| 850–899 | Hold current state |
| < 850 | Disengage |

### Turbine Regulation Rules

1. **Always regulated** — no state-based exceptions. Every turbine gets individual closed-loop flow control every tick.
2. **Target RPM determines behavior** — active=900, stopping=0.
3. **Overspeed brake disabled at target=0** — turbines stopping naturally; no OVERSPEED_BRAKE deadlock.

### Startup / Capacity Learning

```
Boot → 5s delay → Discover peripherals
     → CAPACITY LEARNING
         Rods: 50% (bypasses regulator_min_rods cap)
         All 25 turbines regulated to 900 RPM simultaneously
         3 stable samples with output > 0 → LOCKED
         Cache saved: /xreactor/config/capacity_cache.lua
     → MASTER mode: accept SET_SETPOINTS
```

---

## FUEL & REPROCESSING — Routing

Mekanism pipe valves must be set to **High Redstone = Interrupt**. Configure via the **Router tab** on the Monitor (or PC terminal). Routes save immediately to `/xreactor/config/fuel_routes.lua` / `reproc_routes.lua`.

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

## Release

| Field | Value |
|-------|-------|
| `release_id` | `beta-v45` |
| `manifest_version` | 45 |
| `manifest_file_count` | 125 |

---

## Development

```sh
python3 -m pytest tests/ -q                        # run all tests
python3 tools/regenerate_manifest_metadata.py      # after changing any xreactor/ file
```
