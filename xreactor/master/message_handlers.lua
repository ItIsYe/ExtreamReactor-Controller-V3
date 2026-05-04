local M = {}
local rt_sync = require("master.rt_sync")

function M.new(opts)
  local constants = assert(opts.constants, "constants required")
  local utils = assert(opts.utils, "utils required")
  local health = assert(opts.health, "health required")
  local nodes = assert(opts.nodes, "nodes required")
  local comms = assert(opts.comms, "comms getter required")
  local sequencer = assert(opts.sequencer, "sequencer required")
  local mark_rt_sync_dirty = assert(opts.mark_rt_sync_dirty, "mark_rt_sync_dirty required")
  local add_alarm = assert(opts.add_alarm, "add_alarm required")
  local master_time_label = assert(opts.master_time_label, "master_time_label required")
  local log = assert(opts.log, "log required")


  local function format_reasons(reason_set)
    if type(reason_set) ~= "table" then return "none" end
    local out = {}
    for reason, enabled in pairs(reason_set) do
      if enabled then out[#out + 1] = tostring(reason) end
    end
    table.sort(out)
    return #out > 0 and table.concat(out, ",") or "none"
  end

  local function reasons_to_set(reasons)
    if type(reasons) ~= "table" then return {} end
    local out = {}
    local is_array = (#reasons > 0)
    if is_array then
      for _, reason in ipairs(reasons) do out[tostring(reason)] = true end
      return out
    end
    for reason, enabled in pairs(reasons) do
      if enabled then out[tostring(reason)] = true end
    end
    return out
  end

  local function assign_node_status_from_health(node, origin)
    local previous_status = node.status
    local health_payload = node.health
    local computed = previous_status
    if health_payload and health_payload.status then
      computed = health_payload.status
    end
    local reasons = reasons_to_set(health_payload and health_payload.reasons)
    local shutdown_state = node.last_setpoints and node.last_setpoints.assignment_state
    local workflow_stage = node.shutdown_workflow and node.shutdown_workflow.stage or nil
    local controlled_shutdown = shutdown_state == "shutdown" or shutdown_state == "shed" or shutdown_state == "standby" or
        workflow_stage == "RAMPDOWN" or workflow_stage == "REQUEST_STATE" or workflow_stage == "REQUESTED" or workflow_stage == "WAITING_STATE"
    if controlled_shutdown and computed == health.status.DEGRADED then
      if reasons[health.reasons.COMMS_DOWN] ~= true and reasons[health.reasons.PROTO_MISMATCH] ~= true and reasons[health.reasons.DISCOVERY_FAILED] ~= true then
        computed = constants.status_levels.OK
        log(("Node %s suppresses degraded during controlled shutdown: state=%s assign=%s reasons=%s source=%s"):format(
          tostring(node.id), tostring(node.state), tostring(shutdown_state), format_reasons(reasons), tostring(origin or "unknown")
        ))
      end
    end
    node.status = computed or constants.status_levels.OK
    if previous_status ~= node.status then
      log(("Node %s status %s -> %s (%s)"):format(tostring(node.id), tostring(previous_status or "UNKNOWN"), tostring(node.status), tostring(origin or "unknown")))
    end
  end

  local function ack_matches_last_setpoints(node, result)
    if type(result) ~= "table" or result.ok == false then return false end
    local target = result.command_target
    local expected_target = constants.command_targets.SET_SETPOINTS or constants.command_targets.POWER_TARGET
    if target ~= expected_target then return false end
    local value = result.command_value
    local last = node and node.last_setpoints
    if type(value) ~= "table" or type(last) ~= "table" then return false end
    return rt_sync.same_setpoints(rt_sync.normalize_setpoints(value), rt_sync.normalize_setpoints(last))
  end

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
    nodes[id].recovering = false

    if message.type == constants.message_types.HELLO or message.type == constants.message_types.REGISTER then
      if nodes[id].status == constants.status_levels.OFFLINE then log("Node online: " .. tostring(id)) end
      assign_node_status_from_health(nodes[id], "hello")
      nodes[id].state = constants.node_states.OFF
      if message.role == constants.roles.RT_NODE then sequencer:enqueue(id) end
      mark_rt_sync_dirty(nodes[id], "hello")
    elseif message.type == constants.message_types.HEARTBEAT then
      nodes[id].state = message.payload.state
      nodes[id].down_since = nil
      nodes[id].offline = false
      nodes[id].stale = false
      nodes[id].managed = true
      nodes[id].recovering = false
      if nodes[id].health and nodes[id].health.reasons and nodes[id].health.reasons[health.reasons.COMMS_DOWN] then
        nodes[id].health.reasons[health.reasons.COMMS_DOWN] = nil
        log(("Node %s reason removed: %s (heartbeat)"):format(id, health.reasons.COMMS_DOWN))
      end
      assign_node_status_from_health(nodes[id], "heartbeat")
      mark_rt_sync_dirty(nodes[id], "heartbeat")
    elseif message.type == constants.message_types.STATUS then
      local previous_mode = nodes[id].mode
      nodes[id] = utils.merge(nodes[id], message.payload)
      local previous_health_status = nodes[id].health and nodes[id].health.status or nil
      local previous_reasons = nodes[id].health and nodes[id].health.reasons or nil
      if message.payload.health then
        nodes[id].health = message.payload.health
        if previous_health_status ~= message.payload.health.status then
          log(("Node %s health %s -> %s (status payload)"):format(id, tostring(previous_health_status or "UNKNOWN"), tostring(message.payload.health.status or "UNKNOWN")))
        end
        local old_reasons = format_reasons(previous_reasons)
        local new_reasons = format_reasons(message.payload.health.reasons)
        if old_reasons ~= new_reasons then
          log(("Node %s reasons %s -> %s"):format(id, old_reasons, new_reasons))
        end
        assign_node_status_from_health(nodes[id], "status")
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
      mark_rt_sync_dirty(nodes[id], "status")
    elseif message.type == constants.message_types.ACK_APPLIED then
      local result = message.payload and message.payload.result or {}
      local redundant_setpoint_ack = ack_matches_last_setpoints(nodes[id], result)
      nodes[id].last_command_result = {
        ok = result.ok ~= false,
        error = result.error,
        reason_code = result.reason_code,
        module_id = result.module_id,
        ack_for = message.ack_for,
        at = os.epoch("utc"),
        command_target = result.command_target,
        command_value = result.command_value,
        transition = result.transition,
        desired_node_state = result.desired_node_state,
        shutdown_stage = result.shutdown_stage
      }
      nodes[id].last_command_error = result.ok == false and (result.error or "unknown") or nil
      if result.ok == false then log(("Command failed on %s: %s"):format(id, result.error or "unknown"), "WARN") end
      sequencer:notify_ack(id, result.module_id)
      local workflow_stage = nodes[id].shutdown_workflow and nodes[id].shutdown_workflow.stage or nil
      local workflow_waiting = workflow_stage == "REQUEST_STATE" or workflow_stage == "REQUESTED" or workflow_stage == "WAITING_STATE"
      local ack_transition = tostring(result.transition or "")
      local needs_workflow_followup = workflow_waiting and (
        result.ok == false or ack_transition == "REQUESTED" or ack_transition == "ALREADY_IN_STATE" or ack_transition == "APPLIED"
      )
      if not redundant_setpoint_ack or needs_workflow_followup then
        mark_rt_sync_dirty(nodes[id], "ack_applied")
      else
        log(("Node %s ACK_APPLIED deduped: unchanged setpoint ack does not re-dirty"):format(tostring(id)))
      end
    elseif message.type == constants.message_types.ALERT then
      add_alarm(id, message.payload.severity, message.payload.message)
    end
  end

  return { update_node = update_node }
end

return M
