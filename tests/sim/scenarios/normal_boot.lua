-- tests/sim/scenarios/normal_boot.lua  Phase 7.3
-- Szenario: normaler Reaktor-Kaltstart.
-- Invarianten: Temp < 1800°C, Fuel >= 0, Waste <= Kapazität.

local scenario_mod = dofile("tests/sim/scenario.lua")
local inv_control  = dofile("tests/sim/invariants/control.lua")
local inv_safety   = dofile("tests/sim/invariants/safety.lua")
local reactor_mod  = dofile("tests/sim/models/reactor.lua")

local function build_world(topology, kernel, eq)
  local reactors = {}
  for _, cfg in ipairs(topology.reactors or {}) do
    reactors[#reactors+1] = reactor_mod.new(cfg)
  end
  local w = { reactors = reactors }
  function w:tick(t)
    for _, r in ipairs(self.reactors) do r.tick() end
  end
  return w
end

local spec = {
  seed       = 1,
  max_ticks  = 500,
  stop_on_first_violation = true,
  topology   = {
    reactors = {
      { rod_level=50, initial_fuel=4000, base_fuel_rate=0.5,
        cooling_rate=0.3, max_heat=2000, thermal_mass=200 },
    },
  },
  timeline   = {},
  invariants = {
    inv_control.temp_ceiling(1800),
    inv_safety.fuel_nonneg(),
    inv_safety.waste_bounded(),
  },
}

local result = scenario_mod.run(spec, build_world)
assert(result.ok, "normal_boot FAILED at tick " ..
  (result.first_violation and result.first_violation.tick or "?") ..
  ": " .. (result.first_violation and result.first_violation.message or "unknown"))
assert(result.ticks_run == 500, "expected 500 ticks, ran " .. result.ticks_run)

print("scenario:normal_boot: ok (" .. result.ticks_run .. " Ticks)")
