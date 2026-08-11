-- CONFIG
local CONFIG = {
  LOGGER_DEFAULT_PREFIX = "LOG",
  NODE_ID_PATH = "/xreactor/config/node_id.txt",
  ROLE_CONFIG_PATH = "/xreactor/config/role.lua",
  LOG_NAME_SEPARATOR = "_",
  DEFAULT_LOG_DIR = "/disk/xreactor_logs",
  REMOTE_LOG_CHANNEL = 6503,
  REMOTE_LOG_PENDING_LIMIT = 16,
  REMOTE_LOG_RETRY_EVERY = 60,
  REMOTE_LOG_MAX_SENDS = 2,
  REMOTE_LOG_MODEM_REFRESH_SECONDS = 10
}

local utils = {}
local logger = require("core.logger")

local current_log_mode = "all"

function utils.set_log_mode(mode)
  local valid = { all = true, disk = true, remote = true, terminal = true, none = true }
  if not valid[mode] then return false end
  current_log_mode = mode
  if settings and type(settings.set) == "function" then
    pcall(settings.set, "xreactor.log_mode", mode)
    pcall(settings.save)
  end
  return true
end

function utils.get_log_mode() return current_log_mode end

local function load_log_mode()
  if settings and type(settings.get) == "function" then
    local stored = settings.get("xreactor.log_mode")
    if stored and type(stored) == "string" then
      local valid = { all = true, disk = true, remote = true, terminal = true, none = true }
      if valid[stored] then current_log_mode = stored end
    end
  end
end
load_log_mode()

local remote_log_state = {
  initialized = false,
  enabled = true,
  modems = {},
  modem_names = {},
  node_id = nil,
  role = nil,
  boot_id = nil,
  seq = 0,
  sent = 0,
  resent = 0,
  dropped = 0,
  acked = 0,
  modem_refreshes = 0,
  pending = {},
  pending_order = {},
  next_retry_at = 0,
  next_modem_refresh_at = 0,
  auth_secret = nil,
}

local function read_file(path)
  if not path or not fs.exists(path) then return nil end
  local file = fs.open(path, "r")
  if not file then return nil end
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
  if ok and type(result) == "table" and type(result.role) == "string" then return result.role end
  return "UNKNOWN"
end

local function resolve_node_id()
  local value = trim_text(read_file(CONFIG.NODE_ID_PATH) or "")
  if value ~= "" then return value end
  if os and type(os.getComputerID) == "function" then return "pc-" .. tostring(os.getComputerID()) end
  return "unknown-node"
end

local function now_ticks()
  if os and type(os.clock) == "function" then
    local ok, value = pcall(os.clock)
    if ok and type(value) == "number" then return value end
  end
  if os and type(os.epoch) == "function" then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then return math.floor(value / 1000) end
  end
  return 0
end

local function make_boot_id(node_id)
  local epoch = 0
  if os and type(os.epoch) == "function" then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then epoch = value end
  end
  local computer = "unknown"
  if os and type(os.getComputerID) == "function" then
    local ok, value = pcall(os.getComputerID)
    if ok then computer = tostring(value) end
  end
  local random_part = "0"
  if math and type(math.random) == "function" then
    local ok, value = pcall(math.random, 100000, 999999)
    if ok then random_part = tostring(value) end
  end
  return tostring(node_id or "node") .. ":boot:" .. tostring(computer) .. ":" .. tostring(epoch) .. ":" .. random_part
end

local function is_ender_modem(modem)
  if type(modem.getRange) ~= "function" then return false end
  local ok, range = pcall(modem.getRange)
  if not ok or type(range) ~= "number" then return false end
  return range >= 65536
end

