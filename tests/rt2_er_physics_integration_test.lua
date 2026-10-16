package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Der echte RT-Stapel gegen ein Anlagenmodell, das aus dem QUELLTEXT von
-- Extreme Reactors 2.4.27 (MC 1.21.1, die Version in ATM10 8.1)
-- uebernommen ist -- siehe tests/support/er_plant_model.lua.
--
-- Warum das etwas anderes ist als die bestehenden Integrationstests:
-- deren Rotormodell ist "Drehzahl folgt dem Durchfluss" mit einem
-- Verzoegerungsglied. Die echte Turbine ist ein INTEGRATOR --
--
--   rotorEnergy += Auftrieb - Spule - Luftwiderstand - Reibung
--   rpm = rotorEnergy / (Blaetter * Rotormasse)
--
-- -- und die Spule ist der groesste Term davon. Eine Stellgroesse wirkt
-- also nicht auf die Drehzahl, sondern auf ihre ABLEITUNG, und das
-- Einhaengen der Spule dreht das Vorzeichen der Beschleunigung um. Beide
-- Eigenschaften fehlten den bisherigen Modellen, und beide sind genau
-- die, an denen sich der Regler entscheidet.
--
-- Die Auslegung hier ist nachgerechnet, nicht geraten: 80 Blaetter auf 20
-- Wellenbloecken mit 74 Enderium-Spulenbloecken ergeben im Modell bei
-- 2000 mB/t 899.6 RPM und 24.1 kFE/t -- also genau den Auslegungspunkt,
-- auf den der Regler zielt. Derselbe Aufbau mit Ludicrite ergibt 47 kFE/t
-- gegen die vom Mod-Autor genannten "rund 45K FE/t aus einer vollen Spule
-- in einer Reinforced-Turbine". Die Kalibrierung stimmt also unabhaengig
-- nach.

local harness = require('support.er_rt_harness')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local TRACE = os.getenv('TRACE')
local h = harness.new({ turbine_count = 6 })

local peak_rpm, overspeed_ticks, coil_toggles, settled_at = 0, 0, 0, nil
local coil_state = {}
for _, n in ipairs(h.turbine_names) do coil_state[n] = false end

local SECONDS = 900
for tick = 1, SECONDS * 10 do
  h:step()
  local all_on_target = true
  for _, n in ipairs(h.turbine_names) do
    local t = h.plant.turbines[n]
    local rpm = t:rotor_speed()
    if rpm > peak_rpm then peak_rpm = rpm end
    if rpm > rt2_turbine.OVERSPEED_RPM then overspeed_ticks = overspeed_ticks + 1 end
    if t.inductor_engaged ~= coil_state[n] then
      coil_toggles = coil_toggles + 1
      coil_state[n] = t.inductor_engaged
    end
    if math.abs(rpm - rt2_turbine.FULL_TARGET_RPM) > rt2_turbine.RPM_BAND
        or t.energy_generated_last_tick <= 0 then
      all_on_target = false
    end
  end
  if all_on_target and not settled_at then settled_at = tick end
  if TRACE and tick % 300 == 0 then
    local t = h.plant.turbines[h.turbine_names[1]]
    print(string.format('t=%6.1fs %-9s T1 rpm=%7.1f flow=%5d coil=%-5s FE/t=%8.0f Dampf=%7d Staebe=%3d',
      tick / 10, tostring(h.last.state), t:rotor_speed(), t.max_intake_rate,
      tostring(t.inductor_engaged), t.energy_generated_last_tick,
      h.plant.reactor.steam, h.plant.reactor.rods))
  end
end

assert_true(h.last.state == rt2_state.states.MASTER or h.last.state == rt2_state.states.AUTONOM,
  'der Knoten muss den Betriebszustand erreichen, steht aber auf ' .. tostring(h.last.state))
assert_true(h.plant.reactor.active, 'der Reaktor muss eingeschaltet worden sein')

assert_true(overspeed_ticks == 0, string.format(
  'Ueberdrehzahl in %d Takten, Spitze %.0f RPM -- %s', overspeed_ticks, peak_rpm, h:describe()))

assert_true(settled_at ~= nil, string.format(
  'die Flotte ist in %d s nie gemeinsam im Zielband mit Energieabgabe angekommen -- %s',
  SECONDS, h:describe()))

-- Dauerflattern der Spule: ein Einhaengen je Turbine ist der Normalfall.
assert_true(coil_toggles <= #h.turbine_names * 3, string.format(
  '%d Spulen-Umschaltungen bei %d Turbinen -- das ist ein Grenzzyklus. %s',
  coil_toggles, #h.turbine_names, h:describe()))

for _, n in ipairs(h.turbine_names) do
  local t = h.plant.turbines[n]
  assert_true(t.inductor_engaged, n .. ' laeuft am Ende ohne eingehaengte Spule -- sie liefert dann nichts')
  assert_true(t.energy_generated_last_tick > 0, n .. ' liefert am Ende keine Energie')
  assert_true(math.abs(t:rotor_speed() - rt2_turbine.FULL_TARGET_RPM) <= rt2_turbine.RPM_BAND,
    string.format('%s steht am Ende bei %.0f RPM statt im Band um %d',
      n, t:rotor_speed(), rt2_turbine.FULL_TARGET_RPM))
end

-- Die Fertigmeldung gehoert EINMAL gemeldet, nicht bei jeder Schwankung
-- der Zaehler im Vergleichsschluessel.
local done_messages = h:count_log('EINLERNEN FERTIG')
assert_true(done_messages <= 1, string.format(
  '"EINLERNEN FERTIG" wurde %dmal gemeldet -- einmal ist richtig', done_messages))

print(string.format('rt2_er_physics_integration_test.lua: ok (eingeschwungen nach %.1fs, Spitze %.0f RPM, %d Spulenschalter)',
  settled_at / 10, peak_rpm, coil_toggles))
