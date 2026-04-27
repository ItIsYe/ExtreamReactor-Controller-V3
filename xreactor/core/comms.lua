local constants = require("shared.constants")
local network_lib = require("core.network")
local protocol = require("core.protocol")
local utils = require("core.utils")

local comms = {}

local DEFAULT_CONFIG = {
  ack_timeout_s = 3.0,
  max_retries = 4,
  backoff_base_s = 0.6,
  backoff_cap_s = 6.0,
  dedupe_ttl_s = 30.0,
  dedupe_limit = 200,
  peer_timeout_s = 12.0,
  peer_down_grace_s = 2.0,
  peer_down_min_observations = 2,
  peer_up_debounce_s = 1.5,
  peer_up_min_observations = 2,
  queue_limit = 200,
  drop_simulation = 0,
  volatile_ttl_s = 15.0,
  peer_retention_s = 180.0
}

local state = {
  initialized = false,
  seq = 0,
  node_id = nil,
  role = nil,
  proto_ver = nil,
  config = nil,
  network = nil,
  log_prefix = "COMMS",
  logger = nil,
  drop_simulation = 0,
  handlers = {},
  any_handlers = {},
  queue = {},
  inflight = {},
  dedupe = {},
  peers = {},
  incoming = {},
  metrics = {
    dropped = 0,
    queue_dropped = 0,
    retries = 0,
    dedupe_hits = 0,
    timeouts = 0,
    last_timeout_ts = nil,
    last_timeout_id = nil
  },
  timeouts = {}
}

local function now_ms()
  return os.epoch("utc")
end

local function reset_runtime_state()
  state.initialized = false
  state.seq = 0
  state.node_id = nil
  state.role = nil
  state.proto_ver = nil
  state.config = nil
  state.network = nil
  state.log_prefix = "COMMS"
  state.logger = nil
  state.drop_simulation = 0
  state.handlers = {}
  state.any_handlers = {}
  state.queue = {}
  state.inflight = {}
  state.dedupe = {}
  state.peers = {}
  state.incoming = {}
  state.metrics = {
    dropped = 0,
    queue_dropped = 0,
    retries = 0,
    dedupe_hits = 0,
    timeouts = 0,
    last_timeout_ts = nil,
    last_timeout_id = nil
  }
  state.timeouts = {}
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

local function clamp_number(value, fallback, min, max)
  local num = tonumber(value)
  if not num then
    return fallback
  end
  if min and num < min then
    return min
  end
  if max and num > max then
    return max
  end
  return num
end

local function sanitize_config(config)
  local merged = merge_config(config)
  merged.ack_timeout_s = clamp_number(merged.ack_timeout_s, DEFAULT_CONFIG.ack_timeout_s, 0.2, 30.0)
  merged.max_retries = math.floor(clamp_number(merged.max_retries, DEFAULT_CONFIG.max_retries, 0, 12))
  merged.backoff_base_s = clamp_number(merged.backoff_base_s, DEFAULT_CONFIG.backoff_base_s, 0.1, 10.0)
  merged.backoff_cap_s = clamp_number(merged.backoff_cap_s, DEFAULT_CONFIG.backoff_cap_s, merged.backoff_base_s, 60.0)
  merged.dedupe_ttl_s = clamp_number(merged.dedupe_ttl_s, DEFAULT_CONFIG.dedupe_ttl_s, 1.0, 300.0)
  merged.dedupe_limit = math.floor(clamp_number(merged.dedupe_limit, DEFAULT_CONFIG.dedupe_limit, 10, 1000))
  merged.peer_timeout_s = clamp_number(merged.peer_timeout_s, DEFAULT_CONFIG.peer_timeout_s, 2.0, 120.0)
  merged.peer_down_grace_s = clamp_number(merged.peer_down_grace_s, DEFAULT_CONFIG.peer_down_grace_s, 0.0, 60.0)
  merged.peer_down_min_observations = math.floor(clamp_number(
    merged.peer_down_min_observations,
    DEFAULT_CONFIG.peer_down_min_observations,
    1,
    10
  ))
  merged.peer_up_debounce_s = clamp_number(merged.peer_up_debounce_s, DEFAULT_CONFIG.peer_up_debounce_s, 0.0, 30.0)
  merged.peer_up_min_observations = math.floor(clamp_number(
    merged.peer_up_min_observations,
    DEFAULT_CONFIG.peer_up_min_observations,
    1,
    10
  ))
  merged.queue_limit = math.floor(clamp_number(merged.queue_limit, DEFAULT_CONFIG.queue_limit, 10, 1000))
  merged.drop_simulation = clamp_number(merged.drop_simulation, DEFAULT_CONFIG.drop_simulation, 0, 0.9)
  merged.volatile_ttl_s = clamp_number(merged.volatile_ttl_s, DEFAULT_CONFIG.volatile_ttl_s, 1.0, 300.0)
  merged.peer_retention_s = clamp_number(merged.peer_retention_s, DEFAULT_CONFIG.peer_retention_s, 10.0, 3600.0)
  return merged
