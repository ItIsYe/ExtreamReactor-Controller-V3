package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Bremsen muss mit der Abweichung staerker werden.
--
-- Betriebsmeldung (2026-09-29): "die turbine geht in overspeed und coil wird
-- nicht eingehaengt, aktuell 1700 rpm", nachgereicht: "der regler hat
-- reagiert aber sehr spaet".
--
-- Ursache war nicht die Spule -- deren Entscheidung ist oberhalb des Bands
-- eindeutig BRAKE_TO_TARGET -- sondern die Schrittweite des Durchflusses.
-- Der Schritt wurde als TRIM_STEP * Abweichung / RPM_BAND gerechnet und
-- danach in BEIDE Richtungen auf TRIM_STEP gedeckelt. Ab Bandbreite war er
-- damit immer derselbe: 35, ob die Turbine nun 40 oder 350 Umdrehungen zu
-- schnell dreht. Nachgemessen am alten Stand, Ziel 900, Durchfluss 2000:
-- 58 Takte -- rund 35 Sekunden -- um den Dampf zurueckzunehmen. So lange
-- laeuft der Rotor unter fast vollem Dampf weiter hoch, bis ihn die harte
-- Abschaltung bei OVERSPEED_RPM faengt.
--
-- Nach oben bleibt es bewusst gemaechlich: zu viel Dampf endet in
-- Ueberdrehzahl, zu wenig Dampf kostet kurz Leistung, und ein schneller
-- Schritt nach oben vergroessert genau das Ueberschwingen, das ueberhaupt
-- erst in diese Lage fuehrt.

local t = require('nodes.rt.rt2_turbine')

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: erwartet %s, bekommen %s",
      label, tostring(expected), tostring(actual)), 2)
  end
end

local function flow_for(rpm, target, current, extra)
  local input = { rpm = rpm, target_rpm = target, current_flow = current }
  for k, v in pairs(extra or {}) do input[k] = v end
  return t.compute_flow_decision(input)
end

-- 1. Der Bremsschritt waechst mit der Abweichung. Frueher war er hier
--    dreimal derselbe.
do
  local a = flow_for(940, 900, 2000)   -- 40 zu schnell (Bandrand)
  local b = flow_for(1000, 900, 2000)  -- 100 zu schnell
  local c = flow_for(1250, 900, 2000)  -- 350 zu schnell
  assert_eq(a.reason, "TRIM_DOWN", "Bandrand bremst")
  assert_eq(c.reason, "TRIM_DOWN", "weit drueber bremst")

  local step_a = 2000 - a.flow
  local step_b = 2000 - b.flow
  local step_c = 2000 - c.flow
  assert_eq(step_a, t.TRIM_STEP, "am Bandrand bleibt es bei TRIM_STEP")
  if not (step_b > step_a) then
    error("100 zu schnell muss staerker bremsen als 40 -- " .. step_b .. " vs " .. step_a, 0)
  end
  if not (step_c > step_b) then
    error("350 zu schnell muss staerker bremsen als 100 -- " .. step_c .. " vs " .. step_b, 0)
  end
end

-- 2. Gedeckelt wird er trotzdem.
do
  -- Ziel 450 (abgesenkter Platz), 1000 U/min: 550 zu schnell, aber noch
  -- unter OVERSPEED_RPM -- also echte Regelung, keine harte Abschaltung.
  local d = flow_for(1000, 450, 2000)
  assert_eq(d.reason, "TRIM_DOWN", "unter der harten Abschaltung wird geregelt")
  assert_eq(2000 - d.flow, t.MAX_TRIM_STEP_DOWN, "der Bremsschritt ist gedeckelt")
end

-- 3. Nach oben bleibt alles wie es war: nie mehr als TRIM_STEP.
do
  for _, rpm in ipairs({ 0, 200, 500, 800, 860 }) do
    local d = flow_for(rpm, 900, 0)
    assert_eq(d.reason, "TRIM_UP", "zu langsam legt nach")
    assert_eq(d.flow, t.TRIM_STEP, "der Schritt nach oben bleibt gedeckelt bei TRIM_STEP")
  end
end

-- 4. Die Ruhezone ist unangetastet.
do
  for _, rpm in ipairs({ 896, 900, 904 }) do
    local d = flow_for(rpm, 900, 1200)
    assert_eq(d.reason, "SETTLED", "innerhalb der Ruhezone wird nicht gestellt")
    assert_eq(d.flow, 1200, "und der Durchfluss bleibt stehen")
  end
end

-- 5. Oberhalb des Bands gilt die Stellsperre nicht -- dieselbe Schwelle, ab
--    der auch die Spule bremst. Sonst verschenkt der Regler jeden zweiten
--    Takt, waehrend der Rotor weiter hochlaeuft.
do
  local clock = { now_ms = 10000, last_change_ms = 9900 }  -- 100ms < 600ms
  local braking = flow_for(1100, 900, 2000, clock)
  assert_eq(braking.reason, "TRIM_DOWN", "Bremsen wartet nicht auf das Stellintervall")

  -- Innerhalb des Bands greift sie weiterhin.
  local trimming = flow_for(830, 900, 1000, clock)
  assert_eq(trimming.reason, "SETTLING", "normales Nachlegen wartet weiterhin")

  -- Und knapp ueber dem Ziel, aber noch im Band, ebenfalls.
  local inside = flow_for(930, 900, 1000, clock)
  assert_eq(inside.reason, "SETTLING", "im Band wird weiter gewartet, auch nach oben")
end

-- 6. Die harte Abschaltung bleibt, wo sie war.
do
  local d = flow_for(1301, 900, 2000)
  assert_eq(d.reason, "OVERSPEED", "ueber OVERSPEED_RPM wird sofort abgeschaltet")
  assert_eq(d.flow, 0, "und zwar auf null")
end

-- 7. Der Durchfluss ist deutlich schneller unten. Schlechtester Fall:
--    die Drehzahl haengt bei 1000 fest (nur 100 zu schnell), der Schritt
--    waechst also nicht mit. Vorher: 58 Takte.
do
  local flow, ticks = 2000, 0
  while flow > 0 and ticks < 500 do
    local d = flow_for(1000, 900, flow)
    if d.flow == flow then break end
    flow = d.flow
    ticks = ticks + 1
  end
  assert_eq(flow, 0, "der Durchfluss kommt auf null")
  if ticks >= 40 then
    error("zu langsam heruntergeregelt: " .. ticks .. " Takte (vorher 58, erwartet unter 40)", 0)
  end
end

-- 8. Die Spule war nie das Problem: oberhalb des Bands kuppelt sie, auch
--    aus dem geloesten Zustand heraus und auch bei 1700 U/min.
do
  local c = t.compute_coil_decision({ rpm = 1700, target_rpm = 900, currently_engaged = false })
  assert_eq(c.engaged, true, "bei 1700 gegen Ziel 900 muss gekuppelt werden")
  assert_eq(c.reason, "BRAKE_TO_TARGET", "und zwar als Bremsung")
end

print("OK rt2_brake_step_test")
