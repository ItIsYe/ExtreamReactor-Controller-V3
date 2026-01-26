-- CONFIG
local CONFIG = {
  CORE_PATH = "/xreactor/installer/installer_core.lua", -- Installed core installer path.
  CORE_META_PATH = "/xreactor/installer/installer_core.meta", -- Stored core metadata snapshot.
  RELEASE_PATH = "xreactor/installer/release.lua", -- Release metadata path.
  REPO_OWNER = "ItIsYe", -- GitHub repository owner.
  REPO_NAME = "ExtreamReactor-Controller-V3", -- GitHub repository name.
  RELEASE_BRANCH = "beta", -- Branch to fetch release metadata from.
  QUICK_INSTALL_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer", -- README Quick Install URL.
  QUICK_INSTALL_TARGET = "installer", -- README Quick Install target filename.
  BASE_URLS = { -- Raw download mirrors (no blob links).
    "https://raw.githubusercontent.com",
    "https://raw.github.com"
  },
  DOWNLOAD_ATTEMPTS = 4, -- Retry attempts per URL.
  DOWNLOAD_BACKOFF = 1, -- Backoff base seconds between retries.
  DOWNLOAD_JITTER = 0.35, -- Max jitter seconds added to backoff.
  DOWNLOAD_TIMEOUT = 8, -- HTTP timeout in seconds (when http.request is available).
  MIN_CORE_BYTES = 200, -- Minimum bytes to accept core download.
  CORE_SANITY_MARKER = "local function main", -- Core sanity marker.
  CORE_DOWNLOAD_PATH = "/xreactor/.tmp/installer_core.lua.download", -- Temp download path for core.
  CORE_BAD_PATH = "/xreactor/.tmp/installer_core.bad", -- Saved bad core content for debugging.
  CORE_MAX_RETRIES = 3, -- Max core download attempts before aborting.
  CORE_RETRY_BACKOFF = 1, -- Backoff seconds between core download retries.
  LOG_ENABLED = nil, -- Enable bootstrap logging (nil uses settings key or default).
  LOG_DEFAULT_ENABLED = true, -- Default logging when settings are unset.
  LOG_SETTINGS_KEY = "xreactor.debug_logging", -- Settings key for debug logging toggle.
  LOG_PATH = "/xreactor/logs/installer_debug.log", -- Bootstrap log file path.
  LOG_FALLBACK_PATH = "/installer_debug.log", -- Fallback log path when /xreactor is unavailable.
  LOG_MAX_BYTES = 200000, -- Max log size before rotation.
  LOG_BACKUP_SUFFIX = ".1", -- Suffix for rotated log.
  LOG_FLUSH_LINES = 6, -- Buffered log lines before flushing.
  LOG_FLUSH_INTERVAL = 1.5, -- Seconds between log flushes.
  LOG_SAMPLE_BYTES = 120 -- Bytes to capture as response signature.
}

local function ensure_dir(path)
  if path and path ~= "" and not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function now_stamp()
  return textutils.formatTime(os.epoch("utc") / 1000, true)
end

local function resolve_log_enabled()
  if CONFIG.LOG_ENABLED ~= nil then
    return CONFIG.LOG_ENABLED == true
  end
  if settings and settings.get and CONFIG.LOG_SETTINGS_KEY then
    return settings.get(CONFIG.LOG_SETTINGS_KEY) == true
  end
  return CONFIG.LOG_DEFAULT_ENABLED == true
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
  fallback_used = false,
  memory_fallback = {},
  last_write_ok = false
}

local function ensure_log_dirs()
  pcall(function()
    if not fs.exists("/xreactor") then
      fs.makeDir("/xreactor")
    end
    if not fs.exists("/xreactor/logs") then
      fs.makeDir("/xreactor/logs")
    end
  end)
end

local function open_log_file()
  ensure_log_dirs()
  local file = fs.open(log_state.path, "a")
  if file then
    return file
  end
  if log_state.path ~= CONFIG.LOG_FALLBACK_PATH then
    log_state.path = CONFIG.LOG_FALLBACK_PATH
    log_state.fallback_used = true
    file = fs.open(log_state.path, "a")
    if file then
      return file
    end
  end
  return nil
end

local function get_log_path()
  if not log_state.last_write_ok then
    return "RAM (printed on exit)"
  end
  return log_state.path
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
    log_state.last_write_ok = false
    for _, line in ipairs(log_state.buffer) do
      table.insert(log_state.memory_fallback, line)
    end
    log_state.buffer = {}
  end
end

local function log_line(level, message)
  if log_state.enabled == nil then
    log_state.enabled = resolve_log_enabled()
    log_state.last_flush = os.clock()
  end
  if not log_state.enabled then
    return
  end
  table.insert(log_state.buffer, string.format("[%s] BOOTSTRAP | %s | %s", now_stamp(), tostring(level), tostring(message)))
  flush_log(false)
end

