package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local function turbine(name, rpm, energy, coil_engaged, current_flow)
  return { name = name, rpm = rpm, energy = energy, coil_engaged = coil_engaged, current_flow = current_flow or 0 }
end

-- End-to-end spec check: boot -> LEARNING runs unconditionally, even with
-- a MASTER already connected -- capacity readiness is what gates the
-- exit, not MASTER presence.
do
  local o = orchestrator.new()
  o.note_master_seen(0) -- MASTER connected from tick 1 onward

  local result = o.tick({
    now_ms = 1000, hardware_ready = true,
    turbines = { turbine('T1', 100, 0, false), turbine('T2', 100, 0, false) },
    reactor = { fill_ratio = 0.5 },
  })
  assert_eq(result.state, rt2_state.states.LEARNING, 'must enter LEARNING on first tick with hardware, regardless of MASTER')

  -- Turbines not yet at target -> both still targeting the fixed RPM,
  -- capacity not yet ready.
  for _, t in ipairs(result.turbines) do
    assert_eq(t.target_rpm, 900, 'LEARNING must target the fixed RPM for every turbine')
  end
  assert_true(not result.capacity.ready, 'capacity must not be ready before turbines reach target')

  -- Turbines now at target -> capacity becomes ready, and because MASTER
  -- is connected, the very next tick must move straight to MASTER (per
  -- spec: "wenn das fertig ist, schauen ob master da ist").
  result = o.tick({
    now_ms = 2000, hardware_ready = true,
    turbines = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) },
    reactor = { fill_ratio = 0.5 },
  })
  assert_true(result.capacity.ready, 'capacity must become ready once turbines settle at target RPM')
  assert_eq(result.state, rt2_state.states.MASTER, 'learning complete with MASTER connected must move straight to MASTER')
end

-- Same boot sequence but with NO MASTER at all -> must still learn (spec
-- point 1: unabhaengig vom Master), then land in AUTONOM.
do
  local o = orchestrator.new()
  -- never call note_master_seen()

  local result = o.tick({
    now_ms = 1000, hardware_ready = true,
    turbines = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) },
    reactor = { fill_ratio = 0.5 },
  })
  assert_eq(result.state, rt2_state.states.LEARNING, 'learning must still happen with no MASTER present at all')
  assert_true(result.capacity.ready, 'a turbine fleet already at target learns capacity on the very first tick')

  result = o.tick({
    now_ms = 2000, hardware_ready = true,
    turbines = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) },
    reactor = { fill_ratio = 0.5 },
  })
  assert_eq(result.state, rt2_state.states.AUTONOM, 'learning complete with no MASTER must land in AUTONOM')
  for _, t in ipairs(result.turbines) do
    assert_eq(t.target_rpm, 900, 'AUTONOM turbines still target the fixed RPM (the reactor is what regulates independently)')
  end
end

-- The regression that started this rewrite: a turbine assigned to the
-- AUS slot under MASTER control, still spinning at thousands of RPM
-- (residual momentum), must be forced to flow=0 THIS tick -- not ramped
-- down over many ticks, and without needing to engage its coil.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  -- Warm up into MASTER: two ticks of a settled, at-target fleet.
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) }, reactor = {} })
  local warm = o.tick({ now_ms = 2000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) }, reactor = {} })
  assert_eq(warm.state, rt2_state.states.MASTER)

  -- MASTER now asks for 50% with T1 landing in the AUS slot (rotation
  -- offset is 0 at this point, so slot 1 = turbine 1 = the AUS slot at 50%/2).
  local result = o.tick({
    now_ms = 3000, hardware_ready = true, master_percent = 50,
    turbines = { turbine('T1', 2000, 100, true, 20000), turbine('T2', 900, 100, true, 20000) },
    reactor = {},
  })
  local t1 = result.turbines[1]
  assert_eq(t1.target_rpm, 0, 'sanity: T1 must be the AUS-slot turbine at 50%/2 turbines')
  assert_eq(t1.flow_decision.flow, 0, 'an AUS-slot turbine massively overspeeding must be forced to flow=0 this very tick')
  assert_eq(t1.coil_decision.engaged, false, 'an AUS-slot turbine must never have its coil engaged')
end

-- AUTONOM reactor regulation: purely steam-tank driven, MASTER's percent
-- (if any leaked through) must have zero effect on the rod decision.
do
  local o = orchestrator.new()
  -- No MASTER ever seen -> straight to AUTONOM once learned.
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  local result = o.tick({
    now_ms = 2000, hardware_ready = true, master_percent = 999, -- must be ignored entirely in AUTONOM
    turbines = { turbine('T1', 900, 100, true) },
    reactor = { fill_ratio = 0.1 }, -- tank low -> withdraw rods -> more power
  })
  assert_eq(result.state, rt2_state.states.AUTONOM)
  assert_eq(result.reactor_decision.reason, 'TANK_LOW_WITHDRAW', 'AUTONOM reactor control must react only to the steam tank, never to a stray master_percent')
end

-- Safety trip forces full rod insertion and zero flow everywhere,
-- overriding whatever state the node was in.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  local result = o.tick({
    now_ms = 2000, hardware_ready = true, safety_tripped = true,
    turbines = { turbine('T1', 900, 100, true) },
    reactor = { fill_ratio = 0.5 },
  })
  assert_eq(result.state, rt2_state.states.SAFE)
  assert_eq(result.reactor_decision.rods, 100, 'a safety trip must force full rod insertion')
  assert_eq(result.turbines[1].target_rpm, 0, 'a safety trip must zero every turbine target')
  assert_eq(result.turbines[1].flow_decision.flow, 0, 'a safety trip must force flow to zero')
end

print('rt2_orchestrator_test.lua: ok')
