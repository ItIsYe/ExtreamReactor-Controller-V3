local M = {}

function M.new(opts)
  opts = opts or {}
  local protocol = assert(opts.protocol, "protocol required")
  local constants = assert(opts.constants, "constants required")
  local get_comms_id = assert(opts.get_comms_id, "get_comms_id required")
  local set_last_command = assert(opts.set_last_command, "set_last_command required")
  local mark_master_seen = opts.mark_master_seen
  local on_master_alerts = opts.on_master_alerts
  local on_proto_mismatch = opts.on_proto_mismatch

  local handler = {}

  function handler.handle_message(message)
    if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
      if on_proto_mismatch then on_proto_mismatch() end
      return
    end
    if message.role == constants.roles.MASTER then
      if mark_master_seen then mark_master_seen() end
      if message.type == constants.message_types.STATUS and message.payload and message.payload.alerts and on_master_alerts then
        on_master_alerts(message.payload.alerts)
      end
    end
  end

  function handler.handle_command(message)
    if not protocol.is_for_node(message, get_comms_id()) then return end
    local ok_proto = protocol.is_proto_compatible(message.proto_ver)
    if not ok_proto then
      return { ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" }
    end
    local payload = type(message.payload) == "table" and message.payload or nil
    local command = payload and payload.command
    if type(command) ~= "table" then
      local result = { ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" }
      set_last_command(result.error)
      return result
    end
    local result = { ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" }
    set_last_command(result.error)
    return result
  end

  return handler
end

return M
