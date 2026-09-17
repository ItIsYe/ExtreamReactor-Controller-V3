package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (user report 2026-09-17: "wenn rt in capacity learn ist
-- aber der master nichts anfordert bleibt der reaktor solange mit den
-- fuelrods auf 100% also 0% leistung bis der master etwas anfordert", and
-- follow-up: "das kapasity lerning ist komplet unabhaengig vom regulaer
-- betrieb ... egal ob master oder nicht oder ob ein soll wert da ist oder
-- nicht auch wenn der soll auf 0 ist der reaktor [soll] starten und die
-- turbinen eingelernt werden, wenn das durch ist soll alles in den
-- normalbetrieb gehen").
--
-- Root cause: start_module() (which actually calls setActive(true)/engages
-- inductors on the physical reactor/turbine) was ONLY ever reachable via
-- request_startup_if_needed(), which itself required ctx.get_current_
-- state() == ctx.STATE.MASTER AND a MASTER-issued SET_SETPOINTS command.
-- An RT that never saw a MASTER (or whose MASTER never sent a setpoint,
-- or sent one with power=0) therefore never activated its reactor at all
-- -- rods stayed fully inserted forever, and capacity_learning.lua (which
-- needs turbines actually spinning at target RPM to measure anything)
-- could never collect a single sample.
--
-- state_handlers.request_capacity_learning_startup_if_needed() is
-- completely independent of normal operation: it fires regardless of
-- AUTONOM/MASTER and regardless of any setpoint value (it never even looks
-- at ctx.targets), gated ONLY on capacity learning not yet being ready,
-- the node-state machine actually being OFF, and SAFE never auto-starting.
-- Once learning completes, control simply resumes normal operation (master
-- regulation if a master is present, idle otherwise) -- see main.lua's
-- monitor_master() for that hand-back.
--
-- IMPORTANT, second regression (also 2026-09-17, "haengt im learning fest,
-- keine turbinen flow steuerung, keine induction coil steuerung, reaktor
-- auch nicht zuverlaessig"): an earlier version of this function also
-- allowed machine_state RUNNING and LIMITED, reasoning that a master-parked
-- (LIMITED) or already-running node might need re-kicking too. But BOTH
-- running_on_tick() and limited_on_tick() already call adjust_reactors()/
-- adjust_turbines()/monitor_master() unconditionally every tick (see
-- M.build() above) -- capacity learning already samples passively there,
-- no restart needed. Because this function unconditionally transitions to
-- STARTUP, and startup_on_tick() immediately flips back to RUNNING once
-- its (typically empty, since modules are usually already active) queue
-- drains, allowing RUNNING caused a tick-by-tick RUNNING<->STARTUP
-- oscillation for as long as learning.ready stayed false: every
-- monitor_master() call from RUNNING re-triggered the very next STARTUP
-- transition. startup_on_enter() resets ctx.targets.steam and the startup
-- watchdog on every single re-entry, which never let flow/coil regulation
-- settle -- a new, self-inflicted deadlock. Fixed by restricting this
-- function to machine_state == OFF only, the one state whose on_tick does
-- NOT already run the control loop on its own.

local constants = require('shared.constants')
local handlers = require('nodes.rt.state_handlers')

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ' expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local STATE = { INIT = 'INIT', MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' }

local function make_ctx(opts)
  local transitions = {}
  local machine_state = opts.machine_state or constants.node_states.OFF
  return {
    constants = constants,
    STATE = STATE,
    modules = opts.modules,
    capacity_learning = opts.capacity_learning,
    targets = opts.targets, -- deliberately not read by the function under test
    log = function() end,
    get_active_startup = function() return opts.active_startup end,
    get_current_state = function() return opts.current_state end,
    get_node_state_machine = function()
      return {
        state = function() return machine_state end,
        transition = function(_, next_state)
          table.insert(transitions, next_state)
          machine_state = next_state
        end,
      }
    end,
    _transitions = transitions,
  }
end

local function fresh_off_modules()
  return {
    ['turbine:A'] = { type = 'turbine', state = 'OFF' },
    ['reactor:A'] = { type = 'reactor', state = 'OFF' },
  }
end

-- 1) AUTONOM, machine_state OFF, never learned -- must fire and transition
--    to STARTUP.
local ctx_autonom = make_ctx({
  modules = fresh_off_modules(), capacity_learning = nil,
  current_state = STATE.AUTONOM, machine_state = constants.node_states.OFF,
})
assert_true(handlers.request_capacity_learning_startup_if_needed(ctx_autonom, 'TEST'),
  'must fire in AUTONOM when capacity learning has never run and the node is OFF')
assert_eq(ctx_autonom._transitions[1], constants.node_states.STARTUP,
  'must transition the node state machine to STARTUP')

