-- core/me_bridge_compat.lua
--
-- Advanced Peripherals overhauled the ME/RS Bridge item API for the 1.21+
-- (0.7+) mod versions: the old exportItemToPeripheral(item, container)/
-- importItemFromPeripheral(item, container) pair (used alongside a
-- direction-based exportItem(item, direction)/importItem(item, direction))
-- was merged into a single exportItem(filter, target)/importItem(filter,
-- target), where target is either a redstone side or a peripheral name
-- (the mod tries direction first, then peripheral lookup). Both API
-- generations are seen live -- detect and call whichever the wrapped
-- peripheral actually exposes instead of assuming one or the other.

local M = {}

-- getItem/getFluid exist unchanged across both generations; only the
-- import/export method names differ. A caller may only ever need one
-- direction (e.g. feed_router.lua only ever exports, never imports), so
-- detection only requires getItem plus at least one transfer method from
-- either generation -- not both directions.
function M.is_bridge(method_set)
  return method_set.getItem ~= nil
    and (method_set.importItem or method_set.importItemFromPeripheral
      or method_set.exportItem or method_set.exportItemToPeripheral) ~= nil
end

-- target_name is a peripheral name (never a redstone side) at every call
-- site in this codebase -- the modern exportItem/importItem also accept
-- that directly per Advanced Peripherals' own docs.
function M.export_to(bridge, filter, target_name)
  local method = bridge.exportItemToPeripheral or bridge.exportItem
  return pcall(method, filter, target_name)
end

function M.import_from(bridge, filter, source_name)
  local method = bridge.importItemFromPeripheral or bridge.importItem
  return pcall(method, filter, source_name)
end

-- The old API's Item Stack used `.amount`; keep accepting `.count` too in
-- case a given mod version renamed the field.
function M.item_amount(info)
  if type(info) ~= "table" then return 0 end
  return tonumber(info.amount) or tonumber(info.count) or 0
end

return M
