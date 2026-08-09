package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local calls = { wrap = 0, set_scale = 0 }
local current_scale = 0.5

local mon = {
  getTextScale = function() return current_scale end,
  setTextScale = function(value)
    calls.set_scale = calls.set_scale + 1
    current_scale = value
  end,
  getSize = function()
    if current_scale == 1 then return 29, 19 end
    return 57, 38
  end,
}

_G.peripheral = {
  isPresent = function(name) return name == 'monitor_0' end,
  getType = function(name) return name == 'monitor_0' and 'monitor' or nil end,
  getNames = function() return { 'monitor_0' } end,
}

package.loaded['core.utils'] = {
  safe_wrap = function(name)
    assert(name == 'monitor_0')
    calls.wrap = calls.wrap + 1
    return mon
  end,
  log = function() end,
}
package.loaded['adapters.monitor'] = nil

local adapter = require('adapters.monitor')

local first = assert(adapter.find(nil, 'first', 0.5, 'TEST'))
assert(first.name == 'monitor_0')
assert(first.mon == mon)
local wrap_after_first = calls.wrap
local scale_after_first = calls.set_scale

local second = assert(adapter.find(nil, 'first', 0.5, 'TEST'))
assert(second.name == 'monitor_0')
assert(second.mon == first.mon, 'same physical monitor must keep a stable wrapper')
assert(calls.wrap == wrap_after_first, 'periodic discovery must not wrap the same monitor again')
assert(calls.set_scale == scale_after_first, 'periodic discovery must not probe/modify monitor text scale again')

adapter.invalidate_name('monitor_0')
local third = assert(adapter.find(nil, 'first', 0.5, 'TEST'))
assert(third.mon == mon)
assert(calls.wrap == wrap_after_first + 1, 'explicit invalidation must allow a fresh wrap')
assert(calls.set_scale > scale_after_first, 'explicit invalidation must allow a fresh shape probe')

print('monitor_adapter_discovery_stability_test.lua: ok')
