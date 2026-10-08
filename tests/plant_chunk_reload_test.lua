package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- RT nach Chunk-Entladen: erholt sich die Node von selbst?
--
-- Betreibermeldung (2026-10): RT-Knoten erholten sich nicht, wenn Chunks
-- nicht geladen waren, MASTER und FUEL ebenso -- erst ein Neustart des
-- RT-Knotens half. "Es waren noch lebende Werte, aber nur RPM."
--
-- Die Uebergabe vom 2026-10-04 fuehrte das auf den Faehigkeiten-Cache in
-- nodes/rt/turbine_control.lua zurueck: get_device_caps() schreibt ihn
-- einmal und prueft nie nach. Das stimmt -- aber dieser Cache liegt nicht im
-- Regelpfad. rt2_engine.tick() liest und schreibt ueber adapters/turbine.lua
-- und adapters/reactor.lua, die Statusmeldung an MASTER ebenso
-- (status_snapshot.lua), und beide Adapter heilen von selbst: eine
-- unvollstaendige Methodenliste wird nicht gemerkt, eine verschwundene
-- Peripherie verwirft ihren Eintrag.
--
-- Fuenf Lagen, jede mit echt gebooteter RT- und MASTER-Node am Funknetz:
--
--   A  eine Turbine verschwindet und kommt mit verkuerzter Methodenliste
--      zurueck (Multiblock im Zusammenbau: Drehzahl ja, Durchfluss nein)
--   B  die ganze Anlage verschwindet und kommt zurueck
--   C  wie B, aber zuerst mit verkuerzten Methodenlisten -- das ist genau
--      das Bild "nur RPM" aus der Meldung
--   D  die Anlage bleibt angemeldet, aber jeder Aufruf wirft
--   E  der Ausfall dauert laenger als die Messausfall-Schonfrist: SAFE,
--      und danach zurueck
--
-- In allen fuenf Lagen erholt sich die Node OHNE Neustart. Die Ursache des
-- Feldbefunds liegt damit ausserhalb dessen, was hier modelliert ist. Der
-- Test ist das Gelaender dafuer: laeuft Regelung oder Status kuenftig ueber
-- einen einmal geschriebenen Zustand, faellt es hier auf und nicht in der
-- Anlage.
--
-- NICHT modelliert, ausdruecklich:
--   * ob und wie lange Extreme Reactors 2 im Spiel wirklich verkuerzte
--     Methodenlisten meldet -- das ist eine Annahme, keine Messung
--   * Peripherie-Ereignisse (peripheral/peripheral_detach): die Discovery
--     laeuft hier nur auf ihrem Takt
--   * das Entladen des RT-Computers selbst, geteilte Kabelnetze, den
--     lokalen Monitor
--
-- BEKANNT, ABER HIER NICHT GEPRUEFT: nach einer verkuerzten Phase bleiben
-- turbine_control.lua's Faehigkeiten-Cache UND das wrap-Handle in
-- ctx.peripherals.turbines veraltet. Bis v813 hing daran die Bestaetigung
-- des Update-Quiesce (nach 60 s erzwang installer/auto_update.lua das
-- Update); seit v814 laeuft der Quiesce namensbasiert ueber die Adapter --
-- nachgewiesen in tests/rt_update_quiesce_after_chunk_reload_test.lua.
-- Uebrig ist der Lese-Rueckfall des lokalen Schirms.

local boot = require('support.cc_node_boot')
local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local REACTOR = 'BigReactors-Reactor_1'
local TURBINES = { 'BigReactors-Turbine_1', 'BigReactors-Turbine_2', 'BigReactors-Turbine_3' }
local PLANT = { REACTOR, TURBINES[1], TURBINES[2], TURBINES[3] }

