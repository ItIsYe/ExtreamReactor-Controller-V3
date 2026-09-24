package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Zwei Reaktoren an einem Knoten, jeder mit EIGENEN Turbinen, unabhaengig
-- geregelt. Der Kern der Zusage: was an der einen Einheit passiert, darf
-- die andere nicht mitreissen -- weder beim Regeln noch beim Einlernen
-- noch bei einer Sicherheitsausloesung.

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_state = require('nodes.rt.rt2_state')
local rt2_capacity = require('nodes.rt.rt2_capacity')
local rt2_reactor = require('nodes.rt.rt2_reactor')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local function fleet(prefix, n, rpm, energy)
  local t = {}
  for i = 1, n do
    t[i] = { name = prefix .. i, rpm = rpm, energy = energy,
             coil_engaged = rpm >= 900, current_flow = 1200, active = true }
  end
  return t
end

local function new_node()
  return orchestrator.new({ units = { { name = 'R_A' }, { name = 'R_B' } } })
end

-- ── Beide Einheiten regeln aus IHREM eigenen Dampftank ───────────────────

do
  local o = new_node()
  -- A hat einen vollen Tank (zu viel Dampf -> Staebe einfahren),
  -- B einen leeren (zu wenig -> Staebe ausfahren). Gleicher Takt.
  local r = o.tick({
    now_ms = 1000, hardware_ready = true,
    units = {
      { reactor = { fill_ratio = 0.95, current_rods = 85, active = true }, turbines = fleet('A', 8, 900, 100) },
      { reactor = { fill_ratio = 0.05, current_rods = 85, active = true }, turbines = fleet('B', 8, 900, 100) },
    },
  })
  assert_eq(#r.units, 2, 'beide Einheiten bekommen eine eigene Entscheidung')
  assert_true(r.units[1].reactor_decision.rods > 85,
    'der volle Tank faehrt SEINE Staebe ein: ' .. tostring(r.units[1].reactor_decision.rods))
  assert_true(r.units[2].reactor_decision.rods < 85,
    'der leere Tank faehrt SEINE Staebe aus: ' .. tostring(r.units[2].reactor_decision.rods))
  assert_eq(r.units[1].reactor_decision.reason, 'TANK_FULL_INSERT')
  assert_eq(r.units[2].reactor_decision.reason, 'TANK_LOW_WITHDRAW')
end

-- ── Jede Turbine gehoert genau einer Einheit ─────────────────────────────

do
  local o = new_node()
  local r = o.tick({
    now_ms = 1000, hardware_ready = true,
    units = {
      { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('A', 8, 900, 100) },
      { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('B', 12, 900, 100) },
    },
  })
  assert_eq(#r.turbines, 20, 'die Gesamtsicht enthaelt alle Turbinen beider Einheiten')
  local a_count, b_count = 0, 0
  for _, t in ipairs(r.turbines) do
    if t.unit == 'R_A' then a_count = a_count + 1 end
    if t.unit == 'R_B' then b_count = b_count + 1 end
  end
  assert_eq(a_count, 8, 'und jede traegt ihre Einheit mit')
  assert_eq(b_count, 12)
end

-- ── Einlernen laeuft je Einheit, die Kapazitaet ist die Summe ────────────

do
  local o = new_node()
  local now, r = 1000, nil
  for _ = 1, 6 do
    r = o.tick({
      now_ms = now, hardware_ready = true,
      units = {
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('A', 10, 900, 100) },
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('B', 10, 900, 250) },
      },
    })
    now = now + rt2_capacity.STABLE_MS
  end
  assert_true(r.units[1].capacity.ready and r.units[2].capacity.ready,
    'beide Einheiten muessen sich ausmessen lassen')
  assert_eq(r.units[1].capacity.max_output, 1000 * (1 - rt2_capacity.SAFETY_MARGIN))
  assert_eq(r.units[2].capacity.max_output, 2500 * (1 - rt2_capacity.SAFETY_MARGIN))
  -- Was MASTER liest, ist die Leistung des KNOTENS, also die Summe.
  assert_eq(r.capacity.max_output,
    r.units[1].capacity.max_output + r.units[2].capacity.max_output,
    'die Knotenkapazitaet ist die Summe der Einheiten')
  assert_true(r.capacity.ready, 'und gilt erst, wenn beide fertig sind')
  assert_eq(r.capacity.total_turbines, 20)
end

