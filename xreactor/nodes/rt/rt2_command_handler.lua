-- RT rewrite, step 7: command handling.
--
-- The single biggest structural change here: MODE IS NO LONGER A COMMAND.
-- In the old implementation, MASTER told RT "you are now in MASTER mode"
-- (SET_MODE), and RT's own connectivity tracking separately decided
-- AUTONOM on disconnect -- two independent writers of the same fact, which
-- is exactly the shape of bug this project hit in production (MASTER's
-- cached belief about the node's mode went stale, and nothing forced it
-- back in sync for 20+ minutes). In this rewrite, rt2_state.lua derives
-- MASTER vs AUTONOM purely from rt2_master_link's connectivity signal --
-- there is nothing for a SET_MODE command to set, so there is nothing
-- that can desync. A SET_MODE/MODE command is accepted as a harmless
-- no-op (some MASTER versions may still send it) rather than acted on.
--
-- Every handler is a pure function: (command, world) -> result, where
-- `world` is a plain snapshot table (never a live ctx) describing what
-- this command needs to know to be validated. Side effects (updating
-- master_percent, requesting a manual SCRAM) are returned as an explicit
-- `effects` table for the caller to apply -- this handler never mutates
-- anything itself, so it is testable with plain tables exactly like
-- rt2_turbine/rt2_reactor.

local M = {}

local rt2_state = require('nodes.rt.rt2_state')

local function ok(effects)
  return { ok = true, effects = effects }
end

local function fail(error_msg, reason_code)
  return { ok = false, error = error_msg, reason_code = reason_code }
end

local handlers = {}

-- SET_SETPOINTS { power_target_percent } -- only meaningful while the
-- node is actually in MASTER state. If it isn't (still LEARNING, in
-- AUTONOM because MASTER only just reconnected and the link hasn't
-- caught up yet, or SAFE), reject explicitly with a real reason_code --
-- the old false-success bug (nil return silently became {ok=true}) has
-- no equivalent construction here: every branch returns a real result.
handlers.SET_SETPOINTS = function(command, world)
  if world.state ~= rt2_state.states.MASTER then
    return fail("node not in MASTER state (currently " .. tostring(world.state) .. ")", "INVALID_STATE")
  end
  local value = command.value or {}
  local percent = tonumber(value.power_target_percent)
  if type(percent) ~= "number" or percent < 0 or percent > 100 then
    return fail("invalid power_target_percent: " .. tostring(value.power_target_percent), "INVALID_VALUE")
  end
  return ok({ master_percent = percent })
end

-- SCRAM is always accepted, from any state, including while already
-- SAFE (idempotent -- re-asserting a trip changes nothing).
handlers.SCRAM = function(_, _)
  return ok({ manual_safety_trip = true })
end

-- The way BACK from a manual SCRAM. Without this the manual trip latch
-- could only ever be set, never released: SCRAM latched manual_safety_trip
-- forever and the SAFE blanket block below rejected every other command,
-- so a SCRAMmed v2 node stayed dead until someone physically rebooted the
-- computer -- MASTER had no way to restart the plant at all.
--
-- Reuses the command MASTER already sends to bring modules back up
-- (REQUEST_STARTUP_MODULE/STARTUP_STAGE in v1's command_handler.lua)
-- rather than inventing a new protocol verb MASTER would have to learn.
--
-- This clears ONLY the manual latch. A still-active physical condition
-- (temperature/coolant) is evaluated independently from the live reading
-- every tick in rt2_engine, so an operator cannot "acknowledge away" a
-- reactor that is genuinely still over its limit -- it simply trips again
-- on the next tick.
local function clear_trip()
  return ok({ clear_safety_trip = true })
end
handlers.REQUEST_STARTUP_MODULE = clear_trip
handlers.STARTUP_STAGE = clear_trip

-- The only command targets that get through while SAFE.
local SAFE_ALLOWED = {
  SCRAM = true,
  REQUEST_STARTUP_MODULE = true,
  STARTUP_STAGE = true,
}

-- MODE/SET_MODE: accepted, deliberately a no-op (see module header).
handlers.SET_MODE = function(_, _) return ok({}) end
handlers.MODE = function(_, _) return ok({}) end

handlers.REQUEST_STATUS = function(_, _)
  return ok({ status_requested = true })
end

-- world: { state = <rt2_state.states value> }
function M.handle(command, world)
  world = world or {}
  if type(command) ~= "table" or type(command.target) ~= "string" then
    return fail("invalid command", "INVALID_COMMAND")
  end
  -- SAFE allows exactly two things: SCRAM (idempotent re-assert) and the
  -- restart commands that release the manual trip -- without the latter,
  -- SAFE would be a state with no exit (see clear_trip above). Every
  -- other target is blocked before even reaching its handler -- one rule,
  -- one place, instead of a per-handler INVALID_STATE check that a future
  -- handler could forget to add.
  if world.state == rt2_state.states.SAFE and not SAFE_ALLOWED[command.target] then
    return fail("safe: ignoring commands", "SAFE_MODE")
  end
  local handler = handlers[command.target]
  if not handler then
    return fail("unsupported command: " .. tostring(command.target), "UNSUPPORTED_COMMAND")
  end
  return handler(command, world)
end

return M
