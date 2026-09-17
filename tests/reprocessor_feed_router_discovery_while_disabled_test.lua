package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage: the new REPROC Diagnostics "requirements" panel
-- (2026-09-17, main.lua's build_requirements()) shows ME-BRIDGE/SORTER
-- status from feed_router.lua's get_summary() (bridge_bound/sorter_bound).
-- Before this fix, tick() returned immediately whenever config.feed.
-- enabled was false, BEFORE ever calling refresh_peripherals() -- so a
-- freshly set up (or deliberately still-disabled) node always showed
-- ME-BRIDGE/SORTER as FEHLT, even with both physically present and
-- wired, simply because detection had never run. Peripheral discovery
-- must happen on its own schedule regardless of the enabled switch; only
-- the actual feed actions (feed_one/feed_chest) must stay gated by it.

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'me_bridge' end,
  getMethods = function(name)
    if name == 'sorter_0' then return { 'setDefaultColor', 'getDefaultColor' } end
    if name == 'me_bridge' then return { 'getItem', 'exportItemToPeripheral' } end
    return {}
  end,
  getType = function() return 'logisticalSorter' end,
  wrap = function(name) return { name = name } end,
}

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local feed_router_lib = require('nodes.reprocessor.feed_router')

local export_calls = 0
local feed = feed_router_lib.new({
  config = {
    buffers = { 'puffer_chest_0' },
    feed = {
      enabled = false, -- deliberately still disabled
      me_bridge = 'me_bridge', sorter = 'sorter_0',
      waste_item = 'x', feed_amount = 2, discovery_interval = 60,
      targets = { { label = 'Reprocessor A', color = 'RED' } },
    },
  },
  log = function() end, warn_once = function() end,
})

feed:tick()

local summary = feed:get_summary()
assert_true(summary.bridge_bound, 'ME-Bridge must be detected even while feeding is disabled')
assert_eq(summary.bridge_name, 'me_bridge')
assert_true(summary.sorter_bound, 'Sorter must be detected even while feeding is disabled')
assert_eq(summary.sorter_name, 'sorter_0')
assert_eq(summary.enabled, false, 'get_summary() must still report feeding as disabled')

-- Discovery running must not itself trigger a feed while disabled.
assert_eq(export_calls, 0)

print('reprocessor_feed_router_discovery_while_disabled_test.lua: ok')
