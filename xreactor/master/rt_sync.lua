local constants = require("shared.constants")
local utils = require("core.utils")

local M = {}

local function number_or(value, fallback)
  if type(value) == "number" then return value end
  return fallback
end

local function normalize_node_mode(mode)
  if mode == nil then return "UNKNOWN" end
  return tostring(mode)
end

local function sort_by_priority_then_id(a, b)
  if (a.priority or 0) == (b.priority or 0) then
    return (a.id or "") < (b.id or "")
  end
  return (a.priority or 0) > (b.priority or 0)
end

function M.normalize_setpoints(setpoints)
  local payload = setpoints or {}
  return {
    target_rpm = payload.target_rpm,
    power_target = payload.power_target,
    steam_target = payload.steam_target,
    enable_reactors = payload.enable_reactors,
    enable_turbines = payload.enable_turbines,
    assignment_reason = payload.assignment_reason,
    assignment_source = payload.assignment_source,
    assignment_rank = payload.assignment_rank,
    assignment_state = payload.assignment_state,
    controllable = payload.controllable,
    shutdown_stage = payload.shutdown_stage,
    desired_node_state = payload.desired_node_state
  }
end

function M.send_rt_mode(comms, node, mode)
  if not node or not mode then return end
  comms:send_command(utils.normalize_node_id(node.id), {
    target = constants.command_targets.SET_MODE or constants.command_targets.MODE,
    value = mode
  }, { requires_applied = true })
  node.last_mode_request = os.epoch("utc")
  node.desired_mode = mode
end

function M.send_rt_setpoints(comms, node, setpoints)
  if not node then return end
  local payload = M.normalize_setpoints(setpoints)
  comms:send_command(utils.normalize_node_id(node.id), {
    target = constants.command_targets.SET_SETPOINTS or constants.command_targets.POWER_TARGET,
    value = payload
  }, { requires_applied = true })
  node.last_setpoints = payload
  node.last_setpoints_ts = os.epoch("utc")
end

function M.same_setpoints(a, b)
  if not a or not b then return false end
  return a.target_rpm == b.target_rpm and a.power_target == b.power_target and a.steam_target == b.steam_target and
      a.enable_reactors == b.enable_reactors and a.enable_turbines == b.enable_turbines and
      a.assignment_reason == b.assignment_reason and a.assignment_source == b.assignment_source and a.assignment_rank == b.assignment_rank and
      a.assignment_state == b.assignment_state and a.controllable == b.controllable and
      a.shutdown_stage == b.shutdown_stage and a.desired_node_state == b.desired_node_state
end

local function same_shutdown_intent(a, b)
  if not a or not b then return false end
  local state_a = a.assignment_state
  local state_b = b.assignment_state
  local shutdown_like_a = state_a == "shutdown" or state_a == "shed" or state_a == "standby"
  local shutdown_like_b = state_b == "shutdown" or state_b == "shed" or state_b == "standby"
  if not shutdown_like_a or not shutdown_like_b then return false end
  return a.desired_node_state == b.desired_node_state and
      a.shutdown_stage == b.shutdown_stage and
      (tonumber(a.power_target) or 0) == (tonumber(b.power_target) or 0) and
      (tonumber(a.steam_target) or 0) == (tonumber(b.steam_target) or 0) and
      a.enable_reactors == b.enable_reactors and
      a.enable_turbines == b.enable_turbines
end

local function should_debounce_resend(node, desired, now)
  local min_gap_ms = 1000
  local last_ts = tonumber(node.last_setpoints_ts) or 0
  if last_ts <= 0 then return false end
  if not M.same_setpoints(node.last_setpoints, desired) then return false end
  local last_result = node.last_command_result
  if type(last_result) == "table" and last_result.ok == false then
    return false
  end
  if (now - last_ts) > min_gap_ms then return false end
  return true
end

