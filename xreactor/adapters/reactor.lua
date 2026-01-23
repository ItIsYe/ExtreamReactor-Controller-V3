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
  return "n/a"
end

local function has_method(set, key)
  return set and set[key] == true
end

function reactor.inspect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local type_name = peripheral.getType(name) or "reactor"
  local methods = peripheral.getMethods(name) or {}
  local method_set = {}
  for _, method in ipairs(methods) do
    method_set[method] = true
  end
  local status = safe_call(name, "getStatus", log_prefix) or safe_call(name, "getActive", log_prefix)
  local active = (status == true or status == "online") and true or false
  local temp = read_number(name, has_method(method_set, "getFuelTemperature") and "getFuelTemperature" or "getTemperature", log_prefix)
  local fuel = read_number(name, "getFuelAmount", log_prefix)
  local waste = read_number(name, "getWasteAmount", log_prefix)
  local energy = read_number(name, has_method(method_set, "getEnergyStored") and "getEnergyStored" or "getEnergyProducedLastTick", log_prefix)
  local rods = read_number(name, "getControlRodLevel", log_prefix)
  local steam = read_number(name, has_method(method_set, "getHotFluidAmount") and "getHotFluidAmount" or "getSteamAmount", log_prefix)
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
      rods = has_method(method_set, "getControlRodLevel"),
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
  local ok, err = utils.safe_peripheral_call(name, "setAllControlRodLevels", level)
  if err then
    log_once(log_prefix, tostring(name) .. ":setAllControlRodLevels", "Reactor rod level failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
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
