local M = {}

-- Fix P5: ctx-Interface ist bewusst flach gehalten für CC:Tweaked-Kompatibilität,
-- aber die Felder sind jetzt in logische Gruppen dokumentiert:
--
--  ctx.config          -- Master-Config (heartbeat_interval, rt_setpoints, ...)
--  ctx.utils/constants/health/... -- Bibliotheken
--  ctx.refs            -- Mutable refs (wird von M.run befüllt: comms, services, ...)
--  ctx.nodes/alarms/trends/...    -- Shared State
--  ctx.*_tick / ctx.*_render / ctx.*_snapshot  -- Callbacks aus runtime_loop
--  ctx.get_*/set_*     -- State-Accessor-Lambdas
--
-- Neue Felder bitte in die passende Gruppe oben einsortieren.
function M.run(ctx)
  local configured_scale = ctx.config.monitor_scale
  if configured_scale == nil then
    configured_scale = ctx.config.ui_scale_default
  end
  local resolved_scale = tonumber(configured_scale)
  if configured_scale ~= nil and not resolved_scale then
    ctx.utils.log("MASTER", "Ignoring non-numeric monitor scale config value: " .. tostring(configured_scale), "WARN")
  end
  local min_monitor_width = tonumber(ctx.config.master_min_monitor_width) or 48
  local min_monitor_height = tonumber(ctx.config.master_min_monitor_height) or 27
  ctx.utils.log("MASTER", "Configured monitor scale for master scan: raw=" .. tostring(configured_scale) .. " resolved=" .. tostring(resolved_scale), "INFO")
  ctx.utils.log("MASTER", "Configured MASTER minimum monitor size: " .. tostring(min_monitor_width) .. "x" .. tostring(min_monitor_height), "INFO")
  ctx.refs.monitor_mgr = ctx.monitor_manager.new({
    log_prefix = "MASTER",
    node_id = ctx.node_id,
    scale = resolved_scale,
    min_width = min_monitor_width,
    min_height = min_monitor_height,
    path = "/xreactor/config/registry_master_monitors.json"
  })
  ctx.refs.view_manager = ctx.multiview_ui.new({
    layout_path = ctx.layout_config_path,
    views = {
      overview = { label = "Overview", render = ctx.overview_ui.render, hit_test = ctx.overview_ui.hit_test, interval = 0.5 },
      energy = { label = "Energy", render = ctx.energy_ui.render, interval = 1.0 },
      rt = { label = "RT", render = ctx.rt_ui.render, hit_test = ctx.rt_ui.hit_test, interval = 1.0 },
      resources = { label = "Resources", render = ctx.resources_ui.render, interval = 2.0 },
      alerts = { label = "Alerts", render = ctx.alerts_ui.render, hit_test = ctx.alerts_ui.hit_test, interval = 0.5 },
      alarms = { label = "Logs", render = ctx.alarms_ui.render, hit_test = ctx.alarms_ui.handle_input, interval = 1.0 },
      maintenance = { label = "Maintenance", render = ctx.maintenance_ui.render, hit_test = ctx.maintenance_ui.hit_test, interval = 1.0 },
      updates = { label = "Updates", render = ctx.updates_ui.render, interval = 2.0 },
      system_map = { label = "System Map", render = ctx.system_map_ui.render, interval = 2.0 },
      config_editor = { label = "Config", render = ctx.config_editor_ui.render, hit_test = ctx.config_editor_ui.hit_test, interval = 1.0 },
    },
    view_order = { "overview", "rt", "energy", "resources", "alerts", "alarms", "maintenance", "updates", "system_map", "config_editor" },
    on_action = function(action)
      if ctx.refs.ui_controller then
        return ctx.refs.ui_controller.handle_action(action)
      end
      return false, "ui-controller-missing"
    end
  })
  ctx.utils.log("MASTER", "View manager initialized for primary roles: monitor1=overview monitor2=rt monitor3=energy", "INFO")
  ctx.refresh_monitors(true)
  ctx.refs.comms = ctx.comms_service.new({ config = ctx.config, log_prefix = "MASTER", on_message = ctx.update_node })
  ctx.refs.services = ctx.service_manager.new({ log_prefix = "MASTER" })
  ctx.refs.rt_sync_coalescer = ctx.rt_sync_coalescer_lib.new({
    constants = ctx.constants,
    utils = ctx.utils,
    batch_window_ms = ctx.rt_sync_batch_window_ms,
    sync_rt_node = ctx.sync_rt_node,
    log = function(message, level) ctx.utils.log("MASTER", message, level or "INFO") end
  })
  ctx.utils.log("MASTER", "RT sync coalescer ready: role_inference=enabled skip_diagnostics=enabled", "INFO")
  ctx.refs.services:add(ctx.refs.comms)
  local recovery_notice = nil
  if ctx.recovery_status and ctx.recovery_status.had_marker then
    local action = ctx.recovery_status.result or "recovery"
    local notice_until = os.epoch("utc") + (ctx.config.alert_info_ttl or 20) * 1000
    recovery_notice = { active = true, active_until = notice_until, message = "Update recovery: " .. tostring(action), details = ctx.recovery_status.marker or {} }
  end
  ctx.refs.alert_service = ctx.alert_service_lib.new({
    config = ctx.config,
    nodes = ctx.nodes,
    power_target = function() return ctx.get_power_target() end,
    log_prefix = "ALERT",
    recovery_notice = recovery_notice
  })
  ctx.refs.services:add(ctx.refs.alert_service)
  ctx.refs.services:add(ctx.telemetry_service.new({
    comms = ctx.refs.comms,
    log_prefix = "MASTER",
    status_interval = ctx.config.status_interval or ctx.config.heartbeat_interval,
    heartbeat_interval = ctx.config.heartbeat_interval,
    build_payload = ctx.build_master_alert_payload
  }))
  ctx.refs.services:add(ctx.control_service.new({ name = "HOUSEKEEPING", interval = 0.5, runtime = { tick = ctx.housekeeping_tick } }))
  ctx.refs.services:add(ctx.ui_service.new({ interval = 0.5, force_interval = 2, snapshot = ctx.ui_snapshot, render = ctx.ui_render, handle_input = ctx.ui_handle_input }))
  ctx.refs.services:init()
  ctx.refs.sequencer = ctx.sequencer_lib.new(ctx.refs.comms, ctx.config.startup_ramp, {
    alert_service = ctx.refs.alert_service,
    timeout_s = ctx.config.startup_stage_timeout_s,
    config = ctx.config
  })
  ctx.refs.node_message_handler = ctx.message_handlers.new({
    constants = ctx.constants,
    utils = ctx.utils,
    health = ctx.health,
    nodes = ctx.nodes,
    comms = function() return ctx.refs.comms end,
    sequencer = ctx.refs.sequencer,
    mark_rt_sync_dirty = ctx.mark_rt_sync_dirty,
    add_alarm = ctx.add_alarm,
    master_time_label = ctx.master_time_label,
    log = function(message, level) ctx.utils.log("MASTER", message, level or "INFO") end
  })
  ctx.refs.ui_controller = ctx.ui_controller_lib.new({
    constants = ctx.constants,
    health = ctx.health,
    config = ctx.config,
    nodes = ctx.nodes,
    alarms = ctx.alarms,
    comms = ctx.refs.comms,
    sequencer = ctx.refs.sequencer,
    alert_service = ctx.refs.alert_service,
    view_manager = ctx.refs.view_manager,
    trends = ctx.trends,
    trend_cache = ctx.trend_cache,
    node_message_handler = ctx.refs.node_message_handler,
    state = {
      monitor_cache = ctx.monitor_cache,
      last_draw = ctx.last_draw,
      critical_blink_until = ctx.get_critical_blink_until(),
      power_target = ctx.get_power_target(),
      active_profile = ctx.get_active_profile(),
      auto_profile = ctx.get_auto_profile(),
      rt_global_off_hold = ctx.get_rt_global_off_hold()
    },
    log = function(message, level) ctx.utils.log("MASTER", message, level or "INFO") end,
    calc = {
      apply_profile = ctx.apply_profile,
      set_auto_profile = ctx.set_auto_profile,
      get_auto_profile = ctx.get_auto_profile,
      get_active_profile = ctx.get_active_profile,
      get_power_target = ctx.get_power_target,
      get_critical_blink_until = ctx.get_critical_blink_until,
      get_rt_global_off_hold = ctx.get_rt_global_off_hold,
      set_rt_global_off_hold = ctx.set_rt_global_off_hold,
      set_fuel_reserve = ctx.set_fuel_reserve,
      set_water_target = ctx.set_water_target,
      set_reactor_fill_target = ctx.set_reactor_fill_target,
      get_auto_update_enabled = ctx.get_auto_update_enabled,
      set_auto_update_enabled = ctx.set_auto_update_enabled
    }
  })
  ctx.utils.log("MASTER", ("UI wiring ready: monitors=%d view_manager=%s ui_controller=%s"):format(
    ctx.monitor_cache.list and #ctx.monitor_cache.list or 0,
    tostring(ctx.refs.view_manager ~= nil),
    tostring(ctx.refs.ui_controller ~= nil)
  ), "INFO")
  ctx.refs.comms:send_hello({ monitors = ctx.monitor_cache.list and #ctx.monitor_cache.list or 0 })
  ctx.utils.log("MASTER", "Initialized as " .. ctx.refs.comms.network.id)
end

return M
