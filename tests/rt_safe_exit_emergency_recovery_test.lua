package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (2026-09-18, follow-up to wiring node_state_machine:
-- tick() into control_tick() for real): module_lifecycle.lua always pairs
-- entering EMERGENCY with ctx.setState(SAFE, ...) (see its temperature/
-- coolant trip handlers). Before this fix, reactor_control.lua's SAFE-Exit
-- (temperature recovered) only called ctx.setState(MASTER, ...) -- it never
-- transitioned node_state_machine back out of EMERGENCY. Once node_state_
-- machine:tick() is actually wired (this session), that meant EVERY trip,
-- however brief, permanently stopped adjust_reactors()/adjust_turbines()
-- from ever running again: only running_on_tick()/limited_on_tick()/
-- startup_on_tick()/autonom_on_tick() call them, and emergency_on_tick()
-- deliberately does not (matching SCRAM semantics) -- with no path back to
-- RUNNING, that was permanent for the rest of the node's uptime.
--
-- Fix: reactor_control.lua's SAFE-Exit now also transitions node_state_
-- machine EMERGENCY -> RUNNING, mirroring module_lifecycle.lua's own
-- SAFE+EMERGENCY entry pairing.

local reactor_control = require('nodes.rt.reactor_control')

local function assert_eq(a, b, m) if a ~= b then error((m or 'assert_eq') .. ': expected=' .. tostring(b) .. ' actual=' .. tostring(a)) end end

local function make_ctx(opts)
  local current_state = 'SAFE'
  local machine_state = opts.machine_state
  local transitions = {}
  local ctx = {
    current_state = function() return current_state end,
    STATE = { SAFE = 'SAFE', MASTER = 'MASTER' },
    config = { safety = { max_temperature = 2000, temperature_hysteresis = 50 }, reactors = {} },
    modules = {},
    peripherals = { reactors = {} },
    setState = function(next_state) current_state = next_state end,
    warn_once = function() end,
    log = function() end,
    CONFIG = { ROD_MAX = 100 },
  }
  reactor_control.applyReactorRods = function() end
  if opts.provide_node_state_machine then
    ctx.get_node_state_machine = function()
      return {
        state = function() return machine_state end,
        transition = function(_, target) table.insert(transitions, target); machine_state = target end,
      }
    end
  end
  ctx.config.reactors = { 'R1' } -- non-empty so the SAFE-Exit branch actually runs
  return ctx, function() return current_state end, function() return machine_state end, transitions
end

-- 1) EMERGENCY -> temperature recovers -> must transition back to RUNNING,
--    alongside the existing operating-mode recovery to MASTER.
local ctx1, get_state1, get_machine1, transitions1 = make_ctx({
  machine_state = 'EMERGENCY', provide_node_state_machine = true,
})
reactor_control.updateReactorControl(ctx1)
assert_eq(get_state1(), 'MASTER', 'operating mode must recover to MASTER')
assert_eq(get_machine1(), 'RUNNING', 'node_state_machine must recover EMERGENCY -> RUNNING')
assert_eq(#transitions1, 1, 'exactly one node_state_machine transition expected')
assert_eq(transitions1[1], 'RUNNING', 'the transition must target RUNNING')

-- 2) Not currently EMERGENCY (e.g. already RUNNING for some other reason)
--    -- must NOT fire a redundant/incorrect transition.
local ctx2, get_state2, get_machine2, transitions2 = make_ctx({
  machine_state = 'RUNNING', provide_node_state_machine = true,
})
reactor_control.updateReactorControl(ctx2)
assert_eq(get_state2(), 'MASTER', 'operating mode must still recover to MASTER')
assert_eq(#transitions2, 0, 'must not transition node_state_machine when it was not EMERGENCY')

-- 3) ctx has no get_node_state_machine at all (older/simpler callers, e.g.
--    existing unit tests) -- must not error, operating-mode recovery must
--    still work.
local ctx3, get_state3 = make_ctx({ provide_node_state_machine = false })
local ok3 = pcall(reactor_control.updateReactorControl, ctx3)
assert_eq(ok3, true, 'must not error when ctx has no node_state_machine accessor at all')
assert_eq(get_state3(), 'MASTER', 'operating mode recovery must work without node_state_machine access')

print('rt_safe_exit_emergency_recovery_test.lua: ok')
