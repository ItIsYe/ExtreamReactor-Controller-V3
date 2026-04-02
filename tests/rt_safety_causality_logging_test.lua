local function read(path)
  local handle = io.open(path, "r")
  if not handle then
    error("unable to read " .. tostring(path))
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local main_src = read("xreactor/nodes/rt/main.lua")
local lifecycle_src = read("xreactor/nodes/rt/module_lifecycle.lua")

local function assert_contains(src, pattern, message)
  if not src:find(pattern, 1, true) then
    error(message)
  end
end

assert_contains(main_src, "Entering SAFE mode reason=", "state transition log must include explicit SAFE reason")
assert_contains(main_src, "Turbine active name=", "turbine active transitions must be explicitly logged")
assert_contains(main_src, "reason=SAFE_MODE", "SAFE-mode actuator command reason must be logged")
assert_contains(main_src, "readback_state=", "turbine diagnostics must log explicit readback state")
assert_contains(main_src, "Overspeed brake pending name=", "overspeed mismatch path must emit explicit diagnostics")

assert_contains(lifecycle_src, "Safety ownership=SAFETY subsystem=REACTOR_COOLANT action=ENTER_SAFE", "coolant safety path must log ownership separation")
assert_contains(lifecycle_src, "Safety ownership=SAFETY subsystem=REACTOR_TEMP action=ENTER_SAFE", "temperature safety path must log ownership separation")
assert_contains(lifecycle_src, "ctx.setState(ctx.STATE.SAFE, \"SAFETY_COOLANT_LOW\")", "coolant safety must set SAFE with explicit reason")
assert_contains(lifecycle_src, "ctx.setState(ctx.STATE.SAFE, \"SAFETY_TEMPERATURE_HIGH\")", "temperature safety must set SAFE with explicit reason")

print("rt_safety_causality_logging_test.lua: ok")
