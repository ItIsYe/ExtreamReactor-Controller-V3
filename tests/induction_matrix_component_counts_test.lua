package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['adapters.induction_matrix'] = nil
package.loaded['adapters.energy_storage'] = nil

local methods_by_name = {
  inductionPort_0 = {
    'getInstalledCells',
    'getInstalledProviders',
    'getEnergy',
    'getMaxEnergy',
  },
  inductionPort_1 = {
    'getInstalledCells',
    'getInstalledProviders',
    'getInstalledPorts',
    'getEnergy',
    'getMaxEnergy',
  },
  inductionPort_2 = {
    'getInstalledCells',
    'getInstalledProviders',
    'getInstalledPorts',
    'getEnergy',
    'getMaxEnergy',
  },
  inductionPort_3 = {
    getInstalledCells = true,
    getInstalledProviders = true,
    getInstalledPorts = true,
    getEnergy = true,
    getMaxEnergy = true,
  },
  inductionPort_4 = {
    getInstalledCells = function() end,
    getInstalledProviders = "callable",
    getInstalledPorts = {},
    getEnergy = true,
    getMaxEnergy = true,
  },
  inductionPort_5 = {
    'getInstalledCells',
    'getInstalledProviders',
    'getEnergy',
    'getMaxEnergy',
  },
}

_G.peripheral = {
  isPresent = function(name)
    return methods_by_name[name] ~= nil
  end,
  getMethods = function(name)
    return methods_by_name[name]
  end,
  getType = function()
    return 'inductionPort'
  end,
  call = function(name, method)
    if method == 'getEnergy' then
      return 1200
    end
    if method == 'getMaxEnergy' then
      return 5000
    end
    if name == 'inductionPort_0' and method == 'getInstalledCells' then
      return { 'cell_a', 'cell_b' }
    end
    if name == 'inductionPort_0' and method == 'getInstalledProviders' then
      return { provider_a = true, provider_b = true, provider_c = true }
    end
    if name == 'inductionPort_1' and method == 'getInstalledCells' then
      return '4'
    end
    if name == 'inductionPort_1' and method == 'getInstalledProviders' then
      return 6
    end
    if name == 'inductionPort_1' and method == 'getInstalledPorts' then
      return { 'p1', 'p2', 'p3' }
    end
    if name == 'inductionPort_2' and method == 'getInstalledCells' then
      return { 'cell_x', 'cell_y' }, 'ok'
    end
    if name == 'inductionPort_2' and method == 'getInstalledProviders' then
      return { count = '7' }, 'ok'
    end
    if name == 'inductionPort_2' and method == 'getInstalledPorts' then
      return nil, 'matrix warming up'
    end
    if name == 'inductionPort_3' and method == 'getInstalledCells' then
      return true, { items = { 'cell_alpha', 'cell_beta', 'cell_gamma' } }
    end
    if name == 'inductionPort_3' and method == 'getInstalledProviders' then
      return true, { result = { count = '8' } }
    end
    if name == 'inductionPort_3' and method == 'getInstalledPorts' then
      return true, { installed = { 'p1', 'p2', 'p3', 'p4' } }
    end
    if name == 'inductionPort_4' and method == 'getInstalledCells' then
      return nil, 'warming up', { 'cell_1', 'cell_2' }
    end
    if name == 'inductionPort_4' and method == 'getInstalledProviders' then
      return nil, 'warming up', { count = 9 }
    end
    if name == 'inductionPort_4' and method == 'getInstalledPorts' then
      return nil, 'warming up', { 'p1', 'p2' }
    end
    if name == 'inductionPort_5' and method == 'getInstalledCells' then
      return true
    end
    if name == 'inductionPort_5' and method == 'getInstalledProviders' then
      return false, 'matrix not assembled'
    end
    error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method))
  end
}

local adapter = require('adapters.induction_matrix')

local matrix0 = adapter.detect('inductionPort_0', 'TEST')
if not matrix0 then
  error('expected inductionPort_0 matrix adapter')
