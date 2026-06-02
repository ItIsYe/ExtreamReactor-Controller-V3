local ui = require("core.ui")
local ui_router = require("core.ui_router")
local colors = require("shared.colors")

local M = {
  monitor_router = nil,
  last_monitor_update = 0
}

local function try_set_scale(monitor, scale)
  if not monitor or type(scale) ~= "number" then return end
  ui.setScale(monitor, scale)
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
    local found = monitor_adapter.find(preferred_name, "first", monitor_scale, "RT")
    local monitor, monitor_name = normalize_monitor_result(found)
    if monitor then return monitor, monitor_name end
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
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then return parsed end
  end
  return fallback
end

local function fmt(value, digits, suffix)
  local n = num(value, nil)
  if not n then return "n/a" end
  return string.format("%." .. tostring(digits or 1) .. "f%s", n, suffix or "")
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

local function panel_box(mon, x, y, w, h, title, status)
  local width = math.max(8, math.floor(num(w, 8)))
  local height = math.max(3, math.floor(num(h, 3)))
  ui.panel(mon, x, y, width, height, fit(title or "", math.max(4, width - 4)), status or "OK")
  return { x = x + 1, y = y + 1, w = math.max(1, width - 2), h = math.max(1, height - 2), right = x + width - 1, bottom = y + height - 1 }
end

