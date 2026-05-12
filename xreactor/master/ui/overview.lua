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
  ui.panel(mon, 1, 1, w, h, "MONITOR 1 - UEBERSICHT & STEUERUNG", model.system_status or "OK")

  local header_h = 6
  local header = widgets.panel_box(mon, 2, 2, w - 2, header_h, "Systemstatus", model.system_status or "OK")
  local hx = header.x
  hx = hx + widgets.status_badge(mon, hx, header.y, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK", math.floor(header.w * 0.26)) + 1
  hx = hx + widgets.status_badge(mon, hx, header.y, model.auto_profile and "AUTO AKTIV" or "AUTO AUS", model.auto_profile and "LIMITED" or "OFFLINE", math.floor(header.w * 0.20)) + 1
  hx = hx + widgets.status_badge(mon, hx, header.y, tostring(model.rt_online or 0) .. " RT ONLINE", (model.rt_online or 0) > 0 and "OK" or "OFFLINE", math.floor(header.w * 0.20)) + 1
  widgets.status_badge(mon, hx, header.y, tostring(model.nodes_total or 0) .. " NODES", (model.nodes_total or 0) > 0 and "LIMITED" or "OFFLINE", math.floor(header.w * 0.18))
  local counts = model.alert_counts or {}
  ui.text(mon, header.x, header.y + 1, widgets.fit((counts.CRITICAL or 0) .. " KRIT | " .. (counts.WARN or 0) .. " WARN | " .. (counts.INFO or 0) .. " INFO", header.w - 14), colors.get("muted"), colors.get("background"))
  ui.text(mon, header.x + math.max(0, header.w - 12), header.y + 1, widgets.fit(tostring(model.clock_label or ""), 12), colors.get("muted"), colors.get("background"))
  ui.text(mon, header.x, header.y + 2, widgets.fit(tostring(model.peer_summary or "Peer-Lage unbekannt"), header.w), colors.get("text"), colors.get("background"))

  local row2_y = 2 + header_h
  local row2_h = math.max(9, math.floor(h * 0.24))
  local cols = widgets.split_columns(w - 2, { 3, 2 }, 1)
  local left_w = cols[1]
  local right_w = cols[2]

  local hits = {}
  safe_section(mon, 2, row2_y, "Steuerung", function()
    local box = widgets.panel_box(mon, 2, row2_y, left_w, row2_h, "Globale Steuerung", "OK")
    local bx = box.x
    for _, profile in ipairs(model.profile_list or {}) do
      local active = model.active_profile == profile
      local bw = widgets.status_badge(mon, bx, box.y, profile, active and "OK" or "OFFLINE", math.max(10, math.floor(box.w * 0.18)))
      hits[#hits + 1] = { type = "profile", name = profile, x1 = bx, x2 = bx + bw, y = box.y }
      bx = bx + bw + 1
    end
    local aw = widgets.status_badge(mon, box.x, box.y + 2, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE", 8)
    hits[#hits + 1] = { type = "auto", x1 = box.x, x2 = box.x + aw, y = box.y + 2 }
    local hw = widgets.status_badge(mon, box.x + aw + 2, box.y + 2, model.rt_global_off_hold and "RT-HOLD" or "RT-OFF", model.rt_global_off_hold and "WARNING" or "OFFLINE", 12)
    hits[#hits + 1] = { type = "rt_hold", x1 = box.x + aw + 2, x2 = box.x + aw + 2 + hw, y = box.y + 2 }
    ui.text(mon, box.x, box.y + 4, widgets.fit("Soll " .. string.format("%.1f MRF/t", model.power_target or 0) .. " | Ist " .. string.format("%.1f MRF/t", model.power_actual or 0), box.w), colors.get("muted"), colors.get("background"))
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2 + left_w + 1, row2_y, "Meldungen", function()
    local status = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or ((counts.WARN or 0) > 0 and "WARNING" or "OK")
    local box = widgets.panel_box(mon, 2 + left_w + 1, row2_y, right_w, row2_h, "Aktive Meldungen", status)
    local alerts = model.alert_rows or {}
    if #alerts == 0 then alerts = { { title = "System", text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
    for i = 1, math.min(#alerts, box.h) do widgets.alert_row(mon, box.x, box.y + i - 1, box.w, alerts[i], { compact = false }) end
    if #alerts < box.h then
      ui.text(mon, box.x, box.y + box.h - 1, widgets.fit("Hinweis: keine weiteren Alerts aktiv", box.w), colors.get("muted"), colors.get("background"))
    end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  local kpi_y = row2_y + row2_h
  safe_section(mon, 2, kpi_y, "KPI", function()
    local box = widgets.panel_box(mon, 2, kpi_y, w - 2, 8, "KPI / Betriebslage", "OK")
    local cws = widgets.columns_from_width(box.w)
    widgets.stat_card(mon, box.x, box.y, cws[1], "Leistung", string.format("Soll %.1f MRF/t", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", (model.power_target or 0) > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
    if cws[2] then
      local energy = model.energy_overview or {}
      widgets.stat_card(mon, box.x + cws[1] + 1, box.y, cws[2], "Energie", string.format("Fuellstand %.1f %%", energy.percent or 0), tostring(energy.trend or "Trend stabil"), energy.status or "OFFLINE", energy.percent or 0)
    end
    if cws[3] then
      widgets.stat_card(mon, box.x + cws[1] + cws[2] + 2, box.y, cws[3], "Node Freshness", tostring(model.nodes_live or 0) .. " live", tostring(model.nodes_stale or 0) .. " stale", model.nodes_stale and model.nodes_stale > 0 and "WARNING" or "OK")
    end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2, kpi_y + 8, "Nodes", function()
    local panel_h = math.max(8, h - (kpi_y + 8) + 1)
    local box = widgets.panel_box(mon, 2, kpi_y + 8, w - 2, panel_h, "Node-Status", model.nodes_stale and model.nodes_stale > 0 and "WARNING" or "OK")
    local widths = widgets.table_widths(box.w, { 7, 10, 10, 10, 8, 8, 12 })
    widgets.compact_header(mon, box.x, box.y, { "Node", "Rolle", "Status", "Mode", "Seen", "Fresh", "Hinweis" }, widths)
    local y = box.y + 1
    for _, n in ipairs(model.nodes or {}) do
      if y > (box.y + box.h - 1) then break end
      widgets.compact_status_row(mon, box.x, y, { tostring(n.id or "-"), tostring(n.role or "-"), tostring(n.status or "OFFLINE"), tostring(n.mode or "-"), tostring(n.last_seen_age or -1) .. "s", tostring(n.freshness or "-"), tostring(n.note or "-") }, widths, n.status or "OFFLINE", 3)
      y = y + 1
    end
    if y == box.y + 1 then ui.text(mon, box.x, y, "Keine Nodes verbunden", colors.get("OFFLINE"), colors.get("background")) end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

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
