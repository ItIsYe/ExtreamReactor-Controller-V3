local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function safe_section(mon, x, y, title, fn, on_error)
  local ok, err = pcall(fn)
  if not ok then
    ui.panel(mon, x, y, 30, 3, widgets.fit(title .. " Fehler", 24), "WARNING")
    ui.text(mon, x + 1, y + 1, widgets.fit(tostring(err), 28), colors.get("WARNING"), colors.get("background"))
    if on_error then on_error(title, err) end
  end
  return ok
end

local function render(mon, model)
  local section_errors = {}
  local key = utils.safe_serialize(model) or tostring(model)
  local unchanged = (cache[mon] == key)
  cache[mon] = key

  local w, h = ui.getSize(mon)
  local is_large = (w * h) >= 900 and w >= 48 and h >= 18
  ui.panel(mon, 1, 1, w, h, "MONITOR 1 - UEBERSICHT & STEUERUNG", model.system_status or "OK")

  local header_h = is_large and 9 or 8
  local header = widgets.panel_box(mon, 2, 2, w - 2, header_h, "Systemstatus", model.system_status or "OK")
  local top_badges = widgets.split_columns(header.w, is_large and { 2, 2, 2, 2, 2 } or { 3, 3, 2, 2 }, 1)
  local bx = header.x
  widgets.status_badge(mon, bx, header.y, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK", top_badges[1])
  bx = bx + top_badges[1] + 1
  widgets.status_badge(mon, bx, header.y, model.auto_profile and "AUTO AKTIV" or "AUTO AUS", model.auto_profile and "LIMITED" or "OFFLINE", top_badges[2])
  bx = bx + top_badges[2] + 1
  widgets.status_badge(mon, bx, header.y, tostring(model.rt_online or 0) .. " RT ONLINE", (model.rt_online or 0) > 0 and "OK" or "OFFLINE", top_badges[3])
  bx = bx + top_badges[3] + 1
  widgets.status_badge(mon, bx, header.y, tostring(model.nodes_total or 0) .. " NODES", (model.nodes_total or 0) > 0 and "LIMITED" or "OFFLINE", top_badges[4])
  if top_badges[5] then
    bx = bx + top_badges[4] + 1
    widgets.status_badge(mon, bx, header.y, model.rt_global_off_hold and "RT-HOLD" or "RT FREI", model.rt_global_off_hold and "WARNING" or "OK", top_badges[5])
  end

  local counts = model.alert_counts or {}
  ui.text(mon, header.x, header.y + 1, widgets.fit((counts.CRITICAL or 0) .. " KRIT | " .. (counts.WARN or 0) .. " WARN | " .. (counts.INFO or 0) .. " INFO", header.w - 14), colors.get("muted"), colors.get("background"))
  ui.text(mon, header.x + math.max(0, header.w - 12), header.y + 1, widgets.fit(tostring(model.clock_label or ""), 12), colors.get("muted"), colors.get("background"))
  ui.text(mon, header.x, header.y + 2, widgets.fit(tostring(model.peer_summary or "Peer-Lage unbekannt"), header.w), colors.get("text"), colors.get("background"))
  ui.text(mon, header.x, header.y + 3, widgets.fit(tostring(model.energy_hint or "Energy-Lage unbekannt"), header.w), colors.get("muted"), colors.get("background"))

  local content_top = 2 + header_h
  local bottom_h = is_large and math.max(13, math.floor(h * 0.40)) or math.max(9, math.floor(h * 0.30))
  local top_h = math.max(10, h - content_top - bottom_h)

  local top_cols = widgets.split_columns(w - 2, is_large and { 3, 2 } or { 3, 2 }, 1)
  local control_w = top_cols[1]
  local alert_w = top_cols[2]

  local hits = {}
  safe_section(mon, 2, content_top, "Steuerung", function()
    local box = widgets.panel_box(mon, 2, content_top, control_w, top_h, "Globale Steuerung / Aktionen", "OK")
    local controls_cols = widgets.split_columns(box.w, is_large and { 1, 1, 1 } or { 1, 1 }, 1)
    local profiles = model.profile_list or {}
    local row = 0
    local col = 0
    for _, profile in ipairs(profiles) do
      local active = model.active_profile == profile
      local px = box.x
      for k = 1, col do px = px + controls_cols[k] + 1 end
      local py = box.y + row
      local col_width = controls_cols[col + 1] or controls_cols[#controls_cols] or box.w
      local bw = widgets.status_badge(mon, px, py, profile, active and "OK" or "OFFLINE", col_width)
      hits[#hits + 1] = { type = "profile", name = profile, x1 = px, x2 = px + math.max(0, bw - 1), y = py }
      col = col + 1
      if col >= (is_large and 3 or 2) then
        col = 0
        row = row + 1
      end
      if box.y + row >= box.y + box.h - 5 then break end
    end

    local ctrl_y = math.min(box.y + box.h - 6, box.y + row + 1)
    ui.text(mon, box.x, ctrl_y - 1, widgets.fit("Direktsteuerung", box.w), colors.get("text"), colors.get("background"))
    local aw = widgets.status_badge(mon, box.x, ctrl_y, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE", math.max(8, math.floor(box.w * 0.18)))
    hits[#hits + 1] = { type = "auto", x1 = box.x, x2 = box.x + math.max(0, aw - 1), y = ctrl_y }
    local hw = widgets.status_badge(mon, box.x + aw + 2, ctrl_y, model.rt_global_off_hold and "RT-HOLD" or "RT-OFF", model.rt_global_off_hold and "WARNING" or "OFFLINE", math.max(10, math.floor(box.w * 0.26)))
    hits[#hits + 1] = { type = "rt_hold", x1 = box.x + aw + 2, x2 = box.x + aw + 2 + math.max(0, hw - 1), y = ctrl_y }
    ui.text(mon, box.x, ctrl_y + 1, widgets.fit("Soll " .. string.format("%.1f MRF/t", model.power_target or 0) .. " | Ist " .. string.format("%.1f MRF/t", model.power_actual or 0), box.w), colors.get("muted"), colors.get("background"))
    ui.text(mon, box.x, ctrl_y + 2, widgets.fit("Trefferzonen aktiv: Profile/AUTO/RT-HOLD direkt antippbar", box.w), colors.get("LIMITED"), colors.get("background"))
    ui.text(mon, box.x, ctrl_y + 3, widgets.fit("RT-Lage: " .. tostring(model.rt_summary or "-"), box.w), colors.get("muted"), colors.get("background"))
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2 + control_w + 1, content_top, "Meldungen", function()
    local status = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or ((counts.WARN or 0) > 0 and "WARNING" or "OK")
    local box = widgets.panel_box(mon, 2 + control_w + 1, content_top, alert_w, top_h, "Aktive Meldungen", status)
    local alerts = model.alert_rows or {}
    if #alerts == 0 then alerts = { { title = "System", text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
    local max_rows = math.max(1, box.h - 1)
    for i = 1, math.min(#alerts, max_rows) do widgets.alert_row(mon, box.x, box.y + i - 1, box.w, alerts[i], { compact = false }) end
    if #alerts < max_rows then
      ui.text(mon, box.x, box.y + box.h - 1, widgets.fit("Hinweis: keine weiteren Alerts aktiv", box.w), colors.get("muted"), colors.get("background"))
    end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  local bottom_y = content_top + top_h
  local bottom_cols = widgets.split_columns(w - 2, is_large and { 2, 3 } or { 2, 3 }, 1)
  local kpi_w = bottom_cols[1]
  local nodes_w = bottom_cols[2]

  safe_section(mon, 2, bottom_y, "KPI", function()
    local box = widgets.panel_box(mon, 2, bottom_y, kpi_w, bottom_h, "KPI / Betriebslage", "OK")
    local cws = widgets.split_columns(box.w, is_large and { 1, 1 } or { 1 }, 1)
    widgets.stat_card(mon, box.x, box.y, cws[1], "Leistung", string.format("Soll %.1f MRF/t", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", (model.power_target or 0) > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
    if cws[2] then
      local energy = model.energy_overview or {}
      widgets.stat_card(mon, box.x + cws[1] + 1, box.y, cws[2], "Energie", string.format("Fuellstand %.1f %%", energy.percent or 0), tostring(energy.trend or "Trend stabil"), energy.status or "OFFLINE", energy.percent or 0)
    end
    local stale_status = model.nodes_stale and model.nodes_stale > 0 and "WARNING" or "OK"
    widgets.stat_card(mon, box.x, box.y + 5, box.w, "Node Freshness", tostring(model.nodes_live or 0) .. " live", tostring(model.nodes_stale or 0) .. " stale", stale_status)
    ui.text(mon, box.x, box.y + 10, widgets.fit(tostring(model.rt_summary or "RT-Lage unbekannt"), box.w), colors.get("muted"), colors.get("background"))
    ui.text(mon, box.x, box.y + 11, widgets.fit(tostring(model.peer_summary or "Peer-Lage unbekannt"), box.w), colors.get("muted"), colors.get("background"))
    ui.text(mon, box.x, box.y + 12, widgets.fit("Energy: " .. tostring(model.energy_hint or "-") .. " | RT: " .. tostring(model.rt_summary or "-"), box.w), colors.get("text"), colors.get("background"))
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2 + kpi_w + 1, bottom_y, "Nodes", function()
    local box = widgets.panel_box(mon, 2 + kpi_w + 1, bottom_y, nodes_w, bottom_h, "Node-Status", model.nodes_stale and model.nodes_stale > 0 and "WARNING" or "OK")
    local widths = widgets.table_widths(box.w, is_large and { 7, 10, 10, 10, 8, 8, 14 } or { 6, 9, 9, 9, 7, 7, 11 })
    widgets.compact_header(mon, box.x, box.y, { "Node", "Rolle", "Status", "Mode", "Seen", "Fresh", "Hinweis" }, widths)
    local y = box.y + 1
    for _, n in ipairs(model.nodes or {}) do
      if y > (box.y + box.h - 1) then break end
      widgets.compact_status_row(mon, box.x, y, { tostring(n.id or "-"), tostring(n.role or "-"), tostring(n.status or "OFFLINE"), tostring(n.mode or "-"), tostring(n.last_seen_age or -1) .. "s", tostring(n.freshness or "-"), tostring(n.note or "-") }, widths, n.status or "OFFLINE", 3)
      y = y + 1
    end
    if y == box.y + 1 then ui.text(mon, box.x, y, "Keine Nodes verbunden", colors.get("OFFLINE"), colors.get("background")) end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2, bottom_y + bottom_h - 2, "Leitstand-Hinweise", function()
    local hints = model.ops_hints or {}
    if #hints > 0 then
      ui.text(mon, 2, bottom_y + bottom_h - 2, widgets.fit("Hinweise: " .. table.concat(hints, " | "), w - 4), colors.get("muted"), colors.get("background"))
    end
  end)

  if #section_errors > 0 then model.ui_errors = section_errors end
  hit_cache[mon] = hits
  model._overview_render_meta = { cache_unchanged = unchanged, rendered = true }
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    if y == hit.y and x >= hit.x1 and x <= hit.x2 then return hit end
  end
end

return { render = render, hit_test = hit_test }
