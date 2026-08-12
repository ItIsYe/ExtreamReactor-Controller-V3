-- tests/install_p0_2_quiesce_wiring_test.lua
--
-- Regression test fuer INSTALL-P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 4 "Runtime und Installer laufen
-- parallel"). Die funktionalen Kernmechanismen (core/update_handshake.lua,
-- nodes/support/runtime.lua's run_event_loop()-Integration, nodes/energy/
-- heartbeat.lua) sind in eigenen Tests direkt getrieben (core_update_
-- handshake_test.lua, support_runtime_quiesce_test.lua, energy_heartbeat_
-- quiesce_test.lua). Dieser Test prueft strukturell direkt am Quelltext,
-- dass JEDE der acht Rollen tatsaechlich an den Handshake angeschlossen ist
-- -- fuer FUEL/REPROCESSOR/VALVE/WATER insbesondere, dass die physische
-- Sicherzustandsbestaetigung ueber die jeweilige physische Aktor-API laeuft:
--   VALVE:        controller:apply_valve(true, true) (frischer Sorter-Write)
--   FUEL:         redstone_router:begin/poll_quiesce (BLOCKED-ACKs)
--   REPROCESSOR:  enter_standby() + Router-BLOCKED-ACKs
--   WATER:        set_rs_output(..., false, ...)     (echtes true/false, pro Cluster)
-- sowie dass start.lua/auto_update.lua/master/loop.lua/log_collector/
-- main.lua/rt/main.lua tatsaechlich verdrahtet sind. Faellt automatisch
-- durch, sobald der pre-fix-Code (git stash) wieder aktiv ist -- die
-- geprueften Marker existieren dort schlicht nicht.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function assert_contains(src, needle, label)
  if not src:find(needle, 1, true) then
    error(label .. ": expected marker not found: " .. needle)
  end
end

local function assert_not_contains(src, needle, label)
  if src:find(needle, 1, true) then
    error(label .. ": marker must NOT be present: " .. needle)
  end
end

local repo_root = os.getenv("REPO_ROOT") or "."
local function read(rel) return read_file(repo_root .. "/xreactor/" .. rel) end

