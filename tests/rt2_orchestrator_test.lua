package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local function turbine(name, rpm, energy, coil_engaged, current_flow)
  return { name = name, rpm = rpm, energy = energy, coil_engaged = coil_engaged, current_flow = current_flow or 0 }
end

-- Das Einlernen braucht Zeit: ein tauglicher Takt legt nichts fest, erst
-- wenn sich der Hoechstwert LEARN_STABLE_MS lang nicht mehr verbessert,
-- ist die Anlage ausgemessen. Die meisten Bloecke hier pruefen das
-- Verhalten DANACH, also wird es vorweg durchgefahren.
local function learn(o, turbines, master_seen)
  local ms = 1000
  for _ = 1, 40 do
    if master_seen then o.note_master_seen(ms) end
    local r = o.tick({ now_ms = ms, hardware_ready = true, turbines = turbines, reactor = { fill_ratio = 0.5 } })
    if r.capacity.ready then return ms end
    ms = ms + 1000
  end
  error('das Einlernen wurde nicht fertig', 2)
end

-- Der Knoten lernt nichts mehr ein: mit Hardware und MASTER ist er im
-- ersten Takt betriebsbereit.
do
  local o = orchestrator.new()
  o.note_master_seen(0)

  local result = o.tick({
    now_ms = 1000, hardware_ready = true,
    turbines = { turbine('T1', 100, 0, false), turbine('T2', 100, 0, false) },
    reactor = { fill_ratio = 0.5 },
  })
  assert_eq(result.state, rt2_state.states.MASTER,
    'hardware plus MASTER is operational at once -- there is no learning phase left')
  for _, t in ipairs(result.turbines) do
    assert_eq(t.target_rpm, 900, 'and every turbine gets the fixed target')
  end
end

-- Ohne MASTER landet derselbe Knoten in AUTONOM, und die Turbinen fahren
-- ebenfalls das feste Ziel -- geregelt wird dort der REAKTOR.
do
  local o = orchestrator.new()
  local fleet = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) }
  local result = o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet, reactor = { fill_ratio = 0.5 } })
  assert_eq(result.state, rt2_state.states.AUTONOM, 'no MASTER -> AUTONOM immediately')
  for _, t in ipairs(result.turbines) do
    assert_eq(t.target_rpm, 900, 'AUTONOM turbines still target the fixed RPM')
  end
end

-- Das Einlernen: solange es laeuft, gibt es keine Zahl fuer MASTER.
do
  local o = orchestrator.new()
  local result = o.tick({ now_ms = 1000, hardware_ready = true,
    turbines = { turbine('T1', 100, 0, false), turbine('T2', 100, 0, false) }, reactor = {} })
  assert_true(not result.capacity.ready, 'waehrend des Einlernens meldet der Knoten nichts')
  assert_true(result.capacity.learning)

  -- Ein einzelner tauglicher Takt legt noch nichts fest -- erst wenn sich
  -- der Hoechstwert eine Weile nicht mehr verbessert.
  local fleet = { turbine('T1', 900, 100, true), turbine('T2', 900, 120, true) }
  result = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet, reactor = {} })
  assert_true(result.capacity.learning, 'ein einzelner Messwert legt noch nichts fest')
  assert_eq(result.capacity.reason, 'LEARNING')
  assert_eq(result.capacity.best_output, 220, 'aber der Hoechstwert steht schon')

  result = o.tick({ now_ms = 2000 + orchestrator.LEARN_STABLE_MS + 1, hardware_ready = true,
    turbines = fleet, reactor = {} })
  assert_true(result.capacity.ready, 'bleibt der Hoechstwert stehen, ist die Anlage ausgemessen')
  assert_eq(result.capacity.reason, 'MEASURED')
  -- 220 abzueglich 5 % Sicherheitsreserve.
  assert_eq(result.capacity.max_output, math.floor(220 * 0.95))
  assert_eq(result.capacity.at_target, 2)
  assert_true(not result.capacity.learning, 'und danach laeuft die normale Regelung')

  -- Die gemessene Zahl steht. Ein schwaecherer Takt widerlegt sie nicht.
  local measured = result.capacity.max_output
  result = o.tick({ now_ms = 20000, hardware_ready = true,
    turbines = { turbine('T1', 900, 50, true), turbine('T2', 900, 50, true) }, reactor = {} })
  assert_eq(result.capacity.max_output, measured, 'die Messung steht')
