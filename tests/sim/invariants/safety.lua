-- tests/sim/invariants/safety.lua  Phase 7.2
-- Safety-Invarianten: SCRAM-Auslöser, Fuel-Erschöpfung, Overspeed.

local M = {}

-- Wenn Temp > limit → Reaktor muss inaktiv sein (SCRAM)
function M.scram_on_overtemp(temp_limit)
  return function(world, tick)
    for i, r in ipairs(world.reactors or {}) do
      if r.getCasingTemperature() > temp_limit and r.getActive() then
        return false, string.format(
          "tick=%d reactor[%d] temp %.1f > %.1f but still active (SCRAM missing)",
          tick, i, r.getCasingTemperature(), temp_limit)
      end
    end
    return true
  end
end

-- Fuel nie unter 0
function M.fuel_nonneg()
  return function(world, tick)
    for i, r in ipairs(world.reactors or {}) do
      if r.getFuelAmount() < 0 then
        return false, string.format("tick=%d reactor[%d] fuel < 0", tick, i)
      end
    end
    return true
  end
end

-- Waste nie über Kapazität
function M.waste_bounded()
  return function(world, tick)
    for i, r in ipairs(world.reactors or {}) do
      if r.getWasteAmount() > r.getWasteCapacity() then
        return false, string.format("tick=%d reactor[%d] waste > capacity", tick, i)
      end
    end
    return true
  end
end

-- Turbine überschreitet Overspeed-Limit nie wenn Coil engaged
function M.no_coil_overspeed(max_rpm)
  return function(world, tick)
    for i, t in ipairs(world.turbines or {}) do
      if t.isCoilEngaged() and t.getRotorSpeed() > max_rpm then
        return false, string.format(
          "tick=%d turbine[%d] coil engaged + overspeed %.1f > %.1f",
          tick, i, t.getRotorSpeed(), max_rpm)
      end
    end
    return true
  end
end

return M
