local utils = require("core.utils")

local reactor = {}

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

function reactor.inspect(name)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local type_name = peripheral.getType(name) or "reactor"
  local methods = peripheral.getMethods(name) or {}
  local status = safe_call(name, "getStatus") or safe_call(name, "getActive")
  local active = status == true or status == "online"
  local temp = read_number(name, "getFuelTemperature") or read_number(name, "getTemperature")
  local fuel = read_number(name, "getFuelAmount")
  local waste = read_number(name, "getWasteAmount")
  local energy = read_number(name, "getEnergyStored") or read_number(name, "getEnergyProducedLastTick")
  local rods = read_number(name, "getControlRodLevel")
  return {
    name = name,
    type = type_name,
    adapter = "reactor",
    active = active,
    temperature = temp,
    fuel = fuel,
    waste = waste,
    energy = energy,
    control_rod_level = rods,
    methods = methods
  }
end

function reactor.apply_rod_level(name, level)
  if not name or level == nil then return nil, "missing data" end
  return utils.safe_peripheral_call(name, "setAllControlRodLevels", level)
end

function reactor.set_active(name, enabled)
  if not name then return nil, "missing peripheral" end
  if enabled then
    return utils.safe_peripheral_call(name, "setActive", true)
  end
  return utils.safe_peripheral_call(name, "setActive", false)
end

return reactor
