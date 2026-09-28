package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- capacity_max MUSS die Leistung der GANZEN Flotte sein.
--
-- MASTER und Knoten lesen denselben Prozentsatz verschieden:
--
--   MASTER (master/rt_sync.lua):  assigned_power = capacity * pct / 100
--                                 -- Anteil der LEISTUNG
--   Knoten (rt2_turbine.lua):     running_count  = pct / 100 * turbine_count
--                                 -- Anteil der TURBINEN
--
-- Das geht nur auf, wenn capacity_max beschreibt, was die Flotte liefert,
-- wenn ALLE Turbinen laufen. Meldet der Knoten stattdessen die Summe
-- dessen, was gerade laeuft, ist MASTERs Aufteilung um genau den Faktor
-- daneben, mit dem er den Knoten gerade faehrt -- und dieser Fehler
-- verstaerkt sich: haelt MASTER den Knoten auf 50 %, meldet der die halbe
-- Wahrheit, MASTER teilt erneut dagegen auf, und so weiter.
--
-- Deshalb wird an einem sauberen Betriebspunkt gemessen (jede Turbine, die
-- laufen SOLL, steht am Ziel und ist gekuppelt) und auf die Flottengroesse
-- hochgerechnet.

local orchestrator = require('nodes.rt.rt2_orchestrator')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- n Turbinen, davon laufen die ersten `running` am Ziel und gekuppelt.
local function fleet(n, running)
  local t = {}
  for i = 1, n do
    local runs = i <= running
    t[i] = {
      name = 'T' .. i,
      rpm = runs and 900 or 0,
      energy = runs and 100 or 0,
      coil_engaged = runs,
      current_flow = runs and 1200 or 0,
    }
  end
  return t
end

-- ══ 1. MASTER haelt den Knoten auf 50 % -- die Meldung bleibt voll ═══════

do
  local o = orchestrator.new()
  o.note_master_seen(0)
  -- Erster Takt: noch nichts gemessen, also faehrt die ganze Flotte.
  o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 50,
    turbines = fleet(50, 0), reactor = {} })

  local r
  for i = 2, 6 do
    r = o.tick({ now_ms = i * 1000, hardware_ready = true, master_percent = 50,
      turbines = fleet(50, 25), reactor = {} })
  end

  assert_eq(r.capacity.running, 25, 'Vorbedingung: MASTER faehrt nur die halbe Flotte')
  assert_eq(r.capacity.at_target, 25, 'und die laufende Haelfte steht am Ziel')
  assert_eq(r.capacity.observed, 2500, 'geflossen sind dabei nur 2500 RF/t')
  assert_eq(r.capacity.max_output, 5000,
    'gemeldet werden MUSS die ganze Flotte (50 x 100) -- sonst teilt MASTER'
      .. ' gegen die halbe Wahrheit auf')
  assert_eq(r.capacity.reason, 'MEASURED')
end

-- ══ 2. Ein unsauberer Betriebspunkt zaehlt nicht als Messung ════════════
--
-- Die ALTE Formel rechnete aus den Turbinen hoch, die zufaellig gerade am
-- Ziel waren, WAEHREND andere es verfehlten -- und erfand damit Leistung
-- fuer Turbinen, die sie nachweislich nicht brachten. Genau das darf nicht
-- wieder passieren.
do
  local o = orchestrator.new()
  -- 5 Turbinen sollen laufen (AUTONOM, also alle), 4 schaffen es.
  local mixed = fleet(5, 4)
  mixed[5].rpm = 780          -- laeuft, aber verfehlt das Ziel
  mixed[5].coil_engaged = false
  mixed[5].energy = 0

  local r
  for i = 1, 4 do
    r = o.tick({ now_ms = i * 1000, hardware_ready = true, turbines = mixed, reactor = {} })
  end

  assert_eq(r.capacity.running, 5, 'alle fuenf sollen laufen')
  assert_eq(r.capacity.at_target, 4, 'aber nur vier stehen am Ziel')
  assert_eq(r.capacity.reason, 'OBSERVED',
    'ein unsauberer Betriebspunkt darf nicht als Messung gelten')
  assert_eq(r.capacity.max_output, 400,
    'gemeldet wird dann der rohe Hoechstausstoss (400), nicht (400/4)*5 = 500')
end

-- ══ 3. Der Rueckfallwert haelt die Sackgasse offen ══════════════════════
--
-- Eine dampfarme Anlage erreicht den sauberen Betriebspunkt womoeglich
-- nie. Ohne Rueckfall stuende capacity_max dort fuer immer auf 0 und MASTER
-- wuerde den Knoten nie zuteilen -- das war die Sackgasse der alten
-- Lernphase.
do
  local o = orchestrator.new()
  local starved = fleet(10, 10)
  for i = 1, 10 do
    starved[i].rpm = 600        -- keine einzige erreicht je ihr Ziel
    starved[i].coil_engaged = false
    starved[i].energy = 20
  end

  local r
  for i = 1, 4 do
    r = o.tick({ now_ms = i * 1000, hardware_ready = true, turbines = starved, reactor = {} })
  end

  assert_true(r.capacity.ready,
    'auch eine Anlage, die ihr Ziel nie erreicht, muss MASTER eine Zahl melden')
  assert_eq(r.capacity.reason, 'OBSERVED')
  assert_eq(r.capacity.max_output, 200, 'naemlich das, was wirklich fliesst')
end

-- ══ 4. Die Messung loest den Rueckfallwert ab, sobald sie da ist ════════

do
  local o = orchestrator.new()
  -- Erst unsauber: 3 von 4 am Ziel.
  local ramping = fleet(4, 3)
  ramping[4].rpm = 700
  ramping[4].coil_engaged = false
  ramping[4].energy = 0
  local r = o.tick({ now_ms = 1000, hardware_ready = true, turbines = ramping, reactor = {} })
  r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = ramping, reactor = {} })
  assert_eq(r.capacity.reason, 'OBSERVED')
  assert_eq(r.capacity.max_output, 300)

  -- Dann kommt die vierte dazu -- jetzt ist der Punkt sauber.
  r = o.tick({ now_ms = 3000, hardware_ready = true, turbines = fleet(4, 4), reactor = {} })
  assert_eq(r.capacity.reason, 'MEASURED', 'sobald alle am Ziel stehen, gilt die Messung')
  assert_eq(r.capacity.max_output, 400)
end

-- ══ 5. Eine geaenderte Flottengroesse wirft die Messung weg ═════════════

do
  local o = orchestrator.new()
  local r = o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(4, 4), reactor = {} })
  assert_eq(r.capacity.max_output, 400)

  -- Eine Turbine abgebaut: die alte Zahl darf nicht weiterleben.
  r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet(3, 3), reactor = {} })
  assert_eq(r.capacity.total_turbines, 3)
  assert_eq(r.capacity.max_output, 300, 'die Messung gilt nur fuer die Flotte, an der sie entstand')
end

-- ══ 6. Im SAFE wird nicht gemessen ══════════════════════════════════════
--
-- Der Durchfluss ist dort erzwungen 0; was die Flotte dann liefert,
-- beschreibt ihre Leistung nicht.
do
  local o = orchestrator.new()
  local r = o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(4, 4), reactor = {} })
  assert_eq(r.capacity.max_output, 400)

  r = o.tick({ now_ms = 2000, hardware_ready = true, safety_tripped = true,
    turbines = fleet(4, 0), reactor = {} })
  assert_eq(r.capacity.max_output, 400, 'die Messung ueberlebt eine Ausloesung unveraendert')
end

print('rt2_capacity_is_full_fleet_test.lua: ok')
