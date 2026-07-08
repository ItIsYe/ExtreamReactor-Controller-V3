# XReactor Controller V3

Distributed CC:Tweaked controller for **Extreme Reactors 2** (reactors + turbines), **Mekanism Induction Matrices**, and supporting infrastructure. One MASTER computer coordinates state, setpoints, telemetry, alerts, and UI. Hardware control stays strictly local to the node that owns the peripherals.

> **Branch:** `beta` — active development.
> **Manifest / Release:** `manifest-v343` / `beta-v343` · ATM10 (MC 1.21.1)
> **Status:** Phase 1–4 rewrite complete. Since v274: a new shared "Mockup Dashboard Toolkit" (`core/mockup_ui.lua`) was rolled out across most node-local displays and 4 new AUX pages (Maintenance, Updates, System Map, Config Editor); several critical data-pipeline bugs were found and fixed (see RUNTIME_STATUS_2026-06-03.md for full details, including a `refresh_bindings()` early-return bug that silently left `devices.turbines`/`devices.reactors` empty forever once triggered); and RT nodes with more than one reactor now regulate each reactor independently based on its own internal steam fill ratio (configurable target, default 50%, editable live via the Config Editor).
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

**Multi-node assignment** (`rt_sync.lua`): nodes are sorted by capacity; the master counts how many are needed for `global_target`; `uniform_pct = global_target / sum(needed capacities) × 100`; only the needed nodes are assigned active load, the rest go to `shed`/`standby`. The computed `assigned_power`/`assigned_percent` are persisted directly on the node object so the UI shows a stable value — this used to only exist in a temporary, discarded structure, which caused the UI to permanently show `Soll 0.0` per RT node. Fixed 2026-07-07.

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
| `nodes/rt/reactor_control.lua` | Rod control — shared steam-margin regulator for single-reactor nodes, independent per-reactor regulator for multi-reactor nodes (see below) |
| `nodes/rt/turbine_control.lua` | Flow, inductor, overspeed, rotation |
| `nodes/rt/capacity_learning.lua` | Continuous capacity measurement |
| `nodes/rt/status_snapshot.lua` | Status payload for Master |
| `nodes/rt/state_handlers.lua` | State machine (AUTONOM/MASTER/SAFE) |
| `nodes/rt/discovery_runtime.lua` | Peripheral discovery and binding — populates `devices.reactors`/`devices.turbines`, re-run every ~60s in the main loop (not just once at boot) |
| `nodes/rt/monitor_ui.lua` + `nodes/rt/mockup_pages.lua` | RT's own on-node monitor UI (4 pages: Overview/Turbines/Reactors/Diagnostics), plus the Ampel status monitor (see below) |

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

### Multiple Reactors on One RT Node — Independent Regulation

An RT node can have more than one reactor wired to it (e.g. two identical reactors sharing a common pool of turbines on the same wired data bus, with no explicit turbine-to-reactor mapping). Since v313, each reactor is regulated **independently**:

