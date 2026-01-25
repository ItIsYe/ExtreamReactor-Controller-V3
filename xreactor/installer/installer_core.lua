local INSTALLER_CORE_VERSION = "1.4"

-- CONFIG
local CONFIG = {
  BASE_DIR = "/xreactor", -- Base install directory.
  REPO_OWNER = "ItIsYe", -- GitHub repository owner.
  REPO_NAME = "ExtreamReactor-Controller-V3", -- GitHub repository name.
  REPO_BASE_URL = "https://raw.githubusercontent.com", -- Raw GitHub base URL.
  DEFAULT_BRANCH = "beta", -- Default branch for base URLs when no commit SHA is pinned.
  RELEASE_REMOTE = "xreactor/installer/release.lua", -- Release metadata path.
  MANIFEST_REMOTE = "xreactor/installer/manifest.lua", -- Manifest path (fallback).
  MANIFEST_LOCAL = "/xreactor/.manifest", -- Cached manifest in install dir.
  MANIFEST_CACHE = "/xreactor/.cache/manifest.lua", -- Serialized manifest cache.
  MANIFEST_CACHE_LEGACY = "/xreactor/.manifest_cache", -- Legacy cache path.
  BACKUP_BASE = "/xreactor_backup", -- Backup base directory.
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  UPDATE_STAGING_BASE = "/xreactor_stage", -- Base staging folder for updates.
  INSTALLER_VERSION = "1.4", -- Installer version for min-version checks.
  INSTALLER_MIN_BYTES = 200, -- Min bytes to accept installer download.
  INSTALLER_SANITY_MARKER = "local function main", -- Installer sanity marker.
  MANIFEST_MIN_BYTES = 50, -- Min bytes to accept manifest download.
  MANIFEST_SANITY_MARKER = "return", -- Manifest sanity marker.
  RELEASE_MIN_BYTES = 50, -- Min bytes to accept release download.
  RELEASE_SANITY_MARKER = "commit_sha", -- Release sanity marker.
  DOWNLOAD_ATTEMPTS = 4, -- Download retry attempts (per URL).
  DOWNLOAD_BACKOFF = 1, -- Backoff base (seconds) between retries.
  DOWNLOAD_JITTER = 0.35, -- Max jitter seconds added to download backoff.
  DOWNLOAD_TIMEOUT = 8, -- HTTP timeout in seconds (used when http.request is available).
  DOWNLOAD_MIRRORS = { -- Download mirrors (raw content only).
    "https://raw.githubusercontent.com",
    "https://raw.github.com"
  },
  DOWNLOAD_HTML_SUSPECT_BYTES = 256, -- Treat small HTML-like responses as errors.
  MANIFEST_URL_PRIMARY = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/installer/manifest.lua", -- Primary manifest URL.
  MANIFEST_URL_FALLBACK = "https://cdn.jsdelivr.net/gh/ItIsYe/ExtreamReactor-Controller-V3@beta/xreactor/installer/manifest.lua", -- Optional fallback manifest URL.
  MANIFEST_RETRY_ATTEMPTS = 3, -- Retry attempts for manifest acquisition menu.
  MANIFEST_RETRY_BACKOFF = 1, -- Backoff seconds for manifest retry menu.
  MANIFEST_MENU_RETRY_LIMIT = 5, -- Retry rounds from menu before auto-cancel.
  FILE_RETRY_ROUNDS = 3, -- Retry rounds for file download failures.
  FILE_RETRY_BACKOFF = 1, -- Backoff seconds for file download retry rounds.
  BASE_CACHE_PATH = "/xreactor/.cache/source.lua", -- Cache for last good base URL.
  PROTOCOL_ABORT_ON_MAJOR_CHANGE = true, -- Abort SAFE UPDATE if protocol major version changes.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging for installer (nil uses settings/config).
  LOG_ENABLED = false, -- Enables installer file logging to /xreactor_logs/installer.log.
  LOG_PATH = "/xreactor/logs/installer_core.log", -- Installer log file path.
  LOG_MAX_BYTES = 200000, -- Rotate installer log after this size.
  LOG_BACKUP_SUFFIX = ".1", -- Suffix for rotated log file.
  LOG_PREFIX = "INSTALLER", -- Installer log prefix.
  LOG_SETTINGS_KEY = "xreactor.debug_logging", -- settings key for debug logs.
  LOG_FLUSH_LINES = 6, -- Buffered log lines before flushing.
  LOG_FLUSH_INTERVAL = 1.5, -- Seconds between log flushes.
  LOG_SAMPLE_BYTES = 96, -- Bytes to capture as response signature.
  CHECKSUM_DIAG_SAMPLE_BYTES = 80, -- Bytes to show when checksum mismatch occurs.
  REQUIRED_CORE_FILES = { -- Core files that must exist in the manifest.
    "xreactor/core/bootstrap.lua",
    "xreactor/core/logger.lua",
    "xreactor/core/network.lua",
    "xreactor/core/protocol.lua",
    "xreactor/core/safety.lua",
    "xreactor/core/state_machine.lua",
    "xreactor/core/trends.lua",
    "xreactor/core/control_rails.lua",
    "xreactor/core/ui.lua",
    "xreactor/core/ui_router.lua",
    "xreactor/core/update_recovery.lua",
    "xreactor/core/utils.lua",
    "xreactor/shared/colors.lua",
    "xreactor/shared/constants.lua"
  },
  FILE_MIGRATIONS = { -- Optional migrations for renamed files.
    -- { from = "xreactor/core/old.lua", to = "xreactor/core/new.lua" }
  }
}

local BASE_DIR = CONFIG.BASE_DIR
local REPO_OWNER = CONFIG.REPO_OWNER
local REPO_NAME = CONFIG.REPO_NAME
local REPO_BASE_URL_MAIN = CONFIG.REPO_BASE_URL
local RELEASE_REMOTE = CONFIG.RELEASE_REMOTE
local MANIFEST_REMOTE = CONFIG.MANIFEST_REMOTE
local MANIFEST_LOCAL = CONFIG.MANIFEST_LOCAL
local MANIFEST_CACHE = CONFIG.MANIFEST_CACHE
local MANIFEST_CACHE_LEGACY = CONFIG.MANIFEST_CACHE_LEGACY
local BACKUP_BASE = CONFIG.BACKUP_BASE
local NODE_ID_PATH = CONFIG.NODE_ID_PATH
local UPDATE_STAGING_BASE = CONFIG.UPDATE_STAGING_BASE
local INSTALLER_VERSION = CONFIG.INSTALLER_VERSION
local INSTALLER_MIN_BYTES = CONFIG.INSTALLER_MIN_BYTES
local INSTALLER_SANITY_MARKER = CONFIG.INSTALLER_SANITY_MARKER
local MANIFEST_MIN_BYTES = CONFIG.MANIFEST_MIN_BYTES
local MANIFEST_SANITY_MARKER = CONFIG.MANIFEST_SANITY_MARKER
local RELEASE_MIN_BYTES = CONFIG.RELEASE_MIN_BYTES
local RELEASE_SANITY_MARKER = CONFIG.RELEASE_SANITY_MARKER
local DOWNLOAD_ATTEMPTS = CONFIG.DOWNLOAD_ATTEMPTS
local DOWNLOAD_BACKOFF = CONFIG.DOWNLOAD_BACKOFF
local DOWNLOAD_TIMEOUT = CONFIG.DOWNLOAD_TIMEOUT
local CHECKSUM_DIAG_SAMPLE_BYTES = CONFIG.CHECKSUM_DIAG_SAMPLE_BYTES
local REQUIRED_CORE_FILES = CONFIG.REQUIRED_CORE_FILES
local FILE_MIGRATIONS = CONFIG.FILE_MIGRATIONS