end

local cells0, cells0_err = matrix0.getCells()
if cells0 ~= 2 or cells0_err ~= nil then
  error('expected table cell list to be normalized to count=2')
end
local providers0, providers0_err = matrix0.getProviders()
if providers0 ~= 3 or providers0_err ~= nil then
  error('expected keyed provider table to be normalized to count=3')
end
local ports0, ports0_err = matrix0.getPorts()
if ports0 ~= nil or tostring(ports0_err) ~= 'missing_method' then
  error('expected missing installed ports method to surface as missing_method')
end
local snap0 = matrix0.getSnapshot()
if snap0.cells ~= 2 or snap0.providers ~= 3 or snap0.ports ~= 'n/a' then
  error('snapshot should expose normalized counts and n/a for unavailable ports')
end

local matrix1 = adapter.detect('inductionPort_1', 'TEST')
if not matrix1 then
  error('expected inductionPort_1 matrix adapter')
end
local cells1 = matrix1.getCells()
local providers1 = matrix1.getProviders()
local ports1 = matrix1.getPorts()
if cells1 ~= 4 or providers1 ~= 6 or ports1 ~= 3 then
  error('expected numeric/string/table component values to normalize to counts')
end

local matrix2 = adapter.detect('inductionPort_2', 'TEST')
if not matrix2 then
  error('expected inductionPort_2 matrix adapter')
end
local cells2, cells2_err = matrix2.getCells()
if cells2 ~= 2 or cells2_err ~= nil then
  error('expected multi-return success payload to normalize using first return value')
end
local providers2, providers2_err = matrix2.getProviders()
if providers2 ~= 7 or providers2_err ~= nil then
  error('expected table count field to normalize to numeric provider count')
end
local ports2, ports2_err = matrix2.getPorts()
if ports2 ~= nil or tostring(ports2_err) ~= 'nil_value:matrix warming up' then
  error('expected nil payload with detail to be treated as temporary nil_value')
end

local matrix3 = adapter.detect('inductionPort_3', 'TEST')
if not matrix3 then
  error('expected inductionPort_3 matrix adapter')
end
local cells3, cells3_err = matrix3.getCells()
if cells3 ~= 3 or cells3_err ~= nil then
  error('expected success+table payload for cells to normalize to count=3')
end
local providers3, providers3_err = matrix3.getProviders()
if providers3 ~= 8 or providers3_err ~= nil then
  error('expected nested count payload for providers to normalize to count=8')
end
local ports3, ports3_err = matrix3.getPorts()
if ports3 ~= 4 or ports3_err ~= nil then
  error('expected nested installed list for ports to normalize to count=4')
end

local matrix4 = adapter.detect('inductionPort_4', 'TEST')
if not matrix4 then
  error('expected inductionPort_4 matrix adapter')
end
local cells4, cells4_err = matrix4.getCells()
if cells4 ~= 2 or cells4_err ~= nil then
  error('expected trailing payload list to normalize to count=2')
end
local providers4, providers4_err = matrix4.getProviders()
if providers4 ~= 9 or providers4_err ~= nil then
  error('expected trailing payload count table to normalize to count=9')
end
local ports4, ports4_err = matrix4.getPorts()
if ports4 ~= 2 or ports4_err ~= nil then
  error('expected trailing payload list for ports to normalize to count=2')
end

local matrix5 = adapter.detect('inductionPort_5', 'TEST')
if not matrix5 then
  error('expected inductionPort_5 matrix adapter')
end
local cells5, cells5_err = matrix5.getCells()
if cells5 ~= nil or tostring(cells5_err) ~= 'nil_value:empty_payload' then
  error('expected bare success flag to report empty payload nil_value')
end
local providers5, providers5_err = matrix5.getProviders()
if providers5 ~= nil or tostring(providers5_err) ~= 'call_failed:matrix not assembled' then
  error('expected false+error tuple to map to call_failed with detail')
end

print('induction_matrix_component_counts_test.lua: ok')
