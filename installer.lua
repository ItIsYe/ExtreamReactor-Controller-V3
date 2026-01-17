-- CONFIG
local CONFIG = {
  CORE_PATH = "/xreactor/installer/installer_core.lua", -- Installed core installer path.
  CORE_META_PATH = "/xreactor/installer/installer_core.meta", -- Stored core metadata snapshot.
  RELEASE_PATH = "xreactor/installer/release.lua", -- Release metadata path.
  REPO_OWNER = "ItIsYe", -- GitHub repository owner.
  REPO_NAME = "ExtreamReactor-Controller-V3", -- GitHub repository name.
  BASE_URLS = { -- Raw download mirrors (no blob links).
    "https://raw.githubusercontent.com",
    "https://raw.github.com"
  },
  DOWNLOAD_ATTEMPTS = 4, -- Retry attempts per URL.
  DOWNLOAD_BACKOFF = 1, -- Backoff base seconds between retries.
  DOWNLOAD_TIMEOUT = 8, -- HTTP timeout in seconds (when http.request is available).
  MIN_CORE_BYTES = 200, -- Minimum bytes to accept core download.
  CORE_SANITY_MARKER = "local function main", -- Core sanity marker.
  LOG_ENABLED = false, -- Enable bootstrap logging.
  LOG_PATH = "/xreactor/logs/installer.log", -- Bootstrap log file path.
  LOG_MAX_BYTES = 200000, -- Max log size before rotation.
  LOG_BACKUP_SUFFIX = ".1" -- Suffix for rotated log.
}

local function ensure_dir(path)
  if path and path ~= "" and not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function now_stamp()
  return textutils.formatTime(os.epoch("utc") / 1000, true)
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

local function log_line(level, message)
  if not CONFIG.LOG_ENABLED then
    return
  end
  local ok = pcall(function()
    ensure_dir(fs.getDir(CONFIG.LOG_PATH))
    rotate_log_if_needed(CONFIG.LOG_PATH)
    local file = fs.open(CONFIG.LOG_PATH, "a")
    if not file then
      return
    end
    file.write(string.format("[%s] BOOTSTRAP | %s | %s\n", now_stamp(), tostring(level), tostring(message)))
    file.close()
  end)
  if not ok then
    CONFIG.LOG_ENABLED = false
  end
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

local function is_html_response(body)
  if not body or body == "" then
    return false
  end
  local head = body:sub(1, 512)
  local lower = head:lower()
  if lower:find("<!doctype", 1, true) or lower:find("<html", 1, true) then
    return true
  end
  if lower:find("<body", 1, true) or lower:find("<head", 1, true) then
    return true
  end
  if lower:find("rate limit", 1, true) or lower:find("not found", 1, true) then
    return true
  end
  if head:match("^%s*<") then
    return true
  end
  return false
end

local function fetch_url(url)
  if not http or not http.get then
    return false, nil, "HTTP API unavailable", { url = url }
  end
  local response
  local err
  if http.request and CONFIG.DOWNLOAD_TIMEOUT then
    local ok, req_err = pcall(http.request, url, nil, nil, false)
    if not ok then
      return false, nil, "http.request failed (" .. tostring(req_err) .. ")", { url = url }
    end
    local timer = os.startTimer(CONFIG.DOWNLOAD_TIMEOUT)
    while true do
      local event, p1, p2 = os.pullEvent()
      if event == "http_success" and p1 == url then
        response = p2
        break
      elseif event == "http_failure" and p1 == url then
        return false, nil, "http failure (" .. tostring(p2) .. ")", { url = url }
      elseif event == "timer" and p1 == timer then
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
      return false, nil, "http.get returned nil" .. (err and (" (" .. tostring(err) .. ")") or ""), { url = url }
    end
  end
  local code = response.getResponseCode and response.getResponseCode() or nil
  local headers = response.getResponseHeaders and response.getResponseHeaders() or nil
  local body = response.readAll()
  response.close()
  local meta = { url = url, code = code, headers = headers, bytes = body and #body or 0 }
  if not body or body == "" then
    return false, nil, "empty body", meta
  end
  if is_html_response(body) then
    return false, nil, "html response", meta
  end
  if code and code ~= 200 then
    return false, nil, "http " .. tostring(code), meta
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

local function fetch_with_retries(urls)
  local last_meta
  for attempt = 1, CONFIG.DOWNLOAD_ATTEMPTS do
    for _, url in ipairs(urls or {}) do
      local ok, body, err, meta = fetch_url(url)
      last_meta = meta or { url = url, err = err }
      if ok then
        return true, body, meta
      end
      log_line("WARN", string.format("Download failed: %s (%s)", tostring(url), tostring(err)))
    end
    if attempt < CONFIG.DOWNLOAD_ATTEMPTS then
      os.sleep(CONFIG.DOWNLOAD_BACKOFF * attempt)
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

local function load_release()
  local urls = build_raw_urls(CONFIG.RELEASE_PATH, "main")
  local ok, content, meta = fetch_with_retries(urls)
  if not ok then
    return nil, meta
  end
  local loader = load(content, "release", "t", {})
  if not loader then
    return nil, { err = "release load failed" }
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
  local loader = load(content, "installer_core", "t", {})
  if not loader then
    return false, "core load failed"
  end
  return true
end

local function load_local_core()
  if not fs.exists(CONFIG.CORE_PATH) then
    return nil
  end
  local loader = loadfile(CONFIG.CORE_PATH)
  if not loader then
    return nil
  end
  return loader
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
  local valid, reason = validate_core(content)
  if not valid then
    return false, nil, { err = reason, url = meta and meta.url }
  end
  if release and release.installer_core_hash then
    local hash = crc32_hash(content)
    if hash ~= release.installer_core_hash then
      return false, nil, { err = "checksum mismatch", url = meta and meta.url }
    end
  end
  if not write_file(CONFIG.CORE_PATH, content) then
    return false, nil, { err = "write failed" }
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

local release, release_meta = load_release()
if not release then
  print("Warning: unable to fetch release metadata. Using local installer core if present.")
  log_line("WARN", "Release metadata unavailable: " .. tostring(release_meta and release_meta.err))
end

if release and needs_core_update(release) then
  print("Checking installer core update...")
  local ok, _, meta = download_core(release)
  while not ok do
    print("Installer core download failed. Using local installer core if available.")
    log_line("WARN", "Core download failed: " .. tostring(meta and meta.err))
    if not fs.exists(CONFIG.CORE_PATH) then
      break
    end
    if not confirm("Retry download?", true) then
      break
    end
    ok, _, meta = download_core(release)
  end
  if ok then
    print("Installer core updated.")
  end
end

local loader = load_local_core()
if not loader then
  print("Installer core missing or corrupted.")
  return
end

loader()
