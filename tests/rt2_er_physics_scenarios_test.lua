package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betriebsfaelle gegen dasselbe quelltextnahe Anlagenmodell wie
-- tests/rt2_er_physics_integration_test.lua (Extreme Reactors 2.4.27,
-- MC 1.21.1 / ATM10 8.1). Hier geht es nicht um den Normalbetrieb,
-- sondern um die Lagen, in denen sich frueher etwas verklemmt hat.

local harness = require('support.er_rt_harness')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_state = require('nodes.rt.rt2_state')
local rt2_orchestrator = require('nodes.rt.rt2_orchestrator')

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

-- ── 3. Ueberdimensionierter Reaktor: Staebe am Anschlag ist GESUND ────────
--
-- Der Normalfall einer gewachsenen Anlage: der Reaktor kann bei Staeben 70
-- (rt2_reactor.ROD_MIN, die bewusste Leistungsgrenze) ein Mehrfaches des
-- Flottenbedarfs liefern. Dazu ein realistisch KLEINER Dampftank --
-- getHotFluidAmountMax ist 1000 mB je Kuehlmittel-Port
-- (ReactorVariant.setPartFluidCapacity), nicht die 200000 Obergrenze, also
-- liegt die Tankgroesse in der Groessenordnung EINES Takts Flottenbedarf.
--
-- Folge: der gemessene Fuellstand bleibt dauerhaft unter dem Sollwert von
-- 70 %, weil in jedem Takt abgezogen wird -- der Stabregler fordert also
-- fuer immer mehr Leistung und steht am Anschlag. Das sieht nach einem
-- festgefahrenen Regler aus, ist aber der gesunde Zustand: die Turbinen
-- bekommen jeden mB, den sie anfordern, und nichts schwingt. Dieser Test
-- haelt das fest, damit es niemand "repariert".
do
  local h = harness.new({ turbine_count = 6, reactor_headroom = 4.0, steam_capacity = 20000 })
  h:run(900)

  local starved = 0
  for _, n in ipairs(h.turbine_names) do
    local t = h.plant.turbines[n]
    if t.fluid_consumed_last_tick < t.max_intake_rate then starved = starved + 1 end
    assert_true(math.abs(t:rotor_speed() - rt2_turbine.FULL_TARGET_RPM) <= rt2_turbine.RPM_BAND,
      string.format('%s steht bei %.0f RPM statt im Band um %d',
        n, t:rotor_speed(), rt2_turbine.FULL_TARGET_RPM))
    assert_true(t.energy_generated_last_tick > 0, n .. ' liefert keine Energie')
  end
  assert_true(starved == 0, string.format(
    '%d Turbinen bekommen weniger Dampf als angefordert, obwohl der Reaktor ein Mehrfaches liefern kann',
    starved))
  assert_true(h.plant.reactor.rods == 70, string.format(
    'bei Dampfueberschuss muss der Stabregler am Anschlag stehen (erwartet 70, ist %d)',
    h.plant.reactor.rods))
end

