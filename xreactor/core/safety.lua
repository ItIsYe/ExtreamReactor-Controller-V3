local safety = {}

function safety.clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

function safety.with_reserve(amount, reserve)
  if amount < reserve then
    return reserve, true
  end
  return amount, false
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
  if capacity <= 0 then return 0 end
  return safety.clamp(request, 0, capacity)
end

return safety
