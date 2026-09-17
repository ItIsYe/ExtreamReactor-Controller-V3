package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (user report 2026-09-17: "wenn rt in capacity learn ist
-- aber der master nichts anfordert bleibt der reaktor solange mit den
-- fuelrods auf 100% also 0% leistung bis der master etwas anfordert").
--
-- Root cause: start_module() (which actually calls setActive(true)/engages
-- inductors on the physical reactor/turbine) was ONLY ever reachable via
-- request_startup_if_needed(), which itself required ctx.get_current_
-- state() == ctx.STATE.MASTER. An RT that never saw a MASTER therefore
-- never activated its reactor at all -- rods stayed fully inserted
-- forever, and capacity_learning.lua (which needs turbines actually
-- spinning at target RPM to measure anything) could never collect a
-- single sample.
--
-- state_handlers.request_capacity_learning_startup_if_needed() is the
-- autonomous-only counterpart: it is allowed to fire in AUTONOM (no
-- master), but ONLY while capacity learning is not yet ready -- it must
-- never fire once learning is done, and never fire at all while a MASTER
-- is connected (that path already works via the existing function).

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
  local machine_state = opts.machine_state or constants.node_states.RUNNING
  return {
    constants = constants,
    STATE = STATE,
    modules = opts.modules,
    capacity_learning = opts.capacity_learning,
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

local off_modules = {
  ['turbine:A'] = { type = 'turbine', state = 'OFF' },
  ['reactor:A'] = { type = 'reactor', state = 'OFF' },
}

-- 1) MASTER connected -- must never fire, even with a fresh RT that never
--    learned capacity. The existing master-driven request_startup_if_needed
--    path owns this case.
local ctx_master = make_ctx({
  modules = off_modules, capacity_learning = nil,
  current_state = STATE.MASTER,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_master, 'TEST'), false,
  'must not fire while a MASTER is connected')
assert_eq(#ctx_master._transitions, 0, 'no node-state transition while MASTER is connected')

-- 2) AUTONOM, never learned, modules OFF -- must fire and transition to
--    STARTUP.
local ctx_autonom = make_ctx({
  modules = off_modules, capacity_learning = nil,
  current_state = STATE.AUTONOM,
})
assert_true(handlers.request_capacity_learning_startup_if_needed(ctx_autonom, 'TEST'),
  'must fire in AUTONOM when capacity learning has never run')
assert_eq(ctx_autonom._transitions[1], constants.node_states.STARTUP,
  'must transition the node state machine to STARTUP')

-- 3) AUTONOM, capacity learning already ready (e.g. loaded from cache) --
--    must NOT fire, must never re-trigger a physical startup once learned.
local ctx_ready = make_ctx({
  modules = off_modules, capacity_learning = { ready = true, max_output = 12345 },
  current_state = STATE.AUTONOM,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_ready, 'TEST'), false,
  'must not fire once capacity learning is ready')
assert_eq(#ctx_ready._transitions, 0, 'no node-state transition once already learned')

-- 4) AUTONOM, never learned, but a startup is already in progress -- must
--    not double-fire (same busy-guard as the master-driven path).
local ctx_busy = make_ctx({
  modules = off_modules, capacity_learning = nil,
  current_state = STATE.AUTONOM, active_startup = 'turbine:A',
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_busy, 'TEST'), false,
  'must not fire while a startup is already active')

-- 5) AUTONOM, never learned, but every module already running -- nothing to
--    start.
local ctx_running = make_ctx({
  modules = { ['turbine:A'] = { type = 'turbine', state = 'RUNNING' },
              ['reactor:A'] = { type = 'reactor', state = 'RUNNING' } },
  capacity_learning = nil, current_state = STATE.AUTONOM,
})
assert_eq(handlers.request_capacity_learning_startup_if_needed(ctx_running, 'TEST'), false,
  'must not fire when no module is OFF')

print('rt_capacity_learning_autonom_startup_test.lua: ok')
