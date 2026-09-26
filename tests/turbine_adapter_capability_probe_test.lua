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

do
  install_peripheral({ 'getActive', 'getRotorRPM', 'getFluidFlowRate' },
    { getActive = true, getRotorRPM = 880, getFluidFlowRate = 1400 })
  local turbine = fresh_adapter()
  local info = turbine.inspect('T1', 'RT')
  assert_eq(info.rpm, 880, 'ist nur getRotorRPM da, wird eben die genommen')
  assert_eq(info.flow, 1400, 'dasselbe fuer den Durchfluss')
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

print('turbine_adapter_capability_probe_test.lua: ok')
