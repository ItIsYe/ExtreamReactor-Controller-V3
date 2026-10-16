package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Der Update-Quiesce der RT-Node nach dem Laden der Anlage-Chunks.
--
-- tests/plant_chunk_reload_test.lua zeigt, dass sich Regelung und Status
-- nach einem Chunk-Ausfall von selbst erholen, und vermerkt eine bekannte
-- Luecke: nach einer Phase mit verkuerzten Methodenlisten blieben
-- turbine_control.lua's Faehigkeiten-Cache und die wrap-Handles in
-- ctx.peripherals veraltet. Der Update-Quiesce lief bis v813 genau ueber
-- diese beiden -- er wurde nie bestaetigt, und installer/auto_update.lua
-- erzwang das Update nach 60 s ohne Bestaetigung des sicheren Zustands.
--
-- Hier: echte RT- und MASTER-Node am Funknetz, die Anlage verschwindet,
-- kommt mit verkuerzten Listen zurueck (Multiblock im Zusammenbau) und dann
-- vollstaendig. Danach muss on_quiesce() -- genau die Funktion, die
-- run_fast_loop() bei einem Update aufruft -- den sicheren Zustand
-- herstellen UND bestaetigen.

local boot = require('support.cc_node_boot')
local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')
local update_handshake = require('core.update_handshake')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local REACTOR = 'BigReactors-Reactor_1'
local TURBINES = { 'BigReactors-Turbine_1', 'BigReactors-Turbine_2', 'BigReactors-Turbine_3' }
local PLANT = { REACTOR, TURBINES[1], TURBINES[2], TURBINES[3] }

-- Wie in plant_chunk_reload_test.lua: laenger als ein langsamer
-- Discovery-Lauf, sonst sieht die Discovery die verkuerzte Phase nicht.
local OUTAGE_ROUNDS = 700
local RECOVERY_ROUNDS = 1500

local SHORT_TURBINE = { getActive = true, setActive = true, getRotorSpeed = true,
  getInductorEngaged = true, setInductorEngaged = true }
local SHORT_REACTOR = { getActive = true, setActive = true }

local function is_turbine(name) return name:find('Turbine', 1, true) ~= nil end

local function subset(methods, keep)
  local out = {}
  for name, fn in pairs(methods) do
    if keep[name] then out[name] = fn end
  end
  return out
end

local function setup()
  boot.reset_module_cache()
  -- Ohne Handshake verdrahtet die RT-Node keinen Quiesce (main.lua liest ihn
  -- beim Laden, wie start.lua ihn bereitstellt).
  _G.__xreactor_update_handshake = update_handshake.new()
  local rt = plant.new_rt({ turbines = 3, node_id = 'node-101' })
  -- Wie Extreme Reactors: alle Stabstellungen auf einmal lesbar. Ohne eine
  -- VOLLSTAENDIGE Rueckmessung bestaetigt adapters/reactor.lua "Staebe voll
  -- eingefahren" mit Absicht nicht (tests/reactor_update_quiesce_all_rods_
  -- test.lua) -- der Stub der Harness kennt nur getControlRodLevel(0).
  local reactor_stub = rt.plant.reactors[1]
  reactor_stub.methods.getControlRodsLevels = function()
    local levels = {}
    for index = 0, reactor_stub.rod_count - 1 do levels[index] = reactor_stub.rods end
    return levels
  end
  local master = plant.new_master({ node_id = 'master-1' })
  plant.boot_all({
    { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
    { name = 'MASTER', env = master, main = 'master/main.lua' },
  })
  local net = bus_lib.new()
  net:attach('RT', rt)
  net:attach('MASTER', master)
  local site = { rt = rt, net = net, full = {} }
  for index, name in ipairs(TURBINES) do site.full[name] = rt.plant.turbines[index].methods end
  site.full[REACTOR] = rt.plant.reactors[1].methods
  net:run(300)
  return site
end

local function plug(site, names, shortened)
  for _, name in ipairs(names) do
    local methods = site.full[name]
    local ptype = is_turbine(name) and 'BigReactors-Turbine' or 'BigReactors-Reactor'
    if shortened then
      methods = subset(methods, is_turbine(name) and SHORT_TURBINE or SHORT_REACTOR)
    end
    site.rt:add_peripheral(name, ptype, methods)
  end
end

-- Ruft on_quiesce() wie run_fast_loop(): je Takt einmal, bis bestaetigt.
local function quiesce(site, label)
  local opts = site.rt.loops.fast and site.rt.loops.fast.quiesce_opts
  assert_true(opts and type(opts.on_quiesce) == 'function', label .. ': die RT-Node verdrahtet keinen Quiesce')
  for _ = 1, 10 do
    site.rt:activate()
    if opts.on_quiesce() == true then return true end
    site.net:run(1)
  end
  return false
end

local function assert_safe(site, label)
  for index, name in ipairs(TURBINES) do
    local stub = site.rt.plant.turbines[index]
    assert_true(stub.flow == 0, ('%s: %s hat Durchfluss %s statt 0'):format(label, name, tostring(stub.flow)))
    assert_true(stub.active == false, label .. ': ' .. name .. ' laeuft noch')
    assert_true(stub.coil == true, label .. ': die Coil von ' .. name .. ' ist nicht eingehaengt')
  end
  local reactor = site.rt.plant.reactors[1]
  assert_true(reactor.active == false, label .. ': der Reaktor laeuft noch')
end

-- ══ 1. Grundfall: der Quiesce wird bestaetigt ═════════════════════════════
do
  local site = setup()
  assert_true(quiesce(site, 'Grundfall'), 'Grundfall: der Update-Quiesce wird nicht bestaetigt')
  assert_safe(site, 'Grundfall')
end

-- ══ 2. Nach dem Chunk-Laden mit verkuerzten Methodenlisten ═══════════════
do
  local site = setup()
  for _, name in ipairs(PLANT) do site.rt:remove_peripheral(name) end
  site.net:run(OUTAGE_ROUNDS)
  plug(site, PLANT, true)
  site.net:run(OUTAGE_ROUNDS)
  plug(site, PLANT, false)
  site.net:run(RECOVERY_ROUNDS)
  assert_true(quiesce(site, 'Chunk'),
    'Chunk: nach verkuerzten Methodenlisten wird der Update-Quiesce nie bestaetigt'
      .. ' -- er haengt an veralteten wrap-Handles oder am Faehigkeiten-Cache')
  assert_safe(site, 'Chunk')
end

_G.__xreactor_update_handshake = nil
print('ok rt_update_quiesce_after_chunk_reload_test')
