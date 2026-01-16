local constants = require("shared.constants")

local protocol = {}

local function normalize_proto(ver)
  if type(ver) == "table" then
    local major = tonumber(ver.major)
    local minor = tonumber(ver.minor) or 0
    if major then
      return { major = major, minor = minor }
    end
  elseif type(ver) == "string" then
    local major, minor = ver:match("^(%d+)%.(%d+)$")
    if major then
      return { major = tonumber(major), minor = tonumber(minor) }
    end
    local single = tonumber(ver)
    if single then
      return { major = single, minor = 0 }
    end
  elseif type(ver) == "number" then
    return { major = ver, minor = 0 }
  end
  return { major = constants.proto_ver.major, minor = constants.proto_ver.minor }
end

local function is_proto_compatible(ver)
  local current = normalize_proto(constants.proto_ver)
  local incoming = normalize_proto(ver)
  if incoming.major ~= current.major then
    return false, "proto_ver mismatch"
  end
  return true
end

local function sanitize_value(value, depth)
  if depth > 6 then
    return nil
  end
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return value
  end
  if value_type ~= "table" then
    return nil
  end
  local out = {}
  for k, v in pairs(value) do
    local key_type = type(k)
    if key_type == "string" or key_type == "number" then
      local sanitized = sanitize_value(v, depth + 1)
      if sanitized ~= nil then
        out[k] = sanitized
      end
    end
  end
  return out
end

local function base_message(msg_type, sender_id, role, payload)
  return {
    type = msg_type,
    sender_id = utils.normalize_node_id(sender_id),
    node_id = utils.normalize_node_id(sender_id),
    role = role,
    timestamp = os.epoch("utc"),
    proto_ver = normalize_proto(constants.proto_ver),
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

function protocol.sanitize_message(message)
  if type(message) ~= "table" then return nil end
  local normalized_proto = normalize_proto(message.proto_ver)
  local sanitized = {
    type = message.type,
    sender_id = utils.normalize_node_id(message.sender_id),
    node_id = utils.normalize_node_id(message.node_id or message.sender_id),
    role = message.role,
    timestamp = message.timestamp,
    proto_ver = normalized_proto,
    payload = sanitize_value(message.payload or {}, 0)
  }
  if type(sanitized.payload) ~= "table" then
    sanitized.payload = {}
  end
  return sanitized
end

function protocol.validateMessage(message)
  if type(message) ~= "table" then return false, "message not table" end
  if type(message.type) ~= "string" then return false, "missing type" end
  local sender_id = utils.normalize_node_id(message.sender_id)
  if sender_id == "UNKNOWN" then return false, "missing sender_id" end
  if type(message.role) ~= "string" then return false, "missing role" end
  if type(message.timestamp) ~= "number" then return false, "missing timestamp" end
  if type(message.payload) ~= "table" then return false, "missing payload" end
  local ok, err = is_proto_compatible(message.proto_ver)
  if not ok then return false, err end
  return true
end

function protocol.validate(message)
  return protocol.validateMessage(message)
end

function protocol.is_for_node(message, node_id)
  local payload = message.payload or {}
  if message.type == constants.message_types.COMMAND then
    return payload.target == node_id
  end
  return true
end

return protocol
