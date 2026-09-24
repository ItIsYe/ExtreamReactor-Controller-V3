package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- LEBENSLAUF-PRUEFUNG: PC-Start -> Einlernen -> AUTONOM -> MASTER -> zurueck,
-- Sicherheitsausloesung und Erholung, Neustart aus dem Cache.
--
-- Geht durch die ECHTE Engine und den echten Adapterstapel auf einer
-- simulierten Anlage mit 25 Turbinen und einem Reaktor. Die Einzeltests
-- pruefen jeweils ein Modul; diese Datei prueft, dass die Abschnitte auch
-- in der richtigen Reihenfolge ineinandergreifen -- genau dort lagen in
-- dieser Umbauphase die meisten Fehler.

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
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_reactor = require('nodes.rt.rt2_reactor')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local CACHE = '/xreactor_config/rt2_lifecycle_cache.lua'
local phase_log = {}
local function phase(name) phase_log[#phase_log + 1] = name end

-- Einen Takt fahren, wie main.lua's control_tick() es tut.
local last
local function tick(steps, ms)
  for _ = 1, (steps or 1) do
    local ok, result = pcall(rt2_engine.tick, ctx)
    if not ok then error('Takt hat geworfen: ' .. tostring(result), 0) end
    last = result
    step_physics()
    clock_ms = clock_ms + (ms or 100)
  end
  return last
end

local function count_targets()
  local full, partial, off = 0, 0, 0
  for _, t in ipairs(last.turbines) do
    if t.target_rpm <= 0 then off = off + 1
    elseif t.target_rpm >= rt2_turbine.FULL_TARGET_RPM then full = full + 1
    else partial = partial + 1 end
  end
  return full, partial, off
end

-- ═══ A · Hochfahren ohne erkannte Hardware ═══════════════════════════════
phase('A INIT ohne Hardware')
-- Vor der Discovery sind beide Listen leer -- so startet der Rechner.
config.turbines, config.reactors = {}, {}
rt2_engine.init({ cache_path = CACHE, turbine_count = 0, log = ctx.log })
tick(3)
assert_eq(last.state, rt2_state.states.INIT, 'ohne entdeckte Geraete bleibt der Knoten in INIT')
assert_eq(#last.turbines, 0, 'und trifft keine Turbinenentscheidung')
assert_true(not plant.reactor.active, 'vor allem fasst er die Hardware nicht an')
for _, t in pairs(plant.turbines) do
  assert_true(not t.active, 'keine Turbine darf ohne Discovery eingeschaltet werden')
end

-- ═══ B · Discovery findet die Anlage ═════════════════════════════════════
phase('B Discovery -> LEARNING')
config.turbines = turbine_names
config.reactors = { REACTOR_NAME }
rt2_engine.init({ cache_path = CACHE, turbine_count = TURBINE_COUNT, log = ctx.log })

tick(1)
assert_eq(last.state, rt2_state.states.LEARNING, 'erster Takt mit Hardware fuehrt ins Einlernen')
assert_true(plant.reactor.active, 'der Reaktor wird selbst eingeschaltet, wenn er aus gelesen wird')
local full = count_targets()
assert_eq(full, TURBINE_COUNT, 'beim Einlernen bekommt JEDE Turbine das volle Ziel')
assert_true(last.max_active == nil, 'und es wird dabei nichts gedeckelt')

-- Alle Turbinen muessen eingeschaltet worden sein.
local switched_on = 0
for _, t in pairs(plant.turbines) do if t.active then switched_on = switched_on + 1 end end
assert_eq(switched_on, TURBINE_COUNT, 'jede Turbine wird eingeschaltet')

-- ═══ C · Einlernen laeuft durch ══════════════════════════════════════════
phase('C Einlernen')
for _ = 1, 400 do
  tick(1)
  if last.capacity.ready then break end
end
assert_true(last.capacity.ready, 'die Anlage muss sich ausmessen lassen -- Grund: ' .. tostring(last.capacity.reason))
assert_true(last.capacity.max_output > 0, 'mit einem positiven, gemessenen Gesamtausstoss')
assert_eq(last.capacity.sustainable_turbines, TURBINE_COUNT,
  'diese Anlage traegt ihre ganze Flotte, das muss die Messung auch so sehen')
assert_true(last.capacity.at_target >= math.ceil(TURBINE_COUNT * 0.8),
  'und die 80-%-Schwelle war erfuellt, als gemessen wurde')
local learned_max = last.capacity.max_output

-- Der Cache muss geschrieben sein, sonst war das Einlernen beim naechsten
-- Start umsonst.
assert_true(files[CACHE] ~= nil, 'die Messung muss im Cache landen')

-- ═══ D · Ohne MASTER -> AUTONOM ══════════════════════════════════════════
phase('D AUTONOM')
tick(2)
assert_eq(last.state, rt2_state.states.AUTONOM, 'ohne MASTER laeuft der Knoten autonom weiter')
full = count_targets()
assert_eq(full, TURBINE_COUNT, 'in AUTONOM haelt jede Turbine das feste Ziel')
assert_true(plant.reactor.rods >= rt2_reactor.ROD_MIN and plant.reactor.rods <= rt2_reactor.ROD_MAX,
  'die Staebe bleiben im erlaubten Stellbereich, hier: ' .. tostring(plant.reactor.rods))

-- Der Reaktor regelt NUR aus seinem Dampftank -- in AUTONOM wie ueberall.
local before_rods = plant.reactor.rods
-- Den Tank randvoll HALTEN, nicht nur einmal fuellen: im vereinfachten
-- Anlagenmodell zieht die Flotte ihn binnen weniger Takte wieder leer,
-- und die Pruefung liefe dann gegen einen inzwischen LEEREN Tank -- bei
-- dem der Regler die Staebe voellig richtig wieder ausfaehrt. Genau
-- dieser Ablauf hat die Zusicherung frueher zufaellig bestehen lassen.
for _ = 1, 10 do
  plant.reactor.steam = plant.reactor.steam_max
  tick(1)
end
assert_true(plant.reactor.rods > before_rods,
  'ein voller Dampftank muss die Staebe einfahren (weniger Leistung), war ' ..
  tostring(before_rods) .. ' jetzt ' .. tostring(plant.reactor.rods))

-- ═══ E · MASTER meldet sich ══════════════════════════════════════════════
phase('E MASTER uebernimmt')
rt2_engine.note_master_seen(clock_ms)
tick(1)
assert_eq(last.state, rt2_state.states.MASTER, 'eine MASTER-Nachricht allein genuegt -- kein Kommando noetig')

-- ═══ F · MASTER gibt Leistung vor ════════════════════════════════════════
phase('F Leistungsvorgabe 50 %')
local res = rt2_engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } })
assert_true(res.ok, 'im MASTER-Zustand muss die Vorgabe angenommen werden: ' .. tostring(res.error))
rt2_engine.note_master_seen(clock_ms)
tick(1)
local f, p, off = count_targets()
assert_eq(f + p + off, TURBINE_COUNT, 'jede Turbine bekommt genau eine Zuweisung')
assert_true(f >= 12 and f <= 13, '50 % von 25 ergibt rund 12 Turbinen auf Vollast, hier: ' .. tostring(f))
assert_true(off >= 12, 'und der Rest wird geparkt, hier: ' .. tostring(off))

