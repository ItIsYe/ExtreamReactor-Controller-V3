local DEFAULT_LOG_DIR = "/xreactor_logs"
local DISK_LOG_DIR = "/disk/xreactor_logs"

local function normalize_log_dir(path)
  if type(path) ~= "string" then
    return nil
  end
  local trimmed = path:gsub("%s+$", "")
  trimmed = trimmed:gsub("^%s+", "")
  if trimmed == "" then
    return nil
  end
  return trimmed
end

local CONFIG = {
  LOG_DIR = DEFAULT_LOG_DIR,
  DISK_LOG_DIR = DISK_LOG_DIR,
  DISK_ROOT = "/disk",
  DISK_MIN_FREE_BYTES = 32768,
  SETTINGS_KEY = "xreactor.debug_logging",
  DEFAULT_ENABLED = false,
  FLUSH_LINES = 8,
  FLUSH_INTERVAL = 2,
  MAX_BYTES = 200000,
  DISK_MAX_BYTES = 300000,
  ROTATE_SUFFIX = ".1",
  STARTUP_MODE = "truncate"
}

local logger = {}

local state = {
  enabled = nil,
  log_dir = CONFIG.LOG_DIR,
  log_name = nil,
  log_path = nil,
  log_source = "default",
  buffer = {},
  last_flush = 0,
  warn_once = false,
  startup_action = "none"
}

local function now_stamp()
  return os.date("!%H:%M:%S")
end

local function ensure_dir(path)
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function summarize_error(err)
  if type(err) == "string" then
    return err
  end
  return tostring(err)
end

local function disk_free_ok()
  if not fs or type(fs.getFreeSpace) ~= "function" then
    return true
  end
  local ok, free = pcall(fs.getFreeSpace, CONFIG.DISK_ROOT)
  if not ok then
    return false, "free-space-check-failed"
  end
  if type(free) == "string" then
    local lowered = string.lower(free)
    if lowered == "unlimited" or lowered == "inf" then
      return true
    end
    local parsed = tonumber(free)
    if parsed then
      free = parsed
    else
      return false, "invalid-free-space-type:string"
    end
  end
  if type(free) ~= "number" then
    return false, "invalid-free-space-type:" .. type(free)
  end
  if free < (CONFIG.DISK_MIN_FREE_BYTES or 0) then
    return false, "insufficient-free-space:" .. tostring(free)
  end
  return true
end

local function disk_write_test(path)
  local probe = path .. "/.xreactor_log_probe"
  local ok, err = pcall(function()
    ensure_dir(path)
    local file = fs.open(probe, "w")
    if not file then
      error("probe-open-failed")
    end
    file.write("probe")
    file.close()
    if fs.exists(probe) then
      fs.delete(probe)
    end
  end)
  if not ok then
    return false, summarize_error(err)
  end
  return true
end

local function resolve_log_dir(opts)
  local explicit = opts and normalize_log_dir(opts.log_dir)
  if explicit then
    return explicit, "explicit"
  end
  if settings and settings.get then
    local configured = normalize_log_dir(settings.get("xreactor.log_dir"))
    if configured then
      return configured, "settings"
    end
  end

  local disk_exists = fs and fs.exists and fs.exists(CONFIG.DISK_ROOT)
  local disk_is_dir = fs and fs.isDir and fs.isDir(CONFIG.DISK_ROOT)
  if disk_exists and disk_is_dir then
    local free_ok, free_reason = disk_free_ok()
    if free_ok then
      local writable, write_reason = disk_write_test(CONFIG.DISK_LOG_DIR)
      if writable then
        return CONFIG.DISK_LOG_DIR, "auto-disk"
      end
      return DEFAULT_LOG_DIR, "fallback-local(write-test:" .. tostring(write_reason) .. ")"
    end
    return DEFAULT_LOG_DIR, "fallback-local(space:" .. tostring(free_reason) .. ")"
  end

  return DEFAULT_LOG_DIR, "default-local"
end

local function current_max_bytes()
  if state.log_source == "auto-disk" then
    return CONFIG.DISK_MAX_BYTES or CONFIG.MAX_BYTES
  end
  return CONFIG.MAX_BYTES
end

local function rotate_log_if_needed(path)
  local max_bytes = current_max_bytes()
  if not max_bytes or max_bytes <= 0 then
    return
  end
  if not fs.exists(path) then
    return
  end
  if fs.getSize(path) < max_bytes then
    return
  end
  local backup = path .. (CONFIG.ROTATE_SUFFIX or ".1")
  if fs.exists(backup) then
    fs.delete(backup)
  end
  fs.move(path, backup)
end

local function resolve_enabled(current)
  if current == true then
    return true
  end
  if settings and settings.get then
    local stored = settings.get(CONFIG.SETTINGS_KEY)
    if stored == true then
      return true
    end
  end
  if current == false then
    return false
  end
  return CONFIG.DEFAULT_ENABLED
end

local function resolve_log_name(current, fallback)
  local name = current or fallback or "xreactor"
  return tostring(name):lower()
end

local function flush_buffer_to_dir(target_dir)
  ensure_dir(target_dir)
  local path = string.format("%s/%s.log", target_dir, state.log_name or "xreactor")
  rotate_log_if_needed(path)
  local file = fs.open(path, "a")
  if not file then
    error("Unable to open log file: " .. path)
  end
  for _, line in ipairs(state.buffer) do
    file.write(line .. "\n")
  end
  file.close()
  state.log_dir = target_dir
  state.log_path = path
