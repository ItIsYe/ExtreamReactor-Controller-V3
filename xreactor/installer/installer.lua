-- CONFIG
local CONFIG = {
  BASE_DIR = "/xreactor", -- Base install directory.
  REPO_OWNER = "ItIsYe", -- GitHub repository owner.
  REPO_NAME = "ExtreamReactor-Controller-V3", -- GitHub repository name.
  REPO_BASE_URL = "https://raw.githubusercontent.com", -- Raw GitHub base URL.
  MANIFEST_REMOTE = "xreactor/installer/manifest.lua", -- Manifest path (fallback).
  MANIFEST_LOCAL = "/xreactor/.manifest", -- Cached manifest in install dir.
  MANIFEST_CACHE = "/xreactor/.cache/manifest.lua", -- Serialized manifest cache.
  MANIFEST_CACHE_RAW = "/xreactor/.cache/cached_manifest.lua", -- Raw manifest cache.
  CACHE_LAST_BASE = "/xreactor/.cache/last_good_base_url", -- Last known good base URL.
  CACHE_LAST_SOURCE = "/xreactor/.cache/last_good_source", -- Last known good source (main/sha).
  CACHE_LAST_SHA = "/xreactor/.cache/last_good_sha", -- Last known good sha (if pinned).
  MANIFEST_CACHE_LEGACY = "/xreactor/.manifest_cache", -- Legacy cache path.
  BACKUP_BASE = "/xreactor_backup", -- Backup base directory.
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  UPDATE_STAGING = "/xreactor_update_tmp", -- Temp staging folder for updates.
  INSTALLER_VERSION = "1.3", -- Installer version for min-version checks.
  INSTALLER_MIN_BYTES = 200, -- Min bytes to accept installer download.
  INSTALLER_SANITY_MARKER = "local function main", -- Installer sanity marker.
  MANIFEST_MIN_BYTES = 50, -- Min bytes to accept manifest download.
  MANIFEST_SANITY_MARKER = "return", -- Manifest sanity marker.
  DOWNLOAD_BACKOFF = 1, -- Backoff base (seconds) between retries.
  DOWNLOAD_TIMEOUT = 8, -- HTTP timeout in seconds (used when http.request is available).
  MANIFEST_RETRY_ATTEMPTS = 2, -- Retry attempts for manifest acquisition menu.
  MANIFEST_RETRY_BACKOFF = 1, -- Backoff seconds for manifest retry menu.
  MANIFEST_MENU_RETRY_LIMIT = 5, -- Retry rounds from menu before auto-cancel.
  FILE_RETRY_ROUNDS = 3, -- Retry rounds for file download failures.
  FILE_RETRY_BACKOFF = 1, -- Backoff seconds for file download retry rounds.
  FILE_DOWNLOAD_ATTEMPTS = 2, -- Retry attempts per file for timeout/http.get nil.
  BASE_VALIDATE_ATTEMPTS = 2, -- Retry attempts for base validation on timeout.
  LOG_ENABLED = false, -- Enables installer file logging to /xreactor_installer.log.
  LOG_PATH = "/xreactor_installer.log", -- Installer log file path.
  LOG_NAME = "installer", -- Installer log file name.
  LOG_PREFIX = "INSTALLER", -- Installer log prefix.
  LOG_SETTINGS_KEY = "xreactor.debug_logging" -- settings key for debug logs.
}

local BASE_DIR = CONFIG.BASE_DIR
local REPO_OWNER = CONFIG.REPO_OWNER
local REPO_NAME = CONFIG.REPO_NAME
local REPO_BASE_URL_MAIN = CONFIG.REPO_BASE_URL
local MANIFEST_REMOTE = CONFIG.MANIFEST_REMOTE
local MANIFEST_LOCAL = CONFIG.MANIFEST_LOCAL
local MANIFEST_CACHE = CONFIG.MANIFEST_CACHE
local MANIFEST_CACHE_RAW = CONFIG.MANIFEST_CACHE_RAW
local CACHE_LAST_BASE = CONFIG.CACHE_LAST_BASE
local CACHE_LAST_SOURCE = CONFIG.CACHE_LAST_SOURCE
local CACHE_LAST_SHA = CONFIG.CACHE_LAST_SHA
local MANIFEST_CACHE_LEGACY = CONFIG.MANIFEST_CACHE_LEGACY
local BACKUP_BASE = CONFIG.BACKUP_BASE
local NODE_ID_PATH = CONFIG.NODE_ID_PATH
local UPDATE_STAGING = CONFIG.UPDATE_STAGING
local INSTALLER_VERSION = CONFIG.INSTALLER_VERSION
local INSTALLER_MIN_BYTES = CONFIG.INSTALLER_MIN_BYTES
local INSTALLER_SANITY_MARKER = CONFIG.INSTALLER_SANITY_MARKER
local MANIFEST_MIN_BYTES = CONFIG.MANIFEST_MIN_BYTES
local MANIFEST_SANITY_MARKER = CONFIG.MANIFEST_SANITY_MARKER
local DOWNLOAD_BACKOFF = CONFIG.DOWNLOAD_BACKOFF
local DOWNLOAD_TIMEOUT = CONFIG.DOWNLOAD_TIMEOUT
local FILE_DOWNLOAD_ATTEMPTS = CONFIG.FILE_DOWNLOAD_ATTEMPTS
local BASE_VALIDATE_ATTEMPTS = CONFIG.BASE_VALIDATE_ATTEMPTS

-- UI helpers (centralized input).
local function ui_prompt(label, default, min, max)
  local suffix = default and (" [" .. tostring(default) .. "]") or ""
  write(label .. suffix .. ": ")
  local input = read()
  if input == "" then
    input = default
  end
  if min or max then
    local num = tonumber(input)
    if not num then
      return nil
    end
    if min and num < min then
      return nil
    end
    if max and num > max then
      return nil
    end
    return num
  end
  return input
end

