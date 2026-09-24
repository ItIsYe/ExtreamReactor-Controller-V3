package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Behavioural proof for the five things the operator asked to have verified:
--   1. every turbine is regulated INDIVIDUALLY, not by one broadcast decision
--   2. the state machine walks its full lifecycle
--   3. capacity learning gates on the real measurement condition
--   4. the reactor regulates from its steam tank, in every mode
--   5. devices get switched on when they read off
--
-- Deliberately uses a HETEROGENEOUS fleet. The existing integration test
-- runs 25 identical turbines, which cannot tell individual regulation apart
-- from "same decision broadcast to everyone" -- with identical inputs both
-- produce identical output. Here every turbine is in a different situation
-- in the SAME tick, so a broadcast implementation fails immediately.

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_state = require('nodes.rt.rt2_state')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_reactor = require('nodes.rt.rt2_reactor')
local rt2_capacity = require('nodes.rt.rt2_capacity')

-- Diese Datei prueft die EINZELREGELUNG, nicht das Einlernen. Seit das
-- Einlernen ein gestaffelter Suchlauf ist, laeuft in LEARNING zunaechst
-- nur eine Turbine -- dann gaebe es nichts zu vergleichen. Also startet
-- hier jeder Block mit einer bereits vermessenen Anlage, so wie sie nach
-- dem ersten Lauf aus dem Cache kaeme.
local function learned(count)
  local c = rt2_capacity.new_state()
  c.ready, c.max_output = true, 1000
  c.total_turbines, c.sustainable_turbines, c.released = count, count, count
  c.reason = 'LOADED_FROM_CACHE'
  return c
end

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local function turbine(name, rpm, flow, coil, energy, active)
  return { name = name, rpm = rpm, current_flow = flow, coil_engaged = coil,
           energy = energy or 0, active = active }
end

local function by_name(result)
  local out = {}
  for _, t in ipairs(result.turbines) do out[t.name] = t end
  return out
end

