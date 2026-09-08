package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test for adapters/monitor.lua's direct-side preference.
--
-- A monitor placed directly against a computer's face is reachable under
-- its side name (e.g. "top") AND, if a Wired Modem also links it into the
-- network, under a separate generated name (e.g. "monitor_48") -- the
-- SAME physical screen under two different peripheral names.
-- peripheral.getNames() lists both, so monitor.find() previously treated
-- them as two independent candidates and picked whichever sorted first
-- alphabetically ("monitor_48" < "top"). Real user logs (2026-09-03)
-- showed FUEL bound to "monitor_48" this way while every monitor_touch
-- event -- landing exactly on the rendered footer buttons -- reported
-- "top", so core/ui_router.lua's monitor_touch_matches() rejected every
-- single tap as coming from a "foreign" monitor: page navigation looked
-- completely dead even though the touches were perfectly on target.

local function make_mon(w, h)
  return {
    getTextScale = function() return 1 end,
    setTextScale = function() end,
    getSize = function() return w, h end,
  }
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local top_mon = make_mon(82, 33)
local network_mon = make_mon(82, 33)

_G.peripheral = {
  isPresent = function(name) return name == 'top' or name == 'monitor_48' end,
  getType = function(name) return (name == 'top' or name == 'monitor_48') and 'monitor' or nil end,
  getNames = function() return { 'monitor_48', 'top' } end,
}

package.loaded['core.utils'] = {
  safe_wrap = function(name)
    if name == 'top' then return top_mon end
    if name == 'monitor_48' then return network_mon end
    return nil, 'unknown'
  end,
  log = function() end,
}
package.loaded['adapters.monitor'] = nil
local adapter = require('adapters.monitor')

-- strategy="first": alphabetically "monitor_48" would win without the fix.
local first = assert(adapter.find(nil, 'first', nil, 'TEST'))
assert_eq(first.name, 'top', 'a directly-attached monitor must win over its own network alias')
assert_eq(first.mon, top_mon)

-- strategy="largest" (both candidates report the identical size here, so
-- area-based selection alone can't disambiguate) must also prefer the
-- direct side -- touch-identity correctness matters regardless of the
-- configured selection strategy.
package.loaded['adapters.monitor'] = nil
local adapter2 = require('adapters.monitor')
local largest = assert(adapter2.find(nil, 'largest', nil, 'TEST'))
assert_eq(largest.name, 'top', 'direct-side preference must apply under the largest strategy too')

print('monitor_adapter_direct_side_preference_test.lua: ok')
