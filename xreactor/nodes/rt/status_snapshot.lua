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
      state    = module.state,
      progress = module.progress,
      limits   = module.limits,
      -- Fix: module.type mitschicken damit Master plan_modules()
      -- den Typ korrekt bestimmen kann (statt fragiles name:find())
      type     = module.type,
      name     = module.name or id
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
      -- Feature (2026-07-08): Fuel-Fuellstand mit in den Reaktor-Snapshot
      -- aufnehmen, den RT sowieso schon regelmaessig an Master schickt.
      -- Vorher wurde fuel/fuel_max von adapters/reactor.lua zwar lokal
      -- gelesen, aber nie weitergegeben — die FUEL-Node hatte dadurch
      -- keine Moeglichkeit, den Fuellstand ohne eigenen (nicht vorhandenen)
      -- Wired-Modem-Zugriff auf den Reaktor zu erfahren.
      fuel_amount = info and info.fuel or nil,
      fuel_capacity = info and info.fuel_max or nil,
      state = module and module.state or nil
    })
  end
  return list
end

-- Capacity-Learning ausgelagert nach nodes/rt/capacity_learning.lua
local capacity_learning_lib = require("nodes.rt.capacity_learning")

function M.build_status_payload(ctx)
  local health_payload = ctx.build_health_payload()
  local turbines, actual_output = M.build_turbine_snapshots(ctx.registry, ctx.turbine_adapter, ctx.modules, ctx.log_prefix, ctx.targets)
  local reactors = M.build_reactor_snapshots(ctx.registry, ctx.reactor_adapter, ctx.modules, ctx.log_prefix)
  local capacity = capacity_learning_lib.update(ctx, turbines)
  local capacity_max = capacity and capacity.max_output or 0
  -- Hinweis: capacity_stable_samples/capacity_stable_turbines/
  -- capacity_required_stable_turbines sind Alt-Feldnamen aus der vorherigen
  -- Lock-basierten Learning-Logik — UI (monitor_ui.lua) und Master
  -- (ui_controller.lua) lesen sie noch für die Fortschritts-Anzeige. Die
  -- neue, einfachere Learning-Logik kennt kein "Sample-Fenster" mehr,
  -- daher hier sinnvoll auf die neuen Konzepte gemappt: stable_turbines =
  -- Turbinen aktuell am 900-RPM-Ziel, stable_samples = 1 sobald ready
  -- (kein Lock-Fortschritt mehr nötig, die UI zeigt einfach "fertig").
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
    capacity_ready = capacity and capacity.ready == true or false,
    capacity_source = capacity and capacity.reason or "UNKNOWN",
    capacity_stable_samples = capacity and capacity.ready and 1 or 0,
    capacity_stable_turbines = capacity and capacity.at_target or 0,
    capacity_total_turbines = capacity and capacity.total_turbines or 0,
    capacity_required_stable_turbines = 1,
    capacity_sample_output = capacity_max,
    capacity_topology_generation = capacity and capacity.topology_generation or 0,
    capacity_topology_signature = capacity and capacity.topology_signature or nil,
    capacity_topology_changed_at = capacity and capacity.topology_changed_at or nil,
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
