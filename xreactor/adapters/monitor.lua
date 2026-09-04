local utils = require("core.utils")

local monitor = {}
local warned = {}
local scale_cache = setmetatable({}, { __mode = "k" })
local scale_cache_by_name = {}
local wrapper_cache_by_name = {}
local shape_cache_by_name = {}
local known_monitor_names = {}

local function log_once(prefix, key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  utils.log(prefix or "MONITOR", message, "WARN")
end

local function wrap_monitor(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    if name then wrapper_cache_by_name[tostring(name)] = nil end
    return nil
  end
  local cache_name = tostring(name)
  if wrapper_cache_by_name[cache_name] then
    return wrapper_cache_by_name[cache_name]
  end
  local mon, err = utils.safe_wrap(name)
  if mon then
    wrapper_cache_by_name[cache_name] = mon
    known_monitor_names[cache_name] = true
  elseif err then
    log_once(log_prefix, "wrap:" .. cache_name, "Monitor wrap failed for " .. cache_name .. ": " .. tostring(err))
  end
  return mon, err
end

local function safe_call(mon, name, method, log_prefix, ...)
  if not mon or not mon[method] then
    return false, "missing method"
  end
  local fn = mon[method]
  local results = table.pack(pcall(fn, ...))
  if not results[1] then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method), "Monitor call failed for " .. tostring(name) .. "." .. tostring(method) .. ": " .. tostring(results[2]))
  end
  return table.unpack(results, 1, results.n)
end

local function maybe_set_scale(mon, name, scale, log_prefix)
  if scale == nil then
    return true
  end
  local scale_number = tonumber(scale)
  if not scale_number then
    log_once(
      log_prefix,
      tostring(name) .. ":setTextScale:invalid",
      "Monitor setTextScale skipped for " .. tostring(name)
        .. " (non-numeric scale type=" .. type(scale)
        .. " value=" .. tostring(scale) .. ")"
    )
    return false, "invalid scale"
  end
  local normalized = math.floor((scale_number * 2) + 0.5) / 2
  if normalized < 0.5 then
    normalized = 0.5
  elseif normalized > 5 then
    normalized = 5
  end
  local cache_name = tostring(name or "")
  if scale_cache[mon] == normalized then
    return true
  end
  if cache_name ~= "" and scale_cache_by_name[cache_name] == normalized then
    scale_cache[mon] = normalized
    return true
  end
  utils.log(log_prefix or "MONITOR", "Applying monitor scale for " .. tostring(name) .. ": " .. tostring(normalized))
  local ok, err = safe_call(mon, name, "setTextScale", log_prefix, normalized)
  if ok then
    scale_cache[mon] = normalized
    if cache_name ~= "" then
      scale_cache_by_name[cache_name] = normalized
      known_monitor_names[cache_name] = true
    end
    log_once(log_prefix, tostring(name) .. ":setTextScale:" .. tostring(normalized), "Monitor setTextScale applied for " .. tostring(name) .. " -> " .. tostring(normalized))
  end
  return ok, err
end

local function clear_name_cache(name)
  local cache_name = tostring(name or "")
  if cache_name == "" then
    return
  end
  scale_cache_by_name[cache_name] = nil
  wrapper_cache_by_name[cache_name] = nil
  shape_cache_by_name[cache_name] = nil
  known_monitor_names[cache_name] = nil
end

-- Lehnt 1x3-Ampel-Monitore als Hauptmonitor ab: mehr als 3 Zeilen ODER
-- mehr als 1 Spalte qualifiziert; ein reiner 1x3 (oder kleiner) wird
-- abgelehnt, auch wenn preferred_name darauf zeigt.
local function is_too_small_for_main(mon, name)
  local cache_name = tostring(name or "")
  if cache_name ~= "" and shape_cache_by_name[cache_name] ~= nil then
    return shape_cache_by_name[cache_name]
  end
  -- Skala wird vor der Messung explizit auf 1 gesetzt (Referenz-Skala
  -- fuer die 7x19-Formel einer 1x3-Ampel) und danach zurueckgesetzt --
  -- ein Monitor, der bei einer alten Skala haengt, wuerde sonst
  -- faelschlich winzige Werte messen und als Ampel gelten.
  local ok_orig, orig_scale = pcall(function() return mon.getTextScale() end)
  pcall(function() mon.setTextScale(1) end)
  local ok, w, h = pcall(function() return mon.getSize() end)
  if ok_orig and type(orig_scale) == "number" then
    pcall(function() mon.setTextScale(orig_scale) end)
  end
  if not ok or type(w) ~= "number" or type(h) ~= "number" then return false end
  -- Verifizierte Formel (siehe optional/ampel.lua): 1 Block breit x 3
  -- Bloecke hoch bei Skala 1 = exakt 7x19 Zeichen. Kleine Toleranz fuer
  -- Hoehe (17-21), falls die tatsaechliche Bauhoehe leicht abweicht.
  local too_small = w == 7 and h >= 17 and h <= 21
  if cache_name ~= "" then
    shape_cache_by_name[cache_name] = too_small
    known_monitor_names[cache_name] = true
  end
  return too_small
end

function monitor.find(preferred_name, strategy, scale, log_prefix)
  -- Keep cache lifetime tied to the physical peripheral inventory. This is
  -- deliberately done once per discovery call: a periodic scan reuses the
  -- same wrapper/shape result while a real detach removes all name-scoped
  -- cache state before a later reconnect with the same peripheral name.
  local names = peripheral.getNames() or {}
  monitor.sync_names(names)

  if preferred_name and peripheral.getType(preferred_name) == "monitor" then
    local mon = wrap_monitor(preferred_name, log_prefix)
    local too_small = mon and is_too_small_for_main(mon, preferred_name)
    if mon and not too_small then
      maybe_set_scale(mon, preferred_name, scale, log_prefix)
      return { name = preferred_name, mon = mon }
    end
    if mon and too_small then
      log_once(log_prefix, "preferred_too_small:" .. tostring(preferred_name),
        "Configured monitor " .. tostring(preferred_name) .. " is 1x3 (Ampel-sized) - refusing to use it as the main monitor, searching for another one")
    end
  end
  local candidates = {}
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      local mon = wrap_monitor(name, log_prefix)
      if mon and not is_too_small_for_main(mon, name) then
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
    local ok, w, h = safe_call(entry.mon, entry.name, "getSize", log_prefix)
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

function monitor.sync_names(names)
  local present = {}
  for _, name in ipairs(names or {}) do
    if name ~= nil then
      local key = tostring(name)
      present[key] = true
      known_monitor_names[key] = true
    end
  end
  for key in pairs(known_monitor_names) do
    if not present[key] then
      clear_name_cache(key)
    end
  end
end

function monitor.invalidate_name(name)
  clear_name_cache(name)
end

return monitor
