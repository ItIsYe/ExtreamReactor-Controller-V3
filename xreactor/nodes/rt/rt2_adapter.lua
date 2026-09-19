-- RT rewrite, step 8: the thin, only-non-pure layer -- maps real
-- peripheral readings to the plain tables rt2_orchestrator expects, and
-- applies its decisions back to hardware.
--
-- Deliberately reuses adapters/turbine.lua and adapters/reactor.lua for
-- the actual peripheral.call()s (inspect/set_flow/set_coils/
-- apply_rod_level) -- those were never part of the bugs this rewrite
-- exists to fix, including apply_rod_level()'s existing safe-readback
-- confirmation for a 100%-insertion write. Re-implementing that here
-- would be exactly the kind of unnecessary risk the "keep core/adapters
-- as-is, rewrite only nodes/rt orchestration" scoping decision was meant
-- to avoid.
--
-- Every function here takes its adapter module as a parameter rather
-- than require()ing adapters/*.lua directly, so tests can pass a fake
-- adapter (plain Lua functions, no CC:Tweaked globals) and this file
-- stays testable exactly like the rest of the rewrite.

local M = {}

local function num_or_nil(v)
  if type(v) == "number" then return v end
  return nil
end

-- turbine_info: the table returned by adapters/turbine.lua's inspect().
-- Returns the plain reading table rt2_orchestrator.tick()'s `turbines`
-- entries need, or nil if the peripheral could not be inspected at all.
function M.read_turbine(name, turbine_info)
  if type(turbine_info) ~= "table" then return nil end
  return {
    name = name,
    rpm = num_or_nil(turbine_info.rpm),
    energy = num_or_nil(turbine_info.energy) or 0,
    coil_engaged = turbine_info.coil_engaged == true,
    current_flow = num_or_nil(turbine_info.flow) or 0,
  }
end

-- reactor_info: the table returned by adapters/reactor.lua's inspect().
function M.read_reactor(reactor_info)
  if type(reactor_info) ~= "table" then return nil end
  return {
    fill_ratio = num_or_nil(reactor_info.steam_fill_ratio),
    current_rods = num_or_nil(reactor_info.control_rod_level),
    active = reactor_info.active == true,
  }
end

-- Writes one turbine's flow+coil decision to hardware via the given
-- turbine_adapter module (adapters/turbine.lua in production, a fake in
-- tests). Returns a small result table for logging -- never raises.
function M.apply_turbine(turbine_adapter, name, log_prefix, turbine_result)
  local result = {}
  if turbine_result.flow_decision then
    result.flow_ok, result.flow_err = turbine_adapter.set_flow(name, turbine_result.flow_decision.flow, log_prefix)
  end
  if turbine_result.coil_decision then
    result.coil_ok, result.coil_err = turbine_adapter.set_coils(name, turbine_result.coil_decision.engaged, log_prefix)
  end
  return result
end

-- Writes the reactor's rod decision (and, if set, an activation request)
-- to hardware via the given reactor_adapter module. Reuses
-- apply_rod_level()'s own safe-readback confirmation -- see module header.
-- reactor_decision.activate is already dirty-checked by
-- rt2_reactor.compute_active_decision() against this tick's own reading
-- (false once the reactor reads active), so this never issues a redundant
-- setActive(true) once the reactor is confirmed on.
function M.apply_reactor(reactor_adapter, name, log_prefix, reactor_decision)
  local ok, err = reactor_adapter.apply_rod_level(name, reactor_decision.rods, log_prefix)
  local result = { ok = ok, err = err }
  if reactor_decision.activate and type(reactor_adapter.set_active) == "function" then
    result.active_ok, result.active_err = reactor_adapter.set_active(name, true, log_prefix)
  end
  return result
end

return M
