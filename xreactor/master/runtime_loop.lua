-- master/runtime_loop.lua
-- Orchestrierung: Bootstrap > Init > Event-Loop.

local M = {}

local function run_master()
  local bootstrap = dofile("/xreactor/core/bootstrap.lua")
  bootstrap.setup({ role = "master", log_enabled = false })
  local require = bootstrap.require

  local constants           = require("shared.constants")
  local utils               = require("core.utils")
  local health              = require("core.health")
  local monitor_manager     = require("core.monitor_manager")
  local build_info          = require("shared.build_info")
  local config              = require("master.config")
  -- Fix (2026-07-13): CRITICAL (GLOBAL-P0, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md). MASTER hatte bisher UEBERHAUPT
  -- KEINE Trennschicht zwischen Default- und Nutzerkonfiguration --
  -- master/config.lua wurde direkt per require() geladen, ist Teil des
  -- Manifests und wird bei jedem Auto-Update ueberschrieben. Jede
  -- manuelle Bearbeitung (Schwellwerte, Monitorkonfiguration) ging
  -- dadurch spaetestens beim naechsten Update-Zyklus verloren. Jetzt:
  -- eine geschuetzte Nutzerdatei (kein Manifest-Eintrag) wird -- falls
  -- vorhanden -- rekursiv ueber die Defaults gemergt. Einmalige
  -- Migration eines eventuell noch vorhandenen Standes beim ersten
  -- Boot mit diesem Fix.
  local MASTER_USER_CONFIG_PATH = "/xreactor/config/master.lua"
  if not fs.exists(MASTER_USER_CONFIG_PATH) then
    local ok_read, handle = pcall(fs.open, "/xreactor/master/config.lua", "r")
    if ok_read and handle then
      local content = handle.readAll()
      handle.close()
      local dir = fs.getDir(MASTER_USER_CONFIG_PATH)
      if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
      local ok_write, out = pcall(fs.open, MASTER_USER_CONFIG_PATH, "w")
      if ok_write and out then
        out.write(content)
        out.close()
        utils.log("MASTER", "Config-Migration: /xreactor/master/config.lua -> " .. MASTER_USER_CONFIG_PATH, "INFO")
      end
    end
  end
  if fs.exists(MASTER_USER_CONFIG_PATH) then
    local ok_user, user_cfg = pcall(dofile, MASTER_USER_CONFIG_PATH)
    if ok_user and type(user_cfg) == "table" then
      utils.merge_defaults(user_cfg, config)
      config = user_cfg
    end
  end
  local context             = require("master.context")
  local init_runtime        = require("master.init_runtime")
  local loop_mod            = require("master.loop")
  local trends_lib          = require("core.trends")
  local time                = require("core.time")
  local ui                  = require("core.ui")
  local rt_sync             = require("master.rt_sync")
  local rt_sync_coalescer_lib = require("master.rt_sync_coalescer")
  local housekeeping        = require("master.housekeeping")
  local monitor_ops         = require("master.runtime_ops_monitor")
  local profile_ops         = require("master.runtime_ops_profile")
  local rt_ops              = require("master.runtime_ops_rt")
  local fuel_relay           = require("master.fuel_relay")
  local message_handlers    = require("master.message_handlers")
  local profiles            = require("master.profiles")
  local sequencer_lib       = require("master.startup_sequencer")
  local overview_ui         = require("master.ui.overview")
  local rt_ui               = require("master.ui.rt_dashboard")
  local energy_ui           = require("master.ui.energy")
  local resources_ui        = require("master.ui.resources")
  local alarms_ui           = require("master.ui.alarms")
  local alerts_ui           = require("master.ui.alerts")
  local maintenance_ui      = require("master.ui.maintenance")
  local updates_ui          = require("master.ui.updates")
  local system_map_ui       = require("master.ui.system_map")
  local config_editor_ui    = require("master.ui.config_editor")
  local multiview_ui        = require("master.ui.multiview")
  local ui_controller_lib   = require("master.ui_controller")
  local ui_diagnostics      = require("master.ui_diagnostics")
  local service_manager     = require("services.service_manager")
  local comms_service       = require("services.comms_service")
  local alert_service_lib   = require("services.alert_service")
  local telemetry_service   = require("services.telemetry_service")
  local control_service     = require("services.control_service")
  local ui_service          = require("services.ui_service")

  -- Logger
  local node_id = utils.read_node_id("/xreactor/config/node_id.txt")
  context.normalize_config(config)
  utils.init_logger({ log_name = utils.build_log_name("master", node_id), prefix = "MASTER",
    enabled = config.debug_logging, truncate = config.reset_log_on_start == true, log_dir = config.log_dir })
  local function log(msg, level) utils.log("MASTER", msg, level or "INFO") end
  local release = build_info.get()
  log(("Fingerprint: build=%s manifest=%s/%s"):format(
    tostring(release.commit or release.version or "?"),
    tostring(release.manifest_id or "?"),
    tostring(release.manifest_version or "?")), "INFO")

  -- Runtime
  local runtime = context.new_runtime({
    trends = trends_lib.new(600),
    node_offline_purge_after_ms = math.floor((tonumber(config.node_offline_purge_after_s) or 120) * 1000)
  })
  runtime.config = config
  runtime.log    = log
  runtime.libs   = {
    constants = constants, utils = utils, health = health, ui = ui,
    profiles = profiles, rt_sync = rt_sync,
    rt_sync_coalescer = rt_sync_coalescer_lib,
    rt_ops = rt_ops, profile_ops = profile_ops, fuel_relay = fuel_relay
  }

  local function mark_rt_sync_dirty(node, reason)
    if runtime.refs.rt_sync_coalescer then runtime.refs.rt_sync_coalescer.mark_dirty(node, reason) end
  end
  local function flush_rt_sync_queue(opts)
    if runtime.refs.rt_sync_coalescer then runtime.refs.rt_sync_coalescer.flush(opts) end
  end
  runtime.mark_rt_sync_dirty  = mark_rt_sync_dirty
  runtime.flush_rt_sync_queue = flush_rt_sync_queue

  -- Init
  local recovery_status = bootstrap.get_recovery_status and bootstrap.get_recovery_status() or nil
  init_runtime.run({
    config = config, utils = utils, constants = constants, health = health,
    node_id = node_id, layout_config_path = runtime.tuning.layout_config_path,
    monitor_manager = monitor_manager, multiview_ui = multiview_ui,
    overview_ui = overview_ui, energy_ui = energy_ui, rt_ui = rt_ui,
    resources_ui = resources_ui, alerts_ui = alerts_ui, alarms_ui = alarms_ui,
    maintenance_ui = maintenance_ui, updates_ui = updates_ui, system_map_ui = system_map_ui,
    config_editor_ui = config_editor_ui,
    comms_service = comms_service, service_manager = service_manager,
    rt_sync_coalescer_lib = rt_sync_coalescer_lib, alert_service_lib = alert_service_lib,
    telemetry_service = telemetry_service, control_service = control_service,
    ui_service = ui_service, sequencer_lib = sequencer_lib,
    message_handlers = message_handlers, ui_controller_lib = ui_controller_lib,
    runtime_context = context, recovery_status = recovery_status,
    nodes = runtime.state.nodes, alarms = runtime.state.alarms,
    trends = runtime.refs.trends, trend_cache = runtime.state.trend_cache,
    monitor_cache = runtime.state.monitor_cache,
    rt_sync_batch_window_ms = runtime.tuning.rt_sync_batch_window_ms,
    refresh_monitors    = function(force) monitor_ops.refresh_monitors(runtime, force) end,
    update_node         = function(message) return runtime.refs.node_message_handler.update_node(message) end,
    sync_rt_node        = function(node, reason) rt_ops.sync_rt_node(runtime, node, reason) end,
    build_master_alert_payload = function() return housekeeping.build_master_alert_payload(runtime.refs.alert_service, config) end,
    housekeeping_tick   = function() housekeeping.tick(runtime) end,
    mark_rt_sync_dirty  = mark_rt_sync_dirty,
    add_alarm = function(sender, severity, msg)
      table.insert(runtime.state.alarms, 1, { sender_id = sender, severity = severity,
        message = msg, timestamp = context.master_time_label(time) })
      if #runtime.state.alarms > 50 then table.remove(runtime.state.alarms) end
    end,
    master_time_label   = function() return context.master_time_label(time) end,
    apply_profile       = function(name) profile_ops.apply_profile(runtime, name) end,
    set_auto_profile    = function(v) runtime.state.auto_profile = v end,
    get_auto_profile    = function() return runtime.state.auto_profile end,
    get_active_profile  = function() return runtime.state.active_profile end,
    get_power_target    = function() return runtime.state.power_target end,
    get_critical_blink_until = function() return runtime.state.critical_blink_until end,
    get_rt_global_off_hold   = function() return runtime.state.rt_global_off_hold end,
    set_rt_global_off_hold   = function(v) profile_ops.set_rt_global_hold(runtime, v) end,
    -- Feature (2026-07-02): Config-Editor am Monitor. Sendet SET_RESERVE/
    -- SET_TARGET Commands an ALLE FUEL/WATER-Nodes (analog zu
    -- set_reactor_fill_target unten) — bei mehreren Nodes derselben Rolle
    -- erhalten alle denselben Wert statt nur ein nicht-deterministisch
    -- ausgewaehlter erster Node. runtime.state.auto_update_enabled ist rein
    -- lokal (kein Command noetig, jeder Node liest sein eigenes
    -- config/remote_update.lua — echtes Verteilen dieser Einstellung an
    -- alle Nodes ist eine spaetere Erweiterung).
    set_fuel_reserve = function(amount)
      local sent_count = 0
      for id, node in pairs(runtime.state.nodes or {}) do
        if node.role == constants.roles.FUEL_NODE then
          runtime.refs.comms:send_command(id, { target = constants.command_targets.SET_RESERVE, value = amount })
          sent_count = sent_count + 1
        end
      end
      if sent_count == 0 then return false, "kein FUEL-Node gefunden" end
      return true, sent_count
    end,
    set_water_target = function(amount)
      local sent_count = 0
      for id, node in pairs(runtime.state.nodes or {}) do
        if node.role == constants.roles.WATER_NODE then
          runtime.refs.comms:send_command(id, { target = constants.command_targets.SET_TARGET, value = amount })
          sent_count = sent_count + 1
        end
      end
      if sent_count == 0 then return false, "kein WATER-Node gefunden" end
      return true, sent_count
    end,
    -- Feature (2026-07-06): Zielwert (0.0-1.0) fuer den internen Dampf-
    -- Fuellstand bei individueller Pro-Reaktor-Regelung. Wie
    -- set_fuel_reserve/set_water_target oben wird dieser Wert an ALLE
    -- passenden Nodes gesendet — es koennen mehrere unabhaengige
    -- RT-Nodes existieren, von denen mehrere jeweils >1 Reaktor haben
    -- koennten, und alle sollen denselben Zielwert nutzen.
    set_reactor_fill_target = function(value)
      local sent_count = 0
      for id, node in pairs(runtime.state.nodes or {}) do
        if node.role == constants.roles.RT_NODE then
          runtime.refs.comms:send_command(id, { target = "SET_REACTOR_FILL_TARGET", value = value })
          sent_count = sent_count + 1
        end
      end
      if sent_count == 0 then return false, "kein RT-Node gefunden" end
      return true, sent_count
    end,
    get_auto_update_enabled = function() return runtime.state.auto_update_enabled ~= false end,
    set_auto_update_enabled = function(v) runtime.state.auto_update_enabled = v end,
    last_draw = runtime.state.last_draw, refs = runtime.refs,
    ui_snapshot = function(event)
      return {
        event = event and event[1] or "tick",
        monitors = runtime.state.monitor_cache.list and #runtime.state.monitor_cache.list or 0,
        active_view = runtime.refs.view_manager and runtime.refs.view_manager.active_key or "overview",
        node_count = context.table_count(runtime.state.nodes),
        queue_depth = runtime.refs.sequencer and #runtime.refs.sequencer.queue or 0,
        rt_sync_pending = runtime.refs.rt_sync_coalescer and runtime.refs.rt_sync_coalescer.size() or 0,
        critical_blink = runtime.state.critical_blink_until,
        trends = runtime.state.last_trend_sample
      }
    end,
    ui_render = function()
      monitor_ops.refresh_monitors(runtime, false)
      if runtime.refs.ui_controller then
        context.warn_once(runtime.state, log, "ui_draw_started", "UI draw active")
        local ok2, draw_err = pcall(runtime.refs.ui_controller.draw)
        if not ok2 then log("UI draw failed: " .. tostring(draw_err), "ERROR") end
        local ui_models = runtime.refs.ui_controller._last_models
        if ui_models and not runtime.state._steady_ui_shape_logged then
          runtime.state._steady_ui_shape_logged = true
          local s = ui_diagnostics.snapshot_shape(ui_models)
          log(("Steady UI: ov=%d rt=%d en=%d"):format(s.ov_nodes, s.rt_nodes, s.en_matrices), "INFO")
        end
      else
        context.warn_once(runtime.state, log, "ui_draw_missing", "UI draw skipped")
      end
    end,
    ui_handle_input = function(event)
      if runtime.refs.ui_controller then runtime.refs.ui_controller.handle_input(event) end
    end,
  })

  log(("Refs: comms=%s services=%s ui=%s"):format(
    tostring(runtime.refs.comms ~= nil),
    tostring(runtime.refs.services ~= nil),
    tostring(runtime.refs.ui_controller ~= nil)), "INFO")

  -- Startup-Diagnose-Report (Kernfunktion, 2026-07-01): siehe
  -- xreactor/core/startup_report.lua.
  local ok_report_mod, report_mod = pcall(require, "core.startup_report")
  if ok_report_mod then
    pcall(function()
      local checks = { report_mod.check_wireless_modem() }
      checks[#checks + 1] = { name = "Comms initialisiert", ok = runtime.refs.comms ~= nil }
      checks[#checks + 1] = { name = "Services initialisiert", ok = runtime.refs.services ~= nil }
      checks[#checks + 1] = { name = "UI initialisiert", ok = runtime.refs.ui_controller ~= nil }
      checks[#checks + 1] = { name = "Monitor(e) gefunden",
        ok = runtime.state.monitor_cache and runtime.state.monitor_cache.list and #runtime.state.monitor_cache.list > 0 }
      -- Speaker-Instanz wiederverwenden, falls alert_service bereits eine
      -- erstellt hat (2026-07-02) — vermeidet doppelte Speaker-Peripheral-
      -- Suche und stellt sicher, dass Startup-Sound und Alarm-Sound
      -- konsistent dieselbe Instanz nutzen.
      local speaker = runtime.refs.alert_service and runtime.refs.alert_service.speaker_alarm or nil
      report_mod.run(checks, { log = log, speaker = speaker })
    end)
  end

  monitor_ops.refresh_monitors(runtime, true)
  if runtime.refs.services then runtime.refs.services:tick() end

  -- runtime an message_handler übergeben (kein _G)
  if runtime.refs.node_message_handler
      and type(runtime.refs.node_message_handler.set_runtime) == "function" then
    runtime.refs.node_message_handler.set_runtime(runtime)
  end

  loop_mod.run(runtime, constants)
end

local function is_terminate(err)
  return tostring(err or ""):lower():find("terminate", 1, true) ~= nil
end

function M.run()
  local ok, err = xpcall(run_master, function(e) return e end)
  if ok or is_terminate(err) then return end
  -- Fix (2026-07-13): CRITICAL (SHARED-P0.2, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md). Vorher eigenes, dupliziertes
  -- Crash-Handling hier, das UNBEGRENZT auf einen physischen Tastendruck
  -- wartete, bevor ueberhaupt rebootet wurde. Jetzt: dieselbe bereits
  -- fuer FUEL/WATER/REPROCESSOR/RT/ENERGY/LOG_COLLECTOR bewaehrte Logik
  -- (begrenzte Wartezeit, automatischer Reboot, Crash-Loop-Erkennung)
  -- wiederverwendet. dofile() statt require(), da die Bootstrap-
  -- konfigurierte require-Funktion nur innerhalb von run_master()
  -- lokal verfuegbar ist, nicht hier auf M.run()-Ebene.
  local ok_mod, support_runtime = pcall(dofile, "/xreactor/nodes/support/runtime.lua")
  if ok_mod and support_runtime and support_runtime.crash_screen then
    support_runtime.crash_screen(err)
    return
  end
  -- Fallback, falls das Shared-Modul selbst nicht geladen werden kann --
  -- besser ein einfacher, aber trotzdem NICHT unbegrenzt wartender
  -- Crash-Screen als ein komplett unbeaufsichtigter Haenger.
  if term and term.setTextColor and colors then
    term.setBackgroundColor(colors.black); term.setTextColor(colors.red)
    term.clear(); term.setCursorPos(1, 1)
    print("=== MASTER CRASH ==="); print("")
    term.setTextColor(colors.white); print(tostring(err)); print("")
    term.setTextColor(colors.yellow); print("Automatischer Neustart in 20s, oder Taste druecken...")
    term.setTextColor(colors.white)
  else
    print("MASTER CRASH: " .. tostring(err))
  end
  pcall(function()
    local timer_id = os.startTimer(20)
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "key" or (ev[1] == "timer" and ev[2] == timer_id) then return end
    end
  end)
  if os.reboot then os.reboot() end
end

return M
