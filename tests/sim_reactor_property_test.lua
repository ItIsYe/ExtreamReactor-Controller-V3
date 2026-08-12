-- tests/sim_reactor_property_test.lua  Phase 9.1
local prop   = dofile("tests/sim/property.lua")
local kernel = dofile("tests/sim/cc/kernel.lua")
local React  = dofile("tests/sim/models/reactor.lua")
local InvC   = dofile("tests/sim/invariants/control.lua")
local InvS   = dofile("tests/sim/invariants/safety.lua")
local gen    = prop.gen

-- P1: Casing-Temperatur bleibt immer >= 20°C (Umgebungstemperatur)
prop.check("temp_always_nonneg",
  gen.tuple({ gen.int(0, 100), gen.int(1, 50), gen.int(0, 4000) }),
  function(t)
    local rod_level, ticks, initial_fuel = t[1], t[2], t[3]
    local r = React.new({ rod_level=rod_level, initial_fuel=initial_fuel })
    for _ = 1, ticks do r.tick() end
    assert(r.getCasingTemperature() >= 20,
      "temp below 20: " .. r.getCasingTemperature())
  end, { trials=200, seed=1 })

-- P2: Fuel monoton fallend (nie steigend)
prop.check("fuel_monotone_decreasing",
  gen.tuple({ gen.int(0, 100), gen.int(1, 20) }),
  function(t)
    local rod_level, ticks = t[1], t[2]
    local r = React.new({ rod_level=rod_level, initial_fuel=2000 })
    local prev_fuel = r.getFuelAmount()
    for _ = 1, ticks do
      r.tick()
      local fuel = r.getFuelAmount()
      assert(fuel <= prev_fuel + 0.01,  -- Epsilon für Floating-Point
        "fuel increased: " .. fuel .. " > " .. prev_fuel)
      prev_fuel = fuel
    end
  end, { trials=200, seed=2 })

-- P3: Waste monoton steigend (nie sinkend)
prop.check("waste_monotone_increasing",
  gen.tuple({ gen.int(0, 80), gen.int(1, 20) }),
  function(t)
    local rod_level, ticks = t[1], t[2]
    local r = React.new({ rod_level=rod_level, initial_fuel=3000 })
    local prev_waste = r.getWasteAmount()
    for _ = 1, ticks do
      r.tick()
      local waste = r.getWasteAmount()
      assert(waste >= prev_waste - 0.01,
        "waste decreased: " .. waste .. " < " .. prev_waste)
      prev_waste = waste
    end
  end, { trials=200, seed=3 })

-- P4: Rod-Level in [0, 100] bleibt nach clamp
prop.check("rod_level_clamp",
  gen.tuple({ gen.int(-50, 150) }),
  function(t)
    local level = t[1]
    local r = React.new({ rod_level=0 })
    r.setAllControlRodLevels(level)
    for _, rod in ipairs(r.getControlRods()) do
      assert(rod.level >= 0 and rod.level <= 100,
        "rod level out of [0,100]: " .. rod.level)
    end
  end, { trials=300, seed=4 })

-- P5: Inaktiver Reaktor kühlt nie auf unter 20°C
prop.check("inactive_cooling_floor",
  gen.tuple({ gen.int(100, 2000), gen.int(1, 100) }),
  function(t)
    local start_temp, ticks = t[1], t[2]
    local r = React.new({ active=false, casing_temp=start_temp })
    for _ = 1, ticks do r.tick() end
    assert(r.getCasingTemperature() >= 20,
      "cooled below 20: " .. r.getCasingTemperature())
  end, { trials=200, seed=5 })

print("sim_reactor_property_test.lua: ok (5 Properties, 200 trials each)")
