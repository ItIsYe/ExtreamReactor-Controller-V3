package.path = package.path .. ";/workspace/ExtreamReactor-Controller-V3/?.lua"

local normalizer = dofile("/workspace/ExtreamReactor-Controller-V3/xreactor/nodes/rt/config_normalizer.lua")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq failed") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then
    error(message or "assert_true failed")
  end
end

local function mk_defaults()
  return {
    node_id = "RT-1",
    role = "RT-NODE",
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
    channels = { control = 6500, status = 6501 },
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
      min_rods = 0,
      max_rods = 98,
      regulator_min_rods = 0,
      regulator_max_rods = 98,
      reactor_adjust_interval = 5,
      steam_reserve = 5000,
      steam_deficit = 5000
    },
    monitor_interval = 2,
    monitor_scale = 0.5,
    status_log = false,
    comms = {}
  }
end

local utils
utils = {
  normalize_node_id = function(value)
    if type(value) == "string" and value ~= "" then
      return value
    end
    return "UNKNOWN"
  end,
  deep_copy = function(value)
    if type(value) ~= "table" then
      return value
    end
    local out = {}
    for key, item in pairs(value) do
      out[key] = utils.deep_copy(item)
    end
    return out
  end
}

local function run(cfg)
  local defaults = mk_defaults()
  local warnings = {}
  normalizer.validate_config(cfg, defaults, function(message)
    table.insert(warnings, message)
  end, utils)
  return warnings
end

local function test_range_clamp_and_swap()
  local cfg = mk_defaults()
  cfg.autonom.regulator_min_rods = -25
  cfg.autonom.regulator_max_rods = 140
  local warnings = run(cfg)
  assert_eq(cfg.autonom.regulator_min_rods, 0, "min must clamp to 0")
  assert_eq(cfg.autonom.regulator_max_rods, 100, "max must clamp to 100")
  assert_true(#warnings >= 2, "out-of-range values must produce warnings")

  cfg = mk_defaults()
  cfg.autonom.regulator_min_rods = 90
  cfg.autonom.regulator_max_rods = 30
  run(cfg)
  assert_eq(cfg.autonom.regulator_min_rods, 30, "inverted limits must be normalized")
  assert_eq(cfg.autonom.regulator_max_rods, 90, "inverted limits must be normalized")
end

local function test_legacy_alias_fallback()
  local cfg = mk_defaults()
  cfg.autonom.regulator_min_rods = nil
  cfg.autonom.regulator_max_rods = nil
  cfg.autonom.min_rods = 40
  cfg.autonom.max_rods = 85

  run(cfg)

  assert_eq(cfg.autonom.regulator_min_rods, 40, "legacy min_rods must map to regulator_min_rods")
  assert_eq(cfg.autonom.regulator_max_rods, 85, "legacy max_rods must map to regulator_max_rods")
end

test_range_clamp_and_swap()
test_legacy_alias_fallback()

print("rt_config_normalizer_rod_limits_test.lua: ok")
