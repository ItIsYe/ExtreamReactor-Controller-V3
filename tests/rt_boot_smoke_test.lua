package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Bootet nodes/rt/main.lua WIRKLICH und faehrt die Anlage im geschlossenen
-- Regelkreis -- mit der Groesse, um die es ging: 2 Reaktoren, 50 Turbinen.
--
-- Zwei Luecken schliesst dieser Test, die kein Modultest schliessen kann:
--
-- 1. main.lua ist ein Boot-Skript und nicht require()-bar. Ein nil-Zugriff
--    in init() faellt erst auf dem Computer auf -- als abgestuerzte Node.
--    Bis v768 lagen hier zwei Regler; beim Ausbau von v1 kann jede
--    Verdrahtung ins Leere zeigen, ohne dass ein Modultest es merkt.
--
-- 2. Ein Regler, der laedt, ist kein Regler, der regelt. Die Peripherie-
--    Stubs sind deshalb keine Attrappen, sondern ein kleines Modell:
--    Durchfluss treibt die Drehzahl (traege), ausgefahrene Staebe erzeugen
--    Dampf, die Turbinen verbrauchen ihn. Die Rueckkopplung laeuft damit
--    ueber den DAMPF, nicht ueber Code -- genau die Architektur, die diese
--    Anlage haben soll.
--
-- Geprueft wird der Reihe nach: der Boot laeuft durch; danach ist kein
-- einziges v1-Modul geladen; die Anlage ist vollstaendig erkannt; das
-- Einlernen wird fertig; alle 50 Turbinen fuehren Durchfluss und stehen in
-- ihrem Drehzahlband; die Staebe regeln WIRKLICH (sie stehen weder auf
-- Anschlag noch fest); und ein leerer Dampftank drosselt die Turbinen NICHT.

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
local NOW_MS = 1700000000000
os.epoch = function() return NOW_MS end
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
-- Turbine mit Traegheit: die Drehzahl laeuft dem Durchfluss nach.
-- 600 mB/t entsprechen etwa 900 RPM -- so verhaelt sich eine
-- Extreme-Reactors-Turbine im relevanten Bereich naeherungsweise.
local TURBINE_SIM = {}
local function turbine_stub(name)
  local sim = { flow = 0, rpm = 0, coil = false, active = true }
  TURBINE_SIM[name] = sim
  return {
    getConnected = function() return true end,
    getActive = function() return sim.active end,
    setActive = function(v) sim.active = v; return true end,
    getRotorSpeed = function() return sim.rpm end,
    getFluidFlowRateMax = function() return sim.flow end,
    setFluidFlowRateMax = function(v) sim.flow = v; return true end,
    getFluidFlowRate = function() return sim.flow end,
    getInductorEngaged = function() return sim.coil end,
    setInductorEngaged = function(v) sim.coil = v; return true end,
    getEnergyProducedLastTick = function()
      return sim.coil and (sim.rpm * 30) or 0
    end,
    getEnergyStored = function() return 0 end,
    getInputAmount = function() return sim.flow end,
    getInputAmountMax = function() return 4000 end,
  }
end

-- Reaktor mit Dampftank: ausgefahrene Staebe erzeugen Dampf, die Turbinen
-- verbrauchen ihn. Genau die Rueckkopplung, ueber die der Regler arbeitet --
-- durch den Dampf, nicht durch Code.
local REACTOR_SIM = {}
local function reactor_stub(name)
  local sim = { rods = 100, steam = 8000, steam_max = 16000, active = true }
  REACTOR_SIM[name] = sim
  return {
    getConnected = function() return true end,
    getActive = function() return sim.active end,
    setActive = function(v) sim.active = v; return true end,
    getControlRodLevel = function() return sim.rods end,
    setAllControlRodLevels = function(v) sim.rods = v; return true end,
    getControlRods = function() return { { level = sim.rods } } end,
    getFuelTemperature = function() return 900 end,
    getCasingTemperature = function() return 500 end,
    getEnergyStored = function() return 0 end,
    getFuelAmount = function() return 4000 end,
    getFuelAmountMax = function() return 4000 end,
    getWasteAmount = function() return 0 end,
    getHotFluidAmount = function() return sim.steam end,
    getHotFluidAmountMax = function() return sim.steam_max end,
    getColdFluidAmount = function() return 16000 end,
    getColdFluidAmountMax = function() return 16000 end,
    getEnergyProducedLastTick = function() return 0 end,
  }
end

-- Ein Simulationsschritt = ein Regeltakt (100 ms bei 10 Hz).
STEAM_PRODUCTION_SCALE = 1
local function advance_world()
  NOW_MS = NOW_MS + 100
  local demand = 0
  for _, sim in pairs(TURBINE_SIM) do
    local target_rpm = math.min(sim.flow * 1.5, 1800)
    sim.rpm = sim.rpm + (target_rpm - sim.rpm) * 0.08
    demand = demand + sim.flow
  end
  local produced = 0
  for _, sim in pairs(REACTOR_SIM) do
    produced = produced + (100 - sim.rods) * 1000 * STEAM_PRODUCTION_SCALE
  end
  local share = produced - demand
  for _, sim in pairs(REACTOR_SIM) do
    local n = 0
    for _ in pairs(REACTOR_SIM) do n = n + 1 end
    sim.steam = math.max(0, math.min(sim.steam_max, sim.steam + share / n * 0.1))
  end
