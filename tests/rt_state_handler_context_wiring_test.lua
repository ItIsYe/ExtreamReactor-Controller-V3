package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local state_handlers = require('nodes.rt.state_handlers')

local function assert_true(value, message)
  if not value then
    error(message or 'assert_true failed')
  end
end

local function make_ctx()
  local calls = { turbines = 0, reactors = 0 }
  local queue = {}
  local machine = {
    state = function()
      return constants.node_states.RUNNING
    end,
    transition = function() end
  }
  local ctx = {
    constants = constants,
    STATE = { MASTER = 'MASTER', AUTONOM = 'AUTONOM' },
    config = { startup_watchdog_s = 60 },
    devices = { turbines = {}, reactors = {} },
    modules = {},
    comms = { network = { id = 'RT-TEST' } },
    targets = {},
    reset_startup_watchdog = function() end,
    scram = function() end,
    monitor_master = function() end,
    get_target_rpm = function() return 900 end,
    start_module = function() end,
    adjust_turbines = function() calls.turbines = calls.turbines + 1 end,
    adjust_reactors = function() calls.reactors = calls.reactors + 1 end,
    clamp_autonom_targets = function() end,
    add_alarm = function() end,
    handle_startup_timeout = function() end,
    get_startup_started_ms = function() return nil end,
    set_startup_started_ms = function() end,
    get_startup_watchdog_tripped = function() return false end,
    set_startup_watchdog_tripped = function() end,
    get_startup_queue = function() return queue end,
    set_startup_queue = function(value) queue = value end,
    get_active_startup = function() return nil end,
    set_active_startup = function() end,
    get_current_state = function() return 'MASTER' end,
    get_node_state_machine = function() return machine end
  }
  return ctx, calls
end

do
  local ctx, calls = make_ctx()
  local handlers = state_handlers.build(ctx)
  handlers[constants.node_states.RUNNING].on_tick()
  assert_true(calls.turbines == 1, 'adjust_turbines should be called on RUNNING tick')
  assert_true(calls.reactors == 1, 'adjust_reactors should be called on RUNNING tick')
end

do
  local ctx = make_ctx()
  ctx.adjust_reactors = nil
  local ok, err = pcall(function()
    state_handlers.build(ctx)
  end)
  assert_true(not ok, 'build must fail when adjust_reactors is missing')
  assert_true(type(err) == 'string' and err:find('adjust_reactors', 1, true), 'error should mention adjust_reactors')
end

do
  local ctx = make_ctx()
  ctx.adjust_turbines = nil
  local ok, err = pcall(function()
    state_handlers.build(ctx)
  end)
  assert_true(not ok, 'build must fail when adjust_turbines is missing')
  assert_true(type(err) == 'string' and err:find('adjust_turbines', 1, true), 'error should mention adjust_turbines')
end

print('rt_state_handler_context_wiring_test.lua: ok')