end

-- Regression gegen einen Stillstand, aus dem der Knoten nicht mehr
-- herauskommt: MASTER teilt seinen Bedarf gegen capacity_max auf. Solange
-- der Knoten noch nichts gemessen hat, ist das 0, also kaeme eine Vorgabe
-- von 0 % zurueck -- keine Turbine laeuft, kein Ausstoss, nichts zu messen.
-- Genau dagegen uebersteuert das Einlernen die MASTER-Vorgabe.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local result = o.tick({
    now_ms = 1000, hardware_ready = true, master_percent = 0,
    turbines = { turbine('T1', 0, 0, false), turbine('T2', 0, 0, false) },
    reactor = {},
  })
  assert_eq(result.state, rt2_state.states.MASTER)
  assert_eq(result.effective_percent, 100, 'waehrend des Einlernens gilt die MASTER-Vorgabe nicht')
  for _, t in ipairs(result.turbines) do
    assert_eq(t.target_rpm, 900, 'die ganze Flotte faehrt auf Zieldrehzahl')
  end

  -- Sobald das Einlernen durch ist, gilt die Vorgabe.
  local fleet = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) }
  local ms = learn(o, fleet, true)
  o.note_master_seen(ms + 1000)
  result = o.tick({
    now_ms = ms + 1000, hardware_ready = true, master_percent = 0,
    turbines = fleet, reactor = {},
  })
  assert_eq(result.effective_percent, 0, 'danach gilt die MASTER-Vorgabe')
  for _, t in ipairs(result.turbines) do
    assert_eq(t.target_rpm, 0, 'and 0 % really means no turbine runs')
  end
end

-- MASTER: die Vorgabe in Prozent bestimmt, WIEVIELE Turbinen laufen.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local fleet = { turbine('T1', 900, 100, true), turbine('T2', 900, 100, true) }
  local ms = learn(o, fleet, true)
  o.note_master_seen(ms + 1000)
  local result = o.tick({
    now_ms = ms + 1000, hardware_ready = true, master_percent = 50,
    turbines = { turbine('T1', 900, 100, true, 1200), turbine('T2', 2000, 100, true, 1200) },
    reactor = {},
  })
  assert_eq(result.turbines[1].target_rpm, 900, 'at 50% of 2 turbines the first slot runs')
  assert_eq(result.turbines[2].target_rpm, 0, 'and the second one stands')

  -- Die abgestellte Turbine dreht noch (Schwung). Der Dampf muss SOFORT
  -- weg -- das war der Fehler, der diesen Umbau ausgeloest hat (node-101:
  -- abgestellte Turbinen auf 2.0k Durchfluss bei 3200 RPM).
  local t2 = result.turbines[2]
  assert_eq(t2.flow_decision.flow, 0, 'a parked turbine still spinning must be cut to flow=0 this very tick')
  -- Und die Spule bleibt gekoppelt: sie IST die Bremse, das holt die
  -- Rotationsenergie noch herein statt sie auslaufen zu lassen.
  assert_eq(t2.coil_decision.engaged, true, 'a parked turbine still spinning at 2000 rpm brakes through its coil')
  assert_eq(t2.coil_decision.reason, 'BRAKE_TO_STOP')
end

-- AUTONOM reactor regulation: purely steam-tank driven, MASTER's percent
-- (if any leaked through) must have zero effect on the rod decision.
do
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  local result = o.tick({
    now_ms = 2000, hardware_ready = true, master_percent = 999, -- must be ignored entirely in AUTONOM
    turbines = { turbine('T1', 900, 100, true) },
    reactor = { fill_ratio = 0.1 }, -- tank low -> withdraw rods -> more power
  })
  assert_eq(result.state, rt2_state.states.AUTONOM)
  assert_eq(result.reactor_decision.reason, 'TANK_LOW_WITHDRAW',
    'AUTONOM reactor control must react only to the steam tank, never to a stray master_percent')
end

-- reactor_decision.activate must be wired through from the tick's own
-- reactor.active reading -- true while the reading says OFF/unknown,
-- false once the reading confirms it is already ON.
do
  local o = orchestrator.new()
  local off_result = o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5, active = false } })
  assert_true(off_result.reactor_decision.activate, 'a reactor reading active=false must be flagged for activation')
  local on_result = o.tick({ now_ms = 2000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5, active = true } })
  assert_true(not on_result.reactor_decision.activate, 'a reactor already reading active=true must not be re-flagged for activation')
