local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function safe_section(mon, x, y, title, fn, on_error)
  local ok, err = pcall(fn)
  if not ok then
    ui.panel(mon, x, y, 30, 4, widgets.fit(title .. " Fehler", 24), "WARNING")
    ui.text(mon, x + 2, y + 1, widgets.fit(tostring(err), 26), colors.get("WARNING"), colors.get("background"))
    if on_error then on_error(title, err) end
  end
  return ok
end

local function status_weight(status)
  local s = tostring(status or "OFFLINE"):upper()
  if s == "EMERGENCY" or s == "OFFLINE" then return 5 end
  if s == "WARNING" then return 4 end
  if s == "LIMITED" then return 3 end
  if s == "OK" then return 1 end
  return 2
end

local function node_score(node)
  local score = status_weight(node and node.status) * 1000
  local freshness = tostring(node and node.freshness or ""):lower()
  if freshness == "stale" then
    score = score + 500
  end
  local age = tonumber(node and node.last_seen_age) or -1
  if age > 0 then
    score = score + math.min(age, 300)
  end
  return score
end

local function prioritized_nodes(nodes)
  local list = {}
  for _, node in ipairs(nodes or {}) do
    list[#list + 1] = node
  end
  table.sort(list, function(a, b)
    local sa = node_score(a)
    local sb = node_score(b)
    if sa ~= sb then
      return sa > sb
    end
    return tostring(a and a.id or "") < tostring(b and b.id or "")
  end)
  return list
end

local function render(mon, model)
  local section_errors = {}
  local key = utils.safe_serialize(model) or tostring(model)
  local unchanged = (cache[mon] == key)
  cache[mon] = key

  local w, h = ui.getSize(mon)
  local is_large = (w * h) >= 900 and w >= 48 and h >= 18
  ui.panel(mon, 1, 1, w, h, "OVERVIEW", model.system_status or "OK")

  local header_h = is_large and 7 or 6
  local header = widgets.panel_box(mon, 2, 2, w - 2, header_h, "Systemlage", model.system_status or "OK")
  local badge_cols = widgets.split_columns(header.w, is_large and { 2, 2, 2, 2, 2 } or { 2, 2, 2, 2 }, 1)
  local bx = header.x
  widgets.status_badge(mon, bx, header.y, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK", badge_cols[1])
  bx = bx + badge_cols[1] + 1
  widgets.status_badge(mon, bx, header.y, model.auto_profile and "AUTO AN" or "AUTO AUS", model.auto_profile and "LIMITED" or "OFFLINE", badge_cols[2])
  bx = bx + badge_cols[2] + 1
  widgets.status_badge(mon, bx, header.y, tostring(model.rt_online or 0) .. " RT", (model.rt_online or 0) > 0 and "OK" or "OFFLINE", badge_cols[3])
  bx = bx + badge_cols[3] + 1
  widgets.status_badge(mon, bx, header.y, tostring(model.nodes_live or 0) .. "/" .. tostring(model.nodes_total or 0) .. " LIVE", (model.nodes_stale or 0) > 0 and "WARNING" or "OK", badge_cols[4])
  if badge_cols[5] then
    bx = bx + badge_cols[4] + 1
    widgets.status_badge(mon, bx, header.y, model.rt_global_off_hold and "RT HOLD" or "RT FREI", model.rt_global_off_hold and "WARNING" or "OK", badge_cols[5])
  end
  ui.text(mon, header.x, header.y + 1, widgets.fit(tostring(model.system_status_line or "Statuslage unbekannt"), header.w), colors.get("text"), colors.get("background"))
  ui.text(mon, header.x, header.y + 2, widgets.fit(tostring(model.peer_summary or "Peers unbekannt"), header.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, header.x, header.y + 3, widgets.fit("Energie: " .. tostring(model.energy_hint or "-"), header.w), colors.get("muted"), colors.get("background"))
  ui.rightText(mon, header.x, header.y + 4, header.w, widgets.fit(tostring(model.clock_label or ""), 14), colors.get("muted"), colors.get("background"))

  local content_top = 2 + header_h + 1
  local top_h = is_large and 10 or 9
  local bottom_y = content_top + top_h + 1
  local bottom_h = math.max(8, h - bottom_y - 1)
  local cols = widgets.split_columns(w - 2, { 3, 2 }, 1)
  local left_w, right_w = cols[1], cols[2]

  local hits = {}

  safe_section(mon, 2, content_top, "Steuerung", function()
    local box = widgets.panel_box(mon, 2, content_top, left_w, top_h, "Steuerung", "OK")
    local profile_cols = widgets.split_columns(box.w, is_large and { 1, 1, 1 } or { 1, 1 }, 1)
    local profiles = model.profile_list or {}
    local row, col = 0, 0
    for _, profile in ipairs(profiles) do
      local px = box.x
      for i = 1, col do
        px = px + profile_cols[i] + 1
      end
      local py = box.y + row
      local active = model.active_profile == profile
      local bw = widgets.status_badge(mon, px, py, profile, active and "OK" or "OFFLINE", profile_cols[col + 1] or profile_cols[#profile_cols] or box.w)
      hits[#hits + 1] = { type = "profile", name = profile, x1 = px, x2 = px + math.max(0, bw - 1), y1 = py, y2 = py }
      col = col + 1
      if col >= #profile_cols then
        col = 0
        row = row + 1
      end
      if row >= 2 then break end
    end

    local action_y = box.y + 3
    local auto_w = math.max(10, math.floor(box.w * 0.28))
    local hold_w = math.max(12, math.floor(box.w * 0.34))
    local aw = widgets.status_badge(mon, box.x, action_y, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE", auto_w)
    hits[#hits + 1] = { type = "auto", x1 = box.x, x2 = box.x + math.max(0, aw - 1), y1 = action_y, y2 = action_y }
    local hx = box.x + auto_w + 2
    local hw = widgets.status_badge(mon, hx, action_y, model.rt_global_off_hold and "RT-HOLD" or "RT-OFF", model.rt_global_off_hold and "WARNING" or "OFFLINE", hold_w)
    hits[#hits + 1] = { type = "rt_hold", x1 = hx, x2 = hx + math.max(0, hw - 1), y1 = action_y, y2 = action_y }

    ui.text(mon, box.x, box.y + 5, widgets.fit("Profil " .. tostring(model.active_profile or "-") .. " | " .. tostring(model.controls_summary or "-"), box.w), colors.get("text"), colors.get("background"))
    ui.text(mon, box.x, box.y + 6, widgets.fit(string.format("Soll %.1f | Ist %.1f MRF/t", model.power_target or 0, model.power_actual or 0), box.w), colors.get("muted"), colors.get("background"))
    ui.text(mon, box.x, box.y + 7, widgets.fit(string.format("Nodes %d live / %d stale | RT %d online", model.nodes_live or 0, model.nodes_stale or 0, model.rt_online or 0), box.w), colors.get("text"), colors.get("background"))
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2 + left_w + 1, content_top, "Meldungen", function()
    local counts = model.alert_counts or {}
    local severity = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or (((counts.WARN or 0) > 0) and "WARNING" or "OK")
    local box = widgets.panel_box(mon, 2 + left_w + 1, content_top, right_w, top_h, "Meldungen", severity)
    ui.text(mon, box.x, box.y, widgets.fit(string.format("C:%d  W:%d  I:%d", counts.CRITICAL or 0, counts.WARN or 0, counts.INFO or 0), box.w), colors.get("text"), colors.get("background"))
    local alerts = model.alert_rows or {}
    if #alerts == 0 then
      alerts = { { title = "System", text = model.alert_summary or "Keine aktiven Meldungen", status = "OK" } }
    end
    local max_rows = math.max(1, box.h - 3)
    for i = 1, math.min(#alerts, max_rows) do
      widgets.alert_row(mon, box.x, box.y + i, box.w, alerts[i], { compact = true })
    end
    ui.text(mon, box.x, box.y + box.h - 1, widgets.fit("Summary: " .. tostring(model.alert_summary or "-"), box.w), colors.get("muted"), colors.get("background"))
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2, bottom_y, "Kennzahlen", function()
    local box = widgets.panel_box(mon, 2, bottom_y, left_w, bottom_h, "Kennzahlen", "OK")
    widgets.stat_card(mon, box.x, box.y, box.w, "Leistung", string.format("Soll %.1f", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", (model.power_target or 0) > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
    local energy = model.energy_overview or {}
    widgets.stat_card(mon, box.x, box.y + 6, box.w, "Energie", string.format("%.1f %%", energy.percent or 0), tostring(energy.trend or "Trend stabil"), energy.status or "OFFLINE", energy.percent or 0)
    local fresh_status = (model.nodes_stale or 0) > 0 and "WARNING" or "OK"
    widgets.stat_card(mon, box.x, box.y + 12, box.w, "Node Freshness", tostring(model.nodes_live or 0) .. " live", tostring(model.nodes_stale or 0) .. " stale", fresh_status)
    local hints = model.ops_hints or {}
    if hints[1] then
      ui.text(mon, box.x, box.y + math.max(0, box.h - 2), widgets.fit("Hinweis: " .. tostring(hints[1]), box.w), colors.get("muted"), colors.get("background"))
    end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2 + left_w + 1, bottom_y, "Nodes", function()
    local box = widgets.panel_box(mon, 2 + left_w + 1, bottom_y, right_w, bottom_h, "Top-Nodes", (model.nodes_stale or 0) > 0 and "WARNING" or "OK")
    local widths = widgets.table_widths(box.w, is_large and { 8, 9, 9, 7, 10 } or { 7, 8, 8, 6, 9 })
    widgets.compact_header(mon, box.x, box.y, { "Node", "Rolle", "Status", "Seen", "Hinweis" }, widths)
    local ordered = prioritized_nodes(model.nodes or {})
    local row_slots = math.max(1, box.h - 1)
    local overflow = #ordered > row_slots
    local show_count = overflow and math.max(1, row_slots - 1) or row_slots
    local y = box.y + 1
    for i = 1, math.min(#ordered, show_count) do
      local n = ordered[i]
      widgets.compact_status_row(mon, box.x, y, {
        tostring(n.id or "-"),
        tostring(n.role or "-"),
        tostring(n.status or "OFFLINE"),
        tostring(n.last_seen_age or -1) .. "s",
        tostring(n.note or "-")
      }, widths, n.status or "OFFLINE", 3)
      y = y + 1
    end
    if #ordered == 0 then
      ui.text(mon, box.x, y, "Keine Nodes sichtbar", colors.get("OFFLINE"), colors.get("background"))
    elseif overflow then
      local hidden = #ordered - show_count
      ui.text(mon, box.x, y, widgets.fit("+" .. tostring(hidden) .. " weitere Nodes - nur kritischste angezeigt", box.w), colors.get("muted"), colors.get("background"))
    end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  if #section_errors > 0 then model.ui_errors = section_errors end
  hit_cache[mon] = hits
  model._overview_render_meta = { cache_unchanged = unchanged, rendered = true }
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