end

local WRAPPED = {}
for _, n in ipairs(REACTORS) do WRAPPED[n] = reactor_stub(n) end
for _, n in ipairs(TURBINES) do WRAPPED[n] = turbine_stub(n) end
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

-- discovery_runtime.build_modules() abgreifen: dieses Verzeichnis ist das,
-- was rt2_projection.lua beschreibt und was MASTER liest.
local dr_wrapper
do
  local dr = require('nodes.rt.discovery_runtime')
  dr_wrapper = {}
  for k, v in pairs(dr) do dr_wrapper[k] = v end
  local real = dr.build_modules
  dr_wrapper.build_modules = function(devices)
    local r = real(devices)
    _G.__rt_modules_seed = r
    return r
  end
end

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
  _G.__xreactor_loaded = { ['services.service_manager'] = wrapper,
    ['nodes.rt.discovery_runtime'] = dr_wrapper }
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


local rt2_engine = _G.__xreactor_loaded['nodes.rt.rt2_engine']
local rt2_turbine = _G.__xreactor_loaded['nodes.rt.rt2_turbine']
local rt2_reactor = _G.__xreactor_loaded['nodes.rt.rt2_reactor']
assert(rt2_engine and rt2_turbine and rt2_reactor, 'der Regler ist nicht geladen')

local function run(ticks)
  for _ = 1, ticks do
    control_tick()
    advance_world()
  end
end

local function turbines_with_flow()
  local n = 0
  for _, sim in pairs(TURBINE_SIM) do if sim.flow > 0 then n = n + 1 end end
  return n
end

-- ── 1. Kein v1-Modul ist geladen ─────────────────────────────────────────
--
-- Nicht "wird nicht aufgerufen" -- gar nicht erst geladen. Ein geladenes
-- Modul haelt Zustand und kann schreiben.

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

-- ── 3. Der Regler faehrt die Anlage hoch und lernt sie ein ───────────────

run(400)
local f = rt2_engine.status_fields()
assert(f.capacity_ready == true,
  'das Einlernen wird nicht fertig (Modus ' .. tostring(f.mode) .. ')')
assert((tonumber(f.capacity_max) or 0) > 0, 'die gemessene Kapazitaet ist 0')
assert(f.node_state == 'AUTONOM',
  'nach dem Einlernen ohne Master erwarten wir AUTONOM, nicht ' .. tostring(f.node_state))

-- ── 4. Alle Turbinen laufen, im Drehzahlband ─────────────────────────────
--
-- Das ist der Punkt, an dem es im Feld wehtat: Flow 0 auf allen Turbinen,
-- waehrend Anzeige und Drehzahlmessung normal weiterliefen.

