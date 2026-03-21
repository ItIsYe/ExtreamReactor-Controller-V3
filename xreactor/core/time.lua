local time = {}

-- Wall-clock helper for UI/log surfaces that should show real time rather than CC's in-game time.
function time.wall_clock_hms_utc()
  if os and os.date then
    return os.date("!%H:%M:%S UTC")
  end
  if textutils and textutils.formatTime and os and os.time then
    return textutils.formatTime(os.time(), true) .. " UTC"
  end
  return "unknown-time"
end

return time
