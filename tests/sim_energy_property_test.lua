-- tests/sim_energy_property_test.lua  Phase 9.1
local prop   = dofile("tests/sim/property.lua")
local Energy = dofile("tests/sim/models/energy.lua")
local gen    = prop.gen

-- P1: Stored immer >= 0
prop.check("stored_nonneg",
  gen.tuple({ gen.int(0, 100000), gen.int(0, 100000), gen.int(0, 100000) }),
  function(t)
    local stored, inp, out = t[1], t[2], t[3]
    local es = Energy.new({ capacity=200000, stored=stored, max_input=100000, max_output=100000 })
    es.tick(inp, out)
    assert(es.getEnergyStored() >= 0,
      "stored < 0: " .. es.getEnergyStored())
  end, { trials=500, seed=20 })

-- P2: Stored <= capacity
prop.check("stored_le_capacity",
  gen.tuple({ gen.int(0, 200000), gen.int(0, 200000), gen.int(0, 200000) }),
  function(t)
    local stored, inp, out = t[1], t[2], t[3]
    local cap = 100000
    local es = Energy.new({ capacity=cap, stored=math.min(stored,cap), max_input=200000, max_output=200000 })
    es.tick(inp, out)
    assert(es.getEnergyStored() <= cap + 0.01,
      "stored > capacity: " .. es.getEnergyStored() .. " > " .. cap)
  end, { trials=500, seed=21 })

-- P3: last_input + last_output <= |delta stored| + epsilon
prop.check("energy_conservation",
  gen.tuple({ gen.int(0, 50000), gen.int(0, 50000), gen.int(0, 50000) }),
  function(t)
    local stored, inp, out = t[1], t[2], t[3]
    local cap = 100000
    local es = Energy.new({ capacity=cap, stored=math.min(stored,cap),
                            max_input=100000, max_output=100000 })
    local before = es.getEnergyStored()
    es.tick(inp, out)
    local after = es.getEnergyStored()
    local delta = after - before
    local net = es.getLastTickInput() - es.getLastTickOutput()
    assert(math.abs(delta - net) < 1.0,
      "energy not conserved: delta=" .. delta .. " net=" .. net)
  end, { trials=500, seed=22 })

-- P4: Prozentfüllung in [0, 100]
prop.check("fill_percentage_range",
  gen.tuple({ gen.int(0, 1000) }),
  function(t)
    local stored = t[1]
    local cap = 1000
    local es = Energy.new({ capacity=cap, stored=math.min(stored,cap) })
    local pct = es.getEnergyFilledPercentage()
    assert(pct >= 0 and pct <= 100.01,
      "percentage out of [0,100]: " .. pct)
  end, { trials=300, seed=23 })

print("sim_energy_property_test.lua: ok (4 Properties, 300-500 trials each)")
