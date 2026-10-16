-- RT: Probleme erkennen, die MASTER als "RT meldet ein Problem" anzeigt.
--
-- Betreiber (2026-10-16): "Drehzahlmeldung raus. Das ist ja ein RT-Problem,
-- dann muss angezeigt werden, dass die RT ein Problem hat, dass man dann auf
-- dem RT-Monitor weiterschauen muss."
--
-- Bis v832 hat MASTER selbst jede Turbine unter 800 U/min und jede gekuppelte
-- Spule unter 800 U/min gemeldet (TURBINE_RPM_LOW, COIL_EARLY). Der Regler
-- stellt aber bei Teillast absichtlich Turbinen ab und bremst sie mit der
-- Spule bis zum Stillstand, und alle 5 Minuten wechselt, welche Turbine
-- steht (rt2_orchestrator.ROTATE_INTERVAL_MS). Jeder Wechsel gab bis zu vier
-- Warnungen -- MASTER kennt die Zieldrehzahl je Turbine nicht und konnte
-- "steht absichtlich" nicht von "kommt nicht hoch" unterscheiden.
--
-- Hier entscheidet der Knoten, der es weiss. Gemeldet wird nur, was nach
-- einer Entprellzeit noch ansteht:
--   - Leistung: unter MASTER-Vorgabe liefert der Knoten LOW_OUTPUT_MS lang
--     weniger als LOW_OUTPUT_RATIO der Sollleistung (dieselbe Grenze, ab der
--     seine eigene Ampel nicht mehr gruen ist). Dazu, als Hinweis, die
--     Turbinen, die laufen sollen und unter dem Zielband stehen.
--   - je Turbine: Drehzahl NO_RPM_MS lang nicht lesbar.
--   - je Turbine: Ueberdrehzahl (Regler-Grund OVERSPEED) OVERSPEED_MS lang.
-- Waehrend des Einlernens faehrt die Flotte absichtlich auf 100 % -- die
-- Leistungspruefung ruht dann.
--
-- Die Leistung gilt erst als wieder in Ordnung, wenn sie LOW_OUTPUT_CLEAR_MS
-- am Stueck reicht. Gemessen am Zwilling (tests/rt2_problems_test.lua): bei
-- Dampfmangel liefert beim Turbinenwechsel alle 5 Minuten die abbremsende
-- Turbine kurz Strom, das Verhaeltnis springt fuer Sekunden ueber die
-- Grenze -- ohne diese Rueckfallzeit setzte genau das die Entprellung
-- zurueck, und das Problem erschien je Wechsel nur fuer Sekunden.
--
-- Reine Funktion ueber einen eigenen Zustand (Zeitpunkte, seit wann eine
-- Bedingung ansteht); keine Peripherie, kein Logging.

local M = {}

M.LOW_OUTPUT_RATIO = 0.85
M.LOW_OUTPUT_MS = 300000
M.LOW_OUTPUT_CLEAR_MS = 60000
M.NO_RPM_MS = 30000
M.OVERSPEED_MS = 30000
-- Unter dem Ziel gilt eine Turbine ab dieser Abweichung (wie
-- rt2_turbine.RPM_BAND).
M.BELOW_TARGET_RPM = 40
-- So viele Zeilen gehen hoechstens in den Status an MASTER.
M.MAX_LINES = 8
-- So viele Turbinen unter Ziel werden als Hinweis aufgezaehlt.
M.MAX_TURBINE_HINTS = 5

function M.new()
  return { since = {} }
end

local function short_rf(value)
  local v = tonumber(value) or 0
  if v >= 1000000 then return string.format("%.1fM", v / 1000000) end
  if v >= 1000 then return string.format("%.1fk", v / 1000) end
  return string.format("%.0f", v)
end

local function minutes(ms)
  return math.max(1, math.floor(ms / 60000))
end

-- Seit wann steht die Bedingung an? nil, wenn sie nicht (mehr) ansteht.
-- clear_ms: so lange muss sie am Stueck weg sein, bevor sie als behoben
-- gilt (0: sofort). Bis dahin zaehlt die Zeit weiter.
local function track(state, seen, key, active, now_ms, clear_ms)
  seen[key] = true
  local entry = state.since[key]
  if active then
    if not entry then
      entry = { since = now_ms }
      state.since[key] = entry
    end
    entry.ok_since = nil
  elseif entry then
    entry.ok_since = entry.ok_since or now_ms
    if now_ms - entry.ok_since >= (clear_ms or 0) then
      state.since[key] = nil
      return nil
    end
  else
    return nil
  end
  return now_ms - entry.since
end

-- input:
--   now_ms         -- Epochenzeit in ms
--   state          -- Reglerzustand (rt2_state.states: MASTER/AUTONOM/SAFE/INIT)
--   learning       -- Einlernen laeuft
--   power_target   -- Sollleistung dieses Takts in RF/t
--   actual_output  -- gemessene Leistung in RF/t (Summe der Turbinen)
--   turbines       -- { { name, target_rpm, rpm, flow_reason }, ... }
-- Gibt eine Liste von Zeilen (Strings) zurueck, leer wenn alles in Ordnung.
function M.update(state, input)
  input = input or {}
  local now_ms = tonumber(input.now_ms) or 0
  local seen = {}
  local lines = {}

  local target = tonumber(input.power_target) or 0
  local actual = tonumber(input.actual_output) or 0
  local low_active = input.state == "MASTER" and input.learning ~= true and target > 0
    and actual < target * M.LOW_OUTPUT_RATIO
  local low_for = track(state, seen, "LOW_OUTPUT", low_active, now_ms, M.LOW_OUTPUT_CLEAR_MS)
  if low_for and low_for >= M.LOW_OUTPUT_MS then
    lines[#lines + 1] = string.format("liefert %d%% vom Soll (%s von %s RF/t) seit %d min",
      math.floor(actual / target * 100 + 0.5), short_rf(actual), short_rf(target), minutes(low_for))
    local hints = 0
    for _, t in ipairs(input.turbines or {}) do
      local rpm, goal = tonumber(t.rpm), tonumber(t.target_rpm) or 0
      if goal > 0 and rpm and rpm < goal - M.BELOW_TARGET_RPM and hints < M.MAX_TURBINE_HINTS then
        hints = hints + 1
        lines[#lines + 1] = string.format("- %s: %d/%d U/min", tostring(t.name), math.floor(rpm), math.floor(goal))
      end
    end
  end

  for _, t in ipairs(input.turbines or {}) do
    local name = tostring(t.name)
    local no_rpm_for = track(state, seen, "NO_RPM|" .. name, tonumber(t.rpm) == nil, now_ms)
    if no_rpm_for and no_rpm_for >= M.NO_RPM_MS then
      lines[#lines + 1] = string.format("Turbine %s: Drehzahl nicht lesbar", name)
    end
    local over_for = track(state, seen, "OVERSPEED|" .. name, t.flow_reason == "OVERSPEED", now_ms)
    if over_for and over_for >= M.OVERSPEED_MS then
      lines[#lines + 1] = string.format("Turbine %s: Ueberdrehzahl %d U/min", name, math.floor(tonumber(t.rpm) or 0))
    end
  end

  -- Zeitpunkte verschwundener Turbinen vergessen.
  for key in pairs(state.since) do
    if not seen[key] then state.since[key] = nil end
  end

  while #lines > M.MAX_LINES do table.remove(lines) end
  return lines
end

return M
