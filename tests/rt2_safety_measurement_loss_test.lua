package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: ein Ausfall der Sicherheitsmessungen blieb dauerhaft folgenlos.
--
-- rt2_safety reichte nur `triggered` weiter. Die Auswerter in core/safety.lua
-- stellen zwar "unavailable" fest (TEMP_UNAVAILABLE, COOLANT_UNAVAILABLE),
-- aber das kam hier nie an: `reason` wurde ausschliesslich bei einer
-- Ausloesung gesetzt. Gegenprobe vor dem Fix: 1000 Auswertungen ohne
-- Temperatur und ohne Kuehlmittel ergaben `{ tripped = false }` -- und zwar
-- buchstaeblich nur dieses eine Feld. Ein Verbraucher konnte "alles in
-- Ordnung" nicht von "ich sehe nichts" unterscheiden.
--
-- Zwei Dinge werden verlangt:
--   1. Die Messlage steht IMMER im Ergebnis, auch ohne Ausloesung.
--   2. Ein Kanal, der schon einmal gelesen wurde und dann ausfaellt,
--      loest nach einer endlichen Schonfrist aus.
--
-- Und zwei Dinge duerfen ausdruecklich NICHT passieren:
--   * Ein passiv gekuehlter Reaktor hat gar keinen Kuehlkreis
--     (core/fluid.lua's resolve_ratio liefert dauerhaft nil) -- der darf
--     nie wegen "Kuehlmittel fehlt" abschalten.
--   * Beim Start ist die Peripherie noch nicht gebunden -- auch das darf
--     nicht abschalten.
-- Beides deckt die klebrige ever_valid-Bedingung ab.

local rt2_safety = require('nodes.rt.rt2_safety')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

local LIMITS = {
  max_temperature = 2000, temperature_hysteresis = 50, temperature_trip_samples = 3,
  min_water = 0.10, coolant_hysteresis = 0.05, coolant_trip_samples = 3,
  coolant_invalid_grace_samples = 3,
}
local GRACE = rt2_safety.DEFAULT_MEASUREMENT_GRACE_SAMPLES

-- Betreibervorgabe: 30 Minuten bei 10 Hz Regeltakt. Hier festgehalten,
-- damit eine Aenderung dieser Zahl eine bewusste Entscheidung bleibt und
-- nicht nebenbei passiert -- sie bestimmt, wie lange ein echter
-- Sensorausfall unentdeckt bleibt.
assert_eq(GRACE, 18000, 'die Schonfrist ist auf 30 Minuten bei 10 Hz festgelegt')
assert_eq(GRACE / 10 / 60, 30, 'das sind 30 Minuten')

local HEALTHY = { temperature = 800, coolant_ratio = 0.8,
                  coolant_amount = 8000, coolant_amount_max = 10000 }

local function feed(state, reading, n, limits)
  local first_trip, last
  for i = 1, n do
    last = rt2_safety.evaluate(state, reading, limits or LIMITS)
    if last.tripped and not first_trip then first_trip = i end
  end
  return first_trip, last
end

-- 1. Die Messlage steht immer im Ergebnis.
do
  local out = rt2_safety.evaluate(rt2_safety.new_state(), HEALTHY, LIMITS)
  assert_eq(out.temperature_available, true)
  assert_eq(out.coolant_available, true)
  assert_true(out.temperature_condition ~= nil, 'die Temperaturlage gehoert ins Ergebnis')
  assert_true(out.coolant_condition ~= nil, 'die Kuehlmittellage gehoert ins Ergebnis')

  local blind = rt2_safety.evaluate(rt2_safety.new_state(), {}, LIMITS)
  assert_eq(blind.temperature_available, false, 'ein Messausfall muss ablesbar sein')
  assert_eq(blind.coolant_available, false)
  assert_eq(blind.temperature_condition, 'TEMP_UNAVAILABLE')
end

-- 2. Temperatur faellt nach gesundem Betrieb aus -> Ausloesung nach der Schonfrist.
do
  local state = rt2_safety.new_state()
  feed(state, HEALTHY, 10)
  local trip, last = feed(state, { coolant_ratio = 0.8, coolant_amount = 8000,
                                   coolant_amount_max = 10000 }, GRACE + 5)
  assert_eq(trip, GRACE + 1, 'die Ausloesung muss genau einen Takt nach der Schonfrist kommen')
  assert_eq(last.reason, 'TEMP_MEASUREMENT_LOST')
  assert_eq(last.temperature_available, false)
end

-- 3. Kuehlmittel faellt nach gesundem Betrieb aus -> ebenso.
do
  local state = rt2_safety.new_state()
  feed(state, HEALTHY, 10)
  local trip, last = feed(state, { temperature = 800 }, GRACE + 5)
  assert_eq(trip, GRACE + 1)
  assert_eq(last.reason, 'COOLANT_MEASUREMENT_LOST')
end

-- 4. Ein Aussetzer KUERZER als die Schonfrist loest nicht aus, und die
--    Rueckkehr setzt den Zaehler zurueck.
do
  local state = rt2_safety.new_state()
  feed(state, HEALTHY, 10)
  local trip = feed(state, {}, GRACE)
  assert_true(trip == nil, 'ein Aussetzer innerhalb der Schonfrist darf nicht ausloesen')
  local _, back = feed(state, HEALTHY, 5)
  assert_eq(back.tripped, false, 'nach der Rueckkehr ist die Lage wieder normal')
  assert_eq(back.temperature_missing_ticks, 0, 'der Zaehler muss zurueckgesetzt sein')
  -- und die volle Schonfrist gilt erneut
  local trip2 = feed(state, {}, GRACE)
  assert_true(trip2 == nil, 'nach der Erholung gilt die volle Schonfrist erneut')
end

-- 5. Passiv gekuehlter Reaktor: Kuehlmittel war NIE lesbar -> nie Ausloesung.
do
  local state = rt2_safety.new_state()
  local trip, last = feed(state, { temperature = 800 }, GRACE + 100)
  assert_true(trip == nil,
    'ein Reaktor ohne Kuehlkreis darf nicht wegen fehlendem Kuehlmittel abschalten --'
      .. ' auch nicht weit jenseits der Schonfrist')
  assert_eq(last.coolant_available, false, 'sichtbar bleibt es trotzdem')
  assert_eq(last.coolant_missing_ticks, 0, 'ein nie vorhandener Kanal zaehlt nicht')
end

-- 6. Start ohne gebundene Peripherie: gar nichts lesbar -> nie Ausloesung.
do
  local state = rt2_safety.new_state()
  local trip = feed(state, {}, GRACE + 100)
  assert_true(trip == nil, 'eine noch nicht gebundene Peripherie darf nicht abschalten')
end

-- 7. Ein echter Grenzwert gewinnt den Grund gegen einen Messausfall.
do
  local state = rt2_safety.new_state()
  feed(state, HEALTHY, 10)
  local _, last = feed(state, { temperature = 2500 }, GRACE + 10)
  assert_eq(last.tripped, true)
  assert_eq(last.reason, 'TEMP_LIMIT_PERSISTENT',
    'eine echte Ueberschreitung ist die konkretere Aussage als ein Messausfall')
end

-- 8. Die Schonfrist ist konfigurierbar.
do
  local limits = {}
  for k, v in pairs(LIMITS) do limits[k] = v end
  limits.measurement_grace_samples = 10
  local state = rt2_safety.new_state()
  feed(state, HEALTHY, 5, limits)
  local trip = feed(state, {}, 40, limits)
  assert_eq(trip, 11, 'eine kuerzere Schonfrist loest frueher aus')

  limits.measurement_grace_samples = 0
  local state2 = rt2_safety.new_state()
  feed(state2, HEALTHY, 5, limits)
  local trip2 = feed(state2, {}, 10, limits)
  assert_eq(trip2, 1, 'ohne Schonfrist loest der erste Ausfall sofort aus')
end

-- 9. Ein Stale-Fallback ist KEINE frische Messung: er darf den Zaehler
--    nicht zuruecksetzen. evaluate_coolant_limit ersetzt bei einer
--    ungueltigen Messung den Wert fuer coolant_invalid_grace_samples
--    Takte aus dem letzten gueltigen Stand -- der Rohwert bleibt nil.
do
  local state = rt2_safety.new_state()
  feed(state, HEALTHY, 10)
  local _, last = feed(state, { temperature = 800 }, 2)
  assert_eq(last.coolant_available, false,
    'der ersetzte Wert darf nicht als vorhandene Messung zaehlen')
  assert_true((last.coolant_missing_ticks or 0) >= 2, 'der Ausfallzaehler muss laufen')
end

-- 10. Durchstich durch den ganzen Stapel: im laufenden Betrieb faellt die
--     Temperaturmessung aus, der Knoten muss in den sicheren Zustand gehen
--     (Staebe voll eingefahren, Dampf aus) und sich danach wieder erholen.
--     Gegen das quelltextnahe Anlagenmodell, damit nicht nur die reine
--     Entscheidungsfunktion geprueft ist, sondern der Weg bis zur Hardware.
do
  local harness = require('support.er_rt_harness')
  -- Hier ausdruecklich mit einer KURZEN Schonfrist, damit der Durchstich in
  -- Sekunden laeuft statt in simulierten 30 Minuten. Geprueft wird der Weg
  -- bis zur Hardware und zurueck, nicht die Groesse der Zahl -- die haengt
  -- oben an DEFAULT_MEASUREMENT_GRACE_SAMPLES.
  local E2E_GRACE = 200
  local h = harness.new({ turbine_count = 4, reactor_headroom = 4.0, steam_capacity = 20000 })
  h.ctx.config.safety = {
    max_temperature = 2000, temperature_hysteresis = 50, temperature_trip_samples = 3,
    min_water = 0.10, coolant_hysteresis = 0.05, coolant_trip_samples = 3,
    coolant_invalid_grace_samples = 3,
    measurement_grace_samples = E2E_GRACE,
  }

  local blind = false
  local base_call = _G.peripheral.call
  _G.peripheral.call = function(name, method, ...)
    if blind and name == h.reactor_name
        and (method == 'getFuelTemperature' or method == 'getCasingTemperature') then
      return nil
    end
    return base_call(name, method, ...)
  end

  local function run(seconds)
    local safe_at
    for i = 1, seconds * 10 do
      h:step()
      if h.last.state == 'SAFE' and not safe_at then safe_at = i end
    end
    local flow = 0
    for _, n in ipairs(h.turbine_names) do flow = flow + h.plant.turbines[n].max_intake_rate end
    return safe_at, flow
  end

  local safe_at = run(300)
  assert_true(safe_at == nil, 'im normalen Betrieb darf nichts ausloesen')
  assert_true(h.last.state ~= 'SAFE', 'Ausgangslage: der Knoten regelt')

  blind = true
  local trip_at, flow = run(40)
  assert_true(trip_at ~= nil, 'ein Ausfall der Temperaturmessung MUSS in den sicheren Zustand fuehren')
  assert_true(math.abs(trip_at - (E2E_GRACE + 1)) <= 2, string.format(
    'die Ausloesung muss an der konfigurierten Schonfrist haengen (erwartet ~%d Takte, war %d)',
    E2E_GRACE + 1, trip_at))
  assert_eq(h.last.state, 'SAFE')
  assert_eq(flow, 0, 'im sicheren Zustand darf kein Dampf mehr fliessen')
  assert_eq(h.plant.reactor.rods, 100, 'und die Staebe muessen voll eingefahren sein')

  blind = false
  run(60)
  _G.peripheral.call = base_call
  assert_true(h.last.state ~= 'SAFE',
    'sobald die Messung zurueck ist, muss der Knoten von selbst wieder regeln')
  assert_eq(h.plant.reactor.rods, 70, 'und die Staebe wieder ausfahren')
end

print('rt2_safety_measurement_loss_test.lua: ok')
