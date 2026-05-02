package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local handler = require('nodes.rt.command_handler')
local constants = require('shared.constants')

local transitioned_to
local command_handler = handler.new({
  protocol = {
    is_for_node = function() return true end,
    is_proto_compatible = function() return true end
  },
  STATE = { MASTER = 'MASTER', SAFE = 'SAFE' },
  targets = {},
  get_current_state = function() return 'MASTER' end,
  get_states = function() return constants.node_states end,
  node_state_machine = {
    state = function() return constants.node_states.RUNNING end,
    transition = function(_, next_state) transitioned_to = next_state end
  },
  request_startup_if_needed = function() end,
  apply_mode = function() end,
  start_module = function() return nil end,
  add_alarm = function() end,
  get_network_id = function() return 'RT-1' end,
  note_master_seen = function() end,
  set_last_command = function() end,
  set_last_command_ts = function() end
})

local result = command_handler({
  proto_ver = constants.proto_ver,
  payload = {
    command = {
      target = constants.command_targets.SET_SETPOINTS,
      value = { desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }
    }
  }
})

if transitioned_to ~= constants.node_states.OFF then
  error('expected transition to OFF for shutdown workflow')
end
if not result or result.ok ~= true or result.transition ~= 'REQUESTED' then
  error('expected explicit transition ack for shutdown workflow')
end

print('rt_command_shutdown_transition_test.lua: ok')
