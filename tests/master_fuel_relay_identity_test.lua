local root = os.getenv("REPO_ROOT") or "."
package.path = root .. "/xreactor/?.lua;" .. root .. "/xreactor/?/init.lua;" .. package.path

local relay = require("master.fuel_relay")

local constants = { roles = { RT_NODE = "RT", FUEL_NODE = "FUEL" } }
local runtime = {
  libs = { constants = constants },
  state = {
    nodes = {
      ["RT-A"] = {
        id = "RT-A", role = "RT", last_seen = os.epoch("utc"),
        rt = { reactors = {
          { id = "REACTOR-1", global_id = "RT-A:REACTOR-1", alias = "Nord",
            fuel_amount = 10, fuel_capacity = 100 },
        } },
      },
      ["RT-B"] = {
        id = "RT-B", role = "RT", last_seen = os.epoch("utc"),
        rt = { reactors = {
          { id = "REACTOR-1", global_id = "RT-B:REACTOR-1", alias = "Sued",
            fuel_amount = 20, fuel_capacity = 100 },
        } },
      },
    },
  },
}

local snapshot = relay._collect_reactor_fuel(runtime)
assert(snapshot["RT-A:REACTOR-1"] and snapshot["RT-A:REACTOR-1"].label == "Nord")
assert(snapshot["RT-B:REACTOR-1"] and snapshot["RT-B:REACTOR-1"].label == "Sued")
assert(snapshot["REACTOR-1"] == nil,
  "local ID shared by two RT nodes must not select an arbitrary reactor")

runtime.state.nodes["RT-B"] = nil
snapshot = relay._collect_reactor_fuel(runtime)
assert(snapshot["REACTOR-1"] == snapshot["RT-A:REACTOR-1"],
  "unique local ID remains available during rolling upgrade")

runtime.state.nodes["RT-A"].rt.reactors[1].global_id = "RT-X:REACTOR-1"
snapshot = relay._collect_reactor_fuel(runtime)
assert(next(snapshot) == nil, "contradictory published identity must be rejected")

print("master_fuel_relay_identity_test.lua: ok")
