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
    controllable = payload.controllable
  }
end

function M.build_rt_setpoints(config, power_target)
  local hold = config and config.rt_global_off == true
  local target = hold and 0 or power_target
  return M.normalize_setpoints({
    target_rpm = config.rt_setpoints.target_rpm,
    power_target = target,
    steam_target = config.rt_setpoints.steam_target,
    enable_reactors = hold and false or config.rt_setpoints.enable_reactors,
    enable_turbines = hold and false or config.rt_setpoints.enable_turbines,
    assignment_reason = hold and "GLOBAL_HOLD" or "GLOBAL_TARGET",
    assignment_source = "master.rt_sync",
    controllable = not hold
  })
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
      a.assignment_reason == b.assignment_reason and a.assignment_rank == b.assignment_rank and a.controllable == b.controllable
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
  local global_target = number_or(ctx.power_target, 0)
  local hold = ctx.rt_global_off == true
  local plan = {}
  local eligible = {}

  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      local eval = M.evaluate_rt_node(node, { rt_global_off = hold })
      local entry = {
        node = node,
        eval = eval,
        id = utils.normalize_node_id(node.id),
        mode = eval.mode,
        status = eval.status,
        assigned_power = 0,
        assignment_rank = nil,
        assignment_reason = eval.reason,
        controllable = eval.controllable == true
      }
      table.insert(plan, entry)
      if entry.controllable then
        table.insert(eligible, entry)
      end
    end
  end

  table.sort(plan, function(a, b) return (a.id or "") < (b.id or "") end)
  table.sort(eligible, function(a, b) return (a.id or "") < (b.id or "") end)

  local share = (#eligible > 0 and global_target > 0) and (global_target / #eligible) or 0
  for idx, entry in ipairs(eligible) do
    entry.assigned_power = share
    entry.assignment_rank = idx
    entry.assignment_reason = "LOAD_SHARE"
  end

  for _, entry in ipairs(plan) do
    local enabled = entry.controllable and not hold
    entry.setpoints = M.normalize_setpoints({
      target_rpm = base.target_rpm,
      steam_target = enabled and base.steam_target or 0,
      power_target = enabled and entry.assigned_power or 0,
      enable_reactors = enabled and (base.enable_reactors == true) or false,
      enable_turbines = enabled and (base.enable_turbines == true) or false,
      assignment_reason = entry.assignment_reason,
      assignment_source = "master.rt_sync.plan",
      assignment_rank = entry.assignment_rank,
      controllable = entry.controllable
    })
  end

  return {
    nodes = plan,
    global_target = global_target,
    hold = hold,
    controllable_count = #eligible
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
  if ctx.log then
    ctx.log(("RT plan node=%s controllable=%s reason=%s assigned=%.2f mode=%s status=%s"):format(
      tostring(node_id), tostring(assigned.controllable), tostring(assigned.assignment_reason), tonumber(desired.power_target) or 0,
      tostring(assigned.mode), tostring(assigned.status)
    ), assigned.controllable and "INFO" or "WARN")
  end
  if not M.same_setpoints(node.last_setpoints, desired) then
    M.send_rt_setpoints(ctx.comms, node, desired)
  end
end

return M
