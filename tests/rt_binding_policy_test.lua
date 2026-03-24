package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local binding = require("nodes.rt.binding")

local auto = binding.build_policy({}, {})
if not auto.allow_all_reactors or not auto.allow_all_turbines then
  error("empty RT config lists must enable auto-discovery")
end
if not binding.should_bind("reactor", "BigReactors-Reactor_4", auto) then
  error("auto-discovery must bind discovered reactors")
end
if not binding.should_bind("turbine", "BigReactors-Turbine_99", auto) then
  error("auto-discovery must bind discovered turbines")
end
local auto_bind, auto_reason = binding.should_bind_with_reason("turbine", "BigReactors-Turbine_99", auto)
if not auto_bind or not tostring(auto_reason):find("auto%-discovery") then
  error("auto-discovery reason should be returned for bind decision")
end

local explicit = binding.build_policy(
  { "BigReactors-Reactor_6" },
  { "BigReactors-Turbine_327", "BigReactors-Turbine_426" }
)
if explicit.allow_all_reactors or explicit.allow_all_turbines then
  error("explicit RT config lists must stay explicit")
end
if not binding.should_bind("reactor", "BigReactors-Reactor_6", explicit) then
  error("explicit reactor list must bind configured reactor")
end
if binding.should_bind("reactor", "BigReactors-Reactor_4", explicit) then
  error("explicit reactor list must not bind unconfigured reactor")
end
if not binding.should_bind("turbine", "BigReactors-Turbine_327", explicit) then
  error("explicit turbine list must bind configured turbine")
end
if binding.should_bind("turbine", "BigReactors-Turbine_999", explicit) then
  error("explicit turbine list must not bind unconfigured turbine")
end
local denied, deny_reason = binding.should_bind_with_reason("turbine", "BigReactors-Turbine_999", explicit)
if denied then
  error("explicit policy should deny unknown turbine names")
end
if not tostring(deny_reason):find("not listed") then
  error("explicit policy deny reason should mention explicit list")
end

local kind_by_type = binding.detect_kind("BigReactors-Turbine", {})
if kind_by_type ~= "turbine" then
  error("detect_kind should classify turbines via peripheral type")
end
local kind_by_methods, method_reason = binding.detect_kind("unknown", { setFluidFlowRate = true })
if kind_by_methods ~= "turbine" then
  error("detect_kind should classify turbines via setFluidFlowRate signature")
end
if not tostring(method_reason):find("turbine method signature") then
  error("detect_kind method signature reason missing")
end

local auto_msg = binding.missing_devices_message("reactor", auto)
if not auto_msg:find("auto%-discovery") then
  error("auto-discovery missing-device message should explain the default behavior")
end
local explicit_msg = binding.missing_devices_message("turbine", explicit)
if not explicit_msg:find("explicit names") then
  error("explicit missing-device message should explain explicit binding mode")
end

print("rt_binding_policy_test.lua: ok")
