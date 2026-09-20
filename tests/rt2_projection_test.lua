package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local projection = require('nodes.rt.rt2_projection')
local rt2_state = require('nodes.rt.rt2_state')
local constants = require('shared.constants')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- ── node_state ───────────────────────────────────────────────────────────
--
-- Every projected node state must be one the node_state_machine actually
-- knows (shared/constants.lua) -- MASTER and the UI branch on these, and an
-- unknown value would silently fall through every branch.
do
  for _, state in pairs(rt2_state.states) do
    local projected = projection.node_state(state)
    assert_true(constants.node_states[projected] ~= nil,
      'projected node state must exist in constants.node_states: ' .. tostring(state) .. ' -> ' .. tostring(projected))
  end
  assert_eq(projection.node_state(rt2_state.states.MASTER), 'RUNNING')
  assert_eq(projection.node_state(rt2_state.states.AUTONOM), 'AUTONOM')
  assert_eq(projection.node_state(rt2_state.states.LEARNING), 'STARTUP')
  assert_eq(projection.node_state(rt2_state.states.INIT), 'STARTUP')
  assert_eq(projection.node_state(rt2_state.states.SAFE), 'EMERGENCY')
end

-- ── turbine_state ────────────────────────────────────────────────────────

do
  -- On target with the coil engaged -> STABLE. This is the one MASTER's
  -- startup sequencer waits for, so getting it wrong stalls MASTER.
  assert_eq(projection.turbine_state({ target_rpm = 900, rpm = 900, coil_engaged = true }, rt2_state.states.MASTER), 'STABLE')
  -- Still ramping -> STARTING, never STABLE.
  assert_eq(projection.turbine_state({ target_rpm = 900, rpm = 400, coil_engaged = false }, rt2_state.states.MASTER), 'STARTING')
  -- At speed but coil not engaged yet -> not yet STABLE (it produces nothing).
  assert_eq(projection.turbine_state({ target_rpm = 900, rpm = 900, coil_engaged = false }, rt2_state.states.MASTER), 'STARTING')
  -- Deliberately parked AUS slot -> OFF, not ERROR (nothing is wrong with it).
  assert_eq(projection.turbine_state({ target_rpm = 0, rpm = 120, coil_engaged = false }, rt2_state.states.MASTER), 'OFF')
  -- A safety trip must mark every turbine ERROR regardless of its readings.
  assert_eq(projection.turbine_state({ target_rpm = 900, rpm = 900, coil_engaged = true }, rt2_state.states.SAFE), 'ERROR')
end

-- ── turbine_progress ─────────────────────────────────────────────────────

do
  assert_eq(projection.turbine_progress({ target_rpm = 900, rpm = 450 }), 50)
  assert_eq(projection.turbine_progress({ target_rpm = 900, rpm = 0 }), 0)
  assert_eq(projection.turbine_progress({ target_rpm = 900, rpm = 1800 }), 100, 'progress must clamp at 100')
  assert_eq(projection.turbine_progress({ target_rpm = 0, rpm = 500 }), 0, 'a parked turbine has no ramp progress')
end

-- ── reactor_state ────────────────────────────────────────────────────────

do
  assert_eq(projection.reactor_state({ active = true }, rt2_state.states.MASTER), 'STABLE')
  assert_eq(projection.reactor_state({ active = true }, rt2_state.states.LEARNING), 'STARTING')
  assert_eq(projection.reactor_state({ active = false }, rt2_state.states.MASTER), 'OFF')
  assert_eq(projection.reactor_state({ active = true }, rt2_state.states.SAFE), 'ERROR')
  assert_eq(projection.reactor_state(nil, rt2_state.states.MASTER), 'OFF', 'a missing reactor reading must not read as healthy')
end

-- ── project ──────────────────────────────────────────────────────────────

do
  local modules = {
    ['turbine:1'] = { id = 'turbine:1', type = 'turbine', name = 'T1', state = 'OFF', progress = 0 },
    ['turbine:2'] = { id = 'turbine:2', type = 'turbine', name = 'T2', state = 'OFF', progress = 0 },
    ['reactor:1'] = { id = 'reactor:1', type = 'reactor', name = 'R1', state = 'OFF', progress = 0 },
  }
  local result = {
    state = rt2_state.states.MASTER,
    turbines = {
      { name = 'T1', target_rpm = 900, rpm = 900, coil_engaged = true },
      { name = 'T2', target_rpm = 900, rpm = 300, coil_engaged = false },
    },
  }
  local out = projection.project(result, modules, { active = true })
  assert_eq(out.node_state, 'RUNNING')
  assert_eq(out.modules['turbine:1'].state, 'STABLE')
  assert_eq(out.modules['turbine:2'].state, 'STARTING')
  assert_eq(out.modules['reactor:1'].state, 'STABLE')
  -- project() must stay pure: the registry it was handed is untouched.
  assert_eq(modules['turbine:1'].state, 'OFF', 'project() must not mutate the registry it reads')
end

-- A registry turbine that produced no decision this tick (peripheral gone)
-- must be reported OFF rather than silently keeping a stale healthy state.
do
  local modules = {
    ['turbine:9'] = { id = 'turbine:9', type = 'turbine', name = 'T9', state = 'STABLE', progress = 100 },
  }
  local out = projection.project({ state = rt2_state.states.MASTER, turbines = {} }, modules, { active = true })
  assert_eq(out.modules['turbine:9'].state, 'OFF', 'a turbine with no decision this tick must not stay STABLE')
end

print('rt2_projection_test.lua: ok')
