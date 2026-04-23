package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

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

local transitions = {}
local machine_state = constants.node_states.RUNNING
local current_state = 'MASTER'
local targets = { enable_turbines = true, enable_reactors = false }
local modules = {
  ['turbine:A'] = { type = 'turbine', state = 'OFF' },
  ['reactor:A'] = { type = 'reactor', state = 'OFF' }
}
local safe_controls = 0

local ctx = {
  constants = constants,
  STATE = { INIT = 'INIT', MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' },
  TARGET_RPM = 900,
  config = { autonom = { flow_step = 25 } },
  modules = modules,
  targets = targets,
  allowed_transitions = {
    MASTER = { AUTONOM = true, SAFE = true },
    AUTONOM = { MASTER = true, SAFE = true },
    SAFE = {}
  },
  log = function() end,
  set_reactors_active = function() end,
  set_turbines_active = function() end,
  apply_safe_controls = function() safe_controls = safe_controls + 1 end,
  is_master_connected = function() return false end,
  ramp_towards = function(current, target)
    return target
  end,
  get_active_startup = function() return nil end,
  get_current_state = function() return current_state end,
  set_current_state = function(value) current_state = value end,
  get_node_state_machine = function()
    return {
      state = function() return machine_state end,
      transition = function(_, next_state)
        table.insert(transitions, next_state)
        machine_state = next_state
      end
    }
  end
}

local requested = handlers.request_startup_if_needed(ctx, 'TEST')
assert_true(requested, 'startup should be requested when turbine module is OFF in MASTER')
assert_eq(transitions[1], constants.node_states.STARTUP, 'startup transition expected')

handlers.apply_mode(ctx, ctx.STATE.SAFE)
assert_eq(current_state, ctx.STATE.SAFE, 'apply_mode SAFE should set SAFE mode')
assert_true(safe_controls == 1, 'safe controls must be applied once')

current_state = ctx.STATE.MASTER
machine_state = constants.node_states.RUNNING
handlers.monitor_master(ctx)
assert_eq(current_state, ctx.STATE.AUTONOM, 'master timeout should switch to AUTONOM')
assert_eq(transitions[#transitions], constants.node_states.AUTONOM, 'monitor must transition node state machine to AUTONOM')

targets.power, targets.steam, targets.rpm = 100, 200, 400
handlers.clamp_autonom_targets(ctx)
assert_eq(targets.power, 0, 'autonom clamp should zero power target')
assert_eq(targets.steam, 0, 'autonom clamp should zero steam target')
assert_eq(targets.rpm, 900, 'autonom clamp should ramp rpm toward default target')

print('rt_state_mode_helpers_test.lua: ok')
