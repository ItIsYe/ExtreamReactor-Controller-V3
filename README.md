# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development.
> **Manifest / Release:** `manifest-v262` / `beta-v262` · ATM10 (MC 1.21.1)
> **Status:** Phase 1–4 rewrite complete. Installer, auto-updater, setpoint flow, and UI have all been hardened through targeted bugfixes (see RUNTIME_STATUS_2026-06-03.md for the full session history). A UI-Redesign (layout system, summary view, Ampel status monitor) was completed 2026-07-01.
> See [REWRITE_SPEC.md](REWRITE_SPEC.md) for the full rewrite reference and [RUNTIME_STATUS_2026-06-03.md](RUNTIME_STATUS_2026-06-03.md) for session history.

---

## Quick Install

On any new CC:Tweaked computer with HTTP enabled:

```sh
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer
installer
```

The installer downloads the manifest, lets you pick a role, stages all required files, writes `/startup.lua`, and reboots automatically.

**Update / reinstall:** Run `installer` again. The installer preserves `/xreactor/config/role.lua`, `/xreactor/config/node_id.txt`, and `/xreactor/config/capacity_cache.lua` across reinstalls — the existing role and learned data are detected and restored even though `/xreactor` is fully deleted and rebuilt to avoid stale/orphaned files and disk space issues on large roles (MASTER, RT). This applies to **both** the manual installer path and the automatic auto-update reinstall path — earlier this preservation only worked in one of the two paths, which caused nodes to lose their role assignment on every auto-update until it was fixed.

**Auto-Update (built-in, no manual trigger needed):** Every node runs an `auto_update_service` loop alongside its normal logic (`parallel.waitForAny`). First check 30s after boot, then every 120s. If the local `manifest_version` is behind the `beta` branch, the node downloads the current installer via `raw.githubusercontent.com`, re-runs it non-interactively (role preserved), and reboots.

Bump the version to trigger a rollout:

- `xreactor/manifest.lua` → `manifest_version`, `manifest_id`
- `xreactor/release.lua` → `release_id`, `manifest_id`, `manifest_version`, `manifest_file_count`

**Every fix or behavior change must be paired with a version bump**, otherwise nodes won't detect or pull the update. **Every changed file's `size_bytes` entry in `manifest.lua` must also be updated** — a stale `size_bytes` causes the installer to abort with `size mismatch` for every node that needs that file.

---

## Architecture

