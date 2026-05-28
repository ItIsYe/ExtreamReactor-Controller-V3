-- CONFIG
local CONFIG = {
  LOGGER_DEFAULT_PREFIX = "LOG", -- Fallback prefix when none is provided.
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Default node_id storage path.
  LOG_NAME_SEPARATOR = "_", -- Separator for log file names.
  DEFAULT_LOG_DIR = "/disk/xreactor_logs" -- Preferred runtime log directory; logger falls back locally if unavailable.
}

-- Utility helpers shared across nodes.
local utils = {}

local logger = require("core.logger")

local function read_file(path)
  if not path or not fs.exists(path) then
    return nil
  end
  local file = fs.open(path, "r")
  if not file then
    return nil
  end
  local content = file.readAll()
  file.close()
  return content
end

local function sanitize_snapshot(value, active)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" or value_type == "nil" then
    return value
  end
  if value_type ~= "table" then
    return tostring(value)
  end
  active = active or {}
  if active[value] then
    return "<cycle>"
  end
  active[value] = true
  local out = {}
  for key, val in next, value do
    local key_type = type(key)
    if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then
      key = tostring(key)
    end
    out[key] = sanitize_snapshot(val, active)
  end
  active[value] = nil
  return out
end

local function safe_serialize(value)
  if not textutils or not textutils.serialize then
    return nil, "serialize unavailable"
  end
  local sanitized = sanitize_snapshot(value)
  local ok, result = pcall(textutils.serialize, sanitized)
  if not ok then
    return nil, result
  end
  return result
end

function utils.safe_serialize(value)
  return safe_serialize(value)
end

function utils.ensure_dir(path)
  if not path or path == "" then
    return
  end
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

function utils.read_config(path, defaults)
  if not fs.exists(path) then
    return defaults or {}
  end
  local file = fs.open(path, "r")
  if not file then
    return defaults or {}
  end
  local content = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return defaults or {}
end

function utils.deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[utils.deep_copy(key, seen)] = utils.deep_copy(item, seen)
  end
  return copy
end

function utils.merge_defaults(target, defaults)
  local changed = false
  for key, value in pairs(defaults or {}) do
    if target[key] == nil then
      target[key] = value
      changed = true
    elseif type(target[key]) == "table" and type(value) == "table" then
      local inner_changed = utils.merge_defaults(target[key], value)
      changed = changed or inner_changed
    end
  end
  return changed
end

local function migrate_config(path, data, defaults, meta)
  if type(defaults) ~= "table" then
    return data
  end
  local target_version = type(defaults.version) == "number" and defaults.version or nil
  if not target_version then
    return data
  end
  local original = utils.deep_copy(data)
  local changed = utils.merge_defaults(data, defaults)
  local loaded_version = type(data.version) == "number" and data.version or 1
  if data.version == nil or loaded_version < target_version then
    data.version = target_version
    changed = true
  end
  if not changed then
    return data
  end
  local ok, err = pcall(utils.write_config, path, data)
  if ok then
    meta.migrated = true
    return data
  end
  meta.migration_error = err
  utils.log("CONFIG", "Config migration failed at " .. tostring(path) .. "; using existing config.", "WARN")
  return original
end

function utils.load_config(path, defaults)
  local meta = { path = path, source = "defaults" }
  local fallback = utils.deep_copy(defaults or {})
  if not path then
    meta.reason = "missing path"
    return fallback, meta
  end
  if not fs.exists(path) then
    meta.reason = "missing"
    return fallback, meta
  end
  local content = read_file(path)
  if not content then
    meta.reason = "unreadable"
    return fallback, meta
  end
  local loader, err = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      local migrated = migrate_config(path, data, defaults, meta)
      if migrated == data and type(defaults) == "table" and type(defaults.version) ~= "number" then
        utils.merge_defaults(data, defaults)
      end
      meta.source = "lua"
      return migrated, meta
    end
    if not ok then
      err = data
    end
  end
  if textutils and textutils.unserialize then
    local ok, data = pcall(textutils.unserialize, content)
    if ok and type(data) == "table" then
      local migrated = migrate_config(path, data, defaults, meta)
      if migrated == data and type(defaults) == "table" and type(defaults.version) ~= "number" then
        utils.merge_defaults(data, defaults)
      end
      meta.source = "serialized"
      meta.reason = "lua invalid"
      return migrated, meta
    end
  end
  meta.reason = err or "invalid"
  return fallback, meta
end

function utils.write_config(path, tbl)
  utils.ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if not file then
    error("Unable to write config at " .. path)
  end
  local serialized, err = safe_serialize(tbl)
  if not serialized then
    error("Config serialize failed: " .. tostring(err))
  end
  file.write(serialized)
  file.close()
end

-- Initialize file logging for the current runtime.
function utils.init_logger(opts)
  opts = opts or {}
  if opts.log_dir == nil then
    local with_default = {}
    for k, v in pairs(opts) do with_default[k] = v end
    with_default.log_dir = CONFIG.DEFAULT_LOG_DIR
    opts = with_default
  end
  return logger.init(opts)
end

-- Log a message using the shared logger (no terminal spam).
function utils.log(prefix, message, level)
  local ok = pcall(logger.log, prefix or CONFIG.LOGGER_DEFAULT_PREFIX, message, level)
  if not ok then
    pcall(print, "WARN: logging suppressed due to non-fatal logger failure")
  end
end

function utils.safe_peripheral_call(name, method, ...)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local results = table.pack(pcall(peripheral.call, name, method, ...))
  if not results[1] then
    return nil, results[2]
  end
  if results.n == 1 then
    return true
  end
  return table.unpack(results, 2, results.n)
end

function utils.safe_wrap(name)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local ok, wrapped = pcall(peripheral.wrap, name)
  if not ok then
    return nil, wrapped
  end
  return wrapped
end

function utils.safe_get_methods(name)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok then
    return nil, methods
  end
  if type(methods) ~= "table" then
    return nil, "invalid methods"
  end
  return methods
end

function utils.cache_peripherals(names)
  local cache = {}
  for _, name in ipairs(names or {}) do
    local wrapped = utils.safe_wrap(name)
    if wrapped then
      cache[name] = wrapped
    end
  end
  return cache
end

function utils.merge(a, b)
  local merged = {}
  for k, v in pairs(a or {}) do merged[k] = v end
  for k, v in pairs(b or {}) do merged[k] = v end
  return merged
end

function utils.trim(text)
  if not text then return "" end
  return text:match("^%s*(.-)%s*$")
end

function utils.read_node_id(path)
  local target = path or CONFIG.NODE_ID_PATH
  if not target or not fs.exists(target) then
    return nil
  end
  local file = fs.open(target, "r")
  if not file then
    return nil
  end
  local content = file.readAll()
  file.close()
  local trimmed = utils.trim(content)
  if trimmed == "" then
    return nil
  end
  return trimmed
end

function utils.build_log_name(base, node_id)
  local name = tostring(base or "xreactor")
  if node_id and node_id ~= "" then
    return name .. CONFIG.LOG_NAME_SEPARATOR .. tostring(node_id)
  end
  return name
end

function utils.normalize_node_id(value)
  local value_type = type(value)
  if value_type == "string" then
    return value
  end
  if value_type == "number" then
    return tostring(value)
  end
  if value_type == "table" then
    local candidates = { "node_id", "id", "name", "uuid", "uid" }
    for _, key in ipairs(candidates) do
      local candidate = value[key]
      if type(candidate) == "string" or type(candidate) == "number" then
        return tostring(candidate)
      end
    end
  end
  return "UNKNOWN"
end

return utils
