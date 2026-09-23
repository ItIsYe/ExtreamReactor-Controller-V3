package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local tuning = require('nodes.rt.rt2_tuning')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_near(a, e, tol, m)
  if math.abs(a - e) > tol then
    error((m or 'near') .. ': expected~' .. tostring(e) .. ' +/-' .. tostring(tol) .. ' actual=' .. tostring(a))
  end
end

-- A plant with a KNOWN gain: every rod point above the equilibrium drains
-- the tank by `gain` fill-fraction per second, every point below fills it.
-- Feeding the module readings from this plant must recover that gain.
local function simulate(gain, equilibrium_rods, rod_levels, ticks_per_level, dt_ms)
  local state = tuning.new_state()
  local now, fill = 1000000, 0.5
  for _, rods in ipairs(rod_levels) do
    for _ = 1, ticks_per_level do
      state = tuning.observe(state, { now_ms = now, rods = rods, fill = fill })
      -- more insertion -> less steam -> tank drains
      fill = fill + (equilibrium_rods - rods) * gain * (dt_ms / 1000)
      fill = math.max(0.05, math.min(0.95, fill))
      now = now + dt_ms
    end
  end
  return state
end

-- ── Die Ableitung muss die echte Anlagenverstaerkung finden ──────────────
do
  local real_gain = 0.004   -- Fuellstandsanteil pro Sekunde pro Stab-Punkt
  local state = simulate(real_gain, 85, { 78, 82, 86, 90 }, 5, 500)
  local profile, err = tuning.derive(state, { proportional_band = 0.25 })
  assert_true(profile, 'a clean plant must yield a profile, got: ' .. tostring(err))
  assert_near(profile.gain, real_gain, real_gain * 0.2,
    'the derived gain must match the plant it was measured on')
  assert_true(profile.max_step >= tuning.MAX_STEP_MIN and profile.max_step <= tuning.MAX_STEP_MAX)
  assert_true(profile.min_adjust_interval_ms >= tuning.INTERVAL_MIN_MS
    and profile.min_adjust_interval_ms <= tuning.INTERVAL_MAX_MS)
end

-- A SLOWER plant (smaller gain) must be given a longer adjustment interval
-- and a bigger step -- that is the whole point of measuring.
do
  local fast = tuning.derive(simulate(0.010, 85, { 78, 82, 86, 90 }, 5, 500), {})
  local slow = tuning.derive(simulate(0.001, 85, { 78, 82, 86, 90 }, 5, 500), {})
  assert_true(fast and slow, 'both plants must yield profiles')
  assert_true(slow.min_adjust_interval_ms > fast.min_adjust_interval_ms,
    'a sluggish tank must be given more time between adjustments')
  assert_true(slow.max_step >= fast.max_step,
    'a sluggish tank needs at least as large a step to move the same amount')
end

-- ── Schutz gegen schlechte Messungen ─────────────────────────────────────

do
  -- Too few samples.
  local state = simulate(0.004, 85, { 80, 90 }, 2, 500)
  local profile, err = tuning.derive(state, {})
  assert_true(profile == nil, 'too few samples must not yield a profile')
  assert_true(tostring(err):find('Messwerte'), 'and must say why: ' .. tostring(err))
end

do
  -- Plenty of samples but all at essentially the same rod level: the slope
  -- through such a cluster is noise, not a measurement.
  local state = simulate(0.004, 85, { 84, 85, 86 }, 10, 500)
  local profile, err = tuning.derive(state, {})
  assert_true(profile == nil, 'a narrow rod spread must not yield a profile')
  assert_true(tostring(err):find('eng'), 'and must say why: ' .. tostring(err))
end

do
  -- Wrong sign: the tank filled faster the MORE the rods were inserted,
  -- which cannot be caused by the rods. Something else was driving it --
  -- a changing turbine load, most likely -- so the fit must be rejected.
  local state = tuning.new_state()
  local now, fill = 1000000, 0.5
  for _, rods in ipairs({ 78, 82, 86, 90 }) do
    for _ = 1, 5 do
      state = tuning.observe(state, { now_ms = now, rods = rods, fill = fill })
      fill = math.max(0.05, math.min(0.95, fill + (rods - 85) * 0.004 * 0.5))
      now = now + 500
    end
  end
  local profile, err = tuning.derive(state, {})
  assert_true(profile == nil, 'an implausible (positive) slope must be rejected')
  assert_true(tostring(err):find('Vorzeichen'), 'and must say why: ' .. tostring(err))
end

-- ── Was NICHT als Messwert zaehlen darf ──────────────────────────────────

do
  -- Rods moved between the two readings: the fill change cannot be
  -- attributed to a single rod level.
  local state = tuning.new_state()
  state = tuning.observe(state, { now_ms = 1000, rods = 80, fill = 0.50 })
  state = tuning.observe(state, { now_ms = 1500, rods = 82, fill = 0.52 })
  assert_eq(state.n, 0, 'a reading where the rods moved must not become a sample')

  -- Same rods, time passed: that IS a sample.
  state = tuning.observe(state, { now_ms = 2000, rods = 82, fill = 0.54 })
  assert_eq(state.n, 1, 'a steady interval must become a sample')
end

do
  -- A tank pinned at an end stop is clipped, so its rate is meaningless.
  local state = tuning.new_state()
  state = tuning.observe(state, { now_ms = 1000, rods = 80, fill = 0 })
  state = tuning.observe(state, { now_ms = 1500, rods = 80, fill = 0 })
  assert_eq(state.n, 0, 'an empty, pinned tank must not become a sample')

  state = tuning.new_state()
  state = tuning.observe(state, { now_ms = 1000, rods = 80, fill = 1 })
  state = tuning.observe(state, { now_ms = 1500, rods = 80, fill = 1 })
  assert_eq(state.n, 0, 'a full, pinned tank must not become a sample')
end

do
  -- observe() must stay pure: the state handed in is never mutated.
  local state = tuning.new_state()
  state = tuning.observe(state, { now_ms = 1000, rods = 80, fill = 0.5 })
  local before = state.n
  tuning.observe(state, { now_ms = 1500, rods = 80, fill = 0.52 })
  assert_eq(state.n, before, 'observe() must not mutate the state it was given')
end

-- ── Persistenz ───────────────────────────────────────────────────────────

do
  local store = {}
  local profile = { gain = 0.004, max_step = 7, min_adjust_interval_ms = 1250, samples = 40 }
  local ok = tuning.save(profile, { path = '/p', write_config = function(p, d) store[p] = d; return true end })
  assert_true(ok, 'a profile must persist')

  local back = tuning.load({ path = '/p', read_config = function(p) return store[p] end })
  assert_eq(back.max_step, 7)
  assert_eq(back.min_adjust_interval_ms, 1250)

  -- A hand-edited or stale file must not be able to widen the controller
  -- past what the derivation itself is allowed to produce.
  store['/p'].max_step = 999
  store['/p'].min_adjust_interval_ms = 999999
  local clamped = tuning.load({ path = '/p', read_config = function(p) return store[p] end })
  assert_eq(clamped.max_step, tuning.MAX_STEP_MAX, 'a tampered step must clamp to the safe maximum')
  assert_eq(clamped.min_adjust_interval_ms, tuning.INTERVAL_MAX_MS, 'a tampered interval must clamp too')

  assert_true(tuning.load({ path = '/nope', read_config = function() return nil end }) == nil,
    'a missing profile must simply be absent, not an error')
end

print('rt2_tuning_test.lua: ok')
