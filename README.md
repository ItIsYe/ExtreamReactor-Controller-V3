# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development.
> **Manifest / Release:** `manifest-v225` / `beta-v225` · ATM10 (MC 1.21.1)
> **Status:** Phase 1–4 rewrite complete (modular installer, async Energy node, Master without globals, shared services). Auto-Updater hardened and running on all node types. Known open issue: setpoint transmission/calculation between MASTER and nodes is currently broken again — under investigation.
> See [REWRITE_SPEC.md](REWRITE_SPEC.md) for the full rewrite reference.

---

## Quick Install

On any new CC:Tweaked computer with HTTP enabled:

```sh
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer
installer
```

The installer downloads the manifest, lets you pick a role, stages all required files, writes `/startup`, and reboots automatically.

**Update / reinstall:** Run `installer` again. The installer now preserves `/xreactor/config/role.lua` across reinstalls — the existing role is detected and restored even though `/xreactor` is fully deleted and rebuilt to avoid stale/orphaned files and disk space issues (important for large roles like MASTER and RT).

**Auto-Update (built-in, no Redstone trigger needed):** Every node runs an `auto_update_service` loop alongside its normal logic (`parallel.waitForAny`). Every 120 seconds (first check after 30s on boot) it compares the local `manifest_version` (from `xreactor/release.lua`) against the version published on the `beta` branch. If a newer version is available, the node downloads the current monolithic `installer` from `raw.githubusercontent.com`, re-runs it non-interactively (existing role preserved), and reboots automatically.

Bump the version to trigger a rollout:
- `xreactor/manifest.lua` → `manifest_version`, `manifest_id`
- `xreactor/release.lua` → `release_id`, `manifest_id`, `manifest_version`

**Every fix or behavior change to the installer/auto-updater must be paired with a version bump**, otherwise nodes won't detect or pull the update.

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

> **Known issue (2026-06-30):** setpoint transmission/calculation between MASTER and nodes is currently not working correctly. Root cause not yet identified — investigation pending.

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
| `LOG` / `LOG_COLLECTOR` | `nodes/log_collector/main.lua` | Disk Drive(s), Ender Modem |

**LOG receives a minimal file set** (currently ~12 files: always-on base files + `nodes/log_collector/main.lua` itself). It does not receive Master/RT/Energy-specific modules. This is intentional — see `installer/manifest.lua`'s `files_for_role()`.

---

## Boot Sequence

Nodes start in a fixed order to ensure the Master is ready before nodes announce themselves:

| Role | Delay | Waits for |
|------|-------|-----------|
| LOG / LOG_COLLECTOR | 0s | — starts immediately |
| MASTER | 2s | LOG_COLLECTOR |
| RT, ENERGY, FUEL, WATER, all others | 8s | LOG_COLLECTOR + MASTER |

Every node enters `parallel.waitForAny(node_thread, auto_update_loop)` after boot, so the Auto-Updater runs concurrently with normal node operation without blocking it.

---

## Installer Architecture (Phase 1 Rewrite)

The installer is distributed as **one monolithic file** (`/installer` in repo root) so a fresh computer only needs a single `wget`. Internally it embeds the modular `installer/` source files as Lua long-strings and writes them out to `/xreactor/installer/` on the target:

| Module | Responsibility |
|--------|---------------|
| `installer/http.lua` | HTTP helpers |
| `installer/manifest.lua` | Manifest parsing, `files_for_role()` (which files a role needs) |
| `installer/stage.lua` | Download/staging of files with retry |
| `installer/ui.lua` | Role selection UI |
| `installer/auto_update.lua` | Background version-check + self-update loop (parallel-safe) |
| `installer/init.lua` | Entry point, orchestration |

**Reinstall behavior:** Before deleting `/xreactor`, the installer reads and caches `/xreactor/config/role.lua` in memory, deletes the whole directory (avoids orphaned/stale files and disk space bloat on large roles like MASTER/RT), recreates the directory, and immediately restores `role.lua` — so a re-run of the installer after a failed/interrupted install still knows which role to (re)install.

