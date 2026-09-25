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
-- Calibrated to the real limit, not to rt2_turbine's old (wrong) 32000:
-- a Reinforced turbine tops out at 2000 mB/t (Extreme Reactors 2.4.27,
-- TurbineVariant.setMaxPermittedFlow), so the target RPM has to be
-- reachable well below that -- otherwise the simulated fleet could never
-- reach 900 RPM and the test would fail for a reason the real plant
-- does not have.
local RPM_PER_FLOW = 900 / 1500 -- ~1500 mB/t reaches the 900 rpm target

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

-- discovery_runtime.build_modules() shape: id-keyed, state starts at "OFF"
-- and is what MASTER and the UI read.
local modules_registry = {}
for _, name in ipairs(turbine_names) do
  modules_registry['turbine:' .. name] = { id = 'turbine:' .. name, type = 'turbine', name = name, state = 'OFF', progress = 0 }
end
modules_registry['reactor:' .. REACTOR_NAME] =
  { id = 'reactor:' .. REACTOR_NAME, type = 'reactor', name = REACTOR_NAME, state = 'OFF', progress = 0 }

local ctx = {
  config = config,
  CONFIG = { LOG_PREFIX = 'RT' },
  adapters = { reactor = require('adapters.reactor'), turbine = require('adapters.turbine') },
  modules = modules_registry,
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
for tick = 1, 3000 do
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
  clock_ms = clock_ms + 100
  if os.getenv('TRACE') and tick % 100 == 0 then
    local t1 = last.turbines[1]
    local p1 = plant.turbines[turbine_names[1]]
    print(string.format('tick %4d  state=%-9s max_active=%s  T1: ziel=%s rpm=%.0f flow=%s coil=%s  %s',
      tick, tostring(last.state), tostring(last.max_active),
      tostring(t1 and t1.target_rpm), p1.rpm or -1, tostring(p1.flow), tostring(p1.coil),
      tostring(last.capacity.reason)))
  end
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
  'the node must leave LEARNING within 3000 ticks -- stuck in %s with capacity %s/%s (%s), max_output=%s',
  tostring(last.state), tostring(last.capacity.at_target), tostring(last.capacity.total_turbines),
  tostring(last.capacity.reason), tostring(last.capacity.max_output)))

assert_true(last.capacity.ready, 'capacity must be learned')
assert_true((last.capacity.max_output or 0) > 0, 'a learned capacity must carry a positive max_output')

-- ── Module-state projection ──────────────────────────────────────────────
--
-- Regression: main.lua's control_tick() returns early for v2 and so never
-- runs module_lifecycle.update_module_states(). Every module therefore
-- stayed frozen at its boot state "OFF" -- MASTER counts state=="RUNNING"/
-- "STABLE" and its startup sequencer WAITS for "STABLE", so a perfectly
-- regulating v2 node looked dead and stalled MASTER forever.
local stable_turbines, off_modules = 0, 0
for id, module in pairs(modules_registry) do
  if module.state == 'OFF' then off_modules = off_modules + 1 end
  if module.type == 'turbine' and module.state == 'STABLE' then stable_turbines = stable_turbines + 1 end
  assert_true(module.state ~= nil, 'module ' .. id .. ' must carry a projected state')
end
assert_eq(off_modules, 0, 'no module may still sit at its boot state "OFF" once the node is running')
assert_true(stable_turbines > 0, 'turbines at target must be reported STABLE so MASTER can advance its sequencer')

-- Diese Anlage hat genug Dampf fuer ihre ganze Flotte -- dann muss das
-- Einlernen das auch so messen und darf nichts deckeln.
local sustainable = last.capacity.sustainable_turbines
assert_eq(sustainable, TURBINE_COUNT,
  'eine Anlage mit genug Dampf muss alle Turbinen gleichzeitig gemessen haben')
assert_eq(stable_turbines, TURBINE_COUNT, 'und alle laufen')
assert_true(last.max_active == nil or last.max_active >= TURBINE_COUNT,
  'und nichts wird gedeckelt')
assert_true(last.capacity.max_output > 0, 'mit einem positiven, gemessenen Gesamtausstoss')
assert_eq(modules_registry['reactor:' .. REACTOR_NAME].state, 'STABLE', 'a running reactor must be reported STABLE')

-- status_fields() must carry the node state payload.state should report,
-- since node_state_machine itself is deliberately never driven under v2.
local fields = rt2_engine.status_fields()
assert_true(fields.node_state == 'RUNNING' or fields.node_state == 'AUTONOM',
  'an operational v2 node must project to RUNNING/AUTONOM, got ' .. tostring(fields.node_state))

