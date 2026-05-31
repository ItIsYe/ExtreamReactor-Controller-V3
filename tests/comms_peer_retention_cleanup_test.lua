local now = 0
_G.os = {
  epoch = function() return now end
}

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local comms = require('core.comms')

local network = {
  id = 'master-1',
  role = constants.roles.MASTER,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
  send = function() return true end
}

comms.init({
  network = network,
  node_id = network.id,
  role = network.role,
  config = {
    peer_timeout_s = 2,
    peer_down_grace_s = 0,
    peer_down_min_observations = 1,
    peer_retention_s = 3
  }
})

comms.receive({
  type = constants.message_types.HEARTBEAT,
  message_id = 'msg-1',
  src = 'ENERGY-1',
  sender_id = 'ENERGY-1',
  role = constants.roles.ENERGY_NODE,
  proto_ver = constants.proto_ver,
  payload = { state = constants.node_states.RUNNING }
})
comms.tick(now)

now = 6000
comms.tick(now)

local peers = comms.get_peer_state()
if peers['ENERGY-1'] then
  error('expected stale down peer to expire after retention window')
end

print('comms_peer_retention_cleanup_test.lua: ok')
