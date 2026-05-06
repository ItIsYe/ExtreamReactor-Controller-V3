local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  widgets.card(mon, 1, 1, w, h, "MONITOR 3 - ENERGY & RESSOURCEN", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  ui.panel(mon, 2, 2, w - 2, 4, "Energy", model.status or "OK")
  ui.bigNumber(mon, 4, 3, "Gesamtspeicher", string.format("%.1f", pct), "%", model.status or "OK")
  ui.text(mon, 30, 3, string.format("Input %.1f | Output %.1f", model.input or 0, model.output or 0), colors.get("text"), colors.get("background"))

  ui.panel(mon, 2, 7, w - 2, 7, "Matrix-/Storage-Details", "OK")
  local matrix_rows = {}
  for i, m in ipairs(model.matrices or {}) do
    if i > 5 then break end
    matrix_rows[#matrix_rows + 1] = {
      text = string.format("%s fill:%d%% in:%.1f out:%.1f", tostring(m.id or m.label), math.floor((m.percent or 0) * 100), m.input or 0, m.output or 0),
      status = m.status or "OK"
    }
  end
  ui.list(mon, 3, 8, w - 4, matrix_rows, { max_rows = 5 })

  local r = model.resources or {}
  ui.panel(mon, 2, 15, w - 2, 5, "Ressourcen", "LIMITED")
  ui.text(mon, 4, 16, string.format("Fuel %.0f", r.fuel_total or 0), colors.get("text"), colors.get("background"))
  ui.text(mon, 20, 16, string.format("Water %.0f", r.water_total or 0), colors.get("text"), colors.get("background"))
  ui.text(mon, 37, 16, "Reproc " .. tostring(r.reprocessing_state or "-"), colors.get("text"), colors.get("background"))

  ui.panel(mon, 2, 21, w - 2, h - 21, "Verbundene Support-Nodes", "OK")
  local support_rows = {}
  for _, n in ipairs(model.support_nodes or {}) do
    support_rows[#support_rows + 1] = {
      text = string.format("%s %-10s %-8s seen:%ss %s", tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.last_seen_age or -1), tostring(n.note or "")),
      status = n.status or "OFFLINE"
    }
  end
  ui.list(mon, 3, 22, w - 4, support_rows, { max_rows = h - 23 })
end

return { render = render }
