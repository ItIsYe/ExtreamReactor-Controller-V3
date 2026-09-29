local health = require("core.health")
local reactor_identity = require("core.reactor_identity")

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
    -- Je Turbine gehen nur noch die Felder raus, die MASTER auch liest.
    -- Bei 50 Turbinen alle 5 s ist dieses Array der mit Abstand groesste
    -- Posten im Statusverkehr -- vier Felder waren reine Fracht:
    --
    --   name        entry.id ist bereits "turbine:"..name
    --   alias       nur bei REAKTOREN gelesen (master/fuel_relay.lua)
    --   output      Dublette von energy, derselbe Wert
    --   target_rpm  MASTER kennt die Zieldrehzahl aus seiner eigenen Config
    --
    -- Was bleibt und WER es liest (vor dem Kuerzen nachgeprueft):
    --   id           ueberall zur Zuordnung
    --   rpm          Sequencer-Telemetrie, alert_rules
    --   flow_rate    master/startup_sequencer.lua's Telemetriezeile
    --   energy       Summe des Knotenausstosses
    --   coil_engaged core/alert_rules.lua's COIL_EARLY
    --   state        Sequencer wartet auf "STABLE"
    table.insert(list, {
      id = entry.id,
      rpm = info and info.rpm or nil,
      flow_rate = info and info.flow or nil,
      energy = energy,
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
    local global_id = reactor_identity.compose(registry and registry.node_id, entry.id)
    table.insert(list, {
      id = entry.id,
      local_id = entry.id,
      global_id = global_id,
      name = entry.name,
      alias = entry.alias,
      rods_level = info and info.control_rod_level or nil,
      active = info and info.active or nil,
      steam_production = info and info.steam or nil,
      -- Vom Kuehlmittel geht nur der ANTEIL raus. Die Rohmengen
      -- (coolant_amount/-_max) und coolant_ratio_source wertet
      -- ausschliesslich die Node selbst aus (core/safety.lua ueber
      -- rt2_safety) -- MASTER hat sie nie gelesen.
      coolant_filled_percentage = info and info.coolant_filled_percentage or nil,
      coolant_ratio = info and info.coolant_ratio or nil,
      -- Fuel-Fuellstand im Reaktor-Snapshot, den RT sowieso regelmaessig
      -- an Master schickt -- FUEL hat sonst keinen eigenen Wired-Modem-
      -- Zugriff auf den Reaktor.
      fuel_amount = info and info.fuel or nil,
      fuel_capacity = info and info.fuel_max or nil,
      state = module and module.state or nil
    })
  end
  return list
end

-- Diese Datei nimmt HARDWARE auf -- sie entscheidet nichts. Die Kapazitaet
-- stand hier bis v768 selbst im Payload, gemessen von v1s eigenem
-- capacity_learning.lua. Das ist entfallen: das Einlernen im Orchestrator
-- ist die einzige Quelle, und main.lua legt dessen Werte nach diesem
-- Aufruf ueber das Payload. Die Nullen hier sind bewusst Platzhalter,
-- keine Messwerte -- ueberschrieben wird jedes Feld, bevor das Payload die
-- Node verlaesst.
function M.build_status_payload(ctx)
  local health_payload = ctx.build_health_payload()
  local turbines, actual_output = M.build_turbine_snapshots(ctx.registry, ctx.turbine_adapter, ctx.modules, ctx.log_prefix, ctx.targets)
  local reactors = M.build_reactor_snapshots(ctx.registry, ctx.reactor_adapter, ctx.modules, ctx.log_prefix)
  return {
    status = ctx.status_level,
    state = ctx.current_state,
    mode = ctx.current_state,
    output = ctx.targets.power,
    target_output = ctx.targets.power,
    power_target = ctx.targets.power,
    power_target_percent = ctx.targets.power_percent,
    actual_output = actual_output,
    power_actual = actual_output,
    capacity_max = 0,
    capacity_ready = false,
    capacity_source = "UNKNOWN",
    capacity_stable_turbines = 0,
    capacity_total_turbines = 0,
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
  })
end

return M
