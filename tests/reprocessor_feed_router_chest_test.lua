package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for feed_router.lua's optional collector chest
-- (config.feed.chest): a second, independently-toggled export destination
-- for raw Cyanit, on its own random-interval schedule, completely separate
-- from the Reprocessor-target rotation (see color_router_ui.lua's KISTE
-- toggle). UNLIKE the reprocessor targets, the chest does NOT go through
-- the Sorter/a color -- it is exported directly via the ME bridge to
-- chest.target (a peripheral reached over the wired-modem network), so no
-- sorter binding is required at all. Proves:
--   1. a disabled chest never feeds, even while targets keep rotating;
--   2. an enabled chest feeds directly to its target peripheral on its own
--      schedule even with ZERO reprocessor targets AND no sorter bound --
--      i.e. genuinely independent of the sorter-color routing, not just
--      another rotating target;
--   3. an enabled chest with no target peripheral assigned is skipped
--      with a warning, not silently fed or crashed;
--   4. get_summary() reports the chest's own counters separately from the
--      reprocessor rotation's.

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil

local now_ms = 1000000
local sorter_calls = {}
local export_calls = {}

_G.os = _G.os or {}
os.epoch = function() return now_ms end

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'me_bridge' end,
  getMethods = function(name)
    if name == 'sorter_0' then return { 'setDefaultColor', 'getDefaultColor' } end
    return {}
  end,
  getType = function() return 'logisticalSorter' end,
  call = function(name, method, color)
    if name == 'sorter_0' and method == 'setDefaultColor' then
      sorter_calls[#sorter_calls + 1] = color
      return
    end
    error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method))
  end,
}

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local logistical_sorter = require('adapters.logistical_sorter')
local feed_router_lib = require('nodes.reprocessor.feed_router')

local function make_bridge()
  return {
    getItem = function(_query) return { amount = 1000 } end,
    exportItemToPeripheral = function(_query, inlet)
      export_calls[#export_calls + 1] = { inlet = inlet }
      return 2
    end,
  }
end

-- 1. Chest disabled: targets rotate normally via the sorter, chest never
--    fires and never appears in the sorter color calls.
local warnings = {}
local feed = feed_router_lib.new({
  config = { feed = {
    enabled = true, waste_item = 'x', feed_amount = 2,
    interval_min_s = 10, interval_max_s = 10, discovery_interval = 9999,
    export_inlet = 'sorter_inlet_0',
    targets = { { label = 'Reprocessor A', color = 'RED' } },
    chest = { enabled = false, target = nil },
  } },
  log = function() end,
  warn_once = function(key, msg) warnings[key] = msg end,
})
feed._state.bridge = make_bridge()
feed._state.sorter = logistical_sorter.detect('sorter_0', 'TEST')
feed._state.last_refresh = now_ms

feed:tick() -- arms both timers
now_ms = now_ms + 11000
feed:tick() -- target A feeds
assert_eq(#export_calls, 1, 'target A should feed even with chest disabled')
assert_eq(export_calls[1].inlet, 'sorter_inlet_0')

now_ms = now_ms + 11000
feed:tick()
assert_eq(#export_calls, 2, 'target A should feed again on rotation wrap')
local summary_disabled = feed:get_summary()
assert_eq(summary_disabled.chest_enabled, false)
assert_eq(summary_disabled.chest_total_feeds, 0, 'a disabled chest must never count a feed')

-- 2. Chest enabled with ZERO reprocessor targets AND no sorter bound at
--    all: the chest must still feed directly to its own target peripheral
--    on its own schedule -- proves it does not depend on the sorter/color
--    routing in any way, just the ME bridge.
local warnings2 = {}
local export_calls2 = {}

local feed2 = feed_router_lib.new({
  config = { feed = {
    enabled = true, waste_item = 'x', feed_amount = 2,
    interval_min_s = 10, interval_max_s = 10, discovery_interval = 9999,
    export_inlet = 'sorter_inlet_0',
    targets = {},
    chest = { enabled = true, target = 'chest_0' },
  } },
  log = function() end,
  warn_once = function(key, msg) warnings2[key] = msg end,
})
feed2._state.bridge = {
  getItem = function(_query) return { amount = 1000 } end,
  exportItemToPeripheral = function(_query, inlet)
    export_calls2[#export_calls2 + 1] = { inlet = inlet }
    return 2
  end,
}
feed2._state.sorter = nil -- deliberately unbound: chest export must not need it
feed2._state.last_refresh = now_ms

feed2:tick() -- first tick only arms the chest timer, no feed yet
assert_eq(#export_calls2, 0, 'first tick must only arm the chest interval, not feed immediately')

now_ms = now_ms + 11000
feed2:tick()
assert_eq(#export_calls2, 1, 'an enabled chest must feed directly to its target with zero reprocessor targets and no sorter bound')
assert_eq(export_calls2[1].inlet, 'chest_0', 'the chest export must go straight to chest.target, not the shared sorter export_inlet')

local summary_enabled = feed2:get_summary()
assert_eq(summary_enabled.chest_enabled, true)
assert_eq(summary_enabled.chest_total_feeds, 1)
assert_true(summary_enabled.chest_last_feed_ts ~= nil)
assert_eq(summary_enabled.total_feeds, 0, 'the reprocessor rotation counter must stay unaffected by chest feeds')

-- 3. Chest enabled but no target peripheral assigned: skipped with a
--    dedicated warning, no export attempt, no crash.
local warnings3 = {}
local export_calls3 = {}
local feed3 = feed_router_lib.new({
  config = { feed = {
    enabled = true, waste_item = 'x', feed_amount = 2,
    interval_min_s = 10, interval_max_s = 10, discovery_interval = 9999,
    export_inlet = 'sorter_inlet_0',
    targets = {},
    chest = { enabled = true, target = nil },
  } },
  log = function() end,
  warn_once = function(key, msg) warnings3[key] = msg end,
})
feed3._state.bridge = {
  getItem = function(_query) return { amount = 1000 } end,
  exportItemToPeripheral = function(_query, inlet)
    export_calls3[#export_calls3 + 1] = { inlet = inlet }
    return 2
  end,
}
feed3._state.sorter = nil
feed3._state.last_refresh = now_ms

feed3:tick()
now_ms = now_ms + 11000
local ok = pcall(function() feed3:tick() end)
assert_true(ok, 'a targetless chest must not crash the tick')
assert_eq(#export_calls3, 0, 'a targetless chest must never export')
assert_true(warnings3['chest_no_target'] ~= nil, 'a targetless enabled chest must produce a dedicated warning')

print('reprocessor_feed_router_chest_test.lua: ok')
