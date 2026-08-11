package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local service_lib = require('services.comms_service')
local constants = require('shared.constants')
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_false(v, m) if v then error(m or 'assert_false failed') end end

local svc = service_lib.new({ config = {
  role = constants.roles.RT_NODE,
  trusted_master_id = 'MASTER-1',
  comms = { require_command_auth = true },
} })
svc.network = { role = constants.roles.RT_NODE }
local ok, reason = svc:_authorize_command({ role = constants.roles.FUEL_NODE, src = 'FUEL-1' })
assert_false(ok, 'non-master peer must not be able to drive node COMMAND handler')
assert_true(tostring(reason):find('authentication', 1, true) ~= nil,
  'unsigned command must fail authentication first')

ok, reason = svc:_authorize_command({
  role = constants.roles.FUEL_NODE, src = 'FUEL-1', auth_verified = true,
})
assert_false(ok, 'authenticated non-master peer must still be rejected')
assert_true(tostring(reason):find('MASTER', 1, true) ~= nil,
  'authenticated wrong role must identify MASTER requirement')

ok = svc:_authorize_command({
  role = constants.roles.MASTER, src = 'MASTER-2', auth_verified = true,
})
assert_false(ok, 'configured trusted_master_id must reject a different master identity')
ok = svc:_authorize_command({
  role = constants.roles.MASTER, src = 'MASTER-1', auth_verified = true,
})
assert_true(ok, 'configured trusted master identity must be accepted')

-- The coordinator must not accept a signed command from a different network
-- identity merely because it runs locally as MASTER.
local master_svc = service_lib.new({
  config = { role = constants.roles.MASTER, comms = { require_command_auth = true } },
  node_id = 'MASTER-LOCAL',
})
master_svc.network = { role = constants.roles.MASTER, id = 'MASTER-LOCAL' }
ok = master_svc:_authorize_command({
  role = constants.roles.MASTER, src = 'MASTER-OTHER', auth_verified = true,
})
assert_false(ok, 'local MASTER must reject another network identity')
ok = master_svc:_authorize_command({
  role = constants.roles.MASTER, src = 'MASTER-LOCAL', auth_verified = true,
})
assert_true(ok, 'local MASTER identity must remain authorized')

print('comms_command_source_authorization_test.lua: ok')
