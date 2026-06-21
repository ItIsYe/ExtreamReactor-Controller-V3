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

local function sanitize_channels(config)
  config.channels = type(config.channels) == "table" and config.channels or {}
  if type(config.channels.control) ~= "number" then
    config.channels.control = constants.channels.CONTROL
  end
  if type(config.channels.status) ~= "number" then
    config.channels.status = constants.channels.STATUS
  end
end

local function normalize_role(role)
  if role == nil then return nil end
  return tostring(role):upper():gsub("_", "-")
end

local function payload_looks_rt(payload)
  if type(payload) ~= "table" then return false end
  if type(payload.rt) == "table" then return true end
  if type(payload.turbines) == "table" or type(payload.reactors) == "table" or type(payload.modules) == "table" then return true end
  if payload.turbine_rpm ~= nil or payload.steam ~= nil or payload.ramp_state ~= nil then return true end
  if payload.mode ~= nil and (payload.output ~= nil or payload.state ~= nil) then return true end
  return false
end

local function count_keys(value)
  if type(value) ~= "table" then return 0 end
  local n = 0
  for _, _ in pairs(value) do n = n + 1 end
  return n
end

local function yesno(value)
  return value and "yes" or "no"
end

function comms_service.new(opts)
  opts = opts or {}
  local self = {
    name = opts.name or "COMMS",
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
    comms = nil,
    rx_diag_seen = {}
  }
  return setmetatable(self, { __index = comms_service })
end

function comms_service:trace_master_rx(message)
  if self.log_prefix ~= "MASTER" or type(message) ~= "table" then return end
  local payload = type(message.payload) == "table" and message.payload or {}
  local role = normalize_role(message.role)
  local payload_role = normalize_role(payload.role)
  local meta_role = normalize_role(type(payload.meta) == "table" and payload.meta.role or nil)
  local interesting = payload_looks_rt(payload) or role == "RT-NODE" or payload_role == "RT-NODE" or meta_role == "RT-NODE"
  if not interesting and role == "ENERGY-NODE" then return end
  local node_id = utils.normalize_node_id(message.node_id or message.sender_id or message.src)
  local key = tostring(node_id) .. ":" .. tostring(message.type) .. ":" .. tostring(message.role or "-") .. ":" .. tostring(payload.role or "-") .. ":" .. tostring(meta_role or "-")
  if self.rx_diag_seen[key] then return end
  self.rx_diag_seen[key] = true
  utils.log(self.log_prefix, ("RX diag node=%s type=%s sender=%s role=%s payload_role=%s meta_role=%s keys=%d mode=%s state=%s output=%s turbines=%s reactors=%s modules=%s"):format(
    tostring(node_id),
    tostring(message.type or "?"),
    tostring(message.sender_id or message.src or "?"),
    tostring(message.role or "-"),
    tostring(payload.role or "-"),
    tostring(meta_role or "-"),
    count_keys(payload),
    yesno(payload.mode ~= nil),
    yesno(payload.state ~= nil),
    yesno(payload.output ~= nil),
    yesno(type(payload.turbines) == "table"),
    yesno(type(payload.reactors) == "table"),
    yesno(type(payload.modules) == "table")
  ), "INFO")
end

function comms_service:init()
  sanitize_channels(self.config)
  self.config.comms = comms_lib.sanitize_config(self.config.comms or {})
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
    self:trace_master_rx(message)
    if self.on_status then
      self.on_status(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.HEARTBEAT, function(message)
    self:trace_master_rx(message)
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
    self:trace_master_rx(message)
    if self.on_alert then
      self.on_alert(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ERROR, function(message)
    self:trace_master_rx(message)
    if self.on_error then
      self.on_error(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ACK_DELIVERED, function(message)
    self:trace_master_rx(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ACK_APPLIED, function(message)
    self:trace_master_rx(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.HELLO, function(message)
    self:trace_master_rx(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.REGISTER, function(message)
    self:trace_master_rx(message)
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
    require_applied = opts and (opts.requires_applied or opts.require_applied) or false,
    channel = control_channel(self.config)
  })
end

function comms_service:publish_status(payload, opts)
  return self.comms.send(nil, constants.message_types.STATUS, payload, {
    priority = 2,
    require_ack = false,
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
    if utils.handle_remote_log_message and utils.handle_remote_log_message(message) then
      return true
    end
    self.comms.receive(message)
  end
end

function comms_service:tick(now)
  if utils.flush_remote_logs then utils.flush_remote_logs() end
  self.comms.tick(now)
end

function comms_service:get_peers()
  return self.comms.get_peer_state()
end

function comms_service:get_diagnostics()
  return self.comms.get_diagnostics()
end

function comms_service:consume_timeouts()
  return self.comms.consume_timeouts()
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
