-- tests/support/node_message_bus.lua
--
-- Das Funknetz zwischen mehreren ECHT gebooteten Rollen.
--
-- WOFUER. Was in dieser Anlage kaputtgeht, liegt fast nie in einer Funktion,
-- sondern zwischen zwei Rollen: ein Payload-Feld, das die eine Seite
-- umbenennt und die andere noch unter dem alten Namen liest; eine Quittung,
-- die der Empfaenger anders deutet als der Sender; ein Zustand, den MASTER
-- annimmt und die Node nie gemeldet hat. Modultests sehen davon nichts, weil
-- beide Seiten darin mit HANDGESCHRIEBENEN Daten geprueft werden -- und genau
-- die Handschrift ist das Problem: sie bleibt richtig, waehrend die echte
-- Nachricht sich aendert.
--
-- Hier reden die Rollen mit ihren ECHTEN Nachrichten: was eine Node ueber
-- modem.transmit() rausgibt, wird hier eingesammelt und den anderen Nodes
-- genauso zugestellt, wie CC:Tweaked es tun wuerde -- als modem_message in
-- den COMMS-Service (services/comms_service.lua's handle_event).
--
-- VERWENDUNG
--
--   local bus = require('support.node_message_bus')
--   local net = bus.new()
--   net:attach('RT', rt_env)        -- je eine mit support.cc_node_boot
--   net:attach('MASTER', master_env)
--   net:run(30)                     -- 30 Runden: ticken, zustellen, ticken
--   local seen = net:messages_to('MASTER', 'STATUS')
--
-- WIE DIE ROLLEN NEBENEINANDER LAUFEN. In einem Lua-Prozess teilen sich alle
-- Rollen _G. Darum:
--
--   * Jede Node bekommt beim Booten ihren eigenen Modulgraphen
--     (cc_node_boot.reset_module_cache() zwischen den Boots) -- sonst teilen
--     zwei Rollen modulglobalen Zustand und waeren ein Computer mit zwei
--     Namen.
--   * Vor jedem Takt wird die Node aktiviert (env:activate()), damit ihre
--     Platte, ihre Peripherie und ihre Uhr gelten.
--
-- Die Uhr laeuft fuer alle gemeinsam: net:advance() schiebt jede Node um
-- denselben Betrag, sonst wuerde eine Node die andere als veraltet ansehen.
--
-- ROHE KANAELE (opts.raw_channels). Manche Rollen funken neben comms auf
-- einem eigenen Kanal -- FUEL und VALVE etwa SET_VALVE/VALVE_ACK auf
-- constants.channels.VALVE, ausserhalb von comms_service. In CC:Tweaked
-- landet so eine Nachricht als modem_message bei JEDEM Service, der
-- wants_events gesetzt hat (services/service_manager.lua). Standardmaessig
-- stellt dieser Bus nur dem COMMS-Service zu; wer den Ventilkanal mitpruefen
-- will, gibt ihn an:
--
--   local net = bus.new({ raw_channels = { [constants.channels.VALVE] = true } })
--
-- Nachrichten auf diesen Kanaelen gehen dann zusaetzlich an jeden Service
-- mit wants_events (ausser COMMS), so wie service_manager es taete.
--
-- OFFENE KANAELE. Wie in CC:Tweaked bekommt eine Node eine Meldung nur,
-- wenn eines ihrer Modems deren Kanal offen hat (env:listening_modem in
-- support/cc_node_boot.lua). Was niemand hoert, steht in net.not_heard
-- (Zaehler je Node). Fuer einen Test, der bewusst das alte "jeder hoert
-- alles" braucht: bus.new({ ignore_open_channels = true }).

local M = {}

local Bus = {}
Bus.__index = Bus

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    nodes = {},            -- { { name, env, seen_transmitted } }
    by_name = {},
    delivered = {},        -- { { from, to, channel, message } }
    dropped = {},          -- Nachrichten ohne Empfaenger
    step_ms = opts.step_ms or 100,
    tick_dt = opts.tick_dt or 0.1,
    raw_channels = opts.raw_channels or {},
    ignore_open_channels = opts.ignore_open_channels == true,
    not_heard = {},        -- [Node] = Meldungen, deren Kanal sie nicht offen hatte
  }, Bus)
end

