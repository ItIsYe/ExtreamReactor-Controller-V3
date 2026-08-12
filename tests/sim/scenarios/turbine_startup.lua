-- tests/sim/scenarios/turbine_startup.lua  Phase 7.3
-- Szenario: Turbine Kaltstart — RPM steigt, bleibt unter max_rpm.

local scenario_mod = dofile("tests/sim/scenario.lua")
local inv_control  = dofile("tests/sim/invariants/control.lua")
local inv_safety   = dofile("tests/sim/invariants/safety.lua")
local turbine_mod  = dofile("tests/sim/models/turbine.lua")

local MAX_RPM = 1800

local function build_world(topology, kernel, eq)
  local turbines = {}
  for _, cfg in ipairs(topology.turbines or {}) do
    turbines[#turbines+1] = turbine_mod.new(cfg)
  end
  local w = { turbines = turbines }
  function w:tick(t)
    for _, turb in ipairs(self.turbines) do turb.tick() end
  end
  return w
end

local spec = {
  seed       = 3,
  max_ticks  = 1000,
  stop_on_first_violation = true,
  topology   = {
    turbines = {
      { initial_rpm=0, initial_flow=2000, target_rpm=900,
        max_rpm=MAX_RPM, coil_engage_rpm=900,
        flow_capacity=2000, readback_lag=2 },
    },
  },
  timeline   = {},
  invariants = {
    inv_control.rpm_ceiling(MAX_RPM),
    inv_safety.no_coil_overspeed(MAX_RPM),
    inv_control.flow_bounds(2000),
  },
}

local result = scenario_mod.run(spec, build_world)
assert(result.ok,
  "turbine_startup FAILED at tick " ..
  (result.first_violation and result.first_violation.tick or "?") ..
  ": " .. (result.first_violation and result.first_violation.message or "?"))

-- Nach 1000 Ticks sollte RPM > 0 sein
local w2_turbines = {}
local function bw2(top, k, e)
  for _, cfg in ipairs(top.turbines) do w2_turbines[#w2_turbines+1] = turbine_mod.new(cfg) end
  local w = { turbines = w2_turbines }
  function w:tick(t) for _, turb in ipairs(self.turbines) do turb.tick() end end
  return w
end
local r2 = scenario_mod.run(spec, bw2)
assert(w2_turbines[1].getRotorSpeed() > 0, "expected RPM > 0 after 1000 ticks")

print("scenario:turbine_startup: ok (" .. result.ticks_run .. " Ticks, RPM in bounds)")
