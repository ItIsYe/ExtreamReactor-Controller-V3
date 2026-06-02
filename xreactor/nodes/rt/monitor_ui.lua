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
  if not n then return "n/a" end
  return string.format("%." .. tostring(digits or 1) .. "f%s", n, suffix or "")
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

local function status_color(status)
  return colors.get(status or "text")
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

local function write_line(mon, y, text, status)
  local w = ({ ui.getSize(mon) })[1] or 20
  if y < 1 then return end
  ui.text(mon, 2, y, fit(text, math.max(1, w - 3)), status_color(status), colors.get("background"))
end

local function badge_line(mon, y, badges)
  local w = ({ ui.getSize(mon) })[1] or 20
  local x = 2
  for _, badge in ipairs(badges or {}) do
    if x >= w then break end
    local label = fit(badge[1], math.max(4, math.min(12, w - x)))
    ui.badge(mon, x, y, label, badge[2] or "OK")
    x = x + #label + 3
  end
end

local function simple_table_header(mon, y, labels, widths)
  local x = 2
  for i, label in ipairs(labels or {}) do
    local cw = widths[i] or 8
    ui.text(mon, x, y, pad(label, cw - 1), colors.get("muted"), colors.get("background"))
    x = x + cw
  end
end

local function simple_table_row(mon, y, values, widths, status, status_col)
  local x = 2
  for i, value in ipairs(values or {}) do
    local cw = widths[i] or 8
    local key = (i == (status_col or 1)) and (status or "text") or (i == #values and "muted" or "text")
    ui.text(mon, x, y, pad(value or "-", cw - 1), colors.get(key), colors.get("background"))
    x = x + cw
  end
end

local function clear_and_title(mon, title, status)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, title, status or "OK")
  return w, h
end

local function render_compact_header(mon, model, title)
  local health_status = model.health and model.health.status or "OFFLINE"
  badge_line(mon, 2, {
    { "RT " .. tostring(health_status), health_status },
    { "M " .. tostring(model.master_state or "?"), master_status(model) },
    { tostring(model.current_state or "-"), tostring(model.current_state) == "MASTER" and "OK" or "LIMITED" },
    { model.capacity_ready and "CAP" or "LEARN", capacity_status(model) }
  })
  write_line(mon, 3, fit(title .. " | " .. tostring(model.node_id or "UNKNOWN") .. " | " .. tostring(model.node_state or "-"), 120), "text")
  return 4
end

