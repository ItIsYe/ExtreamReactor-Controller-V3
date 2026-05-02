package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local function build(nodes, target)
  return rt_sync.build_node_setpoint_plan({
    config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true } },
    nodes = nodes,
    power_target = target,
    rt_global_off = false
  })
end

local nodes = {
  ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 2800 },
  ['RT-2'] = { id = 'RT-2', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.OFF, output = 0 },
  ['RT-3'] = { id = 'RT-3', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 2600 },
}

local high = build(nodes, 7000)
if high.startup_candidate_id ~= 'RT-2' then error('expected RT-2 selected for next serial startup under high demand') end

local low = build(nodes, 2200)
if low.shutdown_candidate_id ~= 'RT-3' then error('expected RT-3 selected for serial shed under low demand') end

local setpoints = {}
for _, entry in ipairs(low.nodes) do setpoints[entry.id] = entry.setpoints end
if setpoints['RT-1'].power_target <= 0 then error('expected one node to carry load after consolidation') end
if setpoints['RT-3'].power_target ~= 0 then error('shed candidate should receive 0 power target') end
if setpoints['RT-3'].assignment_reason ~= 'SHED_EXCESS_CAPACITY' then error('shed reason missing') end

print('rt_sync_demand_sequencing_test.lua: ok')
