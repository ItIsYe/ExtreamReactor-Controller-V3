-- RT rewrite, step 12: the node measures its own plant and derives its
-- reactor control parameters from it.
--
-- WHY: MAX_STEP, PROPORTIONAL_BAND and MIN_ADJUST_INTERVAL_MS only make
-- sense relative to how fast this particular steam tank actually responds
-- to a rod movement -- and that depends on the reactor's size, its tank
-- capacity and how much the turbine fleet is drawing. Those numbers are not
-- knowable when the code is written. Hand-picked constants are therefore
-- always a guess: the same values that settle one plant will limit-cycle on
-- a bigger one and crawl on a smaller one.
--
-- HOW: purely by OBSERVATION, never by perturbing the reactor. Deliberately
-- no step-response experiment -- deliberately injecting a disturbance into a
-- live reactor to measure it is not something a controller should do on its
-- own. Instead this watches intervals where the rods happened to stay put
-- and records how fast the tank filled or drained at that rod level. During
-- the learning phase the rods move across a good part of their range
-- anyway, so the excitation comes for free.
--
-- Fitting a line through those (rod level -> fill rate) pairs gives the
-- process gain: how much fill-per-second one rod point is worth. Everything
-- else follows from it:
--
--   interval  -- long enough that the smallest possible move (1 rod point)
--                produces a fill change big enough to actually see
--   max_step  -- large enough to null out a full proportional band within
--                SETTLE_INTERVALS adjustments, and no larger
--
-- Pure, like the rest of the decision core: observe() takes a state table
-- and a reading and returns a new state, derive() turns a state into a
-- profile. No clock, no peripherals, no files.

local M = {}

-- A fit is only trusted once it has seen enough steady intervals across a
-- wide enough spread of rod levels. Two samples 1 rod point apart can
-- produce any slope at all once measurement noise is in play.
M.MIN_SAMPLES = 12
M.MIN_ROD_SPREAD = 6

-- Target behaviour the derivation solves for.
M.SETTLE_INTERVALS = 4        -- adjustments allowed to correct a full band
M.MIN_DETECTABLE_FILL = 0.005 -- a 1-point move must move the tank at least this much

-- A single sample must span enough time to be worth anything. The node
-- ticks several times a second, so consecutive readings are ~100 ms apart;
-- across such a span a real plant moves the tank by far less than the
-- reading's own resolution, and the computed rate is then almost pure
-- quantisation noise, amplified by the small dt in the division. Holding
-- the anchor until a full second has passed measures the same plant with
-- roughly ten times less noise, at no cost -- the rods stand still between
-- adjustments anyway, which is exactly when sampling happens.
M.MIN_SAMPLE_DT_MS = 1000
-- ...and not TOO much time: observation stops while SAFE and whenever the
-- steam reading is missing, so the anchor can otherwise survive a gap of
-- minutes and then be differenced against a reading from a completely
-- different regime -- one bogus sample with enormous leverage on the fit.
M.MAX_SAMPLE_DT_MS = 10000

-- Hard limits. A bad fit must never be able to produce a dangerous
-- controller, so the derived values are clamped into a range that is safe
-- even if the measurement was nonsense.
M.MAX_STEP_MIN, M.MAX_STEP_MAX = 2, 15
M.INTERVAL_MIN_MS, M.INTERVAL_MAX_MS = 200, 3000

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function M.new_state()
  return {
    n = 0, sum_x = 0, sum_y = 0, sum_xy = 0, sum_xx = 0,
    rod_min = nil, rod_max = nil,
    last_rods = nil, last_fill = nil, last_ms = nil,
  }
end

local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

-- reading: { now_ms, rods, fill }
--
-- A pair of consecutive readings only yields a usable sample when the rods
-- did not move between them -- otherwise the fill change cannot be
-- attributed to a single rod level. Readings at a tank end stop are dropped
-- too: a tank sitting at 0 or 1 is clipped, so its rate says nothing about
-- the reactor.
function M.observe(state, reading)
  state = type(state) == "table" and state or M.new_state()
  reading = type(reading) == "table" and reading or {}

  local now_ms = tonumber(reading.now_ms)
  local rods = tonumber(reading.rods)
  local fill = tonumber(reading.fill)
  if not (now_ms and rods and fill) then return state end

  local next_state = copy(state)
  local prev_rods, prev_fill, prev_ms = state.last_rods, state.last_fill, state.last_ms

  local function reanchor()
    next_state.last_rods, next_state.last_fill, next_state.last_ms = rods, fill, now_ms
    return next_state
  end

  -- No anchor yet, or the rods moved: this reading becomes the new anchor
  -- and yields nothing, because a fill change spanning a rod movement
  -- cannot be attributed to a single rod level.
  if prev_rods == nil or prev_rods ~= rods then return reanchor() end

  local elapsed_ms = now_ms - (prev_ms or now_ms)
  if elapsed_ms <= 0 then return reanchor() end
  -- Too soon: KEEP the anchor and let more time accumulate, rather than
  -- differencing two readings a tick apart (see MIN_SAMPLE_DT_MS). This is
  -- the whole reason the anchor is not advanced unconditionally.
  if elapsed_ms < M.MIN_SAMPLE_DT_MS then return next_state end
  -- Too long: the anchor survived an observation gap, so drop it and start
  -- a fresh one (see MAX_SAMPLE_DT_MS).
  if elapsed_ms > M.MAX_SAMPLE_DT_MS then return reanchor() end

  local dt = elapsed_ms / 1000
  -- Clipped at an end stop: the tank cannot show the true rate there.
  if (fill <= 0 and prev_fill <= 0) or (fill >= 1 and prev_fill >= 1) then return reanchor() end

  local rate = (fill - prev_fill) / dt

  next_state.n = state.n + 1
  next_state.sum_x = state.sum_x + rods
  next_state.sum_y = state.sum_y + rate
  next_state.sum_xy = state.sum_xy + rods * rate
  next_state.sum_xx = state.sum_xx + rods * rods
  next_state.rod_min = math.min(state.rod_min or rods, rods)
  next_state.rod_max = math.max(state.rod_max or rods, rods)
  return reanchor()
