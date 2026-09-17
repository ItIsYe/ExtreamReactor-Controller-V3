package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for feed_router.lua's architecture: the ME-Bridge
-- exports into the SORTER-KISTE (config.feed.sorter_chest) instead of a
-- shared export_inlet -- Mekanism's own Sorter+Transporter mechanics take
-- over from the chest automatically. Without a configured Sorter-Kiste,
-- feed_one() must skip cleanly with a dedicated warning, not crash or
-- export to a nil/empty destination.

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'sorter_chest_0' end,
  getMethods = function(name)
    if name == 'sorter_0' then return { 'setDefaultColor', 'getDefaultColor' } end
    return {}
  end,
  getType = function() return 'logisticalSorter' end,
  call = function(name, method, ...)
    if name == 'sorter_0' and method == 'setDefaultColor' then return end
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

local export_calls = 0
local function make_feed(sorter_chest)
  local feed = feed_router_lib.new({
    config = {
      feed = {
        enabled = true, waste_item = 'x', feed_amount = 2,
        sorter_chest = sorter_chest,
        targets = { { label = 'Reprocessor A', color = 'RED' } },
      },
    },
    log = function() end, warn_once = function() end,
  })
  feed._state.bridge = {
    getItem = function() return { amount = 1000 } end,
    exportItemToPeripheral = function() export_calls = export_calls + 1; return 2 end,
  }
  feed._state.sorter = logistical_sorter.detect('sorter_0', 'TEST')
  return feed
end

-- 1) No Sorter-Kiste configured at all (nil) -- must skip with a warning,
--    no export, no crash.
do
  local warnings = {}
  local feed = make_feed(nil)
  feed.warn_once = function(key, msg) warnings[key] = msg end
  local ok = pcall(function()
    -- Drive feed_one() indirectly via the module's own tick-adjacent path:
    -- call the same rotation logic tick() would, bypassing the random-
    -- interval gate (matches the pattern used by the other feed_router
    -- tests for this module).
    feed._state.last_refresh = os.epoch('utc')
    feed._state.next_feed_ts = os.epoch('utc') - 1 -- force due
    feed:tick()
  end)
  assert_true(ok, 'a missing Sorter-Kiste must not crash the tick')
  assert_eq(export_calls, 0, 'no export must happen without a configured Sorter-Kiste')
  assert_true(warnings['no_sorter_chest'] ~= nil, 'expected a dedicated no_sorter_chest warning')
end

-- 2) Empty-string Sorter-Kiste -- same as nil, must skip cleanly.
do
  export_calls = 0
  local warnings = {}
  local feed = make_feed('')
  feed.warn_once = function(key, msg) warnings[key] = msg end
  feed._state.last_refresh = os.epoch('utc')
  feed._state.next_feed_ts = os.epoch('utc') - 1
  feed:tick()
  assert_eq(export_calls, 0, 'no export must happen with an empty Sorter-Kiste name')
  assert_true(warnings['no_sorter_chest'] ~= nil, 'expected a dedicated no_sorter_chest warning for an empty name too')
end

-- 3) A real Sorter-Kiste configured -- feed proceeds normally, exporting to it.
do
  export_calls = 0
  local feed = make_feed('sorter_chest_0')
  feed._state.last_refresh = os.epoch('utc')
  feed._state.next_feed_ts = os.epoch('utc') - 1
  feed:tick()
  assert_eq(export_calls, 1, 'a configured Sorter-Kiste must let the feed proceed')
end

-- 4) A Sorter-Kiste NAME is configured, but no such peripheral is actually
--    present (removed/renamed/typo) -- must skip cleanly with a DEDICATED
--    "not found" warning, not the generic feed_fail from a blind export
--    attempt.
do
  export_calls = 0
  local warnings = {}
  local feed = make_feed('typo_chest') -- not in the isPresent() allowlist above
  feed.warn_once = function(key, msg) warnings[key] = msg end
  feed._state.last_refresh = os.epoch('utc')
  feed._state.next_feed_ts = os.epoch('utc') - 1
  local ok = pcall(function() feed:tick() end)
  assert_true(ok, 'a configured-but-absent Sorter-Kiste must not crash the tick')
  assert_eq(export_calls, 0, 'no export must be attempted against a non-existent Sorter-Kiste peripheral')
  assert_true(warnings['sorter_chest_abs'] ~= nil, 'expected a dedicated sorter_chest_abs warning distinct from no_sorter_chest')
end

print('reprocessor_feed_router_no_sorter_chest_test.lua: ok')