local function split_columns(total_w, ratios, gap)
  local width = math.max(1, math.floor(num(total_w, 1)))
  local specs = ratios or { 1 }
  local g = math.max(0, math.floor(num(gap, 1)))
  local total_gap = math.max(0, (#specs - 1) * g)
  local avail = math.max(#specs, width - total_gap)
  local sum = 0
  for _, r in ipairs(specs) do sum = sum + math.max(1, num(r, 1)) end
  local out, used = {}, 0
  for i, r in ipairs(specs) do
    if i == #specs then
      out[i] = math.max(1, avail - used)
    else
      out[i] = math.max(1, math.floor((avail * math.max(1, num(r, 1))) / sum))
      used = used + out[i]
    end
  end
  return out
end

local function status_badge(mon, x, y, text, status, max_width)
  local label = fit(text or "", math.max(4, num(max_width, 18)))
  ui.badge(mon, x, y, label, status or "OK")
  return #label + 2
end

local function stat_card(mon, x, y, w, title, value, meta, status, progress)
  local width = math.max(12, math.floor(num(w, 12)))
  ui.panel(mon, x, y, width, 5, fit(title or "", width - 3), status or "OK")
  ui.text(mon, x + 1, y + 1, fit(value or "-", width - 2), colors.get(status or "text"), colors.get("background"))
  ui.text(mon, x + 1, y + 2, fit(meta or "", width - 2), colors.get("muted"), colors.get("background"))
  if progress ~= nil and width >= 10 then
    local pct = num(progress, 0)
    if pct > 1 then pct = pct / 100 end
    pct = math.max(0, math.min(1, pct))
    ui.progress(mon, x + 1, y + 3, math.max(6, width - 2), pct, status or "OK")
  end
end

local function table_widths(total_w, widths)
  local width = math.max(1, math.floor(num(total_w, 1)))
  local spec = widths or { width }
  local out, used = {}, 0
  for i, raw in ipairs(spec) do
    out[i] = math.max(3, math.floor(num(raw, 6)))
    used = used + out[i]
  end
  local diff = width - used
  local i = #out
  while diff < 0 and i >= 1 do
    if out[i] > 3 then out[i] = out[i] - 1; diff = diff + 1 else i = i - 1 end
  end
  i = 1
  while diff > 0 and #out > 0 do
    out[i] = out[i] + 1
    diff = diff - 1
    i = i + 1
    if i > #out then i = 1 end
  end
  return out
end

local function compact_header(mon, x, y, labels, widths)
  local col = x
  for i, label in ipairs(labels or {}) do
    local cw = widths[i] or 8
    ui.text(mon, col, y, pad(label, cw - 1), colors.get("muted"), colors.get("background"))
    col = col + cw
  end
end

local function compact_row(mon, x, y, values, widths, status, status_col)
  local col = x
  for i, value in ipairs(values or {}) do
    local cw = widths[i] or 8
    local key = (i == (status_col or 2)) and (status or "text") or (i == #values and "muted" or "text")
    ui.text(mon, col, y, pad(value or "-", cw - 1), colors.get(key), colors.get("background"))
    col = col + cw
  end
end

local function count_bound(summary, kind)
  return summary and summary.kinds and summary.kinds[kind] and summary.kinds[kind].bound or 0
end

local function monitor_snapshot(model)
  return model and model.snapshot and model.snapshot.snapshot or nil
end

local function read_reactor_info(entry, adapter, log_prefix)
  if adapter and type(adapter.inspect) == "function" and entry and entry.name then
    local info = adapter.inspect(entry.name, log_prefix)
    if type(info) == "table" then return info end
  end
end

local function read_turbine_info(entry, adapter, log_prefix)
  if adapter and type(adapter.inspect) == "function" and entry and entry.name then
    local info = adapter.inspect(entry.name, log_prefix)
    if type(info) == "table" then return info end
  end
end

local function power_state(actual, target)
  local a = num(actual, 0)
  local t = num(target, 0)
  if t <= 0 then return "LIMITED", 0 end
  local pct = math.max(0, math.min(150, (a / t) * 100))
  if pct < 25 or pct > 115 then return "WARNING", pct end
  return "OK", pct
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

local function render_header(mon, model, title)
  local w = ({ ui.getSize(mon) })[1] or 40
  local health_status = model.health and model.health.status or "OFFLINE"
  local header = panel_box(mon, 2, 2, w - 2, 6, title, health_status)
  local cols = split_columns(header.w, { 2, 2, 2, 2 }, 1)
  local x = header.x
  status_badge(mon, x, header.y, "RT " .. tostring(health_status), health_status, cols[1]); x = x + cols[1] + 1
  status_badge(mon, x, header.y, "MASTER " .. tostring(model.master_state or "?"), master_status(model), cols[2]); x = x + cols[2] + 1
  status_badge(mon, x, header.y, "MODE " .. tostring(model.current_state or "-"), tostring(model.current_state) == "MASTER" and "OK" or "LIMITED", cols[3]); x = x + cols[3] + 1
  status_badge(mon, x, header.y, model.capacity_ready and "CAP OK" or "CAP LEARN", capacity_status(model), cols[4])
  ui.text(mon, header.x, header.y + 2, fit("Node " .. tostring(model.node_id or "UNKNOWN") .. " | State " .. tostring(model.node_state or "-") .. " | Master age " .. tostring(model.master_age or "n/a"), header.w), colors.get("text"), colors.get("background"))
  ui.text(mon, header.x, header.y + 3, fit("Cmd " .. tostring(model.last_command or "none") .. " | Scan " .. tostring(model.last_scan or "n/a") .. " | Build " .. tostring(model.build_label or "n/a"), header.w), colors.get("muted"), colors.get("background"))
  return 9
end

local function render_overview(mon, model)
  local w, h = ui.getSize(mon)
  if not w or not h then return end
  local snapshot = monitor_snapshot(model) or {}
  local summary = model.summary or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  ui.panel(mon, 1, 1, w, h, "RT OVERVIEW", health_status)
  local top = render_header(mon, model, "Lage")
  local actual = num(snapshot.actual_output, 0)
  local target_power = num(model.target_power, num(snapshot.target_power, 0))
  local p_status, p_pct = power_state(actual, target_power)
  local capacity = num(model.capacity_max, 0)
  local capacity_pct = capacity > 0 and math.min(100, (actual / capacity) * 100) or 0
  local reactors = count_bound(summary, "reactor")
  local turbines = count_bound(summary, "turbine")

  local content_h = math.max(8, h - top - 1)
  local cols = split_columns(w - 2, w >= 58 and { 3, 2 } or { 1 }, 1)
  local left_w = cols[1]
  local right_w = cols[2]

  local metrics_h = math.min(17, content_h)
  local box = panel_box(mon, 2, top, left_w, metrics_h, "Kennzahlen", p_status)
  local card_cols = split_columns(box.w, box.w >= 42 and { 1, 1 } or { 1 }, 1)
  stat_card(mon, box.x, box.y, card_cols[1], "Leistung", string.format("Soll %s", fmt(target_power, 1)), string.format("Ist %s RF/t | %.1f%%", fmt(actual, 1), p_pct), p_status, p_pct)
  if card_cols[2] then
    stat_card(mon, box.x + card_cols[1] + 1, box.y, card_cols[2], "Kapazitaet", string.format("Max %s", fmt(capacity, 1)), string.format("Ist %.1f%% | %s", capacity_pct, tostring(model.capacity_source or "-")), capacity_status(model), capacity_pct)
  else
    stat_card(mon, box.x, box.y + 6, box.w, "Kapazitaet", string.format("Max %s", fmt(capacity, 1)), string.format("Ist %.1f%% | %s", capacity_pct, tostring(model.capacity_source or "-")), capacity_status(model), capacity_pct)
  end
  local second_y = box.y + (card_cols[2] and 6 or 12)
  if second_y + 4 <= box.y + box.h then
    local rpm_pct = num(model.target_rpm, 0) > 0 and ((num(snapshot.avg_rpm, 0) / num(model.target_rpm, 1)) * 100) or 0
    stat_card(mon, box.x, second_y, card_cols[1], "Turbinen", tostring(turbines) .. " online", string.format("RPM %s/%s", fmt(snapshot.avg_rpm, 0), fmt(model.target_rpm, 0)), turbines > 0 and "OK" or "WARNING", rpm_pct)
    if card_cols[2] then
      stat_card(mon, box.x + card_cols[1] + 1, second_y, card_cols[2], "Reaktoren", tostring(reactors) .. " online", string.format("Temp %s C | Steam %s", fmt(snapshot.avg_temp, 1), fmt(snapshot.steam_amount, 1)), reactors > 0 and "OK" or "WARNING")
    end
  end

  if right_w then
    local rbox = panel_box(mon, 2 + left_w + 1, top, right_w, metrics_h, "Kurzliste", health_status)
    local y = rbox.y
    ui.text(mon, rbox.x, y, fit("Master Vorgabe: " .. fmt(model.target_percent, 1, "%") .. " -> " .. fmt(target_power, 1) .. " RF/t", rbox.w), colors.get("text"), colors.get("background")); y = y + 1
    ui.text(mon, rbox.x, y, fit("Capacity: " .. tostring(model.capacity_ready and "locked" or "learning") .. " samples=" .. tostring(model.capacity_stable_samples or 0), rbox.w), colors.get("muted"), colors.get("background")); y = y + 2
    local tw = table_widths(rbox.w, { 9, 8, 8, 8 })
    compact_header(mon, rbox.x, y, { "Turb", "RPM", "RF/t", "Coil" }, tw); y = y + 1
    local turbines_list = snapshot.turbines or {}
    for i = 1, math.min(#turbines_list, math.max(0, rbox.bottom - y)) do
      local t = turbines_list[i]
      compact_row(mon, rbox.x, y, { tostring(t.id or i), fmt(t.rpm, 0), fmt(t.energy, 1), t.inductor and "ON" or "OFF" }, tw, (t.bound == false) and "WARNING" or "OK", 4)
      y = y + 1
    end
    if #turbines_list == 0 then ui.text(mon, rbox.x, y, "Keine Turbinen sichtbar", colors.get("WARNING"), colors.get("background")) end
  end
end

local function render_turbines(mon, model)
  local w, h = ui.getSize(mon)
  if not w or not h then return end
  local snapshot = monitor_snapshot(model) or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  ui.panel(mon, 1, 1, w, h, "RT TURBINES", health_status)
  local top = render_header(mon, model, "Turbinen")
  local turbines = snapshot.turbines or {}
  local box = panel_box(mon, 2, top, w - 2, h - top, "Turbinen-Status", #turbines > 0 and "OK" or "WARNING")
  ui.text(mon, box.x, box.y, fit(string.format("Total %d | Output %s RF/t | Avg RPM %s | Target %s", #turbines, fmt(snapshot.actual_output, 1), fmt(snapshot.avg_rpm, 0), fmt(model.target_rpm, 0)), box.w), colors.get("text"), colors.get("background"))
  local widths = table_widths(box.w, { 10, 8, 8, 9, 8, 8, 12 })
  local y = box.y + 2
  compact_header(mon, box.x, y, { "ID", "RPM", "Flow", "RF/t", "Coil", "Act", "Note" }, widths); y = y + 1
  for i = 1, math.min(#turbines, math.max(0, box.bottom - y)) do
    local t = turbines[i]
    local status = (t.bound == false) and "WARNING" or "OK"
    local note = "stable"
    if not t.rpm then note = "no rpm" elseif num(model.target_rpm, 0) > 0 and math.abs(num(t.rpm, 0) - num(model.target_rpm, 0)) > 40 then status = "WARNING"; note = "rpm drift" end
    compact_row(mon, box.x, y, { tostring(t.id or i), fmt(t.rpm, 0), fmt(t.flow, 0), fmt(t.energy, 1), t.inductor and "ON" or "OFF", t.active and "ON" or "OFF", note }, widths, status, 7)
    y = y + 1
  end
  if #turbines == 0 then ui.text(mon, box.x, y, "Keine Turbinen sichtbar", colors.get("WARNING"), colors.get("background")) end
end

local function render_reactors(mon, model)
  local w, h = ui.getSize(mon)
  if not w or not h then return end
  local snapshot = monitor_snapshot(model) or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  ui.panel(mon, 1, 1, w, h, "RT REACTORS", health_status)
  local top = render_header(mon, model, "Reaktoren")
  local reactors = snapshot.reactors or {}
  local box = panel_box(mon, 2, top, w - 2, h - top, "Reaktor-Status", #reactors > 0 and "OK" or "WARNING")
  ui.text(mon, box.x, box.y, fit(string.format("Total %d | Avg Temp %s C | Max Temp %s C | Steam %s", #reactors, fmt(snapshot.avg_temp, 1), fmt(snapshot.max_temp, 1), fmt(snapshot.steam_amount, 1)), box.w), colors.get("text"), colors.get("background"))
  local widths = table_widths(box.w, { 10, 9, 8, 8, 10, 10, 12 })
  local y = box.y + 2
  compact_header(mon, box.x, y, { "ID", "Temp", "Rods", "Act", "Steam", "Coolant", "Note" }, widths); y = y + 1
  for i = 1, math.min(#reactors, math.max(0, box.bottom - y)) do
    local r = reactors[i]
    local status = (r.bound == false) and "WARNING" or "OK"
    local note = "stable"
    if r.active == false then status = "LIMITED"; note = "inactive" end
    compact_row(mon, box.x, y, { tostring(r.id or i), fmt(r.temperature, 1), fmt(r.rods, 0), r.active and "ON" or "OFF", fmt(r.steam_production, 1), fmt(r.coolant_filled_percentage, 1, "%"), note }, widths, status, 7)
    y = y + 1
  end
  if #reactors == 0 then ui.text(mon, box.x, y, "Keine Reaktoren sichtbar", colors.get("WARNING"), colors.get("background")) end
end

local function render_diagnostics(mon, model)
  local w, h = ui.getSize(mon)
  if not w or not h then return end
  local health_status = model.health and model.health.status or "OFFLINE"
  ui.panel(mon, 1, 1, w, h, "RT DIAGNOSTICS", health_status)
  local top = render_header(mon, model, "Diagnose")
  local cols = split_columns(w - 2, w >= 64 and { 1, 1 } or { 1 }, 1)
  local left_w = cols[1]
  local right_w = cols[2]
  local box = panel_box(mon, 2, top, left_w, h - top, "Runtime", master_status(model))
  local rows = {
    { "Master", tostring(model.master_state or "UNKNOWN") .. " age " .. tostring(model.master_age or "n/a"), master_status(model) },
    { "Comms", string.format("tx/rx %d/%d", model.metrics.sent or 0, model.metrics.received or 0), "OK" },
    { "Retry", string.format("retries %d drops %d", model.metrics.retries or 0, model.metrics.dropped or 0), ((model.metrics.dropped or 0) > 0) and "WARNING" or "OK" },
    { "Setpoint", string.format("power %s / %s", fmt(model.target_power, 1), fmt(model.target_percent, 1, "%")), "LIMITED" },
    { "RPM/Steam", string.format("rpm %s steam %s", fmt(model.target_rpm, 0), fmt(model.target_steam, 1)), "LIMITED" },
    { "Capacity", string.format("max %s ready=%s src=%s", fmt(model.capacity_max, 1), tostring(model.capacity_ready), tostring(model.capacity_source or "-")), capacity_status(model) },
    { "Last cmd", tostring(model.last_command or "none") .. " " .. tostring(model.last_command_ts or "n/a"), "OK" },
    { "Last scan", tostring(model.last_scan or "n/a"), "OK" }
  }
  local widths = table_widths(box.w, { 12, box.w - 12 })
  local y = box.y
  for _, r in ipairs(rows) do
    if y > box.bottom then break end
    compact_row(mon, box.x, y, { r[1], r[2] }, widths, r[3], 1)
    y = y + 1
  end

  if right_w then
    local abox = panel_box(mon, 2 + left_w + 1, top, right_w, h - top, "Alerts", (model.local_alerts_critical or 0) > 0 and "EMERGENCY" or "OK")
    local alerts = model.local_alerts or {}
    if #alerts == 0 then
      ui.text(mon, abox.x, abox.y, "Keine lokalen Alerts", colors.get("OK"), colors.get("background"))
    else
      local y2 = abox.y
      for i = 1, math.min(#alerts, abox.h) do
        local a = alerts[i]
        local sev = tostring(a.severity or "INFO")
        ui.badge(mon, abox.x, y2, fit(sev, 7), sev == "CRITICAL" and "EMERGENCY" or (sev == "WARN" and "WARNING" or "OK"))
        ui.text(mon, abox.x + 9, y2, fit(tostring(a.title or a.message or a.code or "alert"), math.max(4, abox.w - 10)), colors.get("text"), colors.get("background"))
        y2 = y2 + 1
      end
    end
  end
end

function M.collect_reactor_temp_stats(devices, reactor_adapter, log_prefix)
  local min_temp, max_temp, sum_temp, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.reactors or {}) do
    local info = read_reactor_info(entry, reactor_adapter, log_prefix)
    local temp = info and info.temperature
    if type(temp) == "number" then
      count = count + 1
      sum_temp = sum_temp + temp
      if not min_temp or temp < min_temp then min_temp = temp end
      if not max_temp or temp > max_temp then max_temp = temp end
    end
  end
  return min_temp, max_temp, count > 0 and (sum_temp / count) or nil
end

function M.collect_turbine_rpm_stats(devices, read_turbine_rpm, get_device_caps)
  local min_rpm, max_rpm, sum_rpm, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.turbines or {}) do
    local caps = get_device_caps("turbine", entry.id)
    local rpm = read_turbine_rpm(entry.peripheral, caps)
    if type(rpm) == "number" then
      count = count + 1
      sum_rpm = sum_rpm + rpm
      if not min_rpm or rpm < min_rpm then min_rpm = rpm end
      if not max_rpm or rpm > max_rpm then max_rpm = rpm end
    end
  end
  return min_rpm, max_rpm, count > 0 and (sum_rpm / count) or nil
end

function M.build_turbine_status_details(devices, turbine_adapter, read_turbine_rpm, read_turbine_flow, get_device_caps, log_prefix)
  local list = {}
  local total_output = 0
  for _, entry in ipairs(devices.turbines or {}) do
    local turbine = entry.peripheral
    local caps = get_device_caps("turbine", entry.id)
    local info = read_turbine_info(entry, turbine_adapter, log_prefix)
    local rpm = info and info.rpm or read_turbine_rpm(turbine, caps)
    local flow = info and info.flow or read_turbine_flow(turbine, caps)
    local active = info and info.active or nil
    local inductor = info and info.coil_engaged or nil
    local energy = num(info and info.energy, nil)
    if energy then total_output = total_output + energy end
    list[#list + 1] = { id = entry.id, bound = entry.bound ~= false, rpm = rpm, flow = flow, energy = energy, active = active, inductor = inductor }
  end
  return list, total_output
end

function M.build_reactor_status_details(devices, reactor_adapter, log_prefix)
  local list = {}
  for _, entry in ipairs(devices.reactors or {}) do
    local info = read_reactor_info(entry, reactor_adapter, log_prefix)
    local rods = info and info.control_rod_level or nil
    if rods == nil and reactor_adapter and type(reactor_adapter.read_control_rods) == "function" and entry and entry.name then
      rods = reactor_adapter.read_control_rods(entry.name, log_prefix)
    end
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      temperature = info and info.temperature or nil,
      fuel = info and info.fuel or nil,
      energy = info and info.energy or nil,
      waste = info and info.waste or nil,
      active = info and info.active or nil,
      rods = rods,
      steam_production = info and info.steam or nil,
      coolant_amount = info and info.coolant_amount or nil,
      coolant_amount_max = info and info.coolant_amount_max or nil,
      coolant_filled_percentage = info and info.coolant_filled_percentage or nil
    }
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
    ts = os.epoch("utc"),
    node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id,
    summary = summary,
    min_temp = min_temp,
    max_temp = max_temp,
    avg_temp = avg_temp,
    min_rpm = min_rpm,
    max_rpm = max_rpm,
    avg_rpm = avg_rpm,
    steam_amount = ctx.get_available_steam(),
    target_power = ctx.targets and ctx.targets.power or nil,
    target_percent = ctx.targets and ctx.targets.power_percent or nil,
    target_rpm = ctx.targets and ctx.targets.rpm or nil,
    target_steam = ctx.targets and ctx.targets.steam or nil,
    actual_output = actual_output,
    capacity_max = capacity.max_output or (ctx.targets and ctx.targets.capacity_max) or 0,
    capacity_ready = capacity.locked == true,
    capacity_source = capacity.reason or (ctx.targets and ctx.targets.capacity_source) or "unknown",
    capacity_stable_samples = capacity.stable_samples or 0,
    reactors = M.build_reactor_status_details(ctx.devices, ctx.reactor_adapter, ctx.log_prefix),
    turbines = turbines
  }
  return ctx.last_status_snapshot
end

function M.init(monitor_adapter, configured_monitor, monitor_scale)
  M.monitor_router = nil
  M.last_monitor_update = 0
  local monitor, monitor_name_or_err = resolve_monitor(monitor_adapter, configured_monitor, monitor_scale)
  if not monitor then return nil, monitor_name_or_err end
  return monitor, monitor_name_or_err
end

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
  local master_state = "UNKNOWN"
  local master_age = "n/a"
  for _, peer in pairs(comms_diag.peers or {}) do
    if peer.role == ctx.constants.roles.MASTER then
      master_state = peer.down and "DOWN" or "OK"
      master_age = peer.age and (math.floor(peer.age) .. "s") or "n/a"
      break
    end
  end

  local node_id = snapshot and snapshot.node_id or ctx.config.node_id
  local alert_payload = ctx.master_alerts and ctx.master_alerts.by_node and ctx.master_alerts.by_node[node_id] or nil
  local local_alerts = alert_payload and alert_payload.top or {}
  local local_critical = alert_payload and alert_payload.critical or 0
  local targets = ctx.targets or {}
  local model = {
    snapshot = { snapshot = snapshot, local_alerts = local_critical },
    health = health_payload,
    summary = summary,
    comms = comms_diag,
    metrics = metrics,
    master_state = master_state,
    master_age = master_age,
    last_scan = ctx.devices.last_scan_ts and (math.floor((now - ctx.devices.last_scan_ts) / 1000) .. "s") or "n/a",
    last_command = ctx.last_command,
    last_command_ts = ctx.last_command_ts and (math.floor((now - ctx.last_command_ts) / 1000) .. "s") or "n/a",
    local_alerts = local_alerts,
    local_alerts_critical = local_critical,
    node_id = node_id,
    current_state = ctx.current_state,
    node_state = ctx.node_state_machine and ctx.node_state_machine:state() or ctx.current_state,
    configured_reactors = ctx.configured_reactors,
    configured_turbines = ctx.configured_turbines,
    target_power = targets.power,
    target_percent = targets.power_percent,
    target_rpm = targets.rpm or (ctx.get_target_rpm and ctx.get_target_rpm()),
    target_steam = targets.steam,
    capacity_max = snapshot and snapshot.capacity_max or 0,
    capacity_ready = snapshot and snapshot.capacity_ready or false,
    capacity_source = snapshot and snapshot.capacity_source or "unknown",
    capacity_stable_samples = snapshot and snapshot.capacity_stable_samples or 0,
    binding = ctx.binding,
    build_label = ctx.build_label or ctx.manifest_id or ctx.release_id
  }

  if not M.monitor_router then
    M.monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = render_overview },
        { name = "Turbines", render = render_turbines },
        { name = "Reactors", render = render_reactors },
        { name = "Diagnostics", render = render_diagnostics }
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
  end
  M.monitor_router:render(monitor, model)
  return snapshot
end

function M.handle_input(event)
  if M.monitor_router then M.monitor_router:handle_input(event) end
end

return M
