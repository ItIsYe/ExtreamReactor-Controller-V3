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

local rt2_turbine = require("nodes.rt.rt2_turbine")

local M = {}

M.TARGET_RPM = 900
M.TOLERANCE_RPM = 15
M.SAFETY_MARGIN = 0.05 -- store max_output as 95% of the measured peak

-- Gestaffeltes Einlernen.
--
-- WARUM: Die alte Messung verlangte, dass 80 % der Flotte GLEICHZEITIG auf
-- Zieldrehzahl stehen, und rechnete daraus mit
--     (Summe Ausstoss / am Ziel) * GESAMTZAHL
-- auf die ganze Flotte hoch. Beides setzt voraus, dass grundsaetzlich alle
-- Turbinen zugleich auf Ziel laufen KOENNTEN. Auf einer dampfbegrenzten
-- Anlage ist das falsch, und zwar doppelt:
--   1. Traegt der Reaktor nur 19 von 25, wird die 80-%-Schwelle nie
--      erreicht -- der Knoten lernt nie fertig, egal wie lange er laeuft.
--   2. Wuerde sie erreicht, stuende trotzdem eine erfundene Zahl drin:
--      bei 6 tragbaren von 25 das Vierfache dessen, was die Anlage je
--      liefern kann.
--
-- Deshalb wird jetzt nicht mehr hochgerechnet, sondern GESUCHT: Der Knoten
-- gibt eine Turbine nach der anderen frei und schaut, ob die bereits
-- laufenden ihre Drehzahl halten. Die groesste Stufe, die sich stabil
-- halten laesst, IST die tragbare Anzahl -- und der dabei gemessene
-- Gesamtausstoss IST die Kapazitaet. Beides gemessen, nichts geschaetzt.
M.SETTLE_MS = 4000     -- so lange muss eine Stufe durchgehend tragen, bevor sie zaehlt
M.STEP_TIMEOUT_MS = 30000 -- schafft eine Stufe das nicht, ist die Grenze erreicht
M.START_COUNT = 1

local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

