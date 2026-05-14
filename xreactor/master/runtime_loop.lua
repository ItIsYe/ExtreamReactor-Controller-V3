local M = {}

local function run_master()
  local CONFIG = { LOG_NAME = "master", LOG_PREFIX = "MASTER", DEBUG_LOG_ENABLED = nil, BOOTSTRAP_LOG_ENABLED = false, BOOTSTRAP_LOG_PATH = nil, NODE_ID_PATH = "/xreactor/config/node_id.txt" }
  local bootstrap = dofile("/xreactor/core/bootstrap.lua")
  bootstrap.setup({ role = "master", log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED, log_path = CONFIG.BOOTSTRAP_LOG_PATH })
  local require = bootstrap.require
  local constants, utils, health, monitor_manager = require("shared.constants"), require("core.utils"), require("core.health"), require("core.monitor_manager")
  local sequencer_lib, overview_ui, rt_ui, energy_ui = require("master.startup_sequencer"), require("master.ui.overview"), require("master.ui.rt_dashboard"), require("master.ui.energy")
  local resources_ui, alarms_ui, alerts_ui, multiview_ui = require("master.ui.resources"), require("master.ui.alarms"), require("master.ui.alerts"), require("master.ui.multiview")
  local profiles, trends_lib, time, ui, config = require("master.profiles"), require("core.trends"), require("core.time"), require("core.ui"), require("master.config")
  local runtime_context, rt_sync, message_handlers = require("master.runtime_context"), require("master.rt_sync"), require("master.message_handlers")
  local rt_sync_coalescer_lib, housekeeping, ui_controller_lib = require("master.rt_sync_coalescer"), require("master.housekeeping"), require("master.ui_controller")
  local init_runtime = require("master.init_runtime")
  local service_manager, comms_service, alert_service_lib = require("services.service_manager"), require("services.comms_service"), require("services.alert_service")
  local telemetry_service, control_service, ui_service = require("services.telemetry_service"), require("services.control_service"), require("services.ui_service")
  local monitor_ops, profile_ops, rt_ops = require("master.runtime_ops_monitor"), require("master.runtime_ops_profile"), require("master.runtime_ops_rt")

  local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
  local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
  local debug_enabled = CONFIG.DEBUG_LOG_ENABLED ~= nil and CONFIG.DEBUG_LOG_ENABLED or config.debug_logging
  utils.init_logger({ log_name = log_name, prefix = CONFIG.LOG_PREFIX, enabled = debug_enabled, truncate = config.reset_log_on_start == true })
  runtime_context.normalize_config(config)

  local runtime = runtime_context.new_runtime({ trends = trends_lib.new(600) })
  runtime.config = config
  runtime.log = function(message, level) utils.log("MASTER", message, level or "INFO") end
  runtime.libs = { constants = constants, utils = utils, health = health, ui = ui, profiles = profiles, rt_sync = rt_sync, rt_sync_coalescer = rt_sync_coalescer_lib }
  local recovery_status = bootstrap.get_recovery_status and bootstrap.get_recovery_status() or nil

  local function mark_rt_sync_dirty(node, reason)
    if not runtime.refs.rt_sync_coalescer then return end
    runtime.refs.rt_sync_coalescer.mark_dirty(node, reason)
  end
  local function flush_rt_sync_queue(opts)
    if runtime.refs.rt_sync_coalescer then runtime.refs.rt_sync_coalescer.flush(opts) end
  end
  runtime.mark_rt_sync_dirty = mark_rt_sync_dirty
  runtime.flush_rt_sync_queue = flush_rt_sync_queue

  init_runtime.run({
    config = config, utils = utils, constants = constants, health = health, node_id = node_id, layout_config_path = runtime.tuning.layout_config_path,
    monitor_manager = monitor_manager, multiview_ui = multiview_ui, overview_ui = overview_ui, energy_ui = energy_ui, rt_ui = rt_ui,
    resources_ui = resources_ui, alerts_ui = alerts_ui, alarms_ui = alarms_ui, comms_service = comms_service, service_manager = service_manager,
    rt_sync_coalescer_lib = rt_sync_coalescer_lib, alert_service_lib = alert_service_lib, telemetry_service = telemetry_service, control_service = control_service,
    ui_service = ui_service, sequencer_lib = sequencer_lib, message_handlers = message_handlers, ui_controller_lib = ui_controller_lib,
    runtime_context = runtime_context, recovery_status = recovery_status, nodes = runtime.state.nodes, alarms = runtime.state.alarms,
    trends = runtime.refs.trends, trend_cache = runtime.state.trend_cache, monitor_cache = runtime.state.monitor_cache,
    rt_sync_batch_window_ms = runtime.tuning.rt_sync_batch_window_ms,
    refresh_monitors = function(force) monitor_ops.refresh_monitors(runtime, force) end,
    update_node = function(message) return runtime.refs.node_message_handler.update_node(message) end,
    sync_rt_node = function(node, reason) rt_ops.sync_rt_node(runtime, node, reason) end,
    build_master_alert_payload = function() return housekeeping.build_master_alert_payload(runtime.refs.alert_service, config) end,
    housekeeping_tick = function() housekeeping.handle_command_timeouts({ constants = constants, utils = utils, comms = runtime.refs.comms, nodes = runtime.state.nodes, log = runtime.log }); if runtime.refs.sequencer then runtime.refs.sequencer:tick(runtime.state.nodes) end; flush_rt_sync_queue(); rt_ops.check_timeouts(runtime); profile_ops.sample_trends(runtime) end,
    ui_snapshot = function(event) return { event = event and event[1] or "tick", monitors = runtime.state.monitor_cache.list and #runtime.state.monitor_cache.list or 0, active_view = runtime.refs.view_manager and runtime.refs.view_manager.active_key or "overview", node_count = runtime_context.table_count(runtime.state.nodes), queue_depth = runtime.refs.sequencer and #runtime.refs.sequencer.queue or 0, rt_sync_pending = runtime.refs.rt_sync_coalescer and runtime.refs.rt_sync_coalescer.size() or 0, critical_blink = runtime.state.critical_blink_until, trends = runtime.state.last_trend_sample } end,
    ui_render = function()
      monitor_ops.refresh_monitors(runtime, false)
      if runtime.refs.ui_controller then
        runtime_context.warn_once(runtime.state, runtime.log, "ui_draw_started", "UI draw path active (ui_controller.draw)")
        local ok, draw_err = pcall(runtime.refs.ui_controller.draw)
        if not ok then
          runtime.log("UI draw failed: " .. tostring(draw_err), "ERROR")
        else
          local ov_meta = runtime.state.last_overview_render_meta
          if ov_meta and runtime.state._last_overview_cache_unchanged ~= ov_meta.cache_unchanged then
            runtime.state._last_overview_cache_unchanged = ov_meta.cache_unchanged
            if ov_meta.cache_unchanged then
              runtime.log("Overview draw executed on unchanged model (cache skip disabled)", "DEBUG")
            else
              runtime.log("Overview draw executed on changed model", "DEBUG")
            end
          end
        end
        local total_nodes = runtime_context.table_count(runtime.state.nodes)
        local rt_nodes, support_nodes = 0, 0
        for _, node in pairs(runtime.state.nodes or {}) do
          if node.role == constants.roles.RT_NODE then rt_nodes = rt_nodes + 1 else support_nodes = support_nodes + 1 end
        end
        local ms = runtime.state.last_ui_model_stats or {}
        local ui_models = runtime.refs.ui_controller and runtime.refs.ui_controller._last_models
        local rt_model = ui_models and ui_models.rt or nil
        local energy_model = ui_models and ui_models.energy or nil
        local sample_rt = nil
        if rt_model and rt_model.rt_nodes then
          for _, candidate in ipairs(rt_model.rt_nodes) do
            if tostring(candidate.id or "") ~= "" and tostring(candidate.id or "UNKNOWN") ~= "UNKNOWN" then
              sample_rt = candidate
              break
            end
          end
          sample_rt = sample_rt or rt_model.rt_nodes[1]
        end
        runtime.log(("UI model density: nodes=%d rt=%d support=%d queue=%d ov=%d rt_vm=%d support_vm=%d matrices=%d"):format(
          total_nodes,
          rt_nodes,
          support_nodes,
          runtime.refs.sequencer and #runtime.refs.sequencer.queue or 0,
          ms.overview_nodes or 0,
          ms.rt_nodes or 0,
          ms.support_nodes or 0,
          (energy_model and (energy_model.matrix_count or #(energy_model.matrices or {}))) or (ms.matrices or 0)
        ), "DEBUG")
        if sample_rt then
          runtime.log(("UI RT semantic sample: id=%s node_mode=%s display=%s assignment=%s reason=%s control=%s queue=%s/%s freshness=%s"):format(
            tostring(sample_rt.id or "?"),
            tostring(sample_rt.node_mode or sample_rt.mode or "-"),
            tostring(sample_rt.display_mode or "-"),
            tostring(sample_rt.assignment_state or "-"),
            tostring(sample_rt.assignment_reason or "-"),
            tostring(sample_rt.control_source or "-"),
            tostring(sample_rt.queue_state or "-"),
            tostring(sample_rt.queue_step or "-"),
            tostring(sample_rt.freshness or "-")
          ), "DEBUG")
        end
        if energy_model then
          local energy_node_count = 0
          for _, node in pairs(runtime.state.nodes or {}) do
            if node.role == constants.roles.ENERGY_NODE then energy_node_count = energy_node_count + 1 end
          end
          runtime.log(("UI energy model: mode=%s matrices=%d matrix_count=%d stored=%.1f capacity=%.1f input=%.1f output=%.1f empty=%s"):format(
            tostring(energy_model.mode or "-"),
            #(energy_model.matrices or {}),
            tonumber(energy_model.matrix_count or #(energy_model.matrices or {})) or 0,
            tonumber(energy_model.stored or 0) or 0,
            tonumber(energy_model.capacity or 0) or 0,
            tonumber(energy_model.input or 0) or 0,
            tonumber(energy_model.output or 0) or 0,
            tostring((#(energy_model.matrices or {}) == 0) and ((energy_model.stored or 0) == 0) and ((energy_model.input or 0) == 0))
          ), "DEBUG")
          if energy_node_count > 0 and #(energy_model.matrices or {}) == 0 and (energy_model.stored or 0) == 0 and (energy_model.input or 0) == 0 then
            runtime.log(("UI energy model empty despite %d ENERGY node(s) - check payload mapping node.energy vs payload root"):format(energy_node_count), "WARN")
          end
        end
        if runtime.refs.view_manager and runtime.refs.view_manager.last_render_results then
          local failures = 0
          for _, r in ipairs(runtime.refs.view_manager.last_render_results) do
            if not r.ok then
              failures = failures + 1
              runtime.log(("UI draw failure detail: view=%s monitor=%s role=%s error=%s"):format(tostring(r.view), tostring(r.monitor), tostring(r.role), tostring(r.error)), "ERROR")
            else
              runtime.log(("UI draw success detail: view=%s monitor=%s role=%s"):format(tostring(r.view), tostring(r.monitor), tostring(r.role)), "DEBUG")
            end
          end
          if failures == 0 then runtime.log("UI draw result: all views rendered successfully", "DEBUG") end
        end
      else
        runtime_context.warn_once(runtime.state, runtime.log, "ui_draw_missing_controller", "UI draw skipped: ui_controller missing")
      end
    end,
    ui_handle_input = function(event) if runtime.refs.ui_controller then runtime.refs.ui_controller.handle_input(event) end end,
    mark_rt_sync_dirty = mark_rt_sync_dirty,
    add_alarm = function(sender, severity, message) table.insert(runtime.state.alarms, 1, { sender_id = sender, severity = severity, message = message, timestamp = runtime_context.master_time_label(time) }); if #runtime.state.alarms > 50 then table.remove(runtime.state.alarms) end end,
    master_time_label = function() return runtime_context.master_time_label(time) end,
    apply_profile = function(name) profile_ops.apply_profile(runtime, name) end,
    set_auto_profile = function(value) runtime.state.auto_profile = value end,
    get_auto_profile = function() return runtime.state.auto_profile end,
    get_active_profile = function() return runtime.state.active_profile end,
    get_power_target = function() return runtime.state.power_target end,
    get_critical_blink_until = function() return runtime.state.critical_blink_until end,
    get_rt_global_off_hold = function() return runtime.state.rt_global_off_hold end,
    set_rt_global_off_hold = function(value) profile_ops.set_rt_global_hold(runtime, value) end,
    last_draw = runtime.state.last_draw, refs = runtime.refs
  })
  runtime.log(("Runtime refs ready: view_manager=%s ui_controller=%s services=%s"):format(
    tostring(runtime.refs.view_manager ~= nil),
    tostring(runtime.refs.ui_controller ~= nil),
    tostring(runtime.refs.services ~= nil)
  ), "INFO")
  monitor_ops.refresh_monitors(runtime, true)
  if runtime.refs.ui_controller then
    runtime.log("Initial UI draw trigger after init", "INFO")
    local ok, draw_err = pcall(runtime.refs.ui_controller.draw)
    if not ok then
      runtime.log("Initial UI draw failed: " .. tostring(draw_err), "ERROR")
    elseif runtime.refs.view_manager and runtime.refs.view_manager.last_render_results then
      local failures = 0
      for _, r in ipairs(runtime.refs.view_manager.last_render_results) do
        if not r.ok then
          failures = failures + 1
          runtime.log(("Initial draw failure detail: view=%s monitor=%s role=%s error=%s"):format(tostring(r.view), tostring(r.monitor), tostring(r.role), tostring(r.error)), "ERROR")
        else
          runtime.log(("Initial draw success detail: view=%s monitor=%s role=%s"):format(tostring(r.view), tostring(r.monitor), tostring(r.role)), "DEBUG")
        end
      end
      if failures == 0 then runtime.log("Initial draw result: all views rendered successfully", "DEBUG") end
    end
  end

  while true do
    local timer = os.startTimer(0.5)
    while true do
      local event = { os.pullEvent() }
      if event[1] == "modem_message" then runtime.refs.comms:handle_event(event)
      elseif event[1] == "monitor_touch" or event[1] == "key" or event[1] == "char" then runtime.refs.services:tick(nil, event)
      elseif event[1] == "timer" and event[2] == timer then break end
    end
    runtime.refs.services:tick()
  end
end

function M.run()
  local ok, err = xpcall(run_master, function(e) return e end)
  if not ok then error(err, 0) end
end

return M
