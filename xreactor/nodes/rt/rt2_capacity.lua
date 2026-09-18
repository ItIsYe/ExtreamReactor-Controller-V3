-- RT rewrite, step 4: capacity learning, fully decoupled from control.
--
-- The old capacity_learning.lua did one thing right (measure turbines at
-- target RPM, apply a safety margin) but got entangled with two things
-- that caused real production bugs this session:
--   1. get_turbine_target_rpm() checked capacity_ready INSIDE the target
--      calculation, so "is capacity known" and "what RPM should this
--      turbine target" were one tangled decision (rt2_turbine.lua's
--      compute_target_rpm() now takes the *state* as an explicit input
--      instead -- rt2_state.lua already decided LEARNING vs MASTER/
--      AUTONOM before this module is even consulted).
--   2. The persisted cache was keyed by an exact per-turbine identity
--      signature (name/registry id) that is NOT stable across a world
--      reload in this pack (BigReactors multiblocks get renamed) -- so a
--      real fix already shipped this session (main.lua v700) reused the
--      registry's own ids consistently, but the underlying fragility
--      (identity-based invalidation) remains a foot-gun. This module
--      instead keys invalidation on turbine COUNT only: a genuine
--      hardware change (added/removed turbine) is the only thing that
--      should ever throw away a learned value. A renamed-but-same-count
--      turbine fleet keeps its learned capacity.
--
-- Pure functions again: M.update() takes the previous state and a plain
-- list of {rpm, energy, coil_engaged} readings and returns a new state --
-- no ctx, no file I/O. Persistence (save/load) is a thin, separate
-- wrapper below so the learning math itself stays trivially testable.

local M = {}

M.TARGET_RPM = 900
M.TOLERANCE_RPM = 15
M.MIN_FRACTION = 0.8   -- at least 80% of turbines must be at target to trust a measurement
M.SAFETY_MARGIN = 0.05 -- store max_output as 95% of the measured peak

local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

function M.new_state()
  return {
    ready = false,
    max_output = 0,
    at_target = 0,
    total_turbines = 0,
    reason = "INIT",
  }
end

local function measure(turbines)
  local total = #(turbines or {})
  if total == 0 then return nil, 0, 0 end
  local at_target, output = 0, 0
  for _, t in ipairs(turbines) do
    local rpm = tonumber(t.rpm)
    local energy = tonumber(t.energy) or 0
    if rpm and t.coil_engaged ~= false
        and math.abs(rpm - M.TARGET_RPM) <= M.TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      output = output + energy
    end
  end
  if at_target < math.max(1, math.ceil(total * M.MIN_FRACTION)) then
    return nil, at_target, total
  end
  return math.floor((output / at_target) * total), at_target, total
end

-- previous: a state table from M.new_state()/a prior M.update() call.
-- turbines: array of { rpm=number, energy=number, coil_engaged=boolean }.
-- Returns a NEW state table (copy-on-write, same discipline as before).
function M.update(previous, turbines)
  local state = copy(previous or M.new_state())
  local total = #(turbines or {})

  if total ~= state.total_turbines then
    -- Turbine COUNT changed: the only signal this module trusts as a real
    -- hardware change. A rename-only reshuffle (same count) never reaches
    -- this branch, so it can never invalidate a learned value the way the
    -- old identity-signature cache did.
    state.ready = false
    state.max_output = 0
    state.total_turbines = total
    state.reason = total == 0 and "NO_TURBINES" or "TOPOLOGY_CHANGED"
  end

  local measured, at_target, measured_total = measure(turbines)
  state.at_target = at_target
  state.total_turbines = measured_total

  if measured then
    local safe = measured * (1 - M.SAFETY_MARGIN)
    if not state.ready then
      state.max_output = safe
      state.ready = true
      state.reason = "MEASURED"
    elseif safe > state.max_output then
      state.max_output = safe
      state.reason = "UPDATED"
    else
      state.reason = "STABLE"
    end
  elseif state.reason ~= "TOPOLOGY_CHANGED" and state.reason ~= "NO_TURBINES" then
    state.reason = measured_total == 0 and "NO_TURBINES" or "NONE_AT_TARGET"
  end

  return state
end

-- ── Persistence (thin wrapper; not itself pure, kept separate on purpose) ──

function M.save(state, opts)
  if type(state) ~= "table" or state.ready ~= true then return false, "not ready" end
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return false, "no path" end
  if type(opts.write_config) ~= "function" then return false, "no writer" end
  return opts.write_config(opts.path, {
    ready = true,
    max_output = tonumber(state.max_output) or 0,
    turbine_count = tonumber(state.total_turbines) or 0,
  })
end

function M.load(opts)
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return nil end
  if type(opts.read_config) ~= "function" then return nil end
  local data = opts.read_config(opts.path)
  if type(data) ~= "table" or data.ready ~= true
      or type(data.max_output) ~= "number" or data.max_output <= 0 then
    return nil
  end
  if type(opts.turbine_count) == "number"
      and type(data.turbine_count) == "number"
      and data.turbine_count ~= opts.turbine_count then
    return nil, "turbine count changed: cached=" .. tostring(data.turbine_count) .. " current=" .. tostring(opts.turbine_count)
  end
  local state = M.new_state()
  state.ready = true
  state.max_output = data.max_output
  state.total_turbines = data.turbine_count
  state.reason = "LOADED_FROM_CACHE"
  return state
end

return M
