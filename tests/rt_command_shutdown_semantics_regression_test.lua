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
    state = function() return constants.node_states.OFF end,
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

local already = command_handler({
  proto_ver = constants.proto_ver,
  payload = { command = { target = constants.command_targets.SET_SETPOINTS, value = { desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' } } }
})
if not already or already.ok ~= true or already.transition ~= 'ALREADY_IN_STATE' then
  error('expected ALREADY_IN_STATE for already reached shutdown target')
end
if transitioned_to ~= nil then
  error('must not transition when already in desired shutdown target')
end

local invalid = command_handler({
  proto_ver = constants.proto_ver,
  payload = { command = { target = constants.command_targets.SET_SETPOINTS, value = { desired_node_state = 'NOT_A_STATE', shutdown_stage = 'REQUEST_OFF' } } }
})
if not invalid or invalid.ok ~= false or invalid.reason_code ~= 'INVALID_STATE' then
  error('expected INVALID_STATE for unknown desired_node_state')
end

print('rt_command_shutdown_semantics_regression_test.lua: ok')
