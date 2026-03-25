local safety = require("core.safety")

local regulator = {}

local function sanitize_number(value, fallback)
  if type(value) == "number" then
    return value
  end
  return fallback
end

function regulator.should_regulate_module_state(module_state)
  if module_state == "ERROR" then
    return false, "STATE_ERROR"
  end
  if module_state == "STARTING" then
    return false, "STATE_STARTING"
  end
  if module_state == "OFF" then
    return false, "STATE_OFF"
  end
  return true, "STATE_OK"
end

function regulator.startup_reached_target(rpm, target_rpm, tolerance)
  rpm = sanitize_number(rpm, 0)
  target_rpm = sanitize_number(target_rpm, 0)
  tolerance = math.max(sanitize_number(tolerance, 0), 0)
  if target_rpm <= 0 then
    return rpm > 0
  end
  return rpm >= math.max(0, target_rpm - tolerance)
end

function regulator.clamp_flow(rate, min_flow, max_flow)
  if type(rate) ~= "number" then
    rate = min_flow
  end
  return safety.clamp(rate, min_flow, max_flow)
end

return regulator
