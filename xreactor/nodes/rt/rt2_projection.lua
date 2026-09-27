-- RT: projiziert den Zustand des Reglers auf das Vokabular, das der Rest
-- des Systems schon liest.
--
-- WARUM DAS EXISTIERT: rt2_state/rt2_turbine entscheiden in ihren eigenen
-- Begriffen (LEARNING/MASTER/AUTONOM/SAFE, Flow-Entscheidungen). Alles
-- danach liest aeltere Felder:
--   - status_snapshot.build_module_payload() schickt module.state an MASTER
--   - build_turbine_snapshots()/build_reactor_snapshots() haengen ihn je
--     Geraet an
--   - MASTERs message_handlers.lua zaehlt state=="RUNNING"/"STABLE", und
--     sein Startup-Sequencer WARTET auf state=="STABLE", bevor er weiterlaeuft
--   - payload.state trug frueher den Zustand einer Zustandsmaschine
-- Ohne diese Uebersetzung blieb all das auf seinem Bootwert stehen ("OFF"
-- fuer jedes Modul): eine korrekt regelnde Node sah fuer den Betreiber und
-- fuer MASTER vollstaendig toter aus als sie war, und MASTERs Sequencer
-- haette ewig gewartet.
--
-- Bewusst eine PROJEKTION, keine zweite Zustandsmaschine: dieses Modul
-- haelt keinen eigenen Zustand und entscheidet nie etwas -- es uebersetzt
-- nur. Damit bleibt "genau ein Zustand, genau eine Stelle, die ihn
-- entscheidet" erhalten, und das ist der Grund, warum es diesen Regler gibt.
--
-- Historische Notiz: bis v768 gab es daneben noch v1s Modul-Lebenszyklus und
-- eine Knoten-Zustandsmaschine, die genau diese Felder selbst pflegten. Die
-- Projektion durfte sie deshalb NICHT antreiben -- deren Uebergaenge loesten
-- echte v1-Regelarbeit aus, und zwei Regler an derselben Hardware sind das
-- Problem, das dieser Umbau beseitigt hat. v1 ist entfernt; die Projektion
-- ist seitdem die einzige Quelle dieser Felder.

local rt2_state = require("nodes.rt.rt2_state")
local rt2_turbine = require("nodes.rt.rt2_turbine")

local M = {}

-- rt2_state -> shared/constants.lua's node_states (what payload.state carries).
-- SAFE maps to EMERGENCY because that is the only "safety tripped" value
-- the existing node_states vocabulary has, and it is what MASTER's alerting
-- already understands.
M.NODE_STATE = {
  INIT     = "STARTUP",
  LEARNING = "STARTUP",
  MASTER   = "RUNNING",
  AUTONOM  = "AUTONOM",
  SAFE     = "EMERGENCY",
}

-- Module states use v1's module vocabulary (OFF/STARTING/STABLE/ERROR),
-- because that is what MASTER and the UI already branch on.
M.MODULE = {
  OFF      = "OFF",
  STARTING = "STARTING",
  STABLE   = "STABLE",
  ERROR    = "ERROR",
}

function M.node_state(state)
  return M.NODE_STATE[state] or "STARTUP"
end

-- One turbine's module state from its own decision entry.
--   SAFE            -> ERROR    (tripped, flow forced to zero)
--   target_rpm <= 0 -> OFF      (deliberately parked AUS slot)
--   at target       -> STABLE   (coil engaged AND rpm inside the band)
--   otherwise       -> STARTING (still ramping toward target)
function M.turbine_state(turbine_result, node_state)
  if node_state == rt2_state.states.SAFE then return M.MODULE.ERROR end
  local target_rpm = tonumber(turbine_result and turbine_result.target_rpm) or 0
  if target_rpm <= 0 then return M.MODULE.OFF end
  local rpm = tonumber(turbine_result and turbine_result.rpm)
  local engaged = turbine_result and turbine_result.coil_engaged == true
  if engaged and rpm and math.abs(rpm - target_rpm) <= rt2_turbine.RPM_BAND then
    return M.MODULE.STABLE
  end
  return M.MODULE.STARTING