local function discover_log_modems()
  local list = {}
  if not peripheral or type(peripheral.getNames) ~= "function" then return list end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return list end
  table.sort(names)
  local all_wireless = {}
  for _, name in ipairs(names) do
    local type_ok, ptype = pcall(peripheral.getType, name)
    if type_ok and ptype == "modem" then
      local wrap_ok, modem = pcall(peripheral.wrap, name)
      if wrap_ok and modem and type(modem.transmit) == "function" then
        local is_wireless = type(modem.isWireless) == "function" and
          (function() local ok2, r = pcall(modem.isWireless); return ok2 and r == true end)()
        if is_wireless then all_wireless[#all_wireless + 1] = { name = name, modem = modem } end
      end
    end
  end
  if #all_wireless == 0 then return list end
  for i = 2, #all_wireless do list[#list + 1] = all_wireless[i] end
  if #list == 0 then list[1] = all_wireless[1] end
  return list
end

local function refresh_log_modems(force)
  if not remote_log_state.initialized then return end
  local now = now_ticks()
  if not force and #remote_log_state.modems > 0 and now < (remote_log_state.next_modem_refresh_at or 0) then return end
  remote_log_state.next_modem_refresh_at = now + CONFIG.REMOTE_LOG_MODEM_REFRESH_SECONDS
  local discovered = discover_log_modems()
  remote_log_state.modems = discovered
  remote_log_state.modem_names = {}
  for _, entry in ipairs(remote_log_state.modems) do
    remote_log_state.modem_names[#remote_log_state.modem_names + 1] = entry.name
    if type(entry.modem.open) == "function" then pcall(entry.modem.open, CONFIG.REMOTE_LOG_CHANNEL) end
  end
  remote_log_state.modem_refreshes = (remote_log_state.modem_refreshes or 0) + 1
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
  if remote_log_state.enabled == nil then remote_log_state.enabled = settings_bool("xreactor.remote_logging", true) end
  remote_log_state.node_id = opts.node_id or resolve_node_id()
  remote_log_state.role = opts.prefix or read_role_config_value()
  remote_log_state.boot_id = make_boot_id(remote_log_state.node_id)
  local ok_protocol, protocol = pcall(require, "core.protocol")
  remote_log_state.auth_secret = ok_protocol and protocol.resolve_auth_secret({}) or nil
  remote_log_state.initialized = true
  refresh_log_modems(true)
end

local function transmit_payload(payload)
  refresh_log_modems(false)
  if not remote_log_state.enabled or #remote_log_state.modems == 0 then return 0 end
  local delivered = 0
  for _, entry in ipairs(remote_log_state.modems) do
    local sent_ok = pcall(function()
      entry.modem.transmit(CONFIG.REMOTE_LOG_CHANNEL, CONFIG.REMOTE_LOG_CHANNEL, payload)
    end)
    if sent_ok then delivered = delivered + 1 end
  end
  return delivered
end

local function forget_pending(event_id)
  if not event_id or not remote_log_state.pending[event_id] then return false end
  remote_log_state.pending[event_id] = nil
  for i = #remote_log_state.pending_order, 1, -1 do
    if remote_log_state.pending_order[i] == event_id then table.remove(remote_log_state.pending_order, i) end
  end
  return true
end

local function add_pending(payload)
  if not payload or not payload.event_id then return end
  if remote_log_state.pending[payload.event_id] then return end
  while #remote_log_state.pending_order >= CONFIG.REMOTE_LOG_PENDING_LIMIT do
    local old_id = table.remove(remote_log_state.pending_order, 1)
    if old_id then remote_log_state.pending[old_id] = nil; remote_log_state.dropped = remote_log_state.dropped + 1 end
  end
  remote_log_state.pending[payload.event_id] = { payload = payload, sends = 1, last_send = now_ticks() }
  remote_log_state.pending_order[#remote_log_state.pending_order + 1] = payload.event_id
end

local function retry_pending(force)
  if not remote_log_state.initialized then return end
  refresh_log_modems(false)
  local now = now_ticks()
  if not force and now < (remote_log_state.next_retry_at or 0) then return end
  remote_log_state.next_retry_at = now + CONFIG.REMOTE_LOG_RETRY_EVERY
  local snapshot = {}
  for _, event_id in ipairs(remote_log_state.pending_order) do snapshot[#snapshot + 1] = event_id end
  for _, event_id in ipairs(snapshot) do
    local item = remote_log_state.pending[event_id]
    if item and item.payload then
      if item.sends >= CONFIG.REMOTE_LOG_MAX_SENDS then
        forget_pending(event_id)
        remote_log_state.dropped = remote_log_state.dropped + 1
      else
        local delivered = transmit_payload(item.payload)
        item.sends = item.sends + 1
        item.last_send = now
        if delivered > 0 then remote_log_state.resent = remote_log_state.resent + 1 end
      end
    end
  end
end

local function handle_remote_ack(message)
  if type(message) ~= "table" or message.type ~= "LOG_ACK" then return false end
  if not remote_log_state.initialized then return true end
  local ok_protocol, protocol = pcall(require, "core.protocol")
  local secret = remote_log_state.auth_secret
  local auth_ok = secret and type(message.auth) == "table" and message.auth.algorithm == "HMAC-SHA256"
    and select(1, protocol.verify_value(protocol.log_auth_value(message), secret, message.auth.mac))
  local ts = tonumber(message.ts)
  local fresh = ts and math.abs((os.epoch and os.epoch("utc") or 0) - ts) <= 60 * 1000
  if not auth_ok or not fresh then return true end
  if message.to_node and tostring(message.to_node) ~= tostring(remote_log_state.node_id or resolve_node_id()) then return true end
  if message.event_id and forget_pending(message.event_id) then remote_log_state.acked = remote_log_state.acked + 1 end
  return true
end

local function send_remote_log(prefix, level, message)
  local ok = pcall(function()
    if not remote_log_state.initialized then init_remote_log({ prefix = prefix }) end
    retry_pending(false)
    if not remote_log_state.enabled or #remote_log_state.modems == 0 then refresh_log_modems(true) end
    if not remote_log_state.enabled or #remote_log_state.modems == 0 then
      remote_log_state.dropped = remote_log_state.dropped + 1
      return
    end
    remote_log_state.seq = (remote_log_state.seq or 0) + 1
    local node_id = remote_log_state.node_id or resolve_node_id()
    local boot_id = remote_log_state.boot_id or make_boot_id(node_id)
    remote_log_state.boot_id = boot_id
    local payload = {
      type = "LOG_EVENT", proto = "xreactor-log-v2", node_id = node_id,
      role = remote_log_state.role or read_role_config_value(), prefix = tostring(prefix or "LOG"),
      level = tostring(level or "INFO"), message = tostring(message or ""), seq = remote_log_state.seq,
      boot_id = boot_id, event_id = tostring(boot_id) .. ":" .. tostring(remote_log_state.seq),
      ts = os and os.epoch and os.epoch("utc") or nil, ack = true
    }
    local ok_protocol, protocol = pcall(require, "core.protocol")
    local secret = remote_log_state.auth_secret
    local mac = secret and protocol.sign_value(protocol.log_auth_value(payload), secret) or nil
    if not mac then
      remote_log_state.dropped = remote_log_state.dropped + 1
      return
    end
    payload.auth = { algorithm = "HMAC-SHA256", mac = mac }
    local delivered = transmit_payload(payload)
    if delivered > 0 then remote_log_state.sent = remote_log_state.sent + 1; add_pending(payload)
    else remote_log_state.dropped = remote_log_state.dropped + 1 end
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
    local safe_key = (key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean") and tostring(key) or key
    out[safe_key] = sanitize_snapshot(val, active)
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
  local call_ok, persisted, persist_err = pcall(utils.write_config, path, data)
  if call_ok and persisted == true then
    meta.migrated = true
    return data
  end
  meta.migration_error = call_ok and (persist_err or "write_config returned false") or persisted
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
      return migrated, meta
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
  return fallback
end

local function restore_config_backup(path, backup)
  if fs.exists(path) then pcall(fs.delete, path) end
  if backup and fs.exists(backup) then
    local ok_restore, restore_result = pcall(fs.move, backup, path)
    return ok_restore and restore_result ~= false and fs.exists(path)
  end
  return not fs.exists(path)
end

function utils.write_config(path, tbl)
  if type(path) ~= "string" or path == "" then return false, "invalid_path" end

  -- Serialize completely before touching the destination. A cyclic/invalid
  -- value can therefore never truncate the previously valid config.
  local serialized, serialize_err = safe_serialize(tbl)
  if not serialized then
    pcall(print, "WARN: write_config serialize failed: " .. tostring(serialize_err))
    return false, "serialize_failed:" .. tostring(serialize_err)
  end

  local dir = fs.getDir(path)
  if dir ~= "" then
    local ok_dir, dir_err = pcall(utils.ensure_dir, dir)
    if not ok_dir then return false, "mkdir_failed:" .. tostring(dir_err) end
  end

  local tmp = path .. ".xr_tmp"
  local backup = path .. ".xr_prev"
  if fs.exists(tmp) then pcall(fs.delete, tmp) end
  local file = fs.open(tmp, "w")
  if not file then
    pcall(print, "WARN: write_config failed to open temp " .. tostring(tmp))
    return false, "open_failed"
  end
  local ok_write, write_err = pcall(function() file.write(serialized) end)
  local ok_close, close_err = pcall(file.close)
  if not ok_write or not ok_close then
    pcall(fs.delete, tmp)
    return false, "write_failed:" .. tostring(write_err or close_err)
  end

  if read_file(tmp) ~= serialized then
    pcall(fs.delete, tmp)
    return false, "verify_failed"
  end

  local had_old = fs.exists(path)
  if had_old then
    if fs.exists(backup) then
      pcall(fs.delete, backup)
      if fs.exists(backup) then pcall(fs.delete, tmp); return false, "stale_backup_delete_failed" end
    end
    local ok_backup, backup_result = pcall(fs.move, path, backup)
    if not ok_backup or backup_result == false or not fs.exists(backup) then
      pcall(fs.delete, tmp)
      return false, "backup_move_failed"
    end
  end

  local ok_commit, commit_result = pcall(fs.move, tmp, path)
  if not ok_commit or commit_result == false or not fs.exists(path) then
    pcall(fs.delete, tmp)
    restore_config_backup(path, had_old and backup or nil)
    return false, "commit_move_failed"
  end

  if read_file(path) ~= serialized then
    restore_config_backup(path, had_old and backup or nil)
    return false, "commit_verify_failed"
  end

  if had_old and fs.exists(backup) then pcall(fs.delete, backup) end
  return true
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
  local mode = current_log_mode or "all"
  if mode == "none" then return end
  if mode == "terminal" then
    pcall(print, string.format("[%s] %s", resolved_prefix, tostring(message)))
    return
  end
  if mode == "all" or mode == "remote" then send_remote_log(resolved_prefix, level or "INFO", message) end
  if mode == "all" or mode == "disk" then
    local ok = pcall(logger.log, resolved_prefix, message, level)
    if not ok then pcall(print, "WARN: logging suppressed due to non-fatal logger failure") end
  end
end

function utils.handle_remote_log_message(message)
  if not remote_log_state.initialized then init_remote_log({}) end
  return handle_remote_ack(message)
end

function utils.flush_remote_logs(force)
  if not remote_log_state.initialized then init_remote_log({}) end
  retry_pending(force == true)
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

function utils.number_or_nil(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then local n = tonumber(value); if n then return n end end
  return nil
end

function utils.payload_looks_rt(payload)
  if type(payload) ~= "table" then return false end
  if type(payload.rt) == "table" then return true end
  if type(payload.turbines) == "table" or type(payload.reactors) == "table" or type(payload.modules) == "table" then return true end
  if payload.turbine_rpm ~= nil or payload.steam ~= nil or payload.ramp_state ~= nil then return true end
  if payload.mode ~= nil and (payload.output ~= nil or payload.state ~= nil)
      and (payload.capabilities ~= nil or payload.bindings ~= nil) then return true end
  return false
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
    modem_refreshes = remote_log_state.modem_refreshes,
    node_id = remote_log_state.node_id,
    role = remote_log_state.role,
    boot_id = remote_log_state.boot_id,
    seq = remote_log_state.seq,
    sent = remote_log_state.sent,
    resent = remote_log_state.resent,
    dropped = remote_log_state.dropped,
    acked = remote_log_state.acked,
    pending = #remote_log_state.pending_order
  }
end

return utils
