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
-- COMMS-Service. Der filtert selbst nach Kanal (control/status) -- genau
-- diese Filterung ist Teil dessen, was hier mitgeprueft wird.
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
      if entry.name ~= outgoing.from then
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
        end
      end
    end
    if not had_receiver then
      self.dropped[#self.dropped + 1] = outgoing
    end
  end
  return #pending
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