-- Geparkte Turbinen: Flow sofort 0, Spule bremst weiter (erntet dabei).
local parked_checked = 0
for _, t in ipairs(last.turbines) do
  if t.target_rpm <= 0 then
    assert_eq(t.flow_decision.flow, 0, 'eine geparkte Turbine bekommt sofort Flow 0')
    if t.rpm > rt2_turbine.COIL_BRAKE_RELEASE_RPM then
      assert_eq(t.coil_decision.engaged, true, 'und bremst ueber die Spule, solange sie noch dreht')
      parked_checked = parked_checked + 1
    end
  end
end
assert_true(parked_checked > 0, 'mindestens eine geparkte Turbine drehte noch und musste bremsen')

-- ═══ G · MASTER verstummt -> zurueck nach AUTONOM ════════════════════════
phase('G MASTER faellt aus')
tick(200)   -- laenger als das 12-s-Fenster
assert_eq(last.state, rt2_state.states.AUTONOM, 'ohne Nachrichten faellt der Knoten selbsttaetig auf AUTONOM zurueck')
full = count_targets()
assert_eq(full, TURBINE_COUNT, 'und faehrt wieder alle Turbinen auf das feste Ziel')
assert_true(last.capacity.ready, 'der gelernte Wert ueberlebt den Moduswechsel')
assert_eq(last.capacity.max_output, learned_max, 'unveraendert')

-- ═══ H · Sicherheitsausloesung ═══════════════════════════════════════════
phase('H SAFE')
plant.reactor.temperature = 2600
tick(10)
assert_eq(last.state, rt2_state.states.SAFE, 'eine Uebertemperatur muss ausloesen')
assert_eq(plant.reactor.rods, rt2_reactor.ROD_MAX, 'Staebe voll eingefahren')
for _, t in ipairs(last.turbines) do
  assert_eq(t.target_rpm, 0, 'im SAFE bekommt keine Turbine ein Ziel')
  assert_eq(t.flow_decision.flow, 0, 'und keine bekommt Dampf')
end
for _, t in pairs(plant.turbines) do
  assert_eq(t.flow, 0, 'auch an der Hardware muss der Flow auf 0 stehen')
end

-- ═══ I · Erholung ════════════════════════════════════════════════════════
phase('I Erholung')
plant.reactor.temperature = 800
tick(10)
assert_true(last.state == rt2_state.states.AUTONOM or last.state == rt2_state.states.MASTER,
  'faellt die Bedingung weg, geht es direkt zurueck in den Betrieb, nicht ins Einlernen')
assert_true(last.capacity.ready, 'und ohne neu einzulernen -- die Kapazitaet ist ja bekannt')