do
  -- Solange EINE Einheit noch misst, ist der Knoten nicht eingelernt --
  -- sonst teilte MASTER Leistung gegen eine halbe Anlage auf.
  local o = new_node()
  local now, r = 1000, nil
  for _ = 1, 6 do
    r = o.tick({
      now_ms = now, hardware_ready = true,
      units = {
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('A', 10, 900, 100) },
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('B', 10, 400, 0) },
      },
    })
    now = now + rt2_capacity.STABLE_MS
  end
  assert_true(r.units[1].capacity.ready, 'A ist fertig')
  assert_true(not r.units[2].capacity.ready, 'B nicht')
  assert_true(not r.capacity.ready, 'also ist der Knoten nicht fertig')
  assert_eq(r.state, rt2_state.states.LEARNING, 'und bleibt im Einlernen')
end

-- ── Eine Ausloesung faehrt NUR ihren eigenen Reaktor ein ─────────────────

do
  local o = new_node()
  local now = 1000
  local function step(trip_a)
    local r = o.tick({
      now_ms = now, hardware_ready = true,
      units = {
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true },
          turbines = fleet('A', 10, 900, 100), safety_tripped = trip_a },
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true },
          turbines = fleet('B', 10, 900, 100) },
      },
    })
    now = now + rt2_capacity.STABLE_MS
    return r
  end
  for _ = 1, 6 do step(false) end
  local r = step(true)

  -- A ist stillgesetzt ...
  assert_eq(r.units[1].reactor_decision.rods, rt2_reactor.ROD_MAX, 'A faehrt die Staebe voll ein')
  assert_eq(r.units[1].reactor_decision.reason, 'SAFETY_FULL_INSERT')
  assert_eq(r.units[1].reactor_decision.activate, false, 'und wird nicht wieder eingeschaltet')
  for _, t in ipairs(r.units[1].turbines) do
    assert_eq(t.target_rpm, 0, 'A-Turbinen bekommen kein Ziel')
    assert_eq(t.flow_decision.flow, 0, 'und keinen Dampf')
    assert_eq(t.activate, false, 'und werden nicht wieder eingeschaltet')
  end

  -- ... B laeuft unbeeindruckt weiter.
  assert_true(r.units[2].reactor_decision.rods < rt2_reactor.ROD_MAX,
    'B regelt normal weiter, Staebe: ' .. tostring(r.units[2].reactor_decision.rods))
  local b_running = 0
  for _, t in ipairs(r.units[2].turbines) do
    if t.target_rpm >= rt2_turbine.FULL_TARGET_RPM then b_running = b_running + 1 end
  end
  assert_eq(b_running, 10, 'und alle B-Turbinen laufen weiter')

  -- Der Knoten als Ganzes ist NICHT SAFE -- nur eine Einheit ist gestoert.
  assert_true(r.state ~= rt2_state.states.SAFE,
    'ein gesunder Reaktor darf den Knoten nicht mit abschalten, Zustand: ' .. tostring(r.state))
end

do
  -- Loesen BEIDE aus, ist der ganze Knoten SAFE.
  local o = new_node()
  local r
  for _ = 1, 3 do
    r = o.tick({
      now_ms = 1000, hardware_ready = true,
      units = {
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true },
          turbines = fleet('A', 4, 900, 100), safety_tripped = true },
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true },
          turbines = fleet('B', 4, 900, 100), safety_tripped = true },
      },
    })
  end
  assert_eq(r.state, rt2_state.states.SAFE, 'sind alle Einheiten ausgeloest, ist auch der Knoten SAFE')
  for _, unit in ipairs(r.units) do
    assert_eq(unit.reactor_decision.rods, rt2_reactor.ROD_MAX)
  end
end

-- ── MASTER-Vorgabe wirkt auf jede Einheit fuer sich ──────────────────────

do
  local o = new_node()
  local now = 1000
  local function step()
    o.note_master_seen(now)
    local r = o.tick({
      now_ms = now, hardware_ready = true,
      units = {
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('A', 10, 900, 100) },
        { reactor = { fill_ratio = 0.5, current_rods = 85, active = true }, turbines = fleet('B', 10, 900, 100) },
      },
    })
    now = now + rt2_capacity.STABLE_MS
    return r
  end
  for _ = 1, 6 do step() end
  assert_eq(step().state, rt2_state.states.MASTER, 'Vorbedingung: MASTER verbunden')

  local cmd = o.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } })
  assert_true(cmd.ok, 'die Vorgabe muss angenommen werden')
  local r = step()

  for index, unit in ipairs(r.units) do
    local full, off = 0, 0
    for _, t in ipairs(unit.turbines) do
      if t.target_rpm <= 0 then off = off + 1
      elseif t.target_rpm >= rt2_turbine.FULL_TARGET_RPM then full = full + 1 end
    end
    assert_eq(full, 5, 'Einheit ' .. index .. ': 50 % von 10 Turbinen = 5 auf Vollast')
    assert_eq(off, 5, 'und 5 geparkt')
  end
end

print('rt2_two_reactor_test.lua: ok')
