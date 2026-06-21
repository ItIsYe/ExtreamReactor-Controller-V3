local ROLE_CONFIG_PATH = "/xreactor/config/role.lua"

local ROLE_PATHS = {
  MASTER = "/xreactor/master/main.lua",
  RT = "/xreactor/nodes/rt/main.lua",
  ENERGY = "/xreactor/nodes/energy/main.lua",
  WATER = "/xreactor/nodes/water/main.lua",
  FUEL = "/xreactor/nodes/fuel/main.lua",
  REPROCESSING = "/xreactor/nodes/reprocessor/main.lua",
  LOG = "/xreactor/nodes/log_collector/main.lua",
  LOG_COLLECTOR = "/xreactor/nodes/log_collector/main.lua"
}

local STARTUP_MIN_FREE_BYTES = 4096
local STARTUP_CRITICAL_FREE_BYTES = 1024

local function safe_print(message)
  pcall(print, tostring(message))
end

local function local_free_space()
  if not fs or type(fs.getFreeSpace) ~= "function" then return nil end
  local ok, value = pcall(fs.getFreeSpace, "/")
  if not ok then return nil end
  if type(value) == "string" then
    local lowered = string.lower(value)
    if lowered == "unlimited" or lowered == "inf" then return math.huge end
    value = tonumber(value)
  end
  if type(value) ~= "number" then return nil end
  return value
end

local function exists(path)
  local ok, result = pcall(fs.exists, path)
  return ok and result == true
end

local function is_dir(path)
  local ok, result = pcall(fs.isDir, path)
  return ok and result == true
end

local function delete_path(path)
  if not exists(path) then return false end
  local ok = pcall(fs.delete, path)
  return ok and not exists(path)
end

local function cleanup_dir_entries(dir, should_delete)
  local removed = 0
  if not exists(dir) or not is_dir(dir) then return removed end
  local ok, entries = pcall(fs.list, dir)
  if not ok or type(entries) ~= "table" then return removed end
  for _, name in ipairs(entries) do
    if type(name) == "string" and should_delete(name) then
      if delete_path(fs.combine(dir, name)) then removed = removed + 1 end
    end
  end
  return removed
end

local function cleanup_local_startup_storage()
  local before = local_free_space()
  if before and before >= STARTUP_MIN_FREE_BYTES then
    return { ran = false, before = before, after = before, removed = 0, reason = "enough-space" }
  end

  local removed = 0
  removed = removed + cleanup_dir_entries("/xreactor_logs", function(name)
    return name:match("%.log$") ~= nil
      or name:match("%.log%.%d+$") ~= nil
      or name:match("%.tmp$") ~= nil
      or name:match("%.temp$") ~= nil
      or name:match("%.old$") ~= nil
      or name:match("%.bak$") ~= nil
      or name:match("%.preboot$") ~= nil
      or name == ".xreactor_log_probe"
  end)

  local cleanup_paths = {
    "/xreactor_stage",
    "/xreactor_stage.tmp",
    "/xreactor_backup_prev",
    "/xreactor_backup_prev.tmp",
    "/xreactor_update.tmp",
    "/xreactor_update.rollback",
    "/xreactor_update.manifest.tmp"
  }
  for _, path in ipairs(cleanup_paths) do
    if delete_path(path) then removed = removed + 1 end
  end

  local after = local_free_space()
  if after and after < STARTUP_CRITICAL_FREE_BYTES then
    if delete_path("/xreactor_logs") then removed = removed + 1 end
    after = local_free_space()
  end

  return { ran = true, before = before, after = after, removed = removed, reason = "low-space" }
end

local startup_cleanup = cleanup_local_startup_storage()
if startup_cleanup and startup_cleanup.ran then
  safe_print(string.format(
    "STARTUP: storage cleanup removed=%s free_before=%s free_after=%s reason=%s",
    tostring(startup_cleanup.removed),
    tostring(startup_cleanup.before),
    tostring(startup_cleanup.after),
    tostring(startup_cleanup.reason)
  ))
end

local function load_logger()
  local ok, loaded = pcall(dofile, "/xreactor/core/logger.lua")
  if ok and type(loaded) == "table" and type(loaded.log) == "function" then
    return loaded
  end
  return {
    log = function(_, message)
      local text = tostring(message or "")
      local safe = pcall(print, "WARN: startup logger unavailable: " .. text)
      if not safe then
        -- logging must never block runtime startup
      end
    end
  }
end

local logger = load_logger()

local function safe_log(prefix, message)
  local ok = pcall(function()
    if type(logger) == "table" and type(logger.log) == "function" then
      logger.log(prefix, message)
    end
  end)
  if not ok then
    pcall(print, "WARN: startup log dropped for prefix=" .. tostring(prefix))
  end
end

local function read_role_config()
  if not fs.exists(ROLE_CONFIG_PATH) then
    return nil, "Role config missing"
  end
  local file = fs.open(ROLE_CONFIG_PATH, "r")
  if not file then
    return nil, "Unable to read role config"
  end
  local content = file.readAll()
  file.close()
  local loader, err = load(content, "=role", "t", {})
  if not loader then
    return nil, err
  end
  local ok, result = pcall(loader)
  if not ok then
    return nil, result
  end
  if type(result) == "table" and type(result.role) == "string" then
    return result.role
  end
  return nil, "Role config invalid"
end

local function read_release_info()
  if not fs.exists("/xreactor/release.lua") then
    return nil
  end
  local ok, result = pcall(dofile, "/xreactor/release.lua")
  if ok and type(result) == "table" then
    return result
  end
  return nil
end

local role, err = read_role_config()
if not role then
  safe_log("STARTUP", "ERROR: " .. tostring(err))
  error(err, 0)
end

local entry = ROLE_PATHS[role]
if not entry then
  safe_log("STARTUP", "ERROR: Unknown role: " .. tostring(role))
  error("Unknown role: " .. tostring(role), 0)
end

local release = read_release_info() or {}
safe_log(
  "STARTUP",
  string.format(
    "Starting XReactor role=%s release=%s manifest=%s files=%s cleanup=%s removed=%s free_before=%s free_after=%s",
    tostring(role),
    tostring(release.release_id or release.commit_sha or "unknown"),
    tostring(release.manifest_id or release.manifest_version or "unknown"),
    tostring(release.manifest_file_count or "unknown"),
    tostring(startup_cleanup and startup_cleanup.ran or false),
    tostring(startup_cleanup and startup_cleanup.removed or 0),
    tostring(startup_cleanup and startup_cleanup.before or "n/a"),
    tostring(startup_cleanup and startup_cleanup.after or "n/a")
  )
)

-- Give LOG_COLLECTOR node time to start first so log messages
-- from this node's startup aren't missed.
-- LOG_COLLECTOR and MASTER skip the delay.
local LOG_COLLECTOR_STARTUP_DELAY_S = 5
if role ~= "LOG" and role ~= "LOG_COLLECTOR" and role ~= "MASTER" then
  safe_print(string.format(
    "Waiting %ds for LOG_COLLECTOR to start... (role=%s)",
    LOG_COLLECTOR_STARTUP_DELAY_S, role))
  for i = LOG_COLLECTOR_STARTUP_DELAY_S, 1, -1 do
    safe_print(string.format("  Starting in %d...", i))
    os.sleep(1)
  end
end

local ok = shell.run(entry)
if not ok then
  safe_log("STARTUP", "ERROR: Failed to start role: " .. tostring(role))
  error("Failed to start role: " .. tostring(role), 0)
end
