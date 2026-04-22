local constants = require("shared.constants")
local utils = require("core.utils")

local M = {}

function M.normalize_setpoints(setpoints)
  local payload = setpoints or {}
  return {
    target_rpm = payload.target_rpm,
    power_target = payload.power_target,
    steam_target = payload.steam_target,
    enable_reactors = payload.enable_reactors,
    enable_turbines = payload.enable_turbines
  }
end

function M.build_rt_setpoints(config, power_target)
  return M.normalize_setpoints({
    target_rpm = config.rt_setpoints.target_rpm,
    power_target = power_target,
    steam_target = config.rt_setpoints.steam_target,
    enable_reactors = config.rt_setpoints.enable_reactors,
    enable_turbines = config.rt_setpoints.enable_turbines
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
      a.enable_reactors == b.enable_reactors and a.enable_turbines == b.enable_turbines
end

function M.set_default_mode(ctx, node)
  local mode = node.desired_mode or ctx.config.rt_default_mode or "MASTER"
  M.send_rt_mode(ctx.comms, node, mode)
end

function M.sync_rt_node(ctx, node)
  if node.role ~= constants.roles.RT_NODE then return end
  if not node.mode then M.set_default_mode(ctx, node) end
  local desired = M.build_rt_setpoints(ctx.config, ctx.power_target)
  if not M.same_setpoints(node.last_setpoints, desired) then
    M.send_rt_setpoints(ctx.comms, node, desired)
  end
end

return M
