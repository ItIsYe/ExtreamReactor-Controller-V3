local CONFIG = {
  DEFAULT_WIRELESS_MODEM = nil,
  DEFAULT_WIRED_MODEM = nil,
  DEFAULT_MONITORS = { "back" },
  DEFAULT_MASTER_MIN_MONITOR_WIDTH = 48,
  DEFAULT_MASTER_MIN_MONITOR_HEIGHT = 27,
  DEFAULT_HEARTBEAT_INTERVAL = 5,
  DEFAULT_STATUS_INTERVAL = 5,
  DEFAULT_STARTUP_RAMP = "NORMAL",
  DEFAULT_STARTUP_STAGE_TIMEOUT = 60,
  DEFAULT_RT_MODE = "MASTER",
  DEFAULT_TARGET_RPM = 900,
  DEFAULT_ALERT_EVAL_INTERVAL = 1.0,
  DEFAULT_ALERT_HISTORY_SIZE = 200,
  DEFAULT_ALERT_INFO_TTL = 20,
  DEFAULT_ALERT_RAISE_AFTER_S = 2.0,
  DEFAULT_ALERT_CLEAR_AFTER_S = 3.0,
  DEFAULT_ALERT_COOLDOWN_S = 6.0,
  DEFAULT_COMMS_DOWN_WARN_SECS = 2,
  DEFAULT_COMMS_DOWN_CRIT_SECS = 12,
  DEFAULT_ENERGY_WARN_PCT = 25,
  DEFAULT_ENERGY_CRIT_PCT = 15,
  DEFAULT_MATRIX_WARN_FULL_PCT = 90,
  DEFAULT_RPM_WARN_LOW = 800,
  DEFAULT_RPM_CRIT_HIGH = 1800,
  DEFAULT_ROD_STUCK_SECS = 20,
  DEFAULT_STEAM_DEFICIT_PCT = 0.9,
  DEFAULT_ALERT_MUTE_DEFAULT_MINUTES = 10,
  DEFAULT_ALERT_MUTE_DURATIONS = { 5, 15, 30, 60 },
  DEFAULT_ALERT_LOG_MUTED_EVENTS = true,
  DEFAULT_ALERT_STATE_PATH = "/xreactor/config/alerts_state.lua",
  DEFAULT_ALERT_NODE_TOP_N = 3,
  DEFAULT_COMMS_CHANNEL = 6500,
  DEFAULT_STATUS_CHANNEL = 6501,
  DEFAULT_COMMS_ACK_TIMEOUT = 3.0,
  DEFAULT_COMMS_MAX_RETRIES = 4,
  DEFAULT_COMMS_BACKOFF_BASE = 0.6,
  DEFAULT_COMMS_BACKOFF_CAP = 6.0,
  DEFAULT_COMMS_DEDUPE_TTL = 30,
  DEFAULT_COMMS_DEDUPE_LIMIT = 200,
  DEFAULT_COMMS_PEER_TIMEOUT = 30.0,
  DEFAULT_NODE_OFFLINE_PURGE_AFTER_S = 120,    -- Sekunden bis ein offline Node aus dem managed-Set entfernt wird.
  DEFAULT_SEQUENCER_SCRAM_TEMPERATURE = 950,   -- °C ab der Sequencer-Timeout als EMERGENCY gilt
  DEFAULT_COMMS_PEER_DOWN_GRACE = 5.0,
  DEFAULT_COMMS_PEER_DOWN_MIN_OBSERVATIONS = 2,
  DEFAULT_COMMS_PEER_UP_DEBOUNCE = 1.5,
  DEFAULT_COMMS_PEER_UP_MIN_OBSERVATIONS = 2,
  DEFAULT_COMMS_QUEUE_LIMIT = 200,
  DEFAULT_COMMS_DROP_SIMULATION = 0,
  DEFAULT_LOG_DIR = "/disk/xreactor_logs",
  DEFAULT_RAILS = {
    ramp_profiles = {
      NORMAL = { up = 1.0, down = 1.0 },
      SLOW = { up = 0.5, down = 0.5 },
      FAST = { up = 1.5, down = 1.5 }
    },
    turbine_flow = {
      deadband_up = 20,
      deadband_down = 20,
      hysteresis_up = 10,
      hysteresis_down = 10,
      max_step_up = 50,
      max_step_down = 50,
      cooldown_s = 1.0,
      min = 200,
      max = 1900,
      ema_alpha = 0.2
    },
    reactor_rods = {
      deadband_up = 5000,
      deadband_down = 5000,
      hysteresis_up = 500,
      hysteresis_down = 500,
      max_step_up = 5,
      max_step_down = 5,
      cooldown_s = 1.5,
      min = 0,
      max = 98,
      ema_alpha = 0.25
    },
    coil = {
      engage_rpm = 850,
      disengage_rpm = 750,
      cooldown_s = 1.0,
      ema_alpha = 0.2
    }
  },
  DEFAULT_DEBUG_LOGGING = true,
  DEFAULT_RESET_LOG_ON_START = true
}

