local M = {}

function M.sync_rt_node(runtime, node, reason)
  if not node or node.role ~= runtime.libs.constants.roles.RT_NODE then return end
  local rt_sync = runtime.libs.rt_sync
  local constants = runtime.libs.constants
  local now = os.epoch("utc")

  rt_sync.set_default_mode({ config = runtime.config, comms = runtime.refs.comms }, node)
  if node.desired_mode and node.mode ~= node.desired_mode then
    if not node.last_mode_request or now - node.last_mode_request > 5000 then
      rt_sync.send_rt_mode(runtime.refs.comms, node, node.desired_mode)
    end
    return
  end

  local plan = rt_sync.build_node_setpoint_plan({
    config = runtime.config,
    nodes = runtime.state.nodes,
    power_target = runtime.state.power_target,
    rt_global_off = runtime.state.rt_global_off_hold
  })

  node.shutdown_workflow = node.shutdown_workflow or {}
  local workflow = node.shutdown_workflow
  local target_shutdown_state = constants.node_states.OFF
  local restart_cooldown_ms = ((runtime.config.rt_setpoints and runtime.config.rt_setpoints.shutdown_restart_cooldown_ms)
      or runtime.libs.rt_sync_coalescer.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS or 15000)

  local function workflow_fail(fail_reason, err_msg, level)
    workflow.stage = "FAILED"
    workflow.failed_at = now
    workflow.completed_at = now
    workflow.final_reason = fail_reason
    workflow.error = err_msg
    workflow.outcome = "FAILED"
    workflow.state_reached_at = nil
    runtime.log(("RT shutdown workflow failed node=%s reason=%s error=%s state=%s request_at=%s ack_at=%s"):format(
      tostring(node.id), tostring(fail_reason), tostring(err_msg), tostring(node.state), tostring(workflow.request_command_at), tostring(workflow.request_ack_at)
    ), level or "WARN")
    runtime.log(("RT shutdown workflow outcome set node=%s outcome=%s final_reason=%s completed_at=%s"):format(
      tostring(node.id), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)
    ), "INFO")
  end

  local candidate_step = runtime.libs.rt_sync_coalescer.advance_shutdown_candidate({
    workflow = workflow,
    now = now,
    is_candidate = plan.shutdown_candidate_id == node.id,
    restart_cooldown_ms = restart_cooldown_ms,
    stability_ms = runtime.tuning.rt_shutdown_candidate_stability_ms
  })

  if candidate_step.action == "candidate_reset" then
    runtime.log(("RT shutdown workflow candidate reset node=%s reason=POST_CANCEL_COOLDOWN_REEVALUATE"):format(tostring(node.id)), "INFO")
  elseif candidate_step.action == "debounce_cooldown" then
    runtime.log(("RT shutdown workflow debounce node=%s remaining_ms=%d reason=CANCEL_RECOVERY_COOLDOWN"):format(tostring(node.id), tonumber(candidate_step.remaining_ms) or 0), "INFO")
  elseif candidate_step.action == "debounce_stability" then
    runtime.log(("RT shutdown workflow debounce node=%s remaining_ms=%d reason=CANDIDATE_STABILITY"):format(tostring(node.id), tonumber(candidate_step.remaining_ms) or 0), "INFO")
  elseif candidate_step.action == "start_requested" then
    workflow.requested_at = now
    workflow.stage = "RAMPDOWN"
    workflow.final_reason = nil
    workflow.error = nil
    workflow.outcome = nil
    workflow.target_state = target_shutdown_state
    workflow.ready_at = now + ((runtime.config.rt_setpoints and runtime.config.rt_setpoints.shutdown_ramp_ms) or 6000)
    workflow.request_command_at = nil
    workflow.request_ack_at = nil
    workflow.command_ack_at = nil
    workflow.completed_at = nil
    workflow.state_reached_at = nil
    runtime.log(("RT shutdown workflow start node=%s reason=SHED_EXCESS_CAPACITY ready_in_ms=%d"):format(tostring(node.id), tonumber(((runtime.config.rt_setpoints and runtime.config.rt_setpoints.shutdown_ramp_ms) or 6000))), "INFO")
  elseif candidate_step.action == "cancelled" then
    runtime.log(("RT shutdown workflow cancelled node=%s reason=%s"):format(tostring(node.id), tostring(workflow.final_reason)), "INFO")
    runtime.log(("RT shutdown workflow outcome set node=%s outcome=%s final_reason=%s completed_at=%s"):format(
      tostring(node.id), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)
    ), "INFO")
  end

  if runtime.refs.sequencer and plan.startup_candidate_id and node.id == plan.startup_candidate_id then
    runtime.refs.sequencer:enqueue(node.id, "DEMAND_STARTUP")
    runtime.log(("RT startup candidate node=%s target=%.2f required_nodes=%d"):format(tostring(node.id), tonumber(runtime.state.power_target) or 0, tonumber(plan.required_nodes) or 0), "INFO")
  end

  if plan.shutdown_candidate_id and node.id == plan.shutdown_candidate_id then
    local remaining_ms = workflow.ready_at and math.max(0, workflow.ready_at - now) or 0
    runtime.log(("RT shutdown candidate node=%s target=%.2f stage=%s remaining_ms=%d"):format(tostring(node.id), tonumber(runtime.state.power_target) or 0, tostring(workflow.stage or "RAMPDOWN"), tonumber(remaining_ms) or 0), "INFO")
  end

  if workflow.requested_at and workflow.stage == "RAMPDOWN" and workflow.ready_at and now >= workflow.ready_at then
    workflow.stage = "REQUEST_STATE"
    workflow.request_command_at = nil
    workflow.command_ack_at = nil
    workflow.request_ack_at = nil
    workflow.failed_at = nil
    runtime.log(("RT shutdown workflow rampdown complete node=%s action=REQUEST_STATE target_state=%s"):format(tostring(node.id), tostring(workflow.target_state or target_shutdown_state)), "INFO")
  end

  local cmd_result = node.last_command_result
  if workflow.requested_at and workflow.stage ~= "COMPLETED" and workflow.stage ~= "FAILED" and workflow.stage ~= "CANCELLED_DEMAND_RECOVERED" then
    if node.state == (workflow.target_state or target_shutdown_state) then
      workflow.stage = "COMPLETED"
      workflow.completed_at = now
      workflow.state_reached_at = now
      workflow.final_reason = "SUCCESS_COMPLETED"
      workflow.error = nil
      workflow.outcome = "SUCCESS"
      runtime.log(("RT shutdown workflow state reached node=%s state=%s"):format(tostring(node.id), tostring(node.state)), "INFO")
      runtime.log(("RT shutdown workflow state_reached_at set node=%s state_reached_at=%s"):format(tostring(node.id), tostring(workflow.state_reached_at)), "INFO")
      runtime.log(("RT shutdown workflow finalised node=%s final_reason=%s requested_at=%s accepted_at=%s completed_at=%s"):format(tostring(node.id), tostring(workflow.final_reason), tostring(workflow.request_command_at), tostring(workflow.request_ack_at), tostring(workflow.completed_at)), "INFO")
      runtime.log(("RT shutdown workflow outcome set node=%s outcome=%s final_reason=%s completed_at=%s"):format(tostring(node.id), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)), "INFO")
    elseif workflow.target_state and node.state == constants.node_states.EMERGENCY then
      workflow_fail("FAILED_INVALID_STATE", "NODE_IN_EMERGENCY")
    end
  end

  if workflow.stage == "REQUEST_STATE" or workflow.stage == "REQUESTED" then
    if not workflow.request_command_at or now - workflow.request_command_at > 5000 then
      local setpoints = rt_sync.normalize_setpoints(node.last_setpoints or {})
      setpoints.shutdown_stage = "REQUEST_OFF"
      setpoints.desired_node_state = workflow.target_state or target_shutdown_state
      rt_sync.send_rt_setpoints(runtime.refs.comms, node, setpoints)
      workflow.request_command_at = now
      workflow.stage = "REQUESTED"
      runtime.log(("RT shutdown workflow request sent node=%s stage=%s target_state=%s request_at=%s"):format(tostring(node.id), tostring(setpoints.shutdown_stage), tostring(setpoints.desired_node_state), tostring(workflow.request_command_at)), "INFO")
    end
    if cmd_result and cmd_result.at and cmd_result.at >= (workflow.request_command_at or 0) then
      local cmd_value = cmd_result.command_value or {}
      local ack_shutdown_stage = cmd_result.shutdown_stage or cmd_value.shutdown_stage
      local ack_desired_node_state = cmd_result.desired_node_state or cmd_value.desired_node_state
      local is_shutdown_ack = cmd_result.command_target == (constants.command_targets.SET_SETPOINTS or "SET_SETPOINTS") and ack_shutdown_stage == "REQUEST_OFF" and ack_desired_node_state == (workflow.target_state or target_shutdown_state)
      if is_shutdown_ack and cmd_result.ok == false then
        local failure_reason = (cmd_result.reason_code == "INVALID_STATE") and "FAILED_INVALID_STATE" or "FAILED_REJECTED"
        workflow_fail(failure_reason, cmd_result.error or cmd_result.reason_code or "unknown")
      elseif is_shutdown_ack and cmd_result.ok ~= false then
        workflow.command_ack_at = now
        workflow.request_ack_at = now
        workflow.request_accept_at = now
        local transition = tostring(cmd_result.transition or "UNKNOWN")
        if transition == "REQUESTED" or transition == "ALREADY_IN_STATE" then
          workflow.stage = "WAITING_STATE"
          runtime.log(("RT shutdown workflow request accepted node=%s requested_state=%s transition=%s accepted_at=%s"):format(tostring(node.id), tostring(workflow.target_state or target_shutdown_state), transition, tostring(workflow.request_accept_at)), "INFO")
        else
          workflow_fail("FAILED_REJECTED", "UNEXPECTED_ACK_TRANSITION=" .. transition)
        end
      end
    end
    if not workflow.request_ack_at and workflow.request_command_at and now - workflow.request_command_at > 15000 then
      workflow_fail("FAILED_ACK_MISSING", "ACK_MISSING")
    end
  elseif workflow.stage == "WAITING_STATE" then
    if workflow.command_ack_at and now - workflow.command_ack_at > 15000 then
      workflow_fail("FAILED_TIMEOUT", ("STATE_TRANSITION_TIMEOUT current=%s target=%s"):format(tostring(node.state), tostring(workflow.target_state or target_shutdown_state)))
    end
  end

  if workflow.stage == "COMPLETED" or workflow.stage == "FAILED" or workflow.stage == "CANCELLED_DEMAND_RECOVERED" then
    if not workflow.outcome or not workflow.final_reason or not workflow.completed_at then
      runtime.log(("RT shutdown workflow terminal field gap node=%s stage=%s outcome=%s final_reason=%s completed_at=%s"):format(tostring(node.id), tostring(workflow.stage), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)), "WARN")
    end
    if workflow.completed_at and (now - workflow.completed_at) > 20000 then
      if workflow.stage == "COMPLETED" and workflow.final_reason ~= "SUCCESS_COMPLETED" then
        runtime.log(("RT shutdown workflow cleanup guard node=%s corrected_final_reason=%s previous=%s"):format(tostring(node.id), "SUCCESS_COMPLETED", tostring(workflow.final_reason)), "WARN")
        workflow.final_reason = "SUCCESS_COMPLETED"
      elseif workflow.stage == "CANCELLED_DEMAND_RECOVERED" and workflow.final_reason ~= "CANCELLED_DEMAND_RECOVERED" then
        runtime.log(("RT shutdown workflow cleanup guard node=%s corrected_final_reason=%s previous=%s"):format(tostring(node.id), "CANCELLED_DEMAND_RECOVERED", tostring(workflow.final_reason)), "WARN")
        workflow.final_reason = "CANCELLED_DEMAND_RECOVERED"
      elseif workflow.stage == "FAILED" and (workflow.final_reason == nil or tostring(workflow.final_reason):sub(1, 7) ~= "FAILED_") then
        runtime.log(("RT shutdown workflow cleanup guard node=%s corrected_final_reason=%s previous=%s"):format(tostring(node.id), "FAILED_UNKNOWN", tostring(workflow.final_reason)), "WARN")
        workflow.final_reason = "FAILED_UNKNOWN"
      end
      runtime.log(("RT shutdown workflow cleanup node=%s final_reason=%s stage=%s"):format(tostring(node.id), tostring(workflow.final_reason or "UNKNOWN"), tostring(workflow.stage or "UNKNOWN")), "INFO")
      node.shutdown_workflow = {}
      workflow = node.shutdown_workflow
    end
  end

  rt_sync.sync_rt_node({
    config = runtime.config,
    comms = runtime.refs.comms,
    nodes = runtime.state.nodes,
    plan = plan,
    power_target = runtime.state.power_target,
    rt_global_off = runtime.state.rt_global_off_hold,
    trigger = tostring(reason or "coalesced:unspecified"),
    log = function(message, level) runtime.log(message, level or "INFO") end
  }, node)
