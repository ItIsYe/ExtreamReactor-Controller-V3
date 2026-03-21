_G.os = _G.os or {}
os.date = function(fmt)
  if fmt ~= "!%H:%M:%S UTC" then
    error("expected UTC wall-clock format")
  end
  return "12:34:56 UTC"
end

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local time = require("core.time")
if time.wall_clock_hms_utc() ~= "12:34:56 UTC" then
  error("wall-clock helper should use real UTC time")
end

print("time_test.lua: ok")
