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
    loop_entered = false,
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

function Env:install()
  local env = self
  local real_dofile = dofile

  _G.fs = {
    exists = function(p) return env.files[p] ~= nil end,
    open = function(p, mode)
      if mode == 'r' then
        if env.files[p] == nil then return nil end
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
  os.pullEvent = function() return 'timer', 1 end
  os.pullEventRaw = os.pullEvent
  os.reboot = function() error('unerwarteter Reboot waehrend des Boots', 0) end
  os.shutdown = function() error('unerwartetes Shutdown waehrend des Boots', 0) end
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
    find = function(kind)
      for _, n in ipairs(env.names) do
        if env.types[n] == kind then return env.wrapped[n], n end
      end
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

  -- Der Boot soll nach init() enden, nicht in die Event-Schleife laufen.
  _G.parallel = {
    waitForAny = function() env.loop_entered = true end,
    waitForAll = function() env.loop_entered = true end,
  }

  -- print() waehrend des Boots einsammeln statt ausgeben: die Nodes schreiben
  -- dort absichtlich direkt auf den Bildschirm (Regler aktiv, Warnungen), und
  -- das ist Teil dessen, was ein Test pruefen will (env:find_prints()).
  --
  -- boot() gibt print() danach zurueck -- sonst verschluckt die Umgebung auch
  -- die Ausgaben des TESTS selbst, und ein gruener Testlauf sieht aus wie ein
  -- stiller Absturz.
  self.real_print = print
  _G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    env.prints[#env.prints + 1] = table.concat(parts, ' ')
  end

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

  if self.node_id then
    self:add_file('/xreactor_config/node_id.txt', self.node_id)
  end
  return self
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
  local ok, err = pcall(dofile, './xreactor/' .. main_path)
  -- print() dem Test zurueckgeben, auch wenn der Boot gescheitert ist.
  if self.real_print then _G.print = self.real_print end
  if not ok then
    error('Boot von ' .. tostring(main_path) .. ' gescheitert: ' .. tostring(err), 0)
  end
  return self
end

-- Wieder einsammeln, falls ein Test nach dem Boot Service-Takte fahren will,
-- deren print()-Ausgaben er pruefen moechte.
function Env:capture_prints()
  local env = self
  _G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    env.prints[#env.prints + 1] = table.concat(parts, ' ')
  end
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
  for _ = 1, (times or 1) do
    if service.tick then
      local ok, err = pcall(service.tick, service, dt or 0.1, event)
      if not ok then
        error('Service "' .. tostring(name) .. '" ist im tick gescheitert: '
          .. tostring(err), 2)
      end
    end
    self:advance(100)
  end
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