-- 2) MASTER connected but has not requested anything (no setpoints ever
--    received, targets left at their zero default), machine_state OFF --
--    must fire exactly like AUTONOM. Capacity learning does not care about
--    the master connection or any setpoint value.
local ctx_master_idle = make_ctx({
  modules = fresh_off_modules(), capacity_learning = nil,
  current_state = STATE.MASTER, targets = { power = 0, steam = 0, rpm = 0 },
  machine_state = constants.node_states.OFF,
})
assert_true(handlers.request_capacity_learning_startup_if_needed(ctx_master_idle, 'TEST'),
  'must fire under MASTER too when the master has not requested anything yet')
assert_eq(ctx_master_idle._transitions[1], constants.node_states.STARTUP,
  'must transition the node state machine to STARTUP under MASTER as well')

-- 3) SAFE -- must never auto-start, regardless of learning state or
--    machine_state.
local ctx_safe = make_ctx({
  modules = fresh_off_modules(), capacity_learning = nil,
  current_state = STATE.SAFE, machine_state = constants.node_states.OFF,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_safe, 'TEST'), false,
  'must never fire in SAFE')
assert_eq(#ctx_safe._transitions, 0, 'no node-state transition in SAFE')

-- 4) Capacity learning already ready (e.g. loaded from cache) -- must NOT
--    fire under AUTONOM or MASTER, must never re-trigger a physical
--    startup once learned.
for _, state in ipairs({ STATE.AUTONOM, STATE.MASTER }) do
  local ctx_ready = make_ctx({
    modules = fresh_off_modules(), capacity_learning = { ready = true, max_output = 12345 },
    current_state = state, machine_state = constants.node_states.OFF,
  })
  assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_ready, 'TEST'), false,
    'must not fire once capacity learning is ready (state=' .. tostring(state) .. ')')
  assert_eq(#ctx_ready._transitions, 0, 'no node-state transition once already learned (state=' .. tostring(state) .. ')')
end

-- 5) Never learned, but a startup is already in progress -- must not
--    double-fire (same busy-guard as the master-driven path).
local ctx_busy = make_ctx({
  modules = fresh_off_modules(), capacity_learning = nil,
  current_state = STATE.AUTONOM, active_startup = 'turbine:A',
  machine_state = constants.node_states.OFF,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_busy, 'TEST'), false,
  'must not fire while a startup is already active')

-- 6) Never learned, every module already RUNNING (not "OFF" module-state),
--    but the NODE-state machine itself is OFF -- must still fire. This is
--    the exact scenario has_off_modules() used to permanently block after
--    the very first successful boot (module.state never reverts to "OFF",
--    see module_lifecycle.lua), which was the original 2026-09-17 bug
--    ("die nod ist in kapazitaet lerne aber raktor ist aus"). No
--    has_off_modules()-style gate exists anymore.
local ctx_running_modules = make_ctx({
  modules = { ['turbine:A'] = { type = 'turbine', state = 'RUNNING' },
              ['reactor:A'] = { type = 'reactor', state = 'RUNNING' } },
  capacity_learning = nil, current_state = STATE.MASTER,
  machine_state = constants.node_states.OFF,
})
assert_true(handlers.request_capacity_learning_startup_if_needed(ctx_running_modules, 'TEST'),
  'must fire when the node-state machine is OFF even if every module is already RUNNING')
assert_eq(ctx_running_modules._transitions[1], constants.node_states.STARTUP,
  'must transition to STARTUP to restart the control loop for relearning')

-- 7) machine_state == RUNNING -- must NOT fire. running_on_tick() already
--    calls adjust_reactors()/adjust_turbines()/monitor_master() every tick
--    on its own; forcing a STARTUP transition here caused the RUNNING<->
--    STARTUP oscillation regression (see file header).
local ctx_running_state = make_ctx({
  modules = fresh_off_modules(), capacity_learning = nil,
  current_state = STATE.MASTER, machine_state = constants.node_states.RUNNING,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_running_state, 'TEST'), false,
  'must not fire while the node state machine is RUNNING -- its own on_tick already samples passively')
assert_eq(#ctx_running_state._transitions, 0, 'no node-state transition while RUNNING')

-- 8) machine_state == LIMITED -- must NOT fire, for the same reason as
--    RUNNING: limited_on_tick() already calls adjust_reactors()/
--    adjust_turbines() every tick unconditionally (Fix #9).
local ctx_limited = make_ctx({
  modules = fresh_off_modules(), capacity_learning = nil,
  current_state = STATE.MASTER, machine_state = constants.node_states.LIMITED,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_limited, 'TEST'), false,
  'must not fire while the node state machine is LIMITED -- its own on_tick already samples passively')
assert_eq(#ctx_limited._transitions, 0, 'no node-state transition while LIMITED')

-- 9) machine_state == STARTUP itself (already mid-startup) -- must not fire.
local ctx_mid_startup = make_ctx({
  modules = fresh_off_modules(), capacity_learning = nil,
  current_state = STATE.MASTER, machine_state = constants.node_states.STARTUP,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_mid_startup, 'TEST'), false,
  'must not fire while the node state machine is already in STARTUP')

print('rt_capacity_learning_autonom_startup_test.lua: ok')
