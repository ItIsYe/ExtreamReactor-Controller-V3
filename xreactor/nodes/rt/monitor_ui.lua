local ui = require("core.ui")
local ui_router = require("core.ui_router")
local colors = require("shared.colors")

local M = {
  monitor_router = nil,
  last_monitor_update = 0
}

local function warn(message)
  print("[RT][MONITOR_UI][WARN] " .. tostring(message))
end

local function try_set_scale(monitor, scale, monitor_name)
  if not monitor or type(scale) ~= "number" or not monitor.setTextScale then
    return
  end
  local ok, err = pcall(monitor.setTextScale, monitor, scale)
  if not ok then
    warn(("setTextScale failed for %s: %s"):format(tostring(monitor_name), tostring(err)))
  end
end

local function normalize_monitor_result(result)
  if type(result) == "table" then
    if result.mon then
      return result.mon, result.name
    end
    if result.monitor then
      return result.monitor, result.name
    end
  end
  return result
end

local function resolve_monitor(monitor_adapter, preferred_name, monitor_scale)
  if type(monitor_adapter) ~= "table" then
    return nil, "monitor adapter missing"
  end

  if type(monitor_adapter.find) == "function" then
    local found = monitor_adapter.find(preferred_name, "first", monitor_scale, "RT")
    local monitor, monitor_name = normalize_monitor_result(found)
    if monitor then
      return monitor, monitor_name
    end
  end

  if type(monitor_adapter.wrap) == "function" and preferred_name then
    local monitor = monitor_adapter.wrap(preferred_name)
    if monitor then
      try_set_scale(monitor, monitor_scale, preferred_name)
      return monitor, preferred_name
    end
  end

  if preferred_name and peripheral and type(peripheral.wrap) == "function" then
    local monitor = peripheral.wrap(preferred_name)
    if monitor then
      try_set_scale(monitor, monitor_scale, preferred_name)
      return monitor, preferred_name
    end
  end

  return nil, preferred_name and ("monitor unavailable: " .. tostring(preferred_name)) or "no monitor found"
end

local function format_value(value)
  if type(value) ~= "number" then
    return "n/a"
  end
  return string.format("%.1f", value)
end

local function render_alert_banner(target, model)
  local critical = model.local_alerts_critical or 0
  if critical <= 0 then
    return
  end
  ui.badge(target, 2, 2, ("ALERT %d"):format(critical), "EMERGENCY")
end

local function monitor_snapshot(model)
  return model and model.snapshot and model.snapshot.snapshot or nil
end

local function build_details_rows(snapshot)
  if not snapshot then
    return { { text = "Snapshot unavailable", status = "WARNING" } }
  end
  return {
    { text = ("Average RPM: %s"):format(format_value(snapshot.avg_rpm)) },
    { text = ("Average Temp: %s"):format(format_value(snapshot.avg_temp)) },
    { text = ("Max Temp: %s"):format(format_value(snapshot.max_temp)) },
    { text = ("Steam Stored: %s"):format(format_value(snapshot.steam_amount)) }
  }
end

local function build_diagnostic_rows(model)
  local rows = {
    { text = ("Master: %s (%s)"):format(model.master_state, model.master_age), status = model.master_state == "DOWN" and "WARNING" or "OK" },
    { text = ("Comms tx/rx: %d/%d"):format(model.metrics.sent or 0, model.metrics.received or 0) },
    { text = ("Retries: %d, drops: %d"):format(model.metrics.retries or 0, model.metrics.dropped or 0) },
    { text = ("Last scan: %s"):format(model.last_scan) },
    { text = ("Last cmd: %s (%s)"):format(model.last_command or "none", model.last_command_ts) }
  }
  if model.local_alerts and #model.local_alerts > 0 then
    table.insert(rows, { text = "Local Alerts:", status = "WARNING" })
    for _, alert in ipairs(model.local_alerts) do
      local sev = alert.severity and alert.severity:sub(1, 1) or "?"
      local title = alert.title or alert.message or alert.code or "alert"
      local status = alert.severity == "CRITICAL" and "EMERGENCY" or alert.severity == "WARN" and "WARNING" or "OK"
      table.insert(rows, { text = string.format("%s %s", sev, title), status = status })
    end
  end
  return rows
end

