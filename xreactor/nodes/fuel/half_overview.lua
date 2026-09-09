-- nodes/fuel/half_overview.lua
-- Compatibility shim retained because beta-v644 monitor_ui.lua still requires
-- this module when an older user config contains ui_scale=0.5.
--
-- FUEL is fixed back to TextScale 1.0 / 82x40, so the former native 164x81
-- overlay is intentionally disabled. Keeping this harmless no-op avoids a
-- require failure during rolling upgrades while removing all double-rendering.
local M = {}
function M.render(_mon, _model) return false end
M.DISABLED_FIXED_SCALE_1 = true
return M
