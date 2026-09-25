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
    -- NICHT auf 0 vorbelegen. adapters/turbine.lua's read_number() liefert
    -- bei einem fehlgeschlagenen Peripherieaufruf den String "n/a" -- daraus
    -- eine 0 zu machen heisst, "unbekannt" als "steht auf 0" auszugeben.
    -- Genau darauf ist der Livetest auf node-101 aufgelaufen: der Regler
    -- entschied korrekt auf Durchfluss 0, verglich das gegen diese erfundene
    -- 0, hielt die Vorgabe fuer bereits gesetzt und schrieb nie -- waehrend
    -- im Mod weiter 2000 anstanden und die Rotoren lastfrei hochliefen.
    -- nil heisst jetzt nil, und der Aufrufer muss damit umgehen.
    current_flow = num_or_nil(turbine_info.flow),
    active = turbine_info.active == true,
  }
end

-- reactor_info: the table returned by adapters/reactor.lua's inspect().
-- temperature/coolant_* are the inputs rt2_safety.evaluate() needs -- they
-- are read from the SAME inspect() call the control decision already uses,
-- so wiring safety in costs no extra peripheral round-trip per tick.
function M.read_reactor(reactor_info)
  if type(reactor_info) ~= "table" then return nil end
  return {
    fill_ratio = num_or_nil(reactor_info.steam_fill_ratio),
    current_rods = num_or_nil(reactor_info.control_rod_level),
    active = reactor_info.active == true,
    temperature = num_or_nil(reactor_info.temperature),
    coolant_ratio = num_or_nil(reactor_info.coolant_ratio),
    coolant_amount = num_or_nil(reactor_info.coolant_amount),
    coolant_amount_max = num_or_nil(reactor_info.coolant_amount_max),
  }
end

-- Writes one turbine's flow+coil+activation decision to hardware via the
-- given turbine_adapter module (adapters/turbine.lua in production, a fake
-- in tests). Returns a small result table for logging -- never raises.
-- turbine_result.activate is already dirty-checked by
-- rt2_turbine.compute_active_decision() against this tick's own reading
-- (false once the turbine reads active), so this never issues a redundant
-- setActive(true) once the turbine is confirmed on.
function M.apply_turbine(turbine_adapter, name, log_prefix, turbine_result)
  local result = {}
  -- unchanged: die Vorgabe steht bereits genau so an der Turbine (vom
  -- Orchestrator gegen den zurueckgelesenen Wert geprueft). Seit der
  -- Regler eine Ruhezone hat, ist das der Normalfall, und ein Schreiben
  -- je Turbine und Takt waere reine Last ohne Wirkung.
  if turbine_result.flow_decision and turbine_result.flow_decision.unchanged ~= true then
    result.flow_ok, result.flow_err = turbine_adapter.set_flow(name, turbine_result.flow_decision.flow, log_prefix)
  end
  if turbine_result.coil_decision then
    result.coil_ok, result.coil_err = turbine_adapter.set_coils(name, turbine_result.coil_decision.engaged, log_prefix)
  end
  if turbine_result.activate and type(turbine_adapter.set_active) == "function" then
    result.active_ok, result.active_err = turbine_adapter.set_active(name, true, log_prefix)
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
