-- tests/sim/runner.lua
-- Haupt-Runner: verbindet kernel, timers, event_queue, scheduler (Phase 4.1-4.4)
-- Stellt eine cc_env-ähnliche API bereit die in Tests injiziert werden kann.

local runner = {}
runner.__index = runner

function runner.new(opts)
  opts = opts or {}
  local sim_path = opts.sim_path or "tests/sim/cc"
  local kernel      = dofile(sim_path .. "/kernel.lua")
  local event_queue = dofile(sim_path .. "/event_queue.lua")
  local timers_mod  = dofile(sim_path .. "/timers.lua")
  local scheduler   = dofile(sim_path .. "/scheduler.lua")

  local self = setmetatable({
    kernel    = kernel,
    eq_cls    = event_queue,
    sched_cls = scheduler,
  }, runner)

  self:reset(opts.seed or 0)
  return self
end

function runner:reset(seed)
  self.kernel.reset(seed)
  self.queue  = self.eq_cls.new()
  self.timers = self.timers_mod and self.timers_mod.new(self.kernel)
               or (function()
    local timers_mod = dofile(
      (self._sim_path or "tests/sim/cc") .. "/timers.lua")
    self.timers = timers_mod.new(self.kernel)
    return self.timers
  end)()
end

-- os-Ersatz für Code-under-Test
function runner:make_os()
  local k = self.kernel
  local q = self.queue
  local t = self.timers
  return {
    epoch       = function(tz) return k.epoch_ms() end,
    time        = function() return k.now_s() end,
    clock       = function() return k.now_s() end,
    sleep       = function(s) k.advance_s(s) end,
    startTimer  = function(s) return t:start(s) end,
    cancelTimer = function(id) t:cancel(id) end,
    pullEvent   = function(f) t:fired(q); return q:pull(f) end,
    pullEventRaw= function(f) t:fired(q); return q:pull_raw(f) end,
    queueEvent  = function(...) q:push(...) end,
    reboot      = function() error("SIM:reboot", 0) end,
    shutdown    = function() error("SIM:shutdown", 0) end,
    getComputerID   = function() return 1 end,
    getComputerLabel= function() return "SIM" end,
  }
end

-- Tick-Loop: führt cb(tick) aus bis cb false zurückgibt oder max_ticks erreicht
function runner:run(cb, max_ticks)
  max_ticks = max_ticks or self.kernel.MAX_TICKS
  for _ = 1, max_ticks do
    self.timers:fired(self.queue)
    self.kernel.tick()
    self.kernel.check_limit()
    if cb(self.kernel.now_ticks()) == false then break end
  end
end

return runner
