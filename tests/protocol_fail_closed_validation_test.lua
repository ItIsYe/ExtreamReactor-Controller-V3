package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local constants = require('shared.constants')
local protocol = require('core.protocol')

local function base(t)
  return {
    type = t, message_id = 'm-1', sender_id = 'RT-1', src = 'RT-1', role = 'RT-NODE',
    ts = os.epoch('utc'), proto_ver = constants.proto_ver, payload = {},
  }
end

local missing_proto = base(constants.message_types.STATUS); missing_proto.proto_ver = nil
local ok, err = protocol.validate(missing_proto)
assert(ok == false and err == 'missing/invalid proto_ver', 'missing proto version must fail closed')

local invalid_proto = base(constants.message_types.STATUS); invalid_proto.proto_ver = 'garbage'
ok, err = protocol.validate(invalid_proto)
assert(ok == false and err == 'missing/invalid proto_ver', 'invalid proto version must fail closed')

local cmd = base(constants.message_types.COMMAND); cmd.message_id = nil
ok, err = protocol.validate(cmd)
assert(ok == false and err == 'missing message_id', 'COMMAND without message_id must be rejected')

local ack = base(constants.message_types.ACK_APPLIED); ack.ack_for = nil
ok, err = protocol.validate(ack)
assert(ok == false and err == 'missing ack_for', 'reliable ACK without ack_for must be rejected')

local built = protocol.command('MASTER-1', 'MASTER', 'RT-1', { target = 'SET_MODE', value = 'AUTO' })
assert(type(built.message_id) == 'string' and built.message_id ~= '', 'protocol constructors must emit message IDs')
ok, err = protocol.validate(built)
assert(ok == true, 'protocol.command envelope should validate: ' .. tostring(err))
print('protocol_fail_closed_validation_test.lua: ok')
