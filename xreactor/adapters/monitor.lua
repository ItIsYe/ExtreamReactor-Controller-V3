local utils = require("core.utils")

local monitor = {}
local warned = {}
local scale_cache = setmetatable({}, { __mode = "k" })

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

local function maybe_set_scale(mon, name, scale, log_prefix)
  if scale == nil then
    return true
  end
  local scale_number = tonumber(scale)
  if not scale_number then
    log_once(log_prefix, tostring(name) .. ":setTextScale:invalid", "Monitor setTextScale skipped for " .. tostring(name) .. " (non-numeric scale)")
    return false, "invalid scale"
  end
  if scale_cache[mon] == scale_number then
    return true
  end
  local ok, err = safe_call(mon, name, "setTextScale", log_prefix, scale_number)
  if ok then
    scale_cache[mon] = scale_number
    log_once(log_prefix, tostring(name) .. ":setTextScale:" .. tostring(scale_number), "Monitor setTextScale applied for " .. tostring(name) .. " -> " .. tostring(scale_number))
  end
  return ok, err
end

function monitor.find(preferred_name, strategy, scale, log_prefix)
  if preferred_name and peripheral.getType(preferred_name) == "monitor" then
    local mon = wrap_monitor(preferred_name, log_prefix)
    if mon then
      maybe_set_scale(mon, preferred_name, scale, log_prefix)
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
    maybe_set_scale(selected.mon, selected.name, scale, log_prefix)
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
    maybe_set_scale(best.mon, best.name, scale, log_prefix)
    return { name = best.name, mon = best.mon }
  end
  table.sort(candidates, function(a, b) return a.name < b.name end)
  local fallback = candidates[1]
  maybe_set_scale(fallback.mon, fallback.name, scale, log_prefix)
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
  return maybe_set_scale(mon, name, scale, log_prefix)
end

return monitor
