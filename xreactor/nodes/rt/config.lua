local CURRENT_VERSION = 3

return {
  version = CURRENT_VERSION,
  role = "RT-NODE",
  node_id = "RT-1",
  debug_logging = true,
  reset_log_on_start = true,

  wireless_modem = nil,
  wired_modem = nil,
  modem = nil,

  reactors = {},
  turbines = {},

  heartbeat_interval = 2,
  status_interval = 5,
  scan_interval = 10,
  startup_watchdog_s = 60,

  channels = {
    control = 6500,
    status = 6501
  },

  comms = {
    ack_timeout_s = 3.0,
    max_retries = 4,
    backoff_base_s = 0.6,
    backoff_cap_s = 6.0,
    dedupe_ttl_s = 30,
    dedupe_limit = 200,
    peer_timeout_s = 12.0,
    queue_limit = 200,
    drop_simulation = 0
  },

  safety = {
    max_temperature = 2000,
    temperature_hysteresis = 50,
    temperature_trip_samples = 2,
    max_rpm = 1800,
    min_water = 0.2,
    coolant_hysteresis = 0.05,
    coolant_trip_samples = 3,
    coolant_invalid_grace_samples = 3
  },

  autonom = {
    control_rod_level = 70,
    max_rpm = 900,
    min_flow = 0,
    max_flow = 2000,
    flow_step = 50,
    ramp_step = 50,
    regulator_min_rods = 80,
    regulator_max_rods = 98,
    reactor_adjust_interval = 5.0,
    steam_reserve = 5000,
    steam_deficit = 5000
  },

  rails = {
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
      max_step_up = 250,
      max_step_down = 250,
      min_step_up = 50,
      min_step_down = 50,
      step_per_rpm_up = 0.5,
      step_per_rpm_down = 0.5,
      adaptive_step = true,
      cooldown_s = 0.2,
      settle_timeout_s = 0.8,
      confirm_tolerance = 1,
      readback_retry_cap = 3,
      readback_fast_rereads = 2,
      effective_min_samples = 3,
      target_hold_band_rpm = 30,
      target_trim_trigger_rpm = 6,
      target_trim_hold_samples = 2,
      target_trim_step_up = 50,
      target_trim_step_down = 75,
      min = 0,
      max = 2000,
      ema_alpha = 0.2
    },
    reactor_rods = {
      deadband_up = 5000,
      deadband_down = 5000,
      hysteresis_up = 500,
      hysteresis_down = 500,
      max_step_up = 5,
      max_step_down = 5,
      max_apply_step_up = 5,
      max_apply_step_down = 5,
      cooldown_s = 1.5,
      apply_cooldown_s = 1.5,
      coolant_ramp_soft_limit_ratio = 0.28,
      coolant_ramp_hard_limit_ratio = 0.22,
      max_step_down_when_coolant_soft = 2,
      max_step_down_when_coolant_hard = 0,
      min = 80,
      max = 98,
      ema_alpha = 0.25
    },
    reactor_steam_guard = {
      enabled = true,
      high_ratio = 0.82,
      high_release_ratio = 0.74,
      critical_ratio = 0.92,
      critical_release_ratio = 0.86,
      force_close_step = 2,
      ema_alpha = 0.20
    },
    coil = {
      engage_rpm = 850,
      disengage_rpm = 750,
      cooldown_s = 1.0,
      ema_alpha = 0.2
    }
  },

  monitor_interval = 2,
  monitor_scale = 0.5,
  status_log = false
}
