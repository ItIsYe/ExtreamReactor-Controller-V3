local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render(mon, model)
  local w, h = ui.getSize(mon)
  widgets.card(mon, 1, 1, w, h, "MONITOR 2 - RT-FLOTTE", "OK")

  ui.panel(mon, 2, 2, w - 2, 4, "RT-Uebersicht", "OK")
  ui.badge(mon, 4, 3, "Ramp " .. tostring(model.ramp_profile or "NORMAL"), "OK")
  ui.badge(mon, 20, 3, "State " .. tostring(model.sequence_state or "IDLE"), "LIMITED")
  ui.badge(mon, 40, 3, model.rt_global_off_hold and "GLOBAL HOLD" or "HOLD AUS", model.rt_global_off_hold and "WARNING" or "OK")

  local card_w = math.floor((w - 5) / 2)
  local y = 7
  for i, rt in ipairs(model.rt_nodes or {}) do
    if i > 4 then break end
    local col = (i % 2 == 1) and 2 or (3 + card_w)
    if i % 2 == 1 and i > 1 then y = y + 7 end
    ui.panel(mon, col, y, card_w, 6, tostring(rt.id or "RT"), rt.status or "OFFLINE")
    ui.badge(mon, col + card_w - 11, y + 1, tostring(rt.state or "OFF"), rt.status or "OFFLINE")
    ui.text(mon, col + 1, y + 1, "Modus " .. tostring(rt.mode or "-"), colors.get("text"), colors.get("background"))
    ui.text(mon, col + 1, y + 2, string.format("Soll %.1f", rt.target or 0), colors.get("text"), colors.get("background"))
    ui.text(mon, col + 13, y + 2, string.format("Ist %.1f", rt.actual_output or rt.output or 0), colors.get("text"), colors.get("background"))
    ui.text(mon, col + 1, y + 3, "Workflow " .. tostring(rt.assignment_reason or rt.assignment_state or "-"), colors.get("muted"), colors.get("background"))
  end

  ui.panel(mon, 2, h - 6, w - 2, 6, "Sequencer / Queue", "LIMITED")
  local rows = {}
  for i, q in ipairs(model.queue or {}) do
    if i > 4 then break end
    rows[#rows + 1] = { text = string.format("%s -> %s", tostring(q.node_id or "RT"), tostring(q.module_id or q.action or "step")), status = "LIMITED" }
  end
  if #rows == 0 then
    rows[1] = { text = "Queue leer", status = "OFFLINE" }
  end
  ui.list(mon, 3, h - 5, w - 4, rows, { max_rows = 4 })
end

return { render = render }
