package.path = package.path .. ";/workspace/ExtreamReactor-Controller-V3/?.lua"

local rails = dofile("/workspace/ExtreamReactor-Controller-V3/xreactor/core/control_rails.lua")

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

local function test_clamp_with_reason()
  local value, reason = rails.clamp_with_reason(15, 40, 85)
  assert_eq(value, 40, "value below config minimum must clamp to minimum")
  assert_eq(reason, "MIN", "below-range clamp reason must be MIN")

  value, reason = rails.clamp_with_reason(92, 40, 85)
  assert_eq(value, 85, "value above config maximum must clamp to maximum")
  assert_eq(reason, "MAX", "above-range clamp reason must be MAX")

  value, reason = rails.clamp_with_reason(66, 40, 85)
  assert_eq(value, 66, "value inside range must stay unchanged")
  assert_eq(reason, nil, "in-range value must not report a clamp reason")
end


local function test_rt_config_uses_single_authoritative_regulator_fields()
  local cfg = dofile('/workspace/ExtreamReactor-Controller-V3/xreactor/nodes/rt/config.lua')
  assert_true(type(cfg.autonom) == 'table', 'rt config must define autonom section')
  assert_true(cfg.autonom.min_rods == nil and cfg.autonom.max_rods == nil,
    'legacy autonom.min_rods/max_rods must be removed from defaults to avoid ambiguous caps')
  assert_eq(cfg.autonom.regulator_min_rods, cfg.rails.reactor_rods.min,
    'default regulator_min_rods must align with rails.reactor_rods.min for unambiguous default cap')
  assert_eq(cfg.autonom.regulator_max_rods, cfg.rails.reactor_rods.max,
    'default regulator_max_rods must align with rails.reactor_rods.max for unambiguous default cap')
  assert_eq(cfg.autonom.regulator_min_rods, 80,
    'default regulator min rods must enforce 20% automatic power cap (100-rods semantics)')
  assert_eq(100 - cfg.autonom.regulator_min_rods, 20,
    'power semantics regression: min rods of 80 must equal max 20% automatic power')
end

local function test_rt_main_has_config_clamp_logging_and_safe_override()
  local file = io.open('xreactor/nodes/rt/main.lua', 'r')
  if not file then
    error('failed to open RT main source')
  end
  local content = file:read('*a')
  file:close()

  assert_true(content:find('ROD_TARGET_CLAMPED_BY_CONFIG_MIN', 1, true) ~= nil,
    'automatic rod controller must log min clamp diagnostics')
  assert_true(content:find('ROD_TARGET_CLAMPED_BY_CONFIG_MAX', 1, true) ~= nil,
    'automatic rod controller must log max clamp diagnostics')
  assert_true(content:find('rails%.clamp_with_reason%(target_rods, cfg_min, cfg_max%)') ~= nil,
    'automatic rod controller must clamp target via config min/max before write path')
  assert_true(content:find('ROD_APPLY_CLAMPED_BY_CONFIG_MIN', 1, true) ~= nil,
    'rod write path must log min cap clamp diagnostics')
  assert_true(content:find('ROD_APPLY_CLAMPED_BY_CONFIG_MAX', 1, true) ~= nil,
    'rod write path must log max cap clamp diagnostics')
  assert_true(content:find('ROD_APPLY_SAFE_OVERRIDE', 1, true) ~= nil,
    'SAFE/SCRAM override path must be explicitly logged')
  assert_true(content:find('Rod cap config loaded', 1, true) ~= nil,
    'startup log must report effective rod cap config source values')
  assert_true(content:find('ROD_CAP_CONFIG_MIN_MISMATCH', 1, true) ~= nil,
    'startup diagnostics must report min-cap mismatches between autonom and rails config paths')
  assert_true(content:find('math%.max%(autonom_min, rails_min%)') ~= nil,
    'effective rod cap resolver must use stricter min cap when autonom and rails both exist')
  assert_true(content:find('applyReactorRods%(ROD_MAX, true, "SAFE_TICK"%)') ~= nil,
    'SAFE/SCRAM path must still force 100% rod insertion via allow_overmax')
end

test_clamp_with_reason()
test_rt_config_uses_single_authoritative_regulator_fields()
test_rt_main_has_config_clamp_logging_and_safe_override()

print('reactor_rod_config_clamp_regression_test.lua: ok')
