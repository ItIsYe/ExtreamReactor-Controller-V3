local constants = require("shared.constants")
local utils = require("core.utils")

local protocol = {}
local sequence = 0

local function normalize_proto(version)
  if type(version) == "table" then
    local major = tonumber(version.major)
    local minor = tonumber(version.minor) or 0
    if major then return { major = major, minor = minor } end
  elseif type(version) == "string" then
    local major, minor = version:match("^(%d+)%.(%d+)$")
    if major then return { major = tonumber(major), minor = tonumber(minor) } end
    local single = tonumber(version)
    if single then return { major = single, minor = 0 } end
  elseif type(version) == "number" then
    return { major = version, minor = 0 }
  end
  return nil
end

local function is_proto_compatible(version)
  local current = normalize_proto(constants.proto_ver)
  local incoming = normalize_proto(version)
  if not incoming then return false, "missing/invalid proto_ver" end
  if incoming.major ~= current.major then return false, "proto_ver mismatch" end
  return true
end

local function sanitize_value(value, depth)
  if depth > 6 then return nil end
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return value
  end
  if value_type ~= "table" then return nil end

  local result = {}
  for key, item in pairs(value) do
    local key_type = type(key)
    if key_type == "string" or key_type == "number" then
      local sanitized = sanitize_value(item, depth + 1)
      if sanitized ~= nil then result[key] = sanitized end
    end
  end
  return result
end

-- normalize_node_id() intentionally falls back to the local computer ID for
-- local identity creation. Never use that fallback for a remote envelope.
local function normalize_remote_id(value)
  if value == nil then return nil end
  local text = tostring(value):match("^%s*(.-)%s*$") or ""
  if text == "" then return nil end
  return utils.normalize_node_id(text)
end

local function now_ms()
  return os.epoch("utc")
end

local function base_message(message_type, sender_id, role, payload)
  local timestamp = now_ms()
  local sender = utils.normalize_node_id(sender_id)
  sequence = sequence + 1
  return {
    type = message_type,
    message_id = string.format("%s-%d-%d", tostring(sender), timestamp, sequence),
    sender_id = sender,
    src = sender,
    dst = nil,
    node_id = sender,
    role = role,
    ts = timestamp,
    timestamp = timestamp,
    proto_ver = normalize_proto(constants.proto_ver),
    payload = payload or {},
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
  return base_message(constants.message_types.ALERT, sender_id, role,
    { severity = severity, message = message })
end

function protocol.command(sender_id, role, target_node, command)
  command = type(command) == "table" and command or {}
  command.command_id = command.command_id or now_ms()
  local message = base_message(constants.message_types.COMMAND, sender_id, role,
    { target = target_node, command = command })
  message.dst = target_node
  return message
end

function protocol.ack(sender_id, role, command_id, detail, module_id)
  return base_message(constants.message_types.ACK, sender_id, role,
    { command_id = command_id, detail = detail, module_id = module_id })
end

function protocol.ack_delivered(sender_id, role, command_id, detail)
  return base_message(constants.message_types.ACK_DELIVERED, sender_id, role,
    { command_id = command_id, detail = detail })
end

function protocol.ack_applied(sender_id, role, command_id, result)
  return base_message(constants.message_types.ACK_APPLIED, sender_id, role,
    { command_id = command_id, result = result })
end

function protocol.error(sender_id, role, message)
  return base_message(constants.message_types.ERROR, sender_id, role, { message = message })
end

function protocol.sanitize_message(message)
  if type(message) ~= "table" then return nil end
  local sender = normalize_remote_id(message.sender_id or message.src)
  local payload = nil
  if message.payload ~= nil then payload = sanitize_value(message.payload, 0) end
  return {
    type = message.type,
    message_id = message.message_id,
    sender_id = sender,
    node_id = normalize_remote_id(message.node_id or message.sender_id or message.src),
    src = normalize_remote_id(message.src or message.sender_id),
    dst = normalize_remote_id(message.dst),
    role = message.role,
    ts = message.ts or message.timestamp,
    timestamp = message.ts or message.timestamp,
    proto_ver = normalize_proto(message.proto_ver),
    ack_for = message.ack_for,
    phase = message.phase,
    payload = payload,
  }
end

function protocol.validateMessage(message)
  if type(message) ~= "table" then return false, "message not table" end
  if type(message.type) ~= "string" or message.type == "" then return false, "missing type" end
  if normalize_remote_id(message.sender_id or message.src) == nil then
    return false, "missing sender_id"
  end
  if type(message.role) ~= "string" or message.role == "" then return false, "missing role" end
  if type(message.ts) ~= "number" and type(message.timestamp) ~= "number" then
    return false, "missing timestamp"
  end
  if type(message.payload) ~= "table" then return false, "missing payload" end

  local compatible, proto_err = is_proto_compatible(message.proto_ver)
  if not compatible then return false, proto_err end

  if message.type == constants.message_types.COMMAND then
    if type(message.message_id) ~= "string" or message.message_id == "" then
      return false, "missing message_id"
    end
  elseif message.type == constants.message_types.ACK_DELIVERED
      or message.type == constants.message_types.ACK_APPLIED then
    if type(message.message_id) ~= "string" or message.message_id == "" then
      return false, "missing message_id"
    end
    if type(message.ack_for) ~= "string" or message.ack_for == "" then
      return false, "missing ack_for"
    end
  end
  return true
end

function protocol.validate(message)
  return protocol.validateMessage(message)
end

function protocol.is_proto_compatible(version)
  return is_proto_compatible(version)
end

function protocol.is_for_node(message, node_id)
  if type(message) ~= "table" then return false end
  local local_id = utils.normalize_node_id(node_id)
  local destination = normalize_remote_id(message.dst)
  if destination and destination ~= local_id then return false end

  local payload = type(message.payload) == "table" and message.payload or {}
  if message.type == constants.message_types.COMMAND then
    local target = normalize_remote_id(payload.target)
    if target and target ~= local_id then return false end
  end
  return true
end

return protocol
