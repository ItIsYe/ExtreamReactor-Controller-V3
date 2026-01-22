local utils = require("core.utils")
local energy_storage = require("adapters.energy_storage")

local matrix = {}

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
end

local function resolve_component_method(methods, candidates)
  for _, name in ipairs(candidates) do
    if methods[name] then
      return name
    end
  end
  return nil
end

local function is_matrix_method_set(methods)
  local keys = {
    "getInstalledCells",
    "getInstalledProviders",
    "getInstalledPorts",
    "getCells",
    "getProviders",
    "getPorts",
    "getInductionCells",
    "getInductionProviders",
    "getInductionPorts"
  }
  for _, key in ipairs(keys) do
    if methods[key] then
      return true
    end
  end
  return false
end

function matrix.detect(name)
  if not name or not peripheral.isPresent(name) then
    return nil
  end
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    return nil
  end
  local method_set = to_set(methods)
  if not is_matrix_method_set(method_set) then
    return nil
  end
  local storage_adapter = energy_storage.detect(name)
  local type_name = peripheral.getType(name) or "induction_matrix"
  local get_cells = resolve_component_method(method_set, {
    "getInstalledCells",
    "getCells",
    "getInductionCells"
  })
  local get_providers = resolve_component_method(method_set, {
    "getInstalledProviders",
    "getProviders",
    "getInductionProviders"
  })
  local get_ports = resolve_component_method(method_set, {
    "getInstalledPorts",
    "getPorts",
    "getInductionPorts"
  })

  local function safe_call(method)
    if not method then
      return nil
    end
    return utils.safe_peripheral_call(name, method)
  end

  return {
    name = name,
    type = type_name,
    getStored = storage_adapter and storage_adapter.getStored or function() return nil end,
    getCapacity = storage_adapter and storage_adapter.getCapacity or function() return nil end,
    getInput = storage_adapter and storage_adapter.getInput or function() return nil end,
    getOutput = storage_adapter and storage_adapter.getOutput or function() return nil end,
    getCells = function()
      return safe_call(get_cells)
    end,
    getProviders = function()
      return safe_call(get_providers)
    end,
    getPorts = function()
      return safe_call(get_ports)
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

return matrix
