local M = {}

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

return M
