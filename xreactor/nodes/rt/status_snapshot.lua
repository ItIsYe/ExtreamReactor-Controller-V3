local health = require("core.health")

local M = {}

local function numeric_value(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then
    local n = tonumber(value)
    if n then return n end
  end
  return nil
end

local function bool_or_nil(value)
  if type(value) == "boolean" then return value end
  return nil
end

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
  local total_output = 0
  for _, entry in ipairs(registry:get_bound_devices("turbine")) do
    local info = turbine_adapter.inspect(entry.name, log_prefix)
    local module = modules[entry.id]
    local energy = info and numeric_value(info.energy) or nil
    if energy then total_output = total_output + energy end
    table.insert(list, {
      id = entry.id,
      name = entry.name,
      alias = entry.alias,
      rpm = info and info.rpm or nil,
      flow_rate = info and info.flow or nil,
      energy = energy,
      output = energy,
      target_rpm = targets.rpm,
      coil_engaged = info and bool_or_nil(info.coil_engaged) or nil,
      state = module and module.state or nil
    })
  end
  return list, total_output
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
      coolant_amount = info and info.coolant_amount or nil,
      coolant_amount_max = info and info.coolant_amount_max or nil,
      coolant_filled_percentage = info and info.coolant_filled_percentage or nil,
      coolant_ratio = info and info.coolant_ratio or nil,
      coolant_ratio_source = info and info.coolant_ratio_source or nil,
      state = module and module.state or nil
    })
  end
  return list
end

local function turbines_stable_for_capacity(turbines, target_rpm)
  if type(turbines) ~= "table" or #turbines == 0 then return false, "NO_TURBINES" end
  local target = numeric_value(target_rpm) or 900
  local tolerance = math.max(10, target * 0.10)
  local producing = 0
  for _, turbine in ipairs(turbines) do
    local rpm = numeric_value(turbine.rpm)
    local energy = numeric_value(turbine.energy)
    local coil = turbine.coil_engaged
    if not rpm then return false, "RPM_UNAVAILABLE" end
    if math.abs(rpm - target) > tolerance then return false, "RPM_NOT_STABLE_10PCT" end
    if not energy or energy <= 0 then return false, "OUTPUT_UNAVAILABLE" end
    if coil == false then return false, "COIL_OFF" end
    producing = producing + 1
  end
  if producing <= 0 then return false, "NO_OUTPUT" end
  return true, "STABLE_10PCT"
end

function M.update_capacity_learning(ctx, turbines, actual_output)
  ctx.capacity_learning = ctx.capacity_learning or {
    locked = false,
    stable_samples = 0,
    max_candidate = 0,
    max_output = 0,
    reason = "INIT"
  }
  local learning = ctx.capacity_learning
  if learning.locked then return learning end

  local output = numeric_value(actual_output) or 0
  local stable, reason = turbines_stable_for_capacity(turbines, ctx.targets and ctx.targets.rpm)
  learning.reason = reason
  if stable and output > 0 then
    learning.stable_samples = (learning.stable_samples or 0) + 1
    learning.max_candidate = math.max(learning.max_candidate or 0, output)
    if learning.stable_samples >= 3 then
      learning.max_output = learning.max_candidate
      learning.locked = true
      learning.reason = "LOCKED_STABLE_10PCT_MAX"
      if type(ctx.log) == "function" then
        pcall(ctx.log, "INFO", string.format("RT capacity locked output=%.2f samples=%d tolerance=10pct", learning.max_output, learning.stable_samples))
      end
    end
  else
    learning.stable_samples = 0
  end
  return learning
end

function M.build_status_payload(ctx)
  local health_payload = ctx.build_health_payload()
  local turbines, actual_output = M.build_turbine_snapshots(ctx.registry, ctx.turbine_adapter, ctx.modules, ctx.log_prefix, ctx.targets)
  local reactors = M.build_reactor_snapshots(ctx.registry, ctx.reactor_adapter, ctx.modules, ctx.log_prefix)
  local capacity = M.update_capacity_learning(ctx, turbines, actual_output)
  local capacity_max = capacity and capacity.max_output or 0
  return {
    status = ctx.status_level,
    state = ctx.node_state_machine:state(),
    mode = ctx.current_state,
    output = ctx.targets.power,
    target_output = ctx.targets.power,
    power_target = ctx.targets.power,
    power_target_percent = ctx.targets.power_percent,
    actual_output = actual_output,
    power_actual = actual_output,
    capacity_max = capacity_max,
    capacity_ready = capacity and capacity.locked == true or false,
    capacity_source = capacity and capacity.reason or "UNKNOWN",
    capacity_stable_samples = capacity and capacity.stable_samples or 0,
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
    reactor_adapter = ctx.reactor_adapter,
    turbine_adapter = ctx.turbine_adapter,
    log_prefix = ctx.log_prefix,
    get_device_caps = ctx.get_device_caps,
    get_available_steam = ctx.get_available_steam,
    last_status_snapshot = ctx.last_status_snapshot,
    capacity_learning = ctx.capacity_learning
  })
end

return M
