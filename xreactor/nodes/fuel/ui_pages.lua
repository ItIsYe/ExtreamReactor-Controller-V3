-- nodes/fuel/ui_pages.lua
-- Fixed-SCADA page container for the FUEL node.
--
-- The former responsive Diagnostics renderer was removed. All three operator
-- pages (Overview, Details, Diagnostics) are attached by ui_completion.lua.

local M = {}

function M.new(opts)
  opts = opts or {}
  return {
    _fuel_fixed_scada_pages = true,
    _scada_devices = opts.devices,
  }
end

return M
