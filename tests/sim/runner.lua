local R={}; R.__index=R
function R.new(opts)
  opts=opts or {}; local p=opts.sim_path or "tests/sim/cc"
  local self=setmetatable({
    kernel=dofile(p.."/kernel.lua"), eq_cls=dofile(p.."/event_queue.lua"),
    timers_mod=dofile(p.."/timers.lua"), sched_cls=dofile(p.."/scheduler.lua"),
  },R)
  self:reset(opts.seed or 0); return self
end
function R:reset(seed)
  self.kernel.reset(seed); self.queue=self.eq_cls.new()
  self.timers=self.timers_mod.new(self.kernel)
end
function R:make_os()
  local k=self.kernel; local q=self.queue; local t=self.timers
  return {
    epoch=function() return k.epoch_ms() end,
    time=function() return k.now_s() end,
    clock=function() return k.now_s() end,
    sleep=function(s) k.advance_s(s) end,
    startTimer=function(s) return t:start(s) end,
    cancelTimer=function(id) t:cancel(id) end,
    pullEvent=function(f) t:fired(q); return q:pull(f) end,
    pullEventRaw=function(f) t:fired(q); return q:pull_raw(f) end,
    queueEvent=function(...) q:push(...) end,
    reboot=function() error("SIM:reboot",0) end,
    shutdown=function() error("SIM:shutdown",0) end,
    getComputerID=function() return 1 end,
    getComputerLabel=function() return "SIM" end,
  }
end
function R:run(cb,max)
  max=max or self.kernel.MAX_TICKS
  for _=1,max do
    self.timers:fired(self.queue); self.kernel.tick(); self.kernel.check_limit()
    if cb(self.kernel.now_ticks())==false then break end
  end
end
return R
