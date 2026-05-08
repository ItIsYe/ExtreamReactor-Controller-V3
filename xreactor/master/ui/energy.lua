local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  widgets.card(mon, 1, 1, w, h, "MONITOR 3 - ENERGY & RESSOURCEN", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  ui.panel(mon, 2, 2, w - 2, 5, "Energy", model.status or "OK")
  ui.bigNumber(mon, 4, 3, "Gesamtspeicher", string.format("%.1f", pct), "%", model.status or "OK")
  ui.text(mon, 4, 5, widgets.fit(string.format("Input %.1f MRF/t  |  Output %.1f MRF/t", model.input or 0, model.output or 0), w - 8), colors.get("text"), colors.get("background"))

  local left_w = math.max(28, math.floor((w - 5) * 0.55))
  local right_w = math.max(20, w - left_w - 4)
  ui.panel(mon, 2, 8, left_w, 10, "Matrix-/Storage-Details", "OK")
  local matrix_widths = { 6, 10, 8, 8, math.max(8, left_w - 36) }
  widgets.compact_header(mon, 3, 9, { "ID", "Fuellst", "Input", "Output", "Status" }, matrix_widths)
  local y = 10
  for i, m in ipairs(model.matrices or {}) do
    if i > 7 then break end
    widgets.compact_status_row(mon, 3, y, { tostring(m.id or m.label or "M"), string.format("%d%%", math.floor((m.percent or 0) * 100)), string.format("%.1f", m.input or 0), string.format("%.1f", m.output or 0), tostring(m.status or "OK") }, matrix_widths, m.status or "OK", 5)
    y = y + 1
  end
  if y == 10 then ui.text(mon, 3, 10, "Keine Matrixdaten", colors.get("OFFLINE"), colors.get("background")) end

  ui.panel(mon, 3 + left_w, 8, right_w, 10, "Ressourcen", "OK")
  local r = model.resources or {}
  widgets.stat_card(mon, 4 + left_w, 9, right_w - 2, "Fuel", string.format("Reserve %.1f", r.fuel_total or 0), string.format("Quellen %d", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, 4 + left_w, 13, right_w - 2, "Water / Reprocessing", string.format("Wasser %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")

  local support_y = 19
  ui.panel(mon, 2, support_y, w - 2, h - support_y, "Verbundene Support-Nodes", "OK")
  local support_widths = { 7, 12, 8, 8, math.max(10, w - 38) }
  widgets.compact_header(mon, 3, support_y + 1, { "Node", "Rolle", "Status", "Seen", "Hinweis" }, support_widths)
  local sy = support_y + 2
  for _, n in ipairs(model.support_nodes or {}) do
    if sy > h - 1 then break end
    widgets.compact_status_row(mon, 3, sy, { tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-") }, support_widths, n.status or "OFFLINE", 3)
    sy = sy + 1
  end
  if sy == support_y + 2 then ui.text(mon, 3, sy, "Keine Support-Nodes", colors.get("OFFLINE"), colors.get("background")) end
end

return { render = render }
