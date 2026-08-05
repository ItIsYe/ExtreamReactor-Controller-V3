-- tests/sim_turbine_property_test.lua  Phase 9.1
local prop  = dofile("tests/sim/property.lua")
local Turb  = dofile("tests/sim/models/turbine.lua")
local gen   = prop.gen

-- P1: RPM immer >= 0
prop.check("rpm_nonneg",
  gen.tuple({ gen.int(0, 2000), gen.int(0, 2000), gen.int(1, 50) }),
  function(t)
    local init_rpm, flow_target, ticks = t[1], t[2], t[3]
    local turb = Turb.new({ initial_rpm=init_rpm, initial_flow=0, flow_capacity=2000 })
    turb.setFluidFlowRateTarget(flow_target)
    for _ = 1, ticks do turb.tick() end
    assert(turb.getRotorSpeed() >= 0, "RPM < 0: " .. turb.getRotorSpeed())
  end, { trials=300, seed=10 })

-- P2: RPM <= max_rpm
prop.check("rpm_below_max",
  gen.tuple({ gen.int(0, 500), gen.int(0, 2000), gen.int(1, 100) }),
  function(t)
    local init_rpm, flow, ticks = t[1], t[2], t[3]
    local max_rpm = 1800
    local turb = Turb.new({ initial_rpm=init_rpm, max_rpm=max_rpm, flow_capacity=2000 })
    turb.setFluidFlowRateTarget(flow)
    for _ = 1, ticks do turb.tick() end
    assert(turb.getRotorSpeed() <= max_rpm + 0.01,
      "RPM above max: " .. turb.getRotorSpeed() .. " > " .. max_rpm)
  end, { trials=300, seed=11 })

-- P3: Flow-Target-Clamp bleibt in [0, max]
prop.check("flow_target_clamp",
  gen.tuple({ gen.int(-1000, 5000) }),
  function(t)
    local target = t[1]
    local turb = Turb.new({ flow_capacity=2000 })
    turb.setFluidFlowRateTarget(target)
    local actual = turb.getFluidFlowRateTarget()
    assert(actual >= 0 and actual <= 2000,
      "flow target out of [0,2000]: " .. actual)
  end, { trials=300, seed=12 })

-- P4: Kein Energie-Output wenn Coil nicht engaged
prop.check("energy_requires_coil",
  gen.tuple({ gen.int(0, 1800) }),
  function(t)
    local rpm = t[1]
    local turb = Turb.new({ initial_rpm=rpm })
    turb.setCoilEngaged(false)
    assert(turb.getEnergyProduced() == 0,
      "energy without coil: " .. turb.getEnergyProduced())
  end, { trials=200, seed=13 })

-- P5: Inaktive Turbine verliert immer RPM
prop.check("inactive_turbine_loses_rpm",
  gen.tuple({ gen.int(1, 500), gen.int(1, 5) }),
  function(t)
    local init_rpm, ticks = t[1], t[2]
    local turb = Turb.new({ initial_rpm=init_rpm })
    turb.setActive(false)
    local before = turb.getRotorSpeed()
    for _ = 1, ticks do turb.tick() end
    assert(turb.getRotorSpeed() <= before + 0.01,
      "RPM increased while inactive: " .. turb.getRotorSpeed() .. " > " .. before)
  end, { trials=200, seed=14 })

print("sim_turbine_property_test.lua: ok (5 Properties, 200-300 trials each)")
