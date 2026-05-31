package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

_G.os = _G.os or {}

os.date = function(fmt)
  if fmt ~= "!%H:%M:%S UTC" then
    error("expected UTC wall-clock format")
  end
  return "12:34:56 UTC"
end

package.loaded["core.time"] = nil
local time = require("core.time")
if time.wall_clock_hms_utc() ~= "12:34:56 UTC" then
  error("wall-clock helper should use real UTC time")
end

os.date = nil
_G.textutils = {
  formatTime = function() return "06:00" end
}
os.time = function() return 6 end
package.loaded["core.time"] = nil
time = require("core.time")
if time.wall_clock_hms_utc() ~= "unknown UTC" then
  error("wall-clock helper must not mislabel in-game time as UTC fallback")
end

print("time_test.lua: ok")
