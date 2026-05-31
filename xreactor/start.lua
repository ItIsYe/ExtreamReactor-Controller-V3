local ROLE_CONFIG_PATH = "/xreactor/config/role.lua"

local ROLE_PATHS = {
  MASTER = "/xreactor/master/main.lua",
  RT = "/xreactor/nodes/rt/main.lua",
  ENERGY = "/xreactor/nodes/energy/main.lua",
  WATER = "/xreactor/nodes/water/main.lua",
  FUEL = "/xreactor/nodes/fuel/main.lua",
  REPROCESSING = "/xreactor/nodes/reprocessor/main.lua"
}

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
    "Starting XReactor role=%s release=%s manifest=%s files=%s",
    tostring(role),
    tostring(release.release_id or release.commit_sha or "unknown"),
    tostring(release.manifest_id or release.manifest_version or "unknown"),
    tostring(release.manifest_file_count or "unknown")
  )
)

local ok = shell.run(entry)
if not ok then
  safe_log("STARTUP", "ERROR: Failed to start role: " .. tostring(role))
  error("Failed to start role: " .. tostring(role), 0)
end
