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
  DISK_MIN_FREE_BYTES = 4096,
  DISK_STARTUP_MIN_FREE_BYTES = 128,
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

local list_disk_roots

local function get_free_space(root)
  if not fs or type(fs.getFreeSpace) ~= "function" then
    return true, nil
  end
  local ok, free = pcall(fs.getFreeSpace, root or CONFIG.DISK_ROOT)
  if not ok then
    return false, "free-space-check-failed"
  end
  if type(free) == "string" then
    local lowered = string.lower(free)
    if lowered == "unlimited" or lowered == "inf" then
      return true, math.huge
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
  return true, free
end

local function disk_free_ok(root, required_bytes)
  local ok, free_or_reason = get_free_space(root)
  if not ok then
    return false, free_or_reason
  end
  local required = tonumber(required_bytes) or 0
  if required < 0 then
    required = 0
  end
  if type(free_or_reason) == "number" and free_or_reason < required then
    return false, "insufficient-free-space:" .. tostring(free_or_reason)
  end
  return true, free_or_reason
end

local function is_disk_path(path)
  if type(path) ~= "string" then
    return false
  end
  if path:match("^/disk%d*($|/)") then
    return true
  end
  for _, root in ipairs(list_disk_roots()) do
    if type(root) == "string" and root ~= "" then
      if path == root or path:sub(1, #root + 1) == (root .. "/") then
        return true
      end
    end
  end
  return false
end

function list_disk_roots()
  local roots = {}
  local seen = {}
  local function add(path)
    if type(path) ~= "string" or path == "" or seen[path] then
      return
    end
    seen[path] = true
    roots[#roots + 1] = path
  end

  add(CONFIG.DISK_ROOT)
  if peripheral and type(peripheral.getNames) == "function" and disk and type(disk.getMountPath) == "function" then
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then
      for _, name in ipairs(names) do
        local is_drive = false
        if peripheral.hasType and type(peripheral.hasType) == "function" then
          local type_ok, type_result = pcall(peripheral.hasType, name, "drive")
          is_drive = type_ok and type_result == true
        else
          local type_ok, p_type = pcall(peripheral.getType, name)
          is_drive = type_ok and p_type == "drive"
        end
        if is_drive then
          local path_ok, mount_path = pcall(disk.getMountPath, name)
          if path_ok and type(mount_path) == "string" and mount_path ~= "" then
            add(mount_path)
          end
        end
      end
    end
  end
  if fs and type(fs.list) == "function" then
    local ok, entries = pcall(fs.list, "/")
    if ok and type(entries) == "table" then
      for _, entry in ipairs(entries) do
        if type(entry) == "string" and entry:match("^disk%d*$") then
          add("/" .. entry)
        end
      end
    end
  end
  return roots
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

local function validate_log_target(path)
  local free_ok, free_reason = disk_free_ok(path, 1)
  if not free_ok then
    return false, "space:" .. tostring(free_reason)
  end
  local writable, write_reason = disk_write_test(path)
  if not writable then
    return false, "write-test:" .. tostring(write_reason)
  end
  return true
end

local function resolve_log_dir(opts)
  local explicit = opts and normalize_log_dir(opts.log_dir)
  if explicit then
    if is_disk_path(explicit) then
      local explicit_ok, explicit_reason = validate_log_target(explicit)
      if not explicit_ok then
        return DEFAULT_LOG_DIR, "fallback-local(explicit-disk:" .. tostring(explicit_reason) .. ")"
      end
    end
    return explicit, "explicit"
  end
  if settings and settings.get then
    local configured = normalize_log_dir(settings.get("xreactor.log_dir"))
    if configured then
      if is_disk_path(configured) then
        local configured_ok, configured_reason = validate_log_target(configured)
        if not configured_ok then
          return DEFAULT_LOG_DIR, "fallback-local(settings-disk:" .. tostring(configured_reason) .. ")"
        end
      end
      return configured, "settings"
    end
  end

  local disk_failures = {}
  for _, disk_root in ipairs(list_disk_roots()) do
    if fs and fs.exists and fs.exists(disk_root) and fs.isDir and fs.isDir(disk_root) then
      local disk_log_dir = disk_root .. "/xreactor_logs"
      local target_ok, target_reason = validate_log_target(disk_log_dir)
      if target_ok then
        return disk_log_dir, "auto-disk:" .. disk_root
      end
      disk_failures[#disk_failures + 1] = tostring(disk_root) .. ":" .. tostring(target_reason)
    end
  end
  if #disk_failures > 0 then
    return DEFAULT_LOG_DIR, "fallback-local(" .. table.concat(disk_failures, "|") .. ")"
  end

  return DEFAULT_LOG_DIR, "default-local"
end

local function current_max_bytes()
  if is_disk_path(state.log_dir) then
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

  if is_disk_path(state.log_dir) then
    local target_ok, target_reason = validate_log_target(state.log_dir)
    if not target_ok then
      local fallback_ok, fallback_err = pcall(flush_buffer_to_dir, DEFAULT_LOG_DIR)
      if fallback_ok then
        if not state.warn_once then
          state.warn_once = true
          print("WARN: Log dir fallback to local (reason=" .. tostring(target_reason) .. ")")
        end
        state.log_source = "runtime-fallback-local"
        state.buffer = {}
        state.last_flush = os.clock()
        return true
      end
      if not state.warn_once then
        state.warn_once = true
        print("WARN: Logging disabled (" .. tostring(target_reason) .. " | fallback=" .. tostring(fallback_err) .. ")")
      end
      state.enabled = false
      state.buffer = {}
      state.last_flush = os.clock()
      return false
    end
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
  local cleanup_summary = "none"
  local final_path = type(path) == "string" and path or ""
  local final_dir = log_dir or (final_path ~= "" and final_path:match("^(.*)/[^/]+$")) or CONFIG.LOG_DIR
  local cleanup_path = final_dir
  local cleanup_is_disk = is_disk_path(final_dir)
  local free_before = "n/a"
  if cleanup_is_disk then
    local _, before_value = disk_free_ok(final_dir, 0)
    free_before = tostring(before_value)
  end
  local function cleanup_rotated_logs()
    if not cleanup_is_disk then
      return "executed=false,reason=non-disk,path=" .. tostring(cleanup_path)
    end
    if not (fs and type(fs.list) == "function" and fs.exists and fs.exists(cleanup_path)) then
      return "executed=false,reason=unavailable,path=" .. tostring(cleanup_path)
    end
    local ok, entries = pcall(fs.list, cleanup_path)
    if not ok or type(entries) ~= "table" then
      return "executed=false,reason=list-failed,path=" .. tostring(cleanup_path)
    end
    local removed = 0
    local failures = 0
    local removed_names = {}
    local failure_names = {}
    local active_name = path and path:match("([^/]+)$") or nil
    for _, entry in ipairs(entries) do
      if type(entry) == "string" then
        local is_rotated_log = entry:match("%.log%..+$") ~= nil
        local is_cleanup_probe = entry == ".xreactor_log_probe"
        local is_temp = entry:match("%.tmp$") ~= nil
          or entry:match("%.temp$") ~= nil
          or entry:match("%.old$") ~= nil
          or entry:match("%.bak$") ~= nil
          or entry:match("%.preboot$") ~= nil
          or entry:match("^%.xreactor_.*%.tmp$") ~= nil
        local is_active = active_name ~= nil and entry == active_name
        if (is_rotated_log or is_cleanup_probe or is_temp) and not is_active then
          local stale_path = cleanup_path .. "/" .. entry
          local deleted = pcall(fs.delete, stale_path)
          if deleted then
            removed = removed + 1
            removed_names[#removed_names + 1] = entry
          else
            failures = failures + 1
            failure_names[#failure_names + 1] = entry
          end
        end
      end
    end
    table.sort(removed_names)
    table.sort(failure_names)
    local removed_detail = #removed_names > 0 and table.concat(removed_names, "|") or "none"
    local failed_detail = #failure_names > 0 and table.concat(failure_names, "|") or "none"
    return "executed=true,path=" .. tostring(cleanup_path) .. ",removed=" .. tostring(removed) .. "[" .. removed_detail .. "],failed=" .. tostring(failures) .. "[" .. failed_detail .. "]"
  end

  cleanup_summary = cleanup_rotated_logs()
  local free_after_cleanup = "n/a"
  local free_after_prepare = "n/a"
  local startup_min = "n/a"
  local startup_required = "n/a"
  local target_budget = "n/a"
  local startup_space_ok = true
  local startup_space_reason = "n/a"
  local startup_budget_ok = true
  local startup_budget_reason = "n/a"
  if cleanup_is_disk then
    local _, after_value = disk_free_ok(final_dir, 0)
    free_after_cleanup = tostring(after_value)
    startup_min = tostring(CONFIG.DISK_STARTUP_MIN_FREE_BYTES or 0)
    startup_required = "1"
    target_budget = tostring(CONFIG.DISK_MIN_FREE_BYTES or 0)
  end
  local prepare_ok = pcall(function()
    ensure_dir(log_dir or CONFIG.LOG_DIR)
    if mode == "rotate" and fs.exists(path) then
      local backup = path .. (CONFIG.ROTATE_SUFFIX or ".1")
      if fs.exists(backup) then
        fs.delete(backup)
      end
      fs.move(path, backup)
    end
    if mode ~= "keep" then
      local file = fs.open(path, "w")
      if file then
        file.close()
      end
    end
  end)
  if cleanup_is_disk then
    local _, after_prepare = disk_free_ok(final_dir, 0)
    free_after_prepare = tostring(after_prepare)
    startup_space_ok, startup_space_reason = disk_free_ok(final_dir, 1)
    startup_budget_ok, startup_budget_reason = disk_free_ok(final_dir, CONFIG.DISK_STARTUP_MIN_FREE_BYTES or 0)
  end
  local cleanup_prefix = "final_path=" .. tostring(final_path)
    .. ",final_dir=" .. tostring(final_dir)
    .. ",disk=" .. tostring(cleanup_is_disk)
    .. ",free_before=" .. tostring(free_before)
    .. ",free_after_cleanup=" .. tostring(free_after_cleanup)
    .. ",free_after_prepare=" .. tostring(free_after_prepare)
    .. ",startup_required_now=" .. tostring(startup_required)
    .. ",startup_min_required=" .. tostring(startup_min)
    .. ",target_budget=" .. tostring(target_budget)
    .. ",startup_space_ok=" .. tostring(startup_space_ok)
    .. ",startup_space_reason=" .. tostring(startup_space_reason)
    .. ",startup_budget_ok=" .. tostring(startup_budget_ok)
    .. ",startup_budget_reason=" .. tostring(startup_budget_reason)
    .. ",cleanup={" .. tostring(cleanup_summary) .. "}"
  if cleanup_is_disk and not startup_space_ok then
    return "startup_space_reject(" .. cleanup_prefix .. ")"
  end
  if not prepare_ok then
    if not state.warn_once then
      state.warn_once = true
      print("WARN: Log startup policy failed for " .. tostring(path))
    end
    return "startup_policy_failed(" .. cleanup_prefix .. ")"
  end
  if mode == "keep" then
    return "kept(" .. cleanup_prefix .. ")"
  end
  if mode == "rotate" then
    return "rotated(" .. cleanup_prefix .. ")"
  end
  return "truncated(" .. cleanup_prefix .. ")"
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
