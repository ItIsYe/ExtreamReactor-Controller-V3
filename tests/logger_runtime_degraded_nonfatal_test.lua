package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local original_fs = _G.fs
local original_settings = _G.settings
local original_os = _G.os
local original_print = _G.print
local original_peripheral = _G.peripheral
local original_disk = _G.disk

local files = {}
local dirs = { ["/"] = true, ["/disk"] = true, ["/disk/xreactor_logs"] = true, ["/xreactor_logs"] = true }

_G.fs = {
  exists = function(path) return files[path] ~= nil or dirs[path] == true end,
  isDir = function(path) return dirs[path] == true end,
  list = function(path)
    if path == "/" then
      return { "disk" }
    end
    return {}
  end,
  makeDir = function(path) dirs[path] = true end,
  getFreeSpace = function(path)
    if path == "/disk/xreactor_logs" then
      return 0
    end
    return 100000
  end,
  getSize = function(path) return #(files[path] or "") end,
  delete = function(path) files[path] = nil end,
  move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
  open = function(path, mode)
    if mode == "a" or mode == "w" then
      if path:sub(1, 5) == "/disk" then
        return nil
      end
      if path:sub(1, 14) == "/xreactor_logs" then
        return nil
      end
    end
    return nil
  end
}

_G.settings = { get = function() return false end }
_G.os = _G.os or {}
os.clock = function() return 1 end
os.date = function() return "00:00:00" end
_G.print = function() end
_G.peripheral = {
  getNames = function() return {} end
}
_G.disk = {
  getMountPath = function() return nil end
}

package.loaded["core.logger"] = nil
local logger = require("core.logger")

local status = logger.init({ enabled = true, log_name = "rt", log_dir = "/disk/xreactor_logs", truncate = true })
if status.enabled ~= true then
  error("logger should remain enabled to keep runtime calls non-fatal")
end

for _ = 1, 40 do
  logger.log("RT", "line", "INFO")
end
logger.flush()

local describe = logger.describe()
if describe.degraded_mode ~= "EMERGENCY_BUFFER_ONLY" and describe.degraded_mode ~= "LOGGING_DISABLED_NONFATAL" then
  error("logger should degrade non-fatally when all write targets are unavailable")
end

_G.fs = original_fs
_G.settings = original_settings
_G.os = original_os
_G.print = original_print
_G.peripheral = original_peripheral
_G.disk = original_disk

print("logger_runtime_degraded_nonfatal_test.lua: ok")
