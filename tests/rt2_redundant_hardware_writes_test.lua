package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Keine wirkungslosen Schreibzugriffe auf die Hardware.
--
-- Die Taktzeit der Regelschleife ergibt sich aus der Summe der
-- Peripherieaufrufe je Takt (nodes/rt/main.lua's RECEIVE_TIMEOUT gibt 100 ms
-- VOR, haelt sie aber nicht ein, wenn ein Durchgang laenger braucht). Sie
-- ist damit die Groesse, an der mehrere Betriebsmeldungen dieser Anlage
-- hingen -- bis hin zu "MASTER DOWN", weil ein blockierender Durchgang den
-- Heartbeat verpasste.
--
-- Der Durchfluss hatte seinen Dirty-Check seit v7xx. Spule und Staebe
-- wurden dagegen BEDINGUNGSLOS in jedem Takt geschrieben. Am
-- quelltextnahen Anlagenmodell gemessen, 6 Turbinen im eingeschwungenen
-- Beharrungszustand (nichts zu tun), 600 Takte:
--
--   setInductorEngaged      3600   6.00/Takt
--   setAllControlRodLevels   600   1.00/Takt
--   setFluidFlowRateMax        0   0.00/Takt
--
-- Sieben Schreibzugriffe je Takt, von denen keiner etwas veraenderte. Bei
-- 50 Turbinen waeren es 510 je Sekunde.
--
-- Dieser Test haelt fest, dass eine Anlage, an der nichts zu stellen ist,
-- auch nichts stellt -- und dass eine echte Aenderung trotzdem ankommt.

local harness = require('support.er_rt_harness')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local WRITE_METHODS = {
  setInductorEngaged = true,
  setAllControlRodLevels = true,
  setFluidFlowRateMax = true,
  setActive = true,
}

-- Zaehlt Peripherieaufrufe nach Methodenname. Muss NACH harness.new()
-- gelegt werden, weil das _G.peripheral dort neu aufgebaut wird.
local function count_calls(h)
  local inner = _G.peripheral.call
  local counts = {}
  _G.peripheral.call = function(name, method, ...)
    counts[method] = (counts[method] or 0) + 1
    return inner(name, method, ...)
  end
  return counts
end

local function reset(counts)
  for k in pairs(counts) do counts[k] = nil end
end

local function writes(counts)
  local n = 0
  for method, c in pairs(counts) do
    if WRITE_METHODS[method] then n = n + c end
  end
  return n
end