-- Download base tracking (default branch vs pinned commit).
local current_base_url = nil
local current_base_source = CONFIG.DEFAULT_BRANCH
local current_base_sha = nil

-- BOOTSTRAP HELPERS (standalone, no external dependencies).
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

local function ensure_dir(path)
  if path == "" then return end
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

-- Internal standalone logger for the installer (no project dependencies).
local active_logger = {}
local internal_log_enabled = false
local log_buffer = {}
local log_last_flush = 0

local function resolve_log_enabled()
  if CONFIG.DEBUG_LOG_ENABLED ~= nil then
    return CONFIG.DEBUG_LOG_ENABLED == true
  end
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

local function rotate_log_if_needed()
  if not CONFIG.LOG_MAX_BYTES or CONFIG.LOG_MAX_BYTES <= 0 then
    return
  end
  if not fs.exists(CONFIG.LOG_PATH) then
    return
  end
  if fs.getSize(CONFIG.LOG_PATH) < CONFIG.LOG_MAX_BYTES then
    return
  end
  local backup = CONFIG.LOG_PATH .. (CONFIG.LOG_BACKUP_SUFFIX or ".1")
  if fs.exists(backup) then
    fs.delete(backup)
  end
  fs.move(CONFIG.LOG_PATH, backup)
end

local function internal_log(prefix, message, level)
  if not internal_log_enabled then
    return
  end
  local resolved_prefix = CONFIG.LOG_PREFIX
  local resolved_message = ""
  local resolved_level = "INFO"
  if level ~= nil then
    resolved_prefix = prefix or CONFIG.LOG_PREFIX
    resolved_message = message
    resolved_level = level or "INFO"
  else
    resolved_message = message
    resolved_level = prefix or "INFO"
  end
  local line = string.format("[%s] %s | %s | %s", log_stamp(), tostring(resolved_prefix), tostring(resolved_level), tostring(resolved_message))
  table.insert(log_buffer, line)
  local elapsed = os.clock() - (log_last_flush or 0)
  if #log_buffer < CONFIG.LOG_FLUSH_LINES and elapsed < CONFIG.LOG_FLUSH_INTERVAL then
    return
  end
  local ok = pcall(function()
    ensure_dir(fs.getDir(CONFIG.LOG_PATH))
    rotate_log_if_needed()
    local file = fs.open(CONFIG.LOG_PATH, "a")
    if not file then
      return
    end
    for _, entry in ipairs(log_buffer) do
      file.write(entry .. "\n")
    end
    file.close()
  end)
  log_buffer = {}
  log_last_flush = os.clock()
  if not ok then
    internal_log_enabled = false
  end
end

local function init_internal_logger()
  internal_log_enabled = resolve_log_enabled()
  log_last_flush = os.clock()
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

local fetch_url_seeded = false

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

local function normalize_newlines(content)
  if not content then return "" end
  return content:gsub("\r\n", "\n")
end

local function sanitize_snapshot(value, active)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" or value_type == "nil" then
    return value
  end
  if value_type ~= "table" then
    return tostring(value)
  end
  active = active or {}
  if active[value] then
    return "<cycle>"
  end
  active[value] = true
  local out = {}
  for key, val in next, value do
    local key_type = type(key)
    if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then
      key = tostring(key)
    end
    out[key] = sanitize_snapshot(val, active)
  end
  active[value] = nil
  return out
end

local function safe_serialize(value)
  local sanitized = sanitize_snapshot(value)
  local ok, result = pcall(textutils.serialize, sanitized)
  if not ok then
    return nil, result
  end
  return result
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
  return manifest.hash_algo or release.hash_algo
end

local function validate_hash_algo(manifest, release)
  local algo = resolve_hash_algo(manifest, release)
  local allowed = { ["sumlen-v1"] = true, ["crc32"] = true, ["sha1"] = true }
  if not allowed[algo] then
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

local UPDATE_MARKER_PATH = "/xreactor/.update_in_progress"

local function read_update_marker()
  if not fs.exists(UPDATE_MARKER_PATH) then
    return nil
  end
  local content = read_file(UPDATE_MARKER_PATH)
  if not content then
    return nil
  end
  local data = textutils.unserialize(content)
  if type(data) ~= "table" then
    return nil
  end
  return data
end

local function write_update_marker(data)
  write_atomic(UPDATE_MARKER_PATH, textutils.serialize(data or {}))
end

local function clear_update_marker()
  if fs.exists(UPDATE_MARKER_PATH) then
    fs.delete(UPDATE_MARKER_PATH)
  end
end

local function recover_update_marker()
  local marker = read_update_marker()
  if not marker then
    return false, "no marker"
  end
  local algo = marker.hash_algo or "crc32"
  if marker.stage_dir and fs.exists(marker.stage_dir) and type(marker.updates) == "table" then
    local staged_map = {}
    for _, entry in ipairs(marker.updates) do
      staged_map[entry.path] = marker.stage_dir .. "/" .. entry.path
      local verify = file_checksum(staged_map[entry.path], algo)
      if verify ~= entry.hash then
        if marker.rollback_paths and marker.backup_dir then
          rollback_from_backup(marker.backup_dir, marker.rollback_paths, marker.created or {})
        end
        clear_update_marker()
        return false, "staged verify mismatch: " .. entry.path
      end
    end
    local ok, apply_err = apply_staged(marker.updates, staged_map, {})
    if not ok then
      if marker.rollback_paths and marker.backup_dir then
        rollback_from_backup(marker.backup_dir, marker.rollback_paths, marker.created or {})
      end
      clear_update_marker()
      return false, apply_err
    end
    for _, entry in ipairs(marker.updates) do
      local target_path = "/" .. entry.path
      local verify = file_checksum(target_path, algo)
      if verify ~= entry.hash then
        if marker.rollback_paths and marker.backup_dir then
          rollback_from_backup(marker.backup_dir, marker.rollback_paths, marker.created or {})
        end
        clear_update_marker()
        return false, "verify mismatch: " .. entry.path
      end
    end
    if marker.stage_dir and fs.exists(marker.stage_dir) then
      fs.delete(marker.stage_dir)
    end
    clear_update_marker()
    return true, "applied"
  end
  if marker.rollback_paths and marker.backup_dir then
    rollback_from_backup(marker.backup_dir, marker.rollback_paths, marker.created or {})
  end
  clear_update_marker()
  return false, "rolled back"
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
  local serialized, err = safe_serialize(tbl)
  if not serialized then
    error("Config serialize failed: " .. tostring(err))
  end
  write_atomic(path, "return " .. serialized)
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

