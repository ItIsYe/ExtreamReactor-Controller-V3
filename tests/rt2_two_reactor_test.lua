package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Zwei Reaktoren an EINEM Knoten, die dasselbe Dampfnetz speisen.
--
-- Der Knoten fasst die Anlage als ein System auf: eine Turbinenflotte,
-- eine Kapazitaet, eine Leistungsvorgabe. Was sich nicht teilen laesst,
-- ist die Reaktorregelung -- jeder Reaktor hat seinen eigenen Dampftank
-- und regelt daraus. Eine Zuordnung Turbine->Reaktor gibt es bewusst
-- nicht; die Reaktoren stimmen sich auch nicht ab, sondern regeln sich
-- ueber das gemeinsame Netz von selbst gegenseitig ein.

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_state = require('nodes.rt.rt2_state')
local rt2_reactor = require('nodes.rt.rt2_reactor')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local function fleet(n, rpm, energy)
  local t = {}
  for i = 1, n do
    t[i] = { name = 'T' .. i, rpm = rpm, energy = energy,
             coil_engaged = rpm >= 900, current_flow = 1200, active = true }
  end
  return t
end

local function new_node()
  return orchestrator.new({ reactors = { { name = 'R_A' }, { name = 'R_B' } } })
end

local function reactors(fill_a, fill_b, trip_a, trip_b)
  return {
    { name = 'R_A', safety_tripped = trip_a,
      reactor = { fill_ratio = fill_a, current_rods = 85, active = true } },
    { name = 'R_B', safety_tripped = trip_b,
      reactor = { fill_ratio = fill_b, current_rods = 85, active = true } },
  }
end

-- ── Jeder Reaktor regelt aus SEINEM eigenen Tank ─────────────────────────

