-- CONFIG
local CONFIG = {
  LOG_NAME = "master", -- Log file name for this role.
  LOG_PREFIX = "MASTER", -- Default log prefix for master events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_master.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt" -- Node ID storage path.
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "master",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local require = bootstrap.require

local constants = require("shared.constants")
local colors = require("shared.colors")
local utils = require("core.utils")
local health = require("core.health")
local monitor_manager = require("core.monitor_manager")
local sequencer_lib = require("master.startup_sequencer")
local overview_ui = require("master.ui.overview")
local rt_ui = require("master.ui.rt_dashboard")
local energy_ui = require("master.ui.energy")
local resources_ui = require("master.ui.resources")
local alarms_ui = require("master.ui.alarms")
local alerts_ui = require("master.ui.alerts")
local multiview_ui = require("master.ui.multiview")
local profiles = require("master.profiles")
local trends_lib = require("core.trends")
local time = require("core.time")
local ui = require("core.ui")
local config = require("master.config")
local runtime_context = require("master.runtime_context")
local rt_sync = require("master.rt_sync")
local message_handlers = require("master.message_handlers")
local rt_sync_coalescer_lib = require("master.rt_sync_coalescer")
local housekeeping = require("master.housekeeping")
local ui_controller_lib = require("master.ui_controller")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local alert_service_lib = require("services.alert_service")
local telemetry_service = require("services.telemetry_service")
local control_service = require("services.control_service")
local ui_service = require("services.ui_service")

-- Initialize file logging early to capture startup events.
local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
local debug_enabled = config.debug_logging
if CONFIG.DEBUG_LOG_ENABLED ~= nil then
  debug_enabled = CONFIG.DEBUG_LOG_ENABLED
end
local log_status = utils.init_logger({
  log_name = log_name,
  prefix = CONFIG.LOG_PREFIX,
  enabled = debug_enabled,
  truncate = config.reset_log_on_start == true
})
if log_status and log_status.enabled then
  utils.log(CONFIG.LOG_PREFIX, string.format("Logfile %s (startup=%s)", tostring(log_status.log_path), tostring(log_status.startup_action)), "INFO")
end
utils.log(CONFIG.LOG_PREFIX, "Startup", "INFO")
local recovery_status = bootstrap.get_recovery_status and bootstrap.get_recovery_status() or nil

local multiview_source = "unknown"
do
  local probe = multiview_ui and multiview_ui.render
  if type(probe) == "function" and debug and type(debug.getinfo) == "function" then
    local info = debug.getinfo(probe, "S")
    multiview_source = info and info.source or multiview_source
  end
end
utils.log(CONFIG.LOG_PREFIX, "Loaded multiview module source: " .. tostring(multiview_source), "INFO")
utils.log(CONFIG.LOG_PREFIX, "Configured monitor scale: " .. tostring(config.monitor_scale), "INFO")
if type(config.channels) == "table" then
  utils.log(CONFIG.LOG_PREFIX, ("Configured channels control=%s status=%s"):format(tostring(config.channels.control), tostring(config.channels.status)), "INFO")
end

runtime_context.normalize_config(config)

local state = runtime_context.new_state()
local monitor_cache = state.monitor_cache
local monitor_mgr = nil
local view_manager = nil
local layout_config_path = "/xreactor/config/master_ui_layout.json"
local nodes = state.nodes
local alarms = state.alarms
local alert_service = nil
local power_target = state.power_target
local sequencer
local comms
local services
local last_draw = state.last_draw
local monitor_scan_last = state.monitor_scan_last
local trends = trends_lib.new(600)
local last_trend_sample = state.last_trend_sample
local active_profile = state.active_profile
local auto_profile = profiles.AUTO_ENABLED or state.auto_profile
local critical_blink_until = state.critical_blink_until
local trend_cache = state.trend_cache
local ui_controller
local rt_global_off_hold = state.rt_global_off_hold == true
local node_offline_purge_after_ms = 120000
local rt_sync_batch_window_ms = 250
local rt_shutdown_candidate_stability_ms = 1500

local function warn_once(key, message)
  runtime_context.warn_once(state, function(msg)
    utils.log("MASTER", msg)
  end, key, message)
end

local function master_time_label()
  return runtime_context.master_time_label(time)
end

local function normalize_setpoints(setpoints)
  return rt_sync.normalize_setpoints(setpoints)
end


local function send_rt_mode(node, mode)
  rt_sync.send_rt_mode(comms, node, mode)
end

local function send_rt_setpoints(node, setpoints)
  rt_sync.send_rt_setpoints(comms, node, setpoints)
end

local function refresh_monitors(force)
  local now = os.epoch("utc")
  if not monitor_mgr then
    return
  end
  if not force and now - monitor_scan_last < 5000 then
    return
  end
  monitor_scan_last = now
  local monitors = monitor_mgr:scan()
  local signature_parts = {}
  for _, entry in ipairs(monitors) do
    table.insert(signature_parts, entry.id or entry.name)
  end
  local signature = table.concat(signature_parts, "|")
  if monitor_cache.signature ~= signature or force then
    local healthy = {}
    for _, entry in ipairs(monitors) do
      local ok, err = pcall(ui.clear, entry.mon)
      if ok then
        table.insert(healthy, entry)
      else
        utils.log("MASTER", "Disabling monitor " .. tostring(entry.name or entry.id) .. " during initial clear: " .. tostring(err), "WARN")
      end
    end
    local healthy_signature_parts = {}
    for _, entry in ipairs(healthy) do
      table.insert(healthy_signature_parts, entry.id or entry.name)
    end
    monitor_cache = { list = healthy, signature = table.concat(healthy_signature_parts, "|") }
    if #healthy < #monitors then
      utils.log("MASTER", ("UI degraded: %d/%d monitors available after clear guard"):format(#healthy, #monitors), "WARN")
    end
  end
end

local function add_alarm(sender, severity, message)
  table.insert(alarms, 1, {
    sender_id = sender,
    severity = severity,
    message = message,
    timestamp = master_time_label()
  })
  if #alarms > 50 then table.remove(alarms) end
  if severity == constants.status_levels.EMERGENCY then
    critical_blink_until = os.epoch("utc") + 5000
  end
end

local function set_default_mode(node)
  rt_sync.set_default_mode({ config = config, comms = comms }, node)
end

local function same_setpoints(a, b)
  return rt_sync.same_setpoints(a, b)
end

local function sync_rt_node(node, reason)
  if not node or node.role ~= constants.roles.RT_NODE then return end
  set_default_mode(node)
  local now = os.epoch("utc")
  if node.desired_mode and node.mode ~= node.desired_mode then
    if not node.last_mode_request or now - node.last_mode_request > 5000 then
      send_rt_mode(node, node.desired_mode)
    end
    return
  end
  local plan = rt_sync.build_node_setpoint_plan({
    config = config,
    nodes = nodes,
    power_target = power_target,
    rt_global_off = rt_global_off_hold
  })
  node.shutdown_workflow = node.shutdown_workflow or {}
  local workflow = node.shutdown_workflow
  local target_shutdown_state = constants.node_states.OFF
  local restart_cooldown_ms = ((config.rt_setpoints and config.rt_setpoints.shutdown_restart_cooldown_ms) or 15000)
  local function workflow_fail(reason, err_msg, level)
    workflow.stage = "FAILED"
    workflow.failed_at = now
    workflow.completed_at = now
    workflow.final_reason = reason
    workflow.error = err_msg
    workflow.outcome = "FAILED"
    workflow.state_reached_at = nil
    utils.log("MASTER", ("RT shutdown workflow failed node=%s reason=%s error=%s state=%s request_at=%s ack_at=%s"):format(
      tostring(node.id), tostring(reason), tostring(err_msg), tostring(node.state), tostring(workflow.request_command_at), tostring(workflow.request_ack_at)
    ), level or "WARN")
    utils.log("MASTER", ("RT shutdown workflow outcome set node=%s outcome=%s final_reason=%s completed_at=%s"):format(
      tostring(node.id), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)
    ), "INFO")
  end
  if plan.shutdown_candidate_id == node.id then
    if workflow.stage == "CANCELLED_DEMAND_RECOVERED" and workflow.cancelled_at and (now - workflow.cancelled_at) >= restart_cooldown_ms and not workflow.requested_at then
      workflow.shutdown_candidate_since = now
      workflow.stage = nil
      workflow.final_reason = nil
      workflow.outcome = nil
      workflow.completed_at = nil
      workflow.error = nil
      utils.log("MASTER", ("RT shutdown workflow candidate reset node=%s reason=POST_CANCEL_COOLDOWN_REEVALUATE"):format(tostring(node.id)), "INFO")
    end
    workflow.shutdown_candidate_since = workflow.shutdown_candidate_since or now
    local candidate_age_ms = now - workflow.shutdown_candidate_since
    if workflow.cancelled_at and (now - workflow.cancelled_at) < restart_cooldown_ms then
      workflow.shutdown_candidate_since = now
      utils.log("MASTER", ("RT shutdown workflow debounce node=%s remaining_ms=%d reason=CANCEL_RECOVERY_COOLDOWN"):format(tostring(node.id), math.max(0, restart_cooldown_ms - (now - workflow.cancelled_at))), "INFO")
    elseif candidate_age_ms < rt_shutdown_candidate_stability_ms then
      utils.log("MASTER", ("RT shutdown workflow debounce node=%s remaining_ms=%d reason=CANDIDATE_STABILITY"):format(tostring(node.id), math.max(0, rt_shutdown_candidate_stability_ms - candidate_age_ms)), "INFO")
    elseif not workflow.requested_at then
      workflow.requested_at = now
      workflow.stage = "RAMPDOWN"
      workflow.final_reason = nil
      workflow.error = nil
      workflow.outcome = nil
      workflow.target_state = target_shutdown_state
      workflow.ready_at = now + ((config.rt_setpoints and config.rt_setpoints.shutdown_ramp_ms) or 6000)
      workflow.request_command_at = nil
      workflow.request_ack_at = nil
      workflow.command_ack_at = nil
      workflow.completed_at = nil
      workflow.state_reached_at = nil
      utils.log("MASTER", ("RT shutdown workflow start node=%s reason=SHED_EXCESS_CAPACITY ready_in_ms=%d"):format(tostring(node.id), tonumber(((config.rt_setpoints and config.rt_setpoints.shutdown_ramp_ms) or 6000))), "INFO")
    end
  elseif workflow.requested_at and workflow.stage ~= "COMPLETED" and workflow.stage ~= "FAILED" and workflow.stage ~= "CANCELLED_DEMAND_RECOVERED" then
    workflow.stage = "CANCELLED_DEMAND_RECOVERED"
    workflow.final_reason = "CANCELLED_DEMAND_RECOVERED"
    workflow.error = nil
    workflow.outcome = "CANCELLED"
    workflow.state_reached_at = nil
    workflow.completed_at = now
    workflow.cancelled_at = now
    workflow.requested_at = nil
    utils.log("MASTER", ("RT shutdown workflow cancelled node=%s reason=%s"):format(tostring(node.id), tostring(workflow.final_reason)), "INFO")
    utils.log("MASTER", ("RT shutdown workflow outcome set node=%s outcome=%s final_reason=%s completed_at=%s"):format(
      tostring(node.id), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)
    ), "INFO")
  else
    workflow.shutdown_candidate_since = nil
  end
  if sequencer and plan.startup_candidate_id and node.id == plan.startup_candidate_id then
    sequencer:enqueue(node.id, "DEMAND_STARTUP")
    utils.log("MASTER", ("RT startup candidate node=%s target=%.2f required_nodes=%d"):format(tostring(node.id), tonumber(power_target) or 0, tonumber(plan.required_nodes) or 0), "INFO")
  end
  if plan.shutdown_candidate_id and node.id == plan.shutdown_candidate_id then
    local remaining_ms = workflow.ready_at and math.max(0, workflow.ready_at - now) or 0
    utils.log("MASTER", ("RT shutdown candidate node=%s target=%.2f stage=%s remaining_ms=%d"):format(
      tostring(node.id), tonumber(power_target) or 0, tostring(workflow.stage or "RAMPDOWN"), tonumber(remaining_ms) or 0), "INFO")
  end
  if workflow.requested_at and workflow.stage == "RAMPDOWN" and workflow.ready_at and now >= workflow.ready_at then
    workflow.stage = "REQUEST_STATE"
    workflow.request_command_at = nil
    workflow.command_ack_at = nil
    workflow.request_ack_at = nil
    workflow.failed_at = nil
    utils.log("MASTER", ("RT shutdown workflow rampdown complete node=%s action=REQUEST_STATE target_state=%s"):format(
      tostring(node.id), tostring(workflow.target_state or target_shutdown_state)
    ), "INFO")
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
      utils.log("MASTER", ("RT shutdown workflow state reached node=%s state=%s"):format(
        tostring(node.id), tostring(node.state)
      ), "INFO")
      utils.log("MASTER", ("RT shutdown workflow state_reached_at set node=%s state_reached_at=%s"):format(
        tostring(node.id), tostring(workflow.state_reached_at)
      ), "INFO")
      utils.log("MASTER", ("RT shutdown workflow finalised node=%s final_reason=%s requested_at=%s accepted_at=%s completed_at=%s"):format(
        tostring(node.id), tostring(workflow.final_reason), tostring(workflow.request_command_at), tostring(workflow.request_ack_at), tostring(workflow.completed_at)
      ), "INFO")
      utils.log("MASTER", ("RT shutdown workflow outcome set node=%s outcome=%s final_reason=%s completed_at=%s"):format(
        tostring(node.id), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)
      ), "INFO")
    elseif workflow.target_state and node.state == constants.node_states.EMERGENCY then
      workflow_fail("FAILED_INVALID_STATE", "NODE_IN_EMERGENCY")
    end
  end

  if workflow.stage == "REQUEST_STATE" or workflow.stage == "REQUESTED" then
    if not workflow.request_command_at or now - workflow.request_command_at > 5000 then
      local setpoints = normalize_setpoints(node.last_setpoints or {})
      setpoints.shutdown_stage = "REQUEST_OFF"
      setpoints.desired_node_state = workflow.target_state or target_shutdown_state
      send_rt_setpoints(node, setpoints)
      workflow.request_command_at = now
      workflow.stage = "REQUESTED"
      utils.log("MASTER", ("RT shutdown workflow request sent node=%s stage=%s target_state=%s request_at=%s"):format(
        tostring(node.id), tostring(setpoints.shutdown_stage), tostring(setpoints.desired_node_state), tostring(workflow.request_command_at)
      ), "INFO")
    end
    if cmd_result and cmd_result.at and cmd_result.at >= (workflow.request_command_at or 0) then
      local cmd_value = cmd_result.command_value or {}
      local ack_shutdown_stage = cmd_result.shutdown_stage or cmd_value.shutdown_stage
      local ack_desired_node_state = cmd_result.desired_node_state or cmd_value.desired_node_state
      local is_shutdown_ack = cmd_result.command_target == (constants.command_targets.SET_SETPOINTS or "SET_SETPOINTS") and
          ack_shutdown_stage == "REQUEST_OFF" and
          ack_desired_node_state == (workflow.target_state or target_shutdown_state)
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
          utils.log("MASTER", ("RT shutdown workflow request accepted node=%s requested_state=%s transition=%s accepted_at=%s"):format(
            tostring(node.id), tostring(workflow.target_state or target_shutdown_state), transition, tostring(workflow.request_accept_at)
          ), "INFO")
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
      workflow_fail("FAILED_TIMEOUT", ("STATE_TRANSITION_TIMEOUT current=%s target=%s"):format(
        tostring(node.state), tostring(workflow.target_state or target_shutdown_state)
      ))
    end
  end
  if workflow.stage == "COMPLETED" or workflow.stage == "FAILED" or workflow.stage == "CANCELLED_DEMAND_RECOVERED" then
    if not workflow.outcome or not workflow.final_reason or not workflow.completed_at then
      utils.log("MASTER", ("RT shutdown workflow terminal field gap node=%s stage=%s outcome=%s final_reason=%s completed_at=%s"):format(
        tostring(node.id), tostring(workflow.stage), tostring(workflow.outcome), tostring(workflow.final_reason), tostring(workflow.completed_at)
      ), "WARN")
    end
    if workflow.completed_at and (now - workflow.completed_at) > 20000 then
      if workflow.stage == "COMPLETED" and workflow.final_reason ~= "SUCCESS_COMPLETED" then
        utils.log("MASTER", ("RT shutdown workflow cleanup guard node=%s corrected_final_reason=%s previous=%s"):format(
          tostring(node.id), "SUCCESS_COMPLETED", tostring(workflow.final_reason)
        ), "WARN")
        workflow.final_reason = "SUCCESS_COMPLETED"
      elseif workflow.stage == "CANCELLED_DEMAND_RECOVERED" and workflow.final_reason ~= "CANCELLED_DEMAND_RECOVERED" then
        utils.log("MASTER", ("RT shutdown workflow cleanup guard node=%s corrected_final_reason=%s previous=%s"):format(
          tostring(node.id), "CANCELLED_DEMAND_RECOVERED", tostring(workflow.final_reason)
        ), "WARN")
        workflow.final_reason = "CANCELLED_DEMAND_RECOVERED"
      elseif workflow.stage == "FAILED" and (workflow.final_reason == nil or tostring(workflow.final_reason):sub(1, 7) ~= "FAILED_") then
        utils.log("MASTER", ("RT shutdown workflow cleanup guard node=%s corrected_final_reason=%s previous=%s"):format(
          tostring(node.id), "FAILED_UNKNOWN", tostring(workflow.final_reason)
        ), "WARN")
        workflow.final_reason = "FAILED_UNKNOWN"
      end
      utils.log("MASTER", ("RT shutdown workflow cleanup node=%s final_reason=%s stage=%s"):format(
        tostring(node.id), tostring(workflow.final_reason or "UNKNOWN"), tostring(workflow.stage or "UNKNOWN")
      ), "INFO")
      node.shutdown_workflow = {}
      workflow = node.shutdown_workflow
    end
  end
  rt_sync.sync_rt_node({
    config = config,
    comms = comms,
    nodes = nodes,
    plan = plan,
    power_target = power_target,
    rt_global_off = rt_global_off_hold,
    trigger = tostring(reason or "direct"),
    log = function(message, level) utils.log("MASTER", message, level or "INFO") end
  }, node)
