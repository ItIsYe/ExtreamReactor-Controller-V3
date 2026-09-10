package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- End-to-end coverage for feed_router.lua's tick()-driven feed cycle after
-- the Sorter-color routing rewrite: rotation across targets, the sorter
-- color being set before each export, and a target with a missing/invalid
-- color being skipped (no export, no crash, rotation still advances).

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

local logistical_sorter = require('adapters.logistical_sorter')
local feed_router_lib = require('nodes.reprocessor.feed_router')

local warnings = {}
local feed = feed_router_lib.new({
  config = { feed = {
    enabled = true, waste_item = 'bigreactors:cyanite_ingot', feed_amount = 2,
    interval_min_s = 10, interval_max_s = 10, discovery_interval = 9999,
    export_inlet = 'sorter_inlet_0',
    targets = {
      { label = 'Reprocessor A', color = 'RED' },
      { label = 'Reprocessor B', color = nil },      -- invalid: must be skipped
      { label = 'Reprocessor C', color = 'AQUA' },
    },
  } },
  log = function() end,
  warn_once = function(key, msg) warnings[key] = msg end,
})

-- Bind peripherals directly (skip discovery -- exercised separately by
-- logistical_sorter_adapter_test.lua / the ME-bridge discovery tests).
-- me_bridge_compat.lua calls bridge.getItem/exportItemToPeripheral as plain
-- function values (pcall(bridge.exportItemToPeripheral, filter, target) --
-- no colon-call, no implicit self), so these must NOT take a leading self.
feed._state.bridge = {
  getItem = function(_query) return { amount = 1000 } end,
  exportItemToPeripheral = function(_query, inlet)
    export_calls[#export_calls + 1] = { inlet = inlet }
    return 2
  end,
}
feed._state.sorter = logistical_sorter.detect('sorter_0', 'TEST')
feed._state.last_refresh = now_ms -- prevent tick() from re-running discovery

-- First tick after construction only arms the timer (see feed_router.lua's
-- M:tick() -- "beim ersten Tick sofort einen Timer setzen").
feed:tick()
assert_eq(#export_calls, 0, 'first tick must not feed yet, only arm the interval timer')

-- Advance past the (fixed 10s) interval and drive three feed cycles.
now_ms = now_ms + 11000
feed:tick() -- target 1: Reprocessor A (RED) -- must export
assert_eq(#export_calls, 1, 'target A should feed')
assert_eq(sorter_calls[#sorter_calls], 'RED', 'sorter must be set to RED before feeding A')
assert_eq(export_calls[1].inlet, 'sorter_inlet_0', 'export must go to the shared export_inlet')

now_ms = now_ms + 11000
feed:tick() -- target 2: Reprocessor B (no color) -- must be skipped
assert_eq(#export_calls, 1, 'target B has no color and must be skipped, not fed')
assert_eq(warnings['bad_target:2'] ~= nil, true, 'a warning must be recorded for the colorless target')

now_ms = now_ms + 11000
feed:tick() -- target 3: Reprocessor C (AQUA) -- must export
assert_eq(#export_calls, 2, 'target C should feed')
assert_eq(sorter_calls[#sorter_calls], 'AQUA', 'sorter must be set to AQUA before feeding C')

now_ms = now_ms + 11000
feed:tick() -- rotation wraps back to target 1
assert_eq(#export_calls, 3, 'rotation must wrap back to target A')
assert_eq(sorter_calls[#sorter_calls], 'RED')

local summary = feed:get_summary()
assert_eq(summary.total_feeds, 3, 'get_summary total_feeds must count only successful feeds')
assert_eq(summary.target_count, 3)
assert_eq(summary.sorter_bound, true)

print('reprocessor_feed_router_color_rotation_test.lua: ok')
