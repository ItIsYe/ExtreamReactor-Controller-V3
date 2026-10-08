package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Der lokale Monitor der RT-Node darf nicht nur beim Start gesucht werden.
--
-- Bis v813 loeste nodes/rt/main.lua den Monitor genau einmal in init() auf.
-- War er beim Start nicht da -- sein Chunk noch nicht geladen, er wurde erst
-- spaeter gebaut oder neu angeschlossen --, zeichnete die Node bis zum
-- Neustart auf das Terminal. FUEL/WATER/REPROCESSOR suchen ihn bei jeder
-- Discovery neu; RT jetzt auch.

local boot = require('support.cc_node_boot')
local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Ein Monitor wie in CC:Tweaked, der seine Zeichenaufrufe zaehlt.
local function new_monitor_stub()
  local stub = { draws = 0, scale = 1 }
  local function draw() stub.draws = stub.draws + 1 end
  stub.methods = {
    clear = draw, clearLine = draw, write = draw, blit = draw, scroll = function() end,
    setCursorPos = function() end, getCursorPos = function() return 1, 1 end,
    setTextColor = function() end, setBackgroundColor = function() end,
    setTextColour = function() end, setBackgroundColour = function() end,
    getTextColor = function() return 1 end, getBackgroundColor = function() return 32768 end,
    isColor = function() return true end, isColour = function() return true end,
    setCursorBlink = function() end, setPaletteColor = function() end,
    getSize = function() return 39, 19 end,
    getTextScale = function() return stub.scale end,
    setTextScale = function(v) stub.scale = v end,
  }
  return stub
end

boot.reset_module_cache()
local rt = plant.new_rt({ turbines = 3, node_id = 'node-101' })
local master = plant.new_master({ node_id = 'master-1' })
plant.boot_all({
  { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
  { name = 'MASTER', env = master, main = 'master/main.lua' },
})
local net = bus_lib.new()
net:attach('RT', rt)
net:attach('MASTER', master)
net:run(300)

-- Jetzt kommt der Monitor dazu. Die Discovery laeuft alle 10 s, nach drei
-- unveraenderten Laeufen nur noch alle 60 s -- 70 s reichen in jedem Fall.
local monitor = new_monitor_stub()
rt:add_peripheral('monitor_0', 'monitor', monitor.methods)
net:run(700)

assert_true(monitor.draws > 0,
  'die RT-Node zeichnet nicht auf einen Monitor, der nach dem Start dazukommt -- sie sucht ihn nur beim Start')

-- Und er ist wirklich der Hauptschirm geworden: weitere Takte zeichnen weiter
-- auf ihn.
local before = monitor.draws
net:run(50)
assert_true(monitor.draws > before, 'der Monitor wird nach dem Wechsel nicht weiter bezeichnet')

print('ok rt_monitor_late_attach_test')
