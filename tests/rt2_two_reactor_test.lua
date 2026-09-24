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
local rt2_capacity = require('nodes.rt.rt2_capacity')
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
      'beim Einlernen bekommt jede Turbine das volle Ziel')
    assert_true(t.unit == nil, 'eine Zuordnung zu einem Reaktor gibt es bewusst nicht')
  end
end

-- ── Eingelernt wird EINMAL, fuer den ganzen Knoten ───────────────────────

do
  local o = new_node()
  local now, r = 1000, nil
  for _ = 1, 6 do
    r = o.tick({
      now_ms = now, hardware_ready = true,
      turbines = fleet(30, 900, 100),
      reactors = reactors(0.5, 0.5),
    })
    now = now + rt2_capacity.STABLE_MS
  end
  assert_true(r.capacity.ready, 'die Flotte muss sich ausmessen lassen')
  -- 30 Turbinen x 100 RF/t, abzueglich 5 % Reserve -- unabhaengig davon,
  -- wie viele Reaktoren den Dampf dafuer liefern.
  assert_eq(r.capacity.max_output, 3000 * (1 - rt2_capacity.SAFETY_MARGIN))
  assert_eq(r.capacity.total_turbines, 30)
  assert_eq(r.state, rt2_state.states.AUTONOM, 'und danach laeuft der Knoten')
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
    now = now + rt2_capacity.STABLE_MS
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

-- ── Jeder Reaktor vermisst sich selbst ───────────────────────────────────

do
  -- Zwei verschieden traege Anlagen an einem Knoten: die Selbstvermessung
  -- muss je Reaktor laufen, sonst bekaeme der eine die Stellwerte des
  -- anderen.
  local o = new_node()
  local now = 1000
  local fill_a, fill_b = 0.5, 0.5
  -- Die Staebe muessen jeweils ein paar Takte STILLSTEHEN -- nur dann
  -- entsteht ueberhaupt ein Messwert (rt2_tuning misst die Fuellrate bei
  -- konstanter Stabstellung).
  for i = 1, 200 do
    local level = math.floor((i - 1) / 4) % 12
    local rods_a = 78 + level
    local rods_b = 78 + level
    o.tick({
      now_ms = now, hardware_ready = true,
      turbines = fleet(20, 900, 100),
      reactors = {
        { name = 'R_A', reactor = { fill_ratio = fill_a, current_rods = rods_a, active = true } },
        { name = 'R_B', reactor = { fill_ratio = fill_b, current_rods = rods_b, active = true } },
      },
    })
    -- A reagiert zehnmal traeger als B.
    fill_a = math.max(0.05, math.min(0.95, fill_a + (85 - rods_a) * 0.0006))
    fill_b = math.max(0.05, math.min(0.95, fill_b + (85 - rods_b) * 0.006))
    now = now + 1000
  end
  local a, b = o.reactors[1].tuning_profile, o.reactors[2].tuning_profile
  assert_true(a ~= nil and b ~= nil, 'beide Reaktoren muessen sich vermessen lassen')
  assert_true(b.gain > a.gain,
    'die flinkere Anlage muss die groessere Verstaerkung messen: A=' ..
    string.format('%.5f', a.gain) .. ' B=' .. string.format('%.5f', b.gain))
  assert_true(a.min_adjust_interval_ms >= b.min_adjust_interval_ms,
    'und die traegere ein laengeres Stellintervall bekommen')
end

print('rt2_two_reactor_test.lua: ok')
