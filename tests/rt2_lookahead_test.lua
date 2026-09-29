package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Schnell reagieren, ohne zu ueberschwingen -- der Vorhalt.
--
-- Betreibervorgabe (2026-09-29): "der Regler muss fast instant reagieren
-- koennen, aber trotzdem nicht ueberschwingen."
--
-- Mit einem Regler, der nur die IST-Drehzahl sieht, ist das nicht zu haben:
-- schnell heisst grosse Verstaerkung, und grosse Verstaerkung heisst
-- Ueberschwingen. Der Rotor antwortet erst Sekunden spaeter, und bis dahin
-- stellt ein schneller Regler weiter gegen eine Wirkung, die noch aussteht.
--
-- Geregelt wird deshalb auf die Drehzahl, die in LOOKAHEAD_S Sekunden
-- anliegt, wenn es so weitergeht -- aus der Aenderungsrate zweier
-- aufeinanderfolgender Messpunkte. Kein Lernen: nichts wird gespeichert,
-- nichts gemittelt, keine Kennlinie gebildet.

local t = require('nodes.rt.rt2_turbine')

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: erwartet %s, bekommen %s",
      label, tostring(expected), tostring(actual)), 2)
  end
end

local DT = 500

-- Ein Aufruf mit Vorgeschichte: prev_rpm liegt DT Millisekunden zurueck.
local function decide(rpm, prev_rpm, target, flow, extra)
  local input = {
    rpm = rpm, target_rpm = target or 900, current_flow = flow or 1000,
    now_ms = 100000, last_rpm = prev_rpm, last_rpm_ms = 100000 - DT,
  }
  for k, v in pairs(extra or {}) do input[k] = v end
  return t.compute_flow_decision(input)
end

-- 1. Der Kern: eine Turbine unter dem Ziel, die schnell genug steigt, um
--    darueber hinauszuschiessen, bekommt KEINEN Dampf mehr nachgelegt.
--    700 U/min mit +120 U/min/s ergibt bei 1 s Vorhalt 820 -- noch unter
--    dem Ziel, also wird noch nachgelegt, aber schwaecher.
do
  local slow = decide(700, 700, 900, 1000)          -- steht, 200 zu langsam
  local rising = decide(700, 640, 900, 1000)        -- +120 U/min/s
  assert_eq(slow.reason, "TRIM_UP", "stehend unter Ziel wird nachgelegt")
  assert_eq(rising.reason, "TRIM_UP", "steigend unter Ziel auch noch")
  if not (rising.flow < slow.flow) then
    error("wer schon steigt, braucht weniger Nachschub -- " ..
      rising.flow .. " vs " .. slow.flow, 0)
  end
end

-- 2. Steigt sie schnell genug, wird VOR dem Ziel zurueckgenommen. 800
--    U/min mit +250 U/min/s ergibt bei 1 s Vorhalt 1050 -- deutlich
--    darueber, also Dampf weg, obwohl sie noch 100 unter dem Ziel steht.
--    Genau das ist der Unterschied zwischen "schnell" und "ueberschwingend".
do
  local d = decide(800, 675, 900, 1500)
  assert_eq(d.reason, "TRIM_DOWN",
    "wer auf 1050 zulaeuft, bekommt keinen Dampf mehr -- auch bei 800 U/min")
  if not (d.flow < 1500) then
    error("und der Durchfluss muss wirklich sinken, nicht nur gehalten werden", 0)
  end
end

-- 3. Ohne Vorhalt (kein voriger Messpunkt) verhaelt es sich wie zuvor:
--    800 unter Ziel 900 heisst nachlegen.
do
  local d = t.compute_flow_decision({ rpm = 800, target_rpm = 900, current_flow = 1500 })
  assert_eq(d.reason, "TRIM_UP", "ohne Rate wird rein auf den Istwert geregelt")
end

-- 4. "Kommt hin" heisst nichts tun. Die Vorhersage trifft das Ziel genau,
--    also waere jede weitere Verstellung das Ueberschwingen selbst.
do
  -- 800 U/min, +100 U/min/s, 1 s Vorhalt -> Vorhersage 900.
  local d = decide(800, 750, 900, 1500)
  assert_eq(d.reason, "ON_PREDICTED_TARGET", "auf Kurs wird nicht gestellt")
  assert_eq(d.flow, 1500, "und der Durchfluss bleibt stehen")
end

-- 5. Die Ruhezone braucht jetzt BEIDES: kleine Abweichung und kleine Rate.
--    Eine Turbine, die gerade durch 900 hindurchbeschleunigt, steht nicht
--    am Ziel, auch wenn die Abweichung in diesem Augenblick null ist.
do
  local resting = decide(900, 900, 900, 1000)
  assert_eq(resting.reason, "SETTLED", "wirklich still stehend ist SETTLED")

  local passing = decide(900, 850, 900, 1000)  -- +100 U/min/s mitten durchs Ziel
  if passing.reason == "SETTLED" then
    error("eine durch das Ziel beschleunigende Turbine darf nicht als angekommen gelten", 0)
  end
  assert_eq(passing.reason, "TRIM_DOWN", "sie muss gebremst werden")
end

-- 6. Messrauschen loest das nicht aus. Ein paar Umdrehungen Zittern liegen
--    unter SETTLE_RATE_RPM_PER_S.
do
  -- 3 U/min in 500 ms = 6 U/min/s, unter der Schwelle von 12.
  local d = decide(901, 898, 900, 1000)
  assert_eq(d.reason, "SETTLED", "Rauschen darf die Ruhezone nicht aufbrechen")
end

