-- CONFIG
local CONFIG = {
  LOGGER_DEFAULT_PREFIX = "LOG",
  NODE_ID_PATH = "/xreactor/config/node_id.txt",
  ROLE_CONFIG_PATH = "/xreactor/config/role.lua",
  LOG_NAME_SEPARATOR = "_",
  DEFAULT_LOG_DIR = "/disk/xreactor_logs",
  REMOTE_LOG_CHANNEL = 6502
}

local utils = {}

local logger = require("core.logger")

local remote_log_state = {
  initialized = false,
  enabled = true,
  modems = {},
  modem_names = {},
  node_id = nil,
  role = nil,
  sent = 0,
  dropped = 0
}

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

local function trim_text(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function read_role_config_value()
  local content = read_file(CONFIG.ROLE_CONFIG_PATH)
  if not content then return "UNKNOWN" end
  local loader = load(content, "=role", "t", {})
  if not loader then return "UNKNOWN" end
  local ok, result = pcall(loader)
  if ok and type(result) == "table" and type(result.role) == "string" then
    return result.role
  end
  return "UNKNOWN"
end

local function resolve_node_id()
  local value = trim_text(read_file(CONFIG.NODE_ID_PATH) or "")
  if value ~= "" then return value end
  if os and type(os.getComputerID) == "function" then
    return "pc-" .. tostring(os.getComputerID())
  end
  return "unknown-node"
end

local function discover_log_modems()
  local list = {}
  if not peripheral or type(peripheral.getNames) ~= "function" then return list end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return list end
  table.sort(names)
  local wired = {}
  local wireless = {}
  for _, name in ipairs(names) do
    local type_ok, ptype = pcall(peripheral.getType, name)
    if type_ok and ptype == "modem" then
      local wrap_ok, modem = pcall(peripheral.wrap, name)
      if wrap_ok and modem and type(modem.transmit) == "function" then
        local is_wireless = false
        if type(modem.isWireless) == "function" then
          local wireless_ok, result = pcall(modem.isWireless)
          is_wireless = wireless_ok and result == true
        end
        local entry = { name = name, modem = modem, wireless = is_wireless }
        if is_wireless then wireless[#wireless + 1] = entry else wired[#wired + 1] = entry end
      end
    end
  end
  for _, entry in ipairs(wireless) do list[#list + 1] = entry end
  for _, entry in ipairs(wired) do list[#list + 1] = entry end
  return list
end

local function settings_bool(key, fallback)
  if settings and type(settings.get) == "function" then
    local value = settings.get(key)
    if type(value) == "boolean" then return value end
  end
  return fallback
end

local function init_remote_log(opts)
  opts = opts or {}
  if remote_log_state.initialized then return end
  remote_log_state.enabled = opts.remote_logging
  if remote_log_state.enabled == nil then
    remote_log_state.enabled = settings_bool("xreactor.remote_logging", true)
  end
  remote_log_state.node_id = opts.node_id or resolve_node_id()
  remote_log_state.role = opts.prefix or read_role_config_value()
  remote_log_state.modems = discover_log_modems()
  remote_log_state.modem_names = {}
  for _, entry in ipairs(remote_log_state.modems) do
    remote_log_state.modem_names[#remote_log_state.modem_names + 1] = entry.name
  end
  remote_log_state.initialized = true
end

local function send_remote_log(prefix, level, message)
  local ok = pcall(function()
    if not remote_log_state.initialized then init_remote_log({ prefix = prefix }) end
    if not remote_log_state.enabled or #remote_log_state.modems == 0 then
      remote_log_state.dropped = remote_log_state.dropped + 1
      return
    end
    local payload = {
      type = "LOG_EVENT",
      proto = "xreactor-log-v1",
      node_id = remote_log_state.node_id or resolve_node_id(),
      role = remote_log_state.role or read_role_config_value(),
      prefix = tostring(prefix or "LOG"),
      level = tostring(level or "INFO"),
      message = tostring(message or ""),
      ts = os and os.epoch and os.epoch("utc") or nil
    }
    local delivered = 0
    for _, entry in ipairs(remote_log_state.modems) do
      local sent_ok = pcall(function()
        entry.modem.transmit(CONFIG.REMOTE_LOG_CHANNEL, CONFIG.REMOTE_LOG_CHANNEL, payload)
      end)
      if sent_ok then delivered = delivered + 1 end
    end
    if delivered > 0 then remote_log_state.sent = remote_log_state.sent + 1 else remote_log_state.dropped = remote_log_state.dropped + 1 end
  end)
  if not ok then remote_log_state.dropped = remote_log_state.dropped + 1 end
end

local function sanitize_snapshot(value, active)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" or value_type == "nil" then return value end
  if value_type ~= "table" then return tostring(value) end
  active = active or {}
  if active[value] then return "<cycle>" end
  active[value] = true
  local out = {}
  for key, val in next, value do
    local key_type = type(key)
    if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then key = tostring(key) end
    out[key] = sanitize_snapshot(val, active)
  end
  active[value] = nil
  return out
end

local function safe_serialize(value)
  if not textutils or not textutils.serialize then return nil, "serialize unavailable" end
  local sanitized = sanitize_snapshot(value)
  local ok, result = pcall(textutils.serialize, sanitized)
  if not ok then return nil, result end
  return result
end

function utils.safe_serialize(value) return safe_serialize(value) end
function utils.ensure_dir(path) if not path or path == "" then return end if not fs.exists(path) then fs.makeDir(path) end end

function utils.read_config(path, defaults)
  if not fs.exists(path) then return defaults or {} end
  local file = fs.open(path, "r")
  if not file then return defaults or {} end
  local content = file.readAll(); file.close()
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then return data end
  return defaults or {}
end

function utils.deep_copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}; seen[value] = copy
  for key, item in pairs(value) do copy[utils.deep_copy(key, seen)] = utils.deep_copy(item, seen) end
  return copy
end

function utils.merge_defaults(target, defaults)
  local changed = false
  for key, value in pairs(defaults or {}) do
    if target[key] == nil then target[key] = value; changed = true
    elseif type(target[key]) == "table" and type(value) == "table" then changed = utils.merge_defaults(target[key], value) or changed end
  end
  return changed
end

local function migrate_config(path, data, defaults, meta)
  if type(defaults) ~= "table" then return data end
  local target_version = type(defaults.version) == "number" and defaults.version or nil
  if not target_version then return data end
  local original = utils.deep_copy(data)
  local changed = utils.merge_defaults(data, defaults)
  local loaded_version = type(data.version) == "number" and data.version or 1
  if data.version == nil or loaded_version < target_version then data.version = target_version; changed = true end
  if not changed then return data end
  local ok, err = pcall(utils.write_config, path, data)
  if ok then meta.migrated = true; return data end
  meta.migration_error = err
  utils.log("CONFIG", "Config migration failed at " .. tostring(path) .. "; using existing config.", "WARN")
  return original
end

function utils.load_config(path, defaults)
  local meta = { path = path, source = "defaults" }
  local fallback = utils.deep_copy(defaults or {})
  if not path then meta.reason = "missing path"; return fallback, meta end
  if not fs.exists(path) then meta.reason = "missing"; return fallback, meta end
  local content = read_file(path)
  if not content then meta.reason = "unreadable"; return fallback, meta end
  local loader, err = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      local migrated = migrate_config(path, data, defaults, meta)
      if migrated == data and type(defaults) == "table" and type(defaults.version) ~= "number" then utils.merge_defaults(data, defaults) end
      meta.source = "lua"
      return migrated
    end
    if not ok then err = data end
  end
  if textutils and textutils.unserialize then
    local ok, data = pcall(textutils.unserialize, content)
    if ok and type(data) == "table" then
      local migrated = migrate_config(path, data, defaults, meta)
      if migrated == data and type(defaults) == "table" and type(defaults.version) ~= "number" then utils.merge_defaults(data, defaults) end
      meta.source = "serialized"; meta.reason = "lua invalid"
      return migrated, meta
    end
  end
  meta.reason = err or "invalid"
  return fallback, meta
end

function utils.write_config(path, tbl)
  utils.ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if not file then error("Unable to write config at " .. path) end
  local serialized, err = safe_serialize(tbl)
  if not serialized then error("Config serialize failed: " .. tostring(err)) end
  file.write(serialized); file.close()
end

local function normalize_logger_opts(opts)
  opts = opts or {}
  if opts.log_dir ~= CONFIG.DEFAULT_LOG_DIR and opts.log_dir ~= "auto" then return opts end
  local normalized = {}
  for k, v in pairs(opts) do if k ~= "log_dir" then normalized[k] = v end end
  return normalized
end

function utils.init_logger(opts)
  local result = logger.init(normalize_logger_opts(opts))
  init_remote_log(opts or {})
  return result
end

function utils.log(prefix, message, level)
  local resolved_prefix = prefix or CONFIG.LOGGER_DEFAULT_PREFIX
  send_remote_log(resolved_prefix, level or "INFO", message)
  local ok = pcall(logger.log, resolved_prefix, message, level)
  if not ok then pcall(print, "WARN: logging suppressed due to non-fatal logger failure") end
end

function utils.safe_peripheral_call(name, method, ...)
  if not name or not peripheral.isPresent(name) then return nil, "peripheral missing" end
  local results = table.pack(pcall(peripheral.call, name, method, ...))
  if not results[1] then return nil, results[2] end
  if results.n == 1 then return true end
  return table.unpack(results, 2, results.n)
end

function utils.safe_wrap(name)
  if not name or not peripheral.isPresent(name) then return nil, "peripheral missing" end
  local ok, wrapped = pcall(peripheral.wrap, name)
  if not ok then return nil, wrapped end
  return wrapped
end

function utils.safe_get_methods(name)
  if not name or not peripheral.isPresent(name) then return nil, "peripheral missing" end
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok then return nil, methods end
  if type(methods) ~= "table" then return nil, "invalid methods" end
  return methods
end

function utils.cache_peripherals(names)
  local cache = {}
  for _, name in ipairs(names or {}) do local wrapped = utils.safe_wrap(name); if wrapped then cache[name] = wrapped end end
  return cache
end

function utils.merge(a, b)
  local merged = {}
  for k, v in pairs(a or {}) do merged[k] = v end
  for k, v in pairs(b or {}) do merged[k] = v end
  return merged
end

function utils.trim(text) return trim_text(text) end

function utils.normalize_node_id(value)
  local raw = trim_text(value or "")
  if raw == "" then
    if os and type(os.getComputerID) == "function" then raw = tostring(os.getComputerID()) else raw = "unknown" end
  end
  raw = raw:gsub("%s+", "_")
  raw = raw:gsub("[^%w%-%_%.:]+", "_")
  raw = raw:gsub("^_+", ""):gsub("_+$", "")
  if raw == "" then raw = "unknown" end
  return raw
end

function utils.read_node_id(path)
  local target = path or CONFIG.NODE_ID_PATH
  if not target or not fs.exists(target) then return nil end
  local file = fs.open(target, "r")
  if not file then return nil end
  local content = file.readAll(); file.close()
  local trimmed = utils.trim(content)
  if trimmed == "" then return nil end
  return trimmed
end

function utils.build_log_name(base, node_id)
  local prefix = tostring(base or CONFIG.LOGGER_DEFAULT_PREFIX):lower()
  if not node_id or node_id == "" then return prefix end
  local sanitized = tostring(node_id):lower():gsub("[^%w%-_]+", CONFIG.LOG_NAME_SEPARATOR)
  return prefix .. CONFIG.LOG_NAME_SEPARATOR .. sanitized
end

function utils.init_role_logger(role, node_id, opts)
  opts = opts or {}
  opts.prefix = role or opts.prefix
  opts.node_id = node_id or opts.node_id
  opts.log_name = opts.log_name or utils.build_log_name(role, node_id)
  return utils.init_logger(opts)
end

function utils.remote_log_status()
  return {
    enabled = remote_log_state.enabled == true,
    modem = table.concat(remote_log_state.modem_names or {}, ","),
    modems = remote_log_state.modem_names,
    node_id = remote_log_state.node_id,
    role = remote_log_state.role,
    sent = remote_log_state.sent,
    dropped = remote_log_state.dropped
  }
end

return utils
