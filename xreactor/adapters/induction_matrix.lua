local utils = require("core.utils")
local energy_storage = require("adapters.energy_storage")

local matrix = {}
local warned = {}

local function log_once(prefix, key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  utils.log(prefix or "MATRIX", message, "WARN")
end

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

function matrix.detect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    return nil
  end
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    if not ok then
      log_once(log_prefix, "methods:" .. tostring(name), "Matrix methods failed for " .. tostring(name) .. ": " .. tostring(methods))
    end
    return nil
  end
  local method_set = to_set(methods)
  if not is_matrix_method_set(method_set) then
    return nil
  end
  local storage_adapter = energy_storage.detect(name, log_prefix)
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

  local features = {
    stored = storage_adapter ~= nil,
    capacity = storage_adapter ~= nil,
    input = storage_adapter and storage_adapter.features and storage_adapter.features.input or false,
    output = storage_adapter and storage_adapter.features and storage_adapter.features.output or false,
    cells = get_cells ~= nil,
    providers = get_providers ~= nil,
    ports = get_ports ~= nil
  }

  return {
    name = name,
    type = type_name,
    features = features,
    schema = {
      stored = "number",
      capacity = "number",
      input = "number",
      output = "number",
      cells = "number",
      providers = "number",
      ports = "number"
    },
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
    getSnapshot = function()
      local stored = storage_adapter and storage_adapter.getStored and storage_adapter.getStored()
      local capacity = storage_adapter and storage_adapter.getCapacity and storage_adapter.getCapacity()
      local input = storage_adapter and storage_adapter.getInput and storage_adapter.getInput()
      local output = storage_adapter and storage_adapter.getOutput and storage_adapter.getOutput()
      local cells = safe_call(get_cells)
      local providers = safe_call(get_providers)
      local ports = safe_call(get_ports)
      return {
        stored = stored ~= nil and stored or "n/a",
        capacity = capacity ~= nil and capacity or "n/a",
        input = input ~= nil and input or "n/a",
        output = output ~= nil and output or "n/a",
        cells = cells ~= nil and cells or "n/a",
        providers = providers ~= nil and providers or "n/a",
        ports = ports ~= nil and ports or "n/a"
      }
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
