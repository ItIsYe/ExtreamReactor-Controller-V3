local handle = assert(io.open('xreactor/nodes/rt/main.lua', 'r'))
local content = handle:read('*a')
handle:close()

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local constants = require('shared.constants')
local handlers = require('nodes.rt.state_handlers')

if not content:find('ctx%.is_master_connected%s*=%s*is_master_connected') then
  error('build_state_context must include is_master_connected in runtime context')
end
if not content:find('rt state context missing required function: is_master_connected', 1, true) then
  error('missing explicit runtime guard for is_master_connected')
end
if not content:find('State context ready %(is_master_connected=true%)') then
  error('missing context readiness diagnostic log for state context build')
end

local machine_transitions = {}
local semantic_ctx = {
  constants = constants,
  STATE = { INIT = 'INIT', MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' },
  config = { startup_watchdog_s = 60, autonom = { flow_step = 25 } },
  devices = { reactors = {}, turbines = {} },
  modules = {},
  comms = { network = { id = 'RT-TEST' } },
  targets = { power = 0, steam = 0, rpm = 900, enable_reactors = false, enable_turbines = false },
  reset_startup_watchdog = function() end,
  scram = function() end,
  get_target_rpm = function() return 900 end,
  start_module = function() end,
  adjust_turbines = function() end,
  adjust_reactors = function() end,
  clamp_autonom_targets = function() end,
  add_alarm = function() end,
  handle_startup_timeout = function() end,
  get_startup_started_ms = function() return nil end,
  set_startup_started_ms = function() end,
  get_startup_watchdog_tripped = function() return false end,
  set_startup_watchdog_tripped = function() end,
  get_startup_queue = function() return {} end,
  set_startup_queue = function() end,
  get_active_startup = function() return nil end,
  set_active_startup = function() end,
  get_network_id = function() return 'RT-TEST' end,
  get_current_state = function() return 'MASTER' end,
  set_current_state = function() end,
  get_node_state_machine = function()
    return {
      state = function() return constants.node_states.RUNNING end,
      transition = function(_, state) table.insert(machine_transitions, state) end
    }
  end,
  is_master_connected = function() return false end,
  log = function() end
}
semantic_ctx.monitor_master = function()
  return handlers.monitor_master(semantic_ctx)
end

local states = handlers.build(semantic_ctx)
states[constants.node_states.RUNNING].on_tick()
if machine_transitions[#machine_transitions] ~= constants.node_states.AUTONOM then
  error('semantic runtime guard failed: running tick must transition to AUTONOM on master disconnect')
end

print('rt_main_state_context_guard_test.lua: ok')
