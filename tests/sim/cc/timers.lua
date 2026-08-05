-- tests/sim/cc/timers.lua
-- CC:Tweaked Timer-Simulation (Phase 4.3)
-- Eindeutige IDs, Cancel, 0.05s-Aufrundung, deterministische Reihenfolge.

local timers = {}
timers.__index = timers

local TICK_S = 0.05

function timers.new(kernel)
  return setmetatable({
    _kernel  = kernel,
    _next_id = 1,
    _timers  = {}    -- { id → fire_at_tick }
  }, timers)
end

-- os.startTimer(seconds) → id
function timers:start(seconds)
  -- 0.05s-Aufrundung wie CC:Tweaked
  local ticks = math.max(1, math.ceil(seconds / TICK_S))
  local id = self._next_id
  self._next_id = self._next_id + 1
  self._timers[id] = self._kernel.now_ticks() + ticks
  return id
end

-- Timer abbrechen (kein Event)
function timers:cancel(id)
  self._timers[id] = nil
end

-- Feuernde Timer für den aktuellen Tick ermitteln (sortiert nach ID)
function timers:fired(event_queue)
  local now = self._kernel.now_ticks()
  local fired = {}
  for id, fire_at in pairs(self._timers) do
    if fire_at <= now then
      fired[#fired + 1] = id
    end
  end
  -- Deterministisch: nach ID aufsteigend
  table.sort(fired)
  for _, id in ipairs(fired) do
    self._timers[id] = nil
    event_queue:push("timer", id)
  end
  return #fired
end

function timers:pending() return next(self._timers) ~= nil end
function timers:count()
  local n = 0
  for _ in pairs(self._timers) do n = n + 1 end
  return n
end

return timers
