local constants = require("shared.constants")
local utils = require("core.utils")

local protocol = {}

local function base_message(msg_type, sender_id, role, payload)
  return {
    type = msg_type,
    sender_id = sender_id,
    role = role,
    timestamp = os.epoch("utc"),
    payload = payload or {}
  }
end

function protocol.hello(sender_id, role, capabilities)
  return base_message(constants.message_types.HELLO, sender_id, role, { capabilities = capabilities })
end

function protocol.register(sender_id, role, capabilities)
  return base_message(constants.message_types.REGISTER, sender_id, role, { capabilities = capabilities })
end

function protocol.heartbeat(sender_id, role, state)
  return base_message(constants.message_types.HEARTBEAT, sender_id, role, { state = state })
end

function protocol.status(sender_id, role, payload)
  return base_message(constants.message_types.STATUS, sender_id, role, payload)
end

function protocol.alert(sender_id, role, severity, message)
  return base_message(constants.message_types.ALERT, sender_id, role, { severity = severity, message = message })
end

function protocol.command(sender_id, role, target_node, command)
  command.command_id = command.command_id or os.epoch("utc")
  return base_message(constants.message_types.COMMAND, sender_id, role, { target = target_node, command = command })
end

function protocol.ack(sender_id, role, command_id, detail, module_id)
  return base_message(constants.message_types.ACK, sender_id, role, { command_id = command_id, detail = detail, module_id = module_id })
end

function protocol.error(sender_id, role, message)
  return base_message(constants.message_types.ERROR, sender_id, role, { message = message })
end

function protocol.validate(message)
  if type(message) ~= "table" then return false end
  if not message.type or not message.sender_id or not message.role then
    return false
  end
  return true
end

function protocol.is_for_node(message, node_id)
  local payload = message.payload or {}
  if message.type == constants.message_types.COMMAND then
    return payload.target == node_id
  end
  return true
end

return protocol
