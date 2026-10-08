-- tests/auto_update_lost_timer_test.lua
--
-- Ein verlorenes Timer-Ereignis darf die Update-Pruefung nicht fuer immer
-- abstellen.
--
-- installer/auto_update.lua's M.make_loop() wartete bis v813 auf genau EINEN
-- Timer zwischen zwei Pruefungen. CC:Tweaked verwirft Ereignisse, sobald 256
-- in der Warteschlange stehen -- Timer eingeschlossen. Ging er verloren,
-- pruefte der Knoten bis zum Neustart nie wieder auf Updates.
--
-- Faehrt die echte Schleife mit simulierter Uhr. Wie in
-- auto_update_loop_cadence_test.lua ist der Knoten nicht scharf geschaltet
-- (fs.exists() liefert immer false): jede Pruefung loggt nur "Auto-Update
-- uebersprungen" und kehrt zurueck -- genau diese Zeilen werden gezaehlt.
-- Nebenher laufen, wie im Spiel, Funknachrichten ein (jede Sekunde).

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local real_print = print

local function drive(seconds, drop)
  local lines = {}
  _G.print = function(msg) lines[#lines + 1] = tostring(msg) end
  local now_s, next_id, timers, own = 0, 0, {}, 0
  _G.os = {
    startTimer = function(delay)
      next_id = next_id + 1
      timers[next_id] = now_s + (tonumber(delay) or 0)
      return next_id
    end,
    cancelTimer = function(id) timers[id] = nil end,
    pullEvent = function() return coroutine.yield() end,
    epoch = function() return now_s * 1000 end,
    clock = function() return now_s end,
    sleep = function() end,
    getComputerID = function() return 0 end,  -- Jitter 0
  }
  _G.fs = { exists = function() return false end }
  _G.dofile = function(path)
    if path == '/xreactor/core/update_handshake.lua' then
      return { peek_remote_update = function() return nil end }
    end
    error('unexpected dofile: ' .. tostring(path))
  end

  package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
  package.loaded['installer.auto_update'] = nil
  local auto_update = require('installer.auto_update')
  local co = coroutine.create(auto_update.make_loop(120, {}))
  local ok, err = coroutine.resume(co)
  assert(ok, err)

  for _ = 1, seconds do
    now_s = now_s + 1
    local events = {}
    local due = {}
    for id, at in pairs(timers) do
      if at <= now_s then due[#due + 1] = id end
    end
    table.sort(due)
    for _, id in ipairs(due) do
      timers[id] = nil
      own = own + 1
      if not drop or drop ~= own then events[#events + 1] = { 'timer', id } end
    end
    events[#events + 1] = { 'modem_message', 'back', 1, 1, {}, 1 }
    for _, ev in ipairs(events) do
      ok, err = coroutine.resume(co, table.unpack(ev))
      assert(ok, err)
      assert(coroutine.status(co) ~= 'dead', 'make_loop() darf nie enden')
    end
  end
  _G.print = real_print

  local checks, notices = 0, 0
  for _, line in ipairs(lines) do
    if line:find('Auto-Update uebersprungen', 1, true) then checks = checks + 1 end
    if line:find('Timer ausgeblieben', 1, true) then notices = notices + 1 end
  end
  return { checks = checks, notices = notices }
end

-- ══ 1. Ohne Verlust: erste Pruefung nach 30 s, dann alle 120 s ═══════════
-- (30, 150, 270, ..., 990)
local base = drive(1000)
assert_eq(base.checks, 9, 'ohne Verlust: neun Pruefungen in 1000 s')
assert_eq(base.notices, 0, 'ohne Verlust: keine Meldung')

-- ══ 2. Der Timer vor der zweiten Pruefung geht verloren ═══════════════════
--
-- Die Pruefung darf sich um die Schonzeit verschieben, aber nicht ausfallen.
local dropped = drive(1000, 2)
assert_true(dropped.checks >= 8,
  ('die Update-Pruefung steht nach EINEM verlorenen Timer still (Pruefungen: %d, ohne Verlust 9)')
    :format(dropped.checks))
assert_eq(dropped.notices, 1, 'der ausgebliebene Timer wird einmal gemeldet')

print('ok auto_update_lost_timer_test')
