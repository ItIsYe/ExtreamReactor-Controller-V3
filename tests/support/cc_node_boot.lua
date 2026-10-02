-- tests/support/cc_node_boot.lua
--
-- Eine CC:Tweaked-Umgebung, in der sich eine ECHTE Node booten laesst --
-- nodes/<rolle>/main.lua, unveraendert, mit ihrem eigenen Bootstrap, ihrem
-- Config-Laden, ihrer Normalisierung und ihrem Service-Aufbau.
--
-- WARUM DAS GEBRAUCHT WIRD. Die Modultests dieses Projekts pruefen
-- Funktionen. Was im Betrieb kaputtgeht, sind dagegen fast immer die NAEHTE:
--
--   * eine Config-Datei, die beim Booten geladen, aber danach nie wieder
--     gelesen wird,
--   * ein Default, der ueber migrate_config() persistiert wird und einen
--     geaenderten Default nie ankommen laesst,
--   * ein Payload-Feld, das die eine Seite umbenennt und die andere noch
--     unter dem alten Namen liest,
--   * eine Eigenschaft, die nur als Nebenwirkung einer Umsetzung bestand
--     (siehe rt2_uneven_control_rods_test.lua).
--
-- Keine dieser Naehte liegt in einer Funktion, die man einzeln aufrufen
-- kann. main.lua ist ein Boot-Skript -- es laesst sich nicht require()n, und
-- ein nil-Zugriff darin faellt erst auf dem Computer auf, als abgestuerzte
-- Node. tests/rt_boot_smoke_test.lua hat genau dafuer eine Umgebung
-- aufgebaut; dieses Modul ist dieselbe Idee, nur wiederverwendbar und fuer
-- jede Rolle.
--
-- VERWENDUNG
--
--   local boot = require('support.cc_node_boot')
--   local env = boot.new({ computer_id = 102, node_id = 'fuel-1' })
--   env:add_file('/xreactor_config/fuel.lua', 'return { ... }')
--   env:add_peripheral('meBridge_0', 'meBridge', { listItems = ... })
--   env:install()
--   env:boot('nodes/fuel/main.lua')
--   env:tick_service('logistics', 3)
--
-- Nach dem Boot liegen die abgegriffenen Services in env.services (nach
-- Name), alle print()-Ausgaben in env.prints und alle utils.log()-Zeilen in
-- env.logs.
--
-- GRENZE, ausdruecklich: in EINEM Lua-Prozess laesst sich nur EINE Node
-- booten. Die Rollen teilen sich Modul-Caches (_G.__xreactor_loaded) und
-- modulglobalen Zustand (z.B. den Faehigkeits-Cache in adapters/turbine.lua).
-- Mehrere Rollen gegeneinander laufen zu lassen ist Sache der
-- Nachrichten-Ebene: jede Node bootet in ihrem eigenen Prozess/Testlauf, und
-- die Payloads wandern ueber support/node_message_bus.lua.

local M = {}

-- Das UNBERUEHRTE require() von Lua, einmal beim Laden dieses Moduls
-- festgehalten.
--
-- Warum das noetig ist: core/bootstrap.lua merkt sich beim Laden
-- native_require = _G.require und setzt in setup() anschliessend
-- _G.require = bootstrap.require. Wird eine zweite Rolle gebootet, laedt
-- main.lua bootstrap.lua erneut per dofile -- und diese zweite Instanz
-- fuengt sich als "native" require die bootstrap.require der ERSTEN ein.
-- Jede Delegation laeuft dann im Kreis, und der Boot stirbt mit
-- "Circular dependency while loading shared.constants".
local PRISTINE_REQUIRE = rawget(_G, 'require')

-- Kennung, mit der die Umgebung das Erreichen der Event-Schleife meldet.
--
-- Nicht jede Rolle laeuft ueber parallel.waitForAny(): master/runtime_loop.lua
-- hat seine eigene Schleife mit os.pullEvent(). Ein gestubbtes pullEvent, das
-- immer dasselbe Event liefert, laesst den Boot dort unendlich kreisen -- der
-- Test haengt, statt etwas zu sagen. Nach einer Handvoll Events wird deshalb
-- genau dieser Fehler geworfen, und boot() liest ihn als "der Boot ist durch,
-- die Rolle wartet jetzt auf Ereignisse".
M.EVENT_LOOP_SENTINEL = 'XR_BOOT_EVENT_LOOP_REACHED'

