
local normalizer = dofile("xreactor/nodes/rt/config_normalizer.lua")
local defaults = dofile("xreactor/nodes/rt/config.lua")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq failed") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = deep_copy(item)
  end
  return out
end

local cfg = {
  safety = {},
  autonom = {
    max_rpm = 800,
    min_flow = -10,
    max_flow = 9000,
    flow_step = nil,
    ramp_step = nil
  },
  rails = {},
  monitor_interval = nil,
  monitor_scale = nil,
  scan_interval = nil,
  startup_watchdog_s = nil
}

local normalize_called = false
normalizer.apply_runtime_defaults(cfg, defaults, {
  target_rpm = 900,
  min_flow = 0,
  max_flow = 2000,
  flow_step = 50,
  rod_tick = 5,
  deep_copy = deep_copy,
  normalize_rails = function(values, default_values)
    normalize_called = true
    values.rails = values.rails or {}
    values.rails._normalized = true
    assert_eq(default_values.autonom.max_rpm, defaults.autonom.max_rpm, "defaults pass-through mismatch")
  end
})

assert_eq(cfg.autonom.target_rpm, 900, "target rpm should be pinned to runtime target")
assert_eq(cfg.autonom.max_rpm, 900, "max_rpm should floor to target rpm")
assert_eq(cfg.autonom.min_flow, 0, "min_flow should clamp to runtime minimum")
assert_eq(cfg.autonom.max_flow, 2000, "max_flow should clamp to runtime maximum")
assert_eq(cfg.autonom.flow_step, 50, "flow_step should default from runtime")
assert_eq(cfg.autonom.ramp_step, 50, "ramp_step should backfill from flow_step")
assert_eq(cfg.autonom.reactor_adjust_interval, 5, "reactor interval should default from runtime rod tick")
assert_eq(cfg.rails._normalized, true, "runtime normalize callback should be used")
assert_eq(normalize_called, true, "normalize_rails should be invoked")
assert_eq(cfg.monitor_interval, defaults.monitor_interval, "monitor interval should default")
assert_eq(cfg.monitor_scale, defaults.monitor_scale, "monitor scale should default")
assert_eq(cfg.scan_interval, defaults.scan_interval, "scan interval should default")
assert_eq(cfg.startup_watchdog_s, defaults.startup_watchdog_s, "startup watchdog should default")

print("rt_config_runtime_defaults_test.lua: ok")
