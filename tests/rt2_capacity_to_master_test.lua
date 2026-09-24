package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Wozu das Einlernen ueberhaupt da ist: MASTER braucht eine Zahl, gegen
-- die er seinen Leistungsbedarf aufteilen kann. Diese Datei sichert die
-- KETTE ab -- gemessener Ausstoss -> Statusfelder -> MASTERs Aufteilung --
-- und nicht nur die einzelnen Glieder. Genau dazwischen lagen die Fehler:
-- die Kapazitaet war hochgerechnet statt gemessen, und die Statusfelder
-- hiessen anders als die, die MASTER liest.

local rt2_capacity = require('nodes.rt.rt2_capacity')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- ── 1. Die gemessene Zahl ist die, die der Knoten liefern KANN ───────────

do
  -- 25 Turbinen, aber der Reaktor traegt nur 6 davon auf Zieldrehzahl.
  -- Jede tragende Turbine liefert 1000 RF/t.
  local TOTAL, CARRIES, EACH = 25, 6, 1000
  local fleet = {}
  for i = 1, TOTAL do
    if i <= CARRIES then
      fleet[i] = { rpm = 900, energy = EACH, coil_engaged = true, current_flow = 1200 }
    else
      fleet[i] = { rpm = 780, energy = 0, coil_engaged = false, current_flow = rt2_turbine.MAX_FLOW }
    end
  end

  local state, now = rt2_capacity.new_state(), 1000
  for _ = 1, 60 do
    state = rt2_capacity.update(state, fleet, { now_ms = now })
    if state.ready then break end
    now = now + rt2_capacity.STEP_TIMEOUT_MS
  end

  assert_true(state.ready, 'der Knoten muss trotz begrenztem Dampf zu einem Ergebnis kommen')
  assert_eq(state.sustainable_turbines, CARRIES)

  local really_deliverable = CARRIES * EACH                  -- 6000 RF/t
  local extrapolated_old   = (CARRIES * EACH / CARRIES) * TOTAL -- 25000 RF/t (alte Formel)

  assert_eq(state.max_output, really_deliverable * (1 - rt2_capacity.SAFETY_MARGIN),
    'die Kapazitaet muss der gemessene Ausstoss sein')
  assert_true(state.max_output < really_deliverable,
    'mit Sicherheitsreserve darunter -- MASTER soll den Knoten nicht randvoll fahren')
  assert_true(state.max_output < extrapolated_old / 3,
    'und weit unter dem, was die alte Hochrechnung geliefert haette ('
      .. tostring(extrapolated_old) .. ' statt ' .. tostring(really_deliverable) .. ')')
end

-- ── 2. MASTERs Rechnung gegen eine falsche Kapazitaet ────────────────────

do
  -- So teilt MASTER auf (rt_sync.lua): uniform_pct = Bedarf / Kapazitaet.
  local function uniform_pct(global_target, capacity)
    return capacity > 0 and math.min(100, global_target / capacity * 100) or 0
  end
  -- Und so setzt der Knoten die Vorgabe in laufende Turbinen um.
  local function running(pct, total, max_active)
    local n = 0
    for slot = 1, total do
      if rt2_turbine.compute_target_rpm('MASTER', {
            turbine_count = total, slot_index = slot,
            power_percent = pct, max_active = max_active }) > 0 then
        n = n + 1
      end
    end
    return n
  end

  local honest   = 6000 * (1 - rt2_capacity.SAFETY_MARGIN)  -- gemessen
  local inflated = 25000                                    -- alte Hochrechnung

  -- WICHTIG, und anders als man zuerst vermutet: bei NIEDRIGEM Bedarf
  -- heben sich die beiden alten Fehler gegenseitig auf. Die Kapazitaet war
  -- um 25/6 zu hoch, aber die Prozentvorgabe wurde auch auf alle 25
  -- Turbinen statt auf die 6 tragbaren verteilt. Ergebnis: dieselbe Anzahl
  -- laufender Turbinen und dieselbe Leistung. Das ist der Grund, warum der
  -- Fehler so lange unentdeckt bleiben konnte -- und der Grund, diesen
  -- Fall hier festzuhalten, damit ihn niemand fuer den Schaden haelt.
  do
    local low = 6000
    assert_eq(running(uniform_pct(low, inflated), 25, 25), 6,
      'alt: 24 % von 25 Turbinen = 6 laufende')
    assert_eq(running(uniform_pct(low, honest), 25, 6), 6,
      'neu: 100 % von 6 tragbaren = ebenfalls 6 laufende')
  end

  -- Der Schaden zeigt sich bei HOHEM Bedarf. Dann verspricht die
  -- ueberhoehte Kapazitaet etwas, das die Anlage nicht hat, und der Knoten
  -- faehrt weit mehr Turbinen an, als der Dampf traegt -- alle ziehen
  -- gleichzeitig, keine erreicht die Zieldrehzahl, der Ausstoss bricht
  -- zusammen. MASTER rechnet dabei weiter mit der versprochenen Leistung
  -- und sieht keinen Grund, einen anderen Knoten zuzuschalten.
  do
    local high = 20000
    local old_running = running(uniform_pct(high, inflated), 25, 25)
    assert_true(old_running > 15,
      'alt: der Knoten verspricht sich und faehrt ' .. old_running .. ' Turbinen an')

    local new_pct = uniform_pct(high, honest)
    assert_eq(new_pct, 100, 'neu: der Knoten meldet ehrlich seine Grenze -- mehr als 100 % gibt es nicht')
    assert_eq(running(new_pct, 25, 6), 6,
      'und faehrt genau seine sechs tragbaren Turbinen, statt sich zu uebernehmen')
  end

  -- Und MASTER kann jetzt ueberhaupt erst erkennen, dass der Bedarf
  -- ungedeckt ist: gegen die gemessene Kapazitaet bleibt eine Luecke,
  -- gegen die hochgerechnete scheint alles gedeckt.
  assert_true(20000 > honest, 'gemessen: der Bedarf uebersteigt diesen Knoten sichtbar')
  assert_true(20000 < inflated, 'hochgerechnet: der Bedarf schien gedeckt -- und war es nie')
end

-- ── 3. Die Deckelung gilt auch bei voller Vorgabe ────────────────────────

do
  -- Der eigentliche Grund, warum die Kapazitaet allein nicht reicht:
  -- MASTER rechnet in Leistung, der Knoten teilt in Turbinen-Anteilen auf.
  -- Ohne max_active hiesse "100 %" wieder "alle 25 gleichzeitig" -- also
  -- genau der Dampf-Ansturm, den die Anlage nicht vertraegt.
  local with_cap, without_cap = 0, 0
  for slot = 1, 25 do
    if rt2_turbine.compute_target_rpm('MASTER',
        { turbine_count = 25, slot_index = slot, power_percent = 100, max_active = 6 }) > 0 then
      with_cap = with_cap + 1
    end
    if rt2_turbine.compute_target_rpm('MASTER',
        { turbine_count = 25, slot_index = slot, power_percent = 100 }) > 0 then
      without_cap = without_cap + 1
    end
  end
  assert_eq(with_cap, 6, 'mit gemessener Grenze laufen hoechstens sechs Turbinen')
  assert_eq(without_cap, 25, 'ohne die Grenze wuerden alle 25 gleichzeitig anfahren')
end

print('rt2_capacity_to_master_test.lua: ok')
