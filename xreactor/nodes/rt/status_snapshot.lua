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
      state = module and module.state or nil
    })
  end
  return list
end

local function summarize_capacity_sample(turbines, target_rpm, total_output)
  local total = type(turbines) == "table" and #turbines or 0
  if total == 0 then
    return { ok = false, reason = "NO_TURBINES", total = 0, stable = 0, producing = 0, sample_output = 0, required = 1 }
  end

  local target = numeric_value(target_rpm) or 900
  local tolerance = math.max(10, target * 0.10)
  local stable = 0
  local producing = 0
  local stable_output = 0
  local rpm_missing = 0
  local coil_off = 0
  local out_of_band = 0

  for _, turbine in ipairs(turbines) do
    local rpm = numeric_value(turbine.rpm)
    local energy = numeric_value(turbine.energy) or 0
    local coil = turbine.coil_engaged
    if not rpm then
      rpm_missing = rpm_missing + 1
    elseif math.abs(rpm - target) <= tolerance then
      if coil == false then
        coil_off = coil_off + 1
      elseif energy and energy > 0 then
        stable   = stable   + 1
        producing = producing + 1
        stable_output = stable_output + energy
      elseif coil ~= false then
        -- Turbine is in RPM band with coil engaged but energy reads as zero (readback lag).
        -- Count as mechanically stable for diagnostics.
        -- Lock still requires sample_output > 0 — no energy means no valid sample.
        stable = stable + 1
        -- producing and stable_output unchanged: no real energy to record
      end
    else
      out_of_band = out_of_band + 1
    end
  end

  -- Option A: required = 1 — eine stabile Turbine reicht zum Locken.
  -- max_output wird als stable_output / stable * total hochgerechnet damit
  -- der Master die echte Gesamt-Kapazität bekommt, nicht nur die einer Turbine.
  local required = 1
  local observed_total = numeric_value(total_output) or 0
  local sample_output = stable_output > 0 and stable_output or observed_total
  -- Hochrechnung: wenn nur ein Teil der Turbinen stabil ist,
  -- schätze Gesamtkapazität proportional hoch.
  if stable > 0 and stable < total and stable_output > 0 then
    sample_output = math.floor(stable_output / stable * total)
  end
  -- Sample gültig wenn mindestens 1 Turbine stabil + Energie messbar.
  local ok = stable >= required and sample_output > 0
  local reason
  if ok then
    reason = "SAMPLE_OK"
  elseif stable < required then
    reason = "NOT_ALL_STABLE"
  else
    reason = "OUTPUT_UNAVAILABLE"
  end

  return {
    ok = ok,
    reason = reason,
    total = total,
    stable = stable,
    producing = producing,
    sample_output = sample_output,
    required = required,
    target = target,
    tolerance = tolerance,
    rpm_missing = rpm_missing,
    coil_off = coil_off,
    out_of_band = out_of_band
  }
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
  local sample = summarize_capacity_sample(turbines, ctx.targets and ctx.targets.rpm, actual_output)

  learning.reason = sample.reason
  learning.total_turbines = sample.total
  learning.stable_turbines = sample.stable
  learning.producing_turbines = sample.producing
  learning.required_stable_turbines = sample.required
  learning.sample_output = sample.sample_output
  learning.rpm_missing = sample.rpm_missing
  learning.out_of_band_turbines = sample.out_of_band
  learning.coil_off_turbines = sample.coil_off

  -- Letzten bekannten Turbinen-Stand für UI-Fortschrittsbalken speichern
  learning.stable_turbines_last = sample.stable
  learning.total_turbines_last  = sample.total

  if sample.ok then
    learning.stable_samples = (learning.stable_samples or 0) + 1
    learning.max_candidate = math.max(learning.max_candidate or 0, sample.sample_output or 0)
    -- Gut-Fenster: zählt aufeinanderfolgende gültige Samples.
    -- Ein kurzer Ausreißer (ungültiger Sample) setzt nur den Fenster-Zähler zurück,
    -- nicht stable_samples — verhindert dass RPM-Schwankungen das Learning blockieren.
    learning.ok_window = (learning.ok_window or 0) + 1
    if not learning.locked and learning.stable_samples >= 3 then
      learning.max_output = learning.max_candidate
      learning.locked = true
      learning.reason = "LOCKED"
      if type(ctx.log) == "function" then
        pcall(ctx.log, "INFO", string.format(
          "RT capacity locked output=%.2f samples=%d stable=%d/%d",
          learning.max_output, learning.stable_samples,
          sample.stable, sample.total
        ))
      end
    elseif learning.locked then
      -- Update wenn >1% über bisherigem Max
      local threshold = (learning.max_output or 0) * 1.01
      if sample.sample_output and sample.sample_output > threshold then
        learning.max_output = sample.sample_output
        learning.reason = "UPDATED"
        if type(ctx.log) == "function" then
          pcall(ctx.log, "INFO", string.format(
            "RT capacity updated output=%.2f stable=%d/%d",
            learning.max_output, sample.stable, sample.total
          ))
        end
      end
    end
  else
    -- Ungültiger Sample: Fenster-Zähler zurücksetzen.
    -- stable_samples und max_candidate bleiben erhalten solange nicht gesperrt —
    -- kurzzeitige Ausreißer sollen den Fortschritt nicht zunichtemachen.
    learning.ok_window = 0
    if not learning.locked then
      -- Nur zurücksetzen wenn zu viele aufeinanderfolgende Fehler (>3 in Folge)
      -- um echte Probleme (Reaktor aus, alle Turbinen weg) zu erkennen.
      learning.consecutive_fail = (learning.consecutive_fail or 0) + 1
      if learning.consecutive_fail > 3 then
        learning.stable_samples   = 0
        learning.max_candidate    = 0
        learning.consecutive_fail = 0
        if type(ctx.log) == "function" then
          pcall(ctx.log, "WARN",
            "CapacityLearning: reset after 3 consecutive failed samples reason=" .. tostring(sample.reason))
        end
      end
    end
  end
  -- Gut-Samples setzen consecutive_fail zurück
  if sample.ok then
    learning.consecutive_fail = 0
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
    capacity_stable_turbines = capacity and capacity.stable_turbines or 0,
    capacity_total_turbines = capacity and capacity.total_turbines or 0,
    capacity_required_stable_turbines = capacity and capacity.required_stable_turbines or 1,
    capacity_sample_output = capacity and capacity.sample_output or 0,
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
