local mux = require("core.mockup_ui")

local STATUS_COLOR_KEY = {
  OK = "OK", EMERGENCY = "EMERGENCY", WARNING = "WARNING",
  LIMITED = "LIMITED", OFFLINE = "muted",
}

local function role_state(role_status, role_counts, role_key)
  local count = role_counts[role_key] or 0
  local status = role_status[role_key]
  if count == 0 then return count, "muted" end
  return count, STATUS_COLOR_KEY[status] or "muted"
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
  local w, h = mon.getSize()
  local role_status = (model and model.role_status) or {}
  local role_counts = (model and model.role_counts) or {}
  local counts = (model and model.alert_counts) or {}
  local summary = (model and model.summary) or model or {}

  local FUEL, RT, ENERGY, WATER, LOG = "FUEL-NODE", "RT-NODE", "ENERGY-NODE", "WATER-NODE", "LOG_COLLECTOR"
  local critical = counts.CRITICAL or 0
  local warn = counts.WARN or counts.WARNING or 0
  local page_status = critical > 0 and "EMERGENCY" or warn > 0 and "WARNING" or "OK"

  local fuel_n, fuel_key = role_state(role_status, role_counts, FUEL)
  local rt_n, rt_key = role_state(role_status, role_counts, RT)
  local energy_n, energy_key = role_state(role_status, role_counts, ENERGY)
  local water_n, water_key = role_state(role_status, role_counts, WATER)
  local log_n, log_key = role_state(role_status, role_counts, LOG)

  mux.clear(mon)
  mux.header(mon, { title = "AUX SYSTEM MAP", node_id = "MASTER AUX", page = "LIVE FLOW", status = page_status, icon = "network" })
  mux.status_dot(mon, 2, 3, "LIVE FLOW", "OK")
  if w >= 40 then mux.status_dot(mon, math.floor(w * 0.36), 3, "RT " .. tostring(rt_n), rt_n > 0 and "OK" or "muted") end
  if w >= 58 then mux.status_dot(mon, math.floor(w * 0.68), 3, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OK") end

  local map_w = w >= 66 and math.floor(w * 0.64) or (w - 3)
  local card_w = math.max(12, math.floor((map_w - 6) / 3))
  local x1, x2, x3 = 2, 4 + card_w, 6 + card_w * 2

  mux.metric_card(mon, x1, 6, card_w, 5, { label = "FUEL", value = tostring(fuel_n) .. " NODE", status = fuel_key, icon = "fuel" })
  mux.metric_card(mon, x2, 6, card_w, 5, { label = "RT FLEET", value = tostring(rt_n) .. " NODE", status = rt_key, icon = "reactor" })
  mux.metric_card(mon, x3, 6, card_w, 5, { label = "ENERGY", value = tostring(energy_n) .. " NODE", status = energy_key, icon = "energy" })

  mux.data_row(mon, x1, 12, math.max(1, x3 + card_w - x1), { label = "FUEL", value = "----> RT FLEET ----> ENERGY", status = "LIMITED", icon = "flow" })

  mux.metric_card(mon, x1, 14, card_w, 5, { label = "WATER", value = tostring(water_n) .. " NODE", status = water_key, icon = "water" })
  mux.metric_card(mon, x2, 14, card_w, 5, { label = "LOG", value = tostring(log_n) .. " NODE", status = log_key, icon = "network" })
  mux.metric_card(mon, x3, 14, card_w, 5, { label = "ALERTS", value = string.format("C:%d W:%d", critical, warn), status = page_status, icon = "warning" })

  mux.data_row(mon, x1, 20, math.max(1, x3 + card_w - x1), { label = "WATER ----> RT FLEET", value = "ALL NODES ----> LOG", status = "LIMITED", icon = "flow" })

  if w >= 66 then
    local rx = map_w + 2
    local rw = w - rx - 1
    mux.card(mon, rx, 6, rw, math.max(15, h - 8), { title = "SYSTEM SUMMARY", status = page_status, icon = "network" })
    local active_rt = first_number(summary, { "active_rt", "active_rt_count", "rt_active" })
    local target = first_number(summary, { "power_target", "target_power", "total_target" })
    local actual = first_number(summary, { "power_actual", "actual_power", "total_actual" })
    local energy_pct = first_number(summary, { "energy_percent", "energy_pct", "stored_percent" })

    mux.data_row(mon, rx + 2, 8, rw - 4, { label = "ACTIVE RT", value = tostring(active_rt or rt_n) .. "/" .. tostring(rt_n), status = rt_key, icon = "reactor" })
    mux.data_row(mon, rx + 2, 9, rw - 4, { label = "POWER TARGET", value = fmt_power(target) .. " RF/t", status = "LIMITED", icon = "master" })
    mux.data_row(mon, rx + 2, 10, rw - 4, { label = "POWER ACTUAL", value = fmt_power(actual) .. " RF/t", status = "OK", icon = "energy" })
    mux.data_row(mon, rx + 2, 11, rw - 4, { label = "ENERGY", value = energy_pct and string.format("%.0f%%", energy_pct > 1 and energy_pct or energy_pct * 100) or "n/a", status = energy_key, icon = "storage" })
    mux.data_row(mon, rx + 2, 12, rw - 4, { label = "ALERTS", value = string.format("C:%d W:%d", critical, warn), status = page_status, icon = "warning" })

    mux.section(mon, rx + 2, 14, rw - 4, "> NODE HEALTH", page_status, "network")
    mux.data_row(mon, rx + 2, 16, rw - 4, { label = "FUEL", value = tostring(fuel_n), status = fuel_key, icon = "fuel" })
    mux.data_row(mon, rx + 2, 17, rw - 4, { label = "RT", value = tostring(rt_n), status = rt_key, icon = "reactor" })
    mux.data_row(mon, rx + 2, 18, rw - 4, { label = "ENERGY", value = tostring(energy_n), status = energy_key, icon = "energy" })
    mux.data_row(mon, rx + 2, 19, rw - 4, { label = "WATER", value = tostring(water_n), status = water_key, icon = "water" })
    mux.data_row(mon, rx + 2, 20, rw - 4, { label = "LOG", value = tostring(log_n), status = log_key, icon = "network" })
  end

  -- Kein eigener footer_nav() hier -- multiview.lua zeichnet bereits den
  -- funktionalen AUX-Zyklus-Footer, ein zweiter wuerde kollidieren.
end

return { render = render }
