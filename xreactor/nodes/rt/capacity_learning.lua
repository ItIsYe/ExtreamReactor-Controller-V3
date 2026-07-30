-- nodes/rt/capacity_learning.lua
--
-- Eigenständiges Capacity-Learning-Modul für die RT-Node.
-- Misst kontinuierlich die maximale Leistungskapazität der Turbinen-Gruppe,
-- damit der Master weiß, wie viel diese Node liefern kann.
--
-- PRINZIP:
--   - Ziel für die Kapazitätsmessung: IMMER fest 900 RPM — unabhängig vom
--     Master. Das Learning soll gerade dann funktionieren, BEVOR der Master
--     sinnvoll zuweisen kann.
--   - Reaktor-Steuerung wird NICHT berührt.
--   - Eine Turbine zählt als "am Ziel" wenn: Coil eingerastet UND
--     RPM nah an 900 (±15) UND Energie > 0.
--   - Mindestens 80% der Turbinen müssen am Ziel sein, bevor eine Messung
--     akzeptiert wird (Schutz vor ungenauen Einzelstichproben).
--   - Durchschnitt der Turbinen am Ziel wird auf Gesamtzahl hochgerechnet.
--   - Messung läuft KONTINUIERLICH: höhere Werte werden sofort übernommen,
--     niedrigere werden ignoriert (kein Reset bei kurzzeitigem Einbruch).
--   - "ready = true" sobald die erste gültige Messung vorliegt — ab dann
--     kann der Master mit dem Wert planen.
--
-- SCHNITTSTELLE:
--   M.update(ctx, turbines) -> learning
--     ctx.capacity_learning  -- persistenter State (wird direkt mutiert)
--     ctx.log                -- function(level, msg), optional
--     turbines               -- Liste von { rpm, energy, coil_engaged, ... }
--
--   M.new_state() -> table   -- leerer Initialzustand

local M = {}

local TARGET_RPM     = 900
local TOLERANCE_RPM  = 15
local MIN_FRACTION   = 0.8  -- 80% der Turbinen müssen am Ziel sein

local function numeric_value(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v); if n then return n end
  end
  return nil
end

-- Misst die aktuelle Kapazität. Gibt (output, at_target, total) zurück.
-- output ist nil wenn nicht genug Turbinen am Ziel sind.
local function measure(turbines)
  local total = type(turbines) == "table" and #turbines or 0
  if total == 0 then return nil, 0, 0 end

  local at_target, at_target_output = 0, 0
  for _, t in ipairs(turbines) do
    local rpm    = numeric_value(t.rpm)
    local energy = numeric_value(t.energy) or 0
    if rpm and t.coil_engaged ~= false
        and math.abs(rpm - TARGET_RPM) <= TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      at_target_output = at_target_output + energy
    end
  end

  local min_required = math.max(1, math.ceil(total * MIN_FRACTION))
  if at_target < min_required then return nil, at_target, total end

  return math.floor((at_target_output / at_target) * total), at_target, total
end

-- Leerer Initialzustand.
function M.new_state()
  return { ready = false, max_output = 0, at_target = 0, total_turbines = 0, reason = "INIT" }
end

-- Haupt-Update — wird bei jedem Status-Tick aufgerufen.
-- Mutiert ctx.capacity_learning direkt und gibt es zurück.
function M.update(ctx, turbines)
  if type(ctx.capacity_learning) ~= "table" then
    ctx.capacity_learning = M.new_state()
  end
  local learning = ctx.capacity_learning
  local log = type(ctx.log) == "function" and ctx.log or function() end

  local measured, at_target, total = measure(turbines)
  learning.at_target      = at_target
  learning.total_turbines = total

  if measured then
    if not learning.ready then
      learning.max_output = measured
      learning.ready      = true
      learning.reason     = "MEASURED"
      pcall(log, "INFO", string.format(
        "RT capacity measured output=%.2f at_target=%d/%d",
        measured, at_target, total))
    elseif measured > learning.max_output then
      learning.max_output = measured
      learning.reason     = "UPDATED"
      pcall(log, "INFO", string.format(
        "RT capacity updated output=%.2f at_target=%d/%d",
        measured, at_target, total))
    else
      learning.reason = "STABLE"
    end
  else
    learning.reason = total == 0 and "NO_TURBINES" or "NONE_AT_TARGET"
  end

  return learning
end

return M
