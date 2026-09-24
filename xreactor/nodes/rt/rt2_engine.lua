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
-- Je Reaktor (Schluessel: Name): Sicherheitszustand, letzte gemeldete
-- Sicherheitslage, ob sein Anlagenprofil schon geschrieben wurde.
local reactor_state = {}
local last_saved_max_output

-- Die Reaktoren dieses Knotens (Peripherienamen). Die Turbinen bleiben
-- EINE Flotte: sie haengen alle am selben Dampfnetz, und jeder Reaktor
-- regelt sich unabhaengig aus seinem eigenen Tank.
local reactor_names = {}

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

  reactor_names = {}
  for _, name in ipairs((opts.config and opts.config.reactors) or {}) do
    reactor_names[#reactor_names + 1] = name
  end

  -- Kapazitaet: EINE fuer den Knoten, wie bisher.
  local loaded, load_err = rt2_capacity.load({
    path = cache_path, read_config = read_config, turbine_count = opts.turbine_count,
  })
  last_saved_max_output = loaded and loaded.max_output or nil
  if type(opts.log) == "function" then
    if loaded then
      opts.log("INFO", string.format("v2 Kapazitaet aus Cache: max_output=%.0f", loaded.max_output))
    elseif load_err then
      opts.log("INFO", "v2 Kapazitaets-Cache nicht genutzt: " .. tostring(load_err))
    end
  end

  -- Anlagenprofil: je Reaktor, denn jeder hat seinen eigenen Dampftank.
  local profiles = rt2_tuning.load_units({ path = tuning_path, read_config = read_config })

  reactor_state = {}
  local specs = {}
  for index, name in ipairs(reactor_names) do
    local key = name or ("reactor" .. index)
    local tuned = profiles[key]
    reactor_state[key] = { safety = rt2_safety.new_state(), tuning_saved = tuned ~= nil }
    specs[#specs + 1] = { name = name, tuning_profile = tuned }
    if tuned and type(opts.log) == "function" then
      opts.log("INFO", string.format(
        "v2 Reaktorprofil fuer %s aus Messung geladen: max_step=%d Stellintervall=%dms",
        key, tuned.max_step, tuned.min_adjust_interval_ms))
    end
  end

  last_logged_safety_reason = nil
  last_logged_capacity_diag = nil
  last_projection = nil
  engine = orchestrator.new({
    initial_state = opts.initial_state,
    master_timeout_ms = opts.master_timeout_ms,
    initial_capacity = loaded,
    reactors = specs,
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

  -- Discovery laeuft nach init(), deshalb die Reaktorliste hier frisch
  -- nehmen. Die Turbinen bleiben EINE Flotte.
  local live = (ctx.config and ctx.config.reactors) or {}
  if #live > 0 then
    if #live ~= #reactor_names then
      reactor_names = {}
      for _, name in ipairs(live) do reactor_names[#reactor_names + 1] = name end
    end
  end

  local turbine_readings = {}
  for _, name in ipairs((ctx.config and ctx.config.turbines) or {}) do
    local info = ctx.adapters.turbine.inspect(name, ctx.CONFIG.LOG_PREFIX)
    local reading = adapter.read_turbine(name, info)
    if reading then turbine_readings[#turbine_readings + 1] = reading end
  end

  -- Sicherheit VOR der Regelentscheidung, je Reaktor: eine Ausloesung
  -- muss diesen Takt gewinnen, nicht den naechsten.
  local reactor_inputs = {}
  for index, name in ipairs(reactor_names) do
    local key = name or ("reactor" .. index)
    reactor_state[key] = reactor_state[key] or { safety = rt2_safety.new_state() }

    local info = ctx.adapters.reactor.inspect(name, ctx.CONFIG.LOG_PREFIX)
    local reading = adapter.read_reactor(info) or {}
    local safety_result = rt2_safety.evaluate(reactor_state[key].safety, reading,
      (ctx.config and ctx.config.safety) or nil)

    local previous = reactor_state[key].last_safety_reason
    if safety_result.reason ~= previous then
      reactor_state[key].last_safety_reason = safety_result.reason
      local label = (#reactor_names > 1) and (" an " .. key) or ""
      if safety_result.tripped then
        local msg = string.format(
          "v2 SAFETY-TRIP%s: %s (Temperatur=%s, Kuehlmittel=%s) -- dessen Staebe voll eingefahren",
          label, tostring(safety_result.reason), tostring(safety_result.temperature),
          tostring(safety_result.coolant_ratio))
        ctx.log("WARN", msg)
        pcall(print, "[RT] " .. msg)
      elseif previous ~= nil then
        ctx.log("INFO", "v2 Sicherheitslage" .. label .. " wieder normal")
      end
    end

    reactor_inputs[index] = { name = name, safety_tripped = safety_result.tripped, reactor = reading }
  end

  local result = engine.tick({
    now_ms = now_ms,
    hardware_ready = (#reactor_names > 0) and (#turbine_readings > 0),
    turbines = turbine_readings,
    reactors = reactor_inputs,
  })

  for _, t in ipairs(result.turbines) do
    adapter.apply_turbine(ctx.adapters.turbine, t.name, ctx.CONFIG.LOG_PREFIX, t)
  end
  for index, decision in ipairs(result.reactors) do
    local name = reactor_names[index]
    if name then
      adapter.apply_reactor(ctx.adapters.reactor, name, ctx.CONFIG.LOG_PREFIX, decision)
    end
  end

  -- Einlernen sichtbar machen.
  local cap = result.capacity
  local waiting = (cap.max_output or 0) <= 0
  local diag = string.format("%s|%d|%s|%s", tostring(cap.reason),
    math.floor((cap.max_output or 0) / 1000), tostring(cap.ready), tostring(waiting))
  do
    local msg
    if cap.reason == "MEASURING" then
      msg = string.format("v2 Einlernen laeuft: bisher %.0f RF/t gemessen (%d von %d Turbinen am Ziel)",
        cap.max_output or 0, cap.at_target or 0, cap.total_turbines or 0)
    elseif cap.reason == "MEASURED" then
      msg = string.format("v2 Einlernen FERTIG: %.0f RF/t aus %d Turbinen gemessen",
        cap.max_output or 0, cap.sustainable_turbines or 0)
      if (cap.sustainable_turbines or 0) < (cap.total_turbines or 0) then
        msg = msg .. string.format(" -- %d der %d Turbinen waren dabei nie gleichzeitig am Ziel",
          (cap.total_turbines or 0) - (cap.sustainable_turbines or 0), cap.total_turbines or 0)
      end
    elseif cap.reason == "FLOW_SATURATED" then
      msg = string.format(
        "v2 Einlernen: %d Turbine(n) fahren VOLLEN Flow (%d) und erreichen trotzdem keine %d RPM"
        .. " -- im Zielbereich %d von %d, noetig %d.",
        cap.saturated or 0, rt2_turbine.MAX_FLOW, rt2_capacity.TARGET_RPM,
        cap.at_target or 0, cap.total_turbines or 0, cap.required_at_target or 0)
    elseif cap.reason == "BELOW_FRACTION" and waiting then
      msg = string.format(
        "v2 Einlernen wartet: %d von %d Turbinen im Zielbereich (%d RPM +/- %d), noetig sind %d",
        cap.at_target or 0, cap.total_turbines or 0, rt2_capacity.TARGET_RPM,
        rt2_capacity.TOLERANCE_RPM, cap.required_at_target or 0)
    elseif cap.reason == "TOPOLOGY_CHANGED" then
      msg = string.format("v2 Turbinenzahl geaendert (%d) -- Anlage wird neu vermessen", cap.total_turbines or 0)
    elseif cap.reason == "NO_TURBINES" then
      msg = waiting and "v2 noch keine Turbine gefunden -- warte auf Discovery"
        or "v2 keine Turbine lesbar -- gelernter Wert bleibt erhalten"
    end
    -- Den Schluessel nur fortschreiben, wenn auch gemeldet wurde.
    if msg and diag ~= last_logged_capacity_diag then
      last_logged_capacity_diag = diag
      ctx.log("INFO", msg)
      pcall(print, "[RT] " .. msg)
    end
  end

  if cap.ready and cap.max_output ~= last_saved_max_output then
    if rt2_capacity.save(cap, { path = cache_path, write_config = write_config }) then
      last_saved_max_output = cap.max_output
      ctx.log("INFO", string.format("v2 Kapazitaet gesichert: max_output=%.0f", cap.max_output))
    end
  end

  -- Anlagenprofile: je Reaktor, einmalig geschrieben.
  local profiles, tuning_changed = {}, false
  for index, unit in ipairs(engine.reactors) do
    local key = unit.name or ("reactor" .. index)
    if unit.tuning_profile then
      profiles[key] = unit.tuning_profile
      local st = reactor_state[key]
      if st and not st.tuning_saved then
        st.tuning_saved = true
        tuning_changed = true
        local msg = string.format(
          "v2 Reaktor %s selbst vermessen: %d Messwerte -> max_step=%d, Stellintervall=%dms",
          key, unit.tuning_profile.samples or 0, unit.tuning_profile.max_step,
          unit.tuning_profile.min_adjust_interval_ms)
        ctx.log("INFO", msg)
        pcall(print, "[RT] " .. msg)
      end
    end
  end
  if tuning_changed then
    rt2_tuning.save_units(profiles, { path = tuning_path, write_config = write_config })
  end

  -- Jeder Reaktor wird nach seinem eigenen Messwert und seiner eigenen
  -- Sicherheitslage beurteilt.
  local by_name = {}
  for index, ri in ipairs(reactor_inputs) do
    local decision = result.reactors[index]
    if ri.name then
      by_name[ri.name] = { reading = ri.reactor, tripped = ri.safety_tripped == true }
    end
    local _ = decision
  end
  last_projection = rt2_projection.project(result, ctx.modules, { by_name = by_name })
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
    -- Je Reaktor, weil ein Knoten mehrere haben kann und sie unabhaengig
    -- regeln -- control_rod_level allein zeigte nur den ersten.
    reactors = (function()
      local out = {}
      for _, decision in ipairs(last_result.reactors or {}) do
        out[#out + 1] = {
          id = decision.name,
          control_rod_level = decision.rods,
          reason = decision.reason,
          safety_tripped = decision.safety_tripped == true,
        }
      end
      return out
    end)(),
    tripped_reactors = last_result.tripped_reactors or 0,
  }
end

return M
