local root = os.getenv("REPO_ROOT") or "."
package.path = root .. "/xreactor/?.lua;" .. root .. "/xreactor/?/init.lua;" .. package.path

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
  ["REACTOR-1"] = {
    fuel_amount = 10,
    fuel_capacity = 100,
    label = "Nordreaktor",
    source_node = "node-53",
    local_reactor_id = "REACTOR-1",
    global_reactor_id = "node-53:REACTOR-1",
  },
})

local list = targets.collect({ logistics = {} }, cache)
assert(#list == 1, "global and compatibility cache keys must collapse to one target")
assert(list[1].id == "node-53:REACTOR-1", "route identity must stay global")
assert(list[1].label == "Nordreaktor", "installer name must reach FUEL editor")

local manual = targets.collect({
  logistics = {
    reactors = { { reactor_id = "node-54:REACTOR-2", name = "Suedreaktor" } },
  },
}, cache)
assert(#manual == 2 and manual[1].label == "Nordreaktor" and manual[2].label == "Suedreaktor",
  "manual and discovered names must be sorted and preserved")

print("fuel_reactor_alias_display_test.lua: ok")
