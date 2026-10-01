package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Stabregelung darf nicht dauerschwingen.
--
-- Die Dampfkette antwortet auf eine Stabbewegung erst nach Sekunden, und der
-- interne Dampftank fasst nur die Groessenordnung eines Ticks
-- Flottenbedarf. Faehrt der Regler seine gesamte Vollmacht (70..100 %
-- Einschub) innerhalb EINER Antwortzeit der Strecke durch, kann er nicht
-- einschwingen -- er stellt immer gegen eine Wirkung, die noch aussteht.
--
-- Bis v807 war die Stellrate 12 %/s (MAX_STEP 6 je 500 ms), die ganze
-- Vollmacht also in 2,5 s. In der Auslegung, in der Tankinhalt und
-- Waermetraegheit in derselben Groessenordnung liegen, hielt die Flotte ihr
-- Zielband damit zu NULL Prozent der Zeit: der Tank schlug ueber seinen
-- ganzen Bereich, die Staebe ueber ihren ganzen, und die Drehzahl sackte auf
-- 862 statt 899 RPM ab. Die Kapazitaet wurde dadurch nie nachgefuehrt
-- (at_target blieb unter required_at_target).
--
-- Dieser Test prueft BEIDE Auslegungen: die realistische, in der die
-- Regelung am Anschlag sitzt (und das ist der gesunde Zustand, siehe
-- rt2_reactor.lua's ROD_MIN), und die resonante, in der sie wirklich regeln
-- muss.

local harness = require('support.er_rt_harness')
local rt2_reactor = require('nodes.rt.rt2_reactor')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Faehrt die Anlage ein und vermisst dann 180 s Beharrungsbetrieb.
local function measure(opts)
  local h = harness.new({
    turbine_count = 6,
    reactor_headroom = opts.headroom,
    steam_capacity = opts.steam_capacity,
  })
  if opts.thermal_lag then h.plant.reactor.thermal_lag = opts.thermal_lag end
  h:run(400)

  local tank_min, tank_max = 1.0, 0.0
  local reversals, direction = 0, 0
  local prev_rods = h.plant.reactor.rods
  local in_band_ticks, tick_count = 0, 0

  for _ = 1, 1800 do
    h:step()
    local r = h.plant.reactor
    local fill = r.steam / r.steam_capacity
    if fill < tank_min then tank_min = fill end
    if fill > tank_max then tank_max = fill end

    local delta = r.rods - prev_rods
    if delta ~= 0 then
      local d = delta > 0 and 1 or -1
      if direction ~= 0 and d ~= direction then reversals = reversals + 1 end
      direction = d
      prev_rods = r.rods
    end

    local in_band = 0
    for _, name in ipairs(h.turbine_names) do
      if math.abs(h.plant.turbines[name]:rotor_speed() - 900) <= 15 then
        in_band = in_band + 1
      end
    end
    in_band_ticks = in_band_ticks + in_band
    tick_count = tick_count + #h.turbine_names
  end

  return {
    swing = tank_max - tank_min,
    reversals_per_min = reversals / 3,
    band_percent = in_band_ticks / tick_count * 100,
    rods = h.plant.reactor.rods,
    capacity_ready = h.last.capacity.ready,
  }
end

-- ── 1. Realistische Auslegung: die Regelung sitzt am Anschlag ────────────
--
-- Der interne Dampftank fasst 1000 mB je Kuehlmittelport, also rund einen
-- Tick Flottenbedarf. Die Staebe stehen fest auf ROD_MIN, der Tank unter dem
-- Sollwert -- genau der Zustand, den rt2_reactor.lua als den gesunden
-- beschreibt. Hier darf sich durch die langsamere Stellrate NICHTS
-- verschlechtern.
do
  for _, headroom in ipairs({ 1.15, 2.0, 4.0 }) do
    local m = measure({ headroom = headroom, steam_capacity = 20000 })
    assert_true(m.reversals_per_min == 0, string.format(
      'Reserve %.2f: am Anschlag darf die Stabrichtung nicht wechseln, es waren %.1f/min',
      headroom, m.reversals_per_min))
    assert_true(m.rods == rt2_reactor.ROD_MIN, string.format(
      'Reserve %.2f: die Staebe muessen auf ROD_MIN stehen, sie stehen auf %.0f',
      headroom, m.rods))
    assert_true(m.band_percent == 100, string.format(
      'Reserve %.2f: die Flotte muss durchgehend im Zielband stehen, es sind %.1f %%',
      headroom, m.band_percent))
  end
end

-- ── 2. Resonante Auslegung: der Kreis muss regeln, ohne zu schwingen ─────
--
-- Grosser Tank (200000 mB) und eine Waermetraegheit von 2,5 s -- die
-- Paarung, bei der der Kreis am schlechtesten war. Vorher: Tankhub 0,940,
-- 12 Richtungswechsel je Minute, 0 % im Zielband.
do
  local m = measure({ headroom = 2.0, steam_capacity = 200000, thermal_lag = 0.02 })

  assert_true(m.band_percent >= 95, string.format(
    'die Flotte muss ihr Zielband halten, sie haelt es %.1f %% der Zeit', m.band_percent))
  assert_true(m.swing < 0.85, string.format(
    'der Tank darf nicht mehr ueber seinen ganzen Bereich schlagen, der Hub ist %.3f',
    m.swing))
  assert_true(m.reversals_per_min < 10, string.format(
    'die Stabrichtung darf nicht im Sekundentakt wechseln, es sind %.1f/min',
    m.reversals_per_min))
  assert_true(m.capacity_ready == true,
    'und das Einlernen muss zu einem Ergebnis kommen')
end

-- ── 3. Die Stellrate ist der wirksame Hebel ──────────────────────────────
--
-- Festgehalten, damit die Begruendung nachpruefbar bleibt und nicht nur im
-- Kommentar steht: entscheidend ist Schritt JE ZEIT, nicht der Einzelschritt.
do
  local rate_per_s = rt2_reactor.MAX_STEP / (rt2_reactor.MIN_ADJUST_INTERVAL_MS / 1000)
  assert_true(rate_per_s <= 2.5, string.format(
    'die Stellrate der Staebe muss bei hoechstens 2,5 %%/s liegen, sie ist %.1f %%/s',
    rate_per_s))

  -- Einmal durch die ganze Vollmacht darf nicht schneller gehen als die
  -- Dampfkette antwortet (Groessenordnung Sekunden).
  local traverse_s = (rt2_reactor.ROD_MAX - rt2_reactor.ROD_MIN) / rate_per_s
  assert_true(traverse_s >= 10, string.format(
    'die ganze Stabvollmacht darf nicht in unter 10 s durchfahren werden, es sind %.1f s',
    traverse_s))

  -- Die bewusste Leistungsgrenze bleibt unberuehrt.
  assert_true(rt2_reactor.ROD_MIN == 70,
    'ROD_MIN ist eine Betreibervorgabe und bleibt bei 70')
end

-- ── 4. Eine Sicherheitsausloesung bleibt sofort ──────────────────────────
--
-- Die langsamere Stellrate bremst ausdruecklich NUR die gewoehnliche
-- Tankregelung. Ein Trip fahrt die Staebe im selben Takt voll ein.
do
  local rt2_unit = require('nodes.rt.rt2_unit')
  local unit = rt2_unit.new({ name = 'r1' })

  -- Erst ein normaler Takt, damit das Stellintervall gerade frisch ist.
  unit.observe({ now_ms = 1000, safety_tripped = false,
    reactor = { fill_ratio = 0.1, current_rods = 70 } })
  unit.decide({ now_ms = 1000, node_state = 'AUTONOM',
    reactor = { fill_ratio = 0.1, current_rods = 70 } })

  -- Jetzt die Ausloesung, 50 ms spaeter -- weit innerhalb des Intervalls.
  unit.observe({ now_ms = 1050, safety_tripped = true,
    reactor = { fill_ratio = 0.1, current_rods = 70 } })
  local d = unit.decide({ now_ms = 1050, node_state = 'AUTONOM',
    reactor = { fill_ratio = 0.1, current_rods = 70 } })
  assert_true(d.rods == rt2_reactor.ROD_MAX, string.format(
    'eine Ausloesung muss die Staebe sofort voll einfahren, sie steht auf %s',
    tostring(d.rods)))
  assert_true(d.reason == 'SAFETY_FULL_INSERT',
    'und zwar auf dem Sicherheitsweg, nicht ueber die Tankregelung')
end

print('ok rt2_rod_loop_stability_test')
