local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  widgets.card(mon, 1, 1, w, h, "MONITOR 3 - ENERGY & RESSOURCEN", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  ui.panel(mon, 2, 2, w - 2, 5, "Energy", model.status or "OK")
  ui.bigNumber(mon, 4, 3, "Gesamtspeicher", string.format("%.1f", pct), "%", model.status or "OK")
  ui.text(mon, 4, 5, string.format("Input %.1f MRF/t | Output %.1f MRF/t", model.input or 0, model.output or 0), colors.get("text"), colors.get("background"))

  ui.panel(mon, 2, 8, w - 2, 8, "Matrix-/Storage-Details", "OK")
  local matrix_rows = {}
  for i, m in ipairs(model.matrices or {}) do
    if i > 5 then break end
    matrix_rows[#matrix_rows + 1] = {
      text = string.format("%s  %2d%%  in %.1f  out %.1f", tostring(m.id or m.label), math.floor((m.percent or 0) * 100), m.input or 0, m.output or 0),
      status = m.status or "OK"
    }
  end
  if #matrix_rows == 0 then matrix_rows[1] = { text = "Keine Matrixdaten", status = "OFFLINE" } end
  ui.list(mon, 3, 9, w - 4, matrix_rows, { max_rows = 6 })

  local r = model.resources or {}
  local half = math.floor((w - 5) / 2)
  widgets.stat_card(mon, 2, 17, half, "Fuel", string.format("Reserve %.1f", r.fuel_total or 0), string.format("Quellen %d", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, 3 + half, 17, half - 1, "Water / Reprocessing", string.format("Wasser %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")

  ui.panel(mon, 2, 22, w - 2, h - 22, "Verbundene Support-Nodes", "OK")
  local support_rows = {}
  for _, n in ipairs(model.support_nodes or {}) do
    support_rows[#support_rows + 1] = {
      text = string.format("%s %-10s %-8s %ss %s", tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.last_seen_age or -1), tostring(n.note or "")),
      status = n.status or "OFFLINE"
    }
  end
  if #support_rows == 0 then support_rows[1] = { text = "Keine Support-Nodes", status = "OFFLINE" } end
  ui.list(mon, 3, 23, w - 4, support_rows, { max_rows = h - 24 })
end

return { render = render }
