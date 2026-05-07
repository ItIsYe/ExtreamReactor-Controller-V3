local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function render_status_line(mon, w, model)
  ui.panel(mon, 2, 2, w - 2, 4, "Systemstatus", model.system_status or "OK")
  ui.badge(mon, 4, 3, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK")
  ui.badge(mon, 22, 3, (model.auto_profile and "AUTO AKTIV" or "AUTO AUS"), model.auto_profile and "LIMITED" or "OFFLINE")
  ui.badge(mon, 36, 3, tostring(model.rt_online or 0) .. " RT ONLINE", (model.rt_online or 0) > 0 and "OK" or "OFFLINE")

  local counts = model.alert_counts or {}
  local warn = counts.WARN or 0
  local crit = counts.CRITICAL or 0
  ui.badge(mon, 4, 4, tostring(warn) .. " WARN", warn > 0 and "WARNING" or "OFFLINE")
  ui.badge(mon, 15, 4, tostring(crit) .. " KRIT", crit > 0 and "EMERGENCY" or "OFFLINE")
  ui.text(mon, math.max(2, w - 10), 4, tostring(model.clock_label or ""), colors.get("muted"), colors.get("background"))
end

local function render_controls(mon, w, model)
  ui.panel(mon, 2, 7, w - 2, 4, "Globale Steuerung", "OK")
  local hits, x = {}, 4
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
  ui.text(mon, 4, 10, "Profile, Auto-Modus und globales RT-Off/Hold", colors.get("muted"), colors.get("background"))
  return hits
end

local function render_alerts(mon, w, model)
  ui.panel(mon, 2, 12, w - 2, 6, "Aktive Meldungen", "WARNING")
  local alerts = model.alert_rows or {}
  if #alerts == 0 then alerts = { { text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
  for i, a in ipairs(alerts) do
    if i > 4 then break end
    ui.badge(mon, 3, 12 + i, tostring(a.status or "INFO"), tostring(a.status or "INFO"))
    ui.text(mon, 11, 12 + i, tostring(a.text or ""), colors.get("text"), colors.get("background"))
  end
end

local function render_kpi(mon, w, model)
  ui.panel(mon, 2, 19, w - 2, 5, "KPI", "OK")
  local half = math.floor((w - 6) / 2)
  local energy = model.energy_overview or {}

  widgets.stat_card(mon, 3, 20, half - 1, "Leistung", string.format("Soll %.1f MRF/t", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", model.power_target and model.power_target > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
  widgets.stat_card(mon, 3 + half, 20, half - 1, "Energie", string.format("%.1f %%", energy.percent or 0), tostring(energy.trend or "Trend stabil"), energy.status or "OFFLINE", energy.percent or 0)
end

local function render_nodes(mon, w, h, model)
  ui.panel(mon, 2, 25, w - 2, h - 25, "Node-Status", "OK")
  widgets.compact_row(mon, 3, 26, { "Node", "Rolle", "Status", "Mode", "Zuletzt", "Hinweis" }, { "muted", "muted", "muted", "muted", "muted", "muted" })

  local rows = {}
  for i, n in ipairs(model.nodes or {}) do
    if i > math.max(1, h - 30) then break end
    rows[#rows + 1] = {
      text = string.format("%s %-9s %-8s %-8s %ss %s", tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.mode or "-"), tostring(n.last_seen_age or -1), tostring(n.note or "")),
      status = n.status or "OFFLINE"
    }
  end
  if #rows == 0 then rows[1] = { text = "Keine Nodes verbunden", status = "OFFLINE" } end
  ui.list(mon, 3, 27, w - 4, rows, { max_rows = h - 28 })
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
    if y == hit.y and x >= hit.x1 and x <= hit.x2 then
      return hit
    end
  end
end

return { render = render, hit_test = hit_test }