-- ── 1. Beharrungszustand: keine wirkungslosen Schreibzugriffe ────────────
--
-- steam_capacity 20000 ist der REALISTISCHE Tank: der interne Dampftank
-- eines Reaktors fasst 1000 mB je Kuehlmittelport, also in der
-- Groessenordnung eines Ticks Flottenbedarf. In dieser Auslegung sitzt die
-- Stabregelung am Anschlag (Staebe fest auf rt2_reactor.ROD_MIN, Tank
-- unter dem Sollwert) -- der Zustand, den rt2_reactor.lua ausdruecklich als
-- den gesunden beschreibt. Nachgemessen ueber Reaktorreserven von 1,15 bis
-- 4,0: alle sechs Turbinen gekuppelt im Zielband, 899 RPM, Staebe
-- unveraendert auf 70.
--
-- Mit einem unrealistisch GROSSEN Tank (200000+) schwingt die Stabregelung
-- dagegen, und dann sind Stabschreibzugriffe keine Verschwendung, sondern
-- echte Stellbewegungen -- dieser Test waere dort zu Recht rot und wuerde
-- das Falsche messen.
do
  local h = harness.new({ turbine_count = 6, reactor_headroom = 2.0, steam_capacity = 20000 })
  local counts = count_calls(h)
  h:run(400)                     -- einlernen und einschwingen lassen

  -- Nachweis, dass wirklich der RUHIGE Betriebsfall vorliegt: alle
  -- Turbinen gekuppelt und im Zielband. Ohne diese Vorbedingung wuerde
  -- der Test auch gruen, wenn die Anlage nur stillsteht.
  local in_band = 0
  for _, name in ipairs(h.turbine_names) do
    local t = h.plant.turbines[name]
    if t.inductor_engaged and math.abs(t:rotor_speed() - 900) <= 15 then
      in_band = in_band + 1
    end
  end
  assert_true(in_band == #h.turbine_names, string.format(
    'Vorbedingung: alle %d Turbinen muessen gekuppelt im Zielband stehen, es sind %d',
    #h.turbine_names, in_band))

  reset(counts)
  h:run(60)                      -- 600 Takte Messfenster

  -- Spule und Durchfluss: nichts zu stellen, also nichts geschrieben.
  assert_true((counts.setInductorEngaged or 0) == 0, string.format(
    'die Spule darf im Beharrungszustand nicht geschrieben werden, es waren %d Zugriffe',
    counts.setInductorEngaged or 0))
  assert_true((counts.setFluidFlowRateMax or 0) == 0, string.format(
    'der Durchfluss darf im Beharrungszustand nicht geschrieben werden, es waren %d Zugriffe',
    counts.setFluidFlowRateMax or 0))
  assert_true((counts.setActive or 0) == 0,
    'und nichts muss eingeschaltet werden')

  -- Die STAEBE dagegen werden bewusst in jedem Takt geschrieben. Siehe den
  -- Kopf von rt2_adapter.apply_reactor(): control_rod_level ist der
  -- MITTELWERT ueber alle Staebe, und das bedingungslose Schreiben ist die
  -- Selbstheilung fuer ungleich stehende Staebe. In v808 war hier ein
  -- Dirty-Check, der genau diese Eigenschaft entfernt hat -- ein Reaktor mit
  -- ungleichen Staeben blieb damit stehen, weil der Mittelwert auf dem
  -- Sollwert lag.
  assert_true((counts.setAllControlRodLevels or 0) == 600, string.format(
    'die Staebe muessen in JEDEM Takt geschrieben werden (Selbstheilung bei'
      .. ' ungleichen Staeben), es waren %d von 600',
    counts.setAllControlRodLevels or 0))
end

-- ── 2. Von aussen umgeschaltete Spule wird zurueckgestellt ───────────────
--
-- Der Dirty-Check vergleicht gegen den MESSWERT, nicht gegen die letzte
-- eigene Entscheidung. Genau deshalb heilt er einen von Hand (oder durch
-- einen Chunk-Reload) umgeschalteten Induktor von selbst.
do
  local h = harness.new({ turbine_count = 6, reactor_headroom = 2.0, steam_capacity = 20000 })
  local counts = count_calls(h)
  h:run(400)

  local victim = h.plant.turbines[h.turbine_names[1]]
  assert_true(victim.inductor_engaged == true,
    'Vorbedingung: die Turbine muss gekuppelt sein')

  reset(counts)
  victim.inductor_engaged = false        -- Eingriff von aussen
  h:run(1)                               -- 10 Takte
  assert_true(victim.inductor_engaged == true,
    'eine von aussen geloeste Spule muss der Regler wieder einhaengen')
  assert_true((counts.setInductorEngaged or 0) >= 1,
    'dafuer muss die Spule auch wirklich geschrieben worden sein')
end

-- ── 3. Von aussen verstellte Staebe werden zurueckgestellt ───────────────
--
-- Das deckt der bedingungslose Schreibweg ab (siehe Block 1). Der Test
-- bleibt, weil er die EIGENSCHAFT prueft, nicht die Umsetzung: egal wie der
-- Schreibweg spaeter aussieht, ein von aussen verstellter Stab muss
-- zurueckkommen.
do
  local h = harness.new({ turbine_count = 6, reactor_headroom = 2.0, steam_capacity = 20000 })
  local counts = count_calls(h)
  h:run(400)

  local r = h.plant.reactor
  local before = r.rods
  reset(counts)
  r.rods = before >= 50 and 20 or 90     -- Eingriff von aussen
  h:run(2)
  assert_true((counts.setAllControlRodLevels or 0) >= 1,
    'von aussen verstellte Staebe muessen wieder gestellt werden')
  assert_true(r.rods ~= (before >= 50 and 20 or 90),
    'und die Stellung muss sich dadurch auch geaendert haben, sie steht auf '
      .. tostring(r.rods))
end

-- ── 4. Der Stab-Schreibweg kennt keine Ausnahme ──────────────────────────
--
-- Jede Entscheidung wird geschrieben -- die gewoehnliche Tankregelung
-- genauso wie die Sicherheitsausloesung. Festgehalten, damit ein kuenftiger
-- Spar-Versuch hier auffaellt: wer das aendert, braucht zuerst die
-- Information, ob die Staebe UNTEREINANDER gleich stehen (siehe den
-- Modulkopf), denn control_rod_level ist nur ihr Mittelwert.
do
  local rt2_adapter = require('nodes.rt.rt2_adapter')
  local calls = {}
  local fake = {
    apply_rod_level = function(name, level) calls[#calls + 1] = level; return true end,
  }

  for _, case in ipairs({
    { rods = 100, reason = 'SAFETY_FULL_INSERT', safety_tripped = true },
    { rods = 100, reason = 'NO_STEAM_READING' },
    { rods = 94,  reason = 'DEADBAND' },
    { rods = 94,  reason = 'RATE_LIMITED' },
    { rods = 94,  reason = 'CONVERGING' },
    { rods = 92,  reason = 'TANK_LOW_WITHDRAW' },
  }) do
    calls = {}
    rt2_adapter.apply_reactor(fake, 'r', 'RT', case)
    assert_true(#calls == 1,
      'jede Stabentscheidung muss geschrieben werden, auch ' .. case.reason)
  end
end

-- ── 5. Unlesbare Spule: immer schreiben ──────────────────────────────────
do
  local rt2_adapter = require('nodes.rt.rt2_adapter')
  local sets = {}
  local fake = {
    set_flow = function() return true end,
    set_coils = function(_, enabled) sets[#sets + 1] = enabled; return true end,
  }
  -- coil_known = false (adapters/turbine.lua macht aus einem fehlenden
  -- getInductorEngaged ein coil_engaged = false)
  rt2_adapter.apply_turbine(fake, 't', 'RT', {
    flow_decision = { flow = 0, unchanged = true },
    coil_decision = { engaged = false }, coil_engaged = false, coil_known = false,
  })
  assert_true(#sets == 1,
    'ohne lesbaren Spulenzustand muss geschrieben werden -- unbekannt ist kein "steht schon"')

  sets = {}
  rt2_adapter.apply_turbine(fake, 't', 'RT', {
    flow_decision = { flow = 0, unchanged = true },
    coil_decision = { engaged = false }, coil_engaged = false, coil_known = true,
  })
  assert_true(#sets == 0, 'lesbar und gleich: nicht schreiben')

  sets = {}
  rt2_adapter.apply_turbine(fake, 't', 'RT', {
    flow_decision = { flow = 0, unchanged = true },
    coil_decision = { engaged = true }, coil_engaged = false, coil_known = true,
  })
  assert_true(#sets == 1 and sets[1] == true, 'lesbar und verschieden: schreiben')
end

-- ── 6. read_turbine fuehrt coil_known aus den features ───────────────────
do
  local rt2_adapter = require('nodes.rt.rt2_adapter')
  local with = rt2_adapter.read_turbine('t', {
    rpm = 900, flow = 2000, energy = 1, coil_engaged = true,
    features = { coils = true },
  })
  assert_true(with.coil_known == true, 'features.coils = true -> coil_known')

  local without = rt2_adapter.read_turbine('t', {
    rpm = 900, flow = 2000, energy = 1, coil_engaged = false,
    features = { coils = false },
  })
  assert_true(without.coil_known == false, 'features.coils = false -> nicht bekannt')

  local none = rt2_adapter.read_turbine('t', { rpm = 900 })
  assert_true(none.coil_known == false, 'ohne features-Tabelle gilt der Zustand als unbekannt')
end

print('ok rt2_redundant_hardware_writes_test')