local function ack_matches_setpoints(node, ack, desired)
  if type(ack) ~= "table" then return false end
  if ack.ok == false then return false end
  local setpoints_target = constants.command_targets.SET_SETPOINTS or constants.command_targets.POWER_TARGET
  local legacy_target = constants.command_targets.POWER_TARGET
  if ack.command_target ~= setpoints_target and ack.command_target ~= legacy_target then
    return false
  end
  local ack_value = ack.command_value
  if type(ack_value) ~= "table" then return false end
  local ack_matches_desired = M.same_setpoints(M.normalize_setpoints(ack_value), desired)
  if not ack_matches_desired then return false end
  local ack_at = tonumber(ack.at) or 0
  local last_setpoints_ts = tonumber(node and node.last_setpoints_ts) or 0
  if last_setpoints_ts > 0 and ack_at > 0 and ack_at < last_setpoints_ts then
    return false
  end
  return true
end

function M.set_default_mode(ctx, node)
  local mode = node.desired_mode or ctx.config.rt_default_mode or "MASTER"
  M.send_rt_mode(ctx.comms, node, mode)
end

function M.evaluate_rt_node(node, opts)
  opts = opts or {}
  local hold = opts.rt_global_off == true
  local mode = normalize_node_mode(node and node.mode)
  local status = node and node.status or constants.status_levels.OFFLINE
  local state = node and node.state or constants.node_states.OFF
  local output = node and number_or(node.output, 0) or 0
  if hold then
    return { controllable = false, reason = "GLOBAL_HOLD", mode = mode, status = status, state = state, output = output }
  end
  if mode ~= "MASTER" then
    return { controllable = false, reason = "MODE_" .. mode, mode = mode, status = status, state = state, output = output }
  end
  if status == constants.status_levels.EMERGENCY or state == constants.node_states.EMERGENCY or state == constants.node_states.SAFE then
    return { controllable = false, reason = "SAFE_OR_EMERGENCY", mode = mode, status = status, state = state, output = output }
  end
  if status == constants.status_levels.OFFLINE then
    return { controllable = false, reason = "OFFLINE", mode = mode, status = status, state = state, output = output }
  end
  if state == constants.node_states.OFF then
    return { controllable = false, reason = "STARTUP_PENDING", mode = mode, status = status, state = state, output = output }
  end
  return { controllable = true, reason = "ACTIVE", mode = mode, status = status, state = state, output = output }
end