- With exactly one reactor, behavior is unchanged (shared regulator based on total steam demand across all turbines).
- With more than one reactor, each one is regulated based on its **own internal steam fill ratio** (not the shared turbine demand, since there's no way to know which turbines are physically fed by which reactor) — if one reactor's tank runs low relative to the other, its rods move independently to compensate.
- The target fill ratio (default 50%) is editable live via the Master's Config Editor AUX page (`REACTOR FILL TARGET` card, 10–90% in 5% steps) and is sent to **all** RT nodes, persisted to each node's `config/rt.lua`.
- Each reactor gets its own EMA smoothing state, steam-guard state, and rod-apply rate limit — none of this is shared between reactors on the same node.
- Multi-reactor nodes use a faster, dedicated ramp configuration (`config.rails.reactor_rods_individual`, overridable) and a shorter outer control-loop tick (`config.rails.reactor_adjust_interval_individual`, default 1.0s) than the single-reactor shared path, since an individual reactor's internal tank is more volatile than a demand value averaged across many turbines.

### Capacity Learning

Learning runs continuously and independently. A measurement only counts when **at least 80% of turbines are simultaneously at target RPM** — this threshold is deliberate: it protects against measuring a false "maximum" from a partial/gamed sample, at the cost of only being reachable near full-power operation (e.g. under a PEAK profile). This is expected behavior, not a bug — see the discussion in the 2026-06-30/07-01 session log for the reasoning.

Once `capacity_ready = true`, the result is cached to disk (`/xreactor/config/capacity_cache.lua`, preserved across reinstalls) and the Master prefers `learned_capacity_total` over the currently measured output when computing the PEAK power target — this was itself a bug fix (see RUNTIME_STATUS_2026-06-03.md).

### Optional Peripheral Features (`xreactor/optional/`)

A small set of features are **opt-in only** — they require additional physical hardware (a second monitor, a Speaker, a Pocket Computer) and are never installed unless explicitly selected. Running `installer` interactively asks about each one (`ampel installieren? [j/N]`, etc.); the choice is persisted to `/xreactor/config/optional_features.lua` and survives reinstalls/auto-updates without re-prompting. If a feature isn't installed, the corresponding `require()` call in the core code is `pcall`-guarded and the entire code path is silently skipped — no error, no effect.

#### Ampel Status Monitor (1×3, RT, ENERGY, and MASTER)

Attach a second monitor (wired modem, scaled to exactly 1 wide × 3 tall) to an RT, ENERGY, **or** MASTER computer and it is auto-detected — no configuration needed beyond selecting the relevant feature during install (`ampel` for RT/ENERGY, `master_ampel` for MASTER). Shows a solid color reflecting status, no text.

| Color | RT meaning | ENERGY meaning | MASTER meaning |
|-------|-----------|-----------------|-----------------|
| Green | Delivering normally | Storage % within normal range | Everything normal |
| Yellow | Learning capacity, starting up, or waiting for a setpoint | Below the warning threshold | At least one RT node still learning capacity |
| Orange | Output deviates from target, or over-delivering | Above the "nearly full" threshold | At least one WARN-level alert active |
| Red | Under-delivering (emergency) | Below the critical threshold | At least one CRITICAL alert, or an RT node in SAFE/EMERGENCY |
| Gray | Shutting down / on standby (SHED) | Degraded / no data | Plant deliberately off (RT global hold, or no power target) |

MASTER's Ampel (`xreactor/optional/master_ampel.lua`) evaluates priority Gray > Red > Orange > Yellow > Green — a deliberately shut-down plant never shows red. RT/ENERGY share one implementation (`xreactor/optional/ampel.lua`). ENERGY's thresholds (default 15/30/95%) are configurable via `/xreactor/config/ampel_thresholds.lua`, preserved across reinstalls.

Implementation notes: the Ampel logic is fully `pcall`-isolated and identifies the main monitor by name to exclude it reliably. A separate, unrelated bug (`adapters/monitor.lua` main-monitor selection with zero size check) could previously cause a 1×3 Ampel monitor to be picked as the **main** monitor if it happened to sort alphabetically first — fixed by rejecting any 1-wide/≤3-tall monitor as a main-monitor candidate, and switching the search strategy to "largest" (2026-07-06).

#### Speaker Alarm (any node type)

An attached CC:Tweaked Speaker (any name, auto-detected) plays short tones for named events, with a per-event cooldown so it can't spam. `xreactor/optional/speaker_alarm.lua` exposes a generic `play(event_name, overrides)` API usable by **any** node type, not just MASTER:

| Event | Default trigger |
|-------|-----------------|
| `alarm` / `critical` | MASTER: at least one CRITICAL alert active |
| `clear` | MASTER: transition from CRITICAL-active to no-CRITICAL (all-clear) |
| `warning` | Available for any WARN-level condition a caller wants to sonify |
| `startup` | Any node: played once at the end of boot, alongside the startup diagnostic report |
| `node_offline` | MASTER: a `NODE_COMMS_DOWN` alert newly appears for a node |
| `safe_mode` | MASTER: an RT node newly enters SAFE/EMERGENCY (`RT_SAFE_MODE` alert) |
| `capacity_learned` | RT: capacity learning transitions from not-ready to ready |
| `update_available` | Any node: the auto-updater detects a newer version before installing it |

Each event only fires once per new occurrence (not continuously while the condition persists), except `alarm`/`warning` which re-fire on their own cooldown. Every node type creates its own Speaker instance; instances don't share cooldown state across node types.

#### Pocket Computer Remote Query & Control

Lets a Pocket Computer (or any other computer not registered as a regular node) query MASTER for a compact status summary, and optionally issue a small set of remote-control commands, without walking up to a monitor.

- **Master side** (`xreactor/optional/pocket_query_handler.lua`, feature name `pocket_query`): answers `POCKET_QUERY` with a one-shot `POCKET_STATUS` reply on the STATUS channel (6501). Also handles `POCKET_COMMAND` messages for remote control.
- **Client** (`xreactor/optional/pocket_client.lua`): a standalone script, **not** part of the role-based installer flow. Copy it manually onto the Pocket Computer and run it; it polls every 5s and displays the reply. `[Q]` to quit, `[C]` opens a command menu (RT-Hold toggle, profile set, per-node maintenance toggle).
- **Safety**: every `POCKET_COMMAND` requires a rotating 6-digit token, shown on the Master Overview screen and regenerated every 5 minutes. A command with a wrong or expired token is rejected with no side effect — this prevents accidental or automated remote control without someone physically reading the token off the Master monitor.

---

## Master UI

### Layout System (`master/ui/layout.lua`)

Badge rows (the small colored status labels like `RT OK | M OK | MASTER | CAP | SHD`) are built centrally through `layout.badge_row()`, which knows the monitor width in advance and degrades gracefully: full labels if there's room, short forms if not, lowest-priority badges dropped last if it still doesn't fit. This replaced ad-hoc per-view badge rendering that could silently overlap or get cut off on narrow monitors — a recurring problem before this was introduced 2026-07-07.

### Overview / Summary

The `overview` view (`master/ui/overview.lua`) is the single "everything at a glance" screen: system status, controls (profile/auto/RT-hold), alerts, key metrics (power target vs actual, energy %, **RT fleet summary** — active/total node count and current assignment state, without switching to the RT view), and a prioritized node table. Uses the classic panel/text layout (not the newer `core/mockup_ui.lua` toolkit used elsewhere — reverted by request 2026-07-05, `master/ui/rt_dashboard.lua` kept the newer style).

### Alerts

`master/ui/alerts.lua` and the AUX-monitor "Logs" view (`master/ui/alarms.lua`) both draw from the real `alert_service` (active CRITICAL/WARN/INFO counts) via `ui_controller.build_models()`'s `alerts`/`alarms` models. Alerts carry a lifecycle state (`neu`/`aktiv`/`quittiert`/`behoben`/`wieder_aufgetreten`, derived in `core/alerts.lua`'s `lifecycle_state()`) — reoccurring alerts (resolved, then triggered again within an hour by the same code+source) are marked with an `R` prefix in the alert list.

