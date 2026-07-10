-- nodes/fuel/command_handler.lua
--
-- Feature (2026-07-09): Modularisierungs-Rewrite. Reine Kommando-Parsing/
-- Dispatch-Logik hier -- die eigentlichen Effekte (Reserve setzen,
-- Fuel-Status-Daten uebernehmen) laufen ueber Callback-Funktionen, die
-- main.lua bereitstellt. So bleibt dieses Modul unabhaengig von main.lua's
-- konkreter State-Verwaltung (reserve-Variable, fuel_status_cache, ...)
-- und laesst sich leicht um neue Kommandos erweitern, ohne main.lua
-- anfassen zu muessen.
--
-- Erwartete ctx-Felder:
--   support_command_handler, protocol, comms, devices, constants, utils,
--   set_reserve = function(new_value) -> ok:boolean,
--   on_fuel_status = function(value_table),  -- siehe fuel_status_network.lua

local M = {}

function M.handle(message, ctx)
  local sch = ctx.support_command_handler
  local constants = ctx.constants
  local devices = ctx.devices

  local command, parse_error = sch.parse_node_command(message, { protocol = ctx.protocol, comms = ctx.comms })
  if parse_error then return sch.finish_with_result(devices, parse_error) end
  if not command then return end

  if command.target == constants.command_targets.SET_RESERVE then
    local new_reserve = tonumber(command.value)
    if type(new_reserve) == "number" and new_reserve >= 0 then
      ctx.set_reserve(new_reserve)
      ctx.utils.log("FUEL", "Reserve updated to " .. tostring(new_reserve))
    else
      ctx.utils.log("FUEL", "SET_RESERVE rejected: invalid value=" .. tostring(command.value), "WARN")
      return sch.finish_with_result(devices, { ok = false, error = "invalid reserve value", reason_code = "INVALID_VALUE" })
    end
  elseif command.target == constants.command_targets.FUEL_STATUS then
    if type(command.value) == "table" then
      ctx.on_fuel_status(command.value)
    end
  elseif command.target == constants.command_targets.MODE and command.value == constants.node_states.MANUAL then
    -- kein Effekt, aber explizit als unterstuetzt behandelt (nicht rejecten)
  else
    return sch.reject_unsupported(devices)
  end
  return sch.finish(devices, true)
end

return M
