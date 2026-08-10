package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local service_lib = require('services.comms_service')
local constants = require('shared.constants')
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_false(v, m) if v then error(m or 'assert_false failed') end end

local svc = service_lib.new({ config = { role = constants.roles.RT_NODE } })
svc.network = { role = constants.roles.RT_NODE }
local ok, reason = svc:_authorize_command({ role = constants.roles.FUEL_NODE, src = 'FUEL-1' })
assert_false(ok, 'non-master peer must not be able to drive node COMMAND handler')
assert_true(tostring(reason):find('MASTER', 1, true) ~= nil, 'rejection should identify master role requirement')

ok = svc:_authorize_command({ role = constants.roles.MASTER, src = 'MASTER-1' })
assert_true(ok, 'master role must remain authorized by default')

svc.config.trusted_master_id = 'MASTER-1'
ok = svc:_authorize_command({ role = constants.roles.MASTER, src = 'MASTER-2' })
assert_false(ok, 'configured trusted_master_id must reject a different master identity')
ok = svc:_authorize_command({ role = constants.roles.MASTER, src = 'MASTER-1' })
assert_true(ok, 'configured trusted master identity must be accepted')

-- MASTER is a coordinator and may receive role-specific commands/replies;
-- the node-side MASTER-only restriction must not be applied to local MASTER.
local master_svc = service_lib.new({ config = { role = constants.roles.MASTER } })
master_svc.network = { role = constants.roles.MASTER }
ok = master_svc:_authorize_command({ role = constants.roles.RT_NODE, src = 'RT-1' })
assert_true(ok, 'local MASTER must not inherit node-only source restriction')

print('comms_command_source_authorization_test.lua: ok')
