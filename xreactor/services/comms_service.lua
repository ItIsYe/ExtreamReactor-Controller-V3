local constants = require("shared.constants")
local comms_lib = require("core.comms")
local network_lib = require("core.network")
local utils = require("core.utils")

local comms_service = {}

local function control_channel(config)
  return (config.channels and config.channels.control) or constants.channels.CONTROL
end

local function status_channel(config)
  return (config.channels and config.channels.status) or constants.channels.STATUS
end

function comms_service.new(opts)
  opts = opts or {}
  local self = {
    config = opts.config or {},
    log_prefix = opts.log_prefix or "COMMS",
    role = opts.role,
    node_id = opts.node_id,
    on_message = opts.on_message,
    on_command = opts.on_command,
    on_status = opts.on_status,
    on_heartbeat = opts.on_heartbeat,
    on_alert = opts.on_alert,
    on_error = opts.on_error,
    network = nil,
    comms = nil
  }
  return setmetatable(self, { __index = comms_service })
end

function comms_service:init()
  self.network = network_lib.init(self.config)
  local normalized_id = utils.normalize_node_id(self.network.id)
  if normalized_id ~= self.network.id then
    utils.log(self.log_prefix, "WARN: normalized node_id to string", "WARN")
    self.network.id = normalized_id
  end
  self.comms = comms_lib.init({
    network = self.network,
    node_id = self.network.id,
    role = self.network.role,
    proto_ver = constants.proto_ver,
    log_prefix = self.log_prefix,
    config = self.config.comms or {}
  })

  self.comms.on(constants.message_types.STATUS, function(message)
    if self.on_status then
      self.on_status(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.HEARTBEAT, function(message)
    if self.on_heartbeat then
      self.on_heartbeat(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.COMMAND, function(message)
    if self.on_command then
      return self.on_command(message)
    end
    return { ok = false, error = "command handler missing" }
  end)

  self.comms.on(constants.message_types.ALERT, function(message)
    if self.on_alert then
      self.on_alert(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ERROR, function(message)
    if self.on_error then
      self.on_error(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ACK_DELIVERED, function(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ACK_APPLIED, function(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.HELLO, function(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.REGISTER, function(message)
    if self.on_message then
      self.on_message(message)
    end
  end)
end

function comms_service:send_command(target, command, opts)
  local payload = { target = target, command = command }
  return self.comms.send(target, constants.message_types.COMMAND, payload, {
    priority = 1,
    require_ack = true,
    require_applied = opts and opts.requires_applied or false,
    channel = control_channel(self.config)
  })
end

function comms_service:publish_status(payload, opts)
  return self.comms.send(nil, constants.message_types.STATUS, payload, {
    priority = 2,
    require_ack = opts and opts.requires_ack or false,
    channel = status_channel(self.config)
  })
end

function comms_service:send_heartbeat(state)
  return self.comms.send(nil, constants.message_types.HEARTBEAT, { state = state }, {
    priority = 3,
    require_ack = false,
    channel = status_channel(self.config)
  })
end

function comms_service:send_alert(severity, message)
  return self.comms.send(nil, constants.message_types.ALERT, { severity = severity, message = message }, {
    priority = 1,
    require_ack = false,
    channel = status_channel(self.config)
  })
end

function comms_service:send_hello(capabilities)
  return self.comms.send(nil, constants.message_types.HELLO, { capabilities = capabilities or {} }, {
    priority = 2,
    require_ack = false,
    channel = control_channel(self.config)
  })
end

function comms_service:handle_event(event)
  if event[1] == "modem_message" then
    local _, _, _, _, message = table.unpack(event)
    self.comms.receive(message)
  end
end

function comms_service:tick(now)
  self.comms.tick(now)
end

function comms_service:get_peers()
  return self.comms.get_peer_state()
end

function comms_service:is_master_reachable()
  local peers = self:get_peers() or {}
  for _, data in pairs(peers) do
    if data.role == constants.roles.MASTER then
      return not data.down
    end
  end
  return false
end

return comms_service
