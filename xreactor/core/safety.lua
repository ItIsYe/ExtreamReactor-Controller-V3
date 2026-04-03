local safety = {}

function safety.clamp(value, min, max)
  local num = tonumber(value)
  if not num then
    return min or max or value
  end
  if min ~= nil and num < min then return min end
  if max ~= nil and num > max then return max end
  return num
end

function safety.with_reserve(amount, reserve)
  local current = tonumber(amount) or 0
  local min = tonumber(reserve) or 0
  if current < min then
    return min, true
  end
  return current, false
end

function safety.should_scram(reactor_metrics)
  if not reactor_metrics then return true end
  if reactor_metrics.temperature and reactor_metrics.temperature > (reactor_metrics.max_temperature or 950) then
    return true
  end
  if reactor_metrics.damage and reactor_metrics.damage > 0 then
    return true
  end
  return false
end

local function normalize_temperature(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then
      return parsed
    end
  end
  return nil
end

function safety.evaluate_temperature_limit(input)
  local data = type(input) == "table" and input or {}
  local fuel_temp = normalize_temperature(data.fuel_temperature)
  local casing_temp = normalize_temperature(data.casing_temperature)
  local limit = tonumber(data.max_temperature) or 950
  local hysteresis = math.max(0, tonumber(data.hysteresis) or 0)
  local required_samples = math.max(1, math.floor(tonumber(data.trip_samples) or 1))
  local state = type(data.state) == "table" and data.state or {}

  local selected_temp = nil
  local source = "UNAVAILABLE"
  if type(fuel_temp) == "number" and type(casing_temp) == "number" then
    if fuel_temp >= casing_temp then
      selected_temp = fuel_temp
      source = "getFuelTemperature"
    else
      selected_temp = casing_temp
      source = "getCasingTemperature"
    end
  elseif type(fuel_temp) == "number" then
    selected_temp = fuel_temp
    source = "getFuelTemperature"
  elseif type(casing_temp) == "number" then
    selected_temp = casing_temp
    source = "getCasingTemperature"
  end

  local over_limit = type(selected_temp) == "number" and selected_temp > limit
  if over_limit then
    state.over_limit_ticks = (tonumber(state.over_limit_ticks) or 0) + 1
    state.last_over_limit_temp = selected_temp
  elseif type(selected_temp) == "number" and selected_temp <= (limit - hysteresis) then
    state.over_limit_ticks = 0
  end

  local over_limit_ticks = tonumber(state.over_limit_ticks) or 0
  local triggered = over_limit and over_limit_ticks >= required_samples
  local condition = "TEMP_OK"
  if selected_temp == nil then
    condition = "TEMP_UNAVAILABLE"
  elseif triggered then
    condition = "TEMP_LIMIT_PERSISTENT"
  elseif over_limit then
    condition = "TEMP_LIMIT_PENDING"
  end

  return {
    triggered = triggered,
    over_limit = over_limit,
    condition = condition,
    source = source,
    temperature = selected_temp,
    fuel_temperature = fuel_temp,
    casing_temperature = casing_temp,
    max_temperature = limit,
    hysteresis = hysteresis,
    trip_samples = required_samples,
    over_limit_ticks = over_limit_ticks
  }
end

function safety.safe_steam_request(request, capacity)
  local cap = tonumber(capacity) or 0
  if cap <= 0 then return 0 end
  local req = tonumber(request) or 0
  return safety.clamp(req, 0, cap)
end

return safety
