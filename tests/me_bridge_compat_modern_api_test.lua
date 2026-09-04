package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test for core/me_bridge_compat.lua. Advanced Peripherals
-- overhauled the ME/RS Bridge item API for 1.21+ (0.7+): the legacy
-- exportItemToPeripheral(item, container)/importItemFromPeripheral(item,
-- container) pair was replaced by a single exportItem(filter, target)/
-- importItem(filter, target), where target can be a peripheral name
-- directly. Real logs (2026-09-03) showed a live ME Bridge exposing
-- getItem/importItem/exportItem/getFluid/... but NEITHER
-- exportItemToPeripheral NOR importItemFromPeripheral -- code that only
-- checked for the legacy names (logistics_router.lua, feed_router.lua,
-- fuel/main.lua's storage discovery) never recognized it as a bridge at
-- all, and every actual export/import call would have silently failed
-- (pcall on a nil method).

local compat = require('core.me_bridge_compat')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- 1. Modern API (no ToPeripheral/FromPeripheral methods) must still be
--    recognized as a bridge.
do
  local modern_methods = {
    getItem = true, importItem = true, exportItem = true,
    getFluid = true, getCells = true, getConfiguration = true,
  }
  assert_true(compat.is_bridge(modern_methods), 'modern ME/RS Bridge API must be recognized')
end

-- 2. Legacy API (both directions via ToPeripheral/FromPeripheral) must
--    still be recognized -- this must not regress.
do
  local legacy_methods = {
    getItem = true, exportItemToPeripheral = true, importItemFromPeripheral = true,
  }
  assert_true(compat.is_bridge(legacy_methods), 'legacy ME Bridge API must still be recognized')
end

-- 3. Export-only legacy bridge (feed_router.lua's historical case: it
--    never imports, so its method-signature probe only ever required
--    getItem+exportItemToPeripheral) must still be recognized.
do
  local export_only = { getItem = true, exportItemToPeripheral = true }
  assert_true(compat.is_bridge(export_only), 'export-only legacy signature must still be recognized')
end

-- 4. Something that merely has getItem (e.g. an unrelated inventory
--    peripheral) without any transfer method must NOT be misdetected.
do
  local not_a_bridge = { getItem = true, list = true }
  assert_true(not compat.is_bridge(not_a_bridge), 'getItem alone must not be enough to misdetect a bridge')
end

-- 5. export_to()/import_from() must prefer the legacy method when present
--    (behavior-preserving for existing installs)...
do
  local calls = {}
  local bridge = {
    exportItemToPeripheral = function(filter, target) calls[#calls + 1] = { 'legacy_export', filter, target }; return 5 end,
    exportItem = function() error('modern exportItem must not be called when legacy method exists') end,
  }
  local ok, result = compat.export_to(bridge, { name = 'x' }, 'chest_0')
  assert_true(ok, 'export_to must succeed')
  assert_eq(result, 5, 'export_to must return the underlying call result')
  assert_eq(#calls, 1, 'exactly one export call must be made')
  assert_eq(calls[1][1], 'legacy_export')
end

-- ...and fall back to the modern method when the legacy one is absent.
do
  local calls = {}
  local bridge = {
    exportItem = function(filter, target) calls[#calls + 1] = { 'modern_export', filter, target }; return 7 end,
  }
  local ok, result = compat.export_to(bridge, { name = 'y' }, 'me_bridge_3')
  assert_true(ok, 'export_to must succeed via the modern method')
  assert_eq(result, 7)
  assert_eq(calls[1][1], 'modern_export')
  assert_eq(calls[1][3], 'me_bridge_3', 'target peripheral name must be passed through unchanged')
end

-- 6. import_from() mirrors export_to()'s legacy/modern preference.
do
  local modern_bridge = {
    importItem = function(filter, target) return { amount = 12 } end,
  }
  local ok, result = compat.import_from(modern_bridge, {}, 'reprocessor_inlet')
  assert_true(ok)
  assert_eq(result.amount, 12)
end

-- 7. item_amount() accepts both the legacy `.amount` field and a `.count`
--    fallback, and never errors on nil/non-table input.
do
  assert_eq(compat.item_amount({ amount = 42 }), 42)
  assert_eq(compat.item_amount({ count = 17 }), 17)
  assert_eq(compat.item_amount(nil), 0)
  assert_eq(compat.item_amount('not a table'), 0)
end

print('me_bridge_compat_modern_api_test.lua: ok')