end

-- How far this turbine has ramped toward its target, 0..100 -- feeds the
-- UI's ramp display (module.progress).
function M.turbine_progress(turbine_result)
  local target_rpm = tonumber(turbine_result and turbine_result.target_rpm) or 0
  if target_rpm <= 0 then return 0 end
  local rpm = tonumber(turbine_result and turbine_result.rpm) or 0
  local pct = (rpm / target_rpm) * 100
  if pct < 0 then return 0 end
  if pct > 100 then return 100 end
  return math.floor(pct + 0.5)
end

-- tripped: dieser EINE Reaktor hat ausgeloest. Bei mehreren Reaktoren am
-- Knoten faehrt nur er ein, waehrend die uebrigen weiterlaufen -- dann
-- darf auch nur SEIN Modul als gestoert gemeldet werden.
function M.reactor_state(reactor_reading, node_state, tripped)
  if node_state == rt2_state.states.SAFE or tripped then return M.MODULE.ERROR end
  if not (reactor_reading and reactor_reading.active == true) then return M.MODULE.OFF end
  if node_state == rt2_state.states.INIT or node_state == rt2_state.states.LEARNING then
    return M.MODULE.STARTING
  end
  return M.MODULE.STABLE
end

-- Pure projection of one tick onto module states.
--
-- result:  rt2_orchestrator.tick()'s return value
-- modules: modules_registry ({ [id] = { id, type, name, state, progress } })
-- reactor_reading: the reactor reading this tick (for its active flag)
--
-- Returns { node_state = <node_states value>, modules = { [id] = {state, progress} } }
-- -- a plain table; applying it to the live registry is the caller's job
-- (see rt2_engine.apply_projection), which keeps this function testable
-- without any live registry.
-- reactor_readings: entweder EIN Messwert (Ein-Reaktor-Fall, unveraendert)
-- oder { [name] = { reading = ..., tripped = bool } } fuer mehrere.
function M.project(result, modules, reactor_readings)
  local node_state = result and result.state or rt2_state.states.INIT
  local by_name = {}
  for _, t in ipairs((result and result.turbines) or {}) do
    if t.name then by_name[t.name] = t end
  end

  -- Mehrere Reaktoren kommen namentlich herein, ein einzelner unveraendert
  -- als schlichter Messwert.
  local by_reactor, single_reading = {}, nil
  if type(reactor_readings) == "table" and reactor_readings.by_name then
    by_reactor = reactor_readings.by_name
  else
    single_reading = reactor_readings
  end

  local projected = {}
  for id, module in pairs(modules or {}) do
    if module.type == "turbine" then
      local t = by_name[module.name]
      -- A turbine the registry knows but this tick produced no decision
      -- for (peripheral missing/unreadable) must not silently keep a
      -- stale STABLE -- report it as OFF rather than as healthy.
      if t then
        projected[id] = { state = M.turbine_state(t, node_state), progress = M.turbine_progress(t) }
      else
        projected[id] = { state = M.MODULE.OFF, progress = 0 }
      end
    elseif module.type == "reactor" then
      -- Jeder Reaktor wird nach SEINEM eigenen Messwert beurteilt. Vorher
      -- bekamen bei zwei Reaktoren beide Module den Zustand des ersten --
      -- ein ausgeloester zweiter waere weiter als STABLE gemeldet worden.
      local entry = by_reactor[module.name]
      if entry then
        projected[id] = {
          state = M.reactor_state(entry.reading, node_state, entry.tripped), progress = 0,
        }
      else
        projected[id] = { state = M.reactor_state(single_reading, node_state), progress = 0 }
      end
    end
  end

  return { node_state = M.node_state(node_state), modules = projected }
end

return M
