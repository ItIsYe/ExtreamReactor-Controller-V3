package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Warnungen "einmal je Stoerung" statt "einmal je Laufzeit"
-- (core/once_log.lua, Selbstheilung Stufe 1).
--
-- Bis v816 meldeten die Adapter einen gescheiterten Peripherieaufruf ueber
-- warned[key] = true: einmal, dann nie wieder bis zum Neustart. Erholte
-- sich das Geraet und fiel spaeter erneut aus, blieb die zweite Stoerung
-- stumm -- im Log stand nur die erste, Stunden alt.
--
--   1. once_log: melden, schweigen solange gestoert, nach Erholung wieder
--      melden -- aber hoechstens einmal je Minute (Flattern)
--   2. adapters/turbine.lua: Ausfall -> Meldung; Erholung; erneuter Ausfall
--      nach mehr als einer Minute -> erneute Meldung (vorher: nichts)
--   3. adapters/reactor.lua: dasselbe
--   4. adapters/energy_storage.lua: getMethods scheitert, klappt, scheitert
--      wieder -> zwei Meldungen
--   5. eine dauerhaft fehlende Methode meldet sich NICHT jede Minute neu

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local now = 1000000
local real_epoch = os.epoch
os.epoch = function() return now end

-- ══ 1. once_log ═══════════════════════════════════════════════════════════
do
  local once_log = require('core.once_log')
  local reg = once_log.new()
  assert_eq(reg.report('t1', 'getRotorSpeed'), true, 'erste Stoerung wird gemeldet')
  assert_eq(reg.report('t1', 'getRotorSpeed'), false, 'solange sie andauert, nicht erneut')
  assert_eq(reg.report('t2', 'getRotorSpeed'), true, 'eine andere Peripherie ist eine eigene Stoerung')
  reg.recover('t1', 'getRotorSpeed')
  now = now + 10 * 1000
  assert_eq(reg.report('t1', 'getRotorSpeed'), false, 'nach 10 s schon wieder kaputt: Flattern, nicht melden')
  reg.recover('t1', 'getRotorSpeed')
  now = now + 61 * 1000
  assert_eq(reg.report('t1', 'getRotorSpeed'), true, 'nach Erholung und mehr als einer Minute: neue Stoerung, melden')
  reg.recover_name('t1')
  assert_eq(reg.is_active('t1', 'getRotorSpeed'), false, 'recover_name raeumt alles dieser Peripherie')
  -- Uhr zurueckgesprungen: der alte Zeitstempel liegt in der Zukunft und
  -- gilt als alt -- gemeldet wird.
  now = now - 3600 * 1000
  assert_eq(reg.report('t1', 'getRotorSpeed'), true, 'Uhr-Ruecksprung blockiert keine Meldung')
  now = now + 3600 * 1000
end