end

local function log(message, level)
  if state.logger then
    state.logger(state.log_prefix, message, level)
  else
    utils.log(state.log_prefix, message, level)
  end
end

local function build_id()
  state.seq = state.seq + 1
  return string.format("%s-%d-%d", tostring(state.node_id), now_ms(), state.seq)
end

local function schedule_backoff(retries)
  local delay = state.config.backoff_base_s * math.pow(2, retries - 1)
  return math.min(delay, state.config.backoff_cap_s)
end

local function add_dedupe(sender, msg_id, applied_result)
  if not sender or not msg_id then return end
  state.dedupe[sender] = state.dedupe[sender] or {}
  table.insert(state.dedupe[sender], { id = msg_id, ts = now_ms(), applied = applied_result })
  if #state.dedupe[sender] > state.config.dedupe_limit then
    table.remove(state.dedupe[sender], 1)
  end
end

local function prune_dedupe()
  local ttl_ms = state.config.dedupe_ttl_s * 1000
  local cutoff = now_ms() - ttl_ms
  for sender, entries in pairs(state.dedupe) do
    local trimmed = {}
    for _, entry in ipairs(entries) do
      if entry.ts >= cutoff then
        table.insert(trimmed, entry)
      end
    end
    state.dedupe[sender] = trimmed
  end
end

local function find_dedupe(sender, msg_id)
  local entries = state.dedupe[sender]
  if not entries then return nil end
  for _, entry in ipairs(entries) do
    if entry.id == msg_id then
      return entry
    end
  end
  return nil
end

local function update_peer(message)
  local sender = message.src or message.sender_id
  if not sender or sender == state.node_id then return end
  state.peers[sender] = state.peers[sender] or {}
  local peer = state.peers[sender]
  peer.last_seen = now_ms()
  peer.last_message_type = message.type
  peer.role = message.role
  peer.proto_ver = message.proto_ver
  peer.stale_since = nil
  peer.stale_observations = 0
  if peer.down then
    if not peer.recovering_since then
      peer.recovering_since = peer.last_seen
      peer.recovering_observations = 1
    else
      peer.recovering_observations = (peer.recovering_observations or 0) + 1
    end
  else
    peer.recovering_observations = 0
  end
end

local function should_drop()
  local drop_rate = tonumber(state.drop_simulation or 0) or 0
  if drop_rate <= 0 then return false end
  return math.random() < drop_rate
end

local function build_message(dst, msg_type, payload)
  return {
    type = msg_type,
    message_id = build_id(),
    src = state.node_id,
    sender_id = state.node_id,
    node_id = state.node_id,
    dst = dst,
    role = state.role,
    ts = now_ms(),
    timestamp = now_ms(),
    proto_ver = state.proto_ver,
    payload = payload or {}
  }
end

local function resolve_channel(msg_type, explicit_channel)
  if explicit_channel then
    return explicit_channel
  end
  local channels = state.network and state.network.channels or {}
  if msg_type == constants.message_types.STATUS or msg_type == constants.message_types.HEARTBEAT or msg_type == constants.message_types.ALERT then
    return channels.status or constants.channels.STATUS
  end
  return channels.control or constants.channels.CONTROL
end

