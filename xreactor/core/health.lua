local constants = require("shared.constants")

local health = {}

health.status = {
  OK = "OK",
  DEGRADED = "DEGRADED",
  DOWN = "DOWN"
}

health.reasons = {
  NO_MONITOR = "NO_MONITOR",
  NO_STORAGE = "NO_STORAGE",
  NO_MATRIX = "NO_MATRIX",
  NO_TURBINE = "NO_TURBINE",
  NO_REACTOR = "NO_REACTOR",
  PROTO_MISMATCH = "PROTO_MISMATCH",
  DISCOVERY_FAILED = "DISCOVERY_FAILED",
  COMMS_DOWN = "COMMS_DOWN",
  CONTROL_DEGRADED = "CONTROL_DEGRADED"
}

local function now()
  return os.epoch("utc")
end

function health.new(opts)
  opts = opts or {}
  return {
    status = opts.status or health.status.OK,
    reasons = opts.reasons or {},
    last_seen_ts = opts.last_seen_ts or now(),
    capabilities = opts.capabilities or {},
    bindings = opts.bindings or {}
  }
end

function health.update(entry, status, reasons)
  entry.status = status or entry.status
  entry.reasons = reasons or entry.reasons or {}
  entry.last_seen_ts = now()
  return entry
end

function health.add_reason(entry, reason)
  entry.reasons = entry.reasons or {}
  if not entry.reasons[reason] then
    entry.reasons[reason] = true
  end
end

function health.clear_reason(entry, reason)
  if entry.reasons then
    entry.reasons[reason] = nil
  end
end

function health.reasons_list(entry)
  local out = {}
  for reason in pairs(entry.reasons or {}) do
    table.insert(out, reason)
  end
  table.sort(out)
  return out
end

function health.is_degraded(entry)
  return entry.status == health.status.DEGRADED or entry.status == constants.status_levels.WARNING
end

return health
