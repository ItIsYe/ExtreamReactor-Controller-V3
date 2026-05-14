local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local is_large = (w * h) >= 900 and w >= 48 and h >= 18
  ui.panel(mon, 1, 1, w, h, "MONITOR 3 - ENERGY & RESSOURCEN", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  local summary_h = is_large and 14 or 11
  local summary = widgets.panel_box(mon, 2, 2, w - 2, summary_h, "Energy Summary", model.status or "OK")
  ui.bigNumber(mon, summary.x + 1, summary.y, "Gesamtspeicher", string.format("%.1f", model.aggregate_percent or pct), "%", model.status or "OK")
  ui.text(mon, summary.x + 1, summary.y + 2, widgets.fit(string.format("Stored %.1f / %.1f", model.stored or 0, model.capacity or 0), summary.w - 2), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x + 1, summary.y + 3, widgets.fit(string.format("Input %.1f MRF/t  |  Output %.1f MRF/t", model.input or 0, model.output or 0), summary.w - 2), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x + 1, summary.y + 4, widgets.fit("Mode " .. tostring(model.mode or "-") .. " | Matrices " .. tostring(model.matrix_count or 0) .. ((model.matrix_only and " | Matrix-Only") or " | Hybrid"), summary.w - 2), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x + 1, summary.y + 5, widgets.fit(string.format("Nettofluss %.1f MRF/t | Aggregate %.1f%%", (model.input or 0) - (model.output or 0), model.aggregate_percent or 0), summary.w - 2), colors.get("text"), colors.get("background"))
  ui.progress(mon, summary.x + 1, summary.y + 1, math.max(10, summary.w - 2), math.max(0, math.min(100, model.aggregate_percent or pct)) / 100, model.status or "OK")

  ui.text(mon, summary.x + 1, summary.y + 6, widgets.fit(tostring(model.resource_summary or ""), summary.w - 2), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x + 1, summary.y + 7, widgets.fit("Betrieb: " .. (model.matrix_only and "Matrix-Only" or "Hybrid/Storage") .. " | Support " .. tostring(model.support_online or 0) .. "/" .. tostring(#(model.support_nodes or {})), summary.w - 2), colors.get("text"), colors.get("background"))

  if (model.matrix_count or 0) == 1 and model.matrices and model.matrices[1] then
    local m = model.matrices[1]
    ui.text(mon, summary.x + 1, summary.y + 8, widgets.fit(string.format("Single-Matrix %s: %.1f%% | In %.1f | Out %.1f", tostring(m.id or "M1"), m.percent or 0, m.input or 0, m.output or 0), summary.w - 2), colors.get("LIMITED"), colors.get("background"))
  end
  if (model.capacity or 0) <= 0 and ((model.stored or 0) > 0 or (model.input or 0) > 0 or (model.output or 0) > 0) then
    ui.text(mon, summary.x + 1, summary.y + 9, widgets.fit("Hinweis: Kapazitaet fehlt im Payload, Flussdaten sind vorhanden.", summary.w - 2), colors.get("WARNING"), colors.get("background"))
  end

  local content_y = 2 + summary_h + 1
  local content_h = math.max(is_large and 15 or 11, h - content_y - 1)
  local cols = widgets.split_columns(w - 2, is_large and { 3, 2 } or { 3, 2 }, 1)
  local left_w = cols[1]
  local right_w = cols[2]

  local matrix_title = ((model.matrix_count or 0) == 1) and "Matrix-Detail (Single Matrix)" or "Matrix-/Storage-Details"
  local matrix = widgets.panel_box(mon, 2, content_y, left_w, content_h, matrix_title, (model.matrix_count or 0) > 0 and "OK" or "OFFLINE")
  local matrix_widths = widgets.table_widths(matrix.w, is_large and { 14, 10, 10, 10, 9, 8 } or { 11, 9, 9, 9, 7, 7 })
  widgets.compact_header(mon, matrix.x, matrix.y, { "ID", "Fuellst", "Input", "Output", "Seen", "Status" }, matrix_widths)
  local y = matrix.y + 1
  for _, m in ipairs(model.matrices or {}) do
    if y > (matrix.y + matrix.h - 1) then break end
    widgets.compact_status_row(mon, matrix.x, y, {
      tostring(m.id or m.label or "M"),
      string.format("%.1f%%", m.percent or 0),
      string.format("%.1f", m.input or 0),
      string.format("%.1f", m.output or 0),
      tostring(m.last_seen_age or "-") .. "s",
      tostring(m.status or "OK")
    }, matrix_widths, m.status or "OK", 6)
    y = y + 1
  end
  if y == matrix.y + 1 then
    local has_flow = (model.stored or 0) > 0 or (model.input or 0) > 0 or (model.output or 0) > 0
    local msg = has_flow and "Keine Matrixzeilen, aber Energiefluss vorhanden" or "Keine Matrixdaten vom Energy-Node"
    if model.matrix_only then msg = msg .. " (Matrix-Only Payload)" end
    ui.text(mon, matrix.x, y, msg, colors.get(has_flow and "WARNING" or "OFFLINE"), colors.get("background"))
  end

  local right_x = 2 + left_w + 1
  local resources_h = is_large and math.max(13, math.floor(content_h * 0.50)) or math.max(9, math.floor(content_h * 0.48))
  local resources = widgets.panel_box(mon, right_x, content_y, right_w, resources_h, "Ressourcen", "OK")
  local r = model.resources or {}
  widgets.stat_card(mon, resources.x, resources.y, resources.w, "Fuel", string.format("Reserve %.1f", r.fuel_total or 0), string.format("Quellen %d", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, resources.x, resources.y + 5, resources.w, "Water / Reprocessing", string.format("Wasser %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")
  ui.text(mon, resources.x, resources.y + 10, widgets.fit("Support online: " .. tostring(model.support_online or 0) .. " / " .. tostring(#(model.support_nodes or {})), resources.w), colors.get("muted"), colors.get("background"))
  if model.matrix_only then
    ui.text(mon, resources.x, resources.y + 11, widgets.fit("Betrieb: Matrix-Only Payload aktiv", resources.w), colors.get("LIMITED"), colors.get("background"))
  end

  local support_y = content_y + resources_h + 1
  local support_h = math.max(7, (content_y + content_h) - support_y + 1)
  local support = widgets.panel_box(mon, right_x, support_y, right_w, support_h, "Support-Nodes", (model.support_stale or 0) > 0 and "WARNING" or "OK")
  local support_widths = widgets.table_widths(support.w, { 7, 11, 9, 8, 8 })
  widgets.compact_header(mon, support.x, support.y, { "Node", "Rolle", "Status", "Seen", "Hinweis" }, support_widths)
  local sy = support.y + 1
  for _, n in ipairs(model.support_nodes or {}) do
    if sy > (support.y + support.h - 1) then break end
    widgets.compact_status_row(mon, support.x, sy, { tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-") }, support_widths, n.status or "OFFLINE", 3)
    sy = sy + 1
  end
  if sy == support.y + 1 then ui.text(mon, support.x, sy, "Keine Support-/Energy-Nodes sichtbar", colors.get("OFFLINE"), colors.get("background")) end
end

return { render = render }
