package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer INSTALL-P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 4). Vor diesem Fix hatte nodes/
-- support/runtime.lua's run_event_loop() (gemeinsame Hauptschleife von RT/
-- VALVE/FUEL/REPROCESSOR/WATER) UEBERHAUPT KEINEN kontrollierten Weg, die
-- Schleife zu verlassen -- ein Auto-Update konnte Dateien ersetzen, WAEHREND
-- die Rolle weiter Hardware steuerte.
--
-- Dieser Test treibt die ECHTE run_event_loop()-Funktion mit einer
-- gemockten os.pullEvent/os.startTimer-Eventquelle und einem echten core/
-- update_handshake.lua-Objekt: (1) mit QUIESCE_REQUESTED wird on_quiesce()
-- bei jedem Zyklus erneut versucht, bis es EXPLIZIT true liefert, (2) nil
-- bleibt fail-closed, (3) ein fehlender Callback bleibt fail-closed, und
-- (4) ohne quiesce_opts aendert sich am bisherigen Verhalten nichts.

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

local function fresh_services()
  local ticks = 0
  return { tick = function() ticks = ticks + 1 end }, function() return ticks end
end

local function with_timer_event_source(limit, fn)
  local os_start_timer = os.startTimer
  local os_pull_event = os.pullEvent
  local timer_id = 0
  local pulls = 0
  os.startTimer = function() timer_id = timer_id + 1; return timer_id end
  os.pullEvent = function()
    pulls = pulls + 1
    if pulls > limit then
      error('terminate: test boundary')
    end
    return 'timer', timer_id
  end
  local ok, err = pcall(fn, function() return pulls end)
  os.startTimer = os_start_timer
  os.pullEvent = os_pull_event
  if not ok then error(err, 0) end
end

-- 1. on_quiesce() wird wiederholt versucht, bis es true liefert; erst dann
--    endet die Schleife sauber und der Handshake landet bei RUNTIME_STOPPED.
do
  local services, get_ticks = fresh_services()
  local comms = { handle_event = function() end }
  local handshake = update_handshake.new()
  update_handshake.request_quiesce(handshake)
  local quiesce_attempts = 0

  with_timer_event_source(50, function()
    support_runtime.run_event_loop(1, services, comms, nil, {
      handshake = handshake,
      on_quiesce = function()
        quiesce_attempts = quiesce_attempts + 1
        return quiesce_attempts >= 3
      end,
    })
  end)

  assert_eq(quiesce_attempts, 3, 'on_quiesce must be retried until it explicitly confirms a safe state')
  assert_eq(handshake.state, update_handshake.STATE.RUNTIME_STOPPED,
    'the handshake must reach RUNTIME_STOPPED once on_quiesce confirms safety')
  assert_true(get_ticks() >= 3, 'services:tick() must keep running normally during the quiesce retries')
end

-- 2. nil is NOT a confirmation. The old implementation used
--    `result3 ~= false`, which made an omitted return value silently safe.
do
  local services = { tick = function() end }
  local comms = { handle_event = function() end }
  local handshake = update_handshake.new()
  update_handshake.request_quiesce(handshake)
  local attempts = 0

  with_timer_event_source(4, function()
    support_runtime.run_event_loop(1, services, comms, nil, {
      handshake = handshake,
      on_quiesce = function()
        attempts = attempts + 1
        return nil
      end,
    })
  end)

  assert_true(attempts >= 1, 'nil-returning quiesce callback must be attempted')
  assert_eq(handshake.state, update_handshake.STATE.QUIESCE_REQUESTED,
    'nil quiesce result must remain fail-closed at QUIESCE_REQUESTED')
end

-- 3. A handshake without an actuator callback is ambiguous and must not
--    automatically advance to RUNTIME_STOPPED.
do
  local services = { tick = function() end }
  local comms = { handle_event = function() end }
  local handshake = update_handshake.new()
  update_handshake.request_quiesce(handshake)

  with_timer_event_source(4, function()
    support_runtime.run_event_loop(1, services, comms, nil, { handshake = handshake })
  end)

  assert_eq(handshake.state, update_handshake.STATE.QUIESCE_REQUESTED,
    'missing on_quiesce callback must remain fail-closed')
end

-- 4. Ohne quiesce_opts darf sich am Verhalten nichts aendern: die Schleife
--    laeuft bis zur Testgrenze weiter, ohne stillen Quiesce-Exit.
do
  local cycles = 0
  with_timer_event_source(3, function(get_pulls)
    local services = { tick = function() cycles = get_pulls() end }
    local comms = { handle_event = function() end }
    support_runtime.run_event_loop(1, services, comms, nil, nil)
  end)
  assert_true(cycles >= 1, 'without quiesce_opts the loop must keep running normally')
end

print('support_runtime_quiesce_test.lua: ok')
