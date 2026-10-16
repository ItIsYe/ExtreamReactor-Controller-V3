local sampler = {}

local function now_ms()
  return os.epoch("utc")
end

function sampler.new(opts)
  opts = opts or {}
  local start_delay = tonumber(opts.start_delay) or 0
  if start_delay < 0 then
    start_delay = 0
  end
  local now = now_ms()
  local self = {
    name = opts.name or "MATRIX_SAMPLE",
    interval = tonumber(opts.interval) or 0.25,
    runtime = opts.runtime,
    start_delay = start_delay,
    started_at = now,
    next_due_at = now + math.floor(start_delay * 1000)
  }
  return setmetatable(self, { __index = sampler })
end

function sampler:tick()
  local ts = now_ms()
  if ts < (self.next_due_at or 0) then
    return
  end
  local interval_ms = math.max(1, math.floor((self.interval or 0.25) * 1000))
  self.next_due_at = ts + interval_ms
  if self.runtime and self.runtime.tick then
    self.runtime:tick(ts)
  end
end

-- Vom service_manager gerufen, wenn tick() wiederholt scheitert (siehe
-- services/service_manager.lua's maybe_discard_derived_state()): die Caches
-- der Runtime verwerfen -- dieselbe invalidate(), die die ENERGY-Discovery
-- bei einer geaenderten Matrix-Topologie ruft. Der naechste Takt liest
-- alles frisch; bis dahin gilt der Schnappschuss als veraltet, und MASTER
-- nimmt veraltete ENERGY-Daten nicht in den Lastabwurf.
function sampler:discard_derived_state()
  if self.runtime and type(self.runtime.invalidate) == "function" then
    self.runtime:invalidate()
  end
end

return sampler
