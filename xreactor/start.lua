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

local function read_all(path)
  if not fs.exists(path) then return nil, "missing" end
  local handle = fs.open(path, "r")
  if not handle then return nil, "open failed" end
  local data = handle.readAll()
  handle.close()
  return data
end

local function write_all(path, data)
  local handle = fs.open(path, "w")
  if not handle then return false, "open failed" end
  handle.write(data)
  handle.close()
  return true
end

local function apply_rt_startup_self_heal(entry, release)
  local source, read_err = read_all(entry)
  if type(source) ~= "string" then
    safe_log("STARTUP", "RT self-heal skipped: " .. tostring(read_err))
    return
  end

  local before = source
  source = source:gsub(
    "build_health_payload = function%(%) return build_status_payload%(%) end\n    read_turbine_rpm =",
    "build_health_payload = function() return build_status_payload() end,\n    read_turbine_rpm =",
    1
  )

  local manifest_id = release and release.manifest_id
  local release_id = release and release.release_id
  if type(manifest_id) == "string" and manifest_id ~= "" then
    source = source:gsub('manifest_id%s*=%s*"manifest%-v%d+"', 'manifest_id          = "' .. manifest_id .. '"', 1)
  end
  if type(release_id) == "string" and release_id ~= "" then
    source = source:gsub('release_id%s*=%s*"beta%-v%d+"', 'release_id           = "' .. release_id .. '"', 1)
  end

  if source ~= before then
    local ok, err = write_all(entry, source)
    if ok then
      safe_log("STARTUP", "RT startup self-heal applied before launch")
    else
      safe_log("STARTUP", "ERROR: RT startup self-heal write failed: " .. tostring(err))
    end
  end
end

local function apply_startup_self_heal(role, entry, release)
  if role == "RT" then
    apply_rt_startup_self_heal(entry, release)
  end
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
safe_log("STARTUP", string.format(
  "Starting XReactor | role=%-12s | %s | files=%s",
  tostring(role),
  tostring(release.release_id or "unknown"),
  tostring(release.manifest_file_count or "?")
))

apply_startup_self_heal(role, entry, release)

-- Gestaffelte Startreihenfolge: LOG_COLLECTOR → MASTER → Nodes
--
-- Warum: Nodes senden beim Start sofort ein HELLO. Wenn der Master
-- noch nicht bereit ist (bootet noch), geht dieses HELLO verloren
-- und die Node wartet bis zum nächsten heartbeat_interval (~2-5s)
-- bevor sie sich erneut meldet. Das ist kein Datenverlust (Nodes
-- reconnecten automatisch via AUTONOM-Mode), aber eine unnötige
-- Verzögerung bei der ersten Master-Synchronisation.
--
-- Reihenfolge:
--   LOG/LOG_COLLECTOR:  0s — sofort, damit Logs vom Start an erfasst werden
--   MASTER:             2s — kurz nach LOG_COLLECTOR, damit Logs vom Boot erfasst
--   ALLE ANDEREN:       8s — 5s für LOG_COLLECTOR + 3s Vorsprung für Master
--
-- Hinweis: Ein statischer Delay ist kein Garant (Master könnte länger
-- brauchen), aber er deckt den Normalfall ab. Nodes sind bereits
-- resilient gegen einen nicht-erreichbaren Master (AUTONOM-Mode).

local STARTUP_DELAYS = {
  LOG          = 0,
  LOG_COLLECTOR = 0,
  MASTER       = 2,
}
local STARTUP_DELAY_DEFAULT = 8  -- alle anderen Nodes

local startup_delay = STARTUP_DELAYS[role]
if startup_delay == nil then
  startup_delay = STARTUP_DELAY_DEFAULT
end

if startup_delay > 0 then
  local reason = (role == "MASTER") and "LOG_COLLECTOR" or "LOG_COLLECTOR + MASTER"
  safe_print(string.format("[BOOT] Warte %ds auf %s...", startup_delay, reason))
  for i = startup_delay, 1, -1 do
    -- Countdown intern, keine Ausgabe
    os.sleep(1)
  end
end

-- Auto-Update Loop parallel zum Node-Prozess.
-- Läuft in start.lua damit er unabhängig vom Node-Code ist —
-- auch alte Node-Versionen bekommen Updates ohne zu crashen.
local function run_with_auto_update()
  local auto_loop = nil
  local ok_ru, remote_update = pcall(dofile, "/xreactor/core/remote_update.lua")
  if ok_ru and type(remote_update) == "table"
     and type(remote_update.auto_check_loop) == "function" then
    auto_loop = remote_update.auto_check_loop(
      function(level, msg) safe_log("AUTO_UPDATE", tostring(msg)) end, 120)
  end

  if auto_loop then
    parallel.waitForAny(
      function() shell.run(entry) end,
      auto_loop
    )
  else
    shell.run(entry)
  end
end

local ok, run_err = pcall(run_with_auto_update)
if not ok then
  safe_log("STARTUP", "ERROR: Failed to start role: " .. tostring(role) .. " - " .. tostring(run_err))
  error("Failed to start role: " .. tostring(role), 0)
end
