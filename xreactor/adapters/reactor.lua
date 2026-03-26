local utils = require("core.utils")

local reactor = {}
local warned = {}

local function log_once(prefix, key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  utils.log(prefix or "REACTOR", message, "WARN")
end

local function safe_call(name, method, log_prefix, ...)
  if not method then
    return nil
  end
  local result, err = utils.safe_peripheral_call(name, method, ...)
  if err then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method), "Reactor call failed for " .. tostring(name) .. "." .. tostring(method) .. ": " .. tostring(err))
  end
  return result
end

local function read_number(name, method, log_prefix)
  local value = safe_call(name, method, log_prefix)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then
      return parsed
    end
  end
  if value ~= nil then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method) .. ":type", "Reactor metric type mismatch peripheral=" .. tostring(name) .. " method=" .. tostring(method) .. " type=" .. type(value) .. " value=" .. tostring(value))
  end
  return "n/a"
end

local function has_method(set, key)
  return set and set[key] == true
end

local function build_method_set(name)
  local methods = utils.safe_get_methods(name) or {}
  local set = {}
  for _, method in ipairs(methods) do
    set[method] = true
  end
  return methods, set
end

local function normalize_rod_level(value)
  if type(value) == "number" then
    return value
  end
  if type(value) ~= "table" then
    return nil
  end
  if type(value.level) == "number" then
    return value.level
  end
  if type(value.inserted) == "number" then
    return value.inserted
  end
  if type(value.insertion) == "number" then
    return value.insertion
  end
  return nil
end

