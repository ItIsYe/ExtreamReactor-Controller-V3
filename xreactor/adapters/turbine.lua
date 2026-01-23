local utils = require("core.utils")

local turbine = {}
local warned = {}

local function log_once(prefix, key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  utils.log(prefix or "TURBINE", message, "WARN")
end

local function safe_call(name, method, log_prefix, ...)
  if not method then
    return nil
  end
  local result, err = utils.safe_peripheral_call(name, method, ...)
  if err then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method), "Turbine call failed for " .. tostring(name) .. "." .. tostring(method) .. ": " .. tostring(err))
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

function turbine.inspect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local type_name = peripheral.getType(name) or "turbine"
  local methods = peripheral.getMethods(name) or {}
  local method_set = {}
  for _, method in ipairs(methods) do
    method_set[method] = true
  end
  local active = safe_call(name, "getActive", log_prefix) == true
  local rpm = read_number(name, has_method(method_set, "getRotorSpeed") and "getRotorSpeed" or "getRotorRPM", log_prefix)
  local flow = read_number(name, "getFluidFlowRateMax", log_prefix)
  local energy = read_number(name, "getEnergyProducedLastTick", log_prefix)
  local coil = safe_call(name, "getInductorEngaged", log_prefix)
  return {
    name = name,
    type = type_name,
    adapter = "turbine",
    features = {
      active = has_method(method_set, "getActive"),
      rpm = has_method(method_set, "getRotorSpeed") or has_method(method_set, "getRotorRPM"),
      flow = has_method(method_set, "getFluidFlowRateMax"),
      energy = has_method(method_set, "getEnergyProducedLastTick"),
      coils = has_method(method_set, "getInductorEngaged")
    },
    schema = {
      active = "boolean",
      rpm = "number",
      flow = "number",
      energy = "number",
      coil_engaged = "boolean"
    },
    active = active,
    rpm = rpm,
    flow = flow,
    energy = energy,
    coil_engaged = coil == true,
    methods = methods
  }
end

function turbine.set_active(name, enabled, log_prefix)
  if not name then return nil, "missing peripheral" end
  local ok, err = utils.safe_peripheral_call(name, "setActive", enabled and true or false)
  if err then
    log_once(log_prefix, tostring(name) .. ":setActive", "Turbine active failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

function turbine.set_flow(name, value, log_prefix)
  if not name or value == nil then return nil, "missing data" end
  local ok, err = utils.safe_peripheral_call(name, "setFluidFlowRateMax", value)
  if err then
    log_once(log_prefix, tostring(name) .. ":setFluidFlowRateMax", "Turbine flow failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

function turbine.set_coils(name, enabled, log_prefix)
  if not name then return nil, "missing peripheral" end
  local ok, err = utils.safe_peripheral_call(name, "setInductorEngaged", enabled and true or false)
  if err then
    log_once(log_prefix, tostring(name) .. ":setInductorEngaged", "Turbine coil failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

return turbine
