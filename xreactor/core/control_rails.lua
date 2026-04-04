local rails = {}

local function clamp(value, min, max)
  if min ~= nil and value < min then
    return min
  end
  if max ~= nil and value > max then
    return max
  end
  return value
end

local function ensure_state(state)
  if type(state) ~= "table" then
    state = {}
  end
  if state.last_change_ts == nil then
    state.last_change_ts = 0
  end
  if state.last_direction == nil then
    state.last_direction = 0
  end
  if type(state.ema) ~= "table" then
    state.ema = {}
  end
  return state
end

function rails.new_state()
  return ensure_state({})
end

function rails.smooth(state, key, value, alpha)
  state = ensure_state(state)
  if type(value) ~= "number" then
    return value
  end
  if type(alpha) ~= "number" or alpha <= 0 or alpha >= 1 then
    return value
  end
  local prev = state.ema[key]
  if type(prev) ~= "number" then
    prev = value
  end
  local next_value = prev + alpha * (value - prev)
  state.ema[key] = next_value
  return next_value
end

local function resolve_ramp(config, direction)
  if not config or not config.ramp_profiles then
    return 1
  end
  local profile = config.ramp_profiles[config.ramp_profile or "NORMAL"] or {}
  if direction > 0 then
    return profile.up or 1
  elseif direction < 0 then
    return profile.down or 1
  end
  return 1
end

local function resolve_step(cfg, direction, error, ramp_multiplier)
  local max_key = direction > 0 and "max_step_up" or "max_step_down"
  local min_key = direction > 0 and "min_step_up" or "min_step_down"
  local gain_key = direction > 0 and "step_per_rpm_up" or "step_per_rpm_down"

  local max_step = math.max(0, tonumber(cfg[max_key]) or 0) * ramp_multiplier
  if max_step == 0 then
    return 0
  end

  local min_step = tonumber(cfg[min_key])
  if type(min_step) ~= "number" then
    min_step = max_step
  else
    min_step = math.max(0, min_step * ramp_multiplier)
  end
  if min_step > max_step then
    min_step = max_step
  end

  if cfg.adaptive_step ~= true then
    return max_step
  end

  local step_per_rpm = tonumber(cfg[gain_key])
  if type(step_per_rpm) ~= "number" or step_per_rpm <= 0 then
    return max_step
  end

  local err_mag = math.abs(tonumber(error) or 0)
  local dynamic_step = err_mag * step_per_rpm * ramp_multiplier
  return clamp(dynamic_step, min_step, max_step)
end

function rails.step(current, error, state, config, now)
  state = ensure_state(state)
  local cfg = config or {}
  local time_now = now or os.clock()
  local cooldown = math.max(0, tonumber(cfg.cooldown_s) or 0)
  if cooldown > 0 and time_now - state.last_change_ts < cooldown then
    return current, 0, {
      reason = "COOLDOWN",
      cooldown_s = cooldown,
      since_change_s = time_now - state.last_change_ts
    }
  end

  local deadband_up = math.max(0, tonumber(cfg.deadband_up) or 0)
  local deadband_down = math.max(0, tonumber(cfg.deadband_down) or deadband_up)
  local hysteresis_up = math.max(0, tonumber(cfg.hysteresis_up) or 0)
  local hysteresis_down = math.max(0, tonumber(cfg.hysteresis_down) or 0)

  local direction = 0
  if type(error) == "number" then
    if error >= deadband_up + (state.last_direction == -1 and hysteresis_up or 0) then
      direction = 1
    elseif error <= -deadband_down - (state.last_direction == 1 and hysteresis_down or 0) then
      direction = -1
    end
  end

  if direction == 0 then
    return current, 0, {
      reason = "DEADBAND",
      error = error,
      deadband_up = deadband_up,
      deadband_down = deadband_down,
      hysteresis_up = hysteresis_up,
      hysteresis_down = hysteresis_down
    }
  end

  local ramp_multiplier = resolve_ramp(cfg, direction)
  local step = resolve_step(cfg, direction, error, ramp_multiplier)
  if step == 0 then
    return current, 0, {
      reason = "STEP_ZERO",
      ramp_multiplier = ramp_multiplier
    }
  end

  local next_value = current + direction * step
  next_value = clamp(next_value, cfg.min, cfg.max)
  local reason = next_value == current and "CLAMP_NOOP" or "STEP"

  if next_value ~= current then
    state.last_change_ts = time_now
    state.last_direction = direction
  end

  return next_value, direction, {
    reason = reason,
    step = step,
    ramp_multiplier = ramp_multiplier,
    min = cfg.min,
    max = cfg.max
  }