end

function M.check_timeouts(runtime)
  local peers = runtime.refs.comms:get_peers() or {}
  local now = os.epoch("utc")
  local timeout_ms = (runtime.config.comms and runtime.config.comms.peer_timeout_s or runtime.config.heartbeat_interval * 4) * 1000
  local down_grace_ms = (runtime.config.comms and runtime.config.comms.peer_down_grace_s or 0) * 1000
  local stale_nodes = {}
  for _, node in pairs(runtime.state.nodes) do
    local peer = peers[node.id]
    local last_seen = peer and peer.last_seen or node.last_seen
    local peer_down = peer and peer.down
    node.recovering = peer and peer.recovering_since ~= nil or false
    if peer and peer.age then node.last_seen_age = math.floor(peer.age) end
    local should_mark_down = false
    if peer ~= nil then should_mark_down = peer_down == true else should_mark_down = last_seen and (now - last_seen > (timeout_ms + down_grace_ms)) end
    if should_mark_down then
      if node.status ~= runtime.libs.constants.status_levels.OFFLINE then runtime.log("Node offline: " .. tostring(node.id)) end
      if not node.down_since then node.down_since = now end
      node.status = runtime.libs.health.status.DOWN
      node.offline = true; node.stale = true; node.recovering = false; node.managed = false
      node.health = node.health or runtime.libs.health.new({})
      node.health.status = runtime.libs.health.status.DOWN
      node.health.reasons = node.health.reasons or {}
      node.health.reasons[runtime.libs.health.reasons.COMMS_DOWN] = true
      if last_seen and (now - last_seen) >= runtime.tuning.node_offline_purge_after_ms then stale_nodes[#stale_nodes + 1] = node.id end
    elseif node.health and node.health.reasons then
      node.health.reasons[runtime.libs.health.reasons.COMMS_DOWN] = nil
      node.down_since = nil; node.offline = false; node.stale = false; node.recovering = false; node.managed = true
    end
  end
  for _, node_id in ipairs(stale_nodes) do
    local node = runtime.state.nodes[node_id]
    if node and node.status == runtime.libs.health.status.DOWN then
      runtime.log(("Node stale purged from managed set: %s"):format(tostring(node_id)), "INFO")
      node.managed = false
      node.active = false
    end
  end
end

return M
