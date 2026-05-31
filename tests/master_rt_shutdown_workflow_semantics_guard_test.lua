package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local handler = require('nodes.rt.command_handler')

-- Secondary guard: keep token-level checks against accidental contract deletion/rename.
local handle, err = io.open('xreactor/master/main.lua', 'r')
if not handle then
  error('failed to open xreactor/master/main.lua: ' .. tostring(err))
end
local content = handle:read('*a')
handle:close()

local required_stages = {
  'RAMPDOWN', 'REQUEST_STATE', 'REQUESTED', 'WAITING_STATE',
  'COMPLETED', 'CANCELLED_DEMAND_RECOVERED', 'FAILED'
}
for _, stage in ipairs(required_stages) do
  if not content:find(stage, 1, true) then
    error('missing required shutdown workflow stage token in master/main.lua: ' .. tostring(stage))
  end
end

local required_reasons = {
  'SUCCESS_COMPLETED', 'CANCELLED_DEMAND_RECOVERED',
  'FAILED_TIMEOUT', 'FAILED_REJECTED', 'FAILED_INVALID_STATE', 'FAILED_ACK_MISSING'
}
for _, reason in ipairs(required_reasons) do
  if not content:find(reason, 1, true) then
    error('missing required shutdown workflow final reason token in master/main.lua: ' .. tostring(reason))
  end
end

-- Primary guard: semantic behavior checks.
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

-- REQUESTED is non-terminal and must not be treated as COMPLETED.
local ch_requested, get_transition_requested = new_handler({ current_state = constants.node_states.RUNNING })
local requested = ch_requested(shutdown_request({ desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }))
if not requested or requested.ok ~= true or requested.transition ~= 'REQUESTED' then
  error('expected REQUESTED transition for RUNNING -> OFF shutdown request')
end
if requested.transition == 'COMPLETED' then
  error('REQUESTED must not be treated as COMPLETED')
end
if get_transition_requested() ~= constants.node_states.OFF then
  error('REQUESTED path must initiate transition to OFF')
end

-- COMPLETED must only be represented by ALREADY_IN_STATE (target reached).
local ch_reached, get_transition_reached = new_handler({ current_state = constants.node_states.OFF })
local reached = ch_reached(shutdown_request({ desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }))
if not reached or reached.ok ~= true or reached.transition ~= 'ALREADY_IN_STATE' then
  error('expected ALREADY_IN_STATE when RT already reached OFF state')
end
if get_transition_reached() ~= nil then
  error('ALREADY_IN_STATE must not trigger another state machine transition')
end

-- FAILED_INVALID_STATE semantic path.
local ch_invalid = new_handler({ current_state = constants.node_states.RUNNING })
local invalid = ch_invalid(shutdown_request({ desired_node_state = 'INVALID', shutdown_stage = 'REQUEST_OFF' }))
if not invalid or invalid.ok ~= false or invalid.reason_code ~= 'INVALID_STATE' then
  error('invalid desired state must fail with INVALID_STATE')
end

-- Rejected command path in SAFE mode.
local ch_safe = new_handler({ runtime_mode = 'SAFE', current_state = constants.node_states.RUNNING })
local safe = ch_safe(shutdown_request({ desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' }))
if not safe or safe.ok ~= false or safe.reason_code ~= 'SAFE_MODE' then
  error('SAFE runtime mode must reject shutdown requests with SAFE_MODE')
end

print('master_rt_shutdown_workflow_semantics_guard_test.lua: ok')