-- ═══ 1. Einzelregelung: jede Turbine bekommt ihre eigene Entscheidung ═══
--
-- Five turbines, five different situations, one tick. Every one must get
-- the decision its OWN readings call for.
do
  local o = orchestrator.new({ initial_capacity = learned(5) })
  -- Reach AUTONOM so every turbine shares the same 900 target -- that way
  -- any difference in the outcome can only come from the turbine's own
  -- readings, not from a different target. Aufgewaermt wird mit derselben
  -- Flottengroesse: eine abweichende Anzahl gilt als Umbau und wuerfe die
  -- eingelernte Kapazitaet weg (rt2_capacity, TOPOLOGY_CHANGED).
  local warm = {}
  for i = 1, 5 do warm[i] = turbine('W' .. i, 900, 1000, true, 100, true) end
  o.tick({ now_ms = 1000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = warm })

  local fleet = {
    turbine('SLOW',      100, 500,  false, 0,   true),   -- weit unter Ziel  -> RAMP_UP
    turbine('UNDER',     880, 1000, true,  100, true),   -- knapp drunter    -> HOLD_TRIM_UP
    turbine('OVER',      905, 1200, true,  100, true),   -- knapp drüber     -> HOLD_TRIM_DOWN
    turbine('FAST',      1000, 1500, true, 100, true),   -- über Band        -> RAMP_DOWN
    turbine('RUNAWAY',   2400, 1800, true, 100, true),   -- echter Ausreißer -> OVERSPEED
  }
  local r = o.tick({ now_ms = 2000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = fleet })
  local t = by_name(r)

  assert_eq(#r.turbines, 5, 'every discovered turbine must get its own decision entry')

  assert_eq(t.SLOW.flow_decision.reason,    'RAMP_UP')
  assert_eq(t.SLOW.flow_decision.flow, 500 + rt2_turbine.TRIM_STEP, 'SLOW ramps up from its OWN flow, not the fleet average')

  assert_eq(t.UNDER.flow_decision.reason,   'HOLD_TRIM_UP')
  -- 20 RPM unter Ziel bei Band 40 -> halber Rampenschritt (35/2 ~ 18).
  assert_eq(t.UNDER.flow_decision.flow, 1018, 'UNDER trims up proportionally from its OWN 1000')

  assert_eq(t.OVER.flow_decision.reason,    'HOLD_TRIM_DOWN')
  -- nur 5 RPM drueber -> entsprechend kleiner Schritt (35 * 5/40 ~ 4).
  assert_eq(t.OVER.flow_decision.flow, 1196, 'OVER trims down proportionally from its OWN 1200')

  assert_eq(t.FAST.flow_decision.reason,    'RAMP_DOWN')
  assert_eq(t.FAST.flow_decision.flow, 1500 - rt2_turbine.TRIM_STEP, 'FAST ramps down from its OWN flow')

  assert_eq(t.RUNAWAY.flow_decision.reason, 'OVERSPEED')
  assert_eq(t.RUNAWAY.flow_decision.flow, 0, 'a genuine runaway is cut to zero immediately')

  -- Five distinct reasons in one tick is the actual proof of independence.
  local reasons = {}
  for _, entry in ipairs(r.turbines) do reasons[entry.flow_decision.reason] = true end
  local distinct = 0
  for _ in pairs(reasons) do distinct = distinct + 1 end
  assert_eq(distinct, 5, 'a broadcast implementation would produce one reason; individual regulation produces five')

  -- Coils are decided per turbine too, from each turbine's own rpm.
  assert_eq(t.SLOW.coil_decision.engaged, false, 'a turbine at 100 rpm must not have its coil engaged')
  assert_eq(t.RUNAWAY.coil_decision.engaged, true, 'a turbine well above engage speed keeps its coil engaged')
end

-- Individual regulation must also hold when the TARGETS differ (MASTER
-- split): VOLLAST, PUFFER and AUS turbines in the same tick.
do
  local o = orchestrator.new({ initial_capacity = learned(4) })
  o.note_master_seen(0)
  local fleet = {}
  for i = 1, 4 do fleet[i] = turbine('T' .. i, 900, 1000, true, 100, true) end

  -- Tick 1 is INIT -> LEARNING, tick 2 is LEARNING -> MASTER. A setpoint
  -- sent before the node has actually reached MASTER is rejected by design
  -- (the command handler validates against the real state, it does not
  -- trust the sender) -- MASTER's retry covers that gap in production.
  o.tick({ now_ms = 1000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = fleet })
  local early = o.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } })
  assert_true(early.ok == false, 'a setpoint arriving before the node reached MASTER must be rejected')
  assert_eq(early.reason_code, 'INVALID_STATE')

  o.tick({ now_ms = 2000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = fleet })
  assert_eq(o.current_state(), rt2_state.states.MASTER)
  local accepted = o.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } })
  assert_true(accepted.ok, 'once in MASTER the same setpoint is accepted')
  local r = o.tick({ now_ms = 3000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = fleet })

  local targets = {}
  for _, entry in ipairs(r.turbines) do targets[#targets + 1] = entry.target_rpm end
  table.sort(targets)
  -- 50 % of 4 turbines = 2 full, 0 partial, 2 off.
  assert_eq(targets[1], 0,   'the AUS slots must target 0')
  assert_eq(targets[2], 0)
  assert_eq(targets[3], 900, 'the VOLLAST slots must target the full rpm')
  assert_eq(targets[4], 900)

  -- An AUS-slot turbine must be flow-zeroed -- that is the regression from
  -- the original report -- but it keeps its coil ENGAGED while it is still
  -- spinning, because the coil is the brake: that stops the rotor faster
  -- than coasting and recovers the energy instead of wasting it.
  for _, entry in ipairs(r.turbines) do
    if entry.target_rpm == 0 then
      assert_eq(entry.flow_decision.flow, 0, 'AUS slot must be flow-zeroed')
      assert_eq(entry.coil_decision.engaged, true, 'AUS slot still spinning must brake through its coil')
      assert_eq(entry.coil_decision.reason, 'BRAKE_TO_STOP')
    end
  end
end

-- ═══ 2. Zustandsmaschine: vollständiger Lebenszyklus ═══
do
  local o = orchestrator.new({ initial_capacity = learned(1) })
  local fleet = { turbine('T1', 900, 1000, true, 100, true) }
  local reactor = { fill_ratio = 0.5, active = true }

  assert_eq(o.current_state(), rt2_state.states.INIT, 'boots in INIT')

  -- no hardware yet -> stays INIT
  local r = o.tick({ now_ms = 1000, hardware_ready = false, turbines = {}, reactor = reactor })
  assert_eq(r.state, rt2_state.states.INIT, 'without hardware the node stays in INIT')

  -- hardware present -> LEARNING
  r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet, reactor = reactor })
  assert_eq(r.state, rt2_state.states.LEARNING, 'INIT -> LEARNING once hardware is there')

  -- capacity learned, no MASTER -> AUTONOM
  r = o.tick({ now_ms = 3000, hardware_ready = true, turbines = fleet, reactor = reactor })
  assert_eq(r.state, rt2_state.states.AUTONOM, 'LEARNING -> AUTONOM without a MASTER')

  -- MASTER appears -> MASTER, purely from connectivity
  o.note_master_seen(4000)
  r = o.tick({ now_ms = 4000, hardware_ready = true, turbines = fleet, reactor = reactor })
  assert_eq(r.state, rt2_state.states.MASTER, 'AUTONOM -> MASTER on connectivity alone, no command needed')

  -- MASTER goes quiet past the timeout -> back to AUTONOM
  r = o.tick({ now_ms = 4000 + 99999, hardware_ready = true, turbines = fleet, reactor = reactor })
  assert_eq(r.state, rt2_state.states.AUTONOM, 'MASTER -> AUTONOM when the link times out')

  -- safety trip -> SAFE from wherever we were
  r = o.tick({ now_ms = 200000, hardware_ready = true, safety_tripped = true, turbines = fleet, reactor = reactor })
  assert_eq(r.state, rt2_state.states.SAFE, 'any state -> SAFE on a trip')

  -- condition clears, capacity already known -> straight back to operation
  r = o.tick({ now_ms = 201000, hardware_ready = true, turbines = fleet, reactor = reactor })
  assert_eq(r.state, rt2_state.states.AUTONOM, 'SAFE -> AUTONOM once the condition clears')
