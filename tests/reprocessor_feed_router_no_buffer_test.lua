package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for feed_router.lua's architecture change (2026-09-17,
-- confirmed against the operator's real build): the ME-Bridge now exports
-- into the PUFFER buffer chest (config.buffers[1]) instead of a shared
-- export_inlet -- Mekanism's own Sorter+Transporter mechanics take over
-- from the chest automatically. Without a configured buffer chest, feed_
-- one() must skip cleanly with a dedicated warning, not crash or export to
-- a nil/empty destination.

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'puffer_chest_0' end,
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
local function make_feed(buffers)
  local feed = feed_router_lib.new({
    config = {
      buffers = buffers,
      feed = {
        enabled = true, waste_item = 'x', feed_amount = 2,
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

-- 1) No buffers configured at all (nil) -- must skip with a warning, no
--    export, no crash.
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
  assert_true(ok, 'a missing buffer list must not crash the tick')
  assert_eq(export_calls, 0, 'no export must happen without a configured buffer')
  assert_true(warnings['no_buffer'] ~= nil, 'expected a dedicated no_buffer warning')
end

-- 2) Empty buffers list ({}) -- same as nil, must skip cleanly.
do
  export_calls = 0
  local warnings = {}
  local feed = make_feed({})
  feed.warn_once = function(key, msg) warnings[key] = msg end
  feed._state.last_refresh = os.epoch('utc')
  feed._state.next_feed_ts = os.epoch('utc') - 1
  feed:tick()
  assert_eq(export_calls, 0, 'no export must happen with an empty buffer list')
  assert_true(warnings['no_buffer'] ~= nil, 'expected a dedicated no_buffer warning for an empty list too')
end

-- 3) A real buffer configured -- feed proceeds normally, exporting to it.
do
  export_calls = 0
  local feed = make_feed({ 'puffer_chest_0' })
  feed._state.last_refresh = os.epoch('utc')
  feed._state.next_feed_ts = os.epoch('utc') - 1
  feed:tick()
  assert_eq(export_calls, 1, 'a configured buffer must let the feed proceed')
end

-- 4) A buffer NAME is configured, but no such peripheral is actually
--    present (e.g. still the shipped default "chemical_tank_0", or a typo)
--    -- must skip cleanly with a DEDICATED "buffer not found" warning, not
--    the generic feed_fail from a blind export attempt. Real-world case:
--    the operator never opened the Router UI's PUFFER page, so config.
--    buffers[1] is still config.lua's DEFAULT_BUFFERS placeholder, which
--    never physically existed in their build.
do
  export_calls = 0
  local warnings = {}
  local feed = make_feed({ 'chemical_tank_0' }) -- not in the isPresent() allowlist above
  feed.warn_once = function(key, msg) warnings[key] = msg end
  feed._state.last_refresh = os.epoch('utc')
  feed._state.next_feed_ts = os.epoch('utc') - 1
  local ok = pcall(function() feed:tick() end)
  assert_true(ok, 'a configured-but-absent buffer must not crash the tick')
  assert_eq(export_calls, 0, 'no export must be attempted against a non-existent buffer peripheral')
  assert_true(warnings['buffer_abs'] ~= nil, 'expected a dedicated buffer_abs warning distinct from no_buffer')
end

print('reprocessor_feed_router_no_buffer_test.lua: ok')
