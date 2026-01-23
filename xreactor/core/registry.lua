local utils = require("core.utils")

local registry = {}

local SCHEMA_VERSION = 2

local function djb2_hash(text)
  local hash = 5381
  for i = 1, #text do
    hash = bit32.band(bit32.bxor(bit32.lshift(hash, 5) + hash, text:byte(i)), 0xffffffff)
  end
  return string.format("%08x", hash)
end

local function normalize_list(value)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

local function build_signature(type_name, methods)
  local list = normalize_list(methods)
  table.sort(list)
  return type_name .. ":" .. table.concat(list, ",")
end

local function build_device_id(name, type_name, signature)
  local seed = string.format("%s|%s|%s", tostring(name), tostring(type_name), tostring(signature or ""))
  return string.format("%s-%s", tostring(type_name):upper(), djb2_hash(seed))
end

local function now()
  return os.epoch("utc")
end

local function sanitize_value(value, depth, seen)
  depth = depth or 0
  if depth > 5 then
    return nil
  end
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return value
  end
  if value_type ~= "table" then
    return nil
  end
  seen = seen or {}
  if seen[value] then
    return nil
  end
  seen[value] = true
  local out = {}
  for key, val in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      local sanitized = sanitize_value(val, depth + 1, seen)
      if sanitized ~= nil then
        out[key] = sanitized
      end
    end
  end
  seen[value] = nil
  return out
end

local function default_state()
  return { schema_version = SCHEMA_VERSION, devices = {}, order = {}, name_index = {}, load_error = nil, load_error_ts = nil, last_scan = nil }
end

local function rebuild_indexes(state)
  state.devices = type(state.devices) == "table" and state.devices or {}
  state.order = type(state.order) == "table" and state.order or {}
  state.name_index = type(state.name_index) == "table" and state.name_index or {}
  if #state.order == 0 then
    for id in pairs(state.devices) do
      table.insert(state.order, id)
    end
    table.sort(state.order)
  end
  for id, entry in pairs(state.devices) do
    if entry.name then
      state.name_index[entry.name] = id
    end
    entry.id = entry.id or id
  end
end

local function migrate_state(state)
  if type(state.schema_version) ~= "number" then
    state.schema_version = 1
  end
  if state.schema_version < SCHEMA_VERSION then
    rebuild_indexes(state)
    state.schema_version = SCHEMA_VERSION
  end
end

local function load_registry(path)
  if not fs.exists(path) then
    return default_state()
  end
  local file = fs.open(path, "r")
  if not file then
    local state = default_state()
    state.load_error = "unreadable"
    state.load_error_ts = now()
    return state
  end
  local content = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, content)
  if not ok or type(data) ~= "table" then
    local broken_path = path .. ".broken_" .. tostring(now())
    pcall(fs.move, path, broken_path)
    local state = default_state()
    state.load_error = "corrupt"
    state.load_error_ts = now()
    return state
  end
  migrate_state(data)
  rebuild_indexes(data)
  return data
end

local function sanitize_entry(entry)
  local out = {}
  out.id = entry.id
  out.name = entry.name
  out.type = entry.type
  out.signature = entry.signature
  out.kind = entry.kind
  out.alias = entry.alias
  out.first_seen = entry.first_seen
  out.last_seen = entry.last_seen
  out.last_error = entry.last_error
  out.last_error_ts = entry.last_error_ts
  out.found = entry.found
  out.bound = entry.bound
  out.missing = entry.missing
  out.status = entry.status
  out.features = sanitize_value(entry.features or {}, 0)
  out.schema = sanitize_value(entry.schema or {}, 0)
  return out
end

local function save_registry(path, data)
  local snapshot = {
    schema_version = data.schema_version or SCHEMA_VERSION,
    devices = {},
    order = data.order or {},
    name_index = {},
    load_error = data.load_error,
    load_error_ts = data.load_error_ts,
    last_scan = data.last_scan
  }
  for id, entry in pairs(data.devices or {}) do
    local sanitized = sanitize_entry(entry)
    snapshot.devices[id] = sanitized
    if sanitized.name then
      snapshot.name_index[sanitized.name] = id
    end
  end
  utils.write_config(path, snapshot)
end

function registry.new(opts)
  local self = {}
  self.node_id = opts.node_id or "UNKNOWN"
  local role = opts.role or "node"
  self.path = opts.path or ("/xreactor/config/registry_" .. tostring(role) .. "_" .. tostring(self.node_id) .. ".json")
  self.log_prefix = opts.log_prefix or "REGISTRY"
  self.aliases = opts.aliases or {}
  self.state = load_registry(self.path)
  return setmetatable(self, { __index = registry })
