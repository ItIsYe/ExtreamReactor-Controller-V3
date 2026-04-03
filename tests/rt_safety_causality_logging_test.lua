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
assert_contains(lifecycle_src, "source=%s fuel_temp=%s casing_temp=%s hysteresis=%s over_limit_ticks=%s trip_samples=%s condition=%s", "temperature safety log must include source/value/hysteresis diagnostics")
assert_contains(lifecycle_src, "amount=%s max=%s ratio=%s ratio_raw=%s threshold=%s recover_threshold=%s hysteresis=%s source=%s source_method=%s measurement_state=%s stale_fallback=%s low_ticks=%s trip_samples=%s invalid_ticks=%s invalid_grace=%s zero_glitch_pending=%s condition=%s causality=%s", "coolant safety log must include source/value/hysteresis diagnostics")
assert_contains(lifecycle_src, "Safety trigger correlation: temp_causality=%s coolant_ratio=%s coolant_threshold=%s coolant_condition=%s coolant_source=%s coolant_low_ticks=%s", "temperature/coolant causality correlation log must be explicit")
assert_contains(lifecycle_src, "ctx.setState(ctx.STATE.SAFE, \"SAFETY_COOLANT_LOW\")", "coolant safety must set SAFE with explicit reason")
assert_contains(lifecycle_src, "ctx.setState(ctx.STATE.SAFE, \"SAFETY_TEMPERATURE_HIGH\")", "temperature safety must set SAFE with explicit reason")
assert_contains(main_src, "ACTIVE_TRIM_WITH_READBACK_LAG", "target trim and readback lag must be represented as separate combined state")
assert_contains(main_src, "TRIM_PENDING_CONFIRMATION", "trim state should remain trim while confirmation is pending")
assert_contains(main_src, "HOLD_CONFIRMED", "hold status should only be confirmed on readback confirmation")
assert_contains(main_src, "and target_band.mode == \"HOLDING_TARGET_ACTIVE\"", "target hold flag must require explicit hold mode")
assert_contains(main_src, "ctrl.target_trim_active = (not overspeed_state.active)", "target trim flag must be tracked explicitly")

print("rt_safety_causality_logging_test.lua: ok")