-- ── VALVE: frischer physischer Sorter-Write/Readback ───────────────────────
do
  local src = read("nodes/valve/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "valve/main.lua")
  assert_contains(src, "on_quiesce = function() return controller:apply_valve(true, true) end", "valve/main.lua")
end

-- ── FUEL: alle konfigurierten Ventile per frischem BLOCKED-ACK bestaetigt ──
do
  local src = read("nodes/fuel/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "fuel/main.lua")
  assert_contains(src, 'rs_router:begin_quiesce("UPDATE_QUIESCE")', "fuel/main.lua")
  assert_contains(src, "return rs_router:poll_quiesce()", "fuel/main.lua")
end

-- ── REPROCESSOR: enter_standby() ist bereits idempotent, wiederverwendet ───
do
  local src = read("nodes/reprocessor/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "reprocessor/main.lua")
  assert_contains(src, 'enter_standby("UPDATE_QUIESCE")', "reprocessor/main.lua")
  assert_contains(src, 'rs_router:begin_quiesce("UPDATE_QUIESCE")', "reprocessor/main.lua")
  assert_contains(src, "return standby == true and rs_router:poll_quiesce()", "reprocessor/main.lua")
end

-- ── WATER: alle Cluster ueber set_rs_output() erzwungen aus, echtes true/false
do
  local src = read("nodes/water/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "water/main.lua")
  assert_contains(src, "quiesce_all_clusters", "water/main.lua")
  assert_contains(src, "set_rs_output(fill_side, false, integrator)", "water/main.lua")
  assert_contains(src, "set_rs_output(drain_side, false, integrator)", "water/main.lua")
end

-- ── RT: Reaktoren und Turbinen physisch sicher + frischer Readback ─────────
do
  local src = read("nodes/rt/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "rt/main.lua")
  assert_contains(src, "reactor_control.apply_update_quiesce(ctx)", "rt/main.lua")
  assert_contains(src, "turbine_control.apply_update_quiesce(ctx)", "rt/main.lua")
  assert_contains(src, "on_quiesce = update_quiesce_safe", "rt/main.lua")
end

-- ── MASTER: eigener Loop (kein run_event_loop), eigener Quiesce-Check ──────
do
  local src = read("master/loop.lua")
  assert_contains(src, 'require("core.update_handshake")', "master/loop.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "master/loop.lua")
  assert_contains(src, "update_handshake.is_quiesce_requested(quiesce_handshake)", "master/loop.lua")
  assert_contains(src, "update_handshake.mark_runtime_stopped(quiesce_handshake)", "master/loop.lua")
end

-- ── LOG_COLLECTOR: eigener Loop, dofile() statt require() (kein bootstrap-
--    garantierter require in diesem historisch eigenstaendigen Modul) ──────
do
  local src = read("nodes/log_collector/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "log_collector/main.lua")
  assert_contains(src, 'dofile, "/xreactor/core/update_handshake.lua"', "log_collector/main.lua")
  assert_contains(src, "update_handshake.mark_runtime_stopped(quiesce_handshake)", "log_collector/main.lua")
end

-- ── nodes/support/runtime.lua: gemeinsamer Hook-Punkt fuer RT/VALVE/FUEL/
--    REPROCESSOR/WATER, rueckwaertskompatibel (5. Parameter optional) ──────
do
  local src = read("nodes/support/runtime.lua")
  assert_contains(src, "function M.run_event_loop(receive_timeout, services, comms, after_cycle, quiesce_opts)", "support/runtime.lua")
  assert_contains(src, "handshake_lib.is_quiesce_requested(quiesce_opts.handshake)", "support/runtime.lua")
  assert_contains(src, "handshake_lib.mark_runtime_stopped(quiesce_opts.handshake)", "support/runtime.lua")
end

-- ── start.lua: Handshake-Objekt global bereitgestellt, waitForAll statt
--    waitForAny (sonst wuerde ein sauberer Rollen-Exit den Auto-Update-Loop
--    vorzeitig abwuergen, siehe Fix-Kommentar dort) ─────────────────────────
do
  local src = read("start.lua")
  assert_contains(src, "_G.__xreactor_update_handshake = update_handshake", "start.lua")
  assert_contains(src, "parallel.waitForAll(function() dofile(entry) end, auto_loop)", "start.lua")
  assert_not_contains(src, "parallel.waitForAny(function() dofile(entry) end, auto_loop)", "start.lua")
  assert_contains(src, "auto_mod.make_loop(interval, update_handshake)", "start.lua")
end

-- ── installer/auto_update.lua: fordert Quiesce an und wartet auf
--    RUNTIME_STOPPED BEVOR der Installer laeuft; bricht die Installation
--    ab (statt sie ungeprueft zu starten), wenn das nicht bestaetigt wird ──
do
  local src = read("installer/auto_update.lua")
  assert_contains(src, "function M.make_loop(interval_s, handshake)", "installer/auto_update.lua")
  assert_contains(src, "local quiesced, quiesce_err = request_and_await_quiesce(handshake)", "installer/auto_update.lua")
  assert_contains(src, 'update_handshake.wait_for_runtime_stopped(handshake, 20)', "installer/auto_update.lua")
  -- Muss VOR dem eigentlichen Download-/Installlauf entschieden werden
  -- (nicht zu verwechseln mit fetch_remote_version()'s eigener, frueherer
  -- "for attempt = 1, 3 do"-HTTP-Retry-Schleife).
  local quiesce_pos = src:find("local quiesced, quiesce_err = request_and_await_quiesce", 1, true)
  local retry_loop_pos = src:find("for attempt = 1, 3 do", (quiesce_pos or 1) + 1, true)
  if not (quiesce_pos and retry_loop_pos and quiesce_pos < retry_loop_pos) then
    error("installer/auto_update.lua: quiesce must be requested BEFORE the install retry loop")
  end
end

print("install_p0_2_quiesce_wiring_test.lua: ok")
