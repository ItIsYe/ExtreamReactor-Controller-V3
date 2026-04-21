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
  if type(list) ~= "table" then
    return out
  end
  for _, value in ipairs(list) do
    out[value] = true
  end
  for key, value in pairs(list) do
    if type(key) == "string" and value ~= nil and value ~= false then
      out[key] = true
    end
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

local function table_count(tbl)
  local dense = #tbl
  local keyed = 0
  for _ in pairs(tbl) do
    keyed = keyed + 1
  end
  if keyed > dense then
    return keyed
  end
  return dense
end

local function normalize_component_count(value)
  local value_type = type(value)
  if value_type == "number" then
    return math.floor(value)
  end
  if value_type == "string" then
    local parsed = tonumber(value)
    if parsed ~= nil then
      return math.floor(parsed)
    end
    return nil
  end
  if value_type == "table" then
    local nested_keys = { "value", "values", "result", "results", "data", "items", "entries", "components", "installed" }
    for _, key in ipairs(nested_keys) do
      local nested = value[key]
      if nested ~= nil then
        local parsed_nested = normalize_component_count(nested)
        if parsed_nested ~= nil then
          return parsed_nested
        end
      end
    end
    local preferred_keys = { "count", "size", "length", "total", "installed" }
    for _, key in ipairs(preferred_keys) do
      local raw = value[key]
      if raw ~= nil then
        local parsed = normalize_component_count(raw)
        if parsed ~= nil then
          return parsed
        end
      end
    end
    return table_count(value)
  end
  return nil
end

local function describe_value(value)
  local value_type = type(value)
  if value_type == "string" then
    return value
  end
  if value_type == "number" or value_type == "boolean" then
    return tostring(value)
  end
  if value_type == "nil" then
    return "nil"
  end
  if value_type == "table" then
    local ok, serialized = pcall(textutils.serialize, value)
    if ok and type(serialized) == "string" then
      if #serialized > 120 then
        return serialized:sub(1, 117) .. "..."
      end
      return serialized
    end
  end
  return "<" .. value_type .. ">"
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

local function normalize_matrix_group_hint(value)
  if value == nil then
    return nil
  end
  if type(value) == "number" then
    return tostring(math.floor(value))
  end
  if type(value) == "string" then
    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed and trimmed ~= "" then
      return trimmed
    end
    return nil
  end
  if type(value) == "table" then
    local preferred = {
      "id",
      "uuid",
      "matrixId",
      "multiblockId",
      "controller",
      "controllerPos",
      "controllerPosition",
      "position",
      "x",
      "y",
      "z"
    }
    for _, key in ipairs(preferred) do
      local parsed = normalize_matrix_group_hint(value[key])
      if parsed ~= nil then
        return parsed
      end
    end
    local ok, serialized = pcall(textutils.serialize, value)
    if ok and type(serialized) == "string" and serialized ~= "" then
      return serialized
    end
  end
  return nil
end

local function infer_name_group_key(name)
  local string_name = tostring(name or "")
  local prefix = string_name:match("^(.+)_%d+$")
  if prefix and prefix ~= "" then
    return "name_prefix:" .. prefix
  end
  return "name_exact:" .. string_name
end

local function normalize_position(value)
  if type(value) ~= "table" then
    return nil
  end
  local x = tonumber(value.x or value[1])
  local y = tonumber(value.y or value[2])
  local z = tonumber(value.z or value[3])
  if x == nil or y == nil or z == nil then
    return nil
  end
  return ("%d,%d,%d"):format(math.floor(x), math.floor(y), math.floor(z))
end

local function normalize_bounds(value)
  if type(value) ~= "table" then
    return nil
  end
  local min = value.min or value.minimum or value.from or value.low
  local max = value.max or value.maximum or value.to or value.high
  local min_norm = normalize_position(min)
  local max_norm = normalize_position(max)
  if min_norm and max_norm then
    return "min=" .. min_norm .. "|max=" .. max_norm
  end
  return nil
end

function matrix.build_group_key(name, methods, call_fn)
  local method_set = to_set(methods)
  local string_name = tostring(name or "")
  local id_methods = {
    "getMatrixId",
    "getMultiblockId",
    "getMultiblockID",
    "getMatrixUUID",
    "getMatrixUuid",
    "getControllerPos",
    "getControllerPosition",
    "getController"
  }
  for _, method in ipairs(id_methods) do
    if method_set[method] and type(call_fn) == "function" then
      local ok, value = pcall(call_fn, method)
      if ok then
        local normalized = normalize_matrix_group_hint(value)
        if normalized ~= nil then
          return "matrix_id:" .. normalized, "api:" .. method
        end
      end
    end
  end

  local bounds_pairs = {
    { min = "getMinPos", max = "getMaxPos" },
    { min = "getMinimumPos", max = "getMaximumPos" }
  }
  for _, pair in ipairs(bounds_pairs) do
    if method_set[pair.min] and method_set[pair.max] and type(call_fn) == "function" then
      local min_ok, min_value = pcall(call_fn, pair.min)
      local max_ok, max_value = pcall(call_fn, pair.max)
      if min_ok and max_ok then
        local min_norm = normalize_position(min_value)
        local max_norm = normalize_position(max_value)
        if min_norm ~= nil and max_norm ~= nil then
          return "matrix_bounds:min=" .. min_norm .. "|max=" .. max_norm, "api:" .. pair.min .. "+" .. pair.max
        end
      end
    end
  end

  local bounds_methods = { "getBounds", "getBoundaries" }
  for _, method in ipairs(bounds_methods) do
    if method_set[method] and type(call_fn) == "function" then
      local ok, value = pcall(call_fn, method)
      if ok then
        local normalized = normalize_bounds(value)
        if normalized ~= nil then
          return "matrix_bounds:" .. normalized, "api:" .. method
        end
      end
    end
  end

  -- IMPORTANT:
  -- A name prefix heuristic (for example inductionPort_*) is not a reliable
  -- topology signal. Multiple physically separate matrices frequently share
  -- the same peripheral prefix and would then be collapsed into one logical
  -- matrix, which corrupts telemetry aggregation. If no stable matrix identity
  -- API signal is available, keep ports separated per peripheral name.
  return "peripheral_name:" .. string_name, "peripheral_name_fallback"
