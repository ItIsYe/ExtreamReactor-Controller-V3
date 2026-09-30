package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betriebsfaelle gegen dasselbe quelltextnahe Anlagenmodell wie
-- tests/rt2_er_physics_integration_test.lua (Extreme Reactors 2.4.27,
-- MC 1.21.1 / ATM10 8.1). Hier geht es nicht um den Normalbetrieb,
-- sondern um die Lagen, in denen sich frueher etwas verklemmt hat.

local harness = require('support.er_rt_harness')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ── 1. Basic-Turbinen an einem knapp ausgelegten Reaktor ─────────────────
--
-- Die Basic-Variante ist bei 1000 mB/t hart abgeriegelt
-- (TurbineVariant.setMaxPermittedFlow), und setMaxIntakeRate() KLEMMT
-- einen groesseren Sollwert stillschweigend darauf. Der Regler kennt nur
-- seine eigene Obergrenze -- er muss also damit auskommen, dass der
-- Rueckmesswert kleiner ist als das, was er gestellt hat.
--
-- Dazu ein Reaktor ohne Reserve: der Dampftank laeuft immer wieder leer,
-- die Drehzahl kommt nie ganz zur Ruhe, und die Zaehler at_target/
-- saturated wackeln dauernd. Genau daran hing die Fehlmeldung: der
-- Vergleichsschluessel fuer die Logausgabe enthaelt diese Zaehler, also
-- lief "EINLERNEN FERTIG" mit immer derselben Zahl dutzendfach auf.
do
  local h = harness.new({
    turbine_count = 6,
    turbine = { variant = 'basic', blades = 40, shaft_blocks = 10,
                coil_blocks = 30, coil = 'gold' },
    reactor_headroom = 1.0,   -- kein Polster
  })
  h:run(600)

  assert_true(h.last.state == rt2_state.states.MASTER or h.last.state == rt2_state.states.AUTONOM,
    'Basic-Anlage: der Knoten muss den Betriebszustand erreichen, steht aber auf '
      .. tostring(h.last.state))

  for _, n in ipairs(h.turbine_names) do
    local t = h.plant.turbines[n]
    assert_true(t.max_intake_rate <= t.variant.max_permitted_flow, string.format(
      '%s: der Sollwert %d liegt ueber der harten Grenze %d der Variante',
      n, t.max_intake_rate, t.variant.max_permitted_flow))
    assert_true(t:rotor_speed() <= rt2_turbine.OVERSPEED_RPM, string.format(
      '%s dreht mit %.0f RPM ueber die Abschaltschwelle', n, t:rotor_speed()))
    assert_true(t.inductor_engaged, n .. ': die Spule muss eingehaengt bleiben')
  end

  local done = h:count_log('EINLERNEN FERTIG')
  assert_true(done <= 1, string.format(
    'Basic-Anlage: "EINLERNEN FERTIG" wurde %dmal gemeldet. Einmal ist richtig --'
      .. ' schwankende at_target/saturated-Zaehler duerfen die Fertigmeldung nicht erneut ausloesen.',
    done))
  local corrected = h:count_log('Leistung nach oben korrigiert')
  assert_true(corrected <= 12, string.format(
    'Basic-Anlage: %d Nachfuehrmeldungen -- das ist Protokollrauschen, keine Information',
    corrected))
end

-- ── 2. MASTER-Vorgabe unter 100 % samt Slot-Rotation ─────────────────────
--
-- Unter MASTER teilt rt2_turbine.compute_target_rpm die Flotte auf: die
-- ersten running_count(percent, n) Plaetze fahren auf Zieldrehzahl, der
-- Rest bekommt Ziel 0. Damit nicht immer dieselben Turbinen stillstehen,
-- wandert die Zuordnung alle rt2_orchestrator.ROTATE_INTERVAL_MS (5 min)
-- um einen Platz weiter.
--
-- Das ist der Moment, in dem eine einzelne Turbine aus dem Stillstand
-- gegen die Zieldrehzahl anfaehrt, waehrend eine andere abgebremst wird
-- -- und genau dafuer wurde "eine einzelne Turbine geht nach einiger Zeit
-- in Ueberdrehzahl" gemeldet. Der Lauf geht bewusst ueber mehrere
-- Rotationen hinweg.
do
  local h = harness.new({ turbine_count = 6 })
  local rt2_orchestrator = require('nodes.rt.rt2_orchestrator')

  local peak, overspeed_ticks, parked_seen = 0, 0, false
  local rotations = 3
  local seconds = math.ceil((rt2_orchestrator.ROTATE_INTERVAL_MS / 1000) * rotations) + 400

  for _ = 1, seconds * 10 do
    h:step(function(self)
      -- MASTER ist erreichbar und fordert 50 % -- also faehrt die halbe
      -- Flotte, die andere Haelfte steht.
      self.engine.note_master_seen(self.clock_ms)
      self.engine.handle_command({ target = 'SET_SETPOINTS',
        value = { power_target_percent = 50 } })
    end)
    for _, n in ipairs(h.turbine_names) do
      local t = h.plant.turbines[n]
      local rpm = t:rotor_speed()
      if rpm > peak then peak = rpm end
      if rpm > rt2_turbine.OVERSPEED_RPM then overspeed_ticks = overspeed_ticks + 1 end
    end
    for _, tr in ipairs(h.last.turbines or {}) do
      if (tr.target_rpm or 0) <= 0 then parked_seen = true end
    end
  end

  assert_true(h.last.state == rt2_state.states.MASTER, string.format(
    'mit erreichbarem MASTER muss der Knoten in MASTER regeln, steht aber auf %s',
    tostring(h.last.state)))
  assert_true(parked_seen,
    'bei 50 %% Vorgabe muss ein Teil der Flotte auf Ziel 0 stehen -- sonst prueft dieser Fall nichts')
  assert_true(overspeed_ticks == 0, string.format(
    'Ueberdrehzahl in %d Takten ueber %d Rotationen, Spitze %.0f RPM -- %s',
    overspeed_ticks, rotations, peak, h:describe()))

  -- Die laufenden Turbinen muessen am Ziel stehen UND liefern; die
  -- geparkten muessen wirklich heruntergebremst sein.
  local running, parked = 0, 0
  for i, n in ipairs(h.turbine_names) do
    local t = h.plant.turbines[n]
    local decision = h.last.turbines and h.last.turbines[i]
    local target = decision and decision.target_rpm or 0
    if target > 0 then
      running = running + 1
      assert_true(t.max_intake_rate > 0, n .. ' soll laufen, bekommt aber keinen Dampf')
    else
      parked = parked + 1
      assert_true(t.max_intake_rate == 0, string.format(
        '%s ist auf Ziel 0 gestellt, bekommt aber noch %d mB/t', n, t.max_intake_rate))
    end
  end
  assert_true(running > 0 and parked > 0, string.format(
    'bei 50 %% erwartet: ein Teil laeuft, ein Teil steht (laufend=%d, geparkt=%d)',
    running, parked))
end

print('rt2_er_physics_scenarios_test.lua: ok')