local function sanitize_signature(prefix)
  if not prefix or prefix == "" then
    return ""
  end
  local sample = prefix:gsub("[%c]", ".")
  return sample:sub(1, CONFIG.LOG_SAMPLE_BYTES or 96)
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

local function is_html_payload(content)
  if not content then return false end
  return detect_html(content:sub(1, 200))
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
  return detect_html(body:sub(1, 512))
end

local function is_suspect_html(body)
  if not body then
    return false
  end
  if #body <= (CONFIG.DOWNLOAD_HTML_SUSPECT_BYTES or 0) and is_html_response(body) then
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
      return true, "size mismatch", true
    end
  end
  return true
end

local function join_url(base, path)
  if not base or base == "" then
    return path
  end
  if not path or path == "" then
    return base
  end
  local cleaned_path = path:gsub("^/", "")
  if base:sub(-1) ~= "/" then
    return base .. "/" .. cleaned_path
  end
  return base .. cleaned_path
end

local function build_mirror_base_urls(base_url)
  local list = {}
  local seen = {}
  local function add(url)
    if url and url ~= "" and not seen[url] then
      table.insert(list, url)
      seen[url] = true
    end
  end
  add(base_url)
  local host, rest = base_url:match("^(https?://[^/]+)(/.*)$")
  if host and rest then
    for _, mirror in ipairs(CONFIG.DOWNLOAD_MIRRORS or {}) do
      if mirror ~= host then
        add(mirror .. rest)
      end
    end
  end
  return list
end

local function build_mirror_urls(base_url, path)
  local urls = {}
  local seen = {}
  for _, base in ipairs(build_mirror_base_urls(base_url)) do
    local url = join_url(base, path)
    if url and not seen[url] then
      table.insert(urls, url)
      seen[url] = true
    end
  end
  return urls
end

