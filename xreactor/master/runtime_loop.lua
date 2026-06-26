local M = {}


local function run_master()
  local CONFIG = { LOG_NAME = "master", LOG_PREFIX = "MASTER", DEBUG_LOG_ENABLED = nil, BOOTSTRAP_LOG_ENABLED = false, BOOTSTRAP_LOG_PATH = nil, NODE_ID_PATH = "/xreactor/config/node_id.txt" }
  local bootstrap = dofile("/xreactor/core/bootstrap.lua")
  bootstrap.setup({ role = "master", log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED, log_path = CONFIG.BOOTSTRAP_LOG_PATH })
  local require = bootstrap.require
  local constants, utils, health, monitor_manager = require("shared.constants"), require("core.utils"), require("core.health"), require("core.monitor_manager")
  local build_info = require("shared.build_info")
  local sequencer_lib, overview_ui, rt_ui, energy_ui = require("master.startup_sequencer"), require("master.ui.overview"), require("master.ui.rt_dashboard"), require("master.ui.energy")
  local resources_ui, alarms_ui, alerts_ui, multiview_ui = require("master.ui.resources"), require("master.ui.alarms"), require("master.ui.alerts"), require("master.ui.multiview")
  local profiles, trends_lib, time, ui, config = require("master.profiles"), require("core.trends"), require("core.time"), require("core.ui"), require("master.config")
  local runtime_context, rt_sync, message_handlers = require("master.runtime_context"), require("master.rt_sync"), require("master.message_handlers")
  local rt_sync_coalescer_lib, housekeeping, ui_controller_lib = require("master.rt_sync_coalescer"), require("master.housekeeping"), require("master.ui_controller")
  local init_runtime, ui_diagnostics = require("master.init_runtime"), require("master.ui_diagnostics")
  local service_manager, comms_service, alert_service_lib = require("services.service_manager"), require("services.comms_service"), require("services.alert_service")
  local telemetry_service, control_service, ui_service = require("services.telemetry_service"), require("services.control_service"), require("services.ui_service")
  local monitor_ops, profile_ops, rt_ops = require("master.runtime_ops_monitor"), require("master.runtime_ops_profile"), require("master.runtime_ops_rt")

  local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
  local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
  local debug_enabled = CONFIG.DEBUG_LOG_ENABLED ~= nil and CONFIG.DEBUG_LOG_ENABLED or config.debug_logging
  utils.init_logger({ log_name = log_name, prefix = CONFIG.LOG_PREFIX, enabled = debug_enabled, truncate = config.reset_log_on_start == true, log_dir = config.log_dir })
  local runtime_log = function(message, level) utils.log("MASTER", message, level or "INFO") end
  runtime_context.normalize_config(config)
  local release = build_info.get()
  runtime_log(("Master runtime fingerprint: build=%s manifest=%s/%s snapshot_ui_shape=module ui_shape_logs=enabled touch_dispatch_diag=enabled"):format(
    tostring(release.commit or release.version or "unknown"),
    tostring(release.manifest_id or "unknown"),
    tostring(release.manifest_version or "unknown")
  ), "INFO")

  local runtime = runtime_context.new_runtime({
    trends = trends_lib.new(600),
    -- Fix #2: node_offline_purge_after_ms aus config (DEFAULT_NODE_OFFLINE_PURGE_AFTER_S)
    node_offline_purge_after_ms = math.floor(
      (tonumber(config.node_offline_purge_after_s) or CONFIG.DEFAULT_NODE_OFFLINE_PURGE_AFTER_S or 120) * 1000
    )
  })
  runtime.config = config
  runtime.log = runtime_log
  -- Fix P1: rt_ops und profile_ops in libs, damit housekeeping.tick() sie findet
  runtime.libs = {
    constants        = constants,
    utils            = utils,
    health           = health,
    ui               = ui,
    profiles         = profiles,
    rt_sync          = rt_sync,
    rt_sync_coalescer = rt_sync_coalescer_lib,
    rt_ops           = rt_ops,
    profile_ops      = profile_ops
  }
  -- Global verfügbar machen damit message_handlers.lua darauf zugreifen kann
  _G.xreactor_runtime = runtime
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
    -- Fix P1/P6: housekeeping_tick jetzt als housekeeping.tick(runtime)
    housekeeping_tick = function() housekeeping.tick(runtime) end,
    ui_snapshot = function(event)
      -- Fix P1: ui_snapshot aus dem Lambda-Knäuel befreit
      return {
        event             = event and event[1] or "tick",
        monitors          = runtime.state.monitor_cache.list and #runtime.state.monitor_cache.list or 0,
        active_view       = runtime.refs.view_manager and runtime.refs.view_manager.active_key or "overview",
        node_count        = runtime_context.table_count(runtime.state.nodes),
        queue_depth       = runtime.refs.sequencer and #runtime.refs.sequencer.queue or 0,
        rt_sync_pending   = runtime.refs.rt_sync_coalescer and runtime.refs.rt_sync_coalescer.size() or 0,
        critical_blink    = runtime.state.critical_blink_until,
        trends            = runtime.state.last_trend_sample
      }
    end,
    ui_render = function()
      monitor_ops.refresh_monitors(runtime, false)
      if runtime.refs.ui_controller then
        runtime_context.warn_once(runtime.state, runtime.log, "ui_draw_started", "UI draw path active (ui_controller.draw)")
        local ok, draw_err = pcall(runtime.refs.ui_controller.draw)
        if not ok then
          runtime.log("UI draw failed: " .. tostring(draw_err), "ERROR")
        end

        local ui_models = runtime.refs.ui_controller and runtime.refs.ui_controller._last_models
        if ui_models and not runtime.state._steady_ui_shape_logged then
          local steady = ui_diagnostics.snapshot_shape(ui_models)
          runtime.state._steady_ui_shape_logged = true
          runtime.log(("Steady UI shape (first regular tick): ov_nodes=%d ov_hints=%d rt_nodes=%d rt_assign=%s en_matrices=%d en_support=%d"):format(
            steady.ov_nodes, steady.ov_hints, steady.rt_nodes, steady.rt_assign, steady.en_matrices, steady.en_support
          ), "INFO")
          local initial = runtime.state._initial_ui_shape
          if initial then
            local changed = (initial.ov_nodes ~= steady.ov_nodes) or (initial.rt_nodes ~= steady.rt_nodes) or (initial.en_matrices ~= steady.en_matrices) or (initial.en_support ~= steady.en_support)
            runtime.log(("UI shape consistency initial->steady: changed=%s | ov %d->%d | rt %d->%d | matrices %d->%d | support %d->%d"):format(
              tostring(changed), initial.ov_nodes, steady.ov_nodes, initial.rt_nodes, steady.rt_nodes, initial.en_matrices, steady.en_matrices, initial.en_support, steady.en_support
            ), changed and "WARN" or "INFO")
          end
        end

        if runtime.refs.view_manager and runtime.refs.view_manager.last_render_results then
          for _, r in ipairs(runtime.refs.view_manager.last_render_results) do
            if not r.ok then
              runtime.log(("UI draw failure detail: view=%s monitor=%s role=%s error=%s"):format(tostring(r.view), tostring(r.monitor), tostring(r.role), tostring(r.error)), "ERROR")
            end
          end
        end
      else
        runtime_context.warn_once(runtime.state, runtime.log, "ui_draw_missing_controller", "UI draw skipped: ui_controller missing")
      end
    end,
    ui_handle_input = function(event)
      if runtime.refs.ui_controller then
        runtime.refs.ui_controller.handle_input(event)
        if event and event[1] == "monitor_touch" and runtime.refs.view_manager and runtime.refs.view_manager.last_input then
          local li = runtime.refs.view_manager.last_input
          if li.hit or li.dispatch_error then
            runtime.log(("UI touch: monitor=%s pos=%s,%s view=%s hit=%s action=%s dispatched=%s handled=%s err=%s"):format(
              tostring(li.monitor or event[2] or "-"),
              tostring(li.x or event[3] or "-"),
              tostring(li.y or event[4] or "-"),
              tostring(li.view or "-"),
              tostring(li.hit and li.hit.type or "none"),
              tostring(li.action or "none"),
              tostring(li.dispatched),
              tostring(li.handled),
              tostring(li.dispatch_error or "-")
            ), "DEBUG")
          end
        end
      end
    end,
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
  if runtime.refs.services then
    runtime.log("Bootstrap UI/service tick trigger after init", "INFO")
    runtime.refs.services:tick()
    if runtime.refs.ui_controller and runtime.refs.ui_controller._last_models then
      runtime.state._initial_ui_shape = ui_diagnostics.snapshot_shape(runtime.refs.ui_controller._last_models)
      runtime.log(("Bootstrap UI shape: ov_nodes=%d ov_hints=%d rt_nodes=%d rt_assign=%s en_matrices=%d en_support=%d"):format(
        runtime.state._initial_ui_shape.ov_nodes, runtime.state._initial_ui_shape.ov_hints, runtime.state._initial_ui_shape.rt_nodes, runtime.state._initial_ui_shape.rt_assign, runtime.state._initial_ui_shape.en_matrices, runtime.state._initial_ui_shape.en_support
      ), "INFO")
    end
  end

  -- TEMPORÄR: Remote-Update-Auslöser per Redstone auf "top" des Master-PCs.
  -- Broadcastet REMOTE_UPDATE an alle bekannten Nodes (Master selbst nicht
  -- mitgezählt — der müsste sich getrennt selbst aktualisieren). Gedacht für
  -- die aktive Entwicklungsphase; kann später wieder entfernt werden.
  -- Steigende Flanke (false->true) löst aus, damit ein Dauersignal nicht
  -- endlos viele Updates auslöst.
  local last_redstone = { top=false, bottom=false, left=false, right=false, front=false, back=false }
  local REDSTONE_SIDES = { "top", "bottom", "left", "right", "front", "back" }
  local function broadcast_remote_update()
    runtime.log("Redstone-Trigger: broadcasting REMOTE_UPDATE an alle Nodes", "WARN")
    local known = runtime.state.nodes or {}
    local known_count = 0
    for _ in pairs(known) do known_count = known_count + 1 end
    if known_count == 0 then
      -- Fix: wenn der Trigger zu früh nach einem Boot kommt (noch keine Node
      -- hat sich registriert), würde "sent=0" geloggt und scheinbar nichts
      -- passieren — ohne klaren Hinweis warum. Das jetzt explizit sichtbar
      -- machen statt stillschweigend leer zu bleiben.
      runtime.log("Remote-Update: KEINE Nodes bekannt — Trigger zu frueh nach Boot? Bitte ~30s warten und erneut versuchen.", "ERROR")
    end
    local sent = 0
    for node_id, node in pairs(known) do
      local ok = pcall(function()
        runtime.refs.comms:send_command(node_id, { target = constants.command_targets.REMOTE_UPDATE })
      end)
      if ok then sent = sent + 1 end
    end
    runtime.log(("Remote-Update Broadcast an %d Node(s) gesendet (bekannt=%d)"):format(sent, known_count), "WARN")
    -- Fix: comms:send_command() legt die Nachricht nur in eine interne Queue,
    -- der tatsächliche Funk-Versand (modem.transmit) passiert erst beim
    -- nächsten services:tick() Aufruf. os.sleep() blockiert den gesamten
    -- Event-Loop und verhindert dass dieser Tick je läuft — die Broadcasts
    -- waren beim Reboot noch nie wirklich gesendet worden.
    -- Jetzt: Queue über mehrere echte Ticks aktiv leeren BEVOR geschlafen wird.
    runtime.log("Versende Broadcast-Queue...", "WARN")
    for _ = 1, 10 do
      runtime.refs.services:tick()
      if os and type(os.sleep) == "function" then os.sleep(0.1) end
    end
    -- Master aktualisiert sich danach selbst (kurze Verzögerung damit der
    -- Broadcast an alle anderen Nodes garantiert raus ist, bevor der Master
    -- selbst rebootet und damit das Funknetz kurzzeitig verliert).
    runtime.log("Master aktualisiert sich selbst...", "WARN")
    local remote_update = require("core.remote_update")
    remote_update.run(function(level, text) runtime.log(text, level) end)
  end

  local function check_redstone_update_trigger()
    if not redstone or type(redstone.getInput) ~= "function" then return end
    for _, side in ipairs(REDSTONE_SIDES) do
      local ok, current = pcall(redstone.getInput, side)
      if ok and current and not last_redstone[side] then
        broadcast_remote_update()
        for _, s in ipairs(REDSTONE_SIDES) do last_redstone[s] = true end
        return
      end
      if ok then last_redstone[side] = current and true or false end
    end
  end

  while true do
    local timer = os.startTimer(0.5)
    while true do
      local event = { os.pullEvent() }
      if event[1] == "modem_message" then runtime.refs.comms:handle_event(event)
      elseif event[1] == "monitor_touch" or event[1] == "key" or event[1] == "char" then runtime.refs.services:tick(nil, event)
      elseif event[1] == "redstone" then check_redstone_update_trigger()
      elseif event[1] == "timer" and event[2] == timer then break end
    end
    runtime.refs.services:tick()
  end
end

local function is_terminate_error(err)
  return tostring(err or ""):lower():find("terminate", 1, true) ~= nil
end

function M.run()
  local ok, err = xpcall(run_master, function(e) return e end)
  if ok then return end
  if is_terminate_error(err) then return end
  -- Fix #1: Crash-Screen mit Bestätigung + sauberer Neustart (wie Energy-Node).
  if term and term.setBackgroundColor and term.setTextColor and colors then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== MASTER CRASH ===")
    term.setTextColor(colors.white)
    print("")
    print(tostring(err))
    print("")
    term.setTextColor(colors.yellow)
    print("Druecke eine Taste um neu zu starten...")
    term.setTextColor(colors.white)
  else
    print("MASTER CRASH: " .. tostring(err))
    print("Druecke eine Taste um neu zu starten...")
  end
  pcall(os.pullEvent, "key")
  if os.reboot then os.reboot() end
end

return M