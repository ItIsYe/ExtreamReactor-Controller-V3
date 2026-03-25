package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local discovery_log = require("nodes.rt.discovery_log")

local summary = {
  visible_reactors = 1,
  visible_turbines = 25,
  bound_reactors = 1,
  bound_turbines = 25,
}

local decisions = {
  { kind = "reactor", name = "BigReactors-Reactor_0", type_name = "BigReactors-Reactor", bound = true, reason = "auto-discovery mode", error = false },
  { kind = "turbine", name = "BigReactors-Turbine_1", type_name = "BigReactors-Turbine", bound = true, reason = "auto-discovery mode", error = false },
}

local first_signature = discovery_log.build_signature(summary, decisions)
if not discovery_log.should_log_details(nil, first_signature, false) then
  error("first discovery pass must log details")
end

if discovery_log.should_log_details(first_signature, first_signature, false) then
  error("unchanged discovery should not re-log full details")
end

if not discovery_log.should_log_details(first_signature, first_signature, true) then
  error("discovery errors must force detailed logs")
end

local changed_summary = {
  visible_reactors = 1,
  visible_turbines = 26,
  bound_reactors = 1,
  bound_turbines = 26,
}
local next_signature = discovery_log.build_signature(changed_summary, decisions)
if not discovery_log.should_log_details(first_signature, next_signature, false) then
  error("changed discovery signature must log details")
end

print("discovery_log_spam_regression_test.lua: ok")
