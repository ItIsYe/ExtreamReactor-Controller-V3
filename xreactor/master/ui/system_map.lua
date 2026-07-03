local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local STATUS_COLOR_KEY = {
  OK = "OK", EMERGENCY = "EMERGENCY", WARNING = "WARNING",
  LIMITED = "LIMITED", OFFLINE = "muted",
}

local function role_label(role_status, role_counts, role_key, short_name)
  local count = role_counts[role_key] or 0
  local status = role_status[role_key]
  if count == 0 then return string.format("[%s]", short_name), "muted" end
  return string.format("[%s:%d]", short_name, count), STATUS_COLOR_KEY[status] or "muted"
end

local function first_number(tbl, keys)
  for _, key in ipairs(keys or {}) do
    local value = tbl and tbl[key]
    if type(value) == "number" then return value end
  end
  return nil
end

local function fmt_power(value)
  if type(value) ~= "number" then return "n/a" end
  local abs = math.abs(value)
  if abs >= 1000000 then return string.format("%.1fM", value / 1000000) end
  if abs >= 1000 then return string.format("%.1fk", value / 1000) end
  return string.format("%.1f", value)
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local role_status = (model and model.role_status) or {}
  local role_counts = (model and model.role_counts) or {}
  local counts = (model and model.alert_counts) or {}

  local FUEL, RT, ENERGY, WATER, LOG = "FUEL-NODE", "RT-NODE", "ENERGY-NODE", "WATER-NODE", "LOG_COLLECTOR"
  local critical = counts.CRITICAL or 0
  local warn = counts.WARN or counts.WARNING or 0
  local page_status = critical > 0 and "EMERGENCY" or warn > 0 and "WARNING" or "OK"

  ui.panel(mon, 1, 1, w, h, "AUX MONITOR | SYSTEM MAP", page_status)
  ui.badge(mon, 2, 2, "LIVE FLOW", "OK")
  local rt_count = role_counts[RT] or 0
  if w >= 28 then ui.badge(mon, 14, 2, "RT " .. tostring(rt_count), rt_count > 0 and "OK" or "muted") end
  if w >= 42 then ui.badge(mon, 24, 2, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OK") end
  if w >= 58 then ui.badge(mon, 36, 2, "PROFILE AUTO", "LIMITED") end

  local fuel_text, fuel_status = role_label(role_status, role_counts, FUEL, "FUEL")
  local rt_text, rt_status = role_label(role_status, role_counts, RT, "RT FLEET")
  local energy_text, energy_status = role_label(role_status, role_counts, ENERGY, "ENERGY")
  local water_text, water_status = role_label(role_status, role_counts, WATER, "WATER")
  local log_text, log_status = role_label(role_status, role_counts, LOG, "LOG")

  local y = 5
  local map_width = math.max(20, math.floor(w * 0.68))
  local right_x = map_width + 2

  local x = 2
  ui.text(mon, x, y, fuel_text, colors.get(fuel_status), colors.get("background")); x = x + #fuel_text
  ui.text(mon, x, y, " --> ", colors.get("muted"), colors.get("background")); x = x + 5
  ui.text(mon, x, y, rt_text, colors.get(rt_status), colors.get("background")); x = x + #rt_text
  ui.text(mon, x, y, " --> ", colors.get("muted"), colors.get("background")); x = x + 5
  ui.text(mon, x, y, widgets.fit(energy_text, math.max(1, map_width - x)), colors.get(energy_status), colors.get("background"))

  y = y + 1
  local rt_x = 2 + #fuel_text + 5
  ui.text(mon, rt_x, y, "^", colors.get("muted"), colors.get("background"))
  y = y + 1
  ui.text(mon, 2, y, water_text, colors.get(water_status), colors.get("background"))
  ui.text(mon, 2 + #water_text, y, " ---+", colors.get("muted"), colors.get("background"))

  y = y + 2
  ui.text(mon, 2, y, log_text, colors.get(log_status), colors.get("background"))
  ui.text(mon, 2 + #log_text, y, widgets.fit(" <-- Logs von allen Nodes", math.max(1, map_width - 4 - #log_text)), colors.get("muted"), colors.get("background"))

  if right_x < w - 10 then
    local summary = (model and model.summary) or model or {}
    local active_rt = first_number(summary, { "active_rt", "active_rt_count", "rt_active" })
    local target = first_number(summary, { "power_target", "target_power", "total_target" })
    local actual = first_number(summary, { "power_actual", "actual_power", "total_actual" })
    local energy_pct = first_number(summary, { "energy_percent", "energy_pct", "stored_percent" })

    local sy = 5
    ui.text(mon, right_x, sy, "SYSTEM SUMMARY", colors.get("text"), colors.get("background")); sy = sy + 2
    ui.text(mon, right_x, sy, widgets.fit("Active RT  " .. tostring(active_rt or rt_count) .. "/" .. tostring(rt_count), w - right_x - 1), colors.get(rt_status), colors.get("background")); sy = sy + 1
    ui.text(mon, right_x, sy, widgets.fit("Power Target  " .. fmt_power(target) .. " RF/t", w - right_x - 1), colors.get("text"), colors.get("background")); sy = sy + 1
    ui.text(mon, right_x, sy, widgets.fit("Power Actual  " .. fmt_power(actual) .. " RF/t", w - right_x - 1), colors.get("text"), colors.get("background")); sy = sy + 1
    ui.text(mon, right_x, sy, widgets.fit("Energy  " .. (energy_pct and string.format("%.0f%%", energy_pct > 1 and energy_pct or energy_pct * 100) or "n/a"), w - right_x - 1), colors.get(energy_status), colors.get("background")); sy = sy + 1
    ui.text(mon, right_x, sy, widgets.fit(string.format("Alerts  C:%d W:%d", critical, warn), w - right_x - 1), colors.get(page_status), colors.get("background"))
  end

  if h >= 3 then
    local footer = string.format("STATUS %s | RT %d | ALERTS %d", page_status, rt_count, critical + warn)
    ui.text(mon, 2, h - 1, widgets.fit(footer, w - 3), colors.get(page_status), colors.get("background"))
  end
end

return { render = render }
