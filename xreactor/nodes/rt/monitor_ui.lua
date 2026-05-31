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
  local raw = tostring(text or "")
  local w = math.max(1, tonumber(width) or #raw)
  if #raw <= w then return raw end
  if w <= 2 then return raw:sub(1, w) end
  return raw:sub(1, w - 1) .. "~"
end

local function count_bound(summary, kind)
  return summary and summary.kinds and summary.kinds[kind] and summary.kinds[kind].bound or 0
end

local function monitor_snapshot(model)
  return model and model.snapshot and model.snapshot.snapshot or nil
end

local function render_alert_banner(target, model)
  local critical = model.local_alerts_critical or 0
  if critical <= 0 then return end
  ui.badge(target, 2, 2, ("ALERT %d"):format(critical), "EMERGENCY")
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

local function row(target, y, text, status)
  local w = ({ ui.getSize(target) })[1] or 20
  ui.text(target, 2, y, fit(text, w - 3), colors.get(status or "text"), colors.get("background"))
end

local function build_turbine_rows(snapshot)
  local rows = {}
  local turbines = snapshot and snapshot.turbines or {}
  if #turbines == 0 then return { { text = "No turbines visible", status = "WARNING" } } end
  for _, t in ipairs(turbines) do
    local status = t.bound == false and "WARNING" or "OK"
    rows[#rows + 1] = {
      text = ("%s rpm=%s flow=%s out=%s coil=%s active=%s"):format(
        tostring(t.id or "turbine"), fmt(t.rpm, 0), fmt(t.flow, 0), fmt(t.energy, 1),
        t.inductor and "ON" or "OFF", t.active and "ON" or "OFF"
      ),
      status = status
    }
  end
  return rows
end

local function build_reactor_rows(snapshot)
  local rows = {}
  local reactors = snapshot and snapshot.reactors or {}
  if #reactors == 0 then return { { text = "No reactors visible", status = "WARNING" } } end
  for _, r in ipairs(reactors) do
    local status = r.bound == false and "WARNING" or "OK"
    rows[#rows + 1] = {
      text = ("%s temp=%s rods=%s active=%s steam=%s coolant=%s"):format(
        tostring(r.id or "reactor"), fmt(r.temperature, 1), fmt(r.rods, 0),
        r.active and "ON" or "OFF", fmt(r.steam_production, 1), fmt(r.coolant_filled_percentage, 1, "%")
      ),
      status = status
    }
  end
  return rows
end

local function build_diagnostic_rows(model)
  local rows = {
    { text = ("Master: %s (%s)"):format(tostring(model.master_state or "UNKNOWN"), tostring(model.master_age or "n/a")), status = model.master_state == "DOWN" and "WARNING" or "OK" },
    { text = ("Manifest: %s"):format(tostring(model.build_label or "n/a")), status = "LIMITED" },
    { text = ("Comms tx/rx: %d/%d"):format(model.metrics.sent or 0, model.metrics.received or 0) },
    { text = ("Retries: %d drops: %d"):format(model.metrics.retries or 0, model.metrics.dropped or 0) },
    { text = ("Last scan: %s"):format(tostring(model.last_scan or "n/a")) },
    { text = ("Last cmd: %s (%s)"):format(tostring(model.last_command or "none"), tostring(model.last_command_ts or "n/a")) },
    { text = ("Setpoints power=%s rpm=%s steam=%s"):format(fmt(model.target_power, 1), fmt(model.target_rpm, 0), fmt(model.target_steam, 1)), status = "LIMITED" },
    { text = ("Node state=%s control=%s"):format(tostring(model.node_state or "-"), tostring(model.current_state or "-")) }
  }
  if model.local_alerts and #model.local_alerts > 0 then
    rows[#rows + 1] = { text = "Local Alerts:", status = "WARNING" }
    for _, alert in ipairs(model.local_alerts) do
      local sev = alert.severity and alert.severity:sub(1, 1) or "?"
      local title = alert.title or alert.message or alert.code or "alert"
      local status = alert.severity == "CRITICAL" and "EMERGENCY" or alert.severity == "WARN" and "WARNING" or "OK"
      rows[#rows + 1] = { text = string.format("%s %s", sev, title), status = status }
    end
  end
  return rows
end

local function render_overview(target, model)
  local w, h = ui.getSize(target)
  if not w or not h then return end
  local snapshot = monitor_snapshot(model) or {}
  local summary = model.summary or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  local actual = num(snapshot.actual_output, 0)
  local target_power = num(model.target_power, num(snapshot.target_power, 0))
  local p_status, p_pct = power_state(actual, target_power)
  local reactors = count_bound(summary, "reactor")
  local turbines = count_bound(summary, "turbine")

  ui.panel(target, 1, 1, w, h, "RT NODE " .. tostring(model.node_id or "UNKNOWN"), health_status)
  render_alert_banner(target, model)
  ui.badge(target, math.max(2, w - 10), 2, fit(health_status, 8), health_status)
  row(target, 2, ("Master: %s age %s | Mode: %s | State: %s"):format(tostring(model.master_state or "UNKNOWN"), tostring(model.master_age or "n/a"), tostring(model.current_state or "-"), tostring(model.node_state or "-")), model.master_state == "DOWN" and "WARNING" or "text")
  row(target, 3, ("Power Soll %s RF/t | Ist %s RF/t | %.1f%%"):format(fmt(target_power, 1), fmt(actual, 1), p_pct), p_status)
  if w >= 22 then ui.progress(target, 2, 4, math.min(w - 3, 42), math.min(100, p_pct), p_status) end
  row(target, 6, ("Turbines %d | RPM target %s avg %s max %s"):format(turbines, fmt(model.target_rpm, 0), fmt(snapshot.avg_rpm, 0), fmt(snapshot.max_rpm, 0)))
  row(target, 7, ("Reactors %d | Temp avg %s C max %s C"):format(reactors, fmt(snapshot.avg_temp, 1), fmt(snapshot.max_temp, 1)))
  row(target, 8, ("Steam target %s | stored %s"):format(fmt(model.target_steam, 1), fmt(snapshot.steam_amount, 1)))
  row(target, 10, ("Last cmd: %s (%s)"):format(tostring(model.last_command or "none"), tostring(model.last_command_ts or "n/a")), "muted")

  local y = 12
  if turbines == 0 or reactors == 0 then
    local policy = model.binding and model.binding.build_policy and model.binding.build_policy(model.configured_reactors, model.configured_turbines) or {}
    if reactors == 0 then row(target, y, policy.allow_all_reactors and "Reactors: auto-discovery waiting" or "Reactors: explicit binding unmatched", "WARNING"); y = y + 1 end
    if turbines == 0 then row(target, y, policy.allow_all_turbines and "Turbines: auto-discovery waiting" or "Turbines: explicit binding unmatched", "WARNING"); y = y + 1 end
  end
  local rows = build_turbine_rows(snapshot)
  for i = 1, math.min(#rows, math.max(0, h - y)) do
    row(target, y + i - 1, rows[i].text, rows[i].status)
  end
end

local function render_turbines(target, model)
  local w, h = ui.getSize(target)
  if not w or not h then return end
  local snapshot = monitor_snapshot(model) or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  ui.panel(target, 1, 1, w, h, "RT TURBINES " .. tostring(model.node_id or "UNKNOWN"), health_status)
  render_alert_banner(target, model)
  row(target, 2, ("Total %d | Output %s RF/t | Avg RPM %s"):format(#(snapshot.turbines or {}), fmt(snapshot.actual_output, 1), fmt(snapshot.avg_rpm, 0)), "LIMITED")
  ui.list(target, 2, 4, w - 2, build_turbine_rows(snapshot), { max_rows = h - 5 })
end

local function render_reactors(target, model)
  local w, h = ui.getSize(target)
  if not w or not h then return end
  local snapshot = monitor_snapshot(model) or {}
  local health_status = model.health and model.health.status or "OFFLINE"
  ui.panel(target, 1, 1, w, h, "RT REACTORS " .. tostring(model.node_id or "UNKNOWN"), health_status)
  render_alert_banner(target, model)
  row(target, 2, ("Total %d | Steam %s | Avg Temp %s C"):format(#(snapshot.reactors or {}), fmt(snapshot.steam_amount, 1), fmt(snapshot.avg_temp, 1)), "LIMITED")
  ui.list(target, 2, 4, w - 2, build_reactor_rows(snapshot), { max_rows = h - 5 })
end

local function render_diagnostics(target, model)
  local w, h = ui.getSize(target)
  if not w or not h then return end
  local health_status = model.health and model.health.status or "OFFLINE"
  ui.panel(target, 1, 1, w, h, "RT DIAGNOSTICS", health_status)
  render_alert_banner(target, model)
  ui.list(target, 2, 3, w - 2, build_diagnostic_rows(model), { max_rows = h - 4 })
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
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      rpm = rpm,
      flow = flow,
      energy = energy,
      active = active,
      inductor = inductor
    }
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
    target_rpm = ctx.targets and ctx.targets.rpm or nil,
    target_steam = ctx.targets and ctx.targets.steam or nil,
    actual_output = actual_output,
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
    target_rpm = targets.rpm or (ctx.get_target_rpm and ctx.get_target_rpm()),
    target_steam = targets.steam,
    get_target_rpm = ctx.get_target_rpm,
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
