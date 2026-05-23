local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local is_large = (w * h) >= 900 and w >= 48 and h >= 18
  ui.panel(mon, 1, 1, w, h, "MONITOR 3 - ENERGY", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  local summary_h = is_large and 11 or 10
  local summary = widgets.panel_box(mon, 2, 2, w - 2, summary_h, "Energy Summary", model.status or "OK")
  ui.bigNumber(mon, summary.x, summary.y, "Fuellstand", string.format("%.1f", model.aggregate_percent or pct), "%", model.status or "OK")
  ui.progress(mon, summary.x, summary.y + 2, math.max(12, summary.w), math.max(0, math.min(100, model.aggregate_percent or pct)) / 100, model.status or "OK")
  ui.text(mon, summary.x, summary.y + 3, widgets.fit(string.format("Stored %.1f / %.1f", model.stored or 0, model.capacity or 0), summary.w), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 4, widgets.fit(string.format("Input %.1f | Output %.1f MRF/t", model.input or 0, model.output or 0), summary.w), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 5, widgets.fit("Mode " .. tostring(model.mode or "-") .. " | Matrices " .. tostring(model.matrix_count or 0), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 6, widgets.fit((model.matrix_only and "Matrix-Only" or "Hybrid/Storage") .. " | Support " .. tostring(model.support_online or 0) .. "/" .. tostring(#(model.support_nodes or {})), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 7, widgets.fit("Resources: " .. tostring(model.resource_summary or "-"), summary.w), colors.get("muted"), colors.get("background"))
  if (model.matrix_count or 0) == 1 and model.matrices and model.matrices[1] then
    local m = model.matrices[1]
    ui.text(mon, summary.x, summary.y + 8, widgets.fit(string.format("Single Matrix %s %.1f%% | In %.1f | Out %.1f", tostring(m.id or "M1"), m.percent or 0, m.input or 0, m.output or 0), summary.w), colors.get("LIMITED"), colors.get("background"))
  end

  local content_y = 2 + summary_h + 1
  local content_h = math.max(8, h - content_y - 1)
  local cols = widgets.split_columns(w - 2, { 3, 2 }, 1)
  local left_w, right_w = cols[1], cols[2]

  local matrix = widgets.panel_box(mon, 2, content_y, left_w, content_h, ((model.matrix_count or 0) == 1) and "Matrix-Detail" or "Matrix / Storage", (model.matrix_count or 0) > 0 and "OK" or "OFFLINE")
  local matrix_widths = widgets.table_widths(matrix.w, is_large and { 12, 9, 9, 9, 8 } or { 10, 8, 8, 8, 7 })
  widgets.compact_header(mon, matrix.x, matrix.y, { "ID", "%", "In", "Out", "Status" }, matrix_widths)
  local my = matrix.y + 1
  for _, m in ipairs(model.matrices or {}) do
    if my > (matrix.y + matrix.h - 1) then break end
    widgets.compact_status_row(mon, matrix.x, my, {
      tostring(m.id or m.label or "M"),
      string.format("%.1f", m.percent or 0),
      string.format("%.1f", m.input or 0),
      string.format("%.1f", m.output or 0),
      tostring(m.status or "OK")
    }, matrix_widths, m.status or "OK", 5)
    my = my + 1
  end
  if my == matrix.y + 1 then
    local has_flow = (model.stored or 0) > 0 or (model.input or 0) > 0 or (model.output or 0) > 0
    local msg = has_flow and "Keine Matrixzeilen, aber Energiefluss vorhanden" or "Keine Matrixdaten sichtbar"
    ui.text(mon, matrix.x, my, widgets.fit(msg, matrix.w), colors.get(has_flow and "WARNING" or "OFFLINE"), colors.get("background"))
  end

  local right_x = 2 + left_w + 1
  local resources_h = math.max(7, math.floor(content_h * 0.45))
  local resources = widgets.panel_box(mon, right_x, content_y, right_w, resources_h, "Ressourcen", "OK")
  local r = model.resources or {}
  widgets.stat_card(mon, resources.x, resources.y, resources.w, "Fuel", string.format("%.1f Reserve", r.fuel_total or 0), string.format("%d Quellen", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, resources.x, resources.y + 6, resources.w, "Water / Reproc", string.format("Water %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")
  if model.matrix_only then
    ui.text(mon, resources.x, resources.y + math.max(0, resources.h - 1), widgets.fit("Payload: Matrix-Only", resources.w), colors.get("LIMITED"), colors.get("background"))
  end

  local support_y = content_y + resources_h + 1
  local support_h = math.max(6, (content_y + content_h) - support_y + 1)
  local support = widgets.panel_box(mon, right_x, support_y, right_w, support_h, "Support-Nodes", (model.support_stale or 0) > 0 and "WARNING" or "OK")
  local support_widths = widgets.table_widths(support.w, { 8, 8, 7, 10 })
  widgets.compact_header(mon, support.x, support.y, { "Node", "Rolle", "Seen", "Hinweis" }, support_widths)
  local sy = support.y + 1
  for _, n in ipairs(model.support_nodes or {}) do
    if sy > (support.y + support.h - 1) then break end
    widgets.compact_status_row(mon, support.x, sy, {
      tostring(n.id or "-"),
      tostring(n.role or "-"),
      tostring(n.last_seen_age or -1) .. "s",
      tostring(n.note or "-")
    }, support_widths, n.status or "OFFLINE", 2)
    sy = sy + 1
  end
  if sy == support.y + 1 then
    ui.text(mon, support.x, sy, "Keine Support-Nodes sichtbar", colors.get("OFFLINE"), colors.get("background"))
  end
end

return { render = render }
