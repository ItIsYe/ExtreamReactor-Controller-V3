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

-- Wie viele Takte eine Sicherheitsmessung ausfallen darf, bevor der
-- Messausfall selbst als Sicherheitslage gilt. Bei 10 Hz Regeltakt
-- (nodes/rt/main.lua's RECEIVE_TIMEOUT) sind 200 Takte 20 Sekunden --
-- lang genug fuer einen nachladenden Chunk, ein kurz zerlegtes Multiblock
-- oder einen geworfenen Peripherieaufruf (alles in
-- tests/rt2_er_physics_scenarios_test.lua nachgestellt), und kurz genug,
-- dass ein echter Sensorausfall nicht unbegrenzt als "sicher" durchgeht.
M.DEFAULT_MEASUREMENT_GRACE_SAMPLES = 200

function M.new_state()
  return {
    temperature = {},
    coolant = {},
    -- Messverfuegbarkeit, siehe evaluate(). ever_valid ist bewusst
    -- klebrig: nur ein Kanal, der schon einmal gelesen WURDE, kann
    -- ausfallen. Ein Reaktor ohne Kuehlkreis (passiv gekuehlt) oder eine
    -- noch nicht gebundene Peripherie loest damit nie aus.
    availability = {
      temperature_ever_valid = false, temperature_missing_ticks = 0,
      coolant_ever_valid = false, coolant_missing_ticks = 0,
    },
  }
end

-- state:   a table from M.new_state(), carried across ticks by the caller
-- reading: { temperature, coolant_ratio, coolant_amount, coolant_amount_max }
--          -- as produced by rt2_adapter.read_reactor()
-- limits:  config.safety (max_temperature/temperature_hysteresis/
--          temperature_trip_samples/min_water/coolant_hysteresis/
--          coolant_trip_samples/coolant_invalid_grace_samples)
--
-- returns: { tripped, reason, temperature, coolant_ratio }
-- Messausfall als eigene Sicherheitslage.
--
-- Vorher reichte rt2_safety nur `triggered` weiter. Die Core-Auswerter
-- stellen zwar "unavailable" fest (TEMP_UNAVAILABLE,
-- COOLANT_UNAVAILABLE), aber das kam hier nie an: `reason` wurde nur bei
-- einer Ausloesung gesetzt. Bei vollstaendigem Messausfall gab evaluate()
-- genau `{ tripped = false }` zurueck -- ein Verbraucher konnte "alles
-- sicher" nicht von "ich bin blind" unterscheiden, und 1000 Takte ohne
-- Temperatur und ohne Kuehlmittel blieben folgenlos.
--
-- Bewusste Grenze: gezaehlt wird nur ein Kanal, der auf DIESEM Reaktor
-- schon einmal einen gueltigen Wert geliefert hat. Ein passiv gekuehlter
-- Reaktor hat gar keinen Kuehlkreis (core/fluid.lua's resolve_ratio
-- liefert dann dauerhaft nil), und beim Start ist die Peripherie noch
-- nicht gebunden -- beides darf keine Abschaltung ausloesen. Der Fall,
-- den es zu fassen gilt, ist "war lesbar, ist es jetzt nicht mehr".
local function track_availability(availability, key, valid, grace)
  local ever = key .. "_ever_valid"
  local ticks = key .. "_missing_ticks"
  if valid then
    availability[ever] = true
    availability[ticks] = 0
    return false, 0
  end
  if not availability[ever] then
    availability[ticks] = 0
    return false, 0
  end
  local n = (tonumber(availability[ticks]) or 0) + 1
  availability[ticks] = n
  return n > grace, n
end

function M.evaluate(state, reading, limits)
  state = type(state) == "table" and state or M.new_state()
  reading = type(reading) == "table" and reading or {}
  limits = type(limits) == "table" and limits or {}
  state.availability = type(state.availability) == "table" and state.availability or {
    temperature_ever_valid = false, temperature_missing_ticks = 0,
    coolant_ever_valid = false, coolant_missing_ticks = 0,
  }

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
  local grace = math.max(0, math.floor(tonumber(limits.measurement_grace_samples)
    or M.DEFAULT_MEASUREMENT_GRACE_SAMPLES))
  local temperature_valid = type(temp.temperature) == "number"
  -- Fuer das Kuehlmittel zaehlt der ROHE Messwert, nicht der von
  -- evaluate_coolant_limit ggf. aus dem letzten gueltigen Stand
  -- ersetzte: ein Stale-Fallback ist gerade KEINE frische Messung.
  local coolant_valid = type(coolant.coolant_ratio_raw) == "number"
  local temperature_lost, temperature_missing_ticks =
    track_availability(state.availability, "temperature", temperature_valid, grace)
  local coolant_lost, coolant_missing_ticks =
    track_availability(state.availability, "coolant", coolant_valid, grace)

  local tripped = temp.triggered == true or coolant.triggered == true
    or temperature_lost or coolant_lost
  -- Die Temperatur gewinnt den Grund, wenn mehrere zutreffen: sie hat den
  -- kuerzesten Weg zu echtem Schaden. Ein Messausfall steht hinter einer
  -- echten Grenzwertueberschreitung -- die ist die konkretere Aussage.
  local reason = nil
  if temp.triggered then
    reason = temp.condition
  elseif coolant.triggered then
    reason = coolant.condition
  elseif temperature_lost then
    reason = "TEMP_MEASUREMENT_LOST"
  elseif coolant_lost then
    reason = "COOLANT_MEASUREMENT_LOST"
  end

  return {
    tripped = tripped,
    reason = reason,
    temperature = temp.temperature,
    coolant_ratio = coolant.coolant_ratio,
    -- Messlage, IMMER gefuellt -- auch ohne Ausloesung. Das ist der
    -- Unterschied zwischen "alles in Ordnung" und "ich sehe nichts".
    temperature_available = temperature_valid,
    coolant_available = coolant_valid,
    temperature_condition = temp.condition,
    coolant_condition = coolant.condition,
    temperature_missing_ticks = temperature_missing_ticks,
    coolant_missing_ticks = coolant_missing_ticks,
    measurement_grace_samples = grace,
  }
end

return M