end

function matrix.group_ports(entries)
  local groups = {}
  local order = {}
  for _, entry in ipairs(entries or {}) do
    local adapter = entry and entry.adapter or entry
    if adapter and adapter.name then
      local group_key = adapter.group_key or infer_name_group_key(adapter.name)
      local group = groups[group_key]
      if not group then
        group = {
          key = group_key,
          key_source = adapter.group_key_source,
          ports = {},
          representative = nil
        }
        groups[group_key] = group
        order[#order + 1] = group_key
      end
      group.ports[#group.ports + 1] = {
        id = entry and entry.id or adapter.name,
        alias = entry and entry.alias or nil,
        name = adapter.name,
        adapter = adapter
      }
      local current = group.representative
      if current == nil or tostring(adapter.name) < tostring(current.name) then
        group.representative = {
          id = entry and entry.id or adapter.name,
          alias = entry and entry.alias or nil,
          name = adapter.name,
          adapter = adapter
        }
      end
    end
  end
  local out = {}
  for _, key in ipairs(order) do
    local group = groups[key]
    table.sort(group.ports, function(a, b)
      return tostring(a.name) < tostring(b.name)
    end)
    out[#out + 1] = group
  end
  table.sort(out, function(a, b)
    return tostring(a.key) < tostring(b.key)
  end)
  return out
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
  local group_key, group_key_source = matrix.build_group_key(name, methods, function(method)
    if not peripheral.isPresent(name) then
      return nil
    end
    return peripheral.call(name, method)
  end)

  local function safe_component_call(method)
    if not method then
      return nil, "missing_method"
    end
    if not peripheral.isPresent(name) then
      return nil, "call_failed:peripheral missing"
    end
    local packed = table.pack(pcall(peripheral.call, name, method))
    if not packed[1] then
      return nil, "call_failed:" .. tostring(packed[2])
    end
    local results = {}
    for i = 2, packed.n do
      results[#results + 1] = packed[i]
    end
    if #results == 0 then
      return nil, "nil_value:no_return"
    end
    if type(results[1]) == "boolean" then
      local success = results[1]
      if success == false then
        return nil, "call_failed:" .. tostring(results[2])
      end
      table.remove(results, 1)
    end
    if #results == 0 then
      return nil, "nil_value:empty_payload"
    end
    for _, candidate in ipairs(results) do
      local count = normalize_component_count(candidate)
      if count ~= nil then
        if count < 0 then
          return 0
        end
        return count
      end
    end
    if results[1] == nil then
      if results[2] ~= nil then
        return nil, "nil_value:" .. describe_value(results[2])
      end
      return nil, "nil_value"
    end
    local type_summary = {}
    for i, candidate in ipairs(results) do
      type_summary[#type_summary + 1] = tostring(i) .. "=" .. type(candidate)
    end
    return nil, "unsupported_value:" .. table.concat(type_summary, ",") .. ":" .. describe_value(results[1])
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
      return safe_component_call(get_cells)
    end,
    getProviders = function()
      return safe_component_call(get_providers)
    end,
    getPorts = function()
      return safe_component_call(get_ports)
    end,
    getSnapshot = function()
      local stored = storage_adapter and storage_adapter.getStored and storage_adapter.getStored()
      local capacity = storage_adapter and storage_adapter.getCapacity and storage_adapter.getCapacity()
      local input = storage_adapter and storage_adapter.getInput and storage_adapter.getInput()
      local output = storage_adapter and storage_adapter.getOutput and storage_adapter.getOutput()
      local cells = safe_component_call(get_cells)
      local providers = safe_component_call(get_providers)
      local ports = safe_component_call(get_ports)
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
    group_key = group_key,
    group_key_source = group_key_source,
    getType = function()
      return type_name
    end,
    isValid = function()
      return peripheral.isPresent(name)
    end,
    getMethodList = function()
      return methods
    end,
    getComponentMethods = function()
      return {
        cells = get_cells,
        providers = get_providers,
        ports = get_ports
      }
    end
  }
end

return matrix
