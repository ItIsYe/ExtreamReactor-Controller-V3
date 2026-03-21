local time = {}

local function has_utc_wall_clock()
  return os and type(os.date) == "function"
end

-- Wall-clock helper for UI/log surfaces that should show real time rather than CC's in-game time.
-- Never fall back to CC:Tweaked in-game time here, because that would mislabel a gameplay clock as UTC.
function time.wall_clock_hms_utc()
  if has_utc_wall_clock() then
    return os.date("!%H:%M:%S UTC")
  end
  return "unknown UTC"
end

return time
