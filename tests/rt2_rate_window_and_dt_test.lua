package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Zwei Eigenschaften des Reglers, die beide an der TAKTZEIT haengen.
--
-- Betriebsmeldung 2026-09-30: "auch wenn fein geregelt wird, schiesst die
-- Turbine in Overspeed oder geht dann wieder runter, weil der Regler zu
-- stark stellt und erst im naechsten Takt nachregelt."
--
-- 1. Der Bezugspunkt der Aenderungsrate ist nicht mehr der unmittelbar
--    vorige Takt. Bei 100 ms Regeltakt ist die Differenz zweier Messungen
--    zu einem grossen Teil Messrauschen -- mit einer Sekunde Vorhalt
--    hochgerechnet stellt der Regler dieses Rauschen nach.
--
-- 2. Die Schrittweite bezieht sich auf die tatsaechlich verstrichene Zeit.
--    Vorher war sie ein fester Betrag JE TAKT, und damit hing die wirksame
--    Verstaerkung davon ab, wie oft die Schleife zufaellig lief -- in der
--    groesseren Anlage (mehr Turbinen, laengerer Durchgang) wurde der
--    Regler ausgerechnet schwaecher.

local t = require('nodes.rt.rt2_turbine')
local orchestrator = require('nodes.rt.rt2_orchestrator')

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: erwartet %s, bekommen %s",
      label, tostring(expected), tostring(actual)), 2)
  end
end
local function assert_true(v, m) if not v then error(m or 'assert_true', 2) end end

-- ══ 1. Schrittweite an der verstrichenen Zeit ═══════════════════════════

-- 1a. Ohne Zeitangabe bleibt alles wie zuvor. Das ist der Rueckfallpfad
--     fuer Altaufrufer und Modultests -- er MUSS unveraendert sein.
do
  local base = t.compute_flow_decision({ rpm = 800, target_rpm = 900, current_flow = 1000 })
  local same = t.compute_flow_decision({ rpm = 800, target_rpm = 900, current_flow = 1000,
    dt_ms = nil })
  assert_eq(same.flow, base.flow, 'ohne dt_ms aendert sich nichts')
end

-- 1b. Beim Bezugstakt (100 ms) ist der Faktor genau 1 -- das eingefahrene
--     Verhalten bleibt stehen.
do
  local base = t.compute_flow_decision({ rpm = 800, target_rpm = 900, current_flow = 1000 })
  local nominal = t.compute_flow_decision({ rpm = 800, target_rpm = 900, current_flow = 1000,
    dt_ms = t.NOMINAL_STEP_INTERVAL_MS })
  assert_eq(nominal.flow, base.flow, 'beim Bezugstakt aendert sich nichts')
end

-- 1c. Doppelte Taktzeit, doppelter Schritt -- die Bewegung je Sekunde
--     bleibt dieselbe. Geprueft in der Bremsrichtung, weil dort der Deckel
--     grosszuegig genug ist, um die Skalierung ueberhaupt sichtbar zu
--     machen (nach oben begrenzt ihn ohne Rate TRIM_STEP).
do
  local one = t.compute_flow_decision({ rpm = 980, target_rpm = 900, current_flow = 1500,
    dt_ms = 100 })
  local two = t.compute_flow_decision({ rpm = 980, target_rpm = 900, current_flow = 1500,
    dt_ms = 200 })
  local step_one, step_two = 1500 - one.flow, 1500 - two.flow
  assert_true(step_one > 0 and step_two > 0, 'beide bremsen')
  assert_eq(step_two, step_one * 2, 'doppelte Taktzeit heisst doppelter Schritt')
end

-- 1d. Der Faktor ist begrenzt. Ein Wert weit ausserhalb heisst nicht "sehr
--     traege Schleife", sondern "die Zeitangabe stimmt nicht" -- dann wird
--     lieber nicht weiter verstaerkt.
do
  local absurd = t.compute_flow_decision({ rpm = 980, target_rpm = 900, current_flow = 1500,
    dt_ms = 100000 })
  local at_cap = t.compute_flow_decision({ rpm = 980, target_rpm = 900, current_flow = 1500,
    dt_ms = t.NOMINAL_STEP_INTERVAL_MS * t.MAX_STEP_SCALE })
  assert_eq(absurd.flow, at_cap.flow, 'eine absurde Taktzeit wird gedeckelt')
  assert_true(1500 - absurd.flow < 1500, 'und bleibt eine endliche Bremsung')

  local tiny = t.compute_flow_decision({ rpm = 980, target_rpm = 900, current_flow = 1500,
    dt_ms = 0.001 })
  local at_floor = t.compute_flow_decision({ rpm = 980, target_rpm = 900, current_flow = 1500,
    dt_ms = t.NOMINAL_STEP_INTERVAL_MS * t.MIN_STEP_SCALE })
  assert_eq(tiny.flow, at_floor.flow, 'und eine winzige Taktzeit ebenso')
