local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function safe(fn)
  local ok, err = pcall(fn)
  return ok, err
end

local function safe_section(mon, x, y, label, fn)
  local ok, err = safe(fn)
  if not ok then
    ui.text(mon, x, y, widgets.fit(label .. " Fehler: " .. tostring(err), 48), colors.get("WARNING"), colors.get("background"))
  end
  return ok
end

local function render_status_line(mon, w, model)
  ui.panel(mon, 2, 2, w - 2, 4, "Systemstatus", model.system_status or "OK")
  local counts = model.alert_counts or {}
  local x = 3
  x = x + widgets.status_badge(mon, x, 3, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK", math.floor(w * 0.18)) + 1
  x = x + widgets.status_badge(mon, x, 3, model.auto_profile and "AUTO AKTIV" or "AUTO AUS", model.auto_profile and "LIMITED" or "OFFLINE", math.floor(w * 0.14)) + 1
  x = x + widgets.status_badge(mon, x, 3, tostring(model.rt_online or 0) .. " RT ONLINE", (model.rt_online or 0) > 0 and "OK" or "OFFLINE", math.floor(w * 0.14)) + 1
  widgets.status_badge(mon, x, 3, tostring(counts.CRITICAL or 0) .. " KRIT", (counts.CRITICAL or 0) > 0 and "EMERGENCY" or "OFFLINE", 10)
  widgets.status_badge(mon, 3, 4, tostring(counts.WARN or 0) .. " WARNUNG", (counts.WARN or 0) > 0 and "WARNING" or "OFFLINE", 14)
  ui.text(mon, math.max(2, w - 12), 4, widgets.fit(tostring(model.clock_label or ""), 10), colors.get("muted"), colors.get("background"))
end

local function render(mon, model)
  local key = utils.safe_serialize(model) or tostring(model)
  if cache[mon] == key then return end
  cache[mon] = key

  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "MONITOR 1 - UEBERSICHT & STEUERUNG", model.system_status or "OK")

  local ok, err = safe(function() render_status_line(mon, w, model) end)
  if not ok then ui.text(mon, 3, 3, "Statusbereich Fehler: " .. tostring(err), colors.get("WARNING"), colors.get("background")) end

  local top_y = 7
  local usable_w = math.max(30, w - 2)
  local left_w = math.max(28, math.floor((usable_w - 3) * 0.58))
  local right_w = math.max(24, usable_w - left_w - 1)

  local control_hits = {}
  ok = safe(function()
    ui.panel(mon, 2, top_y, left_w, 5, "Globale Steuerung", "OK")
    local x = 3
    for _, profile in ipairs(model.profile_list or {}) do
      local active = model.active_profile == profile
      local bw = widgets.status_badge(mon, x, top_y + 1, profile, active and "OK" or "OFFLINE", 12)
      control_hits[#control_hits + 1] = { type = "profile", name = profile, x1 = x, x2 = x + bw, y = top_y + 1 }
      x = x + bw + 1
    end
    local auto_w = widgets.status_badge(mon, x, top_y + 1, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE", 7)
    control_hits[#control_hits + 1] = { type = "auto", x1 = x, x2 = x + auto_w, y = top_y + 1 }
    x = x + auto_w + 1
    local hold_w = widgets.status_badge(mon, x, top_y + 1, model.rt_global_off_hold and "RT-HOLD" or "RT-OFF", model.rt_global_off_hold and "WARNING" or "OFFLINE", 10)
    control_hits[#control_hits + 1] = { type = "rt_hold", x1 = x, x2 = x + hold_w, y = top_y + 1 }
    ui.text(mon, 3, top_y + 3, widgets.fit("Profile, Auto-Modus und globaler RT-Off/Hold", left_w - 2), colors.get("muted"), colors.get("background"))
  end)
  if not ok then ui.text(mon, 3, top_y + 1, "Steuerung Fehler", colors.get("WARNING"), colors.get("background")) end

  safe_section(mon, 4 + left_w, top_y + 1, "Alerts", function()
    local counts = model.alert_counts or {}
    local alerts = model.alert_rows or {}
    local status = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or ((counts.WARN or 0) > 0 and "WARNING" or "OK")
    ui.panel(mon, 3 + left_w, top_y, right_w, 8, "Aktive Meldungen", status)
    if #alerts == 0 then alerts = { { title = "System", text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
    for i = 1, math.min(#alerts, 4) do widgets.alert_row(mon, 4 + left_w, top_y + i, right_w - 3, alerts[i], { compact = true }) end
  end)

  local kpi_y = top_y + 9
  safe_section(mon, 3, kpi_y + 1, "KPI", function()
    local energy = model.energy_overview or {}
    ui.panel(mon, 2, kpi_y, w - 2, 6, "KPI", "OK")
    local half = math.floor((w - 6) / 2)
    widgets.stat_card(mon, 3, kpi_y + 1, half - 1, "Leistung", string.format("Soll %.1f MRF/t", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", model.power_target and model.power_target > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
    widgets.stat_card(mon, 3 + half, kpi_y + 1, half - 1, "Energie", string.format("Fuellstand %.1f %%", energy.percent or 0), tostring(energy.trend or "Trend stabil"), energy.status or "OFFLINE", energy.percent or 0)
  end)

  safe_section(mon, 3, kpi_y + 8, "Nodes", function()
    local node_y = kpi_y + 7
    ui.panel(mon, 2, node_y, w - 2, math.max(4, h - node_y), "Node-Status", "OK")
    local note_w = math.max(10, w - 48)
    local widths = { 6, 10, 10, 10, 8, note_w }
    widgets.compact_header(mon, 3, node_y + 1, { "Node", "Rolle", "Status", "Mode", "Seen", "Hinweis" }, widths)
    local y = node_y + 2
    for _, n in ipairs(model.nodes or {}) do
      if y > h - 1 then break end
      widgets.compact_status_row(mon, 3, y, { tostring(n.id or "-"), tostring(n.role or "-"), tostring(n.status or "OFFLINE"), tostring(n.mode or "-"), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-") }, widths, n.status or "OFFLINE", 3)
      y = y + 1
    end
    if y == node_y + 2 then ui.text(mon, 3, y, "Keine Nodes verbunden", colors.get("OFFLINE"), colors.get("background")) end
  end)

  hit_cache[mon] = control_hits
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    if y == hit.y and x >= hit.x1 and x <= hit.x2 then return hit end
  end
end

return { render = render, hit_test = hit_test }
