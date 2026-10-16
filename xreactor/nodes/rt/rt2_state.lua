-- RT rewrite, step 1: a single state machine for the RT node.
--
-- Replaces the two parallel systems from the old implementation
-- (ctx.STATE MASTER/AUTONOM/SAFE/INIT, and a separate node_state_machine
-- OFF/STARTUP/RUNNING/LIMITED/AUTONOM/MANUAL/EMERGENCY) that repeatedly
-- caused bugs this project hit in production: a command_handler check
-- against ctx.STATE could pass while node_state_machine disagreed, a
-- MASTER-vs-AUTONOM desync could go undetected because nothing looked at
-- both, etc. There is now exactly one state, exactly one place that
-- decides the next state, and exactly one thing every other module reads.
--
-- Vorgabe (bestaetigt): der Knoten LERNT NICHTS MEHR. Es gab einen
-- Zustand LEARNING, in dem eine Kapazitaetsmessung lief, bevor der Knoten
-- ueberhaupt auf MASTER hoerte -- mit eigenem Suchlauf, eigener
-- Zwischendatei und einer Menge Wege, auf denen er haengenbleiben konnte.
-- Geregelt wird jetzt schlicht auf Drehzahl gegen Drehzahlvorgabe, und
-- dafuer muss nichts vermessen werden.
--
-- Damit bleiben:
--   1. Sobald Hardware da ist, arbeitet der Knoten. Ist ein MASTER
--      verbunden, folgen die Turbinenvorgaben dessen Leistungsvorgabe;
--      ist keiner da (AUTONOM), fahren alle Turbinen die feste Drehzahl
--      und der REAKTOR regelt sich aus seinem Dampftank (rt2_reactor.lua).
--   2. Eine Sicherheitsausloesung gewinnt immer, aus jedem Zustand, und
--      die Erholung geht direkt zurueck nach MASTER oder AUTONOM.

local M = {}

M.states = {
  INIT    = "INIT",    -- boot, hardware not yet discovered/confirmed
  MASTER  = "MASTER",  -- MASTER connected and driving setpoints
  AUTONOM = "AUTONOM", -- no MASTER; steam-tank-driven reactor control
  SAFE    = "SAFE",    -- safety trip; rods full insertion, turbines flow-zeroed
}

local VALID_STATES = {}
for _, name in pairs(M.states) do VALID_STATES[name] = true end

-- Pure decision function: given the current state and the world's inputs,
-- what should the next state be? No I/O, no side effects -- this is what
-- makes every transition in this module testable with plain tables, the
-- same way core/control_rails.lua's decisions are tested.
--
-- inputs:
--   hardware_ready    -- discovery has found at least one reactor+turbine
--   master_connected  -- comms peer-liveness for the MASTER role
--   safety_tripped    -- true while ANY active safety condition holds
--                         (temperature limit, coolant low, etc.)
function M.decide_next_state(current, inputs)
  inputs = inputs or {}

  if inputs.safety_tripped then
    return M.states.SAFE
  end

  if current == M.states.INIT and not inputs.hardware_ready then
    return M.states.INIT
  end

  -- INIT (mit Hardware), SAFE-Erholung und der laufende Betrieb landen
  -- alle bei derselben Frage -- es gibt keinen Zwischenzustand mehr:
  -- haengt ein MASTER dran oder nicht?
  --
  -- Keine Hysterese noetig: comms.lua's Lebendigkeitspruefung (Entprellung
  -- und Nachlauf) glaettet das Signal, bevor es hier ankommt.
  if inputs.master_connected then
    return M.states.MASTER
  end
  return M.states.AUTONOM
end

function M.new(initial)
  local state = VALID_STATES[initial] and initial or M.states.INIT
  local self = {
    _state = state,
    _history = {},
  }

  function self.current()
    return self._state
  end

  -- Advances the machine by one tick's worth of inputs. Returns
  -- (new_state, changed, previous_state) so callers can log/act on a
  -- transition without re-deriving it.
  function self.tick(inputs)
    local previous = self._state
    local next_state = M.decide_next_state(previous, inputs)
    if not VALID_STATES[next_state] then
      next_state = previous
    end
    self._state = next_state
    if next_state ~= previous then
      self._history[#self._history + 1] = { from = previous, to = next_state }
    end
    return next_state, next_state ~= previous, previous
  end

  function self.history()
    return self._history
  end

  return self
end

return M
