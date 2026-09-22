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
-- Required behaviour (explicit product spec):
--   1. On boot the node ALWAYS learns its turbine capacity first --
--      completely independent of whether a MASTER is present. Reactor and
--      turbines ramp to the fixed target RPM (900) during this phase.
--   2. Once learning is complete, the node checks whether a MASTER is
--      connected:
--        - MASTER present  -> turbine RPM targets follow MASTER's
--          requested power split (VOLLAST/PUFFER/AUS).
--        - MASTER absent   -> AUTONOM: turbines still target the fixed
--          RPM, but the REACTOR regulates independently from the internal
--          steam tank fill level (see rt2_reactor.lua) instead of a
--          MASTER-driven percentage.
--   3. A safety trip (temperature/coolant) always wins, from any state,
--      and recovery returns to MASTER or AUTONOM directly (capacity is
--      already known -- no need to relearn).

local M = {}

M.states = {
  INIT     = "INIT",     -- boot, hardware not yet discovered/confirmed
  LEARNING = "LEARNING", -- capacity not yet known; reactor+turbines ramp to fixed target RPM
  MASTER   = "MASTER",   -- capacity known, MASTER connected and driving setpoints
  AUTONOM  = "AUTONOM",  -- capacity known, no MASTER; steam-tank-driven reactor control
  SAFE     = "SAFE",     -- safety trip; rods full insertion, turbines flow-zeroed
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
--   capacity_ready    -- capacity_learning.ready == true
--   master_connected  -- comms peer-liveness for the MASTER role
--   safety_tripped    -- true while ANY active safety condition holds
--                         (temperature limit, coolant low, etc.)
function M.decide_next_state(current, inputs)
  inputs = inputs or {}

  if inputs.safety_tripped then
    return M.states.SAFE
  end

  if current == M.states.INIT then
    if inputs.hardware_ready then
      return M.states.LEARNING
    end
    return M.states.INIT
  end

  if current == M.states.LEARNING then
    if not inputs.capacity_ready then
      return M.states.LEARNING
    end
    if inputs.master_connected then
      return M.states.MASTER
    end
    return M.states.AUTONOM
  end

  if current == M.states.SAFE then
    -- Recovery: safety_tripped is already false here (checked above), so
    -- it is safe to leave SAFE.
    --
    -- A trip that happened DURING the learning phase leaves capacity
    -- unlearned -- going straight to MASTER/AUTONOM there would run the
    -- node on a capacity_max of 0 (MASTER would split power against a
    -- capacity it never measured). Rule 1 of the spec is that learning
    -- always completes first, so an unlearned node resumes LEARNING.
    if not inputs.capacity_ready then
      return M.states.LEARNING
    end
    if inputs.master_connected then
      return M.states.MASTER
    end
    return M.states.AUTONOM
  end

  -- MASTER <-> AUTONOM: a live decision every tick, purely driven by
  -- current MASTER connectivity. No hysteresis needed here -- comms.lua's
  -- own peer-liveness tracking (debounce/grace) already smooths this
  -- signal before it reaches this function.
  if current == M.states.MASTER or current == M.states.AUTONOM then
    if inputs.master_connected then
      return M.states.MASTER
    end
    return M.states.AUTONOM
  end

  return current
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
