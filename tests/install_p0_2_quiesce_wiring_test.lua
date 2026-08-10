-- tests/install_p0_2_quiesce_wiring_test.lua
-- Structural wiring regression for the managed update/quiesce contract.

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

-- VALVE: updater proof must force a fresh physical sorter write rather than
-- trusting current_high from RAM.
do
  local src = read("nodes/valve/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "valve/main.lua")
  assert_contains(src, "on_quiesce = function() return apply_valve(true, true) end", "valve/main.lua")
  assert_contains(src, "local function apply_valve(high, force_physical)", "valve/main.lua")
end

-- FUEL: runtime stops only after confirmed all-BLOCKED router quiesce.
do
  local src = read("nodes/fuel/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "fuel/main.lua")
  assert_contains(src, 'rs_router:begin_quiesce("UPDATE_QUIESCE")', "fuel/main.lua")
  assert_contains(src, "return rs_router:poll_quiesce()", "fuel/main.lua")
end

-- REPROCESSOR: standby plus confirmed all-BLOCKED router quiesce.
do
  local src = read("nodes/reprocessor/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "reprocessor/main.lua")
  assert_contains(src, 'enter_standby("UPDATE_QUIESCE")', "reprocessor/main.lua")
  assert_contains(src, 'rs_router:begin_quiesce("UPDATE_QUIESCE")', "reprocessor/main.lua")
  assert_contains(src, "return standby == true and rs_router:poll_quiesce()", "reprocessor/main.lua")
end

-- WATER: both outputs of every cluster are forced off.
do
  local src = read("nodes/water/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "water/main.lua")
  assert_contains(src, "quiesce_all_clusters", "water/main.lua")
  assert_contains(src, "set_rs_output(fill_side, false, integrator)", "water/main.lua")
  assert_contains(src, "set_rs_output(drain_side, false, integrator)", "water/main.lua")
end

-- RT: control freeze plus reactor/turbine physical safe readback.
do
  local src = read("nodes/rt/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "rt/main.lua")
  assert_contains(src, "if rt_update_quiescing then return end", "rt/main.lua")
  assert_contains(src, "reactor_control.apply_update_quiesce(ctx)", "rt/main.lua")
  assert_contains(src, "turbine_control.apply_update_quiesce(ctx)", "rt/main.lua")
  assert_contains(src, "on_quiesce = update_quiesce_safe", "rt/main.lua")
end

-- MASTER has no local process actuators, but must still go through the shared
-- SAFE_OUTPUTS_APPLIED -> RUNTIME_STOPPED state transition.
do
  local src = read("master/loop.lua")
  assert_contains(src, 'require("core.update_handshake")', "master/loop.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "master/loop.lua")
  assert_contains(src, "update_handshake.is_quiesce_requested(quiesce_handshake)", "master/loop.lua")
  assert_contains(src, "update_handshake.mark_safe_outputs_applied(quiesce_handshake)", "master/loop.lua")
  assert_contains(src, "update_handshake.mark_runtime_stopped(quiesce_handshake)", "master/loop.lua")
  assert_not_contains(src, "remote_update.run(", "master/loop.lua")
end

-- LOG_COLLECTOR has its own event loop but uses the same handshake states.
do
  local src = read("nodes/log_collector/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "log_collector/main.lua")
  assert_contains(src, 'dofile, "/xreactor/core/update_handshake.lua"', "log_collector/main.lua")
  assert_contains(src, "update_handshake.mark_safe_outputs_applied(quiesce_handshake)", "log_collector/main.lua")
  assert_contains(src, "update_handshake.mark_runtime_stopped(quiesce_handshake)", "log_collector/main.lua")
end

-- Shared runtime accepts only an explicit true actuator proof.
do
  local src = read("nodes/support/runtime.lua")
  assert_contains(src, "function M.run_event_loop(receive_timeout, services, comms, after_cycle, quiesce_opts)", "support/runtime.lua")
  assert_contains(src, "handshake_lib.is_quiesce_requested(quiesce_opts.handshake)", "support/runtime.lua")
  assert_contains(src, "confirmed = result3 == true", "support/runtime.lua")
  assert_contains(src, "handshake_lib.mark_safe_outputs_applied(quiesce_opts.handshake)", "support/runtime.lua")
  assert_contains(src, "handshake_lib.mark_runtime_stopped(quiesce_opts.handshake)", "support/runtime.lua")
  assert_not_contains(src, "result3 ~= false", "support/runtime.lua")
end

-- start.lua owns one shared object and waits for both role and updater.
do
  local src = read("start.lua")
  assert_contains(src, "_G.__xreactor_update_handshake = update_handshake", "start.lua")
  assert_contains(src, "parallel.waitForAll(function() dofile(entry) end, auto_loop)", "start.lua")
  assert_not_contains(src, "parallel.waitForAny(function() dofile(entry) end, auto_loop)", "start.lua")
  assert_contains(src, "auto_mod.make_loop(interval, update_handshake)", "start.lua")
end

-- The managed updater must pin one immutable SHA, then quiesce before any
-- installer execution. Timeout/error recovery must not leave a latent stopped
-- role with no updater waiting for it.
do
  local src = read("installer/auto_update.lua")
  assert_contains(src, "function M.make_loop(interval_s, handshake)", "installer/auto_update.lua")
  assert_contains(src, "local quiesced, qerr = request_and_await_quiesce(handshake)", "installer/auto_update.lua")
  assert_contains(src, 'update_handshake.wait_for_runtime_stopped(handshake, 20)', "installer/auto_update.lua")
  assert_contains(src, 'local sha, sha_err = resolve_sha()', "installer/auto_update.lua")
  assert_contains(src, 'if not valid_sha(sha) then return false, "immutable sha required" end', "installer/auto_update.lua")
  assert_contains(src, "recover_after_quiesced_failure", "installer/auto_update.lua")
  assert_contains(src, "update_handshake.reset(handshake)", "installer/auto_update.lua")

  local perform_pos = assert(src:find("local function perform_update", 1, true))
  local quiesce_pos = assert(src:find("request_and_await_quiesce(handshake)", perform_pos, true))
  local run_pos = assert(src:find("run_update(sha)", quiesce_pos, true))
  if quiesce_pos >= run_pos then
    error("installer/auto_update.lua: quiesce must complete BEFORE run_update")
  end
end

-- Shared REMOTE_UPDATE entry point may queue a request but may not execute the
-- installer while managed runtime is still active.
do
  local src = read("core/remote_update.lua")
  assert_contains(src, "function M.queue_command(opts)", "core/remote_update.lua")
  assert_contains(src, "request_remote_update(handshake", "core/remote_update.lua")
  assert_contains(src, "if not update_handshake.is_runtime_stopped(managed) then", "core/remote_update.lua")
end

print("install_p0_2_quiesce_wiring_test.lua: ok")
