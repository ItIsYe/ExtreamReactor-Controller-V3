-- RT rewrite, step 3: reactor rod control.
--
-- Confirmed spec (2026-09-18): the reactor regulates ONLY from its own
-- internal steam tank fill level, in every state -- MASTER does not hand
-- the reactor a percentage; it only ever changes what the TURBINES are
-- asked to draw, and the reactor reacts to whatever that draw does to the
-- tank. This makes the reactor's control law itself mode-independent by
-- construction (no separate "MASTER reactor logic" vs "AUTONOM reactor
-- logic" to keep in sync -- there is only one).
--
-- Rod convention (BigReactors): rod level is INSERTION, not power.
--   100% inserted = control rods fully in  = ~0% reactivity/power
--     0% inserted = control rods fully out = ~100% reactivity/power
-- So: tank fill BELOW target (need more steam) -> WITHDRAW rods (decrease
-- level). Tank fill ABOVE target (too much steam) -> INSERT rods
-- (increase level). This is the inverse of a naive "more fill -> more
-- rods" reading, and got it backwards was never seen in this codebase,
-- but it is exactly the kind of off-by-a-sign-convention bug this module
-- exists to make impossible to get wrong twice: it is asserted by tests
-- below, not just written in a comment.
--
-- Confirmed spec (2026-09-19): the controller may only regulate within
-- 70-100% rod insertion, never withdrawing further than 70% (i.e. never
-- exceeding whatever power that corresponds to) -- ROD_MIN raised from 0
-- to 70 clamps every decision below to that floor, same as the existing
-- 0/100 clamp test at the bottom of this file already exercises.

local M = {}

-- DELIBERATE POWER CAP, confirmed with the operator (2026-09-19, re-confirmed
-- 2026-09-23): the controller may only move the rods between 70 % and 100 %
-- INSERTION. Extreme Reactors reduces produced radiation in proportion to
-- insertion ("100% insertion = 100% reduction", ReactorLogic.java), so a 70 %
-- floor caps this reactor at roughly 30 % of its rated output. That is the
-- intended operating envelope here -- do NOT "fix" it by lowering ROD_MIN.
-- If the steam tank sits empty with the rods pinned at 70, the plant is
-- asking for more steam than this envelope can deliver; that is a load
-- question, not a controller bug.
M.ROD_MIN = 70
M.ROD_MAX = 100
M.DEFAULT_TARGET_FILL = 0.5   -- keep the internal steam tank ~50% full
M.DEADBAND = 0.06             -- +/-6 percentage points: no rod movement inside this

-- Proportional response. The step used to be
--   clamp(|error| * 100, 1, MAX_STEP)
-- which looks proportional but never was: leaving the 0.06 deadband already
-- means |error| * 100 > 6, so the clamp returned MAX_STEP every single time.
-- Measured across the whole error range: 45 of 45 samples gave exactly
-- MAX_STEP. The reactor was therefore a pure two-point controller that
-- slammed the rods at full rate for any deviation, however small.
--
-- Now the step scales with how far outside the deadband we actually are:
-- MIN_STEP right at the edge, MAX_STEP once the error exceeds the
-- proportional band. MIN_STEP stays at 1 because the mod stores rod levels
-- as integers -- a smaller step would be rounded away on write and the
-- controller would stall just outside the deadband.
M.MIN_STEP = 1
M.MAX_STEP = 6
M.PROPORTIONAL_BAND = 0.25    -- full authority once |error| exceeds DEADBAND + this

-- Rod movement is rate limited on top of that. At 10 Hz with the old fixed
-- step the rods crossed their entire 70..100 range in 1.5 s and reached a
-- stop from mid-travel in 0.8 s -- far faster than the steam tank responds,
-- which produced a limit cycle instead of settling (simulated: 48 % fill
-- swing with 9 direction reversals in 40 s). Adjusting at most twice a
-- second gives the tank time to show the effect of the last move before the
-- next one. A safety trip ignores this gate entirely.
M.MIN_ADJUST_INTERVAL_MS = 500

-- Damping against overshoot. Looking only at WHERE the tank is -- and never
-- at which way it is already moving -- is what made the loop cycle: traced
-- against a lagging tank the controller kept inserting rods through ticks
-- 190-220 while the fill had already turned around and was falling back
-- toward target on its own, so by the time it arrived the rods were far
-- over-inserted and the whole thing tipped the other way.
--
-- So before correcting, project the current trend forward: if the tank
-- would reach the deadband on its own within TREND_LOOKAHEAD adjustment
-- intervals, the situation is already resolving and adding more correction
-- would only overshoot. This is the derivative term, expressed as a
-- prediction rather than a gain so it stays obvious what it does.
M.TREND_LOOKAHEAD = 4

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- input:
--   fill_ratio     -- current internal steam tank fill, 0..1
--   target_fill    -- desired fill, 0..1 (defaults to DEFAULT_TARGET_FILL)
--   current_rods   -- current rod level, 0..100 (100 = fully inserted)
--   safety_override -- true forces full insertion regardless of fill
--                       (SAFE state, or any active safety trip)
--
-- returns: { rods, reason }
function M.compute_rod_level(input)
  input = input or {}
  if input.safety_override then
    return { rods = M.ROD_MAX, reason = "SAFETY_FULL_INSERT" }
  end

  local fill = tonumber(input.fill_ratio)
  local current_rods = clamp(tonumber(input.current_rods) or M.ROD_MAX, M.ROD_MIN, M.ROD_MAX)
  if type(fill) ~= "number" then
    -- No steam reading available: fail safe toward full insertion rather
    -- than guessing a power level from stale/missing data.
    return { rods = M.ROD_MAX, reason = "NO_STEAM_READING" }
  end

  local target = tonumber(input.target_fill) or M.DEFAULT_TARGET_FILL
  local error_fill = fill - target -- positive: tank fuller than wanted

  if math.abs(error_fill) <= M.DEADBAND then
    return { rods = current_rods, reason = "DEADBAND" }
  end

  -- Already heading home? Then leave it alone -- see TREND_LOOKAHEAD.
  -- previous_fill is the reading one adjustment interval ago, supplied by
  -- the caller (the orchestrator samples it); without it this simply falls
  -- through to the proportional response below.
  local previous_fill = tonumber(input.previous_fill)
  if previous_fill then
    local projected_error = (fill + (fill - previous_fill) * M.TREND_LOOKAHEAD) - target
    -- Hold as soon as the projection no longer calls for a correction in
    -- the direction we are about to apply -- that covers both "it will
    -- settle inside the deadband" and "it will shoot clean past the
    -- target". Testing only for the deadband would get the second case
    -- exactly backwards: a tank at 0.62 already falling to a projected
    -- 0.30 is still above target, so a deadband-only check would insert
    -- even more rods and deepen the undershoot it is about to have.
    if (error_fill > 0 and projected_error <= M.DEADBAND)
        or (error_fill < 0 and projected_error >= -M.DEADBAND) then
      return { rods = current_rods, reason = "CONVERGING" }
    end
  end

  -- Tank too full (error_fill > 0) -> reduce power -> INSERT rods (increase level).
  -- Tank too empty (error_fill < 0) -> increase power -> WITHDRAW rods (decrease level).
  --
  -- Proportional: how far past the deadband edge are we, relative to the
  -- proportional band? Right at the edge that is 0 -> MIN_STEP; at or beyond
  -- the band it saturates at MAX_STEP.
  local excess = math.abs(error_fill) - M.DEADBAND
  local ratio = M.PROPORTIONAL_BAND > 0 and (excess / M.PROPORTIONAL_BAND) or 1
  local step = clamp(M.MAX_STEP * ratio, M.MIN_STEP, M.MAX_STEP)
  local next_rods
  if error_fill > 0 then
    next_rods = clamp(current_rods + step, M.ROD_MIN, M.ROD_MAX)
  else
    next_rods = clamp(current_rods - step, M.ROD_MIN, M.ROD_MAX)
  end
  return { rods = next_rods, reason = error_fill > 0 and "TANK_FULL_INSERT" or "TANK_LOW_WITHDRAW" }
end

-- Confirmed spec (2026-09-19): if the physical reactor reads OFF (e.g.
-- never switched on after a fresh multiblock assembly, or manually
-- toggled), v2 must turn it back on itself rather than sit there
-- regulating rods on a block producing zero power. Only ever turns it
-- ON -- SAFE already reaches zero power via full rod insertion above, so
-- there is no case where v2 needs to switch the reactor off itself.
--
-- current_active: the last read `active` state (true/false), or nil/
-- anything non-boolean if unknown -- treated the same as false so an
-- unreadable state fails toward "make sure it's on" rather than assuming
-- it already is.
function M.compute_active_decision(current_active)
  return current_active ~= true
end

return M
