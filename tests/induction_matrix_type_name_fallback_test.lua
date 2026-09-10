-- Regression test: Mekanism's Induction Matrix PORT block (the block
-- actually wired to the network) only exposes getMode/setMode plus the
-- generic energy getters itself -- the cell/provider/port-count methods
-- is_matrix_method_set() checks for live on the multiblock structure and
-- may not be present on every port (e.g. an unformed matrix, or an older
-- Mekanism version). Such a port used to fall through matrix detection
-- entirely and get classified as plain energy storage, so ENERGY reported
-- "matrix missing" even with a real matrix attached. adapters/
-- induction_matrix.lua now also accepts a peripheral whose
-- peripheral.getType() contains "induction" as a matrix, even without the
-- cell/provider/port methods.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['adapters.induction_matrix'] = nil
package.loaded['adapters.energy_storage'] = nil

local methods_by_name = {
  -- Only port-level + generic energy methods -- no getInstalledCells/
  -- Providers/Ports at all. This is what a real Induction Matrix Port
  -- peripheral looks like per Mekanism's own computer_help docs.
  inductionPort_bare = { 'getMode', 'setMode', 'getEnergy', 'getMaxEnergy' },
  -- Unrelated peripheral with a generic energy profile but nothing
  -- matrix-like about its type -- must NOT be misdetected as a matrix.
  energy_cube_0 = { 'getEnergy', 'getMaxEnergy', 'getChargeItem' },
}

local type_by_name = {
  inductionPort_bare = 'inductionPort',
  energy_cube_0 = 'mekanism:energy_cube',
}

_G.peripheral = {
  isPresent = function(name) return methods_by_name[name] ~= nil end,
  getMethods = function(name) return methods_by_name[name] end,
  getType = function(name) return type_by_name[name] end,
  call = function(name, method)
    if method == 'getEnergy' then return 1200 end
    if method == 'getMaxEnergy' then return 5000 end
    error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method))
  end,
}

local adapter = require('adapters.induction_matrix')

local matrix = adapter.detect('inductionPort_bare', 'TEST')
if not matrix then
  error('expected inductionPort_bare to be detected as a matrix via its "induction" type name')
end
local cells, cells_err = matrix.getCells()
if cells ~= nil or tostring(cells_err) ~= 'missing_method' then
  error('expected missing cell/provider/port methods to surface as missing_method, not a detection failure')
end

local not_matrix = adapter.detect('energy_cube_0', 'TEST')
if not_matrix ~= nil then
  error('expected a non-induction peripheral with only generic energy methods to NOT be detected as a matrix')
end

print('induction_matrix_type_name_fallback_test.lua: ok')
