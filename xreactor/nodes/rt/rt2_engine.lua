-- RT rewrite, step 9 (cutover glue): the ONLY module main.lua talks to
-- for the "v2" engine path. Owns the single rt2_orchestrator instance for
-- this RT process and bridges it to main.lua's existing ctx (peripheral
-- adapters, config, logging) via rt2_adapter.
--
-- main.lua's discovery/comms/monitor/status-publishing machinery is
-- UNCHANGED for v2 -- only the control decision + hardware write step
-- (this module's M.tick()) and command handling (M.handle_command())
-- are redirected here when config.engine == "v2".
--
-- Single-reactor limitation is enforced by main.lua before this module
-- is ever initialized (see main.lua's engine-selection guard) -- this
-- module itself only ever looks at devices.reactors[1].

local orchestrator = require("nodes.rt.rt2_orchestrator")
local adapter = require("nodes.rt.rt2_adapter")
local rt2_state = require("nodes.rt.rt2_state")
local rt2_capacity = require("nodes.rt.rt2_capacity")
local rt2_safety = require("nodes.rt.rt2_safety")
local rt2_projection = require("nodes.rt.rt2_projection")
local rt2_tuning = require("nodes.rt.rt2_tuning")
local rt2_turbine = require("nodes.rt.rt2_turbine")
local rt2_reactor = require("nodes.rt.rt2_reactor")
local utils = require("core.utils")

local M = {}

-- Deliberately a SEPARATE file from CONFIG.CAPACITY_CACHE_PATH (v1's
-- cache): the persisted shape differs (count-keyed, no per-turbine
-- identity signature -- see rt2_capacity.lua's header on why) and the
-- two engines must never read each other's cache.
M.CACHE_PATH = "/xreactor_config/rt2_capacity_cache.lua"
-- The measured reactor plant profile (see rt2_tuning.lua). Separate file
-- from the capacity cache: it is derived from entirely different readings
-- and stays valid when the turbine count changes, which invalidates the
-- capacity but says nothing about how the steam tank responds.
M.TUNING_PATH = "/xreactor_config/rt2_reactor_tuning.lua"

local engine
local last_result
local cache_path
local last_logged_capacity_diag
local last_logged_safety_reason
local last_projection
local tuning_path
-- Je Einheit (Schluessel: Reaktorname): Sicherheitszustand, zuletzt
-- gesicherte Kapazitaet, ob das Anlagenprofil schon geschrieben wurde.
local unit_state = {}
-- Die Einheiten dieses Knotens: { { name = <Reaktor>, turbines = {...} }, ... }
local units = {}

-- Baut die Einheitenliste. Ohne konfigurierte Zuordnung ist es genau eine
-- Einheit aus dem ersten Reaktor und allen Turbinen -- das ist der
-- Ein-Reaktor-Fall und bleibt unveraendert. Mit config.units gehoert jede
-- Turbine genau einem Reaktor, weil sie physisch an dessen Dampfleitung
-- haengt und sonst gegen den falschen Tank geregelt wuerde.
local function build_units(config)
  local out = {}
  local configured = config and config.units
  if type(configured) == "table" and #configured > 0 then
    for _, spec in ipairs(configured) do
      if type(spec) == "table" and type(spec.reactor) == "string" then
        out[#out + 1] = { name = spec.reactor, turbines = spec.turbines or {} }
      end
    end
    if #out > 0 then return out end
  end
  local reactor_name = (config and config.reactors or {})[1]
  if not reactor_name then return {} end
  return { { name = reactor_name, turbines = (config and config.turbines) or {} } }
end
M._build_units = build_units

local function read_config(path)
  return (utils.load_config(path, {}))
end

local function write_config(path, data)
  return (utils.write_config(path, data))
end

-- opts.turbine_count: how many turbines discovery just found -- required
-- to validate (or reject) a persisted cache from a genuinely different
-- fleet size. opts.cache_path overrides M.CACHE_PATH (mainly for tests).
function M.init(opts)
  opts = opts or {}
  cache_path = opts.cache_path or M.CACHE_PATH
  tuning_path = opts.tuning_path or M.TUNING_PATH

  units = build_units(opts.config)
  if #units == 0 and opts.turbine_count then
    -- init() vor der Discovery (Tests, fruehes main.lua): eine namenlose
    -- Einheit, die beim ersten Takt ihre Geraete bekommt.
    units = { { name = nil, turbines = {} } }
  end

  local cached = rt2_capacity.load_units({ path = cache_path, read_config = read_config })
  local profiles = rt2_tuning.load_units({ path = tuning_path, read_config = read_config })

  unit_state = {}
  local specs = {}
  for index, unit in ipairs(units) do
    local key = unit.name or ("unit" .. index)
    local count = opts.turbine_count
    if #units > 1 or (unit.turbines and #unit.turbines > 0) then count = #(unit.turbines or {}) end
    local loaded, load_err = rt2_capacity.from_cached(cached[key], count)
    local tuned = profiles[key]
    unit_state[key] = {
      safety = rt2_safety.new_state(),
      last_saved_max_output = loaded and loaded.max_output or nil,
      tuning_saved = tuned ~= nil,
    }
    specs[#specs + 1] = { name = unit.name, initial_capacity = loaded, tuning_profile = tuned }
    if type(opts.log) == "function" then
      if loaded then
        opts.log("INFO", string.format("v2 Kapazitaet aus Cache fuer %s: max_output=%.0f", key, loaded.max_output))
      elseif load_err then
        opts.log("INFO", string.format("v2 Kapazitaets-Cache fuer %s nicht genutzt: %s", key, tostring(load_err)))
      end
      if tuned then
        opts.log("INFO", string.format(
          "v2 Reaktorprofil fuer %s aus Messung geladen: max_step=%d Stellintervall=%dms",
          key, tuned.max_step, tuned.min_adjust_interval_ms))
      end
    end
  end

  last_logged_safety_reason = nil
  last_logged_capacity_diag = nil
  last_projection = nil
  engine = orchestrator.new({
    initial_state = opts.initial_state,
    master_timeout_ms = opts.master_timeout_ms,
    units = specs,
  })
  last_result = nil
  return engine
end

function M.note_master_seen(now_ms)
  if engine then engine.note_master_seen(now_ms) end
end

function M.handle_command(command)
  if not engine then
    return { ok = false, error = "v2 engine not initialized", reason_code = "NOT_READY" }
  end
  return engine.handle_command(command)
end

function M.current_state()
  if not engine then return rt2_state.states.INIT end
  return engine.current_state()
end

-- ctx: main.lua's RT ctx. Needs:
--   ctx.config.turbines / ctx.config.reactors -- discovered peripheral names
--   ctx.adapters.turbine / ctx.adapters.reactor -- adapters/turbine.lua, adapters/reactor.lua
--   ctx.CONFIG.LOG_PREFIX
function M.tick(ctx)
  if not engine then return nil end
  local now_ms = os.epoch and os.epoch("utc") or 0

  -- Die Einheiten koennen sich nach der Discovery aendern (sie laeuft
  -- nach init()), deshalb hier frisch bauen.
  local live = build_units(ctx.config)
  if #live > 0 then units = live end

  local unit_inputs, hardware_ready = {}, #units > 0
  for index, unit in ipairs(units) do
    local key = unit.name or ("unit" .. index)
    unit_state[key] = unit_state[key] or { safety = rt2_safety.new_state() }

    local turbine_readings = {}
    for _, name in ipairs(unit.turbines or {}) do
      local info = ctx.adapters.turbine.inspect(name, ctx.CONFIG.LOG_PREFIX)
      local reading = adapter.read_turbine(name, info)
      if reading then turbine_readings[#turbine_readings + 1] = reading end
    end

    local reactor_reading = {}
    if unit.name then
      local info = ctx.adapters.reactor.inspect(unit.name, ctx.CONFIG.LOG_PREFIX)
      reactor_reading = adapter.read_reactor(info) or {}
    end

    -- Sicherheit VOR der Regelentscheidung, je Einheit: eine Ausloesung
    -- muss diesen Takt gewinnen, nicht den naechsten.
    local safety_result = { tripped = false }
    if unit.name then
      safety_result = rt2_safety.evaluate(unit_state[key].safety, reactor_reading,
        (ctx.config and ctx.config.safety) or nil)
      local previous = unit_state[key].last_safety_reason
      if safety_result.reason ~= previous then
        unit_state[key].last_safety_reason = safety_result.reason
        if safety_result.tripped then
          local msg = string.format(
            "v2 SAFETY-TRIP an %s: %s (Temperatur=%s, Kuehlmittel=%s)"
            .. " -- Staebe voll eingefahren, dessen Turbinen Flow 0",
            key, tostring(safety_result.reason), tostring(safety_result.temperature),
            tostring(safety_result.coolant_ratio))
          ctx.log("WARN", msg)
          pcall(print, "[RT] " .. msg)
        elseif previous ~= nil then
          ctx.log("INFO", string.format("v2 Sicherheitslage an %s wieder normal", key))
        end
      end
    end

    if not unit.name or #turbine_readings == 0 then hardware_ready = false end

    unit_inputs[index] = {
      name = unit.name,
      safety_tripped = safety_result.tripped,
      reactor = reactor_reading,
      turbines = turbine_readings,
    }
  end

  local result = engine.tick({
    now_ms = now_ms,
    hardware_ready = hardware_ready,
    units = unit_inputs,
  })

  -- Auf die Hardware schreiben -- je Einheit, mit IHREN Geraeten.
  for index, unit_result in ipairs(result.units) do
    for _, t in ipairs(unit_result.turbines) do
      adapter.apply_turbine(ctx.adapters.turbine, t.name, ctx.CONFIG.LOG_PREFIX, t)
    end
    local unit = units[index]
    if unit and unit.name then
      adapter.apply_reactor(ctx.adapters.reactor, unit.name, ctx.CONFIG.LOG_PREFIX,
        unit_result.reactor_decision)
    end
  end

  -- Einlernen sichtbar machen. Bei mehreren Einheiten je Einheit, sonst
  -- saehe man nur eine Summe und wuesste nicht, welcher Reaktor haengt.
  local cap = result.capacity
  local diag_parts = {}
  for _, ur in ipairs(result.units) do
    diag_parts[#diag_parts + 1] = string.format("%s=%s/%d", tostring(ur.name),
      tostring(ur.capacity.reason), math.floor((ur.capacity.max_output or 0) / 1000))
  end
  local diag = table.concat(diag_parts, " ") .. "|" .. tostring(cap.ready)
  if diag ~= last_logged_capacity_diag then
    last_logged_capacity_diag = diag
    for _, ur in ipairs(result.units) do
      local uc = ur.capacity
      local label = (#result.units > 1) and (" [" .. tostring(ur.name) .. "]") or ""
      local msg
      if uc.reason == "MEASURING" then
        msg = string.format("v2 Einlernen laeuft%s: bisher %.0f RF/t gemessen (%d von %d Turbinen am Ziel)",
          label, uc.max_output or 0, uc.at_target or 0, uc.total_turbines or 0)
      elseif uc.reason == "MEASURED" then
        msg = string.format("v2 Einlernen FERTIG%s: %.0f RF/t aus %d Turbinen gemessen",
          label, uc.max_output or 0, uc.sustainable_turbines or 0)
      elseif uc.reason == "FLOW_SATURATED" then
        msg = string.format(
          "v2 Einlernen%s: %d Turbine(n) fahren VOLLEN Flow (%d) und erreichen trotzdem keine %d RPM"
          .. " -- im Zielbereich %d von %d, noetig %d.",
          label, uc.saturated or 0, rt2_turbine.MAX_FLOW, rt2_capacity.TARGET_RPM,
          uc.at_target or 0, uc.total_turbines or 0, uc.required_at_target or 0)
      elseif uc.reason == "BELOW_FRACTION" and (uc.max_output or 0) <= 0 then
        msg = string.format(
          "v2 Einlernen wartet%s: %d von %d Turbinen im Zielbereich (%d RPM +/- %d), noetig sind %d",
          label, uc.at_target or 0, uc.total_turbines or 0, rt2_capacity.TARGET_RPM,
          rt2_capacity.TOLERANCE_RPM, uc.required_at_target or 0)
      elseif uc.reason == "TOPOLOGY_CHANGED" then
        msg = string.format("v2 Turbinenzahl geaendert%s (%d) -- wird neu vermessen", label, uc.total_turbines or 0)
      elseif uc.reason == "NO_TURBINES" then
        msg = (uc.max_output or 0) > 0
          and ("v2 keine Turbine lesbar" .. label .. " -- gelernter Wert bleibt erhalten")
          or ("v2 noch keine Turbine gefunden" .. label .. " -- warte auf Discovery")
      end
      if msg then
        ctx.log("INFO", msg)
        pcall(print, "[RT] " .. msg)
      end
    end
  end

  -- Sichern, je Einheit und nur bei echter Wertaenderung.
  local dirty_capacity, dirty_tuning = {}, {}
  local capacity_changed, tuning_changed = false, false
  for index, ur in ipairs(result.units) do
    local key = ur.name or ("unit" .. index)
    local st = unit_state[key]
    if ur.capacity.ready then
      dirty_capacity[key] = ur.capacity
      if ur.capacity.max_output ~= st.last_saved_max_output then
        st.last_saved_max_output = ur.capacity.max_output
        capacity_changed = true
      end
    end
    if ur.tuning then
      dirty_tuning[key] = ur.tuning
      if not st.tuning_saved then
        st.tuning_saved = true
        tuning_changed = true
        local msg = string.format(
          "v2 Reaktor %s selbst vermessen: %d Messwerte -> max_step=%d, Stellintervall=%dms",
          key, ur.tuning.samples or 0, ur.tuning.max_step, ur.tuning.min_adjust_interval_ms)
        ctx.log("INFO", msg)
        pcall(print, "[RT] " .. msg)
      end
    end
  end
  if capacity_changed then
    rt2_capacity.save_units(dirty_capacity, { path = cache_path, write_config = write_config })
  end
  if tuning_changed then
    rt2_tuning.save_units(dirty_tuning, { path = tuning_path, write_config = write_config })
  end

  -- Auf die Modul-/Knotenzustaende abbilden, die UI und MASTER lesen.
  local first_reactor = unit_inputs[1] and unit_inputs[1].reactor or {}
  last_projection = rt2_projection.project(result, ctx.modules, first_reactor)
  for id, projected in pairs(last_projection.modules) do
    local module = ctx.modules and ctx.modules[id]
    if module then
      module.state = projected.state
      module.progress = projected.progress
    end
  end

  last_result = result
  return result
end

-- Fields merged into the status payload sent to MASTER -- mirrors the
-- shape status_snapshot.lua's build_status_payload() already produces
-- (mode/turbines/capacity_*) so MASTER-side code needs no v2-specific
-- branching to read it.
function M.status_fields()
  if not last_result then
    return { mode = M.current_state(), node_state = rt2_projection.node_state(M.current_state()) }
  end
  local turbines = {}
  for _, t in ipairs(last_result.turbines) do
    turbines[#turbines + 1] = {
      id = t.name,
      target_rpm = t.target_rpm,
      flow = t.flow_decision and t.flow_decision.flow or nil,
      coil_engaged = t.coil_decision and t.coil_decision.engaged or nil,
    }
  end
  return {
    mode = last_result.state,
    -- What payload.state should report -- node_state_machine itself stays
    -- untouched under v2 (see rt2_projection.lua's header on why).
    node_state = last_projection and last_projection.node_state
      or rt2_projection.node_state(last_result.state),
    capacity_ready = last_result.capacity.ready,
    -- Der Zweck des ganzen Einlernens: wieviel RF/t dieser Knoten
    -- tatsaechlich liefern kann. MASTER teilt seinen Bedarf gegen genau
    -- diese Zahl auf (rt_sync.node_capacity -> uniform_pct), also muss sie
    -- gemessen und nicht hochgerechnet sein -- siehe rt2_capacity.
    capacity_max = last_result.capacity.max_output,
    capacity_total_turbines = last_result.capacity.total_turbines,
    -- MASTER liest diese beiden Namen (message_handlers.lua) und baut
    -- daraus seine Lernanzeige. v2 schickte stattdessen capacity_at_target
    -- und capacity_reason -- also Felder, die MASTER gar nicht kennt. Auf
    -- dem MASTER-Schirm stand deshalb waehrend des gesamten Einlernens
    -- "LEARNING 0/25 Turbinen stabil", egal wie weit der Knoten war.
    capacity_stable_turbines = last_result.capacity.at_target,
    capacity_source = last_result.capacity.reason,
    -- Neu: wieviele Turbinen diese Anlage nachweislich traegt. Damit kann
    -- MASTER den Fortschritt des Suchlaufs zeigen und erkennen, dass ein
    -- Knoten seine Flotte bewusst nur teilweise fahren kann.
    capacity_sustainable_turbines = last_result.capacity.sustainable_turbines,
    -- Aliase unter den alten v2-Namen beibehalten: die RT-eigene UI und
    -- der Integrationstest lesen sie.
    capacity_at_target = last_result.capacity.at_target,
    capacity_reason = last_result.capacity.reason,
    turbines = turbines,
    control_rod_level = last_result.reactor_decision and last_result.reactor_decision.rods or nil,
  }
end

return M
