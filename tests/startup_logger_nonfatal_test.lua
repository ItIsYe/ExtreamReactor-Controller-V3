local function read(path)
  local handle = io.open(path, "r")
  if not handle then
    error("unable to read " .. tostring(path))
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local source = read("xreactor/start.lua")

local function run_start(env_overrides)
  local env = {
    fs = {
      exists = function(path)
        if path == "/xreactor/config/role.lua" then
          return true
        end
        if path == "/xreactor/release.lua" then
          return true
        end
        return false
      end,
      open = function(path, mode)
        if mode ~= "r" then
          return nil
        end
        if path == "/xreactor/config/role.lua" then
          return {
            readAll = function() return 'return { role = "RT" }' end,
            close = function() end
          }
        end
        return nil
      end
    },
    shell = {
      run = function()
        return true
      end
    },
    dofile = function(path)
      if path == "/xreactor/core/logger.lua" then
        return {
          log = function()
            error("logger write failed")
          end
        }
      end
      if path == "/xreactor/release.lua" then
        return {
          release_id = "test-release",
          manifest_id = "manifest-v6",
          manifest_file_count = 70
        }
      end
      error("unexpected dofile path " .. tostring(path))
    end,
    load = load,
    pcall = pcall,
    tostring = tostring,
    type = type,
    error = error,
    string = string,
    print = function() end
  }
  if type(env_overrides) == "table" then
    for key, value in pairs(env_overrides) do
      env[key] = value
    end
  end
  local chunk, load_err = load(source, "=xreactor/start.lua", "t", env)
  if not chunk then
    error(load_err)
  end
  return pcall(chunk)
end

local ok = run_start()
if not ok then
  error("startup must remain non-fatal when logger backend fails")
end

local fail_ok, fail_err = run_start({
  shell = {
    run = function()
      return false
    end
  }
})
if fail_ok then
  error("startup must still fail if role entrypoint fails")
end
if not tostring(fail_err):find("Failed to start role: RT", 1, true) then
  error("role start failure must preserve explicit error")
end

print("startup_logger_nonfatal_test.lua: ok")
