local DEFAULT_LOG_DIR = "/xreactor_logs"

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

local function resolve_log_dir(opts)
  local explicit = opts and normalize_log_dir(opts.log_dir)
  if explicit then
    return explicit
  end
  if settings and settings.get then
    local configured = normalize_log_dir(settings.get("xreactor.log_dir"))
    if configured then
      return configured
    end
  end
  return DEFAULT_LOG_DIR
end

-- CONFIG
local CONFIG = {
  LOG_DIR = DEFAULT_LOG_DIR, -- Directory for log files.
  SETTINGS_KEY = "xreactor.debug_logging", -- settings API key for enabling debug logs.
  DEFAULT_ENABLED = false, -- Default debug logging state when no config/setting exists.
  FLUSH_LINES = 8, -- Buffer size before flushing to disk.
  FLUSH_INTERVAL = 2, -- Seconds between flushes during active logging.
  MAX_BYTES = 200000, -- Rotate log files after this size.
  ROTATE_SUFFIX = ".1", -- Suffix for rotated log.
  STARTUP_MODE = "truncate" -- Startup policy: "truncate", "rotate", or "keep".
}

-- Lightweight file logger for CC:Tweaked.
local logger = {}

local state = {
  enabled = nil,
  log_dir = CONFIG.LOG_DIR,
  log_name = nil,
  log_path = nil,
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

local function rotate_log_if_needed(path)
  if not CONFIG.MAX_BYTES or CONFIG.MAX_BYTES <= 0 then
    return
  end
  if not fs.exists(path) then
    return
  end
  if fs.getSize(path) < CONFIG.MAX_BYTES then
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
  local ok, err = pcall(function()
    ensure_dir(state.log_dir or CONFIG.LOG_DIR)
    local path = string.format("%s/%s.log", state.log_dir or CONFIG.LOG_DIR, state.log_name or "xreactor")
    rotate_log_if_needed(path)
    local file = fs.open(path, "a")
    if not file then
      error("Unable to open log file: " .. path)
    end
    for _, line in ipairs(state.buffer) do
      file.write(line .. "\n")
    end
    file.close()
  end)
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
  state.log_dir = resolve_log_dir(opts)
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
    print(string.format("LOG: dir=%s file=%s startup=%s", tostring(state.log_dir), state.log_path, state.startup_action))
  end
  return {
    enabled = state.enabled == true,
    log_dir = state.log_dir,
    log_name = state.log_name,
    log_path = state.log_path,
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
    startup_action = state.startup_action
  }
end

return logger
