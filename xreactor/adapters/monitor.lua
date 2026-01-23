local utils = require("core.utils")

local monitor = {}
local warned = {}

local function log_once(prefix, key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  utils.log(prefix or "MONITOR", message, "WARN")
end

local function wrap_monitor(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    return nil
  end
  local mon, err = utils.safe_wrap(name)
  if not mon and err then
    log_once(log_prefix, "wrap:" .. tostring(name), "Monitor wrap failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return mon, err
end

local function safe_call(mon, name, method, log_prefix, ...)
  if not mon or not mon[method] then
    return false, "missing method"
  end
  local ok, err = pcall(mon[method], mon, ...)
  if not ok then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method), "Monitor call failed for " .. tostring(name) .. "." .. tostring(method) .. ": " .. tostring(err))
  end
  return ok, err
end

function monitor.find(preferred_name, strategy, scale, log_prefix)
  if preferred_name and peripheral.getType(preferred_name) == "monitor" then
    local mon = wrap_monitor(preferred_name, log_prefix)
    if mon then
      if scale then
        safe_call(mon, preferred_name, "setTextScale", log_prefix, scale)
      end
      return { name = preferred_name, mon = mon }
    end
  end
  local candidates = {}
  for _, name in ipairs(peripheral.getNames() or {}) do
    if peripheral.getType(name) == "monitor" then
      local mon = wrap_monitor(name, log_prefix)
      if mon then
        table.insert(candidates, { name = name, mon = mon })
      end
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
      safe_call(selected.mon, selected.name, "setTextScale", log_prefix, scale)
    end
    return selected
  end
  local best
  for _, entry in ipairs(candidates) do
    local ok, w, h = pcall(entry.mon.getSize, entry.mon)
    if ok then
      local area = w * h
      if not best or area > best.area then
        best = { name = entry.name, mon = entry.mon, area = area }
      end
    end
  end
  if best then
    if scale then
      safe_call(best.mon, best.name, "setTextScale", log_prefix, scale)
    end
    return { name = best.name, mon = best.mon }
  end
  table.sort(candidates, function(a, b) return a.name < b.name end)
  local fallback = candidates[1]
  if scale then
    safe_call(fallback.mon, fallback.name, "setTextScale", log_prefix, scale)
  end
  return fallback
end

function monitor.safe_clear(mon, name, log_prefix)
  return safe_call(mon, name, "clear", log_prefix)
end

function monitor.safe_set_cursor(mon, name, x, y, log_prefix)
  return safe_call(mon, name, "setCursorPos", log_prefix, x, y)
end

function monitor.safe_write(mon, name, text, log_prefix)
  return safe_call(mon, name, "write", log_prefix, text or "")
end

function monitor.safe_set_scale(mon, name, scale, log_prefix)
  return safe_call(mon, name, "setTextScale", log_prefix, scale)
end

return monitor