local function log_download_entry(entry, label)
  local name = label or "download"
  local level = entry.ok and "INFO" or "WARN"
  local msg = string.format(
    "%s attempt=%d url=%s ok=%s err=%s code=%s bytes=%s sig=%s",
    name,
    tonumber(entry.attempt) or 0,
    tostring(entry.url or "unknown"),
    tostring(entry.ok),
    tostring(entry.err or ""),
    tostring(entry.code or "n/a"),
    tostring(entry.bytes or 0),
    tostring(entry.signature or "")
  )
  log(level, msg)
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
  local prefix = body and body:sub(1, 1024) or ""
  local meta = {
    url = url,
    code = code,
    status = code,
    headers = headers,
    bytes = body and #body or 0,
    signature = sanitize_signature(prefix)
  }
  if not body or body == "" then
    meta.reason = "empty body"
    return false, nil, "empty body", meta
  end
  if is_suspect_html(body) then
    meta.reason = "html response"
    return false, nil, meta.reason, meta
  end
  local ok, reason, size_mismatch = validate_response(code, headers, prefix, body and #body or 0)
  if not ok then
    meta.reason = reason
    return false, nil, reason, meta
  end
  if size_mismatch then
    meta.size_mismatch = true
    meta.reason = reason
  end
  return true, body, nil, meta
end

-- Download helper with retries per URL and full tried list tracking.
local function fetch_with_retries(urls, max_attempts, backoff_seconds, opts)
  local attempts = max_attempts or DOWNLOAD_ATTEMPTS
  local backoff = backoff_seconds or DOWNLOAD_BACKOFF
  local tried = {}
  if not fetch_url_seeded then
    math.randomseed(os.time())
    fetch_url_seeded = true
  end
  local list = {}
  for _, url in ipairs(urls or {}) do
    if url and url ~= "" then
      table.insert(list, url)
    end
  end
  if #list == 0 then
    list = { CONFIG.MANIFEST_URL_PRIMARY }
  end
  for _, url in ipairs(list) do
    for attempt = 1, attempts do
      local ok, body, err, meta = fetch_url(url, { timeout = DOWNLOAD_TIMEOUT })
      local entry = {
        url = url,
        ok = ok,
        err = err,
        bytes = body and #body or 0,
        code = meta and meta.code or nil,
        headers = meta and meta.headers or nil,
        reason = meta and meta.reason or nil,
        size_mismatch = meta and meta.size_mismatch or nil,
        signature = meta and meta.signature or nil,
        starts_with_lt = body and body:sub(1, 1) == "<" or false,
        attempt = attempt
      }
      if not entry.ok then
        entry.err = entry.err or entry.reason
      end
      if ok and entry.size_mismatch and not (opts and opts.allow_size_mismatch) then
        entry.ok = false
        entry.err = "size mismatch"
      end
      table.insert(tried, entry)
      log_download_entry(entry, "fetch")
      if ok then
        return true, body, { tried = tried, last = entry }
      end
      if attempt < attempts then
        local jitter = math.random() * (CONFIG.DOWNLOAD_JITTER or 0)
        os.sleep((backoff * attempt) + jitter)
      end
    end
  end
  local last_entry = tried[#tried] or { url = list[1], ok = false, err = "timeout or http error", bytes = 0 }
  return false, nil, { tried = tried, last = last_entry }
end

local function download_with_retry(urls, max_attempts, backoff_seconds, opts)
  local attempts = max_attempts or DOWNLOAD_ATTEMPTS
  local backoff = backoff_seconds or DOWNLOAD_BACKOFF
  local tried = {}
  local list = {}
  for _, url in ipairs(urls or {}) do
    if url and url ~= "" then
      table.insert(list, url)
    end
  end
  if #list == 0 then
    return false, nil, { tried = {}, last = { url = nil, ok = false, err = "no urls" } }
  end
  for attempt = 1, attempts do
    for _, url in ipairs(list) do
      local ok, body, err, meta = fetch_url(url, { timeout = DOWNLOAD_TIMEOUT })
      local entry = {
        url = url,
        ok = ok,
        err = err,
        bytes = body and #body or 0,
        code = meta and meta.code or nil,
        headers = meta and meta.headers or nil,
        reason = meta and meta.reason or nil,
        size_mismatch = meta and meta.size_mismatch or nil,
        signature = meta and meta.signature or nil,
        attempt = attempt
      }
      if not entry.ok then
        entry.err = entry.err or entry.reason
      end
      if ok and entry.size_mismatch and not (opts and opts.allow_size_mismatch) then
        entry.ok = false
        entry.err = "size mismatch"
      end
      if entry.ok and opts and opts.validate then
        local valid, reason = opts.validate(body, meta, entry)
        if not valid then
          entry.ok = false
          entry.err = reason or "validation failed"
        end
      end
      table.insert(tried, entry)
      log_download_entry(entry, "download")
      if entry.ok then
        return true, body, { tried = tried, last = entry }
      end
    end
    if attempt < attempts then
      if not fetch_url_seeded then
        math.randomseed(os.time())
        fetch_url_seeded = true
      end
      local jitter = math.random() * (CONFIG.DOWNLOAD_JITTER or 0)
      os.sleep((backoff * attempt) + jitter)
    end
  end
  local last_entry = tried[#tried] or { url = list[1], ok = false, err = "timeout or http error", bytes = 0 }
  return false, nil, { tried = tried, last = last_entry }
end

local function download_file_with_retry(urls, expected_hash, hash_algo, opts)
  local function validate(body, meta, entry)
    if expected_hash then
      local actual = compute_hash(body, hash_algo)
      entry.expected_hash = expected_hash
      entry.actual_hash = actual
      entry.expected_size = opts and opts.expected_size or nil
      if actual ~= expected_hash then
        return false, ("checksum mismatch expected=%s actual=%s"):format(expected_hash, actual)
      end
    end
    return true
  end
  return download_with_retry(
    urls,
    opts and opts.attempts or DOWNLOAD_ATTEMPTS,
    opts and opts.backoff or DOWNLOAD_BACKOFF,
    {
      allow_size_mismatch = true,
      validate = validate
    }
  )
end

local function is_valid_sha(sha)
  return type(sha) == "string" and sha:match("^[a-fA-F0-9]+$") and #sha == 40
end

local function build_main_base_url()
  return string.format("%s/%s/%s/%s/", REPO_BASE_URL_MAIN, REPO_OWNER, REPO_NAME, CONFIG.DEFAULT_BRANCH or "main")
end

local function build_commit_base_url(sha)
  return string.format("%s/%s/%s/%s/", REPO_BASE_URL_MAIN, REPO_OWNER, REPO_NAME, sha)
end

local function read_base_cache()
  if not fs.exists(CONFIG.BASE_CACHE_PATH) then
    return nil
  end
  local content = read_file(CONFIG.BASE_CACHE_PATH)
  if not content then
    return nil
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

local function write_base_cache(payload)
  local serialized, err = safe_serialize(payload)
  if not serialized then
    log("WARN", "Unable to serialize base cache: " .. tostring(err))
    return
  end
  write_atomic(CONFIG.BASE_CACHE_PATH, serialized)
end

local function set_base_source(base_url, source, sha)
  current_base_url = base_url
  current_base_source = source or CONFIG.DEFAULT_BRANCH
  current_base_sha = sha
  write_base_cache({
    last_good_base_url = current_base_url,
    last_good_source = current_base_source,
    last_good_sha = current_base_sha
  })
end

local function build_manifest_sources(release)
  local sources = {}
  local sha = release and release.commit_sha
  if is_valid_sha(sha) then
    table.insert(sources, { base_url = build_commit_base_url(sha), source = "sha", sha = sha })
  else
    if sha then
      log("WARN", "Invalid commit SHA format; falling back to default branch")
    end
  end
  table.insert(sources, { base_url = build_main_base_url(), source = CONFIG.DEFAULT_BRANCH, sha = nil })
  return sources
end

local function fetch_repo_file(ref, path, opts)
  local base = current_base_url or build_main_base_url()
  local urls = build_mirror_urls(base, path)
  local ok, body, info = fetch_with_retries(urls, opts and opts.attempts, opts and opts.backoff, {
    allow_size_mismatch = opts and opts.allow_size_mismatch
  })
  if not ok then
    return false, nil, info
  end
  local ok_sanity, reason = sanity_check(body, opts and opts.min_bytes, opts and opts.marker)
  if not ok_sanity then
    local entry = info and info.last or { url = urls[1], ok = false, err = reason, bytes = body and #body or 0 }
    entry.ok = false
    entry.err = reason
    return false, nil, { tried = info and info.tried or { entry }, last = entry }
  end
  return true, body, info
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
  if not path then
    return nil
  end
  local content = read_file(path)
  if not content then
    return nil
  end
  local ok, data = pcall(textutils.unserialize, content)
  if not ok or type(data) ~= "table" then
    return nil
  end
  if type(data.manifest_content) ~= "string" then
    return nil
  end
  if type(data.release) ~= "table" or type(data.release.commit_sha) ~= "string" then
    return nil
  end
  if type(data.base_url) ~= "string" then
    return nil
  end
  return data
end

local function write_manifest_cache(manifest_content, release, source, base_info)
  local safe_release = {
    commit_sha = release and release.commit_sha,
    hash_algo = release and release.hash_algo,
    manifest_path = release and release.manifest_path
  }
  local payload = {
    manifest_content = manifest_content,
    release = safe_release,
    source = source,
    base_url = base_info and base_info.base_url,
    base_source = base_info and base_info.source,
    base_sha = base_info and base_info.sha,
    saved_at = os.time()
  }
  local serialized, err = safe_serialize(payload)
  if not serialized then
    local fallback = safe_serialize({
      manifest_content = manifest_content,
      saved_at = os.time()
    })
    if fallback then
      write_atomic(MANIFEST_CACHE, fallback)
    else
      print("Warning: unable to save manifest cache.")
      log("WARN", "Unable to serialize manifest cache: " .. tostring(err))
    end
    return
  end
  write_atomic(MANIFEST_CACHE, serialized)
end

local function describe_download_error(err)
  if err == "html response" then
    return "Downloaded HTML, expected Lua"
  end
  return err or "timeout or http error"
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
  reason = describe_download_error(reason)
  if #tried_list == 0 then
    tried_list = { CONFIG.MANIFEST_URL_PRIMARY }
    if CONFIG.MANIFEST_URL_FALLBACK then
      table.insert(tried_list, CONFIG.MANIFEST_URL_FALLBACK)
    end
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
    urls = { CONFIG.MANIFEST_URL_PRIMARY }
  end
  return urls
end

local function print_download_failure(label, info, fallback_urls)
  local urls = collect_tried_urls(info, fallback_urls)
  local last = info and info.last or {}
  local err_msg = describe_download_error(last.err)
  print(label)
  print(("Last error: %s (url=%s)"):format(
    tostring(err_msg),
    tostring(last.url or urls[1])
  ))
  local signature = last.signature or ""
  local is_checksum = last.err and tostring(last.err):find("checksum mismatch", 1, true)
  if is_checksum then
    local expected_size = last.expected_size or "n/a"
    local actual_size = last.bytes or "n/a"
    local expected_hash = last.expected_hash or "n/a"
    local actual_hash = last.actual_hash or "n/a"
    local headers = last.headers or {}
    local content_length = headers["Content-Length"] or headers["content-length"] or "n/a"
    local starts_with_lt = last.starts_with_lt and "yes" or "no"
    print(("Expected size: %s bytes, actual size: %s bytes"):format(tostring(expected_size), tostring(actual_size)))
    print(("Expected crc32: %s, actual crc32: %s"):format(tostring(expected_hash), tostring(actual_hash)))
    print(("Content-Length: %s"):format(tostring(content_length)))
    print(("Starts with '<': %s"):format(starts_with_lt))
    if signature ~= "" then
      local sample = signature:sub(1, CHECKSUM_DIAG_SAMPLE_BYTES or 80)
      print(("Response signature (first %d): %s"):format(CHECKSUM_DIAG_SAMPLE_BYTES or 80, tostring(sample)))
    end
  elseif signature ~= "" then
    print(("Response signature: %s"):format(tostring(signature)))
  end
end

local function download_release()
  local urls = build_mirror_urls(build_main_base_url(), RELEASE_REMOTE)
  local ok, content, meta = download_with_retry(urls, DOWNLOAD_ATTEMPTS, DOWNLOAD_BACKOFF)
  if not ok then
    return nil, "Release download failed", meta
  end
  local ok_sanity, reason = sanity_check(content, RELEASE_MIN_BYTES, RELEASE_SANITY_MARKER)
  if not ok_sanity then
    local entry = meta and meta.last or { url = url, ok = false, err = reason, bytes = content and #content or 0 }
    entry.ok = false
    entry.err = reason
    meta = { tried = meta and meta.tried or { entry }, last = entry }
    return nil, "Release download failed", meta
  end
  local loader = load(content, "release", "t", {})
  if not loader then
    return nil, "Release load failed", meta
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then
    return nil, "Release parse failed", meta
  end
  if type(data.commit_sha) ~= "string" then
    return nil, "Release missing commit_sha", meta
  end
  if type(data.hash_algo) ~= "string" then
    return nil, "Release missing hash_algo", meta
  end
  data.manifest_path = data.manifest_path or MANIFEST_REMOTE
  log("INFO", "Release fetched: " .. data.commit_sha)
  return data, meta
end

local function validate_manifest_required(manifest)
  local missing = {}
  for _, path in ipairs(REQUIRED_CORE_FILES or {}) do
    if not manifest.lookup or not manifest.lookup[path] then
      table.insert(missing, path)
    end
  end
  if #missing > 0 then
    return nil, "Manifest missing required files: " .. table.concat(missing, ", ")
  end
  for _, migration in ipairs(FILE_MIGRATIONS or {}) do
    if type(migration) == "table" then
      local to_path = migration.to
      local from_path = migration.from
      if to_path and from_path and not manifest.lookup[to_path] then
        return nil, ("Manifest missing migration target %s (from %s)"):format(to_path, from_path)
      end
    end
  end
  return true
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
  if type(data.manifest_version) ~= "number" then
    return nil, "Manifest missing manifest_version"
  end
  if type(data.source_ref) ~= "string" then
    return nil, "Manifest missing source_ref"
  end
  local entries = {}
  for _, entry in ipairs(data.files) do
    if type(entry) ~= "table" then
      return nil, "Manifest entry invalid"
    end
    if type(entry.path) ~= "string" or entry.path == "" then
      return nil, "Manifest entry missing path"
    end
    if type(entry.hash) ~= "string" or entry.hash == "" then
      return nil, "Manifest entry missing hash"
    end
    if type(entry.size_bytes) ~= "number" or entry.size_bytes < 1 then
      return nil, "Manifest entry missing size"
    end
    table.insert(entries, {
      path = entry.path,
      hash = entry.hash,
      size_bytes = entry.size_bytes
    })
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  local lookup = {}
  for _, entry in ipairs(entries) do
    lookup[entry.path] = entry
  end
  data.entries = entries
  data.lookup = lookup
  local ok, err = validate_manifest_required(data)
  if not ok then
    return nil, err
  end
  return data
end

local function download_manifest_from_source(release, base_info)
  local manifest_path = release.manifest_path or MANIFEST_REMOTE
  local urls = build_mirror_urls(base_info.base_url, manifest_path)
  if base_info.source == CONFIG.DEFAULT_BRANCH and CONFIG.MANIFEST_URL_FALLBACK then
    table.insert(urls, CONFIG.MANIFEST_URL_FALLBACK)
  end
  local ok, content, meta = download_with_retry(urls, DOWNLOAD_ATTEMPTS, DOWNLOAD_BACKOFF)
  if not ok then
    return nil, "Manifest download failed", meta
  end
  local ok_sanity, reason = sanity_check(content, MANIFEST_MIN_BYTES, MANIFEST_SANITY_MARKER)
  if not ok_sanity then
    local entry = meta and meta.last or { url = urls[1], ok = false, err = reason, bytes = content and #content or 0 }
    entry.ok = false
    entry.err = reason
    meta = { tried = meta and meta.tried or { entry }, last = entry }
    return nil, "Manifest download failed", meta
  end
  local manifest, manifest_err = parse_manifest(content)
  if not manifest then
    return nil, manifest_err, meta
  end
  if base_info.source == "sha" and manifest.source_ref ~= base_info.sha then
    return nil, "Manifest source_ref mismatch", meta
  end
  validate_hash_algo(manifest, release)
  return content, manifest, meta
end

local function download_manifest_with_retries(attempts, backoff)
  local max_attempts = attempts or CONFIG.MANIFEST_RETRY_ATTEMPTS or 1
  local delay = backoff or CONFIG.MANIFEST_RETRY_BACKOFF or 1
  local last_meta
  for attempt = 1, max_attempts do
    log("WARN", ("Manifest download attempt %d/%d"):format(attempt, max_attempts))
    local release, release_err, release_meta = download_release()
    if not release then
      last_meta = release_meta
    else
      local sources = build_manifest_sources(release)
      for _, base_info in ipairs(sources) do
        if base_info.source == "sha" then
          log("INFO", "Attempting pinned manifest download")
        end
        local content, manifest, meta = download_manifest_from_source(release, base_info)
        if content then
          set_base_source(base_info.base_url, base_info.source, base_info.sha)
          write_manifest_cache(content, release, base_info.source, base_info)
          if meta then
            meta.attempt = attempt
          end
          log("INFO", "Manifest fetched from " .. tostring(base_info.source))
          return content, manifest, release, meta
        end
        last_meta = meta
        if base_info.source == "sha" then
          print(("Pinned commit download failed, falling back to %s."):format(CONFIG.DEFAULT_BRANCH))
          log("WARN", "Pinned manifest download failed; falling back to default branch")
        end
      end
    end
    if attempt < max_attempts then
      os.sleep(delay * attempt)
    end
  end
  return nil, nil, nil, last_meta
end

local function acquire_manifest()
  local manifest_content, manifest, release, manifest_meta = download_manifest_with_retries(1, 0)
  local retry_rounds = 0
  while not manifest_content do
    local cache = read_manifest_cache()
    local failure = format_manifest_failure(manifest_meta)
    print(failure)
    if manifest_meta and manifest_meta.last then
      local last = manifest_meta.last
      print(("Last error: %s (url=%s)"):format(tostring(last.err or "timeout or http error"), tostring(last.url or "unknown")))
    end
    log("WARN", failure)
    local default_choice = cache and 1 or 1
    local choice = ui_menu(nil, cache and {
      "Use cached manifest (offline update)",
      "Retry download",
      "Cancel"
    } or {
      "Retry download",
      "Cancel"
    }, default_choice)
    if cache and choice == 1 then
      manifest_content = cache.manifest_content
      local parsed, parse_err = parse_manifest(manifest_content)
      if not parsed then
        print("Cached manifest invalid: " .. tostring(parse_err))
        log("ERROR", "Cached manifest invalid: " .. tostring(parse_err))
        return nil
      end
      if type(cache.base_url) ~= "string" then
        print("Cached manifest missing base URL.")
        log("ERROR", "Cached manifest missing base URL")
        return nil
      end
      manifest = parsed
      release = cache.release
      manifest_meta = cache.source
      set_base_source(cache.base_url, cache.base_source, cache.base_sha)
      validate_hash_algo(manifest, release)
      break
    elseif (cache and choice == 2) or (not cache and choice == 1) then
      retry_rounds = retry_rounds + 1
      if retry_rounds > CONFIG.MANIFEST_MENU_RETRY_LIMIT then
        print("Retry limit reached. Installer cancelled.")
        log("WARN", "Manifest retry limit reached; cancelling")
        return nil
      end
      manifest_content, manifest, release, manifest_meta = download_manifest_with_retries()
    else
      print("Installer cancelled.")
      log("INFO", "User cancelled manifest acquisition")
      return nil
    end
  end
  return manifest_content, manifest, release, manifest_meta
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
  if not path then
    return false
  end
  if path:match("^xreactor/config/") then
    return true
  end
  if path:match("/config%.lua$") ~= nil then
    return true
  end
  return false
end

local function parse_proto_version_from_content(content)
  if not content or content == "" then
    return nil
  end
  local block = content:match("proto_ver%s*=%s*(%b{})")
  if not block then
    return nil
  end
  local major = tonumber(block:match("major%s*=%s*(%d+)"))
  local minor = tonumber(block:match("minor%s*=%s*(%d+)"))
  if not major or not minor then
    return nil
  end
  return { major = major, minor = minor }
end

local function load_proto_version(path)
  if not path or not fs.exists(path) then
    return nil
  end
  local content = read_file(path)
  return parse_proto_version_from_content(content)
end

local function format_proto_version(ver)
  if not ver then
    return "unknown"
  end
  return tostring(ver.major) .. "." .. tostring(ver.minor)
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
  for _, entry in ipairs(manifest.entries or {}) do
    local path = entry.path
    if not is_config_file(path) then
      local full_path = "/" .. path
      local needs_update = false
      if not fs.exists(full_path) then
        needs_update = true
      else
        if entry.size_bytes and fs.getSize(full_path) ~= entry.size_bytes then
          needs_update = true
        else
          local local_hash = file_checksum(full_path, hash_algo)
          if local_hash ~= entry.hash then
            needs_update = true
          end
        end
      end
      if needs_update then
        table.insert(updates, { path = entry.path, hash = entry.hash, size_bytes = entry.size_bytes })
      end
    end
  end
  table.sort(updates, function(a, b) return a.path < b.path end)
  return updates
end

local function build_staging_dir()
  ensure_dir(UPDATE_STAGING_BASE)
  if not fetch_url_seeded then
    math.randomseed(os.time())
    fetch_url_seeded = true
  end
  local stamp = os.epoch and os.epoch("utc") or os.time()
  local dir = string.format("%s/%s-%d", UPDATE_STAGING_BASE, tostring(stamp), math.random(1000, 9999))
  ensure_dir(dir)
  return dir
end

local function cleanup_staging(dir)
  if dir and fs.exists(dir) then
    fs.delete(dir)
  end
end

local function build_staging_path(stage_dir, path)
  return stage_dir .. "/" .. path
end

local function stage_updates(entries, release, hash_algo)
  local stage_dir = build_staging_dir()
  local staged = {}
  for _, entry in ipairs(entries) do
    local base = current_base_url or build_main_base_url()
    local urls = build_mirror_urls(base, entry.path)
    local ok, content, meta = download_file_with_retry(urls, entry.hash, hash_algo, {
      expected_size = entry.size_bytes
    })
    if not ok then
      cleanup_staging(stage_dir)
      return nil, ("Download failed for %s"):format(entry.path), meta, "download"
    end
    local staging_path = build_staging_path(stage_dir, entry.path)
    write_atomic(staging_path, content)
    local verify = file_checksum(staging_path, hash_algo)
    if verify ~= entry.hash then
      cleanup_staging(stage_dir)
      return nil, ("Integrity check failed for %s (staged mismatch expected=%s actual=%s)"):format(
        entry.path,
        entry.hash,
        verify
      ), nil, "integrity"
    end
    staged[entry.path] = staging_path
  end
  return staged, nil, nil, stage_dir
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

local function build_migration_paths()
  local paths = {}
  for _, migration in ipairs(FILE_MIGRATIONS or {}) do
    if type(migration) == "table" and migration.from then
      table.insert(paths, "/" .. migration.from)
    end
  end
  return paths
end

local function apply_file_migrations()
  local applied = {}
  for _, migration in ipairs(FILE_MIGRATIONS or {}) do
    if type(migration) == "table" and migration.from and migration.to then
      local from_path = "/" .. migration.from
      local to_path = "/" .. migration.to
      if fs.exists(from_path) then
        if not fs.exists(to_path) then
          return false, ("Migration target missing: %s (from %s)"):format(migration.to, migration.from)
        end
        fs.delete(from_path)
        table.insert(applied, migration.from)
      end
    end
  end
  return true, applied
end

local function update_installer_if_required(manifest, release, hash_algo)
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
    local base = current_base_url or build_main_base_url()
    local urls = build_mirror_urls(base, installer_path)
    local ok, content, meta = download_file_with_retry(urls, expected, hash_algo, {
      expected_size = manifest.installer_size_bytes
    })
    if not ok then
      local last = meta and meta.last or {}
      print(("SAFE UPDATE aborted: installer download failed (url=%s reason=%s)"):format(
        tostring(last.url or installer_path),
        tostring(describe_download_error(last.err))
      ))
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

local function migrate_config(role, cfg_path, manifest, release, hash_algo)
  local remote_path = "xreactor/" .. role_targets[role].config
  local entry = manifest.lookup and manifest.lookup[remote_path] or nil
  local expected_hash = entry and entry.hash or nil
  if not expected_hash then
    return false
  end
  local base = current_base_url or build_main_base_url()
  local urls = build_mirror_urls(base, remote_path)
  local ok, content, meta = download_file_with_retry(urls, expected_hash, hash_algo, {
    expected_size = entry and entry.size_bytes or nil
  })
  if not ok then
    local last = meta and meta.last or {}
    error(("Config download failed (url=%s reason=%s)"):format(
      tostring(last.url or remote_path),
      tostring(last.err or "timeout or http error")
    ))
  end
  local defaults = read_config_from_content(content)
  local existing = read_config(cfg_path, {})
  local original = safe_serialize(existing) or ""
  merge_defaults(existing, defaults)
  if existing.role ~= role then
    existing.role = role
  end
  local normalized_node_id = normalize_node_id(existing.node_id)
  if not normalized_node_id then
    normalized_node_id = fallback_node_id()
  end
  existing.node_id = normalized_node_id
  local updated = safe_serialize(existing) or ""
  if updated ~= original then
    write_config_file(cfg_path, existing)
    return true
  end
  return false
end

local function verify_integrity(manifest, role, cfg_path)
  local required = {
    "xreactor/core/bootstrap.lua",
    "xreactor/core/network.lua",
    "xreactor/core/protocol.lua",
    "xreactor/core/utils.lua",
    "xreactor/shared/colors.lua",
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
  for _, entry in ipairs(manifest.entries or {}) do
    table.insert(entries, { path = entry.path, hash = entry.hash, size_bytes = entry.size_bytes })
  end
  if manifest.installer_path and manifest.installer_hash and manifest.installer_size_bytes then
    table.insert(entries, {
      path = manifest.installer_path,
      hash = manifest.installer_hash,
      size_bytes = manifest.installer_size_bytes
    })
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

  local manifest_content
  local manifest
  local release
  local manifest_meta
  local hash_algo
  local updates
  local staged
  local stage_dir
  local retry_rounds = 0
  while true do
    manifest_content, manifest, release, manifest_meta = acquire_manifest()
    if not manifest_content then
      return
    end
    hash_algo = resolve_hash_algo(manifest, release)
    print(("Debug: manifest source=%s base=%s hash=%s"):format(
      tostring(current_base_source or "unknown"),
      tostring(current_base_url or "unknown"),
      tostring(hash_algo or "unknown")
    ))
    ensure_base_dirs()

    log("INFO", "SAFE UPDATE started for role " .. tostring(role))
    local can_continue = update_installer_if_required(manifest, release, hash_algo)
    if not can_continue then
      return
    end

    local node_ok = ensure_node_id(role, cfg_path)
    if not node_ok then
      return
    end

    updates = update_files(manifest, hash_algo)
    log("INFO", "Files needing update: " .. tostring(#updates))
    local stage_err
    local stage_meta
    staged, stage_err, stage_meta, stage_dir = stage_updates(updates, release, hash_algo)
    if staged then
      break
    end
    print_download_failure("SAFE UPDATE failed: " .. tostring(stage_err), stage_meta, nil)
    local choice = ui_menu(nil, { "Retry download", "Cancel" }, 1)
    if choice ~= 1 then
      log("ERROR", "SAFE UPDATE staging failed: " .. tostring(stage_err))
      cleanup_staging(stage_dir)
      return
    end
    retry_rounds = retry_rounds + 1
    if retry_rounds > CONFIG.FILE_RETRY_ROUNDS then
      print("Retry limit reached. Installer cancelled.")
      log("WARN", "File retry limit reached; cancelling")
      cleanup_staging(stage_dir)
      return
    end
    os.sleep(CONFIG.FILE_RETRY_BACKOFF * retry_rounds)
  end
  local backup_dir = create_backup_dir()
  local protected = { cfg_path, NODE_ID_PATH, "/startup.lua", MANIFEST_LOCAL, MANIFEST_CACHE }
  local update_paths = {}
  local created = {}
  local migration_paths = build_migration_paths()
  for _, entry in ipairs(updates) do
    table.insert(update_paths, "/" .. entry.path)
  end

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, migration_paths)
  backup_files(backup_dir, protected)

  local created_before = {}
  for _, path in ipairs(update_paths) do
    if not fs.exists(path) then
      table.insert(created_before, path)
    end
  end
  local rollback_paths = {}
  for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
  for _, path in ipairs(migration_paths) do table.insert(rollback_paths, path) end
  for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
  write_update_marker({
    ts = os.epoch("utc"),
    version = manifest.version or release and release.commit_sha or "unknown",
    stage_dir = stage_dir,
    backup_dir = backup_dir,
    updates = updates,
    created = created_before,
    rollback_paths = rollback_paths,
    hash_algo = hash_algo
  })

  local local_proto = load_proto_version("/xreactor/shared/constants.lua")
  local staged_proto = nil
  if staged["xreactor/shared/constants.lua"] then
    staged_proto = load_proto_version(staged["xreactor/shared/constants.lua"])
  end
  if CONFIG.PROTOCOL_ABORT_ON_MAJOR_CHANGE and local_proto and staged_proto then
    if local_proto.major ~= staged_proto.major then
      local message = ("Protocol major change detected (%s -> %s). SAFE UPDATE aborted."):format(
        format_proto_version(local_proto),
        format_proto_version(staged_proto)
      )
      print(message)
      log("WARN", message)
      cleanup_staging(stage_dir)
      clear_update_marker()
      return
    end
  end

  local changed = 0
  local ok, err = apply_staged(updates, staged, created)
  if ok then
    changed = #updates
  end
  if ok then
    local migrate_ok, migrate_err = apply_file_migrations()
    if not migrate_ok then
      ok = false
      err = migrate_err
    end
  end
  local migrated = false
  if ok then
    local success, result = pcall(migrate_config, role, cfg_path, manifest, release, hash_algo)
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
    local cache_ok, cache_err = pcall(write_manifest_cache, manifest_content, release, current_base_source, {
      base_url = current_base_url,
      source = current_base_source,
      sha = current_base_sha
    })
    if not cache_ok then
      ok = false
      err = cache_err
    end
  end

  if not ok then
    rollback_from_backup(backup_dir, rollback_paths, created)
    cleanup_staging(stage_dir)
    clear_update_marker()
    print("SAFE UPDATE failed. Rolled back. Error: " .. tostring(err))
    print("Backup: " .. backup_dir)
    log("ERROR", "SAFE UPDATE rolled back: " .. tostring(err))
    return
  end

  local integrity_ok, integrity_err = verify_integrity(manifest, role, cfg_path)
  if not integrity_ok then
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("Integrity check failed: " .. tostring(integrity_err))
    print("Rollback complete. Backup: " .. backup_dir)
    log("ERROR", "SAFE UPDATE integrity failure: " .. tostring(integrity_err))
    cleanup_staging(stage_dir)
    clear_update_marker()
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
  clear_update_marker()
  cleanup_staging(stage_dir)
end

-- FULL REINSTALL overwrites all files and optionally restores existing config.
local function full_reinstall()
  local manifest_content
  local manifest
  local release
  local manifest_meta
  local hash_algo
  local staged
  local stage_dir
  local retry_rounds = 0
  local existing_role
  local existing_cfg_path
  local keep_config = false
  while true do
    manifest_content, manifest, release, manifest_meta = acquire_manifest()
    if not manifest_content then
      return
    end
    hash_algo = resolve_hash_algo(manifest, release)
    print(("Debug: manifest source=%s base=%s hash=%s"):format(
      tostring(current_base_source or "unknown"),
      tostring(current_base_url or "unknown"),
      tostring(hash_algo or "unknown")
    ))
    ensure_base_dirs()
    log("INFO", "FULL REINSTALL started")

    existing_role, existing_cfg_path = find_existing_role()
    keep_config = false
    if existing_role then
      local existing_cfg = read_config(existing_cfg_path, {})
      if existing_cfg.debug_logging == true and active_logger.set_enabled then
        active_logger.set_enabled(true)
      end
      keep_config = confirm("Keep existing config + role?", true)
    end

    local entries = build_manifest_entries(manifest)
    local stage_err
    local stage_meta
    staged, stage_err, stage_meta, stage_dir = stage_updates(entries, release, hash_algo)
    if staged then
      break
    end
    print_download_failure("FULL REINSTALL failed: " .. tostring(stage_err), stage_meta, nil)
    local choice = ui_menu(nil, { "Retry download", "Cancel" }, 1)
    if choice ~= 1 then
      log("ERROR", "FULL REINSTALL staging failed: " .. tostring(stage_err))
      cleanup_staging(stage_dir)
      return
    end
    retry_rounds = retry_rounds + 1
    if retry_rounds > CONFIG.FILE_RETRY_ROUNDS then
      print("Retry limit reached. Installer cancelled.")
      log("WARN", "File retry limit reached; cancelling")
      cleanup_staging(stage_dir)
      return
    end
    os.sleep(CONFIG.FILE_RETRY_BACKOFF * retry_rounds)
  end

  local backup_dir = create_backup_dir()
  local update_paths = {}
  local created = {}
  local migration_paths = build_migration_paths()
  local entries = build_manifest_entries(manifest)
  for _, entry in ipairs(entries) do
    table.insert(update_paths, "/" .. entry.path)
  end
  local protected = { NODE_ID_PATH, "/startup.lua", MANIFEST_LOCAL, MANIFEST_CACHE }
  for _, target in pairs(role_targets) do
    table.insert(protected, BASE_DIR .. "/" .. target.config)
  end

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, migration_paths)
  backup_files(backup_dir, protected)

  local created_before = {}
  for _, path in ipairs(update_paths) do
    if not fs.exists(path) then
      table.insert(created_before, path)
    end
  end
  local rollback_paths = {}
  for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
  for _, path in ipairs(migration_paths) do table.insert(rollback_paths, path) end
  for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
  write_update_marker({
    ts = os.epoch("utc"),
    version = manifest.version or release and release.commit_sha or "unknown",
    stage_dir = stage_dir,
    backup_dir = backup_dir,
    updates = entries,
    created = created_before,
    rollback_paths = rollback_paths,
    hash_algo = hash_algo
  })

  local ok, err = apply_staged(entries, staged, created)
  if ok then
    local migrate_ok, migrate_err = apply_file_migrations()
    if not migrate_ok then
      ok = false
      err = migrate_err
    end
  end
  if not ok then
    rollback_from_backup(backup_dir, rollback_paths, created)
    cleanup_staging(stage_dir)
    clear_update_marker()
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
  write_manifest_cache(manifest_content, release, current_base_source, {
    base_url = current_base_url,
    source = current_base_source,
    sha = current_base_sha
  })

  print("FULL REINSTALL complete.")
  print("Next steps: reboot or run the role entrypoint.")
  log("INFO", "FULL REINSTALL complete")
  clear_update_marker()
  cleanup_staging(stage_dir)
end

local function bootstrap_self_check()
  local required = {
    { name = "ui_prompt", fn = ui_prompt },
    { name = "ui_menu", fn = ui_menu },
    { name = "ui_pause", fn = ui_pause },
    { name = "prompt", fn = prompt },
    { name = "ensure_dir", fn = ensure_dir },
    { name = "read_file", fn = read_file },
    { name = "write_atomic", fn = write_atomic },
    { name = "compute_hash", fn = compute_hash },
    { name = "file_checksum", fn = file_checksum },
    { name = "fetch_url", fn = fetch_url },
    { name = "fetch_with_retries", fn = fetch_with_retries },
    { name = "download_with_retry", fn = download_with_retry },
    { name = "download_file_with_retry", fn = download_file_with_retry },
    { name = "fetch_repo_file", fn = fetch_repo_file },
    { name = "build_main_base_url", fn = build_main_base_url },
    { name = "build_commit_base_url", fn = build_commit_base_url },
    { name = "read_manifest_cache", fn = read_manifest_cache },
    { name = "write_manifest_cache", fn = write_manifest_cache },
    { name = "ensure_base_dirs", fn = ensure_base_dirs },
    { name = "stage_updates", fn = stage_updates },
    { name = "apply_staged", fn = apply_staged },
    { name = "rollback_from_backup", fn = rollback_from_backup }
  }
  local missing = {}
  for _, entry in ipairs(required) do
    if type(entry.fn) ~= "function" then
      table.insert(missing, entry.name)
    end
  end
  if #missing > 0 then
    error("Installer bootstrap failed: missing helpers: " .. table.concat(missing, ", "))
  end
end

bootstrap_self_check()

local function main()
  if not http then
    error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
  end
  print("=== XReactor Installer ===")
  log("INFO", "Installer started")
  local recovered, result = recover_update_marker()
  if result and result ~= "no marker" then
    log("INFO", "Update recovery: " .. tostring(result))
  end
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
