-- tests/sim/cc/event_queue.lua
-- CC:Tweaked Event-Queue Simulation (Phase 4.2)
-- Unterstützt: ungefilterte/gefilterte Pulls, terminate, Tabellen-Werte.

local event_queue = {}
event_queue.__index = event_queue

function event_queue.new()
  return setmetatable({ _queue = {} }, event_queue)
end

-- Event in die Queue stellen
function event_queue:push(event_name, ...)
  local args = { event_name, ... }
  -- Tabellen-Werte als Kopie speichern
  self._queue[#self._queue + 1] = args
end

-- Nächstes Event lesen (blockiert nicht — gibt nil zurück wenn leer)
function event_queue:peek()
  return self._queue[1]
end

function event_queue:pop()
  if #self._queue == 0 then return nil end
  local ev = self._queue[1]
  table.remove(self._queue, 1)
  return table.unpack(ev)
end

-- os.pullEvent(filter): konsumiert Events bis filter passt
-- terminate wird immer durchgelassen (wie CC:Tweaked)
function event_queue:pull(filter)
  while #self._queue > 0 do
    local ev = self._queue[1]
    local name = ev[1]
    if name == "terminate" then
      table.remove(self._queue, 1)
      error("Terminated", 0)
    end
    table.remove(self._queue, 1)
    if not filter or filter == "" or name == filter then
      return table.unpack(ev)
    end
    -- Anderes Event verwerfen (wie CC:Tweaked pullEvent)
  end
  return nil  -- Leere Queue
end

-- os.pullEventRaw(filter): wie pull, aber terminate nicht auto-throw
function event_queue:pull_raw(filter)
  while #self._queue > 0 do
    local ev = self._queue[1]
    local name = ev[1]
    table.remove(self._queue, 1)
    if not filter or filter == "" or name == filter then
      return table.unpack(ev)
    end
  end
  return nil
end

function event_queue:size()  return #self._queue end
function event_queue:empty() return #self._queue == 0 end
function event_queue:clear() self._queue = {} end

return event_queue