```text
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

**Setpoint fields (Master → RT):**

| Field | Type | Meaning |
|-------|------|---------|
| `power_target_percent` | number 0–100 | Percent of the node's learned capacity |
| `assignment_state` | string | `active`, `shed`, `shutdown`, `standby` |
| `shutdown_stage` | string/nil | Shutdown/rampdown intent |
| `desired_node_state` | string/nil | Desired node state |

**Multi-node assignment** (`rt_sync.lua`): nodes are sorted by capacity; the master counts how many are needed for `global_target`; `uniform_pct = global_target / sum(needed capacities) × 100`; only the needed nodes are assigned active load, the rest go to `shed`/`standby`. The computed `assigned_power`/`assigned_percent` are persisted directly on the node object so the UI shows a stable value — this used to only exist in a temporary, discarded structure, which caused the UI to permanently show `Soll 0.0` per RT node. Fixed 2026-07-01.

The setpoint flow (Master → RT_sync → node.assigned_power/percent → UI) and the PEAK-profile power-target calculation were both hardened on 2026-06-30/07-01 after two separate real bugs (a field-ordering bug in `message_handlers.lua` and a `measured_total`-vs-`learned_capacity_total` preference bug in `runtime_ops_profile.lua`) caused setpoints to silently stay too low. Both are fixed; see RUNTIME_STATUS_2026-06-03.md for details.

### Modem Channels

| Channel | Purpose |
|---------|---------|
| 6500 | Control — MASTER → nodes (commands, setpoints) |
| 6501 | Status — nodes → MASTER (heartbeat, status payloads) |
| 6503 | Log transport — all nodes → LOG collector |

> Log traffic uses 6503, not 6502 — this was a real channel mismatch bug (sender used 6502, `shared/constants.lua` defines 6503) that caused the LOG collector to receive nothing for an extended period. Fixed 2026-06-30.

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

**LOG receives a minimal file set** (always-on base files plus its own `nodes/log_collector/main.lua`). It does not receive Master/RT/Energy-specific modules — this is intentional, see `installer/manifest.lua`'s `files_for_role()`.

**LOG modem note:** if a LOG computer has both an Ender Modem (wireless, for receiving remote log traffic) and a wired Modem (for local disk drives/monitor), the collector opens all detected modems on the log channel — it does not require the wireless one specifically, but a missing Ender Modem means it will never receive anything from remote nodes even though it appears to be running normally.

---

## Boot Sequence

| Role | Delay | Waits for |
|------|-------|-----------|
| LOG / LOG_COLLECTOR | 0s | — starts immediately |
| MASTER | 2s | LOG_COLLECTOR |
| RT, ENERGY, FUEL, WATER, all others | 8s | LOG_COLLECTOR + MASTER |

Every node enters `parallel.waitForAny(node_thread, auto_update_loop)` after boot, so the Auto-Updater runs concurrently with normal node operation without blocking it.

### CC:Tweaked Parallel-Coroutine Constraints (hard-won, do not violate)

- `shell` is **not available** inside a `parallel` coroutine — use `dofile(path)` instead of `shell.run(path)`. `/startup.lua` itself runs as a top-level program (not inside `parallel`), so `shell.run("/xreactor/start.lua")` there is fine — the constraint only applies to code that actually executes inside `parallel.waitForAny`.
- Avoid extra dependent HTTP round-trips (e.g. resolving a commit SHA via `api.github.com`) inside the update-check path — every additional external call is another place the async event wait can stall on event-heavy nodes like RT. Fetch `beta` branch files directly via `raw.githubusercontent.com`.
- `os.pullEvent()` must remain unfiltered in parallel threads so sibling coroutines still receive their events.
- `f.write(content)` must be called directly, not via `pcall(f.write, f, content)`.

---

## RT Node — Reactor & Turbine Control

### Module Structure (SCADA Rewrite)

| Module | Responsibility |
|--------|----------------|
| `nodes/rt/main.lua` | Boot, service wiring, ctx assembly |
| `nodes/rt/reactor_control.lua` | Rod control, steam-margin regulator |
| `nodes/rt/turbine_control.lua` | Flow, inductor, overspeed, rotation |
| `nodes/rt/capacity_learning.lua` | Continuous capacity measurement |
| `nodes/rt/status_snapshot.lua` | Status payload for Master |
| `nodes/rt/state_handlers.lua` | State machine (AUTONOM/MASTER/SAFE) |
| `nodes/rt/monitor_ui.lua` | RT's own on-node monitor UI, including the Ampel status monitor (see below) |

### Why 900 RPM?

**900 RPM is the efficiency optimum for ER2 turbines.** The coil (generator) only produces power at ≥ 900 RPM. Below that, the turbine consumes steam but generates no electricity.

### Power Control — 3-State Turbine Model

The RT node receives `power_target_percent` (0–100%) from the Master and converts it into a turbine plan autonomously:

```
exact       = n_turbines × power_percent / 100
full_count  = floor(exact)            → run at 900 RPM (coil ON)
remainder   = exact − full_count      → one buffer turbine at remainder × 900 RPM
off_count   = n − full_count − 1      → flow = 0, coil OFF (rotate periodically)
```

### Capacity Learning

Learning runs continuously and independently. A measurement only counts when **at least 80% of turbines are simultaneously at target RPM** — this threshold is deliberate: it protects against measuring a false "maximum" from a partial/gamed sample, at the cost of only being reachable near full-power operation (e.g. under a PEAK profile). This is expected behavior, not a bug — see the discussion in the 2026-06-30/07-01 session log for the reasoning.

Once `capacity_ready = true`, the result is cached to disk (`/xreactor/config/capacity_cache.lua`, preserved across reinstalls) and the Master prefers `learned_capacity_total` over the currently measured output when computing the PEAK power target — this was itself a bug fix (see RUNTIME_STATUS_2026-06-03.md).

### Ampel Status Monitor (optional, 1x3)

Attach a second monitor (wired modem, scaled to exactly 1 wide × 3 tall) to an RT node and it is auto-detected — no configuration needed. It shows a solid color reflecting the node's current status, no text:

| Color | Meaning |
|-------|---------|
| Green | Delivering normally |
| Yellow | Learning capacity, starting up, or waiting for a setpoint |
| Orange | Output deviates from target, or over-delivering |
| Red | Under-delivering (emergency) |
| Gray | Shutting down / on standby (SHED) |

Implementation notes: the Ampel logic in `monitor_ui.lua` is fully `pcall`-isolated on every level and identifies the main monitor by the name `M.init()` actually resolved (`M.main_monitor_name`) — an earlier version incorrectly referenced a non-existent `ctx.config.monitor_name` config field, and an even earlier attempt could, on failure, corrupt the main monitor's rendering state entirely. Both were fixed 2026-07-01.

---

## Master UI

### Layout System (`master/ui/layout.lua`)

Badge rows (the small colored status labels like `RT OK | M OK | MASTER | CAP | SHD`) are built centrally through `layout.badge_row()`, which knows the monitor width in advance and degrades gracefully: full labels if there's room, short forms if not, lowest-priority badges dropped last if it still doesn't fit. This replaced ad-hoc per-view badge rendering that could silently overlap or get cut off on narrow monitors — a recurring problem before this was introduced 2026-07-01.

### Overview / Summary

The `overview` view (`master/ui/overview.lua`) is the single "everything at a glance" screen: system status, controls (profile/auto/RT-hold), alerts, key metrics (power target vs actual, energy %, **RT fleet summary** — active/total node count and current assignment state, without switching to the RT view), and a prioritized node table.

### Alerts

`master/ui/alerts.lua` and the AUX-monitor "Logs" view (`master/ui/alarms.lua`) both draw from the real `alert_service` (active CRITICAL/WARN/INFO counts) via `ui_controller.build_models()`'s `alerts`/`alarms` models — earlier, neither of those models existed in `data_map`, so both views (and the AUX monitor status badge) stayed stuck on green/"no alerts" regardless of actual system state. Fixed 2026-06-30.

---

## Known Resolved Issues (historical, kept for context)

These were real bugs found and fixed during the 2026-06-30/07-01 hardening sessions. Listed here so future debugging doesn't waste time re-investigating already-closed issues:

- Setpoint transmission (Master → RT) silently stayed near zero due to a field-ordering bug in `populate_rt_status()` (message_handlers.lua) — fixed.
- PEAK profile power target froze at the currently-measured (possibly throttled) output instead of the learned max capacity — fixed.
- `node.assignment_state`/`node.control_source` could get stuck showing stale "UNASSIGNED"/"LOCAL" on some nodes due to a sticky self-referential read-before-write bug in `ui_controller.lua` — fixed.
- `node.rt` was fully replaced (not merged) on every STATUS tick, wiping any field the UI layer had written into it — fixed (now merges).
- `node.assigned_power`/`assigned_percent` were computed correctly in `rt_sync.lua` but never persisted to the node object, only to a local, discarded `entry` — the RT card "Soll" display showed 0.0 for every node as a result — fixed.
- LOG collector received nothing (`Recv 0`) due to a channel mismatch: senders used 6502, `shared/constants.lua` defines LOG channel as 6503 — fixed.
- `role.lua` was preserved across reinstalls only in the manual-install codepath, not in the (far more frequently triggered) auto-update reinstall codepath — every auto-update silently wiped the node's role assignment — fixed.
- "Overspeed brake pending" turbine warning logged on every tick with no rate limit, flooding the log ring buffer and pushing out other, potentially more important log lines — now rate-limited to 1x/5s per turbine.
- Repo hygiene pass (2026-07-01, v262): removed 6 orphaned `installer_*.lua` files in the repo root (dead since the monolithic installer rewrite, never `require`'d/`dofile`'d, only referenced by a stale manifest entry), the duplicate `xreactor/xreactor/` path (orphaned since at least v134), and 9 tests for the since-replaced stage-based installer mechanism. `tools/offline_validate.lua`'s required-file check (run by CI on every push) still expected the deleted files to exist and would have failed every subsequent run — fixed alongside the cleanup.

## Known Open Issues

None tracked as open at time of writing (2026-07-01, v262). See RUNTIME_STATUS_2026-06-03.md for the full, dated session log if something regresses.
