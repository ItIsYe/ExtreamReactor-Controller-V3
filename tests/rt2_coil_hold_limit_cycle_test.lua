package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: "eine einzelne Turbine geht nach einiger Zeit in
-- Ueberdrehzahl" (MASTER online, Regler ansonsten stabil).
--
-- Der bestehende Zwillings-Integrationstest konnte das nicht sehen: sein
-- Rotormodell kennt die SPULE nicht (rpm haengt dort allein am
-- Durchfluss). Genau die Spule ist aber die Ursache. Sie ist kein kleiner
-- Beitrag zur Last, sie IST die Last -- Ein- und Aushaengen aendert die
-- Streckenverstaerkung sprunghaft um ein Mehrfaches.
--
-- Mit der alten Loeseschwelle (COIL_DISENGAGE_RPM) schaukelten sich
-- Spulenschalter und Durchflussregler gegenseitig auf:
--   Spule bremst unter 850 -> loest -> Rotor schiesst hoch -> Spule
--   greift -> bremst unter 850 -> ...
-- Die Drehzahlspitzen dieses Grenzzyklus wachsen mit sinkender
-- Rotortraegheit monoton und reissen die Ueberdrehzahlschwelle.
--
-- Dieser Test fuehrt den geschlossenen Regelkreis mit einem Rotormodell
-- MIT Spulenlast ueber einen Traegheitsbereich und verlangt: kein
-- Dauerflattern, keine Ueberdrehzahl, und am Ende steht die Turbine am
-- Ziel -- gekuppelt, denn nur gekuppelt liefert sie Energie.

local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- Rotormodell: d(rpm)/dt = (K*flow - (DRAG + Spulenlast)*rpm) / TRAEGHEIT.
-- K ist so kalibriert, dass mit eingehaengter Spule ~1500 mB/t die
-- Zieldrehzahl 900 halten (dieselbe Kennzahl wie im Zwillingstest).
local DRAG, COIL_LOAD, K = 1.0, 2.0, 1.8
local TARGET = rt2_turbine.FULL_TARGET_RPM
local DT_MS = 100          -- echter Regeltakt, siehe nodes/rt/main.lua

local function simulate(inertia, seconds)
  local rpm, flow, coil = 0.0, 0, false
  local now, samples = 0, {}
  local peak, toggles, last_coil = 0, 0, false
  local dev_sum, dev_n = 0, 0
  local steps = math.floor((seconds * 1000) / DT_MS)
  for step = 1, steps do
    now = now + DT_MS
    -- Ratenbezug wie rt2_orchestrator: juengste Probe, die mindestens
    -- MIN_RATE_WINDOW_MS alt ist.
    local ref_rpm, ref_ms
    for i = #samples, 1, -1 do
      if now - samples[i][1] >= rt2_turbine.MIN_RATE_WINDOW_MS then
        ref_ms, ref_rpm = samples[i][1], samples[i][2]
        break
      end
    end
    local decision = rt2_turbine.compute_flow_decision({
      rpm = rpm, target_rpm = TARGET, current_flow = flow, coil_engaged = coil,
      now_ms = now, last_rpm = ref_rpm, last_rpm_ms = ref_ms, dt_ms = DT_MS,
    })
    local coil_decision = rt2_turbine.compute_coil_decision({
      rpm = rpm, target_rpm = TARGET, currently_engaged = coil,
      current_flow = decision.flow,
    })
    flow = decision.flow
    if coil_decision.engaged ~= last_coil then
      toggles = toggles + 1
      last_coil = coil_decision.engaged
    end
    coil = coil_decision.engaged
    samples[#samples + 1] = { now, rpm }

    rpm = rpm + ((K * flow - (DRAG + (coil and COIL_LOAD or 0)) * rpm) / inertia) * (DT_MS / 1000)
    if rpm < 0 then rpm = 0 end
    if rpm > peak then peak = rpm end
    if step > steps * 0.5 then
      dev_sum = dev_sum + math.abs(rpm - TARGET)
      dev_n = dev_n + 1
    end
  end
  return {
    peak = peak, toggles = toggles, rpm = rpm, coil = coil, flow = flow,
    mean_dev = dev_sum / math.max(1, dev_n),
  }
end

-- Der Traegheitsbereich deckt langsame wie schnelle Rotoren ab. Mit der
-- alten Regel wuchs die Spitze hier monoton bis ueber die
-- Ueberdrehzahlschwelle; mit der neuen bleibt sie ueber den ganzen
-- Bereich darunter.
for _, inertia in ipairs({ 1.2, 0.9, 0.7, 0.5, 0.35, 0.25 }) do
  local r = simulate(inertia, 90)

  assert_true(r.peak <= rt2_turbine.OVERSPEED_RPM, string.format(
    'Traegheit %.2f: Drehzahlspitze %.0f reisst die Ueberdrehzahlschwelle %d',
    inertia, r.peak, rt2_turbine.OVERSPEED_RPM))

  -- Dauerflattern der Spule: mit der alten Regel waren es ueber 700
  -- Umschaltungen in 90 s, also fast jeder Takt.
  assert_true(r.toggles <= 10, string.format(
    'Traegheit %.2f: %d Spulen-Umschaltungen in 90 s -- das ist ein Grenzzyklus, keine Hysterese',
    inertia, r.toggles))
end

-- Im ausgelegten Betriebspunkt muss sie danach sauber am Ziel stehen --
-- und gekuppelt, sonst liefert sie nichts (rt2_orchestrator's
-- measure_capacity verlangt energy > 0).
do
  local r = simulate(0.7, 90)
  assert_true(r.coil == true, 'am Ziel muss die Spule eingehaengt sein')
  assert_true(math.abs(r.rpm - TARGET) <= rt2_turbine.RPM_BAND, string.format(
    'Enddrehzahl %.0f liegt nicht im Zielband um %d', r.rpm, TARGET))
  assert_true(r.mean_dev <= 15, string.format(
    'mittlere Abweichung %.1f RPM in der zweiten Haelfte -- der Regler steht nicht still', r.mean_dev))
end

-- Der Hochlauf bleibt unbelastet: eine noch nie gekuppelte Turbine
-- beschleunigt ohne Last, die neue Regel greift erst ab der ersten
-- Kupplung.
do
  local ramping = rt2_turbine.compute_coil_decision({
    rpm = 400, target_rpm = TARGET, currently_engaged = false, current_flow = rt2_turbine.MAX_FLOW,
  })
  assert_true(ramping.engaged == false, 'eine anfahrende Turbine beschleunigt weiterhin ohne Last')
end

-- Und das Parken bleibt unveraendert: dort bremst die Spule bis zum
-- Stillstand und gibt erst dann frei.
do
  local parked_spinning = rt2_turbine.compute_coil_decision({
    rpm = 600, target_rpm = 0, currently_engaged = true, current_flow = 0,
  })
  assert_true(parked_spinning.engaged == true, 'ein geparkter, noch drehender Rotor bremst ueber die Spule')

  local parked_stopped = rt2_turbine.compute_coil_decision({
    rpm = 10, target_rpm = 0, currently_engaged = true, current_flow = 0,
  })
  assert_true(parked_stopped.engaged == false, 'steht er, wird die Spule frei')
end

print('rt2_coil_hold_limit_cycle_test.lua: ok')
