local utils = require("core.utils")

local registry = {}

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

local function load_registry(path)
  if not fs.exists(path) then
    return { devices = {}, order = {}, name_index = {} }
  end
  local content = utils.read_config(path, {})
  if type(content) ~= "table" then
    return { devices = {}, order = {}, name_index = {} }
  end
  content.devices = type(content.devices) == "table" and content.devices or {}
  content.order = type(content.order) == "table" and content.order or {}
  content.name_index = type(content.name_index) == "table" and content.name_index or {}
  return content
end

local function save_registry(path, data)
  utils.write_config(path, data)
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
  entry.last_seen = os.epoch("utc")
  entry.kind = info.kind
  local alias = info.alias or self.aliases[name]
  if alias then entry.alias = alias end
  if info.found ~= nil then
    entry.found = info.found
  end
  if info.bound ~= nil then
    entry.bound = info.bound
  end
  if info.status then entry.status = info.status end
  if info.last_error then
    entry.last_error = info.last_error
    entry.last_error_ts = os.epoch("utc")
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
  self:save()
end

function registry:update_status(id, status, reason)
  local entry = self.state.devices[id]
  if not entry then return end
  entry.status = status
  if reason then
    entry.last_error = reason
    entry.last_error_ts = os.epoch("utc")
  end
  self:save()
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
