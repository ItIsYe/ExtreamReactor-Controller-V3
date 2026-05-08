local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render_rt_card(mon, x, y, w, rt)
  widgets.card(mon, x, y, w, 8, "RT-" .. tostring(rt.id or "?"), rt.status or "OFFLINE")
  widgets.status_badge(mon, x + math.max(2, w - 12), y + 1, tostring(rt.state or "OFF"), rt.status or "OFFLINE", 10)
  ui.text(mon, x + 1, y + 2, widgets.fit(string.format("Soll %.1f%%", rt.target or 0), w - 2), colors.get("muted"), colors.get("background"))
  ui.text(mon, x + 1, y + 3, widgets.fit(string.format("Ist %.1f%%", rt.actual_output or rt.output or 0), w - 2), colors.get("text"), colors.get("background"))
  ui.text(mon, x + 1, y + 4, widgets.pad("Modus", 8) .. widgets.fit(tostring(rt.mode or "-"), w - 10), colors.get("muted"), colors.get("background"))
  ui.text(mon, x + 1, y + 5, widgets.pad("Betrieb", 8) .. widgets.fit(tostring(rt.assignment_state or "MASTER"), w - 10), colors.get("text"), colors.get("background"))
  ui.text(mon, x + 1, y + 6, widgets.fit("Workflow: " .. tostring(rt.assignment_reason or rt.assignment_state or "-"), w - 2), colors.get("muted"), colors.get("background"))
  ui.progress(mon, x + 1, y + 7, w - 2, math.max(0, math.min(100, rt.actual_output or rt.output or 0)), rt.status or "OFFLINE")
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  widgets.card(mon, 1, 1, w, h, "MONITOR 2 - RT-FLOTTE", "OK")
  ui.panel(mon, 2, 2, w - 2, 4, "RT-Uebersicht", "OK")
  widgets.status_badge(mon, 3, 3, tostring(model.rt_active or 0) .. " AKTIV", "OK", math.floor(w*0.14))
  widgets.status_badge(mon, math.floor(w*0.22), 3, tostring(model.rt_startup or 0) .. " STARTUP", "LIMITED", math.floor(w*0.16))
  widgets.status_badge(mon, math.floor(w*0.43), 3, tostring(model.rt_shutdown or 0) .. " SHUTDOWN", "OFFLINE", math.floor(w*0.16))
  widgets.status_badge(mon, math.floor(w*0.66), 3, model.rt_global_off_hold and "GLOBAL HOLD AUS" or "GLOBAL HOLD", model.rt_global_off_hold and "OK" or "WARNING", math.floor(w*0.3))

  local cards_top = 6
  local cards_bottom = math.max(cards_top + 8, h - 8)
  local rows = math.max(1, math.floor((cards_bottom - cards_top + 1) / 9))
  local cols = (w >= 80) and 3 or 2
  local gap = 1
  local card_w = math.max(20, math.floor((w - 3 - (cols - 1) * gap) / cols))
  for i, rt in ipairs(model.rt_nodes or {}) do
    local idx = i - 1
    local r = math.floor(idx / cols)
    if r >= rows then break end
    local c = idx % cols
    local x = 2 + c * (card_w + gap)
    local y = cards_top + r * 9
    render_rt_card(mon, x, y, card_w, rt)
  end

  ui.panel(mon, 2, h - 6, w - 2, 6, "Sequencer / Queue", "LIMITED")
  local rows_data = {}
  for i, q in ipairs(model.queue or {}) do
    if i > 3 then break end
    rows_data[#rows_data + 1] = { text = widgets.fit(string.format("%d. RT-%s -> %s", i, tostring(q.node_id or "?"), tostring(q.module_id or q.action or "step")), w - 7), status = "LIMITED" }
  end
  if #rows_data == 0 then rows_data[1] = { text = "Queue leer - keine aktiven Sequenzen", status = "OFFLINE" } end
  ui.list(mon, 3, h - 5, w - 4, rows_data, { max_rows = 3 })
end

return { render = render }