-- Laenger als ein langsamer Discovery-Lauf. Nach drei unveraenderten Laeufen
-- sucht die RT-Discovery nur noch alle 60 s (nodes/rt/main.lua's
-- should_discover). Eine kuerzere Phase sieht sie unter Umstaenden gar nicht
-- -- die verkuerzte Liste wuerde dann nie eingebunden, und A und C prueften
-- nichts.
local OUTAGE_ROUNDS = 700        -- 70 s bei 100 ms je Runde
local RECOVERY_ROUNDS = 1500     -- 150 s: Discovery, Neu-Vermessen, Einlernen
local DISTURBANCE_ROUNDS = 300   -- 30 s: Zeit zum Ausregeln einer Stoerung

-- Ein Multiblock im Zusammenbau, wie die Uebergabe ihn beschreibt: die
-- Turbine kennt ihre Drehzahl, aber weder Durchfluss noch Ausstoss; der
-- Reaktor nur seinen Aktiv-Zustand.
local SHORT_TURBINE = { getActive = true, setActive = true, getRotorSpeed = true,
  getInductorEngaged = true, setInductorEngaged = true }
local SHORT_REACTOR = { getActive = true, setActive = true }

local function subset(methods, keep)
  local out = {}
  for name, fn in pairs(methods) do
    if keep[name] then out[name] = fn end
  end
  return out
end

-- Nach "Turbine" unterscheiden, nicht nach "Reactor": "BigReactors-Turbine"
-- enthaelt "Reactor" -- genau daran ist der erste Entwurf dieses Tests
-- gescheitert und hat Turbinen als Reaktoren wieder angemeldet.
local function is_turbine(name)
  return name:find('Turbine', 1, true) ~= nil
end