-- ═══ J · Neustart des Rechners ═══════════════════════════════════════════
phase('J Neustart aus dem Cache')
rt2_engine.init({ cache_path = CACHE, turbine_count = TURBINE_COUNT, log = ctx.log })
tick(1)
assert_eq(last.state, rt2_state.states.LEARNING, 'auch mit Cache laeuft der erste Takt ueber LEARNING')
assert_true(last.capacity.ready, 'aber die Kapazitaet steht sofort -- kein erneutes Ausmessen')
assert_eq(last.capacity.max_output, learned_max, 'und zwar der gemessene Wert von vorhin')
tick(1)
assert_true(last.state ~= rt2_state.states.LEARNING, 'der zweite Takt ist schon im Betrieb')

-- ═══ K · Was MASTER zu sehen bekommt ═════════════════════════════════════
phase('K Statusfelder')
local fields = rt2_engine.status_fields()
assert_eq(fields.capacity_ready, true)
assert_eq(fields.capacity_max, learned_max, 'MASTER teilt gegen genau diese Zahl auf')
assert_eq(fields.capacity_total_turbines, TURBINE_COUNT)
assert_eq(fields.capacity_sustainable_turbines, TURBINE_COUNT)
assert_true(fields.capacity_stable_turbines ~= nil, 'MASTER liest capacity_stable_turbines')
assert_true(fields.capacity_source ~= nil, 'und capacity_source')
assert_true(fields.node_state ~= nil and fields.node_state ~= 'STARTUP',
  'der gemeldete Knotenzustand muss den Betrieb widerspiegeln, ist: ' .. tostring(fields.node_state))
assert_eq(#fields.turbines, TURBINE_COUNT, 'und jede Turbine taucht im Status auf')

-- Modulzustaende: nichts darf auf dem Bootwert "OFF" haengenbleiben.
local off_modules = 0
for _, module in pairs(modules_registry) do
  if module.state == 'OFF' then off_modules = off_modules + 1 end
end
assert_eq(off_modules, 0, 'kein Modul darf nach dem Hochlauf noch auf OFF stehen')

-- ═══ L · Vorgabe im falschen Zustand ═════════════════════════════════════
phase('L Vorgabe ohne MASTER')
-- Ohne MASTER-Verbindung faellt der Knoten nach AUTONOM. Eine Vorgabe
-- muss dort ABGELEHNT werden, mit einem echten Grund -- der alte
-- Stillschweigend-OK-Fehler hatte MASTER glauben lassen, seine
-- Leistungsaufteilung sei angekommen.
tick(200)
assert_eq(last.state, rt2_state.states.AUTONOM, 'Vorbedingung: kein MASTER verbunden')
local rejected = rt2_engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 40 } })
assert_eq(rejected.ok, false, 'eine Vorgabe ausserhalb von MASTER muss abgelehnt werden')
assert_eq(rejected.reason_code, 'INVALID_STATE', 'und zwar mit nachvollziehbarem Grund')

-- Unsinnige Werte ebenso, auch im richtigen Zustand.
rt2_engine.note_master_seen(clock_ms)
tick(1)
assert_eq(last.state, rt2_state.states.MASTER)
local bad = rt2_engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 400 } })
assert_eq(bad.ok, false, 'ein Prozentwert ausserhalb 0..100 muss abgelehnt werden')
assert_eq(bad.reason_code, 'INVALID_VALUE')

-- ═══ M · Handabschaltung und Rueckweg ════════════════════════════════════
phase('M SCRAM von Hand')
local scram = rt2_engine.handle_command({ target = 'SCRAM' })
assert_true(scram.ok, 'ein SCRAM muss aus jedem Zustand angenommen werden')
tick(2)
assert_eq(last.state, rt2_state.states.SAFE, 'und den Knoten sofort stillsetzen')
assert_eq(plant.reactor.rods, rt2_reactor.ROD_MAX, 'Staebe voll eingefahren')

-- Der Riegel haelt: er faellt NICHT von allein, obwohl physikalisch alles
-- in Ordnung ist.
tick(50)
assert_eq(last.state, rt2_state.states.SAFE, 'ein Hand-SCRAM haelt, bis er geloest wird')

-- Und im SAFE werden gewoehnliche Kommandos blockiert.
local blocked = rt2_engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } })
assert_eq(blocked.ok, false, 'im SAFE gibt es keine Leistungsvorgabe')
assert_eq(blocked.reason_code, 'SAFE_MODE')

-- Der Weg zurueck -- ohne den waere SAFE eine Sackgasse bis zum Neustart.
local restart = rt2_engine.handle_command({ target = 'REQUEST_STARTUP_MODULE' })
assert_true(restart.ok, 'der Startbefehl muss den Riegel loesen')
rt2_engine.note_master_seen(clock_ms)
tick(3)
assert_true(last.state == rt2_state.states.MASTER or last.state == rt2_state.states.AUTONOM,
  'danach laeuft der Knoten wieder, ist aber: ' .. tostring(last.state))
assert_true(last.capacity.ready, 'und muss dafuer nicht neu einlernen')

print('rt2_lifecycle_test.lua: ok (' .. table.concat(phase_log, ' | ') .. ')')
