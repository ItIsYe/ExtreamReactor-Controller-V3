local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function render_status_line(mon, w, model)
  ui.panel(mon, 2, 2, w - 2, 3, "Systemstatus", model.system_status or "OK")
  ui.badge(mon, 4, 3, tostring(model.system_status or "OK"), model.system_status or "OK")
  local counts = model.alert_counts or {}
  ui.badge(mon, 20, 3, "RT " .. tostring(model.rt_online or 0), "OK")
  ui.badge(mon, 29, 3, "WARN " .. tostring(counts.WARN or 0), (counts.WARN or 0) > 0 and "WARNING" or "OFFLINE")
  ui.badge(mon, 40, 3, "KRIT " .. tostring(counts.CRITICAL or 0), (counts.CRITICAL or 0) > 0 and "EMERGENCY" or "OFFLINE")
end

local function render_controls(mon, model)
  ui.panel(mon, 2, 6, 48, 4, "Globale Steuerung", "OK")
  local hits, x = {}, 4
  for _, profile in ipairs(model.profile_list or {}) do
    local active = model.active_profile == profile
    ui.badge(mon, x, 7, profile, active and "OK" or "OFFLINE")
    hits[#hits + 1] = { type = "profile", name = profile, x1 = x, x2 = x + #profile + 1, y = 7 }
    x = x + #profile + 3
  end
  ui.badge(mon, x, 7, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE")
  hits[#hits + 1] = { type = "auto", x1 = x, x2 = x + 5, y = 7 }
  x = x + 7
  local rt_label = model.rt_global_off_hold and "RT-HOLD" or "RT-OFF"
  ui.badge(mon, x, 7, rt_label, model.rt_global_off_hold and "WARNING" or "OFFLINE")
  hits[#hits + 1] = { type = "rt_hold", x1 = x, x2 = x + #rt_label + 1, y = 7 }
  return hits
end

local function render(mon, model)
  local key = utils.safe_serialize(model) or tostring(model)
  if cache[mon] == key then return end
  cache[mon] = key

  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "MONITOR 1 - UEBERSICHT & STEUERUNG", model.system_status or "OK")
  render_status_line(mon, w, model)
  hit_cache[mon] = render_controls(mon, model)

  ui.panel(mon, 2, 11, w - 2, 5, "Aktive Meldungen", "WARNING")
  local alerts = model.alert_rows or {}
  if #alerts == 0 then alerts = { { text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
  ui.list(mon, 3, 12, w - 4, alerts, { max_rows = 3 })


  ui.panel(mon, 2, 17, w - 2, 4, "KPI", "OK")
  local energy = model.energy_overview or {}
  local half = math.floor((w - 6) / 2)
  widgets.kpi_tile(mon, 3, 18, half - 1, "Leistung", string.format("Soll %.1f", model.power_target or 0), "MRF/t", "LIMITED")
  widgets.kpi_tile(mon, 3 + half, 18, half - 1, "Energie", string.format("%.1f%%", energy.percent or 0), tostring(energy.status or "OFFLINE"), energy.status or "OFFLINE")

  ui.panel(mon, 2, 22, w - 2, h - 22, "Node-Status", "OK")

  local rows = {}
  for i, n in ipairs(model.nodes or {}) do
    if i > math.max(1, h - 20) then break end
    rows[#rows + 1] = {
      text = string.format("%s %-8s %-7s %-8s %ss", tostring(n.id), tostring(n.role), tostring(n.status), tostring(n.mode or "-"), tostring(n.last_seen_age or -1)),
      status = n.status or "OFFLINE"
    }
  end
  ui.list(mon, 3, 18, w - 4, rows, { max_rows = h - 20 })
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    if y == hit.y and x >= hit.x1 and x <= hit.x2 then
      return hit
    end
  end
end

return { render = render, hit_test = hit_test }