local function setup(rt_config)
  -- Jede Lage bekommt eigene Modulgraphen, wie zwei frische Computer.
  boot.reset_module_cache()
  local rt = plant.new_rt({ turbines = 3, node_id = 'node-101', config = rt_config })
  local master = plant.new_master({ node_id = 'master-1' })
  plant.boot_all({
    { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
    { name = 'MASTER', env = master, main = 'master/main.lua' },
  })
  local net = bus_lib.new()
  net:attach('RT', rt)
  net:attach('MASTER', master)

  -- Schreibzaehler je Turbine. peripheral.call() schlaegt die Methode zur
  -- Laufzeit nach; der Zaehler sitzt in genau dem Methodentisch, den die
  -- Node nach einem Wieder-Anmelden zurueckbekommt.
  local site = { rt = rt, net = net, flow_writes = {}, full = {} }
  for index, name in ipairs(TURBINES) do
    local stub = rt.plant.turbines[index]
    local real_set = stub.methods.setFluidFlowRateMax
    site.flow_writes[index] = 0
    stub.methods.setFluidFlowRateMax = function(v)
      site.flow_writes[index] = site.flow_writes[index] + 1
      return real_set(v)
    end
    site.full[name] = stub.methods
  end
  site.full[REACTOR] = rt.plant.reactors[1].methods

  net:run(300)
  return site
end

local function status(site)
  local message = site.net:last_message_from('RT', 'STATUS')
  assert_true(message and message.payload, 'die RT-Node meldet keinen Status')
  return message.payload
end

local function unplug(site, names)
  for _, name in ipairs(names) do site.rt:remove_peripheral(name) end
end

local function plug(site, names, shortened)
  for _, name in ipairs(names) do
    local methods = site.full[name]
    local ptype = is_turbine(name) and 'BigReactors-Turbine' or 'BigReactors-Reactor'
    if shortened then
      methods = subset(methods, is_turbine(name) and SHORT_TURBINE or SHORT_REACTOR)
    end
    site.rt:add_peripheral(name, ptype, methods)
  end
end

-- Erholt heisst: der Status ist vollstaendig, das Einlernen ist durch, und
-- die Regelung WIRKT -- eine Stoerung von aussen wird ausgeregelt. "Der
-- Status sieht gut aus" allein waere zu wenig: im Feld liefen die Anzeigen
-- weiter, waehrend nichts mehr geregelt wurde.
local function assert_recovered(site, label)
  site.net:run(RECOVERY_ROUNDS)

  local payload = status(site)
  assert_eq(payload.mode, 'MASTER', label .. ': Modus nach der Erholung')
  assert_eq(payload.capacity_ready, true, label .. ': das Einlernen muss abgeschlossen sein')
  assert_eq(payload.capacity_total_turbines, 3, label .. ': Turbinenzahl')
  assert_eq(#(payload.turbines or {}), 3, label .. ': Turbinen im Status')
  for _, t in ipairs(payload.turbines) do
    assert_true(type(t.rpm) == 'number' and type(t.flow_rate) == 'number'
        and type(t.energy) == 'number',
      ('%s: Turbine %s meldet nicht alle Messwerte (rpm=%s flow_rate=%s energy=%s)')
        :format(label, tostring(t.id), tostring(t.rpm), tostring(t.flow_rate), tostring(t.energy)))
  end
  local reactor = (payload.reactors or {})[1]
  assert_true(reactor and type(reactor.rods_level) == 'number'
      and type(reactor.fuel_amount) == 'number',
    label .. ': die Reaktorwerte fehlen im Status')

  -- Stoerung von aussen: Durchfluss auf 0. Die Regelung muss wieder stellen
  -- und die Turbinen ins Zielband (900 +/- 15 RPM) zurueckholen.
  local writes_before = {}
  local rods_before = site.rt.plant.reactors[1].writes
  for index = 1, #TURBINES do
    writes_before[index] = site.flow_writes[index]
    site.rt.plant.turbines[index].flow = 0
  end
  site.net:run(DISTURBANCE_ROUNDS)
  for index, name in ipairs(TURBINES) do
    local stub = site.rt.plant.turbines[index]
    assert_true(site.flow_writes[index] > writes_before[index],
      label .. ': ' .. name .. ' wird nicht mehr gestellt')
    assert_true(stub.rotor_speed() >= 885,
      ('%s: %s kommt nicht ins Zielband zurueck (rpm=%s)')
        :format(label, name, tostring(stub.rotor_speed())))
  end
  assert_true(site.rt.plant.reactors[1].writes > rods_before,
    label .. ': die Staebe werden nicht mehr gestellt')
end

-- ══ A. Eine Turbine weg, zurueck mit verkuerzter Methodenliste ═══════════
do
  local site = setup()
  local before = status(site)
  assert_eq(#(before.turbines or {}), 3, 'A: Vorbedingung drei Turbinen')

  unplug(site, { TURBINES[2] })
  site.net:run(OUTAGE_ROUNDS)
  local during = status(site)
  assert_eq(#(during.turbines or {}), 2, 'A: die entfernte Turbine muss aus dem Status verschwinden')

  -- Ihre Kennung ist die, die jetzt fehlt. Die Registry vergibt sie je
  -- Peripherienamen und behaelt sie 30 min (MISSING_RETENTION_MS) -- beim
  -- Wieder-Anmelden kommt also dieselbe zurueck.
  local present, gone = {}, nil
  for _, t in ipairs(during.turbines) do present[t.id] = true end
  for _, t in ipairs(before.turbines) do
    if not present[t.id] then gone = t.id end
  end
  assert_true(gone ~= nil, 'A: Kennung der entfernten Turbine nicht gefunden')

  plug(site, { TURBINES[2] }, true)
  site.net:run(OUTAGE_ROUNDS)
  local entry
  for _, t in ipairs(status(site).turbines or {}) do
    if t.id == gone then entry = t end
  end
  assert_true(entry ~= nil,
    'A: die Turbine muss mit verkuerzter Liste eingebunden sein -- sonst prueft A nichts')
  assert_true(type(entry.rpm) == 'number', 'A: die Drehzahl muss lesbar sein')
  assert_true(type(entry.flow_rate) ~= 'number',
    'A: ein Durchfluss ohne Durchfluss-Methode darf nicht erfunden werden')

  plug(site, { TURBINES[2] }, false)
  assert_recovered(site, 'A')
end

-- ══ B. Die ganze Anlage weg und zurueck ═══════════════════════════════════
do
  local site = setup()
  unplug(site, PLANT)
  site.net:run(OUTAGE_ROUNDS)
  local during = status(site)
  assert_eq(#(during.turbines or {}), 0, 'B: ohne Anlage darf keine Turbine gemeldet werden')
  assert_eq(#(during.reactors or {}), 0, 'B: ohne Anlage darf kein Reaktor gemeldet werden')

  plug(site, PLANT, false)
  assert_recovered(site, 'B')
end

-- ══ C. Die ganze Anlage weg, zurueck zuerst mit verkuerzten Listen ═══════
do
  local site = setup()
  unplug(site, PLANT)
  site.net:run(OUTAGE_ROUNDS)
  plug(site, PLANT, true)
  site.net:run(OUTAGE_ROUNDS)

  -- Das Bild aus der Meldung: Drehzahlen ja, sonst nichts. Unbekanntes
  -- bleibt unbekannt -- erfunden wird kein Wert.
  local short = status(site)
  assert_eq(#(short.turbines or {}), 3, 'C: die Turbinen muessen eingebunden sein')
  for _, t in ipairs(short.turbines) do
    assert_true(type(t.rpm) == 'number', 'C: Drehzahl von ' .. tostring(t.id) .. ' muss lesbar sein')
    assert_true(type(t.flow_rate) ~= 'number' and t.energy == nil,
      'C: Durchfluss/Ausstoss von ' .. tostring(t.id) .. ' duerfen nicht erfunden werden')
  end
  local reactor = (short.reactors or {})[1]
  assert_true(reactor ~= nil and reactor.rods_level == nil,
    'C: der Reaktor muss eingebunden sein, seine Staebe aber unbekannt')

  plug(site, PLANT, false)
  assert_recovered(site, 'C')
end

-- ══ D. Angemeldet, aber jeder Aufruf wirft ═══════════════════════════════
do
  local site = setup()
  local saved = {}
  for name, methods in pairs(site.full) do
    saved[name] = {}
    for key, fn in pairs(methods) do
      saved[name][key] = fn
      methods[key] = function() error('Multiblock not assembled', 0) end
    end
  end
  site.net:run(OUTAGE_ROUNDS)
  local during = status(site)
  assert_eq(#(during.turbines or {}), 3, 'D: die Turbinen bleiben angemeldet')
  for _, t in ipairs(during.turbines) do
    assert_true(type(t.rpm) ~= 'number',
      'D: ein geworfener Aufruf darf keine Drehzahl liefern (' .. tostring(t.id) .. ')')
  end

  for name, methods in pairs(site.full) do
    for key, fn in pairs(saved[name]) do methods[key] = fn end
  end
  assert_recovered(site, 'D')
end

-- ══ E. Ausfall laenger als die Schonfrist: SAFE, dann zurueck ════════════
--
-- Die Schonfrist steht im Betrieb auf 30 min (rt2_safety.lua's
-- DEFAULT_MEASUREMENT_GRACE_SAMPLES). Hier 50 Takte, damit der Fall in
-- Testzeit eintritt -- die Mechanik ist dieselbe.
do
  local site = setup('return { safety = { measurement_grace_samples = 50 } }\n')
  unplug(site, PLANT)
  site.net:run(OUTAGE_ROUNDS)
  assert_eq(status(site).mode, 'SAFE', 'E: nach der Schonfrist muss die Node auf SAFE gehen')
  assert_true(#site.rt:find_prints('TEMP_MEASUREMENT_LOST') > 0,
    'E: der Grund muss auf dem Rechner stehen')

  plug(site, PLANT, false)
  assert_recovered(site, 'E')
end

print('ok plant_chunk_reload_test')
