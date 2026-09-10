package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['adapters.logistical_sorter'] = nil

local calls = {}
local methods_by_name = {
  sorter_0 = { 'setDefaultColor', 'getDefaultColor', 'getAutoMode' },
  chest_0  = { 'list', 'size' }, -- not a sorter: must not be detected
}
local default_color = 'WHITE'

_G.peripheral = {
  isPresent = function(name) return methods_by_name[name] ~= nil end,
  getMethods = function(name) return methods_by_name[name] end,
  getType = function(name) return name == 'sorter_0' and 'logisticalSorter' or 'minecraft:chest' end,
  call = function(name, method, ...)
    calls[#calls + 1] = { name = name, method = method, ... }
    if method == 'setDefaultColor' then
      default_color = ...
      return
    end
    if method == 'getDefaultColor' then
      return default_color
    end
    error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method))
  end,
}

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local adapter = require('adapters.logistical_sorter')

-- COLORS matches Mekanism's real EnumColor (18 entries, no duplicates).
assert_eq(#adapter.COLORS, 18, 'expected all 18 Mekanism EnumColor values')
local seen = {}
for _, c in ipairs(adapter.COLORS) do
  assert_eq(seen[c], nil, 'duplicate color in COLORS: ' .. tostring(c))
  seen[c] = true
end

assert_eq(adapter.is_valid_color('RED'), true, 'RED must be a valid color')
assert_eq(adapter.is_valid_color('red'), true, 'lowercase must also validate (case-insensitive)')
assert_eq(adapter.is_valid_color('NOT_A_COLOR'), false, 'unknown color must be invalid')
assert_eq(adapter.is_valid_color(nil), false, 'nil must be invalid')
assert_eq(adapter.is_valid_color(42), false, 'non-string must be invalid')

-- A peripheral without setDefaultColor/getDefaultColor is not a sorter.
assert_eq(adapter.detect('chest_0', 'TEST'), nil, 'a plain chest must not be detected as a sorter')

local sorter = adapter.detect('sorter_0', 'TEST')
assert_eq(sorter ~= nil, true, 'sorter_0 must be detected')
assert_eq(sorter.name, 'sorter_0')
assert_eq(sorter.isValid(), true)

local ok, err = sorter.setDefaultColor('aqua')
assert_eq(ok, true, 'setDefaultColor should succeed: ' .. tostring(err))
assert_eq(calls[#calls].method, 'setDefaultColor')
assert_eq(calls[#calls][1], 'AQUA', 'color must be normalized to uppercase before the peripheral call')

local color = sorter.getDefaultColor()
assert_eq(color, 'AQUA', 'getDefaultColor must reflect the last set color')

local bad_ok, bad_err = sorter.setDefaultColor('turquoise')
assert_eq(bad_ok, false, 'an unknown color must be rejected before any peripheral call')
assert_eq(tostring(bad_err):find('invalid_color', 1, true) ~= nil, true)

print('logistical_sorter_adapter_test.lua: ok')
