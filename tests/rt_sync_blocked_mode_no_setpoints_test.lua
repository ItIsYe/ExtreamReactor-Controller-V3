package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test: rt_sync.lua's M.sync_rt_node() handled mode_action ==
-- "send"/"wait" with an explicit `return`, but the "blocked" branch
-- (a node that is OFFLINE, or in node.state SAFE/EMERGENCY, needs a mode
-- correction it currently cannot receive) fell straight through into the
-- setpoint-plan/send logic below instead of stopping there -- a node the
-- system itself flagged as unsafe to mode-switch still got setpoints sent.

if not os.epoch then
  os.epoch = function() return 200000 end
end

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end

local sends = 0
local comms = { send_command = function() sends = sends + 1 end }

-- A node that reports mode=AUTONOM (MASTER wants MASTER) while its node
-- state machine is in EMERGENCY -- mode_sync_action() must return
-- "blocked" here (SAFE_OR_EMERGENCY), and sync_rt_node() must stop right
-- there: no setpoints should be sent to a node the mode-sync logic itself
-- just decided is unsafe to touch.
local node = {
  id = 'RT-EMERGENCY',
  role = constants.roles.RT_NODE,
  mode = 'AUTONOM',
  status = constants.status_levels.WARNING,
  state = constants.node_states.EMERGENCY,
}

rt_sync.sync_rt_node({
  comms = comms,
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = { ['RT-EMERGENCY'] = node },
  power_target = 1200,
  rt_global_off = false,
  trigger = 'test',
  log = function() end
}, node)

assert_eq(sends, 0, 'a node blocked from a mode correction (SAFE/EMERGENCY) must not fall through to receive setpoints')

print('rt_sync_blocked_mode_no_setpoints_test.lua: ok')
