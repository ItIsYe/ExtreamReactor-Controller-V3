package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- ── compute_target_rpm ───────────────────────────────────────────────────

assert_eq(rt2_turbine.compute_target_rpm("AUTONOM", { power_percent = 0 }), 900,
  'AUTONOM turbines target the fixed RPM (the reactor handles independence, not the turbines)')
assert_eq(rt2_turbine.compute_target_rpm("SAFE", {}), 0, 'SAFE targets 0 for every turbine')
assert_eq(rt2_turbine.compute_target_rpm("INIT", { power_percent = 0 }), 900,
  'any non-MASTER state targets the fixed RPM')

-- MASTER: die Vorgabe in Prozent bestimmt, WIEVIELE Turbinen laufen. Es
-- gibt keinen Teillast-Platz mehr -- eine Turbine laeuft auf 900 oder sie
-- steht.
do
  local full, off, other = 0, 0, 0
  for slot = 1, 25 do
    local target = rt2_turbine.compute_target_rpm("MASTER",
      { turbine_count = 25, slot_index = slot, power_percent = 50 })
    if target == 900 then full = full + 1
    elseif target == 0 then off = off + 1
    else other = other + 1 end
  end
  assert_eq(full, 13, '50% of 25 turbines: 13 run (12.5 rounded up)')
  assert_eq(off, 12, '50% of 25 turbines: 12 stand')
  assert_eq(other, 0, 'no turbine gets a partial target any more')
end

do
  local full, off = 0, 0
  for slot = 1, 50 do
    local target = rt2_turbine.compute_target_rpm("MASTER",
      { turbine_count = 50, slot_index = slot, power_percent = 60 })
    if target == 900 then full = full + 1 else off = off + 1 end
  end
  assert_eq(full, 30, '60% of 50 turbines: 30 run')
  assert_eq(off, 20, '60% of 50 turbines: 20 stand')
end

-- 100 % heisst die ganze Flotte, 0 % heisst keine einzige.
do
  for slot = 1, 10 do
    assert_eq(rt2_turbine.compute_target_rpm("MASTER",
      { turbine_count = 10, slot_index = slot, power_percent = 100 }), 900,
      'at 100% every turbine runs')
    assert_eq(rt2_turbine.compute_target_rpm("MASTER",
      { turbine_count = 10, slot_index = slot, power_percent = 0 }), 0,
      'at 0% no turbine runs')
  end
end

-- Eine Vorgabe ueber 0 laesst immer mindestens eine Turbine laufen --
-- sonst faellt eine grosse Flotte bei kleinem Bedarf ganz aus.
do
  assert_eq(rt2_turbine.compute_target_rpm("MASTER",
    { turbine_count = 50, slot_index = 1, power_percent = 1 }), 900,
    'above 0% at least one turbine runs')
  assert_eq(rt2_turbine.compute_target_rpm("MASTER",
    { turbine_count = 50, slot_index = 2, power_percent = 1 }), 0,
    'and only that one')
end

-- Ein-Turbinen-Flotte: entweder sie laeuft auf 900 oder sie steht. Eine
-- krumme Zieldrehzahl gibt es nicht mehr.
do
  assert_eq(rt2_turbine.compute_target_rpm("MASTER", { turbine_count = 1, slot_index = 1, power_percent = 20 }), 900)
  assert_eq(rt2_turbine.compute_target_rpm("MASTER", { turbine_count = 1, slot_index = 1, power_percent = 0 }), 0)
end

-- ── compute_flow_decision ────────────────────────────────────────────────

-- Regression: an AUS-slot turbine (target_rpm=0) spinning at thousands of
-- RPM must be forced to flow=0 immediately -- this was the exact bug
-- reported 2026-09-18 (node-101/102/103: STATUS=OFF turbines sitting on
-- 2.0k-3.0k flow at 1000-3200 RPM while the "ON" ones correctly throttled).
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 2866, target_rpm = 0, current_flow = 2000, max_flow = 2000 })
  assert_eq(d.flow, 0, 'AUS-slot turbine massively overspeeding must be forced to flow=0 immediately')
  assert_eq(d.reason, 'TARGET_ZERO', 'reason must reflect the target-zero rule')
end

-- A real overspeed case (positive target, RPM far above it) must also be
-- forced to 0 immediately -- same outcome, different reason, so a caller
-- can tell "parked" apart from "braking".
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 2000, target_rpm = 900, current_flow = 2000, max_flow = 2000 })
  assert_eq(d.flow, 0, 'genuine overspeed must be forced to flow=0')
  assert_eq(d.reason, 'OVERSPEED', 'reason must reflect genuine overspeed, distinct from TARGET_ZERO')
