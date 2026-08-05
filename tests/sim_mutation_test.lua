-- tests/sim_mutation_test.lua  Phase 9.3
-- Einfacher Mutations-Smoke-Test: prüft ob Tests echte Fehler fangen.
-- Injiziert bekannte Fehler in Sim-Modelle und prüft ob Properties reagieren.

local function T(v,m) if not v then error(m or"true") end end

-- Mutation 1: Reaktor mit falscher Fuel-Semantik (Fuel steigt statt sinkt)
local broken_reactor = {}
broken_reactor.tick  = function() broken_reactor._fuel = broken_reactor._fuel + 1 end
broken_reactor._fuel = 100
broken_reactor.getCasingTemperature = function() return 300 end
broken_reactor.getFuelAmount = function() return broken_reactor._fuel end
broken_reactor.getWasteAmount = function() return 0 end
broken_reactor.getWasteCapacity = function() return 4000 end
broken_reactor.getActive = function() return true end
broken_reactor.getControlRods = function() return {{level=50,index=0}} end

-- Property: Fuel muss sinken → soll bei Mutation fehlschlagen
local ok = pcall(function()
  local prev = broken_reactor.getFuelAmount()
  broken_reactor.tick()
  local after = broken_reactor.getFuelAmount()
  assert(after <= prev + 0.01, "fuel increased: mutation must trigger failure")
end)
T(not ok, "mutation must be detected: fuel-increase must fail property")

-- Mutation 2: Turbine RPM-Clamp fehlt (RPM kann ins Negative gehen)
local broken_turb = {}
broken_turb._rpm = 100
broken_turb.tick = function()
  broken_turb._rpm = broken_turb._rpm - 50  -- geht ins Negative
end
broken_turb.getRotorSpeed = function() return broken_turb._rpm end
broken_turb.setActive = function() end

local ok2 = pcall(function()
  for _ = 1, 5 do broken_turb.tick() end
  assert(broken_turb.getRotorSpeed() >= 0, "rpm negative: mutation detected")
end)
T(not ok2, "mutation must be detected: rpm-negative must fail property")

-- Mutation 3: Energy-Speicher kann über Kapazität gehen
local broken_es = { _stored = 0 }
broken_es.tick = function(inp, out)
  broken_es._stored = broken_es._stored + (inp or 0)  -- kein Capacity-Cap!
end
broken_es.getEnergyStored = function() return broken_es._stored end
broken_es.getMaxEnergyStored = function() return 1000 end

local ok3 = pcall(function()
  broken_es.tick(5000)
  assert(broken_es.getEnergyStored() <= broken_es.getMaxEnergyStored() + 0.01,
    "stored exceeds capacity: mutation detected")
end)
T(not ok3, "mutation must be detected: over-capacity must fail property")

print("sim_mutation_test.lua: ok (3 mutations correctly detected)")