-- Gemeinsame Bauteile fuer die Adapter: utils.log abgreifen, Peripherie
-- nachbilden.
local utils = require('core.utils')
local logged = {}
local real_log = utils.log
utils.log = function(prefix, message, level) logged[#logged + 1] = tostring(message) end
local function count(needle)
  local n = 0
  for _, line in ipairs(logged) do if line:find(needle, 1, true) then n = n + 1 end end
  return n
end

local failing = {}
local real_peripheral = rawget(_G, 'peripheral')
local METHODS = {
  turbine_0 = { 'getRotorSpeed', 'getFluidFlowRateMax', 'getEnergyProducedLastTick', 'getActive',
    'getInductorEngaged', 'setFluidFlowRateMax', 'setInductorEngaged', 'setActive' },
  reactor_0 = { 'getActive', 'getFuelTemperature', 'getEnergyProducedLastTick' },
  storage_0 = { 'getEnergy', 'getMaxEnergy' },
}
local methods_fail = {}
_G.peripheral = {
  isPresent = function(name) return METHODS[name] ~= nil end,
  getType = function(name) return name:match('^(%a+)') end,
  getMethods = function(name)
    if methods_fail[name] then error('peripheral busy') end
    return METHODS[name]
  end,
  call = function(name, method)
    if failing[name .. '.' .. method] then error('No such peripheral') end
    if method == 'getActive' or method == 'getInductorEngaged' then return true end
    return 100
  end,
}

-- ══ 2. Turbinen-Adapter ═══════════════════════════════════════════════════
do
  package.loaded['adapters.turbine'] = nil
  local turbine = require('adapters.turbine')
  failing['turbine_0.getRotorSpeed'] = true
  turbine.inspect('turbine_0', 'RT')
  turbine.inspect('turbine_0', 'RT')
  assert_eq(count('Turbine call failed for turbine_0.getRotorSpeed'), 1, 'erster Ausfall: eine Meldung')
  failing['turbine_0.getRotorSpeed'] = nil
  turbine.inspect('turbine_0', 'RT')          -- erholt
  now = now + 2 * 60 * 1000
  failing['turbine_0.getRotorSpeed'] = true
  turbine.inspect('turbine_0', 'RT')          -- faellt erneut aus
  assert_eq(count('Turbine call failed for turbine_0.getRotorSpeed'), 2,
    'der ZWEITE Ausfall nach einer Erholung muss wieder gemeldet werden')
  failing['turbine_0.getRotorSpeed'] = nil

  -- Schreiben: abgelehnt, klappt, abgelehnt
  failing['turbine_0.setFluidFlowRateMax'] = true
  turbine.set_flow('turbine_0', 0, 'RT')
  failing['turbine_0.setFluidFlowRateMax'] = nil
  turbine.set_flow('turbine_0', 0, 'RT')
  now = now + 2 * 60 * 1000
  failing['turbine_0.setFluidFlowRateMax'] = true
  turbine.set_flow('turbine_0', 0, 'RT')
  assert_eq(count('Turbine flow failed for turbine_0'), 2, 'auch beim Stellen: zweite Stoerung gemeldet')
  failing['turbine_0.setFluidFlowRateMax'] = nil
end

-- ══ 3. Reaktor-Adapter ════════════════════════════════════════════════════
do
  package.loaded['adapters.reactor'] = nil
  local reactor = require('adapters.reactor')
  failing['reactor_0.getFuelTemperature'] = true
  reactor.inspect('reactor_0', 'RT')
  reactor.inspect('reactor_0', 'RT')
  assert_eq(count('Reactor call failed for reactor_0.getFuelTemperature'), 1, 'erster Ausfall: eine Meldung')
  failing['reactor_0.getFuelTemperature'] = nil
  reactor.inspect('reactor_0', 'RT')
  now = now + 2 * 60 * 1000
  failing['reactor_0.getFuelTemperature'] = true
  reactor.inspect('reactor_0', 'RT')
  assert_eq(count('Reactor call failed for reactor_0.getFuelTemperature'), 2,
    'der zweite Ausfall nach einer Erholung muss wieder gemeldet werden')
  failing['reactor_0.getFuelTemperature'] = nil
end

-- ══ 4. Energiespeicher: getMethods ════════════════════════════════════════
do
  package.loaded['adapters.energy_storage'] = nil
  local storage = require('adapters.energy_storage')
  methods_fail.storage_0 = true
  storage.detect('storage_0', 'ENERGY')
  storage.detect('storage_0', 'ENERGY')
  methods_fail.storage_0 = nil
  storage.detect('storage_0', 'ENERGY')
  now = now + 2 * 60 * 1000
  methods_fail.storage_0 = true
  storage.detect('storage_0', 'ENERGY')
  assert_eq(count('Energy storage methods failed for storage_0'), 2,
    'getMethods: erste und zweite Stoerung gemeldet, die Wiederholung dazwischen nicht')
  methods_fail.storage_0 = nil
end

-- ══ 5. Dauerhaft fehlende Methode: kein Minutentakt ═══════════════════════
do
  package.loaded['adapters.turbine'] = nil
  local turbine = require('adapters.turbine')
  METHODS.turbine_1 = { 'getRotorSpeed', 'getFluidFlowRateMax', 'getEnergyProducedLastTick' }  -- kein setActive
  local before = count('kennt keine der bekannten active-Methoden')
  for _ = 1, 5 do
    turbine.set_active('turbine_1', false, 'RT')
    now = now + 2 * 60 * 1000
  end
  assert_eq(count('kennt keine der bekannten active-Methoden') - before, 1,
    'eine Methode, die es nicht gibt, ist EINE Stoerung -- nicht eine je Minute')
end

utils.log = real_log
_G.peripheral = real_peripheral
os.epoch = real_epoch
print('ok once_log_rearm_test')
