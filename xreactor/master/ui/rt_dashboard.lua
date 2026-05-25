local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function status_weight(status)
  local s = tostring(status or "OFFLINE"):upper()
  if s == "EMERGENCY" or s == "OFFLINE" then return 6 end
  if s == "WARNING" then return 5 end
  if s == "LIMITED" then return 4 end
  if s == "OK" then return 2 end
  return 3
end

local function first_number(...)
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    local n = tonumber(v)
    if n ~= nil then return n end
  end
  return 0
end

local function first_text(...)
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if v ~= nil and tostring(v) ~= "" and tostring(v) ~= "-" then return v end
  end
  return "-"
end

local function count_table(value)
  if type(value) ~= "table" then return 0 end
  if #value > 0 then return #value end
  local n = 0
  for _, _ in pairs(value) do n = n + 1 end
  return n
end

local function rt_setpoints(rt)
  return (rt and (rt.last_setpoints or rt.setpoints or rt.targets)) or {}
end

local function rt_target(rt)
  local sp = rt_setpoints(rt)
  return first_number(rt and rt.target, rt and rt.power_target, sp.power_target, sp.target, sp.output_target, 0)
end

local function rt_actual(rt)
  return first_number(rt and rt.actual_output, rt and rt.output, rt and rt.power_actual, rt and rt.energy_output, 0)
end

local function rt_state(rt)
  return first_text(rt and rt.state, rt and rt.node_state, rt and rt.status_state, "OFF")
end

local function rt_local_mode(rt)
  return first_text(rt and rt.local_mode, rt and rt.mode, rt and rt.control_mode, "-")
end

local function rt_hardware_summary(rt)
  local reactors = first_number(rt and rt.reactor_count, count_table(rt and rt.reactors), 0)
  local turbines = first_number(rt and rt.turbine_count, count_table(rt and rt.turbines), 0)
  local modules = first_number(rt and rt.module_count, count_table(rt and rt.modules), 0)
  local stable = first_number(rt and rt.modules_stable, 0)
  local limited = first_number(rt and rt.modules_limited, 0)
  return string.format("HW R:%d T:%d M:%d S:%d L:%d", reactors, turbines, modules, stable, limited)
end

local function rt_runtime_summary(rt)
  local rpm = first_number(rt and rt.turbine_rpm, rt and rt.rpm, 0)
  local steam = first_number(rt and rt.steam, 0)
  return string.format("RPM %.0f | Steam %.0f", rpm, steam)
end

local function rt_score(rt)
  local score = status_weight(rt and rt.status) * 1000
  local assignment = tostring(rt and rt.assignment_state or ""):upper()
  if assignment == "UNASSIGNED" then
    score = score + 700
  elseif assignment == "UNAVAILABLE" then
    score = score + 600
  elseif assignment ~= "ASSIGNED" then
    score = score + 450
  end
  if tostring(rt and rt.control_source or ""):upper() == "LOCAL" then
    score = score + 300
  end
  local age = tonumber(rt and rt.last_seen_age) or -1
  if age > 0 then
    score = score + math.min(age, 300)
  end
  local target = rt_target(rt)
  local actual = rt_actual(rt)
  score = score + math.min(200, math.abs(target - actual) * 5)
  return score
end