end

local function flush_if_needed(force)
  if not state.enabled then
    return true
  end
  if #state.buffer == 0 then
    return true
  end
  local elapsed = os.clock() - (state.last_flush or 0)
  if not force and #state.buffer < CONFIG.FLUSH_LINES and elapsed < CONFIG.FLUSH_INTERVAL then
    return true
  end

  local ok, err = pcall(flush_buffer_to_dir, state.log_dir or CONFIG.LOG_DIR)
  if not ok and (state.log_dir ~= DEFAULT_LOG_DIR) then
    local fallback_ok, fallback_err = pcall(flush_buffer_to_dir, DEFAULT_LOG_DIR)
    if fallback_ok then
      if not state.warn_once then
        state.warn_once = true
        print("WARN: Log dir fallback to local (reason=" .. tostring(err) .. ")")
      end
      state.log_source = "runtime-fallback-local"
      ok = true
    else
      err = tostring(err) .. " | fallback=" .. tostring(fallback_err)
    end
  end

  state.buffer = {}
  state.last_flush = os.clock()
  if not ok and not state.warn_once then
    state.warn_once = true
    print("WARN: Logging disabled (" .. tostring(err) .. ")")
  end
  if not ok then
    state.enabled = false
    return false
  end
  return true
end

local function normalize_level(level)
  if not level then
    return "INFO"
  end
  local upper = tostring(level):upper()
  if upper == "WARN" or upper == "WARNING" then
    return "WARN"
  end
  if upper == "ERR" then
    return "ERROR"
  end
  return upper
end

local function parse_message_level(message, level)
  if level then
    return normalize_level(level), message
  end
  local text = tostring(message or "")
  local prefixes = {
    { tag = "ERROR", pattern = "^ERROR:%s*" },
    { tag = "WARN", pattern = "^WARN:%s*" },
    { tag = "DEBUG", pattern = "^DEBUG:%s*" },
    { tag = "INFO", pattern = "^INFO:%s*" }
  }
  for _, entry in ipairs(prefixes) do
    if text:find(entry.pattern) then
      return entry.tag, text:gsub(entry.pattern, "", 1)
    end
  end
  return "INFO", text
end

local function startup_prepare(path, mode, log_dir)
  if mode == "keep" then
    return "kept"
  end
  local ok = pcall(function()
    ensure_dir(log_dir or CONFIG.LOG_DIR)
    if mode == "rotate" and fs.exists(path) then
      local backup = path .. (CONFIG.ROTATE_SUFFIX or ".1")
      if fs.exists(backup) then
        fs.delete(backup)
      end
      fs.move(path, backup)
    end
    local file = fs.open(path, "w")
    if file then
      file.close()
    end
  end)
  if not ok then
    if not state.warn_once then
      state.warn_once = true
      print("WARN: Log startup policy failed for " .. tostring(path))
    end
    return "startup_policy_failed"
  end
  if mode == "rotate" then
    return "rotated"
  end
  return "truncated"
end

function logger.init(opts)
  opts = opts or {}
  state.enabled = resolve_enabled(opts.enabled)
  local log_dir, source = resolve_log_dir(opts)
  state.log_dir = log_dir
  state.log_source = source
  state.log_name = resolve_log_name(opts.log_name, opts.prefix)
  state.log_path = string.format("%s/%s.log", state.log_dir, state.log_name or "xreactor")
  state.last_flush = os.clock()
  state.buffer = {}
  state.startup_action = "none"
  if state.enabled then
    local startup_mode = CONFIG.STARTUP_MODE
    if opts.truncate ~= nil then
      startup_mode = opts.truncate and "truncate" or "keep"
    end
    if type(opts.startup_mode) == "string" then
      startup_mode = string.lower(opts.startup_mode)
    end
    state.startup_action = startup_prepare(state.log_path, startup_mode, state.log_dir)
    print(string.format("LOG: dir=%s file=%s startup=%s source=%s", tostring(state.log_dir), state.log_path, state.startup_action, tostring(state.log_source)))
  end
  return {
    enabled = state.enabled == true,
    log_dir = state.log_dir,
    log_name = state.log_name,
    log_path = state.log_path,
    log_source = state.log_source,
    startup_action = state.startup_action
  }
end

function logger.set_enabled(enabled)
  state.enabled = resolve_enabled(enabled)
end

function logger.log(prefix, message, level)
  if state.enabled == nil then
    logger.init({ prefix = prefix })
  end
  if not state.enabled then
    return
  end
  local resolved_level, resolved_message = parse_message_level(message, level)
  local line = string.format("[%s] %s | %s | %s", now_stamp(), tostring(prefix or "LOG"), resolved_level, resolved_message)
  table.insert(state.buffer, line)
  flush_if_needed(false)
end

function logger.flush()
  flush_if_needed(true)
end

function logger.describe()
  return {
    enabled = state.enabled == true,
    log_dir = state.log_dir,
    log_name = state.log_name,
    log_path = state.log_path,
    log_source = state.log_source,
    startup_action = state.startup_action
  }
end

return logger
