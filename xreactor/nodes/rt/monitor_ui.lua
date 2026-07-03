local ui = require("core.ui")
local ui_router = require("core.ui_router")
local colors = require("shared.colors")
local support_ui_pages = require("nodes.support.ui_pages")
local ok_utils, utils = pcall(require, "core.utils")
if not ok_utils or type(utils) ~= "table" then utils = nil end

local M = {
  monitor_router = nil,
  last_monitor_update = 0,
  main_monitor_name = nil,
  last_monitor = nil,
  last_capacity_ready = nil,
}

local function try_set_scale(monitor, scale)
  if monitor and type(scale) == "number" then ui.setScale(monitor, scale) end
end

local LAYOUT_THRESHOLDS = { compact_max_area = 700, medium_max_area = 1400 }

local function classify_rt_layout(w, h)
  local width, height = tonumber(w) or 0, tonumber(h) or 0
  local area = width * height
  if area <= LAYOUT_THRESHOLDS.compact_max_area or width < 30 or height < 16 then return "compact" end
  if area <= LAYOUT_THRESHOLDS.medium_max_area or width < 50 or height < 24 then return "medium" end
  return "large"
end

local function normalize_monitor_result(result)
  if type(result) == "table" then
    if result.mon then return result.mon, result.name end
    if result.monitor then return result.monitor, result.name end
  end
  return result
end

local function resolve_monitor(monitor_adapter, preferred_name, monitor_scale)
  if type(monitor_adapter) ~= "table" then return nil, "monitor adapter missing" end
  if type(monitor_adapter.find) == "function" then
    local monitor, name = normalize_monitor_result(monitor_adapter.find(preferred_name, "first", monitor_scale, "RT"))
    if monitor then return monitor, name end
  end
  if type(monitor_adapter.wrap) == "function" and preferred_name then
    local monitor = monitor_adapter.wrap(preferred_name)
    if monitor then try_set_scale(monitor, monitor_scale); return monitor, preferred_name end
  end
  if preferred_name and peripheral and type(peripheral.wrap) == "function" then
    local monitor = peripheral.wrap(preferred_name)
    if monitor then try_set_scale(monitor, monitor_scale); return monitor, preferred_name end
  end
  return nil, preferred_name and ("monitor unavailable: " .. tostring(preferred_name)) or "no monitor found"
end

local function num(value, fallback)
  if type(value) == "number" then return value end
  if type(value) == "string" then local parsed = tonumber(value); if parsed then return parsed end end
  return fallback
end