### CC:Tweaked Parallel-Coroutine Constraints (hard-won, do not violate)

These limitations caused real bugs during the rewrite and must be respected in any code that runs inside `parallel.waitForAny`:

- `shell` is **not available** inside a `parallel` coroutine — use `dofile(path)` instead of `shell.run(path)`.
- `http.get(url)` has no usable 3-argument timeout form in this context — use async `http.request` + listen for `http_success` / `http_failure` events instead.
- `os.pullEvent()` must remain unfiltered in parallel threads so other coroutines still receive their events; don't use `os.pullEventRaw` or a filtered pull that could swallow events meant for siblings.
- `f.write(content)` must be called directly, not via `pcall(f.write, f, content)` (wrong self-argument order causes silent failures).
- Avoid extra dependent HTTP round-trips (e.g. resolving a commit SHA via `api.github.com`) inside the update-check path — every additional external call is another place the async event wait can stall, especially on event-heavy nodes like RT. Fetch `beta` branch files directly via `raw.githubusercontent.com`.

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

> **Currently broken (2026-06-30):** setpoint transmission/calculation is not reliably reaching or being applied at the node side. Not yet root-caused; treat RT/Energy power control as untrusted until fixed.

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

## Energy Node (Phase 2 Rewrite)

The Energy node's previously blocking `main.lua` (674 lines) was split into:

| Module | Responsibility |
|--------|---------------|
| `nodes/energy/main.lua` | Boot, wiring, `parallel.waitForAny(heartbeat, matrix)` |
| `nodes/energy/heartbeat.lua` | Heartbeat thread, runs independently of matrix polling |
| `nodes/energy/matrix.lua` | Mekanism Induction Matrix polling/control thread |

No more blocking calls inside the main loop — heartbeat and matrix monitoring run as separate coroutines via `parallel.waitForAny`, so a slow matrix peripheral call no longer delays heartbeat/status reporting.

---

## Master (Phase 3 Rewrite)

The Master's `runtime_loop`, `init_runtime`, and `runtime_context` were consolidated and the `_G.xreactor_runtime` global hack removed:

| Module | Responsibility |
|--------|---------------|
| `master/context.lua` | Runtime context construction (replaces global state) |
| `master/loop.lua` / `master/runtime_loop.lua` | Main loop orchestration |

`message_handlers` now receive the runtime context explicitly via `set_runtime()` instead of reading a global. Setpoint-Flow and Profiles were moved into their own dedicated modules as part of this phase.

---

## Shared Services (Phase 4 Rewrite)

Reusable across all node types:

| Module | Responsibility |
|--------|---------------|
| `xreactor/services/heartbeat_service.lua` | Shared heartbeat logic, used by all nodes |
| `xreactor/services/auto_update_service.lua` | Shared auto-update loop logic, used by all nodes |

---

## Peripheral Detection

The system uses `peripheral.getType()` and string matching to detect ER2 devices:

- Type contains `"reactor"` → bound as reactor
- Type contains `"turbine"` → bound as turbine

Compatible type names: `BigReactors-Reactor`, `BigReactors-Turbine`, `extremereactors:turbine_part`, and variants.

Rod-level writes use a 4-step fallback: `setAllControlRodLevels` → `setControlRodsLevels` → `setControlRodLevel` → `getControlRods.setLevel`.

---

## Known Open Issues (2026-06-30)

- **Setpoint transmission/calculation (Master ↔ RT/Energy) is broken** — under investigation, no root cause identified yet.
- `node-55` (RT) reports `reactors=0` — confirmed in-game hardware issue (missing cable to reactor), not a software bug.
- Legacy flat `installer_*.lua` files (`installer_main.lua` etc.) still present in the repo root/`xreactor/` from before the Phase 1 rewrite — safe to delete, kept only for reference during the transition.
