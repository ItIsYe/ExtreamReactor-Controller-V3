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

function regulator.flows_match(requested_flow, confirmed_flow, tolerance)
  if type(requested_flow) ~= "number" or type(confirmed_flow) ~= "number" then
    return false
  end
  local tol = tonumber(tolerance) or 0
  if tol < 0 then
    tol = 0
  end
  return math.abs(requested_flow - confirmed_flow) <= tol
end

function regulator.should_defer_cooldown(requested_flow, confirmed_flow, pending_since, now_ts, settle_timeout_s, tolerance)
  if regulator.flows_match(requested_flow, confirmed_flow, tolerance) then
    return false, "SETTLED"
  end
  local now = tonumber(now_ts) or 0
  local since = tonumber(pending_since) or now
  local timeout_s = tonumber(settle_timeout_s) or 0
  if timeout_s <= 0 then
    return true, "WAITING_CONFIRM"
  end
  local age = now - since
  if age < timeout_s then
    return true, "WAITING_CONFIRM"
  end
  return false, "SETTLE_TIMEOUT"
end

return regulator