local function fit(text, width)
  local raw = tostring(text or ""):gsub("\n", " "):gsub("\r", " ")
  local w = math.max(1, tonumber(width) or #raw)
  if #raw <= w then return raw end
  if w <= 2 then return raw:sub(1, w) end
  return raw:sub(1, w - 1) .. "~"
end

local function pad(text, width)
  local w = math.max(1, tonumber(width) or 1)
  local clipped = fit(text, w)
  return clipped .. string.rep(" ", math.max(0, w - #clipped))
end

local function fmt(value, digits, suffix)
  local n = num(value, nil)
  if not n then return "-" end
  return string.format("%." .. tostring(digits or 1) .. "f%s", n, suffix or "")
end

local function fmt_short(value, suffix)
  local n = num(value, nil)
  if not n then return "-" end
  local abs = math.abs(n)
  if abs >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if abs >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  if abs >= 100 then return string.format("%.0f%s", n, suffix or "") end
  return string.format("%.1f%s", n, suffix or "")
end

local function count_bound(summary, kind)
  return summary and summary.kinds and summary.kinds[kind] and summary.kinds[kind].bound or 0
end

local function monitor_snapshot(model)
  return model and model.snapshot and model.snapshot.snapshot or nil
end

local function status_color(status)
  return colors.get(status or "text")
end

local function master_status(model)
  if model.master_state == "DOWN" then return "WARNING" end
  if model.master_state == "OK" then return "OK" end
  return "LIMITED"
end

local function capacity_status(model)
  if model.capacity_ready then return "OK" end
  if (num(model.capacity_stable_samples, 0) or 0) > 0 then return "LIMITED" end
  return "WARNING"
end

local function write_line(mon, y, text, status)
  local w = ({ ui.getSize(mon) })[1] or 20
  if y < 1 then return end
  ui.text(mon, 2, y, fit(text, math.max(1, w - 3)), status_color(status), colors.get("background"))
end

local function badge_line(mon, y, badges)
  local w = ({ ui.getSize(mon) })[1] or 20
  local x = 2
  for _, b in ipairs(badges or {}) do
    if b and x < w then
      local label = fit(b[1], math.max(3, math.min(12, w - x)))
      ui.badge(mon, x, y, label, b[2] or "OK")
      x = x + #label + 2
    end
  end
end

local function clear_and_title(mon, title, status)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, title, status or "OK")
  return w, h
end

local function progress_row(mon, x, y, width, value, status)
  if width < 4 then return end
  ui.progress(mon, x, y, width, math.max(0, math.min(1, num(value, 0) or 0)), status or "OK")
end

local function rt_status(model)
  if not model.capacity_ready then
    local samples = num(model.capacity_stable_samples, 0)
    return "LERNT EIN", "LIMITED", string.format("Sample %d/3", samples)
  end
  local assignment = tostring(model.assignment_state or "")
  if assignment == "shutdown" then return "HERUNTERFAHREN", "muted", "Master hat Abschaltung angefordert" end
  if assignment == "shed" or assignment == "standby" then return "WARTET AUF AUFTRAG", "muted", "Keine aktive Lastzuweisung" end
  if assignment == "startup" then return "FAEHRT HOCH", "LIMITED", "Wird vom Master gestartet" end
  local target = num(model.target_power, 0)
  local actual = num(model.snapshot and model.snapshot.snapshot and model.snapshot.snapshot.actual_output, 0)
  if target <= 0 then
    if actual > 0 then return "HERUNTERFAHREN", "muted", "Turbinen fahren ab" end
    return "WARTET AUF AUFTRAG", "muted", "Kein Soll-Wert vom Master"
  end
  local ratio = actual / target
  if ratio >= 0.85 and ratio <= 1.15 then return "LIEFERT NORMAL", "OK", nil end
  if ratio < 0.5 then return "LIEFERT ZU WENIG", "EMERGENCY", string.format("%.0f%% des Solls", ratio * 100) end
  if ratio > 1.3 then return "LIEFERT ZU VIEL", "WARNING", string.format("%.0f%% des Solls", ratio * 100) end
  return "WEICHT AB", "WARNING", string.format("%.0f%% des Solls", ratio * 100)
end

local function render_header(mon, model, title, page_text)
  local health = model.health and model.health.status or "OFFLINE"
  local w = ({ ui.getSize(mon) })[1] or 20
  write_line(mon, 2, string.format("RT NODE | %s", tostring(model.node_id or "?")), health)
  if page_text and w >= 30 then ui.text(mon, math.max(2, w - #page_text - 1), 2, page_text, colors.get("muted"), colors.get("background")) end
  badge_line(mon, 3, {
    { "M " .. tostring(model.master_state or "--"), master_status(model) },
    { model.capacity_ready and "CAP READY" or "LEARNING", capacity_status(model) },
    { tostring(model.assignment_state or "-"):upper(), model.assignment_state == "active" and "OK" or "LIMITED" },
  })
  write_line(mon, 4, title, health)
  return 5
end

local function render_overview(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local summary = model.summary or {}
  local health = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT OVERVIEW", health)
  local layout = classify_rt_layout(w, h)
  local y = render_header(mon, model, "UEBERSICHT", "SEITE 1/4")
  local status_text, status_key, status_detail = rt_status(model)
  write_line(mon, y, ">> " .. status_text .. " <<", status_key); y = y + 1
  if status_detail and h >= 18 then write_line(mon, y, status_detail, status_key); y = y + 1 end
  local actual = num(snapshot.actual_output, 0)
  local target = num(model.target_power, num(snapshot.target_power, 0))
  local master_pct = num(model.target_percent, num(snapshot.target_percent, 0))
  local capacity = num(model.capacity_max, 0)
  local turbines = count_bound(summary, "turbine")
  local reactors = count_bound(summary, "reactor")
  local turb_list = snapshot.turbines or {}
  if w >= 48 then
    write_line(mon, y, string.format("SOLL %s | IST %s | MASTER SOLL %.1f%%", fmt_short(target, "RF/t"), fmt_short(actual, "RF/t"), master_pct or 0), "text"); y = y + 1
    write_line(mon, y, string.format("TURBINEN %d | REAKTOREN %d | CAP %s", turbines, reactors, model.capacity_ready and "READY" or "LEARNING"), model.capacity_ready and "OK" or "LIMITED"); y = y + 1
  else
    write_line(mon, y, string.format("Soll %s  Ist %s", fmt_short(target, "RF/t"), fmt_short(actual, "RF/t")), "text"); y = y + 1
    write_line(mon, y, string.format("Master Soll %.1f%%", master_pct or 0), "LIMITED"); y = y + 1
    write_line(mon, y, string.format("Turbinen %d  Reaktoren %d", turbines, reactors), "text"); y = y + 1
  end
  if capacity > 0 then
    local cap_ratio = math.min(1, math.max(0, actual / capacity))
    write_line(mon, y, string.format("AUSLASTUNG %.1f%%  CAP %s", cap_ratio * 100, fmt_short(capacity, "RF/t")), "text"); y = y + 1
    progress_row(mon, 2, y, math.max(8, w - 3), cap_ratio, cap_ratio > 0.9 and "WARNING" or "OK"); y = y + 1
  end
  local rod_pct = nil
  local first_reactor = snapshot.reactors and snapshot.reactors[1]
  if first_reactor then rod_pct = num(first_reactor.rods, nil) end
  local avg_rpm = num(snapshot.avg_rpm, nil)
  local steam = num(snapshot.steam_amount, nil)
  local stable_turbines = 0
  for _, t in ipairs(turb_list) do
    if t.rpm and num(model.target_rpm, 0) > 0 and math.abs(num(t.rpm, 0) - num(model.target_rpm, 0)) <= math.max(20, num(model.target_rpm, 0) * 0.1) then stable_turbines = stable_turbines + 1 end
  end
  if y <= h - 3 then
    write_line(mon, y, "REAKTOR / TURBINEN SUMMARY", "text"); y = y + 1
    write_line(mon, y, string.format("RODS %s | DAMPF %s | AVG RPM %s", fmt(rod_pct, 0, "%"), fmt_short(steam), fmt(avg_rpm, 0, "")), "text"); y = y + 1
    if layout ~= "compact" and y <= h - 1 then write_line(mon, y, string.format("AKTIV %d/%d | MASTER %s | BUILD %s", stable_turbines, #turb_list, tostring(model.master_state or "?"), tostring(model.build_label or "-")), "muted") end
  end
end

local function turbine_status(t)
  if t.bound == false then return "OFFLINE" end
  if t.inductor == true then return "ON" end
  if t.inductor == false then return "OFF" end
  return "?"
end

local function render_turbines(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local health = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT TURBINEN", health)
  local y = render_header(mon, model, "TURBINEN DETAILS", "SEITE 2/4")
  local list = snapshot.turbines or {}
  local sum_rpm, rpm_n, sum_flow, flow_n, active = 0, 0, 0, 0, 0
  for _, t in ipairs(list) do
    local rpm = num(t.rpm, nil); local flow = num(t.flow, nil)
    if rpm then sum_rpm = sum_rpm + rpm; rpm_n = rpm_n + 1 end
    if flow then sum_flow = sum_flow + flow; flow_n = flow_n + 1 end
    if t.inductor == true or t.active == true then active = active + 1 end
  end
  local avg_rpm = rpm_n > 0 and sum_rpm / rpm_n or 0
  local avg_flow = flow_n > 0 and sum_flow / flow_n or 0
  write_line(mon, y, string.format("GESAMT %d | AKTIV %d | AVG RPM %.0f | AVG FLOW %.1f", #list, active, avg_rpm, avg_flow), "text"); y = y + 1
  local compact = w < 50
  if compact then write_line(mon, y, "ID       RPM     FLOW    IND", "muted") else write_line(mon, y, "TURBINE ID        RPM         FLOWRATE        INDUKTION", "muted") end
  y = y + 1
  local max_rows = math.max(1, h - y - 1)
  for i = 1, math.min(#list, max_rows) do
    local t = list[i]
    local id = tostring(t.id or ("T-" .. string.format("%02d", i)))
    local rpm = num(t.rpm, nil); local flow = num(t.flow, nil); local ind = turbine_status(t)
    local status = ind == "ON" and "OK" or (ind == "OFFLINE" and "EMERGENCY" or "muted")
    if compact then write_line(mon, y, string.format("%-7s %6s %7s %3s", fit(id, 7), rpm and string.format("%.0f", rpm) or "-", flow and string.format("%.1f", flow) or "-", ind), status)
    else write_line(mon, y, string.format("%-16s %8s RPM   %9s mB/t   %s", fit(id, 16), rpm and string.format("%.0f", rpm) or "-", flow and string.format("%.1f", flow) or "-", ind), status) end
    y = y + 1
  end
  if #list > max_rows and y <= h - 1 then write_line(mon, y, string.format("... %d weitere Turbinen", #list - max_rows), "LIMITED") end
end

local function reactor_key(r)
  if r.bound == false then return "muted" end
  if r.active == false then return "muted" end
  local t = num(r.temperature, nil)
  if t and t >= 1000 then return "EMERGENCY" end
  if t and t >= 850 then return "WARNING" end
  if t and t >= 700 then return "LIMITED" end
  return "OK"
end

local function render_reactors(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local health = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT REAKTOREN", health)
  local y = render_header(mon, model, "RT REAKTOREN", "SEITE 3/4")
  local reactors = snapshot.reactors or {}
  local shown_count = math.min(2, #reactors)
  local avg_temp = num(snapshot.avg_temp, nil)
  local steam = num(snapshot.steam_amount, nil)
  write_line(mon, y, string.format("SYSTEM %s | REAKTOREN %d/2 | AVG TEMP %sC | DAMPF %s | MASTER %s", health == "OK" and "NORMAL" or health, shown_count, fmt_short(avg_temp), fmt_short(steam), tostring(model.master_state or "?")), health); y = y + 2
  if shown_count == 0 then
    write_line(mon, y, "KEINE REAKTOREN GEFUNDEN", "WARNING")
    return
  end
  for i = 1, shown_count do
    local r = reactors[i]
    local key = reactor_key(r)
    local id = tostring(r.id or ("R-" .. string.format("%02d", i)))
    local rods = num(r.rods, 0) or 0
    local coolant = num(r.coolant_filled_percentage, nil)
    local cooling = coolant and string.format("%.0f%%", coolant * (coolant <= 1 and 100 or 1)) or (r.is_actively_cooled and "ACTIVE" or "n/a")
    if w >= 48 then
      write_line(mon, y, string.format("%-12s TEMP %-7s | RODS %-6s | DAMPF %-8s | COOL %-7s | %s", fit(id, 12), fmt(r.temperature, 0, "C"), fmt(rods, 0, "%"), fmt_short(r.steam_production, "mB/t"), cooling, r.active == false and "INAKTIV" or "AKTIV"), key)
    else
      write_line(mon, y, string.format("%s TEMP %s RODS %s", id, fmt(r.temperature, 0, "C"), fmt(rods, 0, "%")), key)
    end
    y = y + 1
    if y <= h - 2 then progress_row(mon, 2, y, math.max(8, w - 3), math.max(0, math.min(100, rods)) / 100, key); y = y + 2 end
  end
  if #reactors > 2 and y <= h - 1 then write_line(mon, y, string.format("INFO: %d weitere gefunden; UI zeigt max. 2 pro RT-Node", #reactors - 2), "muted") end
end

local function render_diagnostics(mon, model)
  local health = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT DIAGNOSTICS", health)
  local y = render_header(mon, model, "RT DIAGNOSTIK", "SEITE 4/4")
  local metrics = model.metrics or {}
  local dropped = metrics.dropped or 0
  local retries = metrics.retries or 0
  write_line(mon, y, string.format("GESUNDHEIT %s | MASTER %s age %s | TX/RX %d/%d | RETRIES %d | DROPPED %d", health, tostring(model.master_state or "?"), tostring(model.master_age or "-"), metrics.sent or 0, metrics.received or 0, retries, dropped), dropped > 0 and "WARNING" or health); y = y + 2
  write_line(mon, y, string.format("ZIEL LEISTUNG %s | ZIEL PROZENT %s | ZIEL RPM %s | ZIEL DAMPF %s", fmt_short(model.target_power, "RF/t"), fmt(model.target_percent, 1, "%"), fmt_short(model.target_rpm), fmt_short(model.target_steam)), "LIMITED"); y = y + 1
  write_line(mon, y, string.format("KAPAZITAET %s | MAX %s | SOURCE %s", model.capacity_ready and "BEREIT" or "LERNT", fmt_short(model.capacity_max, "RF/t"), tostring(model.capacity_source or "-")), capacity_status(model)); y = y + 2
  write_line(mon, y, string.format("LETZTER BEFEHL %s | vor %s", tostring(model.last_command or "none"), tostring(model.last_command_ts or "-")), "text"); y = y + 1
  write_line(mon, y, string.format("LETZTER SCAN %s | STATE %s | NODE %s", tostring(model.last_scan or "-"), tostring(model.current_state or "-"), tostring(model.node_state or "-")), "text"); y = y + 2
  local alerts = model.local_alerts or {}
  if #alerts > 0 and y <= h - 2 then
    write_line(mon, y, "ALERTE", "WARNING"); y = y + 1
    local shown = math.min(#alerts, math.max(0, h - y - 1))
    for i = 1, shown do
      local a = alerts[i]
      local sev = tostring(a.severity or "INFO")
      local key = sev == "CRITICAL" and "EMERGENCY" or (sev == "WARN" or sev == "WARNING") and "WARNING" or "LIMITED"
      write_line(mon, y, string.format("%-9s %-12s %s", sev, tostring(a.code or "-"), tostring(a.title or a.message or "alert")), key); y = y + 1
    end
  elseif y <= h - 1 then
    write_line(mon, y, "ALERTE: keine aktiven lokalen Meldungen", "OK")
  end
  if utils then support_ui_pages.render_log_mode_button(mon, utils, 1, h, w - 2) end
end

function M.collect_reactor_temp_stats(devices, reactor_adapter, log_prefix)
  local min_temp, max_temp, sum_temp, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.reactors or {}) do
    local info = reactor_adapter and type(reactor_adapter.inspect) == "function" and entry and entry.name and reactor_adapter.inspect(entry.name, log_prefix) or nil
    local temp = type(info) == "table" and info.temperature or nil
    if type(temp) == "number" then count = count + 1; sum_temp = sum_temp + temp; if not min_temp or temp < min_temp then min_temp = temp end; if not max_temp or temp > max_temp then max_temp = temp end end
  end
  return min_temp, max_temp, count > 0 and (sum_temp / count) or nil
end

function M.collect_turbine_rpm_stats(devices, read_turbine_rpm, get_device_caps)
  local min_rpm, max_rpm, sum_rpm, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.turbines or {}) do
    local rpm = read_turbine_rpm(entry.peripheral, get_device_caps("turbine", entry.id))
    if type(rpm) == "number" then count = count + 1; sum_rpm = sum_rpm + rpm; if not min_rpm or rpm < min_rpm then min_rpm = rpm end; if not max_rpm or rpm > max_rpm then max_rpm = rpm end end
  end
  return min_rpm, max_rpm, count > 0 and (sum_rpm / count) or nil
end

function M.build_turbine_status_details(devices, turbine_adapter, read_turbine_rpm, read_turbine_flow, get_device_caps, log_prefix)
  local list, total_output = {}, 0
  for _, entry in ipairs(devices.turbines or {}) do
    local turbine = entry.peripheral
    local caps = get_device_caps("turbine", entry.id)
    local info = turbine_adapter and type(turbine_adapter.inspect) == "function" and entry and entry.name and turbine_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local energy = num(info.energy, nil)
    if energy then total_output = total_output + energy end
    list[#list + 1] = { id = entry.id, bound = entry.bound ~= false, rpm = info.rpm or read_turbine_rpm(turbine, caps), flow = info.flow or read_turbine_flow(turbine, caps), energy = energy, active = info.active, inductor = info.coil_engaged }
  end
  return list, total_output
end

function M.build_reactor_status_details(devices, reactor_adapter, log_prefix)
  local list = {}
  for _, entry in ipairs(devices.reactors or {}) do
    local info = reactor_adapter and type(reactor_adapter.inspect) == "function" and entry and entry.name and reactor_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local rods = info.control_rod_level
    if rods == nil and reactor_adapter and type(reactor_adapter.read_control_rods) == "function" and entry and entry.name then rods = reactor_adapter.read_control_rods(entry.name, log_prefix) end
    list[#list + 1] = { id = entry.id, bound = entry.bound ~= false, temperature = info.temperature, fuel = info.fuel, energy_stored = info.energy_stored, energy_output = info.energy_output, waste = info.waste, active = info.active, is_actively_cooled = info.is_actively_cooled, rods = rods, steam_production = info.steam, coolant_amount = info.coolant_amount, coolant_amount_max = info.coolant_amount_max, coolant_filled_percentage = info.coolant_filled_percentage }
  end
  return list
end

function M.update_status_snapshot(ctx)
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary() or {}
  local min_temp, max_temp, avg_temp = M.collect_reactor_temp_stats(ctx.devices, ctx.reactor_adapter, ctx.log_prefix)
  local min_rpm, max_rpm, avg_rpm = M.collect_turbine_rpm_stats(ctx.devices, ctx.read_turbine_rpm, ctx.get_device_caps)
  local turbines, actual_output = M.build_turbine_status_details(ctx.devices, ctx.turbine_adapter, ctx.read_turbine_rpm, ctx.read_turbine_flow, ctx.get_device_caps, ctx.log_prefix)
  local capacity = ctx.capacity_learning or {}
  ctx.last_status_snapshot = {
    ts = os.epoch("utc"), node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id,
    summary = summary, min_temp = min_temp, max_temp = max_temp, avg_temp = avg_temp,
    min_rpm = min_rpm, max_rpm = max_rpm, avg_rpm = avg_rpm,
    steam_amount = ctx.get_available_steam(), target_power = ctx.targets and ctx.targets.power or nil,
    target_percent = ctx.targets and ctx.targets.power_percent or nil, target_rpm = ctx.targets and ctx.targets.rpm or nil,
    target_steam = ctx.targets and ctx.targets.steam or nil, actual_output = actual_output,
    capacity_max = capacity.max_output or (ctx.targets and ctx.targets.capacity_max) or 0,
    capacity_ready = capacity.ready == true, capacity_source = capacity.reason or (ctx.targets and ctx.targets.capacity_source) or "unknown",
    capacity_stable_samples = capacity.ready and 1 or 0, capacity_stable_turbines = capacity.at_target or 0,
    capacity_total_turbines = capacity.total_turbines or 0,
    reactors = M.build_reactor_status_details(ctx.devices, ctx.reactor_adapter, ctx.log_prefix), turbines = turbines,
  }
  return ctx.last_status_snapshot
end

function M.init(monitor_adapter, configured_monitor, monitor_scale)
  M.monitor_router = nil; M.last_monitor_update = 0
  local monitor, name_or_err = resolve_monitor(monitor_adapter, configured_monitor, monitor_scale)
  if not monitor then return nil, name_or_err end
  M.main_monitor_name = name_or_err
  return monitor, name_or_err
end

local ok_ampel_mod, ampel_mod = pcall(require, "optional.ampel")
local ampel_instance = ok_ampel_mod and type(ampel_mod) == "table" and type(ampel_mod.new) == "function" and ampel_mod.new() or nil

function M.update(monitor, ctx)
  if not monitor then return ctx.last_status_snapshot end
  local now = os.epoch("utc")
  if now - M.last_monitor_update < (ctx.config.monitor_interval * 1000) then return ctx.last_status_snapshot end
  M.last_monitor_update = now
  local snapshot = M.update_status_snapshot(ctx)
  local health_payload = ctx.build_health_payload()
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary()
  local comms_diag = ctx.comms and ctx.comms:get_diagnostics() or {}
  local metrics = comms_diag.metrics or {}
  local master_state, master_age = "UNKNOWN", "n/a"
  for _, peer in pairs(comms_diag.peers or {}) do if peer.role == ctx.constants.roles.MASTER then master_state = peer.down and "DOWN" or "OK"; master_age = peer.age and (math.floor(peer.age) .. "s") or "n/a"; break end end
  local node_id = snapshot and snapshot.node_id or ctx.config.node_id
  local alert_payload = ctx.master_alerts and ctx.master_alerts.by_node and ctx.master_alerts.by_node[node_id] or nil
  local targets = ctx.targets or {}
  local model = {
    snapshot = { snapshot = snapshot, local_alerts = alert_payload and alert_payload.critical or 0 }, health = health_payload,
    summary = summary, comms = comms_diag, metrics = metrics, master_state = master_state, master_age = master_age,
    last_scan = ctx.devices.last_scan_ts and (math.floor((now - ctx.devices.last_scan_ts) / 1000) .. "s") or "n/a",
    last_command = ctx.last_command, last_command_ts = ctx.last_command_ts and (math.floor((now - ctx.last_command_ts) / 1000) .. "s") or "n/a",
    local_alerts = alert_payload and alert_payload.top or {}, local_alerts_critical = alert_payload and alert_payload.critical or 0,
    node_id = node_id, current_state = ctx.current_state, node_state = ctx.node_state_machine and ctx.node_state_machine:state() or ctx.current_state,
    configured_reactors = ctx.configured_reactors, configured_turbines = ctx.configured_turbines,
    target_power = targets.power, target_percent = targets.power_percent,
    target_rpm = targets.rpm or (ctx.get_target_rpm and ctx.get_target_rpm()), target_steam = targets.steam,
    assignment_state = targets.assignment_state, capacity_max = snapshot and snapshot.capacity_max or 0,
    capacity_ready = snapshot and snapshot.capacity_ready or false, capacity_source = snapshot and snapshot.capacity_source or "unknown",
    capacity_stable_samples = snapshot and snapshot.capacity_stable_samples or 0,
    capacity_stable_turbines = snapshot and snapshot.capacity_stable_turbines or 0,
    capacity_total_turbines = snapshot and snapshot.capacity_total_turbines or 0,
    binding = ctx.binding, build_label = ctx.build_label or ctx.manifest_id or ctx.release_id,
  }
  if not M.monitor_router then
    M.monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = render_overview },
        { name = "Turbines", render = render_turbines },
        { name = "Reactors", render = render_reactors },
        { name = "Diagnostics", render = render_diagnostics },
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true },
    })
  end
  M.last_monitor = monitor
  M.monitor_router:render(monitor, model)
  pcall(function()
    if not ampel_instance then return end
    local ok_status, _, status_key = pcall(rt_status, model)
    if ok_status and status_key then ampel_instance.render(M.main_monitor_name, status_key) end
  end)
  pcall(function()
    if M.last_capacity_ready == nil then M.last_capacity_ready = model.capacity_ready == true; return end
    if model.capacity_ready == true and M.last_capacity_ready == false then
      local ok_spk_mod, spk_mod = pcall(require, "optional.speaker_alarm")
      if ok_spk_mod and type(spk_mod) == "table" and type(spk_mod.new) == "function" then local speaker = spk_mod.new(); pcall(speaker.play, "capacity_learned") end
    end
    M.last_capacity_ready = model.capacity_ready == true
  end)
  return snapshot
end

function M.handle_input(event)
  if M.monitor_router then M.monitor_router:handle_input(event) end
  if utils and event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then
    local page = M.monitor_router and M.monitor_router:current()
    if page and page.name == "Diagnostics" and M.last_monitor then
      local _, h = ui.getSize(M.last_monitor)
      if h then support_ui_pages.handle_log_mode_touch(event[3], event[4], h, utils, 1) end
    end
  end
end

return M