end

function registry:save()
  save_registry(self.path, self.state)
end

function registry:register(name, info)
  local type_name = info.type or peripheral.getType(name) or "unknown"
  local signature = info.signature
  if not signature then
    signature = build_signature(type_name, info.methods or {})
  end
  local id = self.state.name_index[name]
  local entry = id and self.state.devices[id] or nil
  if not entry then
    id = build_device_id(name, type_name, signature)
    local suffix = 1
    while self.state.devices[id] do
      suffix = suffix + 1
      id = build_device_id(name, type_name, signature .. ":" .. suffix)
    end
    entry = {
      id = id,
      name = name,
      type = type_name,
      signature = signature,
      first_seen = os.epoch("utc"),
      last_error = nil,
      last_error_ts = nil
    }
    table.insert(self.state.order, id)
    self.state.devices[id] = entry
    self.state.name_index[name] = id
  end
  entry.name = name
  entry.type = type_name
  entry.signature = signature
  entry.last_seen = now()
  entry.kind = info.kind
  local alias = info.alias or self.aliases[name]
  if alias then entry.alias = alias end
  if info.found ~= nil then
    entry.found = info.found
  end
  if info.bound ~= nil then
    entry.bound = info.bound
  end
  if info.features then
    entry.features = sanitize_value(info.features, 0)
  end
  if info.schema then
    entry.schema = sanitize_value(info.schema, 0)
  end
  if info.status then entry.status = info.status end
  if info.last_error then
    entry.last_error = info.last_error
    entry.last_error_ts = now()
  end
  return entry
end

function registry:sync(devices)
  local seen = {}
  for _, device in ipairs(devices or {}) do
    local entry = self:register(device.name, device)
    entry.found = true
    entry.bound = device.bound == true
    entry.missing = false
    seen[entry.id] = true
  end
  for id, entry in pairs(self.state.devices) do
    if not seen[id] then
      entry.missing = true
      entry.found = false
      entry.bound = false
    else
      entry.missing = false
    end
  end
  self.state.last_scan = now()
  self:save()
end

function registry:update_status(id, status, reason)
  local entry = self.state.devices[id]
  if not entry then return end
  entry.status = status
  if reason then
    entry.last_error = reason
    entry.last_error_ts = now()
  end
  self:save()
end

function registry:get_devices_by_kind(kind)
  return self:list(kind)
end

function registry:get_bound_devices(kind)
  local out = {}
  for _, entry in ipairs(self:list(kind)) do
    local bound = entry.bound
    if bound == nil then
      bound = not entry.missing
    end
    if bound then
      table.insert(out, entry)
    end
  end
  return out
end

function registry:get_summary()
  local summary = { total = 0, bound = 0, missing = 0, kinds = {} }
  for _, entry in ipairs(self:list()) do
    summary.total = summary.total + 1
    if entry.missing then
      summary.missing = summary.missing + 1
    end
    local bound = entry.bound
    if bound == nil then
      bound = not entry.missing
    end
    if bound then
      summary.bound = summary.bound + 1
    end
    local kind = entry.kind or "unknown"
    summary.kinds[kind] = summary.kinds[kind] or { total = 0, bound = 0, missing = 0 }
    summary.kinds[kind].total = summary.kinds[kind].total + 1
    if entry.missing then
      summary.kinds[kind].missing = summary.kinds[kind].missing + 1
    end
    if bound then
      summary.kinds[kind].bound = summary.kinds[kind].bound + 1
    end
  end
  return summary
end

function registry:set_alias(device_id, alias)
  local entry = self.state.devices[device_id]
  if not entry then return nil, "unknown device" end
  entry.alias = alias
  self:save()
  return entry
end

function registry:get_diagnostics()
  return {
    load_error = self.state.load_error,
    load_error_ts = self.state.load_error_ts,
    last_scan = self.state.last_scan,
    summary = self:get_summary()
  }
end

function registry:get_order_index()
  local order = {}
  for idx, id in ipairs(self.state.order or {}) do
    order[id] = idx
  end
  return order
end

function registry:list(kind)
  local out = {}
  local order = self.state.order or {}
  for _, id in ipairs(order) do
    local entry = self.state.devices[id]
    if entry and (not kind or entry.kind == kind) then
      table.insert(out, entry)
    end
  end
  return out
end

return registry