-- 7. Die Vorhersage ist gedeckelt. Eine absurde Rate (ein Sprung von 400
--    U/min in einem halben Takt) darf die Lage nicht beliebig verschieben.
do
  local d = decide(900, 100, 900, 2000)   -- +1600 U/min/s
  assert_eq(d.reason, "TRIM_DOWN", "eine wilde Rate bremst")
  -- Gedeckelt auf MAX_PREDICT_RPM: Abweichung hoechstens -300, Schritt also
  -- hoechstens TRIM_STEP * 300 / RPM_BAND.
  local max_step = math.floor(t.TRIM_STEP * t.MAX_PREDICT_RPM / t.RPM_BAND + 0.5)
  local step = 2000 - d.flow
  if step > max_step then
    error("die Vorhersage ist nicht gedeckelt: Schritt " .. step .. " > " .. max_step, 0)
  end
end

-- 8. Mit Vorhalt darf auch nach oben entschieden zugepackt werden -- ohne
--    ihn bleibt es beim alten, vorsichtigen TRIM_STEP. Die Vorsicht muss
--    mit ihrer Grundlage verschwinden, nicht ohne sie bestehen bleiben.
do
  local with_rate = decide(100, 100, 900, 0)     -- steht, 800 zu langsam
  assert_eq(with_rate.reason, "TRIM_UP", "weit unter Ziel wird nachgelegt")
  if not (with_rate.flow > t.TRIM_STEP) then
    error("mit Vorhalt darf der Schritt nach oben groesser sein als TRIM_STEP", 0)
  end

  local without_rate = t.compute_flow_decision({ rpm = 100, target_rpm = 900, current_flow = 0 })
  assert_eq(without_rate.flow, t.TRIM_STEP, "ohne Rate bleibt es bei TRIM_STEP")
end

-- 9. Eine unbrauchbare Vorgeschichte gilt als "keine Rate", nicht als
--    "Rate null": zu alt, und eine rueckwaerts gesprungene Uhr.
do
  local stale = t.compute_flow_decision({
    rpm = 800, target_rpm = 900, current_flow = 1500,
    now_ms = 100000, last_rpm = 100, last_rpm_ms = 100000 - (t.MAX_RATE_AGE_MS + 1),
  })
  assert_eq(stale.reason, "TRIM_UP", "ein zu alter Messpunkt begruendet keine Vorhersage")

  local backwards = t.compute_flow_decision({
    rpm = 800, target_rpm = 900, current_flow = 1500,
    now_ms = 100000, last_rpm = 100, last_rpm_ms = 100500,
  })
  assert_eq(backwards.reason, "TRIM_UP", "eine rueckwaerts gesprungene Uhr ebenso")
end

-- 10. Die Schutzentscheidungen bleiben unberuehrt -- sie stehen oberhalb
--     des Vorhalts und gelten unabhaengig von jeder Vorhersage.
do
  local over = decide(1301, 1301, 900, 2000)
  assert_eq(over.reason, "OVERSPEED", "die harte Abschaltung bleibt")
  assert_eq(over.flow, 0, "und zwar auf null")

  local parked = decide(900, 900, 0, 1000)
  assert_eq(parked.reason, "TARGET_ZERO", "ein abgewaehlter Platz bekommt keinen Dampf")

  local blind = t.compute_flow_decision({ rpm = nil, target_rpm = 900, current_flow = 1000 })
  assert_eq(blind.reason, "NO_RPM_READING", "ohne Drehzahl kein Dampf")
end

-- 11. Anfahrt aus dem Stand gegen eine erste Ordnung: der Vorhalt darf die
--     Spitze nicht ueber das Zielband tragen, und er muss schneller
--     ankommen als ohne ihn. Das ist ein MODELL, kein Spiel -- es zeigt,
--     dass die Regelung in sich stimmig ist, nicht wie der Mod reagiert.
do
  local RPM_PER_FLOW = 900 / 1500
  local function run(lookahead, lag)
    local rpm, flow, prev_rpm, prev_ms, now = 0, 0, nil, nil, 0
    local peak, settled = 0, nil
    for i = 1, 400 do
      local d = t.compute_flow_decision({
        rpm = rpm, target_rpm = 900, current_flow = flow,
        now_ms = now, last_rpm = prev_rpm, last_rpm_ms = prev_ms,
        lookahead_s = lookahead,
      })
      prev_rpm, prev_ms = rpm, now
      flow = d.flow
      rpm = rpm + (flow * RPM_PER_FLOW - rpm) * lag
      now = now + DT
      if rpm > peak then peak = rpm end
      if not settled and math.abs(rpm - 900) <= 15 then settled = i end
      if settled and math.abs(rpm - 900) > 15 then settled = nil end
    end
    return peak, settled
  end

  for _, lag in ipairs({ 0.35, 0.10, 0.04 }) do
    local peak_off, settled_off = run(0, lag)
    local peak_on, settled_on = run(nil, lag)   -- nil = M.LOOKAHEAD_S
    if not settled_on then
      error("mit Vorhalt muss die Turbine ankommen (lag=" .. lag .. ")", 0)
    end
    if peak_on > peak_off + 1 then
      error(string.format(
        "der Vorhalt darf nicht mehr ueberschwingen als ohne (lag=%.2f): %.0f vs %.0f",
        lag, peak_on, peak_off), 0)
    end
    if settled_off and settled_on > settled_off then
      error(string.format(
        "mit Vorhalt darf es nicht laenger dauern (lag=%.2f): %d vs %d Takte",
        lag, settled_on, settled_off), 0)
    end
  end
end

print("OK rt2_lookahead_test")
