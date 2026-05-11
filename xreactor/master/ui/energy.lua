local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "MONITOR 3 - ENERGY & RESSOURCEN", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  local summary = widgets.panel_box(mon, 2, 2, w - 2, 6, "Energy Summary", model.status or "OK")
  ui.bigNumber(mon, summary.x + 1, summary.y, "Gesamtspeicher", string.format("%.1f", pct), "%", model.status or "OK")
  ui.text(mon, summary.x + 1, summary.y + 2, widgets.fit(string.format("Input %.1f MRF/t  |  Output %.1f MRF/t", model.input or 0, model.output or 0), summary.w - 2), colors.get("text"), colors.get("background"))

  local content_y = 9
  local content_h = math.max(10, h - content_y - 6)
  local left_w = math.max(36, math.floor((w - 4) * 0.62))
  local right_w = math.max(22, (w - 3) - left_w)

  local matrix = widgets.panel_box(mon, 2, content_y, left_w, content_h, "Matrix-/Storage-Details", "OK")
  local matrix_widths = { 7, 10, 10, 10, math.max(8, matrix.w - 37) }
  widgets.compact_header(mon, matrix.x, matrix.y, { "ID", "Fuellst", "Input", "Output", "Status" }, matrix_widths)
  local y = matrix.y + 1
  for _, m in ipairs(model.matrices or {}) do
    if y > (matrix.y + matrix.h - 1) then break end
    widgets.compact_status_row(mon, matrix.x, y, { tostring(m.id or m.label or "M"), string.format("%d%%", math.floor((m.percent or 0) * 100)), string.format("%.1f", m.input or 0), string.format("%.1f", m.output or 0), tostring(m.status or "OK") }, matrix_widths, m.status or "OK", 5)
    y = y + 1
  end
  if y == matrix.y + 1 then ui.text(mon, matrix.x, y, "Keine Matrixdaten", colors.get("OFFLINE"), colors.get("background")) end

  local resources = widgets.panel_box(mon, 2 + left_w + 1, content_y, right_w, 11, "Ressourcen", "OK")
  local r = model.resources or {}
  widgets.stat_card(mon, resources.x, resources.y, resources.w, "Fuel", string.format("Reserve %.1f", r.fuel_total or 0), string.format("Quellen %d", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, resources.x, resources.y + 5, resources.w, "Water / Reprocessing", string.format("Wasser %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")

  local support = widgets.panel_box(mon, 2 + left_w + 1, content_y + 12, right_w, math.max(6, h - (content_y + 12) - 1), "Support-Nodes", "OK")
  local support_widths = { 6, 10, 9, 7, math.max(8, support.w - 32) }
  widgets.compact_header(mon, support.x, support.y, { "Node", "Rolle", "Status", "Seen", "Hinweis" }, support_widths)
  local sy = support.y + 1
  for _, n in ipairs(model.support_nodes or {}) do
    if sy > (support.y + support.h - 1) then break end
    widgets.compact_status_row(mon, support.x, sy, { tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-") }, support_widths, n.status or "OFFLINE", 3)
    sy = sy + 1
  end
  if sy == support.y + 1 then ui.text(mon, support.x, sy, "Keine Support-Nodes", colors.get("OFFLINE"), colors.get("background")) end
end

return { render = render }