end

-- Eine fehlende Drehzahlmessung ist nicht "0 RPM": ohne Messwert kein Dampf.
do
  local d = rt2_turbine.compute_flow_decision({ rpm = nil, target_rpm = 900, current_flow = 1500 })
  assert_eq(d.flow, 0, 'an unreadable RPM must cut the steam, not raise it')
  assert_eq(d.reason, 'NO_RPM_READING')
end

-- Die Ueberdrehzahl-Abschaltung ist eine ABSOLUTE Maschinengrenze, kein
-- Zuschlag auf das Ziel. Darunter regelt der Regler ganz normal herunter.
do
  local limit = rt2_turbine.OVERSPEED_RPM
  local below = rt2_turbine.compute_flow_decision({ rpm = limit - 1, target_rpm = 900, current_flow = 1000 })
  assert_eq(below.reason, 'TRIM_DOWN', 'below the machine limit a turbine trims down toward its target')
  local above = rt2_turbine.compute_flow_decision({ rpm = limit + 1, target_rpm = 900, current_flow = 1000 })
  assert_eq(above.reason, 'OVERSPEED', 'at the limit the steam is cut')
  assert_eq(above.flow, 0)
end

-- Es gibt genau EIN Regelgesetz, und jeder seiner Zweige muss erreichbar
-- bleiben. Vorher lagen hier vier Verfahren nebeneinander (Rampe,
-- Feintrimmung, Kennlinie, Vorausschau), von denen eines schon einmal
-- vollstaendig unerreichbar war.
do
  local reached = {}
  for rpm = 0, 3000 do
    reached[rt2_turbine.compute_flow_decision({ rpm = rpm, target_rpm = 900, current_flow = 1000 }).reason] = true
  end
  assert_true(reached.TRIM_UP, 'TRIM_UP must be reachable')
  assert_true(reached.TRIM_DOWN, 'TRIM_DOWN must be reachable')
  assert_true(reached.SETTLED, 'SETTLED must be reachable')
  assert_true(reached.OVERSPEED, 'OVERSPEED must be reachable')
  -- Feinzone nah am Ziel (FINE_BAND_RPM): dieselbe Entscheidung, nur mit
  -- verkuerztem Vorhalt und gedeckeltem Schritt -- deshalb ein eigener
  -- Grund, damit von aussen sichtbar ist, welcher Zweig gerade stellt.
  assert_true(reached.FINE_UP, 'FINE_UP must be reachable')
  assert_true(reached.FINE_DOWN, 'FINE_DOWN must be reachable')
  local count = 0
  for _ in pairs(reached) do count = count + 1 end
  assert_eq(count, 6, 'and nothing else -- one control law, six outcomes')
end

-- Der Schritt ist PROPORTIONAL zur Abweichung: winzig nah am Ziel, ein
-- voller TRIM_STEP am Rand des Zielbands. Kein Sprung dazwischen.
do
  -- 894 liegt innerhalb der Feinzone, deshalb FINE_UP -- der Schritt ist
  -- dort zusaetzlich gedeckelt, die Aussage "nah am Ziel bleibt er klein"
  -- gilt unveraendert.
  local near = rt2_turbine.compute_flow_decision({ rpm = 894, target_rpm = 900, current_flow = 1200, band = 40 })
  assert_eq(near.reason, 'FINE_UP')
  assert_true(near.flow - 1200 <= 6, 'close to the target the step stays small, got ' .. tostring(near.flow - 1200))

  local far = rt2_turbine.compute_flow_decision({ rpm = 860, target_rpm = 900, current_flow = 1200, band = 40 })
  assert_true(far.flow - 1200 > near.flow - 1200, 'further from the target the step must be larger')
  assert_eq(far.flow - 1200, rt2_turbine.TRIM_STEP, 'at the band edge exactly one full step')

  local beyond = rt2_turbine.compute_flow_decision({ rpm = 100, target_rpm = 900, current_flow = 1200, band = 40 })
  assert_eq(beyond.flow - 1200, rt2_turbine.TRIM_STEP, 'and never more than one full step, however far off')
end

-- Ruhezone: nah genug am Ziel wird gar nicht mehr gestellt.
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 898, target_rpm = 900, current_flow = 1200 })
  assert_eq(d.reason, 'SETTLED')
  assert_eq(d.flow, 1200, 'inside the settle band the commanded flow does not move')
