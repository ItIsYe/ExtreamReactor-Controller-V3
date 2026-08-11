package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local protocol = require('core.protocol')
local secret = 'log-transport-test-secret-123456'

local event = {
  type = 'LOG_EVENT', proto = 'xreactor-log-v2', event_id = 'node-1:boot:1',
  node_id = 'node-1', role = 'RT', prefix = 'RT', level = 'INFO',
  message = 'reactor online', seq = 1, boot_id = 'node-1:boot', ack = true,
  ts = os.epoch('utc'),
}
local mac = assert(protocol.sign_value(protocol.log_auth_value(event), secret))
event.auth = { algorithm = 'HMAC-SHA256', mac = mac }
assert(protocol.verify_value(protocol.log_auth_value(event), secret, event.auth.mac),
  'signed log event must verify')
event.message = 'tampered'
assert(not protocol.verify_value(protocol.log_auth_value(event), secret, event.auth.mac),
  'tampered log event must fail authentication')

local ack = {
  type = 'LOG_ACK', proto = 'xreactor-log-v2', event_id = 'node-1:boot:1',
  to_node = 'node-1', collector_node = 'LOG-1', status = 'written', ts = os.epoch('utc'),
}
ack.auth = { algorithm = 'HMAC-SHA256', mac = assert(protocol.sign_value(protocol.log_auth_value(ack), secret)) }
assert(protocol.verify_value(protocol.log_auth_value(ack), secret, ack.auth.mac),
  'signed collector ACK must verify')

local collector = assert(io.open('xreactor/nodes/log_collector/main.lua', 'r'))
local collector_source = collector:read('*a'); collector:close()
assert(collector_source:find('protocol.verify_value(protocol.log_auth_value(message)', 1, true),
  'collector must authenticate log events before writing')
assert(collector_source:find('MAX_TRACKED_NODES', 1, true),
  'collector node tracking must be bounded')

print('log_transport_auth_test.lua: ok')
