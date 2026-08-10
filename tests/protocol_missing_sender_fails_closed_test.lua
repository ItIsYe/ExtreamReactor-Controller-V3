package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local protocol = require('core.protocol')
local constants = require('shared.constants')
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local raw = {
  type = constants.message_types.STATUS,
  role = constants.roles.RT_NODE,
  ts = os.epoch('utc'),
  proto_ver = constants.proto_ver,
  payload = {},
}
local sanitized = protocol.sanitize_message(raw)
assert_true(sanitized.sender_id == nil and sanitized.src == nil,
  'sanitize_message must not synthesize missing remote sender from local computer identity')
local ok, err = protocol.validate(sanitized)
assert_true(ok == false, 'missing sender must fail protocol validation')
assert_true(tostring(err):find('sender', 1, true) ~= nil,
  'missing-sender rejection should identify sender field')

local blank = protocol.sanitize_message({
  type = constants.message_types.STATUS,
  sender_id = '   ', src = '   ', role = constants.roles.RT_NODE,
  ts = os.epoch('utc'), proto_ver = constants.proto_ver, payload = {},
})
ok = protocol.validate(blank)
assert_true(ok == false, 'blank sender must fail protocol validation')

print('protocol_missing_sender_fails_closed_test.lua: ok')
