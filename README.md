# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors** (reactors + turbines), Mekanism Induction Matrices, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development. `main` is a frozen reference snapshot.

---

## Quick Install

On any new CC:Tweaked computer with HTTP enabled:

```sh
delete /installer
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
shell.run("/installer")
```

The installer downloads `manifest.lua` and `release.lua` from GitHub, lets you pick a role, stages all required files, writes `/startup`, and reboots into the new role automatically.

**Re-install / role change:** Just run `shell.run("/installer")` again. The installer detects an existing role and asks whether to keep it or change it before wiping and reinstalling cleanly.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                       MASTER                         │
│  UI · Alerts · Telemetry · Setpoints · Profiles      │
└──────┬───────────────────────────┬───────────────────┘
       │ Modem (ch 6500/6501)      │
  ┌────▼────┐  ┌────────┐  ┌──────▼──────┐  ┌─────┐
  │   RT    │  │ ENERGY │  │ WATER/FUEL/ │  │ LOG │
  │Reactor  │  │Matrix  │  │REPROCESSING │  │     │
  │Turbines │  │Storage │  │ Support     │  │     │
  └─────────┘  └────────┘  └─────────────┘  └─────┘
```

**Key design rule:** MASTER sends only setpoints and intents. RT decides and writes hardware. No other node has direct hardware write access.

### Modem Channels

| Channel | Purpose |
|---------|---------|
| 6500 | Control (MASTER → nodes: commands, setpoints) |
| 6501 | Status (nodes → MASTER: telemetry, health) |
| 6502 | Log transport (all nodes → LOG collector) |

---

## Roles

| Role | Entrypoint | Peripherals |
|------|-----------|-------------|
| `MASTER` | `master/main.lua` | Monitor(s), wireless modem |
| `RT` | `nodes/rt/main.lua` | Reactor(s), turbine(s), wireless modem |
| `ENERGY` | `nodes/energy/main.lua` | Induction matrix/storage, wireless modem |
| `WATER` | `nodes/water/main.lua` | Wireless modem |
| `FUEL` | `nodes/fuel/main.lua` | Wireless modem |
| `REPROCESSING` | `nodes/reprocessor/main.lua` | Wireless modem |
| `LOG` / `LOG_COLLECTOR` | `nodes/log_collector/main.lua` | Disk drive(s), wireless modem |

---

## RT Node — Safety & Control

RT runs a local safety loop independent of MASTER. MASTER setpoints are accepted only after RT finishes its own capacity-learning phase.

### Capacity Learning

On startup RT enters a capacity-learning phase:
- Waits for 3 consecutive stable RPM samples (±10% tolerance) with output > 0
- Only then locks capacity and accepts MASTER `SET_SETPOINTS` commands
- While learning, MASTER commands are rejected with reason `CAPACITY_LEARNING`

### Safety Limits (defaults)

| Parameter | Default |
|-----------|---------|
| Control rod range | 80 – 98 % insertion |
| SCRAM rod override | 100 % (bypasses normal clamp) |
| Turbine RPM target | 900 RPM |
| Turbine coil engage | 850 RPM |
| Turbine coil disengage | 750 RPM |
| Steam guard high ratio | 0.82 |
| Steam guard critical ratio | 0.92 |
| Coolant ramp soft limit | 28 % |
| Coolant ramp hard limit | 22 % |

### Node States

`OFF` → `STARTUP` → `RUNNING` / `LIMITED` / `AUTONOM` / `MANUAL` / `EMERGENCY`

A SCRAM or trip moves RT to `EMERGENCY` and inserts rods to 100 % regardless of normal limits.

---

## LOG Collector

Receives structured log events from all nodes over channel 6502. Writes to attached disk drives with rotation, deduplication, and pause/resume support.

- Events include `event_id` (boot-scoped sequence) for deduplication
- Sender retries unacknowledged events (max 6 attempts, bounded 64-event buffer)
- Collector ACKs each event after successful disk write

---

## Installer Details

### File Layout After Install

```
/xreactor/          Runtime files for the selected role
/xreactor/config/   role.lua, node_id.txt, optional overrides
/startup            Boots /xreactor/start.lua on every reboot
/xreactor_logs/     Installer log (installer_bootstrap.log)
```

### Install Flow

```
No existing role:
  → Role selection → Clean old files → Install → Write role.lua + startup → Reboot

Existing role + keep (yes):
  → Keep role → Clean old files → Reinstall same role → Reboot

Existing role + change (no):
  → Clean old files → Role selection → Install new role → Reboot
```

### Storage Requirements

The installer checks free disk space before staging:
- Minimum required: 4 KB
- Buffer reserved: 24 KB + 3 % of install size

---

## Release & Manifest

Current release: **beta-v28**

| Field | Value |
|-------|-------|
| `release_id` | `beta-v28` |
| `manifest_id` | `manifest-v28` |
| `hash_algo` | `none` |
| `manifest_file_count` | 122 |
| `installer_core_version` | `2.0` |

`hash_algo = "none"` means the installer logs size/hash mismatches as warnings but does not hard-abort on them.

---

## Development

### Running Tests

```sh
# Python guard tests (requires Python 3.10+)
python3 -m pytest tests/ -v

# Individual guard tests (SystemExit-style)
python3 tests/manifest_changed_files_guard_test.py
python3 tests/manifest_hash_size_guard_test.py
python3 tests/manifest_role_scope_guard_test.py
```

Lua tests require a CC:Tweaked environment or `lupa`. Python guard tests run standalone.

### Regenerating Manifest Metadata

After changing any `xreactor/` file:

```sh
python3 tools/regenerate_manifest_metadata.py
```

This updates `size_bytes` and `hash` fields in `manifest.lua` in place.

### Branch Rules

- `beta` — active development, all changes go here
- `main` — frozen reference, do not modify

---

## Roadmap

- [ ] Ingame validation: installer reinstall flow (fresh PC, keep-role, change-role)
- [ ] Ingame validation: RT capacity learning → MASTER setpoint handoff
- [ ] ENERGY + LOG_COLLECTOR log verification
- [ ] Manifest cleanup: align `hash_algo` with actual hash/size usage
- [ ] Fuel logistics (Mekanism Logistical Transporter routing) — post stable MASTER↔RT↔ENERGY
