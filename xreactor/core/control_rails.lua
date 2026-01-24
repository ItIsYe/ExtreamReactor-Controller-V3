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

function rails.step(current, error, state, config, now)
  state = ensure_state(state)
  local cfg = config or {}
  local time_now = now or os.clock()
  local cooldown = math.max(0, tonumber(cfg.cooldown_s) or 0)
  if cooldown > 0 and time_now - state.last_change_ts < cooldown then
    return current, 0
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
    return current, 0
  end

  local ramp_multiplier = resolve_ramp(cfg, direction)
  local step_up = math.max(0, tonumber(cfg.max_step_up) or 0) * ramp_multiplier
  local step_down = math.max(0, tonumber(cfg.max_step_down) or 0) * ramp_multiplier
  local step = direction > 0 and step_up or step_down
  if step == 0 then
    return current, 0
  end

  local next_value = current + direction * step
  next_value = clamp(next_value, cfg.min, cfg.max)

  if next_value ~= current then
    state.last_change_ts = time_now
    state.last_direction = direction
  end

  return next_value, direction
end

return rails