end

local rt_sync_coalescer

local function mark_rt_sync_dirty(node, reason)
  return rt_sync_coalescer.mark_dirty(node, reason)
end

local function flush_rt_sync_queue(opts)
  return rt_sync_coalescer.flush(opts)
end

local node_message_handler

local function update_node(message)
  return node_message_handler.update_node(message)
end

local function handle_command_timeouts()
  return housekeeping.handle_command_timeouts({
    constants = constants,
    utils = utils,
    comms = comms,
    nodes = nodes,
    log = function(message, level) utils.log("MASTER", message, level or "INFO") end
  })
end

local function check_timeouts()
  local peers = comms:get_peers() or {}
  local now = os.epoch("utc")
  local timeout_ms = (config.comms and config.comms.peer_timeout_s or config.heartbeat_interval * 4) * 1000
  local down_grace_ms = (config.comms and config.comms.peer_down_grace_s or 0) * 1000
  local stale_nodes = {}
  for _, node in pairs(nodes) do
    local peer = peers[node.id]
    local last_seen = peer and peer.last_seen or node.last_seen
    local peer_down = peer and peer.down
    node.recovering = peer and peer.recovering_since ~= nil or false
    if peer and peer.age then
      node.last_seen_age = math.floor(peer.age)
    end
    local should_mark_down = false
    if peer ~= nil then
      should_mark_down = peer_down == true
    else
      should_mark_down = last_seen and (now - last_seen > (timeout_ms + down_grace_ms))
    end
    if should_mark_down then
      if node.status ~= constants.status_levels.OFFLINE then
        utils.log("MASTER", "Node offline: " .. tostring(node.id))
      end
      if not node.down_since then
        node.down_since = now
      end
      node.status = health.status.DOWN
      node.offline = true
      node.stale = true
      node.recovering = false
      node.managed = false
      node.health = node.health or health.new({})
      node.health.status = health.status.DOWN
      node.health.reasons = node.health.reasons or {}
      node.health.reasons[health.reasons.COMMS_DOWN] = true
      if last_seen and (now - last_seen) >= node_offline_purge_after_ms then
        stale_nodes[#stale_nodes + 1] = node.id
      end
    elseif node.health and node.health.reasons then
      node.health.reasons[health.reasons.COMMS_DOWN] = nil
      node.down_since = nil
      node.offline = false
      node.stale = false
      node.recovering = false
      node.managed = true
    end
  end
  for _, node_id in ipairs(stale_nodes) do
    local node = nodes[node_id]
    if node and node.status == health.status.DOWN then
      utils.log("MASTER", ("Node stale purged from managed set: %s"):format(tostring(node_id)), "INFO")
      node.managed = false
      node.active = false
    end
  end
end

local function estimate_base_power()
  local total = 0
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      total = total + (node.output or 0)
    end
  end
  if total > 0 then return total end
  if power_target > 0 then return power_target end
  return 0
end

local function apply_profile(name)
  if rt_global_off_hold then
    utils.log("MASTER", "Ignoring profile change while RT-OFF hold is active", "WARN")
    return
  end
  local profile = profiles[name]
  if not profile then return end
  active_profile = name
  sequencer.ramp_profile = profile.ramp or sequencer.ramp_profile
  utils.log("MASTER", ("Profile applied: %s (target_factor=%s, ramp=%s)"):format(tostring(name), tostring(profile.target), tostring(sequencer.ramp_profile)), "INFO")
  local base = estimate_base_power()
  if base > 0 then
    power_target = base * profile.target
    utils.log("MASTER", ("Power target recalculated from profile %s: base=%.2f -> target=%.2f"):format(tostring(name), base, power_target), "INFO")
    for _, node in pairs(nodes) do
      if node.role == constants.roles.RT_NODE then
        mark_rt_sync_dirty(node, "profile_change")
      end
    end
    flush_rt_sync_queue({ force = true })
  else
    utils.log("MASTER", ("Profile %s applied but base power is unavailable; target unchanged"):format(tostring(name)), "WARN")
  end
end

local function set_rt_global_hold(enabled)
  local next_value = enabled == true
  if rt_global_off_hold == next_value then
    return
  end
  rt_global_off_hold = next_value
  utils.log("MASTER", "RT global hold " .. (rt_global_off_hold and "ENABLED (0%)" or "DISABLED (normal control)"), "WARN")
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      mark_rt_sync_dirty(node, "global_hold_toggle")
    end
  end
  flush_rt_sync_queue({ force = true })
end

local function sample_trends()
  local now = os.epoch("utc")
  if now - last_trend_sample < 1000 then return end
  last_trend_sample = now
  local power = 0
  local stored, capacity = 0, 0
  local water_total = 0
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      power = power + (node.output or 0)
    elseif node.role == constants.roles.ENERGY_NODE then
      stored = stored + (node.stored or 0)
      capacity = capacity + (node.capacity or 0)
    elseif node.role == constants.roles.WATER_NODE then
      water_total = node.total_water or water_total
    end
  end
  local energy_pct = capacity > 0 and (stored / capacity) * 100 or 0
  trends:push("power", power)
  if trends:push("energy", energy_pct) then
    local trend_values = trends:values("energy")
    trend_cache.energy = trend_values
    if #trend_values >= 2 then
      local last = trend_values[#trend_values]
      local prev = trend_values[#trend_values - 1]
      if last > prev + 0.5 then
        trend_cache.energy_arrow = "↑"
      elseif last < prev - 0.5 then
        trend_cache.energy_arrow = "↓"
      else
        trend_cache.energy_arrow = "→"
      end
    else
      trend_cache.energy_arrow = "→"
    end
  end
  trends:push("water", water_total)

  if auto_profile then
    if energy_pct > 90 and active_profile ~= "IDLE" then
      apply_profile("IDLE")
    elseif energy_pct < 30 and active_profile ~= "PEAK" then
      apply_profile("PEAK")
    end
  end
end

local function build_master_alert_payload()
  return housekeeping.build_master_alert_payload(alert_service, config)
end

local function init()
  local configured_scale = config.monitor_scale
  if configured_scale == nil then
    configured_scale = config.ui_scale_default
  end
  local resolved_scale = tonumber(configured_scale)
  if configured_scale ~= nil and not resolved_scale then
    utils.log("MASTER", "Ignoring non-numeric monitor scale config value: " .. tostring(configured_scale), "WARN")
  end
  utils.log("MASTER", "Resolved monitor scale for scan: " .. tostring(resolved_scale), "INFO")
  monitor_mgr = monitor_manager.new({
    log_prefix = "MASTER",
    node_id = node_id,
    scale = resolved_scale,
    path = "/xreactor/config/registry_master_monitors.json"
  })
  view_manager = multiview_ui.new({
    layout_path = layout_config_path,
    views = {
      overview = { label = "Overview", render = overview_ui.render, hit_test = overview_ui.hit_test, interval = 0.5 },
      energy = { label = "Energy", render = energy_ui.render, interval = 1.0 },
      rt = { label = "RT", render = rt_ui.render, interval = 1.0 },
      resources = { label = "Resources", render = resources_ui.render, interval = 2.0 },
      alerts = { label = "Alerts", render = alerts_ui.render, hit_test = alerts_ui.hit_test, interval = 0.5 },
      alarms = { label = "Logs", render = alarms_ui.render, interval = 1.0 }
    },
    view_order = { "overview", "energy", "rt", "resources", "alerts", "alarms" },
    on_action = function(action)
      if ui_controller then
        ui_controller.handle_action(action)
      end
    end
  })
  refresh_monitors(true)
  comms = comms_service.new({
    config = config,
    log_prefix = "MASTER",
    on_message = update_node
  })
  services = service_manager.new({ log_prefix = "MASTER" })
  rt_sync_coalescer = rt_sync_coalescer_lib.new({
    constants = constants,
    utils = utils,
    batch_window_ms = rt_sync_batch_window_ms,
    sync_rt_node = sync_rt_node,
    log = function(message, level) utils.log("MASTER", message, level or "INFO") end
  })
  services:add(comms)
  local recovery_notice = nil
  if recovery_status and recovery_status.had_marker then
    local action = recovery_status.result or "recovery"
    local notice_until = os.epoch("utc") + (config.alert_info_ttl or 20) * 1000
    recovery_notice = {
      active = true,
      active_until = notice_until,
      message = "Update recovery: " .. tostring(action),
      details = recovery_status.marker or {}
    }
  end
  alert_service = alert_service_lib.new({
    config = config,
    nodes = nodes,
    power_target = function() return power_target end,
    log_prefix = "ALERT",
    recovery_notice = recovery_notice
  })
  services:add(alert_service)
  services:add(telemetry_service.new({
    comms = comms,
    log_prefix = "MASTER",
    status_interval = config.status_interval or config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval,
    build_payload = build_master_alert_payload
  }))
  services:add(control_service.new({
    name = "HOUSEKEEPING",
    interval = 0.5,
    runtime = {
      tick = function()
        handle_command_timeouts()
        if sequencer then
          sequencer:tick(nodes)
        end
        flush_rt_sync_queue()
        check_timeouts()
        sample_trends()
      end
    }
  }))
  services:add(ui_service.new({
    interval = 0.5,
    force_interval = 2,
    snapshot = function(event)
      return {
        event = event and event[1] or "tick",
        monitors = monitor_cache.list and #monitor_cache.list or 0,
        active_view = view_manager and view_manager.active_key or "overview",
        node_count = runtime_context.table_count(nodes),
        queue_depth = sequencer and #sequencer.queue or 0,
        critical_blink = critical_blink_until,
        trends = last_trend_sample
      }
    end,
    render = function()
      refresh_monitors(false)
      if ui_controller then
        ui_controller.draw()
      end
    end,
    handle_input = function(event)
      if ui_controller then
        ui_controller.handle_input(event)
      end
    end
  }))
  services:init()
  sequencer = sequencer_lib.new(comms, config.startup_ramp, {
    alert_service = alert_service,
    timeout_s = config.startup_stage_timeout_s,
    config = config
  })
  node_message_handler = message_handlers.new({
    constants = constants,
    utils = utils,
    health = health,
    nodes = nodes,
    comms = function() return comms end,
    sequencer = sequencer,
    mark_rt_sync_dirty = mark_rt_sync_dirty,
    add_alarm = add_alarm,
    master_time_label = master_time_label,
    log = function(message, level) utils.log("MASTER", message, level or "INFO") end
  })
  ui_controller = ui_controller_lib.new({
    constants = constants,
    health = health,
    config = config,
    nodes = nodes,
    alarms = alarms,
    comms = comms,
    sequencer = sequencer,
    alert_service = alert_service,
    view_manager = view_manager,
    trends = trends,
    trend_cache = trend_cache,
    state = {
      monitor_cache = monitor_cache,
      last_draw = last_draw,
      critical_blink_until = critical_blink_until,
      power_target = power_target,
      active_profile = active_profile,
      auto_profile = auto_profile,
      rt_global_off_hold = rt_global_off_hold
    },
    calc = {
      apply_profile = function(name)
        apply_profile(name)
      end,
      set_auto_profile = function(value) auto_profile = value end,
      get_auto_profile = function() return auto_profile end,
      get_active_profile = function() return active_profile end,
      get_power_target = function() return power_target end,
      get_critical_blink_until = function() return critical_blink_until end,
      get_rt_global_off_hold = function() return rt_global_off_hold end,
      set_rt_global_off_hold = function(value) set_rt_global_hold(value) end
    }
  })
  comms:send_hello({ monitors = monitor_cache.list and #monitor_cache.list or 0 })
  utils.log("MASTER", "Initialized as " .. comms.network.id)
end

local function main_loop()
  utils.log("MASTER", "Entering event loop", "INFO")
  while true do
    local timer = os.startTimer(0.5)
    while true do
      local event = { os.pullEvent() }
      if event[1] == "modem_message" then
        comms:handle_event(event)
      elseif event[1] == "monitor_touch" or event[1] == "key" or event[1] == "char" then
        services:tick(nil, event)
      elseif event[1] == "timer" and event[2] == timer then
        break
      end
    end
    services:tick()
  end
end

local function is_terminate_error(err)
  local message = tostring(err or ""):lower()
  return message:find("terminate", 1, true) ~= nil
end

local function shutdown(reason)
  local shutdown_reason = tostring(reason or "requested")
  if shutdown_reason:lower():find("terminate", 1, true) then
    utils.log("MASTER", "terminate received", "WARN")
  else
    utils.log("MASTER", "shutdown requested: " .. shutdown_reason, "WARN")
  end
  utils.log("MASTER", "shutting down services", "INFO")
  if services then
    local ok, err = pcall(function() services:stop() end)
    if not ok and not is_terminate_error(err) then
      utils.log("MASTER", "service shutdown error: " .. tostring(err), "ERROR")
    end
  end
  utils.log("MASTER", "shutdown complete", "INFO")
end

local ok, result_or_err = xpcall(function()
  init()
  return main_loop()
end, function(err)
  return err
end)

if ok then
  shutdown(result_or_err)
else
  if is_terminate_error(result_or_err) then
    shutdown("terminate received")
  else
    shutdown("runtime error: " .. tostring(result_or_err))
    error(result_or_err, 0)
  end
end
