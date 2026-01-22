local utils = require("core.utils")
local ui = require("core.ui")

local monitor = {}

local function wrap_monitor(name)
  if not name or not peripheral.isPresent(name) then
    return nil
  end
  local mon, err = utils.safe_wrap(name)
  if not mon then
    return nil, err
  end
  return mon
end

function monitor.find(preferred_name, strategy, scale, log_prefix)
  if preferred_name and peripheral.getType(preferred_name) == "monitor" then
    local mon = wrap_monitor(preferred_name)
    if mon then
      if scale then
        ui.setScale(mon, scale)
      end
      return { name = preferred_name, mon = mon }
    end
  end
  local monitors = { peripheral.find("monitor") }
  local candidates = {}
  for _, mon in ipairs(monitors) do
    local ok, name = pcall(peripheral.getName, mon)
    if ok and name then
      table.insert(candidates, { name = name, mon = mon })
    end
  end
  if #candidates == 0 then
    return nil
  end
  local normalized = tostring(strategy or "largest"):lower()
  if normalized == "first" then
    table.sort(candidates, function(a, b) return a.name < b.name end)
    local selected = candidates[1]
    if scale then
      ui.setScale(selected.mon, scale)
    end
    return selected
  end
  local best
  for _, entry in ipairs(candidates) do
    local w, h = entry.mon.getSize()
    local area = w * h
    if not best or area > best.area then
      best = { name = entry.name, mon = entry.mon, area = area }
    end
  end
  if best then
    if scale then
      ui.setScale(best.mon, scale)
    end
    return { name = best.name, mon = best.mon }
  end
  table.sort(candidates, function(a, b) return a.name < b.name end)
  local fallback = candidates[1]
  if scale then
    ui.setScale(fallback.mon, scale)
  end
  return fallback
end

return monitor