local function flush_memory_fallback()
  if #log_state.memory_fallback == 0 then
    return
  end
  print("Installer Debug Log (RAM fallback):")
  for _, line in ipairs(log_state.memory_fallback) do
    print(line)
  end
  log_state.memory_fallback = {}
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

local function fetch_url(url)
  if not http or not http.get then
    log_line("ERROR", "HTTP API unavailable")
    return false, nil, "HTTP API unavailable", { url = url }
  end
  local response
  local err
  if http.request and CONFIG.DOWNLOAD_TIMEOUT then
    local ok, req_err = pcall(http.request, url, nil, nil, false)
    if not ok then
      log_line("ERROR", "http.request failed: " .. tostring(req_err))
      return false, nil, "http.request failed (" .. tostring(req_err) .. ")", { url = url }
    end
    local timer = os.startTimer(CONFIG.DOWNLOAD_TIMEOUT)
    while true do
      local event, p1, p2 = os.pullEvent()
      if event == "http_success" and p1 == url then
        response = p2
        break
      elseif event == "http_failure" and p1 == url then
        log_line("WARN", "http_failure: " .. tostring(p2))
        return false, nil, "http failure (" .. tostring(p2) .. ")", { url = url }
      elseif event == "timer" and p1 == timer then
        log_line("WARN", "http timeout")
        return false, nil, "timeout", { url = url }
      end
    end
  else
    local ok, result = pcall(function() return http.get(url) end)
    if ok then
      response = result
    else
      err = result
    end
    if not response then
      log_line("WARN", "http.get returned nil: " .. tostring(err))
      return false, nil, "http.get returned nil" .. (err and (" (" .. tostring(err) .. ")") or ""), { url = url }
    end
  end
  local code = response.getResponseCode and response.getResponseCode() or nil
  local headers = response.getResponseHeaders and response.getResponseHeaders() or nil
  local body = response.readAll()
  response.close()
  local prefix = body and body:sub(1, 1024) or ""
  local meta = {
    url = url,
    code = code,
    headers = headers,
    bytes = body and #body or 0,
    signature = sanitize_signature(prefix)
  }
  log_line("INFO", string.format("HTTP response: url=%s code=%s bytes=%s sig=%s",
    tostring(url),
    tostring(code or "n/a"),
    tostring(body and #body or 0),
    tostring(sanitize_signature(prefix))
  ))
  if not body or body == "" then
    return false, nil, "empty body", meta
  end
  local ok, reason = validate_response(code, headers, prefix, body and #body or 0)
  if not ok then
    return false, nil, reason, meta
  end
  return true, body, nil, meta
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

local function fetch_with_retries(urls)
  local last_meta
  if not fetch_url_seeded then
    math.randomseed(os.time())
    fetch_url_seeded = true
  end
  for attempt = 1, CONFIG.DOWNLOAD_ATTEMPTS do
    for _, url in ipairs(urls or {}) do
      local ok, body, err, meta = fetch_url(url)
      last_meta = meta or { url = url, err = err }
      if ok then
        log_line("INFO", string.format("Download ok: url=%s code=%s bytes=%s sig=%s attempt=%d",
          tostring(url),
          tostring(meta and meta.code or "n/a"),
          tostring(meta and meta.bytes or 0),
          tostring(meta and meta.signature or ""),
          attempt
        ))
        return true, body, meta
      end
      log_line("WARN", string.format("Download failed: url=%s err=%s code=%s sig=%s attempt=%d",
        tostring(url),
        tostring(err),
        tostring(meta and meta.code or "n/a"),
        tostring(meta and meta.signature or ""),
        attempt
      ))
    end
    if attempt < CONFIG.DOWNLOAD_ATTEMPTS then
      local jitter = math.random() * (CONFIG.DOWNLOAD_JITTER or 0)
      os.sleep((CONFIG.DOWNLOAD_BACKOFF * attempt) + jitter)
    end
  end
  return false, nil, last_meta
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

local function write_file(path, content)
  ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if not file then
    return false
  end
  file.write(content)
  file.close()
  return true
end

local function write_atomic(path, content)
  ensure_dir(fs.getDir(path))
  local tmp = path .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then
    return false
  end
  file.write(content)
  file.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
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
  if not package.path:find("/xreactor/?.lua", 1, true) then
    package.path = package.path .. ";/xreactor/?.lua"
  end
  if not package.path:find("/xreactor/?/init.lua", 1, true) then
    package.path = package.path .. ";/xreactor/?/init.lua"
  end
end

local function load_release()
  local urls = build_raw_urls(CONFIG.RELEASE_PATH, CONFIG.RELEASE_BRANCH)
  local ok, content, meta = fetch_with_retries(urls)
  if not ok then
    return nil, meta
  end
  local loader, load_err = load(content, "release", "t", {})
  if not loader then
    return nil, { err = "release load failed", detail = load_err }
  end
  local ok_exec, data = pcall(loader)
  if not ok_exec or type(data) ~= "table" then
    return nil, { err = "release parse failed" }
  end
  return data, meta
end

local function parse_core_version(content)
  local marker = content:match("INSTALLER_CORE_VERSION%s*=%s*\"([^\"]+)\"")
  return marker
end

local function validate_core(content)
  if not content or #content < CONFIG.MIN_CORE_BYTES then
    return false, "core too small"
  end
  if not content:find(CONFIG.CORE_SANITY_MARKER, 1, true) then
    return false, "core sanity marker missing"
  end
  local loader, load_err = load(content, "installer_core", "t", {})
  if not loader then
    return false, "core load failed", load_err
  end
  return true
end

local function load_local_core()
  if not fs.exists(CONFIG.CORE_PATH) then
    return nil, "core missing"
  end
  local loader, load_err = loadfile(CONFIG.CORE_PATH)
  if not loader then
    return nil, load_err
  end
  return loader
end

local function cleanup_temp_file(path)
  if path and fs.exists(path) then
    fs.delete(path)
  end
end

local function save_bad_core(content)
  if not content or content == "" then
    return
  end
  ensure_dir(fs.getDir(CONFIG.CORE_BAD_PATH))
  pcall(function()
    local file = fs.open(CONFIG.CORE_BAD_PATH, "w")
    if not file then
      return
    end
    file.write(content)
    file.close()
  end)
end

local function log_core_failure(reason, meta)
  log_line("ERROR", string.format(
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
  local local_content = read_file(CONFIG.CORE_PATH)
  if not local_content then
    return true
  end
  local local_hash = crc32_hash(local_content)
  local local_version = parse_core_version(local_content)
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

local function download_core(release)
  local commit_sha = release and release.commit_sha
  local urls = build_raw_urls("xreactor/installer/installer_core.lua", commit_sha)
  local ok, content, meta = fetch_with_retries(urls)
  if not ok then
    return false, nil, meta
  end
  local valid, reason, detail = validate_core(content)
  if not valid then
    save_bad_core(content)
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
    local hash = crc32_hash(content)
    if hash ~= release.installer_core_hash then
      cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
      return false, nil, {
        err = "checksum mismatch",
        url = meta and meta.url,
        code = meta and meta.code,
        bytes = meta and meta.bytes,
        signature = meta and meta.signature,
        expected_hash = release.installer_core_hash,
        actual_hash = hash
      }
    end
  end
  if not write_file(CONFIG.CORE_DOWNLOAD_PATH, content) then
    cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
    return false, nil, { err = "temp write failed", url = meta and meta.url }
  end
  local loader, load_err = loadfile(CONFIG.CORE_DOWNLOAD_PATH)
  if not loader then
    save_bad_core(content)
    cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
    return false, nil, {
      err = "core loadfile failed",
      detail = load_err,
      url = meta and meta.url,
      code = meta and meta.code,
      bytes = meta and meta.bytes,
      signature = meta and meta.signature
    }
  end
  if fs.exists(CONFIG.CORE_PATH) then
    fs.delete(CONFIG.CORE_PATH)
  end
  local moved = pcall(fs.move, CONFIG.CORE_DOWNLOAD_PATH, CONFIG.CORE_PATH)
  if not moved or not fs.exists(CONFIG.CORE_PATH) then
    cleanup_temp_file(CONFIG.CORE_DOWNLOAD_PATH)
    return false, nil, { err = "move failed", url = meta and meta.url }
  end
  save_core_meta({
    hash = crc32_hash(content),
    version = parse_core_version(content) or "unknown",
    saved_at = os.time()
  })
  return true, content, meta
end

if not http then
  error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
end

ensure_package_path()
log_line("INFO", "Bootstrap start")

local release, release_meta = load_release()
if not release then
  print("Warning: unable to fetch release metadata. Using local installer core if present.")
  log_line("WARN", "Release metadata unavailable: " .. tostring(release_meta and release_meta.err))
end

if release and needs_core_update(release) then
  print("Checking installer core update...")
  local ok = false
  local meta
  for attempt = 1, (CONFIG.CORE_MAX_RETRIES or 3) do
    ok, _, meta = download_core(release)
    if ok then
      break
    end
    local err_msg = meta and meta.err or "unknown"
    if err_msg == "html response" then
      err_msg = "Downloaded HTML, expected Lua"
    end
    print("Installer core download failed: " .. tostring(err_msg))
    log_line("WARN", "Core download failed: " .. tostring(err_msg))
    flush_log(true)
    print("Details logged to: " .. tostring(get_log_path()))
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
      break
    end
    if not confirm("Retry download?", true) then
      break
    end
    os.sleep((CONFIG.CORE_RETRY_BACKOFF or 1) * attempt)
  end
  if ok then
    print("Installer core updated.")
  end
end

local loader, load_err = load_local_core()
if not loader then
  print("Installer core missing and could not be loaded.")
  log_line("ERROR", "Installer core missing after bootstrap attempt. err=" .. tostring(load_err))
  print_quick_install_hint()
  flush_log(true)
  flush_memory_fallback()
  return
end

loader()
flush_log(true)
flush_memory_fallback()
