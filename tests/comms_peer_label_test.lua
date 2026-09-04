-- tests/comms_peer_label_test.lua
--
-- Regression test: VALVE nodes now carry a clear display name (installer/
-- valve_naming.lua), broadcast over the network so FUEL's routing UI can
-- show it instead of the raw node_id. This asserts the wire path actually
-- carries it end to end: comms_service passes opts.label into core.comms'
-- state, build_message() puts it on the outgoing envelope, protocol.
-- sanitize_message() does not strip it as an unknown field on the
-- receiving end, and get_peer_state() surfaces it per peer. Also checks
-- that a sender without a label (every other role, unaffected by this
-- feature) produces no label at all -- this is a generic, opt-in field,
-- not something every role must now send.

os.epoch = os.epoch or function() return 0 end

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local comms = require('core.comms')

-- Sending side: comms.init({label=...}) must make build_message() put the
-- label on every outgoing envelope, surviving protocol.sanitize_message()
-- (an explicit-whitelist function -- an unlisted field would silently
-- vanish here).
do
  local captured
  local network = {
    id = 'VALVE-1', role = constants.roles.VALVE_NODE,
    channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
    send = function(_, _, payload) captured = payload; return true end,
  }
  comms.init({ network = network, node_id = network.id, role = network.role, label = 'VALVE-42' })
  comms.send(nil, constants.message_types.HEARTBEAT, { state = constants.node_states.RUNNING },
    { channel = constants.channels.STATUS })
  comms.tick()
  if not captured then error('expected the queued message to be flushed to network.send()') end
  if captured.label ~= 'VALVE-42' then
    error("expected the outgoing envelope's label to be VALVE-42, got: " .. tostring(captured.label))
  end
end

-- Drives the full receive path with a FUEL-side comms instance and a raw
-- incoming message shaped exactly like build_message() would produce for
-- a labeled VALVE sender.
do
  local network = {
    id = 'FUEL-1', role = constants.roles.FUEL_NODE,
    channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
    send = function() return true end,
  }
  comms.init({ network = network, node_id = network.id, role = network.role })

  comms.receive({
    type = constants.message_types.HEARTBEAT,
    message_id = 'msg-1',
    src = 'VALVE-1',
    sender_id = 'VALVE-1',
    role = constants.roles.VALVE_NODE,
    label = 'VALVE-42',
    proto_ver = constants.proto_ver,
    ts = os.epoch('utc'),
    payload = { state = constants.node_states.RUNNING },
  })
  comms.tick()

  local peers = comms.get_peer_state()
  local peer = peers['VALVE-1']
  if not peer then error('expected VALVE-1 to be a known peer after a heartbeat') end
  if peer.label ~= 'VALVE-42' then
    error("expected peer.label to survive sanitize_message()/update_peer(), got: " .. tostring(peer.label))
  end

  -- (b) A sender WITHOUT a label (every other role today) must not
  -- fabricate one.
  comms.receive({
    type = constants.message_types.HEARTBEAT,
    message_id = 'msg-2',
    src = 'RT-1',
    sender_id = 'RT-1',
    role = constants.roles.RT_NODE,
    proto_ver = constants.proto_ver,
    ts = os.epoch('utc'),
    payload = { state = constants.node_states.RUNNING },
  })
  comms.tick()
  local rt_peer = comms.get_peer_state()['RT-1']
  if not rt_peer then error('expected RT-1 to be a known peer after a heartbeat') end
  if rt_peer.label ~= nil then
    error("expected an unlabeled sender's peer.label to stay nil, got: " .. tostring(rt_peer.label))
  end
end

print("comms_peer_label_test.lua: ok")
