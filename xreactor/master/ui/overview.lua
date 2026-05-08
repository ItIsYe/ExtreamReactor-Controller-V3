local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function render_status_line(mon, w, model)
  ui.panel(mon, 2, 2, w - 2, 4, "Systemstatus", model.system_status or "OK")
  local counts = model.alert_counts or {}
  ui.badge(mon, 3, 3, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK")
  ui.badge(mon, 21, 3, model.auto_profile and "AUTO AKTIV" or "AUTO AUS", model.auto_profile and "LIMITED" or "OFFLINE")
  ui.badge(mon, 35, 3, tostring(model.rt_online or 0) .. " RT ONLINE", (model.rt_online or 0) > 0 and "OK" or "OFFLINE")
  ui.badge(mon, 3, 4, tostring(counts.CRITICAL or 0) .. " KRIT", (counts.CRITICAL or 0) > 0 and "EMERGENCY" or "OFFLINE")
  ui.badge(mon, 13, 4, tostring(counts.WARN or 0) .. " WARN", (counts.WARN or 0) > 0 and "WARNING" or "OFFLINE")
  ui.text(mon, math.max(2, w - 10), 4, tostring(model.clock_label or ""), colors.get("muted"), colors.get("background"))
end

local function render_controls(mon, w, model)
  ui.panel(mon, 2, 7, w - 2, 4, "Globale Steuerung", "OK")
  local hits, x = {}, 3
  for _, profile in ipairs(model.profile_list or {}) do
    local active = model.active_profile == profile
    ui.badge(mon, x, 8, profile, active and "OK" or "OFFLINE")
    hits[#hits + 1] = { type = "profile", name = profile, x1 = x, x2 = x + #profile + 1, y = 8 }
    x = x + #profile + 3
  end
  ui.badge(mon, x, 8, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE")
  hits[#hits + 1] = { type = "auto", x1 = x, x2 = x + 5, y = 8 }
  x = x + 7
  local rt_label = model.rt_global_off_hold and "RT-HOLD" or "RT-OFF"
  ui.badge(mon, x, 8, rt_label, model.rt_global_off_hold and "WARNING" or "OFFLINE")
  hits[#hits + 1] = { type = "rt_hold", x1 = x, x2 = x + #rt_label + 1, y = 8 }
  ui.text(mon, 3, 10, "Immer sichtbar: Profile, Auto-Modus, globaler RT-Off/Hold", colors.get("muted"), colors.get("background"))
  return hits
end

local function render_alerts(mon, w, model)
  local counts = model.alert_counts or {}
  local alerts = model.alert_rows or {}
  local status = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or ((counts.WARN or 0) > 0 and "WARNING" or "OK")
  ui.panel(mon, 2, 12, w - 2, 6, "Aktive Meldungen", status)
  if #alerts == 0 then alerts = { { title = "System", text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
  for i = 1, math.min(#alerts, 3) do
    local a = alerts[i]
    ui.badge(mon, 3, 12 + i, tostring(a.status or "INFO"), tostring(a.status or "INFO"))
    ui.text(mon, 12, 12 + i, tostring(a.title or "Alert"), colors.get("text"), colors.get("background"))
    ui.text(mon, 27, 12 + i, tostring(a.text or ""), colors.get("muted"), colors.get("background"))
  end
end

local function render_kpi(mon, w, model)
  local half = math.floor((w - 6) / 2)
  local energy = model.energy_overview or {}
  ui.panel(mon, 2, 19, w - 2, 5, "KPI", "OK")
  widgets.stat_card(mon, 3, 20, half - 1, "Leistung", string.format("Soll %.1f MRF/t", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", model.power_target and model.power_target > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
  widgets.stat_card(mon, 3 + half, 20, half - 1, "Energie", string.format("Fuellstand %.1f %%", energy.percent or 0), tostring(energy.trend or "Trend stabil"), energy.status or "OFFLINE", energy.percent or 0)
end

local function render_nodes(mon, w, h, model)
  ui.panel(mon, 2, 25, w - 2, h - 25, "Node-Status", "OK")
  local widths = { 6, 8, 8, 8, 8, 22 }
  widgets.compact_header(mon, 3, 26, { "Node", "Rolle", "Status", "Mode", "Zuletzt", "Hinweis" }, widths)
  local y = 27
  for _, n in ipairs(model.nodes or {}) do
    if y > h - 2 then break end
    widgets.compact_status_row(mon, 3, y, {
      tostring(n.id or "-"), tostring(n.role or "-"), tostring(n.status or "OFFLINE"), tostring(n.mode or "-"), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-")
    }, widths, n.status or "OFFLINE")
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
