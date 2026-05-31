package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local health = require('core.health')
local controller_lib = require('master.ui_controller')

local captured_rt
local nodes = {
  ['RT-1'] = {
    id = 'RT-1', role = constants.roles.RT_NODE, status = constants.status_levels.OK, state = constants.node_states.OFF, mode = 'MASTER', output = 0,
    shutdown_workflow = {
      stage = 'COMPLETED', final_reason = 'SUCCESS_COMPLETED', outcome = 'SUCCESS', error = nil,
      request_command_at = 101, request_ack_at = 102, state_reached_at = 103, completed_at = 104
    }
  },
  ['RT-2'] = {
    id = 'RT-2', role = constants.roles.RT_NODE, status = constants.status_levels.WARNING, state = constants.node_states.RUNNING, mode = 'MASTER', output = 0,
    shutdown_workflow = {
      stage = 'CANCELLED_DEMAND_RECOVERED', final_reason = 'CANCELLED_DEMAND_RECOVERED', outcome = 'CANCELLED', error = nil,
      request_command_at = 201, request_ack_at = 202, state_reached_at = nil, completed_at = 205
    }
  },
  ['RT-3'] = {
    id = 'RT-3', role = constants.roles.RT_NODE, status = constants.status_levels.WARNING, state = constants.node_states.RUNNING, mode = 'MASTER', output = 0,
    shutdown_workflow = {
      stage = 'FAILED', final_reason = 'FAILED_ACK_MISSING', outcome = 'FAILED', error = 'ACK_MISSING',
      request_command_at = 301, request_ack_at = nil, state_reached_at = nil, completed_at = 305
    }
  }
}

local controller = controller_lib.new({
  constants = constants, health = health, config = { energy_warn_pct = 25, energy_crit_pct = 15 },
  nodes = nodes, alarms = {}, comms = { get_diagnostics = function() return {} end },
  sequencer = { ramp_profile = 'NORMAL', state = 'IDLE', queue = {} },
  trends = { is_dirty = function() return false end, clear_dirty = function() end },
  trend_cache = { energy = {}, energy_arrow = '→' },
  state = { monitor_cache = { list = {} }, last_draw = -1000, power_target = 0, active_profile = 'BASELOAD', auto_profile = false, rt_global_off_hold = false, critical_blink_until = 0 },
  view_manager = { render = function(_, _, model) captured_rt = model.rt return {} end },
  calc = { get_auto_profile = function() return false end, get_active_profile = function() return 'BASELOAD' end, get_power_target = function() return 0 end, get_rt_global_off_hold = function() return false end }
})

controller.draw()
if not captured_rt or type(captured_rt.rt_nodes) ~= 'table' then error('expected UI controller draw to project RT model') end

local by_id = {}
for _, rt in ipairs(captured_rt.rt_nodes) do by_id[rt.id] = rt end

local success = assert(by_id['RT-1'], 'missing RT-1 projection')
if success.shutdown_workflow_stage ~= 'COMPLETED' or success.shutdown_workflow_reason ~= 'SUCCESS_COMPLETED' or success.shutdown_workflow_outcome ~= 'SUCCESS' then
  error('SUCCESS projection must preserve terminal workflow semantics')
end
if success.shutdown_state_reached_at ~= 103 then error('SUCCESS must keep shutdown_state_reached_at timestamp') end
if success.shutdown_completed_at ~= 104 then error('SUCCESS must keep shutdown_completed_at timestamp') end

local cancelled = assert(by_id['RT-2'], 'missing RT-2 projection')
if cancelled.shutdown_workflow_stage ~= 'CANCELLED_DEMAND_RECOVERED' or cancelled.shutdown_workflow_reason ~= 'CANCELLED_DEMAND_RECOVERED' or cancelled.shutdown_workflow_outcome ~= 'CANCELLED' then
  error('CANCELLED projection must preserve terminal workflow semantics')
end
if cancelled.shutdown_state_reached_at ~= nil then error('CANCELLED must not expose shutdown_state_reached_at as success timestamp') end
if cancelled.shutdown_completed_at ~= 205 then error('CANCELLED must keep shutdown_completed_at timestamp') end

local failed = assert(by_id['RT-3'], 'missing RT-3 projection')
if failed.shutdown_workflow_stage ~= 'FAILED' or failed.shutdown_workflow_reason ~= 'FAILED_ACK_MISSING' or failed.shutdown_workflow_outcome ~= 'FAILED' then
  error('FAILED projection must preserve terminal workflow semantics')
end
if failed.shutdown_workflow_error ~= 'ACK_MISSING' then error('FAILED error must be projected unchanged') end
if failed.shutdown_state_reached_at ~= nil then error('FAILED must not set shutdown_state_reached_at') end
if failed.shutdown_completed_at ~= 305 then error('FAILED must keep shutdown_completed_at timestamp') end

print('master_ui_shutdown_field_semantic_contract_test.lua: ok')