-- ── 4. Ungleiche Flotte ──────────────────────────────────────────────────
--
-- In einer gewachsenen Anlage sind die Turbinen selten identisch, und das
-- Verhaeltnis Spule zu Blaettern entscheidet, wieviel Gegenmoment je
-- Drehzahl zur Verfuegung steht. Zwei Grenzfaelle gehoeren ausdruecklich
-- dazu:
--
--   * eine Turbine, deren Spule STAERKER bremst, als der Dampf schieben
--     kann (Ludicrite auf derselben Blattzahl) -- sie bleibt bei vollem
--     Durchfluss unter dem Zielband. Richtig ist: Durchfluss am Anschlag,
--     Spule bleibt drin, und das Einlernen zaehlt sie nicht mit.
--   * eine Turbine OHNE Spule -- sie kann gar nicht gebremst werden.
--     Richtig ist: Durchfluss 0, denn jeder Dampf treibt sie unbegrenzt
--     hoch (ein unbelasteter Rotor haelt die Zieldrehzahl schon bei rund
--     3 mB/t; bei 10 mB/t liegt sein Gleichgewicht ueber 4000 RPM).
do
  local ER = require('support.er_plant_model')
  local builds = {
    { blades = 80, shaft_blocks = 20, coil_blocks = 74, coil = 'enderium' },
    { blades = 80, shaft_blocks = 20, coil_blocks = 37, coil = 'enderium' },
    { blades = 32, shaft_blocks = 8,  coil_blocks = 30, coil = 'enderium' },
    { blades = 32, shaft_blocks = 8,  coil_blocks = 10, coil = 'gold' },
    { blades = 80, shaft_blocks = 20, coil_blocks = 74, coil = 'ludicrite' },
    { blades = 80, shaft_blocks = 20, coil_blocks = 0,  coil = 'iron' },
  }
  local h = harness.new({ turbine_count = #builds, reactor_headroom = 4.0, steam_capacity = 20000 })
  for i, b in ipairs(builds) do
    b.variant = 'reinforced'
    h.plant.turbines[h.turbine_names[i]] = ER.new_turbine(b)
  end

  local peak, overspeed = 0, 0
  local in_band_ticks, coil_toggles, energy_ticks = {}, {}, {}
  local coil_last = {}
  local energy_sum = {}
  for i = 1, #builds do
    in_band_ticks[i] = 0; coil_toggles[i] = 0; energy_ticks[i] = 0
    energy_sum[i] = 0; coil_last[i] = false
  end
  local TICKS = 12000
  for _ = 1, TICKS do
    h:step()
    for i, n in ipairs(h.turbine_names) do
      local t = h.plant.turbines[n]
      local rpm = t:rotor_speed()
      if rpm > peak then peak = rpm end
      if rpm > rt2_turbine.OVERSPEED_RPM then overspeed = overspeed + 1 end
      if math.abs(rpm - rt2_turbine.FULL_TARGET_RPM) <= rt2_orchestrator.LEARN_TOLERANCE_RPM then
        in_band_ticks[i] = in_band_ticks[i] + 1
      end
      if t.energy_generated_last_tick > 0 then energy_ticks[i] = energy_ticks[i] + 1 end
      energy_sum[i] = energy_sum[i] + t.energy_generated_last_tick
      if t.inductor_engaged ~= coil_last[i] then
        coil_toggles[i] = coil_toggles[i] + 1
        coil_last[i] = t.inductor_engaged
      end
    end
  end

  assert_true(overspeed == 0, string.format(
    'ungleiche Flotte: Ueberdrehzahl in %d Takten, Spitze %.0f RPM -- %s',
    overspeed, peak, h:describe()))

  -- Die zu stark bebremste Turbine (Ludicrite auf derselben Blattzahl):
  -- ihre Spule bremst staerker, als der Dampf schieben kann. Sie fuehrt den
  -- Durchfluss also am Anschlag -- und muss das Zielband trotzdem ERREICHEN,
  -- sonst kann das Einlernen sie nie zaehlen (es verlangt
  -- |rpm-900| <= LEARN_TOLERANCE_RPM).
  --
  -- Genau das war kaputt: mit der Spulenverriegelung aus v798 und einer
  -- Notfreigabe erst unter 50 % der Zieldrehzahl blieb sie dauerhaft bei
  -- rund 790 RPM haengen -- Spule drin, Flow 2000, nie im Band. Auf dem
  -- Schirm sah das aus wie "Spule aktiv unter 900, Flow dauerhaft am
  -- Anschlag, Einlernen findet keine Turbinen im Zielbereich".
  local strong_coil = h.plant.turbines[h.turbine_names[5]]
  assert_true(strong_coil.max_intake_rate == strong_coil.variant.max_permitted_flow, string.format(
    'eine Turbine unter dem Zielband muss den Durchfluss am Anschlag fahren, hat aber %d',
    strong_coil.max_intake_rate))
  assert_true(in_band_ticks[5] > TICKS * 0.05, string.format(
    'die zu stark bebremste Turbine muss das Zielband erreichen, war aber nur in %.1f %% der Takte darin'
      .. ' -- sonst zaehlt das Einlernen sie nie', in_band_ticks[5] / TICKS * 100))
  -- Sie liefert dabei weiter Energie. Nicht in JEDEM Takt -- waehrend einer
  -- Freigabe ist die Spule draussen und der Ausstoss null. Bezahlt wird das
  -- durch mehr Zeit nahe dem Wirkungsgradmaximum bei 900 RPM: im
  -- Einzelturbinen-Vergleich stieg der Mittelwert dadurch von 39882 auf
  -- 40847 FE/t, obwohl weniger Takte ueberhaupt liefern.
  assert_true(energy_ticks[5] > TICKS * 0.7, string.format(
    'die zu stark bebremste Turbine muss weiter Energie liefern (nur %.1f %% der Takte)',
    energy_ticks[5] / TICKS * 100))
  assert_true(energy_sum[5] / TICKS > 20000, string.format(
    'und im Mittel nennenswert viel: %.0f FE/t', energy_sum[5] / TICKS))
  -- Kein Flattern im Takt: die Notfreigabe darf ein langsames Pendeln
  -- ergeben, nicht den Grenzzyklus, gegen den v798 gebaut wurde.
  assert_true(coil_toggles[5] < TICKS / 100, string.format(
    'die Spule darf nicht im Takt flattern (%d Umschaltungen in %d Takten)',
    coil_toggles[5], TICKS))

  -- Die ausgelegten Turbinen bleiben davon unberuehrt: dort steht der
  -- Durchfluss nicht am Anschlag bzw. die Drehzahl nicht unter der
  -- Freigabeschwelle, also kann die Notfreigabe gar nicht greifen.
  for _, i in ipairs({ 1, 2, 3, 4 }) do
    assert_true(coil_toggles[i] <= 3, string.format(
      'Turbine %d: %d Spulen-Umschaltungen -- eine ausgelegte Turbine kuppelt einmal und bleibt',
      i, coil_toggles[i]))
  end

  -- Die Turbine ohne Spule bekommt keinen Dampf -- sie ist nicht bremsbar.
  local no_coil = h.plant.turbines[h.turbine_names[6]]
  assert_true(no_coil.max_intake_rate == 0, string.format(
    'eine Turbine ohne Spule darf keinen Dampf bekommen, hat aber %d mB/t',
    no_coil.max_intake_rate))
end

-- ── 5. Eine Turbine mit zeitweise unlesbaren Messwerten ──────────────────
--
-- In CC:Tweaked ganz normal: ein Chunk laedt nach, der Multiblock meldet
-- kurz eine verkuerzte Methodenliste, ein Aufruf wirft. Vier Stoerungsarten
-- nacheinander auf EINER Turbine, dazwischen jeweils Erholung. Verlangt
-- wird: kein Absturz, keine Ueberdrehzahl irgendwo in der Flotte, die
-- gestoerte Turbine faellt in den sicheren Zustand (Dampf aus, Spule
-- bleibt drin -- sie ist die Bremse) und erholt sich danach wieder.
do
  local h = harness.new({ turbine_count = 4, reactor_headroom = 4.0, steam_capacity = 20000 })
  local victim = h.turbine_names[2]
  local mode = 'ok'
  local base_call = _G.peripheral.call
  _G.peripheral.call = function(name, method, ...)
    if name == victim then
      if mode == 'no_rpm' and method == 'getRotorSpeed' then return nil end
      if mode == 'no_flow' and method == 'getFluidFlowRateMax' then return nil end
      if mode == 'throws' and (method == 'getRotorSpeed' or method == 'setFluidFlowRateMax') then
        error('peripheral detached', 0)
      end
      -- Der Schreibvorgang wird quittiert, aber nicht ausgefuehrt.
      if mode == 'coil_write_lost' and method == 'setInductorEngaged' then return true end
    end
    return base_call(name, method, ...)
  end

  local peak, overspeed, crashes = 0, 0, 0
  local function phase(m, seconds)
    mode = m
    for _ = 1, seconds * 10 do
      local ok = pcall(function() h:step() end)
      if not ok then crashes = crashes + 1 end
      for _, n in ipairs(h.turbine_names) do
        local rpm = h.plant.turbines[n]:rotor_speed()
        if rpm > peak then peak = rpm end
        if rpm > rt2_turbine.OVERSPEED_RPM then overspeed = overspeed + 1 end
      end
    end
  end

  phase('ok', 400)
  for _, fault in ipairs({ 'no_rpm', 'no_flow', 'throws', 'coil_write_lost' }) do
    phase(fault, 60)
    local v = h.plant.turbines[victim]
    assert_true(v.inductor_engaged, string.format(
      'Stoerung "%s": die Spule muss eingehaengt bleiben -- sie ist die Bremse', fault))
    if fault == 'no_rpm' then
      assert_true(v.max_intake_rate == 0, string.format(
        'Stoerung "%s": ohne Drehzahlmessung muss der Dampf abgestellt werden, steht aber auf %d',
        fault, v.max_intake_rate))
    end
    phase('ok', 150)
  end
  _G.peripheral.call = base_call

  assert_true(crashes == 0, string.format('%d Reglertakte sind an der gestoerten Turbine gescheitert', crashes))
  assert_true(overspeed == 0, string.format(
    'Ueberdrehzahl in %d Takten waehrend der Stoerungen, Spitze %.0f RPM -- %s',
    overspeed, peak, h:describe()))
  local v = h.plant.turbines[victim]
  assert_true(v.energy_generated_last_tick > 0,
    'die gestoerte Turbine muss sich nach dem letzten Aussetzer wieder erholen -- ' .. h:describe())
end

print('rt2_er_physics_scenarios_test.lua: ok')
