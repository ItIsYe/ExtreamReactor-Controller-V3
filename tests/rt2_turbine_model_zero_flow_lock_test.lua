package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb, doppelter Aufbau, unmittelbar nachvollzogen:
--
--   Kopfzeile LEARNING, Spulen eingehaengt, Drehzahl unter Ziel --
--   und der Durchfluss auf der GANZEN Flotte 0.
--
-- Im Einlernen bekommt jede Turbine 900 RPM als Ziel, TARGET_ZERO kann
-- also nicht greifen. Der Regler hat den Durchfluss 0 tatsaechlich
-- AUSGERECHNET, und zwar aus der gelernten Kennlinie:
--
--   operating = (Ziel - Achsenabschnitt) / Steigung
--
-- Die Steigung war begrenzt (0.05..20), der Achsenabschnitt nicht. Ein
-- Achsenabschnitt nahe der Zieldrehzahl behauptet, der Rotor halte seine
-- Drehzahl OHNE Dampf -- der Vorsteuerwert wird winzig und auf 0
-- gerundet. Der Regler stellt 0 und haelt es fuer richtig.
--
-- Und so eine Kennlinie entsteht genau dann, wenn ein AUSLAUFENDER Rotor
-- bei Durchfluss 0 mit eingehaengter Spule vermessen wird: hohe Drehzahl,
-- kein Dampf. Das ist der Zustand, in dem dieser Knoten stand -- die
-- kaputte Lage hat sich ihre eigene Begruendung eingelernt.

local rt2_turbine = require('nodes.rt.rt2_turbine')
local model_lib = require('nodes.rt.rt2_turbine_model')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ══ 1. Die Kennlinie aus dem Betrieb wuergt die Turbine nicht mehr ab ══

do
  -- "900 RPM bei 0.5 mB/t" -- rechnerisch aus 890 RPM Achsenabschnitt.
  local giftig = { slope = 20, intercept = 890, min_adjust_interval_ms = 800 }
  local d = rt2_turbine.compute_flow_decision({
    rpm = 450, target_rpm = 900, current_flow = 0,
    coil_engaged = true, model = giftig,
  })
  assert_true(d.flow > 0, string.format(
    'eine Kennlinie darf die Turbine nicht auf Durchfluss 0 festnageln (Durchfluss %s, Grund %s)',
    tostring(d.flow), tostring(d.reason)))
  assert_true(d.reason ~= 'MODEL_FEEDFORWARD',
    'und sie darf fuer die Vorsteuerung gar nicht erst benutzt werden: ' .. tostring(d.reason))
end

-- ══ 2. Eine brauchbare Kennlinie wird weiter benutzt ═══════════════════
--
-- Sonst waere die Selbstvermessung mit dieser Aenderung wertlos.

do
  -- 1200 mB/t tragen 900 RPM -- eine plausible Turbine.
  local gut = { slope = 0.75, intercept = 0, min_adjust_interval_ms = 800 }
  local d = rt2_turbine.compute_flow_decision({
    rpm = 450, target_rpm = 900, current_flow = 100,
    coil_engaged = true, model = gut,
  })
  assert_eq(d.reason, 'MODEL_FEEDFORWARD', 'die Kennlinie traegt die Vorsteuerung')
  assert_eq(d.flow, 1200, 'und zwar genau auf ihren Beharrungswert')
end

-- ══ 3. So eine Kennlinie entsteht gar nicht erst ═══════════════════════

do
  local state = model_lib.new_state()
  local now = 0
  -- Ein auslaufender Rotor bei Durchfluss 0, Spule eingehaengt: genau die
  -- Messpunkte, die der Knoten stundenlang geliefert hat.
  for rpm = 900, 400, -25 do
    now = now + 1500
    state = model_lib.observe(state, { now_ms = now, flow = 0, rpm = rpm, coil_engaged = true })
    now = now + 1500
    state = model_lib.observe(state, { now_ms = now, flow = 60, rpm = rpm, coil_engaged = true })
  end
  local profile, why = model_lib.derive(state)
  if profile then
    assert_true(profile.intercept <= model_lib.MAX_INTERCEPT_RPM, string.format(
      'eine Kennlinie mit %0.f RPM bei Durchfluss 0 darf nicht entstehen', profile.intercept))
  else
    assert_true(why ~= nil, 'und wenn sie verworfen wird, mit Begruendung')
  end
end

-- ══ 4. Eine bereits GESPEICHERTE schlechte Kennlinie wird verworfen ════
--
-- Sie liegt auf dem Rechner und ueberdauert jede Codeaenderung -- genau
-- daran ist in dieser Anlage schon einmal ein vollstaendiger Rollback
-- gescheitert.

do
  local datei = {
    learning_version = model_lib.LEARNING_VERSION,
    units = {
      giftig = { modelled = true, slope = 20, intercept = 890,
                 min_adjust_interval_ms = 800, samples = 12, flow_spread = 300 },
      gut    = { modelled = true, slope = 0.75, intercept = -10,
                 min_adjust_interval_ms = 800, samples = 12, flow_spread = 300 },
    },
  }
  local loaded = model_lib.load_units({ path = '/p', read_config = function() return datei end })
  assert_true(loaded.giftig == nil,
    'eine gespeicherte Kennlinie mit unmoeglichem Achsenabschnitt darf nicht geladen werden')
  assert_true(loaded.gut ~= nil, 'die brauchbare daneben bleibt erhalten')
end

print('rt2_turbine_model_zero_flow_lock_test.lua: ok')
