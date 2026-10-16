-- tests/log_collector_lost_timer_test.lua
--
-- Ein verlorenes Timer-Ereignis darf die Hauptschleife des Log-Collectors
-- nicht stilllegen.
--
-- nodes/log_collector/main.lua erledigt Ping, Flush, Schirm und
-- Quiesce-Pruefung nur in seinem 1-s-Takt. Bis v813 wartete die Schleife
-- dafuer auf genau EINEN Timer; CC:Tweaked verwirft aber Ereignisse, sobald
-- 256 in der Warteschlange stehen -- Timer eingeschlossen. Ging er verloren,
-- standen Ping und Flush bis zum Neustart, und die Knoten hielten den
-- Collector fuer offline.
--
-- main.lua hat Boot-Seiteneffekte und laesst sich nicht require()n; run()
-- wird wie in log_collector_broadcast_ping_test.lua an Markern
-- herausgeschnitten und mit Stubs fuer seine Helfer gefahren. Die Konstanten
-- kommen aus der echten Datei.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local function read(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local c = f:read('*a')
  f:close()
  return c
end

local SOURCE = read('xreactor/nodes/log_collector/main.lua')
local start_pos = assert(SOURCE:find('local function run()', 1, true), 'run() nicht gefunden')
local end_pos = assert(SOURCE:find('\nend\n\n-- \xe2\x94\x80\xe2\x94\x80 Crash screen', start_pos, true),
  'Ende von run() nicht gefunden')
local RUN_SRC = SOURCE:sub(start_pos, end_pos + 3) .. '\nreturn run\n'

local function constant(name, fallback)
  local value = SOURCE:match('\nlocal ' .. name .. '%s*=%s*([%d%.]+)')
  return tonumber(value) or fallback
end

local STEP_MS = 50

local function drive(seconds, drop)
  local now_ms, next_id, timers, own = 0, 0, {}, 0
  local fake_os = {
    clock = function() return now_ms / 1000 end,
    startTimer = function(s)
      next_id = next_id + 1
      timers[next_id] = now_ms + math.floor((tonumber(s) or 0) * 1000 + 0.5)
      return next_id
    end,
    cancelTimer = function(id) timers[id] = nil end,
    pullEvent = function(filter) return coroutine.yield(filter) end,
  }
  local ticks, diags = 0, {}
  local noop = function() end
  local env = setmetatable({
    os = fake_os,
    stats = { disks = {}, next_ping = 0, last_draw_s = 0, dropped = 0 },
    find_display = function() return nil, nil end,
    refresh_disks = noop, refresh_modems = noop, self_log = noop, draw = noop,
    broadcast_ping = noop, check_log_freshness = noop,
    flush_due = function() ticks = ticks + 1 end,
    diag = function(msg) diags[#diags + 1] = tostring(msg) end,
    now_s = function() return math.floor(now_ms / 1000) end,
    clock_s = function() return now_ms / 1000 end,
    valid_log_event = function() return false end,
    handle_touch = noop, toggle_pause = noop,
    require = function() error('nicht im Test') end,
    LOOP_TICK_S = constant('LOOP_TICK_S', 1),
    LOST_TIMER_GRACE_S = constant('LOST_TIMER_GRACE_S', 1.0),
    LOG_PING_INTERVAL_S = constant('LOG_PING_INTERVAL_S', 20),
    DRAW_INTERVAL_S = constant('DRAW_INTERVAL_S', 5),
    ACTIVE_DRAW_MIN_INTERVAL_S = constant('ACTIVE_DRAW_MIN_INTERVAL_S', 1),
    CHANNEL = 6503,
  }, { __index = _G })
  local run = assert(load(RUN_SRC, '=log_collector_run', 't', env))()

  local co = coroutine.create(run)
  local ok, filter = coroutine.resume(co)
  assert(ok, filter)
  local modem_at = 50
  local ticks_at = {}
  for _ = 1, math.floor(seconds * 1000 / STEP_MS) do
    now_ms = now_ms + STEP_MS
    local events = {}
    local due = {}
    for id, at in pairs(timers) do
      if at <= now_ms then due[#due + 1] = id end
    end
    table.sort(due)
    for _, id in ipairs(due) do
      timers[id] = nil
      own = own + 1
      if drop ~= own then events[#events + 1] = { 'timer', id } end
    end
    if now_ms >= modem_at then
      modem_at = modem_at + 50
      events[#events + 1] = { 'modem_message', 'back', 1, 1, {}, 1 }
    end
    for _, ev in ipairs(events) do
      if coroutine.status(co) == 'suspended' and (filter == nil or filter == ev[1]) then
        ok, filter = coroutine.resume(co, table.unpack(ev))
        assert(ok, filter)
      end
    end
    ticks_at[now_ms] = ticks
  end
  return { ticks = ticks, ticks_at = ticks_at, diags = diags }
end

-- ══ 1. Ohne Verlust: ein Takt je Sekunde ═════════════════════════════════
local base = drive(30)
assert_eq(base.ticks, 30, 'ohne Verlust ein Takt je Sekunde')

-- ══ 2. Ein Timer geht verloren ═══════════════════════════════════════════
do
  local r = drive(45, 10)
  local at_15s = r.ticks_at[15000]
  assert_true(at_15s and r.ticks > at_15s + 25,
    ('der Log-Collector steht nach EINEM verlorenen Timer still (Takte bei 15 s: %s, bei 45 s: %s)')
      :format(tostring(at_15s), tostring(r.ticks)))
  assert_true(r.ticks >= 43,
    ('mehr als zwei Sekunden Pause nach dem Verlust (Takte: %d von 45)'):format(r.ticks))
  local noticed = false
  for _, line in ipairs(r.diags) do
    if line:find('Takt-Timer ausgeblieben', 1, true) then noticed = true end
  end
  assert_true(noticed, 'der ausgebliebene Timer muss auf dem Diagnose-Schirm erscheinen')
end

print('ok log_collector_lost_timer_test')