function Bus:attach(name, env)
  if self.by_name[name] then
    error('Node "' .. tostring(name) .. '" haengt schon am Bus', 2)
  end
  local entry = { name = name, env = env, seen_transmitted = 0 }
  self.nodes[#self.nodes + 1] = entry
  self.by_name[name] = entry
  return self
end

function Bus:node(name)
  local entry = self.by_name[name]
  if not entry then
    local known = {}
    for _, item in ipairs(self.nodes) do known[#known + 1] = item.name end
    error('keine Node "' .. tostring(name) .. '" am Bus -- vorhanden: '
      .. table.concat(known, ', '), 2)
  end
  return entry
end

-- Die Uhr ALLER Nodes gemeinsam weiterstellen. Liefen sie auseinander, haelt
-- die eine die andere fuer abgemeldet (peer_timeout_s), und der Test wuerde
-- einen Verbindungsfehler zeigen, den es nicht gibt.
function Bus:advance(ms)
  for _, entry in ipairs(self.nodes) do entry.env:advance(ms) end
  return self
end

-- Einen Service EINER Node ticken, mit ihren Globals.
function Bus:tick_node(name, service_name, times)
  local entry = self:node(name)
  entry.env:activate()
  local service = entry.env.services[service_name]
  if not service then
    local known = {}
    for key in pairs(entry.env.services) do known[#known + 1] = key end
    table.sort(known)
    error('Node "' .. name .. '" hat keinen Service "' .. tostring(service_name)
      .. '" -- vorhanden: ' .. table.concat(known, ', '), 2)
  end
  for _ = 1, (times or 1) do
    local ok, err = pcall(service.tick, service, self.tick_dt, nil)
    if not ok then
      error('Node "' .. name .. '", Service "' .. service_name
        .. '" ist im tick gescheitert: ' .. tostring(err), 2)
    end
  end
  return self
end

-- Alle Services aller Nodes einmal ticken, in Anmeldereihenfolge.
function Bus:tick_all()
  for _, entry in ipairs(self.nodes) do
    entry.env:activate()
    -- print()-Ausgaben der Rolle einsammeln und danach zurueckgeben, damit
    -- der Test selbst weiter ausgeben kann (siehe cc_node_boot.lua).
    entry.env:capture_prints()
    local names = {}
    for key in pairs(entry.env.services) do names[#names + 1] = key end
    table.sort(names)   -- feste Reihenfolge: ein Test muss wiederholbar sein
    for _, service_name in ipairs(names) do
      local service = entry.env.services[service_name]
      if service and service.tick then
        local ok, err = pcall(service.tick, service, self.tick_dt, nil)
        if not ok then
          entry.env:release_prints()
          error('Node "' .. entry.name .. '", Service "' .. service_name
            .. '" ist im tick gescheitert: ' .. tostring(err), 2)
        end
      end
    end
    -- Und die after_cycle-Haken der Lauf-Schleifen: dort tickt FUEL seinen
    -- Logistik-Router und seinen Ventil-Router (siehe cc_node_boot.lua's
    -- capture_loops). Ohne das bleibt die Reaktorliste leer -- ein Fehler,
    -- den es im Spiel nicht gibt.
    local ok_loops, loop_err = pcall(entry.env.tick_loops, entry.env, 1)
    entry.env:release_prints()
    if not ok_loops then
      error('Node "' .. entry.name .. '": ' .. tostring(loop_err), 2)
    end
  end
  return self
end

-- Was seit dem letzten Lauf gesendet wurde, an alle ANDEREN Nodes zustellen.
--
-- Zugestellt wird wie in CC:Tweaked: als modem_message-Event in den
-- COMMS-Service, und nur an Nodes, die den Kanal offen haben. COMMS filtert
-- danach selbst nach Kanal (control/status) -- genau diese Filterung ist
-- Teil dessen, was hier mitgeprueft wird.
function Bus:hears(entry, channel)
  if self.ignore_open_channels then return true end
  if type(entry.env.listening_modem) ~= 'function' then return true end
  return entry.env:listening_modem(channel) ~= nil
end

function Bus:deliver()
  local pending = {}
  for _, entry in ipairs(self.nodes) do
    local transmitted = entry.env.transmitted
    for index = entry.seen_transmitted + 1, #transmitted do
      pending[#pending + 1] = { from = entry.name, item = transmitted[index] }
    end
    entry.seen_transmitted = #transmitted
  end

  for _, outgoing in ipairs(pending) do
    local item = outgoing.item
    local had_receiver = false
    for _, entry in ipairs(self.nodes) do
      local listening = entry.name ~= outgoing.from and self:hears(entry, item.channel)
      if entry.name ~= outgoing.from and not listening then
        self.not_heard[entry.name] = (self.not_heard[entry.name] or 0) + 1
      end
      if listening then
        local comms = entry.env.services.COMMS
        if comms and comms.handle_event then
          entry.env:activate()
          -- Die Form, die nodes/support/runtime.lua aus os.pullEvent() baut:
          -- { "modem_message", side, channel, replyChannel, message, distance }
          local event = { 'modem_message', 'back', item.channel, item.reply, item.message, 1 }
          local ok, err = pcall(comms.handle_event, comms, event)
          if not ok then
            error('Zustellung an "' .. entry.name .. '" gescheitert: ' .. tostring(err), 2)
          end
          had_receiver = true
          self.delivered[#self.delivered + 1] = {
            from = outgoing.from, to = entry.name,
            channel = item.channel, message = item.message,
          }
          if self.raw_channels[item.channel] then
            self:_deliver_raw(entry, event)
          end
        end
      end
    end
    if not had_receiver then
      self.dropped[#self.dropped + 1] = outgoing
    end
  end
  return #pending
end

-- Ein modem_message-Event auf einem rohen Kanal an jeden Service mit
-- wants_events (ausser COMMS, der hat es schon), in fester Reihenfolge.
--
-- Als Seite (event[2]) steht hier der Name des Modems der EMPFANGENDEN Node,
-- wie in CC:Tweaked: nodes/valve/controller.lua antwortet mit VALVE_ACK
-- ueber peripheral.wrap(event[2]) -- mit der festen Seite 'back' faende es
-- kein Modem und bliebe stumm.
function Bus:_deliver_raw(entry, event)
  local side = event[2]
  local listening = (not self.ignore_open_channels) and type(entry.env.listening_modem) == 'function'
    and entry.env:listening_modem(event[3]) or nil
  if listening then
    side = listening
  else
    for _, name in ipairs(entry.env.names or {}) do
      if entry.env.types[name] == 'modem' then side = name; break end
    end
  end
  event = { event[1], side, event[3], event[4], event[5], event[6] }
  local names = {}
  for key, service in pairs(entry.env.services) do
    if key ~= 'COMMS' and type(service) == 'table' and service.wants_events == true
        and service.tick then
      names[#names + 1] = key
    end
  end
  table.sort(names)
  for _, service_name in ipairs(names) do
    local service = entry.env.services[service_name]
    local ok, err = pcall(service.tick, service, self.tick_dt, event)
    if not ok then
      error('Zustellung (roher Kanal ' .. tostring(event[3]) .. ') an "' .. entry.name
        .. '", Service "' .. service_name .. '" gescheitert: ' .. tostring(err), 3)
    end
  end
end

-- Eine Runde: alle ticken, zustellen, Uhr weiterstellen.
function Bus:step()
  self:tick_all()
  self:deliver()
  self:advance(self.step_ms)
  return self
end

function Bus:run(rounds)
  for _ = 1, (rounds or 1) do self:step() end
  return self
end

-- ── Auswertung ───────────────────────────────────────────────────────────

-- Alle Nachrichten, die bei dieser Node angekommen sind; optional nach Typ.
function Bus:messages_to(name, message_type)
  local out = {}
  for _, record in ipairs(self.delivered) do
    if record.to == name then
      local message = record.message
      if message_type == nil
          or (type(message) == 'table' and message.type == message_type) then
        out[#out + 1] = record
      end
    end
  end
  return out
end

function Bus:messages_from(name, message_type)
  local out = {}
  for _, record in ipairs(self.delivered) do
    if record.from == name then
      local message = record.message
      if message_type == nil
          or (type(message) == 'table' and message.type == message_type) then
        out[#out + 1] = record
      end
    end
  end
  return out
end

-- Die JUENGSTE Nachricht eines Typs von dieser Node -- der Normalfall beim
-- Pruefen eines Payloads.
function Bus:last_message_from(name, message_type)
  local list = self:messages_from(name, message_type)
  return list[#list] and list[#list].message or nil
end

-- Welche Nachrichtentypen ueberhaupt geflossen sind. Fuer die Fehlersuche im
-- Test selbst: steht hier nichts, redet keiner, und dann ist jede weitere
-- Zusicherung wertlos.
function Bus:traffic_summary()
  local counts = {}
  for _, record in ipairs(self.delivered) do
    local key = tostring(record.from) .. '->' .. tostring(record.to) .. ':'
      .. tostring(type(record.message) == 'table' and record.message.type or '?')
    counts[key] = (counts[key] or 0) + 1
  end
  local keys = {}
  for key in pairs(counts) do keys[#keys + 1] = key end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = key .. '=' .. counts[key] end
  return table.concat(parts, ' ')
end

return M
