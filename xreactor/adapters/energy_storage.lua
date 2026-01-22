local utils = require("core.utils")

local energy_storage = {}

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
end

local function resolve_profile(methods)
  if methods.getEnergy and methods.getMaxEnergy then
    return { stored = "getEnergy", capacity = "getMaxEnergy", input = "getLastInput", output = "getLastOutput" }
  end
  if methods.getEnergyStored and methods.getMaxEnergyStored then
    return { stored = "getEnergyStored", capacity = "getMaxEnergyStored" }
  end
  if methods.getStoredPower and methods.getMaxStoredPower then
    return { stored = "getStoredPower", capacity = "getMaxStoredPower" }
  end
  return nil
end

local function safe_call(name, method)
  if not method then
    return nil
  end
  return utils.safe_peripheral_call(name, method)
end

function energy_storage.detect(name)
  if not name or not peripheral.isPresent(name) then
    return nil
  end
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    return nil
  end
  local method_set = to_set(methods)
  local profile = resolve_profile(method_set)
  if not profile then
    return nil
  end
  local type_name = peripheral.getType(name) or "unknown"
  return {
    name = name,
    type = type_name,
    profile = profile,
    getStored = function()
      return safe_call(name, profile.stored)
    end,
    getCapacity = function()
      return safe_call(name, profile.capacity)
    end,
    getInput = function()
      return safe_call(name, profile.input)
    end,
    getOutput = function()
      return safe_call(name, profile.output)
    end,
    getName = function()
      return name
    end,
    getType = function()
      return type_name
    end,
    isValid = function()
      return peripheral.isPresent(name)
    end,
    getMethodList = function()
      return methods
    end
  }
end

return energy_storage