local function ui_menu(title, options, default)
  if title and title ~= "" then
    print(title)
  end
  for idx, label in ipairs(options or {}) do
    print(string.format("%d) %s", idx, label))
  end
  local choice = ui_prompt("Select option", default or 1, 1, #options)
  if not choice then
    return default or 1
  end
  return choice
end

local function ui_pause(msg)
  print(msg or "Press Enter to continue.")
  read()
end

-- Internal standalone logger for the installer (no project dependencies).
local active_logger = {}
local internal_log_enabled = false

local function resolve_log_enabled()
  if CONFIG.LOG_ENABLED == true then
    return true
  end
  if settings and settings.get and CONFIG.LOG_SETTINGS_KEY then
    return settings.get(CONFIG.LOG_SETTINGS_KEY) == true
  end
  return false
end

local function log_stamp()
  return textutils.formatTime(os.epoch("utc") / 1000, true)
end

local function internal_log(level, message)
  if not internal_log_enabled then
    return
  end
  local ok = pcall(function()
    local file = fs.open(CONFIG.LOG_PATH, "a")
    if not file then
      return
    end
    local line = string.format("[%s] %s | %s | %s", log_stamp(), CONFIG.LOG_PREFIX, tostring(level), tostring(message))
    file.write(line .. "\n")
    file.close()
  end)
  if not ok then
    internal_log_enabled = false
  end
end

local function init_internal_logger()
  internal_log_enabled = resolve_log_enabled()
  active_logger.log = internal_log
  active_logger.set_enabled = function(enabled)
    if enabled == true then
      internal_log_enabled = true
      return
    end
    if enabled == false then
      internal_log_enabled = false
      return
    end
    internal_log_enabled = resolve_log_enabled()
  end
end

init_internal_logger()

-- Defensive wrapper for legacy calls.
local function prompt(label, default)
  return ui_prompt(label, default)
end

local roles = {
  MASTER = "MASTER",
  RT_NODE = "RT-NODE",
  ENERGY_NODE = "ENERGY-NODE",
  FUEL_NODE = "FUEL-NODE",
  WATER_NODE = "WATER-NODE",
  REPROCESSOR_NODE = "REPROCESSOR-NODE"
}

local role_targets = {
  [roles.MASTER] = { path = "master", config = "master/config.lua" },
  [roles.RT_NODE] = { path = "nodes/rt", config = "nodes/rt/config.lua" },
  [roles.ENERGY_NODE] = { path = "nodes/energy", config = "nodes/energy/config.lua" },
  [roles.FUEL_NODE] = { path = "nodes/fuel", config = "nodes/fuel/config.lua" },
  [roles.WATER_NODE] = { path = "nodes/water", config = "nodes/water/config.lua" },
  [roles.REPROCESSOR_NODE] = { path = "nodes/reprocessor", config = "nodes/reprocessor/config.lua" }
}

-- Centralized installer logging helper.
local function log(level, message)
  if active_logger and active_logger.log then
    active_logger.log(CONFIG.LOG_PREFIX, message, level)
  end
end

local function ensure_dir(path)
  if path == "" then return end
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function trim(text)
  if not text then return "" end
  return text:match("^%s*(.-)%s*$")
end

local function normalize_node_id(value)
  if type(value) == "string" then
    local trimmed = trim(value)
    if trimmed ~= "" then
      return trimmed
    end
  elseif type(value) == "number" then
    return tostring(value)
  elseif type(value) == "table" then
    local candidate = value.id or value.node_id or value.value
    if type(candidate) == "string" then
      local trimmed = trim(candidate)
      if trimmed ~= "" then
        return trimmed
      end
    elseif type(candidate) == "number" then
      return tostring(candidate)
    end
    return tostring(value)
  end
  return nil
end

local function fallback_node_id()
  return tostring(os.getComputerLabel() or os.getComputerID())
end

local function read_file(path)
  if not fs.exists(path) then return nil end
  local file = fs.open(path, "r")
  if not file then return nil end
  local content = file.readAll()
  file.close()
  return content
end

local function write_atomic(path, content)
  ensure_dir(fs.getDir(path))
  local tmp = path .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then
    error("Unable to write file at " .. path)
  end
  file.write(content)
  file.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
end

local function read_text(path)
  if not fs.exists(path) then
    return nil
  end
  local content = read_file(path)
  if not content then
    return nil
  end
  local trimmed = trim(content)
  if trimmed == "" then
    return nil
  end
  return trimmed
end

local function write_text(path, content)
  if content == nil then
    if fs.exists(path) then
      fs.delete(path)
    end
    return
  end
  write_atomic(path, tostring(content))
end

local function normalize_newlines(content)
  if not content then return "" end
  return content:gsub("\r\n", "\n")
end

local function copy_file(src, dst)
  local content = read_file(src)
  if content == nil then return false end
  write_atomic(dst, content)
  return true
end

local function sumlen_hash(content)
  local sum = 0
  for i = 1, #content do
    sum = (sum + string.byte(content, i)) % 1000000007
  end
  return tostring(sum) .. ":" .. tostring(#content)
end

local crc32_table

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
  crc = bit32.bxor(crc, 0xFFFFFFFF)
  return string.format("%08x", crc)
end

local function sha1_hash(content)
  local function left_rotate(value, bits)
    return bit32.lrotate(value, bits)
  end

  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local ml = #content * 8
  content = content .. string.char(0x80)
  while (#content % 64) ~= 56 do
    content = content .. string.char(0x00)
  end
  local high = math.floor(ml / 2^32)
  local low = ml % 2^32
  content = content .. string.char(
    bit32.band(bit32.rshift(high, 24), 0xFF),
    bit32.band(bit32.rshift(high, 16), 0xFF),
    bit32.band(bit32.rshift(high, 8), 0xFF),
    bit32.band(high, 0xFF),
    bit32.band(bit32.rshift(low, 24), 0xFF),
    bit32.band(bit32.rshift(low, 16), 0xFF),
    bit32.band(bit32.rshift(low, 8), 0xFF),
    bit32.band(low, 0xFF)
  )

  for chunk = 1, #content, 64 do
    local w = {}
    for i = 0, 15 do
      local offset = chunk + (i * 4)
      w[i] = bit32.bor(
        bit32.lshift(string.byte(content, offset), 24),
        bit32.lshift(string.byte(content, offset + 1), 16),
        bit32.lshift(string.byte(content, offset + 2), 8),
        string.byte(content, offset + 3)
      )
    end
    for i = 16, 79 do
      w[i] = left_rotate(bit32.bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bit32.bor(bit32.band(b, c), bit32.band(bit32.bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bit32.bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bit32.bor(bit32.band(b, c), bit32.band(b, d), bit32.band(c, d))
        k = 0x8F1BBCDC
      else
        f = bit32.bxor(b, c, d)
        k = 0xCA62C1D6
      end
      local temp = bit32.band(left_rotate(a, 5) + f + e + k + w[i], 0xFFFFFFFF)
      e = d
      d = c
      c = left_rotate(b, 30)
      b = a
      a = temp
    end
    h0 = bit32.band(h0 + a, 0xFFFFFFFF)
    h1 = bit32.band(h1 + b, 0xFFFFFFFF)
    h2 = bit32.band(h2 + c, 0xFFFFFFFF)
    h3 = bit32.band(h3 + d, 0xFFFFFFFF)
    h4 = bit32.band(h4 + e, 0xFFFFFFFF)
  end
  return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

local function resolve_hash_algo(manifest, release)
  if manifest and manifest.hash_algo then
    return manifest.hash_algo
  end
  if release and release.hash_algo then
    return release.hash_algo
  end
  return nil
end

local function validate_hash_algo(manifest, release)
  local algo = resolve_hash_algo(manifest, release)
  local allowed = { ["sumlen-v1"] = true, ["crc32"] = true, ["sha1"] = true }
  if not algo or not allowed[algo] then
    error("Unsupported hash algo: " .. tostring(algo))
  end
end

local function compute_hash(content, algo)
  content = normalize_newlines(content)
  if algo == "sumlen-v1" then
    return sumlen_hash(content)
  end
  if algo == "crc32" then
    return crc32_hash(content)
  end
  if algo == "sha1" then
    return sha1_hash(content)
  end
  error("Unsupported hash algo: " .. tostring(algo))
end

local function file_checksum(path, algo)
  local content = read_file(path)
  if not content then return nil end
  return compute_hash(content, algo)
end

local function compare_version(a, b)
  local function parse(version)
    local major, minor = tostring(version or "0"):match("^(%d+)%.?(%d*)$")
    return tonumber(major) or 0, tonumber(minor) or 0
  end
  local a_major, a_minor = parse(a)
  local b_major, b_minor = parse(b)
  if a_major ~= b_major then
    return a_major - b_major
  end
  return a_minor - b_minor
end

local function read_config(path, defaults)
  if not fs.exists(path) then
    return defaults or {}
  end
  local content = read_file(path)
  if not content then
    return defaults or {}
  end
  local loader = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      return data
    end
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return defaults or {}
end

local function read_config_from_content(content)
  if not content then return {} end
  local loader = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      return data
    end
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local function write_config_file(path, tbl)
  write_atomic(path, "return " .. textutils.serialize(tbl))
end

local function merge_defaults(target, defaults)
  local changed = false
  for key, value in pairs(defaults or {}) do
    if target[key] == nil then
      target[key] = value
      changed = true
    elseif type(target[key]) == "table" and type(value) == "table" then
      local inner_changed = merge_defaults(target[key], value)
      changed = changed or inner_changed
    end
  end
  return changed
end

local function is_html_payload(content)
  if not content then return false end
  local head = content:sub(1, 200)
  if head:match("^%s*<!DOCTYPE") then return true end
  if head:match("^%s*<html") then return true end
  if head:find("<body") then return true end
  return false
end

local function sanity_check(content, min_bytes, marker)
  if not content or content == "" then
    return false, "empty"
  end
  if min_bytes and #content < min_bytes then
    return false, "too short"
  end
  if marker and not content:find(marker, 1, true) then
    return false, "sanity check failed"
  end
  if is_html_payload(content) then
    return false, "html"
  end
  return true
end

local function is_html_response(body)
  if not body or body == "" then
    return false
  end
  if body:find("<!DOCTYPE", 1, true) or body:find("<html", 1, true) then
    return true
  end
  if body:match("^%s*<") then
    return true
  end
  return false
end

local function is_valid_sha(value)
  return type(value) == "string" and value:match("^[0-9a-fA-F]{40}$") ~= nil
end

local function build_base_url(ref)
  return string.format("%s/%s/%s/%s", REPO_BASE_URL_MAIN, REPO_OWNER, REPO_NAME, tostring(ref))
end

local function build_repo_url(base_url, path)
  return string.format("%s/%s", tostring(base_url), tostring(path))
end

local function source_from_base_url(base_url)
  local prefix = string.format("%s/%s/%s/", REPO_BASE_URL_MAIN, REPO_OWNER, REPO_NAME)
  if type(base_url) ~= "string" then
    return { channel = "main", sha = nil }
  end
  if base_url:sub(1, #prefix) ~= prefix then
    return { channel = "main", sha = nil }
  end
  local ref = base_url:sub(#prefix + 1)
  if ref == "main" then
    return { channel = "main", sha = nil }
  end
  if is_valid_sha(ref) then
    return { channel = "sha", sha = ref }
  end
  return { channel = "main", sha = nil }
end

local function normalize_source_spec(source)
  local channel = "main"
  local sha = nil
  if type(source) == "string" then
    channel = source
  elseif type(source) == "table" then
    if type(source.channel) == "string" then
      channel = source.channel
    end
    if type(source.sha) == "string" then
      sha = source.sha
    end
  end
  if channel ~= "main" and channel ~= "sha" then
    channel = "main"
  end
  if channel == "sha" and not is_valid_sha(sha) then
    channel = "main"
    sha = nil
  end
  return { channel = channel, sha = sha }
end

local function source_to_ref(source)
  if source and source.channel == "sha" and source.sha then
    return source.sha
  end
  return "main"
end

local function source_to_base_url(source)
  return build_base_url(source_to_ref(source))
end

local function error_is_timeout(err)
  if not err then
    return false
  end
  local text = tostring(err):lower()
  return text:find("timeout", 1, true) ~= nil or text:find("http.get returned nil", 1, true) ~= nil
end

local function error_is_not_found(err, meta)
  if meta and tonumber(meta.code) == 404 then
    return true
  end
  if err and tostring(err):find("404", 1, true) then
    return true
  end
  return false
end

-- Single download function used by all network requests.
local function fetch_url(url, opts)
  if not http or not http.get then
    return false, nil, "HTTP API unavailable (enable in CC:Tweaked config/server)", { url = url }
  end
  local timeout = (opts and opts.timeout) or DOWNLOAD_TIMEOUT
  local response
  local err
  if http.request and timeout then
    local ok, req_err = pcall(http.request, url, nil, nil, false)
    if not ok then
      return false, nil, "http.request failed (" .. tostring(req_err) .. ")", { url = url }
    end
    local timer = os.startTimer(timeout)
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
    local ok, result = pcall(function()
      return http.get(url)
    end)
    if ok then
      response = result
    else
      err = result
      response = nil
    end
    if response == nil then
      local reason = "http.get returned nil"
      if err then
        reason = reason .. " (" .. tostring(err) .. ")"
      end
      return false, nil, reason, { url = url }
    end
  end
  local code = response.getResponseCode and response.getResponseCode() or nil
  local headers = response.getResponseHeaders and response.getResponseHeaders() or nil
  local body = response.readAll()
  response.close()
  if not body or body == "" then
    return false, nil, "empty body", { url = url, code = code, headers = headers }
  end
  if is_html_response(body) then
    return false, nil, "html response (wrong url)", { url = url, code = code, headers = headers }
  end
  if code and code ~= 200 then
    return false, nil, "http " .. tostring(code), { url = url, code = code, headers = headers }
  end
  return true, body, nil, { url = url, code = code, headers = headers, bytes = #body }
end

local function download_repo_file(base_url, path, opts)
  local url = build_repo_url(base_url, path)
  local attempts = (opts and opts.attempts) or FILE_DOWNLOAD_ATTEMPTS
  local backoff = (opts and opts.backoff) or DOWNLOAD_BACKOFF
  local tried = {}
  for attempt = 1, attempts do
    local ok, body, err, meta = fetch_url(url, { timeout = DOWNLOAD_TIMEOUT })
    local entry = {
      url = url,
      ok = ok,
      err = err,
      bytes = body and #body or 0,
      code = meta and meta.code or nil,
      headers = meta and meta.headers or nil,
      attempt = attempt
    }
    table.insert(tried, entry)
    if ok then
      local ok_sanity, reason = sanity_check(body, opts and opts.min_bytes, opts and opts.marker)
      if not ok_sanity then
        entry.ok = false
        entry.err = reason
        return nil, "invalid", { tried = tried, last = entry }
      end
      return body, nil, { tried = tried, last = entry }
    end
    if error_is_not_found(err, meta) then
      return nil, "not_found", { tried = tried, last = entry }
    end
    if attempt < attempts and error_is_timeout(err) then
      os.sleep(backoff * attempt)
    else
      return nil, "error", { tried = tried, last = entry }
    end
  end
  return nil, "error", { tried = tried, last = tried[#tried] }
end

local function validate_installer_content(content)
  if not content or #content < INSTALLER_MIN_BYTES then
    return false, "content too short"
  end
  if not content:find(INSTALLER_SANITY_MARKER, 1, true) then
    return false, "sanity check failed"
  end
  local loader, err = load(content, "installer", "t", {})
  if not loader then
    return false, err or "syntax error"
  end
  return true
end

local function read_manifest_cache()
  local path = nil
  if fs.exists(MANIFEST_CACHE) then
    path = MANIFEST_CACHE
  elseif fs.exists(MANIFEST_CACHE_LEGACY) then
    path = MANIFEST_CACHE_LEGACY
  end
  if path then
    local content = read_file(path)
    if content then
      local ok, data = pcall(textutils.unserialize, content)
      if ok and type(data) == "table" and type(data.manifest_content) == "string" then
        if type(data.source) ~= "nil" then
          data.source = normalize_source_spec(data.source)
        elseif type(data.release) == "table" and is_valid_sha(data.release.commit_sha) then
          data.source = normalize_source_spec({ channel = "sha", sha = data.release.commit_sha })
        end
        return data
      end
    end
  end
  if fs.exists(MANIFEST_CACHE_RAW) then
    local raw = read_file(MANIFEST_CACHE_RAW)
    if raw and raw ~= "" then
      return { manifest_content = raw }
    end
  end
  return nil
end

local function write_manifest_cache(manifest_content, source, base_url)
  local payload = {
    manifest_content = manifest_content,
    source = source,
    base_url = base_url,
    saved_at = os.time()
  }
  write_atomic(MANIFEST_CACHE, textutils.serialize(payload))
  write_atomic(MANIFEST_CACHE_RAW, manifest_content)
end

local function read_cached_base_url()
  return read_text(CACHE_LAST_BASE)
end

local function read_cached_source()
  local cached_source = read_text(CACHE_LAST_SOURCE)
  local cached_sha = read_text(CACHE_LAST_SHA)
  if cached_source == "sha" and is_valid_sha(cached_sha) then
    return { channel = "sha", sha = cached_sha }
  end
  if cached_source == "main" then
    return { channel = "main", sha = nil }
  end
  return nil
end

local function write_source_cache(base_url, source)
  write_text(CACHE_LAST_BASE, base_url)
  write_text(CACHE_LAST_SOURCE, source and source.channel or nil)
  if source and source.channel == "sha" and source.sha then
    write_text(CACHE_LAST_SHA, source.sha)
  else
    write_text(CACHE_LAST_SHA, nil)
  end
end

local function format_manifest_failure(meta)
  local reason = "timeout or http error"
  local tried_list = {}
  if meta and meta.tried then
    for _, entry in ipairs(meta.tried) do
      if entry.url then
        table.insert(tried_list, entry.url)
      end
      if entry.err then
        reason = entry.err
      end
    end
  end
  if meta and meta.last and meta.last.err then
    reason = meta.last.err
  end
  if #tried_list == 0 then
    tried_list = { "unknown" }
  end
  local tried = table.concat(tried_list, ", ")
  return ("Manifest download failed (%s). Tried: %s"):format(reason, tried)
end

local function collect_tried_urls(info, fallback_urls)
  local urls = {}
  if info and info.tried then
    for _, entry in ipairs(info.tried) do
      if entry.url then
        table.insert(urls, entry.url)
      end
    end
  end
  if #urls == 0 and info and info.last and info.last.url then
    urls = { info.last.url }
  end
  if #urls == 0 and fallback_urls and #fallback_urls > 0 then
    urls = fallback_urls
  end
  if #urls == 0 then
    urls = { "unknown" }
  end
  return urls
end

local function print_download_failure(label, info, fallback_urls)
  local urls = collect_tried_urls(info, fallback_urls)
  local last = info and info.last or {}
  print(label)
  print("Tried: " .. table.concat(urls, ", "))
  print(("Last error: %s (url=%s)"):format(
    tostring(last.err or "timeout or http error"),
    tostring(last.url or urls[1])
  ))
end

local function parse_manifest(content)
  local loader = load(content, "manifest", "t", {})
  if not loader then
    return nil, "Manifest load failed"
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
    return nil, "Manifest parse failed"
  end
  data.source = normalize_source_spec(data.source)
  return data
end

local function download_manifest_from_base(base_url)
  local url = build_repo_url(base_url, MANIFEST_REMOTE)
  local tried = {}
  for attempt = 1, BASE_VALIDATE_ATTEMPTS do
    log("WARN", ("Manifest download attempt %d/%d"):format(attempt, BASE_VALIDATE_ATTEMPTS))
    local ok, body, err, meta = fetch_url(url, { timeout = DOWNLOAD_TIMEOUT })
    local entry = {
      url = url,
      ok = ok,
      err = err,
      bytes = body and #body or 0,
      code = meta and meta.code or nil,
      headers = meta and meta.headers or nil,
      attempt = attempt
    }
    table.insert(tried, entry)
    if ok then
      local ok_sanity, reason = sanity_check(body, MANIFEST_MIN_BYTES, MANIFEST_SANITY_MARKER)
      if not ok_sanity then
        entry.ok = false
        entry.err = reason
        return nil, "invalid", { tried = tried, last = entry }
      end
      local manifest, manifest_err = parse_manifest(body)
      if not manifest then
        entry.ok = false
        entry.err = manifest_err
        return nil, "invalid", { tried = tried, last = entry }
      end
      validate_hash_algo(manifest, nil)
      return { content = body, manifest = manifest, meta = { tried = tried, last = entry } }
    end
    if error_is_not_found(err, meta) then
      return nil, "not_found", { tried = tried, last = entry }
    end
    if not error_is_timeout(err) or attempt >= BASE_VALIDATE_ATTEMPTS then
      return nil, "error", { tried = tried, last = entry }
    end
    os.sleep(CONFIG.MANIFEST_RETRY_BACKOFF * attempt)
  end
  return nil, "error", { tried = tried, last = tried[#tried] }
end

local function build_candidate_bases(cached_base_url, requested_source)
  local candidates = {}
  local function add(base_url)
    if not base_url then
      return
    end
    for _, existing in ipairs(candidates) do
      if existing == base_url then
        return
      end
    end
    table.insert(candidates, base_url)
  end
  add(cached_base_url)
  if requested_source then
    add(source_to_base_url(requested_source))
  end
  add(build_base_url("main"))
  return candidates
end

local function validate_base_url(base_url)
  local url = build_repo_url(base_url, MANIFEST_REMOTE)
  local tried = {}
  for attempt = 1, BASE_VALIDATE_ATTEMPTS do
    local ok, _, err, meta = fetch_url(url, { timeout = DOWNLOAD_TIMEOUT })
    local entry = {
      url = url,
      ok = ok,
      err = err,
      code = meta and meta.code or nil,
      headers = meta and meta.headers or nil,
      attempt = attempt
    }
    table.insert(tried, entry)
    if ok then
      return true, { tried = tried, last = entry }
    end
    if error_is_not_found(err, meta) then
      return false, "not_found", { tried = tried, last = entry }
    end
    if not error_is_timeout(err) then
      return false, "error", { tried = tried, last = entry }
    end
    if attempt < BASE_VALIDATE_ATTEMPTS then
      os.sleep(CONFIG.MANIFEST_RETRY_BACKOFF * attempt)
    end
  end
  return false, "error", { tried = tried, last = tried[#tried] }
end

local function resolve_download_base(manifest)
  local cached_base_url = read_cached_base_url()
  local requested_source = manifest and manifest.source or { channel = "main" }
  local candidates = build_candidate_bases(cached_base_url, requested_source)
  local last_meta = nil
  for _, base_url in ipairs(candidates) do
    local ok, kind, meta = validate_base_url(base_url)
    last_meta = meta
    if ok then
      return base_url, source_from_base_url(base_url), meta
    end
    if kind == "not_found" then
      log("WARN", "Base validation failed (404) for " .. tostring(base_url))
    else
      log("WARN", "Base validation failed for " .. tostring(base_url))
    end
  end
  return build_base_url("main"), { channel = "main", sha = nil }, last_meta
end

local function create_source_state(base_url, source)
  return {
    base_url = base_url,
    source = source or { channel = "main", sha = nil },
    fallback_used = false
  }
end

local function switch_source_to_main(state)
  state.base_url = build_base_url("main")
  state.source = { channel = "main", sha = nil }
  state.fallback_used = true
end

local function prompt_switch_to_main(path)
  print(("Pinned source returned 404 for %s."):format(path))
  local choice = ui_menu(nil, { "Switch to main (recommended)", "Cancel" }, 1)
  return choice == 1
end

local function download_with_source_fallback(state, path, opts)
  local content, kind, meta = download_repo_file(state.base_url, path, opts)
  if content then
    return content, nil, meta
  end
  if kind == "not_found" then
    if state.source.channel ~= "main" and not state.fallback_used then
      if not prompt_switch_to_main(path) then
        return nil, "cancelled", meta
      end
      switch_source_to_main(state)
      local fallback_content, fallback_kind, fallback_meta = download_repo_file(state.base_url, path, opts)
      if fallback_content then
        return fallback_content, nil, fallback_meta
      end
      if fallback_kind == "not_found" then
        return nil, "missing", fallback_meta
      end
      return nil, "error", fallback_meta
    end
    return nil, "missing", meta
  end
  return nil, "error", meta
end

local function acquire_manifest()
  local cache = read_manifest_cache()
  local cached_base_url = read_cached_base_url()
  local cached_source = read_cached_source()
  local cached_manifest_source = cache and cache.source or nil
  if not cached_manifest_source and cache and cache.manifest_content then
    local parsed = parse_manifest(cache.manifest_content)
    if parsed then
      cached_manifest_source = parsed.source
    end
  end
  local requested_source = cached_manifest_source or cached_source
  local retry_rounds = 0

  while true do
    local candidates = build_candidate_bases(cached_base_url, requested_source)
    local last_meta = nil
    local last_kind = nil
    for _, base_url in ipairs(candidates) do
      local result, kind, meta = download_manifest_from_base(base_url)
      if result and result.content then
        log("INFO", "Manifest fetched from base " .. tostring(base_url))
        return result.content, result.manifest, base_url, result.meta
      end
      last_meta = meta
      last_kind = kind
      if kind == "not_found" then
        log("WARN", "Manifest not found at base " .. tostring(base_url))
      else
        log("WARN", "Manifest download failed at base " .. tostring(base_url))
        if kind ~= "not_found" then
          break
        end
      end
    end

    if cache and cache.manifest_content then
      if last_kind == "not_found" then
        print("Manifest not found on remote base. Using cached manifest.")
        log("WARN", "Manifest 404; using cached manifest")
      else
        print("Manifest download failed (offline/timeout). Using cached manifest.")
        log("WARN", "Manifest download failed; using cached manifest")
      end
      local parsed, parse_err = parse_manifest(cache.manifest_content)
      if not parsed then
        print("Cached manifest invalid: " .. tostring(parse_err))
        log("ERROR", "Cached manifest invalid: " .. tostring(parse_err))
        return nil
      end
      return cache.manifest_content, parsed, cache.base_url or cached_base_url or source_to_base_url(requested_source or { channel = "main" }), last_meta
    end

    if last_kind == "not_found" then
      print("Manifest not found on any base. Installer cancelled.")
      log("ERROR", "Manifest 404 on all bases; cancelling")
      return nil
    end

    local failure = format_manifest_failure(last_meta)
    print(failure)
    if last_meta and last_meta.last then
      local last = last_meta.last
      print(("Last error: %s (url=%s)"):format(tostring(last.err or "timeout or http error"), tostring(last.url or "unknown")))
    end
    log("WARN", failure)
    local choice = ui_menu(nil, { "Retry download", "Cancel" }, 1)
    if choice ~= 1 then
      print("Installer cancelled.")
      log("INFO", "User cancelled manifest acquisition")
      return nil
    end
    retry_rounds = retry_rounds + 1
    if retry_rounds > CONFIG.MANIFEST_MENU_RETRY_LIMIT then
      print("Retry limit reached. Installer cancelled.")
      log("WARN", "Manifest retry limit reached; cancelling")
      return nil
    end
  end
end

local function ensure_base_dirs()
  ensure_dir(BASE_DIR)
  ensure_dir(BASE_DIR .. "/config")
  ensure_dir(BASE_DIR .. "/core")
  ensure_dir(BASE_DIR .. "/master")
  ensure_dir(BASE_DIR .. "/master/ui")
  ensure_dir(BASE_DIR .. "/nodes")
  ensure_dir(BASE_DIR .. "/nodes/rt")
  ensure_dir(BASE_DIR .. "/nodes/energy")
  ensure_dir(BASE_DIR .. "/nodes/fuel")
  ensure_dir(BASE_DIR .. "/nodes/water")
  ensure_dir(BASE_DIR .. "/nodes/reprocessor")
  ensure_dir(BASE_DIR .. "/shared")
  ensure_dir(BASE_DIR .. "/installer")
  ensure_dir(BASE_DIR .. "/.cache")
  ensure_dir(BASE_DIR .. "/logs")
end

local function is_config_file(path)
  return path:match("/config%.lua$") ~= nil
end

local function confirm(prompt_text, default)
  local hint = default and "Y/n" or "y/N"
  local input = ui_prompt(prompt_text .. " (" .. hint .. ")", default and "y" or "n")
  input = input:lower()
  if input == "" then return default end
  return input == "y" or input == "yes"
end

local last_detection = { reactors = {}, turbines = {}, modems = {} }

local function is_wireless_modem(name)
  local ok, result = pcall(peripheral.call, name, "isWireless")
  if ok then return result end
  return false
end

local function scan_peripherals()
  local reactors = {}
  local turbines = {}
  local modems = {}
  for _, name in ipairs(peripheral.getNames()) do
    local peripheral_type = peripheral.getType(name)
    if peripheral_type == "BigReactors-Reactor" then
      table.insert(reactors, name)
    elseif peripheral_type == "BigReactors-Turbine" then
      table.insert(turbines, name)
    elseif peripheral_type == "modem" then
      table.insert(modems, name)
    end
  end
  last_detection = { reactors = reactors, turbines = turbines, modems = modems }
  return last_detection
end

local function detect_modems()
  local wireless = {}
  local wired = {}
  for _, name in ipairs(scan_peripherals().modems) do
    if is_wireless_modem(name) then
      table.insert(wireless, name)
    else
      table.insert(wired, name)
    end
  end
  return { wireless = wireless, wired = wired }
end

local function select_primary_modem(modems)
  if #modems.wireless > 0 then
    return modems.wireless[1]
  end
  if #modems.wired > 0 then
    return modems.wired[1]
  end
  return nil
end

local function choose_role()
  local list = {
    roles.MASTER,
    roles.RT_NODE,
    roles.ENERGY_NODE,
    roles.FUEL_NODE,
    roles.WATER_NODE,
    roles.REPROCESSOR_NODE
  }
  local choice = ui_menu("Select role:", list, 1)
  return list[choice] or roles.MASTER
end

local function write_startup(role)
  local target = role_targets[role]
  write_atomic("/startup.lua", [[shell.run("/xreactor/]] .. target.path .. [[/main.lua")]])
end

local function print_detected(label, items)
  print(label .. ":")
  if #items == 0 then
    print(" - (none)")
    return
  end
  for _, name in ipairs(items) do
    print(" - " .. name)
  end
end

local function prompt_use_detected()
  scan_peripherals()
  local input = ui_prompt("Use detected peripherals? [Y/n]", "y")
  input = tostring(input or ""):lower()
  if input == "" then return true end
  return input == "y" or input == "yes"
end

local function write_config(role, wireless, wired, extras)
  local cfg_path = BASE_DIR .. "/" .. role_targets[role].config
  local defaults = read_config(cfg_path, {})
  defaults.role = role
  defaults.wireless_modem = wireless
  defaults.wired_modem = wired
  if defaults.node_id == nil then
    defaults.node_id = fallback_node_id()
  end
  local normalized_node_id = normalize_node_id(defaults.node_id)
  if not normalized_node_id then
    normalized_node_id = fallback_node_id()
  end
  defaults.node_id = normalized_node_id
  if role == roles.MASTER then
    defaults.monitor_auto = true
    defaults.ui_scale_default = extras.ui_scale_default or 0.5
  elseif role == roles.RT_NODE then
    defaults.reactors = extras.reactors
    defaults.turbines = extras.turbines
    defaults.modem = extras.modem
    if extras.node_id then
      defaults.node_id = normalize_node_id(extras.node_id) or fallback_node_id()
    end
  end
  write_config_file(cfg_path, defaults)
end

local function build_rt_node_id()
  local id_str = tostring(os.getComputerID())
  local suffix = id_str:sub(-4)
  return "RT-" .. suffix
end

local function find_existing_role()
  for role, target in pairs(role_targets) do
    local cfg_path = BASE_DIR .. "/" .. target.config
    if fs.exists(cfg_path) then
      local cfg = read_config(cfg_path, {})
      if cfg.role == role then
        return role, cfg_path, cfg
      end
    end
  end
  return nil, nil, nil
end

local function collect_known_node_id_sources(role, cfg_path)
  local sources = {
    { label = "legacy_file", path = BASE_DIR .. "/data/node_id.txt" },
    { label = "legacy_file", path = BASE_DIR .. "/node_id.txt" },
    { label = "legacy_file", path = BASE_DIR .. "/config/node_id.txt" }
  }
  if cfg_path then
    table.insert(sources, { label = "config", path = cfg_path })
  end
  for _, target in pairs(role_targets) do
    local path = BASE_DIR .. "/" .. target.config
    if path ~= cfg_path then
      table.insert(sources, { label = "config", path = path })
    end
  end
  return sources
end

local function ensure_node_id(role, cfg_path)
  if fs.exists(NODE_ID_PATH) then
    local existing = trim(read_file(NODE_ID_PATH))
    local normalized = normalize_node_id(existing)
    if normalized then
      if normalized ~= existing then
        write_atomic(NODE_ID_PATH, normalized)
        print("normalized node_id from file")
        log("INFO", "Normalized node_id from file")
      end
      return true
    end
  end
  print("node_id missing → attempting migration")
  log("WARN", "node_id missing; attempting migration")
  local sources = collect_known_node_id_sources(role, cfg_path)
  for _, source in ipairs(sources) do
    if fs.exists(source.path) then
      if source.label == "config" then
        local cfg = read_config(source.path, {})
        local normalized = normalize_node_id(cfg.node_id)
        if normalized then
          write_atomic(NODE_ID_PATH, normalized)
          print("migrated node_id from config")
          log("INFO", "Migrated node_id from config")
          return true
        end
      else
        local content = trim(read_file(source.path))
        local normalized = normalize_node_id(content)
        if normalized then
          write_atomic(NODE_ID_PATH, normalized)
          print("migrated node_id from legacy_file")
          log("INFO", "Migrated node_id from legacy file")
          return true
        end
      end
    end
  end

  local generated = fallback_node_id()
  write_atomic(NODE_ID_PATH, generated)
  print("generated new node_id")
  log("INFO", "Generated new node_id")
  return true
end

local function create_backup_dir()
  ensure_dir(BACKUP_BASE)
  local stamp = os.date("%Y%m%d_%H%M%S")
  local path = BACKUP_BASE .. "/" .. stamp
  ensure_dir(path)
  return path
end

local function backup_files(base_dir, paths)
  for _, path in ipairs(paths) do
    if fs.exists(path) then
      local target = base_dir .. path
      ensure_dir(fs.getDir(target))
      copy_file(path, target)
    end
  end
end

local function rollback_from_backup(base_dir, paths, created)
  for _, path in ipairs(paths) do
    local backup_path = base_dir .. path
    if fs.exists(backup_path) then
      ensure_dir(fs.getDir(path))
      copy_file(backup_path, path)
    end
  end
  for _, path in ipairs(created) do
    if fs.exists(path) then
      fs.delete(path)
    end
  end
end

local function restore_from_backup(base_dir, paths)
  for _, path in ipairs(paths) do
    local backup_path = base_dir .. path
    if fs.exists(backup_path) then
      ensure_dir(fs.getDir(path))
      copy_file(backup_path, path)
    end
  end
end

local function update_files(manifest, hash_algo)
  local updates = {}
  for path, expected_hash in pairs(manifest.files) do
    if not is_config_file(path) then
      local local_hash = file_checksum("/" .. path, hash_algo)
      if local_hash ~= expected_hash then
        table.insert(updates, { path = path, hash = expected_hash })
      end
    end
  end
  table.sort(updates, function(a, b) return a.path < b.path end)
  return updates
end

local function build_staging_path(path)
  return UPDATE_STAGING .. "/" .. path
end

local function stage_updates(entries, source_state, hash_algo)
  ensure_dir(UPDATE_STAGING)
  local staged = {}
  for _, entry in ipairs(entries) do
    local content, err_kind, meta = download_with_source_fallback(source_state, entry.path)
    if not content then
      if err_kind == "missing" then
        return nil, ("Manifest references missing file: %s"):format(entry.path), { kind = "missing", meta = meta }
      end
      if err_kind == "cancelled" then
        return nil, "Installer cancelled.", { kind = "cancelled", meta = meta }
      end
      return nil, ("Download failed for %s"):format(entry.path), { kind = "download", meta = meta }
    end
    local actual = compute_hash(content, hash_algo)
    if actual ~= entry.hash then
      local retry_content, retry_kind, retry_meta = download_with_source_fallback(source_state, entry.path)
      if retry_content then
        content = retry_content
        actual = compute_hash(content, hash_algo)
      elseif retry_kind == "missing" then
        return nil, ("Manifest references missing file: %s"):format(entry.path), { kind = "missing", meta = retry_meta }
      elseif retry_kind == "cancelled" then
        return nil, "Installer cancelled.", { kind = "cancelled", meta = retry_meta }
      end
      if actual ~= entry.hash then
        local last = retry_meta and retry_meta.last or meta and meta.last or {}
        return nil, ("Checksum mismatch for %s (expected=%s actual=%s)"):format(
          entry.path,
          entry.hash,
          actual
        ), { kind = "checksum", meta = retry_meta or meta }
      end
    end
    local staging_path = build_staging_path(entry.path)
    write_atomic(staging_path, content)
    local verify = file_checksum(staging_path, hash_algo)
    if verify ~= entry.hash then
      return nil, ("Staged hash mismatch for %s (expected=%s actual=%s)"):format(
        entry.path,
        entry.hash,
        verify
      )
    end
    staged[entry.path] = staging_path
  end
  return staged
end

local function apply_staged(entries, staged, created)
  for _, entry in ipairs(entries) do
    local target_path = "/" .. entry.path
    local staging_path = staged[entry.path]
    local content = read_file(staging_path)
    if content == nil then
      return false, "Missing staged file for " .. entry.path
    end
    if not fs.exists(target_path) then
      table.insert(created, target_path)
    end
    local write_ok, write_err = pcall(write_atomic, target_path, content)
    if not write_ok then
      return false, write_err
    end
  end
  return true
end

local function update_installer_if_required(manifest, source_state, hash_algo)
  local required = manifest.installer_min_version
  if required and compare_version(INSTALLER_VERSION, required) < 0 then
    print("Installer update required.")
    log("WARN", "Installer update required (min " .. tostring(required) .. ")")
    if not confirm("Update installer now?", true) then
      print("SAFE UPDATE aborted: installer update required.")
      log("WARN", "Installer update declined by user")
      return false
    end
    local installer_path = manifest.installer_path or "xreactor/installer/installer.lua"
    local expected = manifest.installer_hash
    if not expected then
      print("SAFE UPDATE aborted: installer hash missing.")
      return false
    end
    local content, err_kind, meta = download_with_source_fallback(source_state, installer_path, {
      min_bytes = INSTALLER_MIN_BYTES,
      marker = INSTALLER_SANITY_MARKER
    })
    if not content then
      if err_kind == "missing" then
        print("SAFE UPDATE aborted: manifest references missing installer.")
      elseif err_kind == "cancelled" then
        print("SAFE UPDATE cancelled.")
      else
        local last = meta and meta.last or {}
        print(("SAFE UPDATE aborted: installer download failed (url=%s reason=%s)"):format(
          tostring(last.url or installer_path),
          tostring(last.err or "timeout or http error")
        ))
      end
      return false
    end
    if compute_hash(content, hash_algo) ~= expected then
      print("SAFE UPDATE aborted: installer checksum mismatch.")
      return false
    end
    local valid, valid_err = validate_installer_content(content)
    if not valid then
      print("SAFE UPDATE aborted: installer invalid (" .. tostring(valid_err) .. ").")
      return false
    end
    local target = "/" .. installer_path
    local temp = target .. ".new"
    write_atomic(temp, content)
    if fs.exists(target) then
      fs.delete(target)
    end
    fs.move(temp, target)
    print("Installer updated.")
    log("INFO", "Installer updated on disk")
    if not _G.__xreactor_installer_restarted then
      _G.__xreactor_installer_restarted = true
      local loader = loadfile(target)
      if loader then
        print("Restarting installer...")
        log("INFO", "Restarting installer after update")
        loader()
      else
        print("Installer updated, but restart failed. Please re-run installer.")
        log("ERROR", "Installer restart failed after update")
      end
    end
    return false
  end
  return true
end

local function migrate_config(role, cfg_path, manifest, source_state, hash_algo)
  local remote_path = "xreactor/" .. role_targets[role].config
  local expected_hash = manifest.files[remote_path]
  if not expected_hash then
    return false
  end
  local content, err_kind, meta = download_with_source_fallback(source_state, remote_path)
  if not content then
    if err_kind == "missing" then
      error("Manifest references missing config: " .. remote_path)
    elseif err_kind == "cancelled" then
      error("Installer cancelled.")
    else
      local last = meta and meta.last or {}
      error(("Config download failed (url=%s reason=%s)"):format(
        tostring(last.url or remote_path),
        tostring(last.err or "timeout or http error")
      ))
    end
  end
  if compute_hash(content, hash_algo) ~= expected_hash then
    error("Config checksum mismatch for " .. remote_path)
  end
  local defaults = read_config_from_content(content)
  local existing = read_config(cfg_path, {})
  local original = textutils.serialize(existing)
  merge_defaults(existing, defaults)
  if existing.role ~= role then
    existing.role = role
  end
  local normalized_node_id = normalize_node_id(existing.node_id)
  if not normalized_node_id then
    normalized_node_id = fallback_node_id()
  end
  existing.node_id = normalized_node_id
  if textutils.serialize(existing) ~= original then
    write_config_file(cfg_path, existing)
    return true
  end
  return false
end

local function verify_integrity(manifest, role, cfg_path)
  local required = {
    "xreactor/core/network.lua",
    "xreactor/core/protocol.lua",
    "xreactor/shared/constants.lua",
    "xreactor/installer/installer.lua"
  }
  if role == roles.MASTER then
    table.insert(required, "xreactor/master/main.lua")
  else
    table.insert(required, "xreactor/nodes/rt/main.lua")
  end
  for _, path in ipairs(required) do
    if not fs.exists("/" .. path) then
      return false, "Missing " .. path
    end
  end
  if role and cfg_path and not fs.exists(cfg_path) then
    return false, "Missing config"
  end
  if not fs.exists(NODE_ID_PATH) then
    return false, "Missing node_id"
  end
  return true
end

local function build_manifest_entries(manifest)
  local entries = {}
  for path, expected_hash in pairs(manifest.files) do
    table.insert(entries, { path = path, hash = expected_hash })
  end
  if manifest.installer_path and manifest.installer_hash then
    table.insert(entries, { path = manifest.installer_path, hash = manifest.installer_hash })
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  return entries
end

-- SAFE UPDATE keeps role/config/node_id intact and updates only changed files.
local function safe_update()
  local role, cfg_path = find_existing_role()
  if not role then
    print("No existing role config found. Use FULL REINSTALL.")
    log("WARN", "SAFE UPDATE aborted: no existing role config")
    return
  end
  local existing_cfg = read_config(cfg_path, {})
  if existing_cfg.debug_logging == true and active_logger.set_enabled then
    active_logger.set_enabled(true)
  end

  local manifest_content, manifest = acquire_manifest()
  if not manifest_content then
    return
  end
  local hash_algo = resolve_hash_algo(manifest, nil)
  local resolved_base, resolved_source = resolve_download_base(manifest)
  local source_state = create_source_state(resolved_base, resolved_source)
  ensure_base_dirs()

  log("INFO", "SAFE UPDATE started for role " .. tostring(role))
  local can_continue = update_installer_if_required(manifest, source_state, hash_algo)
  if not can_continue then
    return
  end

  local node_ok = ensure_node_id(role, cfg_path)
  if not node_ok then
    return
  end

  local updates = update_files(manifest, hash_algo)
  log("INFO", "Files needing update: " .. tostring(#updates))
  local staged, stage_err, stage_meta = stage_updates(updates, source_state, hash_algo)
  local retry_rounds = 0
  while not staged do
    if stage_meta and stage_meta.kind == "missing" then
      print("SAFE UPDATE aborted: " .. tostring(stage_err))
      log("ERROR", "SAFE UPDATE aborted: " .. tostring(stage_err))
      return
    elseif stage_meta and stage_meta.kind == "cancelled" then
      log("INFO", "SAFE UPDATE cancelled by user")
      return
    else
      print_download_failure("SAFE UPDATE failed: " .. tostring(stage_err), stage_meta and stage_meta.meta or stage_meta, nil)
      local choice = ui_menu(nil, { "Retry download", "Cancel" }, 1)
      if choice ~= 1 then
        log("ERROR", "SAFE UPDATE staging failed: " .. tostring(stage_err))
        return
      end
    end
    retry_rounds = retry_rounds + 1
    if retry_rounds > CONFIG.FILE_RETRY_ROUNDS then
      print("Retry limit reached. Installer cancelled.")
      log("WARN", "File retry limit reached; cancelling")
      return
    end
    os.sleep(CONFIG.FILE_RETRY_BACKOFF * retry_rounds)
    staged, stage_err, stage_meta = stage_updates(updates, source_state, hash_algo)
  end
  local backup_dir = create_backup_dir()
  local protected = { cfg_path, NODE_ID_PATH, "/startup.lua", MANIFEST_LOCAL, MANIFEST_CACHE }
  local update_paths = {}
  local created = {}
  for _, entry in ipairs(updates) do
    table.insert(update_paths, "/" .. entry.path)
  end

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, protected)

  local changed = 0
  local ok, err = apply_staged(updates, staged, created)
  if ok then
    changed = #updates
  end
  local migrated = false
  if ok then
    local success, result = pcall(migrate_config, role, cfg_path, manifest, source_state, hash_algo)
    if success then
      migrated = result
    else
      ok = false
      err = result
    end
  end

  if ok then
    local success, result = pcall(write_atomic, MANIFEST_LOCAL, manifest_content)
    if not success then
      ok = false
      err = result
    end
  end
  if ok then
    local cache_ok, cache_err = pcall(write_manifest_cache, manifest_content, source_state.source, source_state.base_url)
    if not cache_ok then
      ok = false
      err = cache_err
    end
  end

  if not ok then
    local rollback_paths = {}
    for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
    for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("SAFE UPDATE failed. Rolled back. Error: " .. tostring(err))
    print("Backup: " .. backup_dir)
    log("ERROR", "SAFE UPDATE rolled back: " .. tostring(err))
    return
  end

  local integrity_ok, integrity_err = verify_integrity(manifest, role, cfg_path)
  if not integrity_ok then
    local rollback_paths = {}
    for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
    for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("Integrity check failed: " .. tostring(integrity_err))
    print("Rollback complete. Backup: " .. backup_dir)
    log("ERROR", "SAFE UPDATE integrity failure: " .. tostring(integrity_err))
    return
  end

  print("SAFE UPDATE complete.")
  print("Changed files: " .. tostring(changed))
  if migrated then
    print("Config migration: updated defaults")
  end
  print("Backup: " .. backup_dir)
  print("Next steps: reboot or run the role entrypoint.")
  log("INFO", "SAFE UPDATE complete. Backup: " .. backup_dir)
  write_source_cache(source_state.base_url, source_state.source)
end

-- FULL REINSTALL overwrites all files and optionally restores existing config.
local function full_reinstall()
  local manifest_content, manifest = acquire_manifest()
  if not manifest_content then
    return
  end
  local hash_algo = resolve_hash_algo(manifest, nil)
  local resolved_base, resolved_source = resolve_download_base(manifest)
  local source_state = create_source_state(resolved_base, resolved_source)
  ensure_base_dirs()
  log("INFO", "FULL REINSTALL started")

  local existing_role, existing_cfg_path = find_existing_role()
  local keep_config = false
  if existing_role then
    local existing_cfg = read_config(existing_cfg_path, {})
    if existing_cfg.debug_logging == true and active_logger.set_enabled then
      active_logger.set_enabled(true)
    end
    keep_config = confirm("Keep existing config + role?", true)
  end

  local entries = build_manifest_entries(manifest)
  local staged, stage_err, stage_meta = stage_updates(entries, source_state, hash_algo)
  local retry_rounds = 0
  while not staged do
    if stage_meta and stage_meta.kind == "missing" then
      print("FULL REINSTALL aborted: " .. tostring(stage_err))
      log("ERROR", "FULL REINSTALL aborted: " .. tostring(stage_err))
      return
    elseif stage_meta and stage_meta.kind == "cancelled" then
      log("INFO", "FULL REINSTALL cancelled by user")
      return
    else
      print_download_failure("FULL REINSTALL failed: " .. tostring(stage_err), stage_meta and stage_meta.meta or stage_meta, nil)
      local choice = ui_menu(nil, { "Retry download", "Cancel" }, 1)
      if choice ~= 1 then
        log("ERROR", "FULL REINSTALL staging failed: " .. tostring(stage_err))
        return
      end
    end
    retry_rounds = retry_rounds + 1
    if retry_rounds > CONFIG.FILE_RETRY_ROUNDS then
      print("Retry limit reached. Installer cancelled.")
      log("WARN", "File retry limit reached; cancelling")
      return
    end
    os.sleep(CONFIG.FILE_RETRY_BACKOFF * retry_rounds)
    staged, stage_err, stage_meta = stage_updates(entries, source_state, hash_algo)
  end

  local backup_dir = create_backup_dir()
  local update_paths = {}
  local created = {}
  for _, entry in ipairs(entries) do
    table.insert(update_paths, "/" .. entry.path)
  end
  local protected = { NODE_ID_PATH, "/startup.lua", MANIFEST_LOCAL, MANIFEST_CACHE }
  for _, target in pairs(role_targets) do
    table.insert(protected, BASE_DIR .. "/" .. target.config)
  end

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, protected)

  local ok, err = apply_staged(entries, staged, created)
  if not ok then
    local rollback_paths = {}
    for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
    for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("FULL REINSTALL failed. Rolled back. Error: " .. tostring(err))
    log("ERROR", "FULL REINSTALL apply failed: " .. tostring(err))
    return
  end
  local role
  local cfg_path

  if keep_config and existing_role then
    restore_from_backup(backup_dir, protected)
    role = existing_role
    cfg_path = existing_cfg_path
    log("INFO", "Restored existing config for role " .. tostring(role))
  else
    role = choose_role()
    cfg_path = BASE_DIR .. "/" .. role_targets[role].config
    local modems = detect_modems()
    local wireless = select_primary_modem(modems)
    local wired = modems.wired[1]
    local extras = {}

    if not wireless then
      wireless = ui_prompt("Primary modem side", nil)
    end
    if wireless and wired == wireless then
      wired = nil
    end

    if role == roles.RT_NODE then
      local label = build_rt_node_id()
      os.setComputerLabel(label)
    end

    if role == roles.MASTER then
      extras.ui_scale_default = tonumber(ui_prompt("UI scale (0.5/1)", "0.5")) or 0.5
    elseif role == roles.RT_NODE then
      local detected = scan_peripherals()
      extras.modem = wireless
      local use_detected = #detected.reactors > 0
      if use_detected then
        print_detected("Detected Reactors", detected.reactors)
        print_detected("Detected Turbines", detected.turbines)
        print_detected("Detected Modems", detected.modems)
        use_detected = prompt_use_detected()
      else
        print("Warning: No reactors detected. Switching to manual entry.")
      end

      if use_detected then
        extras.reactors = detected.reactors
        extras.turbines = detected.turbines
        if #detected.turbines == 0 then
          print("No turbines detected. Reactor-only setup will be used.")
        end
      else
      local reactors = ui_prompt("Reactor peripheral names (comma separated)", "")
      local turbines = ui_prompt("Turbine peripheral names (comma separated)", "")
        extras.reactors = {}
        extras.turbines = {}
        for name in string.gmatch(reactors, "[^,]+") do table.insert(extras.reactors, trim(name)) end
        for name in string.gmatch(turbines, "[^,]+") do table.insert(extras.turbines, trim(name)) end
      end
      if not wireless then
        extras.modem = ui_prompt("Modem peripheral name", nil)
      end
    end

    if role == roles.RT_NODE then
      extras.node_id = build_rt_node_id()
    end
    write_config(role, wireless, wired, extras)
  end

  ensure_node_id(role, cfg_path)
  write_startup(role)
  write_atomic(MANIFEST_LOCAL, manifest_content)
  write_manifest_cache(manifest_content, source_state.source, source_state.base_url)
  write_source_cache(source_state.base_url, source_state.source)

  print("FULL REINSTALL complete.")
  print("Next steps: reboot or run the role entrypoint.")
  log("INFO", "FULL REINSTALL complete")
end

local function main()
  if not http then
    error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
  end
  print("=== XReactor Installer ===")
  log("INFO", "Installer started")
  if fs.exists(BASE_DIR) then
    print("Existing installation detected.")
    log("INFO", "Existing installation detected")
    local choice = ui_menu(nil, { "SAFE UPDATE", "FULL REINSTALL", "CANCEL" }, 1)
    if choice == 1 then
      safe_update()
    elseif choice == 2 then
      full_reinstall()
    else
      print("Cancelled.")
      log("INFO", "Installer cancelled by user")
    end
  else
    log("INFO", "No existing installation found; running full reinstall")
    full_reinstall()
  end
end

main()