### AUX Monitor Pages

In addition to Overview, RT, Energy, Resources, Alerts, and Logs, four more pages are available on AUX monitors (touch-cyclable, added 2026-07-02):

| Page | Purpose |
|------|---------|
| **Maintenance** | All nodes across all roles in one table with AUTO/MAINTENANCE status; tap a row to toggle. LOG in maintenance shows as LIMITED (not WARNING) since it's not a plant-critical role. |
| **Updates** | Every node's `manifest_version` vs MASTER's own — green (current), yellow (1 version behind), orange (2+ behind), red (unknown), gray (offline). Populated by `manifest_version` automatically attached to every heartbeat payload (`services/heartbeat_service.lua`). |
| **System Map** | Per-role aggregated status (worst individual node status wins) shown as a simple text/block diagram of plant dependencies (Fuel → RT → Energy, Water → RT, Log). |
| **Config Editor** | PEAK/IDLE thresholds, RT Global Hold, Fuel Reserve, Water Target, Auto-Update, and Reactor Fill Target (for multi-reactor RT nodes) — all in one place, `[-]`/`[+]` touch buttons apply changes live and persist them to the relevant node's config file. |

All AUX pages only redraw when their model actually changed, a touch occurred, or their declared refresh interval elapsed (fixed 2026-07-05/06) — previously every page redrew unconditionally on every tick regardless of whether any data changed.

