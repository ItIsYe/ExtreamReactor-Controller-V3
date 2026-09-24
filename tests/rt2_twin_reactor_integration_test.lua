package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- ZWEI REAKTOREN, ein gemeinsames Dampfnetz, 30 Turbinen -- durch die
-- ECHTE Engine und den echten Adapterstapel, vom PC-Start bis zurueck.
--
-- Die Modultests pruefen die Entscheidungen; diese Datei prueft, dass sie
-- auf echter (simulierter) Hardware auch ankommen: dass beide Reaktoren
-- wirklich geschrieben werden, dass eine Ausloesung an einem die Flotte
-- nicht mitreisst, und dass Cache und Anlagenprofil einen Neustart
-- ueberleben.

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

local TURBINE_COUNT = 30
-- Calibrated to the real limit, not to rt2_turbine's old (wrong) 32000:
-- a Reinforced turbine tops out at 2000 mB/t (Extreme Reactors 2.4.27,
-- TurbineVariant.setMaxPermittedFlow), so the target RPM has to be
-- reachable well below that -- otherwise the simulated fleet could never
-- reach 900 RPM and the test would fail for a reason the real plant
-- does not have.
local RPM_PER_FLOW = 900 / 1500 -- ~1500 mB/t reaches the 900 rpm target

-- ZWEI Reaktoren am selben Dampfnetz. Jeder hat seinen eigenen Tank --
-- genau daraus regelt er -- und speist damit dieselbe Turbinenflotte.
local REACTOR_NAMES = { 'reactor_0', 'reactor_1' }
local plant = { turbines = {}, reactors = {} }
for _, rname in ipairs(REACTOR_NAMES) do
  plant.reactors[rname] = {
    active = false, rods = 100, steam = 0, steam_max = 100000,
    temperature = 800, coolant = 9000, coolant_max = 10000,
  }
