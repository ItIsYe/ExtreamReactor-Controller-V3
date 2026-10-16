package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Audit-Befund R01, BEWUSST nicht im Verhalten geaendert.
--
-- Waehrend des Einlernens faehrt die Flotte auf 100 %, auch wenn MASTER
-- weniger vorgibt -- einschliesslich eines ausdruecklichen 0-%-Holds. Das
-- Audit stuft das als P1 ein, weil eine als 0 % uebermittelte Pause damit
-- keine verlaessliche Stillsetzfunktion ist.
--
-- Betreiberentscheidung: die KALIBRIERUNG GEWINNT IMMER. Ohne diesen
-- Vorrang gaebe es einen Start-Deadlock -- MASTER teilt seinen Bedarf
-- gegen capacity_max auf, das beim Start 0 ist, also kaeme 0 % zurueck,
-- also liefe keine Turbine, also floesse nichts, also bliebe capacity_max
-- 0. Dieser Test haelt die Entscheidung fest, damit sie niemand
-- versehentlich "repariert".
--
-- Was sich geaendert hat, ist ausschliesslich die SICHTBARKEIT: der
-- Vorrang wird gemeldet, steht im Status, und der Weg zum echten Anhalten
-- (SCRAM) ist benannt.

local harness = require('support.er_rt_harness')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

local function with_master(h)
  return function(self) self.engine.note_master_seen(self.clock_ms) end
end

-- 1. Der Vorrang gilt -- und ist ablesbar.
do
  local h = harness.new({ turbine_count = 4, reactor_headroom = 4.0, steam_capacity = 20000 })
  for _ = 1, 30 do h:step(with_master(h)) end

  local res = h.engine.handle_command({ target = 'SET_SETPOINTS',
    value = { power_target_percent = 0 } })
  assert_eq(res.ok, true, 'der Befehl wird angenommen')

  for _ = 1, 30 do
    h:step(function(self)
      self.engine.note_master_seen(self.clock_ms)
      self.engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 0 } })
    end)
  end

  assert_eq(h.last.capacity.learning, true, 'Vorbedingung: der Knoten lernt noch ein')
  assert_eq(h.last.master_percent, 0, 'die MASTER-Vorgabe ist angekommen')
  assert_eq(h.last.effective_percent, 100,
    'und wird waehrend des Einlernens bewusst ueberstimmt -- Kalibrierung gewinnt')

  local flow = 0
  for _, n in ipairs(h.turbine_names) do flow = flow + h.plant.turbines[n].max_intake_rate end
  assert_true(flow > 0, 'die Flotte faehrt also weiter -- genau das ist der gewollte Vorrang')

  -- Und das steht im Status, statt dass der Schirm die MASTER-Vorgabe
  -- zeigt, waehrend der Knoten etwas anderes tut.
  local status = h.engine.status_fields()
  assert_eq(status.calibration_overrides_master, true,
    'der Vorrang muss im Status ablesbar sein')
  assert_eq(status.effective_percent, 100,
    'und die tatsaechlich wirksame Vorgabe ebenso')
  assert_eq(status.master_percent, 0, 'neben der uebermittelten')

  -- Gemeldet wird er genau einmal, nicht in jedem Takt.
  local announced = 0
  for _, line in ipairs(h.logged) do
    if line:find('EINLERNEN hat Vorrang', 1, true) then announced = announced + 1 end
  end
  assert_eq(announced, 1, 'der Vorrang gehoert einmal gemeldet, nicht pro Takt')
  local names_scram = false
  for _, line in ipairs(h.logged) do
    if line:find('SCRAM', 1, true) then names_scram = true end
  end
  assert_true(names_scram, 'die Meldung muss den Weg zum echten Anhalten benennen')
end

-- 2. Ohne Abweichung wird nichts gemeldet und nichts behauptet.
do
  local h = harness.new({ turbine_count = 4, reactor_headroom = 4.0, steam_capacity = 20000 })
  for _ = 1, 60 do
    h:step(function(self)
      self.engine.note_master_seen(self.clock_ms)
      self.engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 100 } })
    end)
  end
  local status = h.engine.status_fields()
  assert_eq(status.calibration_overrides_master, false,
    'bei uebereinstimmender Vorgabe wird kein Vorrang behauptet')
  for _, line in ipairs(h.logged) do
    assert_true(not line:find('EINLERNEN hat Vorrang', 1, true),
      'und nichts gemeldet')
  end
end

-- 3. SCRAM ist der Halt, der in JEDEM Zustand wirkt -- auch waehrend des
--    Einlernens. Das ist die Gegenleistung fuer den Vorrang oben.
do
  local h = harness.new({ turbine_count = 4, reactor_headroom = 4.0, steam_capacity = 20000 })
  for _ = 1, 30 do h:step(with_master(h)) end
  assert_eq(h.last.capacity.learning, true, 'Vorbedingung: es wird eingelernt')

  local res = h.engine.handle_command({ target = 'SCRAM' })
  assert_eq(res.ok, true, 'SCRAM wird in jedem Zustand angenommen')
  for _ = 1, 20 do h:step(with_master(h)) end

  assert_eq(h.last.state, 'SAFE', 'und fuehrt in den sicheren Zustand')
  local flow = 0
  for _, n in ipairs(h.turbine_names) do flow = flow + h.plant.turbines[n].max_intake_rate end
  assert_eq(flow, 0, 'dort fliesst kein Dampf mehr')
  assert_eq(h.plant.reactor.rods, 100, 'und die Staebe sind voll eingefahren')
end

print('rt2_calibration_precedence_test.lua: ok')