local Env = {}
Env.__index = Env

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    computer_id = opts.computer_id or 100,
    node_id = opts.node_id,
    files = {},
    wrapped = {},
    types = {},
    names = {},
    prints = {},
    logs = {},
    services = {},
    transmitted = {},
    received = {},
    clock_ms = opts.start_ms or 1700000000000,
    sleeps = 0,
    sleep_limit = opts.sleep_limit or 400,
    pull_events = 0,
    pull_event_limit = opts.pull_event_limit or 40,
    loop_entered = false,
    loop_errors = {},
    loops = {},
  }, Env)
  return self
end

function Env:add_file(path, content)
  self.files[path] = content
  return self
end

function Env:read_file(path)
  return self.files[path]
end

-- methods: Tabelle von Funktionen. peripheral.getMethods() leitet die
-- Methodenliste daraus ab, genau wie die echte Peripherie es tut -- ein Test
-- kann eine Methode also weglassen, um "diese Turbine kennt das nicht" zu
-- beschreiben.
function Env:add_peripheral(name, ptype, methods)
  self.wrapped[name] = methods or {}
  self.types[name] = ptype
  for _, existing in ipairs(self.names) do
    if existing == name then return self end
  end
  self.names[#self.names + 1] = name
  return self
end

function Env:remove_peripheral(name)
  self.wrapped[name] = nil
  self.types[name] = nil
  for index, existing in ipairs(self.names) do
    if existing == name then table.remove(self.names, index); break end
  end
  return self
end

-- Ein drahtloses Modem. Alles, was die Node sendet, landet in
-- env.transmitted; alles, was der Test in env.received legt, kommt als
-- modem_message-Event zurueck.
function Env:add_modem(name, wireless)
  local env = self
  return self:add_peripheral(name, 'modem', {
    isWireless = function() return wireless ~= false end,
    open = function() end,
    close = function() end,
    closeAll = function() end,
    isOpen = function() return true end,
    transmit = function(channel, reply, message)
      env.transmitted[#env.transmitted + 1] =
        { channel = channel, reply = reply, message = message, at_ms = env.clock_ms }
    end,
  })
end

function Env:advance(ms)
  self.clock_ms = self.clock_ms + (tonumber(ms) or 0)
  return self
end

-- Setzt die Modul-Caches zurueck, damit die NAECHSTE Rolle ihren eigenen
-- Modulgraphen bekommt.
--
-- bootstrap.require() cached in _G.__xreactor_loaded und delegiert sonst an
-- Luas require() (package.loaded). Beides muss weg, sonst teilen zwei
-- gebootete Rollen denselben modulglobalen Zustand -- etwa den
-- Faehigkeits-Cache in adapters/turbine.lua -- und das waeren keine zwei
-- Computer mehr, sondern einer mit zwei Namen.
--
-- Die bereits gebootete Rolle behaelt ihre Modultabellen ueber die Closures
-- ihrer Services; sie laeuft also unveraendert weiter. Genau das ist
-- gewollt: zwei Rollen, zwei Modulgraphen, wie zwei Computer.
function M.reset_module_cache()
  rawset(_G, '__xreactor_loaded', nil)
  rawset(_G, '__xreactor_loading', nil)
  -- Das globale require() auf Luas eigenes zuruecksetzen (siehe
  -- PRISTINE_REQUIRE): sonst delegiert die naechste bootstrap-Instanz an die
  -- vorige und laeuft im Kreis.
  rawset(_G, 'require', PRISTINE_REQUIRE)
  local drop = {}
  for name in pairs(package.loaded) do
    if name:match('^nodes%.') or name:match('^core%.') or name:match('^services%.')
        or name:match('^adapters%.') or name:match('^shared%.') or name:match('^master%.')
        or name:match('^optional%.') or name == 'xreactor.release' then
      drop[#drop + 1] = name
    end
  end
  for _, name in ipairs(drop) do package.loaded[name] = nil end
  return #drop
end

-- Setzt die CC-Globals dieser Node. Mehrfach aufrufbar: laufen mehrere
-- Rollen in einem Prozess, teilen sie sich _G -- vor jedem Takt muss also
-- die Node aktiviert werden, deren Platte und Peripherie gelten soll.
-- node_message_bus.lua macht das von selbst.
function Env:activate()
  local env = self
  local real_dofile = env._real_dofile or dofile
  env._real_dofile = real_dofile

  -- Die Repo-Dateien unter /xreactor/ sind fuer die virtuelle Platte SICHTBAR.
  --
  -- Das ist kein Komfort, sondern Treue zum Original: auf dem Computer liegen
  -- die Module auf der Platte, also laedt core/bootstrap.lua sie mit seinem
  -- EIGENEN Loader (load_module, hinter `if fs.exists(path)`). Sind sie
  -- unsichtbar, faellt bootstrap auf das native require() von Lua zurueck --
  -- und dann gibt es zwei Lader mit zwei getrennten Buchfuehrungen. Ein
  -- Modul, das waehrend seines eigenen Ladens erneut angefordert wird, ist
  -- fuer den einen Lader fertig und fuer den anderen "gerade im Laden": der
  -- Boot stirbt mit "Circular dependency while loading shared.constants",
  -- obwohl es im Spiel keinen Zyklus gibt. Genau daran ist der MASTER-Boot
  -- hier gescheitert.
  local function repo_path(p)
    local name = tostring(p)
    if name:sub(1, 10) ~= '/xreactor/' then return nil end
    return '.' .. name
  end

  local function read_repo_file(p)
    local mapped = repo_path(p)
    if not mapped then return nil end
    local handle = io.open(mapped, 'r')
    if not handle then return nil end
    local content = handle:read('*a')
    handle:close()
    return content
  end

  _G.fs = {
    exists = function(p)
      if env.files[p] ~= nil then return true end
      return read_repo_file(p) ~= nil
    end,
    open = function(p, mode)
      if mode == 'r' then
        if env.files[p] == nil then
          local repo = read_repo_file(p)
          if repo == nil then return nil end
          local offset = 1
          return {
            readAll = function() return repo end,
            readLine = function()
              if offset > #repo then return nil end
              local stop = repo:find('\n', offset, true)
              local line
              if stop then line = repo:sub(offset, stop - 1); offset = stop + 1
              else line = repo:sub(offset); offset = #repo + 1 end
              return line
            end,
            close = function() end,
          }
        end
        local offset = 1
        return {
          readAll = function() return env.files[p] end,
          readLine = function()
            local content = env.files[p] or ''
            if offset > #content then return nil end
            local stop = content:find('\n', offset, true)
            local line
            if stop then line = content:sub(offset, stop - 1); offset = stop + 1
            else line = content:sub(offset); offset = #content + 1 end
            return line
          end,
          close = function() end,
        }
      end
      if mode == 'a' then
        return { write = function(c) env.files[p] = (env.files[p] or '') .. tostring(c) end,
                 writeLine = function(c) env.files[p] = (env.files[p] or '') .. tostring(c) .. '\n' end,
                 close = function() end }
      end
      local buffer = ''
      return {
        write = function(c) buffer = buffer .. tostring(c) end,
        writeLine = function(c) buffer = buffer .. tostring(c) .. '\n' end,
        close = function() env.files[p] = buffer end,
      }
    end,
    getDir = function(p) return p:match('^(.*)/[^/]+$') or '' end,
    makeDir = function() end,
    isDir = function(p) return env.files[p] == '<dir>' end,
    list = function() return {} end,
    delete = function(p) env.files[p] = nil end,
    getSize = function(p) return #(env.files[p] or '') end,
    getFreeSpace = function() return 1e9 end,
    combine = function(a, b) return ((a or '') .. '/' .. (b or '')):gsub('//', '/') end,
    move = function(a, b) env.files[b] = env.files[a]; env.files[a] = nil end,
    copy = function(a, b) env.files[b] = env.files[a] end,
  }

  _G.settings = { get = function() return nil end, set = function() end, save = function() end }

  -- redstone: die VALVE-Node schaltet damit ihr Ventil. Der Zustand bleibt
  -- je Seite gemerkt, damit ein Test ihn ablesen kann (env.redstone).
  env.redstone = env.redstone or {}
  _G.redstone = {
    getSides = function() return { 'top', 'bottom', 'left', 'right', 'front', 'back' } end,
    setOutput = function(side, value) env.redstone[tostring(side)] = value and true or false end,
    getOutput = function(side) return env.redstone[tostring(side)] == true end,
    getInput = function(side) return env.redstone_input and env.redstone_input[tostring(side)] == true or false end,
    setAnalogOutput = function(side, value) env.redstone[tostring(side)] = tonumber(value) or 0 end,
    getAnalogOutput = function(side) return tonumber(env.redstone[tostring(side)]) or 0 end,
    getAnalogInput = function() return 0 end,
    setBundledOutput = function() end,
    getBundledInput = function() return 0 end,
  }
  _G.rs = _G.redstone

  -- textutils: core/registry.lua und core/utils.lua serialisieren damit ihre
  -- Dateien. Eine vollstaendige Runde (serialize -> unserialize) muss
  -- funktionieren, sonst laeuft der Boot in eine leere Registry.
  local function serialize(value, indent)
    indent = indent or ''
    local t = type(value)
    if t == 'string' then return string.format('%q', value) end
    if t == 'number' or t == 'boolean' then return tostring(value) end
    if t == 'nil' then return 'nil' end
    if t ~= 'table' then return string.format('%q', tostring(value)) end
    local inner = indent .. '  '
    local parts = { '{' }
    local count = 0
    for _, item in ipairs(value) do
      count = count + 1
      parts[#parts + 1] = inner .. serialize(item, inner) .. ','
    end
    local keys = {}
    for key in pairs(value) do
      if not (type(key) == 'number' and key >= 1 and key <= count and key % 1 == 0) then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
      local encoded
      if type(key) == 'string' and key:match('^[%a_][%w_]*$') then encoded = key .. ' = '
      else encoded = '[' .. serialize(key, inner) .. '] = ' end
      parts[#parts + 1] = inner .. encoded .. serialize(value[key], inner) .. ','
    end
    parts[#parts + 1] = indent .. '}'
    return table.concat(parts, '\n')
  end

  _G.textutils = {
    serialize = serialize,
    serialise = serialize,
    unserialize = function(text)
      if type(text) ~= 'string' then return nil end
      local chunk = load('return ' .. text, 'unserialize', 't', {})
      if not chunk then return nil end
      local ok, result = pcall(chunk)
      if not ok then return nil end
      return result
    end,
    serializeJSON = function(value) return serialize(value) end,
    formatTime = function() return '00:00' end,
    tabulate = function() end,
    pagedPrint = function() end,
  }
  _G.textutils.unserialise = _G.textutils.unserialize

  os.getComputerID = function() return env.computer_id end
  os.getComputerLabel = function() return nil end
  os.epoch = function() return env.clock_ms end
  os.startTimer = function() return 1 end
  os.cancelTimer = function() end
  os.queueEvent = function() end
  env.pull_events = 0
  os.pullEvent = function()
    env.pull_events = env.pull_events + 1
    if env.pull_events > env.pull_event_limit then
      env.loop_entered = true
      error(M.EVENT_LOOP_SENTINEL, 0)
    end
    return 'timer', 1
  end
  os.pullEventRaw = os.pullEvent
  -- Ein Reboot beendet den Boot, ohne den Test zu toeten.
  --
  -- Die Rollen fangen Fehler selbst ab (master/runtime_loop.lua's
  -- Crash-Handler, nodes/support/runtime.lua's crash_screen) und starten danach
  -- neu. Die Kennung von oben laeuft also durch EINEN solchen Handler, und am
  -- Ende steht ein os.reboot(). Das ist hier kein Fehler, sondern das Ende des
  -- Boots -- ob es einer war, entscheidet boot() an loop_entered.
  os.reboot = function()
    env.reboot_requested = true
    error(M.EVENT_LOOP_SENTINEL, 0)
  end
  os.shutdown = function()
    env.shutdown_requested = true
    error(M.EVENT_LOOP_SENTINEL, 0)
  end
  os.sleep = function()
    env.sleeps = env.sleeps + 1
    if env.sleeps > env.sleep_limit then
      error('BOOT-WATCHDOG: os.sleep() ' .. env.sleep_limit
        .. 'x -- der Boot dreht sich im Kreis:\n' .. debug.traceback('', 2), 0)
    end
  end
  _G.sleep = os.sleep
  _G.read = function() return '' end

  _G.peripheral = {
    getNames = function() return env.names end,
    isPresent = function(n) return env.wrapped[n] ~= nil end,
    getType = function(n) return env.types[n] end,
    wrap = function(n) return env.wrapped[n] end,
    -- peripheral.find(kind, filter): der FILTER muss durchgereicht werden.
    -- nodes/valve/main.lua sucht sein Funkmodem so (filter prueft
    -- isWireless), und ohne Filterauswertung bekaeme es das erste Modem --
    -- oder, bei kabelgebundenem erstem Modem, ein falsches.
    find = function(kind, filter)
      local found = {}
      for _, n in ipairs(env.names) do
        if env.types[n] == kind then
          local object = env.wrapped[n]
          if filter == nil then return object, n end
          local ok, accepted = pcall(filter, n, object)
          if ok and accepted then found[#found + 1] = { object, n } end
        end
      end
      if #found > 0 then return found[1][1], found[1][2] end
      return nil
    end,
    getMethods = function(n)
      local out = {}
      for key, value in pairs(env.wrapped[n] or {}) do
        if type(value) == 'function' then out[#out + 1] = key end
      end
      table.sort(out)
      return out
    end,
    call = function(n, method, ...)
      local object = env.wrapped[n]
      if not object then error('unbekannte Peripherie ' .. tostring(n), 0) end
      local fn = object[method]
      if type(fn) ~= 'function' then
        error('No such method ' .. tostring(method), 0)
      end
      return fn(...)
    end,
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
    redirect = function() return term_stub end,
    current = function() return term_stub end,
    native = function() return term_stub end,
  }
  _G.term = term_stub
  _G.window = { create = function() return term_stub end }
  _G.colors = _G.colors or setmetatable({}, { __index = function() return 1 end })
  _G.colours = _G.colors

  -- keys: die UI-Dienste vergleichen Tastencodes dagegen (core/ui_router.lua,
  -- nodes/*/monitor_ui.lua). Fehlt die Tabelle, stirbt der erste UI-Takt mit
  -- "attempt to index global 'keys'" -- im Spiel gibt es sie immer.
  -- Die Werte muessen nur EINDEUTIG sein, nicht echt: verglichen wird gegen
  -- genau diese Tabelle.
  _G.keys = _G.keys or (function()
    local names = {
      'up', 'down', 'left', 'right', 'enter', 'space', 'backspace',
      'pageUp', 'pageDown', 'c', 'p', 'q',
    }
    local out, next_code = {}, 200
    for _, name in ipairs(names) do out[name] = next_code; next_code = next_code + 1 end
    -- Alles Weitere bekommt stabil einen eigenen Code, damit ein Vergleich
    -- gegen einen hier nicht aufgefuehrten Namen nicht auf nil laeuft.
    return setmetatable(out, { __index = function(t, key)
      if type(key) ~= 'string' then return nil end
      next_code = next_code + 1
      t[key] = next_code
      return next_code
    end })
  end)()

  -- Die an parallel uebergebenen Funktionen werden EINMAL aufgerufen, nicht
  -- verworfen.
  --
  -- Grund: mehrere Rollen erledigen echte Arbeit NICHT in einem Service,
  -- sondern im after_cycle-Haken ihrer Lauf-Schleife -- nodes/fuel/main.lua
  -- tickt so seinen Logistik-Router und seinen Ventil-Router. Wird parallel
  -- einfach verworfen, laufen diese Haken nie, und der Test sieht eine FUEL-
  -- Node ohne Reaktoren: ein Fehler, den es im Spiel nicht gibt, und
  -- schlimmer noch, er sieht genau wie der echte aus.
  --
  -- Haengen koennen die Funktionen dabei nicht: capture_loops() ersetzt
  -- run_fast_loop/run_slow_loop durch Rekorder, die die Optionen festhalten
  -- und sofort zurueckkehren.
  local function run_loop_bodies(...)
    env.loop_entered = true
    for index = 1, select('#', ...) do
      local body = (select(index, ...))
      if type(body) == 'function' then
        local ok, err = pcall(body)
        if not ok and not tostring(err):find(M.EVENT_LOOP_SENTINEL, 1, true) then
          env.loop_errors[#env.loop_errors + 1] = tostring(err)
        end
      end
    end
  end
  _G.parallel = {
    waitForAny = run_loop_bodies,
    waitForAll = run_loop_bodies,
  }

  -- print() waehrend des Boots einsammeln statt ausgeben: die Nodes schreiben
  -- dort absichtlich direkt auf den Bildschirm (Regler aktiv, Warnungen), und
  -- das ist Teil dessen, was ein Test pruefen will (env:find_prints()).
  --
  -- boot() gibt print() danach zurueck -- sonst verschluckt die Umgebung auch
  -- die Ausgaben des TESTS selbst, und ein gruener Testlauf sieht aus wie ein
  -- stiller Absturz.
  -- print() wird hier ABSICHTLICH NICHT angefasst.
  --
  -- activate() laeuft bei mehreren Rollen vor jedem Takt (node_message_bus.lua).
  -- Wuerde es den print-Abgriff setzen, haette der TEST nach dem ersten Takt
  -- kein print() mehr -- ein gruener Lauf saehe dann aus wie ein stiller
  -- Absturz. Eingesammelt wird nur, wo es gebraucht wird: in boot() und um
  -- Service-Takte herum (capture_prints/release_prints).

  -- dofile() muss BEIDES koennen:
  --
  --   * Code aus dem Repo laden ("/xreactor/core/bootstrap.lua" -> ./xreactor/...)
  --   * Config-Dateien von der VIRTUELLEN Platte laden.
  --
  -- Das zweite ist nicht Bequemlichkeit, sondern notwendig: mehrere Nodes
  -- lesen ihre Config-Dateien mit dofile() statt ueber fs.open (z.B.
  -- nodes/fuel/main.lua fuer /xreactor_config/fuel_routes.lua). In
  -- CC:Tweaked liest dofile() die Platte des Computers -- hier muss es
  -- also env.files lesen, sonst sieht jede so geladene Datei aus wie
  -- "nicht vorhanden", und der Test wuerde einen Fehler melden, den es im
  -- Spiel nicht gibt.
  _G.dofile = function(path)
    local name = tostring(path)
    local content = env.files[name]
    if content ~= nil and content ~= '<dir>' then
      local chunk, err = load(content, name, 't')
      if not chunk then error(err, 0) end
      return chunk()
    end
    local mapped = name:gsub('^/xreactor/', './xreactor/')
    return real_dofile(mapped)
  end

  return self
end

function Env:install()
  if self.node_id then
    self:add_file('/xreactor_config/node_id.txt', self.node_id)
  end
  return self:activate()
end

-- Greift die Services ab, die main.lua anlegt, damit der Test danach echte
-- Takte fahren kann. bootstrap.require() liefert aus _G.__xreactor_loaded
-- aus -- wer dort vorher liegt, gewinnt.
function Env:capture_services()
  local env = self
  local real_sm = require('services.service_manager')
  local wrapper = {}
  for k, v in pairs(real_sm) do wrapper[k] = v end
  wrapper.new = function(...)
    local manager = real_sm.new(...)
    local real_add = manager.add
    manager.add = function(selfm, service)
      if type(service) == 'table' and service.name then
        env.services[service.name] = service
      end
      return real_add(selfm, service)
    end
    return manager
  end
  _G.__xreactor_loaded = _G.__xreactor_loaded or {}
  _G.__xreactor_loaded['services.service_manager'] = wrapper
  return self
end

-- Greift nodes/support/runtime.lua's Lauf-Schleifen ab.
--
-- run_fast_loop()/run_slow_loop() laufen im Spiel endlos. Hier werden sie
-- durch Rekorder ersetzt: sie halten ihre Optionen fest (services, comms und
-- vor allem after_cycle) und kehren sofort zurueck. Der after_cycle-Haken
-- laesst sich danach gezielt ticken -- genau dort tickt nodes/fuel/main.lua
-- seinen Logistik-Router, und ohne ihn bleibt die Reaktorliste leer.
function Env:capture_loops()
  local env = self
  local ok_runtime, real_runtime = pcall(require, 'nodes.support.runtime')
  if not ok_runtime or type(real_runtime) ~= 'table' then return self end
  local wrapper = {}
  for key, value in pairs(real_runtime) do wrapper[key] = value end
  wrapper.run_fast_loop = function(opts)
    env.loops.fast = opts or {}
    return true
  end
  wrapper.run_slow_loop = function(opts)
    env.loops.slow = opts or {}
    return true
  end
  _G.__xreactor_loaded = _G.__xreactor_loaded or {}
  _G.__xreactor_loaded['nodes.support.runtime'] = wrapper
  return self
end

-- Die after_cycle-Haken der abgegriffenen Schleifen einmal ausfuehren.
function Env:tick_loops(times)
  for _ = 1, (times or 1) do
    for _, which in ipairs({ 'fast', 'slow' }) do
      local opts = self.loops[which]
      if opts and type(opts.after_cycle) == 'function' then
        local ok, err = pcall(opts.after_cycle)
        if not ok then
          error('after_cycle der "' .. which .. '"-Schleife ist gescheitert: '
            .. tostring(err), 2)
        end
      end
    end
  end
  return self
end

-- Greift utils.log() ab, damit der Test die Warnungen des Boots lesen kann.
-- Genau dort stehen die Config-Warnungen, die im Betrieb niemand sieht.
function Env:capture_logs()
  local env = self
  local real_utils = require('core.utils')
  local real_log = real_utils.log
  real_utils.log = function(prefix, message, level)
    env.logs[#env.logs + 1] = {
      prefix = tostring(prefix), message = tostring(message), level = tostring(level or 'INFO'),
    }
    return real_log(prefix, message, level)
  end
  return self
end

function Env:boot(main_path)
  self:capture_services()
  self:capture_logs()
  self:capture_loops()
  self:capture_prints()
  local ok, err = pcall(dofile, './xreactor/' .. main_path)
  -- print() dem Test zurueckgeben, auch wenn der Boot gescheitert ist.
  self:release_prints()
  -- Die Event-Schleife erreicht zu haben IST das Ende eines gelungenen Boots
  -- -- bei parallel.waitForAny() kehrt der Stub einfach zurueck, bei einer
  -- eigenen pullEvent-Schleife kommt die Kennung von oben.
  if not ok and tostring(err):find(M.EVENT_LOOP_SENTINEL, 1, true) then
    if self.loop_entered then
      -- Die Rolle hat ihre Event-Schleife erreicht: Boot durch.
      ok, err = true, nil
    else
      -- Reboot/Shutdown OHNE je die Schleife erreicht zu haben -- das ist ein
      -- echter Abbruch (z.B. der Erststart-Assistent, der eine Rolle
      -- schreiben und neu starten will).
      err = self.reboot_requested
        and 'die Rolle hat einen Neustart angefordert, ohne die Event-Schleife'
          .. ' zu erreichen -- fehlt /xreactor_config/role.lua?'
        or 'die Rolle hat ein Shutdown angefordert, ohne die Event-Schleife zu erreichen'
    end
  end
  if not ok then
    error('Boot von ' .. tostring(main_path) .. ' gescheitert: ' .. tostring(err), 0)
  end
  return self
end

-- print() nach env.prints umleiten. Paarweise mit release_prints() benutzen.
function Env:capture_prints()
  local env = self
  if self.real_print == nil then self.real_print = print end
  _G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    env.prints[#env.prints + 1] = table.concat(parts, ' ')
  end
  return self
end

function Env:release_prints()
  if self.real_print then _G.print = self.real_print end
  return self
end

function Env:tick_service(name, times, dt, event)
  local service = self.services[name]
  if not service then
    local known = {}
    for key in pairs(self.services) do known[#known + 1] = key end
    table.sort(known)
    error('kein Service "' .. tostring(name) .. '" -- vorhanden: '
      .. table.concat(known, ', '), 2)
  end
  -- Aufruf genau wie services/service_manager.lua:
  --   pcall(service.tick, service, dt, event)
  -- Methodenform also, mit dem Service als erstem Argument. Ein Service, der
  -- seinen tick als schlichte Funktion ablegt, ignoriert ihn einfach.
  self:capture_prints()
  for _ = 1, (times or 1) do
    if service.tick then
      local ok, err = pcall(service.tick, service, dt or 0.1, event)
      if not ok then
        self:release_prints()
        error('Service "' .. tostring(name) .. '" ist im tick gescheitert: '
          .. tostring(err), 2)
      end
    end
    self:advance(100)
  end
  self:release_prints()
  return self
end

-- Alle Logzeilen, deren Text das Muster enthaelt (einfache Suche, kein
-- Lua-Pattern).
function Env:find_logs(pattern)
  local out = {}
  for _, entry in ipairs(self.logs) do
    if entry.message:find(pattern, 1, true) then out[#out + 1] = entry end
  end
  return out
end

function Env:find_prints(pattern)
  local out = {}
  for _, line in ipairs(self.prints) do
    if line:find(pattern, 1, true) then out[#out + 1] = line end
  end
  return out
end

return M
