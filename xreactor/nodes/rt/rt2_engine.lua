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
local utils = require("core.utils")

local M = {}

-- Deliberately a SEPARATE file from CONFIG.CAPACITY_CACHE_PATH (v1's
-- cache): the persisted shape differs (count-keyed, no per-turbine
-- identity signature -- see rt2_capacity.lua's header on why) and the
-- two engines must never read each other's cache.
M.CACHE_PATH = "/xreactor_config/rt2_capacity_cache.lua"

local engine
local last_result
local cache_path
local last_saved_max_output
local last_logged_capacity_diag
local safety_state
local last_logged_safety_reason
local last_projection

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
  local loaded, load_err = rt2_capacity.load({
    path = cache_path, read_config = read_config, turbine_count = opts.turbine_count,
  })
  if loaded and type(opts.log) == "function" then
    opts.log("INFO", string.format("v2 capacity loaded from cache: max_output=%.2f", loaded.max_output))
  elseif load_err and type(opts.log) == "function" then
    opts.log("INFO", "v2 capacity cache not used: " .. tostring(load_err))
  end
  last_saved_max_output = loaded and loaded.max_output or nil
  safety_state = rt2_safety.new_state()
  last_logged_safety_reason = nil
  last_projection = nil
  engine = orchestrator.new({
    initial_state = opts.initial_state,
    master_timeout_ms = opts.master_timeout_ms,
    initial_capacity = loaded,
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

  local turbine_readings = {}
  for _, name in ipairs(ctx.config.turbines or {}) do
    local info = ctx.adapters.turbine.inspect(name, ctx.CONFIG.LOG_PREFIX)
    local reading = adapter.read_turbine(name, info)
    if reading then
      turbine_readings[#turbine_readings + 1] = reading
    end
  end

  local reactor_name = (ctx.config.reactors or {})[1]
  local reactor_reading = {}
  if reactor_name then
    local info = ctx.adapters.reactor.inspect(reactor_name, ctx.CONFIG.LOG_PREFIX)
    reactor_reading = adapter.read_reactor(info) or {}
  end

  -- Safety evaluation MUST happen before the control decision -- SAFE has
  -- to win this tick, not the next one. Skipped entirely when there is no
  -- reactor to read (hardware_ready is false then anyway, so the state
  -- machine stays in INIT and nothing is written to hardware).
  local safety_result = { tripped = false }
  if reactor_name then
    safety_result = rt2_safety.evaluate(safety_state, reactor_reading,
      (ctx.config and ctx.config.safety) or nil)
    local previous_reason = last_logged_safety_reason
    if safety_result.reason ~= previous_reason then
      last_logged_safety_reason = safety_result.reason
      if safety_result.tripped then
        local msg = string.format("v2 SAFETY-TRIP: %s (Temperatur=%s, Kuehlmittel=%s) -- Staebe voll eingefahren, Flow 0",
          tostring(safety_result.reason), tostring(safety_result.temperature), tostring(safety_result.coolant_ratio))
        ctx.log("WARN", msg)
        pcall(print, "[RT] " .. msg)
      elseif previous_reason ~= nil then
        ctx.log("INFO", "v2 Sicherheitslage wieder normal -- SAFE aufgehoben")
      end
    end
  end

  local result = engine.tick({
    now_ms = now_ms,
    hardware_ready = (reactor_name ~= nil) and (#turbine_readings > 0),
    safety_tripped = safety_result.tripped,
    turbines = turbine_readings,
    reactor = reactor_reading,
  })

  for _, t in ipairs(result.turbines) do
    adapter.apply_turbine(ctx.adapters.turbine, t.name, ctx.CONFIG.LOG_PREFIX, t)
  end
  if reactor_name then
    adapter.apply_reactor(ctx.adapters.reactor, reactor_name, ctx.CONFIG.LOG_PREFIX, result.reactor_decision)
  end

  -- Surface WHY LEARNING is stuck -- ready/at_target/total_turbines/reason
  -- are already computed every tick by rt2_capacity.update(), but were
  -- previously only visible by reading Lua state directly. Log (and print
  -- locally, same as the engine=v2 activation hint) only when the
  -- diagnostic actually changes, not every tick -- this is the same
  -- dirty-check discipline as the capacity-cache save below.
  if not result.capacity.ready then
    local diag = string.format("%d/%d %s", result.capacity.at_target or 0,
      result.capacity.total_turbines or 0, tostring(result.capacity.reason))
    if diag ~= last_logged_capacity_diag then
      last_logged_capacity_diag = diag
      local msg = "v2 Einlernen (LEARNING): " .. diag
        .. " -- Turbinen im Zielbereich (RPM+Spule engaged+Energieausstoss>0) vs. Gesamtzahl"
      ctx.log("INFO", msg)
      pcall(print, "[RT] " .. msg)
    end
  end

  -- Persist only when the learned value actually changed (same
  -- dirty-check discipline as v1's writeback_ctx) -- writing to disk
  -- every tick would be needless CC:Tweaked I/O for a value that is
  -- usually stable for the entire session once learned.
  if result.capacity.ready and result.capacity.max_output ~= last_saved_max_output then
    local saved = rt2_capacity.save(result.capacity, { path = cache_path, write_config = write_config })
    if saved then
      last_saved_max_output = result.capacity.max_output
      ctx.log("INFO", string.format("v2 capacity cached: max_output=%.2f", result.capacity.max_output))
    end
  end

  -- Project this tick onto the module/node vocabulary the UI, the status
  -- payload and MASTER read. Without this, v2 regulates correctly but every
  -- module stays frozen at its boot state ("OFF") and MASTER's startup
  -- sequencer waits forever for a "STABLE" that never comes -- see
  -- rt2_projection.lua's header.
  last_projection = rt2_projection.project(result, ctx.modules, reactor_reading)
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
    capacity_max = last_result.capacity.max_output,
    capacity_at_target = last_result.capacity.at_target,
    capacity_total_turbines = last_result.capacity.total_turbines,
    capacity_reason = last_result.capacity.reason,
    turbines = turbines,
    control_rod_level = last_result.reactor_decision and last_result.reactor_decision.rods or nil,
  }
end

return M
