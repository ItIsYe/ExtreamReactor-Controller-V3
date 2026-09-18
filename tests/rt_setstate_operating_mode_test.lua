-- tests/rt_setstate_operating_mode_test.lua
--
-- Regression test for a P0 safety bug found via external code analysis
-- (2026-09-18), independently verified against the source: main.lua's
-- ctx.setState(next_state, reason) used to forward next_state UNGUARDED
-- into node_state_machine:transition(next_state). All four real callers
-- (reactor_control.lua's SAFE auto-recovery -> ctx.STATE.MASTER;
-- module_lifecycle.lua x2 -> ctx.STATE.SAFE) only ever pass values from
-- the OPERATING-MODE namespace (ctx.STATE: INIT/AUTONOM/MASTER/SAFE) --
-- a completely different system from node_state_machine's lifecycle
-- states (OFF/STARTUP/RUNNING/LIMITED/AUTONOM/MANUAL/EMERGENCY, see
-- shared/constants.lua's node_states). Neither "MASTER" nor "SAFE" is a
-- valid node_state_machine target, so core/state_machine.lua's
-- transition() unconditionally throws error("invalid state: ..."), and
-- nothing in setState() catches it. Since control_tick() is only guarded
-- from the outside (service_manager's pcall), this crashed the entire
-- control tick every single time:
--   - reactor_control.lua's SAFE-recovery could never actually flip the
--     operating mode back to MASTER once the reactor cooled down -- the
--     node stayed stuck in SAFE forever, silently (just repeated
--     "Service tick failed (control)" retries, no explicit error visible
--     to the operator).
--   - Worse: module_lifecycle.lua calls ctx.setState(SAFE, ...) FIRST,
--     then (in the same "if ctx.current_state() ~= ctx.STATE.SAFE"
--     branch, right after) ctx.node_state_machine:transition(EMERGENCY) --
--     the actual SCRAM safety response. The crash at setState() prevented
--     that second, otherwise-valid transition from ever being reached --
--     a real temperature/coolant trip would never have triggered SCRAM,
--     only an infinite loop of crashing control ticks.
--
-- Fix: setState() now only sets current_state_value (the field
-- ctx.current_state() reads) -- exactly what all four real callers need.
-- node_state_machine transitions happen through their own, separate,
-- correct call sites elsewhere and must not be duplicated here.
--
-- main.lua has heavy boot-time side effects and cannot be require()'d
-- directly (same reasoning as install_p0_2_quiesce_wiring_test.lua), so
-- this is a structural source check.

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
    error(label .. ": marker must NOT be present anymore: " .. needle)
  end
end

local repo_root = os.getenv("REPO_ROOT") or "."
local src = read_file(repo_root .. "/xreactor/nodes/rt/main.lua")

local setstate_pos = src:find("setState = function(next_state, reason)", 1, true)
if not setstate_pos then
  error("main.lua: setState closure not found")
end
local body = src:sub(setstate_pos, setstate_pos + 400)

assert_contains(body, "current_state_value = next_state", "main.lua's setState()")
assert_not_contains(body, "node_state_machine:transition(next_state)", "main.lua's setState()")

-- The real callers must still pass operating-mode values, never a
-- node_state_machine value -- confirms the fix's premise still holds.
local reactor_control_src = read_file(repo_root .. "/xreactor/nodes/rt/reactor_control.lua")
assert_contains(reactor_control_src, "ctx.setState(ctx.STATE.MASTER, \"SAFETY_TEMPERATURE_RECOVERED\")",
  "reactor_control.lua's SAFE-recovery call")

local module_lifecycle_src = read_file(repo_root .. "/xreactor/nodes/rt/module_lifecycle.lua")
assert_contains(module_lifecycle_src, "ctx.setState(ctx.STATE.SAFE, \"SAFETY_TEMPERATURE_HIGH\")",
  "module_lifecycle.lua's temperature-trip call")
assert_contains(module_lifecycle_src, "ctx.setState(ctx.STATE.SAFE, \"SAFETY_COOLANT_LOW\")",
  "module_lifecycle.lua's coolant-trip call")

print("rt_setstate_operating_mode_test.lua: ok")
