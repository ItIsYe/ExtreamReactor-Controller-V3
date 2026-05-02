package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local handler = require('nodes.rt.command_handler')
local constants = require('shared.constants')

local function new_handler(current_state, machine_state)
  local transitioned_to
  local command_handler = handler.new({
    protocol = { is_for_node = function() return true end, is_proto_compatible = function() return true end },
    STATE = { MASTER = 'MASTER', SAFE = 'SAFE' },
    targets = {},
    get_current_state = function() return current_state end,
    get_states = function() return constants.node_states end,
    node_state_machine = {
      state = function() return machine_state end,
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
  return command_handler, function() return transitioned_to end
end

local ch1, get_transition1 = new_handler('MASTER', constants.node_states.RUNNING)
local requested = ch1({ proto_ver = constants.proto_ver, payload = { command = { target = constants.command_targets.SET_SETPOINTS, value = { desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' } } } })
if not requested or requested.ok ~= true or requested.transition ~= 'REQUESTED' then
  error('shutdown request must return REQUESTED when transition is initiated')
end
if get_transition1() ~= constants.node_states.OFF then
  error('shutdown request must call transition towards OFF state')
end

local ch2 = new_handler('SAFE', constants.node_states.RUNNING)
local safe = ch2({ proto_ver = constants.proto_ver, payload = { command = { target = constants.command_targets.SET_SETPOINTS, value = { desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' } } } })
if not safe or safe.ok ~= false or safe.reason_code ~= 'SAFE_MODE' then
  error('SAFE mode must reject shutdown requests with SAFE_MODE reason')
end

local ch3 = new_handler('MASTER', constants.node_states.RUNNING)
local bad_state = ch3({ proto_ver = constants.proto_ver, payload = { command = { target = constants.command_targets.SET_SETPOINTS, value = { desired_node_state = 'INVALID', shutdown_stage = 'REQUEST_OFF' } } } })
if not bad_state or bad_state.ok ~= false or bad_state.reason_code ~= 'INVALID_STATE' then
  error('invalid desired state must be rejected with INVALID_STATE reason')
end

print('rt_command_shutdown_ack_semantics_test.lua: ok')
