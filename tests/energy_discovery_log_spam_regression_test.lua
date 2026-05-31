package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local discovery_log = require("nodes.energy.discovery_log")

local snapshot = {
  names = { "monitor_0", "inductionPort_1", "energyCube_0" },
  peripheral_types = {
    monitor_0 = "monitor",
    inductionPort_1 = "mekanism:induction_port",
    energyCube_0 = "mekanism:ultimate_energy_cube"
  },
  candidates = {
    { name = "inductionPort_1", kind = "matrix", methods = { "getEnergy", "getMaxEnergy" } },
    { name = "energyCube_0", kind = "storage", methods = { "getEnergy", "getMaxEnergy" } }
  },
  monitor_name = "monitor_0",
  matrices = {
    { name = "inductionPort_1", methods = { "getEnergy", "getMaxEnergy" } }
  },
  registry_summary = { total = 3, bound = 3, missing = 0 }
}

local first_signature = discovery_log.build_signature(snapshot)
if not discovery_log.should_log_details(nil, first_signature, false) then
  error("first discovery pass must log details")
end

local same_signature = discovery_log.build_signature(snapshot)
if discovery_log.should_log_details(first_signature, same_signature, false) then
  error("unchanged energy discovery signature should not re-log details")
end

if not discovery_log.should_log_details(first_signature, same_signature, true) then
  error("forced mode should still log discovery details")
end

local changed = {
  names = snapshot.names,
  peripheral_types = snapshot.peripheral_types,
  candidates = {
    { name = "inductionPort_1", kind = "matrix", methods = { "getEnergy", "getMaxEnergy", "getTransferCap" } },
    { name = "energyCube_0", kind = "storage", methods = { "getEnergy", "getMaxEnergy" } }
  },
  monitor_name = snapshot.monitor_name,
  matrices = snapshot.matrices,
  registry_summary = snapshot.registry_summary
}
local changed_signature = discovery_log.build_signature(changed)
if not discovery_log.should_log_details(first_signature, changed_signature, false) then
  error("changed methods should trigger energy discovery detail logging")
end

print("energy_discovery_log_spam_regression_test.lua: ok")
