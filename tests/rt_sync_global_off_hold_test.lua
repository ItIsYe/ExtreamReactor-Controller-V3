package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local sent = {}
local comms = {
  send_command = function(_, node_id, command)
    sent[#sent + 1] = { node_id = node_id, command = command }
  end
}

local node = { id = 'node-rt', role = constants.roles.RT_NODE, mode = 'MASTER' }
rt_sync.sync_rt_node({
  config = { rt_setpoints = { target_rpm = 900, enable_reactors = true, enable_turbines = true } },
  comms = comms,
  power_target = 5500,
  rt_global_off = true
}, node)

if #sent ~= 1 then
  error('expected one setpoint command when syncing rt node')
end

local value = sent[1].command.value or {}
if value.power_target ~= 0 then
  error('expected global off hold to force power_target=0')
end
if value.enable_reactors ~= false or value.enable_turbines ~= false then
  error('expected global off hold to disable rt production controls')
end

print('rt_sync_global_off_hold_test.lua: ok')
