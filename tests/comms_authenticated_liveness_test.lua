package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local protocol = require('core.protocol')
local comms = require('core.comms')

local now = 1000000
os.epoch = function() return now end
local secret = 'liveness-test-secret-1234'
local network = {
  id = 'RT-1', role = constants.roles.RT_NODE,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
  send = function() return true end,
}

comms.init({
  network = network, node_id = network.id, role = network.role,
  config = { auth_secret = secret, command_max_age_s = 30 },
  logger = function() end,
})

local function heartbeat(id)
  return {
    type = constants.message_types.HEARTBEAT,
    message_id = 'hb-' .. id,
    src = id, sender_id = id, node_id = id,
    role = constants.roles.MASTER,
    ts = now, timestamp = now, proto_ver = constants.proto_ver,
    payload = { state = 'RUNNING' },
  }
end

local unsigned = heartbeat('FAKE-MASTER')
comms.receive(unsigned)
comms.tick()
assert(comms.get_peer_state()['FAKE-MASTER'] == nil,
  'unsigned MASTER heartbeat must not create a trusted peer')

local signed = heartbeat('MASTER-1')
assert(protocol.sign_message(signed, secret))
comms.receive(signed)
comms.tick()
local peer = comms.get_peer_state()['MASTER-1']
assert(peer and peer.role == constants.roles.MASTER and peer.down == false,
  'fresh authenticated MASTER heartbeat must update peer liveness')

now = now + 31000
local stale = heartbeat('MASTER-STALE')
stale.ts, stale.timestamp = now - 31000, now - 31000
assert(protocol.sign_message(stale, secret))
comms.receive(stale)
comms.tick()
assert(comms.get_peer_state()['MASTER-STALE'] == nil,
  'authenticated but stale heartbeat must not update liveness')

local pocket_handled = 0
comms.on(constants.message_types.POCKET_QUERY, function(message)
  assert(message.auth_verified == true, 'Pocket handler may only receive authenticated traffic')
  pocket_handled = pocket_handled + 1
end)
local function pocket_query()
  return {
    type = constants.message_types.POCKET_QUERY,
    message_id = 'pocket-query-1', src = 'POCKET-1', sender_id = 'POCKET-1', node_id = 'POCKET-1',
    role = 'POCKET', ts = now, timestamp = now, proto_ver = constants.proto_ver, payload = {},
  }
end
comms.receive(pocket_query())
comms.tick()
assert(pocket_handled == 0, 'unsigned Pocket query must be rejected')
local authenticated_query = pocket_query()
assert(protocol.sign_message(authenticated_query, secret))
comms.receive(authenticated_query)
comms.tick()
assert(pocket_handled == 1, 'signed Pocket query must reach its handler')

print('comms_authenticated_liveness_test.lua: ok')