local function send_raw(channel, message)
  local sanitized = protocol.sanitize_message(message)
  if not sanitized then
    log("Invalid outbound message dropped", "WARN")
    state.metrics.dropped = state.metrics.dropped + 1
    return false, "invalid payload"
  end
  if should_drop() then
    log("Drop simulation: outbound message dropped", "WARN")
    state.metrics.dropped = state.metrics.dropped + 1
    return false, "simulated drop"
  end
  return state.network:send(channel, sanitized)
end

local function is_volatile_message(msg_type)
  return msg_type == constants.message_types.STATUS or msg_type == constants.message_types.HEARTBEAT
end

local function build_volatile_key(message, channel)
  if not message or not is_volatile_message(message.type) then
    return nil
  end
  return table.concat({
    tostring(channel),
    tostring(message.dst or "*"),
    tostring(message.type)
  }, "|")
end

local function queue_entry(message, channel, opts)
  opts = opts or {}
  local volatile_key = build_volatile_key(message, channel)
  if volatile_key then
    for _, existing in ipairs(state.queue) do
      if existing.volatile_key == volatile_key and not existing.sent_ts then
        existing.message = message
        existing.channel = channel
        existing.priority = opts.priority or existing.priority or 2
        existing.queued_ts = now_ms()
        existing.last_error = nil
        return existing
      end
    end
  end
  if #state.queue >= state.config.queue_limit then
    log("Send queue full; dropping message " .. tostring(message.type), "WARN")
    state.metrics.dropped = state.metrics.dropped + 1
    state.metrics.queue_dropped = state.metrics.queue_dropped + 1
    return nil, "queue_full"
  end
  local entry = {
    message = message,
    channel = channel,
    priority = opts.priority or 2,
    require_ack = opts.require_ack or false,
    require_applied = opts.require_applied or false,
    sent_ts = nil,
    queued_ts = now_ms(),
    retries = 0,
    next_retry = 0,
    delivered = false,
    volatile_key = volatile_key
  }
  table.insert(state.queue, entry)
  table.sort(state.queue, function(a, b) return a.priority < b.priority end)
  return entry
end

local function flush_queue()
  local remaining = {}
  local now_ts = now_ms()
  local ttl_ms = (state.config.volatile_ttl_s or DEFAULT_CONFIG.volatile_ttl_s) * 1000
  for _, entry in ipairs(state.queue) do
    if entry.volatile_key and entry.queued_ts and ttl_ms > 0 and (now_ts - entry.queued_ts) > ttl_ms then
      state.metrics.dropped = state.metrics.dropped + 1
      state.metrics.queue_dropped = state.metrics.queue_dropped + 1
      log("Dropping stale volatile message " .. tostring(entry.message and entry.message.type), "WARN")
    elseif entry.sent_ts then
      table.insert(remaining, entry)
    else
      local sent_ts = now_ts
      local ok, err = send_raw(entry.channel, entry.message)
      if ok then
        entry.sent_ts = sent_ts
        if entry.require_ack or entry.require_applied then
          state.inflight[entry.message.message_id] = entry
        end
      else
        entry.last_error = err
        table.insert(remaining, entry)
      end
    end
  end
  state.queue = remaining
end

local function retry_inflight()
  local now_ts = now_ms()
  local timeout_ms = state.config.ack_timeout_s * 1000
  for msg_id, entry in pairs(state.inflight) do
    if entry.next_retry ~= 0 and now_ts < entry.next_retry then
      goto continue
    end
    local last_sent = entry.sent_ts or 0
    if now_ts - last_sent < timeout_ms then
      goto continue
    end
    entry.retries = entry.retries + 1
    if entry.retries > state.config.max_retries then
      log("Message retry exhausted " .. tostring(msg_id), "WARN")
      state.metrics.timeouts = state.metrics.timeouts + 1
      state.metrics.last_timeout_ts = now_ts
      state.metrics.last_timeout_id = msg_id
      table.insert(state.timeouts, {
        message_id = msg_id,
        message = entry.message,
        require_ack = entry.require_ack,
        require_applied = entry.require_applied,
        retries = entry.retries,
        last_sent = entry.sent_ts
      })
      state.inflight[msg_id] = nil
      goto continue
    end
    local ok, err = send_raw(entry.channel, entry.message)
    if not ok then
      entry.retries = entry.retries - 1
      entry.next_retry = now_ts + 1000
      entry.last_error = err
      goto continue
    end
    entry.sent_ts = now_ts
    entry.next_retry = now_ts + (schedule_backoff(entry.retries) * 1000)
    state.metrics.retries = state.metrics.retries + 1
    if entry.message and entry.message.type == constants.message_types.COMMAND then
      log(("Retry command %s -> %s (%d/%d)"):format(
        tostring(msg_id),
        tostring(entry.message.dst or "broadcast"),
        entry.retries,
        state.config.max_retries
      ))
    end
    ::continue::
  end
