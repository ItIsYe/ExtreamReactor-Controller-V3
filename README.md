# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development.
> **Manifest / Release:** `manifest-v236` / `beta-v236` · ATM10 (MC 1.21.1)
> **Status:** Phase 1–4 rewrite active. Current known blocker: RT still has a documented Lua table comma issue in `xreactor/nodes/rt/main.lua`; this was intentionally not patched in the latest documentation-only update. See `docs/NODE_START_BLOCKERS_2026-06-25.md` before any rollout.
> See [REWRITE_SPEC.md](REWRITE_SPEC.md) for the full rewrite reference.

---

## Quick Install

On any new CC:Tweaked computer with HTTP enabled:

```sh
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer
installer
```

The installer downloads the manifest, lets you pick a role, stages all required files, writes `/startup`, and reboots automatically.

**Update / reinstall:** Run `installer` again. The installer preserves `/xreactor/config/role.lua` across reinstalls — the existing role is detected and restored even though `/xreactor` is rebuilt to avoid stale/orphaned files and disk space issues.

**Auto-Update:** Nodes can run an auto-update loop alongside normal logic. Before relying on rollout/update behavior, check the current blocker documentation and verify manifest/release consistency.

Bump the version to trigger a rollout:

- `xreactor/manifest.lua` → `manifest_version`, `manifest_id`
- `xreactor/release.lua` → `release_id`, `manifest_id`, `manifest_version`

Every fix or behavior change to the installer/auto-updater should be paired with a version bump, otherwise nodes may not detect or pull the update.

---

## Architecture

```text
┌──────────────────────────────────────────────────────┐
│                       MASTER                         │
│  UI · Alerts · Telemetry · Setpoints · Profiles      │
└──────┬───────────────────────────┬───────────────────┘
       │ Ender Modem ch 6500/6501 │
  ┌────▼────┐  ┌────────┐  ┌──────▼──────┐  ┌─────┐
  │   RT    │  │ ENERGY │  │ WATER/FUEL/ │  │ LOG │
  │Reactor  │  │Matrix  │  │REPROCESSING │  │     │
  │Turbines │  │Storage │  │ Support     │  │     │
  └─────────┘  └────────┘  └─────────────┘  └─────┘
```

**Key design rule (SCADA principle):** MASTER sends only a percentage setpoint (`power_target_percent`) and a state intent (`assignment_state`). Each RT node autonomously decides how many turbines run, which are at partial load, and how to position reactor rods.

> **Known issue (2026-06-30):** RT has a documented parse-risk in `nodes/rt/main.lua`: a missing comma after the `build_health_payload` field in the `monitor_ui.update(...)` table. It is documented but not fixed in code.

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
| `LOG` / `LOG_COLLECTOR` | `nodes/log_collector/main.lua` | Disk Drive(s), Ender Modem |

LOG receives a minimal file set. It does not receive Master/RT/Energy-specific modules. This is intentional; see installer/manifest role selection logic.

---

## Boot Sequence

- LOG / LOG_COLLECTOR starts immediately.
- MASTER waits briefly for LOG.
- Other nodes wait for LOG and MASTER.
- Current `start.lua` can run the node entrypoint alongside an auto-update loop when available.

---

## Current documentation

Start here:

1. `docs/NODE_START_BLOCKERS_2026-06-25.md`
2. `docs/PROJECT_DOCUMENTATION.md`
3. `docs/README.md`

No ingame test or ingame install was performed by the latest documentation-only update.
