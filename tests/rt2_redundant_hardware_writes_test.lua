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
  local w = writes(counts)
  assert_true(w == 0, string.format(
    'im Beharrungszustand darf NICHTS geschrieben werden, es waren %d Zugriffe'
      .. ' (Spule %d, Staebe %d, Durchfluss %d, Aktiv %d)',
    w, counts.setInductorEngaged or 0, counts.setAllControlRodLevels or 0,
    counts.setFluidFlowRateMax or 0, counts.setActive or 0))
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

-- ── 4. Eine Sicherheitsausloesung wird IMMER geschrieben ─────────────────
--
-- Schutzentscheidungen haengen nicht am Dirty-Check: stehen die Staebe
-- schon auf 100, wird trotzdem geschrieben. Eine Bremsung darf nie an
-- einer Ersparnis scheitern.
do
  local rt2_adapter = require('nodes.rt.rt2_adapter')
  local calls = {}
  local fake = {
    apply_rod_level = function(name, level) calls[#calls + 1] = level; return true end,
  }
  rt2_adapter.apply_reactor(fake, 'r', 'RT',
    { rods = 100, reason = 'SAFETY_FULL_INSERT', safety_tripped = true },
    { current_rods = 100 })
  assert_true(#calls == 1,
    'SAFETY_FULL_INSERT muss geschrieben werden, auch wenn die Staebe schon stehen')

  calls = {}
  rt2_adapter.apply_reactor(fake, 'r', 'RT',
    { rods = 100, reason = 'NO_STEAM_READING' }, { current_rods = 100 })
  assert_true(#calls == 1,
    'NO_STEAM_READING muss geschrieben werden, auch wenn die Staebe schon stehen')

  calls = {}
  rt2_adapter.apply_reactor(fake, 'r', 'RT',
    { rods = 94, reason = 'DEADBAND' }, { current_rods = 94 })
  assert_true(#calls == 0, 'DEADBAND auf unveraenderter Stellung darf nicht schreiben')

  -- Ganzzahlvergleich: der Mod speichert Stabstellungen ganzzahlig, und
  -- apply_rod_level() rundet beim Schreiben genauso.
  calls = {}
  rt2_adapter.apply_reactor(fake, 'r', 'RT',
    { rods = 94.4, reason = 'TANK_LOW_WITHDRAW' }, { current_rods = 94 })
  assert_true(#calls == 0,
    '94,4 gegen gemessene 94 ist nach dem Runden dieselbe Stellung')

  calls = {}
  rt2_adapter.apply_reactor(fake, 'r', 'RT',
    { rods = 94.6, reason = 'TANK_LOW_WITHDRAW' }, { current_rods = 94 })
  assert_true(#calls == 1, '94,6 rundet auf 95 und muss geschrieben werden')

  -- Unbekannter Messwert ist nie ein Grund, das Schreiben zu unterlassen.
  calls = {}
  rt2_adapter.apply_reactor(fake, 'r', 'RT',
    { rods = 94, reason = 'DEADBAND' }, { current_rods = nil })
  assert_true(#calls == 1, 'ohne Messwert muss geschrieben werden')
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