end

local function send_ack(message, msg_type, payload)
  if not message or not message.message_id then return end
  local ack = build_message(message.src, msg_type, payload or {})
  ack.ack_for = message.message_id
  ack.phase = msg_type == constants.message_types.ACK_APPLIED and "applied" or "delivered"
  ack.dst = message.src
  ack.src = state.node_id
  local channels = state.network and state.network.channels or {}
  local control_channel = channels.control or constants.channels.CONTROL
  queue_entry(ack, control_channel, { priority = 1 })
end

local function dispatch_handlers(message)
  local handlers = state.handlers[message.type] or {}
  local applied_result
  for _, handler in ipairs(handlers) do
    local ok, result = pcall(handler, message)
    if not ok then
      log("Handler error: " .. tostring(result), "WARN")
      applied_result = applied_result or { ok = false, error = tostring(result) }
    elseif result ~= nil then
      applied_result = result
    end
  end
  for _, handler in ipairs(state.any_handlers) do
    local ok, result = pcall(handler, message)
    if not ok then
      log("Handler error: " .. tostring(result), "WARN")
      applied_result = applied_result or { ok = false, error = tostring(result) }
    elseif result ~= nil then
      applied_result = result
    end
  end
  return applied_result
end

local function handle_ack(message)
  local ack_for = message.ack_for
  if not ack_for then return end
  local entry = state.inflight[ack_for]
  if not entry then return end
  if message.type == constants.message_types.ACK_DELIVERED then
    entry.delivered = true
    entry.sent_ts = now_ms()
    if not entry.require_applied then
      state.inflight[ack_for] = nil
    end
    if entry.message and entry.message.type == constants.message_types.COMMAND then
      log(("Command delivered ack %s from %s"):format(tostring(ack_for), tostring(message.src or message.sender_id or "unknown")))
    end
  elseif message.type == constants.message_types.ACK_APPLIED then
    state.inflight[ack_for] = nil
    if entry.message and entry.message.type == constants.message_types.COMMAND then
      local result = message.payload and message.payload.result or {}
      local status = result.ok == false and "failed" or "ok"
      log(("Command applied ack %s from %s (%s)"):format(
        tostring(ack_for),
        tostring(message.src or message.sender_id or "unknown"),
        status
      ))
    end
  end
end

local function handle_message(message)
  update_peer(message)
  if message.dst and message.dst ~= state.node_id then
    return
  end
  if message.type == constants.message_types.COMMAND and not protocol.is_for_node(message, state.node_id) then
    return
  end

  if message.message_id then
    local dup = find_dedupe(message.src, message.message_id)
    if dup then
      state.metrics.dedupe_hits = state.metrics.dedupe_hits + 1
      if message.type == constants.message_types.COMMAND then
        send_ack(message, constants.message_types.ACK_DELIVERED, { detail = "duplicate" })
        if dup.applied then
          send_ack(message, constants.message_types.ACK_APPLIED, { result = dup.applied })
        end
      end
      return
    end
  end

  if message.type == constants.message_types.ACK_DELIVERED or message.type == constants.message_types.ACK_APPLIED then
    handle_ack(message)
    dispatch_handlers(message)
    return
  end

  if message.type == constants.message_types.COMMAND then
    send_ack(message, constants.message_types.ACK_DELIVERED)
  end

  local result = dispatch_handlers(message)

  if message.type == constants.message_types.COMMAND then
    local applied = result or { ok = true }
    local cmd = message.payload and message.payload.command or nil
    if type(applied) == "table" and type(cmd) == "table" then
      if applied.command_target == nil then
        applied.command_target = cmd.target
      end
      if applied.command_value == nil then
        applied.command_value = cmd.value
      end
    end
    send_ack(message, constants.message_types.ACK_APPLIED, { result = applied })
    add_dedupe(message.src, message.message_id, applied)
  else
    add_dedupe(message.src, message.message_id, nil)
  end
