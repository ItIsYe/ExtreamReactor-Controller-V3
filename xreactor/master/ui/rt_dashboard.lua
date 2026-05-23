local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function render_rt_card(mon, x, y, w, rt)
  local node_id = tostring(rt.id or rt.node_id or "UNKNOWN")
  local box = widgets.panel_box(mon, x, y, w, 13, "RT-" .. node_id, rt.status or "OFFLINE")
  widgets.status_badge(mon, box.x + math.max(0, box.w - 10), box.y, tostring(rt.state or "OFF"), rt.status or "OFFLINE", 9)
  ui.text(mon, box.x, box.y + 1, widgets.fit(string.format("Soll %.1f%%", rt.target or 0), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 2, widgets.fit(string.format("Ist %.1f%%", rt.actual_output or rt.output or 0), box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 3, widgets.pad("Node", 9) .. widgets.fit(tostring(rt.node_mode or rt.mode or "-") .. " | ID " .. node_id, box.w - 9), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 4, widgets.pad("Master", 9) .. widgets.fit(tostring(rt.display_mode or "-") .. " | Quelle " .. tostring(rt.control_source or "-"), box.w - 9), colors.get("text"), colors.get("background"))
  local assign = tostring(rt.assignment_state or "-")
  local control = tostring(rt.control_source or "-")
  local sem = (assign == "UNASSIGNED" and control == "LOCAL") and "(autonom/fallback ohne Master-Zuordnung)" or ""
  ui.text(mon, box.x, box.y + 5, widgets.fit("Zuordnung: " .. assign .. " | " .. tostring(rt.assignment_reason or "-"), box.w), colors.get("muted"), colors.get("background"))
  local sem_note = ""
  if assign == "ASSIGNED" and control == "LOCAL" then sem_note = " (Abweichung: assigned aber lokal)" end
  if assign == "UNASSIGNED" and control == "MASTER" then sem_note = " (Abweichung: unassigned aber master)" end
  ui.text(mon, box.x, box.y + 6, widgets.fit("Steuerquelle: " .. tostring(rt.control_source or "-") .. sem_note .. " " .. sem, box.w), colors.get("muted"), colors.get("background"))
  ui.progress(mon, box.x, box.y + 7, math.max(8, box.w), math.max(0, math.min(100, rt.actual_output or rt.output or 0)) / 100, rt.status or "OFFLINE")
  ui.text(mon, box.x, box.y + 8, widgets.fit("Sync: " .. tostring(rt.last_seen_age or "-") .. "s | " .. tostring(rt.freshness or "-"), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 9, widgets.fit("Node: " .. tostring(rt.node_status or rt.status or "-") .. " | Mode: " .. tostring(rt.node_mode or rt.mode or "-"), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 10, widgets.fit("Queue: " .. tostring(rt.queue_state or "idle") .. " | Step: " .. tostring(rt.queue_step or "-") .. " | Fresh " .. tostring(rt.freshness or "-"), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 11, widgets.fit("Master-Lage: Assignment=" .. tostring(rt.assignment_state or "-") .. " / Control=" .. tostring(rt.control_source or "-"), box.w), colors.get("muted"), colors.get("background"))
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local is_large = (w * h) >= 900 and w >= 48 and h >= 18
  ui.panel(mon, 1, 1, w, h, "MONITOR 2 - RT-FLOTTE", "OK")
  local summary = widgets.panel_box(mon, 2, 2, w - 2, is_large and 9 or 8, "RT-Uebersicht", "OK")
  local badge_cols = widgets.split_columns(summary.w, is_large and { 2, 2, 2, 2, 3 } or { 2, 2, 2, 2, 2 }, 1)
  local sx = summary.x
  widgets.status_badge(mon, sx, summary.y, tostring(model.rt_active or 0) .. " AKTIV", "OK", badge_cols[1])
  sx = sx + badge_cols[1] + 1
  widgets.status_badge(mon, sx, summary.y, tostring(model.rt_startup or 0) .. " STARTUP", "LIMITED", badge_cols[2])
  sx = sx + badge_cols[2] + 1
  widgets.status_badge(mon, sx, summary.y, tostring(model.rt_shutdown or 0) .. " SHUTDOWN", "OFFLINE", badge_cols[3])
  sx = sx + badge_cols[3] + 1
  widgets.status_badge(mon, sx, summary.y, tostring(model.rt_stale or 0) .. " STALE", (model.rt_stale or 0) > 0 and "WARNING" or "OK", badge_cols[4])
  sx = sx + badge_cols[4] + 1
  widgets.status_badge(mon, sx, summary.y, model.rt_global_off_hold and "GLOBAL HOLD AUS" or "GLOBAL HOLD", model.rt_global_off_hold and "OK" or "WARNING", badge_cols[5])
  ui.text(mon, summary.x, summary.y + 1, widgets.fit("Klarlage: Node-Modus vs Zuordnung vs Steuerquelle getrennt dargestellt", summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 2, widgets.fit("Assigned " .. tostring(model.assigned or 0) .. " | Unassigned " .. tostring(model.unassigned or 0) .. " | Master " .. tostring(model.master_control or 0) .. " | Local " .. tostring(model.local_control or 0), summary.w), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 3, widgets.fit("Fleet: " .. tostring(model.fleet_summary or "-") .. " | Queue: " .. tostring(model.queue_summary or "-"), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 4, widgets.fit("Assignment " .. tostring(model.assignment_state or "-") .. " | Grund " .. tostring(model.assignment_reason or "-") .. " | Quelle " .. tostring(model.control_source or "-"), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 5, widgets.fit("Master-Mapping: assigned=" .. tostring(model.assigned or 0) .. " unassigned=" .. tostring(model.unassigned or 0) .. " unavailable=" .. tostring(model.unavailable or 0), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 6, widgets.fit("Display " .. tostring(model.display_mode or "-") .. " | Fleet " .. tostring(model.fleet_summary or "-"), summary.w), colors.get("muted"), colors.get("background"))

  local queue_h = is_large and math.max(14, math.floor(h * 0.34)) or math.max(10, math.floor(h * 0.28))
  local cards_top = is_large and 11 or 10
  local cards_h = math.max(12, h - queue_h - cards_top)
  local cols = is_large and ((w >= 150 and 4) or 3) or ((w >= 180 and 4) or (w >= 136 and 3) or 2)
  local gap = 1
  local card_w = math.max(30, math.floor((w - 3 - ((cols - 1) * gap)) / cols))
  local rows = math.max(1, math.floor(cards_h / 14))
  local drawn = 0
  for i, rt in ipairs(model.rt_nodes or {}) do
    local idx = i - 1
    local r = math.floor(idx / cols)
    if r >= rows then break end
    local c = idx % cols
    render_rt_card(mon, 2 + c * (card_w + gap), cards_top + r * 14, card_w, rt)
    drawn = drawn + 1
  end

  if drawn == 0 then
    render_rt_card(mon, 2, cards_top, math.max(30, card_w), { id = "NO-RT", status = "OFFLINE", state = "IDLE", assignment_state = tostring(model.assignment_state or "UNASSIGNED"), assignment_reason = tostring(model.assignment_reason or "Keine RT-Nodes sichtbar"), control_source = tostring(model.control_source or "LOCAL"), display_mode = tostring(model.display_mode or "RT-Hauptansicht aktiv"), queue_state = "idle", queue_step = "-", freshness = "n/a", node_mode = "-", node_status = "OFFLINE" })
  end

  local queue = widgets.panel_box(mon, 2, h - queue_h + 1, w - 2, queue_h, "Sequencer / Queue", "LIMITED")
  local rows_data = {}
  for i, q in ipairs(model.queue or {}) do
    if i > queue.h then break end
    rows_data[#rows_data + 1] = { text = widgets.fit(string.format("%d. RT-%s -> %s (%s)", i, tostring(q.node_id or "?"), tostring(q.module_id or q.action or "step"), tostring(q.state or "pending")), queue.w), status = "LIMITED" }
  end
  if #rows_data == 0 then rows_data[1] = { text = "Queue leer - keine aktiven Sequenzen", status = "OFFLINE" } end
  ui.list(mon, queue.x, queue.y, queue.w, rows_data, { max_rows = queue.h })
end

return { render = render }
