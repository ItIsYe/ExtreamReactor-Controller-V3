local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  widgets.card(mon, 1, 1, w, h, "MONITOR 3 - ENERGY & RESSOURCEN", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  ui.panel(mon, 2, 2, w - 2, 5, "Energy", model.status or "OK")
  ui.bigNumber(mon, 4, 3, "Gesamtspeicher", string.format("%.1f", pct), "%", model.status or "OK")
  ui.text(mon, 4, 5, string.format("Input %.1f MRF/t  |  Output %.1f MRF/t", model.input or 0, model.output or 0), colors.get("text"), colors.get("background"))

  ui.panel(mon, 2, 8, w - 2, 8, "Matrix-/Storage-Details", "OK")
  widgets.compact_header(mon, 3, 9, { "ID", "Fuellstand", "Input", "Output", "Status" }, { 10, 12, 10, 10, 8 })
  local y = 10
  for i, m in ipairs(model.matrices or {}) do
    if i > 5 then break end
    widgets.compact_status_row(mon, 3, y, {
      tostring(m.id or m.label or "M"), string.format("%d%%", math.floor((m.percent or 0) * 100)), string.format("%.1f", m.input or 0), string.format("%.1f", m.output or 0), tostring(m.status or "OK")
    }, { 10, 12, 10, 10, 8 }, m.status or "OK")
    y = y + 1
  end
  if y == 10 then ui.text(mon, 3, 10, "Keine Matrixdaten", colors.get("OFFLINE"), colors.get("background")) end

  ui.panel(mon, 2, 17, w - 2, 4, "Ressourcen", "OK")
  local r = model.resources or {}
  local half = math.floor((w - 5) / 2)
  widgets.stat_card(mon, 3, 17, half - 1, "Fuel", string.format("Reserve %.1f", r.fuel_total or 0), string.format("Quellen %d", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, 3 + half, 17, half - 1, "Water / Reprocessing", string.format("Wasser %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")

  ui.panel(mon, 2, 22, w - 2, h - 22, "Verbundene Support-Nodes", "OK")
  widgets.compact_header(mon, 3, 23, { "Node", "Rolle", "Status", "Seen", "Hinweis" }, { 7, 10, 8, 7, 24 })
  local sy = 24
  for _, n in ipairs(model.support_nodes or {}) do
    if sy > h - 1 then break end
    widgets.compact_status_row(mon, 3, sy, { tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-") }, { 7, 10, 8, 7, 24 }, n.status or "OFFLINE")
    sy = sy + 1
  end
  if sy == 24 then ui.text(mon, 3, 24, "Keine Support-Nodes", colors.get("OFFLINE"), colors.get("background")) end
end

return { render = render }
