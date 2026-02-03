-- CONFIG
local CONFIG = {
  CORE_PATH = "/xreactor/installer/installer_core.lua", -- Installed core installer path (updated at runtime).
  CORE_META_PATH = "/xreactor/installer/installer_core.meta", -- Stored core metadata snapshot (updated at runtime).
  RELEASE_PATH = "xreactor/installer/release.lua", -- Release metadata path.
  REPO_OWNER = "ItIsYe", -- GitHub repository owner.
  REPO_NAME = "ExtreamReactor-Controller-V3", -- GitHub repository name.
  RELEASE_BRANCH = "beta", -- Branch to fetch release metadata from.
  QUICK_INSTALL_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer", -- README Quick Install URL.
  QUICK_INSTALL_TARGET = "installer", -- README Quick Install target filename.
  BASE_URLS = { -- Raw download mirrors (no blob links).
    "https://raw.githubusercontent.com"
  },
  DOWNLOAD_ATTEMPTS = 4, -- Retry attempts per URL.
  DOWNLOAD_BACKOFF = 1, -- Backoff base seconds between retries.
  DOWNLOAD_JITTER = 0.35, -- Max jitter seconds added to backoff.
  DOWNLOAD_TIMEOUT = 8, -- HTTP timeout in seconds (when http.request is available).
  DOWNLOAD_STREAM_CHUNK_SIZE = 8192, -- Stream chunk size for core downloads.
  MIN_CORE_BYTES = 200, -- Minimum bytes to accept core download.
  CORE_SANITY_MARKER = "local function main", -- Core sanity marker.
  CORE_DOWNLOAD_PATH = "/xreactor/.tmp/installer_core.lua.download", -- Temp download path for core (updated at runtime).
  CORE_BAD_PATH = "/xreactor/.tmp/installer_core.bad", -- Saved bad core content for debugging (updated at runtime).
  CORE_MAX_RETRIES = 3, -- Max core download attempts before aborting.
  CORE_RETRY_BACKOFF = 1, -- Backoff seconds between core download retries.
  LOG_ENABLED = true, -- Always enable bootstrap logging.
  LOG_SETTINGS_KEY = "xreactor.debug_logging", -- Settings key for debug logging toggle.
  LOG_PATH = "/xreactor_logs/installer_debug.log", -- Bootstrap log file path (updated at runtime).
  LOCAL_LOG_DIR = "/xreactor_logs", -- Log directory (updated at runtime).
  LOG_FALLBACK_PATH = "/xreactor_logs/installer_debug.log", -- Fallback log path when storage root is unavailable.
  DISK_LOG_DIR_NAME = "xreactor_logs", -- Legacy disk log directory name.
  LOG_MAX_BYTES = 200000, -- Max log size before rotation.
  LOG_BACKUP_SUFFIX = ".1", -- Suffix for rotated log.
  LOG_FLUSH_LINES = 6, -- Buffered log lines before flushing.
  LOG_FLUSH_INTERVAL = 1.5, -- Seconds between log flushes.
  LOG_SAMPLE_BYTES = 200, -- Bytes to capture as response signature.
  DISK_SPACE_OVERHEAD_BYTES = 2048, -- Reserved extra bytes for write operations.
  DISK_SPACE_MIN_BUFFER = 4096, -- Minimum free bytes to keep after writes.
  DISK_LABEL = "XREACTOR" -- Disk label to set when using a mounted disk.
}

local log_line
local format_bytes
local cleanup_temp_file
local disk_pool

local function list_disk_mounts()
  local mounts = {}
  local candidates = { "/disk" }
  for idx = 2, 9 do
    table.insert(candidates, "/disk" .. tostring(idx))
  end
  for _, path in ipairs(candidates) do
    if fs.exists(path) and fs.isDir(path) then
      local ok_free, free = pcall(fs.getFreeSpace, path)
      local ok_total, total = pcall(fs.getCapacity, path)
      if ok_free and free then
        local test_path = path .. "/.xreactor_write_test"
        local ok_write = pcall(function()
          local file = fs.open(test_path, "w")
          if not file then
            error("open failed", 0)
          end
          file.write("ok")
          file.close()
          fs.delete(test_path)
        end)
        if ok_write then
          local used = (ok_total and total) and (total - free) or nil
          table.insert(mounts, { path = path, free = free, total = ok_total and total or nil, used = used })
        end
      end
    end
  end
  table.sort(mounts, function(a, b) return a.free > b.free end)
  return mounts
end

local function format_mounts(mounts)
  if not mounts or #mounts == 0 then
    return "  (no disks found)"
  end
  local lines = {}
  for _, entry in ipairs(mounts) do
    if entry.total and entry.used then
      table.insert(lines, string.format(
        "  %s: %s free (%s used / %s total)",
        entry.path,
        format_bytes(entry.free),
        format_bytes(entry.used),
        format_bytes(entry.total)
      ))
    else
      table.insert(lines, string.format("  %s: %s free", entry.path, format_bytes(entry.free)))
    end
  end
  return table.concat(lines, "\n")
end

