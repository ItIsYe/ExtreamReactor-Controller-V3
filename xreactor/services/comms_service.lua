local constants = require("shared.constants")
local comms_lib = require("core.comms")
local network_lib = require("core.network")
local protocol = require("core.protocol")
local utils = require("core.utils")

local comms_service = {}

function comms_service.new(opts)
  opts = opts or {}
  local self = {
    config = opts.config or {},
    log_prefix = opts.log_prefix or "COMMS",
    role = opts.role,
    node_id = opts.node_id,
    on_message = opts.on_message,
    network = nil,
    comms = nil
  }
  return setmetatable(self, { __index = comms_service })
end

function comms_service:init()
  self.network = network_lib.init(self.config)
  self.comms = comms_lib.new({
    network = self.network,
    node_id = self.network.id,
    role = self.network.role,
    log_prefix = self.log_prefix,
    config = self.config.comms or {}
  })
  local normalized_id = utils.normalize_node_id(self.network.id)
  if normalized_id ~= self.network.id then
    utils.log(self.log_prefix, "WARN: normalized node_id to string", "WARN")
    self.network.id = normalized_id
  end
end

function comms_service:send_command(target, command, opts)
  local message = protocol.command(self.network.id, self.network.role, target, command)
  message.dst = target
  return self.comms:send(message, constants.channels.CONTROL, {
    priority = 1,
    requires_ack = true,
    requires_applied = opts and opts.requires_applied or false
  })
end

function comms_service:publish_status(payload, opts)
  local message = protocol.status(self.network.id, self.network.role, payload)
  return self.comms:send(message, constants.channels.STATUS, {
    priority = 2,
    requires_ack = opts and opts.requires_ack ~= nil and opts.requires_ack or true
  })
end

function comms_service:send_heartbeat(state)
  local message = protocol.heartbeat(self.network.id, self.network.role, state)
  return self.comms:send(message, constants.channels.STATUS, { priority = 3, requires_ack = false })
end

function comms_service:send_alert(severity, message)
  local alert = protocol.alert(self.network.id, self.network.role, severity, message)
  return self.comms:send(alert, constants.channels.STATUS, { priority = 1, requires_ack = true })
end

function comms_service:send_hello(capabilities)
  local hello = protocol.hello(self.network.id, self.network.role, capabilities or {})
  return self.comms:send(hello, constants.channels.CONTROL, { priority = 2, requires_ack = false })
end

function comms_service:send_applied_ack(message, detail)
  if not message then return end
  self.comms:send_ack(message, "applied", detail)
end

function comms_service:send_command_ack(message, detail, module_id, phase)
  if not message then return end
  local ack = protocol.ack(self.network.id, self.network.role, message.payload and message.payload.command and message.payload.command.command_id, detail, module_id)
  ack.ack_for = message.message_id
  ack.phase = phase or "applied"
  ack.src = self.network.id
  ack.dst = message.src
  self.comms:send(ack, constants.channels.CONTROL, { priority = 1, requires_ack = false })
end

function comms_service:handle_event(event)
  if event[1] == "modem_message" then
    local _, _, _, _, message = table.unpack(event)
    local incoming = self.comms:handle_incoming(message)
    if incoming and self.on_message then
      self.on_message(incoming)
    end
  end
end

function comms_service:tick()
  self.comms:tick()
end

function comms_service:get_peer_health()
  return self.comms:get_peer_health()
end

return comms_service
