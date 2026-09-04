local constants = require("shared.constants")
local health_codes = require("shared.health_codes")

local health = {}

health.status = {
  OK = "OK",
  DEGRADED = "DEGRADED",
  DOWN = "DOWN"
}

health.reasons = health_codes

local function now()
  return os.epoch("utc")
end

function health.build_health(opts)
  opts = opts or {}
  return {
    status = opts.status or health.status.OK,
    reasons = opts.reasons or {},
    last_seen_ts = opts.last_seen_ts or now(),
    capabilities = opts.capabilities or {},
    bindings = opts.bindings or {}
  }
end

function health.new(opts)
  return health.build_health(opts)
end

function health.update(entry, status, reasons)
  entry.status = status or entry.status
  entry.reasons = reasons or entry.reasons or {}
  entry.last_seen_ts = now()
  return entry
end

function health.set_reason(entry, reason, active)
  entry.reasons = entry.reasons or {}
  if active == false then
    entry.reasons[reason] = nil
  else
    entry.reasons[reason] = true
  end
end

function health.add_reason(entry, reason)
  health.set_reason(entry, reason, true)
end

function health.clear_reason(entry, reason)
  health.set_reason(entry, reason, false)
end

function health.reasons_list(entry)
  local out = {}
  for reason in pairs(entry.reasons or {}) do
    table.insert(out, reason)
  end
  table.sort(out)
  return out
end

function health.summarize_bindings(bindings)
  if type(bindings) ~= "table" then
    return ""
  end
  local parts = {}
  for key, value in pairs(bindings) do
    if type(value) == "table" then
      table.insert(parts, string.format("%s:%d", key, #value))
    else
      table.insert(parts, string.format("%s:%s", key, tostring(value)))
    end
  end
  table.sort(parts)
  return table.concat(parts, " ")
end

function health.is_degraded(entry)
  return entry.status == health.status.DEGRADED or entry.status == constants.status_levels.WARNING
end

return health
