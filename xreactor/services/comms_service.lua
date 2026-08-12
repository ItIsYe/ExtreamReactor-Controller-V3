local constants = require("shared.constants")
local comms_lib = require("core.comms")
local network_lib = require("core.network")
local utils = require("core.utils")
local build_info = require("shared.build_info")

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
    rx_diag_seen = {},
    -- Fix (2026-07-14): SHARED-P0 (siehe service_manager.lua). COMMS muss
    -- ein gerade empfangenes modem_message sofort verarbeiten (ACK/Dedupe/
    -- Retry-Reaktion), meldet sich daher immer fuer Event-Ticks an.
    wants_events = true
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

local function command_target(message)
  local payload = type(message) == "table" and message.payload or nil
  local command = type(payload) == "table" and payload.command or nil
  return type(command) == "table" and command.target or nil
end

function comms_service:_authorize_command(message)
  if type(message) ~= "table" then return false, "invalid command envelope" end
  local local_role = normalize_role(self.network and self.network.role or self.role or self.config.role)

  -- The coordinator sends commands; it does not accept peer control commands.
  -- Local Master actions (for example the redstone update trigger) use their
  -- direct runtime APIs and never arrive through this handler.
  if local_role == normalize_role(constants.roles.MASTER) then
    return false, "MASTER does not accept network commands"
  end
  if normalize_role(message.role) ~= normalize_role(constants.roles.MASTER) then
    return false, "command sender is not MASTER"
  end

  local sender = message.src or message.sender_id or message.node_id
  if sender == nil or tostring(sender):match("^%s*$") then
    return false, "command sender identity missing"
  end
  local expected = self.config.trusted_master_id or self.config.master_node_id
  if expected == nil and type(self.config.comms) == "table" then
    expected = self.config.comms.trusted_master_id
  end
  if expected ~= nil
      and utils.normalize_node_id(sender) ~= utils.normalize_node_id(expected) then
    return false, "command sender does not match trusted master id"
  end
  return true
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
    local authorized, reason = self:_authorize_command(message)
    if not authorized then
      utils.log(self.log_prefix,
        "Command rejected before role handler: " .. tostring(reason)
          .. " src=" .. tostring(message and (message.src or message.sender_id) or "?")
          .. " role=" .. tostring(message and message.role or "?")
          .. " target=" .. tostring(command_target(message) or "?"), "WARN")
      return { ok = false, error = reason, reason_code = "UNAUTHORIZED_COMMAND_SOURCE" }
    end

    -- Remote updates are runtime infrastructure, not role-specific business
    -- logic. Queue them for the single updater coroutine instead of executing
    -- an installer from inside a modem event handler.
    if command_target(message) == constants.command_targets.REMOTE_UPDATE then
      return require("core.remote_update").queue_command({
        message = message,
        log_prefix = self.log_prefix,
        utils = utils,
      })
    end
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
  local payload = { state = state }
  local build = build_info.get()
  if type(build) == "table" and build.manifest_version ~= nil then
    payload.manifest_version = build.manifest_version
  end
  return self.comms.send(nil, constants.message_types.HEARTBEAT, payload, {
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

-- Fix (2026-07-27): CRITICAL. Reported node-crash ("attempt to index field
-- 'comms' (a nil value)" at this call site): self.comms is only set by
-- init() (see above), but some callers (e.g. nodes/support/runtime.lua's
-- run_event_loop()) invoke handle_event()/tick() directly, outside of
-- service_manager's own init-before-tick guard. If a role forgets to call
-- services:init() before entering its event loop (as VALVE did until this
-- fix, see nodes/valve/main.lua), the very first modem_message received --
-- entirely plausible as literally the first event on a server with any
-- radio traffic at all, not limited to messages addressed to this node --
-- crashed the whole node before init() ever got a chance to run. Guarded
-- here as defense-in-depth (the actual fix is calling services:init()
-- before the event loop starts, restoring intended behavior instead of
-- silently dropping early messages) -- a future role that makes the same
-- ordering mistake now fails safe (drops the event) instead of crashing.
function comms_service:handle_event(event)
  if not self.comms then return end
  if event[1] == "modem_message" then
    local _, _, _, _, message = table.unpack(event)
    if utils.handle_remote_log_message and utils.handle_remote_log_message(message) then
      return true
    end
    self.comms.receive(message)
  end
end

function comms_service:tick()
  if not self.comms then return end
  if utils.flush_remote_logs then utils.flush_remote_logs() end
  self.comms.tick()
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
