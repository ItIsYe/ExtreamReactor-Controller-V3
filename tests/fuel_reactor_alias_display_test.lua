local root = os.getenv("REPO_ROOT") or "."
package.path = root .. "/xreactor/?.lua;" .. root .. "/xreactor/?/init.lua;" .. package.path

_G.os = _G.os or {}
os.epoch = os.epoch or function() return 100000 end

local network = require("nodes.fuel.fuel_status_network")
local targets = require("nodes.fuel.reactor_targets")

local cache = network.new()
network.ingest_master_relay(cache, {
  ["node-53:REACTOR-1"] = {
    fuel_amount = 10,
    fuel_capacity = 100,
    label = "Nordreaktor",
    source_node = "node-53",
    local_reactor_id = "REACTOR-1",
    global_reactor_id = "node-53:REACTOR-1",
  },
  -- Historical local alias for the same reactor must not create a second row.
  ["REACTOR-1"] = {
    fuel_amount = 10,
    fuel_capacity = 100,
    label = "Nordreaktor",
    source_node = "node-53",
    local_reactor_id = "REACTOR-1",
    global_reactor_id = "node-53:REACTOR-1",
  },
})

local list = targets.collect({ logistics = {} }, cache, nil, { roles = { RT_NODE = "RT-NODE" } })
assert(#list == 1, "global and compatibility cache keys must collapse to one route target")
assert(list[1].id == "node-53:REACTOR-1", "technical global id must remain the route identity")
assert(list[1].label == "Nordreaktor", "installer display name must reach the FUEL route editor")

local manual = targets.collect({
  logistics = {
    reactors = { { reactor_id = "node-54:REACTOR-2", name = "Suedreaktor" } },
  },
}, cache, nil, { roles = { RT_NODE = "RT-NODE" } })
assert(#manual == 2 and manual[1].label == "Nordreaktor" and manual[2].label == "Suedreaktor",
  "manual and discovered reactor names must be sorted and preserved")

print("fuel_reactor_alias_display_test.lua: ok")
