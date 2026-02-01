local INSTALLER_CORE_VERSION = "2.5"

-- CONFIG
local CONFIG = {
  BASE_DIR = "/xreactor", -- Base install directory (updated at runtime).
  REPO_OWNER = "ItIsYe", -- GitHub repository owner.
  REPO_NAME = "ExtreamReactor-Controller-V3", -- GitHub repository name.
  REPO_BASE_URL = "https://raw.githubusercontent.com", -- Raw GitHub base URL.
  DEFAULT_BRANCH = "beta", -- Default branch for base URLs when no commit SHA is pinned.
  RELEASE_REMOTE = "xreactor/installer/release.lua", -- Release metadata path.
  MANIFEST_REMOTE = "xreactor/installer/manifest.lua", -- Manifest path (fallback).
  MANIFEST_LOCAL = "/xreactor/.manifest", -- Cached manifest in install dir (updated at runtime).
  MANIFEST_CACHE = "/xreactor/.cache/manifest.lua", -- Serialized manifest cache (updated at runtime).
  MANIFEST_CACHE_LEGACY = "/xreactor/.manifest_cache", -- Legacy cache path (updated at runtime).
  LOCAL_BACKUP_BASE = "/xreactor_backup", -- Backup base directory (updated at runtime).
  LOCAL_STAGING_BASE = "/xreactor_stage", -- Staging base directory (updated at runtime).
  LOCAL_LOG_DIR = "/xreactor/logs", -- Log directory (updated at runtime).
  BACKUP_BASE = "/xreactor_backup", -- Backup base directory (updated at runtime).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path (updated at runtime).
  ROLE_PATH = "/xreactor/config/role.lua", -- Role storage path (updated at runtime).
  UPDATE_STAGING_BASE = "/xreactor_stage", -- Base staging folder for updates (updated at runtime).
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
  DOWNLOAD_CHUNK_SIZE = 8192, -- Stream chunk size for downloads.
  DOWNLOAD_MIRRORS = { -- Download mirrors (raw content only).
    "https://raw.githubusercontent.com"
  },
  DOWNLOAD_HTML_SUSPECT_BYTES = 256, -- Treat small HTML-like responses as errors.
  MANIFEST_URL_PRIMARY = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/installer/manifest.lua", -- Primary manifest URL.
  MANIFEST_URL_FALLBACK = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/installer/manifest.lua", -- Optional fallback manifest URL.
  MANIFEST_RETRY_ATTEMPTS = 3, -- Retry attempts for manifest acquisition menu.
  MANIFEST_RETRY_BACKOFF = 1, -- Backoff seconds for manifest retry menu.
  MANIFEST_MENU_RETRY_LIMIT = 5, -- Retry rounds from menu before auto-cancel.
  FILE_RETRY_ROUNDS = 3, -- Retry rounds for file download failures.
  FILE_RETRY_BACKOFF = 1, -- Backoff seconds for file download retry rounds.
  BASE_CACHE_PATH = "/xreactor/.cache/source.lua", -- Cache for last good base URL (updated at runtime).
  PROTOCOL_ABORT_ON_MAJOR_CHANGE = true, -- Abort SAFE UPDATE if protocol major version changes.
  DISK_SPACE_OVERHEAD_BYTES = 2048, -- Extra bytes per file reserved for temp writes/metadata.
  DISK_SPACE_MIN_BUFFER = 4096, -- Minimum free bytes to keep after writes.
  CHECKSUM_RETRY_LIMIT = 3, -- Max retries for checksum mismatch per file.
  MAX_BACKUPS = 4, -- Retention: max backup directories under /xreactor_backup.
  MAX_LOG_FILES = 5, -- Retention: max number of log files to keep.
  MAX_LOGS_MB = 6, -- Retention: max combined log size (MB) under log dirs.
  MAX_STAGING_DIRS = 2, -- Retention: number of staging dirs to keep in /xreactor_stage.
  LOG_RETENTION_DIRS = { "/xreactor/logs" }, -- Log dirs eligible for cleanup (updated at runtime).
  DEBUG_LOG_ENABLED = nil, -- Override debug logging for installer (nil uses settings/config).
  LOG_ENABLED = true, -- Always enable installer file logging.
  LOG_PATH = "/xreactor/logs/installer_core.log", -- Installer log file path (updated at runtime).
  LOG_MAX_BYTES = 200000, -- Rotate installer log after this size.
  LOG_BACKUP_SUFFIX = ".1", -- Suffix for rotated log file.
  LOG_PREFIX = "INSTALLER_CORE", -- Installer log prefix.
  LOG_SETTINGS_KEY = "xreactor.debug_logging", -- settings key for debug logs.
  LOG_FLUSH_LINES = 1, -- Buffered log lines before flushing.
  LOG_FLUSH_INTERVAL = 0, -- Seconds between log flushes.
  LOG_SAMPLE_BYTES = 96, -- Bytes to capture as response signature.
  CHECKSUM_DIAG_SAMPLE_BYTES = 80, -- Bytes to show when checksum mismatch occurs.
  UPDATE_MARKER_PATH = "/xreactor/.update_in_progress", -- Update marker path (updated at runtime).
  DISK_LABEL = "XREACTOR_DATA", -- Disk label to set when using a mounted disk.
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

local C = CONFIG

-- NOTE: CC:Tweaked limits each chunk to ~200 local variables. To stay under the
-- limit, many low-level helper functions are defined as globals in this file.


-- Download base tracking (default branch vs pinned commit).
local current_base_url = nil
local current_base_source = CONFIG.DEFAULT_BRANCH
local current_base_sha = nil

-- BOOTSTRAP HELPERS (standalone, no external dependencies).
-- UI helpers (centralized input).
function ui_prompt(label, default, min, max)
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

function ui_menu(title, options, default)
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

function ui_pause(msg)
  print(msg or "Press Enter to continue.")
  read()
end

function ensure_dir(path)
  if path == "" then
    return
  end
  if not fs.exists(path) then
    pcall(fs.makeDir, path)
  end
end

function format_bytes(bytes)
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

function resolve_space_path(path)
  local probe = path
  if not probe or probe == "" then
    probe = "/"
  end
  if not fs.exists(probe) then
    probe = fs.getDir(probe)
    if probe == "" then
      probe = "/"
    end
  end
  return probe
end

function get_free_space(path)
  local probe = resolve_space_path(path)
  local ok, free = pcall(fs.getFreeSpace, probe)
  if not ok then
    return nil
  end
  return free, probe
end

local storage_state = {
  use_disk = false,
  mount_path = nil,
  storage_root = CONFIG.BASE_DIR,
  log_dir = CONFIG.LOCAL_LOG_DIR,
  stage_dir = CONFIG.UPDATE_STAGING_BASE,
  backup_dir = CONFIG.BACKUP_BASE,
  log_primary = CONFIG.LOG_PATH,
  log_fallback = CONFIG.LOG_PATH
}

function detect_storage_mount()
  if not peripheral or not peripheral.find then
    return nil, nil, "Peripheral API unavailable"
  end
  if not disk then
    return nil, nil, "Disk API unavailable"
  end
  local drive = peripheral.find("drive")
  if not drive then
    return nil, nil, "No drive found"
  end
  local drive_name = peripheral.getName and peripheral.getName(drive) or drive
  local present = true
  if disk.isPresent then
    local ok, inserted = pcall(disk.isPresent, drive_name)
    present = ok and inserted or false
  end
  if not present then
    return nil, drive_name, "Disk not inserted"
  end
  local ok, mount_path = pcall(disk.getMountPath, drive_name)
  if ok and mount_path and mount_path ~= "" then
    if fs.exists("/disk") then
      return "/disk", drive_name
    end
    return mount_path, drive_name
  end
  if fs.exists("/disk") then
    return "/disk", drive_name
  end
  return nil, drive_name, "Disk mount missing"
end

function build_storage_paths(root, mount_path)
  local base = root or "/xreactor"
  local log_dir = "/xreactor/logs"
  if mount_path then
    log_dir = mount_path .. "/xreactor_logs"
  end
  return {
    base_dir = base,
    log_dir = log_dir,
    stage_dir = base .. "_stage",
    backup_dir = base .. "_backup",
    manifest_local = base .. "/.manifest",
    manifest_cache = base .. "/.cache/manifest.lua",
    manifest_cache_legacy = base .. "/.manifest_cache",
    base_cache = base .. "/.cache/source.lua",
    node_id = base .. "/config/node_id.txt",
    role = base .. "/config/role.lua",
    update_marker = base .. "/.update_in_progress"
  }
end

function configure_storage_paths()
  local mount_path, drive, mount_err = detect_storage_mount()
  local root = "/xreactor"
  if mount_path then
    root = mount_path .. "/xreactor"
  else
    print("WARNING: No disk mount found. Storage is limited.")
    print('Attach a disk drive directly to this computer and insert a disk so "/disk" appears.')
    if mount_err then
      print("Disk status: " .. tostring(mount_err))
    end
  end
  local paths = build_storage_paths(root, mount_path)
  storage_state.use_disk = mount_path ~= nil
  storage_state.mount_path = mount_path
  storage_state.mount_name = drive
  storage_state.storage_root = root
  storage_state.log_dir = paths.log_dir
  storage_state.stage_dir = paths.stage_dir
  storage_state.backup_dir = paths.backup_dir
  storage_state.log_primary = paths.log_dir .. "/installer_core.log"
  storage_state.log_fallback = "/xreactor/logs/installer_core.log"

  C.BASE_DIR = paths.base_dir
  C.MANIFEST_LOCAL = paths.manifest_local
  C.MANIFEST_CACHE = paths.manifest_cache
  C.MANIFEST_CACHE_LEGACY = paths.manifest_cache_legacy
  C.BASE_CACHE_PATH = paths.base_cache
  C.NODE_ID_PATH = paths.node_id
  C.ROLE_PATH = paths.role
  C.UPDATE_MARKER_PATH = paths.update_marker

  C.LOCAL_LOG_DIR = paths.log_dir
  C.LOCAL_STAGING_BASE = paths.stage_dir
  C.LOCAL_BACKUP_BASE = paths.backup_dir
  C.UPDATE_STAGING_BASE = paths.stage_dir
  C.BACKUP_BASE = paths.backup_dir

  C.LOG_PATH = storage_state.log_primary
  CONFIG.LOG_PATH = C.LOG_PATH
  CONFIG.LOG_RETENTION_DIRS = { paths.log_dir, "/xreactor/logs" }
end

-- Internal standalone logger for the installer (no project dependencies).
local active_logger = {}
local internal_log_enabled = false
local log_buffer = {}
local log_last_flush = 0
local log_fallback_buffer = {}
local log_fallback_reason = nil
local log_fallback_active = false
local log_state = {
  primary = nil,
  fallback = nil,
  active = nil,
  fallback_used = false
}

function resolve_log_enabled()
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

function log_stamp()
  return textutils.formatTime(os.epoch("utc") / 1000, true)
end

function rotate_log_if_needed(path)
  if not CONFIG.LOG_MAX_BYTES or CONFIG.LOG_MAX_BYTES <= 0 then
    return
  end
  if not path or not fs.exists(path) then
    return
  end
  if fs.getSize(path) < CONFIG.LOG_MAX_BYTES then
    return
  end
  local backup = path .. (CONFIG.LOG_BACKUP_SUFFIX or ".1")
  if fs.exists(backup) then
    fs.delete(backup)
  end
  fs.move(path, backup)
end

function set_log_paths(primary, fallback)
  log_state.primary = primary
  log_state.fallback = fallback
  log_state.active = nil
  log_state.fallback_used = false
end

function open_log_file()
  local function try_open(path)
    if not path then
      return nil
    end
    ensure_dir(fs.getDir(path))
    rotate_log_if_needed(path)
    local file = fs.open(path, "a")
    if file then
      log_state.active = path
      return file
    end
    return nil
  end
  local file = try_open(log_state.primary)
  if file then
    return file
  end
  if log_state.fallback and log_state.fallback ~= log_state.primary then
    file = try_open(log_state.fallback)
    if file then
      log_state.fallback_used = true
      return file
    end
  end
  return nil
end

function get_log_path()
  return log_state.active or log_state.primary or log_state.fallback or "RAM (printed below)"
end

function internal_log(prefix, message, level)
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
  if log_fallback_active then
    table.insert(log_fallback_buffer, line)
    return
  end
  table.insert(log_buffer, line)
  local elapsed = os.clock() - (log_last_flush or 0)
  if #log_buffer < CONFIG.LOG_FLUSH_LINES and elapsed < CONFIG.LOG_FLUSH_INTERVAL then
    return
  end
  local ok, err = pcall(function()
    local file = open_log_file()
    if not file then
      error("log open failed", 0)
    end
    for _, entry in ipairs(log_buffer) do
      file.write(entry .. "\n")
    end
    file.close()
  end)
  if ok then
    log_buffer = {}
    log_last_flush = os.clock()
    return
  end
  if not log_fallback_active then
    print("Warning: log file unavailable; continuing without file logging.")
  end
  log_fallback_active = true
  log_fallback_reason = log_fallback_reason or tostring(err)
  for _, entry in ipairs(log_buffer) do
    table.insert(log_fallback_buffer, entry)
  end
  log_buffer = {}
end

function init_internal_logger()
  internal_log_enabled = resolve_log_enabled()
  log_last_flush = os.clock()
  ensure_required_dirs()
  set_log_paths(storage_state.log_primary, storage_state.log_fallback)
  pcall(function()
    local file = open_log_file()
    if file then
      file.write("")
      file.close()
    end
  end)
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

configure_storage_paths()
init_internal_logger()

local function try_label_disk()
  if not storage_state.mount_path or not storage_state.mount_name then
    return
  end
  if not disk or not disk.getLabel or not disk.setLabel then
    return
  end
  local ok, current = pcall(disk.getLabel, storage_state.mount_name)
  local current_label = ok and current or nil
  if current_label and current_label ~= "" then
    return
  end
  local ok_set, err = pcall(disk.setLabel, storage_state.mount_name, CONFIG.DISK_LABEL)
  if ok_set then
    log("INFO", "Disk label set to " .. CONFIG.DISK_LABEL)
  else
    log("WARN", "Failed to set disk label: " .. tostring(err))
  end
end

try_label_disk()

function resolve_install_path(path)
  if not path or path == "" then
    return path
  end
  local normalized = path
  if normalized:sub(1, 1) == "/" then
    normalized = normalized:sub(2)
  end
  if normalized:match("^xreactor/") then
    local suffix = normalized:sub(#"xreactor/" + 1)
    return storage_state.storage_root .. "/" .. suffix
  end
  return "/" .. normalized
end

function flush_log_fallback()
  if not log_fallback_active or #log_fallback_buffer == 0 then
    return
  end
  print("=== INSTALLER CORE DEBUG LOG (RAM) ===")
  if log_fallback_reason then
    print("Log file unavailable: " .. tostring(log_fallback_reason))
  end
  for _, entry in ipairs(log_fallback_buffer) do
    print(entry)
  end
  log_fallback_buffer = {}
end

-- Defensive wrapper for legacy calls.
function prompt(label, default)
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

local ROLE

local role_targets = {
  [roles.MASTER] = { path = "master", config = "master/config.lua" },
  [roles.RT_NODE] = { path = "nodes/rt", config = "nodes/rt/config.lua" },
  [roles.ENERGY_NODE] = { path = "nodes/energy", config = "nodes/energy/config.lua" },
  [roles.FUEL_NODE] = { path = "nodes/fuel", config = "nodes/fuel/config.lua" },
  [roles.WATER_NODE] = { path = "nodes/water", config = "nodes/water/config.lua" },
  [roles.REPROCESSOR_NODE] = { path = "nodes/reprocessor", config = "nodes/reprocessor/config.lua" }
}

local role_keys = {
  [roles.MASTER] = "master",
  [roles.RT_NODE] = "rt",
  [roles.ENERGY_NODE] = "energy",
  [roles.WATER_NODE] = "water",
  [roles.FUEL_NODE] = "fuel",
  [roles.REPROCESSOR_NODE] = "reprocessor"
}

local role_storage_values = {
  [roles.MASTER] = "MASTER",
  [roles.RT_NODE] = "RT",
  [roles.ENERGY_NODE] = "ENERGY",
  [roles.WATER_NODE] = "WATER",
  [roles.FUEL_NODE] = "FUEL",
  [roles.REPROCESSOR_NODE] = "REPROCESSOR"
}

local role_filter_cache = {}
local role_files_cache = nil
local role_files_default = {
  MASTER = {
    "xreactor/master/config.lua",
    "xreactor/master/startup_sequencer.lua",
    "xreactor/master/profiles.lua",
    "xreactor/master/main.lua",
    "xreactor/master/ui/alarms.lua",
    "xreactor/master/ui/resources.lua",
    "xreactor/master/ui/rt_dashboard.lua",
    "xreactor/master/ui/overview.lua",
    "xreactor/master/ui/alerts.lua",
    "xreactor/master/ui/energy.lua",
    "xreactor/master/ui/multiview.lua",
    "xreactor/master/ui/widgets.lua"
  },
  RT = {
    "xreactor/nodes/rt/config.lua",
    "xreactor/nodes/rt/main.lua"
  },
  ENERGY = {
    "xreactor/nodes/energy/config.lua",
    "xreactor/nodes/energy/main.lua"
  },
  WATER = {
    "xreactor/nodes/water/config.lua",
    "xreactor/nodes/water/main.lua"
  },
  FUEL = {
    "xreactor/nodes/fuel/config.lua",
    "xreactor/nodes/fuel/main.lua"
  },
  REPROCESSOR = {
    "xreactor/nodes/reprocessor/config.lua",
    "xreactor/nodes/reprocessor/main.lua"
  }
}

local function load_role_files_map()
  if role_files_cache ~= nil then
    return role_files_cache
  end
  local path = resolve_install_path("xreactor/installer/role_files.lua")
  if not path or not fs.exists(path) then
    role_files_cache = role_files_default
    return role_files_cache
  end
  local file = fs.open(path, "r")
  if not file then
    role_files_cache = role_files_default
    return role_files_cache
  end
  local content = file.readAll()
  file.close()
  local loader = load(content or "", "role_files", "t", {})
  if not loader then
    role_files_cache = role_files_default
    return role_files_cache
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then
    role_files_cache = role_files_default
    return role_files_cache
  end
  role_files_cache = data
  return role_files_cache
end
local base_role_prefixes = {
  "xreactor/core/",
  "xreactor/shared/",
  "xreactor/installer/",
  "xreactor/config/",
  "xreactor/ui/"
}
local base_role_files = {
  "installer",
  "installer.lua"
}
local service_files = {
  service_manager = "xreactor/services/service_manager.lua",
  comms = "xreactor/services/comms_service.lua",
  discovery = "xreactor/services/discovery_service.lua",
  telemetry = "xreactor/services/telemetry_service.lua",
  ui = "xreactor/services/ui_service.lua",
  control = "xreactor/services/control_service.lua",
  alert = "xreactor/services/alert_service.lua"
}
local adapter_files = {
  monitor = "xreactor/adapters/monitor.lua",
  reactor = "xreactor/adapters/reactor.lua",
  turbine = "xreactor/adapters/turbine.lua",
  energy = "xreactor/adapters/energy_storage.lua",
  matrix = "xreactor/adapters/induction_matrix.lua"
}
local role_prefixes = {
  [roles.MASTER] = { "xreactor/master/", "xreactor/services/" },
  [roles.RT_NODE] = { "xreactor/nodes/rt/" },
  [roles.ENERGY_NODE] = { "xreactor/nodes/energy/" },
  [roles.WATER_NODE] = { "xreactor/nodes/water/" },
  [roles.FUEL_NODE] = { "xreactor/nodes/fuel/" },
  [roles.REPROCESSOR_NODE] = { "xreactor/nodes/reprocessor/" }
}
local role_service_files = {
  [roles.MASTER] = {
    service_files.service_manager,
    service_files.comms,
    service_files.alert,
    service_files.telemetry,
    service_files.ui
  },
  [roles.RT_NODE] = {
    service_files.service_manager,
    service_files.comms,
    service_files.discovery,
    service_files.telemetry,
    service_files.control
  },
  [roles.ENERGY_NODE] = {
    service_files.service_manager,
    service_files.comms,
    service_files.discovery,
    service_files.telemetry,
    service_files.ui,
    service_files.control
  },
  [roles.WATER_NODE] = {
    service_files.service_manager,
    service_files.comms,
    service_files.discovery,
    service_files.telemetry,
    service_files.ui
  },
  [roles.FUEL_NODE] = {
    service_files.service_manager,
    service_files.comms,
    service_files.discovery,
    service_files.telemetry,
    service_files.ui
  },
  [roles.REPROCESSOR_NODE] = {
    service_files.service_manager,
    service_files.comms,
    service_files.discovery,
    service_files.telemetry,
    service_files.ui
  }
}
local role_adapter_files = {
  [roles.MASTER] = { adapter_files.monitor },
  [roles.RT_NODE] = { adapter_files.monitor, adapter_files.reactor, adapter_files.turbine },
  [roles.ENERGY_NODE] = { adapter_files.monitor, adapter_files.energy, adapter_files.matrix },
  [roles.WATER_NODE] = { adapter_files.monitor },
  [roles.FUEL_NODE] = { adapter_files.monitor },
  [roles.REPROCESSOR_NODE] = { adapter_files.monitor }
}

local function build_role_filter(role)
  if role_filter_cache[role] then
    return role_filter_cache[role]
  end
  if not role then
    return nil
  end
  local prefixes = {}
  local exact = {}
  local function add_prefixes(list)
    for _, entry in ipairs(list or {}) do
      table.insert(prefixes, entry)
    end
  end
  local function add_exact(list)
    for _, entry in ipairs(list or {}) do
      exact[entry] = true
    end
  end
  add_prefixes(base_role_prefixes)
  add_prefixes(role_prefixes[role])
  add_exact(base_role_files)
  add_exact(role_service_files[role])
  add_exact(role_adapter_files[role])
  local role_map = load_role_files_map()
  local extras = role_map and role_map[role_storage_values[role]] or nil
  add_exact(extras)
  role_filter_cache[role] = { prefixes = prefixes, exact = exact }
  return role_filter_cache[role]
end

local function entry_path_allowed_for_role(path, role)
  local filter = build_role_filter(role)
  if not filter or not path then
    return true
  end
  if filter.exact[path] then
    return true
  end
  for _, prefix in ipairs(filter.prefixes or {}) do
    if path:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- Centralized installer logging helper.
function log(level, message)
  if active_logger and active_logger.log then
    active_logger.log(CONFIG.LOG_PREFIX, message, level)
  end
end

function trim(text)
  if not text then return "" end
  return text:match("^%s*(.-)%s*$")
end

function normalize_node_id(value)
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

function normalize_role_value(value)
  if type(value) ~= "string" then
    return nil
  end
  local upper = value:upper()
  if upper == "MASTER" then
    return roles.MASTER
  end
  if upper == "RT" or upper == "RT-NODE" then
    return roles.RT_NODE
  end
  if upper == "ENERGY" or upper == "ENERGY-NODE" then
    return roles.ENERGY_NODE
  end
  if upper == "FUEL" or upper == "FUEL-NODE" then
    return roles.FUEL_NODE
  end
  if upper == "WATER" or upper == "WATER-NODE" then
    return roles.WATER_NODE
  end
  if upper == "REPROCESSOR" or upper == "REPROCESSOR-NODE" then
    return roles.REPROCESSOR_NODE
  end
  return nil
end

function fallback_node_id()
  return tostring(os.getComputerLabel() or os.getComputerID())
end

local fetch_url_seeded = false

function read_file(path)
  if not fs.exists(path) then return nil end
  local file = fs.open(path, "r")
  if not file then return nil end
  local content = file.readAll()
  file.close()
  return content
end

function read_role_file()
  if not C.ROLE_PATH or not fs.exists(C.ROLE_PATH) then
    return nil
  end
  local content = read_file(C.ROLE_PATH)
  if not content or content == "" then
    return nil
  end
  local loader = load(content, "role", "t", {})
  if loader then
    local ok, result = pcall(loader)
    if ok then
      local normalized = normalize_role_value(result)
      if normalized then
        return normalized
      end
    end
  end
  local trimmed = trim(content)
  return normalize_role_value(trimmed)
end

function write_role_file(role)
  if not role or not C.ROLE_PATH then
    return
  end
  local value = role_storage_values[role] or tostring(role)
  ensure_dir(fs.getDir(C.ROLE_PATH))
  write_atomic(C.ROLE_PATH, 'return "' .. value .. '"\n')
end

function ensure_role_file(role)
  if not role then
    return
  end
  local existing = read_role_file()
  if existing ~= role then
    write_role_file(role)
  end
end

function build_cleanup_suggestions()
  local suggestions = {
    ("delete %s/*"):format(C.BACKUP_BASE),
    ("delete %s/*"):format(C.UPDATE_STAGING_BASE),
    "delete /xreactor/logs/*.log"
  }
  if storage_state.mount_path then
    table.insert(suggestions, "delete " .. storage_state.mount_path .. "/xreactor_logs/*.log")
  else
    table.insert(suggestions, "delete /disk/xreactor_logs/*.log")
  end
  return table.concat(suggestions, " | ")
end

function describe_space_issue(context, free, needed, path)
  local target = path and (" (" .. tostring(path) .. ")") or ""
  local suggestion = build_cleanup_suggestions()
  return string.format(
    "%s: not enough disk space%s. Free=%s Needed=%s. Try: %s",
    tostring(context or "Disk space check"),
    target,
    format_bytes(free),
    format_bytes(needed),
    suggestion
  )
end

function calculate_required_bytes(entries)
  local total = 0
  local count = 0
  for _, entry in ipairs(entries or {}) do
    if entry then
      count = count + 1
      total = total + (entry.size_bytes or 0)
    end
  end
  total = total + (CONFIG.DISK_SPACE_OVERHEAD_BYTES or 0) * count
  total = total + (CONFIG.DISK_SPACE_MIN_BUFFER or 0)
  return total
end

function ensure_free_space(path, needed, context)
  local free, probe = get_free_space(path)
  if free and needed and free >= needed then
    return true
  end
  local message = describe_space_issue(context, free or 0, needed or 0, probe)
  print(message)
  log("WARN", message)
  return false, message
end

function preflight_space(entries, target_dir, context)
  local needed = calculate_required_bytes(entries)
  return ensure_space_with_cleanup(target_dir, needed, context)
end

function print_space_preflight(needed, context)
  local free_local = get_free_space(C.BASE_DIR)
  local free_disk = nil
  if storage_state.use_disk and storage_state.mount_path then
    free_disk = get_free_space(storage_state.mount_path)
  end
  print(string.format("%s preflight:", tostring(context or "Disk space")))
  print("  Free local: " .. format_bytes(free_local or 0))
  if free_disk then
    print("  Free disk: " .. format_bytes(free_disk))
  else
    print("  Free disk: n/a")
  end
  print("  Needed: " .. format_bytes(needed or 0))
  print("  Using disk: " .. (storage_state.use_disk and "yes" or "no"))
end

function print_debug_summary(context)
  local free = get_free_space(storage_state.storage_root or C.BASE_DIR)
  print("=== Installer Debug Summary ===")
  if context then
    print("Context: " .. tostring(context))
  end
  print("Storage root: " .. tostring(storage_state.storage_root or C.BASE_DIR))
  print("Free space: " .. format_bytes(free or 0))
  print("Stage path: " .. tostring(C.UPDATE_STAGING_BASE))
  print("Log path: " .. tostring(get_log_path()))
end

function collect_dir_entries(path)
  if not fs.exists(path) then
    return {}
  end
  local ok, entries = pcall(fs.list, path)
  if not ok or type(entries) ~= "table" then
    return {}
  end
  return entries
end

function prune_backup_dirs()
  if not CONFIG.MAX_BACKUPS or CONFIG.MAX_BACKUPS <= 0 then
    return {}
  end
  local deleted = {}
  local entries = collect_dir_entries(C.BACKUP_BASE)
  local dirs = {}
  for _, entry in ipairs(entries) do
    local path = C.BACKUP_BASE .. "/" .. entry
    if fs.isDir(path) then
      table.insert(dirs, entry)
    end
  end
  table.sort(dirs)
  local keep = CONFIG.MAX_BACKUPS
  if #dirs > keep then
    for idx = 1, #dirs - keep do
      local path = C.BACKUP_BASE .. "/" .. dirs[idx]
      if fs.exists(path) then
        fs.delete(path)
        table.insert(deleted, path)
      end
    end
  end
  return deleted
end

function prune_staging_dirs()
  if not CONFIG.MAX_STAGING_DIRS or CONFIG.MAX_STAGING_DIRS < 0 then
    return {}
  end
  local deleted = {}
  local entries = collect_dir_entries(C.UPDATE_STAGING_BASE)
  local dirs = {}
  for _, entry in ipairs(entries) do
    local path = C.UPDATE_STAGING_BASE .. "/" .. entry
    if fs.isDir(path) then
      table.insert(dirs, entry)
    end
  end
  table.sort(dirs)
  local keep = CONFIG.MAX_STAGING_DIRS
  if #dirs > keep then
    for idx = 1, #dirs - keep do
      local path = C.UPDATE_STAGING_BASE .. "/" .. dirs[idx]
      if fs.exists(path) then
        fs.delete(path)
        table.insert(deleted, path)
      end
    end
  end
  return deleted
end

function dir_total_size(path)
  local total = 0
  if not fs.exists(path) then
    return 0
  end
  for _, entry in ipairs(collect_dir_entries(path)) do
    local full_path = path .. "/" .. entry
    if not fs.isDir(full_path) then
      total = total + (fs.getSize(full_path) or 0)
    end
  end
  return total
end

function dir_size_recursive(path)
  if not fs.exists(path) then
    return 0
  end
  if not fs.isDir(path) then
    return fs.getSize(path) or 0
  end
  local total = 0
  for _, entry in ipairs(collect_dir_entries(path)) do
    total = total + dir_size_recursive(path .. "/" .. entry)
  end
  return total
end

function collect_files_recursive(path, files)
  files = files or {}
  if not fs.exists(path) then
    return files
  end
  if not fs.isDir(path) then
    table.insert(files, path)
    return files
  end
  for _, entry in ipairs(collect_dir_entries(path)) do
    collect_files_recursive(path .. "/" .. entry, files)
  end
  return files
end

function collect_log_files()
  local files = {}
  for _, dir in ipairs(CONFIG.LOG_RETENTION_DIRS or {}) do
    if fs.exists(dir) and fs.isDir(dir) then
      for _, entry in ipairs(collect_dir_entries(dir)) do
        local full_path = dir .. "/" .. entry
        if not fs.isDir(full_path) then
          local ok, modified = pcall(fs.getLastModified, full_path)
          table.insert(files, {
            path = full_path,
            size = fs.getSize(full_path) or 0,
            modified = ok and modified or 0
          })
        end
      end
    end
  end
  return files
end

function prune_logs()
  if not CONFIG.MAX_LOGS_MB or CONFIG.MAX_LOGS_MB <= 0 then
    return {}
  end
  local max_bytes = CONFIG.MAX_LOGS_MB * 1024 * 1024
  local files = collect_log_files()
  local total = 0
  for _, entry in ipairs(files) do
    total = total + (entry.size or 0)
  end
  if total <= max_bytes then
    return {}
  end
  table.sort(files, function(a, b)
    return (a.modified or 0) < (b.modified or 0)
  end)
  local deleted = {}
  for _, entry in ipairs(files) do
    if total <= max_bytes then
      break
    end
    if fs.exists(entry.path) then
      fs.delete(entry.path)
      total = total - (entry.size or 0)
      table.insert(deleted, entry.path)
    end
  end
  return deleted
end

function prune_logs_by_count()
  if not CONFIG.MAX_LOG_FILES or CONFIG.MAX_LOG_FILES <= 0 then
    return {}
  end
  local files = collect_log_files()
  if #files <= CONFIG.MAX_LOG_FILES then
    return {}
  end
  table.sort(files, function(a, b)
    return (a.modified or 0) < (b.modified or 0)
  end)
  local deleted = {}
  local overflow = #files - CONFIG.MAX_LOG_FILES
  for idx = 1, overflow do
    local entry = files[idx]
    if entry and fs.exists(entry.path) then
      fs.delete(entry.path)
      table.insert(deleted, entry.path)
    end
  end
  return deleted
end

function cleanup_storage()
  local deleted = {}
  for _, path in ipairs(prune_backup_dirs()) do
    table.insert(deleted, path)
  end
  for _, path in ipairs(prune_logs_by_count()) do
    table.insert(deleted, path)
  end
  for _, path in ipairs(prune_logs()) do
    table.insert(deleted, path)
  end
  for _, path in ipairs(prune_staging_dirs()) do
    table.insert(deleted, path)
  end
  if #deleted > 0 then
    print("Cleanup: removed " .. tostring(#deleted) .. " old backup/log/staging items.")
    log("INFO", "Cleanup removed: " .. table.concat(deleted, ", "))
  else
    log("INFO", "Cleanup: no old backup/log/staging items removed.")
  end
  return deleted
end

function clear_dir_contents(path)
  local deleted = {}
  if not path or path == "" then
    return deleted
  end
  if not fs.exists(path) then
    return deleted
  end
  for _, entry in ipairs(collect_dir_entries(path)) do
    local full_path = path .. "/" .. entry
    if fs.exists(full_path) then
      fs.delete(full_path)
      table.insert(deleted, full_path)
    end
  end
  return deleted
end

function clear_log_files(log_dir)
  local deleted = {}
  if not log_dir or log_dir == "" then
    return deleted
  end
  if not fs.exists(log_dir) or not fs.isDir(log_dir) then
    return deleted
  end
  for _, entry in ipairs(collect_dir_entries(log_dir)) do
    if entry:match("%.log$") then
      local full_path = log_dir .. "/" .. entry
      if fs.exists(full_path) then
        fs.delete(full_path)
        table.insert(deleted, full_path)
      end
    end
  end
  return deleted
end

function cleanup_logs_for_space()
  local deleted = {}
  for _, dir in ipairs(CONFIG.LOG_RETENTION_DIRS or {}) do
    for _, path in ipairs(clear_log_files(dir)) do
      table.insert(deleted, path)
    end
  end
  return deleted
end

function cleanup_staging_for_space()
  local deleted = {}
  for _, path in ipairs(clear_dir_contents(C.LOCAL_STAGING_BASE)) do
    table.insert(deleted, path)
  end
  if C.UPDATE_STAGING_BASE ~= C.LOCAL_STAGING_BASE then
    for _, path in ipairs(clear_dir_contents(C.UPDATE_STAGING_BASE)) do
      table.insert(deleted, path)
    end
  end
  return deleted
end

function cleanup_backups_for_space()
  local deleted = {}
  for _, path in ipairs(clear_dir_contents(C.LOCAL_BACKUP_BASE)) do
    table.insert(deleted, path)
  end
  if C.BACKUP_BASE ~= C.LOCAL_BACKUP_BASE then
    for _, path in ipairs(clear_dir_contents(C.BACKUP_BASE)) do
      table.insert(deleted, path)
    end
  end
  return deleted
end

function cleanup_storage_for_space()
  local deleted = {}
  for _, path in ipairs(cleanup_logs_for_space()) do
    table.insert(deleted, path)
  end
  for _, path in ipairs(cleanup_staging_for_space()) do
    table.insert(deleted, path)
  end
  for _, path in ipairs(cleanup_backups_for_space()) do
    table.insert(deleted, path)
  end
  if #deleted > 0 then
    print("Cleanup: removed " .. tostring(#deleted) .. " log/staging/backup items.")
    log("INFO", "Cleanup for space removed: " .. table.concat(deleted, ", "))
  else
    log("INFO", "Cleanup for space: nothing to remove.")
  end
  return deleted
end

function cleanup_full_reinstall_storage()
  local deleted = {}
  for _, path in ipairs(clear_dir_contents(C.UPDATE_STAGING_BASE)) do
    table.insert(deleted, path)
  end
  for _, path in ipairs(clear_dir_contents(C.BACKUP_BASE)) do
    table.insert(deleted, path)
  end
  for _, path in ipairs(clear_log_files(C.LOCAL_LOG_DIR)) do
    table.insert(deleted, path)
  end
  if #deleted > 0 then
    print("Cleanup: removed " .. tostring(#deleted) .. " staging/backup/log items.")
    log("INFO", "Full reinstall cleanup removed: " .. table.concat(deleted, ", "))
  else
    log("INFO", "Full reinstall cleanup: nothing to remove.")
  end
  return deleted
end

function ensure_space_with_cleanup(path, expected_bytes, context)
  if not expected_bytes or expected_bytes <= 0 then
    return true
  end
  local needed = expected_bytes + (CONFIG.DISK_SPACE_OVERHEAD_BYTES or 0) + (CONFIG.DISK_SPACE_MIN_BUFFER or 0)
  local ok = ensure_free_space(path, needed, context)
  if ok then
    return true
  end
  cleanup_storage_for_space()
  return ensure_free_space(path, needed, context .. " (after cleanup)")
end

function write_atomic(path, content)
  ensure_dir(fs.getDir(path))
  local needed = (content and #content or 0) + (CONFIG.DISK_SPACE_OVERHEAD_BYTES or 0) + (CONFIG.DISK_SPACE_MIN_BUFFER or 0)
  local ok_space = ensure_free_space(path, needed, "Write " .. tostring(path))
  if not ok_space then
    error("Out of space while writing " .. tostring(path), 0)
  end
  local tmp = path .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then
    error("Unable to write file at " .. path, 0)
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
    error("Unable to write file at " .. path .. ": " .. tostring(err), 0)
  end
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
end

function normalize_newlines(content)
  if not content then
    return ""
  end
  local normalized = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  if normalized:sub(1, 3) == "\239\187\191" then
    normalized = normalized:sub(4)
  end
  return normalized
end

function sanitize_snapshot(value, active)
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

function safe_serialize(value)
  local sanitized = sanitize_snapshot(value)
  local ok, result = pcall(textutils.serialize, sanitized)
  if not ok then
    return nil, result
  end
  return result
end

function copy_file(src, dst)
  local content = read_file(src)
  if content == nil then return false end
  write_atomic(dst, content)
  return true
end

function sumlen_hash(content)
  local sum = 0
  for i = 1, #content do
    sum = (sum + string.byte(content, i)) % 1000000007
  end
  return tostring(sum) .. ":" .. tostring(#content)
end

local crc32_table

function build_crc32_table()
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

function crc32_hash(content)
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

function sha1_hash(content)
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

function resolve_hash_algo(manifest, release)
  return manifest.hash_algo or release.hash_algo
end

function validate_hash_algo(manifest, release)
  local algo = resolve_hash_algo(manifest, release)
  local allowed = { ["sumlen-v1"] = true, ["crc32"] = true, ["sha1"] = true }
  if not allowed[algo] then
    error("Unsupported hash algo: " .. tostring(algo))
  end
end

function compute_hash(content, algo)
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

function normalize_manifest_self_hash(content)
  if not content or content == "" then
    return content
  end
  local pattern = '(path%s*=%s*"xreactor/installer/manifest.lua"%s*,%s*size_bytes%s*=%s*%d+%s*,%s*hash%s*=%s*")%x+(")'
  return content:gsub(pattern, "%1" .. string.rep("0", 8) .. "%2")
end

function file_checksum(path, algo)
  local content = read_file(path)
  if not content then return nil end
  if path == resolve_install_path(C.MANIFEST_REMOTE) then
    content = normalize_manifest_self_hash(content)
  end
  return compute_hash(content, algo)
end

function file_checksum_for_target(temp_path, target_path, algo)
  local content = read_file(temp_path)
  if not content then
    return nil
  end
  if target_path == resolve_install_path(C.MANIFEST_REMOTE) then
    content = normalize_manifest_self_hash(content)
  end
  return compute_hash(content, algo)
end

local UPDATE_MARKER_PATH = C.UPDATE_MARKER_PATH

function read_update_marker()
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

function write_update_marker(data)
  write_atomic(UPDATE_MARKER_PATH, textutils.serialize(data or {}))
end

function clear_update_marker()
  if fs.exists(UPDATE_MARKER_PATH) then
    fs.delete(UPDATE_MARKER_PATH)
  end
end

function recover_update_marker()
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
      local target_path = resolve_install_path(entry.path)
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

function compare_version(a, b)
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

function read_config(path, defaults)
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

function read_config_from_content(content)
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

function write_config_file(path, tbl)
  local serialized, err = safe_serialize(tbl)
  if not serialized then
    error("Config serialize failed: " .. tostring(err))
  end
  write_atomic(path, "return " .. serialized)
end

function merge_defaults(target, defaults)
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

function sanitize_signature(prefix)
  if not prefix or prefix == "" then
    return ""
  end
  local sample = prefix:gsub("[%c]", ".")
  return sample:sub(1, CONFIG.LOG_SAMPLE_BYTES or 96)
end

function detect_html(body_prefix)
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

function is_html_payload(content)
  if not content then return false end
  return detect_html(content:sub(1, 200))
end

function sanity_check(content, min_bytes, marker)
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

function is_html_response(body)
  if not body or body == "" then
    return false
  end
  return detect_html(body:sub(1, 512))
end

function is_suspect_html(body)
  if not body then
    return false
  end
  if #body <= (CONFIG.DOWNLOAD_HTML_SUSPECT_BYTES or 0) and is_html_response(body) then
    return true
  end
  return false
end

function validate_response(status_code, headers, body_prefix, body_len)
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

function join_url(base, path)
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

function build_mirror_base_urls(base_url)
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

function build_mirror_urls(base_url, path)
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

function log_download_entry(entry, label)
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

function fetch_response(url, opts)
  if not http or not http.get then
    return false, nil, "HTTP API unavailable (enable in CC:Tweaked config/server)", { url = url }
  end
  local timeout = (opts and opts.timeout) or C.DOWNLOAD_TIMEOUT
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
  local meta = {
    url = url,
    code = code,
    status = code,
    headers = headers
  }
  if code and code ~= 200 then
    response.close()
    return false, nil, "http " .. tostring(code), meta
  end
  return true, response, nil, meta
end

function stream_response_to_file(response, target_path, opts)
  ensure_dir(fs.getDir(target_path))
  local tmp = target_path .. ".part"
  local file = fs.open(tmp, "wb")
  if not file then
    return false, "open failed"
  end
  local chunk_size = (opts and opts.chunk_size) or C.DOWNLOAD_CHUNK_SIZE or 4096
  local prefix_limit = (opts and opts.prefix_bytes) or 512
  local prefix = ""
  local total = 0
  local ok, err = pcall(function()
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
      if #prefix < prefix_limit then
        local needed = prefix_limit - #prefix
        prefix = prefix .. chunk:sub(1, needed)
      end
      file.write(chunk)
      total = total + #chunk
    end
  end)
  file.close()
  if not ok then
    if fs.exists(tmp) then
      fs.delete(tmp)
    end
    return false, err
  end
  return true, {
    bytes = total,
    prefix = prefix,
    temp_path = tmp
  }
end

function finalize_temp_file(temp_path, target_path)
  if fs.exists(target_path) then
    fs.delete(target_path)
  end
  fs.move(temp_path, target_path)
end

function read_response_body(response, chunk_size)
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

-- Single download function used by all network requests.
function fetch_url(url, opts)
  if not http or not http.get then
    return false, nil, "HTTP API unavailable (enable in CC:Tweaked config/server)", { url = url }
  end
  local timeout = (opts and opts.timeout) or C.DOWNLOAD_TIMEOUT
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
  local body, body_len = read_response_body(response, (opts and opts.chunk_size) or C.DOWNLOAD_CHUNK_SIZE or 8192)
  response.close()
  local prefix = body and body:sub(1, 1024) or ""
  local meta = {
    url = url,
    code = code,
    status = code,
    headers = headers,
    bytes = body_len or 0,
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
  local ok, reason, size_mismatch = validate_response(code, headers, prefix, body_len or 0)
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
function fetch_with_retries(urls, max_attempts, backoff_seconds, opts)
  local attempts = max_attempts or C.DOWNLOAD_ATTEMPTS
  local backoff = backoff_seconds or C.DOWNLOAD_BACKOFF
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
      local ok, body, err, meta = fetch_url(url, { timeout = C.DOWNLOAD_TIMEOUT })
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

function download_with_retry(urls, max_attempts, backoff_seconds, opts)
  local attempts = max_attempts or C.DOWNLOAD_ATTEMPTS
  local backoff = backoff_seconds or C.DOWNLOAD_BACKOFF
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
      local ok, body, err, meta = fetch_url(url, { timeout = C.DOWNLOAD_TIMEOUT })
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

function downloadFile(path_or_urls, base_url, opts)
  local urls = path_or_urls
  if type(path_or_urls) == "string" then
    local base = base_url or build_main_base_url()
    urls = build_mirror_urls(base, path_or_urls)
  end
  return download_with_retry(
    urls,
    opts and opts.attempts or C.DOWNLOAD_ATTEMPTS,
    opts and opts.backoff or C.DOWNLOAD_BACKOFF,
    opts
  )
end

function download_file_with_retry(urls, expected_hash, hash_algo, opts)
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
    opts and opts.attempts or C.DOWNLOAD_ATTEMPTS,
    opts and opts.backoff or C.DOWNLOAD_BACKOFF,
    {
      allow_size_mismatch = true,
      validate = validate
    }
  )
end

function is_staging_path(path)
  if not path then
    return false
  end
  if C.UPDATE_STAGING_BASE and path:find(C.UPDATE_STAGING_BASE, 1, true) == 1 then
    return true
  end
  if C.LOCAL_STAGING_BASE and path:find(C.LOCAL_STAGING_BASE, 1, true) == 1 then
    return true
  end
  return false
end

function prepare_download_urls(urls)
  local list = {}
  for _, url in ipairs(urls or {}) do
    if url and url ~= "" then
      table.insert(list, url)
    end
  end
  return list
end

function init_download_entry(url, attempt)
  return { url = url, ok = false, attempt = attempt }
end

function resolve_expected_size(meta, opts)
  local headers = meta and meta.headers or {}
  local content_length = headers["Content-Length"] or headers["content-length"]
  return (opts and opts.expected_size) or (content_length and tonumber(content_length)) or nil
end

function cleanup_download_artifacts(temp_path, target_path)
  if temp_path and fs.exists(temp_path) then
    fs.delete(temp_path)
  end
  if target_path and fs.exists(target_path) and is_staging_path(target_path) then
    fs.delete(target_path)
  end
end

function write_downloaded_file(temp_path, target_path)
  finalize_temp_file(temp_path, target_path)
end

function verify_downloaded_file(entry, stream_info, target_path, expected_hash, hash_algo, expected_size)
  entry.bytes = stream_info.bytes or 0
  entry.signature = sanitize_signature(stream_info.prefix or "")
  if detect_html(stream_info.prefix) then
    entry.err = "html response"
    cleanup_download_artifacts(stream_info.temp_path, target_path)
    return entry
  end
  if expected_size and entry.bytes ~= expected_size then
    entry.err = "size mismatch"
    cleanup_download_artifacts(stream_info.temp_path, target_path)
    return entry
  end
  if expected_hash then
    local actual = file_checksum_for_target(stream_info.temp_path, target_path, hash_algo)
    entry.expected_hash = expected_hash
    entry.actual_hash = actual
    if actual ~= expected_hash then
      entry.err = ("checksum mismatch expected=%s actual=%s"):format(expected_hash, actual)
      cleanup_download_artifacts(stream_info.temp_path, target_path)
      return entry
    end
  end
  write_downloaded_file(stream_info.temp_path, target_path)
  entry.ok = true
  return entry
end

function log_checksum_retry(entry, attempt, limit)
  local message = ("Checksum mismatch (%d/%d) for %s"):format(attempt, limit, tostring(entry.url or "unknown"))
  log("WARN", message)
end

function log_checksum_abort(entry)
  local message = ("Checksum retry limit reached for %s"):format(tostring(entry.url or "unknown"))
  log("ERROR", message)
end

function download_file_to_path(urls, target_path, expected_hash, hash_algo, opts)
  local attempts = opts and opts.attempts or C.DOWNLOAD_ATTEMPTS
  local backoff = opts and opts.backoff or C.DOWNLOAD_BACKOFF
  local checksum_limit = opts and opts.checksum_attempts or C.CHECKSUM_RETRY_LIMIT
  local checksum_failures = 0
  local tried = {}
  local list = prepare_download_urls(urls)
  if #list == 0 then
    return false, { tried = {}, last = { url = nil, ok = false, err = "no urls" } }
  end
  for attempt = 1, attempts do
    for _, url in ipairs(list) do
      local entry = init_download_entry(url, attempt)
      local ok, response, err, meta = fetch_response(url, { timeout = C.DOWNLOAD_TIMEOUT })
      if not ok then
        entry.err = err
        entry.code = meta and meta.code or nil
      else
        local expected_size = resolve_expected_size(meta, opts)
        entry.expected_size = expected_size
        if expected_size and not ensure_space_with_cleanup(target_path, expected_size, "Download " .. target_path) then
          entry.err = "out of space"
          response.close()
        else
          local stream_ok, stream_info = stream_response_to_file(response, target_path, {
            chunk_size = C.DOWNLOAD_CHUNK_SIZE,
            prefix_bytes = 512
          })
          response.close()
          if not stream_ok then
            entry.err = stream_info
          else
            entry = verify_downloaded_file(entry, stream_info, target_path, expected_hash, hash_algo, expected_size)
          end
        end
      end
      entry.code = entry.code or (meta and meta.code or nil)
      table.insert(tried, entry)
      log_download_entry(entry, "download")
      if entry.ok then
        return true, { tried = tried, last = entry }
      end
      if entry.err and tostring(entry.err):find("checksum mismatch", 1, true) then
        checksum_failures = checksum_failures + 1
        log_checksum_retry(entry, checksum_failures, checksum_limit)
        if checksum_failures >= checksum_limit then
          log_checksum_abort(entry)
          return false, { tried = tried, last = entry }
        end
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
  return false, { tried = tried, last = last_entry }
end

function is_valid_sha(sha)
  return type(sha) == "string" and sha:match("^[a-fA-F0-9]+$") and #sha == 40
end

function build_main_base_url()
  return string.format("%s/%s/%s/%s/", C.REPO_BASE_URL, C.REPO_OWNER, C.REPO_NAME, CONFIG.DEFAULT_BRANCH or "main")
end

function build_commit_base_url(sha)
  return string.format("%s/%s/%s/%s/", C.REPO_BASE_URL, C.REPO_OWNER, C.REPO_NAME, sha)
end

function read_base_cache()
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

function write_base_cache(payload)
  local serialized, err = safe_serialize(payload)
  if not serialized then
    log("WARN", "Unable to serialize base cache: " .. tostring(err))
    return
  end
  write_atomic(CONFIG.BASE_CACHE_PATH, serialized)
end

function set_base_source(base_url, source, sha)
  current_base_url = base_url
  current_base_source = source or CONFIG.DEFAULT_BRANCH
  current_base_sha = sha
  write_base_cache({
    last_good_base_url = current_base_url,
    last_good_source = current_base_source,
    last_good_sha = current_base_sha
  })
end

function build_manifest_sources(release)
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

function fetch_repo_file(ref, path, opts)
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

function validate_installer_content(content)
  if not content or #content < C.INSTALLER_MIN_BYTES then
    return false, "content too short"
  end
  if not content:find(C.INSTALLER_SANITY_MARKER, 1, true) then
    return false, "sanity check failed"
  end
  local loader, err = load(content, "installer", "t", {})
  if not loader then
    return false, err or "syntax error"
  end
  return true
end

function read_manifest_cache()
  local path = nil
  if fs.exists(C.MANIFEST_CACHE) then
    path = C.MANIFEST_CACHE
  elseif fs.exists(C.MANIFEST_CACHE_LEGACY) then
    path = C.MANIFEST_CACHE_LEGACY
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

function write_manifest_cache(manifest_content, release, source, base_info)
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
      write_atomic(C.MANIFEST_CACHE, fallback)
    else
      print("Warning: unable to save manifest cache.")
      log("WARN", "Unable to serialize manifest cache: " .. tostring(err))
    end
    return
  end
  write_atomic(C.MANIFEST_CACHE, serialized)
end

function describe_download_error(err)
  if err == "html response" then
    return "Downloaded HTML, expected Lua"
  end
  return err or "timeout or http error"
end

function format_manifest_failure(meta)
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

function collect_tried_urls(info, fallback_urls)
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

function print_download_failure(label, info, fallback_urls)
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
      local sample = signature:sub(1, C.CHECKSUM_DIAG_SAMPLE_BYTES or 80)
      print(("Response signature (first %d): %s"):format(C.CHECKSUM_DIAG_SAMPLE_BYTES or 80, tostring(sample)))
    end
  elseif signature ~= "" then
    print(("Response signature: %s"):format(tostring(signature)))
  end
end

function download_release()
  local temp_path = C.BASE_DIR .. "/.tmp/release.lua.download"
  ensure_dir(fs.getDir(temp_path))
  local urls = build_mirror_urls(build_main_base_url(), C.RELEASE_REMOTE)
  local ok, meta = download_file_to_path(urls, temp_path, nil, "crc32", { attempts = C.DOWNLOAD_ATTEMPTS })
  if not ok then
    return nil, "Release download failed", meta
  end
  local content = read_file(temp_path)
  local ok_sanity, reason = sanity_check(content, C.RELEASE_MIN_BYTES, C.RELEASE_SANITY_MARKER)
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
  data.manifest_path = data.manifest_path or C.MANIFEST_REMOTE
  log("INFO", "Release fetched: " .. data.commit_sha)
  return data, meta
end

function validate_manifest_required(manifest)
  local missing = {}
  for _, path in ipairs(C.REQUIRED_CORE_FILES or {}) do
    if not manifest.lookup or not manifest.lookup[path] then
      table.insert(missing, path)
    end
  end
  if #missing > 0 then
    return nil, "Manifest missing required files: " .. table.concat(missing, ", ")
  end
  for _, migration in ipairs(C.FILE_MIGRATIONS or {}) do
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

function normalize_manifest_group(group, label)
  if group == nil then
    return {}
  end
  if type(group) ~= "table" then
    return nil, ("Manifest group invalid: %s"):format(tostring(label or "?"))
  end
  local entries = {}
  for _, entry in ipairs(group) do
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
    local normalized_roles, roles_err = normalize_manifest_roles(entry.roles)
    if roles_err then
      return nil, roles_err
    end
    table.insert(entries, {
      path = entry.path,
      hash = entry.hash,
      size_bytes = entry.size_bytes,
      roles = normalized_roles
    })
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  return entries
end

function normalize_manifest_roles(roles)
  if roles == nil then
    return nil
  end
  local role_list = roles
  if type(role_list) == "string" then
    role_list = { role_list }
  end
  if type(role_list) ~= "table" then
    return nil, "Manifest entry roles invalid"
  end
  local allowed = {
    MASTER = true,
    RT = true,
    ENERGY = true,
    WATER = true,
    FUEL = true,
    REPROCESSOR = true,
    ALL = true
  }
  local seen = {}
  local normalized = {}
  for _, role in ipairs(role_list) do
    if type(role) ~= "string" then
      return nil, "Manifest entry roles invalid"
    end
    local key = role:upper()
    if key == "ALL" then
      return { "ALL" }
    end
    if not allowed[key] then
      return nil, ("Manifest entry roles invalid: %s"):format(tostring(role))
    end
    if not seen[key] then
      table.insert(normalized, key)
      seen[key] = true
    end
  end
  if #normalized == 0 then
    return nil, "Manifest entry roles empty"
  end
  table.sort(normalized)
  return normalized
end

function parse_manifest(content)
  local loader = load(content, "manifest", "t", {})
  if not loader then
    return nil, "Manifest load failed"
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then
    return nil, "Manifest parse failed"
  end
  if type(data.manifest_version) ~= "number" then
    return nil, "Manifest missing manifest_version"
  end
  if type(data.source_ref) ~= "string" then
    return nil, "Manifest missing source_ref"
  end
  local manifest_groups = {}
  if type(data.files) == "table" then
    manifest_groups.shared = data.files
  else
    manifest_groups.shared = data.shared
    manifest_groups.master = data.master
    manifest_groups.rt = data.rt
    manifest_groups.energy = data.energy
    manifest_groups.water = data.water
    manifest_groups.fuel = data.fuel
    manifest_groups.reprocessor = data.reprocessor
  end
  local normalized_groups = {}
  local entries = {}
  local lookup = {}
  for label, group in pairs(manifest_groups) do
    local normalized, err = normalize_manifest_group(group, label)
    if not normalized then
      return nil, err
    end
    normalized_groups[label] = normalized
    for _, entry in ipairs(normalized) do
      if lookup[entry.path] then
        return nil, "Manifest duplicate path: " .. entry.path
      end
      lookup[entry.path] = entry
      table.insert(entries, entry)
    end
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  data.entries = entries
  data.lookup = lookup
  data.role_groups = normalized_groups
  local ok, err = validate_manifest_required(data)
  if not ok then
    return nil, err
  end
  return data
end

function download_manifest_from_source(release, base_info)
  local manifest_path = release.manifest_path or C.MANIFEST_REMOTE
  local urls = build_mirror_urls(base_info.base_url, manifest_path)
  if base_info.source == CONFIG.DEFAULT_BRANCH and CONFIG.MANIFEST_URL_FALLBACK then
    table.insert(urls, CONFIG.MANIFEST_URL_FALLBACK)
  end
  local temp_path = C.BASE_DIR .. "/.tmp/manifest.lua.download"
  ensure_dir(fs.getDir(temp_path))
  local ok, meta = download_file_to_path(urls, temp_path, nil, "crc32", { attempts = C.DOWNLOAD_ATTEMPTS })
  if not ok then
    return nil, "Manifest download failed", meta
  end
  local content = read_file(temp_path)
  local ok_sanity, reason = sanity_check(content, C.MANIFEST_MIN_BYTES, C.MANIFEST_SANITY_MARKER)
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

function download_manifest_with_retries(attempts, backoff)
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

function acquire_manifest()
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

function ensure_required_dirs()
  ensure_dir(C.BASE_DIR)
  ensure_dir(C.LOCAL_LOG_DIR)
  ensure_dir("/xreactor/logs")
  if fs.exists("/disk") then
    ensure_dir("/disk/xreactor_logs")
  end
  ensure_dir(C.LOCAL_STAGING_BASE)
  ensure_dir(C.LOCAL_BACKUP_BASE)
  ensure_dir(C.UPDATE_STAGING_BASE)
  ensure_dir(C.BACKUP_BASE)
end

function ensure_base_dirs(role)
  ensure_required_dirs()
  ensure_dir(C.BASE_DIR)
  ensure_dir(C.BASE_DIR .. "/config")
  ensure_dir(C.BASE_DIR .. "/core")
  ensure_dir(C.BASE_DIR .. "/services")
  ensure_dir(C.BASE_DIR .. "/shared")
  ensure_dir(C.BASE_DIR .. "/adapters")
  ensure_dir(C.BASE_DIR .. "/installer")
  ensure_dir(C.BASE_DIR .. "/logs")
  ensure_dir(C.BASE_DIR .. "/state")
  ensure_dir(C.BASE_DIR .. "/.cache")
  ensure_dir(C.LOCAL_LOG_DIR)
  if role == roles.MASTER then
    ensure_dir(C.BASE_DIR .. "/master")
    ensure_dir(C.BASE_DIR .. "/master/ui")
  elseif role and role_targets[role] then
    ensure_dir(C.BASE_DIR .. "/nodes")
    ensure_dir(C.BASE_DIR .. "/" .. role_targets[role].path)
  end
end

function is_config_file(path)
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

function parse_proto_version_from_content(content)
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

function load_proto_version(path)
  if not path or not fs.exists(path) then
    return nil
  end
  local content = read_file(path)
  return parse_proto_version_from_content(content)
end

function format_proto_version(ver)
  if not ver then
    return "unknown"
  end
  return tostring(ver.major) .. "." .. tostring(ver.minor)
end

function confirm(prompt_text, default)
  local hint = default and "Y/n" or "y/N"
  local input = ui_prompt(prompt_text .. " (" .. hint .. ")", default and "y" or "n")
  input = input:lower()
  if input == "" then return default end
  return input == "y" or input == "yes"
end

local last_detection = { reactors = {}, turbines = {}, modems = {} }

function is_wireless_modem(name)
  local ok, result = pcall(peripheral.call, name, "isWireless")
  if ok then return result end
  return false
end

function scan_peripherals()
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

function detect_modems()
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

function select_primary_modem(modems)
  if #modems.wireless > 0 then
    return modems.wireless[1]
  end
  if #modems.wired > 0 then
    return modems.wired[1]
  end
  return nil
end

function choose_role()
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

function write_startup(role)
  local target = role_targets[role]
  local base = storage_state.storage_root or C.BASE_DIR
  write_atomic("/startup.lua", [[shell.run("]] .. base .. [[/]] .. target.path .. [[/main.lua")]])
end

function print_detected(label, items)
  print(label .. ":")
  if #items == 0 then
    print(" - (none)")
    return
  end
  for _, name in ipairs(items) do
    print(" - " .. name)
  end
end

function prompt_use_detected()
  scan_peripherals()
  local input = ui_prompt("Use detected peripherals? [Y/n]", "y")
  input = tostring(input or ""):lower()
  if input == "" then return true end
  return input == "y" or input == "yes"
end

function write_config(role, wireless, wired, extras)
  local cfg_path = C.BASE_DIR .. "/" .. role_targets[role].config
  local defaults = read_config(cfg_path, {})
  ROLE = role
  defaults.role = ROLE or role
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
  ensure_role_file(role)
end

function build_rt_node_id()
  local id_str = tostring(os.getComputerID())
  local suffix = id_str:sub(-4)
  return "RT-" .. suffix
end

function find_existing_role()
  local stored_role = read_role_file()
  if stored_role then
    local target = role_targets[stored_role]
    local cfg_path = target and (C.BASE_DIR .. "/" .. target.config) or nil
    local config = cfg_path and fs.exists(cfg_path) and read_config(cfg_path, {}) or nil
    return stored_role, cfg_path, config
  end
  for role, target in pairs(role_targets) do
    local cfg_path = C.BASE_DIR .. "/" .. target.config
    if fs.exists(cfg_path) then
      local config = read_config(cfg_path, {})
      ROLE = normalize_role_value(config.role) or config.role
      if ROLE == role then
        return role, cfg_path, config
      end
    end
  end
  return nil, nil, nil
end

function collect_known_node_id_sources(role, cfg_path)
  local sources = {
    { label = "legacy_file", path = C.BASE_DIR .. "/data/node_id.txt" },
    { label = "legacy_file", path = C.BASE_DIR .. "/node_id.txt" },
    { label = "legacy_file", path = C.BASE_DIR .. "/config/node_id.txt" }
  }
  if cfg_path then
    table.insert(sources, { label = "config", path = cfg_path })
  end
  for _, target in pairs(role_targets) do
    local path = C.BASE_DIR .. "/" .. target.config
    if path ~= cfg_path then
      table.insert(sources, { label = "config", path = path })
    end
  end
  return sources
end

function ensure_node_id(role, cfg_path)
  if fs.exists(C.NODE_ID_PATH) then
    local existing = trim(read_file(C.NODE_ID_PATH))
    local normalized = normalize_node_id(existing)
    if normalized then
      if normalized ~= existing then
        write_atomic(C.NODE_ID_PATH, normalized)
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
          write_atomic(C.NODE_ID_PATH, normalized)
          print("migrated node_id from config")
          log("INFO", "Migrated node_id from config")
          return true
        end
      else
        local content = trim(read_file(source.path))
        local normalized = normalize_node_id(content)
        if normalized then
          write_atomic(C.NODE_ID_PATH, normalized)
          print("migrated node_id from legacy_file")
          log("INFO", "Migrated node_id from legacy file")
          return true
        end
      end
    end
  end

  local generated = fallback_node_id()
  write_atomic(C.NODE_ID_PATH, generated)
  print("generated new node_id")
  log("INFO", "Generated new node_id")
  return true
end

function create_backup_dir()
  ensure_dir(C.BACKUP_BASE)
  local stamp = os.date("%Y%m%d_%H%M%S")
  local path = C.BACKUP_BASE .. "/" .. stamp
  ensure_dir(path)
  return path
end

function backup_files(base_dir, paths)
  for _, path in ipairs(paths) do
    if fs.exists(path) then
      local target = base_dir .. path
      ensure_dir(fs.getDir(target))
      copy_file(path, target)
    end
  end
end

function rollback_from_backup(base_dir, paths, created)
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

function restore_from_backup(base_dir, paths)
  for _, path in ipairs(paths) do
    local backup_path = base_dir .. path
    if fs.exists(backup_path) then
      ensure_dir(fs.getDir(path))
      copy_file(backup_path, path)
    end
  end
end

function update_files(entries, hash_algo)
  local updates = {}
  for _, entry in ipairs(entries or {}) do
    local path = entry.path
    if not is_config_file(path) then
      local full_path = resolve_install_path(path)
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

function build_staging_dir()
  ensure_dir(C.UPDATE_STAGING_BASE)
  if not fetch_url_seeded then
    math.randomseed(os.time())
    fetch_url_seeded = true
  end
  local stamp = os.epoch and os.epoch("utc") or os.time()
  local dir = string.format("%s/%s-%d", C.UPDATE_STAGING_BASE, tostring(stamp), math.random(1000, 9999))
  ensure_dir(dir)
  return dir
end

function cleanup_staging(dir)
  if dir and fs.exists(dir) then
    fs.delete(dir)
  end
end

function build_staging_path(stage_dir, path)
  return stage_dir .. "/" .. path
end

function stage_updates(entries, release, hash_algo)
  local stage_dir = build_staging_dir()
  local staged = {}
  for _, entry in ipairs(entries) do
    local base = current_base_url or build_main_base_url()
    local urls = build_mirror_urls(base, entry.path)
    local expected_size = entry.size_bytes or 0
    local space_ok = ensure_space_with_cleanup(stage_dir, expected_size, "Stage " .. entry.path)
    if not space_ok then
      cleanup_staging(stage_dir)
      return nil, ("Insufficient space to stage %s"):format(entry.path), nil, "space"
    end
    local staging_path = build_staging_path(stage_dir, entry.path)
    local ok, meta = download_file_to_path(urls, staging_path, entry.hash, hash_algo, {
      expected_size = entry.size_bytes
    })
    if not ok then
      cleanup_staging(stage_dir)
      return nil, ("Download failed for %s"):format(entry.path), meta, "download"
    end
    staged[entry.path] = staging_path
  end
  return staged, nil, nil, stage_dir
end

function apply_staged(entries, staged, created)
  for _, entry in ipairs(entries) do
    local target_path = resolve_install_path(entry.path)
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

function apply_direct(entries, release, hash_algo, created)
  for _, entry in ipairs(entries) do
    local target_path = resolve_install_path(entry.path)
    if not fs.exists(target_path) then
      table.insert(created, target_path)
    end
    local base = current_base_url or build_main_base_url()
    local urls = build_mirror_urls(base, entry.path)
    local ok, meta = download_file_to_path(urls, target_path, entry.hash, hash_algo, {
      expected_size = entry.size_bytes
    })
    if not ok then
      return false, ("Download failed for %s"):format(entry.path), meta, "download"
    end
  end
  return true
end

function build_migration_paths()
  local paths = {}
  for _, migration in ipairs(C.FILE_MIGRATIONS or {}) do
    if type(migration) == "table" and migration.from then
      table.insert(paths, resolve_install_path(migration.from))
    end
  end
  return paths
end

function apply_file_migrations()
  local applied = {}
  for _, migration in ipairs(C.FILE_MIGRATIONS or {}) do
    if type(migration) == "table" and migration.from and migration.to then
      local from_path = resolve_install_path(migration.from)
      local to_path = resolve_install_path(migration.to)
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

function update_installer_if_required(manifest, release, hash_algo)
  local required = manifest.installer_min_version
  if required and compare_version(C.INSTALLER_VERSION, required) < 0 then
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
    local temp = resolve_install_path(installer_path) .. ".new"
    local ok, meta = download_file_to_path(urls, temp, expected, hash_algo, {
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
    local content = read_file(temp)
    local valid, valid_err = validate_installer_content(content)
    if not valid then
      print("SAFE UPDATE aborted: installer invalid (" .. tostring(valid_err) .. ").")
      if fs.exists(temp) then
        fs.delete(temp)
      end
      return false
    end
    local target = resolve_install_path(installer_path)
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

function migrate_config(role, cfg_path, manifest, release, hash_algo)
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

function verify_integrity(manifest, role, cfg_path)
  local required = {
    "xreactor/core/bootstrap.lua",
    "xreactor/core/network.lua",
    "xreactor/core/protocol.lua",
    "xreactor/core/utils.lua",
    "xreactor/shared/colors.lua",
    "xreactor/shared/constants.lua",
    "xreactor/installer/installer.lua"
  }
  local role_required = {
    [roles.MASTER] = "xreactor/master/main.lua",
    [roles.RT_NODE] = "xreactor/nodes/rt/main.lua",
    [roles.ENERGY_NODE] = "xreactor/nodes/energy/main.lua",
    [roles.FUEL_NODE] = "xreactor/nodes/fuel/main.lua",
    [roles.WATER_NODE] = "xreactor/nodes/water/main.lua",
    [roles.REPROCESSOR_NODE] = "xreactor/nodes/reprocessor/main.lua"
  }
  if role_required[role] then
    table.insert(required, role_required[role])
  end
  for _, path in ipairs(required) do
    if not fs.exists(resolve_install_path(path)) then
      return false, "Missing " .. path
    end
  end
  if role and cfg_path and not fs.exists(cfg_path) then
    return false, "Missing config"
  end
  if not fs.exists(C.NODE_ID_PATH) then
    return false, "Missing node_id"
  end
  return true
end

function getFilesForRole(role, manifest)
  local entries = {}
  local groups = manifest and manifest.role_groups or {}
  local role_token = role and role_storage_values[role] or nil
  for _, entry in ipairs(groups.shared or {}) do
    if entry_applies_to_role(entry, role_token) and entry_path_allowed_for_role(entry.path, role) then
      table.insert(entries, entry)
    end
  end
  local key = role and role_keys[role] or nil
  if key and groups[key] then
    for _, entry in ipairs(groups[key]) do
      if entry_applies_to_role(entry, role_token) and entry_path_allowed_for_role(entry.path, role) then
        table.insert(entries, entry)
      end
    end
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  return entries
end

function entry_applies_to_role(entry, role_token)
  if not entry or not entry.roles then
    return true
  end
  for _, allowed in ipairs(entry.roles) do
    if allowed == "ALL" then
      return true
    end
    if role_token and allowed == role_token then
      return true
    end
  end
  return false
end

function filter_manifest_by_role(manifest, role)
  if not manifest or not role then
    return manifest
  end
  local filtered = {}
  for key, value in pairs(manifest) do
    if key ~= "entries" and key ~= "lookup" and key ~= "role_groups" then
      filtered[key] = value
    end
  end
  local entries = {}
  local lookup = {}
  for _, entry in ipairs(getFilesForRole(role, manifest)) do
    local clone = {
      path = entry.path,
      hash = entry.hash,
      size_bytes = entry.size_bytes,
      roles = entry.roles
    }
    table.insert(entries, clone)
    lookup[clone.path] = clone
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  filtered.entries = entries
  filtered.lookup = lookup
  filtered.role_groups = { shared = entries }
  return filtered
end

function build_manifest_entries(manifest, role)
  local entries = {}
  for _, entry in ipairs(getFilesForRole(role, manifest)) do
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

function build_allowed_install_paths(manifest, role)
  local allowed = {}
  for _, entry in ipairs(getFilesForRole(role, manifest)) do
    allowed[resolve_install_path(entry.path)] = true
  end
  if manifest.installer_path and manifest.installer_hash and manifest.installer_size_bytes then
    allowed[resolve_install_path(manifest.installer_path)] = true
  end
  return allowed
end

function is_cleanup_protected_path(full_path)
  if not full_path then
    return true
  end
  local root = storage_state.storage_root or C.BASE_DIR
  local prefix = root .. "/"
  if full_path:sub(1, #prefix) ~= prefix then
    return true
  end
  local rel = full_path:sub(#prefix + 1)
  local normalized = "xreactor/" .. rel
  if is_config_file(normalized) then
    return true
  end
  if normalized:match("^xreactor/logs/") then
    return true
  end
  if normalized:match("^xreactor/%.cache/") then
    return true
  end
  if normalized == "xreactor/.manifest" or normalized == "xreactor/.manifest_cache" then
    return true
  end
  if normalized == "xreactor/.update_in_progress" then
    return true
  end
  return false
end

function cleanup_role_files(manifest, role)
  if not manifest then
    return {}
  end
  local allowed = build_allowed_install_paths(manifest, role)
  local root = storage_state.storage_root or C.BASE_DIR
  local deleted = {}
  for _, full_path in ipairs(collect_files_recursive(root)) do
    if not allowed[full_path] and not is_cleanup_protected_path(full_path) then
      if fs.exists(full_path) then
        fs.delete(full_path)
        table.insert(deleted, full_path)
      end
    end
  end
  if #deleted > 0 then
    log("INFO", "Removed obsolete files: " .. table.concat(deleted, ", "))
  else
    log("INFO", "No obsolete files removed.")
  end
  return deleted
end

function cleanup_role_dirs(role)
  local root = storage_state.storage_root or C.BASE_DIR
  local removed = {}
  local function remove_path(path)
    if path and fs.exists(path) then
      fs.delete(path)
      table.insert(removed, path)
    end
  end
  if role == roles.MASTER then
    remove_path(root .. "/nodes")
  else
    remove_path(root .. "/master")
    local nodes_path = root .. "/nodes"
    local allowed = role_targets[role] and role_targets[role].path or nil
    local allowed_dir = allowed and allowed:match("^nodes/(.+)$") or nil
    if fs.exists(nodes_path) and fs.isDir(nodes_path) then
      for _, entry in ipairs(collect_dir_entries(nodes_path)) do
        if entry ~= allowed_dir then
          remove_path(nodes_path .. "/" .. entry)
        end
      end
      if not allowed_dir or #collect_dir_entries(nodes_path) == 0 then
        remove_path(nodes_path)
      end
    end
  end
  if #removed > 0 then
    log("INFO", "Removed obsolete role directories: " .. table.concat(removed, ", "))
  end
  return removed
end

function safe_update_prepare(role, cfg_path)
  local retry_rounds = 0
  while true do
    local manifest_content, manifest, release = acquire_manifest()
    if not manifest_content then
      return nil
    end
    local hash_algo = resolve_hash_algo(manifest, release)
    print(("Debug: manifest source=%s base=%s hash=%s"):format(
      tostring(current_base_source or "unknown"),
      tostring(current_base_url or "unknown"),
      tostring(hash_algo or "unknown")
    ))
    ensure_base_dirs(role)
    cleanup_storage()

    log("INFO", "SAFE UPDATE started for role " .. tostring(role))
    local can_continue = update_installer_if_required(manifest, release, hash_algo)
    if not can_continue then
      return nil
    end
    local node_ok = ensure_node_id(role, cfg_path)
    if not node_ok then
      return nil
    end
    ensure_role_file(role)

    local filtered_manifest = filter_manifest_by_role(manifest, role)
    local role_entries = getFilesForRole(role, filtered_manifest)
    local updates = update_files(role_entries, hash_algo)
    log("INFO", "Files needing update: " .. tostring(#updates))
    local needed_bytes = calculate_required_bytes(updates)
    print_space_preflight(needed_bytes, "SAFE UPDATE")
    local preflight_ok = preflight_space(updates, C.UPDATE_STAGING_BASE, "SAFE UPDATE preflight")
    if not preflight_ok then
      print("SAFE UPDATE aborted: not enough disk space.")
      log("WARN", "SAFE UPDATE aborted: insufficient disk space")
      cleanup_storage_for_space()
      return nil
    end
    local staged, stage_err, stage_meta, stage_dir = stage_updates(updates, release, hash_algo)
    if staged then
      return {
        manifest_content = manifest_content,
        manifest = filtered_manifest,
        release = release,
        hash_algo = hash_algo,
        updates = updates,
        staged = staged,
        stage_dir = stage_dir
      }
    end
    print_download_failure("SAFE UPDATE failed: " .. tostring(stage_err), stage_meta, nil)
    local choice = ui_menu(nil, { "Retry download", "Cancel" }, 1)
    if choice ~= 1 then
      log("ERROR", "SAFE UPDATE staging failed: " .. tostring(stage_err))
      cleanup_staging(stage_dir)
      return nil
    end
    retry_rounds = retry_rounds + 1
    if retry_rounds > CONFIG.FILE_RETRY_ROUNDS then
      print("Retry limit reached. Installer cancelled.")
      log("WARN", "File retry limit reached; cancelling")
      cleanup_staging(stage_dir)
      return nil
    end
    os.sleep(CONFIG.FILE_RETRY_BACKOFF * retry_rounds)
  end
end

function build_update_paths(entries)
  local update_paths = {}
  for _, entry in ipairs(entries or {}) do
    table.insert(update_paths, resolve_install_path(entry.path))
  end
  return update_paths
end

function build_created_before(paths)
  local created_before = {}
  for _, path in ipairs(paths or {}) do
    if not fs.exists(path) then
      table.insert(created_before, path)
    end
  end
  return created_before
end

function build_rollback_paths(update_paths, migration_paths, protected)
  local rollback_paths = {}
  for _, path in ipairs(update_paths or {}) do
    table.insert(rollback_paths, path)
  end
  for _, path in ipairs(migration_paths or {}) do
    table.insert(rollback_paths, path)
  end
  for _, path in ipairs(protected or {}) do
    table.insert(rollback_paths, path)
  end
  return rollback_paths
end

function write_marker_payload(manifest, release, stage_dir, backup_dir, updates, created, rollback_paths, hash_algo)
  write_update_marker({
    ts = os.epoch("utc"),
    version = manifest.version or release and release.commit_sha or "unknown",
    stage_dir = stage_dir,
    backup_dir = backup_dir,
    updates = updates,
    created = created,
    rollback_paths = rollback_paths,
    hash_algo = hash_algo
  })
end

function safe_update_apply(context, role, cfg_path)
  local manifest_content = context.manifest_content
  local manifest = context.manifest
  local release = context.release
  local hash_algo = context.hash_algo
  local updates = context.updates or {}
  local staged = context.staged or {}
  local stage_dir = context.stage_dir
  local backup_dir = create_backup_dir()
  local protected = { cfg_path, C.NODE_ID_PATH, "/startup.lua", C.MANIFEST_LOCAL, C.MANIFEST_CACHE }
  local update_paths = build_update_paths(updates)
  local created = {}
  local migration_paths = build_migration_paths()

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, migration_paths)
  backup_files(backup_dir, protected)

  local created_before = build_created_before(update_paths)
  local rollback_paths = build_rollback_paths(update_paths, migration_paths, protected)
  write_marker_payload(manifest, release, stage_dir, backup_dir, updates, created_before, rollback_paths, hash_algo)

  local local_proto = load_proto_version(resolve_install_path("xreactor/shared/constants.lua"))
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
    local success, result = pcall(write_atomic, C.MANIFEST_LOCAL, manifest_content)
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

  cleanup_role_files(manifest, role)
  cleanup_role_dirs(role)

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

-- SAFE UPDATE keeps role/config/node_id intact and updates only changed files.
function safe_update()
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
  local context = safe_update_prepare(role, cfg_path)
  if not context then
    return
  end
  safe_update_apply(context, role, cfg_path)
end

function full_reinstall_prepare()
  local retry_rounds = 0
  while true do
    cleanup_full_reinstall_storage()
    local manifest_content, manifest, release, manifest_meta = acquire_manifest()
    if not manifest_content then
      return nil
    end
    local hash_algo = resolve_hash_algo(manifest, release)
    print(("Debug: manifest source=%s base=%s hash=%s"):format(
      tostring(current_base_source or "unknown"),
      tostring(current_base_url or "unknown"),
      tostring(hash_algo or "unknown")
    ))
    ensure_required_dirs()
    cleanup_storage()
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

    local selected_role = existing_role
    if not keep_config or not existing_role then
      selected_role = choose_role()
    end
    ROLE = selected_role
    ensure_base_dirs(selected_role)
    local filtered_manifest = filter_manifest_by_role(manifest, selected_role)
    local entries = build_manifest_entries(filtered_manifest, selected_role)
    local required_total = calculate_required_bytes(entries)
    print_space_preflight(required_total, "FULL REINSTALL")
    local free_space = get_free_space(C.BASE_DIR)
    local existing_size = dir_size_recursive(C.BASE_DIR)
    if free_space and (free_space + existing_size) < required_total then
      local message = describe_space_issue("FULL REINSTALL preflight", free_space + existing_size, required_total, C.BASE_DIR)
      print(message)
      log("WARN", message)
      cleanup_storage_for_space()
      return nil
    end
    local use_staging = preflight_space(entries, C.UPDATE_STAGING_BASE, "FULL REINSTALL staging")
    if not use_staging then
      print("Not enough space for staging. Falling back to direct install.")
      log("WARN", "FULL REINSTALL staging disabled due to space")
      return {
        manifest_content = manifest_content,
        manifest = filtered_manifest,
        release = release,
        hash_algo = hash_algo,
        entries = entries,
        use_staging = false,
        keep_config = keep_config,
        existing_role = existing_role,
        existing_cfg_path = existing_cfg_path,
        selected_role = selected_role
      }
    end
    local staged, stage_err, stage_meta, stage_dir = stage_updates(entries, release, hash_algo)
    if staged then
      return {
        manifest_content = manifest_content,
        manifest = filtered_manifest,
        release = release,
        hash_algo = hash_algo,
        entries = entries,
        use_staging = true,
        staged = staged,
        stage_dir = stage_dir,
        keep_config = keep_config,
        existing_role = existing_role,
        existing_cfg_path = existing_cfg_path,
        selected_role = selected_role
      }
    end
    print_download_failure("FULL REINSTALL failed: " .. tostring(stage_err), stage_meta, nil)
    local choice = ui_menu(nil, { "Retry download", "Cancel" }, 1)
    if choice ~= 1 then
      log("ERROR", "FULL REINSTALL staging failed: " .. tostring(stage_err))
      cleanup_staging(stage_dir)
      return nil
    end
    retry_rounds = retry_rounds + 1
    if retry_rounds > CONFIG.FILE_RETRY_ROUNDS then
      print("Retry limit reached. Installer cancelled.")
      log("WARN", "File retry limit reached; cancelling")
      cleanup_staging(stage_dir)
      return nil
    end
    os.sleep(CONFIG.FILE_RETRY_BACKOFF * retry_rounds)
  end
end

function setup_fresh_config(context, backup_dir, protected)
  if context.keep_config and context.existing_role then
    restore_from_backup(backup_dir, protected)
    log("INFO", "Restored existing config for role " .. tostring(context.existing_role))
    return context.existing_role, context.existing_cfg_path
  end
  local role = context.selected_role or choose_role()
  ROLE = role
  local cfg_path = C.BASE_DIR .. "/" .. role_targets[role].config
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
  return role, cfg_path
end

function full_reinstall_apply(context)
  local manifest_content = context.manifest_content
  local manifest = context.manifest
  local release = context.release
  local hash_algo = context.hash_algo
  local staged = context.staged
  local stage_dir = context.stage_dir
  local use_staging = context.use_staging
  local entries = context.entries
  local backup_dir = create_backup_dir()
  local update_paths = build_update_paths(entries)
  local created = {}
  local migration_paths = build_migration_paths()
  local protected = { C.NODE_ID_PATH, C.ROLE_PATH, "/startup.lua", C.MANIFEST_LOCAL, C.MANIFEST_CACHE }
  for _, target in pairs(role_targets) do
    table.insert(protected, C.BASE_DIR .. "/" .. target.config)
  end

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, migration_paths)
  backup_files(backup_dir, protected)

  local created_before = build_created_before(update_paths)
  local rollback_paths = build_rollback_paths(update_paths, migration_paths, protected)
  write_marker_payload(
    manifest,
    release,
    use_staging and stage_dir or nil,
    backup_dir,
    entries,
    created_before,
    rollback_paths,
    hash_algo
  )

  local ok, err = false, nil
  if use_staging then
    ok, err = apply_staged(entries, staged, created)
  else
    ok, err = apply_direct(entries, release, hash_algo, created)
  end
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

  cleanup_role_files(manifest, context.selected_role or context.existing_role)
  cleanup_role_dirs(context.selected_role or context.existing_role)

  local role, cfg_path = setup_fresh_config(context, backup_dir, protected)

  ensure_node_id(role, cfg_path)
  ensure_role_file(role)
  write_startup(role)
  write_atomic(C.MANIFEST_LOCAL, manifest_content)
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

-- FULL REINSTALL overwrites all files and optionally restores existing config.
function full_reinstall()
  local context = full_reinstall_prepare()
  if not context then
    return
  end
  full_reinstall_apply(context)
end

function bootstrap_self_check()
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

function main()
  if not http then
    error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
  end
  print("=== XReactor Installer ===")
  log("INFO", "Installer started")
  local recovered, result = recover_update_marker()
  if result and result ~= "no marker" then
    log("INFO", "Update recovery: " .. tostring(result))
  end
  if fs.exists(C.BASE_DIR) then
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

function log_fatal(trace)
  log("ERROR", trace)
  print("Installer failed: " .. tostring(trace))
  print("See log: " .. tostring(get_log_path()))
  print_debug_summary("Installer fatal error")
  flush_log_fallback()
end

local ok, err = xpcall(main, function(message)
  return debug.traceback(tostring(message), 2)
end)
if not ok then
  log_fatal(err)
end
flush_log_fallback()
