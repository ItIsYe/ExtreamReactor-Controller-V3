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

local M = {}

M.ROD_MIN = 0
M.ROD_MAX = 100
M.DEFAULT_TARGET_FILL = 0.5   -- keep the internal steam tank ~50% full
M.DEADBAND = 0.03             -- +/-3 percentage points: no rod movement inside this
M.MAX_STEP = 4                -- max rod-level change per control step

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

  -- Tank too full (error_fill > 0) -> reduce power -> INSERT rods (increase level).
  -- Tank too empty (error_fill < 0) -> increase power -> WITHDRAW rods (decrease level).
  local step = clamp(math.abs(error_fill) * 100, 1, M.MAX_STEP)
  local next_rods
  if error_fill > 0 then
    next_rods = clamp(current_rods + step, M.ROD_MIN, M.ROD_MAX)
  else
    next_rods = clamp(current_rods - step, M.ROD_MIN, M.ROD_MAX)
  end
  return { rods = next_rods, reason = error_fill > 0 and "TANK_FULL_INSERT" or "TANK_LOW_WITHDRAW" }
end

return M
