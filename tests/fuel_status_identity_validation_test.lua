local root = os.getenv("REPO_ROOT") or "."
package.path = root .. "/xreactor/?.lua;" .. root .. "/xreactor/?/init.lua;" .. package.path

local protocol = require("core.protocol")
local constants = require("shared.constants")
local network = require("nodes.fuel.fuel_status_network")

local function assert_true(value, message) if not value then error(message) end end
local function assert_nil(value, message) if value ~= nil then error(message) end end

local cache = network.new()
local service = network.make_overhear_service(cache, constants)

local function feed(sender, global_id, fuel)
  local message = protocol.status(sender, constants.roles.RT_NODE, {
    reactors = {
      {
        id = "REACTOR-deadbeef",
        local_id = "REACTOR-deadbeef",
        global_id = global_id,
        fuel_amount = fuel,
        fuel_capacity = 1000,
      },
    },
  })
  service:tick(nil, {
    "modem_message", "left", constants.channels.STATUS,
    constants.channels.STATUS, message, 1,
  })
end

feed("node-A", "node-A:REACTOR-deadbeef", 100)
assert_true(cache.direct_heard["node-A:REACTOR-deadbeef"].fuel_amount == 100,
  "global identity must be cached")
assert_true(cache.direct_heard["REACTOR-deadbeef"].fuel_amount == 100,
  "unique legacy ID may remain compatible")

feed("node-B", "node-B:REACTOR-deadbeef", 200)
assert_true(cache.direct_heard["node-A:REACTOR-deadbeef"].fuel_amount == 100,
  "first global identity must survive collision")
assert_true(cache.direct_heard["node-B:REACTOR-deadbeef"].fuel_amount == 200,
  "second global identity must be independent")
assert_nil(cache.direct_heard["REACTOR-deadbeef"],
  "colliding legacy ID must fail closed")

feed("node-A", "node-B:REACTOR-deadbeef", 999)
assert_true(cache.direct_heard["node-A:REACTOR-deadbeef"].fuel_amount == 100,
  "global ID which contradicts message source must be rejected")

local before = cache.direct_heard["node-A:REACTOR-deadbeef"].fuel_amount
service:tick(nil, {
  "modem_message", "left", constants.channels.STATUS, constants.channels.STATUS,
  {
    type = constants.message_types.STATUS,
    role = constants.roles.RT_NODE,
    payload = { reactors = { { id = "REACTOR-deadbeef", fuel_amount = 999 } } },
  },
  1,
})
assert_true(cache.direct_heard["node-A:REACTOR-deadbeef"].fuel_amount == before,
  "packet without a valid raw protocol envelope must be rejected")

local wrong_channel = protocol.status("node-A", constants.roles.RT_NODE, {
  reactors = { { id = "REACTOR-deadbeef", fuel_amount = 777 } },
})
service:tick(nil, {
  "modem_message", "left", constants.channels.CONTROL,
  constants.channels.STATUS, wrong_channel, 1,
})
assert_true(cache.direct_heard["node-A:REACTOR-deadbeef"].fuel_amount == before,
  "status on wrong channel must be rejected")

network.prune(cache, os.epoch("utc") + 121000)
assert_nil(cache.direct_heard["node-A:REACTOR-deadbeef"], "stale cache must be pruned")
assert_nil(cache.direct_heard["node-B:REACTOR-deadbeef"], "all stale entries must be pruned")

print("fuel_status_identity_validation_test.lua: ok")
