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

function safety.safe_steam_request(request, capacity)
  local cap = tonumber(capacity) or 0
  if cap <= 0 then return 0 end
  local req = tonumber(request) or 0
  return safety.clamp(req, 0, cap)
end

return safety
