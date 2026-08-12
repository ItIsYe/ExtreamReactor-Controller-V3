package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['services.comms_service'] = nil
package.loaded['shared.constants'] = {
  channels = { CONTROL = 6500, STATUS = 6501 },
  message_types = { HEARTBEAT = 'HEARTBEAT' },
}
package.loaded['shared.build_info'] = {
  get = function() return { manifest_version = 512 } end,
}
package.loaded['core.comms'] = {}
package.loaded['core.network'] = {}
package.loaded['core.utils'] = { normalize_node_id = tostring, log = function() end }

local comms_service = require('services.comms_service')
local sent = nil
local service = comms_service.new({ config = { channels = { status = 6501 } } })
service.comms = {
  send = function(target, message_type, payload, opts)
    sent = { target = target, message_type = message_type, payload = payload, opts = opts }
    return true
  end,
}

local state = { ready = true }
assert(service:send_heartbeat(state) == true)
assert(sent and sent.message_type == 'HEARTBEAT')
assert(sent.payload.state == state, 'heartbeat state must retain its existing shape')
assert(sent.payload.manifest_version == 512,
  'the active central heartbeat path must expose the installed manifest version')
assert(state.manifest_version == nil, 'send_heartbeat must not mutate role-owned state')

print('comms_heartbeat_manifest_version_test.lua: ok')
