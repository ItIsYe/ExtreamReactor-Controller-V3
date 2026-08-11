package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local protocol = require('core.protocol')
local handler = require('optional.pocket_query_handler')

local f = assert(io.open('xreactor/optional/pocket_client.lua', 'r'))
local client = f:read('*a'); f:close()
assert(client:find('protocol.status(MY_ID, POCKET_ROLE', 1, true), 'pocket client must send a role')
assert(client:find('protocol.sign_message(message, AUTH_SECRET)', 1, true), 'pocket client must authenticate outgoing packets')
assert(client:find('protocol.verify_message_auth(message, AUTH_SECRET)', 1, true), 'pocket client must authenticate responses')

local comms_file = assert(io.open('xreactor/core/comms.lua', 'r'))
local comms_source = comms_file:read('*a'); comms_file:close()
for _, message_type in ipairs({ 'POCKET_QUERY', 'POCKET_STATUS', 'POCKET_COMMAND', 'POCKET_COMMAND_RESULT' }) do
  assert(comms_source:find('constants.message_types.' .. message_type, 1, true),
    message_type .. ' must use the protected comms transport')
end

local valid = {
  type = constants.message_types.POCKET_QUERY,
  sender_id = 'POCKET-1', src = 'POCKET-1', role = 'POCKET',
  ts = 1000, timestamp = 1000, proto_ver = constants.proto_ver, payload = {},
}
local ok, err = protocol.validate(valid)
assert(ok, 'pocket query protocol envelope must validate: ' .. tostring(err))

local sent
local handled = handler.handle({
  type = constants.message_types.POCKET_COMMAND,
  sender_id = 'POCKET-1', src = 'POCKET-1',
  payload = { token = '123456', action = 'profile_set', params = {} },
}, {
  constants = constants,
  current_token = '123456',
  execute_command = function() return false, 'Ungueltiges Profil' end,
  comms = { send = function(_, _, payload) sent = payload; return true end },
  log = function() end,
})
assert(handled == true, 'pocket command must be handled')
assert(sent and sent.ok == false and sent.reason == 'Ungueltiges Profil',
  'execute_command false result must be returned as a rejection')

print('pocket_protocol_regression_test.lua: ok')