do
  local o = new_node()
  -- Gleicher Takt, gegenlaeufige Taenke: A voll, B leer.
  local r = o.tick({
    now_ms = 1000, hardware_ready = true,
    turbines = fleet(20, 900, 100),
    reactors = reactors(0.95, 0.05),
  })
  assert_eq(#r.reactors, 2, 'beide Reaktoren bekommen eine eigene Entscheidung')
  assert_true(r.reactors[1].rods > 85,
    'der volle Tank faehrt SEINE Staebe ein: ' .. tostring(r.reactors[1].rods))
  assert_true(r.reactors[2].rods < 85,
    'der leere Tank faehrt SEINE Staebe aus: ' .. tostring(r.reactors[2].rods))
  assert_eq(r.reactors[1].reason, 'TANK_FULL_INSERT')
  assert_eq(r.reactors[2].reason, 'TANK_LOW_WITHDRAW')
  assert_eq(r.reactors[1].name, 'R_A', 'die Entscheidung traegt ihren Reaktor mit')
  assert_eq(r.reactors[2].name, 'R_B')
end

-- ── Die Turbinen bleiben EINE Flotte ─────────────────────────────────────

do
  local o = new_node()
  local r = o.tick({
    now_ms = 1000, hardware_ready = true,
    turbines = fleet(30, 900, 100),
    reactors = reactors(0.5, 0.5),
  })
  assert_eq(#r.turbines, 30, 'alle Turbinen werden als eine Flotte entschieden')
  for _, t in ipairs(r.turbines) do
    assert_eq(t.target_rpm, rt2_turbine.FULL_TARGET_RPM,
      'ohne MASTER bekommt jede Turbine das volle Ziel')
    assert_true(t.unit == nil, 'eine Zuordnung zu einem Reaktor gibt es bewusst nicht')
  end
end

-- ── Gemeldet wird EINE Leistung, fuer den ganzen Knoten ──────────────────

do
  local o = new_node()
  local r = o.tick({
    now_ms = 1000, hardware_ready = true,
    turbines = fleet(30, 900, 100),
    reactors = reactors(0.5, 0.5),
  })
  assert_true(r.capacity.ready, 'die Flotte liefert, also gibt es etwas zu melden')
  -- 30 Turbinen x 100 RF/t -- unabhaengig davon, wie viele Reaktoren den
  -- Dampf dafuer liefern.
  assert_eq(r.capacity.max_output, 3000)
  assert_eq(r.capacity.total_turbines, 30)
  assert_eq(r.state, rt2_state.states.AUTONOM, 'und der Knoten laeuft')
end

-- ── Ein Ausloeser faehrt NUR seinen eigenen Reaktor ein ──────────────────

do
  local o = new_node()
  local now = 1000
  local function step(trip_a)
    local r = o.tick({
      now_ms = now, hardware_ready = true,
      turbines = fleet(20, 900, 100),
      reactors = reactors(0.5, 0.5, trip_a),
    })
    now = now + 1000
    return r
  end
  for _ = 1, 6 do step(false) end
  local r = step(true)

  -- A ist stillgesetzt ...
  assert_eq(r.reactors[1].rods, rt2_reactor.ROD_MAX, 'A faehrt die Staebe voll ein')
  assert_eq(r.reactors[1].reason, 'SAFETY_FULL_INSERT')
  assert_eq(r.reactors[1].activate, false, 'und wird nicht wieder eingeschaltet')

  -- ... B regelt unbeeindruckt weiter.
  assert_true(r.reactors[2].rods < rt2_reactor.ROD_MAX,
    'B regelt normal weiter, Staebe: ' .. tostring(r.reactors[2].rods))
  assert_true(r.reactors[2].safety_tripped ~= true, 'und gilt nicht als ausgeloest')

  -- Und die FLOTTE laeuft weiter -- sie haengt am gemeinsamen Netz und
  -- bekommt ihren Dampf jetzt eben von B allein. Genau das ist der Sinn
  -- der Vorgabe "nur dieser Reaktor faehrt ein".
  assert_true(r.state ~= rt2_state.states.SAFE,
    'ein gesunder Reaktor darf den Knoten nicht mit abschalten, Zustand: ' .. tostring(r.state))
  local running = 0
  for _, t in ipairs(r.turbines) do
    if t.target_rpm >= rt2_turbine.FULL_TARGET_RPM then running = running + 1 end
  end
  assert_eq(running, 20, 'alle Turbinen laufen weiter')
  assert_eq(r.tripped_reactors, 1, 'der Knoten weiss aber, dass ein Reaktor aus ist')
end

-- ── Loesen ALLE aus, ist der ganze Knoten SAFE ───────────────────────────

do
  local o = new_node()
  local r
  for _ = 1, 3 do
    r = o.tick({
      now_ms = 1000, hardware_ready = true,
      turbines = fleet(20, 900, 100),
      reactors = reactors(0.5, 0.5, true, true),
    })
  end
  assert_eq(r.state, rt2_state.states.SAFE, 'ohne regelbaren Reaktor ist der Knoten SAFE')
  assert_eq(r.tripped_reactors, 2)
  for _, decision in ipairs(r.reactors) do
    assert_eq(decision.rods, rt2_reactor.ROD_MAX)
  end
  -- Erst JETZT wird auch die Flotte abgestellt -- es gibt keinen Dampf mehr.
  for _, t in ipairs(r.turbines) do
    assert_eq(t.target_rpm, 0, 'im SAFE bekommt keine Turbine ein Ziel')
    assert_eq(t.flow_decision.flow, 0, 'und keinen Dampf')
  end
end

-- ── Jeder Reaktor regelt aus SEINEM eigenen Tank ─────────────────────────

do
  -- Zwei Reaktoren am selben Dampfnetz, zwei verschiedene Tankstaende im
  -- selben Takt. Jeder muss die Entscheidung bekommen, die SEIN Messwert
  -- verlangt -- sonst bekaeme der eine die Stellwerte des anderen.
  --
  -- Selbst vermessen sich die Reaktoren nicht mehr: rt2_tuning hat aus dem
  -- Tankverlauf Stellweite und Stellintervall gelernt und damit die
  -- Regelung von Lauf zu Lauf veraendert. Es gelten jetzt die festen Werte
  -- aus rt2_reactor.lua.
  local o = new_node()
  local r = o.tick({
    now_ms = 1000, hardware_ready = true,
    turbines = fleet(20, 900, 100),
    reactors = {
      { name = 'R_A', reactor = { fill_ratio = 0.10, current_rods = 90, active = true } },
      { name = 'R_B', reactor = { fill_ratio = 0.95, current_rods = 90, active = true } },
    },
  })
  assert_eq(r.reactors[1].name, 'R_A')
  assert_eq(r.reactors[2].name, 'R_B')
  assert_true(r.reactors[1].rods < 90,
    'A hat einen leeren Tank -> Staebe ausfahren, mehr Leistung: ' .. tostring(r.reactors[1].rods))
  assert_true(r.reactors[2].rods > 90,
    'B hat einen vollen Tank -> Staebe einfahren, weniger Leistung: ' .. tostring(r.reactors[2].rods))
  assert_true(r.reactors[1].rods ~= r.reactors[2].rods,
    'eine gemeinsame Entscheidung fuer beide waere genau der Fehler')
end

print('rt2_two_reactor_test.lua: ok')
