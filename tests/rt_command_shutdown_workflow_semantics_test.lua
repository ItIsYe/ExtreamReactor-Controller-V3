package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local handler = require('nodes.rt.command_handler')
local constants = require('shared.constants')

local function new_handler(opts)
  opts = opts or {}
  local transitioned_to
  local current_state = opts.current_state or constants.node_states.RUNNING
  local runtime_mode = opts.runtime_mode or 'MASTER'
  local command_handler = handler.new({
    protocol = { is_for_node = function() return true end, is_proto_compatible = function() return true end },
    STATE = { MASTER = 'MASTER', SAFE = 'SAFE' },
    targets = {},
    get_current_state = function() return runtime_mode end,
    get_states = function() return constants.node_states end,
    node_state_machine = {
      state = function() return current_state end,
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

local function shutdown_request(value)
  return {
    proto_ver = constants.proto_ver,
    payload = { command = { target = constants.command_targets.SET_SETPOINTS, value = value } }
  }
end

local ch_requested, transition_requested = new_handler({ current_state = constants.node_states.RUNNING })
local requested = ch_requested(shutdown_request({ desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }))
if not requested or requested.ok ~= true or requested.transition ~= 'REQUESTED' then
  error('expected REQUESTED transition for RUNNING -> OFF shutdown request')
end
if requested.transition == 'COMPLETED' then
  error('REQUESTED must not be treated as COMPLETED')
end
if transition_requested() ~= constants.node_states.OFF then
  error('REQUESTED path must initiate transition to OFF')
end

local ch_already, transition_already = new_handler({ current_state = constants.node_states.OFF })
local already = ch_already(shutdown_request({ desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }))
if not already or already.ok ~= true or already.transition ~= 'ALREADY_IN_STATE' then
  error('expected ALREADY_IN_STATE when RT already reached OFF state')
end
if transition_already() ~= nil then
  error('ALREADY_IN_STATE must not re-trigger node_state_machine transition')
end

local ch_invalid = new_handler({ current_state = constants.node_states.RUNNING })
local invalid = ch_invalid(shutdown_request({ desired_node_state = 'INVALID', shutdown_stage = 'REQUEST_OFF' }))
if not invalid or invalid.ok ~= false or invalid.reason_code ~= 'INVALID_STATE' then
  error('invalid desired state must fail with INVALID_STATE')
end

local ch_safe = new_handler({ runtime_mode = 'SAFE', current_state = constants.node_states.RUNNING })
local safe = ch_safe(shutdown_request({ desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }))
if not safe or safe.ok ~= false or safe.reason_code ~= 'SAFE_MODE' then
  error('SAFE runtime mode must reject shutdown requests')
end

local ch_not_master = new_handler({ runtime_mode = 'AUTONOM', current_state = constants.node_states.RUNNING })
local not_master = ch_not_master(shutdown_request({ desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }))
if not not_master or not_master.ok ~= false or not_master.reason_code ~= 'INVALID_STATE' then
  error('non-MASTER runtime mode must reject shutdown requests with INVALID_STATE')
end

print('rt_command_shutdown_workflow_semantics_test.lua: ok')
