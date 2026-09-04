-- master/context.lua
-- Runtime-Context für den Master.
-- Kein _G.xreactor_runtime — Runtime wird als Parameter übergeben.

local M = {}

local function clamp(v, fb, mn, mx)
  local n = tonumber(v); if not n or n <= 0 then n = fb end
  if mn and n < mn then n = mn end
  if mx and n > mx then n = mx end
  return n
end

function M.normalize_config(config)
  config.heartbeat_interval = clamp(config.heartbeat_interval, 5, 1, 60)
  config.status_interval = clamp(config.status_interval or config.heartbeat_interval, config.heartbeat_interval, 1, 60)
  config.rt_default_mode = config.rt_default_mode or "MASTER"
  config.rt_setpoints = config.rt_setpoints or {}
  config.rt_setpoints.target_rpm = config.rt_setpoints.target_rpm or 900
  if config.rt_setpoints.enable_reactors == nil then config.rt_setpoints.enable_reactors = true end
  if config.rt_setpoints.enable_turbines == nil then config.rt_setpoints.enable_turbines = true end
  config.startup_stage_timeout_s = clamp(config.startup_stage_timeout_s or 60, 60, 5, 600)
  config.alert_eval_interval   = clamp(config.alert_eval_interval or 1, 1, 0.5, 5)
  config.alert_history_size    = math.floor(clamp(config.alert_history_size or 200, 200, 10, 1000))
  config.alert_info_ttl        = clamp(config.alert_info_ttl or 20, 20, 5, 600)
  config.alert_raise_after_s   = clamp(config.alert_raise_after_s or config.alert_debounce_s or 2, 2, 0, 30)
  config.alert_clear_after_s   = clamp(config.alert_clear_after_s or config.alert_clear_s or 3, 3, 0, 60)
  config.alert_debounce_s      = config.alert_raise_after_s
  config.alert_clear_s         = config.alert_clear_after_s
  config.alert_cooldown_s      = clamp(config.alert_cooldown_s or 6, 6, 0, 120)
  config.comms_down_warn_secs  = clamp(config.comms_down_warn_secs or 2, 2, 1, 120)
  config.comms_down_crit_secs  = clamp(config.comms_down_crit_secs or 12, 12, config.comms_down_warn_secs, 300)
  local function cpct(v, fb)
    local n = tonumber(v); if not n then n = fb end
    if n < 0 then n = 0 end; if n > 100 then n = 100 end; return n
  end
  config.energy_warn_pct       = cpct(config.energy_warn_pct, 25)
  config.energy_crit_pct       = cpct(config.energy_crit_pct, 15)
  if config.energy_crit_pct > config.energy_warn_pct then config.energy_crit_pct = config.energy_warn_pct end
  config.matrix_warn_full_pct  = cpct(config.matrix_warn_full_pct, 90)
  config.rpm_warn_low          = clamp(config.rpm_warn_low  or 800,  800,  0, 5000)
  config.rpm_crit_high         = clamp(config.rpm_crit_high or 1800, 1800, 0, 10000)
  if config.rpm_crit_high < config.rpm_warn_low then config.rpm_crit_high = config.rpm_warn_low end
  config.rod_stuck_secs        = clamp(config.rod_stuck_secs or 20, 20, 1, 300)
  local function cratio(v, fb)
    local n = tonumber(v); if not n then n = fb end
    if n < 0 then n = 0 end; if n > 1 then n = 1 end; return n
  end
  config.steam_deficit_pct     = cratio(config.steam_deficit_pct, 0.9)
  config.alert_mute_default_minutes = math.floor(clamp(config.alert_mute_default_minutes or 10, 10, 1, 1440))
  config.alert_node_top_n      = math.floor(clamp(config.alert_node_top_n or 3, 3, 1, 10))
  if type(config.alert_mute_durations) ~= "table" then config.alert_mute_durations = { 5, 15, 30, 60 } end
  local durations = {}
  for _, e in ipairs(config.alert_mute_durations) do
    local v = math.floor(clamp(e, e, 1, 1440)); if v > 0 then durations[v] = true end
  end
  config.alert_mute_durations = {}
  for v in pairs(durations) do table.insert(config.alert_mute_durations, v) end
  table.sort(config.alert_mute_durations)
  config.alert_log_muted_events = config.alert_log_muted_events == nil and true or config.alert_log_muted_events
  config.alert_state_path = type(config.alert_state_path) == "string"
    and config.alert_state_path or "/xreactor/config/alerts_state.lua"
  return config
end

function M.new_state()
  return {
    monitor_cache = {}, nodes = {}, alarms = {}, warned = {},
    power_target = 0, active_profile = "BASELOAD", auto_profile = true,
    rt_global_off_hold = false, critical_blink_until = 0, last_draw = 0,
    monitor_scan_last = 0, last_trend_sample = 0,
    trend_cache = { energy = {}, energy_arrow = ">" }
  }
end

function M.new_runtime(opts)
  local state = (opts and opts.state) or M.new_state()
  return {
    state = state,
    refs = {
      monitor_mgr = nil, view_manager = nil, alert_service = nil,
      sequencer = nil, comms = nil, services = nil, ui_controller = nil,
      rt_sync_coalescer = nil, node_message_handler = nil,
      trends = (opts and opts.trends) or nil,
    },
    tuning = {
      layout_config_path = (opts and opts.layout_config_path) or "/xreactor/config/master_ui_layout.json",
      node_offline_purge_after_ms = (opts and opts.node_offline_purge_after_ms) or 120000,
      rt_sync_batch_window_ms = (opts and opts.rt_sync_batch_window_ms) or 250,
      rt_shutdown_candidate_stability_ms = (opts and opts.rt_shutdown_candidate_stability_ms) or 1500,
    }
  }
end

function M.warn_once(state, log_fn, key, message)
  state.warned = state.warned or {}
  if state.warned[key] then return end
  state.warned[key] = true; log_fn(message)
end

function M.table_count(tbl)
  local count = 0; for _ in pairs(tbl or {}) do count = count + 1 end; return count
end

function M.master_time_label(time)
  return time.wall_clock_hms_utc()
end

return M
