local mux = require("core.mockup_ui")

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

local function fmt_rf(value)
  local n = tonumber(value)
  if not n then return "-" end
  local abs = math.abs(n)
  if abs >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if abs >= 1000 then return string.format("%.1fk", n / 1000) end
  return string.format("%.1f", n)
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
  return string.format("R:%d T:%d M:%d S:%d L:%d", reactors, turbines, modules, stable, limited)
end

local function rt_runtime_summary(rt)
  local rpm = first_number(rt and rt.turbine_rpm, rt and rt.rpm, 0)
  local steam = first_number(rt and rt.steam, 0)
  return string.format("RPM %.0f | Steam %.0f", rpm, steam)
end

local function rt_score(rt)
  local score = status_weight(rt and rt.status) * 1000
  local assignment = tostring(rt and rt.assignment_state or ""):upper()
  if assignment == "UNASSIGNED" then score = score + 700
  elseif assignment == "UNAVAILABLE" then score = score + 600
  elseif assignment ~= "ASSIGNED" then score = score + 450 end
  if tostring(rt and rt.control_source or ""):upper() == "LOCAL" then score = score + 300 end
  local age = tonumber(rt and rt.last_seen_age) or -1
  if age > 0 then score = score + math.min(age, 300) end
  local target, actual = rt_target(rt), rt_actual(rt)
  score = score + math.min(200, math.abs(target - actual) * 5)
  return score
end

