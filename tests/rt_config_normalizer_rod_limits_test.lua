local normalizer = dofile("xreactor/nodes/rt/config_normalizer.lua")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq failed") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end
local function assert_true(value, message)
  if not value then error(message or "assert_true failed") end
end

local utils = {
  normalize_node_id = function(v) return type(v)=="string" and v~="" and v or "UNKNOWN" end,
  deep_copy = function(v)
    if type(v)~="table" then return v end
    local o={}; for k,i in pairs(v) do o[k]=utils.deep_copy(i) end; return o
  end
}

-- mk_cfg: rails.reactor_rods leer damit regulator_* als einzige Quelle gilt
local function mk_cfg()
  return {
    node_id="RT-1", role="RT-NODE", debug_logging=true, reset_log_on_start=true,
    reactors={}, turbines={}, heartbeat_interval=2, status_interval=5,
    scan_interval=10, startup_watchdog_s=60, channels={control=6500,status=6501},
    safety={max_temperature=2000,temperature_hysteresis=50,temperature_trip_samples=2,
            max_rpm=1800,min_water=0.2,coolant_hysteresis=0.05,coolant_trip_samples=3,
            coolant_invalid_grace_samples=3},
    autonom={control_rod_level=70,max_rpm=900,min_flow=0,max_flow=2000,
             flow_step=50,ramp_step=50,reactor_adjust_interval=5,
             steam_reserve=5000,steam_deficit=5000},
    rails={reactor_rods={}},
    monitor_interval=2, monitor_scale=0.5, status_log=false, comms={}
  }
end

local function mk_defaults() return mk_cfg() end

local function run(cfg)
  local warnings = {}
  normalizer.validate_config(cfg, mk_defaults(), function(m) table.insert(warnings, m) end, utils)
  return warnings
end

-- Test 1: out-of-range werte werden auf [0,100] geklemmt
local function test_range_clamp()
  local cfg = mk_cfg()
  cfg.autonom.regulator_min_rods = -25
  cfg.autonom.regulator_max_rods = 140
  run(cfg)
  assert_eq(cfg.autonom.regulator_min_rods, 0, "min must clamp to 0")
  assert_eq(cfg.autonom.regulator_max_rods, 100, "max must clamp to 100")
end

-- Test 2: invertierte Limits werden getauscht
local function test_swap()
  local cfg = mk_cfg()
  cfg.autonom.regulator_min_rods = 90
  cfg.autonom.regulator_max_rods = 30
  run(cfg)
  assert_eq(cfg.autonom.regulator_min_rods, 30, "inverted min must be normalized")
  assert_eq(cfg.autonom.regulator_max_rods, 90, "inverted max must be normalized")
end

-- Test 3: legacy alias (min_rods/max_rods) → regulator_*_rods
local function test_legacy_alias()
  local cfg = mk_cfg()
  cfg.autonom.min_rods = 40
  cfg.autonom.max_rods = 85
  local warnings = run(cfg)
  assert_eq(cfg.autonom.regulator_min_rods, 40, "legacy min_rods must map to regulator_min_rods")
  assert_eq(cfg.autonom.regulator_max_rods, 85, "legacy max_rods must map to regulator_max_rods")
  local blob = table.concat(warnings, "\n")
  assert_true(
    blob:find("veraltet", 1, true) ~= nil or blob:find("deprecated", 1, true) ~= nil,
    "legacy alias must emit deprecation warning")
end

-- Test 4: regulator_* hat Vorrang vor legacy min_rods/max_rods
local function test_regulator_overrides_legacy()
  local cfg = mk_cfg()
  cfg.autonom.regulator_min_rods = 60
  cfg.autonom.regulator_max_rods = 80
  cfg.autonom.min_rods = 40
  cfg.autonom.max_rods = 90
  run(cfg)
  assert_eq(cfg.autonom.regulator_min_rods, 60, "regulator_min_rods must take priority over legacy")
  assert_eq(cfg.autonom.regulator_max_rods, 80, "regulator_max_rods must take priority over legacy")
end

-- Test 5: rails.reactor_rods backfill wenn regulator_* fehlt
local function test_rails_backfill()
  local cfg = mk_cfg()
  cfg.rails.reactor_rods = { min = 83, max = 96 }
  run(cfg)
  assert_eq(cfg.autonom.regulator_min_rods, 83, "regulator_min_rods must be backfilled from rails.reactor_rods.min")
  assert_eq(cfg.autonom.regulator_max_rods, 96, "regulator_max_rods must be backfilled from rails.reactor_rods.max")
end

test_range_clamp()
test_swap()
test_legacy_alias()
test_regulator_overrides_legacy()
test_rails_backfill()

print("rt_config_normalizer_rod_limits_test.lua: ok")