local function render_overview(target, model)
  local w, h = ui.getSize(target)
  if not w or not h then
    return
  end
  local snapshot = monitor_snapshot(model)
  ui.panel(target, 1, 1, w, h, "RT NODE", model.health.status)
  render_alert_banner(target, model)
  ui.text(target, 2, 2, ("ID: %s"):format(model.node_id or "UNKNOWN"), colors.get("text"), colors.get("background"))
  ui.badge(target, w - 6, 2, model.health.status, model.health.status)
  ui.text(target, 2, 4, ("State: %s"):format(model.current_state), colors.get("text"), colors.get("background"))
  ui.text(target, 2, 5, ("Reactors: %d"):format(model.summary.kinds.reactor and model.summary.kinds.reactor.bound or 0), colors.get("text"), colors.get("background"))
  ui.text(target, 2, 6, ("Turbines: %d"):format(model.summary.kinds.turbine and model.summary.kinds.turbine.bound or 0), colors.get("text"), colors.get("background"))
  local policy = model.binding.build_policy(model.configured_reactors, model.configured_turbines)
  if (model.summary.kinds.reactor and model.summary.kinds.reactor.bound or 0) == 0 then
    ui.text(target, 2, 7, policy.allow_all_reactors and "Reactors: auto-discovery waiting" or "Reactors: explicit binding unmatched", colors.get("WARNING"), colors.get("background"))
  else
    ui.text(target, 2, 7, ("Avg Temp: %.1f"):format(snapshot and snapshot.avg_temp or 0), colors.get("text"), colors.get("background"))
  end
  if (model.summary.kinds.turbine and model.summary.kinds.turbine.bound or 0) == 0 then
    ui.text(target, 2, 8, policy.allow_all_turbines and "Turbines: auto-discovery waiting" or "Turbines: explicit binding unmatched", colors.get("WARNING"), colors.get("background"))
  else
    ui.text(target, 2, 8, ("Target RPM: %d"):format(model.get_target_rpm()), colors.get("text"), colors.get("background"))
  end
end

local function render_details(target, model)
  local w, h = ui.getSize(target)
  if not w or not h then
    return
  end
  local snapshot = monitor_snapshot(model)
  ui.panel(target, 1, 1, w, h, "RT DETAILS", model.health.status)
  render_alert_banner(target, model)
  local rows = build_details_rows(snapshot)
  ui.list(target, 2, 3, w - 2, rows, { max_rows = h - 4 })
end

local function render_diagnostics(target, model)
  local w, h = ui.getSize(target)
  if not w or not h then
    return
  end
  ui.panel(target, 1, 1, w, h, "RT DIAGNOSTICS", model.health.status)
  render_alert_banner(target, model)
  local rows = build_diagnostic_rows(model)
  ui.list(target, 2, 3, w - 2, rows, { max_rows = h - 4 })
end

function M.collect_reactor_temp_stats(devices)
  local min_temp = nil
  local max_temp = nil
  local sum_temp = 0
  local count = 0
  for _, entry in ipairs(devices.reactors or {}) do
    local temp = entry.peripheral and entry.peripheral.getTemperature and entry.peripheral.getTemperature()
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
  local min_rpm = nil
  local max_rpm = nil
  local sum_rpm = 0
  local count = 0
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

function M.build_turbine_status_details(devices, read_turbine_rpm, read_turbine_flow, get_device_caps)
  local list = {}
  for _, entry in ipairs(devices.turbines or {}) do
    local turbine = entry.peripheral
    local caps = get_device_caps("turbine", entry.id)
    local rpm = read_turbine_rpm(turbine, caps)
    local flow = read_turbine_flow(turbine, caps)
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      rpm = rpm,
      flow = flow,
      active = turbine and turbine.getActive and turbine.getActive() or nil,
      inductor = turbine and turbine.getInductorEngaged and turbine.getInductorEngaged() or nil
    }
  end
  return list
end

function M.build_reactor_status_details(devices)
  local list = {}
  for _, entry in ipairs(devices.reactors or {}) do
    local reactor = entry.peripheral
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      temperature = reactor and reactor.getTemperature and reactor.getTemperature() or nil,
      fuel = reactor and reactor.getFuelAmount and reactor.getFuelAmount() or nil,
      active = reactor and reactor.getActive and reactor.getActive() or nil,
      rods = reactor and reactor.getControlRodLevel and reactor.getControlRodLevel(0) or nil
    }
  end
  return list
end

function M.update_status_snapshot(ctx)
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary() or {}
  local min_temp, max_temp, avg_temp = M.collect_reactor_temp_stats(ctx.devices)
  local min_rpm, max_rpm, avg_rpm = M.collect_turbine_rpm_stats(ctx.devices, ctx.read_turbine_rpm, ctx.get_device_caps)
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
    reactors = M.build_reactor_status_details(ctx.devices),
    turbines = M.build_turbine_status_details(ctx.devices, ctx.read_turbine_rpm, ctx.read_turbine_flow, ctx.get_device_caps)
  }
  return ctx.last_status_snapshot
end

function M.init(monitor_adapter, configured_monitor, monitor_scale)
  M.monitor_router = nil
  M.last_monitor_update = 0
  local monitor, monitor_name_or_err = resolve_monitor(monitor_adapter, configured_monitor, monitor_scale)
  if not monitor then
    return nil, monitor_name_or_err
  end
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
    configured_reactors = ctx.configured_reactors,
    configured_turbines = ctx.configured_turbines,
    get_target_rpm = ctx.get_target_rpm,
    binding = ctx.binding
  }

  if not M.monitor_router then
    M.monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = render_overview },
        { name = "Details", render = render_details },
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
  if M.monitor_router then
    M.monitor_router:handle_input(event)
  end
end

return M
