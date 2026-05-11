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
  if cache[mon] == key then return end
  cache[mon] = key

  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "MONITOR 1 - UEBERSICHT & STEUERUNG", model.system_status or "OK")

  local inner = widgets.panel_box(mon, 2, 2, w - 2, 5, "Systemstatus", model.system_status or "OK")
  local x = inner.x
  x = x + widgets.status_badge(mon, x, inner.y, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK", math.floor(inner.w * 0.30)) + 1
  x = x + widgets.status_badge(mon, x, inner.y, model.auto_profile and "AUTO AKTIV" or "AUTO AUS", model.auto_profile and "LIMITED" or "OFFLINE", math.floor(inner.w * 0.22)) + 1
  widgets.status_badge(mon, x, inner.y, tostring(model.rt_online or 0) .. " RT ONLINE", (model.rt_online or 0) > 0 and "OK" or "OFFLINE", math.floor(inner.w * 0.22))
  local counts = model.alert_counts or {}
  ui.text(mon, inner.x, inner.y + 1, widgets.fit((counts.CRITICAL or 0) .. " KRIT  |  " .. (counts.WARN or 0) .. " WARN", inner.w - 12), colors.get("muted"), colors.get("background"))
  ui.text(mon, inner.x + inner.w - 10, inner.y + 1, widgets.fit(tostring(model.clock_label or ""), 10), colors.get("muted"), colors.get("background"))

  local left_w = math.max(34, math.floor((w - 4) * 0.60))
  local right_w = math.max(24, (w - 3) - left_w)
  local controls_h = 7
  local alerts_h = 9

  local hits = {}
  safe_section(mon, 2, 8, "Steuerung", function()
    local box = widgets.panel_box(mon, 2, 8, left_w, controls_h, "Globale Steuerung", "OK")
    local bx = box.x
    for _, profile in ipairs(model.profile_list or {}) do
      local active = model.active_profile == profile
      local bw = widgets.status_badge(mon, bx, box.y, profile, active and "OK" or "OFFLINE", 12)
      hits[#hits + 1] = { type = "profile", name = profile, x1 = bx, x2 = bx + bw, y = box.y }
      bx = bx + bw + 1
    end
    local aw = widgets.status_badge(mon, bx, box.y, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE", 7)
    hits[#hits + 1] = { type = "auto", x1 = bx, x2 = bx + aw, y = box.y }
    bx = bx + aw + 1
    local hw = widgets.status_badge(mon, bx, box.y, model.rt_global_off_hold and "RT-HOLD" or "RT-OFF", model.rt_global_off_hold and "WARNING" or "OFFLINE", 9)
    hits[#hits + 1] = { type = "rt_hold", x1 = bx, x2 = bx + hw, y = box.y }
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2 + left_w + 1, 8, "Meldungen", function()
    local status = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or ((counts.WARN or 0) > 0 and "WARNING" or "OK")
    local box = widgets.panel_box(mon, 2 + left_w + 1, 8, right_w, alerts_h, "Aktive Meldungen", status)
    local alerts = model.alert_rows or {}
    if #alerts == 0 then alerts = { { title = "System", text = model.alert_summary or "Keine Meldungen", status = "OK" } } end
    for i = 1, math.min(#alerts, box.h) do widgets.alert_row(mon, box.x, box.y + i - 1, box.w, alerts[i], { compact = true }) end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  local kpi_y = 8 + math.max(controls_h, alerts_h) + 1
  safe_section(mon, 2, kpi_y, "KPI", function()
    local box = widgets.panel_box(mon, 2, kpi_y, w - 2, 7, "KPI", "OK")
    local card_w = math.floor((box.w - 1) / 2)
    widgets.stat_card(mon, box.x, box.y, card_w, "Leistung", string.format("Soll %.1f MRF/t", model.power_target or 0), string.format("Ist %.1f MRF/t", model.power_actual or 0), "LIMITED", (model.power_target or 0) > 0 and math.min(100, ((model.power_actual or 0) / model.power_target) * 100) or 0)
    local energy = model.energy_overview or {}
    widgets.stat_card(mon, box.x + card_w + 1, box.y, box.w - card_w - 1, "Energie", string.format("Fuellstand %.1f %%", energy.percent or 0), tostring(energy.trend or "Trend stabil"), energy.status or "OFFLINE", energy.percent or 0)
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  safe_section(mon, 2, kpi_y + 8, "Nodes", function()
    local panel_h = math.max(6, h - (kpi_y + 8) + 1)
    local box = widgets.panel_box(mon, 2, kpi_y + 8, w - 2, panel_h, "Node-Status", "OK")
    local note_w = math.max(8, box.w - 46)
    local widths = { 6, 9, 9, 9, 7, note_w }
    widgets.compact_header(mon, box.x, box.y, { "Node", "Rolle", "Status", "Mode", "Seen", "Hinweis" }, widths)
    local y = box.y + 1
    for _, n in ipairs(model.nodes or {}) do
      if y > (box.y + box.h - 1) then break end
      widgets.compact_status_row(mon, box.x, y, { tostring(n.id or "-"), tostring(n.role or "-"), tostring(n.status or "OFFLINE"), tostring(n.mode or "-"), tostring(n.last_seen_age or -1) .. "s", tostring(n.note or "-") }, widths, n.status or "OFFLINE", 3)
      y = y + 1
    end
    if y == box.y + 1 then ui.text(mon, box.x, y, "Keine Nodes verbunden", colors.get("OFFLINE"), colors.get("background")) end
  end, function(title, err) section_errors[#section_errors + 1] = title .. ": " .. tostring(err) end)

  if #section_errors > 0 then
    model.ui_errors = section_errors
  end

  hit_cache[mon] = hits
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    if y == hit.y and x >= hit.x1 and x <= hit.x2 then return hit end
  end
end

return { render = render, hit_test = hit_test }
