package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: das Einlernen endete NIE, wenn die Flotte sich gut verhielt.
--
-- Der Rotor naehert sich der Zieldrehzahl asymptotisch (siehe
-- tests/support/er_plant_model.lua: rpm ist ein Integrator), und die
-- Leistung steigt mit ihm monoton. Die Abbruchbedingung lautete aber
--
--     if output > state.best_output then ... last_improved_ms = now_ms end
--
-- -- ein strikter Groesser-Vergleich auf einem asymptotisch steigenden
-- Gleitkommawert wird nie falsch. Die Stabilitaetsuhr startete also in
-- jedem Takt neu, mit immer kleineren Schritten. Gemessen am
-- Anlagenmodell, vier Turbinen alle im Zielband:
--
--     t= 240s best=96127 ... t=1140s best=96408 ... t=2000s noch LEARNING
--
-- Die Folge waren drei Symptome, die nach drei Fehlern aussahen:
--   * learning=true haelt effective_percent dauerhaft auf 100 (die
--     Kalibrierung hat Vorrang) -- die MASTER-Vorgabe blieb wirkungslos,
--     "Master 0 %, Turbinen trotzdem auf 100 %".
--   * capacity_ready blieb false -- der MASTER bekam keinen brauchbaren
--     Wert und zeigte 0 %.
--   * Ein Wert WURDE gemessen (best_output stieg), also sah es aus, als
--     funktioniere das Einlernen.
--
-- Nur eine Verbesserung um mindestens LEARN_MIN_IMPROVEMENT startet die
-- Uhr jetzt neu. Der gemeldete Hoechstwert wird weiter bei JEDER
-- Verbesserung nachgezogen -- sonst endete das Einlernen unter dem
-- tatsaechlich gemessenen Wert.

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_state = require('nodes.rt.rt2_state')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

local TARGET = orchestrator.TARGET_RPM
local N = 4

-- Eine Flotte, die im Zielband steht und deren Ausstoss sich einem
-- Grenzwert naehert -- genau das Verhalten des echten Rotors.
local function fleet(energy_each)
  local out = {}
  for i = 1, N do
    out[i] = { name = 'turbine_' .. i, rpm = TARGET, current_flow = 1500,
               coil_engaged = true, active = true, energy = energy_each }
  end
  return out
end

local function new_engine()
  local e = orchestrator.new({ initial_state = rt2_state.states.AUTONOM,
                               reactors = { { name = 'reactor_0' } } })
  return e
end

local function reactor_input()
  return { { name = 'reactor_0', safety_tripped = false,
             reactor = { fill_ratio = 0.7, current_rods = 80, active = true,
                         temperature = 800, coolant_ratio = 0.9,
                         coolant_amount = 9000, coolant_amount_max = 10000 } } }
end

-- 1. Der eigentliche Fehler: ein asymptotisch steigender Ausstoss.
do
  local engine = new_engine()
  local now, limit, settled_at, last = 0, 24000.0, nil, nil
  local energy = 20000.0
  for tick = 1, 20000 do
    now = now + 100
    -- Asymptotische Annaeherung an den Grenzwert: der Zuwachs wird immer
    -- kleiner, bleibt aber in jedem Takt positiv. Genau hier lief der
    -- strikte Groesser-Vergleich endlos.
    energy = energy + (limit - energy) * 0.002
    last = engine.tick({ now_ms = now, hardware_ready = true,
                         turbines = fleet(energy), reactors = reactor_input() })
    if not last.capacity.learning and not settled_at then settled_at = tick end
  end
  assert_true(settled_at ~= nil,
    'das Einlernen MUSS enden, auch wenn der Ausstoss asymptotisch weiter steigt')
  assert_eq(last.capacity.ready, true, 'und capacity_ready muss true werden')
  assert_eq(last.capacity.reason, orchestrator.MEASURED)
  assert_true(last.capacity.max_output > 0, 'mit einem Wert > 0')
  -- Die Uhr darf nicht erst nach Minuten ablaufen.
  assert_true(settled_at * 100 <= 60000, string.format(
    'und zwar in angemessener Zeit (war %.1f s)', settled_at / 10))
end

