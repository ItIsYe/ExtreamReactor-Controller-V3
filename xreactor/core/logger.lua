-- CONFIG
local CONFIG = {
  LOG_DIR = "/xreactor/logs", -- Directory for log files.
  SETTINGS_KEY = "xreactor.debug_logging", -- settings API key for enabling debug logs.
  DEFAULT_ENABLED = false, -- Default debug logging state when no config/setting exists.
  FLUSH_LINES = 8, -- Buffer size before flushing to disk.
  FLUSH_INTERVAL = 2 -- Seconds between flushes during active logging.
}

-- Lightweight file logger for CC:Tweaked.
local logger = {}

local state = {
  enabled = nil,
  log_name = nil,
  buffer = {},
  last_flush = 0,
  warn_once = false
}

local function now_stamp()
  return textutils.formatTime(os.epoch("utc") / 1000, true)
end

local function ensure_dir(path)
  if not fs.exists(path) then
    fs.makeDir(path)
  end
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
    ensure_dir(CONFIG.LOG_DIR)
    local path = string.format("%s/%s.log", CONFIG.LOG_DIR, state.log_name or "xreactor")
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

function logger.init(opts)
  opts = opts or {}
  state.enabled = resolve_enabled(opts.enabled)
  state.log_name = resolve_log_name(opts.log_name, opts.prefix)
  state.last_flush = os.clock()
  state.buffer = {}
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

return logger
