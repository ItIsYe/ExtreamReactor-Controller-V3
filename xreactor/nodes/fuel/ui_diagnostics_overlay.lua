-- nodes/fuel/ui_diagnostics_overlay.lua
-- Adds the exact UI lifecycle counters required by the FUEL monitor task to
-- the existing Diagnostics page without replacing its log-mode controls.

local M = {}
local mux = require("core.mockup_ui")

function M.attach(instance)
  if type(instance) ~= "table" or instance._diagnostics_overlay_attached then return instance end
  if type(instance.render_diagnostics) ~= "function" then return instance end
  instance._diagnostics_overlay_attached = true

  local original = instance.render_diagnostics
  instance.render_diagnostics = function(mon, model, should_clear)
    local footer = original(mon, model, should_clear)
    local w, h = mon.getSize()
    local d = model.ui_diagnostics or {}
    if h >= 10 then
      if w < 50 then
        mux.data_row(mon, 2, 8, math.max(1, w - 3), {
          label = "UI",
          value = string.format("R%d C%d S%d X%d T%d",
            d.frames_requested or 0, d.frames_committed or 0, d.frames_skipped or 0,
            d.full_clears or 0, d.transition_count or 0),
          status = "text", icon = "network"
        })
        mux.data_row(mon, 2, 9, math.max(1, w - 3), {
          label = "UI2",
          value = string.format("E%d %dms P%d M%d",
            d.render_errors or 0, d.last_render_ms or 0,
            d.pointer_events_received or 0, d.model_builds or 0),
          status = (d.render_errors or 0) > 0 and "WARNING" or "text", icon = "network"
        })
      else
        mux.data_row(mon, 2, 9, math.max(1, w - 3), {
          label = "UI",
          value = string.format("REQ%d COM%d SKIP%d CLR%d TR%d ERR%d %dms PTR%d MOD%d",
            d.frames_requested or 0, d.frames_committed or 0, d.frames_skipped or 0,
            d.full_clears or 0, d.transition_count or 0, d.render_errors or 0,
            d.last_render_ms or 0, d.pointer_events_received or 0, d.model_builds or 0),
          status = (d.render_errors or 0) > 0 and "WARNING" or "text", icon = "network"
        })
      end
    end
    return footer
  end
  return instance
end

return M
