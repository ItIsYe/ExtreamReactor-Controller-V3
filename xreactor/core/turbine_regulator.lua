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


function regulator.classify_bottleneck(input)
  local requested = sanitize_number(type(input) == "table" and input.requested_flow or nil, 0)
  local confirmed = sanitize_number(type(input) == "table" and input.confirmed_flow or nil, requested)
  local rotor = sanitize_number(type(input) == "table" and input.rpm or nil, -1)
  local target = sanitize_number(type(input) == "table" and input.target_rpm or nil, 0)
  local max = sanitize_number(type(input) == "table" and input.max_flow or nil, 0)
  local inductor_engaged = type(input) == "table" and input.inductor_engaged or nil
  local steam_input = sanitize_number(type(input) == "table" and input.steam_input or nil, -1)
  local min_flow = sanitize_number(type(input) == "table" and input.min_flow or nil, 0)
  local abs_error = target - rotor
  if rotor < 0 then
    return "RPM_UNAVAILABLE", "RPM_READ_FAILED"
  end
  if requested >= max and rotor < (target - 50) then
    if inductor_engaged == true then
      return "MAX_FLOW_LOW_RPM_WITH_COIL", "PLANT_OR_COIL_LIMIT"
    end
    if steam_input >= 0 and steam_input < math.max(0, confirmed - 25) then
      return "MAX_FLOW_LOW_RPM_STEAM_LIMIT", "STEAM_INPUT_BELOW_FLOW"
    end
    return "MAX_FLOW_LOW_RPM_STEAM_LIMIT", "PLANT_LIMIT_AT_MAX_FLOW"
  end
  if requested <= (min_flow + 1) and rotor > (target + 50) then
    if inductor_engaged == true then
      return "MIN_LIMIT_OVERSPEED", "MIN_FLOW_WITH_COIL_ENGAGED_NO_FURTHER_DOWN"
    end
    return "MIN_LIMIT_OVERSPEED", "MIN_FLOW_LIMIT_REACHED_NO_FURTHER_DOWN"
  end
  if requested >= (max - 1) and abs_error > 0 then
    return "MAX_LIMIT_UNDERSPEED", "MAX_FLOW_LIMIT_REACHED_NO_FURTHER_UP"
  end
  if math.abs(requested - confirmed) > 5 then
    return "FLOW_READBACK_LAG", "API_READBACK_LAG"
  end
  return "NONE", "NO_LIMITER_DETECTED"
end