end

local function update_peer_timeouts()
  local now_ts = now_ms()
  local retention_ms = math.max(10000, (state.config.peer_retention_s or DEFAULT_CONFIG.peer_retention_s) * 1000)
  local stale_peers = {}
  for id, peer in pairs(state.peers) do
    local last = peer.last_seen or 0
    local age_s = (now_ts - last) / 1000
    local stale = age_s > state.config.peer_timeout_s
    if stale then
      peer.recovering_since = nil
      peer.recovering_observations = 0
      if not peer.stale_since then
        peer.stale_since = now_ts
        peer.stale_observations = 0
      end
      peer.stale_observations = (peer.stale_observations or 0) + 1
      local stale_for_s = (now_ts - (peer.stale_since or now_ts)) / 1000
      if not peer.down
        and stale_for_s >= (state.config.peer_down_grace_s or 0)
        and (peer.stale_observations or 0) >= (state.config.peer_down_min_observations or 1) then
        peer.down = true
        peer.down_since = now_ts
        log(("Peer down: %s (age=%.1fs timeout=%.1fs grace=%.1fs stale_obs=%d/%d)"):format(
          tostring(id),
          age_s,
          state.config.peer_timeout_s or 0,
          state.config.peer_down_grace_s or 0,
          peer.stale_observations or 0,
          state.config.peer_down_min_observations or 1
        ), "WARN")
      end
    elseif peer.down then
      peer.stale_since = nil
      peer.stale_observations = 0
      if not peer.recovering_since then
        peer.recovering_since = now_ts
      end
      local recovery_observations = peer.recovering_observations or 0
      local recovering_for_s = (now_ts - (peer.recovering_since or now_ts)) / 1000
      -- Require both time-based debounce and multiple fresh sightings so one lucky
      -- heartbeat does not immediately flip a peer from DOWN back to UP.
      if recovering_for_s >= (state.config.peer_up_debounce_s or 0)
        and recovery_observations >= (state.config.peer_up_min_observations or 1) then
        peer.down = false
        peer.down_since = nil
        peer.recovering_since = nil
        peer.recovering_observations = 0
        log(("Peer up: %s (age=%.1fs recover_for=%.1fs observations=%d/%d debounce=%.1fs)"):format(
          tostring(id),
          age_s,
          recovering_for_s,
          recovery_observations,
          state.config.peer_up_min_observations or 1,
          state.config.peer_up_debounce_s or 0
        ))
      end
    else
      peer.stale_since = nil
      peer.stale_observations = 0
      peer.recovering_since = nil
      peer.recovering_observations = 0
    end
    if peer.down and age_s * 1000 >= retention_ms then
      stale_peers[#stale_peers + 1] = id
    end
  end
  for _, peer_id in ipairs(stale_peers) do
    state.peers[peer_id] = nil
    log(("Peer expired: %s (retention=%.1fs)"):format(tostring(peer_id), retention_ms / 1000), "INFO")
  end
end

function comms.init(opts)
  opts = opts or {}
  reset_runtime_state()
  state.config = sanitize_config(opts.config or {})
  state.network = opts.network or network_lib.init(opts)
  state.node_id = opts.node_id or state.network.id
  state.role = opts.role or state.network.role
  state.proto_ver = opts.proto_ver or constants.proto_ver
  state.log_prefix = opts.log_prefix or "COMMS"
  state.logger = opts.logger
  state.drop_simulation = opts.drop_simulation or state.config.drop_simulation
  state.initialized = true
  return comms
end

function comms.on(msg_type, handler_fn)
  if not handler_fn then return end
  if msg_type == "*" then
    table.insert(state.any_handlers, handler_fn)
    return
  end
  state.handlers[msg_type] = state.handlers[msg_type] or {}
  table.insert(state.handlers[msg_type], handler_fn)
end

function comms.send(dst, msg_type, payload, opts)
  if not state.initialized then
    error("comms not initialized")
  end
  local message = build_message(dst, msg_type, payload)
  if opts and opts.message_id then
    message.message_id = opts.message_id
  end
  local channel = resolve_channel(msg_type, opts and opts.channel or nil)
  local require_ack = msg_type == constants.message_types.COMMAND and (opts and opts.require_ack or false)
  local require_applied = msg_type == constants.message_types.COMMAND and (opts and opts.require_applied or false)
  local entry = queue_entry(message, channel, {
    priority = opts and opts.priority or nil,
    require_ack = require_ack,
    require_applied = require_applied
  })
  if entry and msg_type == constants.message_types.COMMAND then
    log(("Command queued %s -> %s (applied=%s)"):format(
      tostring(message.message_id),
      tostring(dst or "broadcast"),
      tostring(opts and opts.require_applied or false)
    ))
  end
  return entry
end

function comms.receive(raw_message)
  if not raw_message then return end
  table.insert(state.incoming, raw_message)
end

function comms.tick(now)
  if not state.initialized then return end
  prune_dedupe()
  flush_queue()
  retry_inflight()

  local queue = state.incoming
  state.incoming = {}
  for _, raw in ipairs(queue) do
    local message = protocol.sanitize_message(raw)
    local ok, err = protocol.validate(message)
    if not ok then
      log("Invalid message ignored: " .. tostring(err), "WARN")
      if err == "proto_ver mismatch" then
        local error_msg = {
          type = constants.message_types.ERROR,
          src = message and (message.src or message.sender_id) or nil,
          role = message and message.role or "UNKNOWN",
          payload = { code = "PROTO_MISMATCH", proto_ver = message and message.proto_ver or nil },
          ts = now_ms(),
          timestamp = now_ms(),
          proto_ver = message and message.proto_ver or constants.proto_ver
        }
        dispatch_handlers(error_msg)
        if message and message.type == constants.message_types.COMMAND
          and protocol.is_for_node(message, state.node_id)
          and message.message_id then
          local applied = { ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" }
          send_ack(message, constants.message_types.ACK_DELIVERED, { error = "proto mismatch", reason_code = "PROTO_MISMATCH" })
          send_ack(message, constants.message_types.ACK_APPLIED, { result = applied })
          add_dedupe(message.src, message.message_id, applied)
        end
      end
    else
      handle_message(message)
    end
  end

  -- Evaluate peer timeout transitions after ingesting fresh messages queued
  -- during this loop iteration so jitter does not cause transient DOWN/UP flaps.
  update_peer_timeouts()
end

function comms.get_peer_state()
  local out = {}
  local now_ts = now_ms()
  for peer, data in pairs(state.peers) do
    local last = data.last_seen or 0
    local delta = (now_ts - last) / 1000
    local down = data.down
    if down == nil then
      down = delta > state.config.peer_timeout_s
    end
    out[peer] = {
      last_seen = last,
      down = down,
      down_since = data.down_since,
      age = delta,
      stale = delta > state.config.peer_timeout_s,
      role = data.role,
      proto_ver = data.proto_ver,
      stale_since = data.stale_since,
      stale_observations = data.stale_observations or 0,
      recovering_since = data.recovering_since,
      recovering_observations = data.recovering_observations or 0,
      last_message_type = data.last_message_type,
      timeout_s = state.config.peer_timeout_s,
      down_grace_s = state.config.peer_down_grace_s,
      down_min_observations = state.config.peer_down_min_observations,
      up_debounce_s = state.config.peer_up_debounce_s,
      up_min_observations = state.config.peer_up_min_observations
    }
  end
  return out
end

function comms.get_diagnostics()
  local inflight_count = 0
  for _ in pairs(state.inflight) do
    inflight_count = inflight_count + 1
  end
  return {
    queue_depth = #state.queue,
    inflight_count = inflight_count,
    incoming = #state.incoming,
    metrics = utils.deep_copy(state.metrics),
    peers = comms.get_peer_state(),
    config = utils.deep_copy(state.config)
  }
end

function comms.consume_timeouts()
  local list = state.timeouts
  state.timeouts = {}
  return list
end

function comms.sanitize_config(config)
  return sanitize_config(config)
end

return comms
