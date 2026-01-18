-- Centralized bootstrap for module loading without package.path.
local bootstrap = {}

local CONFIG = {
  BASE_DIR = "/xreactor",
  LOG_PATH = "/xreactor/logs/bootstrap.log",
  LOG_SETTINGS_KEY = "xreactor.debug_logging"
}

local native_require = rawget(_G, "require")

local function resolve_log_enabled()
  if settings and settings.get and CONFIG.LOG_SETTINGS_KEY then
    return settings.get(CONFIG.LOG_SETTINGS_KEY) == true
  end
  return false
end

local function ensure_dir(path)
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function log_line(level, message)
  if not resolve_log_enabled() then
    return
  end
  if not fs or not fs.open or not textutils then
    return
  end
  local ok = pcall(function()
    ensure_dir(fs.getDir(CONFIG.LOG_PATH))
    local file = fs.open(CONFIG.LOG_PATH, "a")
    if not file then
      return
    end
    local stamp = textutils.formatTime(os.epoch("utc") / 1000, true)
    file.write(string.format("[%s] BOOTSTRAP | %s | %s\n", stamp, tostring(level), tostring(message)))
    file.close()
  end)
  if not ok then
    return
  end
end

local function module_to_path(module_name)
  if type(module_name) ~= "string" then
    return nil
  end
  local rel = module_name:gsub("%.", "/") .. ".lua"
  return CONFIG.BASE_DIR .. "/" .. rel
end

local function read_file(path)
  local file = fs.open(path, "r")
  if not file then
    return nil
  end
  local content = file.readAll()
  file.close()
  return content
end

local function load_module(path, module_name)
  local content = read_file(path)
  if not content then
    return nil, "module not found"
  end
  local env = setmetatable({ require = bootstrap.require }, { __index = _G })
  local loader, err = load(content, "=" .. path, "t", env)
  if not loader then
    return nil, err
  end
  local ok, result = pcall(loader)
  if not ok then
    return nil, result
  end
  if result == nil then
    result = true
  end
  return result
end

local function log_environment()
  local entries = {
    "package=" .. tostring(rawget(_G, "package") ~= nil),
    "require=" .. tostring(rawget(_G, "require") ~= nil),
    "fs=" .. tostring(rawget(_G, "fs") ~= nil),
    "term=" .. tostring(rawget(_G, "term") ~= nil),
    "os=" .. tostring(rawget(_G, "os") ~= nil),
    "textutils=" .. tostring(rawget(_G, "textutils") ~= nil),
    "shell=" .. tostring(rawget(_G, "shell") ~= nil)
  }
  log_line("INFO", "env: " .. table.concat(entries, ", "))
  if rawget(_G, "package") and package.path then
    log_line("INFO", "package.path=" .. tostring(package.path))
  end
  log_line("INFO", "root=" .. CONFIG.BASE_DIR)
end

function bootstrap.require(module_name)
  local loaded = rawget(_G, "__xreactor_loaded")
  if not loaded then
    loaded = {}
    rawset(_G, "__xreactor_loaded", loaded)
  end
  if loaded[module_name] ~= nil then
    return loaded[module_name]
  end
  local loading = rawget(_G, "__xreactor_loading")
  if not loading then
    loading = {}
    rawset(_G, "__xreactor_loading", loading)
  end
  if loading[module_name] then
    error("Circular dependency while loading " .. tostring(module_name))
  end
  loading[module_name] = true
  local result
  local path = module_to_path(module_name)
  if path and fs and fs.exists and fs.exists(path) then
    log_line("INFO", "load " .. module_name .. " -> " .. path)
    local value, err = load_module(path, module_name)
    if value == nil then
      loading[module_name] = nil
      log_line("ERROR", "load failed " .. module_name .. ": " .. tostring(err))
      error("Failed loading " .. module_name .. ": " .. tostring(err))
    end
    result = value
  elseif native_require then
    log_line("INFO", "delegate require " .. module_name)
    result = native_require(module_name)
  else
    loading[module_name] = nil
    log_line("ERROR", "resolve failed " .. module_name)
    error("Unable to resolve module " .. tostring(module_name))
  end
  loaded[module_name] = result
  loading[module_name] = nil
  return result
end

function bootstrap.setup()
  rawset(_G, "require", bootstrap.require)
  if type(_ENV) == "table" then
    _ENV.require = bootstrap.require
  end
  log_environment()
end

return bootstrap
