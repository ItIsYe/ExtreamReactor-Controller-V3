package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: ein echter Kuehlmittelverlust loeste NIE aus.
--
-- core/safety.lua behandelt eine Null-Messung nach einem gesunden Stand als
-- moeglichen Messfehler ("zero glitch") und verschluckt sie fuer
-- zero_glitch_grace_samples Messungen. last_valid_ratio wird dabei bewusst
-- nicht fortgeschrieben -- und genau daran haengt der Fehler: damit blieb
-- bei einem dauerhaft leeren Tank JEDE weitere Nullmessung erneut ein
-- Glitch-Kandidat. Die Schonfrist lief nie ab.
--
-- Die Folge war nicht ein spaeterer Trip, sondern gar keiner: der
-- Glitch-Zweig setzt state.low_ticks in jedem Takt auf 0 zurueck, sobald
-- invalid_grace_samples abgelaufen ist, und triggered verlangt
-- low_ticks >= trip_samples. Gegenprobe vor dem Fix: 0.80 gefolgt von 1000
-- Nullmessungen -> kein Trip, low_ticks=0, zero_glitch_ticks=1000.
--
-- Verlangt wird jetzt: die Schonfrist ist endlich, der Trip faellt
-- spaetestens nach zero_glitch_grace_samples + trip_samples Messungen --
-- und ein kurzer echter Aussetzer wird weiterhin vollstaendig verschluckt.

local safety = require('core.safety')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

local LIMITS = { min_water = 0.10, hysteresis = 0.05, trip_samples = 3, invalid_grace_samples = 3 }

-- Fuehrt eine Messreihe durch und liefert den Index der ersten Ausloesung.
local function feed(ratios, opts)
  opts = opts or {}
  local state = opts.state or {}
  local first_trip, last
  for i, r in ipairs(ratios) do
    local amount = (r == nil) and nil or math.floor(r * 10000)
    last = safety.evaluate_coolant_limit({
      coolant_ratio = r,
      coolant_amount = amount,
      coolant_amount_max = 10000,
      min_water = LIMITS.min_water, hysteresis = LIMITS.hysteresis,
      trip_samples = opts.trip_samples or LIMITS.trip_samples,
      invalid_grace_samples = LIMITS.invalid_grace_samples,
      zero_glitch_grace_samples = opts.zero_glitch_grace_samples,
      measurement_state = (r == nil) and 'INVALID' or 'VALID',
      state = state,
    })
    if last.triggered and not first_trip then first_trip = i end
  end
  return first_trip, last, state
end

local function zeros(n) local t = {} for _ = 1, n do t[#t+1] = 0 end return t end
local function prepend(first, rest) local t = { first } for _, v in ipairs(rest) do t[#t+1] = v end return t end

-- 1. Der eigentliche Fehler: gesund, dann dauerhaft null.
do
  local grace = math.max(3, LIMITS.trip_samples)           -- Default in safety.lua
  local expected = 1 + grace + LIMITS.trip_samples          -- gesunde Messung + Schonfrist + Entprellung
  local trip, last = feed(prepend(0.80, zeros(500)))
  assert_true(trip ~= nil, 'dauerhaft null MUSS ausloesen -- das war der Fehler')
  assert_eq(trip, expected, 'die Ausloesung muss genau nach Schonfrist + Entprellung kommen')
  assert_eq(last.condition, 'COOLANT_LOW_PERSISTENT')
end

-- 2. Und zwar unabhaengig davon, wie lange es dauert: kein stiller Dauerzustand.
do
  local trip = feed(prepend(0.80, zeros(5000)))
  assert_true(trip ~= nil and trip <= 10, 'auch ueber 5000 Messungen darf es keine stille Dauerlage geben')
end

-- 3. Ein KURZER echter Aussetzer wird weiterhin verschluckt. Das ist der
--    Zweck der Schonfrist und darf nicht verlorengehen.
do
  local grace = math.max(3, LIMITS.trip_samples)
  for n = 1, grace do
    local seq = prepend(0.80, zeros(n))
    for _ = 1, 20 do seq[#seq+1] = 0.80 end
    local trip = feed(seq)
    assert_true(trip == nil, string.format(
      '%d Nullmessungen innerhalb der Schonfrist (%d) duerfen NICHT ausloesen', n, grace))
  end
end

-- 4. Genau eine Messung ueber der Schonfrist loest aus, auch wenn der Tank
--    danach wieder gesund meldet -- die Entprellung laeuft dann weiter.
do
  local grace = math.max(3, LIMITS.trip_samples)
  local seq = prepend(0.80, zeros(grace + LIMITS.trip_samples))
  local trip = feed(seq)
  assert_true(trip ~= nil, 'eine Messung ueber der Schonfrist hinaus muss ausloesen')
end

-- 5. Unveraendertes Verhalten an den Raendern, das vorher schon stimmte.
do
  local trip = feed(zeros(50))
  assert_eq(trip, LIMITS.trip_samples, 'ein Kaltstart mit leerem Tank loest wie bisher nach trip_samples aus')

  local seq = { 0.80 }
  for _ = 1, 50 do seq[#seq+1] = 0.05 end
  trip = feed(seq)
  assert_eq(trip, 1 + LIMITS.trip_samples,
    'ein niedriger, aber nicht exakt nuller Stand loest wie bisher ohne Schonfrist aus')

  trip = feed({ 0.80, 0.80, 0.80, 0.80, 0.80 })
  assert_true(trip == nil, 'ein gesunder Tank loest nicht aus')
end

-- 6. Erholung: nach der Schonfrist zurueck in den gesunden Bereich ->
--    der Zaehler faellt zurueck, eine spaetere Nullserie bekommt wieder
--    ihre volle Schonfrist.
do
  local grace = math.max(3, LIMITS.trip_samples)
  local seq = prepend(0.80, zeros(grace))
  for _ = 1, 10 do seq[#seq+1] = 0.80 end
  local trip, _, state = feed(seq)
  assert_true(trip == nil, 'Aussetzer innerhalb der Schonfrist, danach gesund: kein Trip')
  assert_eq(tonumber(state.zero_glitch_ticks) or 0, 0, 'der Glitch-Zaehler muss zurueckgefallen sein')

  -- Dieselbe state-Tabelle weiterverwenden: die naechste Nullserie bekommt
  -- wieder die volle Schonfrist, nicht einen schon verbrauchten Zaehler.
  local trip2 = feed(zeros(grace), { state = state })
  assert_true(trip2 == nil, 'nach der Erholung gilt die volle Schonfrist erneut')
end

-- 7. Die Schonfrist ist konfigurierbar und wirkt auch bei groesseren Werten.
do
  local trip = feed(prepend(0.80, zeros(500)), { zero_glitch_grace_samples = 40 })
  assert_eq(trip, 1 + 40 + LIMITS.trip_samples,
    'eine groessere Schonfrist verschiebt die Ausloesung, hebt sie aber nicht auf')

  trip = feed(prepend(0.80, zeros(500)), { zero_glitch_grace_samples = 0 })
  assert_eq(trip, 1 + LIMITS.trip_samples,
    'ohne Schonfrist loest es unmittelbar nach der Entprellung aus')
end

print('safety_coolant_zero_glitch_finite_test.lua: ok')
