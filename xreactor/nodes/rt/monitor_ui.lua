local ui = require("core.ui")
local ui_router = require("core.ui_router")
local support_ui_pages = require("nodes.support.ui_pages")
local mockup_pages = require("nodes.rt.mockup_pages")
local ok_utils, utils = pcall(require, "core.utils")
if not ok_utils or type(utils) ~= "table" then utils = nil end

local M = {
  monitor_router = nil,
  last_monitor_update = 0,
  main_monitor_name = nil,
  last_monitor = nil,
  last_capacity_ready = nil,
}

local function num(value, fallback)
  if type(value) == "number" then return value end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then return parsed end
  end
  return fallback
end

local function try_set_scale(monitor, scale)
  if monitor and type(scale) == "number" then ui.setScale(monitor, scale) end
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
    if monitor then
      try_set_scale(monitor, monitor_scale)
      return monitor, preferred_name
    end
  end
  if preferred_name and peripheral and type(peripheral.wrap) == "function" then
    local monitor = peripheral.wrap(preferred_name)
    if monitor then
      try_set_scale(monitor, monitor_scale)
      return monitor, preferred_name
    end
  end
  return nil, preferred_name and ("monitor unavailable: " .. tostring(preferred_name)) or "no monitor found"
end

local function rt_status(model)
  if not model.capacity_ready then return "LIMITED" end
  local assignment = tostring(model.assignment_state or "")
  if assignment == "shutdown" or assignment == "shed" or assignment == "standby" then return "muted" end
  if assignment == "startup" then return "LIMITED" end
  local snapshot = model.snapshot and model.snapshot.snapshot or {}
  local target = num(model.target_power, num(snapshot.target_power, 0))
  local actual = num(snapshot.actual_output, 0)
  if target <= 0 then return "muted" end
  local ratio = actual / target
  if ratio >= 0.85 and ratio <= 1.15 then return "OK" end
  if ratio < 0.5 then return "EMERGENCY" end
  return "WARNING"
end

function M.collect_reactor_temp_stats(devices, reactor_adapter, log_prefix)
  local min_temp, max_temp, sum_temp, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.reactors or {}) do
    local info = reactor_adapter and type(reactor_adapter.inspect) == "function" and entry and entry.name and reactor_adapter.inspect(entry.name, log_prefix) or nil
    local temp = type(info) == "table" and info.temperature or nil
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
    local rpm = read_turbine_rpm(entry.peripheral, get_device_caps("turbine", entry.id))
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
  local list, total_output = {}, 0
  for _, entry in ipairs(devices.turbines or {}) do
    local turbine = entry.peripheral
    local caps = get_device_caps("turbine", entry.id)
    local info = turbine_adapter and type(turbine_adapter.inspect) == "function" and entry and entry.name and turbine_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local energy = num(info.energy, nil)
    if energy then total_output = total_output + energy end
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      rpm = info.rpm or read_turbine_rpm(turbine, caps),
      flow = info.flow or read_turbine_flow(turbine, caps),
      energy = energy,
      active = info.active,
      inductor = info.coil_engaged,
    }
  end
  return list, total_output
end

function M.build_reactor_status_details(devices, reactor_adapter, log_prefix)
  local list = {}
  for _, entry in ipairs(devices.reactors or {}) do
    local info = reactor_adapter and type(reactor_adapter.inspect) == "function" and entry and entry.name and reactor_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local rods = info.control_rod_level
    if rods == nil and reactor_adapter and type(reactor_adapter.read_control_rods) == "function" and entry and entry.name then
      rods = reactor_adapter.read_control_rods(entry.name, log_prefix)
    end
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      temperature = info.temperature,
      fuel = info.fuel,
      energy_stored = info.energy_stored,
      energy_output = info.energy_output,
      waste = info.waste,
      active = info.active,
      is_actively_cooled = info.is_actively_cooled,
      rods = rods,
      steam_production = info.steam,
      coolant_amount = info.coolant_amount,
      coolant_amount_max = info.coolant_amount_max,
      coolant_filled_percentage = info.coolant_filled_percentage,
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
    capacity_ready = capacity.ready == true,
    capacity_source = capacity.reason or (ctx.targets and ctx.targets.capacity_source) or "unknown",
    capacity_stable_samples = capacity.ready and 1 or 0,
    capacity_stable_turbines = capacity.at_target or 0,
    capacity_total_turbines = capacity.total_turbines or 0,
    reactors = M.build_reactor_status_details(ctx.devices, ctx.reactor_adapter, ctx.log_prefix),
    turbines = turbines,
  }
  return ctx.last_status_snapshot