function regulator.target_band_state(input)
  local rpm = sanitize_number(type(input) == "table" and input.rpm or nil, 0)
  local live_rpm = sanitize_number(type(input) == "table" and input.live_rpm or nil, rpm)
  local target = sanitize_number(type(input) == "table" and input.target_rpm or nil, 0)
  local requested = sanitize_number(type(input) == "table" and input.requested_flow or nil, 0)
  local confirmed = sanitize_number(type(input) == "table" and input.confirmed_flow or nil, requested)
  local min_flow = sanitize_number(type(input) == "table" and input.min_flow or nil, 0)
  local max_flow = sanitize_number(type(input) == "table" and input.max_flow or nil, 2000)
  local band = math.max(0, sanitize_number(type(input) == "table" and input.band_rpm or nil, 20))
  local trim_trigger = math.max(0, sanitize_number(type(input) == "table" and input.trim_trigger_rpm or nil, 5))
  local trim_up = math.max(1, sanitize_number(type(input) == "table" and input.trim_up_step or nil, 25))
  local trim_down = math.max(1, sanitize_number(type(input) == "table" and input.trim_down_step or nil, 25))
  local coil_engaged = type(input) == "table" and input.coil_engaged == true

  local error_smooth = target - rpm
  local error_live = target - live_rpm
  local error = math.abs(error_live) <= band and error_live or error_smooth
  local abs_error = math.abs(error)
  if abs_error > band then
    return { in_band = false, mode = "TRACKING", flow = requested, direction = 0, reason = "OUTSIDE_TARGET_BAND", error = error, live_error = error_live, smoothed_error = error_smooth }
  end

  local effective_flow = math.max(requested, confirmed)
  local at_max_flow = effective_flow >= (max_flow - 1)

  if at_max_flow and abs_error <= trim_trigger then
    local next_flow = regulator.clamp_flow(requested - trim_down, min_flow, max_flow)
    local reason = next_flow == requested and "MIN_LIMIT_OVERSPEED" or "TARGET_TRIM_DOWN"
    return {
      in_band = true,
      mode = reason,
      flow = next_flow,
      direction = next_flow < requested and -1 or 0,
      reason = reason,
      error = error,
      live_error = error_live,
      smoothed_error = error_smooth,
      at_min_limit = next_flow <= min_flow
    }
  end

  if error >= trim_trigger then
    local next_flow = regulator.clamp_flow(requested + trim_up, min_flow, max_flow)
    local reason = next_flow == requested and "MAX_LIMIT_UNDERSPEED" or "TARGET_TRIM_UP"
    return {
      in_band = true,
      mode = reason,
      flow = next_flow,
      direction = next_flow > requested and 1 or 0,
      reason = reason,
      error = error,
      live_error = error_live,
      smoothed_error = error_smooth,
      at_max_limit = next_flow >= max_flow
    }
  end

  if error <= -trim_trigger then
    local next_flow = regulator.clamp_flow(requested - trim_down, min_flow, max_flow)
    local reason = next_flow == requested and "MIN_LIMIT_OVERSPEED" or "TARGET_TRIM_DOWN"
    return {
      in_band = true,
      mode = reason,
      flow = next_flow,
      direction = next_flow < requested and -1 or 0,
      reason = reason,
      error = error,
      live_error = error_live,
      smoothed_error = error_smooth,
      at_min_limit = next_flow <= min_flow
    }
  end

  if at_max_flow and error <= 0 then
    local next_flow = regulator.clamp_flow(requested - trim_down, min_flow, max_flow)
    local reason = next_flow == requested and "MIN_LIMIT_OVERSPEED" or "TARGET_TRIM_DOWN"
    return {
      in_band = true,
      mode = reason,
      flow = next_flow,
      direction = next_flow < requested and -1 or 0,
      reason = reason,
      error = error,
      live_error = error_live,
      smoothed_error = error_smooth,
      at_min_limit = next_flow <= min_flow
    }
  end
  if requested <= (min_flow + 1) and error >= 0 then
    local next_flow = regulator.clamp_flow(requested + trim_up, min_flow, max_flow)
    local reason = next_flow == requested and "MAX_LIMIT_UNDERSPEED" or "TARGET_TRIM_UP"
    return {
      in_band = true,
      mode = reason,
      flow = next_flow,
      direction = next_flow > requested and 1 or 0,
      reason = reason,
      error = error,
      live_error = error_live,
      smoothed_error = error_smooth,
      at_max_limit = next_flow >= max_flow
    }
  end

  local deadband_reason = coil_engaged and "TARGET_BAND_ACTIVE_WITH_COIL" or "TARGET_BAND_ACTIVE"
  if at_max_flow then
    local next_flow = regulator.clamp_flow(requested - trim_down, min_flow, max_flow)
    local reason = next_flow == requested and "MAX_LIMIT_UNDERSPEED" or "TARGET_TRIM_DOWN"
    return {
      in_band = true,
      mode = reason,
      flow = next_flow,
      direction = next_flow < requested and -1 or 0,
      reason = reason,
      error = error,
      live_error = error_live,
      smoothed_error = error_smooth,
      at_min_limit = next_flow <= min_flow,
      at_max_limit = next_flow >= max_flow
    }
  end
  return {
    in_band = true,
    mode = "HOLDING_TARGET_ACTIVE",
    flow = requested,
    direction = 0,
    reason = deadband_reason,
    error = error,
    live_error = error_live,
    smoothed_error = error_smooth,
    at_max_limit = requested >= max_flow,
    at_min_limit = requested <= min_flow
  }
end

return regulator
