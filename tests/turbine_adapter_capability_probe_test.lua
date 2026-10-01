package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Ursache des Livetest-Ausfalls auf node-101, eine Ebene tiefer als der
-- Regler.
--
-- CC:Tweaked wirft bei einer unbekannten Methode einen Lua-Fehler
-- ("No such method <name>" in PeripheralAPI's PeripheralWrapper.call()).
-- adapters/turbine.lua's inspect() holte die Methodenliste bei JEDEM
-- Aufruf neu -- 25 Turbinen, mehrmals pro Sekunde -- und fiel bei einem
-- fehlgeschlagenen Versuch auf "getRotorRPM" zurueck. Die gibt es bei
-- Extreme Reactors 2 (MC 1.21.1) nicht: der Ausweichweg war ein
-- garantierter Fehlschlag. Ergebnis war ein unlesbarer Messwert -- und
-- der hat weiter oben die Regelung lahmgelegt (siehe
-- rt2_unreadable_turbine_write_test.lua).
--
-- adapters/reactor.lua hat es immer richtig gemacht: dort ist JEDER
-- Aufruf durch has_method() gedeckt. Diese Datei haelt dasselbe fuer die
-- Turbine fest.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Eine Turbine mit der echten Methodenliste von Extreme Reactors 2.
local ER2_METHODS = {
  'getActive', 'setActive', 'getRotorSpeed',
  'getFluidFlowRateMax', 'setFluidFlowRateMax',
  'getEnergyProducedLastTick', 'getInductorEngaged', 'setInductorEngaged',
}

local calls, methods_calls, get_methods_fails
local function install_peripheral(methods, values)
  calls, methods_calls = {}, 0
  _G.peripheral = {
    isPresent = function(n) return n == 'T1' end,
    getType = function() return 'BigReactors-Turbine' end,
    getMethods = function()
      methods_calls = methods_calls + 1
      if get_methods_fails then error('peripheral detached', 0) end
      return methods
    end,
    call = function(_, method)
      calls[#calls + 1] = method
      local v = values[method]
      -- Genau das Verhalten aus CC:Tweakeds Quelltext.
      if v == nil then error('No such method ' .. method, 0) end
      return v
    end,
    wrap = function() return nil end,
  }
end

local function fresh_adapter()
  package.loaded['adapters.turbine'] = nil
  return require('adapters.turbine')
end

local VALUES = {
  getActive = true, getRotorSpeed = 1256, getFluidFlowRateMax = 2000,
  getEnergyProducedLastTick = 4200, getInductorEngaged = false,
}

-- ══ 1. Normalfall: liest, was es gibt ════════════════════════════════════

do
  install_peripheral(ER2_METHODS, VALUES)
  local turbine = fresh_adapter()
  local info = turbine.inspect('T1', 'RT')
  assert_eq(info.rpm, 1256, 'die Drehzahl muss gelesen werden')
  assert_eq(info.flow, 2000)
  assert_eq(info.active, true)
  assert_eq(info.coil_engaged, false)
  for _, m in ipairs(calls) do
    assert_true(m ~= 'getRotorRPM', 'getRotorRPM darf nie aufgerufen werden, wenn getRotorSpeed existiert')
  end
end

-- ══ 2. Die Methodenliste wird EINMAL geholt, nicht je Aufruf ════════════
--
-- Das ist die Haelfte der Ursache: je oefter gefragt wird, desto oefter
-- kann es danebengehen. 25 Turbinen mal zwei Aufrufen je Sekunde sind
-- 50 Gelegenheiten pro Sekunde, dass genau das passiert.

do
  install_peripheral(ER2_METHODS, VALUES)
  local turbine = fresh_adapter()
  for _ = 1, 20 do turbine.inspect('T1', 'RT') end
  assert_eq(methods_calls, 1, 'die Faehigkeiten werden gemerkt, nicht bei jedem inspect() neu geholt')
end

-- ══ 3. Der Kern: ein fehlgeschlagener Versuch raet NICHTS ═══════════════

do
  install_peripheral(ER2_METHODS, VALUES)
  get_methods_fails = true
  local turbine = fresh_adapter()
  local info = turbine.inspect('T1', 'RT')
  get_methods_fails = false

  for _, m in ipairs(calls) do
    assert_true(m ~= 'getRotorRPM', string.format(
      'ohne bekannte Faehigkeiten darf KEIN geratener Methodenname aufgerufen werden'
        .. ' -- getRotorRPM gibt es bei Extreme Reactors 2 nicht, der Aufruf wirft'
        .. ' "No such method" und macht den Messwert unlesbar (aufgerufen wurde: %s)',
      table.concat(calls, ', ')))
  end
  assert_eq(info.rpm, 'n/a', 'die Drehzahl gilt als unbekannt')
  assert_eq(info.flow, 'n/a', 'und der Durchfluss ebenfalls')
  assert_eq(info.features.rpm, false, 'und das steht auch so in den Faehigkeiten')
end

-- ══ 4. Unbekannt darf nicht in der Regelung als Zahl ankommen ═══════════

do
  local rt2_adapter = require('nodes.rt.rt2_adapter')
  install_peripheral(ER2_METHODS, VALUES)
  get_methods_fails = true
  local turbine = fresh_adapter()
  local reading = rt2_adapter.read_turbine('T1', turbine.inspect('T1', 'RT'))
  get_methods_fails = false
  assert_eq(reading.rpm, nil, 'unbekannte Drehzahl kommt als nil in der Regelung an')
  assert_eq(reading.current_flow, nil, 'und ein unbekannter Durchfluss ebenfalls')
end

-- ══ 5. Ein einmaliger Aussetzer wirft die Faehigkeiten nicht weg ════════

do
  install_peripheral(ER2_METHODS, VALUES)
  local turbine = fresh_adapter()
  assert_eq(turbine.inspect('T1', 'RT').rpm, 1256)
  get_methods_fails = true          -- ab jetzt schlaegt getMethods fehl
  local info = turbine.inspect('T1', 'RT')
  get_methods_fails = false
  assert_eq(info.rpm, 1256,
    'ein spaeterer Aussetzer der Faehigkeitsabfrage darf die bereits bekannte'
      .. ' Liste nicht entwerten -- gefragt wird ohnehin nicht mehr')
end

-- ══ 6. Verschwindet die Turbine, gilt die Liste nicht weiter ════════════

do
  install_peripheral(ER2_METHODS, VALUES)
  local turbine = fresh_adapter()
  turbine.inspect('T1', 'RT')
  local present = true
  _G.peripheral.isPresent = function() return present end
  present = false
  local info, err = turbine.inspect('T1', 'RT')
  assert_eq(info, nil, 'eine abwesende Turbine liefert keinen Messwert')
  assert_eq(err, 'peripheral missing')

  -- ...und kommt an diesem Namen etwas anderes zurueck, wird neu gefragt.
  present = true
  methods_calls = 0
  turbine.inspect('T1', 'RT')
  assert_eq(methods_calls, 1, 'nach dem Verschwinden muessen die Faehigkeiten neu ermittelt werden')
end

-- ══ 7. Eine Turbine mit den ALTEN Namen laeuft trotzdem ═════════════════
--
-- getRotorRPM ist nicht verboten -- es darf nur nicht geraten werden.
--
-- Fuer den DURCHFLUSS gilt das NICHT, und das ist der Unterschied:
-- getFluidFlowRate ist kein alter Name derselben Groesse, sondern eine
-- ANDERE Groesse (getFluidConsumedLastTick -- der Verbrauch des letzten
-- Ticks, nicht der gestellte Sollwert). Als Rueckmesswert gelesen liegt er
-- im Beharrungszustand systematisch unter dem Sollwert, der Regler liest
-- daraus dauerhaft "zu wenig gestellt" und dreht bis zum Anschlag auf.
-- Darum bleibt der Wert hier UNBEKANNT -- der Regler nimmt dann seinen
-- eigenen zuletzt gestellten Wert und regelt korrekt weiter (siehe
-- adapters/turbine.lua's FLOW_METHODS).

do
  install_peripheral({ 'getActive', 'getRotorRPM', 'getFluidFlowRate' },
    { getActive = true, getRotorRPM = 880, getFluidFlowRate = 1400 })
  local turbine = fresh_adapter()
  local info = turbine.inspect('T1', 'RT')
  assert_eq(info.rpm, 880, 'ist nur getRotorRPM da, wird eben die genommen')
  assert_eq(info.flow, 'n/a',
    'der Verbrauch ist KEIN Ersatz fuer den Sollwert -- lieber unbekannt als falsch')
  assert_eq(info.features.flow, false,
    'und die Faehigkeit wird auch nicht behauptet')

  -- Gegenprobe: mit der richtigen Methode kommt der Wert an.
  install_peripheral({ 'getActive', 'getRotorSpeed', 'getFluidFlowRateMax',
                       'getFluidFlowRateMaxMax' },
    { getActive = true, getRotorSpeed = 900, getFluidFlowRateMax = 1400,
      getFluidFlowRateMaxMax = 2000 })
  local ok_turbine = fresh_adapter()
  local ok_info = ok_turbine.inspect('T1', 'RT')
  assert_eq(ok_info.flow, 1400, 'getFluidFlowRateMax ist der Sollwert und wird gelesen')
  assert_eq(ok_info.flow_limit, 2000,
    'und die Bauartgrenze kommt aus getFluidFlowRateMaxMax')
end

-- ══ Eine noch nicht fertige Turbine darf sich nicht festfahren ═════════
--
-- Aus dem Betrieb, doppelter Aufbau mit 25 frisch dazugebauten Turbinen:
-- Durchfluss ueberall 0, Kupplungen eingehaengt obwohl die Drehzahl weit
-- unter dem Ziel lag, und das Einlernen kam nie vom Fleck.
--
-- Das sah nach einem kaputten Regler aus, war aber ein Lesefehler. Ein
-- Multiblock, der noch nicht fertig zusammengesetzt ist (oder dessen
-- Chunk gerade laedt), meldet eine verkuerzte Methodenliste OHNE
-- getRotorSpeed. Dieses Ergebnis wurde dauerhaft gemerkt -- und der
-- Cache wird sonst nur verworfen, wenn die Peripherie ganz verschwindet.
-- Eine fertig gebaute Turbine verschwindet aber nicht mehr.
--
-- Ohne Drehzahl faellt die Turbinenregelung auf ihre Schutzentscheidung
-- zurueck (Durchfluss 0), die Spule bleibt stehen wo sie ist, und keine
-- Turbine ist je "am Ziel" -- das Einlernen wartet ewig.

do
  local turbine = require('adapters.turbine')
  turbine.forget_capabilities()

  local stage = 'unfertig'
  local probes = 0
  _G.peripheral = {
    isPresent = function() return true end,
    getType = function() return 'BigReactors-Turbine' end,
    getMethods = function()
      probes = probes + 1
      if stage == 'unfertig' then
        -- Multiblock im Bau: kein getRotorSpeed dabei.
        return { 'getConnected', 'getActive' }
      end
      return { 'getConnected', 'getActive', 'getRotorSpeed', 'getFluidFlowRateMax', 'getEnergyProducedLastTick' }
    end,
    call = function(_, method)
      if method == 'getRotorSpeed' then return 880 end
      if method == 'getFluidFlowRateMax' then return 1200 end
      if method == 'getActive' then return true end
      return nil
    end,
  }

  local first = turbine.inspect('T-neu', 'RT')
  assert_true(first == nil or tonumber(first.rpm) == nil,
    'solange der Multiblock nicht fertig ist, ist die Drehzahl unbekannt -- und das ist richtig')
  local probes_after_first = probes

  -- Die Turbine wird fertiggestellt.
  stage = 'fertig'
  local second = turbine.inspect('T-neu', 'RT')
  assert_true(probes > probes_after_first,
    'ein negatives Ergebnis darf NICHT dauerhaft gemerkt werden -- sonst bleibt die'
      .. ' Drehzahl fuer immer unbekannt, obwohl sie laengst lesbar waere')
  assert_eq(tonumber(second and second.rpm), 880,
    'sobald die Methode da ist, muss die Drehzahl gelesen werden')

  -- Ein POSITIVES Ergebnis wird weiterhin gemerkt: sonst kostete jede
  -- Turbine in jedem Takt ein getMethods().
  local probes_before = probes
  turbine.inspect('T-neu', 'RT')
  assert_eq(probes, probes_before,
    'eine erkannte Turbine wird nicht bei jedem Takt neu abgefragt')
end

-- ══ Auch das SCHREIBEN muss gedeckt sein, nicht nur das Lesen ═════════
--
-- Aus dem Betrieb: "der Flow-Regler funktioniert im doppelten Aufbau
-- nicht, im einzelnen schon" -- bei lesbarer Drehzahl, im Einlernen
-- (MASTER also ausgeschlossen) und nicht voller Matrix.
--
-- Der Lesepfad vertrug seit v739 zwei Namensvarianten
-- (getFluidFlowRateMax / getFluidFlowRate), der Schreibpfad rief dagegen
-- einen fest verdrahteten Namen, UNGEPRUEFT. Kennt die Turbine ihn
-- nicht, scheitert jeder Schreibversuch -- und der Fehler ging ueber
-- log_once() in den Log-Collector, nie auf den Bildschirm. Von aussen
-- sieht das aus wie "der Regler tut nichts": Drehzahl lesbar, Regler
-- rechnet richtig, am Geraet kommt nichts an.

do
  local turbine = require('adapters.turbine')
  turbine.forget_capabilities()

  local written = {}
  _G.peripheral = {
    isPresent = function() return true end,
    getType = function() return 'BigReactors-Turbine' end,
    -- Diese Turbine kennt NUR die zweite Namensvariante.
    getMethods = function()
      return { 'getActive', 'setActive', 'getRotorSpeed',
               'getFluidFlowRate', 'setFluidFlowRate', 'setInductorEngaged' }
    end,
    call = function(_, method, value)
      written[#written + 1] = { method = method, value = value }
      if method == 'getRotorSpeed' then return 450 end
      if method == 'getFluidFlowRate' then return 300 end
      return true
    end,
  }

  local ok, err = turbine.set_flow('T-variante', 1200, 'RT')
  assert_true(ok and not err, 'der Durchfluss muss gestellt werden: ' .. tostring(err))
  local used
  for _, w in ipairs(written) do
    if w.method == 'setFluidFlowRate' then used = w end
  end
  assert_true(used ~= nil,
    'die vorhandene Namensvariante muss benutzt werden, nicht eine fest verdrahtete')
  assert_eq(used.value, 1200)
end

-- Kennt sie GAR keine Stellmethode, wird das am Rechner selbst gesagt --
-- nicht nur im Log-Collector, wo es niemand sieht.

do
  local turbine = require('adapters.turbine')
  turbine.forget_capabilities()

  _G.peripheral = {
    isPresent = function() return true end,
    getType = function() return 'BigReactors-Turbine' end,
    getMethods = function() return { 'getActive', 'getRotorSpeed', 'getFluidFlowRate' } end,
    call = function() return nil end,
  }

  local printed = {}
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  local ok, err = turbine.set_flow('T-stumm', 1200, 'RT')
  _G.print = real_print

  assert_true(not ok, 'ohne Stellmethode kann nichts gestellt werden')
  assert_true(tostring(err):find('no method', 1, true) ~= nil, tostring(err))
  local said = table.concat(printed, ' | ')
  assert_true(said:find('laesst sich nicht stellen', 1, true) ~= nil,
    'und der Betreiber muss es am Rechner sehen: ' .. said)
end

-- ══ Der Ausstoss: Ausweichweg und lautes Melden ═════════════════════════
--
-- Betriebsmeldung 2026-09-29: "kein Wert genommen" -- das Einlernen kam nie
-- zu einem Ergebnis. Ursache eine Ebene tiefer: der Ausstoss war der
-- EINZIGE Messwert ohne Kandidatenliste. Ein fest verdrahtetes
-- getEnergyProducedLastTick, und kannte die Turbine das nicht, kam still
-- eine 0 heraus.
--
-- Teuer ist das, weil rt2_orchestrator.lua's measure() eine Turbine nur
-- dann als "im Zielband" zaehlt, wenn sie energy > 0 meldet. Ohne lesbaren
-- Ausstoss erreicht also NIE eine Turbine das Band, das Einlernen wartet
-- endlos -- und die Anzeige sagt dazu nur "0 von 50 im Zielband", als laege
-- es an der Drehzahl.

-- 1. Kennt die Turbine nur getEnergyStats, wird daraus gelesen.
do
  local methods = {
    'getActive', 'getRotorSpeed', 'getFluidFlowRateMax',
    'getInductorEngaged', 'getEnergyStats',
  }
  install_peripheral(methods, {
    getActive = true, getRotorSpeed = 900, getFluidFlowRateMax = 1500,
    getInductorEngaged = true,
    getEnergyStats = { energyProducedLastTick = 3300, energyStored = 10 },
  })
  local turbine = fresh_adapter()
  local info = turbine.inspect('T1', 'RT')
  assert_eq(info.energy, 3300,
    'ohne getEnergyProducedLastTick muss getEnergyStats einspringen')
  assert_eq(info.features.energy, true, 'und der Wert gilt als lesbar')
end

-- 2. Die direkte Methode hat weiterhin Vorrang.
do
  install_peripheral(ER2_METHODS, VALUES)
  local turbine = fresh_adapter()
  local info = turbine.inspect('T1', 'RT')
  assert_eq(info.energy, 4200, 'getEnergyProducedLastTick bleibt der erste Weg')
  for _, m in ipairs(calls) do
    assert_true(m ~= 'getEnergyStats',
      'getEnergyStats darf nicht zusaetzlich gerufen werden, wenn der direkte Weg existiert')
  end
end

-- 3. Kennt sie keinen von beiden: der Wert bleibt UNBEKANNT (nicht 0), und
--    der Betreiber erfaehrt es am Rechner -- sonst wartet das Einlernen
--    endlos, ohne dass irgendwo steht, warum.
do
  local methods = { 'getActive', 'getRotorSpeed', 'getFluidFlowRateMax', 'getInductorEngaged' }
  install_peripheral(methods, {
    getActive = true, getRotorSpeed = 900, getFluidFlowRateMax = 1500,
    getInductorEngaged = true,
  })
  local turbine = fresh_adapter()
  local printed = {}
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  local info = turbine.inspect('T1', 'RT')
  _G.print = real_print

  assert_true(info.energy == nil,
    'ein unlesbarer Ausstoss bleibt nil -- eine erfundene 0 hiesse "liefert nichts"')
  assert_eq(info.features.energy, false, 'und er gilt als nicht lesbar')
  local said = table.concat(printed, ' | ')
  assert_true(said:find('EINLERNEN', 1, true) ~= nil,
    'der Hinweis muss sagen, was daran haengt: ' .. said)
end

print('turbine_adapter_capability_probe_test.lua: ok')
