local M = {}

function M.new(opts)
  local constants = assert(opts.constants, "constants required")
  local utils = assert(opts.utils, "utils required")
  local health = assert(opts.health, "health required")
  local nodes = assert(opts.nodes, "nodes required")
  local comms = assert(opts.comms, "comms getter required")
  local sequencer = assert(opts.sequencer, "sequencer required")
  local sync_rt_node = assert(opts.sync_rt_node, "sync_rt_node required")
  local add_alarm = assert(opts.add_alarm, "add_alarm required")
  local master_time_label = assert(opts.master_time_label, "master_time_label required")
  local log = assert(opts.log, "log required")

  local function update_node(message)
    if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
      local mismatch_id = utils.normalize_node_id(message.src)
      if mismatch_id ~= "UNKNOWN" then
        nodes[mismatch_id] = nodes[mismatch_id] or { id = mismatch_id, role = "UNKNOWN" }
        nodes[mismatch_id].health = nodes[mismatch_id].health or health.new({})
        nodes[mismatch_id].health.status = health.status.DEGRADED
        nodes[mismatch_id].health.reasons = { [health.reasons.PROTO_MISMATCH] = true }
        nodes[mismatch_id].status = health.status.DEGRADED
        nodes[mismatch_id].last_seen = os.epoch("utc")
        nodes[mismatch_id].last_seen_str = master_time_label()
        nodes[mismatch_id].proto_ver = message.payload.proto_ver
      end
      return
    end

    local sender_id = utils.normalize_node_id(message.sender_id)
    local reported_id = message.node_id and utils.normalize_node_id(message.node_id) or "UNKNOWN"
    local id = (reported_id ~= "UNKNOWN") and reported_id or sender_id
    if sender_id ~= "UNKNOWN" and sender_id ~= id and nodes[sender_id] then
      local legacy = nodes[sender_id]
      nodes[sender_id] = nil
      nodes[id] = nodes[id] or legacy
      log(("Node identity remapped: %s -> %s"):format(tostring(sender_id), tostring(id)))
    end
    nodes[id] = nodes[id] or { id = id, role = message.role, status = constants.status_levels.OFFLINE }
    if nodes[id].down_since then
      local peers = comms() and comms():get_peers() or {}
      local peer = peers and peers[id] or nil
      if not (peer and peer.down) then
        nodes[id].down_since = nil
        log("Node comms restored: " .. tostring(id))
      end
    end

    nodes[id].id = id
    if reported_id ~= "UNKNOWN" then nodes[id].node_id = reported_id end
    nodes[id].sender_id = sender_id ~= "UNKNOWN" and sender_id or nodes[id].sender_id
    nodes[id].last_seen = os.epoch("utc")
    nodes[id].last_seen_str = master_time_label()
    nodes[id].proto_ver = message.proto_ver
    nodes[id].managed = true
    nodes[id].stale = false
    nodes[id].offline = false

    if message.type == constants.message_types.HELLO or message.type == constants.message_types.REGISTER then
      if nodes[id].status == constants.status_levels.OFFLINE then log("Node online: " .. tostring(id)) end
      nodes[id].status = constants.status_levels.OK
      nodes[id].state = constants.node_states.OFF
      if message.role == constants.roles.RT_NODE then sequencer:enqueue(id) end
      sync_rt_node(nodes[id])
    elseif message.type == constants.message_types.HEARTBEAT then
      nodes[id].state = message.payload.state
      sync_rt_node(nodes[id])
    elseif message.type == constants.message_types.STATUS then
      local previous_mode = nodes[id].mode
      nodes[id] = utils.merge(nodes[id], message.payload)
      if message.payload.health then
        nodes[id].health = message.payload.health
        nodes[id].status = message.payload.health.status or nodes[id].status
      else
        nodes[id].status = message.payload.status or nodes[id].status
      end
      nodes[id].bindings = message.payload.bindings or nodes[id].bindings
      nodes[id].bindings_summary = message.payload.bindings_summary or nodes[id].bindings_summary
      nodes[id].capabilities = message.payload.capabilities or nodes[id].capabilities
      nodes[id].mode = message.payload.mode or nodes[id].mode
      nodes[id].registry = message.payload.registry or nodes[id].registry
      nodes[id].last_error = message.payload.last_error or nodes[id].last_error
      nodes[id].last_error_ts = message.payload.last_error_ts or nodes[id].last_error_ts
      if previous_mode and nodes[id].mode and previous_mode ~= nodes[id].mode then
        log(("Node %s mode: %s"):format(id, tostring(nodes[id].mode)))
      end
      if sequencer.active and sequencer.active.node_id == id then
        if message.payload.modules then
          local module = message.payload.modules[sequencer.active.module_id]
          if not module then
            utils.log("SEQ", ("WARN: module %s missing from status, waiting"):format(sequencer.active.module_id))
            return
          end
          if module.state == "STABLE" then
            sequencer:notify_stable(id, sequencer.active.module_id, module.state)
          else
            utils.log("SEQ", ("Waiting for module %s, state=%s"):format(sequencer.active.module_id, module.state or "UNKNOWN"))
          end
        elseif nodes[id].state == constants.node_states.RUNNING then
          sequencer:notify_stable(id, sequencer.active.module_id, nodes[id].state)
        end
      end
      sync_rt_node(nodes[id])
    elseif message.type == constants.message_types.ACK_APPLIED then
      local result = message.payload and message.payload.result or {}
      nodes[id].last_command_result = {
        ok = result.ok ~= false,
        error = result.error,
        reason_code = result.reason_code,
        module_id = result.module_id,
        ack_for = message.ack_for,
        at = os.epoch("utc"),
        command_target = result.command_target,
        command_value = result.command_value
      }
      nodes[id].last_command_error = result.ok == false and (result.error or "unknown") or nil
      if result.ok == false then log(("Command failed on %s: %s"):format(id, result.error or "unknown"), "WARN") end
      sequencer:notify_ack(id, result.module_id)
    elseif message.type == constants.message_types.ALERT then
      add_alarm(id, message.payload.severity, message.payload.message)
    end
  end

  return { update_node = update_node }
end

return M
