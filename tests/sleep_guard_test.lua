package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- core/sleep_guard.lua: os.sleep(), das nicht an EINEM Timer haengt.
--
-- CC:Tweakeds os.sleep() wartet auf genau einen Timer. Geht er verloren
-- (CC:Tweaked verwirft Ereignisse ab 256 in der Warteschlange, Timer
-- eingeschlossen), kommt es nie zurueck -- mitten in einem Update hiesse das:
-- Knoten mit gestoppter Laufzeit, bis jemand ihn neu startet.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local real = {
  startTimer = os.startTimer, pullEvent = os.pullEvent, clock = os.clock, sleep = os.sleep,
  global_sleep = rawget(_G, 'sleep'),
}

-- Faehrt sleep(n) in 50-ms-Schritten. drop: der eigene Timer geht verloren.
-- others: andere Ereignisse alle 50 ms (Funknachrichten).
-- Liefert die Zeit (ms), zu der sleep() zurueckkehrte, oder nil.
local function run_sleep(sleep_fn, n, opts)
  opts = opts or {}
  local now_ms, timers, next_id = 0, {}, 0
  os.clock = function() return now_ms / 1000 end
  os.startTimer = function(s)
    next_id = next_id + 1
    timers[next_id] = now_ms + math.floor((tonumber(s) or 0) * 1000 + 0.5)
    return next_id
  end
  os.pullEvent = function(filter) return coroutine.yield(filter) end
  local co = coroutine.create(function() sleep_fn(n) end)
  local ok, filter = coroutine.resume(co)
  assert(ok, filter)
  for _ = 1, opts.max_steps or 400 do
    if coroutine.status(co) == 'dead' then return now_ms end
    now_ms = now_ms + 50
    local events = {}
    for id, at in pairs(timers) do
      if at <= now_ms then
        timers[id] = nil
        if not opts.drop then events[#events + 1] = { 'timer', id } end
      end
    end
    if opts.others then events[#events + 1] = { 'modem_message', 'back', 1, 1, {}, 1 } end
    for _, ev in ipairs(events) do
      if coroutine.status(co) ~= 'dead' and (filter == nil or filter == ev[1]) then
        ok, filter = coroutine.resume(co, table.unpack(ev))
        assert(ok, filter)
      end
    end
  end
  if coroutine.status(co) == 'dead' then return now_ms end
  return nil
end

local guard = require('core.sleep_guard')

-- 1. Normalfall: kehrt mit dem eigenen Timer zurueck, nicht frueher --
--    auch nicht, wenn andere Ereignisse einlaufen.
assert_eq(run_sleep(guard.sleep, 2, { others = true }), 2000, 'sleep(2) kehrt nach 2 s zurueck')
assert_eq(run_sleep(guard.sleep, 0.5), 500, 'sleep(0.5) ohne andere Ereignisse')

-- 2. Der eigene Timer geht verloren: zurueck nach n + Schonzeit, sobald
--    irgendein Ereignis kommt.
assert_eq(run_sleep(guard.sleep, 2, { drop = true, others = true }), 3000,
  'sleep(2) mit verlorenem Timer kehrt nach 2 s + 1 s Schonzeit zurueck')

-- 3. Gegenprobe: CC:Tweakeds os.sleep() aus bios.lua, unveraendert, kommt im
--    selben Fall nie zurueck.
local function bios_sleep(n)
  local timer = os.startTimer(n or 0)
  repeat
    local _, param = os.pullEvent('timer')
  until param == timer
end
assert_eq(run_sleep(bios_sleep, 2, { drop = true, others = true }), nil,
  'Gegenprobe: das bios-os.sleep() bleibt mit verlorenem Timer haengen')

-- 4. install() ersetzt os.sleep und sleep.
os.startTimer = function() return 1 end
os.pullEvent = function() return 'timer', 1 end
assert_true(guard.install(), 'install() muss greifen, wenn die CC-APIs da sind')
assert_true(os.sleep == guard.sleep, 'os.sleep muss ersetzt sein')
assert_true(rawget(_G, 'sleep') == guard.sleep, 'sleep muss ersetzt sein')

-- 5. start.lua setzt es ein, bevor irgendetwas os.sleep() aufruft.
do
  local f = assert(io.open('xreactor/start.lua', 'r'))
  local src = f:read('*a')
  f:close()
  -- Zeilennummern im Code, Kommentarzeilen nicht mitgezaehlt.
  local install_line, first_sleep_line
  local number = 0
  for line in (src .. '\n'):gmatch('([^\n]*)\n') do
    number = number + 1
    if not line:match('^%s*%-%-') then
      if not install_line and line:find('"/core/sleep_guard.lua"', 1, true) then install_line = number end
      if not first_sleep_line and line:find('os.sleep(', 1, true) then first_sleep_line = number end
    end
  end
  assert_true(install_line ~= nil, 'start.lua muss core/sleep_guard.lua laden')
  assert_true(first_sleep_line == nil or install_line < first_sleep_line,
    'start.lua muss sleep_guard laden, bevor es os.sleep() aufruft')
end

os.startTimer, os.pullEvent, os.clock, os.sleep = real.startTimer, real.pullEvent, real.clock, real.sleep
rawset(_G, 'sleep', real.global_sleep)

print('ok sleep_guard_test')
