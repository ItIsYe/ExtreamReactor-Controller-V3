-- energy_storage.detect() setzte features.capacity immer hart auf true --
-- auch fuer das ER2-Passive-Reaktorport-Profil (getEnergyStored +
-- getEnergyProducedLastTick), das laut resolve_profile()'s eigenem
-- Kommentar KEINE Kapazitaets-Methode hat (profile.capacity == nil).
-- getCapacity() liefert dort immer nil, aber features.capacity behauptete
-- faelschlich das Gegenteil -- Registry/Diagnostics zeigten ein Feature,
-- das der Port gar nicht unterstuetzt.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local peripherals = {}
_G.peripheral = {
  isPresent = function(name) return peripherals[name] ~= nil end,
  getMethods = function(name) return peripherals[name] and peripherals[name].methods or {} end,
  getType = function(name) return peripherals[name] and peripherals[name].type or nil end,
  call = function(name, method, ...) return peripherals[name].calls[method](...) end,
}

local energy_storage = require('adapters.energy_storage')

-- ER2 passive reactor port: nur getEnergyStored + getEnergyProducedLastTick,
-- keine getEnergyCapacity/getMaxEnergy/etc.
peripherals['er2_port_0'] = {
  type = 'er2_reactor_port',
  methods = { 'getEnergyStored', 'getEnergyProducedLastTick' },
  calls = {
    getEnergyStored = function() return 1000 end,
    getEnergyProducedLastTick = function() return 50 end,
  },
}

local info = energy_storage.detect('er2_port_0', 'TEST')
if not info then error('expected energy_storage.detect to recognize the ER2 passive port profile') end
if info.features.capacity ~= false then
  error('expected features.capacity=false for the ER2 passive port profile (no capacity method exists), got ' ..
    tostring(info.features.capacity))
end
if info.getCapacity() ~= nil then
  error('expected getCapacity() to return nil for the ER2 passive port profile')
end

-- Gegenprobe: ein normales Mekanism-Matrix-Profil hat sehr wohl eine
-- Kapazitaets-Methode -- features.capacity muss dort weiterhin true sein.
peripherals['induction_matrix_0'] = {
  type = 'inductionPort',
  methods = { 'getEnergy', 'getEnergyCapacity', 'getLastInput', 'getLastOutput' },
  calls = {
    getEnergy = function() return 500 end,
    getEnergyCapacity = function() return 2000 end,
    getLastInput = function() return 10 end,
    getLastOutput = function() return 5 end,
  },
}
local info2 = energy_storage.detect('induction_matrix_0', 'TEST')
if not info2 or info2.features.capacity ~= true then
  error('expected features.capacity=true for a profile with a real capacity method')
end

print('energy_storage_er2_capacity_feature_test.lua: ok')
