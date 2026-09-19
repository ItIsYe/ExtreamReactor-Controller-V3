package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local adapter = require('nodes.rt.rt2_adapter')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- ── read_turbine ─────────────────────────────────────────────────────────

do
  local r = adapter.read_turbine('T1', { rpm = 900, energy = 120, coil_engaged = true, flow = 4000, active = true })
  assert_eq(r.name, 'T1')
  assert_eq(r.rpm, 900)
  assert_eq(r.energy, 120)
  assert_eq(r.coil_engaged, true)
  assert_eq(r.current_flow, 4000)
  assert_eq(r.active, true)
end

-- adapters/turbine.lua's read_number() returns the string "n/a" for an
-- unavailable/wrong-typed metric, never nil directly -- this must be
-- normalized to nil, not passed through as a bogus rpm value.
do
  local r = adapter.read_turbine('T1', { rpm = 'n/a', energy = 'n/a', coil_engaged = nil, flow = 'n/a' })
  assert_true(r.rpm == nil, 'a non-numeric rpm reading ("n/a") must normalize to nil, not pass through as-is')
  assert_eq(r.energy, 0, 'a non-numeric energy reading must default to 0')
  assert_eq(r.coil_engaged, false, 'a missing coil reading must default to false, never nil')
  assert_eq(r.active, false, 'a missing active reading must default to false, never nil')
end

do
  local r = adapter.read_turbine('T1', nil)
  assert_true(r == nil, 'an inspect() failure (nil info) must propagate as nil, not a half-filled table')
end

-- ── read_reactor ─────────────────────────────────────────────────────────

do
  local r = adapter.read_reactor({ steam_fill_ratio = 0.42, control_rod_level = 55, active = true })
  assert_eq(r.fill_ratio, 0.42)
  assert_eq(r.current_rods, 55)
  assert_eq(r.active, true)
end

do
  local r = adapter.read_reactor({ steam_fill_ratio = nil, control_rod_level = 'n/a' })
  assert_true(r.fill_ratio == nil, 'a missing fill ratio must stay nil, not default to a made-up number')
  assert_true(r.current_rods == nil, 'a non-numeric rod reading must normalize to nil')
  assert_eq(r.active, false, 'a missing active reading must default to false, never nil')
end

-- ── apply_turbine ────────────────────────────────────────────────────────

do
  local calls = {}
  local fake_turbine_adapter = {
    set_flow = function(name, value, log_prefix) calls[#calls + 1] = { fn = 'set_flow', name = name, value = value }; return true end,
    set_coils = function(name, enabled, log_prefix) calls[#calls + 1] = { fn = 'set_coils', name = name, enabled = enabled }; return true end,
  }
  local result = adapter.apply_turbine(fake_turbine_adapter, 'T1', 'RT', {
    flow_decision = { flow = 0, reason = 'OVERSPEED' },
    coil_decision = { engaged = false, reason = 'TARGET_ZERO' },
  })
  assert_eq(#calls, 2, 'both flow and coil must be written when both decisions are present')
  assert_eq(calls[1].fn, 'set_flow'); assert_eq(calls[1].value, 0)
  assert_eq(calls[2].fn, 'set_coils'); assert_eq(calls[2].enabled, false)
  assert_true(result.flow_ok and result.coil_ok, 'both writes must report ok')
end

-- turbine_result.activate = true must call set_active(name, true, ...)
-- when the adapter offers it; a falsy activate must not call it at all.
do
  local set_active_calls = {}
  local fake_turbine_adapter = {
    set_flow = function() return true end,
    set_coils = function() return true end,
    set_active = function(name, enabled, log_prefix) set_active_calls[#set_active_calls + 1] = { name = name, enabled = enabled }; return true end,
  }
  adapter.apply_turbine(fake_turbine_adapter, 'T1', 'RT', {
    flow_decision = { flow = 4000 }, coil_decision = { engaged = true }, activate = true,
  })
  assert_eq(#set_active_calls, 1, 'an activate=true decision must call set_active exactly once')
  assert_eq(set_active_calls[1].name, 'T1'); assert_eq(set_active_calls[1].enabled, true)

  set_active_calls = {}
  adapter.apply_turbine(fake_turbine_adapter, 'T1', 'RT', {
    flow_decision = { flow = 4000 }, coil_decision = { engaged = true }, activate = false,
  })
  assert_eq(#set_active_calls, 0, 'an activate=false decision must not call set_active')
end

-- ── apply_reactor ────────────────────────────────────────────────────────

do
  local seen = nil
  local fake_reactor_adapter = {
    apply_rod_level = function(name, level, log_prefix) seen = { name = name, level = level }; return true end,
  }
  local result = adapter.apply_reactor(fake_reactor_adapter, 'R1', 'RT', { rods = 100, reason = 'SAFETY_FULL_INSERT' })
  assert_eq(seen.name, 'R1'); assert_eq(seen.level, 100)
  assert_true(result.ok, 'apply_reactor must report the underlying write result')
end

-- reactor_decision.activate = true must call set_active(name, true, ...)
-- when the adapter offers it; a falsy activate must not call it at all.
do
  local set_active_calls = {}
  local fake_reactor_adapter = {
    apply_rod_level = function() return true end,
    set_active = function(name, enabled, log_prefix) set_active_calls[#set_active_calls + 1] = { name = name, enabled = enabled }; return true end,
  }
  adapter.apply_reactor(fake_reactor_adapter, 'R1', 'RT', { rods = 100, activate = true })
  assert_eq(#set_active_calls, 1, 'an activate=true decision must call set_active exactly once')
  assert_eq(set_active_calls[1].name, 'R1'); assert_eq(set_active_calls[1].enabled, true)

  set_active_calls = {}
  adapter.apply_reactor(fake_reactor_adapter, 'R1', 'RT', { rods = 100, activate = false })
  assert_eq(#set_active_calls, 0, 'an activate=false decision must not call set_active')
end

print('rt2_adapter_test.lua: ok')
