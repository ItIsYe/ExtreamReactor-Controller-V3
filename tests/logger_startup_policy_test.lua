local package_path = package.path
package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local original_fs = _G.fs
local original_settings = _G.settings
local original_os = _G.os
local original_print = _G.print

local files = {}
local moves = {}
local print_lines = {}

local function write_file(path, content)
  files[path] = content or ""
end

_G.fs = {
  exists = function(path)
    return files[path] ~= nil
  end,
  makeDir = function() end,
  getSize = function(path)
    return #(files[path] or "")
  end,
  delete = function(path)
    files[path] = nil
  end,
  move = function(src, dst)
    moves[#moves + 1] = { src = src, dst = dst }
    files[dst] = files[src]
    files[src] = nil
  end,
  open = function(path, mode)
    if mode == "w" then
      files[path] = ""
      return {
        write = function(self, text) files[path] = files[path] .. tostring(text or "") end,
        close = function() end
      }
    end
    if mode == "a" then
      files[path] = files[path] or ""
      return {
        write = function(self, text) files[path] = files[path] .. tostring(text or "") end,
        close = function() end
      }
    end
    return nil
  end
}

_G.settings = { get = function() return false end }
_G.os = _G.os or {}
os.date = function() return "00:00:00" end
local clock_tick = 0
os.clock = function()
  clock_tick = clock_tick + 1
  return clock_tick
end
_G.print = function(message)
  print_lines[#print_lines + 1] = tostring(message)
end

package.loaded["core.logger"] = nil
local logger = require("core.logger")

write_file("/xreactor_logs/rt.log", "old-content")
local status = logger.init({ log_name = "rt", enabled = true, truncate = true })
if status.startup_action ~= "truncated" then
  error("expected startup_action truncated")
end
if files["/xreactor_logs/rt.log"] ~= "" then
  error("truncate policy should clear startup file")
end
if not print_lines[#print_lines] or not print_lines[#print_lines]:find("startup=truncated", 1, true) then
  error("expected startup log line for truncation")
end

write_file("/xreactor_logs/energy.log", string.rep("a", 200001))
logger.init({ log_name = "energy", enabled = true, truncate = false })
logger.log("ENERGY", "rotation-check", "INFO")
logger.flush()
if not files["/xreactor_logs/energy.log.1"] then
  error("expected size-based rotation backup file")
end
if #moves == 0 then
  error("expected fs.move to be called for rotation")
end

_G.fs = original_fs
_G.settings = original_settings
_G.os = original_os
_G.print = original_print
package.path = package_path

print("logger_startup_policy_test.lua: ok")
