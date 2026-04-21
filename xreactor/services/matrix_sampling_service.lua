local sampler = {}

local function now_ms()
  return os.epoch("utc")
end

function sampler.new(opts)
  opts = opts or {}
  local self = {
    name = opts.name or "MATRIX_SAMPLE",
    interval = tonumber(opts.interval) or 0.25,
    runtime = opts.runtime,
    last_tick = 0
  }
  return setmetatable(self, { __index = sampler })
end

function sampler:tick()
  local ts = now_ms()
  if ts - self.last_tick < self.interval * 1000 then
    return
  end
  self.last_tick = ts
  if self.runtime and self.runtime.tick then
    self.runtime:tick(ts)
  end
end

return sampler
