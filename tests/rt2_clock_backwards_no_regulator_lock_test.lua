package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Eine zurueckspringende Uhr darf den Durchflussregler nicht aussperren.
--
-- Aus dem Betrieb gemeldet (zwei Nodes, eine regelte, die andere nicht):
-- "rpm werden weiterhin gelesen aber der flow nicht angepasst". Genau das
-- erzeugt diese Verklemmung, und sie loest sich aus eigener Kraft nie:
--
--   1. Der Regler merkt sich je Turbine, wann zuletzt gestellt wurde
--      (rt2_orchestrator's turbine_last_change_ms), und sperrt das Stellen
--      fuer MIN_ADJUST_INTERVAL_MS -- der Rotor haengt der Vorgabe um
--      Sekunden hinterher.
--   2. Springt os.epoch("utc") zurueck, liegt die gemerkte Zeit in der
--      ZUKUNFT. now_ms - last_change_ms ist dann negativ, also immer
--      kleiner als das Intervall: der Takt entscheidet SETTLING.
--   3. SETTLING gibt den unveraenderten Durchfluss zurueck. Der ist damit
--      gleich dem Rueckmesswert, also setzt der Orchestrator
--      unchanged=true und schreibt nicht.
--   4. Und weil er nicht schreibt, schreibt er last_change_ms auch nicht
--      fort. Die gemerkte Zeit bleibt in der Zukunft -> zurueck zu 2.
--
-- Die Drehzahl wird dabei weiter gelesen, der Reaktor regelt weiter, die
-- Anzeige sieht gesund aus. Nur ein Neustart der Node hat das geloest.

local rt2_turbine = require('nodes.rt.rt2_turbine')
local orchestrator = require('nodes.rt.rt2_orchestrator')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ══ 1. Das Regelgesetz selbst ═════════════════════════════════════════

do
  -- Vorwaerts innerhalb des Intervalls: die Sperre gilt, wie bisher.
  local within = rt2_turbine.compute_flow_decision({
    rpm = 700, target_rpm = 900, current_flow = 1200,
    now_ms = 10000, last_change_ms = 10000 - (rt2_turbine.MIN_ADJUST_INTERVAL_MS - 100),
  })
  assert_eq(within.reason, 'SETTLING', 'innerhalb des Stellintervalls wird weiterhin gewartet')

  -- Vorwaerts ausserhalb: es wird gestellt, wie bisher.
  local past = rt2_turbine.compute_flow_decision({
    rpm = 700, target_rpm = 900, current_flow = 1200,
    now_ms = 10000, last_change_ms = 10000 - (rt2_turbine.MIN_ADJUST_INTERVAL_MS + 100),
  })
  assert_eq(past.reason, 'TRIM_UP', 'nach Ablauf des Intervalls wird gestellt')

  -- Rueckwaerts: die gemerkte Zeit liegt in der Zukunft. Hier lag der
  -- Fehler -- die Sperre griff und liess nie wieder los.
  local backwards = rt2_turbine.compute_flow_decision({
    rpm = 700, target_rpm = 900, current_flow = 1200,
    now_ms = 1000, last_change_ms = 999999,
  })
  assert_eq(backwards.reason, 'TRIM_UP',
    'eine Uhr, die zurueckspringt, darf das Stellen nicht sperren')
  assert_true(backwards.flow > 1200, 'und der Regler muss wirklich stellen')
end

-- ══ 2. Und am ganzen Knoten: er muss sich selbst befreien ══════════════

local function turbine(rpm, flow)
  return { name = 'T1', rpm = rpm, energy = 100, coil_engaged = true, current_flow = flow }
end

do
  local o = orchestrator.new()

  -- Normalbetrieb: der Regler stellt und merkt sich die Zeit.
  local r = o.tick({ now_ms = 500000, hardware_ready = true,
    turbines = { turbine(700, 1200) }, reactor = { fill_ratio = 0.5 } })
  assert_eq(r.turbines[1].flow_decision.reason, 'TRIM_UP', 'Vorbedingung: es wird geregelt')
  local commanded = r.turbines[1].flow_decision.flow
  assert_true(commanded > 1200)

  -- Jetzt springt die Uhr weit zurueck. Die Turbine haengt weiter unter
  -- ihrem Ziel -- der Regler MUSS also weiter stellen. Geprueft wird nicht
  -- jeder einzelne Takt (nach einer Verstellung WARTET er sein Intervall
  -- ab, das ist richtig so), sondern dass ueberhaupt noch gestellt wird.
  local flow = commanded
  local adjusted, written = 0, 0
  for i = 1, 10 do
    local r2 = o.tick({ now_ms = 1000 + i * 300, hardware_ready = true,
      turbines = { turbine(700, flow) }, reactor = { fill_ratio = 0.5 } })
    local d = r2.turbines[1].flow_decision
    if d.reason == 'TRIM_UP' then adjusted = adjusted + 1 end
    if d.unchanged ~= true then written = written + 1 end
    flow = d.flow
  end

  assert_true(adjusted > 0,
    'nach einem Ruecksprung der Uhr muss der Knoten weiterregeln, nicht stehenbleiben'
      .. ' (Verstellungen: ' .. adjusted .. ')')
  assert_true(written > 0,
    'und die Entscheidungen muessen auch wirklich geschrieben werden -- sonst bleibt'
      .. ' last_change_ms in der Zukunft und die Sperre haelt fuer immer')
  assert_true(flow > commanded,
    'der Durchfluss muss sich dem Ziel genaehert haben (war ' .. commanded
      .. ', ist ' .. tostring(flow) .. ')')

  -- Der Beweis, dass es sich selbst geheilt hat: die gemerkte Zeit liegt
  -- wieder in der Gegenwart, nicht mehr in der Zukunft.
  assert_true(o.turbine_last_change_ms.T1 <= 4000,
    'die gemerkte Stellzeit muss auf die neue Uhr nachgezogen worden sein (ist: '
      .. tostring(o.turbine_last_change_ms.T1) .. ')')
end

-- ══ 3. Eine stehende Uhr sperrt nicht dauerhaft ═══════════════════════
--
-- now_ms == last_change_ms ist der Grenzfall: since = 0, also kleiner als
-- das Intervall -- das ist richtig so und muss SETTLING bleiben. Sobald
-- die Uhr weiterlaeuft, wird wieder gestellt.
do
  local same = rt2_turbine.compute_flow_decision({
    rpm = 700, target_rpm = 900, current_flow = 1200,
    now_ms = 10000, last_change_ms = 10000,
  })
  assert_eq(same.reason, 'SETTLING', 'im selben Augenblick wird nicht erneut gestellt')
end

print('rt2_clock_backwards_no_regulator_lock_test.lua: ok')
