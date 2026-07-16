package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local state_handlers = require('nodes.rt.state_handlers')
local control_service = require('services.control_service')

local function assert_true(value, message)
  if not value then
    error(message or 'assert_true failed')
  end
end

local ticks = 0
local queue = {}
local machine = {
  state = function()
    return constants.node_states.RUNNING
  end,
  transition = function() end
}

local handlers = state_handlers.build({
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
  adjust_turbines = function() ticks = ticks + 1 end,
  adjust_reactors = function() ticks = ticks + 1 end,
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
  get_node_state_machine = function() return machine end,
  is_master_connected = function() return true end
})

local control = control_service.new({
  tick = function()
    handlers[constants.node_states.RUNNING].on_tick()
  end
})

for _ = 1, 3 do
  local ok, err = pcall(function()
    control:tick()
  end)
  assert_true(ok, 'control tick should not crash: ' .. tostring(err))
end

assert_true(ticks == 6, 'expected two adjust calls per tick for three ticks')

print('rt_control_service_tick_stability_test.lua: ok')
