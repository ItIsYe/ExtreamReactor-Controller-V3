package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local plan = rt_sync.build_node_setpoint_plan({
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = {
    ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 3200 },
    ['RT-2'] = { id = 'RT-2', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 1500 },
    ['RT-3'] = { id = 'RT-3', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.OFF, output = 0 },
  },
  power_target = 2500,
  rt_global_off = false
})

local by_id = {}
for _, entry in ipairs(plan.nodes) do by_id[entry.id] = entry.setpoints end

if by_id['RT-1'].assignment_state ~= 'active' then error('RT-1 should remain active for low demand') end
if by_id['RT-2'].assignment_state ~= 'shed' then error('RT-2 should be first shed candidate') end
if by_id['RT-2'].power_target ~= 0 then error('shed node must receive zero power target') end
if by_id['RT-3'].assignment_state ~= 'standby' then error('startup pending node should wait in standby when demand covered') end

print('rt_sync_shutdown_startup_state_test.lua: ok')