end

-- Stellintervall: die letzte Verstellung muss erst wirken koennen.
do
  local d = rt2_turbine.compute_flow_decision({
    rpm = 700, target_rpm = 900, current_flow = 1200,
    now_ms = 10000, last_change_ms = 9800,
  })
  assert_eq(d.reason, 'SETTLING', 'within the adjust interval nothing is commanded')
  assert_eq(d.flow, 1200)

  local due = rt2_turbine.compute_flow_decision({
    rpm = 700, target_rpm = 900, current_flow = 1200,
    now_ms = 10000, last_change_ms = 9000,
  })
  assert_eq(due.reason, 'TRIM_UP', 'once the interval has passed the regulator acts')
end

-- Ohne jeden Bezugspunkt (kein Rueckmesswert, kein zuletzt gestellter
-- Wert) gibt es nichts zu halten -- dann darf gar nicht gestellt werden.
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 900, target_rpm = 900, current_flow = nil })
  assert_eq(d.reason, 'SETTLED')
  assert_eq(d.unchanged, true, 'an unknown flow must not be written as 0')

  local known = rt2_turbine.compute_flow_decision({
    rpm = 900, target_rpm = 900, current_flow = nil, last_commanded_flow = 1400,
  })
  assert_eq(known.flow, 1400, 'the regulator falls back on its own last command')
  assert_true(not known.unchanged)
end

-- ── compute_coil_decision ────────────────────────────────────────────────

-- The coil is the brake, so a parked turbine that is STILL SPINNING keeps
-- it engaged: that slows the rotor down and harvests the energy on the way
-- instead of letting it coast. It only releases once basically stopped.
do
  local spinning = rt2_turbine.compute_coil_decision({ rpm = 2000, target_rpm = 0, currently_engaged = true })
  assert_eq(spinning.engaged, true, 'a parked turbine that still spins must brake through its coil, not coast')
  assert_eq(spinning.reason, 'BRAKE_TO_STOP')

  local stopped = rt2_turbine.compute_coil_decision({ rpm = 10, target_rpm = 0, currently_engaged = true })
  assert_eq(stopped.engaged, false, 'once stopped there is nothing left to brake or harvest')
  assert_eq(stopped.reason, 'STOPPED')
end

-- Braking toward a LOWER target must couple too, even from uncoupled --
-- waiting for the engage threshold there would mean coasting exactly when
-- braking is wanted.
do
  local d = rt2_turbine.compute_coil_decision({ rpm = 900, target_rpm = 450, currently_engaged = false })
  assert_eq(d.engaged, true, 'a turbine well above a lowered target must couple to brake down to it')
  assert_eq(d.reason, 'BRAKE_TO_TARGET')
end

-- Spinning UP must stay uncoupled so the rotor can accelerate unloaded.
do
  assert_eq(rt2_turbine.compute_coil_decision({ rpm = 100, target_rpm = 900, currently_engaged = false }).engaged, false,
    'a turbine ramping up must not be braked by its own coil')
  assert_eq(rt2_turbine.compute_coil_decision({ rpm = 850, target_rpm = 900, currently_engaged = false }).engaged, false,
    'still below the engage threshold on the way up -- stays uncoupled')
end

-- A PUFFER-slot turbine at 450 RPM target must engage/disengage scaled to
-- 450, not the full 900 -- otherwise it would never appear to reach target.
do
  local d = rt2_turbine.compute_coil_decision({ rpm = 450, target_rpm = 450, currently_engaged = false })
  assert_eq(d.engaged, true, 'a 450 RPM-target turbine at 450 RPM must engage (scaled threshold)')
end

do
  local d = rt2_turbine.compute_coil_decision({ rpm = 400, target_rpm = 900, currently_engaged = false })
  assert_eq(d.engaged, false, 'the same 400 RPM must NOT engage against a 900 RPM target (unscaled would wrongly hold this near the 450 case)')
end

-- ── compute_active_decision ──────────────────────────────────────────────

do
  assert_true(rt2_turbine.compute_active_decision(false), 'a turbine reading OFF must be turned on')
  assert_true(rt2_turbine.compute_active_decision(nil), 'an unknown active reading must fail toward turning it on')
  assert_true(not rt2_turbine.compute_active_decision(true), 'a turbine already ON must not be re-activated every tick')
end

print('rt2_turbine_test.lua: ok')
