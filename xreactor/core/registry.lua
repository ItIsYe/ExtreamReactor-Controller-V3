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

local function persisted_entry(entry)
  local out = sanitize_entry(entry)
  out.last_seen = nil
  out.last_error_ts = nil
  return out
end

local function build_persisted_snapshot(data)
  local snapshot = {
    schema_version = data.schema_version or SCHEMA_VERSION,
    devices = {},
    order = data.order or {},
    name_index = {},
    load_error = data.load_error,
    load_error_ts = data.load_error_ts
  }
  for id, entry in pairs(data.devices or {}) do
    local sanitized = persisted_entry(entry)
    snapshot.devices[id] = sanitized
    if sanitized.name then
      snapshot.name_index[sanitized.name] = id
    end
  end
  return snapshot
end

local function save_registry(path, data)
  local snapshot = build_persisted_snapshot(data)
  utils.write_config(path, snapshot)
  return snapshot
end

function registry.new(opts)
  local self = {}
  self.node_id = opts.node_id or "UNKNOWN"
  local role = opts.role or "node"
  self.path = opts.path or ("/xreactor/config/registry_" .. tostring(role) .. "_" .. tostring(self.node_id) .. ".json")
  self.log_prefix = opts.log_prefix or "REGISTRY"
  self.aliases = opts.aliases or {}
  self.state = load_registry(self.path)
  self._last_saved = textutils.serialize(build_persisted_snapshot(self.state))
  self._dirty = false
  self._persist_dirty = false
  -- Fix: Datei beim ersten Start anlegen damit CC:Tweaked sie kennt
  -- und spätere write_config()-Aufrufe nicht fehlschlagen.
  if not fs.exists(self.path) then
    local ok_dir = pcall(fs.makeDir, fs.getDir(self.path))
    local f = fs.open(self.path, "w")
    if f then f.write("return {}") f.close() end
  end
  return setmetatable(self, { __index = registry })
end

function registry:save()
  if not self._dirty then
    return false
  end
  if not self._persist_dirty then
    self._dirty = false
    return false
  end
  local snapshot = textutils.serialize(build_persisted_snapshot(self.state))
  if snapshot == self._last_saved then
    self._dirty = false
    self._persist_dirty = false
    return false
  end
  save_registry(self.path, self.state)
  self._last_saved = snapshot
  self._dirty = false
  self._persist_dirty = false
  return true
end

function registry:register(name, info)
  local type_name = info.type or peripheral.getType(name) or "unknown"
  local signature = info.signature
  if not signature then
    signature = build_signature(type_name, info.methods or {})
  end
  local id = self.state.name_index[name]
  local entry = id and self.state.devices[id] or nil
  local changed = false
  local persist_changed = false
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
    changed = true
    persist_changed = true
  end
  if entry.name ~= name then entry.name = name changed = true persist_changed = true end
  if entry.type ~= type_name then entry.type = type_name changed = true persist_changed = true end
  if entry.signature ~= signature then entry.signature = signature changed = true persist_changed = true end
  entry.last_seen = now()
  if entry.kind ~= info.kind then entry.kind = info.kind changed = true persist_changed = true end
  local alias = info.alias or self.aliases[name]
  if alias and entry.alias ~= alias then entry.alias = alias changed = true persist_changed = true end
  if info.found ~= nil then
    if entry.found ~= info.found then entry.found = info.found changed = true persist_changed = true end
  end
  if info.bound ~= nil then
    if entry.bound ~= info.bound then entry.bound = info.bound changed = true persist_changed = true end
  end
  if info.features then
    local features = sanitize_value(info.features, 0)
    if textutils.serialize(entry.features or {}) ~= textutils.serialize(features or {}) then
      entry.features = features
      changed = true
      persist_changed = true
    end
  end
  if info.schema then
    local schema = sanitize_value(info.schema, 0)
    if textutils.serialize(entry.schema or {}) ~= textutils.serialize(schema or {}) then
      entry.schema = schema
      changed = true
      persist_changed = true
    end
  end
  if info.status and entry.status ~= info.status then entry.status = info.status changed = true persist_changed = true end
  if info.last_error then
    if entry.last_error ~= info.last_error then
      entry.last_error = info.last_error
      entry.last_error_ts = now()
      changed = true
      persist_changed = true
    end
  end
  self._dirty = self._dirty or changed
  self._persist_dirty = self._persist_dirty or persist_changed
  return entry, changed
end

function registry:sync(devices)
  local seen = {}
  local changed = false
  local persist_changed = false
  for _, device in ipairs(devices or {}) do
    local entry, entry_changed = self:register(device.name, device)
    if entry.found ~= true then entry.found = true changed = true persist_changed = true end
    if entry.bound ~= (device.bound == true) then entry.bound = device.bound == true changed = true persist_changed = true end
    if entry.missing ~= false then entry.missing = false changed = true persist_changed = true end
    seen[entry.id] = true
    changed = changed or entry_changed
  end
  for id, entry in pairs(self.state.devices) do
    if not seen[id] then
      if entry.missing ~= true then entry.missing = true changed = true persist_changed = true end
      if entry.found ~= false then entry.found = false changed = true persist_changed = true end
      if entry.bound ~= false then entry.bound = false changed = true persist_changed = true end
    else
      if entry.missing ~= false then entry.missing = false changed = true persist_changed = true end
    end
  end
  self.state.last_scan = now()
  self._dirty = self._dirty or changed
  self._persist_dirty = self._persist_dirty or persist_changed
  self:save()
end

function registry:update_status(id, status, reason)
  local entry = self.state.devices[id]
  if not entry then return end
  local changed = false
  local persist_changed = false
  if entry.status ~= status then
    entry.status = status
    changed = true
    persist_changed = true
  end
  if reason and entry.last_error ~= reason then
    entry.last_error = reason
    entry.last_error_ts = now()
    changed = true
    persist_changed = true
  end
  self._dirty = self._dirty or changed
  self._persist_dirty = self._persist_dirty or persist_changed
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
  if entry.alias == alias then
    return entry
  end
  entry.alias = alias
  self._dirty = true
  self._persist_dirty = true
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
