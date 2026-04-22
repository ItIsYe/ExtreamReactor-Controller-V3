local M = {}

local function stamp_result(devices, label)
  if type(devices) ~= "table" then
    return
  end
  devices.last_command = label
  devices.last_command_ts = os.epoch("utc")
end

function M.handle_common(ctx, msg)
  if type(msg) ~= "table" then
    return false
  end

  local cmd = msg.cmd
  if cmd == "PING" then
    if ctx and ctx.comms then
      ctx.comms:send_ack(msg, true, { pong = true })
    end
    return true
  end

  if cmd == "TERMINATE" or cmd == "SHUTDOWN" then
    if ctx and ctx.utils then
      ctx.utils.log(ctx.log_prefix, "Shutdown command received", "WARN")
    end
    if ctx and ctx.comms then
      ctx.comms:send_ack(msg, true, { terminating = true })
    end
    if type(ctx.on_shutdown) == "function" then
      ctx.on_shutdown(msg)
    end
    return true
  end

  return false
end

function M.parse_node_command(message, opts)
  if type(message) ~= "table" then
    return nil, { ok = false, error = "invalid message", reason_code = "INVALID_MESSAGE" }
  end

  local protocol = opts and opts.protocol
  local comms = opts and opts.comms
  local node_id = comms and comms.network and comms.network.id

  if protocol and node_id and not protocol.is_for_node(message, node_id) then
    return nil, nil
  end

  if protocol and not protocol.is_proto_compatible(message.proto_ver) then
    return nil, { ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" }
  end

  local payload = type(message.payload) == "table" and message.payload or nil
  local command = payload and payload.command
  if type(command) ~= "table" then
    return nil, { ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" }
  end

  return command, nil
end

function M.reject_unsupported(devices)
  local result = { ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" }
  stamp_result(devices, result.error)
  return result
end

function M.finish(devices, ok)
  stamp_result(devices, ok and "ok" or "failed")
  return { ok = ok and true or false }
end

function M.finish_with_result(devices, result)
  local label = (result and result.ok) and "ok" or (result and result.error) or "failed"
  stamp_result(devices, label)
  return result
end

return M
