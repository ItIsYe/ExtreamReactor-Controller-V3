local utils = require("core.utils")

local turbine = {}

local function safe_call(name, method, ...)
  local ok, result = pcall(peripheral.call, name, method, ...)
  if not ok then
    return nil, result
  end
  return result
end

local function read_number(name, method)
  local value = safe_call(name, method)
  if type(value) == "number" then
    return value
  end
  return nil
end

function turbine.inspect(name)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local type_name = peripheral.getType(name) or "turbine"
  local methods = peripheral.getMethods(name) or {}
  local active = safe_call(name, "getActive") == true
  local rpm = read_number(name, "getRotorSpeed") or read_number(name, "getRotorRPM")
  local flow = read_number(name, "getFluidFlowRateMax")
  local energy = read_number(name, "getEnergyProducedLastTick")
  local coil = safe_call(name, "getInductorEngaged")
  return {
    name = name,
    type = type_name,
    adapter = "turbine",
    active = active,
    rpm = rpm,
    flow = flow,
    energy = energy,
    coil_engaged = coil == true,
    methods = methods
  }
end

function turbine.set_active(name, enabled)
  if not name then return nil, "missing peripheral" end
  return utils.safe_peripheral_call(name, "setActive", enabled and true or false)
end

function turbine.set_flow(name, value)
  if not name or value == nil then return nil, "missing data" end
  return utils.safe_peripheral_call(name, "setFluidFlowRateMax", value)
end

function turbine.set_coils(name, enabled)
  if not name then return nil, "missing peripheral" end
  return utils.safe_peripheral_call(name, "setInductorEngaged", enabled and true or false)
end

return turbine
