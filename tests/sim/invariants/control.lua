-- tests/sim/invariants/control.lua  Phase 7.2
-- Kontroll-Invarianten: Rod-Grenzen, Flow-Grenzen, Zielwert-Konvergenz.

local M = {}

-- Rod-Level immer in [min_rods, max_rods]
function M.rod_bounds(min_rods, max_rods)
  min_rods = min_rods or 0
  max_rods = max_rods or 100
  return function(world, tick)
    for _, r in ipairs(world.reactors or {}) do
      for _, rod in ipairs(r.getControlRods()) do
        if rod.level < min_rods or rod.level > max_rods then
          return false, string.format(
            "tick=%d rod level %d out of [%d,%d]", tick, rod.level, min_rods, max_rods)
        end
      end
    end
    return true
  end
end

-- Flow immer in [0, max_flow]
function M.flow_bounds(max_flow)
  max_flow = max_flow or 2000
  return function(world, tick)
    for _, t in ipairs(world.turbines or {}) do
      local f = t.getFluidFlowRateTarget()
      if f < 0 or f > max_flow then
        return false, string.format("tick=%d flow %d out of [0,%d]", tick, f, max_flow)
      end
    end
    return true
  end
end

-- Reaktor bleibt unter max_temp
function M.temp_ceiling(max_temp)
  max_temp = max_temp or 1800
  return function(world, tick)
    for i, r in ipairs(world.reactors or {}) do
      local t = r.getCasingTemperature()
      if t > max_temp then
        return false, string.format("tick=%d reactor[%d] temp %.1f > %.1f", tick, i, t, max_temp)
      end
    end
    return true
  end
end

-- Turbine bleibt unter max_rpm
function M.rpm_ceiling(max_rpm)
  max_rpm = max_rpm or 1800
  return function(world, tick)
    for i, t in ipairs(world.turbines or {}) do
      local rpm = t.getRotorSpeed()
      if rpm > max_rpm then
        return false, string.format("tick=%d turbine[%d] rpm %.1f > %.1f", tick, i, rpm, max_rpm)
      end
    end
    return true
  end
end

-- Energie-Speicher nie negativ
function M.energy_nonneg()
  return function(world, tick)
    for i, e in ipairs(world.energy or {}) do
      if e.getEnergyStored() < 0 then
        return false, string.format("tick=%d energy[%d] stored < 0", tick, i)
      end
    end
    return true
  end
end

return M