end

-- Same wiring for turbines[i].activate.
do
  local o = orchestrator.new()
  local t1_off = turbine('T1', 900, 100, true); t1_off.active = false
  local off_result = o.tick({ now_ms = 1000, hardware_ready = true, turbines = { t1_off }, reactor = { fill_ratio = 0.5 } })
  assert_true(off_result.turbines[1].activate, 'a turbine reading active=false must be flagged for activation')
  local t1_on = turbine('T1', 900, 100, true); t1_on.active = true
  local on_result = o.tick({ now_ms = 2000, hardware_ready = true, turbines = { t1_on }, reactor = { fill_ratio = 0.5 } })
  assert_true(not on_result.turbines[1].activate, 'a turbine already reading active=true must not be re-flagged for activation')
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

-- SCRAM via handle_command() must latch a safety trip that persists
-- across ticks until explicitly cleared -- not just for the one tick it
-- was received on.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })

  local ack = o.handle_command({ target = 'SCRAM' })
  assert_true(ack.ok, 'SCRAM must be accepted')

  local result = o.tick({ now_ms = 2000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  assert_eq(result.state, rt2_state.states.SAFE, 'a latched SCRAM must force SAFE on the very next tick')

  -- Even a later tick, with no safety condition active otherwise, must
  -- stay SAFE until explicitly cleared.
  result = o.tick({ now_ms = 3000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  assert_eq(result.state, rt2_state.states.SAFE, 'SCRAM must remain latched across ticks, not just the one it was issued on')

  o.clear_manual_safety_trip()
  result = o.tick({ now_ms = 4000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  assert_eq(result.state, rt2_state.states.MASTER, 'clearing the trip must allow recovery back to MASTER')
end

-- Regression: the latch must be releasable THROUGH A COMMAND, not only by
-- the internal clear_manual_safety_trip() helper -- nothing in production
-- ever called that helper, so a SCRAMmed node had no way back at all short
-- of a physical reboot.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  o.handle_command({ target = 'SCRAM' })
  local result = o.tick({ now_ms = 2000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  assert_eq(result.state, rt2_state.states.SAFE)

  local ack = o.handle_command({ target = 'REQUEST_STARTUP_MODULE' })
  assert_true(ack.ok, 'the restart command must be accepted while SAFE')
  o.note_master_seen(3000)
  result = o.tick({ now_ms = 3000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  assert_eq(result.state, rt2_state.states.MASTER,
    'a restart command must bring a manually SCRAMmed node back out of SAFE')
end

-- ...but a still-active PHYSICAL trip must not be clearable that way:
-- safety_tripped is re-read from hardware every tick.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  o.handle_command({ target = 'SCRAM' })
  o.tick({ now_ms = 2000, hardware_ready = true, safety_tripped = true, turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  o.handle_command({ target = 'REQUEST_STARTUP_MODULE' })
  local result = o.tick({ now_ms = 3000, hardware_ready = true, safety_tripped = true,
    turbines = { turbine('T1', 900, 100, true) }, reactor = { fill_ratio = 0.5 } })
  assert_eq(result.state, rt2_state.states.SAFE,
    'clearing the manual latch must not override a physical trip condition that is still active')
end

-- SET_SETPOINTS via handle_command() must actually steer the turbine
-- targets on the next tick.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local fleet = {
    turbine('T1', 900, 100, true), turbine('T2', 900, 100, true),
    turbine('T3', 900, 100, true), turbine('T4', 900, 100, true),
  }
  local ms = learn(o, fleet, true)

  local ack = o.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 25 } })
  assert_true(ack.ok, 'SET_SETPOINTS must be accepted once in MASTER state')

  o.note_master_seen(ms + 1000)
  local result = o.tick({ now_ms = ms + 1000, hardware_ready = true, turbines = fleet, reactor = { fill_ratio = 0.5 } })
  local running = 0
  for _, t in ipairs(result.turbines) do
    if t.target_rpm > 0 then running = running + 1 end
  end
  assert_eq(running, 1, 'a stored master_percent must steer the next tick: 25% of 4 turbines = 1 running')
end

print('rt2_orchestrator_test.lua: ok')