end

-- ═══ 3. Einlernen: misst nur, was wirklich am Ziel ist ═══
do
  -- Gemessen wird der hoechste Gesamtausstoss, der tatsaechlich floss --
  -- ohne Schwelle, ohne Staffelung, ohne guenstigen Augenblick. Frueher
  -- stand hier eine 80-%-Regel: waren nie genug Turbinen GLEICHZEITIG im
  -- Messfenster, lieferte das Einlernen ueberhaupt keine Zahl.
  local o = orchestrator.new()
  local function fleet_at(n_running)
    local f = {}
    for i = 1, 5 do
      if i <= n_running then f[i] = turbine('T' .. i, 900, 1000, true, 100, true)
      else f[i] = turbine('T' .. i, 780, rt2_turbine.MAX_FLOW, false, 0, true) end
    end
    return f
  end

  -- Beim Einlernen wird nichts gedeckelt -- alle fahren auf Ziel.
  local r = o.tick({ now_ms = 1000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = fleet_at(3) })
  assert_true(r.max_active == nil, 'beim Einlernen deckelt der Knoten nichts')
  for _, t in ipairs(r.turbines) do
    assert_eq(t.target_rpm, 900, 'jede Turbine bekommt das volle Ziel')
  end

  -- Drei liefern -> das ist der Messwert. Drei von fuenf haette die alte
  -- 80-%-Regel (vier noetig) verworfen und gar nichts gelernt.
  r = o.tick({ now_ms = 2000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = fleet_at(3) })
  assert_eq(r.capacity.reason, 'MEASURING')
  assert_true(not r.capacity.ready, 'ein einzelner Messwert legt noch nichts fest')

  r = o.tick({ now_ms = 2000 + rt2_capacity.STABLE_MS + 1, hardware_ready = true,
               reactor = { fill_ratio = 0.5 }, turbines = fleet_at(3) })
  assert_true(r.capacity.ready, 'bleibt der Hoechstwert stehen, ist die Anlage ausgemessen')
  assert_eq(r.capacity.sustainable_turbines, 3, 'drei Turbinen lieferten den Hoechstwert')
  -- Gemessen, NICHT hochgerechnet: 3 x 100 minus 5 % Reserve. Die alte
  -- Formel haette (300/3) * 5 = 500 eingetragen -- das Ausstossmass von
  -- fuenf Turbinen fuer eine Anlage, bei der drei lieferten.
  assert_eq(r.capacity.max_output, 285)

  -- Und erst JETZT, nach dem Einlernen, wirkt die beobachtete Grenze.
  r = o.tick({ now_ms = 400000, hardware_ready = true, reactor = { fill_ratio = 0.5 }, turbines = fleet_at(3) })
  assert_eq(r.max_active, 3, 'im Betrieb faehrt der Knoten nicht mehr an, als je getragen haben')
