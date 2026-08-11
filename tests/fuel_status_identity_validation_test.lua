package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local protocol = require('core.protocol')
local constants = require('shared.constants')
local network = require('nodes.fuel.fuel_status_network')
local SECRET = 'fuel-status-test-secret-123456'

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_nil(v, m) if v ~= nil then error((m or 'expected nil') .. ': ' .. tostring(v)) end end

local cache = network.new()
local service = network.make_overhear_service(cache, constants, { auth_secret = SECRET })

local function feed(sender, global_id, fuel)
  local msg = protocol.status(sender, constants.roles.RT_NODE, {
    reactors = {
      { id = 'REACTOR-deadbeef', local_id = 'REACTOR-deadbeef', global_id = global_id,
        fuel_amount = fuel, fuel_capacity = 1000 }
    }
  })
  assert(protocol.sign_message(msg, SECRET))
  service:tick(nil, { 'modem_message', 'left', constants.channels.STATUS, constants.channels.STATUS, msg, 1 })
end

feed('node-A', 'node-A:REACTOR-deadbeef', 100)
assert_true(cache.direct_heard['node-A:REACTOR-deadbeef'].fuel_amount == 100,
  'global reactor identity must be cached')
assert_true(cache.direct_heard['REACTOR-deadbeef'].fuel_amount == 100,
  'unique legacy id may remain temporarily compatible')

feed('node-B', 'node-B:REACTOR-deadbeef', 200)
assert_true(cache.direct_heard['node-A:REACTOR-deadbeef'].fuel_amount == 100,
  'first global identity must not be overwritten by collision')
assert_true(cache.direct_heard['node-B:REACTOR-deadbeef'].fuel_amount == 200,
  'second global identity must remain independently addressable')
assert_nil(cache.direct_heard['REACTOR-deadbeef'],
  'legacy local id must fail closed once two RT sources collide')

-- Invalid raw packet has plausible type/role but no valid protocol envelope.
local before = cache.direct_heard['node-A:REACTOR-deadbeef'].fuel_amount
service:tick(nil, { 'modem_message', 'left', constants.channels.STATUS, constants.channels.STATUS, {
  type = constants.message_types.STATUS,
  role = constants.roles.RT_NODE,
  payload = { reactors = { { id = 'REACTOR-deadbeef', fuel_amount = 999, fuel_capacity = 1000 } } }
}, 1 })
assert_true(cache.direct_heard['node-A:REACTOR-deadbeef'].fuel_amount == before,
  'invalid raw modem packet must not inject fuel data')

local tampered = protocol.status('node-A', constants.roles.RT_NODE, {
  reactors = { { id = 'REACTOR-deadbeef', global_id = 'node-A:REACTOR-deadbeef', fuel_amount = 300 } }
})
assert(protocol.sign_message(tampered, SECRET))
tampered.payload.reactors[1].fuel_amount = 999
service:tick(nil, { 'modem_message', 'left', constants.channels.STATUS, constants.channels.STATUS, tampered, 1 })
assert_true(cache.direct_heard['node-A:REACTOR-deadbeef'].fuel_amount == before,
  'tampered authenticated packet must be rejected')

local wrong_channel = protocol.status('node-A', constants.roles.RT_NODE, {
  reactors = { { id = 'REACTOR-deadbeef', global_id = 'node-A:REACTOR-deadbeef', fuel_amount = 777 } }
})
assert(protocol.sign_message(wrong_channel, SECRET))
service:tick(nil, { 'modem_message', 'left', constants.channels.CONTROL, constants.channels.STATUS, wrong_channel, 1 })
assert_true(cache.direct_heard['node-A:REACTOR-deadbeef'].fuel_amount == before,
  'status packet on the wrong channel must be rejected')

network.prune(cache, os.epoch('utc') + 121000)
assert_nil(cache.direct_heard['node-A:REACTOR-deadbeef'], 'stale global cache entry must be pruned')
assert_nil(cache.direct_heard['node-B:REACTOR-deadbeef'], 'all stale direct entries must be pruned')

print('fuel_status_identity_validation_test.lua: ok')
