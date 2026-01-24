-- Centralized bootstrap for module loading without package.path.
local bootstrap = {}

local CONFIG = {
  BASE_DIR = "/xreactor",
  LOG_PATH = "/xreactor_logs/bootstrap.log",
  LOG_SETTINGS_KEY = "xreactor.debug_logging"
}

local state = {
  base_dir = CONFIG.BASE_DIR,
  log_path = CONFIG.LOG_PATH,
  log_enabled_override = nil,
  last_recovery = nil
}

local native_require = rawget(_G, "require")
local searcher_installed = false

local function resolve_log_enabled()
  if state.log_enabled_override ~= nil then
    return state.log_enabled_override == true
  end
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
    local log_path = state.log_path or CONFIG.LOG_PATH
    ensure_dir(fs.getDir(log_path))
    local file = fs.open(log_path, "a")
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

local function resolve_global()
  local global = _G
  if type(global) ~= "table" then
    global = _ENV
  end
  if type(global) ~= "table" then
    global = {}
  end
  if _G ~= global then
    _G = global
  end
  if type(_ENV) == "table" then
    _ENV._G = global
  end
  return global
end

local function ensure_package_table()
  resolve_global()
  if rawget(_G, "package") ~= nil then
    return
  end
  rawset(_G, "package", {
    path = "",
    preload = {},
    loaded = {},
    searchers = {}
  })
end

local function module_to_paths(module_name)
  if type(module_name) ~= "string" then
    return nil
  end
  local rel = module_name:gsub("%.", "/")
  return {
    (state.base_dir or CONFIG.BASE_DIR) .. "/" .. rel .. ".lua",
    (state.base_dir or CONFIG.BASE_DIR) .. "/" .. rel .. "/init.lua"
  }
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
  local env = setmetatable({ require = bootstrap.require }, { __index = resolve_global() })
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
  if rawget(_G, "shell") and shell.dir then
    log_line("INFO", "shell.dir=" .. tostring(shell.dir()))
  end
  log_line("INFO", "root=" .. tostring(state.base_dir or CONFIG.BASE_DIR))
end

local function xreactor_searcher(module_name)
  local paths = module_to_paths(module_name)
  if not paths then
    return nil, "\n\tinvalid module name"
  end
  for _, path in ipairs(paths) do
    if fs and fs.exists and fs.exists(path) then
      local content = read_file(path)
      if not content then
        log_line("WARN", "searcher unreadable " .. module_name .. " -> " .. path)
        return nil, "\n\tno file '" .. path .. "'"
      end
      local env = setmetatable({ require = bootstrap.require }, { __index = resolve_global() })
      local loader, err = load(content, "=" .. path, "t", env)
      if not loader then
        return nil, "\n\tload error '" .. path .. "': " .. tostring(err)
      end
      log_line("INFO", "searcher load " .. module_name .. " -> " .. path)
      return loader, path
    end
  end
  log_line("WARN", "searcher miss " .. module_name)
  return nil, "\n\tno file '" .. table.concat(paths, "'\n\tno file '") .. "'"
end

local function compute_package_paths(module_name)
  local paths = {}
  if not (rawget(_G, "package") and package.path) then
    return paths
  end
  local name = module_name:gsub("%.", "/")
  for pattern in package.path:gmatch("[^;]+") do
    table.insert(paths, pattern:gsub("%?", name))
  end
  return paths
end

local function ensure_package_path()
  if not (rawget(_G, "package") and package.path) then
    return
  end
  local base = state.base_dir or CONFIG.BASE_DIR
  local additions = {
    base .. "/?.lua",
    base .. "/?/init.lua",
    base .. "/shared/?.lua",
    base .. "/shared/?/init.lua"
  }
  local current = package.path or ""
  for i = #additions, 1, -1 do
    local pattern = additions[i]
    if not current:find(pattern, 1, true) then
      current = pattern .. ";" .. current
    end
  end
  package.path = current
end

function bootstrap.require(module_name)
  resolve_global()
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
  local paths = module_to_paths(module_name)
  if paths and fs and fs.exists then
    for _, path in ipairs(paths) do
      if fs.exists(path) then
        log_line("INFO", "load " .. module_name .. " -> " .. path)
        local value, err = load_module(path, module_name)
        if value == nil then
          loading[module_name] = nil
          log_line("ERROR", "load failed " .. module_name .. ": " .. tostring(err))
          error("Failed loading " .. module_name .. ": " .. tostring(err))
        end
        result = value
        break
      end
    end
  end
  if result == nil and native_require then
    log_line("INFO", "delegate require " .. module_name)
    local ok, value_or_err = pcall(native_require, module_name)
    if ok then
      result = value_or_err
    else
      local tried = compute_package_paths(module_name)
      log_line("ERROR", "native require failed " .. module_name .. ": " .. tostring(value_or_err))
      if #tried > 0 then
        log_line("ERROR", "native paths: " .. table.concat(tried, ", "))
      end
      loading[module_name] = nil
      error(value_or_err)
    end
  end
  if result == nil then
    loading[module_name] = nil
    local attempted = paths and table.concat(paths, ", ") or "<none>"
    log_line("ERROR", "resolve failed " .. module_name .. " (paths: " .. attempted .. ")")
    error("Unable to resolve module " .. tostring(module_name))
  end
  loaded[module_name] = result
  loading[module_name] = nil
  return result
end

function bootstrap.setup(opts)
  opts = opts or {}
  if opts.base_dir then
    state.base_dir = opts.base_dir
  end
  if opts.log_enabled ~= nil then
    state.log_enabled_override = opts.log_enabled == true
  end
  if opts.log_path then
    state.log_path = opts.log_path
  elseif opts.role then
    state.log_path = string.format("/xreactor_logs/loader_%s.log", tostring(opts.role):lower())
  end
  resolve_global()
  ensure_package_table()
  rawset(_G, "require", bootstrap.require)
  if type(_ENV) == "table" then
    _ENV.require = bootstrap.require
  end
  ensure_package_path()
  if rawget(_G, "package") and type(package.searchers) == "table" and not searcher_installed then
    table.insert(package.searchers, 1, xreactor_searcher)
    searcher_installed = true
  end
  local ok_recovery, recovery_mod = pcall(bootstrap.require, "core.update_recovery")
  if ok_recovery and recovery_mod and recovery_mod.recover_if_needed then
    local marker = recovery_mod.read_marker and recovery_mod.read_marker() or nil
    local ok_run, result = pcall(recovery_mod.recover_if_needed)
    state.last_recovery = {
      had_marker = marker ~= nil,
      marker = marker,
      ok = ok_run == true,
      result = ok_run and result or nil
    }
    if ok_run and result then
      log_line("INFO", "update recovery: " .. tostring(result))
    elseif not ok_run then
      log_line("ERROR", "update recovery failed: " .. tostring(result))
    end
  end
  log_environment()
end

function bootstrap.get_recovery_status()
  return state.last_recovery
end

return bootstrap
