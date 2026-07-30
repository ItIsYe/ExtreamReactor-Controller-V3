package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer ENERGY-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 15 "Heartbeat-Zeitquelle nicht konsolidiert").
-- Vor diesem Fix pflegte nodes/energy/heartbeat.lua eine EIGENE, private
-- "last_heartbeat_ts"-Kopie im ctx (per make_hb_ctx() mit 0 initialisiert),
-- komplett unabhaengig von hb_state.last_ts in nodes/energy/main.lua (der
-- Quelle, die der Matrix-Thread ueber send_heartbeat_if_due() prueft). Die
-- Timer-ausgeloeste Sendung in heartbeat.lua war zudem UNBEDINGT (kein
-- Faelligkeits-Check gegen die geteilte Quelle) -- ein modem_message-Event
-- kurz nach einem bereits (von main.lua selbst oder vom Matrix-Thread)
-- gesendeten Heartbeat loeste ueber die private, noch bei 0 stehende Kopie
-- sofort einen unnoetigen Zusatz-Send aus.
--
-- Dieser Test treibt das echte, require()-bare Modul nodes/energy/
-- heartbeat.lua mit einem Fake-Ctx, der die geteilte main.lua-Semantik
-- nachbildet (EIN gemeinsamer last_ts-Zustand fuer send_heartbeat_if_due()
-- UND get_last_heartbeat_ts(), genau wie hb_state in main.lua), und beweist,
-- dass ein Event, das kurz nach einem Send eintrifft, KEINEN zweiten,
-- unnoetigen Send ausloest -- sowohl ueber den Timer- als auch den
-- modem_message-Pfad.

local heartbeat_mod = require('nodes.energy.heartbeat')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- 1. Geteilte Zeitquelle: ein modem_message-Event, das (in echter Millisek-
--    unden-Zeit) kurz NACH einem bereits erfolgten Send eintrifft, darf
--    KEINEN weiteren Send ausloesen -- unabhaengig davon, ob dieser vorherige
--    Send vom Heartbeat-Thread selbst oder von aussen (main.lua's initialer
--    Send vor parallel.waitForAny(), oder der Matrix-Thread) kam.
do
  -- Bildet main.lua's echte hb_state/send_heartbeat_if_due()-Semantik nach:
  -- EIN gemeinsamer last_ts-Zustand, den sowohl send_heartbeat_if_due() als
  -- auch get_last_heartbeat_ts() lesen/schreiben.
  local hb_state = { last_ts = 1000 }  -- simuliert: main.lua hat bei t=1000 bereits gesendet
  local interval_ms = 2000
  local send_count = 0

  local now = 1000
  local next_timer_id = 0
  local os_start_timer = os.startTimer
  os.startTimer = function(_s) next_timer_id = next_timer_id + 1; return next_timer_id end

  local event_queue = {
    { 'timer', 2 },        -- svc_timer (2. os.startTimer-Aufruf beim Loop-Start)
    { 'modem_message' },   -- trifft bei now=1050 ein -- 50ms nach dem letzten Send, weit unter dem 2000ms-Intervall
    { 'terminate' },
  }
  local os_pull_event_raw = os.pullEventRaw
  os.pullEventRaw = function()
    local e = table.remove(event_queue, 1)
    if not e then error('event queue exhausted') end
    if e[1] == 'modem_message' then now = 1050 end
    return table.unpack(e)
  end

  local ctx = {
    comms = { handle_event = function() end, tick = function() end },
    config = {}, devices = {}, ui_state = {}, ui_pages = {},
    services = { tick = function() end },
    now_ms = function() return now end,
    log = function() end,
    last_heartbeat_warn_ts = 0,
    heartbeat_interval_ms = function() return interval_ms end,
    get_last_heartbeat_ts = function() return hb_state.last_ts end,
    send_heartbeat_if_due = function(ts)
      if (ts - hb_state.last_ts) >= interval_ms then
        hb_state.last_ts = ts
        send_count = send_count + 1
        return true
      end
      return false
    end,
    tick_interval_s = 0.5,
  }

  local result = heartbeat_mod.run(ctx)
  os.startTimer = os_start_timer
  os.pullEventRaw = os_pull_event_raw

  assert_eq(result, 'terminate', 'the loop should exit cleanly on a terminate event')
  assert_eq(send_count, 0,
    'a modem_message event 50ms after a prior send (2000ms interval) must NOT trigger an extra send -- ' ..
    'a private, un-synced last_heartbeat_ts copy starting at 0 would wrongly consider this "due"')
