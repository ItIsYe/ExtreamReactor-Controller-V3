-- tests/sim/cc/scheduler.lua
-- Coroutine-Scheduler für parallel.waitForAny / parallel.waitForAll (Phase 4.4)
-- Jede Coroutine bekommt eine eigene Kopie jedes Events (wie CC:Tweaked).

local scheduler = {}
scheduler.__index = scheduler

function scheduler.new(kernel, event_queue_cls)
  return setmetatable({
    _kernel      = kernel,
    _eq_cls      = event_queue_cls,
    _coroutines  = {},   -- { co, queue, name, dead, result }
  }, scheduler)
end

-- Coroutine registrieren
function scheduler:add(fn, name)
  local co = coroutine.create(fn)
  local queue = self._eq_cls.new()
  self._coroutines[#self._coroutines + 1] = {
    co = co, queue = queue, name = name or "co"..#self._coroutines,
    dead = false, result = nil, err = nil
  }
  return #self._coroutines
end

-- Event an alle lebenden Coroutinen verteilen
function scheduler:broadcast(...)
  for _, entry in ipairs(self._coroutines) do
    if not entry.dead then
      entry.queue:push(...)
    end
  end
end

-- Eine Tick-Runde: jeden lebenden Coroutine einmal resumieren
-- Gibt { done=bool, any=bool, results={...} } zurück
function scheduler:step()
  local any_finished = false
  local all_finished = true

  for _, entry in ipairs(self._coroutines) do
    if entry.dead then goto continue end

    all_finished = false
    -- Nächstes Event aus eigener Queue
    local ev = entry.queue:pop()
    if ev == nil then goto continue end  -- Kein Event → überspringen

    local ok, val = coroutine.resume(entry.co, table.unpack(type(ev)=="table" and ev or {ev}))
    if not ok then
      entry.dead  = true
      entry.err   = val
      any_finished = true
    elseif coroutine.status(entry.co) == "dead" then
      entry.dead   = true
      entry.result = val
      any_finished = true
    end

    ::continue::
  end

  return {
    any = any_finished,
    all = all_finished or self:_all_dead(),
  }
end

function scheduler:_all_dead()
  for _, e in ipairs(self._coroutines) do
    if not e.dead then return false end
  end
  return true
end

-- parallel.waitForAny(fn1, fn2, ...): kehrt zurück wenn erste fertig
function scheduler.wait_for_any(kernel, event_queue_lib, fns, shared_queue, max_ticks)
  local sch = scheduler.new(kernel, event_queue_lib)
  for i, fn in ipairs(fns) do sch:add(fn, "fn"..i) end

  max_ticks = max_ticks or kernel.MAX_TICKS
  local ticks = 0
  -- Ersten Resume ohne Event (Coroutine startet)
  for _, entry in ipairs(sch._coroutines) do
    coroutine.resume(entry.co)
  end

  while ticks < max_ticks do
    -- Events aus shared_queue an alle Coroutinen verteilen
    while not shared_queue:empty() do
      local args = shared_queue:peek()
      if args then
        shared_queue:pop()
        sch:broadcast(table.unpack(type(args)=="table" and args or {args}))
      end
    end
    local status = sch:step()
    if status.any then break end
    ticks = ticks + 1
    kernel.tick()
  end

  -- Fehler sammeln
  local errors = {}
  for _, e in ipairs(sch._coroutines) do
    if e.err then errors[#errors+1] = e.name..": "..tostring(e.err) end
  end
  if #errors > 0 then error(table.concat(errors, "; "), 2) end
end

-- parallel.waitForAll(fn1, fn2, ...): kehrt zurück wenn alle fertig
function scheduler.wait_for_all(kernel, event_queue_lib, fns, shared_queue, max_ticks)
  local sch = scheduler.new(kernel, event_queue_lib)
  for i, fn in ipairs(fns) do sch:add(fn, "fn"..i) end

  max_ticks = max_ticks or kernel.MAX_TICKS
  local ticks = 0
  for _, entry in ipairs(sch._coroutines) do
    coroutine.resume(entry.co)
  end

  while ticks < max_ticks do
    while not shared_queue:empty() do
      local args = shared_queue:peek()
      if args then
        shared_queue:pop()
        sch:broadcast(table.unpack(type(args)=="table" and args or {args}))
      end
    end
    local status = sch:step()
    if status.all then break end
    ticks = ticks + 1
    kernel.tick()
  end

  local errors = {}
  for _, e in ipairs(sch._coroutines) do
    if e.err then errors[#errors+1] = e.name..": "..tostring(e.err) end
  end
  if #errors > 0 then error(table.concat(errors, "; "), 2) end
end

return scheduler