end
local turbine_names = {}
for i = 1, TURBINE_COUNT do
  local name = string.format('turbine_%d', i)
  turbine_names[#turbine_names + 1] = name
  plant.turbines[name] = { active = false, rpm = 0, flow = 0, coil = false, energy = 0 }
end
local REACTOR_NAME = REACTOR_NAMES[1]

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
  isPresent = function(name) return plant.turbines[name] ~= nil or plant.reactors[name] ~= nil end,
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
    local r = plant.reactors[name]
    if not r then error('unknown peripheral ' .. tostring(name), 0) end
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
  -- Gemeinsames Dampfnetz: beide Reaktoren produzieren hinein, die ganze
  -- Flotte zieht heraus. Die Last wird gleichmaessig auf die noch
  -- laufenden Reaktoren verteilt -- faellt einer aus, traegt der andere
  -- mehr, sein Tank faellt schneller, und er faehrt von selbst hoch.
  local consumed = 0
  for _, t in pairs(plant.turbines) do
    if t.active then consumed = consumed + t.flow end
  end
  local live = 0
  for _, r in pairs(plant.reactors) do if r.active then live = live + 1 end end
  local share = live > 0 and (consumed / live) or 0
  local produced_total, stored_total = 0, 0
  for _, r in pairs(plant.reactors) do
    local power = r.active and math.max(0, (100 - r.rods) / 100) or 0
    local produced = power * 400000
    produced_total = produced_total + produced
    r.steam = math.max(0, math.min(r.steam_max, r.steam + produced - (r.active and share or 0)))
    stored_total = stored_total + r.steam
  end
  local starved = consumed > 0 and (produced_total + stored_total) < consumed
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
for _, rname in ipairs(REACTOR_NAMES) do
  modules_registry['reactor:' .. rname] =
    { id = 'reactor:' .. rname, type = 'reactor', name = rname, state = 'OFF', progress = 0 }
end

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
local rt2_reactor = require('nodes.rt.rt2_reactor')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

config.turbines = turbine_names
config.reactors = REACTOR_NAMES

local CACHE = '/xreactor_config/rt2_twin_cache.lua'
local TUNING = '/xreactor_config/rt2_twin_tuning.lua'

local last
local function tick(steps)
  for _ = 1, (steps or 1) do
    local ok, result = pcall(rt2_engine.tick, ctx)
    if not ok then error('Takt hat geworfen: ' .. tostring(result), 0) end
    last = result
    step_physics()
    clock_ms = clock_ms + 100
  end
  return last
end

rt2_engine.init({ cache_path = CACHE, tuning_path = TUNING,
                  turbine_count = TURBINE_COUNT, config = config, log = ctx.log })

-- ── Hochlauf: BEIDE Reaktoren werden bedient ─────────────────────────────

tick(1)
assert_eq(last.state, rt2_state.states.LEARNING, 'erster Takt mit Hardware fuehrt ins Einlernen')
assert_eq(#last.reactors, 2, 'beide Reaktoren bekommen eine eigene Entscheidung')
for _, rname in ipairs(REACTOR_NAMES) do
  assert_true(plant.reactors[rname].active, rname .. ' muss eingeschaltet worden sein')
end
assert_eq(#last.turbines, TURBINE_COUNT, 'die Flotte wird als EINE entschieden')

-- ── Einlernen: eine Kapazitaet fuer den ganzen Knoten ────────────────────

for _ = 1, 3000 do
  tick(1)
  if last.capacity.ready then break end
end
assert_true(last.capacity.ready, 'die Anlage muss sich ausmessen lassen -- Grund: ' .. tostring(last.capacity.reason))
assert_eq(last.capacity.total_turbines, TURBINE_COUNT)
assert_true(last.capacity.max_output > 0, 'mit positivem, gemessenem Gesamtausstoss')
local learned = last.capacity.max_output
assert_true(files[CACHE] ~= nil, 'die Messung muss im Cache landen')

-- Beide Reaktoren regeln und stehen im erlaubten Stellbereich.
for _, rname in ipairs(REACTOR_NAMES) do
  local rods = plant.reactors[rname].rods
  assert_true(rods >= rt2_reactor.ROD_MIN and rods <= rt2_reactor.ROD_MAX,
    rname .. ' muss im Stellbereich regeln, ist: ' .. tostring(rods))
end

-- ── Beide Reaktoren regeln UNABHAENGIG aus ihrem eigenen Tank ────────────

do
  -- Unabhaengigkeit sauber pruefen: die beiden Taenke werden VOR jedem
  -- Takt auf feste, unterschiedliche Fuellstaende gesetzt -- A dauerhaft
  -- randvoll, B in der Mitte. Ein einmaliges Auffuellen genuegt hier
  -- nicht: die Flotte leert den Tank in unter einer Sekunde wieder, und
  -- der Regler erkennt dann voellig richtig, dass der Stand schon faellt,
  -- statt noch Staebe nachzulegen (CONVERGING).
  local a, b = plant.reactors[REACTOR_NAMES[1]], plant.reactors[REACTOR_NAMES[2]]
  local saw_a_insert, saw_b_insert = false, false
  for _ = 1, 40 do
    a.steam = a.steam_max
    b.steam = b.steam_max * 0.5
    tick(1)
    if last.reactors[1].reason == 'TANK_FULL_INSERT' then saw_a_insert = true end
    if last.reactors[2].reason == 'TANK_FULL_INSERT' then saw_b_insert = true end
  end
  assert_true(saw_a_insert, 'der dauerhaft volle Tank muss SEINE Staebe einfahren')
  assert_true(not saw_b_insert,
    'der Reaktor mit halbvollem Tank darf davon nicht beruehrt werden')
  assert_true(last.reactors[1].rods > last.reactors[2].rods,
    'und am Ende steht A weiter eingefahren als B: ' ..
    tostring(last.reactors[1].rods) .. ' vs ' .. tostring(last.reactors[2].rods))
end

-- ── Ausloesung an EINEM Reaktor ──────────────────────────────────────────

do
  plant.reactors[REACTOR_NAMES[1]].temperature = 2600
  tick(20)

  assert_eq(plant.reactors[REACTOR_NAMES[1]].rods, rt2_reactor.ROD_MAX,
    'der ausgeloeste Reaktor faehrt die Staebe voll ein -- an der HARDWARE')
  assert_true(plant.reactors[REACTOR_NAMES[2]].rods < rt2_reactor.ROD_MAX,
    'der gesunde regelt weiter: ' .. tostring(plant.reactors[REACTOR_NAMES[2]].rods))
  assert_eq(last.tripped_reactors, 1)
  assert_true(last.state ~= rt2_state.states.SAFE,
    'der Knoten darf deswegen nicht abschalten, Zustand: ' .. tostring(last.state))

  -- Die Flotte laeuft weiter -- sie bekommt ihren Dampf jetzt von einem.
  local running = 0
  for _, t in ipairs(last.turbines) do
    if t.target_rpm >= rt2_turbine.FULL_TARGET_RPM then running = running + 1 end
  end
  assert_true(running > 0, 'die Turbinen duerfen nicht mit abgestellt werden')

  -- Und die Modulzustaende muessen das UNTERSCHEIDEN.
  assert_eq(modules_registry['reactor:' .. REACTOR_NAMES[1]].state, 'ERROR',
    'nur der ausgeloeste Reaktor wird als gestoert gemeldet')
  assert_true(modules_registry['reactor:' .. REACTOR_NAMES[2]].state ~= 'ERROR',
    'der gesunde nicht -- er ist: ' .. tostring(modules_registry['reactor:' .. REACTOR_NAMES[2]].state))

  -- Statusfelder tragen beide Reaktoren einzeln.
  local fields = rt2_engine.status_fields()
  assert_eq(#fields.reactors, 2, 'der Status meldet jeden Reaktor einzeln')
  assert_eq(fields.tripped_reactors, 1)
  local tripped_ids = {}
  for _, entry in ipairs(fields.reactors) do
    if entry.safety_tripped then tripped_ids[#tripped_ids + 1] = entry.id end
  end
  assert_eq(#tripped_ids, 1, 'genau einer gilt als ausgeloest')
  assert_eq(tripped_ids[1], REACTOR_NAMES[1])
end

-- ── Erholung ─────────────────────────────────────────────────────────────

do
  plant.reactors[REACTOR_NAMES[1]].temperature = 800
  tick(20)
  assert_eq(last.tripped_reactors, 0, 'faellt die Bedingung weg, ist kein Reaktor mehr ausgeloest')
  assert_true(plant.reactors[REACTOR_NAMES[1]].active, 'und er wird wieder eingeschaltet')
  assert_true(last.capacity.ready, 'ohne neu einzulernen')
end

-- ── Beide ausgeloest -> der ganze Knoten SAFE ────────────────────────────

do
  for _, rname in ipairs(REACTOR_NAMES) do plant.reactors[rname].temperature = 2600 end
  tick(20)
  assert_eq(last.state, rt2_state.states.SAFE, 'ohne regelbaren Reaktor ist der Knoten SAFE')
  for _, rname in ipairs(REACTOR_NAMES) do
    assert_eq(plant.reactors[rname].rods, rt2_reactor.ROD_MAX, rname .. ' faehrt voll ein')
  end
  for _, t in pairs(plant.turbines) do
    assert_eq(t.flow, 0, 'und JETZT steht auch der Flow an der Hardware auf 0')
  end
  for _, rname in ipairs(REACTOR_NAMES) do plant.reactors[rname].temperature = 800 end
  tick(20)
  assert_true(last.state ~= rt2_state.states.SAFE, 'und danach laeuft der Knoten wieder')
end

-- ── Neustart: Cache und Anlagenprofile ueberleben ────────────────────────

do
  -- Der gemessene Hoechstwert kann im Lauf noch gestiegen sein (ein neuer
  -- Spitzenwert hebt ihn an) -- verglichen wird deshalb mit dem Stand
  -- unmittelbar VOR dem Neustart, nicht mit dem beim Einlernen.
  local before_restart = last.capacity.max_output
  assert_true(before_restart >= learned, 'der Wert kann nur gestiegen sein')
  rt2_engine.init({ cache_path = CACHE, tuning_path = TUNING,
                    turbine_count = TURBINE_COUNT, config = config, log = ctx.log })
  tick(1)
  assert_true(last.capacity.ready, 'die Kapazitaet steht sofort aus dem Cache')
  assert_eq(last.capacity.max_output, before_restart, 'und zwar unveraendert')
  tick(1)
  assert_true(last.state ~= rt2_state.states.LEARNING, 'der zweite Takt ist schon im Betrieb')
  assert_eq(#last.reactors, 2, 'und beide Reaktoren sind wieder da')
end

print('rt2_twin_reactor_integration_test.lua: ok')