end

-- 2. Der Timer-Pfad muss ebenfalls gegen die geteilte Quelle gaten: wenn der
--    Matrix-Thread (oder ein anderer Aufrufer) kurz vor dem hb_timer bereits
--    ueber dieselbe geteilte Quelle gesendet hat, darf der Timer-Tick NICHT
--    unbedingt nachsenden.
do
  local hb_state = { last_ts = 1000 }
  local interval_ms = 2000
  local send_count = 0

  local now = 1000
  local next_timer_id = 0
  local os_start_timer = os.startTimer
  os.startTimer = function(_s) next_timer_id = next_timer_id + 1; return next_timer_id end

  local event_queue = {
    { 'timer', 2 },  -- svc_timer
    { 'timer', 1 },  -- hb_timer -- feuert bei now=1200, also NUR 200ms nach dem letzten Send
    { 'terminate' },
  }
  local os_pull_event_raw = os.pullEventRaw
  os.pullEventRaw = function()
    local e = table.remove(event_queue, 1)
    if not e then error('event queue exhausted') end
    if e[1] == 'timer' and e[2] == 1 then now = 1200 end
    return table.unpack(e)
  end

  local ctx = {
    comms = { handle_event = function() end, tick = function() end },
    config = {}, devices = {}, ui_state = {}, ui_pages = {},
    services = { tick = function() end },
    now_ms = function() return now end,
    log = function() end,
    last_heartbeat_warn_ts = 0,
    heartbeat_interval_ms = function() return interval_ms end,
    get_last_heartbeat_ts = function() return hb_state.last_ts end,
    send_heartbeat_if_due = function(ts)
      if (ts - hb_state.last_ts) >= interval_ms then
        hb_state.last_ts = ts
        send_count = send_count + 1
        return true
      end
      return false
    end,
    tick_interval_s = 0.5,
  }

  local result = heartbeat_mod.run(ctx)
  os.startTimer = os_start_timer
  os.pullEventRaw = os_pull_event_raw

  assert_eq(result, 'terminate', 'the loop should exit cleanly on a terminate event')
  assert_eq(send_count, 0,
    'the hb_timer firing 200ms after a prior send (2000ms interval) must NOT unconditionally send -- ' ..
    'the timer path must gate through the same shared send_heartbeat_if_due() as every other caller')
end

-- 3. Strukturelle Absicherung: heartbeat.lua darf keinen privaten
--    "ctx.last_heartbeat_ts"-Zaehler mehr fuehren/setzen, und main.lua darf
--    make_hb_ctx() nicht mehr mit einer bei 0 initialisierten privaten
--    Kopie oder dem ungegateten send_heartbeat verdrahten.
do
  local function read(path)
    local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
    local c = f:read('*a')
    f:close()
    return c
  end

  local hb_source = read('xreactor/nodes/energy/heartbeat.lua')
  assert_true(not hb_source:find('ctx.last_heartbeat_ts', 1, true),
    'heartbeat.lua must not reference a private ctx.last_heartbeat_ts counter anymore')
  assert_true(hb_source:find('ctx.get_last_heartbeat_ts()', 1, true) ~= nil,
    'heartbeat.lua must read the shared last-sent timestamp via ctx.get_last_heartbeat_ts()')
  assert_true(hb_source:find('ctx.send_heartbeat_if_due(now)', 1, true) ~= nil,
    'heartbeat.lua must gate every send through ctx.send_heartbeat_if_due(now), timer and event path alike')

  local main_source = read('xreactor/nodes/energy/main.lua')
  assert_true(not main_source:find('last_heartbeat_ts = 0, last_heartbeat_warn_ts = 0,', 1, true),
    'make_hb_ctx() must no longer seed a private, un-synced last_heartbeat_ts = 0 field')
  assert_true(main_source:find('send_heartbeat_if_due = send_heartbeat_if_due,', 1, true) ~= nil,
    'make_hb_ctx() must pass the shared send_heartbeat_if_due to the heartbeat thread')
  assert_true(main_source:find('get_last_heartbeat_ts = get_last_heartbeat_ts,', 1, true) ~= nil,
    'make_hb_ctx() must pass a getter for the shared last-sent timestamp to the heartbeat thread')
end

print('energy_heartbeat_shared_last_ts_test.lua: ok')