function M.new_state()
  return {
    ready = false,
    max_output = 0,
    -- Wieviele Turbinen diese Anlage nachweislich gleichzeitig auf
    -- Zieldrehzahl halten kann. Deckelt spaeter auch die MASTER-Aufteilung
    -- (rt2_turbine.compute_target_rpm's max_active) -- sonst bedeutete
    -- "100 %" wieder "alle Turbinen", was die Anlage nicht kann.
    sustainable_turbines = 0,
    -- Die Stufe, die der Suchlauf gerade prueft.
    released = M.START_COUNT,
    at_target = 0,
    saturated = 0,
    total_turbines = 0,
    reason = "INIT",
    step_started_ms = nil,
    stable_since_ms = nil,
  }
end

-- A turbine whose flow setting is already pegged at (or just under) the
-- mod's hard limit and which STILL cannot reach the target speed is
-- saturated: no controller action left to take. Either the reactor cannot
-- supply that much steam, or the coil load at this target exceeds what the
-- turbine can carry. Counting these separately is what turns an invisible
-- hang into a diagnosable condition -- see M.update()'s FLOW_SATURATED.
M.SATURATION_FRACTION = 0.95

-- Misst NUR die freigegebenen Turbinen (die ersten `released` der Liste --
-- dieselbe Reihenfolge, nach der rt2_turbine sie ueber slot_index
-- freigibt). Eine noch gar nicht freigegebene Turbine steht absichtlich
-- still und darf die Messung weder verwaessern noch als "gesaettigt"
-- zaehlen.
local function measure(turbines, released)
  local total = #(turbines or {})
  if total == 0 then return 0, 0, 0, 0 end
  local max_flow = rt2_turbine.MAX_FLOW
  local checked = math.min(released or total, total)
  local at_target, output, saturated = 0, 0, 0
  for index = 1, checked do
    local t = turbines[index]
    local rpm = tonumber(t.rpm)
    local energy = tonumber(t.energy) or 0
    if rpm and t.coil_engaged ~= false
        and math.abs(rpm - M.TARGET_RPM) <= M.TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      output = output + energy
    elseif rpm and rpm < M.TARGET_RPM - M.TOLERANCE_RPM then
      local flow = tonumber(t.current_flow)
      if flow and flow >= max_flow * M.SATURATION_FRACTION then
        saturated = saturated + 1
      end
    end
  end
  return output, at_target, total, saturated
end

-- previous: a state table from M.new_state()/a prior M.update() call.
-- turbines: array of { rpm, energy, coil_engaged, current_flow }, in the
--           SAME order rt2_turbine assigns slot_index -- the first
--           `state.released` entries are the ones allowed to run.
-- opts.now_ms: the clock. The search needs it to tell "this step is still
--           spinning up" from "this step cannot be held".
--
-- Returns a NEW state table (copy-on-write, same discipline as before).
function M.update(previous, turbines, opts)
  local state = copy(previous or M.new_state())
  opts = type(opts) == "table" and opts or {}
  local now_ms = tonumber(opts.now_ms) or 0
  local total = #(turbines or {})

  -- Gar keine Turbinen gelesen ist KEIN Umbau, sondern eine fehlende
  -- Messung -- ein Discovery-Aussetzer, ein Peripheral-Hickser. Frueher
  -- lief das in denselben Zweig wie eine geaenderte Anzahl und haette
  -- damit die gelernte Anlage weggeworfen; seit das Einlernen ein
  -- minutenlanger Suchlauf ist, waere das richtig teuer. Also: melden,
  -- nichts anfassen.
  if total == 0 then
    state.at_target, state.saturated = 0, 0
    state.reason = "NO_TURBINES"
    return state
  end

  if total ~= state.total_turbines then
    -- Turbine COUNT changed: the only signal this module trusts as a real
    -- hardware change. A rename-only reshuffle (same count) never reaches
    -- this branch, so it can never invalidate a learned value the way the
    -- old identity-signature cache did. The search restarts from the
    -- bottom, because a changed fleet may well carry a different number.
    state.ready = false
    state.max_output = 0
    state.sustainable_turbines = 0
    state.released = M.START_COUNT
    state.step_started_ms = nil
    state.stable_since_ms = nil
    state.total_turbines = total
    state.reason = "TOPOLOGY_CHANGED"
    return state
  end

  -- Fertig gesucht: nur noch beobachten, nichts mehr verstellen.
  if state.ready then
    -- Hier ueber die GANZE Flotte messen, nicht nur ueber die tragbare
    -- Anzahl: im Betrieb ist at_target eine Diagnose ("wieviele laufen
    -- gerade rund"), und unter MASTER bestimmt die Rotation ohnehin,
    -- welche das sind.
    local output, at_target, _, saturated = measure(turbines, nil)
    state.at_target, state.saturated = at_target, saturated
    state.reason = "STABLE"
    local _ = output
    return state
  end

  state.released = math.max(1, math.min(state.released or M.START_COUNT, total))
  if not state.step_started_ms then state.step_started_ms = now_ms end

  local output, at_target, _, saturated = measure(turbines, state.released)
  state.at_target, state.saturated = at_target, saturated

  if at_target >= state.released then
    -- Diese Stufe traegt gerade. Sie muss es aber DURCHGEHEND tun --
    -- ein kurzer Durchgang durch das Messfenster beim Hochlaufen ist
    -- keine tragfaehige Stufe.
    if not state.stable_since_ms then state.stable_since_ms = now_ms end
    if now_ms - state.stable_since_ms >= M.SETTLE_MS then
      state.sustainable_turbines = state.released
      state.max_output = output * (1 - M.SAFETY_MARGIN)
      if state.released >= total then
        state.ready = true
        state.reason = "ALL_SUSTAINED"
      else
        state.released = state.released + 1
        state.step_started_ms = now_ms
        state.stable_since_ms = nil
        state.reason = "STEP_UP"
      end
    else
      state.reason = "SETTLING"
    end
    return state
  end

  -- Diese Stufe traegt (noch) nicht.
  state.stable_since_ms = nil
  if now_ms - state.step_started_ms >= M.STEP_TIMEOUT_MS then
    if state.sustainable_turbines > 0 then
      -- Die vorherige Stufe war die groesste tragbare -- das IST das
      -- Ergebnis, kein Fehlschlag. Der Knoten kennt jetzt seine Anlage.
      state.ready = true
      state.released = state.sustainable_turbines
      state.reason = "LIMIT_FOUND"
    else
      -- Nicht einmal eine einzige Turbine laesst sich halten. Das ist
      -- nichts, was sich durch Warten oder Regeln loesen laesst, also
      -- wird hier auch nichts "gelernt" -- der Knoten bleibt im
      -- Einlernen und meldet es.
      state.reason = "NO_STEAM"
      state.step_started_ms = now_ms
    end
    return state
  end

  state.reason = saturated > 0 and "FLOW_SATURATED" or "SPINNING_UP"
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
    -- Ohne diese Zahl waere der ganze Suchlauf bei jedem Neustart
    -- umsonst: sie deckelt im Betrieb, wieviele Turbinen laufen duerfen.
    sustainable_turbines = tonumber(state.sustainable_turbines) or 0,
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
  local sustainable = tonumber(data.sustainable_turbines)
  if not sustainable or sustainable <= 0 then
    -- Aelterer Cache (vor dem gestaffelten Einlernen): er enthaelt nur
    -- eine hochgerechnete Kapazitaet und keine tragbare Anzahl. Dieser
    -- Wert ist auf einer dampfbegrenzten Anlage um ein Vielfaches zu
    -- hoch, also wird er verworfen statt uebernommen -- lieber einmal
    -- neu suchen als dauerhaft gegen eine erfundene Zahl regeln.
    return nil, "alter Cache ohne gemessene Turbinenzahl -- wird neu eingelernt"
  end
  local state = M.new_state()
  state.ready = true
  state.max_output = data.max_output
  state.total_turbines = data.turbine_count
  state.sustainable_turbines = math.min(sustainable, data.turbine_count or sustainable)
  state.released = state.sustainable_turbines
  state.reason = "LOADED_FROM_CACHE"
  return state
end

return M