end

function M.spread(state)
  if not (state and state.rod_min and state.rod_max) then return 0 end
  return state.rod_max - state.rod_min
end

-- Returns a profile table, or nil plus a reason string.
--
-- opts.proportional_band -- the band the derivation sizes max_step against
--                           (rt2_reactor.PROPORTIONAL_BAND in production)
function M.derive(state, opts)
  state = type(state) == "table" and state or M.new_state()
  opts = type(opts) == "table" and opts or {}
  local band = tonumber(opts.proportional_band) or 0.25

  if state.n < M.MIN_SAMPLES then
    return nil, string.format("zu wenige Messwerte: %d von %d", state.n, M.MIN_SAMPLES)
  end
  local spread = M.spread(state)
  if spread < M.MIN_ROD_SPREAD then
    return nil, string.format("Stabstellungen zu eng beieinander: %.0f statt %d Punkte",
      spread, M.MIN_ROD_SPREAD)
  end

  -- Least squares slope of fill rate against rod level.
  local n = state.n
  local denominator = n * state.sum_xx - state.sum_x * state.sum_x
  if denominator == 0 then return nil, "Steigung nicht bestimmbar" end
  local slope = (n * state.sum_xy - state.sum_x * state.sum_y) / denominator

  -- More insertion means less steam, so the slope must come out negative.
  -- A positive one means the fill was driven by something other than the
  -- rods (a changing turbine load, most likely) and the fit is worthless.
  local gain = -slope
  if gain <= 0 then
    return nil, "kein plausibler Zusammenhang Staebe -> Fuellstand (Steigung falsches Vorzeichen)"
  end

  local interval_ms = clamp((M.MIN_DETECTABLE_FILL / gain) * 1000, M.INTERVAL_MIN_MS, M.INTERVAL_MAX_MS)
  local interval_s = interval_ms / 1000
  local max_step = clamp(band / (gain * M.SETTLE_INTERVALS * interval_s), M.MAX_STEP_MIN, M.MAX_STEP_MAX)

  return {
    gain = gain,                      -- Fuellstandsanteil pro Sekunde pro Stab-Punkt
    max_step = math.floor(max_step + 0.5),
    min_adjust_interval_ms = math.floor(interval_ms + 0.5),
    samples = n,
    rod_spread = spread,
  }
end

-- ── Persistence (thin wrapper, same shape as rt2_capacity) ───────────────

function M.save(profile, opts)
  if type(profile) ~= "table" then return false, "no profile" end
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return false, "no path" end
  if type(opts.write_config) ~= "function" then return false, "no writer" end
  return opts.write_config(opts.path, {
    tuned = true,
    gain = tonumber(profile.gain) or 0,
    max_step = tonumber(profile.max_step) or 0,
    min_adjust_interval_ms = tonumber(profile.min_adjust_interval_ms) or 0,
    samples = tonumber(profile.samples) or 0,
  })
end

function M.load(opts)
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return nil end
  if type(opts.read_config) ~= "function" then return nil end
  local data = opts.read_config(opts.path)
  if type(data) ~= "table" or data.tuned ~= true then return nil end
  local max_step = tonumber(data.max_step)
  local interval = tonumber(data.min_adjust_interval_ms)
  if not max_step or not interval then return nil, "unvollstaendiges Profil" end
  -- Re-clamp on load: a hand-edited or stale file must not be able to widen
  -- the controller beyond what the derivation itself is allowed to produce.
  return {
    gain = tonumber(data.gain) or 0,
    max_step = clamp(max_step, M.MAX_STEP_MIN, M.MAX_STEP_MAX),
    min_adjust_interval_ms = clamp(interval, M.INTERVAL_MIN_MS, M.INTERVAL_MAX_MS),
    samples = tonumber(data.samples) or 0,
  }
end

return M