end

-- ══ 2. Der Bezugspunkt der Rate ═════════════════════════════════════════

-- Eine Flotte, die der Orchestrator ueber mehrere Takte sieht. Gefragt ist
-- nur, WELCHEN Messpunkt er als Bezug durchreicht.
local function turbine(rpm)
  return { name = 'T1', rpm = rpm, current_flow = 1200, coil_engaged = true,
           energy = 100, active = true }
end

-- 2a. Solange noch kein Messpunkt alt genug ist, gibt es keine Rate --
--     dann regelt rt2_turbine rein auf den Istwert, also wie vor dem
--     Vorhalt. Kein Raten, keine erfundene Null.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local r = o.tick({ now_ms = 1000, hardware_ready = true,
    turbines = { turbine(800) }, reactor = {} })
  assert_true(r.turbines[1] ~= nil, 'die Turbine bekommt eine Entscheidung')

  -- Zweiter Takt, nur 100 ms spaeter: das Fenster ist noch nicht voll.
  local before = t.MIN_RATE_WINDOW_MS
  assert_true(before > 100, 'der Test setzt ein Fenster groesser als ein Takt voraus')
end

-- 2b. Der durchgereichte Bezugspunkt ist mindestens MIN_RATE_WINDOW_MS alt
--     -- niemals der unmittelbar vorige Takt. Geprueft ueber das
--     Verhalten: eine Turbine, die sich NICHT bewegt, aber deren Messwert
--     rauscht, darf nicht auf das Rauschen reagieren.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local now = 1000
  -- Erst das Fenster fuellen, alles bei exakt 900.
  for _ = 1, 10 do
    o.tick({ now_ms = now, hardware_ready = true, turbines = { turbine(900) }, reactor = {} })
    now = now + 100
  end
  -- Jetzt ein einzelner Rauschausreisser von 6 U/min.
  local r = o.tick({ now_ms = now, hardware_ready = true,
    turbines = { turbine(906) }, reactor = {} })
  local decision = r.turbines[1].flow_decision
  -- Der Bezugspunkt ist 900 (mindestens 150 ms alt), die Rate also
  -- 6 U/min ueber >= 150 ms = hoechstens 40 U/min/s -- unter dem Tor der
  -- Feinzone. Die Entscheidung darf deshalb NICHT von einer Vorhersage
  -- getrieben sein, sondern nur von der echten Abweichung von 6.
  assert_true(decision.reason == 'FINE_DOWN' or decision.reason == 'SETTLED',
    'ein einzelner Ausreisser darf keine grosse Reaktion ausloesen, war: '
      .. tostring(decision.reason))
  assert_true(math.abs(decision.flow - 1200) <= t.FINE_TRIM_STEP,
    'und der Schritt bleibt im Feinbereich')
end

-- 2c. Eine zurueckspringende Uhr verwirft die gemerkten Punkte, statt sie
--     auszusitzen -- dieselbe Regel wie beim Stellintervall.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local now = 100000
  for _ = 1, 6 do
    o.tick({ now_ms = now, hardware_ready = true, turbines = { turbine(900) }, reactor = {} })
    now = now + 100
  end
  -- Uhr springt weit zurueck.
  local r = o.tick({ now_ms = 500, hardware_ready = true,
    turbines = { turbine(900) }, reactor = {} })
  assert_true(r.turbines[1] ~= nil, 'der Takt laeuft trotzdem durch')
  -- Und danach baut sich das Fenster neu auf, ohne haengen zu bleiben.
  local later = o.tick({ now_ms = 500 + t.MIN_RATE_WINDOW_MS + 100, hardware_ready = true,
    turbines = { turbine(900) }, reactor = {} })
  assert_true(later.turbines[1] ~= nil, 'und danach ebenfalls')
end

print("OK rt2_rate_window_and_dt_test")