end

function rails.ramp_target(current, target, config, opts)
  local cfg = config or {}
  opts = opts or {}
  local state = ensure_state(opts.state)
  local now_ts = tonumber(opts.now) or os.clock()

  if type(current) ~= "number" or type(target) ~= "number" then
    return current, {
      reason = "INVALID_INPUT",
      current = current,
      target = target
    }
  end

  local requested_delta = target - current
  if requested_delta == 0 then
    return current, {
      reason = "AT_TARGET",
      current = current,
      target = target,
      requested_delta = 0,
      applied_delta = 0
    }
  end

  local direction = requested_delta > 0 and 1 or -1
  local max_apply_key = direction > 0 and "max_apply_step_up" or "max_apply_step_down"
  local fallback_key = direction > 0 and "max_step_up" or "max_step_down"
  local max_step = math.max(0, tonumber(cfg[max_apply_key]) or tonumber(cfg[fallback_key]) or 0)
  if max_step == 0 then
    return current, {
      reason = "RAMP_DISABLED",
      current = current,
      target = target,
      requested_delta = requested_delta,
      applied_delta = 0,
      direction = direction
    }
  end

  local cooldown = math.max(0, tonumber(cfg.apply_cooldown_s) or tonumber(cfg.cooldown_s) or 0)
  local since_apply = now_ts - (tonumber(state.last_apply_ts) or 0)
  if cooldown > 0 and since_apply < cooldown then
    return current, {
      reason = "RAMP_COOLDOWN",
      current = current,
      target = target,
      requested_delta = requested_delta,
      applied_delta = 0,
      direction = direction,
      cooldown_s = cooldown,
      since_apply_s = since_apply
    }
  end

  local coolant_limited = false
  local coolant_reason = nil
  if direction < 0 then
    local coolant_ratio = tonumber(opts.coolant_ratio)
    if type(coolant_ratio) == "number" then
      local hard_limit = tonumber(cfg.coolant_ramp_hard_limit_ratio)
      if type(hard_limit) ~= "number" then
        hard_limit = tonumber(opts.safety_min_water) or 0.2
      end
      local soft_limit = tonumber(cfg.coolant_ramp_soft_limit_ratio) or (hard_limit + 0.08)
      local withdraw_soft = math.max(0, tonumber(cfg.max_step_down_when_coolant_soft) or 1)
      local withdraw_hard = math.max(0, tonumber(cfg.max_step_down_when_coolant_hard) or 0)
      if coolant_ratio <= hard_limit then
        max_step = math.min(max_step, withdraw_hard)
        coolant_limited = true
        coolant_reason = "HARD"
      elseif coolant_ratio <= soft_limit then
        max_step = math.min(max_step, withdraw_soft)
        coolant_limited = true
        coolant_reason = "SOFT"
      end
    end
  end

  if max_step == 0 then
    return current, {
      reason = "COOLANT_HOLD",
      current = current,
      target = target,
      requested_delta = requested_delta,
      applied_delta = 0,
      direction = direction,
      coolant_limited = coolant_limited,
      coolant_reason = coolant_reason
    }
  end

  local applied_mag = math.min(math.abs(requested_delta), max_step)
  local applied_delta = direction * applied_mag
  local next_value = clamp(current + applied_delta, cfg.min, cfg.max)
  state.last_apply_ts = now_ts
  return next_value, {
    reason = applied_mag < math.abs(requested_delta) and "RAMP_APPLIED" or "TARGET_REACHED",
    current = current,
    target = target,
    requested_delta = requested_delta,
    applied_delta = next_value - current,
    direction = direction,
    max_step = max_step,
    coolant_limited = coolant_limited,
    coolant_reason = coolant_reason
  }
end

return rails
