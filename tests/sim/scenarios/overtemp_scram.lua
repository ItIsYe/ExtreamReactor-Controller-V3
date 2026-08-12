-- tests/sim/scenarios/overtemp_scram.lua  Phase 7.3
-- Szenario: Reaktor überhitzt → SCRAM-Invariante greift.
-- Timeline: nach Tick 50 SCRAM (Reaktor deaktivieren) bei Temp > 1500.

local scenario_mod = dofile("tests/sim/scenario.lua")
local inv_control  = dofile("tests/sim/invariants/control.lua")
local inv_safety   = dofile("tests/sim/invariants/safety.lua")
local reactor_mod  = dofile("tests/sim/models/reactor.lua")

local SCRAM_TEMP = 1500
local scrammed   = false

local function build_world(topology, kernel, eq)
  local reactors = {}
  for _, cfg in ipairs(topology.reactors or {}) do
    reactors[#reactors+1] = reactor_mod.new(cfg)
  end
  local w = { reactors = reactors }
  function w:tick(t)
    for _, r in ipairs(self.reactors) do
      -- Einfacher SCRAM-Controller
      if r.getCasingTemperature() > SCRAM_TEMP and r.getActive() then
        r.setActive(false)
        scrammed = true
      end
      r.tick()
    end
  end
  return w
end

local spec = {
  seed       = 2,
  max_ticks  = 2000,
  stop_on_first_violation = true,
  topology   = {
    reactors = {
      -- Kein Kühlmittel: heizt sehr schnell
      { rod_level=0, initial_fuel=4000, base_fuel_rate=2.0,
        cooling_rate=0.01, max_heat=3000, thermal_mass=50 },
    },
  },
  timeline   = {},
  -- Invariante: wenn Temp > SCRAM_TEMP, muss Reaktor inaktiv sein
  invariants = {
    inv_safety.scram_on_overtemp(SCRAM_TEMP + 10),  -- +10 Hysterese Puffer
    inv_safety.fuel_nonneg(),
    inv_safety.waste_bounded(),
  },
}

local result = scenario_mod.run(spec, build_world)
assert(result.ok,
  "overtemp_scram FAILED: " .. (result.first_violation and
    result.first_violation.message or "unknown"))
assert(scrammed, "expected SCRAM to trigger but it never did")

print("scenario:overtemp_scram: ok (SCRAM bei Übertemperatur korrekt ausgelöst)")