local function render_overview(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local summary = model.summary or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT OVERVIEW", health_status)
  local y = render_compact_header(mon, model, "Overview")

  local actual = num(snapshot.actual_output, 0)
  local target_power = num(model.target_power, num(snapshot.target_power, 0))
  local p_status, p_pct = power_state(actual, target_power)
  local capacity = num(model.capacity_max, 0)
  local capacity_pct = capacity > 0 and math.min(100, (actual / capacity) * 100) or 0
  local reactors = count_bound(summary, "reactor")
  local turbines = count_bound(summary, "turbine")

  write_line(mon, y, string.format("Power %s%%  Soll %s  Ist %s", fmt(p_pct, 1), fmt(target_power, 1), fmt(actual, 1)), p_status); y = y + 1
  if w >= 20 then ui.progress(mon, 2, y, math.max(8, w - 3), math.min(100, p_pct), p_status) end; y = y + 1
  write_line(mon, y, string.format("Master %s -> %s RF/t", fmt(model.target_percent, 1, "%"), fmt(target_power, 1)), "text"); y = y + 1
  write_line(mon, y, string.format("Cap %s %s  Ist %.1f%%", fmt(capacity, 1), model.capacity_ready and "locked" or "learning", capacity_pct), capacity_status(model)); y = y + 1
  write_line(mon, y, string.format("RPM %s/%s  Steam %s", fmt(snapshot.avg_rpm, 0), fmt(model.target_rpm, 0), fmt(snapshot.steam_amount, 1)), "muted"); y = y + 1
  write_line(mon, y, string.format("R:%d T:%d  Cmd:%s  M-age:%s", reactors, turbines, tostring(model.last_command or "-"), tostring(model.master_age or "n/a")), "text"); y = y + 1

  local list = snapshot.turbines or {}
  if y <= h - 1 and #list > 0 then
    simple_table_header(mon, y, { "T", "RPM", "RF/t", "C" }, { 7, 7, 9, 4 }); y = y + 1
    for i = 1, math.min(#list, math.max(0, h - y)) do
      local t = list[i]
      simple_table_row(mon, y, { tostring(t.id or i), fmt(t.rpm, 0), fmt(t.energy, 1), t.inductor and "ON" or "OFF" }, { 7, 7, 9, 4 }, (t.bound == false) and "WARNING" or "OK", 4)
      y = y + 1
    end
  end
end

local function render_turbines(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT TURBINES", health_status)
  local y = render_compact_header(mon, model, "Turbines")
  local turbines = snapshot.turbines or {}
  write_line(mon, y, string.format("Total %d  Out %s  AvgRPM %s", #turbines, fmt(snapshot.actual_output, 1), fmt(snapshot.avg_rpm, 0)), "text"); y = y + 1
  simple_table_header(mon, y, { "ID", "RPM", "Flow", "RF/t", "C" }, { 8, 7, 7, 8, 4 }); y = y + 1
  for i = 1, math.min(#turbines, math.max(0, h - y)) do
    local t = turbines[i]
    local status = (t.bound == false) and "WARNING" or "OK"
    if t.rpm and num(model.target_rpm, 0) > 0 and math.abs(num(t.rpm, 0) - num(model.target_rpm, 0)) > 40 then status = "WARNING" end
    simple_table_row(mon, y, { tostring(t.id or i), fmt(t.rpm, 0), fmt(t.flow, 0), fmt(t.energy, 1), t.inductor and "ON" or "OFF" }, { 8, 7, 7, 8, 4 }, status, 5)
    y = y + 1
  end
  if #turbines == 0 then write_line(mon, y, "Keine Turbinen sichtbar", "WARNING") end
end

local function render_reactors(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT REACTORS", health_status)
  local y = render_compact_header(mon, model, "Reactors")
  local reactors = snapshot.reactors or {}
  write_line(mon, y, string.format("Total %d  AvgT %sC  Steam %s", #reactors, fmt(snapshot.avg_temp, 1), fmt(snapshot.steam_amount, 1)), "text"); y = y + 1
  simple_table_header(mon, y, { "ID", "Temp", "Rods", "Act", "Steam" }, { 8, 8, 7, 5, 8 }); y = y + 1
  for i = 1, math.min(#reactors, math.max(0, h - y)) do
    local r = reactors[i]
    local status = (r.bound == false) and "WARNING" or (r.active == false and "LIMITED" or "OK")
    simple_table_row(mon, y, { tostring(r.id or i), fmt(r.temperature, 1), fmt(r.rods, 0), r.active and "ON" or "OFF", fmt(r.steam_production, 1) }, { 8, 8, 7, 5, 8 }, status, 4)
    y = y + 1
  end
  if #reactors == 0 then write_line(mon, y, "Keine Reaktoren sichtbar", "WARNING") end
end

local function render_diagnostics(mon, model)
  local health_status = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT DIAG", health_status)
  local y = render_compact_header(mon, model, "Diag")
  local rows = {
    { "Master", tostring(model.master_state or "UNKNOWN") .. " age " .. tostring(model.master_age or "n/a"), master_status(model) },
    { "Comms", string.format("tx/rx %d/%d", model.metrics.sent or 0, model.metrics.received or 0), "OK" },
    { "Retry", string.format("r%d d%d", model.metrics.retries or 0, model.metrics.dropped or 0), ((model.metrics.dropped or 0) > 0) and "WARNING" or "OK" },
    { "Set", string.format("%s / %s", fmt(model.target_power, 1), fmt(model.target_percent, 1, "%")), "LIMITED" },
    { "RPM", fmt(model.target_rpm, 0) .. " steam " .. fmt(model.target_steam, 1), "LIMITED" },
    { "Cap", fmt(model.capacity_max, 1) .. " " .. tostring(model.capacity_source or "-"), capacity_status(model) },
    { "Cmd", tostring(model.last_command or "none") .. " " .. tostring(model.last_command_ts or "n/a"), "OK" },
    { "Scan", tostring(model.last_scan or "n/a"), "OK" }
  }
  for _, r in ipairs(rows) do
    if y > h then break end
    ui.text(mon, 2, y, pad(r[1], 8), colors.get(r[3]), colors.get("background"))
    ui.text(mon, 10, y, fit(r[2], math.max(1, w - 11)), colors.get("text"), colors.get("background"))
    y = y + 1
  end
  local alerts = model.local_alerts or {}
  if y <= h and #alerts > 0 then
    write_line(mon, y, "Alerts:", "WARNING"); y = y + 1
    for i = 1, math.min(#alerts, math.max(0, h - y + 1)) do
      local a = alerts[i]
      write_line(mon, y, tostring(a.severity or "INFO") .. " " .. tostring(a.title or a.message or a.code or "alert"), a.severity == "CRITICAL" and "EMERGENCY" or "WARNING")
      y = y + 1
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
  local targets = ctx.targets or {}
  local model = {
    snapshot = { snapshot = snapshot, local_alerts = alert_payload and alert_payload.critical or 0 },
    health = health_payload,
    summary = summary,
    comms = comms_diag,
    metrics = metrics,
    master_state = master_state,
    master_age = master_age,
    last_scan = ctx.devices.last_scan_ts and (math.floor((now - ctx.devices.last_scan_ts) / 1000) .. "s") or "n/a",
    last_command = ctx.last_command,
    last_command_ts = ctx.last_command_ts and (math.floor((now - ctx.last_command_ts) / 1000) .. "s") or "n/a",
    local_alerts = alert_payload and alert_payload.top or {},
    local_alerts_critical = alert_payload and alert_payload.critical or 0,
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
