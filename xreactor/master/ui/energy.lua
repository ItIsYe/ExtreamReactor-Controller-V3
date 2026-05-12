local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "MONITOR 3 - ENERGY & RESSOURCEN", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  local summary = widgets.panel_box(mon, 2, 2, w - 2, 9, "Energy Summary", model.status or "OK")
  ui.bigNumber(mon, summary.x + 1, summary.y, "Gesamtspeicher", string.format("%.1f", pct), "%", model.status or "OK")
  ui.text(mon, summary.x + 1, summary.y + 2, widgets.fit(string.format("Stored %.1f / %.1f", model.stored or 0, model.capacity or 0), summary.w - 2), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x + 1, summary.y + 3, widgets.fit(string.format("Input %.1f MRF/t  |  Output %.1f MRF/t", model.input or 0, model.output or 0), summary.w - 2), colors.get("text"), colors.get("background"))

  local content_y = 12
  local content_h = math.max(10, h - content_y - 1)
  local cols = widgets.split_columns(w - 2, { 3, 2 }, 1)
  local left_w = cols[1]
  local right_w = cols[2]

  local matrix = widgets.panel_box(mon, 2, content_y, left_w, content_h, "Matrix-/Storage-Details", (model.matrix_count or 0) > 0 and "OK" or "OFFLINE")
  local matrix_widths = widgets.table_widths(matrix.w, { 8, 10, 10, 10, 9, 8 })
  widgets.compact_header(mon, matrix.x, matrix.y, { "ID", "Fuellst", "Input", "Output", "Seen", "Status" }, matrix_widths)
  local y = matrix.y + 1
  for _, m in ipairs(model.matrices or {}) do
    if y > (matrix.y + matrix.h - 1) then break end
    widgets.compact_status_row(mon, matrix.x, y, {
      tostring(m.id or m.label or "M"),
      string.format("%d%%", math.floor((m.percent or 0) * 100)),
      string.format("%.1f", m.input or 0),
      string.format("%.1f", m.output or 0),
      tostring(m.last_seen_age or "-") .. "s",
      tostring(m.status or "OK")
    }, matrix_widths, m.status or "OK", 6)
    y = y + 1
  end
  if y == matrix.y + 1 then ui.text(mon, matrix.x, y, "Keine Matrixdaten", colors.get("OFFLINE"), colors.get("background")) end

  local right_x = 2 + left_w + 1
  local resources_h = math.max(11, math.floor(content_h * 0.52))
  local resources = widgets.panel_box(mon, right_x, content_y, right_w, resources_h, "Ressourcen", "OK")
  local r = model.resources or {}
  widgets.stat_card(mon, resources.x, resources.y, resources.w, "Fuel", string.format("Reserve %.1f", r.fuel_total or 0), string.format("Quellen %d", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, resources.x, resources.y + 5, resources.w, "Water / Reprocessing", string.format("Wasser %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")
  ui.text(mon, resources.x, resources.y + 10, widgets.fit("Support online: " .. tostring(model.support_online or 0) .. " / " .. tostring(#(model.support_nodes or {})), resources.w), colors.get("muted"), colors.get("background"))

  local support_y = content_y + resources_h + 1
  local support = widgets.panel_box(mon, right_x, support_y, right_w, math.max(7, (content_y + content_h) - support_y), "Support-Nodes", (model.support_stale or 0) > 0 and "WARNING" or "OK")
  local support_widths = widgets.table_widths(support.w, { 7, 11, 9, 8, 8 })
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
