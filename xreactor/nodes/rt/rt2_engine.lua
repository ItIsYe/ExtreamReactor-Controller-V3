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

local M = {}

local engine
local last_result

function M.init(opts)
  engine = orchestrator.new(opts)
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

  local result = engine.tick({
    now_ms = now_ms,
    hardware_ready = (reactor_name ~= nil) and (#turbine_readings > 0),
    turbines = turbine_readings,
    reactor = reactor_reading,
  })

  for _, t in ipairs(result.turbines) do
    adapter.apply_turbine(ctx.adapters.turbine, t.name, ctx.CONFIG.LOG_PREFIX, t)
  end
  if reactor_name then
    adapter.apply_reactor(ctx.adapters.reactor, reactor_name, ctx.CONFIG.LOG_PREFIX, result.reactor_decision)
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
    return { mode = M.current_state() }
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
    capacity_ready = last_result.capacity.ready,
    capacity_max = last_result.capacity.max_output,
    turbines = turbines,
    control_rod_level = last_result.reactor_decision and last_result.reactor_decision.rods or nil,
  }
end

return M
