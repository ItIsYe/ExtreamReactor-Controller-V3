local ROLE_CONFIG_PATH = "/xreactor/config/role.lua"

local ROLE_PATHS = {
  MASTER = "/xreactor/master/main.lua",
  RT = "/xreactor/nodes/rt/main.lua",
  ENERGY = "/xreactor/nodes/energy/main.lua",
  WATER = "/xreactor/nodes/water/main.lua",
  FUEL = "/xreactor/nodes/fuel/main.lua",
  REPROCESSING = "/xreactor/nodes/reprocessor/main.lua"
}

local logger = dofile("/xreactor/core/logger.lua")

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

local role, err = read_role_config()
if not role then
  logger.log("STARTUP", "ERROR: " .. tostring(err))
  error(err, 0)
end

local entry = ROLE_PATHS[role]
if not entry then
  logger.log("STARTUP", "ERROR: Unknown role: " .. tostring(role))
  error("Unknown role: " .. tostring(role), 0)
end

logger.log("STARTUP", "Starting XReactor role: " .. tostring(role))

local ok = shell.run(entry)
if not ok then
  logger.log("STARTUP", "ERROR: Failed to start role: " .. tostring(role))
  error("Failed to start role: " .. tostring(role), 0)
end
