-- tests/sim/cc/kernel.lua
-- CC:Tweaked Simulator-Kern (Phase 4.1)
-- Virtuelle Zeit ohne echte Sleeps; Tick-Limit gegen Endlosschleifen.

local kernel = {}

-- Virtuelle Zeit in Sekunden (1 Tick = 0.05s wie CC:Tweaked)
kernel.TICK_S    = 0.05
kernel.MAX_TICKS = 100000  -- Safety-Limit (~83 Minuten virtuelle Zeit)

local _now_ticks = 0  -- aktueller Tick-Zähler
local _seed      = 0

function kernel.reset(seed)
  _now_ticks = 0
  _seed      = seed or 0
  math.randomseed(_seed)
end

function kernel.tick() _now_ticks = _now_ticks + 1 end
function kernel.now_s()     return _now_ticks * kernel.TICK_S end
function kernel.now_ticks() return _now_ticks end
function kernel.now_ms()    return _now_ticks * kernel.TICK_S * 1000 end

-- os.epoch("utc") Äquivalent: virtuelle ms seit Epoch-Start
function kernel.epoch_ms()  return _now_ticks * 50 end  -- 50ms pro Tick

function kernel.advance(ticks)
  ticks = math.max(1, math.floor(ticks or 1))
  _now_ticks = _now_ticks + ticks
end

function kernel.advance_s(seconds)
  local ticks = math.max(1, math.ceil(seconds / kernel.TICK_S))
  kernel.advance(ticks)
end

function kernel.check_limit()
  if _now_ticks > kernel.MAX_TICKS then
    error(string.format(
      "SIM: Tick-Limit %d überschritten (%.1f virtuelle Sekunden) — mögliche Endlosschleife",
      kernel.MAX_TICKS, kernel.now_s()), 2)
  end
end

function kernel.seed() return _seed end

return kernel
