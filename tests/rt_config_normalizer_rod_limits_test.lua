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
      regulator_min_rods = 80,
      regulator_max_rods = 98,
      reactor_adjust_interval = 5,
      steam_reserve = 5000,
      steam_deficit = 5000
    },
    rails = {
      reactor_rods = {
        min = 80,
        max = 98
      }
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

  local warnings = run(cfg)

  assert_eq(cfg.autonom.regulator_min_rods, 40, "legacy min_rods must map to regulator_min_rods")
  assert_eq(cfg.autonom.regulator_max_rods, 85, "legacy max_rods must map to regulator_max_rods")
  assert_true(table.concat(warnings, "\n"):find("deprecated", 1, true) ~= nil,
    "legacy fallback should emit deprecation warning")
end

local function test_regulator_fields_override_legacy_aliases()
  local cfg = mk_defaults()
  cfg.autonom.regulator_min_rods = 60
  cfg.autonom.regulator_max_rods = 80
  cfg.autonom.min_rods = 40
  cfg.autonom.max_rods = 90

  local warnings = run(cfg)

  assert_eq(cfg.autonom.regulator_min_rods, 60, "explicit regulator_min_rods must stay authoritative")
  assert_eq(cfg.autonom.regulator_max_rods, 80, "explicit regulator_max_rods must stay authoritative")
  local warning_blob = table.concat(warnings, "\n")
  assert_true(warning_blob:find("autonom.min_rods deprecated and ignored", 1, true) ~= nil,
    "conflicting legacy min should log ignored warning")
  assert_true(warning_blob:find("autonom.max_rods deprecated and ignored", 1, true) ~= nil,
    "conflicting legacy max should log ignored warning")
end

local function test_rails_caps_backfill_missing_regulator_caps()
  local cfg = mk_defaults()
  cfg.autonom.regulator_min_rods = nil
  cfg.autonom.regulator_max_rods = nil
  cfg.rails.reactor_rods.min = 83
  cfg.rails.reactor_rods.max = 96

  local warnings = run(cfg)

  assert_eq(cfg.autonom.regulator_min_rods, 83, "missing regulator_min_rods must be backfilled from rails.reactor_rods.min")
  assert_eq(cfg.autonom.regulator_max_rods, 96, "missing regulator_max_rods must be backfilled from rails.reactor_rods.max")
  local warning_blob = table.concat(warnings, "\n")
  assert_true(warning_blob:find("mapped from rails.reactor_rods.min", 1, true) ~= nil,
    "rails->autonom min mapping should emit explicit warning")
  assert_true(warning_blob:find("mapped from rails.reactor_rods.max", 1, true) ~= nil,
    "rails->autonom max mapping should emit explicit warning")
end

test_range_clamp_and_swap()
test_legacy_alias_fallback()
test_regulator_fields_override_legacy_aliases()
test_rails_caps_backfill_missing_regulator_caps()

print("rt_config_normalizer_rod_limits_test.lua: ok")
