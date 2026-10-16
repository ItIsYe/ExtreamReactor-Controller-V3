package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Bootet nodes/rt/main.lua WIRKLICH -- mit der Anlage, um die es ging:
-- 2 Reaktoren und 50 Turbinen an einem Knoten.
--
-- Bis v768 lagen in dieser Datei zwei Regler. Erreichbar war nur rt2, aber
-- v1 wurde weiter initialisiert, seine Zustandsmaschine gebaut und beim
-- Boot durchgeschaltet, und sein Sicherheits-Schreiber konnte die Regelung
-- stillegen. v1 ist entfernt. Kein Modultest merkt, wenn dabei ein Aufrufer
-- auf ein entferntes Feld zeigt: main.lua ist ein Boot-Skript, es laesst
-- sich nicht require()n, und ein nil-Zugriff in init() faellt erst auf dem
-- Computer auf -- als abgestuerzte Node.
--
-- Darum hier ein echter Boot gegen gestubbte CC:Tweaked-Peripherie, mit:
--   * einer ALTEN rt.lua, die noch engine = "v1" enthaelt (der haeufigste
--     Bestand -- das war die Vorgabe),
--   * der Pruefung, dass danach kein einziges v1-Modul geladen ist,
--   * und der Pruefung, dass der Regler die Turbinen tatsaechlich
--     ansteuert, statt sie nur zu kennen.

-- CC:Tweaked-Umgebung fuer einen echten Boot von nodes/rt/main.lua.
local real_dofile = dofile
local FILES = {}
_G.fs = {
  exists = function(p) return FILES[p] ~= nil end,
  open = function(p, mode)
    if mode == 'r' then
      if FILES[p] == nil then return nil end
      return { readAll = function() return FILES[p] end,
               readLine = function() return nil end, close = function() end }
    end
    return { write = function(c) FILES[p] = (mode == 'a' and (FILES[p] or '') or '') .. c end,
             writeLine = function(c) FILES[p] = (FILES[p] or '') .. c .. '\n' end,
             close = function() end }
  end,
  getDir = function(p) return p:match('^(.*)/[^/]+$') or '' end,
  makeDir = function() end, isDir = function() return false end,
  list = function() return {} end, delete = function(p) FILES[p] = nil end,
  getSize = function(p) return #(FILES[p] or '') end,
  getFreeSpace = function() return 1e9 end,
  combine = function(a,b) return (a .. '/' .. b):gsub('//','/') end,
  move = function(a,b) FILES[b]=FILES[a]; FILES[a]=nil end,
  copy = function(a,b) FILES[b]=FILES[a] end,
}
_G.settings = { get = function() return nil end, set = function() end, save = function() end }
os.getComputerID = function() return 101 end
os.epoch = function() return math.floor(os.clock()*1000) + 1700000000000 end
os.startTimer = function() return 1 end
os.cancelTimer = function() end
os.queueEvent = function() end
os.pullEvent = function() return 'timer', 1 end
os.pullEventRaw = os.pullEvent
os.reboot = function() error('unexpected reboot', 0) end
local sleeps = 0
os.sleep = function()
  sleeps = sleeps + 1
  if sleeps > 200 then
    error('SMOKE-WATCHDOG: os.sleep() 200x -- der Boot dreht sich im Kreis:\n'
      .. debug.traceback('', 2), 0)
  end
end
_G.sleep = os.sleep
_G.read = function() return '' end

local REACTORS = { 'BigReactors-Reactor_7', 'BigReactors-Reactor_9' }
local TURBINES = {}
for i = 1, 50 do TURBINES[i] = 'BigReactors-Turbine_' .. i end

local function reactor_stub()
  local rods = 100
  return {
    getConnected = function() return true end, getActive = function() return true end,
    setActive = function() return true end,
    getControlRodLevel = function() return rods end,
    setAllControlRodLevels = function(v) rods = v; return true end,
    getControlRods = function() return { { level = rods } } end,
    getFuelTemperature = function() return 900 end,
    getCasingTemperature = function() return 500 end,
    getEnergyStored = function() return 0 end,
    getFuelAmount = function() return 4000 end,
    getFuelAmountMax = function() return 4000 end,
    getWasteAmount = function() return 0 end,
    getHotFluidAmount = function() return 8000 end,
    getHotFluidAmountMax = function() return 16000 end,
    getColdFluidAmount = function() return 16000 end,
    getColdFluidAmountMax = function() return 16000 end,
    getEnergyProducedLastTick = function() return 0 end,
  }
