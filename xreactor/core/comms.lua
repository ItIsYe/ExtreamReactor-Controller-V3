local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")

local comms = {}

local DEFAULT_CONFIG = {
  ack_timeout = 3.0,
  max_retries = 4,
  backoff_base = 0.6,
  backoff_cap = 6.0,
  dedupe_window = 200,
  peer_timeout = 12.0,
  queue_limit = 200
}

local function now()
  return os.epoch("utc")
end

local function merge_config(config)
  local merged = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    merged[k] = v
  end
  for k, v in pairs(config or {}) do
    merged[k] = v
  end
  return merged
end

local function build_id(state)
  state.seq = (state.seq or 0) + 1
  return string.format("%s-%d-%d", tostring(state.node_id), now(), state.seq)
end

local function schedule_backoff(config, retries)
  local delay = config.backoff_base * math.pow(2, retries - 1)
  return math.min(delay, config.backoff_cap)
end

local function log(self, message, level)
  utils.log(self.log_prefix, message, level)
end

function comms.new(opts)
  local self = {
    network = opts.network,
    node_id = opts.node_id,
    role = opts.role,
    log_prefix = opts.log_prefix or "COMMS",
    config = merge_config(opts.config),
    queue = {},
    inflight = {},
    dedupe = {},
    peers = {},
    state = { seq = 0, node_id = opts.node_id }
  }
  return setmetatable(self, { __index = comms })
end

local function prune_dedupe(self)
  local window = self.config.dedupe_window
  for peer, ids in pairs(self.dedupe) do
    if #ids > window then
      local start = #ids - window
      local trimmed = {}
      for i = start, #ids do
        table.insert(trimmed, ids[i])
      end
      self.dedupe[peer] = trimmed
    end
  end
end

local function add_dedupe(self, sender, msg_id)
  if not sender or not msg_id then return end
  self.dedupe[sender] = self.dedupe[sender] or {}
  table.insert(self.dedupe[sender], msg_id)
  prune_dedupe(self)
end

local function is_duplicate(self, sender, msg_id)
  local list = self.dedupe[sender]
  if not list then return false end
  for _, id in ipairs(list) do
    if id == msg_id then
      return true
    end
  end
  return false
end

function comms:queue_send(message, channel, opts)
  if #self.queue >= self.config.queue_limit then
    log(self, "Send queue full; dropping message " .. tostring(message.type), "WARN")
    return nil, "queue_full"
  end
  opts = opts or {}
  local entry = {
    message = message,
    channel = channel or constants.channels.CONTROL,
    priority = opts.priority or 2,
    requires_ack = opts.requires_ack or false,
    requires_applied = opts.requires_applied or false,
    retries = 0,
    next_retry = 0,
    sent_ts = nil
  }
  table.insert(self.queue, entry)
  table.sort(self.queue, function(a, b) return a.priority < b.priority end)
  return entry
end

function comms:send(message, channel, opts)
  message.message_id = message.message_id or build_id(self.state)
  message.src = message.src or self.node_id
  message.dst = message.dst
  message.timestamp = message.timestamp or now()
  message.proto_ver = message.proto_ver or constants.proto_ver
  return self:queue_send(message, channel, opts)
end

function comms:send_ack(original, phase, detail)
  if not original or not original.message_id then return end
  local ack = protocol.ack(self.node_id, self.role, original.payload and original.payload.command_id, detail)
  ack.ack_for = original.message_id
  ack.phase = phase or "delivered"
  ack.src = self.node_id
  ack.dst = original.src
  self:send(ack, constants.channels.CONTROL, { priority = 1 })
end

local function flush_queue(self)
  local remaining = {}
  for _, entry in ipairs(self.queue) do
    if entry.sent_ts and entry.sent_ts > 0 then
      table.insert(remaining, entry)
    else
      entry.sent_ts = now()
      local sanitized = protocol.sanitize_message(entry.message)
      if sanitized then
        self.network:send(entry.channel, sanitized)
        if entry.requires_ack then
          self.inflight[sanitized.message_id] = entry
        end
      end
    end
  end
  self.queue = remaining
end

local function retry_inflight(self)
  local now_ts = now()
  for msg_id, entry in pairs(self.inflight) do
    if entry.next_retry ~= 0 and now_ts < entry.next_retry then
      goto continue
    end
    local timeout = self.config.ack_timeout * 1000
    if entry.sent_ts and now_ts - entry.sent_ts < timeout then
      goto continue
    end
    entry.retries = entry.retries + 1
    if entry.retries > self.config.max_retries then
      log(self, "Message retry exhausted " .. tostring(msg_id), "WARN")
      self.inflight[msg_id] = nil
      goto continue
    end
    entry.sent_ts = now_ts
    entry.next_retry = now_ts + (schedule_backoff(self.config, entry.retries) * 1000)
    local sanitized = protocol.sanitize_message(entry.message)
    if sanitized then
      self.network:send(entry.channel, sanitized)
    end
    ::continue::
  end
end

local function update_peer(self, sender_id)
  if not sender_id then return end
  self.peers[sender_id] = self.peers[sender_id] or {}
  self.peers[sender_id].last_seen = now()
end

function comms:tick()
  flush_queue(self)
  retry_inflight(self)
end

function comms:handle_incoming(raw_message)
  if not raw_message then return nil end
  local message = protocol.sanitize_message(raw_message)
  local ok, err = protocol.validate(message)
  if not ok then
    log(self, "Invalid message ignored: " .. tostring(err), "WARN")
    if err == "proto_ver mismatch" then
      return {
        type = "PROTO_MISMATCH",
        src = message.sender_id or message.src,
        proto_ver = message.proto_ver
      }
    end
    return nil
  end
  update_peer(self, message.src or message.sender_id)
  local sender = message.src or message.sender_id
  if message.message_id and is_duplicate(self, sender, message.message_id) then
    if message.type == constants.message_types.COMMAND then
      self:send_ack(message, "delivered", "duplicate")
    end
    return nil
  end
  add_dedupe(self, sender, message.message_id)
  if message.type == constants.message_types.ACK then
    local ack_for = message.ack_for or (message.payload and message.payload.command_id)
    if ack_for and self.inflight[ack_for] then
      if message.phase == "applied" then
        self.inflight[ack_for] = nil
      elseif not self.inflight[ack_for].requires_applied then
        self.inflight[ack_for] = nil
      end
    end
    return nil
  end
  if message.type == constants.message_types.COMMAND then
    self:send_ack(message, "delivered")
  end
  return message
end

function comms:get_peer_health()
  local out = {}
  local now_ts = now()
  for peer, data in pairs(self.peers) do
    local last = data.last_seen or 0
    local delta = (now_ts - last) / 1000
    out[peer] = {
      last_seen = last,
      down = delta > self.config.peer_timeout,
      age = delta
    }
  end
  return out
end

return comms
