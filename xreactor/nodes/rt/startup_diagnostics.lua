local safety = require("core.safety")

local M = {}

function M.build_peripheral_summary(summary)
  summary = summary or {}
  local kinds = summary.kinds or {}
  local reactors = kinds.reactor or {}
  local turbines = kinds.turbine or {}
  return string.format(
    "registry total=%d bound=%d missing=%d reactors=%d/%d turbines=%d/%d",
    summary.total or 0,
    summary.bound or 0,
    summary.missing or 0,
    reactors.bound or 0,
    reactors.total or 0,
    turbines.bound or 0,
    turbines.total or 0
  )
end

function M.should_emergency_startup(snapshot, max_temperature, max_rpm)
  local max_temp = snapshot and snapshot.max_temp or nil
  if safety.should_scram({ temperature = max_temp, max_temperature = max_temperature }) then
    return true
  end
  if type(max_rpm) ~= "number" then
    return false
  end
  if snapshot and type(snapshot.avg_rpm) == "number" and snapshot.avg_rpm > max_rpm then
    return true
  end
  for _, entry in pairs(snapshot and snapshot.turbines or {}) do
    if type(entry.rpm) == "number" and entry.rpm > max_rpm then
      return true
    end
  end
  return false
end

return M
