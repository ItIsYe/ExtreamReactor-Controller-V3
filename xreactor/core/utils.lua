-- CONFIG
local CONFIG = {
  LOGGER_DEFAULT_PREFIX = "LOG" -- Fallback prefix when none is provided.
}

-- Utility helpers shared across nodes.
local utils = {}

local logger = require("core.logger")

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
  local sanitized = sanitize_snapshot(value)
  local ok, result = pcall(textutils.serialize, sanitized)
  if not ok then
    return nil, result
  end
  return result
end

function utils.ensure_dir(path)
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
  logger.init(opts)
end

-- Log a message using the shared logger (no terminal spam).
function utils.log(prefix, message, level)
  logger.log(prefix or CONFIG.LOGGER_DEFAULT_PREFIX, message, level)
end

function utils.safe_peripheral_call(name, method, ...)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local ok, result = pcall(peripheral.call, name, method, ...)
  if not ok then
    return nil, result
  end
  return result
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

function utils.cache_peripherals(names)
  local cache = {}
  for _, name in ipairs(names) do
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
