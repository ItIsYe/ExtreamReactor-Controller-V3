-- tests/sim_chaos_test.lua  Phase 9.2
-- Chaos: zufällige Sequenzen von Aktionen auf Anlagenmodellen.
-- Invariante: keine Exception, kein nil-Rückgabewert bei normalen Abfragen.

local kernel = dofile("tests/sim/cc/kernel.lua")
local React  = dofile("tests/sim/models/reactor.lua")
local Turb   = dofile("tests/sim/models/turbine.lua")
local Energy = dofile("tests/sim/models/energy.lua")
local prop   = dofile("tests/sim/property.lua")
local gen    = prop.gen

math.randomseed(99)
local function rng() return math.random() end

-- Reaktor: zufällige Aktionen
local REACTOR_ACTIONS = {
  function(r) r.tick() end,
  function(r) r.setActive(rng() < 0.5) end,
  function(r) r.setAllControlRodLevels(math.floor(rng()*101)) end,
  function(r) r.setControlRod(0, math.floor(rng()*101)) end,
  function(r) local _ = r.getCasingTemperature() end,
  function(r) local _ = r.getFuelAmount() end,
  function(r) local _ = r.getWasteAmount() end,
  function(r) local _ = r.getControlRods() end,
}

local function chaos_reactor(seed, n)
  math.randomseed(seed)
  local r = React.new({ rod_level=50, initial_fuel=4000 })
  for _ = 1, n do
    local action = REACTOR_ACTIONS[1 + math.floor(rng() * #REACTOR_ACTIONS)]
    local ok, err = pcall(action, r)
    if not ok then
      return false, "reactor chaos error: " .. tostring(err)
    end
    -- Invarianten
    if r.getCasingTemperature() < 0 then return false, "temp < 0" end
    if r.getFuelAmount() < 0 then return false, "fuel < 0" end
    if r.getWasteAmount() < 0 then return false, "waste < 0" end
  end
  return true
end

-- Turbine: zufällige Aktionen
local TURBINE_ACTIONS = {
  function(t) t.tick() end,
  function(t) t.setActive(rng() < 0.5) end,
  function(t) t.setFluidFlowRateTarget(math.floor(rng() * 2001)) end,
  function(t) t.setCoilEngaged(rng() < 0.5) end,
  function(t) local _ = t.getRotorSpeed() end,
  function(t) local _ = t.getFluidFlowRate() end,
  function(t) local _ = t.isCoilEngaged() end,
  function(t) local _ = t.getEnergyProduced() end,
}

local function chaos_turbine(seed, n)
  math.randomseed(seed)
  local turb = Turb.new({ initial_rpm=0, flow_capacity=2000 })
  for _ = 1, n do
    local action = TURBINE_ACTIONS[1 + math.floor(rng() * #TURBINE_ACTIONS)]
    local ok, err = pcall(action, turb)
    if not ok then return false, "turbine chaos error: " .. tostring(err) end
    if turb.getRotorSpeed() < 0 then return false, "rpm < 0" end
    if not turb.getCoilEngaged == nil and turb.isCoilEngaged() and turb.getEnergyProduced() < 0 then
      return false, "negative energy with coil"
    end
  end
  return true
end

-- Runs
local runs = { {1,500},{2,500},{3,500},{42,1000},{99,1000} }
for _, r in ipairs(runs) do
  local seed, n = r[1], r[2]
  local ok, err = chaos_reactor(seed, n)
  assert(ok, string.format("reactor chaos(seed=%d,n=%d): %s", seed, n, tostring(err)))
  local ok2, err2 = chaos_turbine(seed, n)
  assert(ok2, string.format("turbine chaos(seed=%d,n=%d): %s", seed, n, tostring(err2)))
end

-- Energy Chaos
for i = 1, 5 do
  math.randomseed(i * 13)
  local es = Energy.new({ capacity=1000000, stored=0, max_input=100000, max_output=100000 })
  for _ = 1, 500 do
    local inp = math.floor(rng() * 150000)
    local out = math.floor(rng() * 150000)
    es.tick(inp, out)
    assert(es.getEnergyStored() >= 0, "chaos: stored < 0")
    assert(es.getEnergyStored() <= 1000000 + 0.01, "chaos: stored > capacity")
  end
end

print("sim_chaos_test.lua: ok (5 seeds × 500-1000 actions × 3 models)")
