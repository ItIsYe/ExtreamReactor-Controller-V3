package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local plan = rt_sync.build_node_setpoint_plan({
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true } },
  nodes = {
    ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 2000 },
    ['RT-2'] = { id = 'RT-2', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 1000 },
    ['RT-3'] = { id = 'RT-3', role = constants.roles.RT_NODE, mode = 'SAFE', status = constants.status_levels.WARNING, state = constants.node_states.SAFE, output = 0 },
  },
  power_target = 6000,
  rt_global_off = false
})

if plan.controllable_count ~= 2 then error('expected two controllable nodes') end

local assigned = {}
for _, entry in ipairs(plan.nodes) do
  assigned[entry.id] = entry.setpoints
end

if not assigned['RT-1'] or not assigned['RT-2'] or not assigned['RT-3'] then
  error('expected plan entries for all RT nodes')
end
if assigned['RT-1'].power_target ~= 3000 or assigned['RT-2'].power_target ~= 3000 then
  error('expected equal per-node power distribution for controllable nodes')
end
if assigned['RT-3'].power_target ~= 0 or assigned['RT-3'].enable_reactors ~= false then
  error('safe-mode node must not receive active setpoints')
end
if assigned['RT-1'].assignment_reason == assigned['RT-3'].assignment_reason then
  error('assignment reasons must differ between controllable and blocked nodes')
end

print('rt_sync_per_node_distribution_test.lua: ok')