end

function M.init(monitor_adapter, configured_monitor, monitor_scale)
  M.monitor_router = nil
  M.last_monitor_update = 0
  local monitor, name_or_err = resolve_monitor(monitor_adapter, configured_monitor, monitor_scale)
  if not monitor then return nil, name_or_err end
  M.main_monitor_name = name_or_err
  return monitor, name_or_err
end

-- Feature (2026-07-05): Skalierung live aendern OHNE M.monitor_router
-- zurueckzusetzen — M.init() wuerde das tun (bewusst, fuer den normalen
-- Boot-Fall), was aber bei einer Touch-ausgeloesten Skalen-Aenderung den
-- Nutzer ungewollt von der aktuellen Seite (z.B. Diagnostics 4/4) zurueck
-- auf Overview werfen wuerde.
function M.set_scale(monitor, scale)
  if not monitor then return end
  try_set_scale(monitor, scale)
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
    assignment_state = targets.assignment_state,
    capacity_max = snapshot and snapshot.capacity_max or 0,
    capacity_ready = snapshot and snapshot.capacity_ready or false,
    capacity_source = snapshot and snapshot.capacity_source or "unknown",
    capacity_stable_samples = snapshot and snapshot.capacity_stable_samples or 0,
    capacity_stable_turbines = snapshot and snapshot.capacity_stable_turbines or 0,
    capacity_total_turbines = snapshot and snapshot.capacity_total_turbines or 0,
    binding = ctx.binding,
    build_label = ctx.build_label or ctx.manifest_id or ctx.release_id,
    -- Feature (2026-07-05): Monitor-Skalierung per Touch auf der
    -- Diagnostics-Seite einstellbar. ctx.monitor_scale wird von main.lua
    -- gesetzt (der aktuell wirksame, ggf. per Touch geaenderte Wert).
    monitor_scale = ctx.monitor_scale,
  }

  if not M.monitor_router then
    M.monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = mockup_pages.render_overview },
        { name = "Turbines", render = mockup_pages.render_turbines },
        { name = "Reactors", render = mockup_pages.render_reactors },
        { name = "Diagnostics", render = mockup_pages.render_diagnostics },
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true },
    })
  end

  M.last_monitor = monitor
  M.monitor_router:render(monitor, model)

  pcall(function()
    if not ampel_instance then return end
    ampel_instance.render(M.main_monitor_name, rt_status(model))
  end)

  pcall(function()
    if M.last_capacity_ready == nil then
      M.last_capacity_ready = model.capacity_ready == true
      return
    end
    if model.capacity_ready == true and M.last_capacity_ready == false then
      local ok_spk_mod, spk_mod = pcall(require, "optional.speaker_alarm")
      if ok_spk_mod and type(spk_mod) == "table" and type(spk_mod.new) == "function" then
        local speaker = spk_mod.new()
        pcall(speaker.play, "capacity_learned")
      end
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
      -- Feature (2026-07-05): Monitor-Skalierung per Touch. War im
      -- vorherigen Commit (338a10d5fa) versehentlich nur teilweise
      -- gepusht — nur das Model-Feld monitor_scale kam an, dieser
      -- Handler-Block fehlte komplett, weshalb die Buttons visuell
      -- sichtbar aber komplett funktionslos waren.
      local hits = mockup_pages.scale_hit_cache and mockup_pages.scale_hit_cache[M.last_monitor]
      if hits then
        local x, y = event[3], event[4]
        local function in_zone(zone)
          return zone and y == zone.y and x >= zone.x1 and x <= zone.x2
        end
        if in_zone(hits.minus) and type(M.on_scale_change) == "function" then
          M.on_scale_change(-0.5)
        elseif in_zone(hits.plus) and type(M.on_scale_change) == "function" then
          M.on_scale_change(0.5)
        end
      end
    end
  end
end

return M
