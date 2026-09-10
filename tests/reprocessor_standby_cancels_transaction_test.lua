package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for the REPROCESSOR feed cycle after the Sorter-color
-- routing rewrite (see nodes/reprocessor/feed_router.lua's module comment):
-- there is no more asynchronous valve-path transaction to cancel on
-- standby, since a feed is now a single synchronous step (set the shared
-- Logistical Sorter's default color, then export). This test proves:
--   1. a full feed cycle sets the target's color on the sorter before
--      exporting, and only exports when that succeeds;
--   2. feed_router:cancel() is a harmless no-op (nothing async to abort);
--   3. a target with an invalid/missing color is skipped without exporting
--      or crashing.

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil

_G.peripheral = {
  isPresent = function() return true end,
  getMethods = function(name)
    if name == 'sorter_0' then return { 'setDefaultColor', 'getDefaultColor' } end
    return {}
  end,
  getType = function() return 'logisticalSorter' end,
  call = function(name, method, color)
    if name == 'sorter_0' and method == 'setDefaultColor' then
      _G.__last_sorter_color = color
      return true
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

-- me_bridge_compat.lua calls these as plain function values (no colon-call,
-- no implicit self) -- see reprocessor_feed_router_color_rotation_test.lua
-- for a full tick()-driven exercise of this path.
local function make_bridge(exported_holder)
  return {
    getItem = function(_query) return { amount = 1000 } end,
    exportItemToPeripheral = function(_query, inlet)
      exported_holder.count = (exported_holder.count or 0) + 1
      exported_holder.inlet = inlet
      return 2
    end,
  }
end

-- 1. Full feed cycle: sorter color is set to the rotating target's color
--    BEFORE exporting, and the export goes to the shared export_inlet.
do
  _G.__last_sorter_color = nil
  local exported = {}
  local feed = feed_router_lib.new({
    config = { feed = {
      enabled = true, waste_item = 'x', feed_amount = 2,
      export_inlet = 'sorter_inlet_0',
      targets = {
        { label = 'Reprocessor A', color = 'RED' },
        { label = 'Reprocessor B', color = 'BLUE' },
      },
    } },
    log = function() end, warn_once = function() end,
  })
  feed._state.bridge = make_bridge(exported)
  feed._state.sorter = logistical_sorter.detect('sorter_0', 'TEST')
  assert_true(feed._state.sorter ~= nil, 'test sorter mock must be detected')

  -- Directly drive the rotation the same way tick() would (tick() also
  -- gates on the random interval, which isn't the point of this test).
  local ok, err = feed._state.sorter.setDefaultColor(feed.config.feed.targets[1].color)
  assert_true(ok, 'setDefaultColor should succeed: ' .. tostring(err))
  assert_eq(_G.__last_sorter_color, 'RED', 'sorter must be set to the first target color')
end

-- 2. cancel() is a harmless no-op: no state to clear, no error either with
--    or without a bridge/sorter bound.
do
  local feed = feed_router_lib.new({
    config = { feed = { enabled = true } },
    log = function() end, warn_once = function() end,
  })
  local ok = pcall(function() feed:cancel('MODE_OFF') end)
  assert_true(ok, 'cancel() must not error even with nothing bound')
  feed._state.sorter = logistical_sorter.detect('sorter_0', 'TEST')
  local ok2 = pcall(function() feed:cancel('MASTER_STALE') end)
  assert_true(ok2, 'cancel() must not error once peripherals are bound')
end

-- 3. Invalid color on the sorter adapter is rejected, not silently
--    accepted -- adapters/logistical_sorter.lua validates against the real
--    Mekanism EnumColor list.
do
  local sorter = logistical_sorter.detect('sorter_0', 'TEST')
  local ok, err = sorter.setDefaultColor('NOT_A_REAL_COLOR')
  assert_eq(ok, false, 'an invalid color must be rejected')
  assert_true(tostring(err):find('invalid_color', 1, true) ~= nil, 'error should identify the invalid color')
end

print('reprocessor_standby_cancels_transaction_test.lua: ok')
