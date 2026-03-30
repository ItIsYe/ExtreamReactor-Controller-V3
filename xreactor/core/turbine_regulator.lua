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

function regulator.update_effective_min(state, requested_flow, confirmed_flow, required_samples)
  if type(state) ~= "table" then
    return nil, false
  end
  local samples = math.max(1, math.floor(tonumber(required_samples) or 3))
  if requested_flow == 0 and type(confirmed_flow) == "number" and confirmed_flow > 0 then
    if state.effective_min_candidate == confirmed_flow then
      state.effective_min_hits = (tonumber(state.effective_min_hits) or 0) + 1
    else
      state.effective_min_candidate = confirmed_flow
      state.effective_min_hits = 1
    end
    if state.effective_min_hits >= samples then
      local changed = state.effective_min_flow ~= confirmed_flow
      state.effective_min_flow = confirmed_flow
      return state.effective_min_flow, changed
    end
    return state.effective_min_flow, false
  end

  state.effective_min_candidate = nil
  state.effective_min_hits = 0
  if requested_flow ~= 0 then
    return state.effective_min_flow, false
  end
  return state.effective_min_flow, false
end

function regulator.sync_startup_state(state, confirmed_flow)
  if type(state) ~= "table" or type(confirmed_flow) ~= "number" then
    return false
  end
  state.confirmed_flow = confirmed_flow
  state.requested_flow = confirmed_flow
  state.flow = confirmed_flow
  state.pending_expected_flow = confirmed_flow
  state.pending_flow_since = 0
  state.pending_retries = 0
  state.last_requested_flow = confirmed_flow
  state.startup_synced = true
  return true
end

function regulator.resolve_min_flow(base_min, effective_min_flow)
  local min_flow = sanitize_number(base_min, 0)
  if min_flow < 0 then
    min_flow = 0
  end
  if type(effective_min_flow) == "number" and effective_min_flow > min_flow then
    return effective_min_flow, true
  end
  return min_flow, false
end

return regulator
