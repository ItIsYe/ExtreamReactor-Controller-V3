package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Integration smoke test for the v2 engine against the REAL adapter stack
-- (adapters/turbine.lua, adapters/reactor.lua) on a simulated CC:Tweaked
-- peripheral layer, with a ctx shaped exactly like main.lua's build_ctx()
-- result -- 25 turbines + 1 reactor, the fleet size actually running in
-- production.
--
-- The unit tests around rt2_engine use hand-written fake adapter modules,
-- so they can (and did) encode the wrong assumptions about what ctx and
-- the adapters actually provide. This test goes through the real ones.

local files = { ['/xreactor_config'] = '<dir>' }
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function() return '/xreactor_config' end,
  makeDir = function(p) files[p] = '<dir>' end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
  open = function(p, mode)
    if mode == 'w' then
      local buffer = ''
      return { write = function(v) buffer = buffer .. tostring(v) end, close = function() files[p] = buffer end }
    elseif mode == 'r' then
      if files[p] == nil or files[p] == '<dir>' then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}
_G.textutils = {
  serialize = function(value)
    local function encode(v)
      if type(v) == 'string' then return string.format('%q', v) end
      if type(v) == 'number' or type(v) == 'boolean' then return tostring(v) end
      if type(v) ~= 'table' then return 'nil' end
      local parts = {}
      for k, item in pairs(v) do parts[#parts + 1] = '[' .. encode(k) .. ']=' .. encode(item) end
      table.sort(parts)
      return '{' .. table.concat(parts, ',') .. '}'
    end
    return encode(value)
  end,
  unserialize = function(content)
    local loader = load('return ' .. content, '=cache', 't', {})
    if not loader then return nil end
    local ok, value = pcall(loader)
    return ok and value or nil
  end,
}

local clock_ms = 1000000
os.epoch = function() return clock_ms end

-- ── Simulated plant ──────────────────────────────────────────────────────
--
-- Deliberately crude physics, but with the one property that matters for
-- the control loop: rotor speed follows the commanded flow, and a turbine
-- only produces energy while its coil is engaged.

local TURBINE_COUNT = 25
local RPM_PER_FLOW = 900 / 4000 -- 4000 flow ~= 900 rpm at steady state

local plant = { turbines = {}, reactor = {
  active = false, rods = 100, steam = 0, steam_max = 100000,
  temperature = 800, coolant = 9000, coolant_max = 10000,
} }
local turbine_names = {}
for i = 1, TURBINE_COUNT do
  local name = string.format('turbine_%d', i)
  turbine_names[#turbine_names + 1] = name
  plant.turbines[name] = { active = false, rpm = 0, flow = 0, coil = false, energy = 0 }
end
local REACTOR_NAME = 'reactor_0'

local TURBINE_METHODS = {
  'getActive', 'setActive', 'getRotorSpeed', 'getFluidFlowRateMax', 'setFluidFlowRateMax',
  'getEnergyProducedLastTick', 'getInductorEngaged', 'setInductorEngaged',
}
local REACTOR_METHODS = {
  'getActive', 'setActive', 'getFuelTemperature', 'getEnergyStored', 'getEnergyProducedLastTick',
  'getFuelAmount', 'getWasteAmount', 'getFuelAmountMax', 'getControlRodLevel', 'setAllControlRodLevels',
  'getNumberOfControlRods', 'getHotFluidAmount', 'getHotFluidAmountMax', 'isActivelyCooled',
  'getCoolantAmount', 'getCoolantAmountMax',
}

_G.peripheral = {
  isPresent = function(name) return plant.turbines[name] ~= nil or name == REACTOR_NAME end,
  getType = function(name) return plant.turbines[name] and 'BigReactors-Turbine' or 'BigReactors-Reactor' end,
  getMethods = function(name) return plant.turbines[name] and TURBINE_METHODS or REACTOR_METHODS end,
  call = function(name, method, ...)
    local t = plant.turbines[name]
    if t then
      if method == 'getActive' then return t.active end
      if method == 'setActive' then t.active = (...) and true or false; return true end
      if method == 'getRotorSpeed' then return t.rpm end
      if method == 'getFluidFlowRateMax' then return t.flow end
      if method == 'setFluidFlowRateMax' then t.flow = tonumber((...)) or 0; return true end
      if method == 'getEnergyProducedLastTick' then return t.energy end
      if method == 'getInductorEngaged' then return t.coil end
      if method == 'setInductorEngaged' then t.coil = (...) and true or false; return true end
      error('unexpected turbine method ' .. tostring(method), 0)
    end
    if name ~= REACTOR_NAME then error('unknown peripheral ' .. tostring(name), 0) end
    local r = plant.reactor
    if method == 'getActive' then return r.active end
    if method == 'setActive' then r.active = (...) and true or false; return true end
    if method == 'getFuelTemperature' then return r.temperature end
    if method == 'getCoolantAmount' then return r.coolant end
    if method == 'getCoolantAmountMax' then return r.coolant_max end
    if method == 'getEnergyStored' then return 0 end
    if method == 'getEnergyProducedLastTick' then return 0 end
    if method == 'getFuelAmount' then return 1000 end
    if method == 'getWasteAmount' then return 0 end
    if method == 'getFuelAmountMax' then return 4000 end
    if method == 'getControlRodLevel' then return r.rods end
    if method == 'getNumberOfControlRods' then return 1 end
    if method == 'setAllControlRodLevels' then r.rods = tonumber((...)) or r.rods; return true end
    if method == 'getHotFluidAmount' then return r.steam end
    if method == 'getHotFluidAmountMax' then return r.steam_max end
    if method == 'isActivelyCooled' then return true end
    error('unexpected reactor method ' .. tostring(method), 0)
  end,
  wrap = function(name)
    return setmetatable({}, { __index = function(_, method)
      return function(...) return _G.peripheral.call(name, method, ...) end
    end })
  end,
}

local function step_physics()
  local r = plant.reactor
  -- Rods: 100 = fully inserted = no steam, 70 = the configured floor.
  local power = r.active and math.max(0, (100 - r.rods) / 100) or 0
  local produced = power * 400000
  local consumed = 0
  for _, t in pairs(plant.turbines) do
    if t.active then consumed = consumed + t.flow end
  end
  r.steam = math.max(0, math.min(r.steam_max, r.steam + produced - consumed))
  local starved = consumed > 0 and (produced + r.steam) < consumed
  for _, t in pairs(plant.turbines) do
    if not t.active then
      t.rpm = math.max(0, t.rpm - 50); t.energy = 0
    else
      local target = starved and 0 or (t.flow * RPM_PER_FLOW)
      t.rpm = t.rpm + (target - t.rpm) * 0.35
      t.energy = t.coil and (t.rpm * 5) or 0
    end
  end
end

-- ── ctx shaped like main.lua's build_ctx() ───────────────────────────────

local logged = {}
local config = { reactors = {}, turbines = {} }
local ctx = {
  config = config,
  CONFIG = { LOG_PREFIX = 'RT' },
  adapters = { reactor = require('adapters.reactor'), turbine = require('adapters.turbine') },
  log = function(level, msg) logged[#logged + 1] = tostring(level) .. ' ' .. tostring(msg) end,
}

-- discovery_runtime.refresh_bindings() populates config.reactors/.turbines
-- with the discovered peripheral NAMES -- reproduce that here.
config.turbines = turbine_names
config.reactors = { REACTOR_NAME }

local rt2_engine = require('nodes.rt.rt2_engine')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

rt2_engine.init({ cache_path = '/xreactor_config/rt2_integration_cache.lua', turbine_count = TURBINE_COUNT, log = ctx.log })

-- Run the loop the way main.lua's control_tick() does. Every tick must
-- complete without raising -- a raise here is exactly the "crashes every
-- control tick, nothing ever regulates" failure mode that service_manager's
-- pcall would otherwise hide behind a generic retry message.
local last
local reached_learning, reached_operational = false, false
for tick = 1, 400 do
  local ok, err = pcall(rt2_engine.tick, ctx)
  if not ok then
    error(string.format('v2 tick %d raised: %s', tick, tostring(err)), 0)
  end
  last = err
  if last.state == rt2_state.states.LEARNING then reached_learning = true end
  if last.state == rt2_state.states.MASTER or last.state == rt2_state.states.AUTONOM then
    reached_operational = true
  end
  step_physics()
  clock_ms = clock_ms + 500
end

assert_true(reached_learning, 'the node must pass through LEARNING after discovery')
assert_true(plant.reactor.active, 'the reactor must have been switched on by the engine')

local active_turbines = 0
for _, t in pairs(plant.turbines) do if t.active then active_turbines = active_turbines + 1 end end
assert_eq(active_turbines, TURBINE_COUNT, 'every discovered turbine must have been switched on by the engine')

assert_true(last.capacity.total_turbines == TURBINE_COUNT,
  'capacity must see all 25 turbines, not a truncated/empty fleet -- got '
    .. tostring(last.capacity.total_turbines))

assert_true(reached_operational, string.format(
  'the node must leave LEARNING within 400 ticks -- stuck in %s with capacity %s/%s (%s), max_output=%s',
  tostring(last.state), tostring(last.capacity.at_target), tostring(last.capacity.total_turbines),
  tostring(last.capacity.reason), tostring(last.capacity.max_output)))

assert_true(last.capacity.ready, 'capacity must be learned')
assert_true((last.capacity.max_output or 0) > 0, 'a learned capacity must carry a positive max_output')

-- ── Safety trip ──────────────────────────────────────────────────────────
--
-- Regression: rt2_engine.tick() never passed safety_tripped into the
-- orchestrator, and main.lua's control_tick() returns early for v2 and so
-- skips v1's module_lifecycle safety detector -- a v2 node therefore had
-- NO temperature and NO coolant monitoring at all. An over-limit reactor
-- must now reach SAFE, fully insert the rods and zero every flow.
plant.reactor.temperature = 2600
local safe_result
for _ = 1, 20 do
  safe_result = rt2_engine.tick(ctx)
  step_physics()
  clock_ms = clock_ms + 500
end
assert_eq(safe_result.state, rt2_state.states.SAFE,
  'a reactor far over its temperature limit must drive the node to SAFE')
assert_eq(plant.reactor.rods, 100, 'SAFE must fully insert the control rods on the real reactor')
for name, t in pairs(plant.turbines) do
  assert_eq(t.flow, 0, 'SAFE must zero the flow of ' .. name)
end

-- ...and it must recover on its own once the reading is healthy again
-- (only a manual SCRAM latches).
plant.reactor.temperature = 800
local recovered
for _ = 1, 20 do
  recovered = rt2_engine.tick(ctx)
  step_physics()
  clock_ms = clock_ms + 500
end
assert_true(recovered.state ~= rt2_state.states.SAFE,
  'the node must leave SAFE by itself once the temperature is back to normal')

print('rt2_engine_integration_test.lua: ok')