local function prioritized_rt_nodes(nodes)
  local list = {}
  for _, node in ipairs(nodes or {}) do list[#list + 1] = node end
  table.sort(list, function(a, b)
    local sa, sb = rt_score(a), rt_score(b)
    if sa ~= sb then return sa > sb end
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

-- Fix (2026-06-30): siehe historische Doku — mehrere rt_node-Felder traten
-- vereinzelt als Tabelle statt String auf ("Queue: table: 0x..."-Bug).
-- Diese Hilfsfunktion bleibt als defensive Absicherung erhalten.
local function safe_text(value, fallback)
  if type(value) == "string" or type(value) == "number" then
    return tostring(value)
  end
  return fallback or "-"
end

local function shutdown_verdict(rt)
  local stage = tostring(first_text(rt and rt.shutdown_stage))
  local outcome = tostring(first_text(rt and rt.shutdown_outcome))
  local reason = tostring(first_text(rt and rt.shutdown_reason))
  if outcome == "SUCCESS" or stage == "COMPLETED" or reason == "SUCCESS_COMPLETED" then
    return "SD:OK"
  end
  if outcome == "FAILED" or stage == "FAILED" or reason:find("FAILED_", 1, true) == 1 then
    local detail = reason ~= "-" and reason or (stage ~= "-" and stage or outcome)
    return "SD:FAIL " .. safe_text(detail, "?"):sub(1, 18)
  end
  if outcome == "CANCELLED" or stage == "CANCELLED_DEMAND_RECOVERED" or reason == "CANCELLED_DEMAND_RECOVERED" then
    return "SD:CANCELLED"
  end
  if stage ~= "-" then return "SD:" .. safe_text(stage, "-"):sub(1, 18) end
  return "SD:-"
end

local function render_rt_card(mon, x, y, w, rt, hits)
  local node_id = safe_text(rt.id or rt.node_id, "UNKNOWN")
  local maintenance = rt.maintenance_mode == true
  local status_key = maintenance and "LIMITED" or (rt.status or "OFFLINE")
  local h = 10

  mux.card(mon, x, y, w, h, { title = "RT-" .. node_id .. (maintenance and " [WARTUNG]" or ""), status = status_key, icon = "reactor" })
  -- Titelzeile als Touch-Zone fuer Wartungsmodus-Toggle registrieren.
  if hits and rt.id and rt.id ~= "NO-RT" then
    hits[#hits + 1] = { type = "maintenance_toggle", node_id = rt.id, x1 = x, x2 = x + math.max(0, w - 1), y1 = y, y2 = y }
  end

  local target, actual = rt_target(rt), rt_actual(rt)
  local bx, by, bw = x + 2, y + 1, w - 4
  mux.data_row(mon, bx, by, bw, { label = "SOLL/IST", value = fmt_rf(target) .. " / " .. fmt_rf(actual) .. " RF/t", status = status_key })
  mux.data_row(mon, bx, by + 1, bw, { label = "STATE", value = safe_text(rt_state(rt)) .. " | " .. safe_text(rt_local_mode(rt)), status = "muted" })
  mux.data_row(mon, bx, by + 2, bw, { label = "HW", value = rt_hardware_summary(rt), status = "text" })
  mux.data_row(mon, bx, by + 3, bw, { label = "RUN", value = rt_runtime_summary(rt), status = "text" })
  mux.data_row(mon, bx, by + 4, bw, { label = "SEEN", value = tostring(rt.last_seen_age or "-") .. "s | " .. safe_text(rt.assignment_state, "-"), status = "muted" })
  mux.data_row(mon, bx, by + 5, bw, { label = "SRC", value = safe_text(rt.control_source, "-") .. " | " .. safe_text(rt.display_mode, "-"), status = "muted" })
  mux.data_row(mon, bx, by + 6, bw, { label = "QUEUE / SD", value = safe_text(rt.queue_state, "idle") .. " | " .. safe_text(rt.queue_step, "-") .. " | " .. shutdown_verdict(rt), status = "muted" })
  -- actual is a raw RF/t figure (often in the thousands) -- clamping it to
  -- [0,100] before dividing by 100 always saturated the bar near 100%.
  -- Show output relative to the node's learned capacity (falling back to
  -- its current target when capacity isn't known yet), same convention as
  -- nodes/rt/mockup_pages.lua's own capacity-relative progress bar.
  local capacity = first_number(rt and rt.capacity_max, target, 0)
  local output_ratio = capacity > 0 and math.max(0, math.min(1, actual / capacity)) or 0
  mux.outlined_progress(mon, bx, by + 7, bw, output_ratio, status_key, nil)
end

local function render_overflow_card(mon, x, y, w, hidden_nodes)
  local h = 10
  mux.card(mon, x, y, w, h, { title = "Weitere RT", status = (#hidden_nodes > 0) and "LIMITED" or "OK", icon = "reactor" })
  local stale, local_ctrl, unassigned = hidden_rt_summary(hidden_nodes)
  local bx, by, bw = x + 2, y + 1, w - 4
  mux.data_row(mon, bx, by, bw, { label = "VERSTECKT", value = "+" .. tostring(#hidden_nodes) .. " RT-Nodes", status = "text" })
  mux.data_row(mon, bx, by + 2, bw, { label = "STALE", value = tostring(stale), status = "text" })
  mux.data_row(mon, bx, by + 3, bw, { label = "LOCAL CTRL", value = tostring(local_ctrl), status = "text" })
  mux.data_row(mon, bx, by + 4, bw, { label = "OFFEN", value = tostring(unassigned), status = "text" })
  if hidden_nodes[1] then
    mux.data_row(mon, bx, by + 6, bw, { label = "TOP", value = "RT-" .. tostring(hidden_nodes[1].id or "?"), status = "muted" })
    mux.data_row(mon, bx, by + 7, bw, { label = "GRUND", value = tostring(hidden_nodes[1].assignment_reason or "-"), status = "muted" })
  end
end

local hit_cache = setmetatable({}, { __mode = "k" })

local function render(mon, model)
  local w, h = mon.getSize()
  mux.clear(mon)
  local hold_status = model.rt_global_off_hold and "WARNING" or "OK"
  mux.header(mon, { title = "RT FLEET", page = "FLEET STATUS", status = (model.unassigned or 0) > 0 and "WARNING" or "OK", icon = "reactor" })
  local hits = {}

  mux.status_dot(mon, 2, 3, tostring(model.rt_active or 0) .. " AKTIV", "OK")
  if w >= 30 then mux.status_dot(mon, math.floor(w * 0.28), 3, tostring(model.assigned or 0) .. " ASSIGN", (model.unassigned or 0) > 0 and "WARNING" or "OK") end
  if w >= 46 then mux.status_dot(mon, math.floor(w * 0.50), 3, tostring(model.master_control or 0) .. " MASTER", "LIMITED") end
  if w >= 62 then mux.status_dot(mon, math.floor(w * 0.72), 3, model.rt_global_off_hold and "RT HOLD" or "RT FREI", hold_status) end

  local summary_top = 5
  mux.section(mon, 2, summary_top, w - 3, "RT-FLOTTE", "OK", "reactor")
  mux.data_row(mon, 2, summary_top + 2, w - 3, { label = "FLEET", value = tostring(model.fleet_summary or "-"), status = "text" })
  mux.data_row(mon, 2, summary_top + 3, w - 3, { label = "QUEUE", value = tostring(model.queue_summary or "-"), status = "muted" })
  mux.data_row(mon, 2, summary_top + 4, w - 3, { label = "ASSIGN", value = tostring(model.assignment_state or "-") .. " | " .. tostring(model.assignment_reason or "-"), status = "muted" })
  mux.data_row(mon, 2, summary_top + 5, w - 3, { label = "MODE", value = tostring(model.display_mode or "-") .. " | Local " .. tostring(model.local_control or 0) .. " | Master " .. tostring(model.master_control or 0), status = "muted" })
  if h >= 24 then
    mux.data_row(mon, 2, summary_top + 6, w - 3, { label = "HINWEIS", value = "Kartentitel antippen = Wartungsmodus", status = "muted" })
  end

  local queue_h = h >= 30 and 6 or 5
  local cards_top = summary_top + 8
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
    render_rt_card(mon, 2 + c * (card_w + gap), cards_top + r * 11, card_w, ordered[i], hits)
    drawn = drawn + 1
  end

  if #ordered == 0 then
    render_rt_card(mon, 2, cards_top, math.max(24, card_w), {
      id = "NO-RT", status = "OFFLINE", state = "IDLE",
      assignment_state = tostring(model.assignment_state or "UNASSIGNED"),
      assignment_reason = tostring(model.assignment_reason or "Keine RT-Nodes sichtbar"),
      control_source = tostring(model.control_source or "LOCAL"),
      display_mode = tostring(model.display_mode or "RT-Hauptansicht aktiv"),
      queue_state = "idle", queue_step = "-", node_mode = "-",
      last_seen_age = "-", output = 0
    })
  elseif overflow then
    local hidden_nodes = {}
    for i = visible_count + 1, #ordered do hidden_nodes[#hidden_nodes + 1] = ordered[i] end
    local idx = drawn
    local r = math.floor(idx / cols)
    local c = idx % cols
    render_overflow_card(mon, 2 + c * (card_w + gap), cards_top + r * 11, card_w, hidden_nodes)
  end

  local queue_y = h - queue_h
  mux.section(mon, 2, queue_y, w - 3, "SEQUENCER / QUEUE", "LIMITED", "network")
  local y = queue_y + 2
  local max_rows = math.max(1, queue_h - 2)
  local shown = 0
  for i, q in ipairs(model.queue or {}) do
    if shown >= max_rows then break end
    -- Fix (2026-06-30): q.node_id kann in der Praxis vereinzelt eine
    -- Tabelle statt String sein — defensive Absicherung bleibt erhalten.
    local node_id_display
    if type(q.node_id) == "string" or type(q.node_id) == "number" then
      node_id_display = tostring(q.node_id)
    else
      node_id_display = "?"
    end
    mux.data_row(mon, 2, y, w - 3, {
      label = string.format("%d. RT-%s", i, node_id_display),
      value = tostring(q.module_id or q.action or "step") .. " (" .. tostring(q.state or "pending") .. ")",
      status = "LIMITED",
    })
    y = y + 1
    shown = shown + 1
  end
  if shown == 0 then
    mux.data_row(mon, 2, y, w - 3, { label = "QUEUE", value = "leer - keine aktiven Sequenzen", status = "muted" })
  end

  hit_cache[mon] = hits
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    local y1 = hit.y1 or hit.y
    local y2 = hit.y2 or hit.y
    if y >= y1 and y <= y2 and x >= hit.x1 and x <= hit.x2 then
      return hit
    end
  end
end

return { render = render, hit_test = hit_test }