---

## Core Features

These are **not** opt-in — they're part of the standard install on every affected role.

- **Startup diagnostic report** (`xreactor/core/startup_report.lua`): every node type prints a one-shot `=== Startup-Diagnose ===` summary at the end of boot, instead of scattered individual log lines. Optionally plays a Speaker "startup" tone if that feature is installed.
- **RT redundancy warning** (`xreactor/core/alert_rules.lua`, code `RT_NO_REDUNDANCY`): MASTER raises a WARN-level alert when exactly one RT node is actively assigned and the remaining nodes' combined learned capacity wouldn't cover current demand if that sole node failed.
- **Per-node maintenance mode**: touch a RT card's title on the Master UI (or use the dedicated Maintenance AUX page) to toggle `node.maintenance_mode`. Excluded from setpoint assignment, highest priority even above global RT-Hold, stays online/visible.
- **Configurable PEAK/IDLE/shed thresholds**: PEAK/IDLE thresholds are adjustable via the Overview screen or Config Editor, 5%-steps, with a safety clamp keeping IDLE above PEAK. A fourth automation stage forces `power_target = 0` (all RT nodes shed) once energy storage exceeds a configurable shed threshold (default 98%).
- **Alarm lifecycle**: see the Alerts section above.
- **Manifest role isolation**: each role now only receives the files it actually needs — `base_files` entries without `required_for`/`always` are installed on every role unconditionally (a real bug found and fixed 2026-07-06: `master/context.lua`, `master/loop.lua`, and the ENERGY-only `nodes/energy/heartbeat.lua`/`matrix.lua` were previously shipped to every role).

---




These were real bugs found and fixed during the 2026-06-30/07-01 hardening sessions. Listed here so future debugging doesn't waste time re-investigating already-closed issues:

- Setpoint transmission (Master → RT) silently stayed near zero due to a field-ordering bug in `populate_rt_status()` (message_handlers.lua) — fixed.
- PEAK profile power target froze at the currently-measured (possibly throttled) output instead of the learned max capacity — fixed.
- `node.assignment_state`/`node.control_source` could get stuck showing stale "UNASSIGNED"/"LOCAL" on some nodes due to a sticky self-referential read-before-write bug in `ui_controller.lua` — fixed.
- `node.rt` was fully replaced (not merged) on every STATUS tick, wiping any field the UI layer had written into it — fixed (now merges).
- `node.assigned_power`/`assigned_percent` were computed correctly in `rt_sync.lua` but never persisted to the node object, only to a local, discarded `entry` — the RT card "Soll" display showed 0.0 for every node as a result — fixed.
- LOG collector received nothing (`Recv 0`) due to a channel mismatch: senders used 6502, `shared/constants.lua` defines LOG channel as 6503 — fixed.
- `role.lua` was preserved across reinstalls only in the manual-install codepath, not in the (far more frequently triggered) auto-update reinstall codepath — every auto-update silently wiped the node's role assignment — fixed.
- "Overspeed brake pending" turbine warning logged on every tick with no rate limit, flooding the log ring buffer and pushing out other, potentially more important log lines — now rate-limited to 1x/5s per turbine.
- Repo hygiene pass (2026-07-07, v262): removed 6 orphaned `installer_*.lua` files in the repo root (dead since the monolithic installer rewrite, never `require`'d/`dofile`'d, only referenced by a stale manifest entry), the duplicate `xreactor/xreactor/` path (orphaned since at least v134), and 9 tests for the since-replaced stage-based installer mechanism. `tools/offline_validate.lua`'s required-file check (run by CI on every push) still expected the deleted files to exist and would have failed every subsequent run — fixed alongside the cleanup.

## Known Open Issues

None tracked as open at time of writing (2026-07-07, v343). See RUNTIME_STATUS_2026-06-03.md for the full, dated session log if something regresses.
