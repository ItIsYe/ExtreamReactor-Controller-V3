local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render_rt_card(mon, x, y, w, rt)
  local box = widgets.panel_box(mon, x, y, w, 10, "RT-" .. tostring(rt.id or "?"), rt.status or "OFFLINE")
  widgets.status_badge(mon, box.x + math.max(0, box.w - 10), box.y, tostring(rt.state or "OFF"), rt.status or "OFFLINE", 9)
  ui.text(mon, box.x, box.y + 1, widgets.fit(string.format("Soll %.1f%%", rt.target or 0), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 2, widgets.fit(string.format("Ist %.1f%%", rt.actual_output or rt.output or 0), box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 3, widgets.pad("Modus", 8) .. widgets.fit(tostring(rt.mode or "-"), box.w - 8), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 4, widgets.pad("Betrieb", 8) .. widgets.fit(tostring(rt.assignment_state or "MASTER"), box.w - 8), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 5, widgets.fit("Workflow: " .. tostring(rt.assignment_reason or rt.assignment_state or "-"), box.w), colors.get("muted"), colors.get("background"))
  ui.progress(mon, box.x, box.y + 6, math.max(8, box.w), math.max(0, math.min(100, rt.actual_output or rt.output or 0)), rt.status or "OFFLINE")
  ui.text(mon, box.x, box.y + 7, widgets.fit("Letzter Sync: " .. tostring(rt.last_seen_age or "-") .. "s", box.w), colors.get("muted"), colors.get("background"))
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "MONITOR 2 - RT-FLOTTE", "OK")
  local summary = widgets.panel_box(mon, 2, 2, w - 2, 5, "RT-Uebersicht", "OK")
  widgets.status_badge(mon, summary.x, summary.y, tostring(model.rt_active or 0) .. " AKTIV", "OK", math.floor(summary.w * 0.20))
  widgets.status_badge(mon, summary.x + math.floor(summary.w * 0.23), summary.y, tostring(model.rt_startup or 0) .. " STARTUP", "LIMITED", math.floor(summary.w * 0.24))
  widgets.status_badge(mon, summary.x + math.floor(summary.w * 0.50), summary.y, tostring(model.rt_shutdown or 0) .. " SHUTDOWN", "OFFLINE", math.floor(summary.w * 0.24))
  widgets.status_badge(mon, summary.x + math.floor(summary.w * 0.76), summary.y, model.rt_global_off_hold and "GLOBAL HOLD AUS" or "GLOBAL HOLD", model.rt_global_off_hold and "OK" or "WARNING", math.floor(summary.w * 0.22))

  local queue_h = math.max(7, math.floor(h * 0.23))
  local cards_top = 8
  local cards_h = math.max(10, h - queue_h - cards_top - 1)
  local cols = (w >= 180 and 5) or (w >= 140 and 4) or (w >= 105 and 3) or 2
  local gap = 1
  local card_w = math.max(22, math.floor((w - 3 - ((cols - 1) * gap)) / cols))
  local rows = math.max(1, math.floor(cards_h / 11))
  for i, rt in ipairs(model.rt_nodes or {}) do
    local idx = i - 1
    local r = math.floor(idx / cols)
    if r >= rows then break end
    local c = idx % cols
    render_rt_card(mon, 2 + c * (card_w + gap), cards_top + r * 11, card_w, rt)
  end

  local queue = widgets.panel_box(mon, 2, h - queue_h, w - 2, queue_h, "Sequencer / Queue", "LIMITED")
  local rows_data = {}
  for i, q in ipairs(model.queue or {}) do
    if i > (queue.h) then break end
    rows_data[#rows_data + 1] = { text = widgets.fit(string.format("%d. RT-%s -> %s", i, tostring(q.node_id or "?"), tostring(q.module_id or q.action or "step")), queue.w), status = "LIMITED" }
  end
  if #rows_data == 0 then rows_data[1] = { text = "Queue leer - keine aktiven Sequenzen", status = "OFFLINE" } end
  ui.list(mon, queue.x, queue.y, queue.w, rows_data, { max_rows = queue.h })
end

return { render = render }
