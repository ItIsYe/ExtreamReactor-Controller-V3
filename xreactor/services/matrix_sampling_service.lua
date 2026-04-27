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
    next_due_at = now + math.floor(start_delay * 1000),
    last_tick = 0
  }
  return setmetatable(self, { __index = sampler })
end

function sampler:tick()
  local ts = now_ms()
  if ts < (self.next_due_at or 0) then
    return
  end
  if ts - self.last_tick < self.interval * 1000 then
    return
  end
  self.last_tick = ts
  if self.runtime and self.runtime.tick then
    self.runtime:tick(ts)
  end
end

return sampler