assert(turbines_with_flow() == #TURBINES,
  ('nur %d von %d Turbinen fuehren Durchfluss -- genau das Bild aus dem Feld')
    :format(turbines_with_flow(), #TURBINES))

local off_band = {}
for name, sim in pairs(TURBINE_SIM) do
  if math.abs(sim.rpm - rt2_turbine.FULL_TARGET_RPM) > rt2_turbine.RPM_BAND then
    off_band[#off_band + 1] = ('%s=%.0f'):format(name, sim.rpm)
  end
end
assert(#off_band == 0, 'Turbinen ausserhalb des Drehzahlbandes: '
  .. table.concat(off_band, ' ', 1, math.min(5, #off_band)))

-- ── 5. Die Staebe REGELN -- kein Anschlag, kein Stillstand ───────────────
--
-- Auf 100 % stehenzubleiben sah im Feld wie Regelung aus und war keine.
-- Ein Wert strikt zwischen den Grenzen ist der Nachweis, dass wirklich
-- gestellt wird; ein Tankstand im Sollband der Nachweis, dass es stimmt.

for name, sim in pairs(REACTOR_SIM) do
  assert(sim.rods > rt2_reactor.ROD_MIN and sim.rods < rt2_reactor.ROD_MAX,
    ('%s steht auf Anschlag (rods=%d) -- der Regler stellt nicht'):format(name, sim.rods))
  local fill = sim.steam / sim.steam_max
  assert(math.abs(fill - rt2_reactor.DEFAULT_TARGET_FILL) <= rt2_reactor.DEADBAND * 2,
    ('%s haelt den Tank nicht am Sollwert: fill=%.2f soll=%.2f')
      :format(name, fill, rt2_reactor.DEFAULT_TARGET_FILL))
end

-- ── 6. MASTER sieht die Module als STABLE ────────────────────────────────
--
-- rt2_projection.lua ist die einzige Quelle dieser Felder (v1s
-- Modul-Lebenszyklus, der sie fuehrte, ist entfernt). MASTERs
-- Startup-Sequencer wartet auf module.state == "STABLE" -- bleibt das aus,
-- laeuft er in einen Timeout, ohne dass an der Regelung etwas falsch waere.

do
  local seen = {}
  for _, m in pairs(_G.__rt_modules_seed or {}) do
    if type(m) == 'table' then seen[tostring(m.state)] = (seen[tostring(m.state)] or 0) + 1 end
  end
  local expected = #REACTORS + #TURBINES
  assert((seen.STABLE or 0) == expected,
    ('MASTER sieht nur %d von %d Modulen als STABLE -- sein Startup-Sequencer wartet dann ewig')
      :format(seen.STABLE or 0, expected))
end

-- ── 7. Ein LEERER Dampftank drosselt die Turbinen NICHT ──────────────────
--
-- Betreibervorgabe, wortwoertlich: "Wenn der Tank leer ist, soll der
-- Reaktor nur nachregeln, nichts anderes." Ein Versuch, aus Dampfmangel die
-- Turbinen herunterzufahren, hat schon einmal 49 von 50 abgestellt (v754,
-- zurueckgenommen in v758). Der Test haelt die Regel fest: Dampfmangel ist
-- Sache des Reaktors, nicht der Turbinen.

for _, sim in pairs(REACTOR_SIM) do sim.steam = 0 end
STEAM_PRODUCTION_SCALE = 0   -- der Reaktor kann nichts mehr liefern
run(300)

assert(turbines_with_flow() == #TURBINES,
  ('ein leerer Dampftank hat %d von %d Turbinen gedrosselt -- verboten')
    :format(#TURBINES - turbines_with_flow(), #TURBINES))
for name, sim in pairs(REACTOR_SIM) do
  assert(sim.rods <= rt2_reactor.ROD_MIN + 1,
    ('%s muss bei leerem Tank voll ausfahren, steht aber auf %d')
      :format(name, sim.rods))
end

-- ── 8. Die Aufzeichnung schreibt brauchbare Daten ────────────────────────
--
-- Sie ist das Werkzeug, mit dem im Feld nachgesehen wird, wenn der Regler
-- spinnt. Eine Aufzeichnung, die beim Boot leer bleibt oder die Spalten
-- verschiebt, ist schlimmer als keine: man glaubt ihr.

do
  local path
  for name in pairs(FILES) do
    if name:find('rt_trace', 1, true) then path = name end
  end
  assert(path, 'die Aufzeichnung hat keine Datei angelegt')

  local content = FILES[path]
  assert(content:find('# xreactor rt trace', 1, true) == 1,
    'die Datei muss ihre Spaltenkoepfe tragen')

  local kinds, fields = {}, {}
  for line in content:gmatch('[^\n]+') do
    if line:sub(1, 1) ~= '#' then
      local kind = line:match('^(%a),')
      assert(kind, 'unlesbare Zeile: ' .. line)
      kinds[kind] = (kinds[kind] or 0) + 1
      local count = 1
      for _ in line:gmatch(',') do count = count + 1 end
      fields[kind] = fields[kind] or count
      assert(fields[kind] == count,
        ('Spaltenzahl in %s-Zeilen schwankt (%d vs %d): %s')
          :format(kind, fields[kind], count, line))
    end
  end

  assert((kinds.T or 0) > 0, 'keine Sammelzeile aufgezeichnet')
  assert((kinds.R or 0) > 0, 'keine Reaktorzeile aufgezeichnet')
  assert((kinds.U or 0) > 0, 'keine Turbinenzeile aufgezeichnet')

  -- Und sie muss den Zustandswechsel enthalten, um den es geht: aus dem
  -- Einlernen in den Regelbetrieb.
  assert(content:find(',LEARNING,', 1, true), 'das Einlernen fehlt in der Aufzeichnung')
  assert(content:find(',AUTONOM,', 1, true), 'der Regelbetrieb fehlt in der Aufzeichnung')

  -- Der Platzbedarf bleibt gedeckelt. Die Zusicherung ist bewusst an die
  -- Rotation gebunden statt an eine feste Zahl: hoechstens keep+1 Dateien,
  -- jede hoechstens max_bytes plus die eine gerade geschriebene Portion.
  -- Eine Datei wird geschlossen, NACHDEM sie die Grenze reisst.
  local writer_lib = require('nodes.rt.rt2_trace_writer')
  local d = writer_lib.defaults()
  local files, total, biggest = 0, 0, 0
  for name, text in pairs(FILES) do
    if name:find('rt_trace', 1, true) then
      files = files + 1
      total = total + #text
      if #text > biggest then biggest = #text end
    end
  end
  assert(files <= d.keep + 1,
    ('hoechstens keep+1 = %d Dateien, es sind %d'):format(d.keep + 1, files))
  assert(biggest <= d.max_bytes + 32 * 1024,
    ('keine Datei darf ueber max_bytes+Zugabe wachsen: %d'):format(biggest))
  assert(total <= (d.keep + 1) * (d.max_bytes + 32 * 1024),
    'die Aufzeichnung muss ihren Platz deckeln, belegt aber ' .. total)
end

print('rt_boot_smoke_test.lua: ok')
