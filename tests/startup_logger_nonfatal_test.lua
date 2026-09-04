local function read(path)
  local handle = assert(io.open(path, "r")); local content = handle:read("*a"); handle:close(); return content
end
local source = read("xreactor/start.lua")

local function run_start(role_should_fail)
  local role_src = 'return { role = "RT" }'
  local release_src = 'return { release_id = "test-release" }'
  local env = {}
  setmetatable(env, { __index = _G })
  env._G = env
  env.fs = {
    exists = function(path)
      return path == "/xreactor/config/role.lua" or path == "/xreactor/release.lua"
    end,
    open = function(path, mode)
      if mode ~= "r" then return nil end
      local src = path == "/xreactor/config/role.lua" and role_src
        or (path == "/xreactor/release.lua" and release_src or nil)
      if not src then return nil end
      return { readAll = function() return src end, close = function() end }
    end,
    delete = function() end,
  }
  env.os = setmetatable({
    sleep = function() end,
    reboot = function() end,
  }, { __index = os })
  env.print = function() error("boot output backend unavailable") end
  env.dofile = function(path)
    if path == "/xreactor/core/update_handshake.lua" then
      return { new = function() return {} end }
    end
    if path == "/xreactor/nodes/rt/main.lua" then
      if role_should_fail then error("role boom") end
      return true
    end
    error("unexpected dofile path " .. tostring(path))
  end
  local chunk = assert(load(source, "=xreactor/start.lua", "t", env))
  return pcall(chunk)
end

local ok, err = run_start(false)
if not ok then error("bootstrap output failure must remain non-fatal: " .. tostring(err)) end
local fail_ok, fail_err = run_start(true)
if fail_ok then error("role entrypoint failure must still fail bootstrap") end
if not tostring(fail_err):find("Failed: RT", 1, true) then
  error("role failure must keep explicit bootstrap failure identity: " .. tostring(fail_err))
end
print("startup_logger_nonfatal_test.lua: ok")