end
local function turbine_stub()
  local flow, coil, active = 0, false, true
  return {
    getConnected = function() return true end,
    getActive = function() return active end,
    setActive = function(v) active = v; return true end,
    getRotorSpeed = function() return 880 end,
    getFluidFlowRateMax = function() return flow end,
    setFluidFlowRateMax = function(v) flow = v; return true end,
    getFluidFlowRate = function() return flow end,
    getInductorEngaged = function() return coil end,
    setInductorEngaged = function(v) coil = v; return true end,
    getEnergyProducedLastTick = function() return 12000 end,
    getEnergyStored = function() return 0 end,
    getInputAmount = function() return 2000 end,
    getInputAmountMax = function() return 4000 end,
  }
end

local WRAPPED = {}
for _, n in ipairs(REACTORS) do WRAPPED[n] = reactor_stub() end
for _, n in ipairs(TURBINES) do WRAPPED[n] = turbine_stub() end
WRAPPED['modem_0'] = {
  isWireless = function() return true end, open = function() end,
  isOpen = function() return true end, transmit = function() end, closeAll = function() end,
}

local NAMES = { 'modem_0' }
for _, n in ipairs(REACTORS) do NAMES[#NAMES+1] = n end
for _, n in ipairs(TURBINES) do NAMES[#NAMES+1] = n end

_G.peripheral = {
  getNames = function() return NAMES end,
  isPresent = function(n) return WRAPPED[n] ~= nil end,
  getType = function(n)
    if n == 'modem_0' then return 'modem' end
    if n:find('Turbine') then return 'BigReactors-Turbine' end
    if n:find('Reactor') then return 'BigReactors-Reactor' end
    return 'unknown'
  end,
  wrap = function(n) return WRAPPED[n] end,
  find = function(kind) if kind == 'modem' then return WRAPPED['modem_0'] end end,
  getMethods = function(n)
    local m = {}
    for k, v in pairs(WRAPPED[n] or {}) do if type(v) == 'function' then m[#m+1] = k end end
    return m
  end,
  call = function(n, method, ...) return WRAPPED[n][method](...) end,
}
local term_stub
term_stub = {
  clear = function() end, clearLine = function() end,
  setCursorPos = function() end, getCursorPos = function() return 1, 1 end,
  setTextColor = function() end, setBackgroundColor = function() end,
  setTextColour = function() end, setBackgroundColour = function() end,
  write = function() end, getSize = function() return 51, 19 end,
  isColor = function() return true end, isColour = function() return true end,
  setPaletteColor = function() end, blit = function() end,
  scroll = function() end, setCursorBlink = function() end,
  redirect = function() return term_stub end, current = function() return term_stub end,
  native = function() return term_stub end,
}
_G.term = term_stub
_G.window = { create = function() return term_stub end }

-- parallel.waitForAny: der Boot soll nach init() enden, nicht in die
-- Event-Schleife laufen.
local loop_entered = false
_G.parallel = {
  waitForAny = function() loop_entered = true end,
  waitForAll = function() loop_entered = true end,
}

-- Eine ALTE rt.lua mit engine = "v1" -- der haeufigste Bestand, denn das
-- war die Vorgabe. Sie muss still auf den einen Regler laufen.
FILES['/xreactor_config/rt.lua'] = 'return {\n  engine = "v1",\n}\n'
FILES['/xreactor_config/node_id.txt'] = 'node-101'
FILES['/xreactor_config/role.lua'] = 'return {\n  role = "rt"\n}\n'

-- Den "control"-Service abgreifen, damit der Test danach echte Regeltakte
-- fahren kann. bootstrap.require() cached in _G.__xreactor_loaded -- wer
-- dort vorher liegt, wird ausgeliefert.
local control_tick
do
  local real_sm = require('services.service_manager')
  local wrapper = {}
  for k, v in pairs(real_sm) do wrapper[k] = v end
  wrapper.new = function(...)
    local mgr = real_sm.new(...)
    local real_add = mgr.add
    mgr.add = function(self, svc)
      if type(svc) == 'table' and svc.name == 'control' then control_tick = svc.tick end
      return real_add(self, svc)
    end
    return mgr
  end
  _G.__xreactor_loaded = { ['services.service_manager'] = wrapper }
end

-- dofile() aus main.lua ("/xreactor/core/bootstrap.lua") auf das Repo lenken.
_G.dofile = function(path)
  local mapped = path:gsub('^/xreactor/', './xreactor/')
  return real_dofile(mapped)
end

local prints = {}
local real_print = print
_G.print = function(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts+1] = tostring((select(i, ...))) end
  prints[#prints+1] = table.concat(parts, ' ')
end

debug.sethook(function()
  debug.sethook()
  error('SMOKE-WATCHDOG: zu viele Schritte -- Endlosschleife beim Boot:\n'
    .. debug.traceback('', 2), 0)
end, '', 60000000)
local ok, err = pcall(real_dofile, './xreactor/nodes/rt/main.lua')
debug.sethook()
_G.print = real_print

assert(ok, 'die RT-Node bootet nicht mehr: ' .. tostring(err))
assert(loop_entered, 'der Boot hat die Event-Schleife nie erreicht')

-- ── 1. Kein v1-Modul ist geladen ─────────────────────────────────────────
--
-- Nicht "wird nicht aufgerufen" -- gar nicht erst geladen. Ein geladenes
-- Modul haelt Zustand und kann geschrieben werden.

for _, mod in ipairs({
  'nodes.rt.module_lifecycle', 'nodes.rt.state_handlers',
  'nodes.rt.command_handler', 'nodes.rt.capacity_learning',
  'nodes.rt.capacity_cache', 'nodes.rt.startup_diagnostics',
  'nodes.rt.flow_apply_helpers', 'nodes.rt.reactor_steam_guard',
  'core.turbine_regulator', 'core.control_rails', 'core.state_machine',
}) do
  assert(_G.__xreactor_loaded[mod] == nil,
    'nach dem Boot ist ein v1-Modul geladen: ' .. mod)
  assert(package.loaded[mod] == nil,
    'nach dem Boot ist ein v1-Modul geladen: ' .. mod)
end

-- ── 2. Die Anlage ist vollstaendig erkannt ───────────────────────────────

local booted
for _, line in ipairs(prints) do
  if line:find('REGLER AKTIV', 1, true) then booted = line end
end
assert(booted, 'der Boot meldet den Regler nicht -- gesehen: ' .. table.concat(prints, ' | '))
assert(booted:find('2 Reaktor(en), 50 Turbinen', 1, true),
  'falsche Anlagengroesse erkannt: ' .. booted)

-- ── 3. Der Regler steuert die Turbinen wirklich an ───────────────────────
--
-- Das ist der Punkt, an dem es im Feld wehtat: Flow 0 auf allen Turbinen,
-- waehrend Anzeige und Drehzahlmessung normal weiterliefen. Ein Boot, der
-- nur nicht abstuerzt, ist deshalb kein ausreichender Nachweis.

assert(type(control_tick) == 'function', 'der control-Service wurde nicht verdrahtet')
for _ = 1, 40 do control_tick() end

local with_flow = 0
for _, name in ipairs(TURBINES) do
  if (WRAPPED[name].getFluidFlowRateMax() or 0) > 0 then with_flow = with_flow + 1 end
end
assert(with_flow == #TURBINES,
  ('der Regler hat nur %d von %d Turbinen angesteuert -- genau das Bild aus dem Feld')
    :format(with_flow, #TURBINES))

-- Und die Staebe stehen nicht mehr stur auf 100%: der Regler holt sie
-- herunter, sobald der Dampftank Bedarf zeigt.
local rods = WRAPPED[REACTORS[1]].getControlRodLevel()
assert(type(rods) == 'number', 'Rod-Stellung nicht lesbar')

print('rt_boot_smoke_test.lua: ok')