local function prioritized_rt_nodes(nodes)
  local list = {}
  for _, node in ipairs(nodes or {}) do
    list[#list + 1] = node
  end
  table.sort(list, function(a, b)
    local sa = rt_score(a)
    local sb = rt_score(b)
    if sa ~= sb then
      return sa > sb
    end
    return tostring(a and a.id or "") < tostring(b and b.id or "")
  end)
  return list
end

local function hidden_rt_summary(nodes)
  local stale, local_ctrl, unassigned = 0, 0, 0
  for _, rt in ipairs(nodes or {}) do
    if (tonumber(rt.last_seen_age) or -1) > 15 then stale = stale + 1 end
    if tostring(rt.control_source or ""):upper() == "LOCAL" then local_ctrl = local_ctrl + 1 end
    local assignment = tostring(rt.assignment_state or ""):upper()
    if assignment == "UNASSIGNED" or assignment == "UNAVAILABLE" then unassigned = unassigned + 1 end
  end
  return stale, local_ctrl, unassigned
end

local function render_rt_card(mon, x, y, w, rt)
  local node_id = tostring(rt.id or rt.node_id or "UNKNOWN")
  local box = widgets.panel_box(mon, x, y, w, 10, "RT-" .. node_id, rt.status or "OFFLINE")
  local target = rt_target(rt)
  local actual = rt_actual(rt)
  widgets.status_badge(mon, box.x + math.max(0, box.w - 10), box.y, tostring(rt_state(rt)), rt.status or "OFFLINE", 9)
  ui.text(mon, box.x, box.y + 1, widgets.fit(string.format("Soll %.1f%% | Ist %.1f%%", target, actual), box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 2, widgets.fit("State: " .. tostring(rt_state(rt)) .. " | Mode: " .. tostring(rt_local_mode(rt)), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 3, widgets.fit(rt_hardware_summary(rt), box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 4, widgets.fit(rt_runtime_summary(rt), box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 5, widgets.fit("Seen " .. tostring(rt.last_seen_age or "-") .. "s | " .. tostring(rt.assignment_state or "-"), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 6, widgets.fit("Source: " .. tostring(rt.control_source or "-") .. " | " .. tostring(rt.display_mode or "-"), box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 7, widgets.fit("Queue: " .. tostring(rt.queue_state or "idle") .. " | " .. tostring(rt.queue_step or "-"), box.w), colors.get("muted"), colors.get("background"))
  ui.progress(mon, box.x, box.y + 8, math.max(8, box.w), math.max(0, math.min(100, actual)) / 100, rt.status or "OFFLINE")
end

local function render_overflow_card(mon, x, y, w, hidden_nodes)
  local box = widgets.panel_box(mon, x, y, w, 10, "Weitere RT", (#hidden_nodes > 0) and "LIMITED" or "OK")
  local hidden = #hidden_nodes
  local stale, local_ctrl, unassigned = hidden_rt_summary(hidden_nodes)
  ui.text(mon, box.x, box.y, widgets.fit("+" .. tostring(hidden) .. " weitere RT-Nodes", box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 1, widgets.fit("Anzeige priorisiert Problemknoten", box.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, box.x, box.y + 3, widgets.fit("Stale: " .. tostring(stale), box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 4, widgets.fit("Local Ctrl: " .. tostring(local_ctrl), box.w), colors.get("text"), colors.get("background"))
  ui.text(mon, box.x, box.y + 5, widgets.fit("Offen/Unavailable: " .. tostring(unassigned), box.w), colors.get("text"), colors.get("background"))
  if hidden_nodes[1] then
    ui.text(mon, box.x, box.y + 7, widgets.fit("Top hidden: RT-" .. tostring(hidden_nodes[1].id or "?"), box.w), colors.get("muted"), colors.get("background"))
    ui.text(mon, box.x, box.y + 8, widgets.fit(tostring(hidden_nodes[1].assignment_reason or "-"), box.w), colors.get("muted"), colors.get("background"))
  end
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local is_large = (w * h) >= 900 and w >= 48 and h >= 18
  ui.panel(mon, 1, 1, w, h, "RT", "OK")

  local summary_h = is_large and 8 or 7
  local summary = widgets.panel_box(mon, 2, 2, w - 2, summary_h, "RT-Flotte", "OK")
  local badge_cols = widgets.split_columns(summary.w, is_large and { 2, 2, 2, 2 } or { 2, 2, 2, 2 }, 1)
  local sx = summary.x
  widgets.status_badge(mon, sx, summary.y, tostring(model.rt_active or 0) .. " AKTIV", "OK", badge_cols[1])
  sx = sx + badge_cols[1] + 1
  widgets.status_badge(mon, sx, summary.y, tostring(model.assigned or 0) .. " ASSIGN", (model.unassigned or 0) > 0 and "WARNING" or "OK", badge_cols[2])
  sx = sx + badge_cols[2] + 1
  widgets.status_badge(mon, sx, summary.y, tostring(model.master_control or 0) .. " MASTER", "LIMITED", badge_cols[3])
  sx = sx + badge_cols[3] + 1
  widgets.status_badge(mon, sx, summary.y, model.rt_global_off_hold and "RT HOLD" or "RT FREI", model.rt_global_off_hold and "WARNING" or "OK", badge_cols[4])
  ui.text(mon, summary.x, summary.y + 1, widgets.fit("Fleet: " .. tostring(model.fleet_summary or "-"), summary.w), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 2, widgets.fit("Queue: " .. tostring(model.queue_summary or "-"), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 3, widgets.fit("Assignment " .. tostring(model.assignment_state or "-") .. " | Grund " .. tostring(model.assignment_reason or "-"), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 4, widgets.fit("Mode " .. tostring(model.display_mode or "-") .. " | Local " .. tostring(model.local_control or 0) .. " | Master " .. tostring(model.master_control or 0), summary.w), colors.get("muted"), colors.get("background"))

  local queue_h = is_large and 7 or 6
  local cards_top = 2 + summary_h + 1
  local cards_h = math.max(10, h - queue_h - cards_top - 1)
  local cols = (w >= 140) and 3 or 2
  local gap = 1
  local card_w = math.max(24, math.floor((w - 3 - ((cols - 1) * gap)) / cols))
  local rows = math.max(1, math.floor(cards_h / 11))
  local capacity = math.max(1, cols * rows)

  local ordered = prioritized_rt_nodes(model.rt_nodes or {})
  local overflow = #ordered > capacity
  local visible_count = overflow and math.max(1, capacity - 1) or math.min(#ordered, capacity)

  local drawn = 0
  for i = 1, visible_count do
    local idx = i - 1
    local r = math.floor(idx / cols)
    local c = idx % cols
    render_rt_card(mon, 2 + c * (card_w + gap), cards_top + r * 11, card_w, ordered[i])
    drawn = drawn + 1
  end

  if #ordered == 0 then
    render_rt_card(mon, 2, cards_top, math.max(24, card_w), {
      id = "NO-RT",
      status = "OFFLINE",
      state = "IDLE",
      assignment_state = tostring(model.assignment_state or "UNASSIGNED"),
      assignment_reason = tostring(model.assignment_reason or "Keine RT-Nodes sichtbar"),
      control_source = tostring(model.control_source or "LOCAL"),
      display_mode = tostring(model.display_mode or "RT-Hauptansicht aktiv"),
      queue_state = "idle",
      queue_step = "-",
      node_mode = "-",
      last_seen_age = "-",
      output = 0
    })
  elseif overflow then
    local hidden_nodes = {}
    for i = visible_count + 1, #ordered do
      hidden_nodes[#hidden_nodes + 1] = ordered[i]
    end
    local idx = drawn
    local r = math.floor(idx / cols)
    local c = idx % cols
    render_overflow_card(mon, 2 + c * (card_w + gap), cards_top + r * 11, card_w, hidden_nodes)
  end

  local queue = widgets.panel_box(mon, 2, h - queue_h, w - 2, queue_h, "Sequencer / Queue", "LIMITED")
  local rows_data = {}
  for i, q in ipairs(model.queue or {}) do
    if i > math.max(1, queue.h - 1) then break end
    rows_data[#rows_data + 1] = {
      text = widgets.fit(string.format("%d. RT-%s -> %s (%s)", i, tostring(q.node_id or "?"), tostring(q.module_id or q.action or "step"), tostring(q.state or "pending")), queue.w),
      status = "LIMITED"
    }
  end
  if #rows_data == 0 then
    rows_data[1] = { text = "Queue leer - keine aktiven Sequenzen", status = "OFFLINE" }
  end
  ui.list(mon, queue.x, queue.y, queue.w, rows_data, { max_rows = queue.h })
end

return { render = render }