end

-- ═══ 4. Reaktorregelung: nur Dampftank, in JEDEM Modus gleich ═══
do
  -- The control law itself, directly.
  local low  = rt2_reactor.compute_rod_level({ fill_ratio = 0.10, current_rods = 90 })
  local high = rt2_reactor.compute_rod_level({ fill_ratio = 0.90, current_rods = 90 })
  local hold = rt2_reactor.compute_rod_level({ fill_ratio = 0.52, current_rods = 90 })
  assert_true(low.rods < 90,  'tank low -> withdraw rods -> more power')
  assert_true(high.rods > 90, 'tank full -> insert rods -> less power')
  assert_eq(hold.rods, 90,    'inside the deadband nothing moves')
  assert_true(low.rods >= rt2_reactor.ROD_MIN, 'never below the 70 % floor')
  assert_true(high.rods <= rt2_reactor.ROD_MAX, 'never above 100 %')

  -- Mode independence: the SAME tank reading must give the SAME rods in
  -- AUTONOM and in MASTER, and a MASTER power setpoint must not shift it.
  local function rods_in(state_setup)
    local o = orchestrator.new({ initial_capacity = learned(1) })
    local fleet = { turbine('T1', 900, 1000, true, 100, true) }
    state_setup(o)
    o.tick({ now_ms = 1000, hardware_ready = true, reactor = { fill_ratio = 0.5, current_rods = 90 }, turbines = fleet })
    o.tick({ now_ms = 2000, hardware_ready = true, reactor = { fill_ratio = 0.5, current_rods = 90 }, turbines = fleet })
    local r = o.tick({ now_ms = 3000, hardware_ready = true,
      reactor = { fill_ratio = 0.15, current_rods = 90 }, turbines = fleet })
    return r
  end

  local autonom = rods_in(function() end)
  local master  = rods_in(function(o)
    o.note_master_seen(0)
  end)
  assert_eq(autonom.state, rt2_state.states.AUTONOM)
  assert_eq(master.state, rt2_state.states.MASTER)
  assert_eq(master.reactor_decision.rods, autonom.reactor_decision.rods,
    'the same tank level must give the same rod level in MASTER and AUTONOM -- the reactor never sees the mode')

  -- A MASTER power setpoint moves turbine targets but must leave the rods alone.
  local o = orchestrator.new({ initial_capacity = learned(4) })
  o.note_master_seen(0)
  local fleet = {}
  for i = 1, 4 do fleet[i] = turbine('T' .. i, 900, 1000, true, 100, true) end
  local reading = { fill_ratio = 0.15, current_rods = 90 }
  o.tick({ now_ms = 1000, hardware_ready = true, reactor = reading, turbines = fleet })
  local before = o.tick({ now_ms = 2000, hardware_ready = true, reactor = reading, turbines = fleet })
  o.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 25 } })
  local after = o.tick({ now_ms = 3000, hardware_ready = true, reactor = reading, turbines = fleet })
  assert_eq(after.reactor_decision.rods, before.reactor_decision.rods,
    'a MASTER power change must not touch the rod decision directly')

  -- Safety overrides the tank law entirely.
  local tripped = o.tick({ now_ms = 4000, hardware_ready = true, safety_tripped = true,
    reactor = { fill_ratio = 0.05, current_rods = 75 }, turbines = fleet })
  assert_eq(tripped.reactor_decision.rods, 100, 'a trip fully inserts regardless of an empty tank')
  assert_eq(tripped.reactor_decision.reason, 'SAFETY_FULL_INSERT')

  -- A missing tank reading must fail safe, not guess.
  local blind = rt2_reactor.compute_rod_level({ fill_ratio = nil, current_rods = 75 })
  assert_eq(blind.rods, 100, 'no steam reading -> full insertion')
  assert_eq(blind.reason, 'NO_STEAM_READING')