-- 2. Der gemeldete Hoechstwert bleibt der tatsaechlich gemessene -- die
--    Schwelle bremst nur die Uhr, nicht die Messung.
do
  local engine = new_engine()
  local now, energy, best_seen = 0, 20000.0, 0
  for _ = 1, 2000 do
    now = now + 100
    energy = energy + (24000.0 - energy) * 0.002
    if energy > best_seen then best_seen = energy end
    local r = engine.tick({ now_ms = now, hardware_ready = true,
                            turbines = fleet(energy), reactors = reactor_input() })
    if not r.capacity.learning then
      -- Nach dem Einlernen fuehrt die Nachfuehrung nach oben weiter --
      -- der gemeldete Wert darf also nie UNTER dem liegen, was zu diesem
      -- Zeitpunkt gemessen war.
      assert_true(r.capacity.best_output >= best_seen * 0.995, string.format(
        'der gemeldete Hoechstwert (%.0f) darf nicht unter dem gemessenen liegen (%.0f)',
        r.capacity.best_output, best_seen))
    end
  end
end

-- 3. Eine ECHTE Verbesserung startet die Uhr weiterhin neu. Sonst wuerde
--    die Schwelle das Einlernen zu frueh beenden, waehrend die Anlage noch
--    hochlaeuft.
do
  local engine = new_engine()
  local now = 0
  -- Erst einschwingen lassen, bis die Uhr fast abgelaufen ist.
  for _ = 1, 50 do
    now = now + 100
    engine.tick({ now_ms = now, hardware_ready = true,
                  turbines = fleet(20000), reactors = reactor_input() })
  end
  -- Jetzt ein deutlicher Sprung (z.B. zurueckkehrender Dampf): die Uhr
  -- muss neu starten, das Einlernen also weiterlaufen.
  local r
  for _ = 1, 55 do
    now = now + 100
    r = engine.tick({ now_ms = now, hardware_ready = true,
                      turbines = fleet(40000), reactors = reactor_input() })
  end
  assert_eq(r.capacity.learning, true,
    'ein deutlicher Leistungssprung muss die Stabilitaetsuhr neu starten')
  assert_true(r.capacity.best_output >= 40000 * 0.99, 'und der Hoechstwert muss mitgehen')
end

-- 4. Durchstich: nach dem Einlernen wirkt die MASTER-Vorgabe wieder.
--    Das ist das Symptom, mit dem es gemeldet wurde.
do
  local harness = require('support.er_rt_harness')
  local h = harness.new({ turbine_count = 4, reactor_headroom = 4.0, steam_capacity = 20000 })

  local done
  for i = 1, 20000 do
    h:step(function(s) s.engine.note_master_seen(s.clock_ms) end)
    if h.last.capacity and not h.last.capacity.learning then done = i; break end
  end
  assert_true(done ~= nil, 'das Einlernen muss am Anlagenmodell enden')
  assert_eq(h.engine.status_fields().capacity_ready, true,
    'der MASTER braucht capacity_ready = true, sonst nimmt er den Wert nicht')
  assert_true(h.engine.status_fields().capacity_max > 0, 'und einen Wert > 0')

  local function total_flow()
    local f = 0
    for _, n in ipairs(h.turbine_names) do f = f + h.plant.turbines[n].max_intake_rate end
    return f
  end

  -- 0 % muss die Flotte parken.
  h.engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 0 } })
  for _ = 1, 100 do h:step(function(s) s.engine.note_master_seen(s.clock_ms) end) end
  assert_eq(h.last.effective_percent, 0,
    'nach dem Einlernen muss die MASTER-Vorgabe gelten -- 0 %% heisst 0 %%')
  assert_eq(total_flow(), 0, 'und die Flotte muss stehen')
  for _, t in ipairs(h.last.turbines or {}) do
    assert_eq(t.target_rpm, 0, 'jede Turbine auf Ziel 0')
  end

  -- 50 % muss einen Teil der Flotte fahren.
  h.engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } })
  for _ = 1, 100 do h:step(function(s) s.engine.note_master_seen(s.clock_ms) end) end
  assert_eq(h.last.effective_percent, 50)
  local running, parked = 0, 0
  for _, t in ipairs(h.last.turbines or {}) do
    if (t.target_rpm or 0) > 0 then running = running + 1 else parked = parked + 1 end
  end
  assert_true(running > 0 and parked > 0, string.format(
    'bei 50 %% muss ein Teil laufen und ein Teil stehen (laufend=%d, geparkt=%d)', running, parked))
  assert_true(total_flow() > 0, 'und es muss wieder Dampf fliessen')

  -- Und die Meldung "Kalibrierung hat Vorrang" darf jetzt nicht mehr kommen.
  for _, line in ipairs(h.logged) do
    assert_true(not line:find('EINLERNEN hat Vorrang', 1, true),
      'nach abgeschlossenem Einlernen darf die Kalibrierung nichts mehr ueberstimmen')
  end
end

print('rt2_learning_terminates_test.lua: ok')
