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

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local defaults = dofile("/workspace/ExtreamReactor-Controller-V3/xreactor/nodes/rt/config.lua")

local cfg = {
  autonom = { steam_reserve = 5000, steam_deficit = 5000 },
  rails = {
    turbine_flow = deep_copy(defaults.rails.turbine_flow),
    reactor_rods = deep_copy(defaults.rails.reactor_rods),
    reactor_steam_guard = {
      enabled = true,
      high_ratio = 1.5,
      high_release_ratio = 0.95,
      critical_ratio = 0.6,
      critical_release_ratio = 1.2,
      force_close_step = -4,
      ema_alpha = 5
    },
    coil = deep_copy(defaults.rails.coil)
  }
}

normalizer.normalize_rails(cfg, defaults, { deep_copy = deep_copy }, { clamp = function(v, min_v, max_v)
  if v < min_v then return min_v end
  if v > max_v then return max_v end
  return v
end }, 0, 2000)

local guard = cfg.rails.reactor_steam_guard
assert_true(guard.enabled, "steam guard should remain enabled when configured true")
assert_eq(guard.high_ratio, 0.6, "high_ratio must be clamped to critical_ratio ceiling")
assert_eq(guard.high_release_ratio, 0.6, "high_release_ratio must not exceed high_ratio")
assert_eq(guard.critical_ratio, 0.6, "critical_ratio should keep configured value in range")
assert_eq(guard.critical_release_ratio, 0.6, "critical_release_ratio must not exceed critical_ratio")
assert_eq(guard.force_close_step, 0, "force_close_step should clamp at zero")
assert_eq(guard.ema_alpha, defaults.rails.reactor_steam_guard.ema_alpha, "invalid ema should reset to default")

print("rt_config_normalizer_steam_guard_test.lua: ok")
