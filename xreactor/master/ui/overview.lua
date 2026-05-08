local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function render_status_line(mon, w, model)
  ui.panel(mon, 2, 2, w - 2, 4, "Systemstatus", model.system_status or "OK")
  local counts = model.alert_counts or {}
  local x = 3
  x = x + widgets.status_badge(mon, x, 3, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK", 15) + 1
  x = x + widgets.status_badge(mon, x, 3, model.auto_profile and "AUTO AKTIV" or "AUTO AUS", model.auto_profile and "LIMITED" or "OFFLINE", 11) + 1
  x = x + widgets.status_badge(mon, x, 3, tostring(model.rt_online or 0) .. " RT ONLINE", (model.rt_online or 0) > 0 and "OK" or "OFFLINE", 11) + 1
  widgets.status_badge(mon, x, 3, tostring(counts.CRITICAL or 0) .. " KRIT", (counts.CRITICAL or 0) > 0 and "EMERGENCY" or "OFFLINE", 8)
  widgets.status_badge(mon, 3, 4, tostring(counts.WARN or 0) .. " WARNUNG", (counts.WARN or 0) > 0 and "WARNING" or "OFFLINE", 11)
  ui.text(mon, math.max(2, w - 12), 4, widgets.fit(tostring(model.clock_label or ""), 10), colors.get("muted"), colors.get("background"))
end

local function render_controls(mon, w, model)
  ui.panel(mon, 2, 7, w - 2, 4, "Globale Steuerung", "OK")
  local hits, x = {}, 3
  for _, profile in ipairs(model.profile_list or {}) do
    local active = model.active_profile == profile
    local bw = widgets.status_badge(mon, x, 8, profile, active and "OK" or "OFFLINE", 9)
    hits[#hits + 1] = { type = "profile", name = profile, x1 = x, x2 = x + bw, y = 8 }
    x = x + bw + 1
  end
  local auto_w = widgets.status_badge(mon, x, 8, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE", 6)
  hits[#hits + 1] = { type = "auto", x1 = x, x2 = x + auto_w, y = 8 }
  x = x + auto_w + 1
  local rt_label = model.rt_global_off_hold and "RT-HOLD" or "RT-OFF"
  local hold_w = widgets.status_badge(mon, x, 8, rt_label, model.rt_global_off_hold and "WARNING" or "OFFLINE", 8)
  hits[#hits + 1] = { type = "rt_hold", x1 = x, x2 = x + hold_w, y = 8 }
  ui.text(mon, 3, 10, "Profile, Auto-Modus und globaler RT-Off/Hold", colors.get("muted"), colors.get("background"))
  return hits
end

local function render_alerts(mon, w, model)
  local counts = model.alert_counts or {}
  local alerts = model.alert_rows or {}
  local status = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or ((counts.WARN or 0) > 0 and "WARNING" or "OK")
  ui.panel(mon, 2, 12, w - 2, 6, "Aktive Meldungen", status)
  if #alerts == 0 then alerts = { { title = "System", text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
  for i = 1, math.min(#alerts, 3) do widgets.alert_row(mon, 3, 12 + i, w - 6, alerts[i], { compact = false }) end
end

local function render_kpi(mon, w, model)
  local half = math.floor((w - 6) / 2)
  local energy = model.energy_overview or {}
  ui.panel(mon, 2, 19, w - 2, 5, "KPI", "OK")
  widgets.stat_card(mon, 3, 20, half - 1, "Leistung", string.format("Soll %.1f MRF/t", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", model.power_target and model.power_target > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
  widgets.stat_card(mon, 3 + half, 20, half - 1, "Energie", string.format("Fuellstand %.1f %%", energy.percent or 0), widgets.fit(tostring(energy.trend or "Trend stabil"), half - 4), energy.status or "OFFLINE", energy.percent or 0)
end

local function render_nodes(mon, w, h, model)
  ui.panel(mon, 2, 25, w - 2, h - 25, "Node-Status", "OK")
  local note_w = math.max(16, w - 42)
  local widths = { 6, 8, 8, 8, 8, note_w }
  widgets.compact_header(mon, 3, 26, { "Node", "Rolle", "Status", "Mode", "Zuletzt", "Hinweis" }, widths)
  local y = 27
  for _, n in ipairs(model.nodes or {}) do
    if y > h - 2 then break end
    widgets.compact_status_row(mon, 3, y, { tostring(n.id or "-"), tostring(n.role or "-"), tostring(n.status or "OFFLINE"), tostring(n.mode or "-"), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-") }, widths, n.status or "OFFLINE", 3)
    y = y + 1
  end
  if y == 27 then ui.text(mon, 3, 27, "Keine Nodes verbunden", colors.get("OFFLINE"), colors.get("background")) end
end

local function render(mon, model)
  local key = utils.safe_serialize(model) or tostring(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "MONITOR 1 - UEBERSICHT & STEUERUNG", model.system_status or "OK")
  render_status_line(mon, w, model)
  hit_cache[mon] = render_controls(mon, w, model)
  render_alerts(mon, w, model)
  render_kpi(mon, w, model)
  render_nodes(mon, w, h, model)
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    if y == hit.y and x >= hit.x1 and x <= hit.x2 then return hit end
  end
end

return { render = render, hit_test = hit_test }
