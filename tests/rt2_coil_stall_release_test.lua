package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression zu einem Fehler, den die Spulenverriegelung aus v798 selbst
-- eingebaut hat.
--
-- v798 hat richtig behoben, dass eine einmal gekuppelte Turbine nicht mehr
-- bei 850 RPM aushaengt -- dieses Flattern war die Ursache fuer die
-- Ueberdrehzahl. Die dabei eingebaute Notfreigabe ("die Spule verhindert
-- den Hochlauf nachweislich") griff aber erst unter 50 % der
-- Zieldrehzahl. Eine Turbine, deren Spule staerker bremst als der Dampf
-- schieben kann, landet nicht dort unten, sondern bei 750-800 RPM -- also
-- genau DAZWISCHEN. Sie blieb damit dauerhaft haengen:
--
--   gemessen am quelltextnahen Anlagenmodell, 90 Enderium-Spulenbloecke
--   auf 80 Blaettern, Dampf im Ueberfluss, 600 s:
--     v798:          749 RPM, Flow 2000, Spule drin,  2.2 % im Zielband
--     vor v798:      853 RPM, Flow 2000, Spule raus, 15.6 % im Zielband
--
-- Auf dem Schirm sah das aus wie die drei Meldungen aus dem Betrieb:
-- "Spule auch unter 900 aktiv", "Flow dauerhaft 2000 obwohl RPM darueber"
-- (auf dem Weg nach unten) und "das Einlernen findet keine Turbinen im
-- Zielbereich" -- das verlangt |rpm-900| <= LEARN_TOLERANCE_RPM.
--
-- Die Freigabeschwelle liegt jetzt bei 95 % der Zieldrehzahl, und sie
-- verlangt zusaetzlich, dass die Drehzahl NICHT MEHR STEIGT. Das ist die
-- Entprellung: direkt nach einer Freigabe steigt sie, also kann die
-- Freigabe nicht im Takt wiederkehren -- der Grenzzyklus aus v798 kommt
-- damit nicht zurueck.
--
-- Hinweis zur Beweislage: dieser Test bricht gegen den Vorstand mit einem
-- harten Fehler, weil compute_rate() dort noch nicht existiert. Den
-- VERHALTENSnachweis fuehrt tests/rt2_er_physics_scenarios_test.lua ueber
-- den echten Adapterstapel -- dort steht gegen den Vorstand "nur in 1.5 %
-- der Takte im Zielband".

local ER = require('support.er_plant_model')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_orchestrator = require('nodes.rt.rt2_orchestrator')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

local TARGET = rt2_turbine.FULL_TARGET_RPM

-- ── Die reine Entscheidungsfunktion ──────────────────────────────────────

-- 1. Alle drei Bedingungen muessen gelten, sonst bleibt die Spule drin.
do
  local base = { target_rpm = TARGET, currently_engaged = true }
  local stall_rpm = TARGET * rt2_turbine.COIL_STALL_RPM_FRACTION

  local function decide(over)
    local input = {}
    for k, v in pairs(base) do input[k] = v end
    for k, v in pairs(over) do input[k] = v end
    return rt2_turbine.compute_coil_decision(input)
  end

  assert_eq(decide({ rpm = stall_rpm - 1, current_flow = rt2_turbine.MAX_FLOW }).reason,
    'RELEASE_STALLED', 'unter der Schwelle und Dampf am Anschlag: Freigabe')

  assert_eq(decide({ rpm = stall_rpm - 1, current_flow = rt2_turbine.MAX_FLOW - 1 }).engaged, true,
    'solange der Regler noch Dampf uebrig hat, ist nicht die Spule das Hindernis')

  assert_eq(decide({ rpm = stall_rpm + 1, current_flow = rt2_turbine.MAX_FLOW }).engaged, true,
    'oberhalb der Schwelle wird nicht freigegeben')

  assert_eq(decide({ rpm = stall_rpm - 1, current_flow = rt2_turbine.MAX_FLOW,
                     rate_rpm_per_s = rt2_turbine.SETTLE_RATE_RPM_PER_S + 1 }).engaged, true,
    'eine noch STEIGENDE Drehzahl heisst: die Spule verhindert den Hochlauf gerade nicht')

  assert_eq(decide({ rpm = stall_rpm - 1, current_flow = rt2_turbine.MAX_FLOW,
                     rate_rpm_per_s = -50 }).reason, 'RELEASE_STALLED',
    'eine fallende Drehzahl dagegen schon')

  assert_eq(decide({ rpm = stall_rpm - 1 }).engaged, true,
    'ohne bekannten Durchfluss wird nicht freigegeben -- unbekannt ist kein Nachweis')
end

-- 2. Die Schwelle liegt unter dem Zielband, aber nicht mehr tief unten.
do
  local stall_rpm = TARGET * rt2_turbine.COIL_STALL_RPM_FRACTION
  assert_true(stall_rpm < TARGET - rt2_turbine.RPM_BAND, string.format(
    'die Freigabeschwelle (%.0f) muss UNTER dem Zielband liegen (%.0f)',
    stall_rpm, TARGET - rt2_turbine.RPM_BAND))
  assert_true(stall_rpm > TARGET - 2 * rt2_turbine.RPM_BAND, string.format(
    'und nicht so tief, dass eine bei 750-800 RPM haengende Turbine darueber bleibt (%.0f)', stall_rpm))
end

-- 3. compute_rate ist die EINE Quelle fuer beide Entscheidungen.
do
  assert_eq(rt2_turbine.compute_rate({ rpm = 900, last_rpm = 880, last_rpm_ms = 0, now_ms = 1000 }), 20)
  assert_eq(rt2_turbine.compute_rate({ rpm = 900 }), nil, 'ohne Bezugspunkt keine Rate')
  assert_eq(rt2_turbine.compute_rate({ rpm = 900, last_rpm = 880, last_rpm_ms = 1000, now_ms = 1000 }), nil,
    'ohne Zeitabstand keine Rate')
  assert_eq(rt2_turbine.compute_rate({ rpm = 900, last_rpm = 880,
    last_rpm_ms = 0, now_ms = rt2_turbine.MAX_RATE_AGE_MS + 1 }), nil, 'ein zu alter Bezugspunkt zaehlt nicht')
  assert_eq(rt2_turbine.compute_rate({ rpm = 900, last_rpm = 880, last_rpm_ms = 2000, now_ms = 1000 }), nil,
    'ein Uhrruecksprung ergibt keine Rate')
end

-- ── Der geschlossene Regelkreis am Anlagenmodell ─────────────────────────

local function run_single(spec, seconds, supply_share)
  supply_share = supply_share or 1.0
  local t = ER.new_turbine(spec)
  t.active = true
  local now, DT, hist = 0, 100, {}
  local in_band, toggles, last, peak, energy = 0, 0, false, 0, 0
  for _ = 1, seconds * 10 do
    now = now + DT
    local ref_rpm, ref_ms
    for i = #hist, 1, -1 do
      if now - hist[i][1] >= rt2_turbine.MIN_RATE_WINDOW_MS then
        ref_ms, ref_rpm = hist[i][1], hist[i][2]; break
      end
    end
    local rpm = t:rotor_speed()
    local decision = rt2_turbine.compute_flow_decision({
      rpm = rpm, target_rpm = TARGET, current_flow = t.max_intake_rate,
      coil_engaged = t.inductor_engaged, now_ms = now,
      last_rpm = ref_rpm, last_rpm_ms = ref_ms, dt_ms = DT,
    })
    local coil = rt2_turbine.compute_coil_decision({
      rpm = rpm, target_rpm = TARGET, currently_engaged = t.inductor_engaged,
      current_flow = decision.flow,
      rate_rpm_per_s = rt2_turbine.compute_rate({
        rpm = rpm, last_rpm = ref_rpm, last_rpm_ms = ref_ms, now_ms = now }),
    })
    t:set_max_intake_rate(decision.flow)
    if coil.engaged ~= last then toggles = toggles + 1; last = coil.engaged end
    t.inductor_engaged = coil.engaged
    hist[#hist + 1] = { now, rpm }
    for _ = 1, 2 do
      t.vapor_amount = math.floor(t.max_intake_rate * supply_share)
      t:tick()
    end
    local after = t:rotor_speed()
    if math.abs(after - TARGET) <= rt2_orchestrator.LEARN_TOLERANCE_RPM then in_band = in_band + 1 end
    if after > peak then peak = after end
    energy = energy + t.energy_generated_last_tick
  end
  local n = seconds * 10
  return { rpm = t:rotor_speed(), flow = t.max_intake_rate, coil = t.inductor_engaged,
           in_band_pct = in_band / n * 100, toggles = toggles, peak = peak, fe = energy / n }
end

-- 4. Eine Turbine, deren Spule staerker bremst als der Dampf schieben kann,
--    MUSS das Zielband erreichen -- sonst zaehlt das Einlernen sie nie.
do
  for _, spec in ipairs({
    { variant = 'reinforced', blades = 80, shaft_blocks = 20, coil_blocks = 90, coil = 'enderium' },
    { variant = 'reinforced', blades = 80, shaft_blocks = 20, coil_blocks = 74, coil = 'ludicrite' },
  }) do
    local r = run_single(spec, 900)
    assert_true(r.in_band_pct > 5, string.format(
      '%d x %s: nur %.1f %% der Takte im Zielband (rpm am Ende %.0f, Flow %d) --'
        .. ' das Einlernen kann diese Turbine nie zaehlen',
      spec.coil_blocks, spec.coil, r.in_band_pct, r.rpm, r.flow))
    assert_true(r.peak <= rt2_turbine.OVERSPEED_RPM, string.format(
      '%d x %s: Spitze %.0f RPM reisst die Ueberdrehzahlschwelle',
      spec.coil_blocks, spec.coil, r.peak))
    -- Langsames Pendeln ist in Ordnung, Flattern im Takt nicht.
    assert_true(r.toggles < 900 * 10 / 100, string.format(
      '%d x %s: %d Spulen-Umschaltungen in 900 s -- das waere wieder ein Grenzzyklus',
      spec.coil_blocks, spec.coil, r.toggles))
    assert_true(r.fe > 0, 'und liefern muss sie dabei')
  end
end

-- 5. Die ausgelegte Turbine bleibt vollstaendig unberuehrt. Dort steht die
--    Drehzahl im Band, also kann die Freigabe nicht greifen -- das ist der
--    Grund, warum 95 % trotz der Naehe zum Band sicher sind.
do
  local r = run_single({ variant = 'reinforced', blades = 80, shaft_blocks = 20,
                         coil_blocks = 74, coil = 'enderium' }, 900)
  assert_eq(r.coil, true, 'die ausgelegte Turbine laeuft mit eingehaengter Spule')
  assert_eq(r.toggles, 1, 'sie kuppelt genau einmal und bleibt -- kein Pendeln')
  assert_true(math.abs(r.rpm - TARGET) <= rt2_turbine.RPM_BAND, string.format(
    'und steht im Zielband (%.1f RPM)', r.rpm))
  assert_true(r.in_band_pct > 50, string.format(
    'die ueberwiegende Zeit sogar im engen Lernband (%.1f %%)', r.in_band_pct))
end

-- 6. Eine Turbine, deren Durchfluss NICHT am Anschlag steht, kann die
--    Freigabe gar nicht erreichen -- unabhaengig von ihrer Drehzahl.
do
  local r = run_single({ variant = 'reinforced', blades = 32, shaft_blocks = 8,
                         coil_blocks = 30, coil = 'enderium' }, 600)
  assert_true(r.flow < rt2_turbine.MAX_FLOW, string.format(
    'Vorbedingung: diese Turbine braucht nicht den vollen Durchfluss (%d)', r.flow))
  assert_eq(r.toggles, 1, 'also kuppelt sie einmal und bleibt')
  assert_eq(r.coil, true)
end

print('rt2_coil_stall_release_test.lua: ok')