local function pick_smallest_mount(mounts, min_free)
  if not mounts or #mounts == 0 then
    return nil
  end
  for idx = #mounts, 1, -1 do
    local entry = mounts[idx]
    if not min_free or entry.free >= min_free then
      return entry
    end
  end
  return mounts[#mounts]
end

local function build_disk_pool(required_bytes)
  local mounts = list_disk_mounts()
  if #mounts == 0 then
    return nil, "No writable disk mount found.", mounts
  end
  local largest = mounts[1]
  if required_bytes and largest.free < required_bytes then
    return nil, "Not enough disk space for core.", mounts
  end
  local stage = largest
  local backup = mounts[2] or largest
  local log_mount = pick_smallest_mount(mounts, CONFIG.DISK_SPACE_MIN_BUFFER or 0) or largest
  return {
    mounts = mounts,
    core_mount = largest,
    stage_mount = stage,
    backup_mount = backup,
    log_mount = log_mount
  }, nil, mounts
end

local function apply_disk_pool(pool)
  local core_mount = pool and pool.core_mount or nil
  local stage_mount = pool and pool.stage_mount or core_mount
  local backup_mount = pool and pool.backup_mount or core_mount
  local log_mount = pool and pool.log_mount or core_mount
  if not core_mount then
    return false
  end
  local root = core_mount.path .. "/xreactor"
  local log_dir = log_mount.path .. "/xreactor_logs"
  local stage_dir = stage_mount.path .. "/xreactor_stage"
  local backup_dir = backup_mount.path .. "/xreactor_backup"
  CONFIG.STORAGE_ROOT = root
  CONFIG.LOG_DIR = log_dir
  CONFIG.STAGE_DIR = stage_dir
  CONFIG.BACKUP_DIR = backup_dir
  CONFIG.CORE_PATH = root .. "/installer/installer_core.lua"
  CONFIG.CORE_META_PATH = root .. "/installer/installer_core.meta"
  CONFIG.CORE_DOWNLOAD_PATH = stage_dir .. "/installer_core.lua.download"
  CONFIG.CORE_BAD_PATH = stage_dir .. "/installer_core.bad"
  CONFIG.LOG_PATH = log_dir .. "/installer_debug.log"
  CONFIG.LOCAL_LOG_DIR = log_dir
  CONFIG.LOG_FALLBACK_PATH = log_dir .. "/installer_debug.log"
  CONFIG.DISK_MOUNT_PATH = core_mount.path
  CONFIG.CORE_MOUNT_PATH = core_mount.path
  CONFIG.STAGE_MOUNT_PATH = stage_mount.path
  CONFIG.BACKUP_MOUNT_PATH = backup_mount.path
  CONFIG.LOG_MOUNT_PATH = log_mount.path
  return true
end

local function configure_storage_root()
  local pool, err = build_disk_pool()
  if not pool then
    print("WARN: " .. tostring(err or "No writable disk mount found."))
    print('No disk mount detected, using local storage. Attach a disk so "/disk" appears for disk-first install.')
    CONFIG.STORAGE_ROOT = "/xreactor"
    CONFIG.LOG_DIR = "/xreactor_logs"
    CONFIG.STAGE_DIR = "/xreactor_stage"
    CONFIG.BACKUP_DIR = "/xreactor_backup"
    CONFIG.CORE_PATH = "/xreactor/installer/installer_core.lua"
    CONFIG.CORE_META_PATH = "/xreactor/installer/installer_core.meta"
    CONFIG.CORE_DOWNLOAD_PATH = "/xreactor_stage/installer_core.lua.download"
    CONFIG.CORE_BAD_PATH = "/xreactor_stage/installer_core.bad"
    CONFIG.LOG_PATH = "/xreactor_logs/installer_debug.log"
    CONFIG.LOCAL_LOG_DIR = "/xreactor_logs"
    CONFIG.LOG_FALLBACK_PATH = "/xreactor_logs/installer_debug.log"
    CONFIG.DISK_MOUNT_PATH = nil
    disk_pool = nil
    return
  end
  disk_pool = pool
  apply_disk_pool(pool)
end

configure_storage_root()

local function label_disk_mount(mount_path, label)
  if not mount_path or not label or not peripheral or not disk or not disk.getMountPath then
    return
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local ok, mount = pcall(disk.getMountPath, name)
      if ok and mount == mount_path then
        local ok_label, existing = pcall(disk.getLabel, name)
        if ok_label and (not existing or existing == "") then
          pcall(disk.setLabel, name, label)
        end
      end
    end
  end
end

local function try_label_disk()
  if not disk_pool or not disk_pool.mounts then
    return
  end
  for idx, entry in ipairs(disk_pool.mounts) do
    label_disk_mount(entry.path, CONFIG.DISK_LABEL .. "_DISK_" .. tostring(idx))
  end
end

local function select_mount_for_bytes(needed)
  local pool, _, mounts = build_disk_pool(needed)
  if not pool then
    print("ERROR: Not enough disk space to continue.")
    print("Detected disks:")
    print(format_mounts(mounts))
    return false
  end
  disk_pool = pool
  apply_disk_pool(pool)
  ensure_log_dirs()
  try_label_disk()
  return true
end

local function relocate_bootstrap_if_needed()
  if not CONFIG.DISK_MOUNT_PATH or not shell or not shell.getRunningProgram or not shell.run then
    return false
  end
  local running = shell.getRunningProgram()
  if not running or running == "" then
    return false
  end
  local absolute = running:sub(1, 1) == "/" and running or ("/" .. running)
  local target = CONFIG.STORAGE_ROOT .. "/installer/installer.lua"
  if absolute == target then
    return false
  end
  local current_mount = nil
  if disk_pool and disk_pool.mounts then
    for _, entry in ipairs(disk_pool.mounts) do
      if absolute:sub(1, #entry.path) == entry.path then
        current_mount = entry.path
        break
      end
    end
  end
  local required_free = (CONFIG.DISK_SPACE_MIN_BUFFER or 0) + (CONFIG.DISK_SPACE_OVERHEAD_BYTES or 0)
  local current_free = current_mount and get_free_space(current_mount) or nil
  local target_free = get_free_space(CONFIG.DISK_MOUNT_PATH)
  if current_mount == CONFIG.DISK_MOUNT_PATH then
    return false
  end
  if current_free and current_free >= required_free then
    return false
  end
  if not target_free or target_free < required_free then
    return false
  end
  if current_free and (target_free - current_free) < required_free then
    return false
  end
  ensure_dir(fs.getDir(target))
  local ok_copy = pcall(fs.copy, absolute, target)
  if not ok_copy then
    return false
  end
  print("Relocating installer to disk: " .. target)
  shell.run(target)
  return true
end

local function ensure_dir(path)
  if path and path ~= "" and not fs.exists(path) then
    pcall(fs.makeDir, path)
  end
end

local function get_free_space(path)
  local probe = path
  if probe == "" or not probe then
    probe = "/"
  end
  if not fs.exists(probe) then
    probe = fs.getDir(probe)
    if probe == "" then
      probe = "/"
    end
  end
  local ok, free = pcall(fs.getFreeSpace, probe)
  if not ok then
    return nil, probe
  end
  return free, probe
end

local function ensure_free_space(path, needed, context)
  local free, probe = get_free_space(path)
  if not free then
    log_line("WARN", "fs", "Unable to read free space for " .. tostring(probe))
    return true
  end
  if needed and free < needed then
    local message = string.format("Out of space (%s). Need %d bytes, free %d bytes.", tostring(context or path), needed, free)
    log_line("ERROR", "fs", message)
    return false, message
  end
  return true
end

local function remove_dir_contents(path)
  if not path or path == "" or not fs.exists(path) or not fs.isDir(path) then
    return
  end
  for _, entry in ipairs(fs.list(path)) do
    pcall(fs.delete, fs.combine(path, entry))
  end
end

local function cleanup_storage_for_space()
  local removed = {}
  local function delete_log_files(path)
    if not path or path == "" or not fs.exists(path) or not fs.isDir(path) then
      return
    end
    for _, entry in ipairs(fs.list(path)) do
      if entry:match("%.log$") then
        local target = fs.combine(path, entry)
        if pcall(fs.delete, target) then
          table.insert(removed, target)
        end
      end
    end
  end
  delete_log_files(CONFIG.LOG_DIR)
  if CONFIG.LOG_DIR ~= "/xreactor_logs" then
    delete_log_files("/xreactor_logs")
  end
  remove_dir_contents(CONFIG.BACKUP_DIR)
  remove_dir_contents(CONFIG.STAGE_DIR)
  if CONFIG.BACKUP_DIR ~= "/xreactor_backup" then
    remove_dir_contents("/xreactor_backup")
  end
  if CONFIG.STAGE_DIR ~= "/xreactor_stage" then
    remove_dir_contents("/xreactor_stage")
  end
  if #removed > 0 then
    log_line("INFO", "fs", "Cleanup removed: " .. table.concat(removed, ", "))
  end
end

local function ensure_core_space(expected_bytes)
  if not expected_bytes then
    return true
  end
  local needed = expected_bytes + (CONFIG.DISK_SPACE_OVERHEAD_BYTES or 0) + (CONFIG.DISK_SPACE_MIN_BUFFER or 0)
  local ok, err = ensure_free_space(CONFIG.CORE_DOWNLOAD_PATH, needed, "Core download")
  if ok then
    return true
  end
  cleanup_storage_for_space()
  ok, err = ensure_free_space(CONFIG.CORE_DOWNLOAD_PATH, needed, "Core download (after cleanup)")
  if ok then
    return true
  end
  if select_mount_for_bytes(needed) then
    cleanup_storage_for_space()
    ok, err = ensure_free_space(CONFIG.CORE_DOWNLOAD_PATH, needed, "Core download (after disk switch)")
    if ok then
      return true
    end
  end
  print("ERROR: Not enough disk space for installer core download.")
  print("Detected disks:")
  print(format_mounts(list_disk_mounts()))
  return false, err
end

local function now_stamp()
  return textutils.formatTime(os.epoch("utc") / 1000, true)
end

format_bytes = function(bytes)
  local value = tonumber(bytes or 0) or 0
  local units = { "B", "KB", "MB", "GB" }
  local idx = 1
  while value >= 1024 and idx < #units do
    value = value / 1024
    idx = idx + 1
  end
  if idx == 1 then
    return tostring(math.floor(value)) .. units[idx]
  end
  return string.format("%.1f%s", value, units[idx])
end

local function resolve_log_enabled()
  if CONFIG.LOG_ENABLED ~= nil then
    return CONFIG.LOG_ENABLED == true
  end
  return true
end

local function rotate_log_if_needed(path)
  if not fs.exists(path) then
    return
  end
  if fs.getSize(path) < CONFIG.LOG_MAX_BYTES then
    return
  end
  local backup = path .. CONFIG.LOG_BACKUP_SUFFIX
  if fs.exists(backup) then
    fs.delete(backup)
  end
  fs.move(path, backup)
end

local log_state = {
  enabled = nil,
  buffer = {},
  last_flush = 0,
  path = CONFIG.LOG_PATH,
  fallback_path = CONFIG.LOG_FALLBACK_PATH,
  fallback_used = false,
  memory_fallback = {},
  last_write_ok = false,
  last_failed_path = nil
}

local function ensure_log_dirs()
  pcall(fs.makeDir, CONFIG.STORAGE_ROOT or "/xreactor")
  pcall(fs.makeDir, CONFIG.LOG_DIR or "/xreactor_logs")
  pcall(fs.makeDir, CONFIG.STAGE_DIR or "/xreactor_stage")
  pcall(fs.makeDir, CONFIG.BACKUP_DIR or "/xreactor_backup")
  if disk_pool and disk_pool.mounts then
    for _, entry in ipairs(disk_pool.mounts) do
      pcall(fs.makeDir, entry.path .. "/xreactor")
      pcall(fs.makeDir, entry.path .. "/xreactor_logs")
      pcall(fs.makeDir, entry.path .. "/xreactor_stage")
      pcall(fs.makeDir, entry.path .. "/xreactor_backup")
    end
  end
end

local function print_storage_summary()
  local free_root = get_free_space(CONFIG.STORAGE_ROOT or "/")
  print("=== Installer Storage Summary ===")
  print("Storage root: " .. tostring(CONFIG.STORAGE_ROOT))
  print("Stage root: " .. tostring(CONFIG.STAGE_DIR))
  print("Backup root: " .. tostring(CONFIG.BACKUP_DIR))
  print("Log root: " .. tostring(CONFIG.LOG_DIR))
  print("Free space: " .. format_bytes(free_root or 0))
end

local function open_log_file()
  ensure_log_dirs()
  local file = fs.open(log_state.path, "a")
  if file then
    return file
  end
  print("Warning: unable to open log file at " .. tostring(log_state.path))
  if log_state.fallback_path and log_state.path ~= log_state.fallback_path then
    log_state.path = log_state.fallback_path
    log_state.fallback_used = true
    file = fs.open(log_state.path, "a")
    if file then
      return file
    end
  end
  if log_state.path ~= CONFIG.LOG_FALLBACK_PATH then
    log_state.path = CONFIG.LOG_FALLBACK_PATH
    log_state.fallback_used = true
    file = fs.open(log_state.path, "a")
    if file then
      return file
    end
  end
  print("Warning: fallback log file unavailable; continuing without file logging.")
  log_state.last_failed_path = log_state.path
  return nil
end

local function get_log_path()
  if log_state.last_write_ok and log_state.path and fs.exists(log_state.path) then
    return log_state.path
  end
  if log_state.fallback_used and fs.exists(CONFIG.LOG_FALLBACK_PATH) then
    return CONFIG.LOG_FALLBACK_PATH
  end
  return "RAM (printed below)"
end

local function flush_log(force)
  if not log_state.enabled then
    return
  end
  if #log_state.buffer == 0 then
    return
  end
  local elapsed = os.clock() - (log_state.last_flush or 0)
  if not force and #log_state.buffer < CONFIG.LOG_FLUSH_LINES and elapsed < CONFIG.LOG_FLUSH_INTERVAL then
    return
  end
  local ok = pcall(function()
    rotate_log_if_needed(log_state.path)
    local file = open_log_file()
    if not file then
      return false
    end
    for _, line in ipairs(log_state.buffer) do
      file.write(line .. "\n")
    end
    file.close()
    return true
  end)
  if ok then
    log_state.last_write_ok = true
    log_state.buffer = {}
    log_state.last_flush = os.clock()
  else
    if not log_state.fallback_used then
      print("Warning: log write failed; continuing without file logging.")
      log_state.fallback_used = true
    end
    log_state.last_write_ok = false
    for _, line in ipairs(log_state.buffer) do
      table.insert(log_state.memory_fallback, line)
    end
    log_state.buffer = {}
  end
end

log_line = function(level, module, message)
  if log_state.enabled == nil then
    log_state.enabled = resolve_log_enabled()
    log_state.last_flush = os.clock()
  end
  if not log_state.enabled then
    return
  end
  table.insert(log_state.buffer, string.format("[%s] %s | %s | %s", now_stamp(), tostring(level), tostring(module), tostring(message)))
  flush_log(true)
end

local function flush_memory_fallback()
  if #log_state.memory_fallback == 0 then
    return
  end
  print("=== INSTALLER DEBUG LOG (RAM) ===")
  for _, line in ipairs(log_state.memory_fallback) do
    print(line)
  end
  log_state.memory_fallback = {}
end

local function print_debug_summary(context)
  local free = get_free_space(CONFIG.STORAGE_ROOT or "/")
  print("=== Installer Debug Summary ===")
  if context then
    print("Context: " .. tostring(context))
  end
  print("Storage root: " .. tostring(CONFIG.STORAGE_ROOT or "/xreactor"))
  print("Free space: " .. format_bytes(free or 0))
  print("Stage path: " .. tostring(CONFIG.STAGE_DIR or "/xreactor_stage"))
  print("Log path: " .. tostring(get_log_path()))
end

local function init_log_file()
  ensure_log_dirs()
  local file = open_log_file()
  if file then
    file.write("")
    file.close()
    log_state.last_write_ok = true
  end
end

local function announce_log_location()
  flush_log(true)
  local location = get_log_path()
  print("Details logged to: " .. tostring(location))
  if location == "RAM (printed below)" then
    flush_memory_fallback()
  end
end

local function run_with_trace(module, label, fn)
  local ok, err = xpcall(fn, function(message)
    return debug.traceback(tostring(message), 2)
  end)
  if not ok then
    log_line("ERROR", module, label .. " failed: " .. tostring(err))
  end
  return ok, err
end

local function confirm(prompt_text, default)
  local hint = default and "Y/n" or "y/N"
  write(prompt_text .. " (" .. hint .. "): ")
  local input = (read() or ""):lower()
  if input == "" then
    return default
  end
  return input == "y" or input == "yes"
end

local function sanitize_signature(prefix)
  if not prefix or prefix == "" then
    return ""
  end
  local sample = prefix:gsub("[%c]", ".")
  return sample:sub(1, CONFIG.LOG_SAMPLE_BYTES or 96)
end

local function quick_install_block()
  local url = CONFIG.QUICK_INSTALL_URL
  local target = CONFIG.QUICK_INSTALL_TARGET
  if not url or not target then
    return nil
  end
  return ("wget %s %s\n%s"):format(url, target, target)
end

local function print_quick_install_hint()
  local block = quick_install_block()
  if not block then
    return
  end
  print("Quick Install (RAW, beta):")
  for line in block:gmatch("[^\n]+") do
    print("  " .. line)
  end
  print("Hinweis: Niemals GitHub /blob/ Links nutzen (HTML -> Lua-Fehler).")
end

local function detect_html(body_prefix)
  if not body_prefix or body_prefix == "" then
    return false
  end
  local head = body_prefix:sub(1, 512)
  local lower = head:lower()
  if lower:find("<!doctype", 1, true) or lower:find("<html", 1, true) then
    return true
  end
  if lower:find("<body", 1, true) or lower:find("<head", 1, true) or lower:find("<title", 1, true) then
    return true
  end
  if lower:find("rate limit", 1, true) or lower:find("not found", 1, true) then
    return true
  end
  if lower:find("cloudflare", 1, true) then
    return true
  end
  if head:match("^%s*<") then
    return true
  end
  return false
end

local function validate_response(status_code, headers, body_prefix, body_len)
  if status_code and status_code ~= 200 then
    return false, "http " .. tostring(status_code)
  end
  if detect_html(body_prefix) then
    return false, "html response"
  end
  local content_length = headers and (headers["Content-Length"] or headers["content-length"])
  if content_length then
    local expected = tonumber(content_length)
    if expected and body_len and expected ~= body_len then
      return false, "size mismatch"
    end
  end
  return true
end

local function read_response_body(response, chunk_size)
  local chunks = {}
  local total = 0
  while true do
    local chunk = nil
    if response.read then
      chunk = response.read(chunk_size)
    elseif response.readLine then
      local line = response.readLine()
      if line then
        chunk = line .. "\n"
      end
    end
    if not chunk then
      break
    end
    total = total + #chunk
    table.insert(chunks, chunk)
  end
  return table.concat(chunks), total
end

local function fetch_url(url)
  if not http or not http.get then
    log_line("ERROR", "http", "HTTP API unavailable")
    return false, nil, "HTTP API unavailable", { url = url }
  end
  local response
  local err
  if http.request and CONFIG.DOWNLOAD_TIMEOUT then
    log_line("INFO", "http", "http.request -> " .. tostring(url))
    local ok, req_err = pcall(http.request, url, nil, nil, false)
    if not ok then
      log_line("ERROR", "http", "http.request failed: " .. tostring(req_err))
      return false, nil, "http.request failed (" .. tostring(req_err) .. ")", { url = url }
    end
    local timer = os.startTimer(CONFIG.DOWNLOAD_TIMEOUT)
    while true do
      local event, p1, p2 = os.pullEvent()
      if event == "http_success" and p1 == url then
        response = p2
        break
      elseif event == "http_failure" and p1 == url then
        log_line("WARN", "http", "http_failure: " .. tostring(p2))
        return false, nil, "http failure (" .. tostring(p2) .. ")", { url = url }
      elseif event == "timer" and p1 == timer then
        log_line("WARN", "http", "http timeout")
        return false, nil, "timeout", { url = url }
      end
    end
  else
    local ok, result = pcall(function() return http.get(url) end)
    log_line("INFO", "http", string.format("http.get -> %s (ok=%s, response=%s)", tostring(url), tostring(ok), tostring(result ~= nil)))
    if ok then
      response = result
    else
      err = result
    end
    if not response then
      log_line("WARN", "http", "http.get returned nil: " .. tostring(err))
      return false, nil, "http.get returned nil" .. (err and (" (" .. tostring(err) .. ")") or ""), { url = url }
    end
  end
  local code = response.getResponseCode and response.getResponseCode() or nil
  local headers = response.getResponseHeaders and response.getResponseHeaders() or nil
  local body, body_len = read_response_body(response, 8192)
  response.close()
  local prefix = body and body:sub(1, 1024) or ""
  local meta = {
    url = url,
    code = code,
    headers = headers,
    bytes = body_len or 0,
    signature = sanitize_signature(prefix)
  }
  local header_dump = headers and textutils.serialize(headers) or "n/a"
  log_line("INFO", "http", string.format("HTTP response: url=%s code=%s bytes=%s sig=%s",
    tostring(url),
    tostring(code or "n/a"),
    tostring(body and #body or 0),
    tostring(sanitize_signature(prefix))
  ))
  log_line("INFO", "http", "HTTP headers: " .. tostring(header_dump))
  log_line("INFO", "http", "HTTP body sample: " .. tostring(sanitize_signature(prefix)))
  if not body or body == "" then
    return false, nil, "empty body", meta
  end
  local ok, reason = validate_response(code, headers, prefix, body_len or 0)
  if not ok then
    return false, nil, reason, meta
  end
  return true, body, nil, meta
end

local function read_stream_chunk(handle, size)
  if handle.read then
    return handle.read(size)
  end
  if handle.readLine then
    local line = handle.readLine()
    if line then
      return line .. "\n"
    end
  end
  return nil
end

local function fetch_url_stream(url, target_path)
  if not http or not http.get then
    log_line("ERROR", "http", "HTTP API unavailable")
    return false, "HTTP API unavailable", { url = url }
  end
  local response
  local err
  if http.request and CONFIG.DOWNLOAD_TIMEOUT then
    log_line("INFO", "http", "http.request -> " .. tostring(url))
    local ok, req_err = pcall(http.request, url, nil, nil, false)
    if not ok then
      log_line("ERROR", "http", "http.request failed: " .. tostring(req_err))
      return false, "http.request failed (" .. tostring(req_err) .. ")", { url = url }
    end
    local timer = os.startTimer(CONFIG.DOWNLOAD_TIMEOUT)
    while true do
      local event, p1, p2 = os.pullEvent()
      if event == "http_success" and p1 == url then
        response = p2
        break
      elseif event == "http_failure" and p1 == url then
        log_line("WARN", "http", "http_failure: " .. tostring(p2))
        return false, "http failure (" .. tostring(p2) .. ")", { url = url }
      elseif event == "timer" and p1 == timer then
        log_line("WARN", "http", "http timeout")
        return false, "timeout", { url = url }
      end
    end
  else
    local ok, result = pcall(function() return http.get(url) end)
    log_line("INFO", "http", string.format("http.get -> %s (ok=%s, response=%s)", tostring(url), tostring(ok), tostring(result ~= nil)))
    if ok then
      response = result
    else
      err = result
    end
    if not response then
      log_line("WARN", "http", "http.get returned nil: " .. tostring(err))
      return false, "http.get returned nil" .. (err and (" (" .. tostring(err) .. ")") or ""), { url = url }
    end
  end

  local code = response.getResponseCode and response.getResponseCode() or nil
  local headers = response.getResponseHeaders and response.getResponseHeaders() or nil
  local file = fs.open(target_path, "wb")
  if not file then
    response.close()
    return false, "file open failed", { url = url, code = code, headers = headers }
  end
  local bytes = 0
  local signature = ""
  local chunk_size = CONFIG.DOWNLOAD_STREAM_CHUNK_SIZE or 4096
  local ok, read_err = pcall(function()
    while true do
      local chunk = read_stream_chunk(response, chunk_size)
      if not chunk then
        break
      end
      bytes = bytes + #chunk
      if #signature < (CONFIG.LOG_SAMPLE_BYTES or 0) then
        local needed = (CONFIG.LOG_SAMPLE_BYTES or 0) - #signature
        signature = signature .. chunk:sub(1, needed)
      end
      file.write(chunk)
    end
  end)
  file.close()
  response.close()
  if not ok then
    return false, read_err, { url = url, code = code, headers = headers, bytes = bytes }
  end
  local meta = {
    url = url,
    code = code,
    headers = headers,
    bytes = bytes,
    signature = sanitize_signature(signature)
  }
  local header_dump = headers and textutils.serialize(headers) or "n/a"
  log_line("INFO", "http", string.format("HTTP response: url=%s code=%s bytes=%s sig=%s",
    tostring(url),
    tostring(code or "n/a"),
    tostring(bytes),
    tostring(sanitize_signature(signature))
  ))
  log_line("INFO", "http", "HTTP headers: " .. tostring(header_dump))
  log_line("INFO", "http", "HTTP body sample: " .. tostring(sanitize_signature(signature)))
  if bytes == 0 then
    return false, "empty body", meta
  end
  local ok_resp, reason = validate_response(code, headers, signature, bytes)
  if not ok_resp then
    return false, reason, meta
  end
  return true, nil, meta
end

local function join_url(base, path)
  local cleaned_path = path:gsub("^/", "")
  if base:sub(-1) ~= "/" then
    return base .. "/" .. cleaned_path
  end
  return base .. cleaned_path
end

local function build_raw_urls(path, commit_sha)
  local urls = {}
  local seen = {}
  local repo_path = string.format("/%s/%s/%s/", CONFIG.REPO_OWNER, CONFIG.REPO_NAME, commit_sha or "main")
  for _, host in ipairs(CONFIG.BASE_URLS) do
    local url = join_url(host .. repo_path, path)
    if not seen[url] then
      table.insert(urls, url)
      seen[url] = true
    end
  end
  return urls
end

local fetch_url_seeded = false

local function fetch_with_retries(urls, attempts, module_name)
  local last_meta
  local module_tag = module_name or "installer"
  if not fetch_url_seeded then
    math.randomseed(os.time())
    fetch_url_seeded = true
  end
  local max_attempts = attempts or CONFIG.DOWNLOAD_ATTEMPTS
  for attempt = 1, max_attempts do
    for _, url in ipairs(urls or {}) do
      local ok, body, err, meta = fetch_url(url)
      last_meta = meta or { url = url, err = err }
      if ok then
        log_line("INFO", module_tag, string.format("Download ok: url=%s code=%s bytes=%s sig=%s attempt=%d",
          tostring(url),
          tostring(meta and meta.code or "n/a"),
          tostring(meta and meta.bytes or 0),
          tostring(meta and meta.signature or ""),
          attempt
        ))
        return true, body, meta
      end
      log_line("WARN", module_tag, string.format("Download failed: url=%s err=%s code=%s sig=%s attempt=%d",
        tostring(url),
        tostring(err),
        tostring(meta and meta.code or "n/a"),
        tostring(meta and meta.signature or ""),
        attempt
      ))
    end
    if attempt < max_attempts then
      local jitter = math.random() * (CONFIG.DOWNLOAD_JITTER or 0)
      os.sleep((CONFIG.DOWNLOAD_BACKOFF * attempt) + jitter)
    end
  end
  return false, nil, last_meta
end

local function download_with_retries_to_path(urls, attempts, module_name, target_path)
  local last_meta
  local module_tag = module_name or "installer"
  if not fetch_url_seeded then
    math.randomseed(os.time())
    fetch_url_seeded = true
  end
  local max_attempts = attempts or CONFIG.DOWNLOAD_ATTEMPTS
  for attempt = 1, max_attempts do
    for _, url in ipairs(urls or {}) do
      cleanup_temp_file(target_path)
      local ok, err, meta = fetch_url_stream(url, target_path)
      last_meta = meta or { url = url, err = err }
      if ok then
        log_line("INFO", module_tag, string.format("Download ok: url=%s code=%s bytes=%s sig=%s attempt=%d",
          tostring(url),
          tostring(meta and meta.code or "n/a"),
          tostring(meta and meta.bytes or 0),
          tostring(meta and meta.signature or ""),
          attempt
        ))
        return true, meta
      end
      log_line("WARN", module_tag, string.format("Download failed: url=%s err=%s code=%s sig=%s attempt=%d",
        tostring(url),
        tostring(err),
        tostring(meta and meta.code or "n/a"),
        tostring(meta and meta.signature or ""),
        attempt
      ))
    end
    if attempt < max_attempts then
      local jitter = math.random() * (CONFIG.DOWNLOAD_JITTER or 0)
      os.sleep((CONFIG.DOWNLOAD_BACKOFF * attempt) + jitter)
    end
  end
  return false, last_meta
end

local function downloadFile(path, ref, opts)
  local urls = (opts and opts.urls) or build_raw_urls(path, ref)
  local attempts = opts and opts.attempts or nil
  local module_name = opts and opts.module_name or nil
  return fetch_with_retries(urls, attempts, module_name)
end

local function build_crc32_table()
  local table_out = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if bit32.band(crc, 1) == 1 then
        crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
      else
        crc = bit32.rshift(crc, 1)
      end
    end
    table_out[i] = crc
  end
  return table_out
end

local crc32_table

local function crc32_hash(content)
  if not crc32_table then
    crc32_table = build_crc32_table()
  end
  local crc = 0xFFFFFFFF
  for i = 1, #content do
    local byte = string.byte(content, i)
    local idx = bit32.band(bit32.bxor(crc, byte), 0xFF)
    crc = bit32.bxor(bit32.rshift(crc, 8), crc32_table[idx])
  end
  return string.format("%08x", bit32.bnot(crc))
end

local function normalize_newlines(content)
  if not content then
    return ""
  end
  local normalized = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  if normalized:sub(1, 3) == "\239\187\191" then
    normalized = normalized:sub(4)
  end
  return normalized
end

local function hash_core_content(content)
  return crc32_hash(normalize_newlines(content))
end

local function crc32_update(crc, byte)
  local idx = bit32.band(bit32.bxor(crc, byte), 0xFF)
  return bit32.bxor(bit32.rshift(crc, 8), crc32_table[idx])
end

local function hash_core_file(path)
  if not crc32_table then
    crc32_table = build_crc32_table()
  end
  local file = fs.open(path, "r")
  if not file then
    return nil
  end
  local crc = 0xFFFFFFFF
  local prev_cr = false
  local bom_buffer = ""
  local chunk_size = 4096
  while true do
    local chunk = file.read(chunk_size)
    if not chunk then
      break
    end
    if #bom_buffer < 3 then
      local needed = 3 - #bom_buffer
      bom_buffer = bom_buffer .. chunk:sub(1, needed)
      chunk = chunk:sub(needed + 1)
      if #bom_buffer == 3 and bom_buffer == "\239\187\191" then
        bom_buffer = ""
      end
    end
    if #bom_buffer > 0 then
      chunk = bom_buffer .. chunk
      bom_buffer = ""
    end
    for i = 1, #chunk do
      local byte = string.byte(chunk, i)
      if prev_cr then
        if byte == 10 then
          crc = crc32_update(crc, 10)
          prev_cr = false
          goto continue
        end
        crc = crc32_update(crc, 10)
        prev_cr = false
      end
      if byte == 13 then
        prev_cr = true
      else
        crc = crc32_update(crc, byte)
      end
      ::continue::
    end
  end
  if prev_cr then
    crc = crc32_update(crc, 10)
  end
  file.close()
  return string.format("%08x", bit32.bnot(crc))
end

local function append_cache_bust(url, seed)
  if not url or url == "" then
    return url
  end
  local token = tostring(seed or os.epoch("utc") or os.time())
  if url:find("?", 1, true) then
    return url .. "&cb=" .. token
  end
  return url .. "?cb=" .. token
end

local function write_file(path, content)
  ensure_dir(fs.getDir(path))
  local needed = (content and #content or 0) + (CONFIG.DISK_SPACE_OVERHEAD_BYTES or 0) + (CONFIG.DISK_SPACE_MIN_BUFFER or 0)
  local ok_space, space_err = ensure_free_space(path, needed, "Write " .. tostring(path))
  if not ok_space then
    return false, space_err
  end
  local file = fs.open(path, "w")
  if not file then
    return false
  end
  local ok, err = pcall(function()
    local chunk = 4096
    local length = #content
    local index = 1
    while index <= length do
      file.write(content:sub(index, index + chunk - 1))
      index = index + chunk
    end
  end)
  file.close()
  if not ok then
    return false, err
  end
  return true
end

local function write_atomic(path, content)
  ensure_dir(fs.getDir(path))
  local tmp = path .. ".tmp"
  local needed = (content and #content or 0) + (CONFIG.DISK_SPACE_OVERHEAD_BYTES or 0) + (CONFIG.DISK_SPACE_MIN_BUFFER or 0)
  local ok_space, space_err = ensure_free_space(path, needed, "Write " .. tostring(path))
  if not ok_space then
    return false, space_err
  end
  local file = fs.open(tmp, "w")
  if not file then
    return false
  end
  local ok, err = pcall(function()
    local chunk = 4096
    local length = #content
    local index = 1
    while index <= length do
      file.write(content:sub(index, index + chunk - 1))
      index = index + chunk
    end
  end)
  file.close()
  if not ok then
    if fs.exists(tmp) then
      fs.delete(tmp)
    end
    return false, err
  end
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
  return true
end

local function move_atomic_with_backup(temp_path, target_path)
  local backup_path = target_path .. ".bak"
  if fs.exists(backup_path) then
    fs.delete(backup_path)
  end
  if fs.exists(target_path) then
    local ok_backup = pcall(fs.move, target_path, backup_path)
    if not ok_backup then
      return false, "backup failed"
    end
  end
  local ok_move = pcall(fs.move, temp_path, target_path)
  if not ok_move or not fs.exists(target_path) then
    if fs.exists(backup_path) then
      pcall(fs.move, backup_path, target_path)
    end
    return false, "move failed"
  end
  return true
end

local function read_file(path)
  if not fs.exists(path) then
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

local function ensure_package_path()
  if not package or not package.path then
    return
  end
  local root = CONFIG.STORAGE_ROOT or "/xreactor"
  if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = package.path .. ";" .. root .. "/?.lua"
  end
  if not package.path:find(root .. "/?/init.lua", 1, true) then
    package.path = package.path .. ";" .. root .. "/?/init.lua"
  end
end

local function load_release()
  local temp_path = CONFIG.STORAGE_ROOT .. "/.tmp/release.lua.download"
  local urls = build_raw_urls(CONFIG.RELEASE_PATH, CONFIG.RELEASE_BRANCH)
  local ok, meta = download_with_retries_to_path(urls, 1, "release", temp_path)
  if not ok then
    return nil, meta
  end
  local loader, load_err = loadfile(temp_path)
  if not loader then
    return nil, { err = "release load failed", detail = load_err }
  end
  local ok_exec, data = pcall(loader)
  if not ok_exec or type(data) ~= "table" then
    return nil, { err = "release parse failed" }
  end
  return data, meta
end

local function read_file_prefix(path, max_bytes)
  if not fs.exists(path) then
    return nil
  end
  local file = fs.open(path, "r")
  if not file then
    return nil
  end
  local content = file.read(max_bytes)
  file.close()
  return content
end

local function file_contains_marker(path, marker)
  if not marker or marker == "" then
    return true
  end
  local file = fs.open(path, "r")
  if not file then
    return false
  end
  local chunk_size = 4096
  local buffer = ""
  while true do
    local chunk = file.read(chunk_size)
    if not chunk then
      break
    end
    buffer = buffer .. chunk
    if buffer:find(marker, 1, true) then
      file.close()
      return true
    end
    if #buffer > #marker then
      buffer = buffer:sub(-#marker)
    end
  end
  file.close()
  return false
end

local function parse_core_version_from_file(path)
  local prefix = read_file_prefix(path, 4096)
  if not prefix then
    return nil
  end
  return prefix:match("INSTALLER_CORE_VERSION%s*=%s*\"([^\"]+)\"")
end

local function validate_core_file(path)
  if not path or not fs.exists(path) then
    return false, "core missing"
  end
  local size = fs.getSize(path)
  if not size or size < CONFIG.MIN_CORE_BYTES then
    return false, "core too small"
  end
  local prefix = read_file_prefix(path, 512) or ""
  if detect_html(prefix) then
    return false, "html response"
  end
  if not file_contains_marker(path, CONFIG.CORE_SANITY_MARKER) then
    return false, "core sanity marker missing"
  end
  local loader, load_err = loadfile(path)
  if not loader then
    return false, "core load failed", load_err
  end
  return true
end

local function load_local_core()
  if not fs.exists(CONFIG.CORE_PATH) then
    return nil, "core missing"
  end
  local valid, reason, detail = validate_core_file(CONFIG.CORE_PATH)
  if not valid then
    return nil, reason or detail
  end
  local loader, load_err = loadfile(CONFIG.CORE_PATH)
  if not loader then
    return nil, load_err
  end
  return loader
end

cleanup_temp_file = function(path)
  if path and fs.exists(path) then
    fs.delete(path)
  end
end

local function save_bad_core_file(path)
  if not path or not fs.exists(path) then
    return
  end
  ensure_dir(fs.getDir(CONFIG.CORE_BAD_PATH))
  pcall(function()
    fs.copy(path, CONFIG.CORE_BAD_PATH)
  end)
end

local function log_core_failure(reason, meta)
  log_line("ERROR", "installer_core", string.format(
    "Core download failed: reason=%s detail=%s url=%s code=%s bytes=%s sig=%s expected=%s actual=%s",
    tostring(reason),
    tostring(meta and meta.detail or ""),
    tostring(meta and meta.url or ""),
    tostring(meta and meta.code or "n/a"),
    tostring(meta and meta.bytes or "n/a"),
    tostring(meta and meta.signature or ""),
    tostring(meta and meta.expected_hash or ""),
    tostring(meta and meta.actual_hash or "")
  ))
end

local function should_cache_bust(err)
  local value = tostring(err or "")
  return value == "checksum mismatch"
    or value == "core loadfile failed"
    or value == "core load failed"
    or value == "html response"
    or value == "core sanity marker missing"
end

local function attempt_core_recovery(release, reason)
  if not release then
    return false, "release metadata unavailable"
  end
  log_line("WARN", "installer_core", "Attempting core recovery: " .. tostring(reason or "unknown"))
  local ok, _, meta = download_core(release, { cache_bust = true })
  if not ok then
    return false, meta
  end
  return true, meta
end

local function save_core_meta(payload)
  local ok, serialized = pcall(textutils.serialize, payload)
  if not ok then
    return
  end
  write_file(CONFIG.CORE_META_PATH, serialized)
end

local function read_core_meta()
  local content = read_file(CONFIG.CORE_META_PATH)
  if not content then
    return nil
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

local function needs_core_update(release)
  if not fs.exists(CONFIG.CORE_PATH) then
    return true
  end
  if not release then
    return false
  end
  local local_hash = hash_core_file(CONFIG.CORE_PATH)
  if not local_hash then
    return true
  end
  local local_version = parse_core_version_from_file(CONFIG.CORE_PATH)
  local meta = read_core_meta() or {}
  if release.installer_core_hash and release.installer_core_hash ~= local_hash then
    return true
  end
  if release.installer_core_version and local_version and release.installer_core_version ~= local_version then
    return true
  end
  if meta and meta.hash and meta.hash ~= local_hash then
    return true
  end
  return false
end

local function download_core(release, opts)
  local commit_sha = release and release.commit_sha
  local cache_bust = opts and opts.cache_bust or false
  local urls = build_raw_urls("xreactor/installer/installer_core.lua", commit_sha)
  if cache_bust then
    local busted = {}
    for _, url in ipairs(urls) do
      table.insert(busted, append_cache_bust(url))
    end
    urls = busted
  end
  local expected_size = release and release.installer_core_size_bytes or nil
  local space_ok, space_err = ensure_core_space(expected_size)
  if not space_ok then
    cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
    return false, nil, { err = space_err or "out of space" }
  end
  local ok, meta = download_with_retries_to_path(urls, 1, "installer_core", CONFIG.CORE_DOWNLOAD_PATH)
  if not ok then
    if meta then
      meta.cache_bust = cache_bust
    end
    cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
    return false, nil, meta
  end
  local valid, reason, detail = validate_core_file(CONFIG.CORE_DOWNLOAD_PATH)
  if not valid then
    save_bad_core_file(CONFIG.CORE_DOWNLOAD_PATH)
    cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
    return false, nil, {
      err = reason,
      detail = detail,
      url = meta and meta.url,
      code = meta and meta.code,
      bytes = meta and meta.bytes,
      signature = meta and meta.signature
    }
  end
  if release and release.installer_core_hash then
    local hash = hash_core_file(CONFIG.CORE_DOWNLOAD_PATH)
    if not hash or hash ~= release.installer_core_hash then
      cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
      return false, nil, {
        err = "checksum mismatch",
        url = meta and meta.url,
        code = meta and meta.code,
        bytes = meta and meta.bytes,
        signature = meta and meta.signature,
        expected_hash = release.installer_core_hash,
        actual_hash = hash,
        cache_bust = cache_bust
      }
    end
  end
  local moved, move_err = move_atomic_with_backup(CONFIG.CORE_DOWNLOAD_PATH, CONFIG.CORE_PATH)
  if not moved then
    cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
    return false, nil, { err = move_err or "move failed", url = meta and meta.url }
  end
  save_core_meta({
    hash = hash_core_file(CONFIG.CORE_PATH),
    version = parse_core_version_from_file(CONFIG.CORE_PATH) or "unknown",
    saved_at = os.time()
  })
  return true, nil, meta
end

if not http then
  error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
end

ensure_package_path()
init_log_file()
log_line("INFO", "installer", "Bootstrap start")
print_storage_summary()
try_label_disk()
if relocate_bootstrap_if_needed() then
  return
end

local release, release_meta = load_release()
if not release then
  print("Warning: unable to fetch release metadata. Using local installer core if present.")
  log_line("WARN", "installer", "Release metadata unavailable: " .. tostring(release_meta and release_meta.err))
end

if release and needs_core_update(release) then
  print("Checking installer core update...")
  local ok = false
  local meta
  for attempt = 1, (CONFIG.CORE_MAX_RETRIES or 3) do
    log_line("INFO", "installer_core", string.format("Core download attempt %d/%d", attempt, CONFIG.CORE_MAX_RETRIES or 3))
    ok, _, meta = download_core(release)
    if not ok and should_cache_bust(meta and meta.err) then
      log_line("INFO", "installer_core", "Retrying core download with cache-bust parameter")
      ok, _, meta = download_core(release, { cache_bust = true })
    end
    if ok then
      break
    end
    local err_msg = meta and meta.err or "unknown"
    if err_msg == "html response" then
      err_msg = "Downloaded HTML, expected Lua"
    end
    print("Installer core download failed: " .. tostring(err_msg))
    log_line("WARN", "installer_core", "Core download failed: " .. tostring(err_msg))
    flush_log(true)
    announce_log_location()
    if meta and meta.detail then
      print("Detail: " .. tostring(meta.detail))
    end
    if err_msg == "Downloaded HTML, expected Lua" then
      print("Detected HTML instead of Lua. This usually means a GitHub /blob/ link or HTML error page.")
      print_quick_install_hint()
    end
    log_core_failure(err_msg, meta)
    if fs.exists(CONFIG.CORE_PATH) and confirm("Use existing installer core?", true) then
      break
    end
    if attempt >= (CONFIG.CORE_MAX_RETRIES or 3) then
      print("Max retries reached. Aborting core update.")
      print_debug_summary("Installer core update failed")
      break
    end
    if not confirm("Retry download?", true) then
      print_debug_summary("Installer core update cancelled")
      break
    end
    os.sleep((CONFIG.CORE_RETRY_BACKOFF or 1) * attempt)
  end
  if ok then
    print("Installer core updated.")
  end
end

local function run_core_with_retries()
  while true do
    local loader, load_err = load_local_core()
    if not loader then
      print("Installer core missing and could not be loaded.")
      log_line("ERROR", "installer_core", "Installer core missing after bootstrap attempt. err=" .. tostring(load_err))
      local recovered, meta = attempt_core_recovery(release, load_err)
      if recovered then
        loader, load_err = load_local_core()
      end
      if not loader then
        if meta and meta.err then
          log_core_failure(meta.err, meta)
        end
        print_quick_install_hint()
        announce_log_location()
        print_debug_summary("Installer core load failure")
      end
    end

    if loader then
      local run_ok = run_with_trace("installer_core", "Installer core execution", loader)
      announce_log_location()
      if run_ok then
        return true
      end
      print("Installer core failed to run. See log: " .. tostring(get_log_path()))
      print_debug_summary("Installer core execution failed")
    end

    if release and confirm("Retry installer core download?", true) then
      local ok, _, meta = download_core(release, { cache_bust = true })
      if ok then
        print("Installer core updated.")
      else
        print("Installer core download failed: " .. tostring(meta and meta.err or "unknown"))
        log_core_failure(meta and meta.err or "unknown", meta)
      end
    end

    if confirm("Retry running installer core?", true) then
      -- Loop again.
    else
      print("Installer will exit. You can re-run after addressing storage or network issues.")
      return false
    end
  end
end

run_core_with_retries()