local constants = require("shared.constants")
local CURRENT_VERSION = 3

return {
  version = CURRENT_VERSION,
  role = constants.roles.MASTER,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  wired_modem = CONFIG.DEFAULT_WIRED_MODEM,
  monitors = CONFIG.DEFAULT_MONITORS,
  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  status_interval = CONFIG.DEFAULT_STATUS_INTERVAL,
  startup_ramp = CONFIG.DEFAULT_STARTUP_RAMP,
  startup_stage_timeout_s = CONFIG.DEFAULT_STARTUP_STAGE_TIMEOUT,
  rt_default_mode = CONFIG.DEFAULT_RT_MODE,
  -- Fix (2026-07-07): CRITICAL. monitor_scale/ui_scale_default waren beide
  -- fest auf 1.0 gesetzt. Laut compute_auto_scale()-Doku in
  -- core/monitor_manager.lua ist die automatische, groessenabhaengige
  -- Skalierung (v328) NUR aktiv "wenn KEINE feste Skala explizit
  -- uebergeben wurde" — init_runtime.lua reicht aber IMMER einen Wert
  -- durch (erst monitor_scale, sonst ui_scale_default als Fallback), und
  -- beide waren nie nil. Das bedeutet: die Auto-Skalierung war seit v328
  -- fuer JEDEN Master standardmaessig komplett deaktiviert, jeder Monitor
  -- (auch kleine 1-Block-AUX-Displays) bekam pauschal Skala 1.0 — zu grobe
  -- Schrift, Inhalte wurden auf kleinen Monitoren abgeschnitten ("~").
  -- Jetzt nil, damit compute_auto_scale() tatsaechlich greift; wer eine
  -- feste Skala will, kann sie weiterhin explizit in der eigenen
  -- config/master.lua setzen.
  monitor_scale = nil,
  ui_scale_default = nil,
  master_min_monitor_width = CONFIG.DEFAULT_MASTER_MIN_MONITOR_WIDTH,
  master_min_monitor_height = CONFIG.DEFAULT_MASTER_MIN_MONITOR_HEIGHT,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  reset_log_on_start = CONFIG.DEFAULT_RESET_LOG_ON_START,
  log_dir = CONFIG.DEFAULT_LOG_DIR,
  alert_eval_interval = CONFIG.DEFAULT_ALERT_EVAL_INTERVAL,
  alert_history_size = CONFIG.DEFAULT_ALERT_HISTORY_SIZE,
  alert_info_ttl = CONFIG.DEFAULT_ALERT_INFO_TTL,
  alert_raise_after_s = CONFIG.DEFAULT_ALERT_RAISE_AFTER_S,
  alert_clear_after_s = CONFIG.DEFAULT_ALERT_CLEAR_AFTER_S,
  alert_debounce_s = CONFIG.DEFAULT_ALERT_RAISE_AFTER_S,
  alert_clear_s = CONFIG.DEFAULT_ALERT_CLEAR_AFTER_S,
  alert_cooldown_s = CONFIG.DEFAULT_ALERT_COOLDOWN_S,
  alert_mute_default_minutes = CONFIG.DEFAULT_ALERT_MUTE_DEFAULT_MINUTES,
  alert_mute_durations = CONFIG.DEFAULT_ALERT_MUTE_DURATIONS,
  alert_log_muted_events = CONFIG.DEFAULT_ALERT_LOG_MUTED_EVENTS,
  alert_state_path = CONFIG.DEFAULT_ALERT_STATE_PATH,
  alert_node_top_n = CONFIG.DEFAULT_ALERT_NODE_TOP_N,
  comms_down_warn_secs = CONFIG.DEFAULT_COMMS_DOWN_WARN_SECS,
  comms_down_crit_secs = CONFIG.DEFAULT_COMMS_DOWN_CRIT_SECS,
  energy_warn_pct = CONFIG.DEFAULT_ENERGY_WARN_PCT,
  energy_crit_pct = CONFIG.DEFAULT_ENERGY_CRIT_PCT,
  matrix_warn_full_pct = CONFIG.DEFAULT_MATRIX_WARN_FULL_PCT,
  rpm_warn_low = CONFIG.DEFAULT_RPM_WARN_LOW,
  rpm_crit_high = CONFIG.DEFAULT_RPM_CRIT_HIGH,
  rod_stuck_secs = CONFIG.DEFAULT_ROD_STUCK_SECS,
  steam_deficit_pct = CONFIG.DEFAULT_STEAM_DEFICIT_PCT,
  channels = { control = CONFIG.DEFAULT_COMMS_CHANNEL, status = CONFIG.DEFAULT_STATUS_CHANNEL },
  comms = {
    ack_timeout_s = CONFIG.DEFAULT_COMMS_ACK_TIMEOUT,
    max_retries = CONFIG.DEFAULT_COMMS_MAX_RETRIES,
    backoff_base_s = CONFIG.DEFAULT_COMMS_BACKOFF_BASE,
    backoff_cap_s = CONFIG.DEFAULT_COMMS_BACKOFF_CAP,
    dedupe_ttl_s = CONFIG.DEFAULT_COMMS_DEDUPE_TTL,
    dedupe_limit = CONFIG.DEFAULT_COMMS_DEDUPE_LIMIT,
    peer_timeout_s = CONFIG.DEFAULT_COMMS_PEER_TIMEOUT,
    peer_down_grace_s = CONFIG.DEFAULT_COMMS_PEER_DOWN_GRACE,
    peer_down_min_observations = CONFIG.DEFAULT_COMMS_PEER_DOWN_MIN_OBSERVATIONS,
    peer_up_debounce_s = CONFIG.DEFAULT_COMMS_PEER_UP_DEBOUNCE,
    peer_up_min_observations = CONFIG.DEFAULT_COMMS_PEER_UP_MIN_OBSERVATIONS,
    queue_limit = CONFIG.DEFAULT_COMMS_QUEUE_LIMIT,
    drop_simulation = CONFIG.DEFAULT_COMMS_DROP_SIMULATION
  },
  rt_setpoints = {
    target_rpm = CONFIG.DEFAULT_TARGET_RPM,
    enable_reactors = true,
    enable_turbines = true
  },
  rails = CONFIG.DEFAULT_RAILS,
  nodes = {
    [constants.roles.RT_NODE] = {},
    [constants.roles.ENERGY_NODE] = {},
    [constants.roles.FUEL_NODE] = {},
    [constants.roles.WATER_NODE] = {},
    [constants.roles.REPROCESSOR_NODE] = {}
  }
}