package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_engine = require('nodes.rt.rt2_engine')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Fake adapters standing in for adapters/turbine.lua / adapters/reactor.lua --
-- plain functions, no CC:Tweaked globals, matching the dependency-
-- injection style rt2_adapter_test.lua already established.
local turbine_hardware = {
  T1 = { rpm = 900, energy = 100, coil_engaged = true, flow = 4000 },
}
local reactor_hardware = {
  R1 = { steam_fill_ratio = 0.5, control_rod_level = 50 },
}
local applied_flow, applied_coil, applied_rods = {}, {}, nil

local fake_ctx = {
  config = { turbines = { 'T1' }, reactors = { 'R1' } },
  CONFIG = { LOG_PREFIX = 'RT' },
  adapters = {
    turbine = {
      inspect = function(name) return turbine_hardware[name] end,
      set_flow = function(name, value) applied_flow[name] = value; return true end,
      set_coils = function(name, engaged) applied_coil[name] = engaged; return true end,
    },
    reactor = {
      inspect = function(name) return reactor_hardware[name] end,
      apply_rod_level = function(name, level) applied_rods = level; return true end,
    },
  },
}

rt2_engine.init({})

-- A tick before capacity is learned must run LEARNING, targeting the
-- fixed RPM and writing that target through to the fake hardware.
local result = rt2_engine.tick(fake_ctx)
assert_eq(result.state, rt2_state.states.LEARNING, 'first tick with fresh hardware must enter LEARNING')
assert_eq(result.turbines[1].target_rpm, 900, 'LEARNING targets the fixed RPM')
-- T1 is already at 900/coil engaged -- inside the band, so flow holds
-- near its current reading rather than the readout getting clobbered.
assert_true(applied_flow.T1 ~= nil, 'the flow decision must have been written to the fake turbine adapter')
assert_true(applied_coil.T1 == true, 'the coil decision must have been written to the fake turbine adapter')
assert_true(applied_rods ~= nil, 'the rod decision must have been written to the fake reactor adapter')

-- status_fields() must reflect the last tick without re-reading hardware.
local fields = rt2_engine.status_fields()
assert_eq(fields.mode, result.state)
assert_eq(fields.turbines[1].id, 'T1')

-- handle_command() must reach the underlying orchestrator and its
-- effects must show up on the next tick.
local ack = rt2_engine.handle_command({ target = 'SCRAM' })
assert_true(ack.ok, 'SCRAM must be accepted through the engine facade')
result = rt2_engine.tick(fake_ctx)
assert_eq(result.state, rt2_state.states.SAFE, 'a SCRAM issued through the engine facade must force SAFE on the next tick')
assert_eq(applied_rods, 100, 'SAFE must have written full rod insertion to the fake reactor adapter')

print('rt2_engine_test.lua: ok')
