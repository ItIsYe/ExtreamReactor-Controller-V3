local health = require("core.health")

local M = {}

function M.build_module_payload(modules)
  local snapshot = {}
  for id, module in pairs(modules or {}) do
    snapshot[id] = {
      state = module.state,
      progress = module.progress,
      limits = module.limits
    }
  end
  return snapshot
end

function M.build_turbine_snapshots(registry, turbine_adapter, modules, log_prefix, targets)
  local list = {}
  for _, entry in ipairs(registry:get_bound_devices("turbine")) do
    local info = turbine_adapter.inspect(entry.name, log_prefix)
    local module = modules[entry.id]
    table.insert(list, {
      id = entry.id,
      name = entry.name,
      alias = entry.alias,
      rpm = info and info.rpm or nil,
      flow_rate = info and info.flow or nil,
      target_rpm = targets.rpm,
      coil_engaged = info and info.coil_engaged or nil,
      state = module and module.state or nil
    })
  end
  return list
end

function M.build_reactor_snapshots(registry, reactor_adapter, modules, log_prefix)
  local list = {}
  for _, entry in ipairs(registry:get_bound_devices("reactor")) do
    local info = reactor_adapter.inspect(entry.name, log_prefix)
    local module = modules[entry.id]
    table.insert(list, {
      id = entry.id,
      name = entry.name,
      alias = entry.alias,
      rods_level = info and info.control_rod_level or nil,
      active = info and info.active or nil,
      steam_production = info and info.steam or nil,
      state = module and module.state or nil
    })
  end
  return list
end

function M.build_status_payload(ctx)
  local health_payload = ctx.build_health_payload()
  local turbines = M.build_turbine_snapshots(ctx.registry, ctx.turbine_adapter, ctx.modules, ctx.log_prefix, ctx.targets)
  local reactors = M.build_reactor_snapshots(ctx.registry, ctx.reactor_adapter, ctx.modules, ctx.log_prefix)
  return {
    status = ctx.status_level,
    state = ctx.node_state_machine:state(),
    mode = ctx.current_state,
    output = ctx.targets.power,
    turbine_rpm = ctx.targets.rpm,
    steam = ctx.targets.steam,
    capabilities = health_payload.capabilities,
    bindings = health_payload.bindings,
    bindings_summary = health.summarize_bindings(health_payload.bindings),
    health = health_payload,
    modules = M.build_module_payload(ctx.modules),
    snapshot = ctx.status_snapshot,
    turbines = turbines,
    reactors = reactors,
    registry = {
      summary = ctx.devices.registry_summary or ctx.registry:get_summary(),
      devices = ctx.registry:get_devices_by_kind(),
      diagnostics = ctx.registry:get_diagnostics()
    },
    control_mode = ctx.current_state,
    ramp_state = { active_module = ctx.active_startup, queue = ctx.startup_queue }
  }
end

function M.update_status_snapshot(ctx)
  return ctx.monitor_ui.update_status_snapshot({
    devices = ctx.devices,
    registry = ctx.registry,
    comms = ctx.comms,
    config = ctx.config,
    read_turbine_rpm = ctx.read_turbine_rpm,
    read_turbine_flow = ctx.read_turbine_flow,
    get_device_caps = ctx.get_device_caps,
    get_available_steam = ctx.get_available_steam,
    last_status_snapshot = ctx.last_status_snapshot
  })
end

return M
