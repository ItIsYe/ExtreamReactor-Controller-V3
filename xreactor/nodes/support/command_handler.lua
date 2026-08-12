local M = {}
local utils = require("core.utils")

local function stamp_result(devices, label)
  if type(devices) ~= "table" then
    return
  end
  devices.last_command = label
  devices.last_command_ts = os.epoch("utc")
end

local function command_label(command)
  if type(command) ~= "table" then return "-" end
  return tostring(command.target or command.cmd or command.type or "UNKNOWN")
end

local function value_label(command)
  if type(command) ~= "table" then return "-" end
  local value = command.value
  if type(value) == "table" then return "table" end
  return tostring(value)
end

local function log_with_devices(devices, level, message)
  local logger = type(devices) == "table" and devices.command_logger or nil
  if type(logger) == "function" then
    local ok = pcall(logger, level or "INFO", message)
    if ok then return end
  end
  utils.log("SUPPORT", message, level or "INFO")
end

function M.parse_node_command(message, opts)
  if type(message) ~= "table" then
    return nil, { ok = false, error = "invalid message", reason_code = "INVALID_MESSAGE" }
  end

  local protocol = opts and opts.protocol
  local comms = opts and opts.comms
  local node_id = comms and comms.network and comms.network.id
  local log_prefix = opts and opts.log_prefix or (comms and comms.network and comms.network.role) or "SUPPORT"
  local logger = opts and opts.log

  local function log_parse(level, text)
    if type(logger) == "function" then
      local ok = pcall(logger, level or "INFO", text)
      if ok then return end
    end
    if opts and opts.utils and type(opts.utils.log) == "function" then
      opts.utils.log(log_prefix, text, level or "INFO")
      return
    end
    utils.log(log_prefix, text, level or "INFO")
  end

  if protocol and node_id and not protocol.is_for_node(message, node_id) then
    return nil, nil
  end

  if protocol and not protocol.is_proto_compatible(message.proto_ver) then
    log_parse("WARN", ("Command rejected target=UNKNOWN reason=PROTO_MISMATCH from=%s node=%s"):format(
      tostring(message.sender_id or message.src or "?"), tostring(node_id or "?")
    ))
    return nil, { ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" }
  end

  local payload = type(message.payload) == "table" and message.payload or nil
  local command = payload and payload.command
  if type(command) ~= "table" then
    log_parse("WARN", ("Command rejected target=UNKNOWN reason=INVALID_COMMAND from=%s node=%s"):format(
      tostring(message.sender_id or message.src or "?"), tostring(node_id or "?")
    ))
    return nil, { ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" }
  end

  log_parse("INFO", ("Command received target=%s value=%s from=%s node=%s"):format(
    command_label(command), value_label(command), tostring(message.sender_id or message.src or "?"), tostring(node_id or "?")
  ))

  return command, nil
end

function M.reject_unsupported(devices)
  local result = { ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" }
  stamp_result(devices, result.error)
  log_with_devices(devices, "WARN", "Command rejected target=UNKNOWN reason=UNSUPPORTED_COMMAND error=unsupported command")
  return result
end

-- Fix (2026-07-17): P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md Abschnitt 16). Optionales drittes `extra`-Argument, damit
-- Aufrufer wie WATER's SET_TARGET dem ACK_APPLIED-Ergebnis zusaetzliche,
-- ehrliche Felder mitgeben koennen (z.B. `persisted = false` nach einem
-- fehlgeschlagenen Config-Write) -- ohne `ok=true` selbst zu verfaelschen,
-- wenn der Wert im RAM trotzdem uebernommen wurde.
function M.finish(devices, ok, extra)
  stamp_result(devices, ok and "ok" or "failed")
  log_with_devices(devices, ok and "INFO" or "WARN", ("Command %s"):format(ok and "applied" or "failed"))
  local result = { ok = ok and true or false }
  if type(extra) == "table" then
    for k, v in pairs(extra) do result[k] = v end
  end
  return result
end

function M.finish_with_result(devices, result)
  local label = (result and result.ok) and "ok" or (result and result.error) or "failed"
  stamp_result(devices, label)
  if result then
    if result.ok == false then
      log_with_devices(devices, "WARN", ("Command rejected reason=%s error=%s"):format(tostring(result.reason_code or "UNKNOWN"), tostring(result.error or "unknown")))
    else
      log_with_devices(devices, "INFO", "Command applied")
    end
  end
  return result
end

return M
