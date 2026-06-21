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

-- ════════════════════════════════════════════════════════════════════════
-- CAPACITY LEARNING — komplett neu geschrieben (siehe Projekt-Notizen)
-- ════════════════════════════════════════════════════════════════════════
-- Zweck: die RT-Node kennt ihre maximale Leistungsfähigkeit nicht von
-- vornherein (hängt von Reaktor-Größe, Turbinen-Anzahl, Mod-Konfiguration
-- ab) und muss sie messen, damit der Master weiß wie viel diese Node
-- liefern kann.
--
-- PRINZIP (bewusst einfach gehalten):
--   - Das Ziel für die Kapazitätsmessung ist IMMER fest 900 RPM
--     (CAPACITY_LEARNING_TARGET_RPM) — komplett unabhängig vom Master.
--     Das Learning soll ja gerade funktionieren BEVOR der Master sinnvoll
--     zuweisen kann; eine Abhängigkeit von Master-Setpoints war der Bug,
--     der das Learning vorher dauerhaft blockiert hat.
--   - Die Reaktor-Steuerung wird davon NICHT berührt — die regelt
--     eigenständig über den Steam-Margin-Regler in main.lua weiter.
--   - Eine Turbine zählt als "am Ziel", wenn Coil eingerastet ist UND die
--     RPM nah genug an 900 liegt UND sie tatsächlich Energie liefert.
--   - Aus allen Turbinen am Ziel wird der Durchschnitts-Output berechnet
--     und auf die Gesamtzahl der Turbinen hochgerechnet — das ergibt die
--     aktuelle Kapazitätsmessung.
--   - Die Messung läuft KONTINUIERLICH weiter (kein einmaliges Lock-und-
--     fertig): steigt der gemessene Wert, wird er sofort übernommen (z.B.
--     mehr Turbinen werden später hinzugefügt). Ein kurzzeitiger Einbruch
--     (z.B. eine Turbine kurz offline) lässt den zuletzt bekannten
--     Höchstwert unverändert, bis eine neue, vollständige Messung vorliegt.
--   - "ready" (für den Master: capacity_ready) wird true, sobald
--     mindestens eine gültige Messung vorliegt — ab dann kann der Master
--     mit dem Wert planen, auch wenn er sich später noch leicht anpasst.

local CAPACITY_LEARNING_TARGET_RPM = 900
local CAPACITY_LEARNING_TOLERANCE_RPM = 15
-- Fix: eine einzelne Turbine als Stichprobe für alle 25 hochzurechnen ist
-- zu ungenau (Dampfverteilung/Position können einzelne Turbinen über- oder
-- unterdurchschnittlich liefern lassen). Jetzt: mindestens 80% der
-- Turbinen müssen am Ziel sein, bevor überhaupt eine Messung akzeptiert
-- wird — Kompromiss zwischen Genauigkeit (Hochrechnung aus wenigen
-- Ausreißern vermeiden) und Geschwindigkeit (nicht auf 100% warten, falls
-- einzelne Turbinen mal länger ausfallen).
local CAPACITY_LEARNING_MIN_FRACTION = 0.8

-- Misst die aktuelle Kapazität aus den Turbinen, die JETZT am Ziel sind.
-- Gibt (output, at_target_count, total_count) zurück. output ist nil wenn
-- nicht mindestens CAPACITY_LEARNING_MIN_FRACTION der Turbinen am Ziel
-- sind — dann bleibt der zuletzt bekannte Wert gültig (kein Reset).
local function measure_capacity(turbines)
  local total = type(turbines) == "table" and #turbines or 0
  if total == 0 then return nil, 0, 0 end

  local at_target = 0
  local at_target_output = 0

  for _, turbine in ipairs(turbines) do
    local rpm = numeric_value(turbine.rpm)
    local energy = numeric_value(turbine.energy) or 0
    local coil = turbine.coil_engaged
    if rpm and coil ~= false
        and math.abs(rpm - CAPACITY_LEARNING_TARGET_RPM) <= CAPACITY_LEARNING_TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      at_target_output = at_target_output + energy
    end
  end

  local min_required = math.max(1, math.ceil(total * CAPACITY_LEARNING_MIN_FRACTION))
  if at_target < min_required then return nil, at_target, total end

  -- Mindestens 80% der Turbinen sind tatsächlich am Ziel — Durchschnitt
  -- dieser breiten Stichprobe auf die Gesamtzahl hochrechnen (für die
  -- wenigen ggf. noch nicht erfassten Turbinen, z.B. kurzzeitig rotierend
  -- im Teillast-Slot).
  local output = math.floor((at_target_output / at_target) * total)
  return output, at_target, total
end

function M.update_capacity_learning(ctx, turbines, actual_output)
  ctx.capacity_learning = ctx.capacity_learning or {
    ready = false,
    max_output = 0,
    at_target = 0,
    total_turbines = 0,
    reason = "INIT"
  }
  local learning = ctx.capacity_learning

  local measured, at_target, total = measure_capacity(turbines)
  learning.at_target = at_target
  learning.total_turbines = total

  if measured then
    if not learning.ready then
      -- Erste gültige Messung: sofort übernehmen, Node ist ab jetzt "ready".
      learning.max_output = measured
      learning.ready = true
      learning.reason = "MEASURED"
      if type(ctx.log) == "function" then
        pcall(ctx.log, "INFO", string.format(
          "RT capacity measured output=%.2f at_target=%d/%d", measured, at_target, total))
      end
    elseif measured > learning.max_output then
      -- Höherer Wert gemessen (z.B. mehr Turbinen verfügbar) -> übernehmen.
      learning.max_output = measured
      learning.reason = "UPDATED"
      if type(ctx.log) == "function" then
        pcall(ctx.log, "INFO", string.format(
          "RT capacity updated output=%.2f at_target=%d/%d", measured, at_target, total))
      end
    else
      -- Gemessener Wert liegt auf/unter dem bisherigen Maximum (z.B. weil
      -- gerade nicht alle Turbinen am Ziel sind) — bisherigen Höchstwert
      -- behalten, nicht jede kurzzeitige Schwankung übernehmen.
      learning.reason = "STABLE"
    end
  else
    -- Aktuell keine einzige Turbine am Ziel (z.B. Reaktor fährt gerade
    -- hoch/runter) — bisherigen Wert unverändert lassen, nicht zurücksetzen.
    learning.reason = total == 0 and "NO_TURBINES" or "NONE_AT_TARGET"
  end

  return learning
end
function M.build_status_payload(ctx)
  local health_payload = ctx.build_health_payload()
  local turbines, actual_output = M.build_turbine_snapshots(ctx.registry, ctx.turbine_adapter, ctx.modules, ctx.log_prefix, ctx.targets)
  local reactors = M.build_reactor_snapshots(ctx.registry, ctx.reactor_adapter, ctx.modules, ctx.log_prefix)
  local capacity = M.update_capacity_learning(ctx, turbines, actual_output)
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
