package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer die Aufteilung von nodes/support/runtime.lua's
-- bisheriger EINEN run_event_loop()-Coroutine in run_fast_loop()/
-- run_slow_loop() (siehe deren Kommentare dort fuer die Begruendung: ein
-- langsamer/blockierender Service in einer gemeinsamen sequentiellen Liste
-- friert sonst auch UI/Touch/Ventil-Sicherheit fuer seine eigene Laufzeit
-- ein). Dieser Test treibt beide Funktionen einzeln mit gemocktem
-- os.pullEvent/os.startTimer/os.sleep, genau wie support_runtime_
-- quiesce_test.lua es fuer die urspruengliche run_event_loop() tut:
-- (1) run_fast_loop() dispatcht modem_message/Touch-Events an services UND
--     wiederholt on_quiesce(), bis es true liefert, danach RUNTIME_STOPPED;
-- (2) run_fast_loop() ohne quiesce_opts aendert nichts am Verhalten;
-- (3) run_slow_loop() tickt services periodisch per os.sleep(interval) und
--     ruft after_cycle() nach jedem Tick auf, ohne jemals Events zu lesen.

local support_runtime = require('nodes.support.runtime')
local update_handshake = require('core.update_handshake')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- 1. run_fast_loop(): on_quiesce() wird wiederholt versucht, bis es true
--    liefert; erst dann endet die Funktion sauber mit RUNTIME_STOPPED.
do
  local os_start_timer = os.startTimer
  local os_pull_event = os.pullEvent
  local timer_id = 0
  os.startTimer = function() timer_id = timer_id + 1; return timer_id end

  local pulls = 0
  os.pullEvent = function()
    pulls = pulls + 1
    if pulls > 50 then
      error('terminate: run_fast_loop() did not exit after 50 cycles -- quiesce_opts is being ignored (regression)')
    end
    return 'timer', timer_id
  end

  local ticks = 0
  local services = { tick = function() ticks = ticks + 1 end }
  local comms = { handle_event = function() end }
  local handshake = update_handshake.new()
  update_handshake.request_quiesce(handshake)

  local quiesce_attempts = 0
  local quiesce_opts = {
    handshake = handshake,
    on_quiesce = function()
      quiesce_attempts = quiesce_attempts + 1
      return quiesce_attempts >= 3
    end,
  }

  support_runtime.run_fast_loop({
    receive_timeout = 1, services = services, comms = comms, quiesce_opts = quiesce_opts,
  })

  os.startTimer = os_start_timer
  os.pullEvent = os_pull_event

  assert_eq(quiesce_attempts, 3, 'on_quiesce must be retried until it confirms a safe state')
  assert_eq(handshake.state, update_handshake.STATE.RUNTIME_STOPPED,
    'the handshake must reach RUNTIME_STOPPED once on_quiesce confirms safety')
  assert_true(ticks >= 3, 'services:tick() must keep running normally during the quiesce retries')
end

-- 2. run_fast_loop(): ohne quiesce_opts laeuft die Schleife unveraendert
--    weiter, bis sie durch einen Fehler verlassen wird (kein stiller Exit).
do
  local os_start_timer = os.startTimer
  local os_pull_event = os.pullEvent
  local timer_id = 0
  os.startTimer = function() timer_id = timer_id + 1; return timer_id end

  local cycles = 0
  os.pullEvent = function()
    cycles = cycles + 1
    if cycles > 3 then error('terminate: test boundary') end
    return 'timer', timer_id
  end

  local services = { tick = function() end }
  local comms = { handle_event = function() end }

  local ok, err = pcall(support_runtime.run_fast_loop, {
    receive_timeout = 1, services = services, comms = comms,
  })

  os.startTimer = os_start_timer
  os.pullEvent = os_pull_event

  assert_true(not ok, 'run_fast_loop must propagate the boundary error, not exit silently')
  assert_true(tostring(err):find('terminate', 1, true) ~= nil)
  assert_true(cycles > 3, 'without quiesce_opts the loop must keep running normally (no silent early exit)')
end

-- 3. run_fast_loop(): ein modem_message-Event geht sowohl an comms als auch
--    an services:tick(nil, event) -- identisch zur bisherigen run_event_loop().
do
  local os_start_timer = os.startTimer
  local os_pull_event = os.pullEvent
  local timer_id = 0
  os.startTimer = function() timer_id = timer_id + 1; return timer_id end

  local events = { { 'modem_message', 1, 6500, 6500, { type = 'X' }, -1 } }
  os.pullEvent = function()
    local e = table.remove(events, 1)
    if e then return table.unpack(e) end
    error('terminate: test boundary')
  end

  local comms_calls, tick_events = 0, {}
  local comms = { handle_event = function() comms_calls = comms_calls + 1 end }
  -- services:tick(nil, event) is a colon-call (self is the implicit first
  -- arg) -- the test double's signature must account for that, exactly
  -- like the real service_manager:tick(self, dt, event).
  local services = { tick = function(_self, _dt, event) tick_events[#tick_events + 1] = event end }

  local ok, err = pcall(support_runtime.run_fast_loop, {
    receive_timeout = 1, services = services, comms = comms,
  })

  os.startTimer = os_start_timer
  os.pullEvent = os_pull_event

  assert_true(not ok and tostring(err):find('terminate', 1, true) ~= nil)
  assert_eq(comms_calls, 1, 'comms:handle_event must be called for a modem_message event')
  assert_true(#tick_events >= 1 and tick_events[1] ~= nil,
    'services:tick(nil, event) must be called with the raw event for a modem_message')
end

-- 4. run_slow_loop(): tickt services periodisch (os.sleep-getrieben) und
--    ruft after_cycle() nach jedem Tick auf -- liest nie Events.
do
  local os_sleep = os.sleep
  local sleeps = 0
  os.sleep = function()
    sleeps = sleeps + 1
    if sleeps > 5 then error('terminate: test boundary') end
  end

  local ticks, after_calls = 0, 0
  local services = { tick = function() ticks = ticks + 1 end }

  local ok, err = pcall(support_runtime.run_slow_loop, {
    interval = 5, services = services, after_cycle = function() after_calls = after_calls + 1 end,
  })

  os.sleep = os_sleep

  assert_true(not ok and tostring(err):find('terminate', 1, true) ~= nil)
  assert_eq(ticks, 5, 'run_slow_loop must tick services once per os.sleep(interval) cycle')
  assert_eq(after_calls, 5, 'run_slow_loop must call after_cycle once per tick cycle')
end

-- 5. run_slow_loop(): a failing services:tick() must not abort the loop
--    (identical resilience to the fast loop's per-cycle pcall wrapping).
do
  local os_sleep = os.sleep
  local sleeps = 0
  os.sleep = function()
    sleeps = sleeps + 1
    if sleeps > 2 then error('terminate: test boundary') end
  end

  local ticks = 0
  local services = { tick = function()
    ticks = ticks + 1
    error('simulated slow-service failure')
  end }

  local ok, err = pcall(support_runtime.run_slow_loop, { interval = 5, services = services })

  os.sleep = os_sleep

  assert_true(not ok and tostring(err):find('terminate', 1, true) ~= nil)
  assert_eq(ticks, 2, 'a failing services:tick() must be caught per-cycle, not abort run_slow_loop')
end

print('support_runtime_split_loop_test.lua: ok')
