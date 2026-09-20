-- RT rewrite, step 10: the safety evaluation v2 was missing entirely.
--
-- CRITICAL GAP this module closes: rt2_orchestrator.tick() has always
-- accepted a `safety_tripped` input (it is what drives the SAFE state, full
-- rod insertion and flow=0), but rt2_engine.tick() never supplied it --
-- it only ever passed now_ms/hardware_ready/turbines/reactor. Combined
-- with main.lua's control_tick() returning early for v2 (thereby skipping
-- module_lifecycle.update_module_states(), v1's safety detector), a v2
-- node had NO temperature and NO coolant monitoring whatsoever: SAFE was
-- reachable only through an explicit manual SCRAM command.
--
-- Deliberately reuses core/safety.lua's existing evaluators rather than
-- reimplementing the limits: those carry the hysteresis, sample-count
-- debouncing, stale/zero-glitch measurement handling and escalation
-- semantics that were tuned against real production incidents in this
-- pack. Re-deriving any of that here would be exactly the kind of
-- duplicated-and-then-drifting safety logic the rewrite exists to remove.
--
-- This module stays pure in the same sense as the rest of the rt2_*
-- decision core: it takes a state table plus a plain reading table and
-- returns a plain decision table. The state table is caller-owned (the
-- evaluators accumulate their debounce counters in it), never a global.

local safety = require("core.safety")

local M = {}

function M.new_state()
  return { temperature = {}, coolant = {} }
end

-- state:   a table from M.new_state(), carried across ticks by the caller
-- reading: { temperature, coolant_ratio, coolant_amount, coolant_amount_max }
--          -- as produced by rt2_adapter.read_reactor()
-- limits:  config.safety (max_temperature/temperature_hysteresis/
--          temperature_trip_samples/min_water/coolant_hysteresis/
--          coolant_trip_samples/coolant_invalid_grace_samples)
--
-- returns: { tripped, reason, temperature, coolant_ratio }
function M.evaluate(state, reading, limits)
  state = type(state) == "table" and state or M.new_state()
  reading = type(reading) == "table" and reading or {}
  limits = type(limits) == "table" and limits or {}

  local temp = safety.evaluate_temperature_limit({
    fuel_temperature = reading.temperature,
    max_temperature = limits.max_temperature,
    hysteresis = limits.temperature_hysteresis,
    trip_samples = limits.temperature_trip_samples,
    state = state.temperature,
  })

  local coolant = safety.evaluate_coolant_limit({
    coolant_ratio = reading.coolant_ratio,
    coolant_amount = reading.coolant_amount,
    coolant_amount_max = reading.coolant_amount_max,
    min_water = limits.min_water,
    hysteresis = limits.coolant_hysteresis,
    trip_samples = limits.coolant_trip_samples,
    invalid_grace_samples = limits.coolant_invalid_grace_samples,
    measurement_state = reading.coolant_ratio ~= nil and "VALID" or "INVALID",
    state = state.coolant,
  })

  -- Temperature wins the reason when both trip: it is the condition with
  -- the shorter path to real damage, and it is what the operator needs to
  -- see first in the log line.
  local tripped = temp.triggered == true or coolant.triggered == true
  local reason = nil
  if temp.triggered then
    reason = temp.condition
  elseif coolant.triggered then
    reason = coolant.condition
  end

  return {
    tripped = tripped,
    reason = reason,
    temperature = temp.temperature,
    coolant_ratio = coolant.coolant_ratio,
  }
end

return M