end

-- ═══ 5. An- und Abschaltung ═══
do
  local o = orchestrator.new({ initial_capacity = learned(3) })
  local mixed = {
    turbine('ON',  900, 1000, true, 100, true),    -- läuft schon
    turbine('OFF', 900, 1000, true, 100, false),   -- steht
    turbine('UNKNOWN', 900, 1000, true, 100, nil), -- Status unlesbar
  }
  local r = o.tick({ now_ms = 1000, hardware_ready = true,
    reactor = { fill_ratio = 0.5, active = false }, turbines = mixed })
  local t = by_name(r)

  assert_true(not t.ON.activate,      'a turbine already running must not be switched on again every tick')
  assert_true(t.OFF.activate,         'a turbine reading off must be switched on')
  assert_true(t.UNKNOWN.activate,     'an unreadable state must fail toward switching on')
  assert_true(r.reactor_decision.activate, 'a reactor reading off must be switched on')

  -- Once everything reads on, no further activation is requested.
  local running = {
    turbine('ON', 900, 1000, true, 100, true),
    turbine('OFF', 900, 1000, true, 100, true),
    turbine('UNKNOWN', 900, 1000, true, 100, true),
  }
  r = o.tick({ now_ms = 2000, hardware_ready = true,
    reactor = { fill_ratio = 0.5, active = true }, turbines = running })
  for _, entry in ipairs(r.turbines) do
    assert_true(not entry.activate, 'no redundant activation once the device confirms it is on')
  end
  assert_true(not r.reactor_decision.activate)

  -- Documented behaviour: v2 only ever switches ON. Even a parked AUS-slot
  -- turbine stays active and is parked via flow=0 + coil off instead.
  local o2 = orchestrator.new({ initial_capacity = learned(4) })
  o2.note_master_seen(0)
  local fleet = {}
  for i = 1, 4 do fleet[i] = turbine('T' .. i, 900, 1000, true, 100, true) end
  o2.tick({ now_ms = 1000, hardware_ready = true, reactor = { fill_ratio = 0.5, active = true }, turbines = fleet })
  o2.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } })
  local split = o2.tick({ now_ms = 2000, hardware_ready = true, reactor = { fill_ratio = 0.5, active = true }, turbines = fleet })
  for _, entry in ipairs(split.turbines) do
    assert_true(entry.deactivate == nil, 'v2 never emits a switch-off decision')
  end
end

print('rt2_regulation_behaviour_test.lua: ok')
