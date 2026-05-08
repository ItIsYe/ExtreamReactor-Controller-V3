local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render_rt_card(mon, x, y, w, rt)
  widgets.card(mon, x, y, w, 8, "RT-" .. tostring(rt.id or "?"), rt.status or "OFFLINE")
  ui.badge(mon, x + w - 12, y + 1, tostring(rt.state or "OFF"), rt.status or "OFFLINE")
  ui.text(mon, x + 1, y + 2, string.format("Soll %.1f%%", rt.target or 0), colors.get("muted"), colors.get("background"))
  ui.text(mon, x + 1, y + 3, string.format("Ist %.1f%%", rt.actual_output or rt.output or 0), colors.get("text"), colors.get("background"))
  ui.text(mon, x + 1, y + 4, "Modus " .. tostring(rt.mode or "-"), colors.get("muted"), colors.get("background"))
  ui.text(mon, x + 1, y + 5, "Workflow " .. tostring(rt.assignment_reason or rt.assignment_state or "-"), colors.get("muted"), colors.get("background"))
  ui.progress(mon, x + 1, y + 7, w - 2, math.max(0, math.min(100, rt.actual_output or rt.output or 0)), rt.status or "OFFLINE")
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  widgets.card(mon, 1, 1, w, h, "MONITOR 2 - RT-FLOTTE", "OK")

  ui.panel(mon, 2, 2, w - 2, 4, "RT-Uebersicht", "OK")
  ui.badge(mon, 4, 3, tostring(model.rt_active or 0) .. " AKTIV", "OK")
  ui.badge(mon, 16, 3, tostring(model.rt_startup or 0) .. " STARTUP", "LIMITED")
  ui.badge(mon, 31, 3, tostring(model.rt_shutdown or 0) .. " SHUTDOWN", "OFFLINE")
  ui.badge(mon, 47, 3, model.rt_global_off_hold and "GLOBAL HOLD AUS" or "GLOBAL HOLD", model.rt_global_off_hold and "OK" or "WARNING")
  ui.text(mon, 3, 5, "Einzelne RT-Nodes mit Sollwert, Zustand, Modus und Workflow", colors.get("muted"), colors.get("background"))

  local card_w, y = math.floor((w - 5) / 2), 6
  for i, rt in ipairs(model.rt_nodes or {}) do
    if i > 4 then break end
    local col = (i % 2 == 1) and 2 or (3 + card_w)
    if i % 2 == 1 and i > 1 then y = y + 9 end
    render_rt_card(mon, col, y, card_w, rt)
  end

  ui.panel(mon, 2, h - 7, w - 2, 7, "Sequencer / Queue", "LIMITED")
  ui.text(mon, 3, h - 6, "Naechste Aktionen", colors.get("muted"), colors.get("background"))
  local rows = {}
  for i, q in ipairs(model.queue or {}) do
    if i > 3 then break end
    rows[#rows + 1] = { text = string.format("%d. RT-%s -> %s", i, tostring(q.node_id or "?"), tostring(q.module_id or q.action or "step")), status = "LIMITED" }
  end
  if #rows == 0 then rows[1] = { text = "Queue leer", status = "OFFLINE" } end
  ui.list(mon, 3, h - 5, w - 4, rows, { max_rows = 3 })
end

return { render = render }