function M.build_node_setpoint_plan(ctx)
  local nodes = ctx.nodes or {}
  local config = ctx.config or {}
  local base = config.rt_setpoints or {}
  local global_target = math.max(0, number_or(ctx.power_target, 0))
  local hold = ctx.rt_global_off == true
  local now = os.epoch("utc")
  local plan = {}
  local active, pending_startup = {}, {}
  local max_node_power = math.max(1, number_or(base.power_per_node_capacity, 3000))
  local startup_margin = math.max(0, number_or(base.startup_margin_power, max_node_power * 0.2))

  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      local eval = M.evaluate_rt_node(node, { rt_global_off = hold })
      local shutdown = node and node.shutdown_workflow or {}
      local entry = {
        node = node,
        eval = eval,
        id = utils.normalize_node_id(node.id),
        mode = eval.mode,
        status = eval.status,
        assigned_power = 0,
        assignment_rank = nil,
        assignment_reason = eval.reason,
        assignment_state = "unavailable",
        controllable = eval.controllable == true,
        startup_eligible = eval.reason == "STARTUP_PENDING",
        priority = math.max(0, number_or(eval.output, 0)),
        shutdown_requested_at = shutdown.requested_at,
        shutdown_stage = shutdown.stage,
        shutdown_ready_at = shutdown.ready_at
      }
      table.insert(plan, entry)
      if entry.controllable then table.insert(active, entry) end
      if entry.startup_eligible then table.insert(pending_startup, entry) end
    end
  end

  table.sort(plan, function(a, b) return (a.id or "") < (b.id or "") end)
  table.sort(active, sort_by_priority_then_id)
  table.sort(pending_startup, function(a, b) return (a.id or "") < (b.id or "") end)

  local needed_nodes = global_target > 0 and math.max(1, math.ceil(global_target / max_node_power)) or 0
  local available_nodes = #active + #pending_startup
  needed_nodes = math.min(needed_nodes, available_nodes)
  local keep_count = math.min(#active, needed_nodes)

  local remaining = global_target
  for idx, entry in ipairs(active) do
    if idx <= keep_count then
      local assign = math.min(max_node_power, remaining)
      if idx == keep_count then assign = remaining end
      assign = math.max(0, assign)
      entry.assigned_power = assign
      entry.assignment_rank = idx
      entry.assignment_state = "active"
      entry.assignment_reason = idx == 1 and "PRIMARY_ACTIVE" or "DEMAND_ACTIVE"
      remaining = math.max(0, remaining - assign)
    else
      entry.assigned_power = 0
      entry.assignment_rank = idx
      if idx == keep_count + 1 then
        local ready_at = entry.shutdown_ready_at or 0
        local requested_at = entry.shutdown_requested_at or now
        local ramp_ms = math.max(1000, number_or(base.shutdown_ramp_ms, 6000))
        if ready_at <= 0 then
          ready_at = requested_at + ramp_ms
        end
        local shutdown_ready = now >= ready_at
        entry.assignment_state = shutdown_ready and "shutdown" or "shed"
        entry.assignment_reason = shutdown_ready and "SHUTDOWN_READY" or "SHED_EXCESS_CAPACITY"
      else
        entry.assignment_state = "standby"
        entry.assignment_reason = "STANDBY"
      end
    end
  end

  local startup_candidate = nil
  local missing_active_nodes = needed_nodes - #active
  if missing_active_nodes > 0 and #pending_startup > 0 and remaining > startup_margin then
    startup_candidate = pending_startup[1]
    startup_candidate.assignment_reason = "STARTUP_NEEDED"
    startup_candidate.assignment_state = "startup"
    startup_candidate.assignment_rank = keep_count + 1
  end

  for _, entry in ipairs(pending_startup) do
    if entry ~= startup_candidate then
      entry.assignment_reason = "STARTUP_WAIT"
      entry.assignment_state = "standby"
      entry.assigned_power = 0
    end
  end

  local shutdown_candidate = nil
  for _, entry in ipairs(active) do
    if entry.assignment_reason == "SHED_EXCESS_CAPACITY" then
      shutdown_candidate = entry
      break
    end
  end

  for _, entry in ipairs(plan) do
    local enabled = entry.controllable and not hold and entry.assignment_state == "active"
    local desired_node_state = nil
    if entry.assignment_state == "shutdown" then
      desired_node_state = constants.node_states.OFF
    elseif entry.assignment_state == "standby" or entry.assignment_state == "shed" then
      desired_node_state = constants.node_states.LIMITED
    end
    entry.setpoints = M.normalize_setpoints({
      target_rpm = base.target_rpm,
      steam_target = enabled and base.steam_target or 0,
      power_target = enabled and entry.assigned_power or 0,
      enable_reactors = enabled and (base.enable_reactors == true) or false,
      enable_turbines = enabled and (base.enable_turbines == true) or false,
      assignment_reason = entry.assignment_reason,
      assignment_source = "master.rt_sync.plan",
      assignment_state = entry.assignment_state,
      assignment_rank = entry.assignment_rank,
      controllable = entry.controllable,
      shutdown_stage = entry.assignment_state == "shutdown" and "REQUEST_OFF" or (entry.assignment_state == "shed" and "RAMPDOWN" or nil),
      desired_node_state = desired_node_state
    })
  end

  return {
    nodes = plan,
    global_target = global_target,
    hold = hold,
    controllable_count = #active + #pending_startup,
    required_nodes = needed_nodes,
    startup_candidate_id = startup_candidate and startup_candidate.id or nil,
    shutdown_candidate_id = shutdown_candidate and shutdown_candidate.id or nil
  }
end

function M.sync_rt_node(ctx, node)
  if node.role ~= constants.roles.RT_NODE then return end
  if not node.mode then M.set_default_mode(ctx, node) end
  local plan = ctx.plan or M.build_node_setpoint_plan(ctx)
  local node_id = utils.normalize_node_id(node.id)
  local assigned = nil
  for _, entry in ipairs(plan.nodes or {}) do
    if entry.id == node_id then assigned = entry break end
  end
  if not assigned then return end
  local desired = assigned.setpoints
  local trigger = tostring(ctx.trigger or "unknown")
  if ctx.log then
    ctx.log(("RT plan node=%s trigger=%s state=%s controllable=%s reason=%s assigned=%.2f mode=%s status=%s"):format(
      tostring(node_id), trigger, tostring(desired.assignment_state), tostring(assigned.controllable), tostring(assigned.assignment_reason), tonumber(desired.power_target) or 0,
      tostring(assigned.mode), tostring(assigned.status)
    ), assigned.controllable and "INFO" or "WARN")
  end
  local now = os.epoch("utc")
  if should_debounce_resend(node, desired, now) then
    if ctx.log then
      ctx.log(("RT setpoints deduped node=%s trigger=%s state=%s reason=%s age_ms=%d"):format(
        tostring(node_id), trigger, tostring(desired.assignment_state), tostring(desired.assignment_reason), now - (node.last_setpoints_ts or now)
      ))
    end
    return
  end

  local workflow = node.shutdown_workflow or {}
  if workflow.stage == "REQUESTED" or workflow.stage == "WAITING_STATE" then
    if ctx.log then
      ctx.log(("RT setpoints deduped node=%s trigger=%s reason=SHUTDOWN_WORKFLOW_%s"):format(tostring(node_id), trigger, tostring(workflow.stage)))
    end
    return
  end

  local ack = node.last_command_result
  if ack_matches_setpoints(node, ack, desired) then
    if ctx.log then
      ctx.log(("RT setpoints deduped node=%s trigger=%s reason=ACK_MATCH"):format(tostring(node_id), trigger))
    end
    return
  end

  local shutdown_target = desired.desired_node_state == constants.node_states.OFF and desired.assignment_state == "shutdown"
  if shutdown_target and ack and ack.ok ~= false and ack.command_target == (constants.command_targets.SET_SETPOINTS or constants.command_targets.POWER_TARGET) then
    local ack_state = ack.desired_node_state or (ack.command_value and ack.command_value.desired_node_state)
    local ack_transition = ack.transition or (ack.command_value and ack.command_value.transition)
    if ack_state == constants.node_states.OFF and (ack_transition == "REQUESTED" or ack_transition == "ALREADY_IN_STATE") then
      if ctx.log then
        ctx.log(("RT shutdown resend skipped node=%s trigger=%s ack_transition=%s"):format(tostring(node_id), trigger, tostring(ack_transition)))
      end
      return
    end
  end

  local last_result = node.last_command_result
  local last_failed = type(last_result) == "table" and last_result.ok == false
  if not last_failed and same_shutdown_intent(node.last_setpoints, desired) then
    if ctx.log then
      ctx.log(("RT shutdown setpoints deduped node=%s trigger=%s stage=%s target=%s"):format(
        tostring(node_id), trigger, tostring(desired.shutdown_stage), tostring(desired.desired_node_state)
      ))
    end
    return
  end
  if not M.same_setpoints(node.last_setpoints, desired) then
    if ctx.log then
      ctx.log(("RT command send node=%s trigger=%s state=%s reason=%s"):format(
        tostring(node_id), trigger, tostring(desired.assignment_state), tostring(desired.assignment_reason)
      ), "INFO")
    end
    M.send_rt_setpoints(ctx.comms, node, desired)
  end
end

return M