local function summarize_value(value)
  local value_type = type(value)
  if value_type == "number" or value_type == "string" or value_type == "boolean" or value_type == "nil" then
    return tostring(value)
  end
  if value_type == "table" then
    return "table(len=" .. tostring(#value) .. ")"
  end
  return value_type
end

local function log_rod_error(log_prefix, name, method, detail)
  log_once(
    log_prefix,
    tostring(name) .. ":rod:" .. tostring(method) .. ":" .. tostring(detail),
    "Reactor rod access failed peripheral="
      .. tostring(name)
      .. " expected="
      .. tostring(method)
      .. " detail="
      .. tostring(detail)
  )
end

function reactor.inspect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local type_name = peripheral.getType(name) or "reactor"
  local methods, method_set = build_method_set(name)
  local status = safe_call(name, "getStatus", log_prefix) or safe_call(name, "getActive", log_prefix)
  local active = (status == true or status == "online") and true or false
  local temp = read_number(name, has_method(method_set, "getFuelTemperature") and "getFuelTemperature" or "getTemperature", log_prefix)
  local fuel = read_number(name, "getFuelAmount", log_prefix)
  local waste = read_number(name, "getWasteAmount", log_prefix)
  local energy = read_number(name, has_method(method_set, "getEnergyStored") and "getEnergyStored" or "getEnergyProducedLastTick", log_prefix)
  local rods = reactor.read_control_rods(name, log_prefix)
  local steam = read_number(
    name,
    has_method(method_set, "getHotFluidAmount") and "getHotFluidAmount"
      or has_method(method_set, "getSteamAmount") and "getSteamAmount"
      or has_method(method_set, "getSteam") and "getSteam",
    log_prefix
  )
  return {
    name = name,
    type = type_name,
    adapter = "reactor",
    features = {
      active = has_method(method_set, "getStatus") or has_method(method_set, "getActive"),
      temperature = has_method(method_set, "getFuelTemperature") or has_method(method_set, "getTemperature"),
      fuel = has_method(method_set, "getFuelAmount"),
      waste = has_method(method_set, "getWasteAmount"),
      energy = has_method(method_set, "getEnergyStored") or has_method(method_set, "getEnergyProducedLastTick"),
      rods = has_method(method_set, "getControlRodLevel") or has_method(method_set, "getControlRodLevels") or has_method(method_set, "getControlRods"),
      steam = has_method(method_set, "getHotFluidAmount") or has_method(method_set, "getSteamAmount") or has_method(method_set, "getSteam")
    },
    schema = {
      active = "boolean",
      temperature = "number",
      fuel = "number",
      waste = "number",
      energy = "number",
      control_rod_level = "number",
      steam = "number"
    },
    active = active,
    temperature = temp,
    fuel = fuel,
    waste = waste,
    energy = energy,
    control_rod_level = rods,
    steam = steam,
    methods = methods
  }
end

function reactor.apply_rod_level(name, level, log_prefix)
  if not name or level == nil then return nil, "missing data" end
  local methods, method_set = build_method_set(name)

  if has_method(method_set, "setAllControlRodLevels") then
    local ok, err = utils.safe_peripheral_call(name, "setAllControlRodLevels", level)
    if err then
      log_rod_error(log_prefix, name, "setAllControlRodLevels", err)
      return nil, err
    end
    if ok == false then
      log_rod_error(log_prefix, name, "setAllControlRodLevels", "returned false")
      return nil, "returned false"
    end
    return true
  end

  if has_method(method_set, "getControlRods") then
    local rods, rods_err = utils.safe_peripheral_call(name, "getControlRods")
    if type(rods) ~= "table" then
      local detail = rods_err or ("unexpected value " .. summarize_value(rods))
      log_rod_error(log_prefix, name, "getControlRods", detail)
      return nil, detail
    end
    local changed = 0
    for _, rod in pairs(rods) do
      if rod and rod.setLevel then
        local ok_set, set_err = pcall(rod.setLevel, rod, level)
        if ok_set then
          changed = changed + 1
        else
          log_rod_error(log_prefix, name, "rod.setLevel", set_err)
        end
      end
    end
    if changed > 0 then
      return true
    end
    local detail = "no writable rods via getControlRods"
    log_rod_error(log_prefix, name, "getControlRods", detail)
    return nil, detail
  end

  local detail = "unsupported methods"
  log_rod_error(log_prefix, name, "setAllControlRodLevels|getControlRods", detail .. " available=" .. tostring(#methods))
  return nil, detail
end

function reactor.read_control_rods(name, log_prefix)
  if not name then
    return nil, "missing peripheral"
  end
  local _, method_set = build_method_set(name)

  if has_method(method_set, "getControlRodLevel") then
    local level, err = utils.safe_peripheral_call(name, "getControlRodLevel", 0)
    if type(level) == "number" then
      return level
    end
    log_rod_error(log_prefix, name, "getControlRodLevel", err or ("unexpected value " .. summarize_value(level)))
  end

  if has_method(method_set, "getControlRodLevels") then
    local levels, err = utils.safe_peripheral_call(name, "getControlRodLevels")
    if type(levels) == "table" and #levels > 0 then
      local sum, count = 0, 0
      for _, value in ipairs(levels) do
        if type(value) == "number" then
          sum = sum + value
          count = count + 1
        end
      end
      if count > 0 then
        return sum / count
      end
    end
    log_rod_error(log_prefix, name, "getControlRodLevels", err or ("unexpected value " .. summarize_value(levels)))
  end

  if has_method(method_set, "getControlRods") then
    local rods, err = utils.safe_peripheral_call(name, "getControlRods")
    if type(rods) == "table" then
      local sum, count = 0, 0
      for _, rod in pairs(rods) do
        local level = normalize_rod_level(rod)
        if level == nil and rod and rod.getLevel then
          local ok_level, value = pcall(rod.getLevel, rod)
          if ok_level then
            level = normalize_rod_level(value) or (type(value) == "number" and value or nil)
          end
        end
        if type(level) == "number" then
          sum = sum + level
          count = count + 1
        end
      end
      if count > 0 then
        return sum / count
      end
      log_rod_error(log_prefix, name, "getControlRods", "empty or unreadable rods")
      return nil, "empty or unreadable rods"
    end
    log_rod_error(log_prefix, name, "getControlRods", err or ("unexpected value " .. summarize_value(rods)))
    return nil, err or "unexpected getControlRods result"
  end

  log_rod_error(log_prefix, name, "getControlRodLevel|getControlRodLevels|getControlRods", "unsupported methods")
  return nil, "unsupported methods"
end

function reactor.set_active(name, enabled, log_prefix)
  if not name then return nil, "missing peripheral" end
  local ok, err = utils.safe_peripheral_call(name, "setActive", enabled and true or false)
  if err then
    log_once(log_prefix, tostring(name) .. ":setActive", "Reactor active failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

return reactor