-- Live-Test node-101: der RT-eigene Schirm zeigte "SOLL 0.0 / MASTER % 0.0",
-- weil er v1's ctx.targets las -- das unter v2 niemand mehr fuellt. Die
-- Vorgabe lebt im Orchestrator, also muss status_fields() sie auch nennen.
assert_true(type(fields.master_percent) == 'number',
  'status_fields() muss die wirksame Leistungsvorgabe nennen, sonst kann keine Anzeige'
    .. ' sagen warum eine Turbine steht -- got ' .. tostring(fields.master_percent))
assert_true(fields.master_percent > 0,
  'ohne MASTER regelt der Knoten auf volle Vorgabe, nicht auf 0 %')
assert_true(type(fields.power_target) == 'number' and fields.power_target > 0,
  'und was diese Vorgabe in RF/t bedeutet -- got ' .. tostring(fields.power_target))
assert_eq(math.floor(fields.power_target + 0.5),
  math.floor(fields.capacity_max * fields.master_percent / 100 + 0.5),
  'der angezeigte Sollwert muss genau der Anteil der gemessenen Kapazitaet sein')

-- ── Turbinenkennlinien ueberdauern den Neustart ──────────────────────────
--
-- rt2_turbine_model.lua misst je Turbine, wieviel Drehzahl ein mB/t wert
-- ist. Das nuetzt nur, wenn die gemessene Kennlinie beim naechsten Start
-- auch wieder da ist und der Regler sie dann wirklich benutzt -- sonst
-- taestet sich jede Turbine nach jedem Neustart von vorne heran.

do
  local rt2_turbine_model = require('nodes.rt.rt2_turbine_model')
  local utils = require('core.utils')
  local MODEL_PATH = '/xreactor_config/rt2_integration_turbine_model.lua'

  -- Eine gemessene Kennlinie, wie sie im Betrieb entstanden waere: genau
  -- die Strecke, die step_physics() oben nachbildet.
  local profiles = {}
  for _, name in ipairs(turbine_names) do
    profiles[name] = {
      slope = RPM_PER_FLOW, intercept = 0,
      min_adjust_interval_ms = 800, samples = 12, flow_spread = 300,
    }
  end
  assert_true(rt2_turbine_model.save_units(profiles, {
    path = MODEL_PATH,
    write_config = function(path, data) return utils.write_config(path, data) end,
  }), 'die Kennlinien muessen sich schreiben lassen')
  assert_true(files[MODEL_PATH] ~= nil, 'und dabei wirklich auf der Platte landen')

  local loaded_msg = nil
  rt2_engine.init({
    cache_path = '/xreactor_config/rt2_integration_cache.lua',
    turbine_model_path = MODEL_PATH,
    turbine_count = TURBINE_COUNT,
    log = function(level, msg)
      ctx.log(level, msg)
      if tostring(msg):find('Turbinenkennlinien geladen') then loaded_msg = msg end
    end,
  })
  assert_true(loaded_msg ~= nil, 'der Neustart muss die Kennlinien laden und das auch sagen')
  assert_true(loaded_msg:find(tostring(TURBINE_COUNT)) ~= nil,
    'und zwar alle: ' .. tostring(loaded_msg))

  -- Und sie muessen auch wirklich regeln: eine Turbine weit unter ihrem
  -- Ziel bekommt jetzt den Durchfluss, den die Kennlinie dafuer nennt --
  -- in einem Zug, statt in Schritten von TRIM_STEP.
  for _, t in pairs(plant.turbines) do t.rpm = 300; t.coil = true end
  local first
  for _ = 1, 40 do
    first = rt2_engine.tick(ctx)
    clock_ms = clock_ms + 500
    local reason = first.turbines[1].flow_decision.reason
    if reason == 'MODEL_FEEDFORWARD' then break end
  end
  assert_eq(first.turbines[1].flow_decision.reason, 'MODEL_FEEDFORWARD',
    'mit geladener Kennlinie muss der Regler sie auch benutzen')
  assert_true(math.abs(first.turbines[1].flow_decision.flow - 900 / RPM_PER_FLOW) <= 5,
    'und genau den Durchfluss stellen, den sie fuer 900 RPM nennt -- war '
      .. tostring(first.turbines[1].flow_decision.flow))
  assert_eq(rt2_engine.status_fields().turbines_modelled, TURBINE_COUNT,
    'die Statusfelder muessen melden, dass die ganze Flotte vermessen ist')
end

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

-- The SAFE trip must also have been visible in the projected module states
-- and node state, not just internally.
do
  plant.reactor.temperature = 2600
  for _ = 1, 20 do
    rt2_engine.tick(ctx)
    step_physics()
    clock_ms = clock_ms + 500
  end
  assert_eq(rt2_engine.status_fields().node_state, 'EMERGENCY',
    'a safety trip must be reported as EMERGENCY, not left at the last healthy node state')
  for id, module in pairs(modules_registry) do
    assert_eq(module.state, 'ERROR', 'module ' .. id .. ' must report ERROR while the node is tripped')
  end
end

print('rt2_engine_integration_test.lua: ok')
